;;;; workers.lisp — the blocking-op worker pool (PLAN.md Phase 05, §3.2). A fixed
;;;; set of sb-threads drain a job mailbox; a job runs a blocking fn and posts its
;;;; result back to the loop thread (loop-post = mailbox + self-pipe wake). An
;;;; in-flight ref'd handle keeps the loop alive until the completion runs.

(in-package :clun.loop)

(defstruct (worker-pool (:constructor %make-worker-pool))
  threads
  job-mailbox
  (lock (sb-thread:make-mutex :name "clun-worker-pool")))

(defstruct (worker-cancel-token (:constructor %make-worker-cancel-token))
  (cancelled-p nil :type boolean))

(defstruct (worker-job (:constructor %make-worker-job))
  loop
  token
  handle
  resource
  on-done
  (state :queued)
  (lock (sb-thread:make-mutex :name "clun-worker-job")))

(defun worker-cancelled-p (token)
  (worker-cancel-token-cancelled-p token))

(defun %terminal-worker-state-p (state)
  (member state '(:completed :failed :cancelled)))

(defun %release-worker-job (job result terminal-state)
  "Claim and publish JOB's terminal transition exactly once."
  (let ((resource nil) (handle nil) (callback nil) (claimed nil))
    (sb-thread:with-mutex ((worker-job-lock job))
      (unless (%terminal-worker-state-p (worker-job-state job))
        (setf claimed t
              (worker-job-state job) terminal-state
              resource (worker-job-resource job)
              handle (worker-job-handle job)
              callback (worker-job-on-done job)
              (worker-job-resource job) nil
              (worker-job-handle job) nil)))
    (when claimed
      (unregister-loop-resource resource)
      (when handle (handle-deactivate handle))
      (when callback (funcall callback result)))
    claimed))

(defun cancel-worker-job (job)
  "Idempotently cancel JOB. Queued jobs settle immediately; running jobs stop
cooperatively when their function observes WORKER-CANCELLED-P."
  (let ((queued nil))
    (sb-thread:with-mutex ((worker-job-lock job))
      (unless (%terminal-worker-state-p (worker-job-state job))
        (setf (worker-cancel-token-cancelled-p (worker-job-token job)) t)
        (case (worker-job-state job)
          (:queued (setf queued t (worker-job-state job) :cancel-requested))
          (:running (setf (worker-job-state job) :cancel-requested)))))
    (when queued
      (%release-worker-job job (list :cancelled nil) :cancelled))
    job))

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
  (let ((handle (make-handle loop :kind :worker)) (resource nil))
    (handler-case
        (with-loop-lifecycle-lock (loop)
          ;; Keep worker creation, handle/resource activation, and queue admission in
          ;; the same lifecycle critical section. Destruction can then either reject
          ;; the submit without side effects or observe the complete in-flight job.
          (%ensure-loop-open-locked loop "submit worker work")
          (ensure-workers (el-workers loop))
          (setf resource
                (%register-loop-handle-resource-locked
                 loop handle (lambda () (handle-deactivate handle)) handle))
          (sb-concurrency:send-message
           (worker-pool-job-mailbox (el-workers loop))
           (lambda ()
             (let ((result (handler-case (list :ok (funcall fn))
                             (error (c) (list :err c)))))
               (unless
                   (loop-post loop
                              (lambda ()
                                (unregister-loop-resource resource)
                                (handle-deactivate handle)
                                (funcall on-done result)))
                 ;; Destruction rejected the completion post. Release accounting on
                 ;; this producer thread; DESTROY waits for the worker before teardown.
                 (unregister-loop-resource resource)
                 (handle-deactivate handle))))))
      (error (e)
        (unregister-loop-resource resource)
        (handle-deactivate handle)
        (error e)))
    handle))

(defun worker-submit-cancellable (loop fn on-done)
  "Run blocking FN on the fixed worker pool with a cooperative cancellation token.
FN receives the token. ON-DONE receives (:OK value), (:ERR condition), or
(:CANCELLED nil) on the loop thread. Returns a WORKER-JOB."
  (let* ((handle (make-handle loop :kind :worker))
         (token (%make-worker-cancel-token))
         (job (%make-worker-job :loop loop :token token :handle handle
                                :on-done on-done))
         (resource nil))
    (handler-case
        (with-loop-lifecycle-lock (loop)
          (%ensure-loop-open-locked loop "submit cancellable worker work")
          (ensure-workers (el-workers loop))
          (setf resource
                (%register-loop-handle-resource-locked
                 loop job (lambda () (cancel-worker-job job)) handle)
                (worker-job-resource job) resource)
          (sb-concurrency:send-message
           (worker-pool-job-mailbox (el-workers loop))
           (lambda ()
             (let ((run nil))
               (sb-thread:with-mutex ((worker-job-lock job))
                 (when (eq (worker-job-state job) :queued)
                   (setf (worker-job-state job) :running run t)))
               (when run
                 (let ((result
                         (handler-case (list :ok (funcall fn token))
                           (error (condition) (list :err condition)))))
                   (unless
                       (loop-post
                        loop
                        (lambda ()
                          (if (worker-cancelled-p token)
                              (%release-worker-job job (list :cancelled nil) :cancelled)
                              (%release-worker-job
                               job result (if (eq (first result) :ok)
                                              :completed :failed)))))
                     ;; Loop teardown rejected the post. Resource release may
                     ;; safely occur here; no JS callback is invoked off-thread.
                     (sb-thread:with-mutex ((worker-job-lock job))
                       (setf (worker-job-on-done job) nil))
                     (%release-worker-job job result :cancelled))))))))
      (error (condition)
        (unregister-loop-resource resource)
        (handle-deactivate handle)
        (error condition)))
    job))
