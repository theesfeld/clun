;;;; workers.lisp — the blocking-op worker pool (PLAN.md Phase 05, §3.2). A fixed
;;;; set of sb-threads drain a job mailbox; a job runs a blocking fn and posts its
;;;; result back to the loop thread (loop-post = mailbox + self-pipe wake). An
;;;; in-flight ref'd handle keeps the loop alive until the completion runs.

(in-package :clun.loop)

(defstruct (worker-pool (:constructor %make-worker-pool))
  threads
  job-mailbox
  (lock (sb-thread:make-mutex :name "clun-worker-pool")))

(defparameter *lazy-worker-count* 4
  "Threads spawned on first blocking submit when the loop was created with :workers 0.")

(defun %worker-loop (mbox)
  (loop for job = (sb-concurrency:receive-message mbox)
        until (eq job :shutdown)
        do (funcall job)))

(defun make-worker-pool (n)
  (let* ((mbox (sb-concurrency:make-mailbox :name "clun-workers"))
         (pool (%make-worker-pool :job-mailbox mbox)))
    (setf (worker-pool-threads pool)
          (loop repeat n
                collect (sb-thread:make-thread (lambda () (%worker-loop mbox))
                                               :name "clun-worker")))
    pool))

(defun stop-worker-pool (pool)
  (dolist (th (worker-pool-threads pool))
    (declare (ignore th))
    (sb-concurrency:send-message (worker-pool-job-mailbox pool) :shutdown))
  (dolist (th (worker-pool-threads pool))
    (ignore-errors (sb-thread:join-thread th)))
  (setf (worker-pool-threads pool) nil))

(defun ensure-workers (pool)
  "Lazily spawn the worker threads if POOL has none. The realm loop is created with
:workers 0 (async coroutines use their own threads); the pool starts on the first
blocking submit (I/O phases — TLS handshake/IO, blocking DNS). Idempotent + lock-guarded
so concurrent submits (Promise.all of fetches) spawn exactly one set."
  (unless (worker-pool-threads pool)
    (sb-thread:with-mutex ((worker-pool-lock pool))
      (unless (worker-pool-threads pool)
        (let ((mbox (worker-pool-job-mailbox pool)))
          (setf (worker-pool-threads pool)
                (loop repeat *lazy-worker-count*
                      collect (sb-thread:make-thread (lambda () (%worker-loop mbox))
                                                     :name "clun-worker")))))))
  pool)

(defun worker-submit (loop fn on-done)
  "Run blocking FN on a worker thread; ON-DONE is called on the loop thread with
(:ok value) or (:err condition). Returns the in-flight handle (keeps loop alive)."
  (ensure-workers (el-workers loop))
  (let ((handle (make-handle loop :kind :worker)))
    (handle-activate handle)
    (sb-concurrency:send-message
     (worker-pool-job-mailbox (el-workers loop))
     (lambda ()
       (let ((result (handler-case (list :ok (funcall fn))
                       (error (c) (list :err c)))))
         (loop-post loop
                    (lambda ()
                      (handle-deactivate handle)
                      (funcall on-done result))))))
    handle))
