;;;; csrf-tests.lisp -- engine-free Phase 35 CSRF wire/authentication coverage.

(in-package :clun-test)

(defparameter +csrf-algorithms+
  '((:sha256 . 32)
    (:sha384 . 48)
    (:sha512 . 64)
    (:sha512/256 . 32)
    (:blake2b256 . 32)
    (:blake2b512 . 64)))

(defparameter +csrf-encodings+ '(:base64 :base64url :hex))

(defparameter +csrf-stable-sha256-hex+
  (concatenate
   'string
   "0000018bcfe5687b000102030405060708090a0b0c0d0e0f0000000000000000"
   "cb92483c1b9ef64def3b2cad92c10101b7c2de73840c8a298df918dcb2ef9ca6"))

(defparameter +csrf-stable-sha256-base64+
  "AAABi8/laHsAAQIDBAUGBwgJCgsMDQ4PAAAAAAAAAADLkkg8G572Te87LK2SwQEBt8Lec4QMiimN+Rjcsu+cpg==")

(defparameter +csrf-stable-sha256-base64url+
  "AAABi8_laHsAAQIDBAUGBwgJCgsMDQ4PAAAAAAAAAADLkkg8G572Te87LK2SwQEBt8Lec4QMiimN-Rjcsu-cpg")

(defparameter +csrf-session-sha256-hex+
  (concatenate
   'string
   "0000018bcfe5687b000102030405060708090a0b0c0d0e0f0000000000000000"
   "77718d2c37580995f735b333d7855bf4b74877e82ac4dda40f63f66a6929b60b"))

;; Fixed with pinned Bun 1.3.14's keyed CryptoHasher and independently accepted
;; by Bun.CSRF.verify. These share the timestamp/nonce/zero-age payload above.
(defparameter +csrf-bun-hex-vectors+
  '((:sha256 .
     "0000018bcfe5687b000102030405060708090a0b0c0d0e0f0000000000000000cb92483c1b9ef64def3b2cad92c10101b7c2de73840c8a298df918dcb2ef9ca6")
    (:sha384 .
     "0000018bcfe5687b000102030405060708090a0b0c0d0e0f0000000000000000bd40ec042b2396b0b344b08ba3461c3c417aad43ea2a181afcad9302edae9ebc1f86a7b4db648c86ca63861af771ffa7")
    (:sha512 .
     "0000018bcfe5687b000102030405060708090a0b0c0d0e0f0000000000000000b7fc044438f63e657a3a8fafb0f8cdac1b9ccd5abd8f840173a1bfb9e79fcb9cc9f6ccb5032c22bef933216739cd21a867fad8364ab8337014db2d8fc05dd8da")
    (:sha512/256 .
     "0000018bcfe5687b000102030405060708090a0b0c0d0e0f0000000000000000f62bae8696339267e1e9157d4f112ce3d0c83d9d2997cb60c2196b1fc6d44d5b")
    (:blake2b256 .
     "0000018bcfe5687b000102030405060708090a0b0c0d0e0f0000000000000000d21e0f5b8b5183d3dff039fc9c22bab56cffd184a39087afc53c32465379bf0d")
    (:blake2b512 .
     "0000018bcfe5687b000102030405060708090a0b0c0d0e0f0000000000000000ed7d9a113d3b18772a648d40d92fa743a17a92d07ddadd824945a6b98db7dbae94e0166195b7a07c49cb3872ba872590bce3cff3125b21cd7caea91d6d53af32")))

(defparameter +csrf-replacement-secret-sha256-hex+
  (concatenate
   'string
   "0000018bcfe5687b000102030405060708090a0b0c0d0e0f0000000000000000"
   "37cc8efed1a9dfb50853bdae26ecf322dcd36703ec4c00e03163e82abca1b92c"))

