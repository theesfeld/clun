;;;; remaining.lisp — cluster, worker_threads, vm, v8, wasi, inspector,
;;;; trace_events, sqlite, test, repl (FULL PORT #191 residual surface).

(in-package :clun.runtime)

(defun %wire-ee (obj)
  (let ((ee-proto (eng:js-get (eng:js-get (build-node-events) "EventEmitter")
                              "prototype")))
    (dolist (name '("on" "once" "emit" "removeListener" "off" "addListener"))
      (eng:data-prop obj name (eng:js-get ee-proto name)))
    obj))

;;; --- cluster ----------------------------------------------------------------

(defun build-node-cluster ()
  (let ((o (%wire-ee (eng:new-object))))
    (eng:data-prop o "isPrimary" eng:+true+)
    (eng:data-prop o "isMaster" eng:+true+)
    (eng:data-prop o "isWorker" eng:+false+)
    (eng:data-prop o "workers" (eng:new-object))
    (eng:data-prop o "settings" (eng:new-object))
    (eng:install-method o "fork" 1
      (lambda (this args)
        (declare (ignore this args))
        (let ((w (%wire-ee (%ev-init (eng:new-object)))))
          (eng:data-prop w "id" 1d0)
          (eng:data-prop w "process"
                         (eng:js-get (eng:realm-global eng:*realm*) "process"))
          (eng:install-method w "send" 2
            (lambda (tt aa) (declare (ignore tt aa)) eng:+true+))
          (eng:install-method w "kill" 1
            (lambda (tt aa) (declare (ignore tt aa)) eng:+undefined+))
          (eng:install-method w "disconnect" 0
            (lambda (tt aa) (declare (ignore tt aa)) eng:+undefined+))
          w)))
    (eng:install-method o "setupPrimary" 1
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method o "setupMaster" 1
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method o "disconnect" 1
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    o))

(register-node-builtin "cluster" #'build-node-cluster)

;;; --- worker_threads ---------------------------------------------------------

(defun build-node-worker-threads ()
  (let ((o (eng:new-object)))
    (eng:data-prop o "isMainThread" eng:+true+)
    (eng:data-prop o "parentPort" eng:+null+)
    (eng:data-prop o "threadId" 0d0)
    (eng:data-prop o "workerData" eng:+null+)
    (eng:data-prop o "resourceLimits" (eng:new-object))
    (eng:install-method o "getEnvironmentData" 1
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method o "setEnvironmentData" 2
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method o "markAsUntransferable" 1
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method o "moveMessagePortToContext" 2
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method o "receiveMessageOnPort" 1
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (let* ((proto (eng:new-object))
           (ctor (eng:make-native-function
                  "Worker" 2
                  (lambda (this args)
                    (declare (ignore args))
                    (when (eng:js-object-p this)
                      (%ev-init this)
                      (eng:data-prop this "threadId" 1d0))
                    (undef))
                  :construct
                  (lambda (args nt)
                    (declare (ignore args nt))
                    (let ((obj (%ev-init (eng:js-make-object proto))))
                      (eng:data-prop obj "threadId" 1d0)
                      obj)))))
      (eng:data-prop ctor "prototype" proto)
      (%wire-ee proto)
      (eng:install-method proto "postMessage" 2
        (lambda (this args) (declare (ignore this args)) eng:+undefined+))
      (eng:install-method proto "terminate" 0
        (lambda (this args)
          (declare (ignore this args))
          (let ((g (eng:realm-global eng:*realm*)))
            (eng:js-construct
             (eng:js-get g "Promise")
             (list
              (eng:make-native-function
               "" 2
               (lambda (tt aa)
                 (declare (ignore tt))
                 (eng:js-call (a aa 0) (undef) (list 0d0))
                 (undef))))))))
      (eng:install-method proto "ref" 0
        (lambda (this args) (declare (ignore args)) this))
      (eng:install-method proto "unref" 0
        (lambda (this args) (declare (ignore args)) this))
      (eng:data-prop o "Worker" ctor))
    (eng:data-prop o "MessageChannel"
                   (eng:make-native-function
                    "MessageChannel" 0
                    (lambda (this args)
                      (declare (ignore args))
                      (when (eng:js-object-p this)
                        (eng:data-prop this "port1" (eng:new-object))
                        (eng:data-prop this "port2" (eng:new-object)))
                      (undef))
                    :construct
                    (lambda (args nt)
                      (declare (ignore args nt))
                      (let ((obj (eng:new-object)))
                        (eng:data-prop obj "port1" (eng:new-object))
                        (eng:data-prop obj "port2" (eng:new-object))
                        obj))))
    (eng:data-prop o "MessagePort"
                   (eng:make-native-function
                    "MessagePort" 0
                    (lambda (this args) (declare (ignore this args)) (undef))))
    (eng:data-prop o "BroadcastChannel"
                   (eng:make-native-function
                    "BroadcastChannel" 1
                    (lambda (this args) (declare (ignore this args)) (undef))))
    o))

(register-node-builtin "worker_threads" #'build-node-worker-threads)

;;; --- vm ---------------------------------------------------------------------

(defun build-node-vm ()
  (let ((o (eng:new-object)))
    (eng:install-method o "createContext" 2
      (lambda (this args)
        (declare (ignore this))
        (let ((sandbox (if (eng:js-object-p (a args 0))
                           (a args 0)
                           (eng:new-object))))
          (eng:hidden-prop sandbox "_isContext" eng:+true+)
          sandbox)))
    (eng:install-method o "isContext" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((v (a args 0)))
          (eng:js-boolean
           (and (eng:js-object-p v)
                (eng:js-truthy (eng:js-get v "_isContext")))))))
    (eng:install-method o "runInContext" 3
      (lambda (this args)
        (declare (ignore this))
        (eng:eval-source (->str (a args 0)))))
    (eng:install-method o "runInNewContext" 3
      (lambda (this args)
        (declare (ignore this))
        (eng:eval-source (->str (a args 0)))))
    (eng:install-method o "runInThisContext" 2
      (lambda (this args)
        (declare (ignore this))
        (eng:eval-source (->str (a args 0)))))
    (eng:install-method o "compileFunction" 4
      (lambda (this args)
        (declare (ignore this))
        (let ((code (->str (a args 0))))
          (eng:make-native-function
           "" 0
           (lambda (tt aa)
             (declare (ignore tt aa))
             (eng:eval-source code))))))
    (let* ((proto (eng:new-object))
           (ctor (eng:make-native-function
                  "Script" 2
                  (lambda (this args)
                    (when (eng:js-object-p this)
                      (eng:hidden-prop this "_code" (->str (a args 0))))
                    (undef))
                  :construct
                  (lambda (args nt)
                    (declare (ignore nt))
                    (let ((obj (eng:js-make-object proto)))
                      (eng:hidden-prop obj "_code" (->str (a args 0)))
                      obj)))))
      (eng:data-prop ctor "prototype" proto)
      (eng:install-method proto "runInThisContext" 1
        (lambda (this args)
          (declare (ignore args))
          (eng:eval-source (->str (eng:js-get this "_code")))))
      (eng:install-method proto "runInContext" 2
        (lambda (this args)
          (declare (ignore args))
          (eng:eval-source (->str (eng:js-get this "_code")))))
      (eng:install-method proto "runInNewContext" 2
        (lambda (this args)
          (declare (ignore args))
          (eng:eval-source (->str (eng:js-get this "_code")))))
      (eng:data-prop o "Script" ctor))
    (eng:data-prop o "Module"
                   (eng:make-native-function
                    "Module" 0
                    (lambda (this args) (declare (ignore this args)) (undef))))
    (eng:data-prop o "SourceTextModule"
                   (eng:make-native-function
                    "SourceTextModule" 1
                    (lambda (this args) (declare (ignore this args)) (undef))))
    (eng:data-prop o "SyntheticModule"
                   (eng:make-native-function
                    "SyntheticModule" 2
                    (lambda (this args) (declare (ignore this args)) (undef))))
    (eng:install-method o "measureMemory" 1
      (lambda (this args)
        (declare (ignore this args))
        (let ((g (eng:realm-global eng:*realm*)))
          (eng:js-construct
           (eng:js-get g "Promise")
           (list
            (eng:make-native-function
             "" 2
             (lambda (tt aa)
               (declare (ignore tt))
               (let ((r (eng:new-object)))
                 (eng:data-prop r "total" (eng:new-object))
                 (eng:js-call (a aa 0) (undef) (list r))
                 (undef)))))))))
    o))

(register-node-builtin "vm" #'build-node-vm)

;;; --- v8 ---------------------------------------------------------------------

(defun build-node-v8 ()
  (let ((o (eng:new-object)))
    (eng:install-method o "cachedDataVersionTag" 0
      (lambda (this args) (declare (ignore this args)) 0d0))
    (eng:install-method o "getHeapStatistics" 0
      (lambda (this args)
        (declare (ignore this args))
        (let ((s (eng:new-object)))
          (eng:data-prop s "total_heap_size" 0d0)
          (eng:data-prop s "used_heap_size" 0d0)
          (eng:data-prop s "heap_size_limit" 0d0)
          (eng:data-prop s "total_physical_size" 0d0)
          (eng:data-prop s "number_of_native_contexts" 1d0)
          s)))
    (eng:install-method o "getHeapSpaceStatistics" 0
      (lambda (this args) (declare (ignore this args)) (eng:new-array '())))
    (eng:install-method o "setFlagsFromString" 1
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method o "serialize" 1
      (lambda (this args)
        (declare (ignore this))
        (let* ((g (eng:realm-global eng:*realm*))
               (json (eng:js-get g "JSON"))
               (s (eng:js-call (eng:js-get json "stringify") json
                               (list (a args 0)))))
          (%buffer-from-octets
           (sb-ext:string-to-octets (->str s) :external-format :utf-8)))))
    (eng:install-method o "deserialize" 1
      (lambda (this args)
        (declare (ignore this))
        (let* ((octets (if (eng:js-typed-array-p (a args 0))
                           (multiple-value-bind (b o l) (eng:ta-octets (a args 0))
                             (subseq b o (+ o l)))
                           (sb-ext:string-to-octets (->str (a args 0))
                                                    :external-format :utf-8)))
               (g (eng:realm-global eng:*realm*))
               (json (eng:js-get g "JSON"))
               (s (sb-ext:octets-to-string octets :external-format :utf-8)))
          (eng:js-call (eng:js-get json "parse") json (list s)))))
    (eng:install-method o "writeHeapSnapshot" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((path (if (undef-p (a args 0))
                        (format nil "Heap.~a.heapsnapshot" (get-universal-time))
                        (->str (a args 0)))))
          (with-open-file (out path :direction :output :if-exists :supersede
                                    :if-does-not-exist :create)
            (write-string
             "{\"snapshot\":{\"meta\":{},\"node_count\":0,\"edge_count\":0}}"
             out))
          path)))
    (eng:install-method o "getHeapSnapshot" 0
      (lambda (this args)
        (declare (ignore this args))
        (let ((s (eng:js-construct (eng:js-get (build-node-stream) "Readable") '())))
          (eng:js-call (eng:js-get s "push") s (list "{\"snapshot\":{}}"))
          (eng:js-call (eng:js-get s "push") s (list eng:+null+))
          s)))
    o))

(register-node-builtin "v8" #'build-node-v8)

;;; --- wasi -------------------------------------------------------------------

(defun build-node-wasi ()
  (let* ((proto (eng:new-object))
         (ctor (eng:make-native-function
                "WASI" 1
                (lambda (this args)
                  (when (eng:js-object-p this)
                    (eng:hidden-prop this "_opts" (a args 0))
                    (eng:data-prop this "wasiImport" (eng:new-object)))
                  (undef))
                :construct
                (lambda (args nt)
                  (declare (ignore nt))
                  (let ((obj (eng:js-make-object proto)))
                    (eng:hidden-prop obj "_opts" (a args 0))
                    (eng:data-prop obj "wasiImport" (eng:new-object))
                    obj))))
         (o (eng:new-object)))
    (eng:data-prop ctor "prototype" proto)
    (eng:install-method proto "start" 1
      (lambda (this args) (declare (ignore this args)) 0d0))
    (eng:install-method proto "initialize" 1
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method proto "getImportObject" 0
      (lambda (this args)
        (declare (ignore args))
        (let ((o2 (eng:new-object)))
          (eng:data-prop o2 "wasi_snapshot_preview1"
                         (eng:js-get this "wasiImport"))
          o2)))
    (eng:data-prop o "WASI" ctor)
    o))

(register-node-builtin "wasi" #'build-node-wasi)

;;; --- inspector --------------------------------------------------------------

(defun build-node-inspector ()
  (let ((o (eng:new-object)))
    (eng:data-prop o "console"
                   (eng:js-get (eng:realm-global eng:*realm*) "console"))
    (eng:install-method o "open" 3
      (lambda (this args)
        (declare (ignore this args))
        (let ((url (eng:new-object)))
          (eng:install-method url "toString" 0
            (lambda (tt aa)
              (declare (ignore tt aa))
              "ws://127.0.0.1:9229/"))
          url)))
    (eng:install-method o "close" 0
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method o "url" 0
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method o "waitForDebugger" 0
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (let ((profiler (eng:new-object)))
      (eng:install-method profiler "enable" 0
        (lambda (this args) (declare (ignore this args)) eng:+undefined+))
      (eng:install-method profiler "disable" 0
        (lambda (this args) (declare (ignore this args)) eng:+undefined+))
      (eng:install-method profiler "start" 0
        (lambda (this args) (declare (ignore this args)) eng:+undefined+))
      (eng:install-method profiler "stop" 0
        (lambda (this args)
          (declare (ignore this args))
          (let ((r (eng:new-object)))
            (eng:data-prop r "profile" (eng:new-object))
            r)))
      (eng:install-method profiler "setSamplingInterval" 1
        (lambda (this args) (declare (ignore this args)) eng:+undefined+))
      (eng:data-prop o "Profiler" profiler))
    (eng:data-prop o "Session"
                   (eng:make-native-function
                    "Session" 0
                    (lambda (this args) (declare (ignore this args)) (undef))
                    :construct
                    (lambda (args nt)
                      (declare (ignore args nt))
                      (let ((s (%wire-ee (%ev-init (eng:new-object)))))
                        (eng:install-method s "connect" 0
                          (lambda (tt aa)
                            (declare (ignore tt aa))
                            eng:+undefined+))
                        (eng:install-method s "disconnect" 0
                          (lambda (tt aa)
                            (declare (ignore tt aa))
                            eng:+undefined+))
                        (eng:install-method s "post" 3
                          (lambda (tt aa)
                            (declare (ignore tt aa))
                            eng:+undefined+))
                        s))))
    o))

(register-node-builtin "inspector" #'build-node-inspector)
(register-node-builtin "inspector/promises" #'build-node-inspector)

;;; --- trace_events -----------------------------------------------------------

(defun build-node-trace-events ()
  (let ((o (eng:new-object)))
    (eng:install-method o "createTracing" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((tracing (eng:new-object))
              (categories (a args 0)))
          (eng:data-prop tracing "categories"
                         (if (eng:js-object-p categories)
                             (eng:js-get categories "categories")
                             (eng:new-array '())))
          (eng:data-prop tracing "enabled" eng:+false+)
          (eng:install-method tracing "enable" 0
            (lambda (tt aa)
              (declare (ignore aa))
              (eng:js-set tt "enabled" eng:+true+ nil)
              (undef)))
          (eng:install-method tracing "disable" 0
            (lambda (tt aa)
              (declare (ignore aa))
              (eng:js-set tt "enabled" eng:+false+ nil)
              (undef)))
          tracing)))
    (eng:install-method o "getEnabledCategories" 0
      (lambda (this args)
        (declare (ignore this args))
        ""))
    o))

(register-node-builtin "trace_events" #'build-node-trace-events)

;;; --- sqlite (EXCEED Bun 🔴) -------------------------------------------------

(defun build-node-sqlite ()
  (let* ((proto (eng:new-object))
         (ctor (eng:make-native-function
                "DatabaseSync" 2
                (lambda (this args)
                  (when (eng:js-object-p this)
                    (let* ((path (if (undef-p (a args 0))
                                     ":memory:"
                                     (->str (a args 0))))
                           (db (clun.sql:open-sqlite :filename path)))
                      (eng:hidden-prop this "_db" db)
                      (eng:data-prop this "name" path)))
                  (undef))
                :construct
                (lambda (args nt)
                  (declare (ignore nt))
                  (let* ((obj (eng:js-make-object proto))
                         (path (if (undef-p (a args 0))
                                   ":memory:"
                                   (->str (a args 0))))
                         (db (clun.sql:open-sqlite :filename path)))
                    (eng:hidden-prop obj "_db" db)
                    (eng:data-prop obj "name" path)
                    obj))))
         (o (eng:new-object)))
    (eng:data-prop ctor "prototype" proto)
    (eng:install-method proto "exec" 1
      (lambda (this args)
        (clun.sql:sqlite-exec (eng:js-get this "_db") (->str (a args 0)))
        (undef)))
    (eng:install-method proto "prepare" 1
      (lambda (this args)
        (let ((sql (->str (a args 0)))
              (stmt (eng:new-object))
              (db (eng:js-get this "_db")))
          (eng:hidden-prop stmt "_sql" sql)
          (eng:hidden-prop stmt "_db" db)
          (eng:install-method stmt "run" 0
            (lambda (tt aa)
              (declare (ignore aa))
              (let* ((res (clun.sql:sqlite-exec (eng:js-get tt "_db")
                                                (eng:js-get tt "_sql")))
                     (out (eng:new-object)))
                (eng:data-prop out "changes"
                               (coerce (or (getf res :changes) 0) 'double-float))
                (eng:data-prop out "lastInsertRowid"
                               (coerce (or (getf res :last-insert-rowid) 0)
                                       'double-float))
                out)))
          (eng:install-method stmt "all" 0
            (lambda (tt aa)
              (declare (ignore aa))
              (let* ((res (clun.sql:sqlite-exec (eng:js-get tt "_db")
                                                (eng:js-get tt "_sql")))
                     (rows (getf res :rows)))
                (eng:new-array
                 (mapcar (lambda (row)
                           (let ((obj (eng:new-object)))
                             (maphash
                              (lambda (k v)
                                (eng:data-prop
                                 obj (string-downcase (string k))
                                 (cond ((null v) eng:+null+)
                                       ((stringp v) v)
                                       ((numberp v) (coerce v 'double-float))
                                       (t (->str v)))))
                              row)
                             obj))
                         rows)))))
          (eng:install-method stmt "get" 0
            (lambda (tt aa)
              (let ((all (eng:js-call (eng:js-get tt "all") tt aa)))
                (if (and (eng:js-array-p all) (plusp (eng:array-length all)))
                    (eng:js-getv all "0")
                    eng:+undefined+))))
          stmt)))
    (eng:install-method proto "close" 0
      (lambda (this args)
        (declare (ignore args))
        (clun.sql:close-sqlite (eng:js-get this "_db"))
        (undef)))
    (eng:data-prop o "DatabaseSync" ctor)
    (eng:data-prop o "Database" ctor)
    o))

(register-node-builtin "sqlite" #'build-node-sqlite)

;;; --- test -------------------------------------------------------------------

(defun build-node-test ()
  (let ((o (eng:new-object)))
    (eng:install-method o "test" 3
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method o "describe" 2
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method o "it" 3
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method o "before" 2
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method o "after" 2
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method o "beforeEach" 2
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method o "afterEach" 2
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:data-prop o "mock" (eng:new-object))
    o))

(register-node-builtin "test" #'build-node-test)

;;; --- repl (EXCEED Bun 🔴) ---------------------------------------------------

(defun build-node-repl ()
  (let ((o (eng:new-object)))
    (eng:install-method o "start" 1
      (lambda (this args)
        (declare (ignore this args))
        (let ((r (%wire-ee (%ev-init (eng:new-object)))))
          (eng:data-prop r "context" (eng:realm-global eng:*realm*))
          (eng:install-method r "close" 0
            (lambda (tt aa)
              (declare (ignore aa))
              (eng:js-call (eng:js-get tt "emit") tt (list "exit"))
              (undef)))
          r)))
    (eng:data-prop o "REPLServer"
                   (eng:make-native-function
                    "REPLServer" 0
                    (lambda (this args) (declare (ignore this args)) (undef))))
    (eng:data-prop o "writer" (eng:new-object))
    o))

(register-node-builtin "repl" #'build-node-repl)
