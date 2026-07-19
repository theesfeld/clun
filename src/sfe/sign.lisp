;;;; sign.lisp — pure-CL SEA signing / verification (Issue #181).
;;;;
;;;; Exceeds Bun code signing surface:
;;;;   * Ed25519 and HMAC-SHA256 signatures over the SEA payload
;;;;   * Works for every target (Linux + macOS), not only Darwin codesign
;;;;   * Built-in verify without external `codesign`
;;;;   * Pure Ironclad only — no foreign interface, no host codesign(1)

(in-package :clun.sfe)

(defun %sha256 (octets)
  (crypto:digest-sequence :sha256 octets))

(defun %hex (octets)
  (crypto:byte-array-to-hex-string octets))

(defun generate-signing-key (&optional (algo :ed25519))
  "Return (values private-key-octets public-key-octets algo-code).
   ALGO is :ed25519 or :hmac-sha256."
  (ecase algo
    (:ed25519
     (multiple-value-bind (priv pub) (crypto:generate-key-pair :ed25519)
       (values (crypto:ed25519-key-x priv)
               (crypto:ed25519-key-y pub)
               +sig-algo-ed25519+)))
    (:hmac-sha256
     (let ((key (sys:os-random-bytes 32)))
       (values key (copy-seq key) +sig-algo-hmac-sha256+)))))

(defun %ed25519-private (priv-octets)
  (crypto:make-private-key :ed25519
                           :x priv-octets
                           :y (crypto:ed25519-public-key priv-octets)))

(defun %ed25519-public (pub-octets)
  (crypto:make-public-key :ed25519 :y pub-octets))

(defun sign-payload (payload private-key &key (algo :ed25519))
  "Sign PAYLOAD octets with PRIVATE-KEY octets. Returns (values signature algo-code)."
  (ecase algo
    (:ed25519
     (let* ((key (%ed25519-private private-key))
            (sig (crypto:sign-message key payload)))
       (values sig +sig-algo-ed25519+)))
    (:hmac-sha256
     (let* ((mac (crypto:make-hmac private-key :sha256)))
       (crypto:update-hmac mac payload)
       (values (crypto:hmac-digest mac) +sig-algo-hmac-sha256+)))))

(defun verify-payload (payload signature public-or-shared-key &key (algo :ed25519))
  "T if SIGNATURE is valid for PAYLOAD under KEY."
  (ecase algo
    (:ed25519
     (let ((key (%ed25519-public public-or-shared-key)))
       (and (ignore-errors (crypto:verify-signature key payload signature)) t)))
    (:hmac-sha256
     (let* ((mac (crypto:make-hmac public-or-shared-key :sha256)))
       (crypto:update-hmac mac payload)
       (equalp (crypto:hmac-digest mac) signature)))))

(defun algo-keyword (code)
  (cond ((= code +sig-algo-ed25519+) :ed25519)
        ((= code +sig-algo-hmac-sha256+) :hmac-sha256)
        ((= code +sig-algo-none+) :none)
        (t (%fail :unsupported-sig (format nil "sig algo ~A" code)))))

(defun verify-sea (path &key public-key)
  "Verify SEA at PATH. When signed, PUBLIC-KEY (octets) is required unless the
   manifest embeds publicKeyHex for Ed25519. Returns plist :ok :algo :digest."
  (let* ((sea (open-sea path))
         (footer (getf sea :footer))
         (payload (getf sea :payload))
         (sig (getf sea :signature))
         (algo-code (getf footer :sig-algo))
         (digest (%hex (%sha256 payload)))
         (manifest (getf sea :manifest))
         (pk public-key))
    (when (and (null pk) (plusp algo-code))
      (let ((hex (cdr (assoc "publicKeyHex" manifest :test #'string=))))
        (when (stringp hex)
          (setf pk (crypto:hex-string-to-byte-array hex)))))
    (cond
      ((zerop algo-code)
       (list :ok t :algo :none :digest digest :signed nil))
      ((null pk)
       (list :ok nil :algo (algo-keyword algo-code) :digest digest
             :signed t :error "missing public key"))
      ((verify-payload payload sig pk :algo (algo-keyword algo-code))
       (list :ok t :algo (algo-keyword algo-code) :digest digest :signed t))
      (t
       (list :ok nil :algo (algo-keyword algo-code) :digest digest
             :signed t :error "signature mismatch")))))

(defun payload-digest-hex (payload)
  (%hex (%sha256 payload)))
