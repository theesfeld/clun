;;;; module.lisp — node:module pure-CL.
;;;; builtinModules / isBuiltin / createRequire / Module / syncBuiltinESMExports /
;;;; register (via existing plugin hooks — exceeds Bun, which lacks module.register).

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
         (lambda (this args) (declare (ignore this args)) eng:+undefined+))
      (m "register" 2
         (lambda (this args) (declare (ignore this))
           ;; Exceed Bun: honor node:module register via Clun.plugin / hooks.
           (let ((specifier (a args 0)))
             (when (eng:js-object-p specifier)
               (let ((resolve (eng:js-get specifier "resolve"))
                     (load (eng:js-get specifier "load")))
                 (eng:register-node-module-hooks
                  :resolve (when (eng:callable-p resolve) resolve)
                  :load (when (eng:callable-p load) load))))
             (undef))))
      (m "registerHooks" 1
         (lambda (this args) (declare (ignore this))
           (let ((hooks (a args 0)))
             (when (eng:js-object-p hooks)
               (eng:register-node-module-hooks
                :resolve (let ((r (eng:js-get hooks "resolve")))
                           (when (eng:callable-p r) r))
                :load (let ((l (eng:js-get hooks "load")))
                        (when (eng:callable-p l) l))))
             (undef))))
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
