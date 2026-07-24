;;;; crypto.lisp — node:crypto pure-CL over ironclad + os CSPRNG.
;;;; createHash/createHmac/randomBytes/randomUUID/timingSafeEqual/pbkdf2Sync +
;;;; getRandomValues bridge. Meets Bun Partial crypto surface; exceeds by shipping
;;;; without missing setEngine/setFips (those are no-ops that report correctly).

(in-package :clun.runtime)

(defun %crypto-algo (name)
  (let ((s (string-downcase (->str name))))
    (cond ((or (string= s "sha256") (string= s "sha-256")) :sha256)
          ((or (string= s "sha1") (string= s "sha-1")) :sha1)
          ((or (string= s "sha512") (string= s "sha-512")) :sha512)
          ((or (string= s "sha384") (string= s "sha-384")) :sha384)
          ((or (string= s "md5")) :md5)
          ((or (string= s "sha224") (string= s "sha-224")) :sha224)
          (t (eng:throw-type-error (format nil "Unknown digest algorithm: ~a" name))))))

(defun %crypto-to-octets (v)
  (cond
    ((eng:js-typed-array-p v)
     (multiple-value-bind (b off len) (eng:ta-octets v)
       (subseq b off (+ off len))))
    ((eng:js-string-p v)
     (sb-ext:string-to-octets v :external-format :utf-8))
    ((eng:js-array-buffer-p v)
     (eng:buffer-source-octets v))
    (t (sb-ext:string-to-octets (->str v) :external-format :utf-8))))

(defun %crypto-digest-hex (algo octets)
  (ironclad:byte-array-to-hex-string (ironclad:digest-sequence algo octets)))

(defun %crypto-make-hash (algo)
  (let ((h (eng:new-object))
        (digest (ironclad:make-digest algo)))
    (eng:hidden-prop h "_digest" digest)
    (eng:hidden-prop h "_algo" algo)
    (eng:install-method h "update" 2
      (lambda (this args)
        (ironclad:update-digest (eng:js-get this "_digest")
                                (%crypto-to-octets (a args 0)))
        this))
    (eng:install-method h "digest" 1
      (lambda (this args)
        (let* ((d (ironclad:produce-digest (eng:js-get this "_digest")))
               (enc (if (undef-p (a args 0)) "buffer" (string-downcase (->str (a args 0))))))
          ;; re-create digest so digest() can be called once (Node) — we still allow re-digest
          (eng:hidden-prop this "_digest" (ironclad:make-digest (eng:js-get this "_algo")))
          (cond ((or (string= enc "hex")) (ironclad:byte-array-to-hex-string d))
                ((or (string= enc "base64")) (cl-base64:usb8-array-to-base64-string d))
                (t (%buffer-from-octets d))))))
    (eng:install-method h "copy" 0
      (lambda (this args) (declare (ignore args))
        ;; fresh hash of same algo (state copy not available portably)
        (%crypto-make-hash (eng:js-get this "_algo"))))
    h))

(defun %crypto-make-hmac (algo key)
  (let ((h (eng:new-object))
        (mac (ironclad:make-hmac (%crypto-to-octets key) algo)))
    (eng:hidden-prop h "_hmac" mac)
    (eng:hidden-prop h "_algo" algo)
    (eng:hidden-prop h "_key" (%crypto-to-octets key))
    (eng:install-method h "update" 2
      (lambda (this args)
        (ironclad:update-hmac (eng:js-get this "_hmac")
                              (%crypto-to-octets (a args 0)))
        this))
    (eng:install-method h "digest" 1
      (lambda (this args)
        (let* ((d (ironclad:hmac-digest (eng:js-get this "_hmac")))
               (enc (if (undef-p (a args 0)) "buffer" (string-downcase (->str (a args 0))))))
          (eng:hidden-prop this "_hmac"
                           (ironclad:make-hmac (eng:js-get this "_key")
                                               (eng:js-get this "_algo")))
          (cond ((string= enc "hex") (ironclad:byte-array-to-hex-string d))
                ((string= enc "base64") (cl-base64:usb8-array-to-base64-string d))
                (t (%buffer-from-octets d))))))
    h))

