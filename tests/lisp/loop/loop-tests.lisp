;;;; loop-tests.lisp — Phase 05 event-loop gate. Timer ordering, cross-thread wake
;;;; latency, refcount liveness, SIGINT→loop event, microtask/nextTick drain order,
;;;; worker completions. Every loop is destroyed (joins workers, closes the pipe).

(in-package :clun-test)

(defmacro with-loop ((var &rest make-args) &body body)
  `(let ((,var (lp:make-event-loop ,@make-args)))
     (unwind-protect (progn ,@body) (lp:destroy-event-loop ,var))))

;;; --- timers ------------------------------------------------------------------

(define-test loop/timer-ordering-by-deadline
  (with-loop (loop)
    (let ((log '()))
      (lp:set-timer loop 30 (lambda () (push :c log)))
      (lp:set-timer loop 10 (lambda () (push :a log)))
      (lp:set-timer loop 20 (lambda () (push :b log)))
      (lp:run-loop loop)
      (is equal '(:a :b :c) (nreverse log)))))

(define-test loop/timer-fifo-ties
  (with-loop (loop)
    (let ((log '()))
      (lp:set-timer loop 0 (lambda () (push 1 log)))
      (lp:set-timer loop 0 (lambda () (push 2 log)))
      (lp:set-timer loop 0 (lambda () (push 3 log)))
      (lp:run-loop loop)
      (is equal '(1 2 3) (nreverse log)))))

(define-test loop/timer-repeat-then-clear
  (with-loop (loop)
    (let ((n 0) (timer nil))
      (setf timer (lp:set-timer loop 3
                                (lambda () (incf n) (when (>= n 3) (lp:clear-timer timer)))
                                :repeat 3))
      (lp:run-loop loop)
      (is = 3 n))))

(define-test loop/timer-clear-before-fire
  (with-loop (loop)
    (let ((fired nil))
      (let ((victim (lp:set-timer loop 20 (lambda () (setf fired t)))))
        (lp:set-timer loop 5 (lambda () (lp:clear-timer victim))))
      (lp:run-loop loop)
      (is eq nil fired))))

;;; --- refcount liveness -------------------------------------------------------

(define-test loop/unrefd-timer-does-not-keep-alive
  (with-loop (loop)
    (let ((fired nil))
      (lp:set-timer loop 50 (lambda () (setf fired t)) :refd nil)
      (lp:run-loop loop)                 ; ref-count 0 -> returns at once
      (is eq nil fired))))

(define-test loop/refd-timer-keeps-alive-then-exits
  (with-loop (loop)
    (let ((fired nil))
      (lp:set-timer loop 10 (lambda () (setf fired t)))
      (lp:run-loop loop)
      (is eq t fired))))

(define-test loop/handle-ref-unref-counting
  (with-loop (loop)
    (let ((h (lp:make-handle loop)))
      (is = 0 (lp:el-ref-count loop))
      (lp:handle-activate h)
      (is = 1 (lp:el-ref-count loop))
      (lp:handle-unref h)
      (is = 0 (lp:el-ref-count loop))
      (lp:handle-ref h)
      (is = 1 (lp:el-ref-count loop))
      (lp:handle-deactivate h)
      (is = 0 (lp:el-ref-count loop)))))

;;; --- cross-thread wake (< 5 ms) ----------------------------------------------

(define-test loop/cross-thread-wake-latency
  (with-loop (loop)
    (let ((keepalive (lp:set-timer loop 2000 (lambda ())))   ; watchdog: bounded, never hangs
          (latency nil) (t0 nil))
      (let ((th (sb-thread:make-thread (lambda () (lp:run-loop loop)) :name "loop-under-test")))
        (sleep 0.05)                     ; let the loop enter poll
        (setf t0 (lp:now-ms))
        (lp:loop-post loop (lambda ()
                             (setf latency (- (lp:now-ms) t0))
                             (lp:clear-timer keepalive)
                             (lp:loop-stop loop)))
        (sb-thread:join-thread th))
      (true (and latency (< latency 5))))))

;;; --- SIGINT -> enqueued loop event -------------------------------------------

(define-test loop/sigint-becomes-loop-event
  (with-loop (loop)
    (let ((got nil)
          (keepalive (lp:set-timer loop 2000 (lambda ()))))  ; watchdog
      (lp:install-signal-handler loop sb-posix:sigint
                                 (lambda () (setf got t)
                                   (lp:clear-timer keepalive) (lp:loop-stop loop)))
      (unwind-protect
           (let ((th (sb-thread:make-thread (lambda () (lp:run-loop loop)) :name "loop-sigint")))
             (sleep 0.05)
             (sb-posix:kill (sb-posix:getpid) sb-posix:sigint)
             (sb-thread:join-thread th))
        (lp:remove-signal-handler loop sb-posix:sigint))
      (is eq t got))))

;;; --- microtask / nextTick drain ordering -------------------------------------

(define-test loop/microtask-drain-ordering
  (with-loop (loop)
    (let ((log '()))
      (lp:enqueue-task
       loop
       (lambda ()
         (push :macro1 log)
         (lp:enqueue-next-tick loop (lambda () (push :tick log)))
         (lp:enqueue-microtask loop (lambda () (push :micro log)))
         (lp:enqueue-task loop (lambda () (push :macro2 log)))))
      (lp:run-loop loop)
      ;; nextTick drains before the microtask; the newly-queued macrotask waits a turn.
      (is equal '(:macro1 :tick :micro :macro2) (nreverse log)))))

(define-test loop/nexttick-priority-between-microtasks
  (with-loop (loop)
    (let ((log '()))
      (lp:enqueue-microtask loop (lambda () (push :m1 log)
                                   (lp:enqueue-next-tick loop (lambda () (push :t1 log)))))
      (lp:enqueue-microtask loop (lambda () (push :m2 log)))
      (lp:run-loop loop)
      ;; the nextTick queued during m1 runs before m2.
      (is equal '(:m1 :t1 :m2) (nreverse log)))))

;;; --- mailbox / signal liveness (Phase 05 review-panel regressions) -----------

(define-test loop/external-post-not-dropped
  ;; a cross-thread loop-post with no other work must run, not be stranded.
  (with-loop (loop)
    (let ((ran :never))
      (lp:loop-post loop (lambda () (setf ran :ok)))
      (lp:run-loop loop)
      (is eq :ok ran))))

(define-test loop/post-from-last-callback-not-dropped
  ;; a loop-post issued by the last timer callback (ref-count already 0) must run.
  (with-loop (loop)
    (let ((ran :never))
      (lp:set-timer loop 5 (lambda () (lp:loop-post loop (lambda () (setf ran :ok)))))
      (lp:run-loop loop)
      (is eq :ok ran))))

(define-test loop/worker-followup-post-not-dropped
  ;; a worker completion whose on-done posts more work must not drop the follow-up.
  (with-loop (loop)
    (let ((stage :none))
      (lp:worker-submit loop (lambda () 7)
                        (lambda (r) (declare (ignore r))
                          (lp:loop-post loop (lambda () (setf stage :followup)))))
      (lp:run-loop loop)
      (is eq :followup stage))))

(define-test loop/signal-pending-at-shutdown-not-dropped
  ;; a signal delivered just as the last ref'd handle deactivates must dispatch.
  (with-loop (loop)
    (let ((got :never))
      (lp:install-signal-handler loop sb-posix:sigint (lambda () (setf got :sigint)))
      (unwind-protect
           (progn
             (lp:set-timer loop 5 (lambda ()
                                    (sb-posix:kill (sb-posix:getpid) sb-posix:sigint)
                                    (sleep 0.02)))   ; let async delivery bump the counter
             (lp:run-loop loop))
        (lp:remove-signal-handler loop sb-posix:sigint))
      (is eq :sigint got))))

;;; --- signal ownership lifecycle ----------------------------------------------

(define-test loop/signal-owner-released-on-destroy
  ;; destroy must release process-global signal ownership so a later loop can claim it.
  (let ((a (lp:make-event-loop)))
    (lp:install-signal-handler a sb-posix:sigusr2 (lambda ()))
    (lp:destroy-event-loop a)
    (let ((b (lp:make-event-loop)))
      (unwind-protect
           (progn (lp:install-signal-handler b sb-posix:sigusr2 (lambda ())) (true t))
        (lp:remove-signal-handler b sb-posix:sigusr2)
        (lp:destroy-event-loop b)))))

(define-test loop/signal-double-owner-errors
  ;; two LIVE loops claiming the same signo is a loud error (single-loop invariant).
  (let ((a (lp:make-event-loop)) (b (lp:make-event-loop)))
    (unwind-protect
         (progn
           (lp:install-signal-handler a sb-posix:sigusr2 (lambda ()))
           (true (handler-case
                     (progn (lp:install-signal-handler b sb-posix:sigusr2 (lambda ())) nil)
                   (error () t))))
      (lp:remove-signal-handler a sb-posix:sigusr2)
      (lp:destroy-event-loop a)
      (lp:destroy-event-loop b))))

;;; --- worker pool -------------------------------------------------------------

(define-test loop/worker-submit-ok
  (with-loop (loop)
    (let ((result nil))
      (lp:worker-submit loop (lambda () (+ 1 2))
                        (lambda (r) (setf result r) (lp:loop-stop loop)))
      (lp:run-loop loop)
      (is equal '(:ok 3) result))))

(define-test loop/worker-submit-error
  (with-loop (loop)
    (let ((result nil))
      (lp:worker-submit loop (lambda () (error "boom"))
                        (lambda (r) (setf result r) (lp:loop-stop loop)))
      (lp:run-loop loop)
      (is eq :err (first result))
      (true (typep (second result) 'error)))))

(define-test loop/destroy-drops-in-flight-worker-completion
  ;; DESTROY marks the loop before joining workers. A worker that finishes in that
  ;; interval must drop its post without signaling from the producer thread.
  (let ((loop (lp:make-event-loop :workers 1)) (callback-ran nil))
    (lp:worker-submit loop (lambda () (sleep 0.02) :done)
                      (lambda (result) (declare (ignore result)) (setf callback-ran t)))
    (lp:destroy-event-loop loop)
    (false callback-ran)
    (is = 0 (lp:el-ref-count loop))
    (is = 0 (sb-concurrency:mailbox-count (clun.loop::el-mailbox loop)))))

(define-test loop/concurrent-worker-teardown-keeps-exact-refcount
  ;; Four workers used to race plain DECF updates while destruction rejected their
  ;; completion posts. Hundreds of accepted jobs make the accounting race visible.
  (let* ((jobs 500)
         (loop (lp:make-event-loop :workers 4))
         (started (sb-thread:make-semaphore :count 0))
         (release (sb-thread:make-semaphore :count 0))
         (callback-count 0)
         (destroyer nil))
    (unwind-protect
         (progn
           (dotimes (i jobs)
             (declare (ignore i))
             (lp:worker-submit
              loop
              (lambda ()
                (sb-thread:signal-semaphore started)
                (sb-thread:wait-on-semaphore release)
                :done)
              (lambda (result)
                (declare (ignore result))
                (incf callback-count))))
           (true (sb-thread:wait-on-semaphore started :n 4 :timeout 2))
           (is = jobs (lp:el-ref-count loop))
           (setf destroyer
                 (sb-thread:make-thread (lambda () (lp:destroy-event-loop loop))
                                        :name "clun-worker-teardown"))
           (loop repeat 200
                 until (clun.loop::el-destroying loop)
                 do (sleep 0.001))
           (true (clun.loop::el-destroying loop))
           (sb-thread:signal-semaphore release jobs)
           (sb-thread:join-thread destroyer)
           (setf destroyer nil)
           (is = 0 callback-count)
           (is = 0 (lp:el-ref-count loop))
           (false (clun.loop::el-resources loop))
           (false (clun.loop::worker-pool-threads (clun.loop::el-workers loop))))
      (sb-thread:signal-semaphore release jobs)
      (when destroyer
        (ignore-errors (sb-thread:join-thread destroyer :timeout 5 :default nil)))
      (lp:destroy-event-loop loop))))

(define-test loop/destroyed-loop-rejects-new-work
  (let* ((loop (lp:make-event-loop :workers 0))
         (timer (lp:set-timer loop 60000 (lambda () (error "must not run"))))
         (raw-handle (lp:make-handle loop)))
    (is = 1 (lp:el-ref-count loop))
    (lp:destroy-event-loop loop)
    (is = 0 (lp:el-ref-count loop))
    (lp:clear-timer timer)
    (is = 0 (lp:el-ref-count loop))
    (let ((timer-seq (clun.loop::el-timer-seq loop)))
      (true (handler-case
                (progn (lp:set-timer loop 0 (lambda () (error "must not run"))) nil)
              (error () t)))
      (is = timer-seq (clun.loop::el-timer-seq loop))
      (is = 0 (fill-pointer
               (clun.loop::timer-heap-vec (clun.loop::el-timers loop)))))
    (true (handler-case
              (progn (lp:worker-submit loop (lambda () :never)
                                      (lambda (result) (declare (ignore result))))
                     nil)
            (error () t)))
    (false (clun.loop::worker-pool-threads (clun.loop::el-workers loop)))
    (is = 0 (sb-concurrency:mailbox-count
             (clun.loop::worker-pool-job-mailbox (clun.loop::el-workers loop))))
    (false (clun.loop::el-resources loop))
    (true (handler-case
              (progn (lp:install-signal-handler loop sb-posix:sigusr2 (lambda ())) nil)
            (error () t)))
    (false (aref (clun.loop::signal-state-installed
                  (clun.loop::el-signal-state loop))
                 sb-posix:sigusr2))
    (false (aref (clun.loop::signal-state-listeners
                  (clun.loop::el-signal-state loop))
                 sb-posix:sigusr2))
    (false (eq (aref clun.loop::*signal-owners* sb-posix:sigusr2) loop))
    (is = 0 (lp:el-ref-count loop))
    (true (handler-case (progn (lp:handle-activate raw-handle) nil) (error () t)))
    (true (handler-case (progn (lp:handle-ref raw-handle) nil) (error () t)))
    (false (clun.loop::handle-active raw-handle))
    (is = 0 (lp:el-ref-count loop))
    (false (lp:loop-post loop (lambda () (error "must not run"))))
    (true (handler-case (progn (lp:run-loop loop) nil) (error () t)))
    ;; Destruction itself remains idempotent.
    (true (progn (lp:destroy-event-loop loop) t))))

(define-test loop/concurrent-destroy-waits-and-rejects-new-work
  (let* ((loop (lp:make-event-loop :workers 0))
         (cleanup-started (sb-thread:make-semaphore :count 0))
         (release-cleanup (sb-thread:make-semaphore :count 0))
         (second-entered (sb-thread:make-semaphore :count 0))
         (second-returned (sb-thread:make-semaphore :count 0))
         (cleanup-count 0)
         (first nil)
         (second nil))
    (lp:register-loop-resource
     loop (list :blocked-cleanup)
     (lambda ()
       (incf cleanup-count)
       (sb-thread:signal-semaphore cleanup-started)
       (sb-thread:wait-on-semaphore release-cleanup)))
    (unwind-protect
         (progn
           (setf first
                 (sb-thread:make-thread (lambda () (lp:destroy-event-loop loop))
                                        :name "clun-first-destroy"))
           (true (sb-thread:wait-on-semaphore cleanup-started :timeout 2))
           (true (clun.loop::el-destroying loop))
           (false (clun.loop::el-destroyed loop))

           ;; Admission while teardown is in progress must be side-effect free.
           (true (handler-case
                     (progn (lp:set-timer loop 0 (lambda () ())) nil)
                   (error () t)))
           (true (handler-case
                     (progn (lp:worker-submit loop (lambda () :never)
                                             (lambda (result) (declare (ignore result))))
                            nil)
                   (error () t)))
           (true (handler-case
                     (progn (lp:install-signal-handler loop sb-posix:sigusr2 (lambda ())) nil)
                   (error () t)))
           (is = 0 (lp:el-ref-count loop))
           (is = 0 (fill-pointer
                    (clun.loop::timer-heap-vec (clun.loop::el-timers loop))))
           (false (clun.loop::worker-pool-threads (clun.loop::el-workers loop)))
           (is = 0 (sb-concurrency:mailbox-count
                    (clun.loop::worker-pool-job-mailbox (clun.loop::el-workers loop))))
           (false (aref (clun.loop::signal-state-installed
                         (clun.loop::el-signal-state loop))
                        sb-posix:sigusr2))
           (false (eq (aref clun.loop::*signal-owners* sb-posix:sigusr2) loop))

           (setf second
                 (sb-thread:make-thread
                  (lambda ()
                    (sb-thread:signal-semaphore second-entered)
                    (lp:destroy-event-loop loop)
                    (sb-thread:signal-semaphore second-returned))
                  :name "clun-second-destroy"))
           (true (sb-thread:wait-on-semaphore second-entered :timeout 2))
           (false (sb-thread:wait-on-semaphore second-returned :timeout 0.02))
           (sb-thread:signal-semaphore release-cleanup)
           (true (sb-thread:wait-on-semaphore second-returned :timeout 2))
           (sb-thread:join-thread first)
           (sb-thread:join-thread second)
           (setf first nil second nil)
           (is = 1 cleanup-count)
           (false (clun.loop::el-destroying loop))
           (true (clun.loop::el-destroyed loop)))
      (sb-thread:signal-semaphore release-cleanup)
      (when first (ignore-errors (sb-thread:join-thread first :timeout 2 :default nil)))
      (when second (ignore-errors (sb-thread:join-thread second :timeout 2 :default nil)))
      (lp:destroy-event-loop loop))))

;;; --- reactor robustness: recover from a handler left on a closed fd -----------

(define-test loop/select-fallback-is-silent-and-fails-at-real-limit
  (let* ((limit (clun.sys:select-fd-limit))
         (expected-range (format nil "supports descriptors 0..~D" (1- limit)))
         (stderr
           (with-output-to-string (stream)
             (let ((*error-output* stream))
               (with-loop (loop)
                 (let ((clun.loop::*reactor-poll-backend* t))
                   (false (clun.loop::probe-reactor nil))
                   (is = (1- limit)
                       (clun.loop::ensure-reactor-fd-supported (1- limit)))
                   (let ((message
                           (handler-case
                               (progn
                                 (lp:reactor-add loop limit :input
                                                 (lambda (fd) (declare (ignore fd))))
                                 nil)
                             (error (condition) (princ-to-string condition)))))
                     (true message)
                     (true (search expected-range message)))
                   (let* ((sp (clun.loop::el-self-pipe loop))
                          (actual-fd (clun.sys:self-pipe-read-fd sp)))
                     (unwind-protect
                          (progn
                            (setf (clun.sys:self-pipe-read-fd sp) limit)
                            (let ((message
                                    (handler-case
                                        (progn (lp:run-loop loop) nil)
                                      (error (condition) (princ-to-string condition)))))
                              (true (search expected-range message))))
                       (setf (clun.sys:self-pipe-read-fd sp) actual-fd)))))))))
    (is string= "" stderr)))

(define-test loop/reactor-recovers-from-closed-fd
  ;; A handler left on an fd that gets closed behind serve-event's back — the narrow
  ;; race where a socket fd is closed (a re-entrant close during dispatch, a peer reset,
  ;; or a GC finalizer on an orphaned socket under load) before its handler is
  ;; unregistered — makes serve-event signal a bad-fd error. reactor-poll must PRUNE the
  ;; stale handler and continue, never let the loop die (§6). Regression for the net
  ;; socket-suite flakiness observed under heavy concurrent load.
  (with-loop (loop)
    (multiple-value-bind (r w) (sb-posix:pipe)
      (unwind-protect
           (progn
             (lp:reactor-add loop r :input (lambda (fd) (declare (ignore fd)) nil))
             (is = 1 (length (clun.loop::el-fd-handlers loop)))
             (sb-posix:close r)                           ; the race: closed fd, live handler
             (setf r nil)
             (true (progn (clun.loop::reactor-poll loop 20) t))
             (is = 0 (length (clun.loop::el-fd-handlers loop)))) ; stale handler pruned
        (when r (ignore-errors (sb-posix:close r)))
        (ignore-errors (sb-posix:close w))))))
