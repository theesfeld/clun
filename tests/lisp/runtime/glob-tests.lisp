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

(define-test glob-runtime/async-producer-brand-and-return-promise
  (is equal (format nil "[object AsyncGenerator] true true true~%")
      (run-rt
       "var iterator=new Clun.Glob('__no_match__').scan({cwd:'.'});var next=iterator.next();var returned=iterator.return('stopped');console.log(Object.prototype.toString.call(iterator),iterator[Symbol.asyncIterator]()===iterator,next instanceof Promise,returned instanceof Promise)")))

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