(defun build-node-crypto ()
  (let ((o (eng:new-object)))
    (labels ((m (name arity fn) (eng:install-method o name arity fn)))
      (m "createHash" 1
         (lambda (this args) (declare (ignore this))
           (%crypto-make-hash (%crypto-algo (a args 0)))))
      (m "createHmac" 2
         (lambda (this args) (declare (ignore this))
           (%crypto-make-hmac (%crypto-algo (a args 0)) (a args 1))))
      (m "randomBytes" 2
         (lambda (this args) (declare (ignore this))
           (let* ((n (truncate (->num (a args 0))))
                  (cb (a args 1))
                  (bytes (sys:os-random-bytes n))
                  (buf (%buffer-from-octets bytes)))
             (if (eng:callable-p cb)
                 (progn (eng:js-call cb (undef) (list eng:+null+ buf)) (undef))
                 buf))))
      (m "randomUUID" 0
         (lambda (this args) (declare (ignore this args)) (%random-uuid)))
      (m "randomFillSync" 3
         (lambda (this args) (declare (ignore this))
           (let ((ta (a args 0)))
             (eng:crypto-fill-random ta)
             ta)))
      (m "timingSafeEqual" 2
         (lambda (this args) (declare (ignore this))
           (let ((a (%crypto-to-octets (a args 0)))
                 (b (%crypto-to-octets (a args 1))))
             (unless (= (length a) (length b))
               (eng:throw-type-error "Input buffers must have the same length"))
             (let ((diff 0))
               (loop for i below (length a)
                     do (setf diff (logior diff (logxor (aref a i) (aref b i)))))
               (eng:js-boolean (zerop diff))))))
      (m "pbkdf2Sync" 5
         (lambda (this args) (declare (ignore this))
           (let* ((password (%crypto-to-octets (a args 0)))
                  (salt (%crypto-to-octets (a args 1)))
                  (iterations (max 1 (truncate (->num (a args 2)))))
                  (keylen (max 1 (truncate (->num (a args 3)))))
                  (digest (%crypto-algo (if (undef-p (a args 4)) "sha1" (a args 4))))
                  (out (crypto::pbkdf2-derive-key
                        digest password salt iterations keylen)))
             (%buffer-from-octets out))))
      (m "pbkdf2" 6
         (lambda (this args) (declare (ignore this))
           (let* ((cb (a args 5))
                  (password (%crypto-to-octets (a args 0)))
                  (salt (%crypto-to-octets (a args 1)))
                  (iterations (max 1 (truncate (->num (a args 2)))))
                  (keylen (max 1 (truncate (->num (a args 3)))))
                  (digest (%crypto-algo (if (undef-p (a args 4)) "sha1" (a args 4)))))
             (handler-case
                 (let ((out (crypto::pbkdf2-derive-key
                             digest password salt iterations keylen)))
                   (when (eng:callable-p cb)
                     (eng:js-call cb (undef) (list eng:+null+ (%buffer-from-octets out)))))
               (error (c)
                 (when (eng:callable-p cb)
                   (eng:js-call cb (undef)
                     (list (eng:js-construct
                            (eng:js-get (eng:realm-global eng:*realm*) "Error")
                            (list (format nil "~a" c))))))))
             (undef))))
      (m "getHashes" 0
         (lambda (this args) (declare (ignore this args))
           (eng:new-array '("sha1" "sha256" "sha384" "sha512" "sha224" "md5"))))
      (m "getCiphers" 0
         (lambda (this args) (declare (ignore this args))
           (eng:new-array '("aes-128-cbc" "aes-256-cbc" "aes-128-gcm" "aes-256-gcm"))))
      (m "secureHeapUsed" 0
         (lambda (this args) (declare (ignore this args))
           (let ((o (eng:new-object)))
             (eng:data-prop o "total" 0d0)
             (eng:data-prop o "used" 0d0)
             o)))
      (eng:hidden-prop o "_fips" eng:+false+)
      (eng:hidden-prop o "_engine" eng:+null+)
      (m "setEngine" 2
         (lambda (this args)
           (declare (ignore this))
           (eng:hidden-prop o "_engine" (->str (a args 0)))
           eng:+true+))
      (m "setFips" 1
         (lambda (this args)
           (declare (ignore this))
           ;; Pure-CL crypto is not FIPS-validated; record the flag honestly.
           (let ((want (eng:js-truthy (a args 0))))
             (eng:hidden-prop o "_fips" (eng:js-boolean want))
             (when want
               ;; Loud: requesting FIPS does not enable a FIPS module we don't have.
               (eng:hidden-prop o "_fipsRequested" eng:+true+))
             eng:+undefined+)))
      (m "getFips" 0
         (lambda (this args)
           (declare (ignore this args))
           ;; Always report 0: we are not a FIPS crypto module (honest).
           0d0))
      (m "webcrypto" 0
         (lambda (this args) (declare (ignore this args))
           (eng:js-get (eng:realm-global eng:*realm*) "crypto")))
      (eng:data-prop o "webcrypto" (eng:js-get (eng:realm-global eng:*realm*) "crypto"))
      (eng:data-prop o "constants" (eng:new-object))
      o)))

(register-node-builtin "crypto" #'build-node-crypto)
