;;;; clun-plugin.lisp — Clun.plugin (Bun.plugin) + node:module hooks (Issue #187).
;;;;
;;;; Pure-CL host; user setup() is JS. Surface meets/exceeds Bun.plugin:
;;;; onResolve, onLoad, onStart, onEnd, module(), clearAll, plus list/clear(name)
;;;; priority, and node:module-style registerHooks.

(in-package :clun.runtime)

(defun %plugin-type-error (message)
  (eng:throw-type-error message))

(defun %plugin-js-string (value)
  (and (eng:js-string-p value) value))

(defun %plugin-read-string (obj key &optional default)
  (let ((v (eng:js-get obj key)))
    (cond
      ((eng:js-undefined-p v) default)
      ((eng:js-null-p v) default)
      ((eng:js-string-p v) v)
      (t (eng:to-string v)))))

(defun %plugin-read-number (obj key &optional (default 0))
  (let ((v (eng:js-get obj key)))
    (cond
      ((eng:js-undefined-p v) default)
      ((eng:js-null-p v) default)
      (t (let ((n (eng:to-number v)))
           (if (eng:js-nan-p n) default (truncate n)))))))

(defun %plugin-constraints (constraints-obj)
  "Extract filter + namespace + chain from a JS constraints object."
  (unless (eng:js-object-p constraints-obj)
    (%plugin-type-error "plugin constraints must be an object"))
  (let* ((filter (eng:js-get constraints-obj "filter"))
         (ns (eng:js-get constraints-obj "namespace"))
         (chain (eng:js-get constraints-obj "chain")))
    (when (or (eng:js-undefined-p filter) (eng:js-null-p filter))
      (%plugin-type-error "plugin filter is required"))
    (list :filter filter
          :namespace (if (or (eng:js-undefined-p ns) (eng:js-null-p ns))
                         nil
                         (eng:to-string ns))
          :chain (and (not (eng:js-undefined-p chain))
                      (not (eng:js-null-p chain))
                      (eng:js-truthy chain)))))

(defun %plugin-wrap-resolve-callback (js-fn)
  (lambda (&key path importer namespace kind)
    (declare (ignore kind))
    (let ((args (eng:new-object)))
      (eng:data-prop args "path" path)
      (eng:data-prop args "importer" (or importer ""))
      (eng:data-prop args "namespace" (or namespace "file"))
      (eng:data-prop args "kind" "import")
      (eng:js-call js-fn eng:+undefined+ (list args)))))

(defun %plugin-wrap-load-callback (js-fn)
  (lambda (&key path namespace loader defer plugin-data)
    (let ((args (eng:new-object)))
      (eng:data-prop args "path" path)
      (eng:data-prop args "namespace" (or namespace "file"))
      (eng:data-prop args "loader" (or loader "js"))
      (when plugin-data
        (eng:data-prop args "pluginData" plugin-data))
      (eng:data-prop
       args "defer"
       (eng:make-native-function
        "defer" 0
        (lambda (this args)
          (declare (ignore this args))
          (funcall defer))))
      (eng:js-call js-fn eng:+undefined+ (list args)))))

(defun %plugin-wrap-module-callback (js-fn)
  (lambda (&key)
    (eng:js-call js-fn eng:+undefined+ '())))

(defun %plugin-wrap-start-callback (js-fn)
  (lambda (&key)
    (eng:js-call js-fn eng:+undefined+ '())))

(defun %make-plugin-builder (entry)
  "JS PluginBuilder object bound to ENTRY."
  (let ((builder (eng:new-object))
        (config (eng:new-object)))
    (eng:data-prop config "plugins" (eng:new-array '()))
    (eng:data-prop builder "config" config)
    (eng:install-method builder "onResolve" 2
      (lambda (this args)
        (declare (ignore this))
        (let* ((constraints (%plugin-constraints (eng:arg args 0)))
               (cb (eng:arg args 1)))
          (unless (eng:callable-p cb)
            (%plugin-type-error "onResolve callback must be a function"))
          (setf (eng::pe-on-resolve entry)
                (append (eng::pe-on-resolve entry)
                        (list (eng::make-resolve-hook
                               :filter (getf constraints :filter)
                               :namespace (getf constraints :namespace)
                               :callback (%plugin-wrap-resolve-callback cb)
                               :chain (getf constraints :chain)
                               :plugin-name (eng::pe-name entry)))))
          (incf eng::*plugin-resolve-generation*)
          builder)))
    (eng:install-method builder "onLoad" 2
      (lambda (this args)
        (declare (ignore this))
        (let* ((constraints (%plugin-constraints (eng:arg args 0)))
               (cb (eng:arg args 1)))
          (unless (eng:callable-p cb)
            (%plugin-type-error "onLoad callback must be a function"))
          (setf (eng::pe-on-load entry)
                (append (eng::pe-on-load entry)
                        (list (eng::make-load-hook
                               :filter (getf constraints :filter)
                               :namespace (getf constraints :namespace)
                               :callback (%plugin-wrap-load-callback cb)
                               :plugin-name (eng::pe-name entry)))))
          builder)))
    (eng:install-method builder "onStart" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((cb (eng:arg args 0)))
          (unless (eng:callable-p cb)
            (%plugin-type-error "onStart callback must be a function"))
          (setf (eng::pe-on-start entry)
                (append (eng::pe-on-start entry)
                        (list (%plugin-wrap-start-callback cb))))
          builder)))
    (eng:install-method builder "onEnd" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((cb (eng:arg args 0)))
          (unless (eng:callable-p cb)
            (%plugin-type-error "onEnd callback must be a function"))
          (setf (eng::pe-on-end entry)
                (append (eng::pe-on-end entry)
                        (list (%plugin-wrap-start-callback cb))))
          builder)))
    (eng:install-method builder "module" 2
      (lambda (this args)
        (declare (ignore this))
        (let ((spec (eng:to-string (eng:arg args 0)))
              (cb (eng:arg args 1)))
          (unless (eng:callable-p cb)
            (%plugin-type-error "module callback must be a function"))
          (setf (eng::pe-virtuals entry)
                (append (eng::pe-virtuals entry)
                        (list (cons spec (%plugin-wrap-module-callback cb)))))
          builder)))
    (eng:install-method builder "onBeforeParse" 2
      (lambda (this args)
        (declare (ignore this args))
        ;; Accepted for API surface; native parse hooks are no-ops in pure CL host.
        builder))
    builder))

(defun %register-js-plugin (options)
  "Bun.plugin(options) — options.name + options.setup(builder)."
  (unless (eng:js-object-p options)
    (%plugin-type-error "Bun.plugin() expects an object with name and setup"))
  (let* ((name (or (%plugin-js-string (eng:js-get options "name"))
                   (let ((v (eng:js-get options "name")))
                     (if (or (eng:js-undefined-p v) (eng:js-null-p v))
                         "plugin"
                         (eng:to-string v)))))
         (setup (eng:js-get options "setup"))
         (priority (%plugin-read-number options "priority" 0))
         (entry (eng::make-plugin-entry* :name name :priority priority)))
    (unless (eng:callable-p setup)
      (%plugin-type-error "plugin.setup must be a function"))
    (let ((builder (%make-plugin-builder entry)))
      (eng:js-call setup eng:+undefined+ (list builder))
      (eng::register-plugin-entry entry)
      ;; onStart fires at registration for runtime plugins (Bun runtime behavior).
      (dolist (cb (eng::pe-on-start entry))
        (eng::plugin-call-sync cb nil))
      options)))

(defun %make-plugin-api ()
  "Callable Clun.plugin with clearAll / clear / list."
  (let ((api (eng:make-native-function
              "plugin" 1
              (lambda (this args)
                (declare (ignore this))
                (%register-js-plugin (eng:arg args 0))))))
    (eng:data-prop
     api "clearAll"
     (eng:make-native-function
      "clearAll" 0
      (lambda (this args)
        (declare (ignore this args))
        (eng:plugin-clear-all)
        eng:+undefined+)))
    (eng:data-prop
     api "clear"
     (eng:make-native-function
      "clear" 1
      (lambda (this args)
        (declare (ignore this))
        (eng:plugin-clear (eng:to-string (eng:arg args 0)))
        eng:+undefined+)))
    (eng:data-prop
     api "list"
     (eng:make-native-function
      "list" 0
      (lambda (this args)
        (declare (ignore this args))
        (eng:new-array (eng:plugin-list-names)))))
    (eng:data-prop
     api "registerHooks"
     (eng:make-native-function
      "registerHooks" 1
      (lambda (this args)
        (declare (ignore this))
        (%register-module-hooks (eng:arg args 0)))))
    api))

(defun %register-module-hooks (hooks-obj)
  "node:module-style { resolve, load } sync hooks (exceed / Deno parity)."
  (unless (eng:js-object-p hooks-obj)
    (%plugin-type-error "registerHooks expects an object"))
  (let* ((resolve-fn (eng:js-get hooks-obj "resolve"))
         (load-fn (eng:js-get hooks-obj "load"))
         (resolve-cb
          (when (eng:callable-p resolve-fn)
            (lambda (&key specifier context next)
              (declare (ignore next))
              (let ((ctx (eng:new-object)))
                (eng:data-prop ctx "parentURL"
                               (or (getf context :parent-url) ""))
                (eng:js-call resolve-fn eng:+undefined+
                             (list specifier ctx
                                   (eng:make-native-function
                                    "nextResolve" 1
                                    (lambda (this a)
                                      (declare (ignore this a))
                                      eng:+undefined+))))))))
         (load-cb
          (when (eng:callable-p load-fn)
            (lambda (&key url context next)
              (declare (ignore next))
              (let ((ctx (eng:new-object)))
                (eng:data-prop ctx "format"
                               (or (getf context :format) "module"))
                (eng:js-call load-fn eng:+undefined+
                             (list url ctx
                                   (eng:make-native-function
                                    "nextLoad" 0
                                    (lambda (this a)
                                      (declare (ignore this a))
                                      eng:+undefined+)))))))))
    (eng:register-node-module-hooks :resolve resolve-cb :load load-cb)
    eng:+undefined+))

(defun install-clun-plugin (clun global)
  "Install Clun.plugin; also alias Bun.plugin when Bun global is present."
  (let ((api (%make-plugin-api)))
    (eng:nonconfigurable-data-prop clun "plugin" api)
    ;; Optional Bun alias for drop-in scripts that import { plugin } from 'bun'.
    (let ((bun (eng:js-get global "Bun")))
      (when (eng:js-object-p bun)
        (eng:data-prop bun "plugin" api)))
    ;; Always expose a Bun global stub with plugin when missing (runtime scripts).
    (unless (eng:js-object-p (eng:js-get global "Bun"))
      (let ((bun (eng:new-object)))
        (eng:data-prop bun "plugin" api)
        (eng:data-prop bun "version" clun::*clun-version*)
        (eng:hidden-prop global "Bun" bun)))
    api))
