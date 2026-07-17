;;;; glob-tests.lisp -- Phase 30 public binding and producer regressions.

(in-package :clun-test)

(defun glob-test-temp-prefix (name)
  (let ((directory (ensure-directories-exist #P"tmp-test/")))
    (sys:path-join (sys:pathname->native (truename directory)) name)))

(define-test glob-runtime/public-binding
  (is equal (format nil "function Glob 0 [object Glob] true false~%")
      (run-rt
       "var g=new Clun.Glob('**/*.js');console.log(typeof Clun.Glob,Clun.Glob.name,Clun.Glob.length,Object.prototype.toString.call(g),g.match('x/y.js'),g.match('x/y.txt'))")))

(define-test glob-runtime/sync-producer-keeps-ordinary-generator-layer
  (is equal (format nil "[object Generator] true true true~%")
      (run-rt
       "var nativeIterator=new Clun.Glob('__no_match__').scanSync({cwd:'.'});var ordinary=(function*(){})();console.log(Object.prototype.toString.call(nativeIterator),nativeIterator[Symbol.iterator]()===nativeIterator,Object.getPrototypeOf(nativeIterator)===Object.getPrototypeOf(Object.getPrototypeOf(ordinary)),Object.getPrototypeOf(nativeIterator)!==Object.getPrototypeOf(ordinary))")))

(define-test glob-runtime/sync-producer-releases-values-on-completion
  (let ((realm (eng:make-realm)))
    (unwind-protect
         (progn
           (rt:install-runtime realm :argv (list :script "[glob-producer-release]")
                                      :cwd "." :colors nil)
           (let ((eng:*realm* realm))
             (let ((returned (eng:make-producer-generator #(1 2 3)))
                   (exhausted (eng:make-producer-generator #())))
               (eng::%generator-step returned :return "done")
               (eng::%generator-step exhausted :next eng:+undefined+)
               (false (eng::js-generator-producer returned))
               (false (eng::js-generator-producer exhausted)))))
      (eng:teardown-realm realm))))

(define-test glob-runtime/async-producer-brand-and-return-promise
  (is equal (format nil "[object AsyncGenerator] true true true~%")
      (run-rt
       "var iterator=new Clun.Glob('__no_match__').scan({cwd:'.'});var next=iterator.next();var returned=iterator.return('stopped');console.log(Object.prototype.toString.call(iterator),iterator[Symbol.asyncIterator]()===iterator,next instanceof Promise,returned instanceof Promise)")))

(define-test glob-runtime/async-abrupt-request-waits-for-cancel-ack
  (let ((realm (eng:make-realm))
        (cancel-called nil))
    (unwind-protect
         (progn
           (rt:install-runtime realm :argv (list :script "[glob-cancel-ack]")
                                      :cwd "." :colors nil)
           (let ((eng:*realm* realm))
             (let* ((generator
                      (eng:make-producer-async-generator
                       :cancel (lambda () (setf cancel-called t))))
                    (promise (eng::%async-gen-enqueue generator :return "stopped")))
               (true cancel-called)
               (is eq :pending (eng::js-promise-pstate promise))
               (true (eng:async-generator-producer-cancelled generator))
               ;; Cancellation acknowledgement releases the producer, then the
               ;; normal async-generator return-value await settles on the job queue.
               (is eq :pending (eng::js-promise-pstate promise))
               (eng:drive-jobs realm)
               (is eq :fulfilled (eng::js-promise-pstate promise))
               (false (eng::js-async-generator-producer generator)))))
      (eng:teardown-realm realm))))

(define-test glob-runtime/thousand-scans-use-fixed-worker-pool
  (let* ((directory (sys:make-temp-dir
                     (glob-test-temp-prefix "clun-glob-workers-XXXXXX")))
         (realm (eng:make-realm))
         (loop nil))
    (unwind-protect
         (progn
           (rt:install-runtime realm :argv (list :script "[glob-workers]")
                                      :cwd directory :colors nil)
           (eng:run-program
            (eng:parse-program
             (format nil
                     "var g=new Clun.Glob('*.txt');var pending=[];for(var i=0;i<1000;i++){var it=g.scan({cwd:'~a'});pending.push(it.next());pending.push(it.return(i));}Promise.all(pending);"
                     directory))
            realm)
           (setf loop (eng::realm-loop realm))
           (true loop)
           (is = 4 (length (clun.loop::worker-pool-threads
                            (clun.loop::el-workers loop))))
           (let ((eng:*realm* realm))
             (eng:drive-jobs realm))
           (is = 0 (lp:el-ref-count loop))
           (false (clun.loop::el-resources loop)))
      (eng:teardown-realm realm)
      (when loop
        (false (clun.loop::worker-pool-threads
                (clun.loop::el-workers loop))))
      (sys:remove-recursive directory))))

(define-test glob-runtime/teardown-cancels-active-scan-before-worker-join
  (let* ((loop (lp:make-event-loop :workers 1))
         (started (sb-thread:make-semaphore :count 0))
         (visits 0)
         (callback-ran nil)
         (directory (glob-test-stat :directory 1))
         (accessor
           (glob:make-glob-accessor
            :map-directory
            (lambda (path callback)
              (declare (ignore path))
              (loop
                (incf visits)
                (when (= visits 1) (sb-thread:signal-semaphore started))
                (funcall callback "entry")))
            :stat (lambda (path) (declare (ignore path)) directory)
            :lstat (lambda (path)
                     (declare (ignore path))
                     (error "nonmatching entry must not be classified"))))
         (job
           (lp:worker-submit-cancellable
            loop
            (lambda (token)
              (glob:scan-glob
               "absent" (glob:make-glob-scan-options :cwd "/virtual")
               (lambda () (lp:worker-cancelled-p token)) accessor))
            (lambda (result)
              (declare (ignore result))
              (setf callback-ran t)))))
    (unwind-protect
         (progn
           (true (sb-thread:wait-on-semaphore started :timeout 2))
           (lp:destroy-event-loop loop)
           (is eq :cancelled (lp:worker-job-state job))
           (false callback-ran)
           (true (plusp visits))
           (is = 0 (lp:el-ref-count loop))
           (false (clun.loop::el-resources loop))
           (false (clun.loop::worker-pool-threads
                   (clun.loop::el-workers loop))))
      (lp:destroy-event-loop loop))))

(define-test glob-runtime/hundred-thousand-sync-scans-retain-under-limit
  (let* ((directory (sys:make-temp-dir
                     (glob-test-temp-prefix "clun-glob-leak-XXXXXX")))
         (realm (eng:make-realm)))
    (unwind-protect
         (progn
           (rt:install-runtime realm :argv (list :script "[glob-leak]")
                                      :cwd directory :colors nil)
           (eng:run-program
            (eng:parse-program
             (format nil
                     "var g=new Clun.Glob('*.txt');for(var i=0;i<1000;i++){[...g.scanSync({cwd:'~a'})];}"
                     directory))
            realm)
           (sb-ext:gc :full t)
           (let ((baseline (sys:heap-bytes-used)))
             (eng:run-program
              (eng:parse-program
               (format nil
                       "var g=new Clun.Glob('*.txt');for(var i=0;i<100000;i++){[...g.scanSync({cwd:'~a'})];}"
                       directory))
              realm)
             (sb-ext:gc :full t)
             (true (< (max 0 (- (sys:heap-bytes-used) baseline))
                      (* 100 1024 1024)))))
      (eng:teardown-realm realm)
      (sys:remove-recursive directory))))
