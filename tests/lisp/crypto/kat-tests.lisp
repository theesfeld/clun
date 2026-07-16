;;;; kat-tests.lisp — Phase 19 crypto known-answer tests (KATs).
;;;;
;;;; These suites assert the vendored ironclad's primitives against PUBLISHED
;;;; RFC/FIPS test vectors. Every EXPECTED value below is taken verbatim from the
;;;; relevant spec (cited per test), NOT from ironclad's own output — so a broken
;;;; ironclad (wrong algorithm, endianness, padding, ...) is caught, not masked.
;;;;
;;;; ironclad API surface exercised:
;;;;   digests   : ironclad:digest-sequence
;;;;   HMAC      : ironclad:make-mac / update-mac / produce-mac (:hmac)
;;;;   HKDF      : ironclad:make-kdf / derive-key (:hmac-kdf, RFC 5869) +
;;;;               crypto::hkdf-extract for the intermediate PRK
;;;;   AES-GCM   : ironclad:make-authenticated-encryption-mode (:gcm) /
;;;;               encrypt-message / decrypt-message / produce-tag
;;;;   ChaCha20  : ironclad:make-cipher (:chacha, :mode :stream) / encrypt
;;;;   Poly1305  : ironclad:make-mac (:poly1305) / update-mac / produce-mac
;;;;   X25519    : ironclad:make-private-key / make-public-key /
;;;;               curve25519-key-y / diffie-hellman (:curve25519)
;;;;   hex<->    : ironclad:hex-string-to-byte-array / byte-array-to-hex-string /
;;;;               ascii-string-to-byte-array

;; Standalone package (not clun-test): the crypto KATs run in their OWN image via
;; scripts/run-crypto-kats.lisp / `make test-crypto`, kept separate from the core
;; parachute suites so loading ironclad (+ its /dev/urandom fd, threads) does not add
;; fd pressure to the socket suites' shared reactor image.
(defpackage :clun.crypto-test
  (:use :cl :parachute))
(in-package :clun.crypto-test)