(defun csrf-ascii (string)
  (let ((octets (make-array (length string)
                            :element-type '(unsigned-byte 8))))
    (dotimes (index (length string) octets)
      (setf (aref octets index) (char-code (char string index))))))

(defun csrf-octets (length &optional (initial-element 0))
  (make-array length :element-type '(unsigned-byte 8)
                     :initial-element initial-element))

(defun csrf-nonce ()
  (let ((nonce (csrf-octets 16)))
    (dotimes (index 16 nonce)
      (setf (aref nonce index) index))))

(defun csrf-secret () (csrf-ascii "phase-35-secret"))
(defun csrf-session () (csrf-ascii "phase-session"))

(defun csrf-generate (&key (secret (csrf-secret)) session-id
                        (timestamp-ms 1700000000123) (expires-in 0)
                        (nonce (csrf-nonce)) (algorithm :sha256)
                        (encoding :base64url))
  (clun.csrf:core-generate
   secret :session-id session-id :timestamp-ms timestamp-ms
   :expires-in expires-in :nonce nonce :algorithm algorithm :encoding encoding))

(defun csrf-verify (token &key (secret (csrf-secret)) session-id
                            (now-ms 1700000000123) (max-age 0)
                            (algorithm :sha256) (encoding :base64url))
  (clun.csrf:core-verify
   token secret :session-id session-id :now-ms now-ms :max-age max-age
   :algorithm algorithm :encoding encoding))

(defun csrf-replace-character (string index replacement)
  (let ((copy (copy-seq string)))
    (setf (char copy index) replacement)
    copy))

(defun csrf-insert (string index insertion)
  (concatenate 'string (subseq string 0 index) insertion (subseq string index)))

(defun csrf-null-string (&optional (count 1))
  (make-string count :initial-element (code-char 0)))

(defun csrf-base64-length (raw-length)
  (* 4 (ceiling raw-length 3)))

(defun csrf-base64url-length (raw-length)
  (ceiling (* raw-length 8) 6))

(defun csrf-fuzz-string (seed length)
  (let ((state seed)
        (output (make-string length)))
    (dotimes (index length output)
      (setf state (ldb (byte 32 0) (+ (* state 1664525) 1013904223))
            (char output index) (code-char (ldb (byte 7 24) state))))))

(define-test security/csrf-stable-wire-vector
  ;; HMAC-SHA-256 computed independently with OpenSSL. The complete hex token was
  ;; also accepted by pinned Bun 1.3.14 with secret, maxAge=0, and hex encoding.
  (is string= +csrf-stable-sha256-hex+
      (csrf-generate :encoding :hex))
  (is string= +csrf-stable-sha256-base64+
      (csrf-generate :encoding :base64))
  (is string= +csrf-stable-sha256-base64url+
      (csrf-generate :encoding :base64url))
  (true (csrf-verify +csrf-stable-sha256-hex+ :encoding :hex
                     :now-ms #xffffffffffffffff))
  (true (csrf-verify +csrf-stable-sha256-base64+ :encoding :base64
                     :now-ms #xffffffffffffffff))
  (true (csrf-verify +csrf-stable-sha256-base64url+ :encoding :base64url
                     :now-ms #xffffffffffffffff))
  (dolist (vector +csrf-bun-hex-vectors+)
    (is string= (cdr vector)
        (csrf-generate :algorithm (car vector) :encoding :hex))
    (true (csrf-verify (cdr vector) :algorithm (car vector) :encoding :hex
                      :now-ms #xffffffffffffffff)))
  ;; U+FFFD bytes are the pinned replacement-mode encoding of one lone surrogate.
  (let ((replacement (make-array 3 :element-type '(unsigned-byte 8)
                                   :initial-contents '(#xef #xbf #xbd))))
    (is string= +csrf-replacement-secret-sha256-hex+
        (csrf-generate :secret replacement :encoding :hex))
    (true (csrf-verify +csrf-replacement-secret-sha256-hex+
                       :secret replacement :encoding :hex
                       :now-ms #xffffffffffffffff))))

(define-test security/csrf-algorithms-and-encodings
  (dolist (algorithm +csrf-algorithms+)
    (dolist (encoding +csrf-encodings+)
      (let* ((digest-length (cdr algorithm))
             (raw-length (+ 32 digest-length))
             (token (csrf-generate :algorithm (car algorithm)
                                   :encoding encoding
                                   :timestamp-ms 1000
                                   :expires-in 50))
             (expected-length
               (ecase encoding
                 (:hex (* raw-length 2))
                 (:base64 (csrf-base64-length raw-length))
                 (:base64url (csrf-base64url-length raw-length)))))
        (is = expected-length (length token))
        (is string= token
            (csrf-generate :algorithm (car algorithm)
                           :encoding encoding
                           :timestamp-ms 1000
                           :expires-in 50))
        (true (csrf-verify token :algorithm (car algorithm)
                                 :encoding encoding
                                 :now-ms 1050 :max-age 100))
        (false (csrf-verify token :algorithm (car algorithm)
                                  :encoding encoding
                                  :now-ms 1051 :max-age 100))))))

(define-test security/csrf-session-binding
  (let* ((session (csrf-session))
         (other (csrf-ascii "other-session"))
         (bound (csrf-generate :session-id session :encoding :hex))
         (unbound (csrf-generate :encoding :hex)))
    (is string= +csrf-session-sha256-hex+ bound)
    (isnt string= bound unbound)
    (true (csrf-verify bound :session-id session :encoding :hex))
    (false (csrf-verify bound :encoding :hex))
    (false (csrf-verify bound :session-id other :encoding :hex))
    (false (csrf-verify unbound :session-id session :encoding :hex))
    (true (csrf-verify unbound :encoding :hex))))

(define-test security/csrf-authentication-failures
  (let ((token (csrf-generate :encoding :hex)))
    (false (csrf-verify token :encoding :hex
                       :secret (csrf-ascii "wrong-secret")))
    (false (csrf-verify token :encoding :hex :algorithm :blake2b256))
    (false (csrf-verify token :encoding :base64url))
    (false (csrf-verify (subseq token 0 (1- (length token))) :encoding :hex))
    (false (csrf-verify (concatenate 'string token "00") :encoding :hex))))

(define-test security/csrf-every-byte-tamper
  (let ((token (csrf-generate :encoding :hex)))
    ;; Cover all 32 payload bytes and all 32 SHA-256 MAC bytes independently.
    (dotimes (byte-index 64)
      (let* ((character-index (1+ (* byte-index 2)))
             (original (char token character-index))
             (replacement (if (char= original #\0) #\1 #\0)))
        (false (csrf-verify
                (csrf-replace-character token character-index replacement)
                :encoding :hex))))))

(define-test security/csrf-expiry-boundaries
  (let ((embedded (csrf-generate :timestamp-ms 1000 :expires-in 100
                                 :encoding :hex))
        (caller (csrf-generate :timestamp-ms 1000 :expires-in 0
                               :encoding :hex)))
    ;; The boundary is strict: now == timestamp + age remains valid.
    (true (csrf-verify embedded :encoding :hex :now-ms 1100 :max-age 0))
    (false (csrf-verify embedded :encoding :hex :now-ms 1101 :max-age 0))
    (true (csrf-verify caller :encoding :hex :now-ms 1050 :max-age 50))
    (false (csrf-verify caller :encoding :hex :now-ms 1051 :max-age 50))
    ;; Zero disables only its own check.
    (true (csrf-verify caller :encoding :hex
                      :now-ms #xffffffffffffffff :max-age 0))
    ;; Future authenticated timestamps are valid.
    (true (csrf-verify embedded :encoding :hex :now-ms 999 :max-age 1))))

(define-test security/csrf-u64-overflow
  (let* ((max #xffffffffffffffff)
         (near-max (- max 5))
         (embedded-overflow
           (csrf-generate :timestamp-ms near-max :expires-in 6 :encoding :hex))
         (embedded-exact
           (csrf-generate :timestamp-ms near-max :expires-in 5 :encoding :hex))
         (caller-overflow
           (csrf-generate :timestamp-ms near-max :expires-in 0 :encoding :hex))
         (full-domain
           (csrf-generate :timestamp-ms max :expires-in 0 :encoding :hex)))
    (false (csrf-verify embedded-overflow :encoding :hex :now-ms 0 :max-age 0))
    (true (csrf-verify embedded-exact :encoding :hex :now-ms max :max-age 0))
    (false (csrf-verify caller-overflow :encoding :hex :now-ms 0 :max-age 6))
    (true (csrf-verify caller-overflow :encoding :hex :now-ms max :max-age 5))
    (true (csrf-verify full-domain :encoding :hex :now-ms max :max-age 0))))

(define-test security/csrf-strict-hex-decoding
  (let ((token (csrf-generate :encoding :hex)))
    (true (csrf-verify (string-upcase token) :encoding :hex))
    (true (csrf-verify (concatenate 'string token (csrf-null-string))
                       :encoding :hex))
    (false (csrf-verify (concatenate 'string token (csrf-null-string 2))
                        :encoding :hex))
    (false (csrf-verify (csrf-replace-character token 10 #\g) :encoding :hex))
    (false (csrf-verify (csrf-insert token 10 " ") :encoding :hex))
    (false (csrf-verify (concatenate 'string token "0") :encoding :hex))
    (false (csrf-verify (make-string 194 :initial-element #\0) :encoding :hex))))

(define-test security/csrf-permissive-bounded-base64
  (let* ((base64 (csrf-generate :encoding :base64))
         (url (csrf-generate :encoding :base64url))
         (mixed (substitute #\_ #\/ (substitute #\- #\+ base64)))
         (junked (csrf-insert base64 12 "=!~"))
         (endpoint-whitespace
           (concatenate 'string
                        (coerce (mapcar #'code-char '(13 10 9 32 11)) 'string)
                        base64
                        (coerce (mapcar #'code-char '(11 32 9 10 13)) 'string))))
    ;; Both public base64 names intentionally use the same permissive decoder.
    (true (csrf-verify base64 :encoding :base64url))
    (true (csrf-verify url :encoding :base64))
    (true (csrf-verify mixed :encoding :base64url))
    (true (csrf-verify junked :encoding :base64))
    (true (csrf-verify endpoint-whitespace :encoding :base64))
    (true (csrf-verify (concatenate 'string base64 (csrf-null-string))
                       :encoding :base64))
    ;; One raw terminal NUL is stripped; a preceding NUL is then ordinary ASCII
    ;; junk and is ignored by the permissive scan.
    (true (csrf-verify (concatenate 'string base64 (csrf-null-string 2))
                       :encoding :base64))
    (false (csrf-verify (csrf-insert base64 5 (string (code-char 128)))
                        :encoding :base64))
    ;; Raw cap is applied before endpoint trimming.
    (false (csrf-verify
            (concatenate 'string base64
                         (make-string (- 257 (length base64))
                                      :initial-element #\Space))
            :encoding :base64))
    ;; The normalized cap counts ignored junk as input work.
    (false (csrf-verify
            (concatenate 'string base64
                         (make-string (- 129 (length base64))
                                      :initial-element #\!))
            :encoding :base64))))

(define-test security/csrf-malformed-base64-shapes
  (let ((token (csrf-generate :encoding :base64url)))
    (false (csrf-verify "" :encoding :base64url))
    (false (csrf-verify "A" :encoding :base64url))
    (false (csrf-verify (subseq token 0 (1- (length token)))
                        :encoding :base64url))
    (false (csrf-verify (concatenate 'string token "A")
                        :encoding :base64url))
    (false (csrf-verify (make-string 128 :initial-element #\A)
                        :encoding :base64url))))

(define-test security/csrf-seeded-malformed-rejection
  (let ((accepted 0))
    (dotimes (index 128)
      (let* ((length (mod (+ (* index 37) 11) 129))
             (candidate (csrf-fuzz-string (+ #x35c5 index) length)))
        (when (csrf-verify candidate :encoding :base64url)
          (incf accepted))))
    (is = 0 accepted)))

(define-test security/csrf-core-input-bounds
  (let ((nonce (csrf-nonce))
        (secret (csrf-secret)))
    (fail (clun.csrf:core-generate
           (csrf-octets 0) :timestamp-ms 0 :expires-in 0 :nonce nonce)
          error)
    (fail (clun.csrf:core-generate
           (csrf-octets 1048577) :timestamp-ms 0 :expires-in 0 :nonce nonce)
          error)
    (fail (clun.csrf:core-generate
           secret :session-id (csrf-octets 1048577)
           :timestamp-ms 0 :expires-in 0 :nonce nonce)
          error)
    (fail (clun.csrf:core-generate
           secret :timestamp-ms -1 :expires-in 0 :nonce nonce)
          type-error)
    (fail (clun.csrf:core-generate
           secret :timestamp-ms (1+ #xffffffffffffffff)
           :expires-in 0 :nonce nonce)
          type-error)
    (fail (clun.csrf:core-generate
           secret :timestamp-ms 0 :expires-in 0 :nonce (csrf-octets 15))
          error)
    (fail (clun.csrf:core-verify
           +csrf-stable-sha256-hex+ secret :encoding :hex
           :algorithm :sha256 :max-age -1 :now-ms 0)
          type-error)))
