;;;; clun-archive.lisp — Clun.gzipSync/gunzipSync/deflateSync/inflateSync,
;;;; Clun.Archive, Clun.zipSync/unzipSync (Phase 74 / issue #134).

(in-package :clun.runtime)

(defparameter *archive-max-input* (* 512 1024 1024)
  "Refuse compress/decompress inputs larger than this before allocation work.")

(defun %archive-resolved (g value)
  "Promise.resolve(value) without depending on clun-global %async macro."
  (eng:js-construct (eng:js-get g "Promise")
    (list (eng:make-native-function "" 2
            (lambda (this a)
              (declare (ignore this))
              (eng:js-call (eng:arg a 0) eng:+undefined+ (list value))
              eng:+undefined+)))))

(defun %archive-rejected (g err)
  (eng:js-construct (eng:js-get g "Promise")
    (list (eng:make-native-function "" 2
            (lambda (this a)
              (declare (ignore this))
              (eng:js-call (eng:arg a 1) eng:+undefined+ (list err))
              eng:+undefined+)))))

(defmacro %archive-async ((g) &body body)
  "Run BODY; compress/tarball errors → rejected Promise, else resolve with value."
  (let ((gg (gensym)) (e (gensym)))
    `(let ((,gg ,g))
       (handler-case (%archive-resolved ,gg (progn ,@body))
         (cmp:compress-error (,e)
           (%archive-rejected ,gg (%compress-error->js ,e)))
         (clun.tarball:tarball-error (,e)
           (%archive-rejected ,gg (%compress-error->js ,e)))
         (error (,e)
           (%archive-rejected ,gg (%compress-error->js ,e)))))))

(defun %archive-buffer-source-p (value)
  (or (eng:js-array-buffer-p value)
      (eng:js-typed-array-p value)
      (and (eng:js-object-p value)
           (eq (eng:js-object-class value) :data-view))
      (js-blob-p value)))

(defun %archive-octets (value name)
  (cond
    ((eng:js-string-p value)
     (eng:code-units->utf8-replacing value))
    ((js-blob-p value)
     (copy-seq (js-blob-bytes value)))
    ((eng:js-typed-array-p value)
     (multiple-value-bind (a o l) (eng:ta-octets value)
       (subseq a o (+ o l))))
    ((eng:js-array-buffer-p value)
     (copy-seq (eng:js-array-buffer-bytes value)))
    ((and (eng:js-object-p value)
          (eq (eng:js-object-class value) :data-view))
     (copy-seq (eng:buffer-source-octets value)))
    (t
     (eng:throw-type-error
      (format nil "The ~A argument must be a string, TypedArray, ArrayBuffer, or Blob"
              name)))))

(defun %archive-level (options default)
  (when (or (eng:js-nullish-p options) (not (eng:js-object-p options)))
    (return-from %archive-level default))
  (let ((level (eng:js-get options "level")))
    (if (eng:js-nullish-p level)
        default
        (let ((n (eng:to-int32 level)))
          (when (or (< n -1) (> n 12))
            (eng:throw-range-error "Compression level out of range"))
          (if (= n -1) default n)))))

(defun %archive-window-bits (options)
  "Return :zlib (default), :raw (negative windowBits), or :gzip (25..31)."
  (when (or (eng:js-nullish-p options) (not (eng:js-object-p options)))
    (return-from %archive-window-bits :zlib))
  (let ((wb (eng:js-get options "windowBits")))
    (when (eng:js-nullish-p wb)
      (return-from %archive-window-bits :zlib))
    (let ((n (eng:to-int32 wb)))
      (cond
        ((<= 25 n 31) :gzip)
        ((<= 9 n 15) :zlib)
        ((<= -15 n -9) :raw)
        (t (eng:throw-range-error "windowBits out of range"))))))

(defun %compress-error->js (condition)
  (eng:make-error-object
   :error-prototype "Error"
   (cond
     ((typep condition 'cmp:compress-error)
      (cmp:compress-error-message condition))
     ((typep condition 'clun.tarball:tarball-error)
      (clun.tarball:tarball-error-message condition))
     (t (princ-to-string condition)))))

(defun %with-compress (thunk)
  (handler-case (funcall thunk)
    (cmp:compress-error (c) (eng:throw-js-value (%compress-error->js c)))
    (clun.tarball:tarball-error (c) (eng:throw-js-value (%compress-error->js c)))))

(defun %gzip-sync (args)
  (%with-compress
   (lambda ()
     (let* ((octets (%archive-octets (eng:arg args 0) "data"))
            (level (%archive-level (eng:arg args 1) 6)))
       (when (> (length octets) *archive-max-input*)
         (eng:throw-range-error "Input too large"))
       (eng:u8-from-octets (cmp:gzip-compress octets :level level))))))

(defun %gunzip-sync (args)
  (%with-compress
   (lambda ()
     (let ((octets (%archive-octets (eng:arg args 0) "data")))
       (when (> (length octets) *archive-max-input*)
         (eng:throw-range-error "Input too large"))
       (eng:u8-from-octets (cmp:gunzip octets))))))

(defun %deflate-sync (args)
  (%with-compress
   (lambda ()
     (let* ((octets (%archive-octets (eng:arg args 0) "data"))
            (opts (eng:arg args 1))
            (level (%archive-level opts 6))
            (fmt (%archive-window-bits opts)))
       (when (> (length octets) *archive-max-input*)
         (eng:throw-range-error "Input too large"))
       (eng:u8-from-octets
        (ecase fmt
          (:gzip (cmp:gzip-compress octets :level level))
          (:zlib (cmp:zlib-compress octets :level level))
          (:raw (cmp:raw-deflate-compress octets :level level))))))))

(defun %inflate-sync (args)
  (%with-compress
   (lambda ()
     (let* ((octets (%archive-octets (eng:arg args 0) "data"))
            (opts (eng:arg args 1))
            (fmt (%archive-window-bits opts)))
       (when (> (length octets) *archive-max-input*)
         (eng:throw-range-error "Input too large"))
       (eng:u8-from-octets
        (ecase fmt
          (:gzip (cmp:gunzip octets))
          (:zlib (cmp:zlib-decompress octets))
          (:raw (cmp:raw-inflate octets))))))))

(defun %zstd-unsupported (&rest args)
  (declare (ignore args))
  (eng:throw-js-value
   (eng:make-error-object
    :error-prototype "Error"
    "zstd compression is not available in pure Common Lisp (no approved pure-CL codec)")))

(defun %zip-sync (args)
  (%with-compress
   (lambda ()
     (let* ((input (eng:arg args 0))
            (opts (eng:arg args 1))
            (method
             (if (and (eng:js-object-p opts)
                      (eng:js-string-p (eng:js-get opts "method"))
                      (string= (eng:to-string (eng:js-get opts "method")) "store"))
                 0
                 8))
            (entries (%object-to-entries input)))
       (eng:u8-from-octets (clun.archive:build-zip entries :method method))))))

(defun %unzip-sync (args)
  (%with-compress
   (lambda ()
     (let* ((octets (%archive-octets (eng:arg args 0) "data"))
            (pairs (clun.archive:read-zip-entries octets))
            (obj (eng:new-object)))
       (dolist (pair pairs)
         (eng:data-prop obj (first pair) (eng:u8-from-octets (second pair))))
       obj))))

;;; --- Archive ----------------------------------------------------------------

(defstruct (js-archive
            (:include eng:js-object (class :archive))
            (:constructor %make-js-archive))
  (bytes nil)
  (entries nil)
  (compress nil)
  (level 6))

(defun %require-archive (value)
  (if (js-archive-p value)
      value
      (eng:throw-type-error "Expected a Clun.Archive instance")))

(defun %object-to-entries (obj)
  (unless (eng:js-object-p obj)
    (eng:throw-type-error "Archive data object must be an object"))
  (when (or (eng:js-typed-array-p obj)
            (eng:js-array-buffer-p obj)
            (js-blob-p obj)
            (js-archive-p obj))
    (eng:throw-type-error "Archive data object must be a path→content object"))
  (let ((entries '()))
    (dolist (key (eng:jm-own-property-keys obj))
      (when (eng:js-string-p key)
        (let* ((path (eng:to-string key))
               (val (eng:js-get obj path))
               (content
                 (cond
                   ((eng:js-string-p val)
                    (eng:code-units->utf8-replacing val))
                   ((%archive-buffer-source-p val)
                    (%archive-octets val path))
                   ((eng:js-nullish-p val)
                    (make-array 0 :element-type '(unsigned-byte 8)))
                   (t
                    (eng:throw-type-error
                     (format nil "Archive entry ~s must be string or binary data" path))))))
          (push (cons path content) entries))))
    (nreverse entries)))

(defun %archive-options (options)
  (when (or (eng:js-nullish-p options) (not (eng:js-object-p options)))
    (return-from %archive-options (values nil 6)))
  (let* ((compress-v (eng:js-get options "compress"))
         (compress (cond
                     ((eng:js-nullish-p compress-v) nil)
                     ((and (eng:js-string-p compress-v)
                           (string= (eng:to-string compress-v) "gzip"))
                      :gzip)
                     (t (eng:throw-type-error
                         "Archive compress must be \"gzip\" when set"))))
         (level (%archive-level options 6)))
    (values compress level)))

(defun %archive-materialize (archive)
  (or (js-archive-bytes archive)
      (let ((bytes (clun.archive:build-archive-bytes
                    (js-archive-entries archive)
                    :compress (js-archive-compress archive)
                    :level (js-archive-level archive))))
        (setf (js-archive-bytes archive) bytes)
        bytes)))

(defun %make-archive-instance (data options)
  (multiple-value-bind (compress level) (%archive-options options)
    (cond
      ((and (eng:js-object-p data)
            (not (eng:js-typed-array-p data))
            (not (eng:js-array-buffer-p data))
            (not (js-blob-p data))
            (not (js-archive-p data)))
       (%make-js-archive
        :entries (%object-to-entries data)
        :compress compress
        :level level))
      (t
       (let ((octets (%archive-octets data "data")))
         (%make-js-archive
          :bytes octets
          :compress (if (cmp:gzip-magic-p octets) :gzip compress)
          :level level))))))

(defun %archive-extract-globs (options)
  (when (or (eng:js-nullish-p options) (not (eng:js-object-p options)))
    (return-from %archive-extract-globs nil))
  (let ((glob (eng:js-get options "glob")))
    (cond
      ((eng:js-nullish-p glob) nil)
      ((eng:js-string-p glob) (list (eng:to-string glob)))
      ((eng:js-array-p glob)
       (loop for i from 0 below (eng:array-length glob)
             collect (eng:to-string (eng:js-get glob (princ-to-string i)))))
      (t (eng:throw-type-error "Archive extract glob must be a string or array")))))

(defun install-clun-archive (clun g)
  "Install Clun compression helpers and Clun.Archive."
  (eng:install-method clun "gzipSync" 2
    (lambda (this args) (declare (ignore this)) (%gzip-sync args)))
  (eng:install-method clun "gunzipSync" 1
    (lambda (this args) (declare (ignore this)) (%gunzip-sync args)))
  (eng:install-method clun "deflateSync" 2
    (lambda (this args) (declare (ignore this)) (%deflate-sync args)))
  (eng:install-method clun "inflateSync" 2
    (lambda (this args) (declare (ignore this)) (%inflate-sync args)))
  (eng:install-method clun "zipSync" 2
    (lambda (this args) (declare (ignore this)) (%zip-sync args)))
  (eng:install-method clun "unzipSync" 1
    (lambda (this args) (declare (ignore this)) (%unzip-sync args)))
  (eng:install-method clun "zstdCompressSync" 1
    (lambda (this args) (declare (ignore this)) (%zstd-unsupported args)))
  (eng:install-method clun "zstdDecompressSync" 1
    (lambda (this args) (declare (ignore this)) (%zstd-unsupported args)))
  (eng:install-method clun "zstdCompress" 1
    (lambda (this args) (declare (ignore this)) (%zstd-unsupported args)))
  (eng:install-method clun "zstdDecompress" 1
    (lambda (this args) (declare (ignore this)) (%zstd-unsupported args)))

  (let* ((prototype (eng:new-object))
         (constructor nil))
    (eng:install-method prototype "extract" 1
      (lambda (this args)
        (let ((archive (%require-archive this))
              (path (eng:to-string (eng:arg args 0)))
              (globs (%archive-extract-globs (eng:arg args 1))))
          (%archive-async (g)
            (%with-compress
             (lambda ()
               (coerce
                (clun.archive:extract-archive (%archive-materialize archive) path :glob globs)
                'double-float)))))))
    (eng:install-method prototype "bytes" 0
      (lambda (this args)
        (declare (ignore args))
        (let ((archive (%require-archive this)))
          (%archive-async (g)
            (%with-compress
             (lambda () (eng:u8-from-octets (%archive-materialize archive))))))))
    (eng:install-method prototype "blob" 0
      (lambda (this args)
        (declare (ignore args))
        (let ((archive (%require-archive this)))
          (%archive-async (g)
            (%with-compress
             (lambda ()
               (%new-blob-from-octets
                (%archive-materialize archive)
                (if (eq (js-archive-compress archive) :gzip)
                    "application/gzip"
                    "application/x-tar"))))))))
    (eng:install-method prototype "files" 1
      (lambda (this args)
        (let* ((archive (%require-archive this))
               (g0 (eng:arg args 0))
               (globs (cond
                        ((eng:js-nullish-p g0) nil)
                        ((eng:js-string-p g0) (list (eng:to-string g0)))
                        ((eng:js-array-p g0)
                         (loop for i from 0 below (eng:array-length g0)
                               collect (eng:to-string
                                        (eng:js-get g0 (princ-to-string i)))))
                        (t nil))))
          (%archive-async (g)
            (%with-compress
             (lambda ()
               (let* ((entries (clun.archive:parse-archive-bytes (%archive-materialize archive)))
                      (map (eng:js-construct (eng:js-get g "Map") nil))
                      (set (eng:js-get map "set")))
                 (dolist (e entries)
                   (when (and (member (clun.tarball:te-typeflag e) '(#\0 #\Nul #\7))
                              (or (null globs)
                                  (clun.archive::%glob-match (clun.tarball:te-name e) globs)))
                     (eng:js-call set map
                                  (list (clun.tarball:te-name e)
                                        (%new-blob-from-octets
                                         (or (clun.tarball:te-data e)
                                             (make-array 0 :element-type '(unsigned-byte 8)))
                                         "")))))
                 map)))))))

    (setf constructor
          (eng:make-native-function
           "Archive" 1
           (lambda (this args)
             (declare (ignore this args))
             (eng:throw-type-error
              "Archive constructor cannot be invoked without 'new'"))
           :construct
           (lambda (args new-target)
             (let ((arch (%make-archive-instance (eng:arg args 0) (eng:arg args 1))))
               (setf (eng::js-object-proto arch)
                     (eng::nt-prototype new-target prototype))
               arch))))    (eng::obj-set-desc prototype "constructor"
                       (eng::data-pd constructor :writable t :enumerable nil
                                                :configurable t))
    (eng::obj-set-desc prototype (eng:well-known :to-string-tag)
                       (eng::data-pd "Archive" :writable nil :enumerable nil
                                           :configurable t))
    (eng::obj-set-desc constructor "prototype"
                       (eng::data-pd prototype :writable nil :enumerable nil
                                              :configurable nil))
    (eng:data-prop
     constructor "write"
     (eng:make-native-function
      "write" 2
      (lambda (this args)
        (declare (ignore this))
        (let* ((path (eng:to-string (eng:arg args 0)))
               (data (eng:arg args 1))
               (opts (eng:arg args 2)))
          (%archive-async (g)
            (%with-compress
             (lambda ()
               (let ((bytes
                       (if (js-archive-p data)
                           (%archive-materialize data)
                           (multiple-value-bind (compress level)
                               (%archive-options opts)
                             (cond
                               ((and (eng:js-object-p data)
                                     (not (%archive-buffer-source-p data)))
                                (clun.archive:build-archive-bytes
                                 (%object-to-entries data)
                                 :compress compress :level level))
                               (t
                                (let ((octets (%archive-octets data "data")))
                                  (if (eq compress :gzip)
                                      (if (cmp:gzip-magic-p octets)
                                          octets
                                          (cmp:gzip-compress octets :level level))
                                      octets))))))))
                 (sys:write-file-octets path bytes)
                 eng:+undefined+))))))))
    (eng::obj-set-desc clun "Archive"
                       (eng::data-pd constructor :writable t :enumerable t
                                               :configurable nil))
    constructor))
