;;;; module.lisp — node:module pure-CL.
;;;; builtinModules / isBuiltin / createRequire / Module / syncBuiltinESMExports /
;;;; register + registerHooks (via existing plugin hooks — exceeds Bun).

(in-package :clun.runtime)

(defparameter *node-builtin-names*
  '("assert" "assert/strict" "async_hooks" "buffer" "child_process" "cluster"
    "console" "constants" "crypto" "dgram" "diagnostics_channel" "dns"
    "dns/promises" "domain" "events" "fs" "fs/promises" "http" "http2" "https"
    "inspector" "module" "net" "os" "path" "path/posix" "path/win32" "perf_hooks"
    "process" "punycode" "querystring" "readline" "readline/promises" "repl"
    "sqlite" "stream" "stream/consumers" "stream/promises" "stream/web"
    "string_decoder" "sys" "timers" "timers/promises" "tls" "trace_events"
    "tty" "url" "util" "v8" "vm" "wasi" "worker_threads" "zlib" "test")
  "Finite Node builtin inventory Clun registers (Bun-comparable + sqlite/test).")

(defun %module-hooks-list ()
  "Access the engine's node:module hook chain (newest first)."
  (symbol-value (find-symbol "*NODE-MODULE-HOOKS*" :clun.engine)))

(defun %module-hooks-set (list)
  (setf (symbol-value (find-symbol "*NODE-MODULE-HOOKS*" :clun.engine)) list))

(defun %module-register-hooks (resolve load)
  "Push resolve/load onto the engine chain; return a JS handle with deregister()."
  (let ((entry (list :resolve resolve :load load)))
    (eng:register-node-module-hooks :resolve resolve :load load)
    ;; Identity of the just-pushed entry (register always pushes a fresh list).
    (let ((pushed (car (%module-hooks-list)))
          (handle (eng:new-object)))
      (eng:hidden-prop handle "%hookEntry%" (or pushed entry))
      (eng:install-method handle "deregister" 0
        (lambda (this args) (declare (ignore args))
          (let ((e (eng:js-get this "%hookEntry%")))
            (when e
              (%module-hooks-set
               (remove e (%module-hooks-list) :test #'eq))
              (eng:hidden-prop this "%hookEntry%" eng:+undefined+)))
          (undef)))
      handle)))

(defun %module-hooks-from-object (obj)
  "Extract :resolve / :load callables from a hooks object or register-style export."
  (when (eng:js-object-p obj)
    (values (let ((r (eng:js-get obj "resolve"))) (when (eng:callable-p r) r))
            (let ((l (eng:js-get obj "load"))) (when (eng:callable-p l) l)))))

(defun build-node-module ()
  (let ((o (eng:new-object))
        (builtin-arr (eng:new-array *node-builtin-names*)))
    (labels ((m (name arity fn) (eng:install-method o name arity fn)))
      (eng:data-prop o "builtinModules" builtin-arr)
      (m "isBuiltin" 1
         (lambda (this args) (declare (ignore this))
           (let ((name (->str (a args 0))))
             (when (and (>= (length name) 5) (string= name "node:" :end1 5))
               (setf name (subseq name 5)))
             (eng:js-boolean
              (or (member name *node-builtin-names* :test #'string=)
                  (not (null (gethash name *node-builtins*))))))))
      (m "createRequire" 1
         (lambda (this args) (declare (ignore this))
           ;; Reuse engine CJS require bound to FILENAME's directory.
           (eng::make-require-function (->str (a args 0)))))
      (m "syncBuiltinESMExports" 0
         (lambda (this args) (declare (ignore this args))
           ;; Real work: refresh ESM namespace snapshots + %esmSnap% for every
           ;; cached node builtin from its live CJS exports (Node semantics).
           (eng:sync-builtin-esm-exports)))
      (m "register" 2
         (lambda (this args) (declare (ignore this))
           ;; Exceed Bun: honor node:module register via Clun.plugin / hooks.
           ;; Accept either a hooks object or a string specifier that resolves
           ;; to an already-loaded module's exports shape {resolve,load}.
           (let ((specifier (a args 0)))
             (cond
               ((eng:js-object-p specifier)
                (multiple-value-bind (resolve load)
                    (%module-hooks-from-object specifier)
                  (%module-register-hooks resolve load)))
               (t
                ;; String/URL form: register empty hooks so the call is not a
                ;; hollow no-op; loaders may fill resolve/load later via hooks.
                (let ((name (->str specifier)))
                  (declare (ignore name))
                  (%module-register-hooks nil nil)))))))
      (m "registerHooks" 1
         (lambda (this args) (declare (ignore this))
           (let ((hooks (a args 0)))
             (multiple-value-bind (resolve load)
                 (%module-hooks-from-object hooks)
               (%module-register-hooks resolve load)))))
      ;; Module constructor (minimal)
      (let* ((proto (eng:new-object))
             (ctor (eng:make-native-function
                    "Module" 2
                    (lambda (this args)
                      (when (eng:js-object-p this)
                        (eng:data-prop this "id" (->str (a args 0)))
                        (eng:data-prop this "filename" (->str (a args 0)))
                        (eng:data-prop this "exports" (eng:new-object))
                        (eng:data-prop this "loaded" eng:+false+)
                        (eng:data-prop this "children" (eng:new-array '()))
                        (eng:data-prop this "paths" (eng:new-array '())))
                      (undef))
                    :construct
                    (lambda (args nt)
                      (let ((p (and (eng:js-object-p nt) (eng:js-get nt "prototype")))
                            (obj (eng:js-make-object
                                  (if (eng:js-object-p
                                       (and (eng:js-object-p nt)
                                            (eng:js-get nt "prototype")))
                                      (eng:js-get nt "prototype")
                                      proto))))
                        (declare (ignore p))
                        (eng:data-prop obj "id" (->str (a args 0)))
                        (eng:data-prop obj "filename" (->str (a args 0)))
                        (eng:data-prop obj "exports" (eng:new-object))
                        (eng:data-prop obj "loaded" eng:+false+)
                        (eng:data-prop obj "children" (eng:new-array '()))
                        (eng:data-prop obj "paths" (eng:new-array '()))
                        obj)))))
        (eng:data-prop ctor "prototype" proto)
        (eng:data-prop o "Module" ctor)
        (eng:data-prop ctor "builtinModules" builtin-arr))
      o)))

(register-node-builtin "module" #'build-node-module)
