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
  out-box                        ; :yield, :yield-no-await, :yield-result, :await, :return, :throw
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

(defun complete-unstarted-coroutine (co)
  "Complete CO without starting a thread and remove its teardown registration."
  (unless (eq (coro-state co) :suspended-start)
    (error "cannot complete a coroutine in state ~s without resuming it"
           (coro-state co)))
  (setf (coro-state co) :completed
        (coro-out-box co) (cons :return +undefined+))
  (when (coro-realm co)
    (setf (realm-coroutines (coro-realm co))
          (delete co (realm-coroutines (coro-realm co)))))
  co)

(defun %coroutine-thread-body (co)
  "Runs on the coroutine's own thread. Rebinds *realm* and re-enters the float-trap
mask (both required — the thread runs outside the driver's dynamic extent)."
  (let ((*realm* (coro-realm co))
        (lp:*on-foreign-thread* t))          ; reactor ops here must marshal to the loop thread
    (with-js-floats
      (sb-thread:wait-on-semaphore (coro-resume-sem co))     ; wait for the first resume
      (let ((result
             (catch *coroutine-return-tag*                   ; .return()/early-return land here
               (destructuring-bind (mode . v) (coro-in-box co)
                 (ecase mode
                   (:next (handler-case (cons :return (funcall (coro-body co)))
                            (js-condition (c) (cons :throw (js-condition-value c)))
                            ;; A non-JS serious-condition (e.g. the runtime's process-exit,
                            ;; or a stray Lisp error) must NOT die on this side thread with a
                            ;; raw backtrace (§6). Marshal it back so coroutine-resume re-raises
                            ;; it on the driver (JS) thread, where the top-level handler runs.
                            (serious-condition (c) (cons :control c))))
                   ;; .throw()/.return() on a not-yet-started coroutine complete it directly
                   (:throw (cons :throw v))
                   (:return (cons :return v)))))))
        (setf (coro-out-box co) result
              (coro-state co) :completed)
        (sb-thread:signal-semaphore (coro-yield-sem co))))))

(defun coroutine-resume (co mode value)
  "Drive CO with MODE (:next/:throw/:return) + VALUE from the driver (loop) thread.
Returns (values kind result); delegated yields use :YIELD-RESULT to preserve the
validated inner iterator-result object instead of wrapping its value again."
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
       ;; A completed coroutine no longer needs teardown tracking — drop it from the
       ;; realm list (on the driver thread, so this is race-free) so a long-running
       ;; server's async handlers don't accumulate coroutines unboundedly (memory leak).
       (when (and (eq (coro-state co) :completed) (coro-realm co))
         (setf (realm-coroutines (coro-realm co))
               (delete co (realm-coroutines (coro-realm co)))))
       ;; :control = a non-JS condition the body raised (e.g. process-exit); re-signal
       ;; it here on the driver thread so it unwinds to the top-level handler cleanly.
       (if (eq (car out) :control)
           (error (cdr out))
           (values (car out) (cdr out)))))
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

(defun coroutine-suspend-raw (co value &optional (kind :yield))
  "Like COROUTINE-SUSPEND but returns the raw injected (mode . value) cons instead of
acting on it. :YIELD-NO-AWAIT is async delegation's already-adopted value path;
:YIELD-RESULT preserves a synchronous iterator-result object by identity."
  (ecase kind (:yield) (:yield-no-await) (:yield-result))
  (setf (coro-out-box co) (cons kind value)
        (coro-state co) :suspended-yield)
  (sb-thread:signal-semaphore (coro-yield-sem co))
  (sb-thread:wait-on-semaphore (coro-resume-sem co))
  (coro-in-box co))

(defun teardown-coroutines (realm)
  "Force-finish every live coroutine and join its thread. A suspended coroutine gets
a bounded sequence of .return() injections so delegated iterators may yield from
return; a runaway or repeatedly re-yielding coroutine is terminated. All waits are
bounded so a wedged test can never hang teardown."
  (dolist (co (realm-coroutines realm))
    (let ((th (coro-thread co)))
      (when (and th (sb-thread:thread-alive-p th))
        (loop repeat 8
              while (and (sb-thread:thread-alive-p th)
                         (member (coro-state co) '(:suspended-start :suspended-yield)))
              do (setf (coro-in-box co) (cons :return +undefined+))
                 (sb-thread:signal-semaphore (coro-resume-sem co))
                 (unless (sb-thread:wait-on-semaphore (coro-yield-sem co) :timeout 0.5)
                   (return)))
        (unless (eq (coro-state co) :completed)
          (ignore-errors (sb-thread:terminate-thread th)))
        (ignore-errors (sb-thread:join-thread th :timeout 1))
        (when (sb-thread:thread-alive-p th)
          (ignore-errors (sb-thread:terminate-thread th))
          (ignore-errors (sb-thread:join-thread th :timeout 1))))))
  (setf (realm-coroutines realm) '()))
