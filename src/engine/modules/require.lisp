;;;; require.lisp — CommonJS `require` via the Node wrapper-function idiom (Phase
;;;; 07, design §5). A CJS body runs (sloppy) inside a synthetic
;;;; `(function (exports, require, module, __filename, __dirname) { … })` compiled
;;;; with the ordinary function machinery. The realm module registry is the cache;
;;;; a re-entrant require of an :evaluating module returns its partial exports.

(in-package :clun.engine)

(defun make-cjs-wrapper (stmts)
  "Compile the Node CJS wrapper for STMTS; return a js-function of 5 args."
  (let ((params (list (make-identifier :name "exports")
                      (make-identifier :name "require")
                      (make-identifier :name "module")
                      (make-identifier :name "__filename")
                      (make-identifier :name "__dirname")))
        (body (make-block-statement :body stmts)))
    (funcall (compile-function-common (make-comp) params body "require") nil)))

(defun run-cjs-body (mr module-obj exports-obj)
  "Run MR's CJS body with the wrapper's 5 bindings bound. Node invokes the wrapper
via `.call(module.exports, …)`, so top-level `this` === module.exports."
  (let* ((path (mr-resolved-path mr))
         (source (or (mr-source mr) (read-source-for path)))
         (*coverage-source-path* path)
         (*current-source-text* source)
         (program (parse-program source :source-type :script))
         (wrapper (make-cjs-wrapper (program-body program)))
         (require-fn (make-require-function path))
         (dir (clun.sys:path-dirname path)))
    (js-call wrapper exports-obj (list exports-obj require-fn module-obj path dir))))

(defun load-cjs-module (path)
  "Evaluate (or return cached) the CJS module at real PATH; return module.exports.
A record may already exist as an :unlinked placeholder (pre-created by the ESM graph
loader) — evaluation is driven by status, not mere existence."
  (let ((mr (realm-module *realm* path)))
    (when (and mr (mr-mock-exports mr))
      (return-from load-cjs-module (mr-mock-exports mr)))
    (if (and mr (member (mr-status mr) '(:evaluated :evaluating)))
        ;; cache hit — for an :evaluating module this is the partial exports (cycle).
        (mr-cjs-exports mr)
        (let ((mr (or mr (make-module-record :resolved-path path :format :cjs)))
              (exports-obj (new-object))
              (module-obj (new-object))
              (done nil))
          (setf (realm-module *realm* path) mr
                (mr-status mr) :evaluating)
          (data-prop module-obj "exports" exports-obj)
          (setf (mr-cjs-exports mr) exports-obj)   ; partial-exports base for cycles
          ;; If the body throws, Node evicts the cache entry so a later require()
          ;; re-runs the module — do the same (don't leave it cached :evaluating).
          (unwind-protect
               (progn
                 (run-cjs-body mr module-obj exports-obj)
                 ;; re-read module.exports (the body may have replaced it wholesale).
                 (setf (mr-cjs-exports mr) (js-get module-obj "exports")
                       (mr-status mr) :evaluated
                       done t))
            (unless done (setf (realm-module *realm* path) nil)))
          (mr-cjs-exports mr)))))

(defun make-require-function (referrer-path)
  "A `require` bound to REFERRER-PATH's directory."
  (let ((dir (clun.sys:path-dirname referrer-path)))
    (make-native-function "require" 1
      (lambda (this args) (declare (ignore this))
        (cjs-require (to-string (arg args 0)) dir)))))

(defun cjs-require (specifier referrer-dir)
  "The CommonJS require(SPECIFIER) from REFERRER-DIR: plugins, builtins, resolve + dispatch."
  (let ((mr (resolve-load-dependency specifier referrer-dir '("node" "require"))))
    (evaluate-module mr)
    (cond
      ((mr-mock-exports mr) (mr-mock-exports mr))
      ((eq (mr-format mr) :esm)
       (throw-type-error
        (format nil "require() of ES Module ~a not supported (use import)"
                (mr-resolved-path mr))))
      ((eq (mr-format mr) :json) (mr-cjs-exports mr))
      ((eq (mr-format mr) :yaml) (mr-cjs-exports mr))
      (t (mr-cjs-exports mr)))))
