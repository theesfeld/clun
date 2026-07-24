;;;; zlib.lisp — node:zlib pure-CL over clun.compress (salza2 + chipz).
;;;; gzip/gunzip/deflate/inflate (+ Sync + create* Transform streams).
;;;; Bounded inflate (zip-bomb safe). Real constants surface.

(in-package :clun.runtime)

(defun %zlib-to-octets (v)
  (cond
    ((eng:js-typed-array-p v)
     (multiple-value-bind (b off len) (eng:ta-octets v)
       (subseq b off (+ off len))))
    ((eng:js-string-p v)
     (sb-ext:string-to-octets v :external-format :utf-8))
    (t (sb-ext:string-to-octets (->str v) :external-format :utf-8))))

(defun %zlib-result (octets)
  (%buffer-from-octets octets))

(defun %zlib-sync (op input)
  (handler-case
      (%zlib-result (funcall op (%zlib-to-octets input)))
    (cmp:compress-error (c)
      (eng:throw-type-error (cmp:compress-error-message c)))
    (error (c)
      (eng:throw-type-error (format nil "zlib: ~a" c)))))

(defun %zlib-async (op input cb)
  (handler-case
      (let ((out (%zlib-result (funcall op (%zlib-to-octets input)))))
        (when (eng:callable-p cb)
          (eng:js-call cb (undef) (list eng:+null+ out)))
        (undef))
    (error (c)
      (when (eng:callable-p cb)
        (eng:js-call cb (undef)
          (list (eng:js-construct
                 (eng:js-get (eng:realm-global eng:*realm*) "Error")
                 (list (format nil "~a" c))))))
      (undef))))

