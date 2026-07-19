;;;; zlib.lisp — node:zlib pure-CL over clun.compress (salza2 + chipz).
;;;; gzip/gunzip/deflate/inflate (+ Sync variants). Bounded inflate (zip-bomb safe).

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

(defun build-node-zlib ()
  (let ((o (eng:new-object)))
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
      (m "constants" 0 (lambda (this args) (declare (ignore this args)) (eng:new-object)))
      (eng:data-prop o "constants" (eng:new-object))
      (eng:data-prop o "Z_OK" 0d0)
      (eng:data-prop o "Z_STREAM_END" 1d0)
      (eng:data-prop o "Z_DEFAULT_COMPRESSION" -1d0)
      o)))

(register-node-builtin "zlib" #'build-node-zlib)
