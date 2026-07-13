;;;; module-loader.lisp — ESM load/evaluate + ESM↔CJS interop + JSON modules +
;;;; the run-module-file drive path (Phase 07, design §3/§6/§7).
;;;;
;;;; Structure: a single post-order pass loads the graph (records + compiled ESM +
;;;; resolved deps), then a post-order evaluate pass runs each module after its
;;;; dependencies. ESM→ESM import bindings are live thunks into the exporter's live
;;;; frame slot; ESM→CJS bindings read module.exports (CJS has no live bindings).
;;;; Cross-module live binding through an ESM cycle is a documented 🟡 (snapshot).

(in-package :clun.engine)

;;; --- TS strip hook (Phase 09) ----------------------------------------------
;;; The transpiler installs this at load time; the engine calls it on .ts/.mts/.cts
;;; source before parse-program. Keeps the engine free of a compile-time dependency
;;; on clun.transpiler (which loads AFTER the engine).

(defvar *ts-strip-hook* nil
  "A function (source path) -> stripped-source, applied to TS files before parse.")

(defun ts-source-extension-p (path)
  (let ((dot (position #\. path :from-end t)))
    (and dot (member (subseq path dot) '(".ts" ".mts" ".cts") :test #'string=))))

(defun read-source-for (path)
  "Read PATH's text; strip types first when it is a TS source and a hook is installed."
  (let ((src (clun.sys:read-file-string path)))
    (if (and *ts-strip-hook* (ts-source-extension-p path))
        (funcall *ts-strip-hook* src path)
        src)))

;;; --- node builtin modules (Phase 12) ----------------------------------------
;;; The runtime layer registers builders (name -> exports-object thunk) and installs
;;; this hook; bare test262 realms leave it NIL, so `require('node:…')` is inert there.

(defvar *builtin-module-builder* nil
  "A function (name) -> a fresh exports js-object for the current *realm*, or NIL if
NAME is not a node builtin. Installed by clun.runtime; NIL in a bare realm.")

(defun try-builtin-module (specifier)
  "If SPECIFIER names a node builtin, return its (per-realm cached) :cjs module-record,
else NIL. A `node:`-prefixed specifier that is not a known builtin throws (as Node does)."
  (when *builtin-module-builder*
    (let* ((prefixed (and (>= (length specifier) 5) (string= specifier "node:" :end1 5)))
           (name (if prefixed (subseq specifier 5) specifier))
           (rec (get-builtin-module name)))
      (cond (rec rec)
            (prefixed (throw-native-error :error (format nil "Cannot find module 'node:~a'" name)))
            (t nil)))))

(defun get-builtin-module (name)
  "The cached :cjs module-record for builtin NAME in *realm*, built on first use, or NIL."
  (let ((key (concatenate 'string (string (code-char 0)) "node:" name)))  ; NUL ⇒ never a truename
    (or (realm-module *realm* key)
        (let ((exports (funcall *builtin-module-builder* name)))
          (when exports
            (setf (realm-module *realm* key)
                  (make-module-record :resolved-path key :format :cjs :status :evaluated
                                      :cjs-exports exports)))))))

;;; --- resolver boundary: map clun.resolver errors to JS errors ---------------

(defun resolve-specifier (specifier referrer-dir conditions)
  "Resolve SPECIFIER, mapping resolution errors to JS TypeErrors."
  (handler-case
      (clun.resolver:resolve specifier referrer-dir :conditions conditions)
    (clun.resolver:resolution-error (e)
      (declare (ignore e))
      (throw-type-error (format nil "Cannot find module '~a' imported from '~a'"
                                specifier referrer-dir)))))

(defun resolve-import (specifier referrer-dir)
  (resolve-specifier specifier referrer-dir '("node" "import")))

;;; --- JSON modules -----------------------------------------------------------

(defun load-json-value (path)
  "The parsed value of a JSON module at real PATH (cached in the registry)."
  (let ((mr (realm-module *realm* path)))
    (if (and mr (eq (mr-status mr) :evaluated))
        (mr-cjs-exports mr)
        (let ((mr (or mr (make-module-record :resolved-path path :format :json)))
              (value (json->js-value (clun.sys:parse-json (clun.sys:read-file-string path)))))
          (setf (mr-cjs-exports mr) value
                (mr-status mr) :evaluated
                (realm-module *realm* path) mr)
          value))))

(defun json->js-value (v)
  "Convert a clun.sys parsed-JSON value to a JS value (reuses the engine JSON path
by round-tripping through JSON.parse semantics — but here we build directly)."
  (cond
    ((eq v clun.sys:json-null) +null+)
    ((eq v clun.sys:json-true) +true+)
    ((eq v clun.sys:json-false) +false+)
    ((eq v :empty-object) (new-object))
    ((stringp v) v)
    ((floatp v) v)
    ((and (vectorp v) (not (stringp v)))
     (new-array (map 'list #'json->js-value v)))
    ((consp v)                             ; alist object
     (let ((o (new-object)))
       (dolist (kv v o) (data-prop o (car kv) (json->js-value (cdr kv))))))
    (t +undefined+)))

;;; --- graph load (records + compile + resolve deps) --------------------------

(defun load-any (path format)
  "Ensure a record exists for real PATH/FORMAT and (for ESM) its graph is loaded.
The record is REGISTERED so the evaluate pass finds the same object (a CJS/JSON
placeholder is evaluated lazily via load-cjs-module / load-json-value)."
  (or (realm-module *realm* path)
      (ecase format
        (:esm (esm-load path))
        ((:cjs :json)
         (setf (realm-module *realm* path)
               (make-module-record :resolved-path path :format format :status :unlinked))))))

(defun esm-load (path)
  "Load the ESM at real PATH: parse, compile, register, and recurse into deps."
  (let ((mr (make-module-record :resolved-path path :format :esm :status :loading)))
    (setf (realm-module *realm* path) mr
          (mr-source mr) (read-source-for path)
          (mr-ast mr) (parse-program (mr-source mr) :source-type :module))
    (compile-esm-module mr)
    (let ((dir (clun.sys:path-dirname path)))
      (dolist (spec (mr-requested mr))
        (let ((builtin (try-builtin-module spec)))
          (if builtin
              (setf (gethash spec (mr-requested-map mr)) builtin)
              (multiple-value-bind (dep-path dep-format) (resolve-import spec dir)
                (setf (gethash spec (mr-requested-map mr)) (load-any dep-path dep-format)))))))
    (setf (mr-status mr) :loaded)
    mr))

;;; --- evaluate (post-order) --------------------------------------------------

(defun evaluate-module (mr)
  "Evaluate MR after its dependencies. CJS/JSON own their own status + cycle handling
(load-cjs-module / load-json-value); ESM uses the guard below."
  (ecase (mr-format mr)
    (:cjs  (load-cjs-module (mr-resolved-path mr)))
    (:json (load-json-value (mr-resolved-path mr)))
    (:esm  (evaluate-esm-guarded mr)))
  mr)

(defun evaluate-esm-guarded (mr)
  "Idempotent ESM evaluation; an :evaluating back-edge (cycle) returns immediately
with whatever bindings exist so far (🟡). An evaluation fault is captured + re-thrown
on re-import."
  (case (mr-status mr)
    ((:evaluated :evaluating) (return-from evaluate-esm-guarded mr))
    (:errored (when (mr-eval-error mr) (throw-js-value (mr-eval-error mr)))))
  (setf (mr-status mr) :evaluating)
  (handler-case (evaluate-esm mr)
    (js-condition (c)
      (setf (mr-status mr) :errored (mr-eval-error mr) (js-condition-value c))
      (error c)))
  (setf (mr-status mr) :evaluated)
  mr)

(defun evaluate-esm (mr)
  "Instantiate MR's frame, wire imports from (already-evaluated) deps, run the body."
  ;; 1. evaluate dependencies first (post-order).
  (dolist (spec (mr-requested mr))
    (evaluate-module (gethash spec (mr-requested-map mr))))
  ;; 2. instantiate the module frame.
  (let ((frame (new-frame (mr-slot-count mr) nil)))
    (setf (mr-environment mr) frame)
    (setf (svref (env-slots frame) (mr-meta-idx mr)) (make-import-meta-object mr))
    (dolist (li (mr-lexical-idxs mr)) (setf (svref (env-slots frame) li) +tdz+))
    (dolist (fc (mr-func-compiled mr))
      (setf (svref (env-slots frame) (car fc)) (funcall (cdr fc) frame)))
    ;; 3. wire import slots to getter thunks into the resolved deps.
    (dolist (desc (mr-import-descs mr))
      (when (id-local desc)
        (setf (svref (env-slots frame) (gethash (id-local desc) (mr-name->index mr)))
              (import-binding-thunk mr desc))))
    ;; 4. build this module's export map (thunks) before running the body.
    (build-export-map mr)
    ;; 5. run the module body.
    (funcall (mr-body-fn mr) frame))
  mr)

;;; --- import binding thunks --------------------------------------------------

(defun import-binding-thunk (mr desc)
  "A no-arg thunk yielding the current value of import DESC, resolved against MR's
already-loaded dep for DESC's source specifier."
  (let ((dep (gethash (id-source desc) (mr-requested-map mr))))
    (ecase (id-kind desc)
      (:default   (module-default-thunk dep))
      (:namespace (let ((ns (module-namespace dep))) (lambda () ns)))
      (:named     (module-named-thunk dep (id-imported desc))))))

(defun module-default-thunk (dep)
  "Thunk for the DEFAULT import of DEP (ESM default binding / CJS module.exports /
JSON value)."
  (ecase (mr-format dep)
    (:esm  (let ((thunk (gethash "default" (mr-exports dep))))
             (or thunk (lambda () +undefined+))))
    (:cjs  (lambda () (mr-cjs-exports dep)))          ; interop: default = module.exports
    (:json (lambda () (mr-cjs-exports dep)))))

(defun module-named-thunk (dep name)
  "Thunk for a NAMED import of DEP. ESM: a live binding thunk; CJS: a property of
module.exports (best-effort 🟡); `default` = the whole value for CJS/JSON. A JSON
module has ONLY a default export — any other named import is a link SyntaxError."
  (ecase (mr-format dep)
    (:esm  (or (gethash name (mr-exports dep))
               (throw-syntax-error
                (format nil "The requested module '~a' does not provide an export named '~a'"
                        (mr-resolved-path dep) name))))
    (:cjs  (if (string= name "default")
               (lambda () (mr-cjs-exports dep))           ; {default as X} = module.exports
               (lambda () (js-get (mr-cjs-exports dep) name))))
    (:json (if (string= name "default")
               (lambda () (mr-cjs-exports dep))           ; {default as X} = the JSON value
               (throw-syntax-error
                (format nil "The requested module '~a' does not provide an export named '~a'"
                        (mr-resolved-path dep) name))))))

(defun json-as-object (v) (if (js-object-p v) v (new-object)))

(defun own-enumerable-string-keys (o)
  "The own enumerable string property keys of O (for CJS interop named exports)."
  (when (js-object-p o)
    (loop for k in (jm-own-property-keys o)
          when (stringp k)
          when (let ((d (jm-get-own-property o k))) (and d (eq (pd-enumerable d) t)))
          collect k)))

;;; --- export map -------------------------------------------------------------

(defun build-export-map (mr)
  "Populate MR's export map: exported-name -> a no-arg getter thunk. :local exports
read this module's live frame slot; :indirect re-exports chain to the source; :star
splices the source's names."
  (let ((frame (mr-environment mr))
        (descs (gethash :export-descs (mr-requested-map mr))))
    (dolist (desc descs)
      (ecase (ed-kind desc)
        (:local
         (let ((slot (ed-local-index desc)))
           (setf (gethash (ed-exported desc) (mr-exports mr))
                 (lambda () (let ((v (svref (env-slots frame) slot)))
                              (if (eq v +tdz+)
                                  (throw-reference-error
                                   (format nil "cannot access '~a' before initialization"
                                           (ed-exported desc)))
                                  v))))))
        (:indirect
         (let ((dep (gethash (ed-source desc) (mr-requested-map mr)))
               (name (ed-imported desc)))
           (setf (gethash (ed-exported desc) (mr-exports mr))
                 (module-export-thunk dep name))))
        (:star-as
         (let ((dep (gethash (ed-source desc) (mr-requested-map mr))))
           (setf (gethash (ed-exported desc) (mr-exports mr))
                 (let ((ns (module-namespace dep))) (lambda () ns)))))
        (:star
         (let ((dep (gethash (ed-source desc) (mr-requested-map mr))))
           (dolist (name (module-export-names dep))
             (unless (or (string= name "default") (gethash name (mr-exports mr)))
               (setf (gethash name (mr-exports mr)) (module-export-thunk dep name))))))))))

(defun module-export-thunk (mr name)
  "A getter thunk for export NAME of MR, across formats."
  (ecase (mr-format mr)
    (:esm  (or (gethash name (mr-exports mr)) (lambda () +undefined+)))
    (:cjs  (if (string= name "default")
               (lambda () (mr-cjs-exports mr))
               (lambda () (js-get (mr-cjs-exports mr) name))))
    (:json (if (string= name "default")
               (lambda () (mr-cjs-exports mr))
               (lambda () (js-get (json-as-object (mr-cjs-exports mr)) name))))))

(defun module-export-names (mr)
  "The exported names of MR (for `export *` splicing / namespace)."
  (ecase (mr-format mr)
    (:esm  (loop for k being the hash-keys of (mr-exports mr) collect k))
    (:cjs  (cons "default" (own-enumerable-string-keys (mr-cjs-exports mr))))
    (:json '("default"))))

;;; --- namespace object -------------------------------------------------------

(defun module-namespace (mr)
  "The Module Namespace object for MR (built once). Snapshot of current export
values (🟡: not a live exotic object) plus, for CJS, a `default`."
  (or (mr-namespace mr)
      (setf (mr-namespace mr)
            (let ((ns (new-object)))
              (ecase (mr-format mr)
                (:esm (dolist (name (module-export-names mr))
                        (data-prop ns name (funcall (module-export-thunk mr name)))))
                (:cjs (data-prop ns "default" (mr-cjs-exports mr))
                      (dolist (k (own-enumerable-string-keys (mr-cjs-exports mr)))
                        (data-prop ns k (js-get (mr-cjs-exports mr) k))))
                (:json (data-prop ns "default" (mr-cjs-exports mr))))
              ns))))

;;; --- drive path -------------------------------------------------------------

(defun run-module-file (entry &key (realm (make-realm)))
  "Load + evaluate the module graph rooted at ENTRY (a path), drive the job loop to
idle, surface unhandled rejections. Returns the realm."
  (let ((*realm* realm))
    (unwind-protect
         (let* ((cwd (clun.sys:pathname->native (truename ".")))
                (spec (entry->specifier entry)))
           (multiple-value-bind (path format) (resolve-specifier spec cwd '("node" "import"))
             (let ((mr (load-any path format)))
               (setf (realm-entry-module realm) mr)
               (evaluate-module mr)
               (drive-jobs realm)
               (report-unhandled-rejections realm))))
      (teardown-coroutines realm)
      (destroy-realm-loop realm)))
  realm)

(defun entry->specifier (entry)
  "Coerce an entry PATH into a specifier the resolver treats as a path (not a bare
package): absolute stays, a dotted-relative stays, anything else gets `./`."
  (cond ((clun.sys:absolute-path-p entry) entry)
        ((and (>= (length entry) 1) (char= (char entry 0) #\.)) entry)
        (t (concatenate 'string "./" entry))))

(defun run-module-source (source &key (realm (make-realm)) (base-dir nil))
  "Evaluate SOURCE as an ESM whose imports resolve against BASE-DIR (default cwd).
Used by run-source for `:source-type :module` and the CLI's -e/[eval] modules."
  (let ((*realm* realm))
    (unwind-protect
         (let* ((dir (or base-dir (clun.sys:pathname->native (truename "."))))
                (path (clun.sys:path-join dir "[eval].mjs"))
                (mr (make-module-record :resolved-path path :format :esm :status :loading)))
           (setf (realm-module realm path) mr
                 (realm-entry-module realm) mr
                 (mr-source mr) source
                 (mr-ast mr) (parse-program source :source-type :module))
           (compile-esm-module mr)
           (dolist (spec (mr-requested mr))
             (let ((builtin (try-builtin-module spec)))
               (if builtin
                   (setf (gethash spec (mr-requested-map mr)) builtin)
                   (multiple-value-bind (dp fmt) (resolve-import spec dir)
                     (setf (gethash spec (mr-requested-map mr)) (load-any dp fmt))))))
           (setf (mr-status mr) :loaded)
           (evaluate-module mr)
           (drive-jobs realm)
           (report-unhandled-rejections realm))
      (teardown-coroutines realm)
      (destroy-realm-loop realm)))
  realm)
