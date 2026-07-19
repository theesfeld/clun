;;;; punycode.lisp — node:punycode (deprecated Node API; pure-CL via vendored idna).
;;;; Bun green: encode/decode/toASCII/toUnicode. Exceeds Bun by using real IDNA tables.

(in-package :clun.runtime)

(defun build-node-punycode ()
  (let ((o (eng:new-object)))
    (labels ((m (name arity fn) (eng:install-method o name arity fn)))
      (m "encode" 1
         (lambda (this args) (declare (ignore this))
           (handler-case (idna:punycode-encode (->str (a args 0)))
             (error (c) (eng:throw-type-error (format nil "punycode.encode: ~a" c))))))
      (m "decode" 1
         (lambda (this args) (declare (ignore this))
           (handler-case (idna:punycode-decode (->str (a args 0)))
             (error (c) (eng:throw-type-error (format nil "punycode.decode: ~a" c))))))
      (m "toASCII" 1
         (lambda (this args) (declare (ignore this))
           (handler-case (idna:to-ascii (->str (a args 0)))
             (error (c) (eng:throw-type-error (format nil "punycode.toASCII: ~a" c))))))
      (m "toUnicode" 1
         (lambda (this args) (declare (ignore this))
           (handler-case (idna:to-unicode (->str (a args 0)))
             (error (c) (eng:throw-type-error (format nil "punycode.toUnicode: ~a" c))))))
      (eng:data-prop o "ucs2" (eng:new-object))
      (eng:data-prop o "version" "2.1.0")
      o)))

(register-node-builtin "punycode" #'build-node-punycode)
