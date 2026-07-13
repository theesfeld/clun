;;;; timers.lisp — node:timers + node:timers/promises (PLAN.md Phase 14).
;;;; node:timers re-exports the realm's timer globals (installed by the engine
;;;; bootstrap for every realm). node:timers/promises builds Promise/async-iterator
;;;; wrappers over those globals, honouring { signal (AbortSignal), ref } options.

(in-package :clun.runtime)

(defun %tp-signal (opts)
  "opts.signal when it is an object (an AbortSignal), else NIL."
  (when (eng:js-object-p opts)
    (let ((s (eng:js-get opts "signal")))
      (and (eng:js-object-p s) s))))

(defun %tp-ref-p (opts)
  "opts.ref — default true; false means unref the underlying timer."
  (or (not (eng:js-object-p opts))
      (let ((r (eng:js-get opts "ref"))) (or (undef-p r) (eng:js-truthy r)))))

(defun %tp-aborted-p (signal) (and signal (eng:js-truthy (eng:js-get signal "aborted"))))
(defun %tp-reason (signal) (eng:js-get signal "reason"))

(defun %tp-unref (id) (let ((u (and (eng:js-object-p id) (eng:js-get id "unref"))))
                        (when (eng:callable-p u) (eng:js-call u id '()))))

(defun %iter-result (value done)
  (let ((o (eng:new-object)))
    (eng:data-prop o "value" value)
    (eng:data-prop o "done" (eng:js-boolean done))
    o))

;;; --- node:timers ------------------------------------------------------------

(defun build-node-timers ()
  (let ((g (eng:realm-global eng:*realm*)) (o (eng:new-object)))
    (dolist (n '("setTimeout" "setInterval" "setImmediate"
                 "clearTimeout" "clearInterval" "clearImmediate" "queueMicrotask"))
      (eng:data-prop o n (eng:js-get g n)))
    ;; legacy enroll/unenroll/active — no-ops (documented); present so code doesn't crash.
    (eng:install-method o "active" 1 (lambda (this args) (declare (ignore this)) (a args 0)))
    (eng:install-method o "unenroll" 1 (lambda (this args) (declare (ignore this args)) (undef)))
    (eng:install-method o "enroll" 2 (lambda (this args) (declare (ignore this args)) (undef)))
    o))

;;; --- node:timers/promises ---------------------------------------------------

(defun %tp-delayed (g scheduler clearer value opts delay delayp)
  "A Promise resolving to VALUE via the global SCHEDULER (setTimeout/setImmediate).
Honours opts.signal (reject with the abort reason; immediate if already aborted) and
opts.ref (unref the underlying timer when false)."
  (let ((promise-ctor (eng:js-get g "Promise"))
        (sched (eng:js-get g scheduler))
        (clear (eng:js-get g clearer))
        (signal (%tp-signal opts)) (refp (%tp-ref-p opts)))
    (eng:js-construct promise-ctor
      (list (eng:make-native-function "" 2
        (lambda (this a2) (declare (ignore this))
          (let ((resolve (a a2 0)) (reject (a a2 1)))
            (if (%tp-aborted-p signal)
                (eng:js-call reject eng:+undefined+ (list (%tp-reason signal)))
                (let* ((fired nil)
                       (cbfn (eng:make-native-function "" 0
                               (lambda (tt aa) (declare (ignore tt aa))
                                 (setf fired t)
                                 (eng:js-call resolve eng:+undefined+ (list value))
                                 (undef))))
                       (id (eng:js-call sched eng:+undefined+
                                        (if delayp (list cbfn delay) (list cbfn)))))
                  (unless refp (%tp-unref id))
                  (when signal
                    (let ((add (eng:js-get signal "addEventListener")))
                      (when (eng:callable-p add)
                        (eng:js-call add signal
                          (list "abort"
                                (eng:make-native-function "" 0
                                  (lambda (tt aa) (declare (ignore tt aa))
                                    (unless fired
                                      (eng:js-call clear eng:+undefined+ (list id))
                                      (eng:js-call reject eng:+undefined+ (list (%tp-reason signal))))
                                    (undef))))))))))
            (undef))))))))

(defun %tp-interval (g delay value opts)
  "An async iterable yielding VALUE every DELAY ms until opts.signal aborts or return()."
  (let* ((signal (%tp-signal opts))
         (refp (%tp-ref-p opts))
         (promise-ctor (eng:js-get g "Promise"))
         (set-int (eng:js-get g "setInterval"))
         (clear-int (eng:js-get g "clearInterval"))
         (waiters '())          ; FIFO of resolve fns awaiting a tick (oldest at front)
         (buffered 0)           ; ticks that arrived with no waiter
         (stopped nil)
         (timer nil)
         (iter (eng:new-object)))
    (labels ((resolve-tick (res) (eng:js-call res eng:+undefined+ (list (%iter-result value nil))))
             (resolve-done (res) (eng:js-call res eng:+undefined+ (list (%iter-result eng:+undefined+ t))))
             (finish ()
               (unless stopped
                 (setf stopped t)
                 (when timer (eng:js-call clear-int eng:+undefined+ (list timer)))
                 (dolist (res waiters) (resolve-done res))
                 (setf waiters '())))
             (tick ()
               (if waiters
                   (let ((res (car waiters))) (setf waiters (cdr waiters)) (resolve-tick res))
                   (incf buffered)))
             (new-promise (thunk)
               (eng:js-construct promise-ctor
                 (list (eng:make-native-function "" 2
                         (lambda (t2 a2) (declare (ignore t2)) (funcall thunk (a a2 0)) (undef)))))))
      (when (%tp-aborted-p signal) (setf stopped t))
      (unless stopped
        (setf timer (eng:js-call set-int eng:+undefined+
                                 (list (eng:make-native-function "" 0
                                         (lambda (tt aa) (declare (ignore tt aa)) (tick) (undef)))
                                       delay)))
        (unless refp (%tp-unref timer))
        (when signal
          (let ((add (eng:js-get signal "addEventListener")))
            (when (eng:callable-p add)
              (eng:js-call add signal
                (list "abort"
                      (eng:make-native-function "" 0
                        (lambda (tt aa) (declare (ignore tt aa)) (finish) (undef)))))))))
      (eng:install-method iter "next" 0
        (lambda (this args) (declare (ignore this args))
          (new-promise (lambda (resolve)
                         (cond (stopped (resolve-done resolve))
                               ((plusp buffered) (decf buffered) (resolve-tick resolve))
                               (t (setf waiters (append waiters (list resolve)))))))))
      (eng:install-method iter "return" 1
        (lambda (this args) (declare (ignore this args))
          (finish)
          (new-promise (lambda (resolve) (resolve-done resolve)))))
      (eng:create-data-property iter (eng:well-known :async-iterator)
        (eng:make-native-function "[Symbol.asyncIterator]" 0
          (lambda (this args) (declare (ignore args)) this)))
      iter)))

(defun build-node-timers-promises ()
  (let ((g (eng:realm-global eng:*realm*)) (o (eng:new-object)))
    (eng:install-method o "setTimeout" 3
      (lambda (this args) (declare (ignore this))
        (%tp-delayed g "setTimeout" "clearTimeout" (a args 1) (a args 2)
                     (%clamp-tp-delay (a args 0)) t)))
    (eng:install-method o "setImmediate" 2
      (lambda (this args) (declare (ignore this))
        (%tp-delayed g "setImmediate" "clearImmediate" (a args 0) (a args 1) nil nil)))
    (eng:install-method o "setInterval" 3
      (lambda (this args) (declare (ignore this))
        (%tp-interval g (%clamp-tp-delay (a args 0)) (a args 1) (a args 2))))
    o))

(defun %clamp-tp-delay (v)
  "Coerce a timers/promises delay to a non-negative Number (NaN/undefined → 0)."
  (let ((n (->num v)))
    (if (or (eng:js-nan-p n) (eng:js-infinite-p n) (< n 0)) 0d0 n)))

(register-node-builtin "timers" #'build-node-timers)
(register-node-builtin "timers/promises" #'build-node-timers-promises)
