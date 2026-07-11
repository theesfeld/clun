;;;; workers.lisp — the blocking-op worker pool (PLAN.md Phase 05, §3.2). A fixed
;;;; set of sb-threads drain a job mailbox; a job runs a blocking fn and posts its
;;;; result back to the loop thread (loop-post = mailbox + self-pipe wake). An
;;;; in-flight ref'd handle keeps the loop alive until the completion runs.

(in-package :clun.loop)

(defstruct (worker-pool (:constructor %make-worker-pool))
  threads
  job-mailbox)

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

(defun worker-submit (loop fn on-done)
  "Run blocking FN on a worker thread; ON-DONE is called on the loop thread with
(:ok value) or (:err condition). Returns the in-flight handle (keeps loop alive)."
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
