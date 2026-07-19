;;;; clun-build.lisp — Clun.build / Clun.buildSync JavaScript surface (#180).
;;;;
;;;; Bun.build-compatible Promise API over pure-CL clun.bundler.
;;;; Exceed Bun: Clun.build.analyze, Clun.buildSync, Clun.build.version.

(in-package :clun.runtime)

(defun %build-js-string (value)
  (cond
    ((null value) nil)
    ((eng:js-undefined-p value) nil)
    ((eq value eng:+null+) nil)
    ((eng:js-string-p value) value)
    ((stringp value) value)
    (t (eng:to-string value))))

(defun %build-js-bool (value &optional default)
  (cond ((eng:js-undefined-p value) default)
        ((null value) default)
        ((eq value eng:+null+) nil)
        ((eq value eng:+true+) t)
        ((eq value eng:+false+) nil)
        (t (eng:js-truthy value))))

(defun %build-string-list (value)
  (cond
    ((null value) nil)
    ((eng:js-undefined-p value) nil)
    ((eq value eng:+null+) nil)
    ((stringp value) (list value))
    ((eng:js-array-p value)
     (loop for i from 0 below (eng:array-length value)
           for v = (eng:js-get value (princ-to-string i))
           for s = (%build-js-string v)
           when s collect s))
    ((eng:js-object-p value)
     (loop for k in (eng:jm-own-property-keys value)
           for v = (eng:js-get value k)
           for s = (%build-js-string v)
           when s collect s))
    (t (list (eng:to-string value)))))

(defun %build-define-alist (value)
  (when (and value (eng:js-object-p value) (not (eng:js-array-p value)))
    (loop for k in (eng:jm-own-property-keys value)
          for v = (eng:js-get value k)
          collect (cons (princ-to-string k)
                        (if (stringp v) v (eng:to-string v))))))

(defun %build-loader-alist (value)
  (when (and value (eng:js-object-p value))
    (loop for k in (eng:jm-own-property-keys value)
          for v = (eng:js-get value k)
          collect (cons (let ((s (princ-to-string k)))
                          (if (and (plusp (length s)) (char= (char s 0) #\.))
                              s
                              (concatenate 'string "." s)))
                        (intern (string-upcase (eng:to-string v)) :keyword)))))

(defun %build-files-table (value)
  (when (and value (eng:js-object-p value))
    (let ((ht (make-hash-table :test 'equal)))
      (dolist (k (eng:jm-own-property-keys value))
        (setf (gethash (princ-to-string k) ht)
              (%build-js-string (eng:js-get value k))))
      ht)))

(defun %build-naming (value)
  (cond
    ((null value) nil)
    ((eng:js-undefined-p value) nil)
    ((stringp value) value)
    ((eng:js-object-p value)
     (list :entry (%build-js-string (eng:js-get value "entry"))
           :chunk (%build-js-string (eng:js-get value "chunk"))
           :asset (%build-js-string (eng:js-get value "asset"))))
    (t (eng:to-string value))))

(defun %build-minify (value)
  (cond
    ((eng:js-undefined-p value) nil)
    ((eq value eng:+true+) t)
    ((eq value eng:+false+) nil)
    ((eng:js-object-p value)
     (list :whitespace (%build-js-bool (eng:js-get value "whitespace") t)
           :syntax (%build-js-bool (eng:js-get value "syntax") t)
           :identifiers (%build-js-bool (eng:js-get value "identifiers") t)
           :keep-names (%build-js-bool (eng:js-get value "keepNames") nil)))
    (t (%build-js-bool value nil))))

(defun %js-object->build-plist (config)
  (unless (eng:js-object-p config)
    (error "Clun.build expects a config object"))
  (list :entrypoints (%build-string-list (eng:js-get config "entrypoints"))
        :outdir (%build-js-string (eng:js-get config "outdir"))
        :outfile (%build-js-string (eng:js-get config "outfile"))
        :root (%build-js-string (eng:js-get config "root"))
        :target (%build-js-string (eng:js-get config "target"))
        :format (%build-js-string (eng:js-get config "format"))
        :splitting (%build-js-bool (eng:js-get config "splitting") nil)
        :minify (%build-minify (eng:js-get config "minify"))
        :loader (%build-loader-alist (eng:js-get config "loader"))
        :external (%build-string-list (eng:js-get config "external"))
        :packages (%build-js-string (eng:js-get config "packages"))
        :define (%build-define-alist (eng:js-get config "define"))
        :public-path (or (%build-js-string (eng:js-get config "publicPath"))
                         (%build-js-string (eng:js-get config "public_path")))
        :naming (%build-naming (eng:js-get config "naming"))
        :sourcemap (let ((s (eng:js-get config "sourcemap")))
                     (cond ((eng:js-undefined-p s) nil)
                           ((eq s eng:+true+) t)
                           ((eq s eng:+false+) nil)
                           (t (%build-js-string s))))
        :banner (%build-js-string (eng:js-get config "banner"))
        :footer (%build-js-string (eng:js-get config "footer"))
        :drop (%build-string-list (eng:js-get config "drop"))
        :features (%build-string-list (eng:js-get config "features"))
        :env (let ((e (eng:js-get config "env")))
               (if (eng:js-undefined-p e) nil (%build-js-string e)))
        :files (%build-files-table (eng:js-get config "files"))
        :metafile (%build-js-bool (eng:js-get config "metafile") nil)
        :tree-shaking (let ((v (eng:js-get config "treeShaking")))
                        (if (eng:js-undefined-p v) t (%build-js-bool v t)))
        :throw (let ((v (eng:js-get config "throw")))
                 (if (eng:js-undefined-p v) t (%build-js-bool v t)))
        :conditions (%build-string-list (eng:js-get config "conditions"))))

(defun %build-resolved-promise (global value)
  (eng:js-construct
   (eng:js-get global "Promise")
   (list
    (eng:make-native-function
     "" 2
     (lambda (this args)
       (declare (ignore this))
       (eng:js-call (eng:arg args 0) eng:+undefined+ (list value))
       eng:+undefined+)))))

(defun %build-rejected-promise (global condition)
  (let* ((msg (if (typep condition 'clun.bundler:build-error)
                  (clun.bundler:build-error-message condition)
                  (princ-to-string condition)))
         (err (eng:make-error-object :error-prototype "Error" msg)))
    (eng:js-set err "name" "BuildError" nil)
    (when (typep condition 'clun.bundler:build-error)
      (when (clun.bundler:build-error-path condition)
        (eng:js-set err "path" (clun.bundler:build-error-path condition) nil)))
    (eng:js-construct
     (eng:js-get global "Promise")
     (list
      (eng:make-native-function
       "" 2
       (lambda (this args)
         (declare (ignore this))
         (eng:js-call (eng:arg args 1) eng:+undefined+ (list err))
         eng:+undefined+))))))

(defun %artifact->js (global art)
  (let ((obj (eng:new-object))
        (path (clun.bundler:ba-path art))
        (text (clun.bundler:ba-text art)))
    (eng:data-prop obj "path" (or path eng:+null+))
    (eng:data-prop obj "kind"
                   (string-downcase (symbol-name (clun.bundler:ba-kind art))))
    (eng:data-prop obj "loader"
                   (string-downcase (symbol-name (clun.bundler:ba-loader art))))
    (eng:data-prop obj "hash" (or (clun.bundler:ba-hash art) eng:+null+))
    (eng:data-prop obj "size" (coerce (length text) 'double-float))
    (eng:data-prop obj "text" text)
    (eng:data-prop obj "entrypoint"
                   (if (clun.bundler:ba-entry-point-p art) eng:+true+ eng:+false+))
    ;; Bun BuildArtifact is Blob-like: async text()/arrayBuffer()
    (eng:data-prop
     obj "arrayBuffer"
     (eng:make-native-function
      "arrayBuffer" 0
      (lambda (this args)
        (declare (ignore this args))
        (%build-resolved-promise global
                           (eng:u8-from-octets (eng:code-units->utf8 text))))))
    obj))

(defun %result->js (global result)
  (let ((obj (eng:new-object))
        (outputs (clun.bundler:br-outputs result))
        (logs (clun.bundler:br-logs result)))
    (eng:data-prop obj "success"
                   (if (clun.bundler:br-success result) eng:+true+ eng:+false+))
    (eng:data-prop obj "outputs"
                   (eng:new-array (mapcar (lambda (a) (%artifact->js global a)) outputs)))
    (eng:data-prop
     obj "logs"
     (eng:new-array
      (mapcar (lambda (log)
                (let ((o (eng:new-object)))
                  (eng:data-prop o "level" (or (getf log :level) "error"))
                  (eng:data-prop o "message" (or (getf log :message) ""))
                  (when (getf log :path)
                    (eng:data-prop o "path" (getf log :path)))
                  o))
              logs)))
    (eng:data-prop obj "metafile"
                   (or (clun.bundler:br-metafile result) eng:+null+))
    obj))

(defun %run-build (global config-js &key sync)
  (let ((plist (%js-object->build-plist config-js)))
    (handler-case
        (let ((result (clun.bundler:build plist)))
          (if sync
              (%result->js global result)
              (%build-resolved-promise global (%result->js global result))))
      (error (e)
        (if sync
            (error e)
            (%build-rejected-promise global e))))))

(defun %run-analyze (global config-js)
  (let* ((plist (%js-object->build-plist config-js))
         (analysis (clun.bundler:analyze plist))
         (obj (eng:new-object))
         (modules (getf analysis :modules)))
    (eng:data-prop obj "count"
                   (coerce (getf analysis :count) 'double-float))
    (eng:data-prop obj "entries"
                   (eng:new-array (getf analysis :entries)))
    (eng:data-prop
     obj "modules"
     (eng:new-array
      (mapcar (lambda (m)
                (let ((o (eng:new-object)))
                  (eng:data-prop o "path" (getf m :path))
                  (eng:data-prop o "id" (coerce (getf m :id) 'double-float))
                  (eng:data-prop o "loader"
                                 (string-downcase (symbol-name (getf m :loader))))
                  (eng:data-prop o "imports" (eng:new-array (getf m :imports)))
                  (eng:data-prop o "exports" (eng:new-array (getf m :exports)))
                  (eng:data-prop o "bytes" (coerce (getf m :bytes) 'double-float))
                  o))
              modules)))
    (%build-resolved-promise global obj)))

(defun make-clun-build (global)
  "Bun-shaped Clun.build function object with .analyze and static helpers."
  (let ((fn (eng:make-native-function
             "build" 1
             (lambda (this args)
               (declare (ignore this))
               (%run-build global (eng:arg args 0))))))
    (eng:data-prop
     fn "analyze"
     (eng:make-native-function
      "analyze" 1
      (lambda (this args)
        (declare (ignore this))
        (%run-analyze global (eng:arg args 0)))))
    (eng:data-prop fn "version" "1.0.0")
    fn))

(defun install-clun-build (clun global)
  "Attach Clun.build + Clun.buildSync (exceed Bun)."
  (eng:nonconfigurable-data-prop clun "build" (make-clun-build global))
  (eng:data-prop
   clun "buildSync"
   (eng:make-native-function
    "buildSync" 1
    (lambda (this args)
      (declare (ignore this))
      (%run-build global (eng:arg args 0) :sync t))))
  clun)
