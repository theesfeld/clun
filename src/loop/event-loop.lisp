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
  (when (begin-loop-destruction loop)
    (unwind-protect
         (progn
           (stop-worker-pool (el-workers loop))
           (clear-loop-timers loop)
           ;; Stop asynchronous signal writers before any descriptor can be recycled.
           (let ((st (el-signal-state loop)))
             (dotimes (s +max-signal+)
               (when (aref (signal-state-installed st) s)
                 (ignore-errors (remove-signal-handler loop s)))))
           ;; No user fd callback may remain dispatchable during owner cleanup.
           (close-loop-reactor-handlers loop)
           ;; Closing the SBCL socket object cancels its finalizer. Dropping only the
           ;; handler could let that finalizer close an OS-recycled fd later.
           (close-loop-resources loop)
           ;; LOOP-POST is mutex-free because status hooks call it in interrupt
           ;; context. Wait for any producer that entered before DESTROYING was set.
           (loop while (plusp (el-posters loop)) do (sb-thread:thread-yield))
           ;; Posts accepted before destruction cannot run against closed resources.
           (sb-concurrency:receive-pending-messages (el-mailbox loop))
           (ignore-errors (clun.sys:self-pipe-close (el-self-pipe loop))))
      (finish-loop-destruction loop)))
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
  (with-loop-lifecycle-lock (loop)
    (when (or (el-destroying loop) (el-destroyed loop))
      (error "cannot run a destroyed event loop"))
    (when (el-running loop) (error "event loop is already running"))
    (let ((owner (el-reactor-thread loop)))
      (when (and owner
                 (not (eq owner sb-thread:*current-thread*))
                 (or (sb-thread:thread-alive-p owner) (el-fd-handlers loop)))
        (error "event loop must run on the thread that owns its fd handlers"))
      (setf (el-reactor-thread loop) sb-thread:*current-thread*))
    (setf (el-running loop) t (el-stop-requested loop) nil
          (el-thread loop) sb-thread:*current-thread*))
  (let* ((sp (el-self-pipe loop))
         (wake-handler nil))
    (unwind-protect
         (progn
           (setf wake-handler
                 (sb-sys:add-fd-handler
                  (clun.sys:self-pipe-read-fd sp) :input
                  (lambda (fd) (declare (ignore fd)) (clun.sys:self-pipe-drain sp))))
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
      (when wake-handler (ignore-errors (sb-sys:remove-fd-handler wake-handler)))
      (with-loop-lifecycle-lock (loop)
        (setf (el-running loop) nil (el-thread loop) nil))))
  (values))

(defun loop-stop (loop)
  "Request a graceful stop and wake the loop. Safe from any thread."
  (with-loop-lifecycle-lock (loop)
    (setf (el-stop-requested loop) t)
    (unless (or (el-destroying loop) (el-destroyed loop))
      (clun.sys:self-pipe-wake (el-self-pipe loop))))
  (values))
