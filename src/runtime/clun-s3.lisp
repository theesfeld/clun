;;;; clun-s3.lisp — Clun.s3 / Clun.S3Client JavaScript boundary (Issue #185 FULL PORT).
;;;;
;;;; Bun.s3-compatible surface: S3Client, file/write/delete/list/exists/size/stat/presign
;;;; backed by pure-CL AWS SigV4 client. Exceed: copy, deleteObjects, pathStyle, multipart.

(in-package :clun.runtime)

(defun %s3-type-error (message)
  (let ((error (eng:make-error-object :type-error-prototype "TypeError" message)))
    (eng:js-set error "code" "ERR_INVALID_ARG_TYPE" nil)
    (eng:throw-js-value error)))

(defun %s3-error-object (condition)
  (let* ((msg (or (clun.s3:s3-error-message condition)
                  (clun.s3:s3-error-detail condition)
                  (format nil "~A" (clun.s3:s3-error-kind condition))))
         (error (eng:make-error-object :error-prototype "Error" (format nil "~A" msg))))
    (eng:js-set error "code"
                (or (clun.s3:s3-error-code condition)
                    (string (clun.s3:s3-error-kind condition)))
                nil)
    (when (clun.s3:s3-error-status condition)
      (eng:js-set error "status" (clun.s3:s3-error-status condition) nil))
    (when (clun.s3:s3-error-key condition)
      (eng:js-set error "key" (clun.s3:s3-error-key condition) nil))
    (when (clun.s3:s3-error-bucket condition)
      (eng:js-set error "bucket" (clun.s3:s3-error-bucket condition) nil))
    error))

(defun %s3-resolved-promise (global value)
  (eng:js-construct
   (eng:js-get global "Promise")
   (list
    (eng:make-native-function
     "" 2
     (lambda (this args)
       (declare (ignore this))
       (eng:js-call (eng:arg args 0) eng:+undefined+ (list value))
       eng:+undefined+)))))

(defun %s3-rejected-promise (global error)
  (eng:js-construct
   (eng:js-get global "Promise")
   (list
    (eng:make-native-function
     "" 2
     (lambda (this args)
       (declare (ignore this))
       (eng:js-call (eng:arg args 1) eng:+undefined+ (list error))
       eng:+undefined+)))))

(defmacro %s3-async ((global) &body body)
  (let ((g (gensym)) (e (gensym)))
    `(let ((,g ,global))
       (handler-case (%s3-resolved-promise ,g (progn ,@body))
         (clun.s3:s3-error (,e)
           (%s3-rejected-promise ,g (%s3-error-object ,e)))
         (error (,e)
           (%s3-rejected-promise
            ,g
            (eng:make-error-object :error-prototype "Error"
                                   (format nil "~A" ,e))))))))

(defun %s3-js-string (value)
  (and (eng:js-string-p value) value))

(defun %s3-opt-string (obj key)
  (when (eng:js-object-p obj)
    (let ((v (eng:js-get obj key)))
      (cond
        ((eng:js-undefined-p v) nil)
        ((eng:js-null-p v) nil)
        ((eng:js-string-p v) v)
        (t (eng:to-string v))))))

(defun %s3-opt-bool (obj key)
  (when (eng:js-object-p obj)
    (let ((v (eng:js-get obj key)))
      (cond
        ((eng:js-undefined-p v) nil)
        ((eng:js-null-p v) nil)
        (t (eq (eng:to-boolean v) eng:+true+))))))

(defun %s3-opt-number (obj key)
  (when (eng:js-object-p obj)
    (let ((v (eng:js-get obj key)))
      (cond
        ((eng:js-undefined-p v) nil)
        ((eng:js-null-p v) nil)
        (t (let ((n (eng:to-number v)))
             (unless (eng:js-nan-p n) (floor n))))))))

(defun %s3-options-from-js (obj)
  "Map a JS options object to CL keyword plist for make-s3-options / merge."
  (unless (and obj (eng:js-object-p obj))
    (return-from %s3-options-from-js nil))
  (list
   :access-key-id (%s3-opt-string obj "accessKeyId")
   :secret-access-key (%s3-opt-string obj "secretAccessKey")
   :session-token (%s3-opt-string obj "sessionToken")
   :bucket (%s3-opt-string obj "bucket")
   :region (%s3-opt-string obj "region")
   :endpoint (%s3-opt-string obj "endpoint")
   :virtual-hosted-style (%s3-opt-bool obj "virtualHostedStyle")
   :path-style (let ((v (eng:js-get obj "pathStyle")))
                 (cond
                   ((eng:js-undefined-p v) nil)
                   ((eng:js-null-p v) nil)
                   (t (eq (eng:to-boolean v) eng:+true+))))
   :part-size (%s3-opt-number obj "partSize")
   :queue-size (%s3-opt-number obj "queueSize")
   :retry (%s3-opt-number obj "retry")
   :acl (%s3-opt-string obj "acl")
   :type (or (%s3-opt-string obj "type") (%s3-opt-string obj "contentType"))
   :content-encoding (%s3-opt-string obj "contentEncoding")
   :content-disposition (%s3-opt-string obj "contentDisposition")
   :storage-class (%s3-opt-string obj "storageClass")
   :request-payer (%s3-opt-string obj "requestPayer")))

(defun %s3-plist-drop-nils (plist)
  (loop for (k v) on plist by #'cddr
        when (not (null v))
          collect k and collect v))

(defun %s3-make-client-from-js (opts-obj)
  (apply #'clun.s3:make-s3-client
         (%s3-plist-drop-nils (%s3-options-from-js opts-obj))))

(defun %s3-data-to-octets (value)
  (cond
    ((eng:js-string-p value)
     (sb-ext:string-to-octets value :external-format :utf-8))
    ((eng:js-undefined-p value)
     (%s3-type-error "Expected data to write"))
    ((eng:js-null-p value)
     (make-array 0 :element-type '(unsigned-byte 8)))
    ;; TypedArray / ArrayBuffer-like
    ((eng:js-object-p value)
     (let ((buf (eng:js-get value "buffer"))
           (byte-length (eng:js-get value "byteLength")))
       (cond
         ((and (not (eng:js-undefined-p byte-length))
               (eng:js-object-p value)
               (eng:js-get value "BYTES_PER_ELEMENT"))
          ;; approximate: toString then utf8 is wrong; use array-like index walk
          (let* ((len (floor (eng:to-number byte-length)))
                 (out (make-array len :element-type '(unsigned-byte 8))))
            (dotimes (i len out)
              (setf (aref out i)
                    (logand (floor (eng:to-number (eng:js-get value (princ-to-string i))))
                            #xff)))))
         ((eng:js-string-p (eng:to-string value))
          (sb-ext:string-to-octets (eng:to-string value) :external-format :utf-8))
         (t
          (sb-ext:string-to-octets (eng:to-string value) :external-format :utf-8)))))
    (t
     (sb-ext:string-to-octets (eng:to-string value) :external-format :utf-8))))

(defun %s3-list-to-js (global result)
  (let ((obj (eng:new-object))
        (contents (getf result :contents))
        (arr (eng:js-construct (eng:js-get global "Array") nil)))
    (when (getf result :name)
      (eng:js-set obj "name" (getf result :name) nil))
    (when (getf result :prefix)
      (eng:js-set obj "prefix" (getf result :prefix) nil))
    (when (getf result :max-keys)
      (eng:js-set obj "maxKeys" (getf result :max-keys) nil))
    (when (getf result :key-count)
      (eng:js-set obj "keyCount" (getf result :key-count) nil))
    (eng:js-set obj "isTruncated"
                (if (getf result :is-truncated) eng:+true+ eng:+false+) nil)
    (when (getf result :next-continuation-token)
      (eng:js-set obj "nextContinuationToken"
                  (getf result :next-continuation-token) nil))
    (let ((i 0))
      (dolist (c contents)
        (let ((entry (eng:new-object)))
          (eng:js-set entry "key" (getf c :key) nil)
          (when (getf c :size)
            (eng:js-set entry "size" (getf c :size) nil))
          (when (getf c :etag)
            (eng:js-set entry "eTag" (getf c :etag) nil))
          (when (getf c :last-modified)
            (eng:js-set entry "lastModified" (getf c :last-modified) nil))
          (eng:js-set arr (princ-to-string i) entry nil)
          (incf i)))
      (eng:js-set arr "length" i nil))
    (eng:js-set obj "contents" arr nil)
    obj))

(defun %s3-stat-to-js (stat)
  (let ((obj (eng:new-object)))
    (eng:js-set obj "size" (clun.s3:s3s-size stat) nil)
    (when (clun.s3:s3s-etag stat)
      (eng:js-set obj "etag" (clun.s3:s3s-etag stat) nil))
    (when (clun.s3:s3s-last-modified stat)
      (eng:js-set obj "lastModified" (clun.s3:s3s-last-modified stat) nil))
    (when (clun.s3:s3s-content-type stat)
      (eng:js-set obj "type" (clun.s3:s3s-content-type stat) nil))
    obj))

(defun %make-s3-file-object (global client key &optional opts-obj)
  (let* ((plist (%s3-plist-drop-nils (%s3-options-from-js opts-obj)))
         (file (if plist
                   (apply #'clun.s3:s3-file client key plist)
                   (clun.s3:s3-file client key)))
         (obj (eng:new-object)))
    (eng:js-set obj "name" (clun.s3:s3f-key file) nil)
    (eng:install-method obj "text" 0
      (lambda (this args)
        (declare (ignore this args))
        (%s3-async (global)
          (clun.s3:s3-file-text file))))
    (eng:install-method obj "arrayBuffer" 0
      (lambda (this args)
        (declare (ignore this args))
        (%s3-async (global)
          (let* ((octets (clun.s3:s3-file-get file))
                 (ab (eng:js-construct (eng:js-get global "ArrayBuffer")
                                       (list (length octets))))
                 (view (eng:js-construct (eng:js-get global "Uint8Array")
                                         (list ab))))
            (dotimes (i (length octets))
              (eng:js-set view (princ-to-string i) (aref octets i) nil))
            ab))))
    (eng:install-method obj "bytes" 0
      (lambda (this args)
        (declare (ignore this args))
        (%s3-async (global)
          (let* ((octets (clun.s3:s3-file-get file))
                 (view (eng:js-construct (eng:js-get global "Uint8Array")
                                         (list (length octets)))))
            (dotimes (i (length octets))
              (eng:js-set view (princ-to-string i) (aref octets i) nil))
            view))))
    (eng:install-method obj "json" 0
      (lambda (this args)
        (declare (ignore this args))
        (%s3-async (global)
          (let* ((text (clun.s3:s3-file-text file))
                 (json (eng:js-get global "JSON"))
                 (parse (eng:js-get json "parse")))
            (eng:js-call parse json (list text))))))
    (eng:install-method obj "write" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((data (eng:arg args 0))
              (opt (eng:arg args 1)))
          (%s3-async (global)
            (let ((octets (%s3-data-to-octets data))
                  (ct (when (eng:js-object-p opt)
                        (or (%s3-opt-string opt "type")
                            (%s3-opt-string opt "contentType")))))
              (clun.s3:s3-file-write file octets :content-type ct)
              (length octets))))))
    (eng:install-method obj "delete" 0
      (lambda (this args)
        (declare (ignore this args))
        (%s3-async (global)
          (clun.s3:s3-file-delete file)
          eng:+undefined+)))
    (eng:install-method obj "unlink" 0
      (lambda (this args)
        (declare (ignore this args))
        (%s3-async (global)
          (clun.s3:s3-file-delete file)
          eng:+undefined+)))
    (eng:install-method obj "exists" 0
      (lambda (this args)
        (declare (ignore this args))
        (%s3-async (global)
          (if (clun.s3:s3-file-exists file) eng:+true+ eng:+false+))))
    (eng:install-method obj "stat" 0
      (lambda (this args)
        (declare (ignore this args))
        (%s3-async (global)
          (%s3-stat-to-js (clun.s3:s3-file-stat file)))))
    (eng:install-method obj "presign" 0
      (lambda (this args)
        (declare (ignore this))
        (let* ((opt (eng:arg args 0))
               (expires (when (eng:js-object-p opt)
                          (%s3-opt-number opt "expiresIn")))
               (method (when (eng:js-object-p opt)
                         (%s3-opt-string opt "method")))
               (type (when (eng:js-object-p opt)
                       (or (%s3-opt-string opt "type")
                           (%s3-opt-string opt "contentType"))))
               (acl (when (eng:js-object-p opt)
                      (%s3-opt-string opt "acl"))))
          (clun.s3:s3-file-presign file
                                   :method (or method "GET")
                                   :expires-in (or expires 86400)
                                   :content-type type
                                   :acl acl))))
    obj))

(defun %make-s3-client-object (global &optional opts-obj)
  (let* ((client (%s3-make-client-from-js opts-obj))
         (obj (eng:new-object)))
    (eng:js-set obj "backend" "pure-cl-sigv4" nil)
    (eng:install-method obj "file" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((path (eng:arg args 0))
              (opt (eng:arg args 1)))
          (unless (eng:js-string-p path)
            (%s3-type-error "Expected path to be a string"))
          (%make-s3-file-object global client path
                                (when (eng:js-object-p opt) opt)))))
    (eng:install-method obj "write" 2
      (lambda (this args)
        (declare (ignore this))
        (let ((path (eng:arg args 0))
              (data (eng:arg args 1))
              (opt (eng:arg args 2)))
          (unless (eng:js-string-p path)
            (%s3-type-error "Expected path to be a string"))
          (%s3-async (global)
            (let ((octets (%s3-data-to-octets data))
                  (ct (when (eng:js-object-p opt)
                        (or (%s3-opt-string opt "type")
                            (%s3-opt-string opt "contentType")))))
              (clun.s3:s3-write client path octets :content-type ct)
              (length octets))))))
    (eng:install-method obj "delete" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((path (eng:arg args 0)))
          (unless (eng:js-string-p path)
            (%s3-type-error "Expected path to be a string"))
          (%s3-async (global)
            (clun.s3:s3-delete client path)
            eng:+undefined+))))
    (eng:install-method obj "unlink" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((path (eng:arg args 0)))
          (unless (eng:js-string-p path)
            (%s3-type-error "Expected path to be a string"))
          (%s3-async (global)
            (clun.s3:s3-delete client path)
            eng:+undefined+))))
    (eng:install-method obj "exists" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((path (eng:arg args 0)))
          (unless (eng:js-string-p path)
            (%s3-type-error "Expected path to be a string"))
          (%s3-async (global)
            (if (clun.s3:s3-exists client path) eng:+true+ eng:+false+)))))
    (eng:install-method obj "size" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((path (eng:arg args 0)))
          (unless (eng:js-string-p path)
            (%s3-type-error "Expected path to be a string"))
          (%s3-async (global)
            (clun.s3:s3-size client path)))))
    (eng:install-method obj "stat" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((path (eng:arg args 0)))
          (unless (eng:js-string-p path)
            (%s3-type-error "Expected path to be a string"))
          (%s3-async (global)
            (%s3-stat-to-js (clun.s3:s3-stat client path))))))
    (eng:install-method obj "list" 0
      (lambda (this args)
        (declare (ignore this))
        (let ((input (eng:arg args 0)))
          (%s3-async (global)
            (let ((prefix (when (eng:js-object-p input)
                            (%s3-opt-string input "prefix")))
                  (max-keys (when (eng:js-object-p input)
                              (%s3-opt-number input "maxKeys")))
                  (delimiter (when (eng:js-object-p input)
                               (%s3-opt-string input "delimiter")))
                  (start-after (when (eng:js-object-p input)
                                 (%s3-opt-string input "startAfter")))
                  (token (when (eng:js-object-p input)
                           (%s3-opt-string input "continuationToken"))))
              (%s3-list-to-js
               global
               (clun.s3:s3-list client
                                :prefix prefix
                                :max-keys max-keys
                                :delimiter delimiter
                                :start-after start-after
                                :continuation-token token)))))))
    (eng:install-method obj "presign" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((path (eng:arg args 0))
              (opt (eng:arg args 1)))
          (unless (eng:js-string-p path)
            (%s3-type-error "Expected path to be a string"))
          (let ((expires (when (eng:js-object-p opt)
                           (%s3-opt-number opt "expiresIn")))
                (method (when (eng:js-object-p opt)
                          (%s3-opt-string opt "method")))
                (type (when (eng:js-object-p opt)
                        (or (%s3-opt-string opt "type")
                            (%s3-opt-string opt "contentType"))))
                (acl (when (eng:js-object-p opt)
                       (%s3-opt-string opt "acl"))))
            (clun.s3:presign (clun.s3:client-options client) path
                             :method (or method "GET")
                             :expires-in (or expires 86400)
                             :content-type type
                             :acl acl)))))
    (eng:install-method obj "copy" 2
      (lambda (this args)
        (declare (ignore this))
        (let ((src (eng:arg args 0))
              (dst (eng:arg args 1)))
          (unless (and (eng:js-string-p src) (eng:js-string-p dst))
            (%s3-type-error "Expected source and destination keys to be strings"))
          (%s3-async (global)
            (clun.s3:s3-copy client src dst)
            eng:+undefined+))))
    (eng:install-method obj "deleteObjects" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((keys-arg (eng:arg args 0)))
          (%s3-async (global)
            (let ((keys nil)
                  (len (if (eng:js-object-p keys-arg)
                           (let ((l (eng:js-get keys-arg "length")))
                             (if (eng:js-undefined-p l) 0
                                 (floor (eng:to-number l))))
                           0)))
              (dotimes (i len)
                (let ((k (eng:js-get keys-arg (princ-to-string i))))
                  (when (eng:js-string-p k) (push k keys))))
              (clun.s3:s3-delete-objects client (nreverse keys))
              eng:+undefined+)))))
    obj))

(defun make-clun-s3 (global)
  "Default Clun.s3 singleton (env credentials), Bun.s3 shape."
  (%make-s3-client-object global nil))

(defun make-clun-s3-client-ctor (global)
  "Clun.S3Client constructor function (new S3Client(options))."
  (flet ((build (args)
           (let ((opts (eng:arg args 0)))
             (%make-s3-client-object global
                                     (when (eng:js-object-p opts) opts)))))
    (eng:make-native-function
     "S3Client" 1
     ;; call without new still returns a client (Bun allows both shapes)
     (lambda (this args)
       (declare (ignore this))
       (build args))
     :construct
     (lambda (args new-target)
       (declare (ignore new-target))
       (build args)))))

(defun install-clun-s3 (clun global)
  (eng:nonconfigurable-data-prop clun "s3" (make-clun-s3 global))
  (eng:nonconfigurable-data-prop clun "S3Client" (make-clun-s3-client-ctor global)))
