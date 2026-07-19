;;;; plugin.lisp — Runtime loader plugins (Issue #187 FULL PORT, Phase 41).
;;;;
;;;; Pure-CL host for Bun.plugin-compatible onResolve / onLoad / onStart /
;;;; builder.module, plus exceed surface (priority, clear by name, list,
;;;; optional resolve chaining, node:module-style sync hooks).
;;;;
;;;; Plugin JS is user code; all machinery lives here. Registry is process-global
;;;; (Bun.plugin semantics). Hooks apply in registration order (priority desc
;;;; first within each plugin's registration wave).

(in-package :clun.engine)

;;; --- registry ---------------------------------------------------------------

(defstruct (plugin-entry (:conc-name pe-))
  (name "" :type string)
  (priority 0 :type integer)
  (target :all)                         ; :all | :bun | :node | :browser
  (on-resolve nil)                      ; list of resolve-hook
  (on-load nil)                         ; list of load-hook
  (on-start nil)                        ; list of callbacks
  (on-end nil)
  (virtuals nil)                        ; alist specifier -> load-callback
  (active t))

(defstruct (resolve-hook (:conc-name rh-))
  filter                                ; predicate of one string, or js-regexp, or string ppcre
  (namespace nil)                       ; nil = any; "file" default for file imports
  callback                              ; (lambda (&key path importer namespace kind) ...)
  (chain nil)                           ; when T, allow further onResolve (exceed Bun)
  (plugin-name "" :type string))

(defstruct (load-hook (:conc-name lh-))
  filter
  (namespace nil)
  callback                              ; (lambda (&key path namespace loader defer plugin-data) ...)
  (plugin-name "" :type string))

(defvar *plugin-entries* nil
  "Ordered list of PLUGIN-ENTRY (newest last; iteration uses priority then order).")

(defvar *node-module-hooks* nil
  "List of (plist :resolve fn :load fn) for node:module-style sync hooks (exceed).")

(defvar *plugin-resolve-generation* 0
  "Bumped when onResolve hooks are added so mid-resolution registers skip current path.")

(defun plugin-clear-all ()
  "Deactivate every plugin and node:module hook (Bun.plugin.clearAll)."
  (setf *plugin-entries* nil
        *node-module-hooks* nil)
  (incf *plugin-resolve-generation*)
  t)

(defun plugin-clear (name)
  "Remove plugins whose name equals NAME (exceed Bun)."
  (setf *plugin-entries*
        (remove name *plugin-entries* :key #'pe-name :test #'string=))
  (incf *plugin-resolve-generation*)
  t)

(defun plugin-list-names ()
  "Registered plugin names in effective order (exceed Bun)."
  (mapcar #'pe-name (plugin-active-entries)))

(defun plugin-active-entries ()
  (sort (copy-list (remove-if-not #'pe-active *plugin-entries*))
        (lambda (a b)
          (let ((pa (pe-priority a)) (pb (pe-priority b)))
            (if (/= pa pb)
                (> pa pb)
                ;; stable: earlier registration first at same priority
                (< (position a *plugin-entries*) (position b *plugin-entries*)))))))

(defun make-plugin-entry* (&key (name "plugin") (priority 0) (target :all))
  (make-plugin-entry :name (or name "plugin")
                     :priority (or priority 0)
                     :target (or target :all)))

(defun register-plugin-entry (entry)
  "Append ENTRY so earlier registrations run first at equal priority."
  (setf *plugin-entries* (append *plugin-entries* (list entry)))
  (incf *plugin-resolve-generation*)
  entry)

;;; --- filter matching --------------------------------------------------------

(defun plugin-filter->matcher (filter)
  "Return a (lambda (string) boolean) for FILTER."
  (cond
    ((functionp filter) filter)
    ((and (symbolp filter) (fboundp filter)) (symbol-function filter))
    ((js-regexp-p filter)
     (let ((scanner (js-regexp-scanner filter)))
       (lambda (text)
         (multiple-value-bind (ms me) (pp:scan scanner text)
           (declare (ignore me))
           (and ms t)))))
    ((stringp filter)
     (handler-case
         (let ((scanner (pp:create-scanner filter)))
           (lambda (text)
             (multiple-value-bind (ms me) (pp:scan scanner text)
               (declare (ignore me))
               (and ms t))))
       (error ()
         (lambda (text) (search filter text :test #'char=)))))
    (t (lambda (text) (declare (ignore text)) nil))))

(defun plugin-filter-matches (filter text)
  (funcall (plugin-filter->matcher filter) (or text "")))

(defun plugin-namespace-matches (hook-ns actual-ns)
  "NIL hook namespace matches any; otherwise exact string match (empty ≡ file)."
  (let ((want (or hook-ns nil))
        (have (plugin-normalize-namespace actual-ns)))
    (cond
      ((null want) t)
      ((string= (plugin-normalize-namespace want) have) t)
      (t nil))))

(defun plugin-normalize-namespace (ns)
  (cond
    ((null ns) "file")
    ((string= ns "") "file")
    (t ns)))

(defun plugin-specifier-eligible-p (specifier)
  "Bun: plugin hooks match only when the specifier contains '.' or ':'."
  (or (find #\. specifier) (find #\: specifier)))

;;; --- registry keys for non-file namespaces ----------------------------------

(defun plugin-registry-key (namespace path)
  (let ((ns (plugin-normalize-namespace namespace)))
    (if (string= ns "file")
        path
        (format nil "#plugin/~a/~a" ns path))))

(defun plugin-key-namespace (key)
  (if (and (>= (length key) 8) (string= key "#plugin/" :end1 8))
      (let* ((rest (subseq key 8))
             (slash (position #\/ rest)))
        (if slash (subseq rest 0 slash) "file"))
      "file"))

(defun plugin-key-path (key)
  (if (and (>= (length key) 8) (string= key "#plugin/" :end1 8))
      (let* ((rest (subseq key 8))
             (slash (position #\/ rest)))
        (if slash (subseq rest (1+ slash)) rest))
      key))

;;; --- result coercion --------------------------------------------------------

(defun plugin-own-enumerable-keys (object)
  "String keys of OBJECT that are own + enumerable (available before module-loader)."
  (loop for key in (jm-own-property-keys object)
        for desc = (and (stringp key) (jm-get-own-property object key))
        when (and desc (eq (pd-enumerable desc) t))
          collect key))

(defun plugin-result-plist (value)
  "Normalize a CL plist, hash-table, or JS object into a plist of keyword keys."
  (cond
    ((null value) nil)
    ((js-undefined-p value) nil)
    ((js-null-p value) nil)
    ((and (listp value) (keywordp (car value))) value)
    ((hash-table-p value)
     (loop for k being the hash-keys of value using (hash-value v)
           collect (intern (string-upcase (string k)) :keyword)
           collect v))
    ((js-object-p value)
     (let ((out nil))
       (dolist (key (plugin-own-enumerable-keys value))
         (push (js-get value key) out)
         (push (intern (string-upcase key) :keyword) out))
       out))
    (t nil)))
(defun plugin-plist-get (plist key &optional default)
  (let ((tail (member key plist)))
    (if tail (second tail) default)))

(defun plugin-call-sync (callback args-plist)
  "Call CALLBACK with keyword args. If it returns a Promise, settle it."
  (unless callback
    (return-from plugin-call-sync nil))
  (let ((result
          (handler-case
              (apply callback args-plist)
            (js-condition (c) (error c))
            (error (e)
              (throw-type-error (format nil "plugin hook error: ~a" e))))))
    (when (and (js-promise-p result) *realm*)
      (multiple-value-bind (kind value)
          (run-callback-to-settlement (lambda () result) *realm* :timeout-ms 30000)
        (ecase kind
          (:fulfilled (setf result value))
          (:rejected
           (if (js-object-p value)
               (throw-js-value value)
               (throw-type-error (format nil "~a" value))))
          (:timeout (throw-type-error "plugin hook Promise timed out")))))
    result))

;;; --- onResolve --------------------------------------------------------------

(defun plugin-run-on-resolve (specifier &key (namespace "file") importer kind)
  "Run onResolve hooks. Returns plist (:path :namespace :external :plugin-data :side-effects)
or NIL. onResolve does not chain by default (Bun); set :chain t to exceed."
  (unless (or (not (string= (plugin-normalize-namespace namespace) "file"))
              (plugin-specifier-eligible-p specifier))
    (return-from plugin-run-on-resolve nil))
  ;; Virtual modules first (exact specifier match from builder.module).
  (dolist (entry (plugin-active-entries))
    (let ((cb (cdr (assoc specifier (pe-virtuals entry) :test #'string=))))
      (when cb
        (return-from plugin-run-on-resolve
          (list :path specifier
                :namespace "bun-module"
                :virtual cb
                :plugin-name (pe-name entry))))))
  (let ((gen *plugin-resolve-generation*)
        (current-path specifier)
        (current-ns (plugin-normalize-namespace namespace))
        (result nil))
    (dolist (entry (plugin-active-entries))
      (dolist (hook (pe-on-resolve entry))
        (when (and (= gen *plugin-resolve-generation*)
                   (plugin-namespace-matches (rh-namespace hook) current-ns)
                   (plugin-filter-matches (rh-filter hook) current-path))
          (let* ((raw (plugin-call-sync
                       (rh-callback hook)
                       (list :path current-path
                             :importer (or importer "")
                             :namespace current-ns
                             :kind (or kind :import))))
                 (pl (plugin-result-plist raw)))
            (when pl
              (let ((new-path (plugin-plist-get pl :path))
                    (new-ns (plugin-plist-get pl :namespace))
                    (external (plugin-plist-get pl :external))
                    (plugin-data (plugin-plist-get pl :plugin-data)))
                (when (or new-path new-ns external plugin-data
                          (member :path pl) (member :namespace pl))
                  (when new-path (setf current-path (if (js-string-p new-path)
                                                        new-path
                                                        (if (stringp new-path)
                                                            new-path
                                                            (to-string new-path)))))
                  (when new-ns
                    (setf current-ns (plugin-normalize-namespace
                                      (if (stringp new-ns) new-ns (to-string new-ns)))))
                  (setf result (list :path current-path
                                     :namespace current-ns
                                     :external external
                                     :plugin-data plugin-data
                                     :plugin-name (rh-plugin-name hook)))
                  (unless (rh-chain hook)
                    (return-from plugin-run-on-resolve result)))))))))
    result))

;;; --- onLoad -----------------------------------------------------------------

(defun plugin-make-defer ()
  "Return a thunk that, when called, yields a resolved Promise (or T without realm)."
  (let ((called nil)
        (waiters nil)
        (done nil))
    (lambda ()
      (when called
        (throw-type-error "onLoad defer() may only be called once"))
      (setf called t)
      (if *realm*
          (multiple-value-bind (p resolve reject)
              (promise-and-caps)
            (declare (ignore reject))
            (if done
                (%fulfill-promise p +undefined+)
                (push resolve waiters))
            ;; Mark load graph complete after current stack drains.
            (enqueue-job
             (lambda ()
               (setf done t)
               (dolist (r waiters)
                 (handler-case (js-call r +undefined+ (list +undefined+))
                   (error ())))
               (setf waiters nil)))
            p)
          (progn (setf done t) t)))))

(defun plugin-run-on-load (path &key (namespace "file") loader plugin-data)
  "Run onLoad hooks. Returns plist (:contents :exports :loader :resolve-dir :errors) or NIL."
  (let ((ns (plugin-normalize-namespace namespace))
        (path-str (if (stringp path) path (to-string path))))
    ;; Virtual module callback (builder.module)
    (dolist (entry (plugin-active-entries))
      (let ((cb (cdr (assoc path-str (pe-virtuals entry) :test #'string=))))
        (when (and cb (string= ns "bun-module"))
          (let* ((raw (plugin-call-sync cb nil))
                 (pl (plugin-result-plist raw)))
            (return-from plugin-run-on-load
              (or pl (list :exports (new-object) :loader "object")))))))
    (dolist (entry (plugin-active-entries))
      (dolist (hook (pe-on-load entry))
        (when (and (plugin-namespace-matches (lh-namespace hook) ns)
                   (plugin-filter-matches (lh-filter hook) path-str))
          (let* ((defer-fn (plugin-make-defer))
                 (raw (plugin-call-sync
                       (lh-callback hook)
                       (list :path path-str
                             :namespace ns
                             :loader (or loader "js")
                             :defer defer-fn
                             :plugin-data plugin-data)))
                 (pl (plugin-result-plist raw)))
            (when pl
              (return-from plugin-run-on-load
                (append pl (list :plugin-name (lh-plugin-name hook)))))))))
    nil))

;;; --- onStart ----------------------------------------------------------------

(defun plugin-run-on-start ()
  (dolist (entry (plugin-active-entries))
    (dolist (cb (pe-on-start entry))
      (plugin-call-sync cb nil)))
  t)

;;; --- node:module hooks (exceed) ---------------------------------------------

(defun register-node-module-hooks (&key resolve load)
  "Register sync resolve/load hooks (node:module.registerHooks style)."
  (push (list :resolve resolve :load load) *node-module-hooks*)
  t)

(defun clear-node-module-hooks ()
  (setf *node-module-hooks* nil)
  t)

(defun node-hooks-resolve (specifier referrer-dir)
  "Run node:module resolve hooks. Return path string or NIL."
  (dolist (hooks (reverse *node-module-hooks*))
    (let ((fn (getf hooks :resolve)))
      (when fn
        (let* ((raw (plugin-call-sync
                     fn
                     (list :specifier specifier
                           :context (list :parent-url referrer-dir)
                           :next (lambda (&key specifier)
                                   (declare (ignore specifier))
                                   nil))))
               (pl (plugin-result-plist raw)))
          (when pl
            (let ((url (or (plugin-plist-get pl :url)
                           (plugin-plist-get pl :path)
                           (plugin-plist-get pl :short-circuit))))
              (when url
                (return-from node-hooks-resolve
                  (if (stringp url) url (to-string url))))))))))
  nil)

(defun node-hooks-load (path)
  "Run node:module load hooks. Return plist or NIL."
  (dolist (hooks (reverse *node-module-hooks*))
    (let ((fn (getf hooks :load)))
      (when fn
        (let* ((raw (plugin-call-sync
                     fn
                     (list :url path
                           :context (list :format "module")
                           :next (lambda () nil))))
               (pl (plugin-result-plist raw)))
          (when pl
            (return-from node-hooks-load pl))))))
  nil)

;;; --- format / loader helpers ------------------------------------------------

(defun plugin-loader-keyword (loader)
  (let ((s (cond
             ((null loader) "js")
             ((stringp loader) (string-downcase loader))
             ((js-string-p loader) (string-downcase loader))
             ((symbolp loader) (string-downcase (symbol-name loader)))
             (t (string-downcase (to-string loader))))))
    (cond
      ((member s '("js" "jsx" "ts" "tsx" "mjs" "cjs") :test #'string=) :js)
      ((string= s "json") :json)
      ((string= s "jsonc") :json)
      ((or (string= s "yaml") (string= s "yml")) :yaml)
      ((string= s "object") :object)
      ((string= s "text") :text)
      ((string= s "file") :file)
      ((string= s "toml") :js)          ; treat as source; user supplies JS
      (t :js))))

(defun plugin-contents-string (contents)
  (cond
    ((null contents) nil)
    ((stringp contents) contents)
    ((js-string-p contents) contents)
    ((js-undefined-p contents) nil)
    (t (to-string contents))))

(defun plugin-apply-text-loader (contents)
  "Build export surface for loader:text — default export is the string."
  (let ((o (new-object))
        (s (or (plugin-contents-string contents) "")))
    (data-prop o "default" s)
    o))

(defun plugin-exports-object (exports)
  (cond
    ((js-object-p exports) exports)
    ((null exports) (new-object))
    ((hash-table-p exports)
     (let ((o (new-object)))
       (maphash (lambda (k v) (data-prop o (string k) v)) exports)
       o))
    ((and (listp exports) (keywordp (car exports)))
     (let ((o (new-object)))
       (loop for (k v) on exports by #'cddr
             do (data-prop o (string-downcase (symbol-name k)) v))
       o))
    (t (let ((o (new-object)))
         (data-prop o "default" exports)
         o))))

;;; --- CL registration helpers (pure-CL plugins, exceed) ----------------------
;;; load-plugin-module / resolve-load-dependency live in module-loader.lisp
;;; (they need the graph loader).

(defun register-cl-plugin (&key name priority setup)
  "Register a pure-CL plugin. SETUP receives a builder plist of functions:
  :on-resolve :on-load :on-start :module :config"
  (let ((entry (make-plugin-entry* :name (or name "cl-plugin") :priority (or priority 0))))
    (labels ((on-resolve (constraints callback)
               (push (make-resolve-hook
                      :filter (getf constraints :filter "\.*")
                      :namespace (getf constraints :namespace)
                      :callback callback
                      :chain (getf constraints :chain)
                      :plugin-name (pe-name entry))
                     (pe-on-resolve entry))
               entry)
             (on-load (constraints callback)
               (push (make-load-hook
                      :filter (getf constraints :filter "\.*")
                      :namespace (getf constraints :namespace)
                      :callback callback
                      :plugin-name (pe-name entry))
                     (pe-on-load entry))
               entry)
             (on-start (callback)
               (push callback (pe-on-start entry))
               entry)
             (module (specifier callback)
               (push (cons specifier callback) (pe-virtuals entry))
               entry))
      (when setup
        (funcall setup
                 (list :on-resolve #'on-resolve
                       :on-load #'on-load
                       :on-start #'on-start
                       :module #'module
                       :config nil)))
      ;; reverse hook lists so first-registered runs first
      (setf (pe-on-resolve entry) (nreverse (pe-on-resolve entry))
            (pe-on-load entry) (nreverse (pe-on-load entry))
            (pe-on-start entry) (nreverse (pe-on-start entry))
            (pe-virtuals entry) (nreverse (pe-virtuals entry)))
      (register-plugin-entry entry)
      entry)))
