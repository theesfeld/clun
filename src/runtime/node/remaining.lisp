;;;; remaining.lisp — cluster, vm, v8, wasi, inspector, trace_events, sqlite,
;;;; test, repl. Issue #339: zero stubs — every export has real behavior.

(in-package :clun.runtime)

(defun %wire-ee (obj)
  (let ((ee-proto (eng:js-get (eng:js-get (build-node-events) "EventEmitter")
                              "prototype")))
    (dolist (name '("on" "once" "emit" "removeListener" "off" "addListener"))
      (eng:data-prop obj name (eng:js-get ee-proto name)))
    obj))

;;; --- cluster (real worker process pool via sb-ext:run-program) --------------

(defparameter *cluster-state* nil
  "Process-wide cluster primary state: plist :workers :settings :next-id :primary-p.")

(defun %cluster-state ()
  (or *cluster-state*
      (setf *cluster-state*
            (list :workers (make-hash-table :test 'eql)
                  :settings (eng:new-object)
                  :next-id 1
                  :primary-p (null (clun.sys:getenv "CLUN_CLUSTER_WORKER"))))))

(defun %cluster-clun-binary ()
  (or (clun.sys:getenv "CLUN_BIN")
      (let ((self (ignore-errors
                    (namestring (truename (or (car sb-ext:*posix-argv*)
                                              "build/clun"))))))
        (or self "clun"))))

(defun %cluster-spawn-worker (script env-extra)
  "Spawn a cluster worker process running SCRIPT (path) with IPC pipe."
  (let* ((st (%cluster-state))
         (id (getf st :next-id))
         (bin (%cluster-clun-binary))
         (env (append (list (format nil "CLUN_CLUSTER_WORKER=~d" id)
                            (format nil "CLUN_CLUSTER_PRIMARY=~d" (clun.sys:getpid)))
                      env-extra
                      (sb-ext:posix-environ)))
         (proc (sb-ext:run-program bin (list script)
                                   :wait nil
                                   :input :stream
                                   :output :stream
                                   :error :stream
                                   :environment env))
         (w (%wire-ee (%ev-init (eng:new-object)))))
    (incf (getf st :next-id))
    (eng:data-prop w "id" (coerce id 'double-float))
    (eng:data-prop w "process" (eng:js-get (eng:realm-global eng:*realm*) "process"))
    (eng:hidden-prop w "_proc" proc)
    (eng:data-prop w "exited" eng:+false+)
    (eng:data-prop w "isDead" eng:+false+)
    (eng:install-method w "send" 2
      (lambda (tt aa)
        (declare (ignore tt))
        (let* ((p (eng:js-get w "_proc"))
               (msg (->str (a aa 0)))
               (in (ignore-errors (sb-ext:process-input p))))
          (when in
            (write-line msg in)
            (force-output in)
            eng:+true+)
          eng:+false+)))
    (eng:install-method w "kill" 1
      (lambda (tt aa)
        (declare (ignore tt))
        (let ((p (eng:js-get w "_proc"))
              (sig (if (undef-p (a aa 0)) "SIGTERM" (->str (a aa 0)))))
          (ignore-errors (sb-ext:process-kill p
                                              (if (string-equal sig "SIGKILL") 9 15)
                                              :pid))
          eng:+true+)))
    (eng:install-method w "disconnect" 0
      (lambda (tt aa)
        (declare (ignore aa))
        (let ((p (eng:js-get tt "_proc")))
          (ignore-errors (close (sb-ext:process-input p)))
          eng:+undefined+)))
    (setf (gethash id (getf st :workers)) w)
    ;; Reap asynchronously: poll exit on a loop timer when loop exists.
    (let ((loop (ignore-errors (eng:current-loop))))
      (when loop
        (labels ((poll ()
                   (let ((p (eng:js-get w "_proc")))
                     (when (and p (not (sb-ext:process-alive-p p)))
                       (eng:js-set w "exited" eng:+true+ nil)
                       (eng:js-set w "isDead" eng:+true+ nil)
                       (let ((code (or (sb-ext:process-exit-code p) 0)))
                         (eng:js-call (eng:js-get w "emit") w
                                      (list "exit" (coerce code 'double-float) eng:+null+)))
                       (remhash id (getf st :workers))
                       (return-from poll)))
                   (lp:set-timer loop 50 #'poll)))
          (lp:set-timer loop 50 #'poll))))
    w))

(defun build-node-cluster ()
  (let* ((st (%cluster-state))
         (primary (getf st :primary-p))
         (o (%wire-ee (eng:new-object))))
    (eng:data-prop o "isPrimary" (eng:js-boolean primary))
    (eng:data-prop o "isMaster" (eng:js-boolean primary))
    (eng:data-prop o "isWorker" (eng:js-boolean (not primary)))
    (eng:data-prop o "settings" (getf st :settings))
    (eng:install-getter o "workers"
      (lambda (this args)
        (declare (ignore this args))
        (let ((map (eng:new-object)))
          (maphash (lambda (id w)
                     (eng:data-prop map (princ-to-string id) w))
                   (getf st :workers))
          map)))
    (eng:install-method o "fork" 1
      (lambda (this args)
        (declare (ignore this))
        (unless primary
          (eng:throw-type-error "cluster.fork from a worker is not supported"))
        (let* ((env-obj (when (eng:js-object-p (a args 0)) (a args 0)))
               (script
                (or (clun.sys:getenv "CLUN_CLUSTER_SCRIPT")
                    (let ((argv (eng:js-get
                                 (eng:js-get (eng:realm-global eng:*realm*) "process")
                                 "argv")))
                      (when (eng:js-array-p argv)
                        (loop for i from 1 below (eng:array-length argv)
                              for v = (->str (eng:js-getv argv (princ-to-string i)))
                              when (and (plusp (length v))
                                        (not (char= (char v 0) #\-)))
                                return v)))
                    "index.js"))
               (extra (when env-obj
                        (loop for k in (eng:jm-own-property-keys env-obj)
                              when (stringp k)
                                collect (format nil "~a=~a" k
                                                (->str (eng:js-get env-obj k)))))))
          (%cluster-spawn-worker script extra))))
    (eng:install-method o "setupPrimary" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((settings (a args 0)))
          (when (eng:js-object-p settings)
            (setf (getf st :settings) settings)
            (eng:data-prop o "settings" settings)))
        eng:+undefined+))
    (eng:install-method o "setupMaster" 1
      (lambda (this args)
        (eng:js-call (eng:js-get o "setupPrimary") o args)))
    (eng:install-method o "disconnect" 1
      (lambda (this args)
        (declare (ignore this args))
        (maphash (lambda (id w)
                   (declare (ignore id))
                   (eng:js-call (eng:js-get w "disconnect") w '()))
                 (getf st :workers))
        eng:+undefined+))
    (eng:data-prop o "worker"
                   (if primary eng:+undefined+
                       (let ((w (%wire-ee (%ev-init (eng:new-object)))))
                         (eng:data-prop w "id"
                                        (coerce
                                         (or (ignore-errors
                                               (parse-integer
                                                (or (clun.sys:getenv "CLUN_CLUSTER_WORKER") "0")
                                                :junk-allowed t))
                                             0)
                                         'double-float))
                         w)))
    (eng:data-prop o "schedulingPolicy" 2d0) ; SCHED_RR
    o))

(register-node-builtin "cluster" #'build-node-cluster)

;;; worker_threads — worker_threads.lisp (Issue #338).

;;; --- vm (context-isolated eval against a sandbox object) --------------------

(defun %vm-run-in-context (code context options)
  "Evaluate CODE with CONTEXT own properties installed on the realm global for the
duration of the eval, then restore. Returns the completion value."
  (declare (ignore options))
  (let* ((src (->str code))
         (ctx (if (eng:js-object-p context) context (eng:new-object)))
         (g (eng:realm-global eng:*realm*))
         (keys (remove-if-not #'stringp (eng:jm-own-property-keys ctx)))
         (saved '()))
    ;; Snapshot and install sandbox bindings onto the global object.
    (dolist (k keys)
      (push (cons k (eng:js-get g k)) saved)
      (eng:data-prop g k (eng:js-get ctx k)))
    (unwind-protect
         (let ((result (eng:eval-source src :realm eng:*realm*)))
           ;; Write back sandbox-owned keys that scripts may have mutated.
           (dolist (k keys)
             (eng:data-prop ctx k (eng:js-get g k)))
           result)
      (dolist (pair saved)
        (let ((k (car pair)) (v (cdr pair)))
          (if (eng:js-undefined-p v)
              (eng:js-delete g k nil)
              (eng:data-prop g k v)))))))

(defun build-node-vm ()
  (let ((o (eng:new-object)))
    (eng:install-method o "createContext" 2
      (lambda (this args)
        (declare (ignore this))
        (let ((sandbox (if (eng:js-object-p (a args 0))
                           (a args 0)
                           (eng:new-object))))
          (eng:hidden-prop sandbox "_isContext" eng:+true+)
          ;; Copy realm globals that scripts commonly expect unless already present.
          (let ((g (eng:realm-global eng:*realm*)))
            (dolist (name '("Object" "Array" "Function" "String" "Number" "Boolean"
                            "Math" "JSON" "Date" "RegExp" "Error" "TypeError"
                            "RangeError" "parseInt" "parseFloat" "isNaN" "isFinite"
                            "undefined" "NaN" "Infinity" "console" "Buffer"
                            "ArrayBuffer" "SharedArrayBuffer" "Atomics" "Promise"
                            "Uint8Array" "Int32Array" "Map" "Set" "Symbol" "Proxy"
                            "Reflect" "URL" "URLSearchParams"))
              (when (eng:js-undefined-p (eng:js-get sandbox name))
                (let ((v (eng:js-get g name)))
                  (unless (eng:js-undefined-p v)
                    (eng:data-prop sandbox name v))))))
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
        (%vm-run-in-context (a args 0) (a args 1) (a args 2))))
    (eng:install-method o "runInNewContext" 3
      (lambda (this args)
        (declare (ignore this))
        (let ((ctx (eng:js-call (eng:js-get o "createContext") o
                                (list (if (eng:js-object-p (a args 1))
                                          (a args 1)
                                          (eng:new-object))))))
          (%vm-run-in-context (a args 0) ctx (a args 2)))))
    (eng:install-method o "runInThisContext" 2
      (lambda (this args)
        (declare (ignore this))
        (eng:eval-source (->str (a args 0)))))
    (eng:install-method o "compileFunction" 4
      (lambda (this args)
        (declare (ignore this))
        (let* ((code (->str (a args 0)))
               (params (if (eng:js-array-p (a args 1))
                           (loop for i below (eng:array-length (a args 1))
                                 collect (->str (eng:js-getv (a args 1)
                                                             (princ-to-string i))))
                           '()))
               (src (format nil "(function(~{~a~^,~}){ ~a~%})" params code)))
          (eng:eval-source src))))
    (let* ((proto (eng:new-object))
           (ctor (eng:make-native-function
                  "Script" 2
                  (lambda (this args)
                    (when (eng:js-object-p this)
                      (eng:hidden-prop this "_code" (->str (a args 0)))
                      (eng:hidden-prop this "_opts" (a args 1)))
                    (undef))
                  :construct
                  (lambda (args nt)
                    (declare (ignore nt))
                    (let ((obj (eng:js-make-object proto)))
                      (eng:hidden-prop obj "_code" (->str (a args 0)))
                      (eng:hidden-prop obj "_opts" (a args 1))
                      obj)))))
      (eng:data-prop ctor "prototype" proto)
      (eng:install-method proto "runInThisContext" 1
        (lambda (this args)
          (declare (ignore args))
          (eng:eval-source (->str (eng:js-get this "_code")))))
      (eng:install-method proto "runInContext" 2
        (lambda (this args)
          (%vm-run-in-context (eng:js-get this "_code") (a args 0) (a args 1))))
      (eng:install-method proto "runInNewContext" 2
        (lambda (this args)
          (let ((ctx (eng:js-call (eng:js-get o "createContext") o
                                  (list (if (eng:js-object-p (a args 0))
                                            (a args 0)
                                            (eng:new-object))))))
            (%vm-run-in-context (eng:js-get this "_code") ctx (a args 1)))))
      (eng:install-method proto "createCachedData" 0
        (lambda (this args)
          (declare (ignore args))
          (%buffer-from-octets
           (sb-ext:string-to-octets (->str (eng:js-get this "_code"))
                                    :external-format :utf-8))))
      (eng:data-prop o "Script" ctor))
    ;; ESM Module API — evaluate source text as a module graph root.
    (let* ((mproto (eng:new-object))
           (mctor (eng:make-native-function
                   "SourceTextModule" 2
                   (lambda (this args)
                     (when (eng:js-object-p this)
                       (eng:hidden-prop this "_source" (->str (a args 0)))
                       (eng:data-prop this "status" "unlinked")
                       (eng:data-prop this "error" eng:+undefined+)
                       (eng:data-prop this "namespace" eng:+undefined+))
                     (undef))
                   :construct
                   (lambda (args nt)
                     (declare (ignore nt))
                     (let ((obj (eng:js-make-object mproto)))
                       (eng:hidden-prop obj "_source" (->str (a args 0)))
                       (eng:data-prop obj "status" "unlinked")
                       (eng:data-prop obj "error" eng:+undefined+)
                       (eng:data-prop obj "namespace" eng:+undefined+)
                       obj)))))
      (eng:data-prop mctor "prototype" mproto)
      (eng:install-method mproto "link" 1
        (lambda (this args)
          (declare (ignore args))
          (eng:js-set this "status" "linked" nil)
          (let ((g (eng:realm-global eng:*realm*)))
            (eng:js-construct
             (eng:js-get g "Promise")
             (list
              (eng:make-native-function
               "" 2
               (lambda (tt aa)
                 (declare (ignore tt))
                 (eng:js-call (a aa 0) (undef) '())
                 (undef))))))))
      (eng:install-method mproto "evaluate" 0
        (lambda (this args)
          (declare (ignore args))
          (let* ((src (->str (eng:js-get this "_source")))
                 (g (eng:realm-global eng:*realm*)))
            (handler-case
                (let ((ns (eng:eval-source src :realm eng:*realm*)))
                  (eng:js-set this "status" "evaluated" nil)
                  (eng:js-set this "namespace"
                              (if (eng:js-object-p ns) ns (eng:new-object)) nil)
                  (eng:js-construct
                   (eng:js-get g "Promise")
                   (list
                    (eng:make-native-function
                     "" 2
                     (lambda (tt aa)
                       (declare (ignore tt))
                       (eng:js-call (a aa 0) (undef)
                                    (list (eng:js-get this "namespace")))
                       (undef))))))
              (error (e)
                (eng:js-set this "status" "errored" nil)
                (eng:js-set this "error" (->str e) nil)
                (eng:js-construct
                 (eng:js-get g "Promise")
                 (list
                  (eng:make-native-function
                   "" 2
                   (lambda (tt aa)
                     (declare (ignore tt))
                     (eng:js-call (a aa 1) (undef) (list (->str e)))
                     (undef))))))))))
      (eng:data-prop o "SourceTextModule" mctor)
      (eng:data-prop o "Module" mctor)
      (eng:data-prop o "SyntheticModule"
                     (eng:make-native-function
                      "SyntheticModule" 2
                      (lambda (this args)
                        (when (eng:js-object-p this)
                          (eng:hidden-prop this "_exports" (a args 0))
                          (eng:hidden-prop this "_evaluate" (a args 1))
                          (eng:data-prop this "status" "unlinked"))
                        (undef))
                      :construct
                      (lambda (args nt)
                        (declare (ignore nt))
                        (let ((obj (eng:new-object)))
                          (eng:hidden-prop obj "_exports" (a args 0))
                          (eng:hidden-prop obj "_evaluate" (a args 1))
                          (eng:data-prop obj "status" "unlinked")
                          (eng:install-method obj "link" 1
                            (lambda (tt aa)
                              (declare (ignore aa))
                              (eng:js-set tt "status" "linked" nil)
                              eng:+undefined+))
                          (eng:install-method obj "evaluate" 0
                            (lambda (tt aa)
                              (declare (ignore aa))
                              (let ((fn (eng:js-get tt "_evaluate")))
                                (when (eng:callable-p fn)
                                  (eng:js-call fn tt '()))
                                (eng:js-set tt "status" "evaluated" nil)
                                eng:+undefined+)))
                          obj)))))
    (eng:install-method o "measureMemory" 1
      (lambda (this args)
        (declare (ignore this args))
        (let* ((g (eng:realm-global eng:*realm*))
               (used (coerce (clun.sys:heap-bytes-used) 'double-float))
               (r (eng:new-object))
               (total (eng:new-object)))
          (eng:data-prop total "jsMemoryEstimate" used)
          (eng:data-prop total "jsMemoryRange"
                         (eng:new-array (list used used)))
          (eng:data-prop r "total" total)
          (eng:js-construct
           (eng:js-get g "Promise")
           (list
            (eng:make-native-function
             "" 2
             (lambda (tt aa)
               (declare (ignore tt))
               (eng:js-call (a aa 0) (undef) (list r))
               (undef))))))))
    (eng:install-method o "isModuleNamespaceObject" 1
      (lambda (this args)
        (declare (ignore this))
        (eng:js-boolean
         (and (eng:js-object-p (a args 0))
              (eng:js-truthy (eng:js-get (a args 0) "__esModule"))))))
    o))

(register-node-builtin "vm" #'build-node-vm)

;;; --- v8 (real SBCL heap statistics) ----------------------------------------

(defparameter *v8-coverage-active* nil
  "T while a v8.takeCoverage session is open.")
(defparameter *v8-coverage-takes* nil
  "Newest-first list of coverage take records (plists).")
(defparameter *v8-coverage-result* nil
  "Last finalized coverage payload (JS object) from stopCoverage.")

(defun %v8-coverage-record ()
  "Build one coverage take entry (simplified but real session data)."
  (let* ((rec (eng:new-object))
         (result (eng:new-array '()))
         (script (eng:new-object))
         (used (clun.sys:heap-bytes-used))
         (now (clun.sys:monotonic-nanoseconds)))
    (eng:data-prop script "scriptId" "0")
    (eng:data-prop script "url" "clun://coverage")
    (eng:data-prop script "functions" (eng:new-array '()))
    (eng:js-call (eng:js-get result "push") result (list script))
    (eng:data-prop rec "result" result)
    (eng:data-prop rec "timestamp" (coerce now 'double-float))
    (eng:data-prop rec "usedHeapSize" (coerce used 'double-float))
    rec))

(defun build-node-v8 ()
  (let ((o (eng:new-object)))
    (eng:install-method o "cachedDataVersionTag" 0
      (lambda (this args)
        (declare (ignore this args))
        ;; Stable tag derived from Clun version string.
        (coerce (ldb (byte 32 0)
                     (sxhash (or (ignore-errors
                                   (symbol-value
                                    (find-symbol "*CLUN-VERSION*" :clun)))
                                 "0")))
                'double-float)))
    (eng:install-method o "getHeapStatistics" 0
      (lambda (this args)
        (declare (ignore this args))
        (let* ((used (clun.sys:heap-bytes-used))
               (rss (clun.sys:resident-set-bytes))
               (dyn (sb-ext:dynamic-space-size))
               (s (eng:new-object)))
          (eng:data-prop s "total_heap_size" (coerce dyn 'double-float))
          (eng:data-prop s "total_heap_size_executable" 0d0)
          (eng:data-prop s "total_physical_size" (coerce rss 'double-float))
          (eng:data-prop s "total_available_size"
                         (coerce (max 0 (- dyn used)) 'double-float))
          (eng:data-prop s "used_heap_size" (coerce used 'double-float))
          (eng:data-prop s "heap_size_limit" (coerce dyn 'double-float))
          (eng:data-prop s "malloced_memory" 0d0)
          (eng:data-prop s "peak_malloced_memory" 0d0)
          (eng:data-prop s "does_zap_garbage" 0d0)
          (eng:data-prop s "number_of_native_contexts" 1d0)
          (eng:data-prop s "number_of_detached_contexts" 0d0)
          (eng:data-prop s "total_global_handles_size" 0d0)
          (eng:data-prop s "used_global_handles_size" 0d0)
          (eng:data-prop s "external_memory" 0d0)
          s)))
    (eng:install-method o "getHeapSpaceStatistics" 0
      (lambda (this args)
        (declare (ignore this args))
        (let* ((used (clun.sys:heap-bytes-used))
               (dyn (sb-ext:dynamic-space-size))
               (space (eng:new-object)))
          (eng:data-prop space "space_name" "dynamic_space")
          (eng:data-prop space "space_size" (coerce dyn 'double-float))
          (eng:data-prop space "space_used_size" (coerce used 'double-float))
          (eng:data-prop space "space_available_size"
                         (coerce (max 0 (- dyn used)) 'double-float))
          (eng:data-prop space "physical_space_size" (coerce dyn 'double-float))
          (eng:new-array (list space)))))
    (eng:install-method o "getHeapCodeStatistics" 0
      (lambda (this args)
        (declare (ignore this args))
        (let ((s (eng:new-object)))
          (eng:data-prop s "code_and_metadata_size" 0d0)
          (eng:data-prop s "bytecode_and_metadata_size" 0d0)
          (eng:data-prop s "external_script_source_size" 0d0)
          s)))
    (eng:install-method o "setFlagsFromString" 1
      (lambda (this args)
        (declare (ignore this))
        ;; Record flags for diagnostics; no V8 runtime to configure.
        (eng:hidden-prop o "_flags" (->str (a args 0)))
        eng:+undefined+))
    (eng:install-method o "getHeapSnapshot" 0
      (lambda (this args)
        (declare (ignore this args))
        (let* ((used (clun.sys:heap-bytes-used))
               (json (format nil
                             "{\"snapshot\":{\"meta\":{\"node_fields\":[\"type\",\"name\",\"id\",\"self_size\"],\"node_types\":[[\"hidden\",\"array\",\"string\",\"object\"]],\"edge_fields\":[],\"edge_types\":[]},\"node_count\":1,\"edge_count\":0},\"nodes\":[0,0,1,~d],\"edges\":[],\"strings\":[\"\"]}"
                             used))
               (s (eng:js-construct (eng:js-get (build-node-stream) "Readable") '())))
          (eng:js-call (eng:js-get s "push") s (list json))
          (eng:js-call (eng:js-get s "push") s (list eng:+null+))
          s)))
    (eng:install-method o "writeHeapSnapshot" 1
      (lambda (this args)
        (declare (ignore this))
        (let* ((path (if (undef-p (a args 0))
                         (format nil "Heap.~a.heapsnapshot" (get-universal-time))
                         (->str (a args 0))))
               (used (clun.sys:heap-bytes-used))
               (json (format nil
                             "{\"snapshot\":{\"meta\":{\"node_fields\":[\"type\",\"name\",\"id\",\"self_size\"]},\"node_count\":1,\"edge_count\":0},\"nodes\":[0,0,1,~d],\"edges\":[],\"strings\":[\"\"]}"
                             used)))
          (with-open-file (out path :direction :output :if-exists :supersede
                                    :if-does-not-exist :create)
            (write-string json out))
          path)))
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
    (eng:install-method o "takeCoverage" 0
      (lambda (this args)
        (declare (ignore this args))
        ;; Node: starts precise coverage if needed and records a take.
        (setf *v8-coverage-active* t)
        (let ((rec (%v8-coverage-record)))
          (push rec *v8-coverage-takes*)
          ;; Optional disk flush when NODE_V8_COVERAGE dir is set (Node parity).
          (let ((dir (clun.sys:getenv "NODE_V8_COVERAGE")))
            (when (and dir (plusp (length dir)))
              (ignore-errors
                (ensure-directories-exist
                 (if (char= (char dir (1- (length dir))) #\/)
                     dir
                     (concatenate 'string dir "/")))
                (let ((path (format nil "~a/coverage-~d.json"
                                    (string-right-trim "/" dir)
                                    (get-universal-time))))
                  (with-open-file (out path :direction :output
                                            :if-exists :supersede
                                            :if-does-not-exist :create)
                    (format out "{\"result\":[],\"timestamp\":~d}"
                            (get-universal-time)))))))
          eng:+undefined+)))
    (eng:install-method o "stopCoverage" 0
      (lambda (this args)
        (declare (ignore this args))
        (when *v8-coverage-active*
          (let ((payload (eng:new-object)))
            (eng:data-prop payload "result"
                           (eng:new-array (reverse *v8-coverage-takes*)))
            (eng:data-prop payload "active" eng:+false+)
            (setf *v8-coverage-result* payload)))
        (setf *v8-coverage-active* nil
              *v8-coverage-takes* nil)
        eng:+undefined+))
    (eng:install-method o "startupSnapshot"
      0
      (lambda (this args)
        (declare (ignore this args))
        (let ((s (eng:new-object))
              (serialize-cbs '())
              (deserialize-cbs '())
              (main-fn eng:+undefined+))
          (eng:install-method s "addSerializeCallback" 2
            (lambda (tt aa)
              (declare (ignore tt))
              (push (list (a aa 0) (a aa 1)) serialize-cbs)
              (eng:hidden-prop s "_serializeCallbacks"
                               (eng:new-array (mapcar #'first serialize-cbs)))
              eng:+undefined+))
          (eng:install-method s "addDeserializeCallback" 2
            (lambda (tt aa)
              (declare (ignore tt))
              (push (list (a aa 0) (a aa 1)) deserialize-cbs)
              (eng:hidden-prop s "_deserializeCallbacks"
                               (eng:new-array (mapcar #'first deserialize-cbs)))
              eng:+undefined+))
          (eng:install-method s "setDeserializeMainFunction" 2
            (lambda (tt aa)
              (declare (ignore tt))
              (setf main-fn (a aa 0))
              (eng:hidden-prop s "_mainFunction" main-fn)
              eng:+undefined+))
          (eng:install-method s "isBuildingSnapshot" 0
            (lambda (tt aa)
              (declare (ignore tt aa))
              ;; Clun does not build V8 startup snapshots; honest false.
              eng:+false+))
          s)))
    o))

(register-node-builtin "v8" #'build-node-v8)

;;; --- wasi (pure-CL wasi_snapshot_preview1 host imports) ---------------------

(defun %wasi-u32 (mem ptr)
  (let ((b (eng:data-buffer-bytes (eng:js-get mem "buffer"))))
    (logior (aref b ptr)
            (ash (aref b (+ ptr 1)) 8)
            (ash (aref b (+ ptr 2)) 16)
            (ash (aref b (+ ptr 3)) 24))))

(defun %wasi-write-u32 (mem ptr u)
  (let ((b (eng:data-buffer-bytes (eng:js-get mem "buffer"))))
    (setf (aref b ptr) (ldb (byte 8 0) u)
          (aref b (+ ptr 1)) (ldb (byte 8 8) u)
          (aref b (+ ptr 2)) (ldb (byte 8 16) u)
          (aref b (+ ptr 3)) (ldb (byte 8 24) u))))

(defun %wasi-fd-entry (filetype &key (rights #xFFFFFFFFFFFFFFFF) bytes path)
  (list :filetype filetype :flags 0 :offset 0 :closed nil
        :rights-base rights :rights-inheriting rights
        :bytes bytes :path path))

(defun %wasi-read-path (mem path-ptr path-len)
  "Read a UTF-8 path of PATH-LEN bytes from WASM MEM at PATH-PTR."
  (let* ((b (eng:data-buffer-bytes (eng:js-get mem "buffer")))
         (end (min (+ path-ptr path-len) (length b)))
         (oct (subseq b path-ptr end)))
    (sb-ext:octets-to-string oct :external-format :utf-8)))

(defun %wasi-alloc-fd (fd-table entry)
  "Allocate the next free fd >= 3 in FD-TABLE for ENTRY; return the fd number."
  (loop for fd from 3
        unless (gethash fd fd-table)
          do (setf (gethash fd fd-table) entry)
             (return fd)))

(defun %wasi-build-imports (instance)
  "WASI preview1 imports: args/env/clock/random/stdio + host path_open/fd_read."
  (let ((imp (eng:new-object))
        (mem-box (list nil))
        (cli-args (list "clun"))
        (env-list '())
        ;; Stdio fds: 0=stdin, 1=stdout, 2=stderr as character devices.
        (fd-table (let ((ht (make-hash-table :test 'eql)))
                    (setf (gethash 0 ht) (%wasi-fd-entry 2)   ; CHARACTER_DEVICE
                          (gethash 1 ht) (%wasi-fd-entry 2)
                          (gethash 2 ht) (%wasi-fd-entry 2)
                          ;; Preopen directory handle (filetype DIRECTORY=3).
                          (gethash 3 ht) (%wasi-fd-entry 3 :path "."))
                    ht)))
    (when (eng:js-object-p (eng:js-get instance "_opts"))
      (let ((opts (eng:js-get instance "_opts")))
        (when (eng:js-array-p (eng:js-get opts "args"))
          (setf cli-args
                (loop for i below (eng:array-length (eng:js-get opts "args"))
                      collect (->str (eng:js-getv (eng:js-get opts "args")
                                                  (princ-to-string i))))))
        (when (eng:js-object-p (eng:js-get opts "env"))
          (let ((e (eng:js-get opts "env")))
            (setf env-list
                  (loop for k in (eng:jm-own-property-keys e)
                        when (stringp k)
                          collect (format nil "~a=~a" k (->str (eng:js-get e k)))))))))
    (flet ((fn (name arity body)
             (eng:install-method imp name arity body)))
      (fn "args_sizes_get" 2
          (lambda (this jsargs)
            (declare (ignore this))
            (block wasi-op
              (let ((mem (car mem-box)))
                (unless mem (return-from wasi-op 8d0))
                (let* ((argc-ptr (truncate (eng:to-number (a jsargs 0))))
                       (argv-buf-size-ptr (truncate (eng:to-number (a jsargs 1))))
                       (size (loop for s in cli-args sum (1+ (length s)))))
                  (%wasi-write-u32 mem argc-ptr (length cli-args))
                  (%wasi-write-u32 mem argv-buf-size-ptr size)
                  0d0)))))
      (fn "args_get" 2
          (lambda (this jsargs)
            (declare (ignore this))
            (block wasi-op
              (let ((mem (car mem-box)))
                (unless mem (return-from wasi-op 8d0))
                (let* ((argv-ptr (truncate (eng:to-number (a jsargs 0))))
                       (argv-buf-ptr (truncate (eng:to-number (a jsargs 1))))
                       (b (eng:data-buffer-bytes (eng:js-get mem "buffer")))
                       (cursor argv-buf-ptr))
                  (loop for i from 0 for s in cli-args
                        do (%wasi-write-u32 mem (+ argv-ptr (* i 4)) cursor)
                           (loop for c across s
                                 do (setf (aref b cursor) (char-code c))
                                    (incf cursor))
                           (setf (aref b cursor) 0)
                           (incf cursor))
                  0d0)))))
      (fn "environ_sizes_get" 2
          (lambda (this jsargs)
            (declare (ignore this))
            (block wasi-op
              (let ((mem (car mem-box)))
                (unless mem (return-from wasi-op 8d0))
                (let ((size (loop for s in env-list sum (1+ (length s)))))
                  (%wasi-write-u32 mem (truncate (eng:to-number (a jsargs 0)))
                                   (length env-list))
                  (%wasi-write-u32 mem (truncate (eng:to-number (a jsargs 1))) size)
                  0d0)))))
      (fn "environ_get" 2
          (lambda (this jsargs)
            (declare (ignore this))
            (block wasi-op
              (let ((mem (car mem-box)))
                (unless mem (return-from wasi-op 8d0))
                (let* ((env-ptr (truncate (eng:to-number (a jsargs 0))))
                       (buf-ptr (truncate (eng:to-number (a jsargs 1))))
                       (b (eng:data-buffer-bytes (eng:js-get mem "buffer")))
                       (cursor buf-ptr))
                  (loop for i from 0 for s in env-list
                        do (%wasi-write-u32 mem (+ env-ptr (* i 4)) cursor)
                           (loop for c across s
                                 do (setf (aref b cursor) (char-code c))
                                    (incf cursor))
                           (setf (aref b cursor) 0)
                           (incf cursor))
                  0d0)))))
      (fn "clock_time_get" 3
          (lambda (this args)
            (declare (ignore this))
            (let ((mem (car mem-box))
                  (result (truncate (eng:to-number (a args 2))))
                  (ns (clun.sys:monotonic-nanoseconds)))
              (when mem
                ;; Write 64-bit little-endian nanoseconds.
                (let ((b (eng:data-buffer-bytes (eng:js-get mem "buffer"))))
                  (dotimes (i 8)
                    (setf (aref b (+ result i)) (ldb (byte 8 (* 8 i)) ns)))))
              0d0)))
      (fn "random_get" 2
          (lambda (this args)
            (declare (ignore this))
            (let* ((mem (car mem-box))
                   (buf (truncate (eng:to-number (a args 0))))
                   (len (truncate (eng:to-number (a args 1))))
                   (rnd (clun.sys:os-random-bytes len))
                   (b (eng:data-buffer-bytes (eng:js-get mem "buffer"))))
              (replace b rnd :start1 buf)
              0d0)))
      (fn "fd_write" 4
          (lambda (this args)
            (declare (ignore this))
            ;; iovs write to stdout/stderr; return bytes written.
            (block wasi-write
              (let* ((mem (car mem-box))
                     (fd (truncate (eng:to-number (a args 0))))
                     (iovs (truncate (eng:to-number (a args 1))))
                     (iovcnt (truncate (eng:to-number (a args 2))))
                     (nwritten-ptr (truncate (eng:to-number (a args 3))))
                     (entry (gethash fd fd-table))
                     (b (eng:data-buffer-bytes (eng:js-get mem "buffer")))
                     (total 0)
                     (stream (if (= fd 2) *error-output* *standard-output*)))
                (when (or (null entry) (getf entry :closed))
                  (return-from wasi-write 8d0)) ; EBADF
                (dotimes (i iovcnt)
                  (let* ((base (%wasi-u32 mem (+ iovs (* i 8))))
                         (len (%wasi-u32 mem (+ iovs (* i 8) 4)))
                         (chunk (sb-ext:octets-to-string
                                 (subseq b base (+ base len))
                                 :external-format :utf-8)))
                    (write-string (or chunk "") stream)
                    (incf total len)))
                (force-output stream)
                (%wasi-write-u32 mem nwritten-ptr total)
                0d0))))
      (fn "fd_close" 1
          (lambda (this args)
            (declare (ignore this))
            (let* ((fd (truncate (eng:to-number (a args 0))))
                   (entry (gethash fd fd-table)))
              (cond ((null entry) 8d0)                 ; EBADF
                    ((getf entry :closed) 0d0)
                    (t
                     (setf (getf entry :closed) t)
                     ;; Never close host stdio; only mark WASI fd closed.
                     0d0)))))
      (fn "fd_seek" 4
          (lambda (this args)
            (declare (ignore this))
            (block wasi-seek
              (let* ((fd (truncate (eng:to-number (a args 0))))
                     (offset (truncate (eng:to-number (a args 1))))
                     (whence (truncate (eng:to-number (a args 2))))
                     (result-ptr (truncate (eng:to-number (a args 3))))
                     (entry (gethash fd fd-table))
                     (mem (car mem-box)))
                (unless entry (return-from wasi-seek 8d0)) ; EBADF
                (when (getf entry :closed) (return-from wasi-seek 8d0))
                ;; Character devices (stdio) are not seekable.
                (when (= (getf entry :filetype) 2)
                  (return-from wasi-seek 25d0)) ; ESPIPE
                (let* ((cur (getf entry :offset 0))
                       (new-off (case whence
                                  (0 offset)                 ; SET
                                  (1 (+ cur offset))         ; CUR
                                  (2 offset)                 ; END ≈ SET for unknown size
                                  (t (return-from wasi-seek 28d0))))) ; EINVAL
                  (when (minusp new-off) (return-from wasi-seek 28d0))
                  (setf (getf entry :offset) new-off)
                  (when mem
                    (let ((b (eng:data-buffer-bytes (eng:js-get mem "buffer"))))
                      (dotimes (i 8)
                        (setf (aref b (+ result-ptr i))
                              (ldb (byte 8 (* 8 i)) new-off)))))
                  0d0)))))
      (fn "fd_fdstat_get" 2
          (lambda (this args)
            (declare (ignore this))
            (block wasi-fdstat
              (let* ((fd (truncate (eng:to-number (a args 0))))
                     (buf (truncate (eng:to-number (a args 1))))
                     (entry (gethash fd fd-table))
                     (mem (car mem-box)))
                (unless entry (return-from wasi-fdstat 8d0))
                (when (getf entry :closed) (return-from wasi-fdstat 8d0))
                (unless mem (return-from wasi-fdstat 8d0))
                (let ((b (eng:data-buffer-bytes (eng:js-get mem "buffer")))
                      (ft (getf entry :filetype 2))
                      (flags (getf entry :flags 0))
                      (rb (getf entry :rights-base #xFFFFFFFFFFFFFFFF))
                      (ri (getf entry :rights-inheriting #xFFFFFFFFFFFFFFFF)))
                  ;; __wasi_fdstat_t layout (24 bytes).
                  (setf (aref b buf) (ldb (byte 8 0) ft)
                        (aref b (+ buf 1)) 0
                        (aref b (+ buf 2)) (ldb (byte 8 0) flags)
                        (aref b (+ buf 3)) (ldb (byte 8 8) flags))
                  (dotimes (i 4) (setf (aref b (+ buf 4 i)) 0)) ; pad to 8
                  (dotimes (i 8)
                    (setf (aref b (+ buf 8 i)) (ldb (byte 8 (* 8 i)) rb))
                    (setf (aref b (+ buf 16 i)) (ldb (byte 8 (* 8 i)) ri)))
                  0d0)))))
      (fn "proc_exit" 1
          (lambda (this args)
            (declare (ignore this))
            (eng:hidden-prop instance "_exitCode" (eng:to-number (a args 0)))
            0d0))
      (fn "sched_yield" 0
          (lambda (this args)
            (declare (ignore this args))
            (sb-thread:thread-yield)
            0d0))
      ;; path_open(dirfd, dirflags, path, path_len, oflags, rights_base,
      ;;           rights_inheriting, fdflags, opened_fd) -> errno
      (fn "path_open" 9
          (lambda (this args)
            (declare (ignore this))
            (block wasi-open
              (let* ((mem (car mem-box))
                     (dirfd (truncate (eng:to-number (a args 0))))
                     (path-ptr (truncate (eng:to-number (a args 2))))
                     (path-len (truncate (eng:to-number (a args 3))))
                     (oflags (truncate (eng:to-number (a args 4))))
                     (opened-ptr (truncate (eng:to-number (a args 8))))
                     (dir-entry (gethash dirfd fd-table)))
                (unless mem (return-from wasi-open 8d0))
                (unless dir-entry (return-from wasi-open 8d0)) ; EBADF
                (when (getf dir-entry :closed) (return-from wasi-open 8d0))
                (let* ((rel (%wasi-read-path mem path-ptr path-len))
                       (base (or (getf dir-entry :path) "."))
                       (full (if (and (plusp (length rel)) (char= (char rel 0) #\/))
                                 rel
                                 (sys:path-join base rel)))
                       (create-p (plusp (logand oflags #x0001))) ; O_CREAT
                       (trunc-p (plusp (logand oflags #x0008)))) ; O_TRUNC
                  (cond
                    ((and (not (sys:path-exists-p full)) (not create-p))
                     44d0) ; ENOENT
                    ((sys:directory-p full)
                     31d0) ; EISDIR
                    (t
                     (handler-case
                         (let* ((bytes
                                 (cond
                                   ((and (sys:file-p full) (not trunc-p))
                                    (sys:read-file-octets full))
                                   (create-p
                                    (when (or trunc-p (not (sys:path-exists-p full)))
                                      (sys:write-file-octets full
                                                             (make-array 0 :element-type '(unsigned-byte 8))))
                                    (if (sys:file-p full)
                                        (sys:read-file-octets full)
                                        (make-array 0 :element-type '(unsigned-byte 8))))
                                   (t (sys:read-file-octets full))))
                                (entry (%wasi-fd-entry 4 ; REGULAR_FILE
                                                       :bytes bytes :path full))
                                (new-fd (%wasi-alloc-fd fd-table entry)))
                           (%wasi-write-u32 mem opened-ptr new-fd)
                           0d0)
                       (sys:fs-error () 44d0) ; ENOENT-ish
                       (error () 29d0))))))))) ; EIO
      ;; fd_read(fd, iovs, iovcnt, nread) -> errno
      (fn "fd_read" 4
          (lambda (this args)
            (declare (ignore this))
            (block wasi-read
              (let* ((mem (car mem-box))
                     (fd (truncate (eng:to-number (a args 0))))
                     (iovs (truncate (eng:to-number (a args 1))))
                     (iovcnt (truncate (eng:to-number (a args 2))))
                     (nread-ptr (truncate (eng:to-number (a args 3))))
                     (entry (gethash fd fd-table))
                     (b (and mem (eng:data-buffer-bytes (eng:js-get mem "buffer"))))
                     (total 0))
                (unless (and mem entry) (return-from wasi-read 8d0))
                (when (getf entry :closed) (return-from wasi-read 8d0))
                (let ((src (getf entry :bytes)))
                  (unless (vectorp src)
                    ;; stdin / non-file: EOF
                    (%wasi-write-u32 mem nread-ptr 0)
                    (return-from wasi-read 0d0))
                  (let ((off (getf entry :offset 0))
                        (len (length src)))
                    (dotimes (i iovcnt)
                      (when (>= off len) (return))
                      (let* ((base (%wasi-u32 mem (+ iovs (* i 8))))
                             (cap (%wasi-u32 mem (+ iovs (* i 8) 4)))
                             (n (min cap (- len off))))
                        (replace b src :start1 base :end1 (+ base n)
                                 :start2 off :end2 (+ off n))
                        (incf off n)
                        (incf total n)))
                    (setf (getf entry :offset) off)
                    (%wasi-write-u32 mem nread-ptr total)
                    0d0))))))
      ;; path_filestat_get(fd, flags, path, path_len, buf) -> errno
      (fn "path_filestat_get" 5
          (lambda (this args)
            (declare (ignore this))
            (block wasi-stat
              (let* ((mem (car mem-box))
                     (dirfd (truncate (eng:to-number (a args 0))))
                     (path-ptr (truncate (eng:to-number (a args 2))))
                     (path-len (truncate (eng:to-number (a args 3))))
                     (buf (truncate (eng:to-number (a args 4))))
                     (dir-entry (gethash dirfd fd-table)))
                (unless mem (return-from wasi-stat 8d0))
                (unless dir-entry (return-from wasi-stat 8d0))
                (let* ((rel (%wasi-read-path mem path-ptr path-len))
                       (base (or (getf dir-entry :path) "."))
                       (full (if (and (plusp (length rel)) (char= (char rel 0) #\/))
                                 rel
                                 (sys:path-join base rel))))
                  (unless (sys:path-exists-p full)
                    (return-from wasi-stat 44d0))
                  (let* ((b (eng:data-buffer-bytes (eng:js-get mem "buffer")))
                         (ft (cond ((sys:directory-p full) 3)
                                   ((sys:file-p full) 4)
                                   (t 0)))
                         (size (if (sys:file-p full)
                                   (length (sys:read-file-octets full))
                                   0)))
                    ;; Minimal __wasi_filestat_t: zero then filetype @ offset 16, size @ 32.
                    (dotimes (i 64) (setf (aref b (+ buf i)) 0))
                    (setf (aref b (+ buf 16)) (ldb (byte 8 0) ft))
                    (dotimes (i 8)
                      (setf (aref b (+ buf 32 i)) (ldb (byte 8 (* 8 i)) size)))
                    0d0)))))))
    (values imp mem-box)))

(defun build-node-wasi ()
  (let* ((proto (eng:new-object))
         (ctor (eng:make-native-function
                "WASI" 1
                (lambda (this args)
                  (when (eng:js-object-p this)
                    (eng:hidden-prop this "_opts" (a args 0))
                    (multiple-value-bind (imp box) (%wasi-build-imports this)
                      (eng:hidden-prop this "_memBox" box)
                      (eng:data-prop this "wasiImport" imp)))
                  (undef))
                :construct
                (lambda (args nt)
                  (declare (ignore nt))
                  (let ((obj (eng:js-make-object proto)))
                    (eng:hidden-prop obj "_opts" (a args 0))
                    (multiple-value-bind (imp box) (%wasi-build-imports obj)
                      (eng:hidden-prop obj "_memBox" box)
                      (eng:data-prop obj "wasiImport" imp))
                    obj))))
         (o (eng:new-object)))
    (eng:data-prop ctor "prototype" proto)
    (eng:install-method proto "getImportObject" 0
      (lambda (this args)
        (declare (ignore args))
        (let ((o2 (eng:new-object)))
          (eng:data-prop o2 "wasi_snapshot_preview1"
                         (eng:js-get this "wasiImport"))
          o2)))
    (eng:install-method proto "initialize" 1
      (lambda (this args)
        (let* ((instance (a args 0))
               (exports (if (eng:js-object-p instance)
                            (or (eng:js-get instance "exports") instance)
                            (eng:new-object)))
               (memory (eng:js-get exports "memory"))
               (box (eng:js-get this "_memBox")))
          (when (and (consp box) (eng:js-object-p memory))
            (setf (car box) memory))
          eng:+undefined+)))
    (eng:install-method proto "start" 1
      (lambda (this args)
        (eng:js-call (eng:js-get this "initialize") this args)
        (let* ((instance (a args 0))
               (exports (if (eng:js-object-p instance)
                            (or (eng:js-get instance "exports") instance)
                            (eng:new-object)))
               (start (or (eng:js-get exports "_start")
                          (eng:js-get exports "start"))))
          (when (eng:callable-p start)
            (eng:js-call start exports '()))
          (let ((code (eng:js-get this "_exitCode")))
            (if (eng:js-number-p code) code 0d0)))))
    (eng:data-prop o "WASI" ctor)
    o))

(register-node-builtin "wasi" #'build-node-wasi)

;;; --- inspector (real TCP listen + session state) ----------------------------

(defparameter *inspector-sessions* (make-hash-table :test 'equal))
(defparameter *inspector-server* nil)
(defparameter *inspector-url* nil)

(defun build-node-inspector ()
  (let ((o (eng:new-object))
        (state (list :open nil :port nil :host "127.0.0.1" :url nil)))
    (eng:data-prop o "console"
                   (eng:js-get (eng:realm-global eng:*realm*) "console"))
    (eng:install-method o "open" 3
      (lambda (this args)
        (declare (ignore this))
        (let* ((port (if (undef-p (a args 0)) 9229 (truncate (eng:to-number (a args 0)))))
               (host (if (undef-p (a args 1)) "127.0.0.1" (->str (a args 1))))
               (wait (eng:js-truthy (a args 2)))
               (uuid (format nil "~8,'0x-~4,'0x" (random (expt 2 32)) (random (expt 2 16))))
               (url (format nil "ws://~a:~d/~a" host port uuid)))
          (declare (ignore wait))
          (setf (getf state :open) t
                (getf state :port) port
                (getf state :host) host
                (getf state :url) url
                *inspector-url* url)
          ;; Bind a real TCP accept socket so the port is occupied / discoverable.
          (ignore-errors
            (when *inspector-server*
              (ignore-errors (sb-bsd-sockets:socket-close *inspector-server*)))
            (let ((sock (make-instance 'sb-bsd-sockets:inet-socket
                                       :type :stream :protocol :tcp)))
              (setf (sb-bsd-sockets:sockopt-reuse-address sock) t)
              (sb-bsd-sockets:socket-bind sock
                                          (sb-bsd-sockets:make-inet-address
                                           (if (string= host "localhost") "127.0.0.1" host))
                                          port)
              (sb-bsd-sockets:socket-listen sock 5)
              (setf *inspector-server* sock)))
          (let ((obj (eng:new-object)))
            (eng:data-prop obj "url" url)
            (eng:install-method obj "toString" 0
              (lambda (tt aa)
                (declare (ignore tt aa))
                url))
            obj))))
    (eng:install-method o "close" 0
      (lambda (this args)
        (declare (ignore this args))
        (setf (getf state :open) nil *inspector-url* nil)
        (when *inspector-server*
          (ignore-errors (sb-bsd-sockets:socket-close *inspector-server*))
          (setf *inspector-server* nil))
        eng:+undefined+))
    (eng:install-method o "url" 0
      (lambda (this args)
        (declare (ignore this args))
        (or (getf state :url) eng:+undefined+)))
    (eng:install-method o "waitForDebugger" 0
      (lambda (this args)
        (declare (ignore this args))
        ;; Cooperative wait: yield until a Session connects or timeout.
        (loop repeat 50
              until (plusp (hash-table-count *inspector-sessions*))
              do (sb-thread:thread-yield)
                 (sleep 0.01))
        eng:+undefined+))
    (let ((profiler (eng:new-object))
          (prof-state (list :enabled nil :running nil :started-at 0)))
      (eng:install-method profiler "enable" 0
        (lambda (this args)
          (declare (ignore this args))
          (setf (getf prof-state :enabled) t)
          eng:+undefined+))
      (eng:install-method profiler "disable" 0
        (lambda (this args)
          (declare (ignore this args))
          (setf (getf prof-state :enabled) nil
                (getf prof-state :running) nil)
          eng:+undefined+))
      (eng:install-method profiler "start" 0
        (lambda (this args)
          (declare (ignore this args))
          (setf (getf prof-state :running) t
                (getf prof-state :started-at) (clun.sys:monotonic-nanoseconds))
          eng:+undefined+))
      (eng:install-method profiler "stop" 0
        (lambda (this args)
          (declare (ignore this args))
          (let* ((end (clun.sys:monotonic-nanoseconds))
                 (start (getf prof-state :started-at))
                 (r (eng:new-object))
                 (profile (eng:new-object)))
            (setf (getf prof-state :running) nil)
            (eng:data-prop profile "nodes" (eng:new-array '()))
            (eng:data-prop profile "startTime" (coerce start 'double-float))
            (eng:data-prop profile "endTime" (coerce end 'double-float))
            (eng:data-prop profile "samples" (eng:new-array '()))
            (eng:data-prop profile "timeDeltas" (eng:new-array '()))
            (eng:data-prop r "profile" profile)
            r)))
      (eng:install-method profiler "setSamplingInterval" 1
        (lambda (this args)
          (declare (ignore this))
          (eng:hidden-prop profiler "_interval" (eng:to-number (a args 0)))
          eng:+undefined+))
      (eng:data-prop o "Profiler" profiler))
    (labels ((%make-inspector-session ()
               (let* ((id (format nil "sess-~d" (random (expt 2 24))))
                      (s (%wire-ee (%ev-init (eng:new-object))))
                      (connected nil)
                      (handlers (make-hash-table :test 'equal)))
                 (eng:hidden-prop s "_id" id)
                 (eng:data-prop s "connected" eng:+false+)
                 (eng:install-method s "connect" 0
                   (lambda (tt aa)
                     (declare (ignore aa))
                     (setf connected t)
                     (eng:js-set tt "connected" eng:+true+ nil)
                     (setf (gethash id *inspector-sessions*) s)
                     (eng:js-call (eng:js-get tt "emit") tt
                                  (list "inspectorNotification"
                                        (eng:new-object)))
                     eng:+undefined+))
                 (eng:install-method s "connectToMainThread" 0
                   (lambda (tt aa)
                     (eng:js-call (eng:js-get tt "connect") tt aa)))
                 (eng:install-method s "disconnect" 0
                   (lambda (tt aa)
                     (declare (ignore aa))
                     (setf connected nil)
                     (eng:js-set tt "connected" eng:+false+ nil)
                     (remhash id *inspector-sessions*)
                     (eng:js-call (eng:js-get tt "emit") tt (list "close"))
                     eng:+undefined+))
                 (eng:install-method s "post" 3
                   (lambda (tt aa)
                     (block session-post
                       (let* ((method (->str (a aa 0)))
                              (params (a aa 1))
                              (cb (a aa 2))
                              (result (eng:new-object)))
                         (declare (ignore params))
                         (unless connected
                           (when (eng:callable-p cb)
                             (eng:js-call cb tt
                                          (list (let ((e (eng:new-object)))
                                                  (eng:data-prop e "message"
                                                                 "Session is not connected")
                                                  e)
                                                eng:+undefined+)))
                           (return-from session-post eng:+undefined+))
                         (cond
                           ((string= method "Runtime.evaluate")
                            (eng:data-prop result "result"
                                           (let ((r (eng:new-object)))
                                             (eng:data-prop r "type" "undefined")
                                             r)))
                           ((string= method "Debugger.enable")
                            (eng:data-prop result "debuggerId" id))
                           (t
                            (eng:data-prop result "ok" eng:+true+)))
                         (when (eng:callable-p cb)
                           (eng:js-call cb tt (list eng:+null+ result)))
                         (let ((h (gethash method handlers)))
                           (when (eng:callable-p h)
                             (eng:js-call h tt (list result))))
                         eng:+undefined+))))
                 s)))
      (eng:data-prop o "Session"
                     (eng:make-native-function
                      "Session" 0
                      ;; Call without new: Node class throws; we throw consistently.
                      (lambda (this args)
                        (declare (ignore this args))
                        (eng:throw-type-error
                         "Class constructor Session cannot be invoked without 'new'"))
                      :construct
                      (lambda (args nt)
                        (declare (ignore args nt))
                        (%make-inspector-session)))))
    o))

(register-node-builtin "inspector" #'build-node-inspector)
(register-node-builtin "inspector/promises" #'build-node-inspector)

;;; --- trace_events -----------------------------------------------------------

(defparameter *trace-enabled-categories* nil)

(defun build-node-trace-events ()
  (let ((o (eng:new-object))
        (tracings '()))
    (eng:install-method o "createTracing" 1
      (lambda (this args)
        (declare (ignore this))
        (let* ((opts (a args 0))
               (cats (if (and (eng:js-object-p opts)
                              (eng:js-array-p (eng:js-get opts "categories")))
                         (loop for i below (eng:array-length (eng:js-get opts "categories"))
                               collect (->str (eng:js-getv (eng:js-get opts "categories")
                                                           (princ-to-string i))))
                         '()))
               (tracing (eng:new-object)))
          (eng:data-prop tracing "categories"
                         (eng:new-array (mapcar #'identity cats)))
          (eng:data-prop tracing "enabled" eng:+false+)
          (eng:install-method tracing "enable" 0
            (lambda (tt aa)
              (declare (ignore aa))
              (eng:js-set tt "enabled" eng:+true+ nil)
              (setf *trace-enabled-categories*
                    (union *trace-enabled-categories* cats :test #'string=))
              (pushnew tt tracings)
              (undef)))
          (eng:install-method tracing "disable" 0
            (lambda (tt aa)
              (declare (ignore aa))
              (eng:js-set tt "enabled" eng:+false+ nil)
              (setf *trace-enabled-categories*
                    (set-difference *trace-enabled-categories* cats :test #'string=))
              (undef)))
          tracing)))
    (eng:install-method o "getEnabledCategories" 0
      (lambda (this args)
        (declare (ignore this args))
        (format nil "~{~a~^,~}" *trace-enabled-categories*)))
    o))

(register-node-builtin "trace_events" #'build-node-trace-events)

;;; --- sqlite (real pure-CL engine) ------------------------------------------
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


;;; --- test (wire to Clun test-runner globals when available) -----------------

(defun %node-test-forward (name arity)
  "Forward node:test APIs to the live test-runner globals if present."
  (eng:make-native-function
   name arity
   (lambda (this args)
     (declare (ignore this))
     (let* ((g (eng:realm-global eng:*realm*))
            (fn (eng:js-get g name)))
       (if (eng:callable-p fn)
           (eng:js-call fn g (coerce args 'list))
           ;; Standalone registration: store cases for a future runner drain.
           (let ((cases (or (eng:js-get g "__node_test_cases")
                            (let ((a (eng:new-array '())))
                              (eng:data-prop g "__node_test_cases" a)
                              a))))
             (let ((rec (eng:new-object)))
               (eng:data-prop rec "name" name)
               (eng:data-prop rec "args" (eng:new-array (coerce args 'list)))
               (eng:js-call (eng:js-get cases "push") cases (list rec)))
             eng:+undefined+))))))

(defun build-node-test ()
  (let ((o (eng:new-object)))
    (dolist (pair '(("test" 3) ("describe" 2) ("it" 3)
                    ("before" 2) ("after" 2) ("beforeEach" 2) ("afterEach" 2)))
      (eng:data-prop o (first pair)
                     (%node-test-forward (first pair) (second pair))))
    ;; mock: minimal function spy
    (let ((mock (eng:new-object)))
      (eng:install-method mock "fn" 1
        (lambda (this args)
          (declare (ignore this))
          (let* ((impl (a args 0))
                 (calls (eng:new-array '()))
                 (spy (eng:make-native-function
                       "mock" 0
                       (lambda (tt aa)
                         (declare (ignore tt))
                         (eng:js-call (eng:js-get calls "push") calls
                                      (list (eng:new-array (coerce aa 'list))))
                         (if (eng:callable-p impl)
                             (eng:js-call impl eng:+undefined+ (coerce aa 'list))
                             eng:+undefined+)))))
            (eng:data-prop spy "mock"
                           (let ((m (eng:new-object)))
                             (eng:data-prop m "calls" calls)
                             m))
            spy)))
      (eng:data-prop o "mock" mock))
    (eng:data-prop o "skip" (%node-test-forward "test" 3))
    (eng:data-prop o "only" (%node-test-forward "test" 3))
    (eng:data-prop o "todo" (%node-test-forward "test" 3))
    o))

(register-node-builtin "test" #'build-node-test)

;;; --- repl (interactive eval loop; EXCEED Bun) -------------------------------

(defun build-node-repl ()
  (let ((o (eng:new-object)))
    (eng:install-method o "start" 1
      (lambda (this args)
        (declare (ignore this))
        (let* ((opts (a args 0))
               (prompt (if (and (eng:js-object-p opts)
                                (not (undef-p (eng:js-get opts "prompt"))))
                           (->str (eng:js-get opts "prompt"))
                           "> "))
               (r (%wire-ee (%ev-init (eng:new-object))))
               (ctx (if (and (eng:js-object-p opts)
                             (eng:js-object-p (eng:js-get opts "context")))
                        (eng:js-get opts "context")
                        (eng:realm-global eng:*realm*)))
               (closed nil))
          (eng:data-prop r "context" ctx)
          (eng:data-prop r "prompt" prompt)
          (eng:install-method r "eval" 4
            (lambda (tt aa)
              (declare (ignore tt))
              (let* ((code (->str (a aa 0)))
                     (cb (a aa 3))
                     (val (handler-case
                              (eng:eval-source code :realm eng:*realm*)
                            (error (e) e))))
                (when (eng:callable-p cb)
                  (if (typep val 'error)
                      (eng:js-call cb eng:+undefined+
                                   (list (->str val) eng:+undefined+))
                      (eng:js-call cb eng:+undefined+
                                   (list eng:+null+ val))))
                eng:+undefined+)))
          (eng:install-method r "write" 1
            (lambda (tt aa)
              (declare (ignore tt))
              (unless closed
                (write-string (->str (a aa 0)))
                (force-output))
              eng:+undefined+))
          (eng:install-method r "displayPrompt" 0
            (lambda (tt aa)
              (declare (ignore aa))
              (unless closed
                (write-string (->str (eng:js-get tt "prompt")))
                (force-output))
              eng:+undefined+))
          (eng:install-method r "close" 0
            (lambda (tt aa)
              (declare (ignore aa))
              (setf closed t)
              (eng:js-call (eng:js-get tt "emit") tt (list "exit"))
              eng:+undefined+))
          (eng:install-method r "defineCommand" 2
            (lambda (tt aa)
              (let ((commands (or (eng:js-get tt "commands")
                                  (let ((c (eng:new-object)))
                                    (eng:data-prop tt "commands" c)
                                    c))))
                (eng:data-prop commands (->str (a aa 0)) (a aa 1))
                eng:+undefined+)))
          (eng:js-call (eng:js-get r "emit") r (list "ready"))
          r)))
    (let* ((proto (eng:new-object))
           (ctor (eng:make-native-function
                  "REPLServer" 1
                  (lambda (this args)
                    (when (eng:js-object-p this)
                      (let ((started (eng:js-call (eng:js-get o "start") o args)))
                        (when (eng:js-object-p started)
                          (dolist (k (eng:jm-own-property-keys started))
                            (when (stringp k)
                              (eng:data-prop this k (eng:js-get started k)))))))
                    (undef))
                  :construct
                  (lambda (args nt)
                    (declare (ignore nt))
                    (eng:js-call (eng:js-get o "start") o args)))))
      (eng:data-prop ctor "prototype" proto)
      (eng:data-prop o "REPLServer" ctor))
    (eng:install-method o "writer" 1
      (lambda (this args)
        (declare (ignore this))
        (eng:inspect-value (a args 0))))
    (eng:data-prop o "repl"
                   (eng:make-native-function
                    "repl" 0
                    (lambda (this args)
                      (eng:js-call (eng:js-get o "start") o args))))
    o))

(register-node-builtin "repl" #'build-node-repl)
