;;;; fake-timers.lisp -- realm-local virtual time for the Jest/Bun timer controls.

(in-package :clun.test-runner)

(defconstant +fake-timer-run-limit+ 100000)

(defstruct (fake-timer-entry (:conc-name fte-))
  state callback (args '()) (deadline 0d0) interval (delay 1d0)
  (seq 0) (id 0d0) (cancelled nil) (refd t) wrapper)

(defstruct (fake-timer-state (:conc-name fts-))
  realm global
  (active nil)
  (now-ms 0d0)
  (wall-base-ms 0d0)
  (entries '())
  (seq 0)
  (originals '())
  (performance-origin 0d0))

(defun %fake-host-wall-ms ()
  (coerce (* 1000 (- (get-universal-time) 2208988800)) 'double-float))

(defun %fake-monotonic-ms ()
  (* 1000d0 (/ (coerce (get-internal-real-time) 'double-float)
               (coerce internal-time-units-per-second 'double-float))))

(defun %fake-next-seq (state)
  (incf (fts-seq state)))

(defun %fake-wall-now (state)
  (+ (fts-wall-base-ms state) (fts-now-ms state)))

(defun %fake-sync-wall-clock (state)
  (setf (eng:realm-clock-now-ms (fts-realm state)) (%fake-wall-now state)))

(defun %fake-require-active (state)
  (unless (fts-active state)
    (eng:throw-type-error "Fake timers are not active. Call useFakeTimers() first.")))

(defun %fake-delay (value)
  (let ((number (eng:to-number value)))
    (cond
      ((or (not (eng:js-finite-p number)) (> number 2147483647d0)) 1d0)
      ((minusp number) 1d0)
      (t (coerce (max 1 (truncate number)) 'double-float)))))

(defun %fake-entry-from-wrapper (value)
  (when (eng:js-object-p value)
    (let ((descriptor (eng:obj-own-desc value "%fake-timer%")))
      (when (and descriptor (fake-timer-entry-p (eng:pd-value descriptor)))
        (eng:pd-value descriptor)))))

(defun %fake-active-entries (state)
  (remove-if #'fte-cancelled (fts-entries state)))

(defun %fake-entry-before-p (left right)
  (or (< (fte-deadline left) (fte-deadline right))
      (and (= (fte-deadline left) (fte-deadline right))
           (< (fte-seq left) (fte-seq right)))))

(defun %fake-next-entry (state)
  (let ((best nil))
    (dolist (entry (fts-entries state) best)
      (when (and (not (fte-cancelled entry))
                 (or (null best) (%fake-entry-before-p entry best)))
        (setf best entry)))))

(defun %fake-latest-deadline (state)
  (let ((entries (%fake-active-entries state)))
    (when entries (reduce #'max entries :key #'fte-deadline))))

(defun %fake-reschedule-entry (entry)
  (let ((state (fte-state entry)))
    (setf (fte-cancelled entry) nil
          (fte-deadline entry) (+ (fts-now-ms state) (fte-delay entry))
          (fte-seq entry) (%fake-next-seq state))
    (pushnew entry (fts-entries state) :test #'eq)
    entry))

(defun %fake-timer-wrapper (entry)
  (let ((wrapper (eng:new-object)))
    (setf (fte-wrapper entry) wrapper)
    (eng:hidden-prop wrapper "%fake-timer%" entry)
    (eng:js-set wrapper (eng:well-known :to-primitive)
                (%fn "[Symbol.toPrimitive]" 1
                  (lambda (this args)
                    (declare (ignore this args))
                    (fte-id entry)))
                t)
    (eng:install-method wrapper "ref" 0
      (lambda (this args)
        (declare (ignore args))
        (setf (fte-refd entry) t)
        this))
    (eng:install-method wrapper "unref" 0
      (lambda (this args)
        (declare (ignore args))
        (setf (fte-refd entry) nil)
        this))
    (eng:install-method wrapper "hasRef" 0
      (lambda (this args)
        (declare (ignore this args))
        (eng:js-boolean (fte-refd entry))))
    (eng:install-method wrapper "close" 0
      (lambda (this args)
        (declare (ignore args))
        (setf (fte-cancelled entry) t)
        this))
    (eng:install-method wrapper "refresh" 0
      (lambda (this args)
        (declare (ignore args))
        (when (fts-active (fte-state entry))
          (%fake-reschedule-entry entry))
        this))
    wrapper))

(defun %fake-schedule (state callback delay args &optional interval)
  (unless (eng:callable-p callback)
    (eng:throw-type-error
     (if interval "setInterval expects a function" "setTimeout expects a function")))
  (let* ((delay-ms (%fake-delay delay))
         (sequence (%fake-next-seq state))
         (entry (make-fake-timer-entry
                 :state state :callback callback :args args
                 :deadline (+ (fts-now-ms state) delay-ms)
                 :interval (and interval delay-ms) :delay delay-ms
                 :seq sequence :id (coerce sequence 'double-float))))
    (push entry (fts-entries state))
    (%fake-timer-wrapper entry)))

(defun %fake-clear (value)
  (let ((entry (%fake-entry-from-wrapper value)))
    (when entry (setf (fte-cancelled entry) t)))
  eng:+undefined+)

(defun %fake-fire (state entry)
  (setf (fts-now-ms state) (fte-deadline entry))
  (%fake-sync-wall-clock state)
  (if (fte-interval entry)
      (setf (fte-deadline entry) (+ (fte-deadline entry) (fte-interval entry))
            (fte-seq entry) (%fake-next-seq state))
      (setf (fte-cancelled entry) t))
  (eng:js-call (fte-callback entry) eng:+undefined+ (fte-args entry)))

(defun %fake-run-limit-error ()
  (eng:throw-type-error
   (format nil "Aborting after running ~d timers, assuming an infinite loop."
           +fake-timer-run-limit+)))

(defun %fake-execute-until (state target)
  (loop with count = 0
        for entry = (%fake-next-entry state)
        while (and (fts-active state) entry (<= (fte-deadline entry) target))
        do (when (>= count +fake-timer-run-limit+) (%fake-run-limit-error))
           (incf count)
           (%fake-fire state entry))
  (when (fts-active state)
    (setf (fts-now-ms state) target)
    (%fake-sync-wall-clock state)))

(defun %fake-execute-next (state)
  (let ((entry (%fake-next-entry state)))
    (when entry (%fake-fire state entry))))

(defun %fake-execute-all (state)
  (loop with count = 0
        for entry = (%fake-next-entry state)
        while (and (fts-active state) entry)
        do (when (>= count +fake-timer-run-limit+) (%fake-run-limit-error))
           (incf count)
           (%fake-fire state entry)))

(defun %fake-cancel-all (state)
  (dolist (entry (fts-entries state))
    (setf (fte-cancelled entry) t))
  (setf (fts-entries state) '())
  state)

(defun %fake-date-value (value operation)
  (cond
    ((eng:js-number-p value) (eng:to-number value))
    ((and (eng:js-object-p value) (eq (eng:js-object-class value) :date))
     (eng:to-number (eng:js-call (eng:js-get value "getTime") value '())))
    (t (eng:throw-type-error
        (format nil "~a expects a number or Date" operation)))))

(defun %fake-options-now (state args)
  (let ((options (eng:arg args 0)))
    (cond
      ((eng:js-undefined-p options)
       (or (eng:realm-clock-now-ms (fts-realm state)) (%fake-host-wall-ms)))
      ((not (eng:js-object-p options))
       (eng:throw-type-error "useFakeTimers() expects an options object"))
      ((eng:has-property options "now")
       (%fake-date-value (eng:js-get options "now") "'now'"))
      (t (%fake-host-wall-ms)))))

(defun %fake-install-global-functions (state)
  (let* ((global (fts-global state))
         (set-timeout
           (%fn "setTimeout" 2
             (lambda (this args)
               (declare (ignore this))
               (%fake-schedule state (eng:arg args 0) (eng:arg args 1) (cddr args)))))
         (set-interval
           (%fn "setInterval" 2
             (lambda (this args)
               (declare (ignore this))
               (%fake-schedule state (eng:arg args 0) (eng:arg args 1) (cddr args) t))))
         (clear-timer
           (%fn "clearTimeout" 1
             (lambda (this args)
               (declare (ignore this))
               (%fake-clear (eng:arg args 0))))))
    (eng:data-prop set-timeout "clock" eng:+true+)
    (eng:hidden-prop global "setTimeout" set-timeout)
    (eng:hidden-prop global "setInterval" set-interval)
    (eng:hidden-prop global "clearTimeout" clear-timer)
    (eng:hidden-prop global "clearInterval" clear-timer)))

(defun %fake-restore-global-functions (state)
  (dolist (entry (fts-originals state))
    (eng:hidden-prop (fts-global state) (car entry) (cdr entry))))

(defun %fake-use-fake (state this args)
  (let ((wall-now (%fake-options-now state args)))
    (%fake-cancel-all state)
    (setf (fts-active state) t
          (fts-now-ms state) 0d0
          (fts-wall-base-ms state) wall-now)
    (%fake-sync-wall-clock state)
    (%fake-install-global-functions state)
    this))

(defun %fake-use-real (state this)
  (%fake-cancel-all state)
  (setf (fts-active state) nil
        (eng:realm-clock-now-ms (fts-realm state)) nil)
  (%fake-restore-global-functions state)
  this)

(defun %fake-set-system-time (state args)
  (let ((value (eng:arg args 0)))
    (setf (fts-wall-base-ms state)
          (- (if (eng:js-undefined-p value)
                 (%fake-host-wall-ms)
                 (%fake-date-value value "setSystemTime"))
             (fts-now-ms state)))
    (%fake-sync-wall-clock state)
    eng:+undefined+))

(defun %fake-performance-object (state)
  (let* ((global (fts-global state))
         (existing (eng:js-get global "performance"))
         (performance (if (eng:js-object-p existing) existing (eng:new-object))))
    (eng:install-method performance "now" 0
      (lambda (this args)
        (declare (ignore this args))
        (if (fts-active state)
            (fts-now-ms state)
            (- (%fake-monotonic-ms) (fts-performance-origin state)))))
    (eng:hidden-prop global "performance" performance)
    performance))

(defun install-fake-timers (realm ctx jest)
  (let* ((global (eng:realm-global realm))
         (state (make-fake-timer-state
                 :realm realm :global global
                 :performance-origin (%fake-monotonic-ms)
                 :originals
                 (mapcar (lambda (name) (cons name (eng:js-get global name)))
                         '("setTimeout" "setInterval" "clearTimeout" "clearInterval")))))
    (setf (ctx-fake-timers ctx) state)
    (%fake-performance-object state)
    (eng:install-method jest "useFakeTimers" 0
      (lambda (this args) (%fake-use-fake state this args)))
    (eng:install-method jest "useRealTimers" 0
      (lambda (this args) (declare (ignore args)) (%fake-use-real state this)))
    (eng:install-method jest "advanceTimersToNextTimer" 0
      (lambda (this args)
        (declare (ignore args))
        (%fake-require-active state)
        (%fake-execute-next state)
        this))
    (eng:install-method jest "advanceTimersByTime" 1
      (lambda (this args)
        (let ((milliseconds (eng:arg args 0)))
          (%fake-require-active state)
          (unless (eng:js-number-p milliseconds)
            (eng:throw-type-error
             "advanceTimersByTime() expects a number of milliseconds"))
          (let ((number (eng:to-number milliseconds)))
            (when (or (not (eng:js-finite-p number)) (< number 0d0) (> number 4294967295d0))
              (eng:throw-range-error
               "advanceTimersByTime() ms is out of range. It must be >= 0 and <= 4294967295"))
            (%fake-execute-until state (+ (fts-now-ms state)
                                          (if (zerop number) 1d0 number)))))
        this))
    (eng:install-method jest "runOnlyPendingTimers" 0
      (lambda (this args)
        (declare (ignore args))
        (%fake-require-active state)
        (let ((target (%fake-latest-deadline state)))
          (when target (%fake-execute-until state target)))
        this))
    (eng:install-method jest "runAllTimers" 0
      (lambda (this args)
        (declare (ignore args))
        (%fake-require-active state)
        (%fake-execute-all state)
        this))
    (eng:install-method jest "getTimerCount" 0
      (lambda (this args)
        (declare (ignore this args))
        (%fake-require-active state)
        (coerce (length (%fake-active-entries state)) 'double-float)))
    (eng:install-method jest "clearAllTimers" 0
      (lambda (this args)
        (declare (ignore args))
        (%fake-require-active state)
        (%fake-cancel-all state)
        this))
    (eng:install-method jest "isFakeTimers" 0
      (lambda (this args)
        (declare (ignore this args))
        (eng:js-boolean (fts-active state))))
    (eng:install-method jest "setSystemTime" 0
      (lambda (this args)
        (declare (ignore this))
        (%fake-set-system-time state args)))
    (eng:install-method jest "now" 0
      (lambda (this args)
        (declare (ignore this args))
        (if (eng:realm-clock-now-ms realm)
            (eng:realm-clock-now-ms realm)
            (%fake-host-wall-ms))))
    state))

(defun restore-fake-timers (ctx)
  (let ((state (ctx-fake-timers ctx)))
    (when state
      (%fake-use-real state eng:+undefined+)
      (setf (ctx-fake-timers ctx) nil)))
  ctx)
