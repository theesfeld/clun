;;;; event-loop.lisp — the driver (PLAN.md Phase 05, §3.2). Wires the self-pipe
;;;; into the reactor, owns the per-iteration order (poll → completions → signals →
;;;; timers → tasks, each callback at a dispatch point), and the run/stop lifecycle.

(in-package :clun.loop)

(defparameter *default-worker-count* 4)
(defconstant +loop-timeout-cap-ms+ 1000
  "Poll never blocks longer than this, so a dropped wake can't hang the loop. The
self-pipe makes real signal/worker latency ~immediate, not cap-bound (Appendix C.5).")

(defun make-event-loop (&key (workers *default-worker-count*))
  (probe-reactor)
  (%make-event-loop
   :self-pipe (clun.sys:make-self-pipe)
   :mailbox (sb-concurrency:make-mailbox :name "clun-loop")
   :timers (make-timer-heap)
   :signal-state (make-signal-state)
   :workers (make-worker-pool workers)))

(defun destroy-event-loop (loop)
  (stop-worker-pool (el-workers loop))
  (dolist (pair (el-fd-handlers loop))
    (ignore-errors (sb-sys:remove-fd-handler (cdr pair))))
  (setf (el-fd-handlers loop) nil)
  ;; Uninstall OS signal handlers BEFORE closing the self-pipe: a surviving handler
  ;; closes over this pipe and would write the wake byte to the closed (and possibly
  ;; OS-recycled) fd on the next delivery — cross-object corruption / EBADF (§6).
  (let ((st (el-signal-state loop)))
    (dotimes (s +max-signal+)
      (when (aref (signal-state-installed st) s)
        (remove-signal-handler loop s))))
  (clun.sys:self-pipe-close (el-self-pipe loop))
  (values))

(defun process-completions (loop)
  "Run every cross-thread post (worker completions, loop-post) queued so far."
  (dolist (thunk (sb-concurrency:receive-pending-messages (el-mailbox loop)))
    (run-at-dispatch loop thunk)))

(defun process-tasks (loop)
  "Run the macrotasks queued at loop entry. A snapshot count means a task scheduled
during this drain waits for the next iteration (after a poll + microtask drain)."
  (loop repeat (fifo-count (el-tasks loop))
        until (fifo-empty-p (el-tasks loop))
        do (run-at-dispatch loop (fifo-pop (el-tasks loop)))))

(defun loop-timeout (loop)
  "Poll timeout in ms: 0 if there is immediate work or a pending post, else time to
the next timer (capped), else the cap."
  (cond ((immediate-work-p loop) 0)
        ((plusp (sb-concurrency:mailbox-count (el-mailbox loop))) 0)
        (t (let ((d (next-timer-delay loop)))
             (if d (min d +loop-timeout-cap-ms+) +loop-timeout-cap-ms+)))))

(defun run-loop (loop)
  "Run until no handle keeps the loop alive and every queue is empty, or LOOP-STOP
is requested. Re-entrant-safe only in the single JS-thread sense (§3.2).

The self-pipe handler is registered HERE, on the running thread: SBCL dispatches
serve-event fd handlers only for registrations made by the thread that calls
serve-event, so make-event-loop (possibly a different thread) must not register it."
  (setf (el-running loop) t (el-stop-requested loop) nil
        (el-thread loop) sb-thread:*current-thread*)
  (let* ((sp (el-self-pipe loop))
         (wake-handler (sb-sys:add-fd-handler
                        (clun.sys:self-pipe-read-fd sp) :input
                        (lambda (fd) (declare (ignore fd)) (clun.sys:self-pipe-drain sp)))))
    (unwind-protect
         (progn
           (drain-microtasks loop)              ; honor pre-run work
           (loop
             (when (el-stop-requested loop) (return))
             (unless (loop-alive-p loop) (return))
             (reactor-poll loop (loop-timeout loop))
             (drain-microtasks loop)              ; reactor fd handlers enqueue jobs (e.g. an
                                                  ; async HTTP handler's .then) — drain them here,
                                                  ; making "after the reactor" a dispatch point (P17)
             (process-completions loop)
             (drain-signals loop)
             (expire-due-timers loop)
             (process-tasks loop)))
      (sb-sys:remove-fd-handler wake-handler)
      (setf (el-running loop) nil (el-thread loop) nil)))
  (values))

(defun loop-stop (loop)
  "Request a graceful stop and wake the loop. Safe from any thread."
  (setf (el-stop-requested loop) t)
  (clun.sys:self-pipe-wake (el-self-pipe loop))
  (values))
