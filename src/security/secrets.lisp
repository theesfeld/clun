;;;; secrets.lisp -- Pure-CL encrypted secrets vault (Issue #179 / FULL PORT).
;;;;
;;;; Clun.secrets meets and exceeds Bun.secrets:
;;;;   get / set / delete by service + name (account)
;;;;   empty-string set deletes (Bun parity)
;;;;   allowUnrestrictedAccess accepted (user-scoped vault; no interactive ACL)
;;;; Exceed-Bun surface (engine-free core):
;;;;   has / list / clear, configurable path and master key, AES-256-GCM file vault
;;;;
;;;; Purity: Common Lisp only (Ironclad AES-GCM + PBKDF2). No foreign-function
;;;; interface and no OS keychain bindings. A pure encrypted vault is the full-port
;;;; realization of this row — purity is implementation language, not feature
;;;; exclusion (epic #177).

(in-package :clun.secrets)

(defparameter +vault-magic+
  (make-array 8 :element-type '(unsigned-byte 8)
              :initial-contents #(#x43 #x4c #x55 #x4e #x53 #x43 #x52 #x31)) ; "CLUNSCR1"
  "On-disk magic for the Clun secrets vault.")

(defconstant +vault-version+ 1)
(defconstant +salt-length+ 16)
(defconstant +iv-length+ 12)
(defconstant +tag-length+ 16)
(defconstant +key-length+ 32)
(defconstant +pbkdf2-iterations+ 100000)
(defconstant +max-service-bytes+ 4096)
(defconstant +max-name-bytes+ 4096)
(defconstant +max-value-bytes+ (* 1024 1024))
(defconstant +max-entries+ 100000)

;; String codes use DEFPARAMETER: SBCL treats reloaded string DEFCONSTANTs as
;; DEFCONSTANT-UNEQL even when the characters match.
(defparameter +not-available-code+ "ERR_SECRETS_NOT_AVAILABLE")
(defparameter +platform-error-code+ "ERR_SECRETS_PLATFORM_ERROR")
(defparameter +access-denied-code+ "ERR_SECRETS_ACCESS_DENIED")

(defparameter +not-available-message+
  "Secrets storage is not available."
  "Retained code string for compatibility; vault is available by default.")

(defparameter *vault-path-override* nil
  "When non-NIL, absolute path of the vault file (tests / hermetic runs).")

(defparameter *master-key-override* nil
  "When non-NIL, octet vector used as master key material (tests).")

(define-condition secrets-error (error)
  ((kind :initarg :kind :reader secrets-error-kind)
   (detail :initarg :detail :initform nil :reader secrets-error-detail)
   (code :initarg :code :initform nil :reader secrets-error-code))
  (:report (lambda (condition stream)
             (if (secrets-error-detail condition)
                 (format stream "~A: ~A"
                         (secrets-error-kind condition)
                         (secrets-error-detail condition))
                 (format stream "~A" (secrets-error-kind condition))))))

(defun %fail (kind detail &optional code)
  (error 'secrets-error :kind kind :detail detail :code code))

(defun secrets-available-p ()
  "T — pure-CL vault is always available (no OS keychain dependency)."
  t)

(defun os-secrets-available-p ()
  "Alias of SECRETS-AVAILABLE-P (historical Phase 58 name)."
  (secrets-available-p))

;;; --- UTF-8 / binary helpers -------------------------------------------------

(defun %utf8-octets (string)
  (sb-ext:string-to-octets string :external-format :utf-8))

(defun %utf8-string (octets &key (start 0) end)
  (sb-ext:octets-to-string octets :external-format :utf-8
                                  :start start :end end))

(defun %u16be (n)
  (vector (ldb (byte 8 8) n) (ldb (byte 8 0) n)))

(defun %u32be (n)
  (vector (ldb (byte 8 24) n) (ldb (byte 8 16) n)
          (ldb (byte 8 8) n) (ldb (byte 8 0) n)))

(defun %read-u16be (octets index)
  (logior (ash (aref octets index) 8) (aref octets (1+ index))))

(defun %read-u32be (octets index)
  (logior (ash (aref octets index) 24)
          (ash (aref octets (1+ index)) 16)
          (ash (aref octets (+ index 2)) 8)
          (aref octets (+ index 3))))

(defun %concat-octets (&rest parts)
  (let* ((total (loop for p in parts sum (length p)))
         (out (make-array total :element-type '(unsigned-byte 8)))
         (i 0))
    (dolist (p parts out)
      (replace out p :start1 i)
      (incf i (length p)))))

(defun %wipe (octets)
  (when (and octets (typep octets '(vector (unsigned-byte 8))))
    (fill octets 0))
  octets)

(defun %hex-encode (octets)
  (with-output-to-string (s)
    (loop for b across octets
          do (format s "~2,'0x" b))))

(defun %hex-decode (string)
  (let* ((len (length string))
         (out (make-array (floor len 2) :element-type '(unsigned-byte 8))))
    (unless (evenp len)
      (%fail :invalid-arg "hex key must have even length" +access-denied-code+))
    (loop for i from 0 below len by 2
          for j from 0
          do (setf (aref out j)
                   (parse-integer string :start i :end (+ i 2) :radix 16)))
    out))

;;; --- path / key material ----------------------------------------------------

(defun %config-home ()
  (or (let ((xdg (clun.sys:getenv "XDG_CONFIG_HOME")))
        (and xdg (plusp (length xdg)) xdg))
      (let ((home (clun.sys:homedir)))
        (if (and home (plusp (length home)))
            (clun.sys:path-join home ".config")
            (clun.sys:path-join (clun.sys:tmpdir) "clun-config")))))

(defun default-vault-path ()
  "Default on-disk vault path: $CLUN_SECRETS_PATH or XDG config clun/secrets.vault."
  (or (let ((env (clun.sys:getenv "CLUN_SECRETS_PATH")))
        (and env (plusp (length env)) env))
      (clun.sys:path-join (%config-home) "clun" "secrets.vault")))

(defun vault-path ()
  (or *vault-path-override* (default-vault-path)))

(defun %key-file-path (vault)
  (concatenate 'string vault ".key"))

(defun %ensure-parent-dir (path)
  (let ((parent (clun.sys:path-dirname path)))
    (when (and parent (plusp (length parent))
               (not (clun.sys:directory-p parent)))
      (handler-case
          (clun.sys:make-directory parent :recursive t :mode #o700)
        (error (e)
          (%fail :platform-error
                 (format nil "cannot create vault directory ~A: ~A" parent e)
                 +platform-error-code+))))))

(defun %load-or-create-key-file (path)
  "Return 32-byte key from PATH, creating a CSPRNG key with mode 0600 if missing."
  (%ensure-parent-dir path)
  (if (clun.sys:file-p path)
      (let* ((raw (clun.sys:read-file-octets path))
             (text (string-trim '(#\Space #\Tab #\Newline #\Return)
                                (%utf8-string raw))))
        (cond
          ((= (length raw) +key-length+)
           (copy-seq raw))
          ((and (= (length text) (* 2 +key-length+))
                (every (lambda (c) (digit-char-p c 16)) text))
           (%hex-decode text))
          (t
           (%fail :access-denied
                  "vault key file is malformed"
                  +access-denied-code+))))
      (let ((key (clun.sys:os-random-bytes +key-length+)))
        (clun.sys:write-file-octets path
                                    (%utf8-octets (%hex-encode key))
                                    :mode #o600)
        key)))

(defun %master-key-material ()
  "Octets used to derive or supply the AES-256 key."
  (cond
    (*master-key-override*
     (let ((k *master-key-override*))
       (unless (typep k '(vector (unsigned-byte 8)))
         (%fail :invalid-arg "master key override must be an octet vector"))
       (copy-seq k)))
    (t
     (let ((env (clun.sys:getenv "CLUN_SECRETS_KEY")))
       (if (and env (plusp (length env)))
           (if (and (= (length env) (* 2 +key-length+))
                    (every (lambda (c) (digit-char-p c 16)) env))
               (%hex-decode env)
               (%utf8-octets env))
           (%load-or-create-key-file (%key-file-path (vault-path))))))))

(defun %derive-aes-key (material salt)
  (if (= (length material) +key-length+)
      (copy-seq material)
      (crypto:derive-key
       (crypto:make-kdf 'crypto:pbkdf2 :digest 'crypto:sha256)
       material salt +pbkdf2-iterations+ +key-length+)))

;;; --- AEAD -------------------------------------------------------------------

(defun %aes-gcm-encrypt (key iv plaintext &optional associated-data)
  (let* ((mode (crypto:make-authenticated-encryption-mode
                'crypto:gcm
                :cipher-name :aes
                :key key
                :initialization-vector iv))
         (ct (crypto:encrypt-message mode plaintext
                                     :associated-data associated-data))
         (tag (crypto:produce-tag mode)))
    (values ct tag)))

(defun %aes-gcm-decrypt (key iv ciphertext tag &optional associated-data)
  (let ((mode (crypto:make-authenticated-encryption-mode
               'crypto:gcm
               :cipher-name :aes
               :key key
               :initialization-vector iv
               :tag tag)))
    (handler-case
        (crypto:decrypt-message mode ciphertext
                                :associated-data associated-data)
      (crypto:bad-authentication-tag ()
        (%fail :access-denied
               "vault authentication failed (wrong key or corrupted vault)"
               +access-denied-code+))
      (error (e)
        (%fail :platform-error
               (format nil "vault decrypt failed: ~A" e)
               +platform-error-code+)))))

;;; --- entry table encode/decode ---------------------------------------------

(defun %encode-entries (entries)
  "ENTRIES is a list of (service name value) strings. Return octet vector."
  (when (> (length entries) +max-entries+)
    (%fail :platform-error "vault entry limit exceeded" +platform-error-code+))
  (let ((parts (list (%u32be (length entries)))))
    (dolist (entry entries)
      (destructuring-bind (service name value) entry
        (let ((s (%utf8-octets service))
              (n (%utf8-octets name))
              (v (%utf8-octets value)))
          (when (> (length s) +max-service-bytes+)
            (%fail :invalid-arg "service exceeds maximum length"))
          (when (> (length n) +max-name-bytes+)
            (%fail :invalid-arg "name exceeds maximum length"))
          (when (> (length v) +max-value-bytes+)
            (%fail :invalid-arg "value exceeds maximum length"))
          (push (%u16be (length s)) parts)
          (push s parts)
          (push (%u16be (length n)) parts)
          (push n parts)
          (push (%u32be (length v)) parts)
          (push v parts))))
    (apply #'%concat-octets (nreverse parts))))

(defun %decode-entries (octets)
  (when (< (length octets) 4)
    (%fail :platform-error "vault payload truncated" +platform-error-code+))
  (let ((count (%read-u32be octets 0))
        (i 4)
        (entries '()))
    (when (> count +max-entries+)
      (%fail :platform-error "vault entry count corrupt" +platform-error-code+))
    (dotimes (_ count)
      (when (> (+ i 2) (length octets))
        (%fail :platform-error "vault payload truncated" +platform-error-code+))
      (let ((slen (%read-u16be octets i)))
        (incf i 2)
        (when (> (+ i slen 2) (length octets))
          (%fail :platform-error "vault payload truncated" +platform-error-code+))
        (let ((service (%utf8-string octets :start i :end (+ i slen))))
          (incf i slen)
          (let ((nlen (%read-u16be octets i)))
            (incf i 2)
            (when (> (+ i nlen 4) (length octets))
              (%fail :platform-error "vault payload truncated" +platform-error-code+))
            (let ((name (%utf8-string octets :start i :end (+ i nlen))))
              (incf i nlen)
              (let ((vlen (%read-u32be octets i)))
                (incf i 4)
                (when (> (+ i vlen) (length octets))
                  (%fail :platform-error "vault payload truncated" +platform-error-code+))
                (let ((value (%utf8-string octets :start i :end (+ i vlen))))
                  (incf i vlen)
                  (push (list service name value) entries))))))))
    (nreverse entries)))

;;; --- vault load / store -----------------------------------------------------

(defun %empty-vault-file-p (path)
  (or (not (clun.sys:path-exists-p path))
      (zerop (length (ignore-errors (clun.sys:read-file-octets path))))))

(defun %load-entries ()
  "Return the list of (service name value) from the vault, or empty list."
  (let ((path (vault-path)))
    (when (%empty-vault-file-p path)
      (return-from %load-entries '()))
    (let* ((blob (handler-case (clun.sys:read-file-octets path)
                   (error (e)
                     (%fail :platform-error
                            (format nil "cannot read vault: ~A" e)
                            +platform-error-code+))))
           (header-len (+ 8 1 +salt-length+ +iv-length+ +tag-length+)))
      (when (< (length blob) header-len)
        (%fail :platform-error "vault file too short" +platform-error-code+))
      (unless (equalp (subseq blob 0 8) +vault-magic+)
        (%fail :platform-error "vault magic mismatch" +platform-error-code+))
      (unless (= (aref blob 8) +vault-version+)
        (%fail :platform-error
               (format nil "unsupported vault version ~A" (aref blob 8))
               +platform-error-code+))
      (let* ((salt (subseq blob 9 (+ 9 +salt-length+)))
             (iv (subseq blob (+ 9 +salt-length+)
                         (+ 9 +salt-length+ +iv-length+)))
             (tag-start (- (length blob) +tag-length+))
             (tag (subseq blob tag-start))
             (ct (subseq blob (+ 9 +salt-length+ +iv-length+) tag-start))
             (material (%master-key-material))
             (key (%derive-aes-key material salt)))
        (unwind-protect
             (let ((plain (%aes-gcm-decrypt key iv ct tag +vault-magic+)))
               (unwind-protect
                    (%decode-entries plain)
                 (%wipe plain)))
          (%wipe key)
          (%wipe material))))))

(defun %store-entries (entries)
  (let* ((path (vault-path))
         (salt (clun.sys:os-random-bytes +salt-length+))
         (iv (clun.sys:os-random-bytes +iv-length+))
         (material (%master-key-material))
         (key (%derive-aes-key material salt))
         (plain (%encode-entries entries)))
    (unwind-protect
         (multiple-value-bind (ct tag)
             (%aes-gcm-encrypt key iv plain +vault-magic+)
           (let* ((blob (%concat-octets
                         +vault-magic+
                         (vector +vault-version+)
                         salt iv ct tag))
                  (tmp (concatenate 'string path ".tmp."
                                    (write-to-string (get-internal-real-time)))))
             (%ensure-parent-dir path)
             (handler-case
                 (progn
                   (clun.sys:write-file-octets tmp blob :mode #o600)
                   (clun.sys:rename-path tmp path)
                   (ignore-errors (clun.sys:change-mode path #o600)))
               (error (e)
                 (ignore-errors (clun.sys:remove-file tmp))
                 (%fail :platform-error
                        (format nil "cannot write vault: ~A" e)
                        +platform-error-code+)))))
      (%wipe key)
      (%wipe material)
      (%wipe plain))))

;;; --- public argument validation (engine-free) -------------------------------

(defun validate-service-name (service name)
  "Validate SERVICE and NAME as non-empty strings.
   Returns T on success; signals secrets-error :invalid-arg otherwise.
   Messages match Bun's ERR_INVALID_ARG_TYPE spellings."
  (unless (and (stringp service) (stringp name))
    (%fail :invalid-arg "Expected service and name to be strings"))
  (when (or (zerop (length service)) (zerop (length name)))
    (%fail :invalid-arg "Expected service and name to not be empty"))
  (when (or (> (length (%utf8-octets service)) +max-service-bytes+)
            (> (length (%utf8-octets name)) +max-name-bytes+))
    (%fail :invalid-arg "service or name exceeds maximum length"))
  t)

(defun validate-set-value (value present-p)
  "Validate SET's value string. PRESENT-P is false when the property was absent
   or null/undefined in the options object form."
  (cond
    ((not present-p)
     (%fail :invalid-arg
            "Expected 'value' to be a string. To delete the secret, call secrets.delete instead."))
    ((not (stringp value))
     (%fail :invalid-arg "Expected 'value' to be a string"))
    ((> (length (%utf8-octets value)) +max-value-bytes+)
     (%fail :invalid-arg "value exceeds maximum length"))
    (t t)))

;;; --- public vault operations ------------------------------------------------

(defun %entry-key (service name)
  (cons service name))

(defun %find-entry (entries service name)
  (find-if (lambda (e)
             (and (string= (first e) service)
                  (string= (second e) name)))
           entries))

(defun secrets-get (service name)
  "Return the secret string for SERVICE/NAME, or NIL if absent."
  (validate-service-name service name)
  (let ((entry (%find-entry (%load-entries) service name)))
    (and entry (third entry))))

(defun secrets-set (service name value &key allow-unrestricted)
  "Store VALUE for SERVICE/NAME. Empty VALUE deletes (Bun parity).
   ALLOW-UNRESTRICTED is accepted for Bun.secrets API shape (no-op on the vault)."
  (declare (ignore allow-unrestricted))
  (validate-service-name service name)
  (validate-set-value value t)
  (if (zerop (length value))
      (progn (secrets-delete service name) (values))
      (let* ((entries (%load-entries))
             (rest (remove-if (lambda (e)
                                (and (string= (first e) service)
                                     (string= (second e) name)))
                              entries)))
        (%store-entries (cons (list service name value) rest))
        (values))))

(defun secrets-delete (service name)
  "Delete SERVICE/NAME. Return T if a credential existed, NIL otherwise."
  (validate-service-name service name)
  (let* ((entries (%load-entries))
         (found (%find-entry entries service name)))
    (if found
        (progn
          (%store-entries
           (remove-if (lambda (e)
                        (and (string= (first e) service)
                             (string= (second e) name)))
                      entries))
          t)
        nil)))

(defun secrets-has (service name)
  "Return T if SERVICE/NAME exists without returning the value."
  (validate-service-name service name)
  (and (%find-entry (%load-entries) service name) t))

(defun secrets-list (&optional service)
  "Return a list of (service . name) conses, optionally filtered by SERVICE."
  (when service
    (unless (stringp service)
      (%fail :invalid-arg "Expected service to be a string"))
    (when (zerop (length service))
      (%fail :invalid-arg "Expected service to not be empty")))
  (let ((entries (%load-entries)))
    (mapcar (lambda (e) (cons (first e) (second e)))
            (if service
                (remove-if-not (lambda (e) (string= (first e) service)) entries)
                entries))))

(defun secrets-clear (&optional service)
  "Delete all secrets, or all secrets for SERVICE. Return count deleted."
  (when service
    (unless (stringp service)
      (%fail :invalid-arg "Expected service to be a string"))
    (when (zerop (length service))
      (%fail :invalid-arg "Expected service to not be empty")))
  (let* ((entries (%load-entries))
         (kept (if service
                   (remove-if (lambda (e) (string= (first e) service)) entries)
                   '()))
         (deleted (- (length entries) (length kept))))
    (when (plusp deleted)
      (%store-entries kept))
    deleted))

(defun reject-os-secrets (&optional operation)
  "Historical Phase 58 helper. Vault is available; this no longer signals."
  (declare (ignore operation))
  (values))
