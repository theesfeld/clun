;;;; clun-filesystem-router.lisp -- Next.js-style file inventory and matcher.

(in-package :clun.runtime)

(defconstant +fsr-max-routes+ 100000)
(defconstant +fsr-max-depth+ 1024)
(defconstant +fsr-max-query-pairs+ 4096)

(defparameter +fsr-default-extensions+
  '(".tsx" ".jsx" ".ts" ".mjs" ".cjs" ".js"))

(defstruct (fsr-route (:constructor %make-fsr-route))
  name
  file-path
  relative-path
  (segments '())
  (kind :exact)
  (exact-count 0 :type (integer 0 *))
  (extension-rank 0 :type (integer 0 *)))

(defstruct (js-file-system-router
            (:include eng:js-object (class :file-system-router))
            (:constructor %make-js-file-system-router))
  root
  (style "nextjs")
  (asset-prefix "")
  origin
  (extensions +fsr-default-extensions+)
  (routes '())
  routes-object)

(defun %require-file-system-router (value)
  (if (js-file-system-router-p value)
      value
      (eng:throw-type-error
       "FileSystemRouter method called on an incompatible receiver")))

(defun %fsr-option (options name)
  (eng:js-get options name))

(defun %fsr-string-option (options name &key required)
  (let ((value (%fsr-option options name)))
    (cond
      ((eng:js-string-p value) (eng:to-string value))
      ((and (not required) (eng:js-nullish-p value)) nil)
      (t (eng:throw-type-error (format nil "Expected ~a to be a string" name))))))

(defun %fsr-extensions-option (options)
  (let ((value (%fsr-option options "fileExtensions")))
    (if (eng:js-undefined-p value)
        (copy-list +fsr-default-extensions+)
        (progn
          (unless (eng:js-array-p value)
            (eng:throw-type-error "Expected fileExtensions to be an Array"))
          (let ((extensions '()))
            (dotimes (index (eng:array-length value) (nreverse extensions))
              (let ((entry (eng:js-getv value (princ-to-string index))))
                (unless (eng:js-string-p entry)
                  (eng:throw-type-error
                   "Expected fileExtensions to be an Array of strings"))
                (let ((extension (eng:to-string entry)))
                  (when (plusp (length extension))
                    (push (if (char= (char extension 0) #\.)
                              extension
                              (concatenate 'string "." extension))
                          extensions))))))))))

(defun %fsr-trim-directory (path)
  (if (> (length path) 1) (string-right-trim "/" path) path))

(defun %fsr-resolve-root (directory)
  (let* ((logical
           (if (sys:absolute-path-p directory)
               (sys:normalize-path directory)
               (sys:normalize-path
                (sys:path-join (sys:current-directory) directory))))
         (canonical (sys:realpath logical)))
    (unless (and canonical (sys:directory-p canonical))
      (eng:throw-native-error
       :error (format nil "Unable to find directory: ~a" directory)))
    (%fsr-trim-directory canonical)))

(defun %fsr-root-contained-p (root path)
  (or (and (string= root "/")
           (plusp (length path))
           (char= (char path 0) #\/))
      (and (<= (length root) (length path))
           (string= root path :end2 (length root))
           (or (= (length root) (length path))
               (char= (char path (length root)) #\/)))))

(defun %fsr-extension-rank (path extensions)
  (let ((extension (sys:path-extension path)))
    (position extension extensions :test #'string=)))

(defun %fsr-route-name (relative extension)
  (let* ((without-extension
           (subseq relative 0 (- (length relative) (length extension))))
         (base (sys:path-basename without-extension))
         (directory (sys:path-dirname without-extension))
         (route
           (if (string= base "index")
               (if (string= directory ".") "" directory)
               without-extension)))
    (if (zerop (length route)) "/" (concatenate 'string "/" route))))

(defun %fsr-parameter-name (segment prefix suffix)
  (let ((name (subseq segment (length prefix)
                      (- (length segment) (length suffix)))))
    (unless (%valid-route-parameter-name-p name)
      (eng:throw-type-error "Invalid route parameter name."))
    name))

(defun %fsr-compile-segment (segment terminal-p)
  (cond
    ((and (>= (length segment) 8)
          (string= "[[..." segment :end2 5)
          (string= "]]" segment :start2 (- (length segment) 2)))
     (unless terminal-p
       (eng:throw-native-error
        :error "Catch-all routes must be the final segment"))
     (cons :optional-catch-all
           (%fsr-parameter-name segment "[[..." "]]")))
    ((and (>= (length segment) 6)
          (string= "[..." segment :end2 4)
          (char= (char segment (1- (length segment))) #\]))
     (unless terminal-p
       (eng:throw-native-error
        :error "Catch-all routes must be the final segment"))
     (cons :catch-all (%fsr-parameter-name segment "[..." "]")))
    ((and (>= (length segment) 3)
          (char= (char segment 0) #\[)
          (char= (char segment (1- (length segment))) #\])
          (null (position #\[ segment :start 1))
          (null (position #\] segment :end (1- (length segment)))))
     (cons :dynamic (%fsr-parameter-name segment "[" "]")))
    ((or (position #\[ segment) (position #\] segment))
     (eng:throw-native-error :error "Route is missing a closing bracket]"))
    (t (cons :exact segment))))

(defun %fsr-compile-route (name file-path relative extension-rank)
  (let* ((names (%split-route-path name))
         (segments
           (loop for segment in names
                 for index from 0
                 collect (%fsr-compile-segment
                          segment (= index (1- (length names))))))
         (specials (remove :exact segments :key #'car))
         (parameter-names (mapcar #'cdr specials)))
    (when (/= (length parameter-names)
              (length (remove-duplicates parameter-names :test #'string=)))
      (eng:throw-type-error
       "Support for duplicate route parameter names is not yet implemented."))
    (%make-fsr-route
     :name name :file-path file-path :relative-path relative
     :segments segments
     :kind (cond ((find :catch-all specials :key #'car) :catch-all)
                 ((find :optional-catch-all specials :key #'car)
                  :optional-catch-all)
                 (specials :dynamic)
                 (t :exact))
     :exact-count (count :exact segments :key #'car)
     :extension-rank extension-rank)))

(defun %fsr-kind-rank (kind)
  (ecase kind
    (:exact 4)
    (:dynamic 3)
    (:catch-all 2)
    (:optional-catch-all 1)))

(defun %fsr-route-before-p (left right)
  (let ((left-kind (%fsr-kind-rank (fsr-route-kind left)))
        (right-kind (%fsr-kind-rank (fsr-route-kind right))))
    (cond
      ((/= left-kind right-kind) (> left-kind right-kind))
      ((/= (fsr-route-exact-count left) (fsr-route-exact-count right))
       (> (fsr-route-exact-count left) (fsr-route-exact-count right)))
      ((/= (length (fsr-route-segments left))
           (length (fsr-route-segments right)))
       (> (length (fsr-route-segments left))
          (length (fsr-route-segments right))))
      (t (string< (fsr-route-name left) (fsr-route-name right))))))

(defun %fsr-entry-stat (directory name)
  (handler-case (sys:stat-at* directory name :lstat t)
    (sys:fs-error (condition)
      (if (string= (sys:fs-error-code condition) "ENOENT")
          nil
          (error condition)))))

(defun %fsr-load-inventory (router)
  (let* ((root (js-file-system-router-root router))
         (extensions (js-file-system-router-extensions router))
         (by-name (make-hash-table :test #'equal))
         (count 0))
    (labels
        ((walk (directory relative depth)
           (when (> depth +fsr-max-depth+)
             (eng:throw-native-error :error "FileSystemRouter directory tree is too deep"))
           (let ((canonical
                   (let ((resolved (sys:realpath directory)))
                     (and resolved (%fsr-trim-directory resolved)))))
             (unless (and canonical
                          (string= canonical directory)
                          (%fsr-root-contained-p root canonical))
               (return-from walk nil)))
           (let ((names '()))
             (sys:map-directory-entries directory (lambda (name) (push name names)))
             (dolist (name (sort names #'string<))
               (unless (or (member name '("." ".." "node_modules" ".git" ".next")
                                   :test #'string=)
                           (and (plusp (length name))
                                (char= (char name 0) #\.)))
                 (let* ((stat (%fsr-entry-stat directory name))
                        (logical (sys:path-join directory name))
                        (child-relative
                          (if (zerop (length relative))
                              name
                              (sys:path-join relative name))))
                   (when stat
                     (cond
                       ((sys:fstat-symlink-p stat) nil)
                       ((sys:fstat-dir-p stat)
                        (walk logical child-relative (1+ depth)))
                       ((sys:fstat-file-p stat)
                        (let ((extension-rank
                                (%fsr-extension-rank name extensions)))
                          (when extension-rank
                            (let* ((extension (nth extension-rank extensions))
                                   (route-name
                                     (%fsr-route-name child-relative extension))
                                   (candidate
                                     (%fsr-compile-route
                                      route-name logical child-relative
                                      extension-rank))
                                   (old (gethash route-name by-name)))
                              (when (or (null old)
                                        (< extension-rank
                                           (fsr-route-extension-rank old)))
                                (unless old
                                  (when (>= count +fsr-max-routes+)
                                    (eng:throw-native-error
                                     :error "FileSystemRouter has too many routes"))
                                  (incf count))
                                (setf (gethash route-name by-name)
                                      candidate))))))))))))))
      (walk root "" 0))
    (let* ((routes
             (sort (loop for route being the hash-values of by-name collect route)
                   #'%fsr-route-before-p))
           (object (eng:new-object)))
      (dolist (route routes)
        (eng:data-prop object (fsr-route-name route)
                       (fsr-route-file-path route)))
      (values routes object))))

(defun %fsr-reload (router)
  (handler-case
      (multiple-value-bind (routes object) (%fsr-load-inventory router)
        (setf (js-file-system-router-routes router) routes
              (js-file-system-router-routes-object router) object)
        router)
    (sys:fs-error (condition)
      (eng:throw-js-value
       (%fs-error->js (eng:realm-global eng:*realm*) condition)))))

(defun %fsr-input-string (value)
  (cond
    ((eng:js-string-p value) (eng:to-string value))
    ((or (js-request-p value) (js-response-p value))
     (let ((url (eng:js-get value "url")))
       (if (eng:js-string-p url) (eng:to-string url) "")))
    (t (eng:throw-type-error "Expected string, Request or Response"))))

(defun %fsr-input-parts (value)
  (let* ((input (%fsr-input-string value))
         (absolute-p
           (or (and (>= (length input) 7)
                    (string-equal "http://" input :end2 7))
               (and (>= (length input) 8)
                    (string-equal "https://" input :end2 8))
               (and (>= (length input) 7)
                    (string-equal "file://" input :end2 7)))))
    (if absolute-p
        (let ((record (%parse-url input)))
          (values (ur-path record) (ur-query record)))
        (let* ((fragment (position #\# input))
               (query (position #\? input))
               (path-end (or (and fragment query (min fragment query))
                             fragment query (length input)))
               (query-end (or fragment (length input)))
               (path (subseq input 0 path-end))
               (query-string
                 (and query (< query query-end)
                      (subseq input (1+ query) query-end))))
          (values
           (cond
             ((or (zerop (length path)) (search "%PUBLIC_URL%" path)) "/")
             ((char= (char path 0) #\/) path)
             (t (concatenate 'string "/" path)))
           query-string)))))

(defun %fsr-normalize-input-path (path)
  (let* ((trimmed
           (if (and (> (length path) 1)
                    (char= (char path (1- (length path))) #\/))
               (subseq path 0 (1- (length path)))
               path))
         (raw-segments (%split-route-path trimmed))
         (segments (mapcar #'%decode-route-segment raw-segments)))
    (when (and segments (string= (car (last segments)) "index"))
      (setf segments (butlast segments)))
    (values segments
            (if segments
                (format nil "/~{~a~^/~}" segments)
                "/"))))

(defun %fsr-match-route (route segments)
  (let ((captures '())
        (index 0)
        (count (length segments)))
    (dolist (part (fsr-route-segments route))
      (case (car part)
        (:exact
         (unless (and (< index count)
                      (string= (cdr part) (nth index segments)))
           (return-from %fsr-match-route (values nil nil)))
         (incf index))
        (:dynamic
         (unless (< index count)
           (return-from %fsr-match-route (values nil nil)))
         (push (cons (cdr part) (nth index segments)) captures)
         (incf index))
        (:catch-all
         (unless (< index count)
           (return-from %fsr-match-route (values nil nil)))
         (push (cons (cdr part)
                     (format nil "~{~a~^/~}" (subseq segments index)))
               captures)
         (setf index count))
        (:optional-catch-all
         (push (cons (cdr part)
                     (format nil "~{~a~^/~}" (subseq segments index)))
               captures)
         (setf index count))))
    (if (= index count)
        (values (nreverse captures) t)
        (values nil nil))))

(defun %fsr-query-object (params query-string)
  (let ((object (eng:new-object))
        (count 0))
    (dolist (pair params)
      (eng:data-prop object (car pair) (cdr pair)))
    (dolist (pair (%usp-parse query-string))
      (when (>= count +fsr-max-query-pairs+) (return))
      (incf count)
      (eng:js-set object (car pair) (cdr pair) nil))
    object))

(defun %fsr-params-object (params)
  (let ((object (eng:new-object)))
    (dolist (pair params object)
      (eng:data-prop object (car pair) (cdr pair)))))

(defun %fsr-script-source (router route)
  (let* ((origin (or (js-file-system-router-origin router) ""))
         (prefix (js-file-system-router-asset-prefix router))
         (relative (fsr-route-relative-path route))
         (origin (string-right-trim "/" origin))
         (prefix
           (cond ((zerop (length prefix)) "/")
                 ((char= (char prefix 0) #\/) prefix)
                 (t (concatenate 'string "/" prefix))))
         (prefix (if (char= (char prefix (1- (length prefix))) #\/)
                     prefix
                     (concatenate 'string prefix "/"))))
    (concatenate 'string origin prefix relative)))

(defun %fsr-match (router value)
  (multiple-value-bind (raw-path query-string) (%fsr-input-parts value)
    (multiple-value-bind (segments pathname) (%fsr-normalize-input-path raw-path)
      (dolist (route (js-file-system-router-routes router) eng:+null+)
        (multiple-value-bind (params matched-p)
            (%fsr-match-route route segments)
          (when matched-p
            (let ((result (eng:new-object)))
              (eng:data-prop result "params" (%fsr-params-object params))
              (eng:data-prop result "filePath" (fsr-route-file-path route))
              (eng:data-prop result "pathname" pathname)
              (eng:data-prop result "query"
                             (%fsr-query-object params query-string))
              (eng:data-prop result "name" (fsr-route-name route))
              (eng:data-prop result "kind"
                             (string-downcase
                              (symbol-name (fsr-route-kind route))))
              (let ((source (%fsr-script-source router route)))
                (eng:data-prop result "src" source)
                (eng:data-prop result "scriptSrc" source))
              (return result))))))))

(defun install-clun-file-system-router (clun global realm)
  "Install the realm-local Clun.FileSystemRouter constructor."
  (declare (ignore global))
  (let* ((prototype (eng:new-object))
         (constructor nil))
    (eng:install-method prototype "match" 1
      (lambda (this args)
        (%fsr-match (%require-file-system-router this) (eng:arg args 0))))
    (eng:install-method prototype "reload" 0
      (lambda (this args)
        (declare (ignore args))
        (%fsr-reload (%require-file-system-router this))
        this))
    (eng:install-getter prototype "routes"
      (lambda (this args)
        (declare (ignore args))
        (js-file-system-router-routes-object
         (%require-file-system-router this))))
    (eng:install-getter prototype "origin"
      (lambda (this args)
        (declare (ignore args))
        (or (js-file-system-router-origin
             (%require-file-system-router this))
            eng:+null+)))
    (eng:install-getter prototype "style"
      (lambda (this args)
        (declare (ignore args))
        (js-file-system-router-style
         (%require-file-system-router this))))
    (eng:install-getter prototype "assetPrefix"
      (lambda (this args)
        (declare (ignore args))
        (let ((prefix
                (js-file-system-router-asset-prefix
                 (%require-file-system-router this))))
          (if (zerop (length prefix)) eng:+null+ prefix))))
    (setf constructor
          (eng:make-native-function
           "FileSystemRouter" 1
           (lambda (this args)
             (declare (ignore this args))
             (eng:throw-type-error
              "FileSystemRouter constructor cannot be invoked without 'new'"))
           :construct
           (lambda (args new-target)
             (let ((options (eng:arg args 0)))
               (unless (eng:js-object-p options)
                 (eng:throw-type-error "Expected object"))
               (let* ((style (%fsr-string-option options "style" :required t))
                      (directory (%fsr-string-option options "dir" :required t))
                      (origin (%fsr-string-option options "origin"))
                      (asset-prefix
                        (or (%fsr-string-option options "assetPrefix") "")))
                 (unless (string= style "nextjs")
                   (eng:throw-type-error
                    "Only 'nextjs' style is currently implemented"))
                 (let ((router
                         (%make-js-file-system-router
                          :proto (eng::nt-prototype new-target prototype)
                          :root (%fsr-resolve-root directory)
                          :style style :origin origin
                          :asset-prefix asset-prefix
                          :extensions (%fsr-extensions-option options))))
                   (let ((eng:*realm* realm))
                     (%fsr-reload router))))))))
    (eng::obj-set-desc prototype "constructor"
                       (eng::data-pd constructor :writable t :enumerable nil
                                                :configurable t))
    (eng::obj-set-desc prototype (eng:well-known :to-string-tag)
                       (eng::data-pd "FileSystemRouter" :writable nil
                                                        :enumerable nil
                                                        :configurable t))
    (eng::obj-set-desc constructor "prototype"
                       (eng::data-pd prototype :writable nil :enumerable nil
                                              :configurable nil))
    (eng::obj-set-desc clun "FileSystemRouter"
                       (eng::data-pd constructor :writable t :enumerable t
                                               :configurable nil))
    constructor))
