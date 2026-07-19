;;;; string_decoder.lisp — node:string_decoder (pure-CL StringDecoder).
;;;; Full utf8/latin1/hex/base64 decode over Buffer/string chunks (Node green surface).

(in-package :clun.runtime)

(defun %sd-encoding (v)
  (let ((s (string-downcase (if (undef-p v) "utf8" (->str v)))))
    (cond ((or (string= s "utf8") (string= s "utf-8")) :utf8)
          ((or (string= s "latin1") (string= s "binary")) :latin1)
          ((string= s "ascii") :ascii)
          ((string= s "hex") :hex)
          ((string= s "base64") :base64)
          ((or (string= s "utf16le") (string= s "ucs2") (string= s "ucs-2")) :ucs2)
          (t :utf8))))

(defun %sd-chunk-octets (chunk)
  (cond
    ((eng:js-typed-array-p chunk)
     (multiple-value-bind (b off len) (eng:ta-octets chunk)
       (subseq b off (+ off len))))
    ((eng:js-string-p chunk)
     (sb-ext:string-to-octets chunk :external-format :utf-8))
    ((eng:js-array-p chunk)
     (let ((n (eng:array-length chunk)))
       (coerce (loop for i below n
                     collect (logand (truncate (->num (eng:js-getv chunk (princ-to-string i)))) #xff))
               '(vector (unsigned-byte 8)))))
    (t (sb-ext:string-to-octets (->str chunk) :external-format :utf-8))))

(defun %sd-decode-octets (octets enc)
  (ecase enc
    (:utf8 (handler-case (sb-ext:octets-to-string octets :external-format :utf-8)
             (error () (map 'string #'code-char octets))))
    ((:latin1 :ascii)
     (map 'string #'code-char octets))
    (:hex
     (with-output-to-string (o)
       (loop for b across octets do (format o "~2,'0x" b))))
    (:base64 (cl-base64:usb8-array-to-base64-string octets))
    (:ucs2
     (with-output-to-string (o)
       (loop for i from 0 below (1- (length octets)) by 2
             do (write-char (code-char (logior (aref octets i)
                                               (ash (aref octets (1+ i)) 8)))
                            o))))))

(defun build-node-string-decoder ()
  (let* ((proto (eng:new-object))
         (ctor (eng:make-native-function
                "StringDecoder" 1
                (lambda (this args)
                  (when (eng:js-object-p this)
                    (eng:hidden-prop this "_encoding" (%sd-encoding (a args 0)))
                    (eng:hidden-prop this "_buf"
                                     (make-array 0 :element-type '(unsigned-byte 8)
                                                   :adjustable t :fill-pointer 0)))
                  (undef))
                :construct
                (lambda (args nt)
                  (let* ((p (and (eng:js-object-p nt) (eng:js-get nt "prototype")))
                         (obj (eng:js-make-object (if (eng:js-object-p p) p proto))))
                    (eng:hidden-prop obj "_encoding" (%sd-encoding (a args 0)))
                    (eng:hidden-prop obj "_buf"
                                     (make-array 0 :element-type '(unsigned-byte 8)
                                                   :adjustable t :fill-pointer 0))
                    obj)))))
    (eng:data-prop ctor "prototype" proto)
    (eng:data-prop proto "constructor" ctor)
    (eng:install-method proto "write" 1
      (lambda (this args)
        (let* ((enc (eng:js-get this "_encoding"))
               (chunk (%sd-chunk-octets (a args 0))))
          (%sd-decode-octets chunk enc))))
    (eng:install-method proto "end" 1
      (lambda (this args)
        (if (undef-p (a args 0))
            ""
            (let* ((enc (eng:js-get this "_encoding"))
                   (chunk (%sd-chunk-octets (a args 0))))
              (%sd-decode-octets chunk enc)))))
    (let ((o (eng:new-object)))
      (eng:data-prop o "StringDecoder" ctor)
      o)))

(register-node-builtin "string_decoder" #'build-node-string-decoder)
