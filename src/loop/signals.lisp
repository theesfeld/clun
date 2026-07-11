;;;; signals.lisp — POSIX signal delivery, enqueue-only (PLAN.md Phase 05, §3.2/§6
;;;; iron rule). The OS handler runs in an arbitrary thread with interrupts
;;;; disabled (Appendix C.7 for run-program's analogue): it may ONLY bump an
;;;; atomic counter and wake the self-pipe. Listeners run on the loop thread.

(in-package :clun.loop)

(defconstant +max-signal+ 65)           ; NSIG on Linux is 64; index by signo.

(defstruct (signal-state (:constructor make-signal-state))
  ;; counts: bumped by the OS handler (atomic). seen: loop-thread high-water mark.
  (counts (make-array +max-signal+ :element-type 'sb-ext:word :initial-element 0))
  (seen (make-array +max-signal+ :element-type 'sb-ext:word :initial-element 0))
  (listeners (make-array +max-signal+ :initial-element nil))
  (installed (make-array +max-signal+ :initial-element nil)))

;; sb-sys:enable-interrupt is process-global, so signal ownership is too. Clun is
;; single-loop (§3.2); a second LIVE loop claiming a signo already owned by another
;; is a loud error, not a silent clobber. destroy-event-loop releases ownership.
(sb-ext:defglobal *signal-owners* (make-array +max-signal+ :initial-element nil))

(defun install-signal-handler (loop signo listener)
  "Run LISTENER (a thunk) on the loop thread each time SIGNO is delivered. The OS
handler does nothing but atomic-incf the counter + wake the self-pipe (§6)."
  (check-type signo (integer 1 (#.+max-signal+)))
  (let ((owner (aref *signal-owners* signo)))
    (when (and owner (not (eq owner loop)))
      (error "signal ~a is already handled by another event loop~
              ~%note: Clun runs a single event loop (PLAN.md §3.2)" signo)))
  (let* ((st (el-signal-state loop))
         (sp (el-self-pipe loop))
         (counts (signal-state-counts st)))
    (setf (aref (signal-state-listeners st) signo) listener)
    (unless (aref (signal-state-installed st) signo)
      (setf (aref (signal-state-installed st) signo) t
            (aref *signal-owners* signo) loop)
      (sb-sys:enable-interrupt
       signo
       (lambda (sig info context)
         (declare (ignore sig info context))
         (sb-ext:atomic-incf (aref counts signo))
         (clun.sys:self-pipe-wake sp))))
    listener))

(defun remove-signal-handler (loop signo)
  (let ((st (el-signal-state loop)))
    (setf (aref (signal-state-listeners st) signo) nil)
    (when (aref (signal-state-installed st) signo)
      (setf (aref (signal-state-installed st) signo) nil)
      (when (eq (aref *signal-owners* signo) loop)
        (setf (aref *signal-owners* signo) nil))
      (sb-sys:enable-interrupt signo :default)))
  (values))

(defun pending-signals-p (loop)
  "True if an installed signal has been delivered but not yet drained. Part of the
loop liveness predicate so a signal accepted at shutdown is dispatched, not dropped."
  (let* ((st (el-signal-state loop))
         (counts (signal-state-counts st))
         (seen (signal-state-seen st)))
    (dotimes (s +max-signal+ nil)
      (when (> (aref counts s) (aref seen s)) (return t)))))

(defun drain-signals (loop)
  "Loop-thread: for each signo whose count advanced past the high-water mark, run
its listener once at a dispatch point (coalescing multiple deliveries per turn)."
  (let* ((st (el-signal-state loop))
         (counts (signal-state-counts st))
         (seen (signal-state-seen st))
         (listeners (signal-state-listeners st)))
    (dotimes (s +max-signal+)
      (let ((c (aref counts s)))
        (when (> c (aref seen s))
          (setf (aref seen s) c)
          (let ((listener (aref listeners s)))
            (when listener (run-at-dispatch loop listener))))))))
