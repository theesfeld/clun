;;;; password-hash-tests.lisp -- Phase 36 KAT, differential, and bounds gates.

(in-package :clun-test)

(defun ph-ascii (string)
  (let ((octets (make-array (length string) :element-type '(unsigned-byte 8))))
    (dotimes (index (length string) octets)
      (setf (aref octets index) (char-code (char string index))))))

(defun ph-bytes (length)
  (let ((bytes (make-array length :element-type '(unsigned-byte 8))))
    (dotimes (index length bytes)
      (setf (aref bytes index) (logand (+ (* index 191) 17) #xff)))))

(defun ph-replace-last (string)
  (let* ((copy (copy-seq string))
         ;; Stay away from base64 tail padding bits so this remains a canonical
         ;; encoding of a different digest rather than malformed input.
         (index (- (length copy) 10)))
    (setf (char copy index)
          (if (char= (char copy index) #\A) #\B #\A))
    copy))

(defun ph-error-kind (thunk)
  (handler-case (progn (funcall thunk) nil)
    (clun.password:password-error (condition)
      (clun.password:password-error-kind condition))))

(defun ph-store-le (value bytes width offset)
  (dotimes (index width)
    (setf (aref bytes (+ offset index))
          (ldb (byte 8 (* index 8)) value))))

(defun ph-smhasher32 (function)
  (let ((prefix (make-array 256 :element-type '(unsigned-byte 8)))
        (hashes (make-array (* 256 4) :element-type '(unsigned-byte 8))))
    (dotimes (length 256)
      (setf (aref prefix length) length)
      (ph-store-le (funcall function (subseq prefix 0 length) (- 256 length))
                   hashes 4 (* length 4)))
    (funcall function hashes 0)))

(defun ph-smhasher64 (function)
  (let ((prefix (make-array 256 :element-type '(unsigned-byte 8)))
        (hashes (make-array (* 256 8) :element-type '(unsigned-byte 8))))
    (dotimes (length 256)
      (setf (aref prefix length) length)
      (ph-store-le (funcall function (subseq prefix 0 length) (- 256 length))
                   hashes 8 (* length 8)))
    (logand (funcall function hashes 0) #xffffffff)))

(define-test security/hash-bun-public-vectors
  (let ((input (ph-ascii "hello world")))
    (is = #x668d5e431c3b2573 (clun.hash:wyhash input))
    (is = #x1a0b045d (clun.hash:adler32 input))
    (is = #x0d4a1185 (clun.hash:crc32 input))
    (is = #x19a7581a (clun.hash:city-hash32 input))
    (is = #xc7920bbdbecee42f (clun.hash:city-hash64 input))
    (is = #xcebb6622 (clun.hash:xxhash32 input))
    (is = #x45ab6734b21e6968 (clun.hash:xxhash64 input))
    (is = #xd447b1ea40e6988b (clun.hash:xxhash3 input))
    (is = #x44a81419 (clun.hash:murmur32v2 input))
    (is = #x5e928f0f (clun.hash:murmur32v3 input))
    (is = #xd3ba2368a832afce (clun.hash:murmur64v2 input))
    (is = #x58a89bdcee89c08c (clun.hash:rapidhash input))))

(define-test security/hash-frozen-reference-vectors
  (dolist (vector
           '((0 "" #x0409638ee2bde459)
             (1 "a" #xa8412d091b5fe0a9)
             (2 "abc" #x32dd92e4b2915153)
             (3 "message digest" #x8619124089a3a16b)
             (4 "abcdefghijklmnopqrstuvwxyz" #x7a43afb61d7f5f40)
             (5 "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
                #xff42329b90e50d58)
             (6 "12345678901234567890123456789012345678901234567890123456789012345678901234567890"
                #xc39cab13b115aad3)))
    (destructuring-bind (seed input expected) vector
      (is = expected (clun.hash:wyhash (ph-ascii input) seed))))
  (let ((input (ph-ascii
                (format nil "~{~A~}" (make-list 128 :initial-element "abcdefgh")))))
    (dolist (vector
             '((0 #x5a6ef77074ebc84b) (1 #xc11328477bc0f5d1)
               (2 #x5644ac035e40d569) (3 #x0347080fbf5fcd81)
               (4 #x056b66b8dc802bcc) (8 #xb6bf9055973aac7c)
               (16 #xed56d62eead1e402) (32 #xc19072d767da8ffb)
               (64 #x89bb40a9928a4f0d) (128 #xe0af7c5e7b6e29fd)
               (256 #x9a3ed35fbedfa11a) (512 #x4c684b2119ca19fb)
               (1024 #x4b575f5bf25600d6)))
      (destructuring-bind (length expected) vector
        (is = expected
            (clun.hash:rapidhash
             (subseq input 0 length) #xbdd89aa982704029)))))
  ;; Frozen Bun's hash implementations use these full-range SMHasher codes.
  (is = #xbd5e840c (ph-smhasher64 #'clun.hash:wyhash))
  (is = #x27864c1e (ph-smhasher32 #'clun.hash:murmur32v2))
  (is = #x1f0d3804 (ph-smhasher64 #'clun.hash:murmur64v2))
  (is = #xb0f57ee3 (ph-smhasher32 #'clun.hash:murmur32v3))
  (is = #x68254f81
      (ph-smhasher32 (lambda (bytes seed)
                       (declare (ignore seed))
                       (clun.hash:city-hash32 bytes))))
  (is = #x5fabc5c5 (ph-smhasher64 #'clun.hash:city-hash64)))

(defparameter +ph-xxh3-vectors+
  '((0 0 #x2d06800538d394c2)
    (0 42 #xb029411ff43d84d2)
    (0 #xabcdef01 #x823d212dbc05808a)
    (1 0 #xf319fe2bdfcdfebd)
    (3 42 #xca175fa91402884f)
    (4 0 #xaed869f675eac794)
    (8 #xabcdef01 #x8408fa079f431149)
    (9 0 #xe17aa5899a63caef)
    (16 0 #x858ddc7a8189c802)
    (16 #xabcdef01 #x7353d4b9da395f86)
    (17 0 #x80ec4e641b4cfc2b)
    (32 42 #xa91e40e07bc2b693)
    (64 0 #x9efbe7494c1483f9)
    (65 0 #x2fdde7eb844656c4)
    (96 #xabcdef01 #x4701ffae732a05dd)
    (128 0 #x506426d4fd0a2163)
    (129 0 #x0fe55d4c5d8d8f71)
    (160 42 #x0760cc17d49d97b9)
    (200 0 #x7af78b7865491461)
    (239 0 #x5e6dd82b298c64d5)
    (240 0 #x744366c87a6954e9)
    (240 #xabcdef01 #xdc5d0fd70f358c69)
    (241 0 #xdc3fc1135592d6e6)
    (256 0 #xd3a2265cf3c76bcc)
    (257 0 #xf11e5731791d1209)
    (257 #xabcdef01 #x9e93f1a43223b5d8)
    (512 0 #x8f3ce4e54002823b)
    (513 42 #xab3f1cf78b260c6f)
    (1024 0 #xa9e2eee0215aa4e9)
    (1025 #xabcdef01 #xc39418c639c2fab2)
    (4096 0 #xa8e6a7a23c5b3935)
    (65536 42 #x56bfc657f60303ca)
    (131072 0 #x6afc5e23ce3c83a5)
    (131072 #xabcdef01 #x28a47fbb68e0e9ab)))

(define-test security/hash-xxh3-frozen-boundaries
  (dolist (vector +ph-xxh3-vectors+)
    (destructuring-bind (length seed expected) vector
      (is = expected (clun.hash:xxhash3 (ph-bytes length) seed)))))

(defparameter +ph-xx32-vectors+
  '((0 0 #x02cc5d05) (0 #xabcdef01 #x994fa74b)
    (1 0 #xb804f774) (3 #xabcdef01 #x43722566)
    (4 0 #xf025fee3) (15 0 #x8c29721d)
    (16 0 #x9c01fb3f) (16 #xabcdef01 #x850a7a8c)
    (31 0 #x053d400f) (32 0 #xa756e696)
    (33 #xabcdef01 #x62f10491) (64 0 #x66b9c369)
    (240 0 #xf93f2096) (256 #xabcdef01 #xd19b892a)
    (1024 0 #xc6f48900) (65536 0 #x4eaba9f5)
    (131072 #xabcdef01 #x55124bc7)))

(defparameter +ph-xx64-vectors+
  '((0 0 #xef46db3751d8e999) (0 #xabcdef01 #x4ec16b94b18c49ef)
    (1 0 #xad10cd9780ac4ff7) (3 #xabcdef01 #xf63c72cac1f3f4c4)
    (4 0 #x7e8a72c9a223a1c0) (8 0 #xb6e941d7f6bbbb0c)
    (15 0 #x131410330f796b84) (16 0 #x82facd078c4684cc)
    (31 #xabcdef01 #xea551fb3e7ef7b93) (32 0 #xd27d959564fd4575)
    (33 0 #x2d5ce4a1d52b96de) (64 #xabcdef01 #x84ce6b0d00882c58)
    (240 0 #xb1d89115ab8aa560) (256 0 #x5ace78799b251d86)
    (1024 #xabcdef01 #x52a820eb6c45f54e)
    (65536 0 #x86ec0151ae772f43) (131072 0 #x6d834d77afc89932)))

(define-test security/hash-xx-frozen-boundaries
  (dolist (vector +ph-xx32-vectors+)
    (destructuring-bind (length seed expected) vector
      (is = expected (clun.hash:xxhash32 (ph-bytes length) seed))))
  (dolist (vector +ph-xx64-vectors+)
    (destructuring-bind (length seed expected) vector
      (is = expected (clun.hash:xxhash64 (ph-bytes length) seed))))
  ;; This seed is specifically wider than u32 in Bun's frozen suite.
  (is = 3224619365169652240
      (clun.hash:xxhash64 (ph-ascii "") 16269921104521594740)))

(define-test security/password-bcrypt-mcf-and-long-password
  (let* ((password (ph-ascii "password"))
         (salt (make-array 16 :element-type '(unsigned-byte 8)
                              :initial-element 0))
         (hash (clun.password:hash-password
                password :algorithm :bcrypt :cost 4 :salt salt)))
    (is string=
        "$2b$04$......................LAtw7/ohmmBAhnXqmkuIz83Rl5Qdjhm"
        hash)
    (true (clun.password:verify-password password (ph-ascii hash)))
    (false (clun.password:verify-password (ph-ascii "wrong") (ph-ascii hash)))
    (false (clun.password:verify-password password
                                          (ph-ascii (ph-replace-last hash)))))
  (let ((long-password (ph-ascii
                        (format nil "~{~A~}"
                                (make-list 100 :initial-element "hello"))))
        (frozen (ph-ascii
                 "$2b$10$PsJ3/W82mzNJoP0rSblfvet2ab9jZg2aH7tIxr1B8uFLJwuWk/jTi")))
    (true (clun.password:verify-password long-password frozen))))

(define-test security/password-argon-kats-and-formats
  (dolist (algorithm '(:argon2d :argon2i :argon2id))
    (let* ((password (ph-ascii "password"))
           (salt (make-array 32 :element-type '(unsigned-byte 8)
                                :initial-element 1))
           (hash (clun.password:hash-password
                  password :algorithm algorithm :memory-cost 8 :time-cost 1
                  :salt salt)))
      (true (clun.password:verify-password password (ph-ascii hash)))
      (false (clun.password:verify-password (ph-ascii "wrong") (ph-ascii hash)))
      ;; Missing v= means v=19, matching the frozen Bun verifier.
      (true (clun.password:verify-password
             password (ph-ascii (concatenate 'string
                                             (subseq hash 0 (search "$v=19" hash))
                                             (subseq hash (+ (search "$v=19" hash) 5))))))))
  ;; Ironclad/public Argon2id KAT with an 8-byte salt proves cross-tool PHC input.
  (let* ((password (ph-ascii "somepassword"))
         (salt (ph-ascii "somesalt"))
         (tag (ironclad:hex-string-to-byte-array
               "e77e03eafc1b9e867a1e7f38832e7d9fb73b04ef403ec2267f8e14e873448f0b"))
         (phc (format nil "$argon2id$v=19$m=12,t=3,p=1$~A$~A"
                      (clun.password::%base64-encode
                       salt clun.password::+base64-alphabet+)
                      (clun.password::%base64-encode
                       tag clun.password::+base64-alphabet+))))
    (true (clun.password:verify-password password (ph-ascii phc)))))

(define-test security/password-argon-multilane-cross-tool
  ;; Independent Argon2 v=19 vectors: password="password", salt="somesalt",
  ;; m=64, t=2, p=2, 24-byte output. These exercise cross-lane indexing and
  ;; slice synchronization that the p=1 generation surface never reaches.
  (let ((password (ph-ascii "password"))
        (salt (ph-ascii "somesalt")))
    (dolist (vector '((:argon2i
                       "2089f3e78a799720f80af806553128f29b132cafe40d059f")
                      (:argon2d
                       "68e2462c98b8bc6bb60ec68db418ae2c9ed24fc6748a40e9")
                      (:argon2id
                       "350ac37222f436ccb5c0972f1ebd3bf6b958bf2071841362")))
      (destructuring-bind (algorithm expected-hex) vector
        (let ((derived (clun.password::%derive-argon
                        algorithm password salt 64 2 24 2)))
          (unwind-protect
               (is string= expected-hex
                   (ironclad:byte-array-to-hex-string derived))
            (fill derived 0)))))
    (let* ((tag (ironclad:hex-string-to-byte-array
                 "350ac37222f436ccb5c0972f1ebd3bf6b958bf2071841362"))
           (phc (format nil "$argon2id$v=19$m=64,t=2,p=2$~A$~A"
                        (clun.password::%base64-encode
                         salt clun.password::+base64-alphabet+)
                        (clun.password::%base64-encode
                         tag clun.password::+base64-alphabet+))))
      (true (clun.password:verify-password password (ph-ascii phc)))
      (false (clun.password:verify-password (ph-ascii "wrong")
                                            (ph-ascii phc))))))

(define-test security/password-bcrypt-phc
  (let* ((password (ph-ascii "password"))
         (salt (make-array 16 :element-type '(unsigned-byte 8)
                              :initial-element 7))
         (derived (clun.password::%derive-bcrypt password salt 4))
         (phc (format nil "$bcrypt$r=4$~A$~A"
                      (clun.password::%base64-encode
                       salt clun.password::+base64-alphabet+)
                      (clun.password::%base64-encode
                       (subseq derived 0 23)
                       clun.password::+base64-alphabet+))))
    (unwind-protect
         (progn
           (true (clun.password:verify-password password (ph-ascii phc)))
           (false (clun.password:verify-password (ph-ascii "wrong")
                                                 (ph-ascii phc))))
      (fill derived 0))))

(define-test security/password-malformed-and-resource-bounds
  (let ((password (ph-ascii "password")))
    (is eq :unsupported-algorithm
        (ph-error-kind (lambda ()
                         (clun.password:verify-password password
                                                        (ph-ascii "$nope$x")))))
    (is eq :invalid-encoding
        (ph-error-kind (lambda ()
                         (clun.password:verify-password
                          password
                          (ph-ascii "$argon2id$v=16$m=8,t=1,p=1$c29tZXNhbHQ$AAAAAA")))))
    (is eq :invalid-encoding
        (ph-error-kind (lambda ()
                         (clun.password:verify-password
                          password
                          (ph-ascii "$argon2id$v=19$m=8,m=9,t=1,p=1$c29tZXNhbHQ$AAAAAA")))))
    (is eq :weak-parameters
        (ph-error-kind (lambda ()
                         (clun.password:verify-password
                          password
                          (ph-ascii "$argon2id$v=19$m=4294967294,t=1,p=1$c29tZXNhbHQ$AAAAAA")))))
    (is eq :weak-parameters
        (ph-error-kind (lambda ()
                         (clun.password:verify-password
                          password
                          (ph-ascii "$2b$32$......................LAtw7/ohmmBAhnXqmkuIz83Rl5Qdjhm")))))
    (is eq :input-too-long
        (ph-error-kind (lambda ()
                         (clun.password:verify-password
                          password
                          (make-array 4097 :element-type '(unsigned-byte 8)
                                           :initial-element 65)))))))

(define-test security/password-core-input-bounds
  (fail (clun.password:hash-password (ph-ascii ""))
        clun.password:password-error)
  (false (clun.password:verify-password (ph-ascii "") (ph-ascii "$")))
  (false (clun.password:verify-password (ph-ascii "$" ) (ph-ascii "")))
  (fail (clun.password:hash-password
         (make-array 1048577 :element-type '(unsigned-byte 8)
                              :initial-element 0))
        clun.password:password-error))

(define-test runtime/clun-password-hash-surface
  (let ((realm (eng:make-realm)))
    (unwind-protect
         (progn
           (rt:install-runtime realm :argv '(:script "[password-test]" :rest nil)
                                       :cwd "/tmp" :colors nil)
           (eng:run-source
            "globalThis.hashVector = Clun.hash.xxHash3('hello world');
             globalThis.syncHash = Clun.password.hashSync('password', {algorithm:'bcrypt',cost:4});
             globalThis.syncOK = Clun.password.verifySync('password', syncHash);
             globalThis.tick = 0;
             setTimeout(()=>tick++,0);
             Clun.password.hash('password',{algorithm:'argon2id',memoryCost:8,timeCost:1})
               .then(h=>{globalThis.asyncOK=Clun.password.verifySync('password',h)});"
            :realm realm)
           (let ((eng::*realm* realm)
                 (global (eng:realm-global realm)))
             (is = #xd447b1ea40e6988b (eng:js-get global "hashVector"))
             (is eq eng:+true+ (eng:js-get global "syncOK"))
             (is eq eng:+true+ (eng:js-get global "asyncOK"))
             ;; Timer progress while the password Promise is pending is the reactor canary.
             (is eql 1d0 (eng:js-get global "tick"))))
      (eng:teardown-realm realm))))
