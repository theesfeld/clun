;;;; coroutine.lisp — the generator/async execution primitive (PLAN.md Phase 06,
;;;; §3.1 fallback: thread-per-coroutine with a semaphore handoff). A coroutine runs
;;;; an ORDINARY compiled body closure on its own sb-thread; yield/await suspend it
;;;; via strict semaphore ping-pong so the real CL stack (and thus try/finally ×
;;;; yield × return) is preserved for free, and exactly one of {driver, coroutine}
;;;; is ever runnable — the single-heap-owner invariant holds cooperatively.
;;;; DECISIONS 2026-07-11 records why we take the fallback over state-machine lowering.

(in-package :clun.engine)

(defstruct (coroutine (:constructor %make-coroutine) (:conc-name coro-))
  thread
  (state :suspended-start)       ; :suspended-start :suspended-yield :running :completed
  (resume-sem (sb-thread:make-semaphore))   ; driver posts, coroutine waits
  (yield-sem (sb-thread:make-semaphore))     ; coroutine posts, driver waits
  in-box                         ; (mode . value): mode in {:next :throw :return}
  out-box                        ; (kind . value): kind in {:yield :return :throw}
  body                           ; zero-arg thunk running the compiled function body
  (realm *realm*))

;; A private catch tag: .return() throws it on the coroutine thread to unwind the
;; real stack through every finally. One interned symbol is safe across threads —
;; catch/throw is per-stack, and each coroutine catches on its own thread's stack.
(defvar *coroutine-return-tag* '%coroutine-return%)

(defun make-coroutine (body)
  "A suspended coroutine over BODY (a zero-arg thunk). Registered with the current
realm so teardown can force-finish it (leak control for the conformance run)."
  (let ((co (%make-coroutine :body body :realm *realm*)))
    (when *realm* (push co (realm-coroutines *realm*)))
    co))

(defun %coroutine-thread-body (co)
  "Runs on the coroutine's own thread. Rebinds *realm* and re-enters the float-trap
mask (both required — the thread runs outside the driver's dynamic extent)."
  (let ((*realm* (coro-realm co)))
    (with-js-floats
      (sb-thread:wait-on-semaphore (coro-resume-sem co))     ; wait for the first resume
      (let ((result
             (catch *coroutine-return-tag*                   ; .return()/early-return land here
               (destructuring-bind (mode . v) (coro-in-box co)
                 (ecase mode
                   (:next (handler-case (cons :return (funcall (coro-body co)))
                            (js-condition (c) (cons :throw (js-condition-value c)))))
                   ;; .throw()/.return() on a not-yet-started coroutine complete it directly
                   (:throw (cons :throw v))
                   (:return (cons :return v)))))))
        (setf (coro-out-box co) result
              (coro-state co) :completed)
        (sb-thread:signal-semaphore (coro-yield-sem co))))))

(defun coroutine-resume (co mode value)
  "Drive CO with MODE (:next/:throw/:return) + VALUE from the driver (loop) thread.
Returns (values kind result) where kind is :yield, :return, or :throw."
  (ecase (coro-state co)
    ((:suspended-start :suspended-yield)
     (setf (coro-in-box co) (cons mode value)
           (coro-state co) :running)
     (unless (coro-thread co)
       (setf (coro-thread co)
             (sb-thread:make-thread (lambda () (%coroutine-thread-body co))
                                    :name "clun-coroutine")))
     (sb-thread:signal-semaphore (coro-resume-sem co))
     (sb-thread:wait-on-semaphore (coro-yield-sem co))
     (let ((out (coro-out-box co)))
       (values (car out) (cdr out))))
    (:completed (values :return +undefined+))
    (:running (throw-type-error "generator is already running"))))

(defun coroutine-suspend (co kind value)
  "Runs ON the coroutine thread (called by yield/await). Hand (KIND . VALUE) to the
driver — KIND is :yield (generator) or :await (async) — park until resumed, then act
on the injected mode: :next returns the value, :throw raises it at the suspension
point, :return unwinds through finally blocks."
  (setf (coro-out-box co) (cons kind value)
        (coro-state co) :suspended-yield)
  (sb-thread:signal-semaphore (coro-yield-sem co))
  (sb-thread:wait-on-semaphore (coro-resume-sem co))
  (destructuring-bind (mode . v) (coro-in-box co)
    (ecase mode
      (:next v)
      (:throw (throw-js-value v))
      (:return (throw *coroutine-return-tag* (cons :return v))))))

(defun coroutine-suspend-raw (co value)
  "Like COROUTINE-SUSPEND but returns the raw injected (mode . value) cons instead of
acting on it — yield* must forward .throw/.return to the inner iterator itself."
  (setf (coro-out-box co) (cons :yield value)
        (coro-state co) :suspended-yield)
  (sb-thread:signal-semaphore (coro-yield-sem co))
  (sb-thread:wait-on-semaphore (coro-resume-sem co))
  (coro-in-box co))

(defun teardown-coroutines (realm)
  "Force-finish every live coroutine and join its thread. A suspended coroutine gets
a bounded .return() (inject → unwind through finally); a runaway one (still :running
because the runner's timeout unwound the driver mid-resume, e.g. an infinite loop) is
terminated. All waits are bounded so a wedged test can never hang teardown."
  (dolist (co (realm-coroutines realm))
    (let ((th (coro-thread co)))
      (when (and th (sb-thread:thread-alive-p th))
        (cond
          ((member (coro-state co) '(:suspended-start :suspended-yield))
           (setf (coro-in-box co) (cons :return +undefined+))
           (sb-thread:signal-semaphore (coro-resume-sem co))
           (unless (sb-thread:wait-on-semaphore (coro-yield-sem co) :timeout 0.5)
             (ignore-errors (sb-thread:terminate-thread th))))
          (t (ignore-errors (sb-thread:terminate-thread th))))
        (ignore-errors (sb-thread:join-thread th :timeout 1)))))
  (setf (realm-coroutines realm) '()))
