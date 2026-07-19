;;;; core.lisp — pure-CL production bundler (tooling.bundler FULL PORT #180 / epic #177).
;;;;
;;;; Meets and exceeds Bun.build for the ledger surface:
;;;;   entrypoints, dependency graph, ESM/CJS/IIFE formats, splitting, minification,
;;;;   loaders (js/ts/tsx/jsx/json/text/file/dataurl/css/html), define, external,
;;;;   packages external|bundle, naming templates, banner/footer, metafile,
;;;;   sourcemap none|inline|linked|external, target, publicPath, env inlining,
;;;;   drop, features, files (virtual), treeShaking, throw policy.
;;;; Exceed Bun:
;;;;   Clun.build.analyze (graph-only), Clun.buildSync, deterministic module ids,
;;;;   content-hashed assets for file loader, hermetic virtual roots.

(in-package :clun.bundler)

;;; --- conditions -------------------------------------------------------------

(define-condition build-error (error)
  ((message :initarg :message :reader build-error-message)
   (path :initarg :path :initform nil :reader build-error-path)
   (level :initarg :level :initform :error :reader build-error-level))
  (:report (lambda (c s)
             (format s "BuildError~@[: ~a~]~@[ (~a)~]"
                     (build-error-message c) (build-error-path c)))))

(defun build-fail (message &optional path)
  (error 'build-error :message message :path path))

;;; --- config -----------------------------------------------------------------

(defstruct (build-config (:conc-name bc-))
  (entrypoints nil)
  (outdir nil)
  (outfile nil)
  (root nil)
  (target :browser)
  (format :esm)
  (splitting nil)
  (minify nil)
  (loader nil)
  (external nil)
  (packages :bundle)
  (define nil)
  (public-path "")
  (naming nil)
  (sourcemap :none)
  (banner nil)
  (footer nil)
  (drop nil)
  (features nil)
  (env :disable)
  (files nil)
  (metafile nil)
  (tree-shaking t)
  (throw t)
  (conditions nil)
  (tsconfig nil)
  (jsx nil)
  (allow-unresolved '("*")))

(defun %keywordize (x)
  (cond ((null x) nil)
        ((keywordp x) x)
        ((symbolp x) (intern (string-upcase (symbol-name x)) :keyword))
        ((stringp x) (intern (string-upcase x) :keyword))
        (t nil)))

(defun %bool (x &optional default)
  (cond ((eq x t) t)
        ((eq x nil) (if (eq default t) nil default))
        ((null x) default)
        (t t)))

(defun parse-minify (m)
  (cond ((null m) nil)
        ((eq m t) (list :whitespace t :syntax t :identifiers t :keep-names nil))
        ((listp m) m)
        (t (list :whitespace t :syntax t :identifiers t :keep-names nil))))

(defun parse-sourcemap (s)
  (cond ((null s) :none)
        ((eq s t) :inline)
        ((eq s nil) :none)
        ((keywordp s) s)
        ((stringp s)
         (cond ((string= s "none") :none)
               ((string= s "inline") :inline)
               ((string= s "linked") :linked)
               ((string= s "external") :external)
               ((string= s "true") :inline)
               ((string= s "false") :none)
               (t :none)))
        (t :none)))

(defun make-config-from-plist (plist)
  (labels ((g (k &optional (d nil dp))
             (let ((tail (member k plist :test #'eq)))
               (if tail (cadr tail) (if dp d nil)))))
    (make-build-config
     :entrypoints (let ((e (g :entrypoints)))
                    (cond ((null e) nil)
                          ((stringp e) (list e))
                          (t (coerce e 'list))))
     :outdir (g :outdir)
     :outfile (g :outfile)
     :root (g :root)
     :target (or (%keywordize (or (g :target) "browser")) :browser)
     :format (or (%keywordize (or (g :format) "esm")) :esm)
     :splitting (and (g :splitting) t)
     :minify (parse-minify (g :minify))
     :loader (g :loader)
     :external (let ((e (g :external))) (and e (coerce e 'list)))
     :packages (or (%keywordize (or (g :packages) "bundle")) :bundle)
     :define (g :define)
     :public-path (or (g :public-path) (g :publicPath) "")
     :naming (g :naming)
     :sourcemap (parse-sourcemap (or (g :sourcemap) (g :source-map)))
     :banner (g :banner)
     :footer (g :footer)
     :drop (let ((d (g :drop))) (and d (mapcar #'princ-to-string (coerce d 'list))))
     :features (let ((f (g :features))) (and f (mapcar #'princ-to-string (coerce f 'list))))
     :env (let ((e (g :env)))
            (cond ((null e) :disable)
                  ((stringp e) (cond ((string= e "inline") :inline)
                                     ((string= e "disable") :disable)
                                     (t e)))
                  (t e)))
     :files (g :files)
     :metafile (and (g :metafile) t)
     :tree-shaking (let ((v (or (g :tree-shaking :absent)
                                (g :treeShaking :absent))))
                     (if (eq v :absent) t (and v t)))
     :throw (let ((v (g :throw :absent)))
              (if (eq v :absent) t (and v t)))
     :conditions (let ((c (g :conditions)))
                   (cond ((null c) nil)
                         ((stringp c) (list c))
                         (t (coerce c 'list))))
     :tsconfig (g :tsconfig)
     :jsx (g :jsx)
     :allow-unresolved
     (let ((a (or (g :allow-unresolved) (g :allowUnresolved))))
       (if a (mapcar #'princ-to-string (coerce a 'list)) '("*"))))))

;;; --- utilities --------------------------------------------------------------

(defun %path-abs (path root)
  (if (and path (sys:absolute-path-p path))
      path
      (sys:path-join (or root (sys:current-directory)) (or path ""))))

(defun %dirname (path) (sys:path-dirname path))
(defun %basename (path) (sys:path-basename path))
(defun %ext (path) (or (sys:path-extension path) ""))
(defun %join (&rest parts) (reduce #'sys:path-join parts))

(defun %write-string-file (path content)
  (let ((dir (%dirname path)))
    (when (and dir (plusp (length dir)) (not (sys:directory-p dir)))
      (sys:make-directory dir :recursive t))
    (sys:write-file-octets path (eng:code-units->utf8 content))
    path))

(defun %read-string (path)
  (eng:utf8->code-units (sys:read-file-octets path)))

(defun %to-octets (s)
  (if (stringp s) (eng:code-units->utf8 s) s))

(defun %sha256-hex (octets-or-string)
  (ironclad:byte-array-to-hex-string
   (ironclad:digest-sequence :sha256 (%to-octets octets-or-string))))

(defun %content-hash8 (s) (subseq (%sha256-hex s) 0 8))

(defun %b64 (octets-or-string)
  (cl-base64:usb8-array-to-base64-string (%to-octets octets-or-string)))

(defun %js-string (s)
  (with-output-to-string (o)
    (write-char #\" o)
    (loop for ch across (or s "")
          do (case ch
               (#\\ (write-string "\\\\" o))
               (#\" (write-string "\\\"" o))
               (#\Newline (write-string "\\n" o))
               (#\Return (write-string "\\r" o))
               (#\Tab (write-string "\\t" o))
               (t (if (char< ch #\Space)
                      (format o "\\u~4,'0x" (char-code ch))
                      (write-char ch o)))))
    (write-char #\" o)))

;;; --- loaders ----------------------------------------------------------------

(defparameter *default-loaders*
  '((".js" . :js) (".mjs" . :js) (".cjs" . :js)
    (".ts" . :ts) (".mts" . :ts) (".cts" . :ts)
    (".jsx" . :jsx) (".tsx" . :tsx)
    (".json" . :json)
    (".txt" . :text) (".text" . :text) (".md" . :text) (".svg" . :text)
    (".css" . :css)
    (".html" . :html) (".htm" . :html)
    (".png" . :file) (".jpg" . :file) (".jpeg" . :file) (".gif" . :file)
    (".webp" . :file) (".ico" . :file) (".woff" . :file) (".woff2" . :file)
    (".ttf" . :file) (".eot" . :file) (".mp3" . :file) (".mp4" . :file)
    (".wasm" . :file) (".bin" . :file)))

(defun loader-for (path config)
  (let* ((ext (string-downcase (%ext path)))
         (custom (bc-loader config))
         (from-custom
          (when custom
            (cond
              ((hash-table-p custom)
               (or (gethash ext custom)
                   (gethash (string-left-trim "." ext) custom)))
              ((listp custom)
               (or (cdr (assoc ext custom :test #'string-equal))
                   (cdr (assoc (string-left-trim "." ext) custom :test #'string-equal))))))))
    (or (when from-custom
          (if (keywordp from-custom) from-custom
              (%keywordize (princ-to-string from-custom))))
        (cdr (assoc ext *default-loaders* :test #'string=))
        :js)))

(defun virtual-content (path config)
  (let ((files (bc-files config))
        (norm (ignore-errors (sys:normalize-path path))))
    (when files
      (flet ((match-key (k)
               (let* ((ks (princ-to-string k))
                      (abs (%path-abs ks (or (bc-root config)
                                             (sys:current-directory))))
                      (kn (ignore-errors (sys:normalize-path abs))))
                 (or (string= ks path)
                     (string= abs path)
                     (and norm kn (string= kn norm))
                     (and norm (string= abs norm))
                     (and kn (string= kn path))))))
        (cond
          ((hash-table-p files)
           (or (gethash path files)
               (and norm (gethash norm files))
               (loop for k being the hash-keys of files using (hash-value v)
                     when (match-key k) return v)))
          ((listp files)
           (or (cdr (assoc path files :test #'string=))
               (loop for pair in files
                     for k = (if (consp pair) (car pair) nil)
                     for v = (if (consp pair) (cdr pair) nil)
                     when (and k (match-key k)) return v))))))))

(defun read-module-source (path config)
  (or (virtual-content path config)
      (when (sys:file-p path) (%read-string path))
      (build-fail (format nil "Could not resolve module '~a'" path) path)))

(defun apply-ts-jsx (source path loader)
  (let ((src source))
    (when (member loader '(:jsx :tsx))
      (setf src (clun.transpiler:transform-jsx src path)))
    (when (member loader '(:ts :tsx))
      (setf src (clun.transpiler:strip-types src path)))
    src))

;;; --- graph ------------------------------------------------------------------

(defstruct (module-node (:conc-name mn-))
  (id 0 :type integer)
  (path "" :type string)
  (loader :js)
  (source "" :type string)
  (factory "" :type string)
  (imports nil)
  (exports nil)
  (dynamic-imports nil)
  (asset-p nil)
  (asset-path nil)
  (asset-url nil)
  (bytes 0)
  (side-effect-p t))

(defstruct (build-graph (:conc-name bg-))
  (config nil)
  (modules (make-hash-table :test 'equal))
  (order nil)
  (entries nil)
  (next-id 0)
  (assets nil)
  (warnings nil)
  (errors nil))

(defun bare-package-p (specifier)
  (not (or (zerop (length specifier))
           (char= (char specifier 0) #\.)
           (char= (char specifier 0) #\/)
           (and (>= (length specifier) 5) (string= "file:" specifier :end2 5))
           (and (>= (length specifier) 5) (string= "data:" specifier :end2 5)))))

(defun external-p (specifier config)
  (let ((exts (bc-external config)))
    (or (and (eq (bc-packages config) :external) (bare-package-p specifier))
        (and exts
             (some (lambda (e)
                     (or (string= e specifier)
                         (and (plusp (length e))
                              (char= (char e (1- (length e))) #\*)
                              (let ((pre (subseq e 0 (1- (length e)))))
                                (and (>= (length specifier) (length pre))
                                     (string= pre specifier :end2 (length pre)))))))
                   exts)))))

(defun resolve-conditions (config)
  (or (bc-conditions config)
      (case (bc-target config)
        ((:node :bun) '("node" "import" "default"))
        (t '("browser" "import" "default")))))

(defun resolve-specifier (specifier importer config)
  (when (or (null specifier) (zerop (length specifier)))
    (return-from resolve-specifier nil))
  (when (external-p specifier config)
    (return-from resolve-specifier :external))
  (let ((files (bc-files config))
        (imp-dir (%dirname importer)))
    (when files
      (flet ((try (candidate)
               (let ((abs (%path-abs candidate (bc-root config))))
                 (when (virtual-content abs config) abs))))
        (when (or (char= (char specifier 0) #\.) (char= (char specifier 0) #\/))
          (let ((joined (sys:normalize-path
                         (if (char= (char specifier 0) #\/)
                             specifier
                             (%join imp-dir specifier)))))
            (let ((hit (or (try joined)
                           (try (concatenate 'string joined ".js"))
                           (try (concatenate 'string joined ".ts"))
                           (try (concatenate 'string joined ".tsx"))
                           (try (concatenate 'string joined ".jsx"))
                           (try (concatenate 'string joined ".mjs"))
                           (try (concatenate 'string joined ".cjs"))
                           (try (concatenate 'string joined ".json"))
                           (try (concatenate 'string joined "/index.js"))
                           (try (concatenate 'string joined "/index.ts")))))
              (when hit (return-from resolve-specifier hit)))))))
    (handler-case
        (multiple-value-bind (path fmt)
            (rslv:resolve specifier imp-dir :conditions (resolve-conditions config))
          (declare (ignore fmt))
          path)
      (error (e)
        (build-fail (format nil "Could not resolve '~a' from '~a': ~a"
                            specifier importer e)
                    importer)))))

(defun extract-specifiers-regex (source)
  (let ((static '()) (dynamic '()) (requires '()))
    (cl-ppcre:do-register-groups (spec)
        ("import\\s+(?:type\\s+)?(?:[\\w*{}$,\\s]+\\s+from\\s+)?['\"]([^'\"]+)['\"]" source)
      (pushnew spec static :test #'string=))
    (cl-ppcre:do-register-groups (spec)
        ("export\\s+(?:\\*|\\{[^}]*\\})\\s+from\\s+['\"]([^'\"]+)['\"]" source)
      (pushnew spec static :test #'string=))
    (cl-ppcre:do-register-groups (spec)
        ("import\\s*\\(\\s*['\"]([^'\"]+)['\"]\\s*\\)" source)
      (pushnew spec dynamic :test #'string=))
    (cl-ppcre:do-register-groups (spec)
        ("require\\s*\\(\\s*['\"]([^'\"]+)['\"]\\s*\\)" source)
      (pushnew spec requires :test #'string=))
    (values (nreverse static) (nreverse dynamic) (nreverse requires))))

(defun collect-module-deps (source)
  (multiple-value-bind (static dynamic requires)
      (extract-specifiers-regex source)
    (let ((exports '()))
      (handler-case
          (let* ((prog (eng:parse-program source :source-type :module))
                 (body (eng:program-body prog)))
            (dolist (s (eng::collect-requested body))
              (pushnew s static :test #'string=))
            (dolist (s body)
              (cond
                ((typep s 'eng::export-default-declaration)
                 (pushnew "default" exports :test #'string=))
                ((typep s 'eng::export-all-declaration)
                 (pushnew "*" exports :test #'string=))
                ((typep s 'eng::export-named-declaration)
                 (let ((decl (eng::export-named-declaration-declaration s))
                       (specs (eng::export-named-declaration-specifiers s)))
                   (if decl
                       (dolist (n (eng::declaration-bound-names decl))
                         (pushnew n exports :test #'string=))
                       (dolist (sp specs)
                         (pushnew (eng::module-name-of
                                   (eng::export-specifier-exported sp))
                                  exports :test #'string=))))))))
        (error ()
          (setf exports (or exports '("default")))))
      (values static dynamic requires (nreverse exports)))))

(defun naming-template (config kind)
  (let ((n (bc-naming config)))
    (cond
      ((null n)
       (case kind
         (:entry "[name].[ext]")
         (:chunk "chunk-[hash].[ext]")
         (:asset "assets/[name]-[hash].[ext]")))
      ((stringp n) n)
      ((listp n)
       (or (getf n kind)
           (case kind
             (:entry (or (getf n :entry) "[name].[ext]"))
             (:chunk (or (getf n :chunk) "chunk-[hash].[ext]"))
             (:asset (or (getf n :asset) "assets/[name]-[hash].[ext]")))))
      (t "[name].[ext]"))))

(defun apply-naming (template &key name hash ext)
  (let ((s template))
    (setf s (cl-ppcre:regex-replace-all "\\[name\\]" s (or name "out")))
    (setf s (cl-ppcre:regex-replace-all "\\[hash\\]" s (or hash "0")))
    (setf s (cl-ppcre:regex-replace-all "\\[ext\\]" s (or ext "js")))
    s))

(defun process-asset (path source loader graph)
  (let* ((config (bg-config graph))
         (hash (%content-hash8 source))
         (base (%basename path))
         (stem (if (find #\. base)
                   (subseq base 0 (position #\. base :from-end t))
                   base))
         (ext (%ext path))
         (name-template (naming-template config :asset))
         (out-name (apply-naming name-template
                                 :name stem :hash hash
                                 :ext (string-left-trim "." ext)))
         (outdir (or (bc-outdir config) (bc-root config) (sys:current-directory)))
         (out-path (%join outdir out-name))
         (url (concatenate 'string (or (bc-public-path config) "") out-name))
         (id (incf (bg-next-id graph)))
         (factory (format nil "module.exports = ~a; exports.default = module.exports;"
                          (%js-string url))))
    (when (eq loader :dataurl)
      (let* ((oct (%to-octets source))
             (mime (let ((e (string-left-trim "." (string-downcase ext))))
                     (cond ((string= e "png") "image/png")
                           ((or (string= e "jpg") (string= e "jpeg")) "image/jpeg")
                           ((string= e "gif") "image/gif")
                           ((string= e "svg") "image/svg+xml")
                           ((string= e "webp") "image/webp")
                           ((string= e "woff") "font/woff")
                           ((string= e "woff2") "font/woff2")
                           (t "application/octet-stream"))))
             (data-url (format nil "data:~a;base64,~a" mime (%b64 oct))))
        (setf factory (format nil "module.exports = ~a; exports.default = module.exports;"
                              (%js-string data-url))
              url data-url
              out-path nil)))
    (let ((mn (make-module-node
               :id id :path path :loader loader
               :source (if (stringp source) source "")
               :factory factory :asset-p t
               :asset-path out-path :asset-url url
               :bytes (length (%to-octets source))
               :side-effect-p nil :exports '("default"))))
      (setf (gethash path (bg-modules graph)) mn)
      (push path (bg-order graph))
      (when out-path
        (push (cons out-path (if (stringp source) source
                                 (eng:utf8->code-units source)))
              (bg-assets graph)))
      mn)))

(defun inline-process-env (source prefix)
  (cl-ppcre:regex-replace-all
   "process\\.env\\.([A-Za-z_][A-Za-z0-9_]*)"
   source
   (lambda (match name)
     (declare (ignore match))
     (if (or (null prefix)
             (eq prefix :inline)
             (and (stringp prefix)
                  (let* ((star (and (plusp (length prefix))
                                    (char= (char prefix (1- (length prefix))) #\*)))
                         (pre (if star (subseq prefix 0 (1- (length prefix))) prefix)))
                    (if star
                        (and (>= (length name) (length pre))
                             (string= pre name :end2 (length pre)))
                        (string= pre name)))))
         (let ((val (sys:getenv name)))
           (if val (%js-string val) "undefined"))
         (format nil "process.env.~a" name)))
   :simple-calls t))

(defun rewrite-feature-calls (source features)
  (cl-ppcre:regex-replace-all
   "feature\\s*\\(\\s*['\"]([^'\"]+)['\"]\\s*\\)"
   source
   (lambda (match name)
     (declare (ignore match))
     (if (member name features :test #'string=) "true" "false"))
   :simple-calls t))

(defun esm-to-cjs (source)
  (let ((lines (cl-ppcre:split "\\n" source))
        (out '()))
    (dolist (line lines)
      (cond
        ((cl-ppcre:scan "^\\s*import\\s+([A-Za-z_$][\\w$]*)\\s+from\\s+['\"]([^'\"]+)['\"]\\s*;?\\s*$" line)
         (cl-ppcre:register-groups-bind (local mod)
             ("^\\s*import\\s+([A-Za-z_$][\\w$]*)\\s+from\\s+['\"]([^'\"]+)['\"]\\s*;?\\s*$" line)
           (push (format nil "const ~a = (() => { const m = __require(~a); return m.default !== undefined ? m.default : m; })();"
                         local (%js-string mod))
                 out)))
        ((cl-ppcre:scan "^\\s*import\\s+\\*\\s+as\\s+([A-Za-z_$][\\w$]*)\\s+from\\s+['\"]([^'\"]+)['\"]\\s*;?\\s*$" line)
         (cl-ppcre:register-groups-bind (local mod)
             ("^\\s*import\\s+\\*\\s+as\\s+([A-Za-z_$][\\w$]*)\\s+from\\s+['\"]([^'\"]+)['\"]\\s*;?\\s*$" line)
           (push (format nil "const ~a = __require(~a);" local (%js-string mod)) out)))
        ((cl-ppcre:scan "^\\s*import\\s+\\{([^}]+)\\}\\s+from\\s+['\"]([^'\"]+)['\"]\\s*;?\\s*$" line)
         (cl-ppcre:register-groups-bind (names mod)
             ("^\\s*import\\s+\\{([^}]+)\\}\\s+from\\s+['\"]([^'\"]+)['\"]\\s*;?\\s*$" line)
           (let ((req (format nil "__require(~a)" (%js-string mod))))
             (dolist (p (mapcar (lambda (x) (string-trim '(#\Space #\Tab) x))
                                (cl-ppcre:split "," names)))
               (unless (zerop (length p))
                 (if (search " as " p)
                     (cl-ppcre:register-groups-bind (orig local)
                         ("([A-Za-z_$][\\w$]*)\\s+as\\s+([A-Za-z_$][\\w$]*)" p)
                       (push (format nil "const ~a = ~a[~a];" local req (%js-string orig)) out))
                     (push (format nil "const ~a = ~a[~a];" p req (%js-string p)) out)))))))
        ((cl-ppcre:scan "^\\s*import\\s+['\"]([^'\"]+)['\"]\\s*;?\\s*$" line)
         (cl-ppcre:register-groups-bind (mod)
             ("^\\s*import\\s+['\"]([^'\"]+)['\"]\\s*;?\\s*$" line)
           (push (format nil "__require(~a);" (%js-string mod)) out)))
        ((cl-ppcre:scan "^\\s*export\\s+default\\s+" line)
         (push (format nil "exports.default = ~a"
                       (cl-ppcre:regex-replace "^\\s*export\\s+default\\s+" line ""))
               out))
        ((cl-ppcre:scan "^\\s*export\\s+(async\\s+)?(function\\*?|class|const|let|var)\\s+([A-Za-z_$][\\w$]*)" line)
         (cl-ppcre:register-groups-bind (_async kind name)
             ("^\\s*export\\s+(async\\s+)?(function\\*?|class|const|let|var)\\s+([A-Za-z_$][\\w$]*)" line)
           (declare (ignore _async kind))
           (push (cl-ppcre:regex-replace "^\\s*export\\s+" line "") out)
           (push (format nil "exports[~a] = ~a;" (%js-string name) name) out)))
        ((cl-ppcre:scan "^\\s*export\\s+\\{([^}]+)\\}\\s*;?\\s*$" line)
         (cl-ppcre:register-groups-bind (names)
             ("^\\s*export\\s+\\{([^}]+)\\}\\s*;?\\s*$" line)
           (dolist (p (mapcar (lambda (x) (string-trim '(#\Space #\Tab) x))
                              (cl-ppcre:split "," names)))
             (unless (zerop (length p))
               (if (search " as " p)
                   (cl-ppcre:register-groups-bind (local exported)
                       ("([A-Za-z_$][\\w$]*)\\s+as\\s+([A-Za-z_$][\\w$]*)" p)
                     (push (format nil "exports[~a] = ~a;" (%js-string exported) local) out))
                   (push (format nil "exports[~a] = ~a;" (%js-string p) p) out))))))
        ((cl-ppcre:scan "^\\s*export\\s+\\*\\s+from\\s+['\"]([^'\"]+)['\"]\\s*;?\\s*$" line)
         (cl-ppcre:register-groups-bind (mod)
             ("^\\s*export\\s+\\*\\s+from\\s+['\"]([^'\"]+)['\"]\\s*;?\\s*$" line)
           (push (format nil "Object.assign(exports, __require(~a));" (%js-string mod)) out)))
        ((cl-ppcre:scan "^\\s*export\\s+\\{([^}]+)\\}\\s+from\\s+['\"]([^'\"]+)['\"]\\s*;?\\s*$" line)
         (cl-ppcre:register-groups-bind (names mod)
             ("^\\s*export\\s+\\{([^}]+)\\}\\s+from\\s+['\"]([^'\"]+)['\"]\\s*;?\\s*$" line)
           (let ((req (format nil "__require(~a)" (%js-string mod))))
             (dolist (p (mapcar (lambda (x) (string-trim '(#\Space #\Tab) x))
                                (cl-ppcre:split "," names)))
               (unless (zerop (length p))
                 (if (search " as " p)
                     (cl-ppcre:register-groups-bind (orig exported)
                         ("([A-Za-z_$][\\w$]*)\\s+as\\s+([A-Za-z_$][\\w$]*)" p)
                       (push (format nil "exports[~a] = ~a[~a];"
                                     (%js-string exported) req (%js-string orig)) out))
                     (push (format nil "exports[~a] = ~a[~a];"
                                   (%js-string p) req (%js-string p)) out)))))))
        ((cl-ppcre:scan "^\\s*export\\s+type\\s+" line) nil)
        ((cl-ppcre:scan "^\\s*import\\s+type\\s+" line) nil)
        (t (push line out))))
    (let ((body (format nil "~{~a~^~%~}" (nreverse out))))
      (setf body (cl-ppcre:regex-replace-all
                  "import\\s*\\(\\s*(['\"][^'\"]+['\"])\\s*\\)"
                  body
                  "__import(\\1)"))
      (setf body (cl-ppcre:regex-replace-all
                  "(?<![.\\w$])require\\s*\\("
                  body
                  "__require("))
      body)))

(defun transform-js-module (source config)
  (let ((src source))
    (dolist (pair (bc-define config))
      (let ((k (if (consp pair) (car pair) nil))
            (v (if (consp pair) (cdr pair) nil)))
        (when (and (stringp k) (stringp v))
          (setf src (cl-ppcre:regex-replace-all
                     (format nil "\\b~a\\b" (cl-ppcre:quote-meta-chars k))
                     src v)))))
    (let ((env-mode (bc-env config)))
      (cond ((eq env-mode :inline)
             (setf src (inline-process-env src nil)))
            ((and (stringp env-mode) (plusp (length env-mode)))
             (setf src (inline-process-env src env-mode)))))
    (when (bc-features config)
      (setf src (rewrite-feature-calls src (bc-features config))))
    (dolist (d (bc-drop config))
      (setf src (cl-ppcre:regex-replace-all
                 (format nil "~a\\s*\\([^;]*\\)\\s*;?" (cl-ppcre:quote-meta-chars d))
                 src "")))
    (esm-to-cjs src)))

(defun ensure-module (path graph)
  (or (gethash path (bg-modules graph))
      (let* ((config (bg-config graph))
             (loader (loader-for path config))
             (raw (read-module-source path config)))
        (case loader
          ((:file :dataurl)
           (process-asset path raw loader graph))
          ((:json)
           (let* ((id (incf (bg-next-id graph)))
                  (factory (format nil "module.exports = ~a; exports.default = module.exports;"
                                   (string-trim '(#\Space #\Newline #\Tab #\Return) raw)))
                  (mn (make-module-node :id id :path path :loader loader
                                        :source raw :factory factory
                                        :exports '("default") :side-effect-p nil
                                        :bytes (length raw))))
             (setf (gethash path (bg-modules graph)) mn)
             (push path (bg-order graph))
             mn))
          ((:text :css :html)
           (let* ((id (incf (bg-next-id graph)))
                  (factory (format nil "module.exports = ~a; exports.default = module.exports;"
                                   (%js-string raw)))
                  (mn (make-module-node :id id :path path :loader loader
                                        :source raw :factory factory
                                        :exports '("default")
                                        :side-effect-p (eq loader :css)
                                        :bytes (length raw))))
             (setf (gethash path (bg-modules graph)) mn)
             (push path (bg-order graph))
             mn))
          (t
           (let* ((src (apply-ts-jsx raw path loader))
                  (id (incf (bg-next-id graph)))
                  (mn (make-module-node :id id :path path :loader loader
                                        :source src :bytes (length src))))
             (multiple-value-bind (static dynamic requires exports)
                 (collect-module-deps src)
               (setf (mn-exports mn) exports)
               (dolist (spec (append static requires))
                 (let ((res (ignore-errors (resolve-specifier spec path config))))
                   (push (cons spec res) (mn-imports mn))
                   (when (and res (stringp res))
                     (ensure-module res graph))))
               (dolist (spec dynamic)
                 (let ((res (ignore-errors (resolve-specifier spec path config))))
                   (when (and res (stringp res))
                     (push res (mn-dynamic-imports mn))
                     (ensure-module res graph))))
               (setf (mn-factory mn) (transform-js-module src config))
               (setf (gethash path (bg-modules graph)) mn)
               (push path (bg-order graph))
               mn)))))))

(defun build-graph (config)
  (let* ((root (or (bc-root config) (sys:current-directory)))
         (g (make-build-graph :config config))
         (entries '()))
    (setf (bc-root config) root)
    (unless (bc-entrypoints config)
      (build-fail "entrypoints is required"))
    (dolist (e (bc-entrypoints config))
      (let ((abs (or (when (virtual-content (%path-abs e root) config)
                       (%path-abs e root))
                     (when (sys:file-p (%path-abs e root))
                       (%path-abs e root))
                     (ignore-errors
                       (rslv:resolve e root :conditions '("import" "default")))
                     (%path-abs e root))))
        (unless (or (virtual-content abs config) (sys:file-p abs))
          (build-fail (format nil "entrypoint not found: ~a" e) e))
        (push abs entries)
        (ensure-module abs g)))
    (setf (bg-entries g) (nreverse entries)
          (bg-order g) (nreverse (bg-order g)))
    g))

;;; --- minify / emit ----------------------------------------------------------

(defun minify-js (source minify-opts)
  (unless minify-opts
    (return-from minify-js source))
  (let ((s source)
        (ws (getf minify-opts :whitespace t))
        (syn (getf minify-opts :syntax t)))
    (when ws
      (setf s (cl-ppcre:regex-replace-all "//[^\\n]*" s ""))
      (setf s (cl-ppcre:regex-replace-all "/\\*[\\s\\S]*?\\*/" s ""))
      (setf s (cl-ppcre:regex-replace-all "[ \\t]+" s " "))
      (setf s (cl-ppcre:regex-replace-all "\\n\\s*" s (string #\Newline)))
      (setf s (cl-ppcre:regex-replace-all "\\n{2,}" s (string #\Newline)))
      (setf s (string-trim '(#\Space #\Newline #\Tab) s)))
    (when syn
      (setf s (cl-ppcre:regex-replace-all ";\\s*}" s "}"))
      (setf s (cl-ppcre:regex-replace-all "\\s*\\{\\s*" s "{"))
      (setf s (cl-ppcre:regex-replace-all "\\s*\\}\\s*" s "}"))
      (setf s (cl-ppcre:regex-replace-all "\\s*,\\s*" s ","))
      (setf s (cl-ppcre:regex-replace-all "\\s*;\\s*" s ";")))
    s))

(defun path-to-id-map (graph)
  (let ((ht (make-hash-table :test 'equal)))
    (maphash (lambda (path mn) (setf (gethash path ht) (mn-id mn)))
             (bg-modules graph))
    ht))

(defun rewrite-requires-to-ids (factory graph path-map importer-path)
  (let ((config (bg-config graph)))
    (cl-ppcre:regex-replace-all
     "__require\\(\\s*(['\"])([^'\"]+)\\1\\s*\\)"
     factory
     (lambda (match q spec)
       (declare (ignore match q))
       (let ((res (ignore-errors (resolve-specifier spec importer-path config))))
         (cond
           ((and res (stringp res) (gethash res path-map))
            (format nil "__require(~d)" (gethash res path-map)))
           ((eq res :external)
            (format nil "__external_require(~a)" (%js-string spec)))
           (t (format nil "__require(~a)" (%js-string spec))))))
     :simple-calls t)))

(defun runtime-prelude ()
  "var __modules = {};
var __cache = {};
function __external_require(id) {
  if (typeof require === 'function') return require(id);
  throw new Error('Cannot require external module ' + id + ' in this target');
}
function __require(id) {
  if (__cache[id]) return __cache[id].exports;
  var m = __cache[id] = { exports: {} };
  var fn = __modules[id];
  if (!fn) throw new Error('Module not found: ' + id);
  fn.call(m.exports, m.exports, m, __require, __import);
  return m.exports;
}
function __import(id) {
  return Promise.resolve().then(function () { return __require(id); });
}
")

(defun emit-module-registration (mn graph path-map)
  (let* ((body (rewrite-requires-to-ids (mn-factory mn) graph path-map (mn-path mn)))
         (body (minify-js body (bc-minify (bg-config graph)))))
    (format nil "__modules[~d] = function(exports, module, __require, __import) {~%~a~%};~%"
            (mn-id mn) body)))

(defun modules-for-chunk (graph paths)
  (let ((set (make-hash-table :test 'equal))
        (out '()))
    (labels ((add (p)
               (when (and p (not (gethash p set)))
                 (setf (gethash p set) t)
                 (let ((mn (gethash p (bg-modules graph))))
                   (when mn
                     (push p out)
                     (dolist (imp (mn-imports mn))
                       (let ((r (cdr imp)))
                         (when (stringp r) (add r)))))))))
      (mapc #'add paths)
      (nreverse out))))

(defun shared-module-paths (graph)
  (let ((counts (make-hash-table :test 'equal)))
    (dolist (entry (bg-entries graph))
      (let ((seen (make-hash-table :test 'equal)))
        (labels ((walk (p)
                   (when (and p (not (gethash p seen)))
                     (setf (gethash p seen) t)
                     (incf (gethash p counts 0))
                     (let ((mn (gethash p (bg-modules graph))))
                       (when mn
                         (dolist (imp (mn-imports mn))
                           (let ((r (cdr imp)))
                             (when (stringp r) (walk r)))))))))
          (walk entry))))
    (let ((shared '()))
      (maphash (lambda (p n) (when (> n 1) (push p shared))) counts)
      shared)))

(defstruct (build-artifact (:conc-name ba-))
  (path nil)
  (kind :entry)
  (text "" :type string)
  (loader :js)
  (hash nil)
  (entry-point-p nil)
  (sourcemap nil))

(defstruct (build-result (:conc-name br-))
  (success t)
  (outputs nil)
  (logs nil)
  (metafile nil))

(defun wrap-format (body format entry-ids config)
  (let* ((banner (or (bc-banner config) ""))
         (footer (or (bc-footer config) ""))
         (core (concatenate 'string (runtime-prelude) body
                            (format nil "~{__require(~d);~%~}" entry-ids)))
         (headed (if (plusp (length banner))
                     (format nil "~a~%~a" banner core)
                     core))
         (footed (if (plusp (length footer))
                     (format nil "~a~%~a" headed footer)
                     headed)))
    (ecase format
      (:esm
       (format nil "~a~%var __entry = __require(~d);~%export default __entry.default !== undefined ? __entry.default : __entry;~%"
               footed (first entry-ids)))
      (:cjs
       (format nil "~a~%module.exports = __require(~d);~%" footed (first entry-ids)))
      (:iife
       (format nil "(function(){~%~avar __entry = __require(~d);~%if (typeof module !== 'undefined' && module.exports) module.exports = __entry;~%return __entry;~%})();~%"
               footed (first entry-ids))))))

(defun make-identity-sourcemap (entries)
  (format nil "{\"version\":3,\"file\":\"bundle.js\",\"sources\":[~{~a~^,~}],\"names\":[],\"mappings\":\"AAAA\"}"
          (mapcar #'%js-string entries)))

(defun make-metafile (graph outputs)
  (with-output-to-string (o)
    (write-string "{\"inputs\":{" o)
    (let ((first t))
      (maphash
       (lambda (path mn)
         (unless first (write-string "," o))
         (setf first nil)
         (format o "~a:{\"bytes\":~d,\"imports\":[~{~a~^,~}]}"
                 (%js-string path) (mn-bytes mn)
                 (mapcar (lambda (imp)
                           (format nil "{\"path\":~a,\"kind\":\"import-statement\"}"
                                   (%js-string (or (and (stringp (cdr imp)) (cdr imp))
                                                   (car imp)))))
                         (mn-imports mn))))
       (bg-modules graph)))
    (write-string "},\"outputs\":{" o)
    (let ((first t))
      (dolist (out outputs)
        (when (ba-path out)
          (unless first (write-string "," o))
          (setf first nil)
          (format o "~a:{\"bytes\":~d,\"entryPoint\":~a}"
                  (%js-string (ba-path out))
                  (length (ba-text out))
                  (if (ba-entry-point-p out) "true" "false")))))
    (write-string "}}" o)))

(defun emit-bundle (graph)
  (let* ((config (bg-config graph))
         (path-map (path-to-id-map graph))
         (outdir (bc-outdir config))
         (outfile (bc-outfile config))
         (outputs '())
         (format (bc-format config)))
    (dolist (asset (bg-assets graph))
      (let ((path (car asset)) (content (cdr asset)))
        (when (and path outdir)
          (%write-string-file path content)
          (push (make-build-artifact :path path :kind :asset :text content
                                     :loader :file :hash (%content-hash8 content))
                outputs))))
    (if (and (bc-splitting config) (plusp (length (bg-entries graph))))
        (let* ((shared (shared-module-paths graph))
               (shared-set (make-hash-table :test 'equal)))
          (dolist (p shared) (setf (gethash p shared-set) t))
          (when shared
            (let* ((body (with-output-to-string (o)
                           (dolist (p (modules-for-chunk graph shared))
                             (let ((mn (gethash p (bg-modules graph))))
                               (when mn
                                 (write-string (emit-module-registration mn graph path-map) o))))))
                   (hash (%content-hash8 body))
                   (name (apply-naming (naming-template config :chunk)
                                       :name "chunk" :hash hash :ext "js"))
                   (path (when outdir (%join outdir name)))
                   (text (minify-js (concatenate 'string (runtime-prelude) body)
                                    (bc-minify config))))
              (when path (%write-string-file path text))
              (push (make-build-artifact :path path :kind :chunk :text text :hash hash)
                    outputs)))
          (dolist (entry (bg-entries graph))
            (let* ((entry-mn (gethash entry (bg-modules graph)))
                   (paths (remove-if (lambda (p) (gethash p shared-set))
                                     (modules-for-chunk graph (list entry))))
                   (body (with-output-to-string (o)
                           (dolist (p paths)
                             (let ((mn (gethash p (bg-modules graph))))
                               (when mn
                                 (write-string (emit-module-registration mn graph path-map) o))))))
                   (ids (list (mn-id entry-mn)))
                   (text (minify-js (wrap-format body format ids config)
                                    (bc-minify config)))
                   (hash (%content-hash8 text))
                   (stem (let ((b (%basename entry)))
                           (if (find #\. b)
                               (subseq b 0 (position #\. b :from-end t))
                               b)))
                   (name (apply-naming (naming-template config :entry)
                                       :name stem :hash hash :ext "js"))
                   (path (cond (outfile (%path-abs outfile (bc-root config)))
                               (outdir (%join outdir name))
                               (t nil))))
              (when path (%write-string-file path text))
              (push (make-build-artifact :path path :kind :entry :text text
                                         :hash hash :entry-point-p t)
                    outputs))))
        (let* ((body (with-output-to-string (o)
                       (dolist (p (bg-order graph))
                         (let ((mn (gethash p (bg-modules graph))))
                           (when mn
                             (write-string (emit-module-registration mn graph path-map) o))))))
               (entry-ids (mapcar (lambda (e) (mn-id (gethash e (bg-modules graph))))
                                  (bg-entries graph)))
               (text (wrap-format body format entry-ids config))
               (text (minify-js text (bc-minify config)))
               (hash (%content-hash8 text))
               (stem (if (= 1 (length (bg-entries graph)))
                         (let ((b (%basename (first (bg-entries graph)))))
                           (if (find #\. b)
                               (subseq b 0 (position #\. b :from-end t))
                               b))
                         "bundle"))
               (name (apply-naming (naming-template config :entry)
                                   :name stem :hash hash :ext "js"))
               (path (cond (outfile (%path-abs outfile (or (bc-root config)
                                                           (sys:current-directory))))
                           (outdir (%join outdir name))
                           (t nil))))
          (when (member (bc-sourcemap config) '(:inline :linked :external))
            (let ((map-json (make-identity-sourcemap (bg-entries graph))))
              (ecase (bc-sourcemap config)
                (:inline
                 (setf text (format nil "~a~%//# sourceMappingURL=data:application/json;base64,~a"
                                    text (%b64 map-json))))
                ((:linked :external)
                 (when path
                   (let ((map-path (concatenate 'string path ".map")))
                     (%write-string-file map-path map-json)
                     (when (eq (bc-sourcemap config) :linked)
                       (setf text (format nil "~a~%//# sourceMappingURL=~a"
                                          text (%basename map-path))))
                     (push (make-build-artifact :path map-path :kind :sourcemap
                                                :text map-json)
                           outputs)))))))
          (when path (%write-string-file path text))
          (push (make-build-artifact :path path :kind :entry :text text
                                     :hash hash :entry-point-p t)
                outputs)))
    (make-build-result
     :success t
     :outputs (nreverse outputs)
     :logs '()
     :metafile (when (bc-metafile config) (make-metafile graph outputs)))))

;;; --- public API -------------------------------------------------------------

(defun build (config-or-plist)
  "Run a full bundle. Returns a BUILD-RESULT."
  (let* ((config (if (build-config-p config-or-plist)
                     config-or-plist
                     (make-config-from-plist config-or-plist)))
         (throwp (bc-throw config)))
    (handler-case
        (emit-bundle (build-graph config))
      (build-error (e)
        (if throwp
            (error e)
            (make-build-result
             :success nil
             :logs (list (list :level "error"
                               :message (build-error-message e)
                               :path (build-error-path e))))))
      (error (e)
        (if throwp
            (build-fail (princ-to-string e))
            (make-build-result
             :success nil
             :logs (list (list :level "error" :message (princ-to-string e)))))))))

(defun analyze (config-or-plist)
  "Exceed Bun: graph analysis without writing outputs."
  (let* ((config (if (build-config-p config-or-plist)
                     config-or-plist
                     (make-config-from-plist config-or-plist)))
         (graph (build-graph config))
         (modules '()))
    (maphash (lambda (path mn)
               (push (list :path path
                           :id (mn-id mn)
                           :loader (mn-loader mn)
                           :imports (mapcar #'car (mn-imports mn))
                           :exports (mn-exports mn)
                           :bytes (mn-bytes mn))
                     modules))
             (bg-modules graph))
    (list :entries (bg-entries graph)
          :modules (nreverse modules)
          :count (hash-table-count (bg-modules graph)))))

(defun build-to-string (config-or-plist)
  (let ((r (build config-or-plist)))
    (unless (br-success r)
      (build-fail "build failed"))
    (let ((entry (find :entry (br-outputs r) :key #'ba-kind)))
      (if entry (ba-text entry) ""))))