;;; ---------------------------------------------------------------------------
;;; small hex/bytes helpers (thin wrappers over ironclad's, for brevity)
;;; ---------------------------------------------------------------------------

(defun kat-hex->bytes (hex)
  "HEX string -> (simple-array (unsigned-byte 8))."
  (ironclad:hex-string-to-byte-array hex))

(defun kat-bytes->hex (bytes)
  "byte vector -> lowercase hex string."
  (ironclad:byte-array-to-hex-string bytes))

(defun kat-ascii (string)
  "ASCII STRING -> byte vector."
  (ironclad:ascii-string-to-byte-array string))

(defun kat-empty ()
  (make-array 0 :element-type '(unsigned-byte 8)))

(defun kat-zeros (n)
  (make-array n :element-type '(unsigned-byte 8) :initial-element 0))

(defun kat-concat (&rest arrays)
  (apply #'concatenate '(vector (unsigned-byte 8)) arrays))

(defun kat-le64 (n)
  "N -> 8-byte little-endian byte vector (used by the RFC 8439 Poly1305 input)."
  (let ((a (make-array 8 :element-type '(unsigned-byte 8))))
    (dotimes (i 8 a)
      (setf (aref a i) (ldb (byte 8 (* i 8)) n)))))

;;; ---------------------------------------------------------------------------
;;; 1. SHA-256 / SHA-512 / SHA-512/256 — FIPS 180-4 (NIST example digests)
;;; ---------------------------------------------------------------------------

(define-test crypto/sha2-fips180-4
  ;; FIPS 180-4 / NIST published example digests.
  ;; SHA-256("abc") — FIPS 180-4 Appendix (and the NIST byte-oriented examples).
  (is string= "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
      (kat-bytes->hex (ironclad:digest-sequence :sha256 (kat-ascii "abc"))))
  ;; SHA-256("") — the canonical empty-string digest.
  (is string= "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      (kat-bytes->hex (ironclad:digest-sequence :sha256 (kat-empty))))
  ;; SHA-512("abc") — FIPS 180-4 Appendix.
  (is string= (concatenate 'string
                           "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea2"
                           "0a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd"
                           "454d4423643ce80e2a9ac94fa54ca49f")
      (kat-bytes->hex (ironclad:digest-sequence :sha512 (kat-ascii "abc"))))
  ;; SHA-512("") — the canonical empty-string digest.
  (is string= (concatenate 'string
                           "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc"
                           "83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f"
                           "63b931bd47417a81a538327af927da3e")
      (kat-bytes->hex (ironclad:digest-sequence :sha512 (kat-empty)))))

(define-test crypto/sha512-256-fips180-4
  (true (ironclad:digest-supported-p :sha512/256))
  (true (member :sha512/256 (ironclad:list-all-digests)))
  (is eq :external
      (nth-value 1 (find-symbol "SHA512/256" (find-package :ironclad))))
  ;; NIST CAVP byte-oriented vectors: empty input and the one-byte message FA.
  (is string= "c672b8d1ef56ed28ab87c3622c5114069bdd3ad7b8f9737498d0c01ecef0967a"
      (kat-bytes->hex (ironclad:digest-sequence :sha512/256 (kat-empty))))
  (is string= "c4ef36923c64e51e875720e550298a5ab8a3f2f875b1e1a4c9b95babf7344fef"
      (kat-bytes->hex (ironclad:digest-sequence :sha512/256
                                                (kat-hex->bytes "fa"))))
  (let ((digest (ironclad:make-digest :sha512/256)))
    (is = 32 (ironclad:digest-length digest))
    (is = 128 (ironclad:block-length digest)))
  ;; A copied partial state must evolve independently from the original.
  (let* ((prefix (kat-ascii "prefix:"))
         (left (kat-ascii "left"))
         (right (kat-ascii "right"))
         (original (ironclad:make-digest :sha512/256)))
    (ironclad:update-digest original prefix)
    (let ((copy (ironclad:copy-digest original)))
      (ironclad:update-digest original left)
      (ironclad:update-digest copy right)
      (is equalp
          (ironclad:digest-sequence :sha512/256 (kat-concat prefix left))
          (ironclad:produce-digest original))
      (is equalp
          (ironclad:digest-sequence :sha512/256 (kat-concat prefix right))
          (ironclad:produce-digest copy))))
  ;; Reinitialization restores the FIPS IV after a populated partial state.
  (let ((digest (ironclad:make-digest :sha512/256)))
    (ironclad:update-digest digest (kat-ascii "discarded state"))
    (reinitialize-instance digest)
    (ironclad:update-digest digest (kat-hex->bytes "fa"))
    (is string= "c4ef36923c64e51e875720e550298a5ab8a3f2f875b1e1a4c9b95babf7344fef"
        (kat-bytes->hex (ironclad:produce-digest digest)))))

;;; ---------------------------------------------------------------------------
;;; 2. HMAC-SHA256 — RFC 4231 test cases 1 & 2
;;; ---------------------------------------------------------------------------

(defun kat-hmac-sha256 (key-bytes msg-bytes)
  (let ((mac (ironclad:make-mac :hmac key-bytes :sha256)))
    (ironclad:update-mac mac msg-bytes)
    (kat-bytes->hex (ironclad:produce-mac mac))))

(define-test crypto/hmac-sha256-rfc4231
  ;; RFC 4231 §4.2 Test Case 1: key = 20 x 0x0b, data = "Hi There".
  (is string= "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
      (kat-hmac-sha256 (make-array 20 :element-type '(unsigned-byte 8)
                                      :initial-element #x0b)
                       (kat-ascii "Hi There")))
  ;; RFC 4231 §4.3 Test Case 2: key = "Jefe", data = "what do ya want for nothing?".
  (is string= "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
      (kat-hmac-sha256 (kat-ascii "Jefe")
                       (kat-ascii "what do ya want for nothing?"))))

(defparameter +wycheproof-sha512/256-key+
  (concatenate 'string
               "8a0c46eb8a2959e39865330079763341e7439dab149694ee57e0d61ec73d947e"
               "1d5301cd974e18a5e0d1cf0d2c37e8aadd9fd589d57ef32e47024a99bc3f70c077"))

(defparameter +wycheproof-sha512/256-tag+
  "05a64be452f9c6e190113eea89bd4ca6ecd14e8fe924a3adf41a53a381615f34")

(defun kat-hmac (digest key-bytes msg-bytes)
  (let ((mac (ironclad:make-mac :hmac key-bytes digest)))
    (ironclad:update-mac mac msg-bytes)
    (ironclad:produce-mac mac)))

(define-test crypto/hmac-sha512-256-wycheproof
  ;; C2SP Wycheproof hmac_sha512_256_test.json tcId 170. The 65-byte key is
  ;; deliberately longer than a SHA-256 block and shorter than SHA-512's
  ;; 128-byte block, so this catches an incorrect 64-byte HMAC block size.
  (let* ((key (kat-hex->bytes +wycheproof-sha512/256-key+))
         (message (kat-empty))
         (expected (kat-hex->bytes +wycheproof-sha512/256-tag+))
         (actual (kat-hmac :sha512/256 key message))
         (ordinary (kat-hmac :sha512 key message))
         (ordinary-first-32 (subseq ordinary 0 32)))
    (is = 65 (length key))
    (is = 32 (length actual))
    (is equalp expected actual)
    ;; Exact negative control: ordinary HMAC-SHA-512 truncated to 32 bytes.
    (is string= "e1657f44bf84895e6db0810a2cca61a6e105e12ec006f0b5961020301b57744e"
        (kat-bytes->hex ordinary-first-32))
    (isnt equalp expected ordinary-first-32)
    ;; PRODUCE-MAC is non-destructive, and reinitialization with the same key
    ;; must reproduce the published tag.
    (let ((mac (ironclad:make-mac :hmac key :sha512/256)))
      (ironclad:update-mac mac message)
      (is equalp expected (ironclad:produce-mac mac))
      (is equalp expected (ironclad:produce-mac mac))
      (reinitialize-instance mac :key key)
      (ironclad:update-mac mac message)
      (is equalp expected (ironclad:produce-mac mac)))))

;;; ---------------------------------------------------------------------------
;;; 3. HKDF-SHA256 — RFC 5869 test cases 1 & 3
;;; ---------------------------------------------------------------------------
;;;
;;; ironclad's :hmac-kdf implements HKDF (RFC 5869); DERIVE-KEY runs
;;; extract-then-expand and returns the OKM. The intermediate PRK is asserted
;;; separately via crypto::hkdf-extract (the internal extract step).

(defun kat-hkdf-sha256-prk (salt-bytes ikm-bytes)
  (kat-bytes->hex (crypto::hkdf-extract :sha256 salt-bytes ikm-bytes)))

(defun kat-hkdf-sha256-okm (ikm-bytes salt-bytes info-bytes out-len)
  (let ((kdf (ironclad:make-kdf :hmac-kdf :digest :sha256
                                :additional-data info-bytes)))
    ;; DERIVE-KEY (kdf passphrase salt iteration-count key-length); HKDF ignores
    ;; iteration-count. The IKM is the "passphrase", the salt is the salt.
    (kat-bytes->hex (ironclad:derive-key kdf ikm-bytes salt-bytes 0 out-len))))

(define-test crypto/hkdf-sha256-rfc5869
  ;; RFC 5869 Appendix A.1, Test Case 1 (basic, with salt & info; L = 42).
  (let ((ikm  (kat-hex->bytes "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"))
        (salt (kat-hex->bytes "000102030405060708090a0b0c"))
        (info (kat-hex->bytes "f0f1f2f3f4f5f6f7f8f9")))
    (is string= "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"
        (kat-hkdf-sha256-prk salt ikm))
    (is string= (concatenate 'string
                            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c"
                            "5db02d56ecc4c5bf34007208d5b887185865")
        (kat-hkdf-sha256-okm ikm salt info 42)))
  ;; RFC 5869 Appendix A.3, Test Case 3 (zero-length salt AND info; L = 42).
  (let ((ikm  (kat-hex->bytes "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"))
        (salt (kat-empty))
        (info (kat-empty)))
    (is string= "19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04"
        (kat-hkdf-sha256-prk salt ikm))
    (is string= (concatenate 'string
                            "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879e"
                            "c3454e5f3c738d2d9d201395faa4b61a96c8")
        (kat-hkdf-sha256-okm ikm salt info 42))))

;;; ---------------------------------------------------------------------------
;;; 4. AES-256-GCM — NIST / McGrew-Viega Test Case 16
;;; ---------------------------------------------------------------------------
;;;
;;; Vector from "The Galois/Counter Mode of Operation (GCM)" (McGrew & Viega),
;;; the reference AES-GCM test-vector set NIST used; Test Case 16 (AES-256):
;;;   K   = feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308
;;;   IV  = cafebabefacedbaddecaf888   (96-bit)
;;;   AAD = feedfacedeadbeeffeedfacedeadbeefabaddad2
;;;   P   = d9313225...ba637b39
;;;   C   = 522dc1f0...c9f662
;;;   T   = 76fc6ece0f4e1768cddf8853bb2d551b

(defparameter +kat-gcm-key+
  "feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308")
(defparameter +kat-gcm-iv+  "cafebabefacedbaddecaf888")
(defparameter +kat-gcm-aad+ "feedfacedeadbeeffeedfacedeadbeefabaddad2")
(defparameter +kat-gcm-pt+
  (concatenate 'string
               "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72"
               "1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39"))
(defparameter +kat-gcm-ct+
  (concatenate 'string
               "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa"
               "8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662"))
(defparameter +kat-gcm-tag+ "76fc6ece0f4e1768cddf8853bb2d551b")

(defun kat-gcm-mode (&optional expected-tag)
  "A fresh GCM mode over the NIST vector's key/IV. When EXPECTED-TAG (a byte
   vector) is supplied, DECRYPT-MESSAGE will verify against it on the final block
   and signal ironclad:bad-authentication-tag on mismatch (NIST SP 800-38D)."
  (apply #'ironclad:make-authenticated-encryption-mode
         :gcm :cipher-name :aes
         :key (kat-hex->bytes +kat-gcm-key+)
         :initialization-vector (kat-hex->bytes +kat-gcm-iv+)
         (when expected-tag (list :tag expected-tag))))

(define-test crypto/aes-256-gcm-nist
  ;; Encrypt: ciphertext + 16-byte tag must match the published vector.
  (let* ((mode (kat-gcm-mode))
         (ct (ironclad:encrypt-message mode (kat-hex->bytes +kat-gcm-pt+)
                                       :associated-data (kat-hex->bytes +kat-gcm-aad+)))
         (tag (ironclad:produce-tag mode)))
    (is string= +kat-gcm-ct+ (kat-bytes->hex ct))
    (is string= +kat-gcm-tag+ (kat-bytes->hex tag)))
  ;; Decrypt (untampered): the recomputed tag matches the expected tag, so the
  ;; plaintext is recovered without a bad-authentication-tag error.
  (let* ((mode (kat-gcm-mode (kat-hex->bytes +kat-gcm-tag+)))
         (pt (ironclad:decrypt-message mode (kat-hex->bytes +kat-gcm-ct+)
                                       :associated-data (kat-hex->bytes +kat-gcm-aad+))))
    (is string= +kat-gcm-pt+ (kat-bytes->hex pt)))
  ;; Decrypt (tampered ciphertext, correct expected tag): the recomputed tag no
  ;; longer matches the expected tag -> ironclad:bad-authentication-tag. Verifying
  ;; against the *correct* expected tag is what makes GCM check integrity.
  (let ((mode (kat-gcm-mode (kat-hex->bytes +kat-gcm-tag+)))
        (bad-ct (kat-hex->bytes +kat-gcm-ct+)))
    (setf (aref bad-ct 0) (logxor (aref bad-ct 0) #xff))   ; corrupt ciphertext
    (is eq :rejected
        (handler-case
            (progn (ironclad:decrypt-message mode bad-ct
                                             :associated-data (kat-hex->bytes +kat-gcm-aad+))
                   :accepted)
          (ironclad:bad-authentication-tag () :rejected)))))

;;; ---------------------------------------------------------------------------
;;; 5. X25519 — RFC 7748 §6.1
;;; ---------------------------------------------------------------------------
;;;
;;; RFC 7748 §6.1 gives Alice's & Bob's private scalars, their derived public
;;; keys, and the shared secret K. ironclad's MAKE-PRIVATE-KEY derives the public
;;; key from the scalar (CURVE25519-KEY-Y); DIFFIE-HELLMAN(priv, pub) computes K.

(defparameter +x25519-alice-sk+
  "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
(defparameter +x25519-bob-sk+
  "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
(defparameter +x25519-alice-pk+
  "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
(defparameter +x25519-bob-pk+
  "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
(defparameter +x25519-shared+
  "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")

(define-test crypto/x25519-rfc7748
  (let* ((alice-priv (ironclad:make-private-key
                      :curve25519 :x (kat-hex->bytes +x25519-alice-sk+)))
         (bob-priv (ironclad:make-private-key
                    :curve25519 :x (kat-hex->bytes +x25519-bob-sk+)))
         ;; Public keys: RFC 7748 derives these from the scalars.
         (alice-pub (ironclad:make-public-key
                     :curve25519 :y (ironclad:curve25519-key-y alice-priv)))
         (bob-pub (ironclad:make-public-key
                   :curve25519 :y (ironclad:curve25519-key-y bob-priv))))
    (is string= +x25519-alice-pk+
        (kat-bytes->hex (ironclad:curve25519-key-y alice-priv)))
    (is string= +x25519-bob-pk+
        (kat-bytes->hex (ironclad:curve25519-key-y bob-priv)))
    ;; Shared secret must match, computed both directions (DH symmetry).
    (is string= +x25519-shared+
        (kat-bytes->hex (ironclad:diffie-hellman alice-priv bob-pub)))
    (is string= +x25519-shared+
        (kat-bytes->hex (ironclad:diffie-hellman bob-priv alice-pub)))))

;;; ---------------------------------------------------------------------------
;;; 6. ChaCha20-Poly1305 AEAD — RFC 8439 §2.8.2
;;; ---------------------------------------------------------------------------
;;;
;;; This ironclad has no first-class ChaCha20-Poly1305 AEAD mode (its AEAD modes
;;; are EAX/ETM/GCM), so we build the RFC 8439 construction from the ChaCha20
;;; stream cipher + Poly1305 MAC primitives ironclad *does* provide — which is
;;; exactly what a ChaCha20-Poly1305 AEAD must be, and exercises both primitives:
;;;   1. Poly1305 one-time key = ChaCha20 keystream block, counter 0 (first 32 B).
;;;   2. Ciphertext = ChaCha20 encrypt of plaintext starting at counter 1
;;;      (ironclad's chacha auto-increments the counter, so continuing the same
;;;       cipher instance after consuming block 0 encrypts from counter 1).
;;;   3. tag = Poly1305(key, AAD || pad16 || CT || pad16 || le64(|AAD|) || le64(|CT|)).
;;;
;;; Vector: RFC 8439 §2.8.2.

(defparameter +cha-key+
  "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
(defparameter +cha-nonce+ "070000004041424344454647")
(defparameter +cha-aad+   "50515253c0c1c2c3c4c5c6c7")
(defparameter +cha-plaintext+
  "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.")
(defparameter +cha-ct+
  (concatenate 'string
               "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6"
               "3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b36"
               "92ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc"
               "3ff4def08e4b7a9de576d26586cec64b6116"))
(defparameter +cha-tag+ "1ae10b594f09e26a7e902ecbd0600691")
(defparameter +cha-poly-key+
  "7bac2b252db447af09b67a55a4e955840ae1d6731075d9eb2a9375783ed553ff")

(defun kat-chacha20-poly1305-seal (key nonce aad plaintext)
  "RFC 8439 ChaCha20-Poly1305 AEAD seal. Returns (values ciphertext tag poly-key)
   as byte vectors."
  (let* ((cipher (ironclad:make-cipher :chacha :key key
                                       :initialization-vector nonce :mode :stream))
         ;; Block 0 of the keystream -> the Poly1305 one-time key (first 32 bytes).
         (block0-out (kat-zeros 64)))
    (ironclad:encrypt cipher (kat-zeros 64) block0-out)
    (let* ((poly-key (subseq block0-out 0 32))
           ;; The cipher's counter is now 1: encrypt the plaintext.
           (ct (make-array (length plaintext) :element-type '(unsigned-byte 8))))
      (ironclad:encrypt cipher plaintext ct)
      (let* ((mac (ironclad:make-mac :poly1305 poly-key))
             (pad-aad (mod (- 16 (mod (length aad) 16)) 16))
             (pad-ct  (mod (- 16 (mod (length ct) 16)) 16)))
        (ironclad:update-mac mac aad)
        (ironclad:update-mac mac (kat-zeros pad-aad))
        (ironclad:update-mac mac ct)
        (ironclad:update-mac mac (kat-zeros pad-ct))
        (ironclad:update-mac mac (kat-le64 (length aad)))
        (ironclad:update-mac mac (kat-le64 (length ct)))
        (values ct (ironclad:produce-mac mac) poly-key)))))

(defun kat-chacha20-poly1305-open (key nonce aad ciphertext tag)
  "RFC 8439 ChaCha20-Poly1305 AEAD open. Recomputes the tag over the ciphertext;
   returns the plaintext bytes if it matches TAG, else NIL (authentication fail)."
  (let* ((cipher (ironclad:make-cipher :chacha :key key
                                       :initialization-vector nonce :mode :stream))
         (block0-out (kat-zeros 64)))
    (ironclad:encrypt cipher (kat-zeros 64) block0-out)
    (let* ((poly-key (subseq block0-out 0 32))
           (mac (ironclad:make-mac :poly1305 poly-key))
           (pad-aad (mod (- 16 (mod (length aad) 16)) 16))
           (pad-ct  (mod (- 16 (mod (length ciphertext) 16)) 16)))
      (ironclad:update-mac mac aad)
      (ironclad:update-mac mac (kat-zeros pad-aad))
      (ironclad:update-mac mac ciphertext)
      (ironclad:update-mac mac (kat-zeros pad-ct))
      (ironclad:update-mac mac (kat-le64 (length aad)))
      (ironclad:update-mac mac (kat-le64 (length ciphertext)))
      (when (ironclad:constant-time-equal (ironclad:produce-mac mac) tag)
        (let ((pt (make-array (length ciphertext) :element-type '(unsigned-byte 8))))
          (ironclad:decrypt cipher ciphertext pt)
          pt)))))

(define-test crypto/chacha20-poly1305-rfc8439
  (let ((key   (kat-hex->bytes +cha-key+))
        (nonce (kat-hex->bytes +cha-nonce+))
        (aad   (kat-hex->bytes +cha-aad+))
        (pt    (kat-ascii +cha-plaintext+)))
    ;; Seal: ciphertext, tag, and the derived Poly1305 one-time key all match §2.8.2.
    (multiple-value-bind (ct tag poly-key)
        (kat-chacha20-poly1305-seal key nonce aad pt)
      (is string= +cha-ct+ (kat-bytes->hex ct))
      (is string= +cha-tag+ (kat-bytes->hex tag))
      (is string= +cha-poly-key+ (kat-bytes->hex poly-key)))
    ;; Open (untampered): recovers the exact plaintext.
    (let ((recovered (kat-chacha20-poly1305-open key nonce aad
                                                 (kat-hex->bytes +cha-ct+)
                                                 (kat-hex->bytes +cha-tag+))))
      (true recovered)
      (is string= (kat-bytes->hex pt) (kat-bytes->hex recovered)))
    ;; Open (tampered tag): authentication fails -> NIL (no plaintext leaked).
    (let ((bad-tag (kat-hex->bytes +cha-tag+)))
      (setf (aref bad-tag 0) (logxor (aref bad-tag 0) #xff))
      (false (kat-chacha20-poly1305-open key nonce aad
                                         (kat-hex->bytes +cha-ct+) bad-tag)))))
