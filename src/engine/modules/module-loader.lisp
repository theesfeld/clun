;;;; module-loader.lisp — ESM load/evaluate + ESM↔CJS interop + data modules +
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

(defvar *jsx-transform-hook* nil
  "A function (source path) -> transformed-source, applied to .jsx/.tsx before parse.")

(defun ts-source-extension-p (path)
  (let ((dot (position #\. path :from-end t)))
    (and dot (member (subseq path dot) '(".ts" ".mts" ".cts") :test #'string=))))

(defun tsx-source-extension-p (path)
  (let ((dot (position #\. path :from-end t)))
    (and dot (string= (subseq path dot) ".tsx"))))

(defun jsx-source-extension-p (path)
  (let ((dot (position #\. path :from-end t)))
    (and dot (member (subseq path dot) '(".jsx" ".tsx") :test #'string=))))

(defun read-source-for (path)
  "Read PATH's text; transform JSX then strip TS types when hooks apply."
  (let ((src (clun.sys:read-file-string path)))
    (when (and *jsx-transform-hook* (jsx-source-extension-p path))
      (setf src (funcall *jsx-transform-hook* src path)))
    (when (and *ts-strip-hook*
               (or (ts-source-extension-p path) (tsx-source-extension-p path)))
      ;; After JSX lower, .tsx is type-strip shaped like .ts (path spoof for strip).
      (let ((strip-path (if (tsx-source-extension-p path)
                            (concatenate 'string (subseq path 0 (- (length path) 1)) "s")
                            path)))
        (setf src (funcall *ts-strip-hook* src strip-path))))
    src))

;;; --- node builtin modules (Phase 12) ----------------------------------------
;;; The runtime layer registers builders (name -> exports-object thunk) and installs
;;; this hook; bare test262 realms leave it NIL, so `require('node:…')` is inert there.

(defvar *builtin-module-builder* nil
  "A function (name) -> a fresh exports js-object for the current *realm*, or NIL if
NAME is not a node builtin. Installed by clun.runtime; NIL in a bare realm.")

;;; --- module mocks -----------------------------------------------------------

(defun module-mock-table (realm)
  (or (realm-module-mocks realm)
      (setf (realm-module-mocks realm) (make-hash-table :test 'equal))))

(defun module-mock-strip-file-url (specifier)
  (cond
    ((and (>= (length specifier) 7) (string= specifier "file://" :end1 7))
     (subseq specifier 7))
    ((and (>= (length specifier) 5) (string= specifier "file:" :end1 5))
     (subseq specifier 5))
    (t specifier)))

(defun module-mock-specifier-key (specifier referrer-dir)
  "A stable pre-resolution key. Relative missing modules remain mockable because this
key does not require the target to exist."
  (let ((plain (module-mock-strip-file-url specifier)))
    (cond
      ((and (>= (length plain) 5) (string= plain "node:" :end1 5))
       (concatenate 'string "builtin:" (subseq plain 5)))
      ((or (clun.sys:absolute-path-p plain)
           (and (>= (length plain) 2)
                (char= (char plain 0) #\.)
                (member (char plain 1) '(#\/ #\.) :test #'char=)))
       (concatenate 'string "path:"
                    (clun.sys:normalize-path
                     (if (clun.sys:absolute-path-p plain)
                         plain
                         (clun.sys:path-join referrer-dir plain)))))
      (t (concatenate 'string "specifier:" plain)))))

(defun module-mock-resolved-key (path)
  (concatenate 'string "resolved:" path))

(defun module-mock-builtin-key (specifier)
  (let ((plain (if (and (>= (length specifier) 5)
                        (string= specifier "node:" :end1 5))
                   (subseq specifier 5)
                   specifier)))
    (concatenate 'string "builtin:" plain)))

(defun replace-enumerable-properties (target source)
  "Replace TARGET's configurable own enumerable string properties with SOURCE's.
Used for already-required CommonJS objects so existing references observe a mock."
  (unless (eq target source)
    (dolist (key (copy-list (own-enumerable-string-keys target)))
      (js-delete target key nil))
    (dolist (key (own-enumerable-string-keys source))
      (data-prop target key (js-get source key))))
  target)

(defun refresh-module-namespace (mr)
  (let ((namespace (mr-namespace mr))
        (exports (mr-mock-exports mr)))
    (when (and namespace exports)
      (dolist (key (copy-list (own-enumerable-string-keys namespace)))
        (js-delete namespace key nil))
      (dolist (key (own-enumerable-string-keys exports))
        (data-prop namespace key (js-get exports key)))))
  mr)

(defun apply-module-mock (record exports)
  (let ((effective exports))
    ;; CommonJS callers retain module.exports by identity. Preserve that identity when
    ;; it is an object while replacing its public enumerable surface.
    (when (and (eq (mr-format record) :cjs)
               (js-object-p (mr-cjs-exports record)))
      (setf effective (replace-enumerable-properties (mr-cjs-exports record) exports)))
    (setf (mr-mock-exports record) effective
          (mr-cjs-exports record) effective
          (mr-status record) :evaluated
          (mr-eval-error record) nil)
    (refresh-module-namespace record)))

(defun resolve-module-mock-path (specifier referrer-dir conditions)
  (handler-case
      (multiple-value-bind (path format)
          (clun.resolver:resolve specifier referrer-dir :conditions conditions)
        (declare (ignore format))
        path)
    (clun.resolver:resolution-error () nil)))

(defun find-module-mock (specifier referrer-dir conditions)
  "Return a per-realm mock without requiring SPECIFIER to resolve."
  (let ((table (realm-module-mocks *realm*)))
    (when table
      (or (gethash (module-mock-specifier-key specifier referrer-dir) table)
          (gethash (module-mock-builtin-key specifier) table)
          (let ((path (resolve-module-mock-path specifier referrer-dir conditions)))
            (and path (gethash (module-mock-resolved-key path) table)))))))

(defun register-module-mock (realm specifier referrer-dir exports)
  "Install EXPORTS as SPECIFIER's module namespace in REALM. Existing ESM bindings,
namespace objects, and CommonJS object references are updated; unresolved specifiers
remain available through their stable pre-resolution key."
  (unless (js-object-p exports)
    (throw-type-error "mock(module, fn) must return an object"))
  (let* ((*realm* realm)
         (table (module-mock-table realm))
         (raw-key (module-mock-specifier-key specifier referrer-dir))
         (records '())
         (builtin (try-builtin-module specifier)))
    (when builtin (pushnew builtin records :test #'eq))
    (dolist (conditions '(("node" "import") ("node" "require")))
      (let ((path (resolve-module-mock-path specifier referrer-dir conditions)))
        (when path
          (let ((record (or (realm-module realm path)
                            (make-module-record :resolved-path path :format :cjs
                                                :status :evaluated))))
            (setf (realm-module realm path) record
                  (gethash (module-mock-resolved-key path) table) record)
            (pushnew record records :test #'eq)))))
    (unless records
      (push (make-module-record :resolved-path raw-key :format :cjs
                                :status :evaluated)
            records))
    (dolist (record records) (apply-module-mock record exports))
    (setf (gethash raw-key table) (car records)
          (gethash (module-mock-builtin-key specifier) table) (car records))
    exports))

(defun bun-builtin-registry-key (name)
  "Realm registry key for the virtual `bun:NAME` module (NUL prefix ⇒ never a path)."
  (concatenate 'string (string (code-char 0)) "bun:" name))

(defun get-bun-builtin-module (name)
  "The :cjs module-record for virtual `bun:NAME` in *realm*, or NIL if unregistered."
  (realm-module *realm* (bun-builtin-registry-key name)))

(defun register-bun-builtin (realm name exports)
  "Install EXPORTS as the pure-CL virtual module `bun:NAME` for REALM.
Used by the test runner for `bun:test` so ESM `import` and CJS `require` resolve
without touching the filesystem or node_modules."
  (unless (js-object-p exports)
    (throw-type-error "bun builtin exports must be an object"))
  (let* ((*realm* realm)
         (key (bun-builtin-registry-key name))
         (record (or (realm-module realm key)
                     (make-module-record :resolved-path key :format :cjs
                                         :status :evaluated))))
    (setf (mr-cjs-exports record) exports
          (mr-mock-exports record) nil
          (mr-status record) :evaluated
          (mr-eval-error record) nil
          (mr-namespace record) nil
          (realm-module realm key) record)
    record))

(defun try-builtin-module (specifier)
  "If SPECIFIER names a node or bun builtin, return its (per-realm cached) :cjs
module-record, else NIL. A `node:`/`bun:`-prefixed specifier that is not a known
builtin throws (as Node does for `node:`)."
  (cond
    ;; bun: scheme — pure-CL virtual modules (e.g. bun:test from the test runner).
    ((and (>= (length specifier) 4) (string= specifier "bun:" :end1 4))
     (let* ((name (subseq specifier 4))
            (rec (get-bun-builtin-module name)))
       (or rec
           (throw-native-error :error
                               (format nil "Cannot find module 'bun:~a'" name)))))
    ;; node builtins: bare name or node: prefix via *builtin-module-builder*.
    (*builtin-module-builder*
     (let* ((prefixed (and (>= (length specifier) 5)
                           (string= specifier "node:" :end1 5)))
            (name (if prefixed (subseq specifier 5) specifier))
            (rec (get-builtin-module name)))
       (cond (rec rec)
             (prefixed
              (throw-native-error :error
                                  (format nil "Cannot find module 'node:~a'" name)))
             (t nil))))
    (t nil)))

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

;;; --- YAML modules -----------------------------------------------------------

(defun load-yaml-value (path)
  "Parse and cache the YAML data module at real PATH. A failed parse is evicted."
  (let ((existing (realm-module *realm* path)))
    (if (and existing (eq (mr-status existing) :evaluated))
        (mr-cjs-exports existing)
        (let ((record (or existing
                          (make-module-record :resolved-path path :format :yaml)))
              (done nil))
          (setf (realm-module *realm* path) record
                (mr-status record) :evaluating)
          (unwind-protect
               (multiple-value-bind (value named-exports-p)
                   (yaml-source->js
                    (yaml-octets->source (clun.sys:read-file-octets path) path)
                    path)
                 (setf (mr-cjs-exports record) value
                       (mr-yaml-named-exports-p record) named-exports-p
                       (mr-status record) :evaluated
                       done t)
                 value)
            (unless done (setf (realm-module *realm* path) nil)))))))

;;; --- graph load (records + compile + resolve deps) --------------------------

(defun load-any (path format)
  "Ensure a record exists for real PATH/FORMAT and (for ESM) its graph is loaded.
The record is REGISTERED so the evaluate pass finds the same object (a CJS/JSON/YAML
placeholder is evaluated lazily by its format-specific loader)."
  (or (realm-module *realm* path)
      (ecase format
        (:esm (esm-load path))
        ((:cjs :json :yaml)
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
        (let ((mock (find-module-mock spec dir '("node" "import"))))
          (if mock
              (setf (gethash spec (mr-requested-map mr)) mock)
              (let ((builtin (try-builtin-module spec)))
                (if builtin
                    (setf (gethash spec (mr-requested-map mr)) builtin)
                    (multiple-value-bind (dep-path dep-format) (resolve-import spec dir)
                      (setf (gethash spec (mr-requested-map mr))
                            (load-any dep-path dep-format)))))))))
    (setf (mr-status mr) :loaded)
    mr))

;;; --- evaluate (post-order) --------------------------------------------------

(defun evaluate-module (mr)
  "Evaluate MR after its dependencies. Data and CJS formats own their status handling;
ESM uses the guard below."
  (when (mr-mock-exports mr)
    (setf (mr-status mr) :evaluated)
    (return-from evaluate-module mr))
  (ecase (mr-format mr)
    (:cjs  (load-cjs-module (mr-resolved-path mr)))
    (:json (load-json-value (mr-resolved-path mr)))
    (:yaml (load-yaml-value (mr-resolved-path mr)))
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
JSON/YAML value)."
  (let ((ordinary
          (ecase (mr-format dep)
            (:esm  (or (gethash "default" (mr-exports dep))
                       (lambda () +undefined+)))
            (:cjs  (lambda () (mr-cjs-exports dep))) ; interop default = module.exports
            (:json (lambda () (mr-cjs-exports dep)))
            (:yaml (lambda () (mr-cjs-exports dep))))))
    (lambda ()
      (if (mr-mock-exports dep)
          (js-get (mr-mock-exports dep) "default")
          (funcall ordinary)))))

(defun module-named-thunk (dep name)
  "Thunk for a NAMED import of DEP. ESM: a live binding thunk; CJS: a property of
module.exports (best-effort 🟡); `default` = the whole value for CJS/JSON/YAML. JSON
has only a default export; YAML mappings also expose their own top-level keys."
  (let ((ordinary
          (ecase (mr-format dep)
            (:esm  (or (gethash name (mr-exports dep))
                       (and (mr-mock-exports dep) (lambda () +undefined+))
                       (throw-syntax-error
                        (format nil
                                "The requested module '~a' does not provide an export named '~a'"
                                (mr-resolved-path dep) name))))
            (:cjs  (if (string= name "default")
                       (lambda () (mr-cjs-exports dep))
                       (lambda () (js-get (mr-cjs-exports dep) name))))
            (:json (if (string= name "default")
                       (lambda () (mr-cjs-exports dep))
                       (throw-syntax-error
                        (format nil
                                "The requested module '~a' does not provide an export named '~a'"
                                (mr-resolved-path dep) name))))
            (:yaml
             (if (string= name "default")
                 (lambda () (mr-cjs-exports dep))
                 (let ((value (mr-cjs-exports dep)))
                   (if (and (mr-yaml-named-exports-p dep)
                            (has-own-property value name))
                       (lambda () (js-get value name))
                       (throw-syntax-error
                        (format nil
                                "The requested module '~a' does not provide an export named '~a'"
                                (mr-resolved-path dep) name)))))))))
    (lambda ()
      (if (mr-mock-exports dep)
          (js-get (mr-mock-exports dep) name)
          (funcall ordinary)))))

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
  (let ((ordinary
          (ecase (mr-format mr)
            (:esm  (or (gethash name (mr-exports mr)) (lambda () +undefined+)))
            (:cjs  (if (string= name "default")
                       (lambda () (mr-cjs-exports mr))
                       (lambda () (js-get (mr-cjs-exports mr) name))))
            (:json (if (string= name "default")
                       (lambda () (mr-cjs-exports mr))
                       (lambda () (js-get (json-as-object (mr-cjs-exports mr)) name))))
            (:yaml (if (string= name "default")
                       (lambda () (mr-cjs-exports mr))
                       (lambda () (js-get (json-as-object (mr-cjs-exports mr)) name)))))))
    (lambda ()
      (if (mr-mock-exports mr)
          (js-get (mr-mock-exports mr) name)
          (funcall ordinary)))))

(defun module-export-names (mr)
  "The exported names of MR (for `export *` splicing / namespace)."
  (when (mr-mock-exports mr)
    (return-from module-export-names
      (own-enumerable-string-keys (mr-mock-exports mr))))
  (ecase (mr-format mr)
    (:esm  (loop for k being the hash-keys of (mr-exports mr) collect k))
    (:cjs  (cons "default" (own-enumerable-string-keys (mr-cjs-exports mr))))
    (:json '("default"))
    (:yaml (if (mr-yaml-named-exports-p mr)
               (cons "default"
                     (remove "default"
                             (own-enumerable-string-keys (mr-cjs-exports mr))
                             :test #'string=))
               '("default")))))

;;; --- namespace object -------------------------------------------------------

(defun module-namespace (mr)
  "The Module Namespace object for MR (built once). Snapshot of current export
values (🟡: not a live exotic object) plus, for CJS, a `default`."
  (or (mr-namespace mr)
      (setf (mr-namespace mr)
            (let ((ns (new-object)))
              (if (mr-mock-exports mr)
                  (dolist (name (own-enumerable-string-keys (mr-mock-exports mr)))
                    (data-prop ns name (js-get (mr-mock-exports mr) name)))
                  (ecase (mr-format mr)
                (:esm (dolist (name (module-export-names mr))
                        (data-prop ns name (funcall (module-export-thunk mr name)))))
                (:cjs (data-prop ns "default" (mr-cjs-exports mr))
                      (dolist (k (own-enumerable-string-keys (mr-cjs-exports mr)))
                        (data-prop ns k (js-get (mr-cjs-exports mr) k))))
                (:json (data-prop ns "default" (mr-cjs-exports mr)))
                (:yaml
                 (data-prop ns "default" (mr-cjs-exports mr))
                 (when (mr-yaml-named-exports-p mr)
                   (dolist (key (remove "default"
                                        (own-enumerable-string-keys (mr-cjs-exports mr))
                                        :test #'string=))
                     (data-prop ns key (js-get (mr-cjs-exports mr) key)))))))
              ns))))

;;; --- drive path -------------------------------------------------------------

(defun run-module-file (entry &key (realm (make-realm)) (teardown t))
  "Load + evaluate the module graph rooted at ENTRY (a path), drive the job loop to
idle, surface unhandled rejections. Returns the realm. With TEARDOWN nil the loop +
coroutines are left ALIVE (the test runner keeps them to run async test bodies, then
calls teardown-realm itself)."
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
      (when teardown (teardown-realm realm))))
  realm)

(defun teardown-realm (realm)
  "Force-finish live coroutines and destroy the loop (leak control). Idempotent."
  (teardown-coroutines realm)
  (destroy-realm-loop realm))

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
             (let ((mock (find-module-mock spec dir '("node" "import"))))
               (if mock
                   (setf (gethash spec (mr-requested-map mr)) mock)
                   (let ((builtin (try-builtin-module spec)))
                     (if builtin
                         (setf (gethash spec (mr-requested-map mr)) builtin)
                         (multiple-value-bind (dp fmt) (resolve-import spec dir)
                           (setf (gethash spec (mr-requested-map mr))
                                 (load-any dp fmt))))))))
           (setf (mr-status mr) :loaded)
           (evaluate-module mr)
           (drive-jobs realm)
           (report-unhandled-rejections realm))
      (teardown-coroutines realm)
      (destroy-realm-loop realm)))
  realm)