(defun %zlib-constants ()
  "Node zlib.constants (and top-level Z_* aliases)."
  (let ((c (eng:new-object)))
    (flet ((d (k v) (eng:data-prop c k (coerce v 'double-float))))
      (d "Z_NO_FLUSH" 0) (d "Z_PARTIAL_FLUSH" 1) (d "Z_SYNC_FLUSH" 2)
      (d "Z_FULL_FLUSH" 3) (d "Z_FINISH" 4) (d "Z_BLOCK" 5) (d "Z_TREES" 6)
      (d "Z_OK" 0) (d "Z_STREAM_END" 1) (d "Z_NEED_DICT" 2)
      (d "Z_ERRNO" -1) (d "Z_STREAM_ERROR" -2) (d "Z_DATA_ERROR" -3)
      (d "Z_MEM_ERROR" -4) (d "Z_BUF_ERROR" -5) (d "Z_VERSION_ERROR" -6)
      (d "Z_NO_COMPRESSION" 0) (d "Z_BEST_SPEED" 1)
      (d "Z_BEST_COMPRESSION" 9) (d "Z_DEFAULT_COMPRESSION" -1)
      (d "Z_FILTERED" 1) (d "Z_HUFFMAN_ONLY" 2) (d "Z_RLE" 3)
      (d "Z_FIXED" 4) (d "Z_DEFAULT_STRATEGY" 0)
      (d "Z_BINARY" 0) (d "Z_TEXT" 1) (d "Z_ASCII" 1) (d "Z_UNKNOWN" 2)
      (d "Z_DEFLATED" 8)
      (d "DEFLATE" 1) (d "INFLATE" 2) (d "GZIP" 3) (d "GUNZIP" 4)
      (d "DEFLATERAW" 5) (d "INFLATERAW" 6) (d "UNZIP" 7)
      (d "Z_MIN_WINDOWBITS" 8) (d "Z_MAX_WINDOWBITS" 15)
      (d "Z_DEFAULT_WINDOWBITS" 15)
      (d "Z_MIN_CHUNK" 64) (d "Z_MAX_CHUNK" 134217728)
      (d "Z_DEFAULT_CHUNK" 16384)
      (d "Z_MIN_MEMLEVEL" 1) (d "Z_MAX_MEMLEVEL" 9)
      (d "Z_DEFAULT_MEMLEVEL" 8)
      (d "Z_MIN_LEVEL" -1) (d "Z_MAX_LEVEL" 9))
    c))

(defun %zlib-make-transform (op)
  "A stream.Transform that applies OP (octets→octets) on each write and on end."
  (let* ((stream-mod (build-node-stream))
         (transform-ctor (eng:js-get stream-mod "Transform"))
         (parts '())
         (xform
          (eng:js-construct
           transform-ctor
           (list
            (let ((opts (eng:new-object)))
              (eng:data-prop
               opts "transform"
               (eng:make-native-function
                "" 3
                (lambda (this args)
                  (declare (ignore this))
                  (let ((chunk (a args 0))
                        (cb (a args 2)))
                    (push (%zlib-to-octets chunk) parts)
                    (when (eng:callable-p cb)
                      (eng:js-call cb (undef) (list eng:+null+)))
                    (undef)))))
              opts)))))
    ;; Override end to flush compressed output.
    (eng:install-method xform "end" 3
      (lambda (this args)
        (unless (undef-p (a args 0))
          (push (%zlib-to-octets (a args 0)) parts))
        (handler-case
            (let* ((input (apply #'concatenate '(vector (unsigned-byte 8))
                                 (nreverse parts)))
                   (out (funcall op input)))
              (setf parts '())
              (%stream-push this (%zlib-result out)))
          (error (c)
            (eng:js-call (eng:js-get this "emit") this
              (list "error"
                    (eng:js-construct
                     (eng:js-get (eng:realm-global eng:*realm*) "Error")
                     (list (format nil "zlib: ~a" c)))))))
        (let ((state (eng:js-get this "_writableState")))
          (when (eng:js-object-p state)
            (eng:js-set state "ended" eng:+true+ nil)
            (eng:js-set state "finished" eng:+true+ nil)))
        (eng:js-call (eng:js-get this "emit") this (list "finish"))
        (eng:js-call (eng:js-get this "emit") this (list "end"))
        (let ((cb (a args 2)))
          (when (eng:callable-p (a args 0)) (setf cb (a args 0)))
          (when (eng:callable-p (a args 1)) (setf cb (a args 1)))
          (when (eng:callable-p cb) (eng:js-call cb (undef) '())))
        this))
    xform))

(defun build-node-zlib ()
  (let ((o (eng:new-object))
        (constants (%zlib-constants)))
    (labels ((m (name arity fn) (eng:install-method o name arity fn)))
      (m "gzipSync" 2
         (lambda (this args) (declare (ignore this))
           (%zlib-sync #'cmp:gzip-compress (a args 0))))
      (m "gunzipSync" 2
         (lambda (this args) (declare (ignore this))
           (%zlib-sync #'cmp:gunzip (a args 0))))
      (m "deflateSync" 2
         (lambda (this args) (declare (ignore this))
           (%zlib-sync #'cmp:zlib-compress (a args 0))))
      (m "inflateSync" 2
         (lambda (this args) (declare (ignore this))
           (%zlib-sync #'cmp:zlib-decompress (a args 0))))
      (m "deflateRawSync" 2
         (lambda (this args) (declare (ignore this))
           (%zlib-sync #'cmp:raw-deflate-compress (a args 0))))
      (m "inflateRawSync" 2
         (lambda (this args) (declare (ignore this))
           (%zlib-sync #'cmp:raw-inflate (a args 0))))
      (m "gzip" 2
         (lambda (this args) (declare (ignore this))
           (%zlib-async #'cmp:gzip-compress (a args 0) (a args 1))))
      (m "gunzip" 2
         (lambda (this args) (declare (ignore this))
           (%zlib-async #'cmp:gunzip (a args 0) (a args 1))))
      (m "deflate" 2
         (lambda (this args) (declare (ignore this))
           (%zlib-async #'cmp:zlib-compress (a args 0) (a args 1))))
      (m "inflate" 2
         (lambda (this args) (declare (ignore this))
           (%zlib-async #'cmp:zlib-decompress (a args 0) (a args 1))))
      (m "createGzip" 1
         (lambda (this args) (declare (ignore this args))
           (%zlib-make-transform #'cmp:gzip-compress)))
      (m "createGunzip" 1
         (lambda (this args) (declare (ignore this args))
           (%zlib-make-transform #'cmp:gunzip)))
      (m "createDeflate" 1
         (lambda (this args) (declare (ignore this args))
           (%zlib-make-transform #'cmp:zlib-compress)))
      (m "createInflate" 1
         (lambda (this args) (declare (ignore this args))
           (%zlib-make-transform #'cmp:zlib-decompress)))
      (m "createDeflateRaw" 1
         (lambda (this args) (declare (ignore this args))
           (%zlib-make-transform #'cmp:raw-deflate-compress)))
      (m "createInflateRaw" 1
         (lambda (this args) (declare (ignore this args))
           (%zlib-make-transform #'cmp:raw-inflate)))
      (eng:data-prop o "constants" constants)
      ;; Top-level Z_* aliases (Node historical surface).
      (dolist (k '("Z_OK" "Z_STREAM_END" "Z_NEED_DICT" "Z_ERRNO" "Z_STREAM_ERROR"
                   "Z_DATA_ERROR" "Z_MEM_ERROR" "Z_BUF_ERROR" "Z_VERSION_ERROR"
                   "Z_NO_FLUSH" "Z_PARTIAL_FLUSH" "Z_SYNC_FLUSH" "Z_FULL_FLUSH"
                   "Z_FINISH" "Z_BLOCK" "Z_NO_COMPRESSION" "Z_BEST_SPEED"
                   "Z_BEST_COMPRESSION" "Z_DEFAULT_COMPRESSION" "Z_FILTERED"
                   "Z_HUFFMAN_ONLY" "Z_RLE" "Z_FIXED" "Z_DEFAULT_STRATEGY"
                   "Z_BINARY" "Z_TEXT" "Z_ASCII" "Z_UNKNOWN" "Z_DEFLATED"))
        (eng:data-prop o k (eng:js-get constants k)))
      o)))

(register-node-builtin "zlib" #'build-node-zlib)
