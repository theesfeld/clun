;;; certificate.lisp --- X.509 Certificate Parsing
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Anthony Green <green@moxielogic.com>
;;;
;;; Implements X.509 certificate parsing using the ASN.1 parser.

(in-package #:pure-tls)

;;;; X.509 Certificate Structure
;;;
;;; Certificate  ::=  SEQUENCE  {
;;;      tbsCertificate       TBSCertificate,
;;;      signatureAlgorithm   AlgorithmIdentifier,
;;;      signatureValue       BIT STRING  }
;;;
;;; TBSCertificate  ::=  SEQUENCE  {
;;;      version         [0]  EXPLICIT Version DEFAULT v1,
;;;      serialNumber         CertificateSerialNumber,
;;;      signature            AlgorithmIdentifier,
;;;      issuer               Name,
;;;      validity             Validity,
;;;      subject              Name,
;;;      subjectPublicKeyInfo SubjectPublicKeyInfo,
;;;      issuerUniqueID  [1]  IMPLICIT UniqueIdentifier OPTIONAL,
;;;      subjectUniqueID [2]  IMPLICIT UniqueIdentifier OPTIONAL,
;;;      extensions      [3]  EXPLICIT Extensions OPTIONAL }

(defstruct x509-certificate
  "Parsed X.509 certificate."
  ;; Raw DER bytes (for signature verification)
  (raw-der nil :type (or null octet-vector))
  (tbs-raw nil :type (or null octet-vector))
  ;; Parsed fields
  (version 1 :type fixnum)
  (serial-number nil)
  (signature-algorithm nil)
  (signature-algorithm-params nil)  ; For RSA-PSS: (:hash :salt-length)
  (issuer nil)
  (validity-not-before nil)
  (validity-not-after nil)
  (subject nil)
  (subject-public-key-info nil)
  (extensions nil :type list)
  ;; Signature
  (signature nil))

(defstruct x509-name
  "X.509 Distinguished Name."
  (rdns nil :type list)  ; Flattened compatibility view of (oid . value) pairs.
  (raw-der nil :type (or null octet-vector)))

(defstruct x509-extension
  "X.509 Extension."
  (oid nil)
  (critical nil :type boolean)
  (value nil))

;;;; Certificate Parsing

(defparameter +enforced-critical-certificate-extensions+
  '(:basic-constraints :key-usage :subject-alt-name :extended-key-usage)
  "Critical X.509 extensions whose DER and authentication semantics are
actually enforced by the bounded pure-Lisp verifier.  Merely mapping an OID to
a keyword does not make its critical semantics understood.  In particular,
name/policy constraints and revocation-distribution extensions stay out of this
set until their path-processing rules are implemented.")

(defconstant +maximum-rsa-modulus-bits+ 8192
  "Maximum RSA modulus size accepted by the bounded WebPKI profile.")

(defconstant +maximum-rsa-pss-salt-length+ 1024
  "Absolute syntactic bound for peer-controlled RSASSA-PSS saltLength values.")

(defconstant +secp256r1-field-prime+
  #xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF)

(defconstant +secp384r1-field-prime+
  #xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFFFF0000000000000000FFFFFFFF)

(defconstant +secp521r1-field-prime+
  #x1FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)

(defun enforced-critical-certificate-extension-p (oid)
  "Return true only when OID names a critical extension this verifier enforces."
  (not (null (member oid +enforced-critical-certificate-extensions+
                     :test #'equal))))

(defun validate-implicit-bit-string (raw-bytes)
  "Validate BIT STRING encoding for IMPLICIT BIT STRING fields.
Per DER (X.690): unused bits count must be 0-7 and padding bits must be zero."
  (unless (and (typep raw-bytes 'octet-vector) (>= (length raw-bytes) 2))
    (error 'tls-decode-error :message "UniqueIdentifier BIT STRING must not be empty"))
  (let ((unused-bits (aref raw-bytes 0)))
    (when (> unused-bits 7)
      (error 'tls-decode-error
             :message "BIT STRING unused bits count must be 0-7"))
    (when (> unused-bits 0)
      (let* ((last-byte (aref raw-bytes (1- (length raw-bytes))))
             (mask (1- (ash 1 unused-bits))))
        (unless (zerop (logand last-byte mask))
          (error 'tls-decode-error
                 :message "BIT STRING has non-zero padding bits (invalid DER)"))))))

(defun asn1-universal-primitive-p (node tag)
  (and (asn1-node-p node)
       (= (asn1-node-class node) +asn1-class-universal+)
       (= (asn1-node-tag node) tag)
       (not (asn1-node-constructed node))))

(defun asn1-null-p (node)
  (and (asn1-universal-primitive-p node +asn1-null+)
       (zerop (asn1-node-content-length node))))

(defun require-asn1-sequence (node description)
  (unless (asn1-sequence-p node)
    (error 'tls-decode-error
           :message (format nil "~A must be a DER SEQUENCE" description)))
  (asn1-children node))

(defun parse-validity (node)
  "Parse the exact RFC 5280 Validity shape and reject inverted windows."
  (let ((children (require-asn1-sequence node "Validity")))
    (unless (= (length children) 2)
      (error 'tls-decode-error
             :message "Validity must contain exactly notBefore and notAfter"))
    (dolist (time children)
      (unless (and (= (asn1-node-class time) +asn1-class-universal+)
                   (not (asn1-node-constructed time))
                   (member (asn1-node-tag time)
                           (list +asn1-utc-time+ +asn1-generalized-time+)))
        (error 'tls-decode-error
               :message "Validity fields must be primitive UTCTime or GeneralizedTime")))
    (let ((not-before (asn1-node-value (first children)))
          (not-after (asn1-node-value (second children))))
      (when (> not-before not-after)
        (error 'tls-decode-error
               :message "Certificate validity notBefore is after notAfter"))
      (values not-before not-after))))

(defun parse-certificate (der-bytes)
  "Parse a DER-encoded X.509 certificate."
  (let* ((root (parse-der der-bytes))
         (cert (make-x509-certificate :raw-der der-bytes)))
    (unless (asn1-sequence-p root)
      (error 'tls-decode-error :message "Certificate must be a SEQUENCE"))
    (let ((children (asn1-children root)))
      (unless (= (length children) 3)
        (error 'tls-decode-error
               :message "Certificate must contain exactly three fields"))
      (let ((tbs (first children))
            (outer-algorithm-node (second children))
            (signature-node (third children)))
        (unless (asn1-sequence-p tbs)
          (error 'tls-decode-error :message "TBSCertificate must be a SEQUENCE"))
        (setf (x509-certificate-tbs-raw cert) (asn1-node-raw-bytes tbs))
        (multiple-value-bind (inner-algorithm-node inner-algorithm inner-params)
            (parse-tbs-certificate cert tbs)
          (multiple-value-bind (outer-algorithm outer-params)
              (parse-algorithm-identifier-with-params outer-algorithm-node)
            ;; RFC 5280 4.1.1.2 requires the complete AlgorithmIdentifier,
            ;; including RSA-PSS parameters, to match the inner identifier.
            (unless (equalp (asn1-node-raw-bytes inner-algorithm-node)
                            (asn1-node-raw-bytes outer-algorithm-node))
              (error 'tls-decode-error
                     :message "Inner and outer signature AlgorithmIdentifiers differ"))
            (unless (and (equal inner-algorithm outer-algorithm)
                         (equal inner-params outer-params))
              (error 'tls-decode-error
                     :message "Signature AlgorithmIdentifier parameters differ"))
            (setf (x509-certificate-signature-algorithm cert) outer-algorithm
                  (x509-certificate-signature-algorithm-params cert) outer-params)))
        (unless (asn1-universal-primitive-p signature-node +asn1-bit-string+)
          (error 'tls-decode-error :message "Certificate signatureValue must be a BIT STRING"))
        (let ((signature-value (asn1-node-value signature-node)))
          (unless (and (zerop (getf signature-value :unused-bits))
                       (plusp (length (getf signature-value :data))))
            (error 'tls-decode-error
                   :message "Certificate signatureValue must be a non-empty octet-aligned BIT STRING"))
          (setf (x509-certificate-signature cert)
                (getf signature-value :data)))))
    cert))

(defun parse-tbs-certificate (cert tbs)
  "Parse the exact TBSCertificate schema and return its signature identifier."
  (let ((children (require-asn1-sequence tbs "TBSCertificate"))
        (idx 0)
        (inner-algorithm-node nil)
        (inner-algorithm nil)
        (inner-params nil))
    ;; Version [0] EXPLICIT (optional, default v1)
    (when (and children (asn1-context-p (nth idx children) 0))
      (let* ((wrapper (nth idx children))
             (wrapped (and (asn1-node-constructed wrapper)
                           (asn1-children wrapper))))
        (unless (and (= (length wrapped) 1)
                     (asn1-universal-primitive-p (first wrapped) +asn1-integer+)
                     (<= 0 (asn1-node-value (first wrapped)) 2))
          (error 'tls-decode-error
                 :message "Version [0] must explicitly wrap one INTEGER in the range 0..2"))
        ;; Version v1 is DEFAULT and therefore must be omitted in DER.
        (when (zerop (asn1-node-value (first wrapped)))
          (error 'tls-decode-error :message "The default v1 Version must be omitted"))
        (setf (x509-certificate-version cert)
              (1+ (asn1-node-value (first wrapped)))))
      (incf idx))
    (when (< (- (length children) idx) 6)
      (error 'tls-decode-error :message "TBSCertificate is missing required fields"))
    ;; SerialNumber - RFC 5280 s4.1.2.2: must be positive
    (let ((serial-node (nth idx children)))
      (unless (asn1-universal-primitive-p serial-node +asn1-integer+)
        (error 'tls-decode-error :message "Certificate serialNumber must be an INTEGER"))
      (let ((serial (asn1-node-value serial-node)))
        (when (or (<= serial 0) (> (asn1-node-content-length serial-node) 20))
          (error 'tls-decode-error
                 :message "Certificate serial number must be positive and at most 20 octets"))
        (setf (x509-certificate-serial-number cert) serial)))
    (incf idx)
    ;; Signature (AlgorithmIdentifier) - capture the complete identifier.
    (setf inner-algorithm-node (nth idx children))
    (multiple-value-setq (inner-algorithm inner-params)
      (parse-algorithm-identifier-with-params inner-algorithm-node))
    (incf idx)
    ;; Issuer must be a non-empty Name.
    (setf (x509-certificate-issuer cert)
          (parse-name (nth idx children)))
    (incf idx)
    ;; Validity must contain exactly two correctly tagged canonical times.
    (multiple-value-bind (not-before not-after)
        (parse-validity (nth idx children))
      (setf (x509-certificate-validity-not-before cert) not-before
            (x509-certificate-validity-not-after cert) not-after))
    (incf idx)
    ;; Subject may be empty only when a critical non-empty SAN follows.
    (setf (x509-certificate-subject cert)
          (parse-name (nth idx children) :allow-empty t))
    (incf idx)
    ;; SubjectPublicKeyInfo exact schema and key validation.
    (setf (x509-certificate-subject-public-key-info cert)
          (parse-subject-public-key-info (nth idx children)))
    (incf idx)
    ;; Optional fields are unique and ordered by their schema positions.
    (when (and (< idx (length children)) (asn1-context-p (nth idx children) 1))
      (unless (>= (x509-certificate-version cert) 2)
        (error 'tls-decode-error
               :message "issuerUniqueID is not permitted in a v1 certificate"))
      (let ((node (nth idx children)))
        (when (asn1-node-constructed node)
          (error 'tls-decode-error :message "issuerUniqueID must be primitive"))
        (validate-implicit-bit-string (asn1-node-value node)))
      (incf idx))
    (when (and (< idx (length children)) (asn1-context-p (nth idx children) 2))
      (unless (>= (x509-certificate-version cert) 2)
        (error 'tls-decode-error
               :message "subjectUniqueID is not permitted in a v1 certificate"))
      (let ((node (nth idx children)))
        (when (asn1-node-constructed node)
          (error 'tls-decode-error :message "subjectUniqueID must be primitive"))
        (validate-implicit-bit-string (asn1-node-value node)))
      (incf idx))
    ;; Extensions [3] EXPLICIT
    (when (and (< idx (length children))
               (asn1-context-p (nth idx children) 3))
      (unless (= (x509-certificate-version cert) 3)
        (error 'tls-decode-error :message "Extensions are permitted only in v3 certificates"))
      (let ((wrapper (nth idx children)))
        (unless (and (asn1-node-constructed wrapper)
                     (= (length (asn1-children wrapper)) 1)
                     (asn1-sequence-p (first (asn1-children wrapper))))
          (error 'tls-decode-error
                 :message "Extensions [3] must explicitly wrap one SEQUENCE")))
      (setf (x509-certificate-extensions cert)
            (parse-extensions-seq (first (asn1-children (nth idx children)))))
      (incf idx)
      ;; RFC 5280 s4.2: reject critical extensions whose semantics are not
      ;; enforced.  Recognizing an OID name is not sufficient.
      (dolist (ext (x509-certificate-extensions cert))
        (when (and (x509-extension-critical ext)
                   (not (enforced-critical-certificate-extension-p
                         (x509-extension-oid ext))))
          (error 'tls-decode-error
                 :message (format nil "Unsupported critical extension: ~A"
                                  (x509-extension-oid ext))))))
    (unless (= idx (length children))
      (error 'tls-decode-error
             :message "TBSCertificate contains duplicate, out-of-order, or trailing fields"))
    (when (null (x509-name-rdns (x509-certificate-subject cert)))
      (let ((san (find :subject-alt-name (x509-certificate-extensions cert)
                       :key #'x509-extension-oid)))
        (unless (and san (x509-extension-critical san)
                     (x509-extension-value san))
          (error 'tls-decode-error
                 :message "An empty subject requires a critical non-empty subjectAltName"))))
    (values inner-algorithm-node inner-algorithm inner-params)))

(defun octets-lexicographically-less-p (left right)
  "Return true when LEFT precedes RIGHT in DER octet-string ordering."
  (loop for index below (min (length left) (length right))
        for left-octet = (aref left index)
        for right-octet = (aref right index)
        when (/= left-octet right-octet)
          do (return (< left-octet right-octet))
        finally (return (< (length left) (length right)))))

(defun parse-name (node &key allow-empty)
  "Parse an X.509 Name (sequence of RDNs)."
  (let ((name-children (require-asn1-sequence node "Name"))
        (rdns nil))
    (unless (or allow-empty name-children)
      (error 'tls-decode-error :message "Issuer Name must not be empty"))
    (dolist (rdn-set name-children)
      (unless (and (asn1-set-p rdn-set) (asn1-children rdn-set))
        (error 'tls-decode-error
               :message "Each RelativeDistinguishedName must be a non-empty SET"))
      ;; RelativeDistinguishedName is SET OF AttributeTypeAndValue, so DER
      ;; requires its complete child encodings in ascending lexicographic
      ;; order (X.690 11.6).  This rule belongs here rather than on generic
      ;; SET values, whose component ordering is governed by their schema.
      (loop for previous = nil then current
            for attr in (asn1-children rdn-set)
            for current = (asn1-node-raw-bytes attr)
            when (and previous
                      (octets-lexicographically-less-p current previous))
              do (error 'tls-decode-error
                        :message "RelativeDistinguishedName SET OF is not in DER order"))
      (dolist (attr (asn1-children rdn-set))
        (let ((children (require-asn1-sequence attr "AttributeTypeAndValue")))
          (unless (and (= (length children) 2)
                       (asn1-universal-primitive-p
                        (first children) +asn1-object-identifier+)
                       (= (asn1-node-class (second children)) +asn1-class-universal+)
                       (not (asn1-node-constructed (second children))))
            (error 'tls-decode-error
                   :message "AttributeTypeAndValue must contain exactly an OID and primitive value"))
          (let ((oid (asn1-node-value (first children)))
                (value (asn1-node-value (second children))))
            (push (cons (oid-name oid) value) rdns)))))
    (make-x509-name :rdns (nreverse rdns)
                    :raw-der (asn1-node-raw-bytes node))))

(defun parse-algorithm-identifier (node)
  "Parse an AlgorithmIdentifier.
   Returns the algorithm OID name, or for EC algorithms, the curve OID."
  (multiple-value-bind (algorithm parameter)
      (parse-algorithm-identifier-components node)
    (if (eql algorithm :ec-public-key)
        (progn
          (unless (and parameter
                       (asn1-universal-primitive-p parameter
                                                   +asn1-object-identifier+))
            (error 'tls-decode-error
                   :message "EC AlgorithmIdentifier requires a named-curve OID"))
          (oid-name (asn1-node-value parameter)))
        algorithm)))

(defun parse-algorithm-identifier-components (node)
  "Validate the common AlgorithmIdentifier shape and return algorithm/parameter."
  (let ((children (require-asn1-sequence node "AlgorithmIdentifier")))
    (unless (and (<= 1 (length children) 2)
                 (asn1-universal-primitive-p
                  (first children) +asn1-object-identifier+))
      (error 'tls-decode-error
             :message "AlgorithmIdentifier must contain an OID and at most one parameter"))
    (values (oid-name (asn1-node-value (first children)))
            (second children))))

(defun rsa-pkcs1-signature-algorithm-p (algorithm)
  (member algorithm '(:sha1-with-rsa-encryption
                      :sha256-with-rsa-encryption
                      :sha384-with-rsa-encryption
                      :sha512-with-rsa-encryption)))

(defun no-parameter-signature-algorithm-p (algorithm)
  (member algorithm '(:ecdsa-with-sha256 :ecdsa-with-sha384
                      :ecdsa-with-sha512 :ed25519 :ed448
                      :mldsa44 :mldsa65 :mldsa87)))

(defun parse-algorithm-identifier-with-params (node)
  "Parse an AlgorithmIdentifier, returning (algorithm . params).
   For RSA-PSS, params is a plist with :hash and :salt-length.
   For other algorithms, params is NIL."
  (multiple-value-bind (algorithm parameter)
      (parse-algorithm-identifier-components node)
    (cond
      ((rsa-pkcs1-signature-algorithm-p algorithm)
       (unless (asn1-null-p parameter)
         (error 'tls-decode-error
                :message "RSA PKCS#1 certificate signature parameters must be NULL"))
       (values algorithm nil))
      ((no-parameter-signature-algorithm-p algorithm)
       (when parameter
         (error 'tls-decode-error
                :message "Certificate signature algorithm parameters must be absent"))
       (values algorithm nil))
      ((member algorithm '(:rsa-pss :rsassa-pss))
       (unless parameter
         (error 'tls-decode-error
                :message "RSASSA-PSS certificate signature parameters must be present"))
       (values algorithm (parse-rsa-pss-params parameter)))
      (t
       (error 'tls-decode-error
              :message (format nil "Unsupported certificate signature algorithm: ~A"
                               algorithm))))))

(defun parse-hash-algorithm-identifier (node)
  "Parse a hash AlgorithmIdentifier used inside RSASSA-PSS parameters."
  (multiple-value-bind (algorithm parameter)
      (parse-algorithm-identifier-components node)
    (unless (member algorithm '(:sha1 :sha256 :sha384 :sha512))
      (error 'tls-decode-error
             :message "RSASSA-PSS uses an unsupported hash algorithm"))
    (when (and parameter (not (asn1-null-p parameter)))
      (error 'tls-decode-error
             :message "Hash AlgorithmIdentifier parameters must be absent or NULL"))
    algorithm))

(defun parse-rsa-pss-params (node)
  "Parse RSA-PSS AlgorithmIdentifier parameters.
   RSASSA-PSS-params ::= SEQUENCE {
     hashAlgorithm      [0] HashAlgorithm DEFAULT sha1,
     maskGenAlgorithm   [1] MaskGenAlgorithm DEFAULT mgf1SHA1,
     saltLength         [2] INTEGER DEFAULT 20,
     trailerField       [3] TrailerField DEFAULT trailerFieldBC }
   Returns a plist with :hash and :salt-length."
  (let ((children (require-asn1-sequence node "RSASSA-PSS parameters"))
        (hash :sha1)
        (mgf-hash :sha1)
        (salt-length 20)
        (last-tag -1))
    (dolist (field children)
      (unless (and (= (asn1-node-class field) +asn1-class-context-specific+)
                   (asn1-node-constructed field)
                   (= (length (asn1-children field)) 1)
                   (<= 0 (asn1-node-tag field) 3)
                   (> (asn1-node-tag field) last-tag))
        (error 'tls-decode-error
               :message "RSASSA-PSS parameter fields must be unique and ordered"))
      (setf last-tag (asn1-node-tag field))
      (let ((value (first (asn1-children field))))
        (case (asn1-node-tag field)
          (0
           (setf hash (parse-hash-algorithm-identifier value))
           (when (eql hash :sha1)
             (error 'tls-decode-error
                    :message "Default RSASSA-PSS hashAlgorithm must be omitted")))
          (1
           (multiple-value-bind (mgf parameter)
               (parse-algorithm-identifier-components value)
             (unless (and (eql mgf :mgf1) parameter)
               (error 'tls-decode-error
                      :message "RSASSA-PSS maskGenAlgorithm must be MGF1"))
             (setf mgf-hash (parse-hash-algorithm-identifier parameter))
             (when (eql mgf-hash :sha1)
               (error 'tls-decode-error
                      :message "Default RSASSA-PSS maskGenAlgorithm must be omitted"))))
          (2
           (unless (and (asn1-universal-primitive-p value +asn1-integer+)
                        (not (minusp (asn1-node-value value)))
                        (<= (asn1-node-value value)
                            +maximum-rsa-pss-salt-length+))
             (error 'tls-decode-error
                    :message "RSASSA-PSS saltLength is negative or exceeds the bounded profile"))
           (setf salt-length (asn1-node-value value))
           (when (= salt-length 20)
             (error 'tls-decode-error
                    :message "Default RSASSA-PSS saltLength must be omitted")))
          (3
           ;; trailerField has the sole supported/default value 1, which DER
           ;; requires omitted.  No other trailer field is supported.
           (error 'tls-decode-error
                  :message "RSASSA-PSS trailerField must be the omitted default")))))
    (unless (eql hash mgf-hash)
      (error 'tls-decode-error
             :message "RSASSA-PSS MGF1 hash must match the message hash"))
    (list :hash hash :salt-length salt-length)))

(defun parse-rsa-public-key-components
    (public-key-der &key (minimum-bits 2048)
                           (maximum-bits +maximum-rsa-modulus-bits+))
  "Parse and validate an RFC 8017 RSAPublicKey, returning modulus/exponent."
  (let* ((node (parse-der public-key-der))
         (children (require-asn1-sequence node "RSAPublicKey")))
    (unless (and (= (length children) 2)
                 (every (lambda (child)
                          (asn1-universal-primitive-p child +asn1-integer+))
                        children))
      (error 'tls-decode-error
             :message "RSAPublicKey must contain exactly two INTEGERs"))
    (let ((modulus (asn1-node-value (first children)))
          (exponent (asn1-node-value (second children))))
      (unless (and (plusp modulus) (oddp modulus)
                   (>= (integer-length modulus) minimum-bits)
                   (<= (integer-length modulus) maximum-bits)
                   (>= exponent 3) (oddp exponent) (< exponent modulus))
        (error 'tls-decode-error
               :message "RSA key exceeds bounds or has an invalid modulus/exponent"))
      (values modulus exponent))))

(defun validate-ec-public-point (curve bytes)
  (multiple-value-bind (coordinate-length field-prime ironclad-curve)
      (ecase curve
        (:prime256v1
         (values 32 +secp256r1-field-prime+ :secp256r1))
        (:secp384r1
         (values 48 +secp384r1-field-prime+ :secp384r1))
        (:secp521r1
         (values 66 +secp521r1-field-prime+ :secp521r1)))
    (unless (and (= (length bytes) (1+ (* 2 coordinate-length)))
                 (= (aref bytes 0) #x04))
      (error 'tls-decode-error
             :message "EC SubjectPublicKey must be a supported uncompressed point"))
    ;; SEC 1 encodes canonical field elements, not arbitrary integers modulo p.
    ;; Ironclad checks the curve equation modulo p, so reject x/y >= p first;
    ;; this also rejects nonzero unused high bits in P-521 coordinates.
    (let ((x (ironclad:octets-to-integer
              bytes :start 1 :end (1+ coordinate-length) :big-endian t))
          (y (ironclad:octets-to-integer
              bytes :start (1+ coordinate-length) :big-endian t)))
      (unless (and (< x field-prime) (< y field-prime))
        (error 'tls-decode-error
               :message "EC SubjectPublicKey coordinates are not canonical field elements")))
    ;; Length, encoding form, and field range are not enough: reject points
    ;; that do not satisfy the selected named curve equation.
    (handler-case
        (ironclad:ec-decode-point ironclad-curve bytes)
      (error ()
        (error 'tls-decode-error
               :message "EC SubjectPublicKey point is not on the selected curve")))))

(defun parse-subject-public-key-info (node)
  "Parse and losslessly validate SubjectPublicKeyInfo."
  (let ((children (require-asn1-sequence node "SubjectPublicKeyInfo")))
    (unless (= (length children) 2)
      (error 'tls-decode-error
             :message "SubjectPublicKeyInfo must contain exactly two fields"))
    (let ((algorithm-node (first children))
          (key-node (second children)))
      (unless (asn1-universal-primitive-p key-node +asn1-bit-string+)
        (error 'tls-decode-error
               :message "SubjectPublicKeyInfo key must be a primitive BIT STRING"))
      (let* ((bits (asn1-node-value key-node))
             (key (getf bits :data))
             (algorithm nil)
             (algorithm-params nil))
        (unless (and (zerop (getf bits :unused-bits)) key (plusp (length key)))
          (error 'tls-decode-error
                 :message "SubjectPublicKeyInfo key must be non-empty and octet-aligned"))
        (multiple-value-bind (base-algorithm parameter)
            (parse-algorithm-identifier-components algorithm-node)
          (case base-algorithm
            (:rsa-encryption
             (unless (asn1-null-p parameter)
               (error 'tls-decode-error
                      :message "rsaEncryption parameters must be NULL"))
             (parse-rsa-public-key-components key)
             (setf algorithm :rsa-encryption))
            (:rsassa-pss
             (when parameter
               (setf algorithm-params (parse-rsa-pss-params parameter)))
             (parse-rsa-public-key-components key)
             (setf algorithm :rsassa-pss))
            (:ec-public-key
             (unless (and parameter
                          (asn1-universal-primitive-p
                           parameter +asn1-object-identifier+))
               (error 'tls-decode-error
                      :message "EC public keys require an explicit named curve"))
             (setf algorithm (oid-name (asn1-node-value parameter)))
             (unless (member algorithm '(:prime256v1 :secp384r1 :secp521r1))
               (error 'tls-decode-error
                      :message "EC public key uses an unsupported named curve"))
             (validate-ec-public-point algorithm key))
            (:ed25519
             (when parameter
               (error 'tls-decode-error :message "Ed25519 parameters must be absent"))
             (unless (= (length key) 32)
               (error 'tls-decode-error :message "Ed25519 public key must be 32 octets"))
             (setf algorithm :ed25519))
            (:ed448
             (when parameter
               (error 'tls-decode-error :message "Ed448 parameters must be absent"))
             (unless (= (length key) 57)
               (error 'tls-decode-error :message "Ed448 public key must be 57 octets"))
             (setf algorithm :ed448))
            ((:mldsa44 :mldsa65 :mldsa87)
             (when parameter
               (error 'tls-decode-error :message "ML-DSA parameters must be absent"))
             (let ((expected (ecase base-algorithm
                               (:mldsa44 1312)
                               (:mldsa65 1952)
                               (:mldsa87 2592))))
               (unless (= (length key) expected)
                 (error 'tls-decode-error :message "ML-DSA public key has the wrong size")))
             (setf algorithm base-algorithm))
            (otherwise
             (error 'tls-decode-error
                    :message (format nil "Unsupported SubjectPublicKeyInfo algorithm: ~A"
                                     base-algorithm))))
          (list :algorithm algorithm
                :algorithm-params algorithm-params
                :algorithm-identifier-der (asn1-node-raw-bytes algorithm-node)
                :spki-der (asn1-node-raw-bytes node)
                :public-key key))))))

(defun parse-extensions-seq (node)
  "Parse a SEQUENCE of Extensions.
Per RFC 5280 Section 4.2: A certificate MUST NOT include more than one
instance of a particular extension."
  (let ((children (require-asn1-sequence node "Extensions"))
        (extensions nil)
        (seen-oids (make-hash-table :test 'equal)))
    (unless children
      (error 'tls-decode-error :message "Extensions SEQUENCE must not be empty"))
    (dolist (child children)
      (let* ((ext-children (require-asn1-sequence child "Extension"))
             (oid-node (first ext-children)))
        (unless (and (<= 2 (length ext-children) 3)
                     (asn1-universal-primitive-p
                      oid-node +asn1-object-identifier+))
          (error 'tls-decode-error
                 :message "Extension has an invalid field shape"))
        (let ((oid (asn1-node-value oid-node)))
        ;; Check for duplicate extensions
        (when (gethash oid seen-oids)
          (error 'tls-decode-error
                 :message (format nil "Duplicate extension: ~A" (oid-name oid))))
        (setf (gethash oid seen-oids) t)
        (push (parse-x509-extension child) extensions))))
    (nreverse extensions)))

(defun parse-x509-extension (node)
  "Parse a single Extension."
  (let ((children (require-asn1-sequence node "Extension")))
    (unless (and (<= 2 (length children) 3)
                 (asn1-universal-primitive-p
                  (first children) +asn1-object-identifier+))
      (error 'tls-decode-error
             :message "Extension must contain OID, optional critical TRUE, and OCTET STRING"))
    (let* ((oid (asn1-node-value (first children)))
           (critical-node (and (= (length children) 3) (second children)))
           (value-node (if critical-node (third children) (second children))))
      (when critical-node
        (unless (and (asn1-universal-primitive-p critical-node +asn1-boolean+)
                     (asn1-node-value critical-node))
          (error 'tls-decode-error
                 :message "Extension critical must be canonical TRUE; DEFAULT FALSE is omitted")))
      (unless (asn1-universal-primitive-p value-node +asn1-octet-string+)
        (error 'tls-decode-error
               :message "Extension extnValue must be a primitive OCTET STRING"))
      (make-x509-extension
       :oid (oid-name oid)
       :critical (not (null critical-node))
       :value (parse-extension-value oid (asn1-node-value value-node))))))

(defun parse-extension-value (oid value-bytes)
  "Parse extension value based on OID."
  (let ((name (oid-name oid)))
    (case name
      (:subject-alt-name
       (parse-subject-alt-name value-bytes))
      (:basic-constraints
       (parse-basic-constraints value-bytes))
      (:key-usage
       (parse-key-usage value-bytes))
      (:crl-distribution-points
       (parse-crl-distribution-points value-bytes))
      (:extended-key-usage
       (parse-extended-key-usage value-bytes))
      (otherwise
       ;; Return raw bytes for unknown extensions
       value-bytes))))

(defun parse-subject-alt-name (bytes)
  "Parse a DER SubjectAltName without accepting malformed GeneralNames."
  (let* ((node (parse-der bytes))
         (children (and node (asn1-sequence-p node) (asn1-children node)))
         (names nil))
    (unless (and children
                 (= (length (asn1-node-raw-bytes node)) (length bytes)))
      (error 'tls-decode-error
             :message "SubjectAltName must be a non-empty DER SEQUENCE"))
    (dolist (child children)
      (let ((tag (asn1-node-tag child))
            (value (asn1-node-value child)))
        (unless (and (= (asn1-node-class child) +asn1-class-context-specific+)
                     (<= 0 tag 8))
          (error 'tls-decode-error
                 :message "SubjectAltName contains an invalid GeneralName"))
        (case tag
          (2 ; dNSName
           (unless (and (not (asn1-node-constructed child))
                        (plusp (length value))
                        (every (lambda (octet) (< octet 128)) value))
             (error 'tls-decode-error :message "Malformed dNSName SAN"))
           (push (list :dns (octets-to-string value)) names))
          (7 ; iPAddress
           (unless (and (not (asn1-node-constructed child))
                        (member (length value) '(4 16)))
             (error 'tls-decode-error :message "Malformed iPAddress SAN"))
           (push (list :ip value) names))
          (1 ; rfc822Name
           (unless (and (not (asn1-node-constructed child))
                        (plusp (length value))
                        (every (lambda (octet) (< octet 128)) value))
             (error 'tls-decode-error :message "Malformed rfc822Name SAN"))
           (push (list :email (octets-to-string value)) names))
          (6 ; uniformResourceIdentifier
           (unless (and (not (asn1-node-constructed child))
                        (plusp (length value))
                        (every (lambda (octet) (< octet 128)) value))
             (error 'tls-decode-error
                    :message "Malformed uniformResourceIdentifier SAN"))
           (push (list :uri (octets-to-string value)) names))
          ;; The bounded profile understands and enforces only DNS, IP, email,
          ;; and URI GeneralNames.  Reject every unsupported choice instead of
          ;; silently treating a critical SAN as if its semantics were known.
          ((0 3 4 5 8)
           (error 'tls-decode-error
                  :message "SubjectAltName uses an unsupported GeneralName form")))))
    (nreverse names)))

(defun parse-basic-constraints (bytes)
  "Parse BasicConstraints and reject non-DER or invalid field combinations."
  (let* ((node (parse-der bytes))
         (children (and node (asn1-sequence-p node) (asn1-children node)))
         (ca nil)
         (path-len nil))
    (unless (and node
                 (asn1-sequence-p node)
                 (= (length (asn1-node-raw-bytes node)) (length bytes))
                 (<= (length children) 2))
      (error 'tls-decode-error
             :message "BasicConstraints must be a DER SEQUENCE of at most two fields"))
    (when children
      (when (and (= (asn1-node-class (first children)) +asn1-class-universal+)
                 (= (asn1-node-tag (first children)) +asn1-boolean+)
                 (not (asn1-node-constructed (first children))))
        ;; cA has DEFAULT FALSE, so DER requires the false value to be omitted.
        (unless (asn1-node-value (first children))
          (error 'tls-decode-error
                 :message "BasicConstraints must omit the default cA=FALSE value"))
        (setf ca (asn1-node-value (first children)))
        (setf children (rest children)))
      (when children
        (unless (and (= (length children) 1)
                     (= (asn1-node-class (first children)) +asn1-class-universal+)
                     (= (asn1-node-tag (first children)) +asn1-integer+)
                     (not (asn1-node-constructed (first children))))
          (error 'tls-decode-error :message "Malformed BasicConstraints fields"))
        (setf path-len (asn1-node-value (first children)))))
    (when (and path-len (or (not ca) (minusp path-len)))
      (error 'tls-decode-error
             :message "BasicConstraints pathLenConstraint requires cA=TRUE and a nonnegative value"))
    (list :ca ca :path-length-constraint path-len)))

(defun parse-key-usage (bytes)
  "Parse a DER KeyUsage BIT STRING and reject empty/malformed encodings."
  (let* ((node (parse-der bytes))
         (bits (and node (asn1-node-value node)))
         (unused (and (listp bits) (getf bits :unused-bits)))
         (data (and (listp bits) (getf bits :data)))
         (usages nil))
    ;; KeyUsage ::= BIT STRING { nine named bits }.  A present extension must
    ;; contain at least one asserted bit (RFC 5280 4.2.1.3).  Requiring the
    ;; exact universal primitive type and complete DER consumption prevents a
    ;; malformed extension from becoming NIL, which callers otherwise mistake
    ;; for an absent/unrestricted KeyUsage.
    (unless (and node
                 (= (asn1-node-class node) +asn1-class-universal+)
                 (= (asn1-node-tag node) +asn1-bit-string+)
                 (not (asn1-node-constructed node))
                 (= (length (asn1-node-raw-bytes node)) (length bytes))
                 (integerp unused)
                 data
                 (<= 1 (length data) 2))
      (error 'tls-decode-error
             :message "KeyUsage must be a non-empty DER BIT STRING of at most nine bits"))
    ;; Named-bit-list DER omits trailing zero bits.  A one-octet encoding's
    ;; unused-bit count must therefore equal the number of low zero bits; a
    ;; second octet is present only when decipherOnly itself is asserted.
    (if (= (length data) 1)
        (let* ((byte (aref data 0))
               (expected-unused
                 (loop for bit from 0 below 8
                       when (logbitp bit byte) return bit
                       finally (return 8))))
          (unless (= unused expected-unused)
            (error 'tls-decode-error
                   :message "KeyUsage BIT STRING is not minimally encoded")))
        (unless (and (= unused 7) (= (aref data 1) #x80))
          (error 'tls-decode-error
                 :message "KeyUsage contains bits outside the nine defined usages")))
    (let ((byte0 (aref data 0))
          (byte1 (if (> (length data) 1) (aref data 1) 0)))
      (when (logbitp 7 byte0) (push :digital-signature usages))
      (when (logbitp 6 byte0) (push :non-repudiation usages))
      (when (logbitp 5 byte0) (push :key-encipherment usages))
      (when (logbitp 4 byte0) (push :data-encipherment usages))
      (when (logbitp 3 byte0) (push :key-agreement usages))
      (when (logbitp 2 byte0) (push :key-cert-sign usages))
      (when (logbitp 1 byte0) (push :crl-sign usages))
      (when (logbitp 0 byte0) (push :encipher-only usages))
      (when (logbitp 7 byte1) (push :decipher-only usages)))
    (unless usages
      (error 'tls-decode-error
             :message "KeyUsage extension has no asserted usage bits"))
    ;; RFC 5280 4.2.1.3 defines encipherOnly and decipherOnly only when
    ;; keyAgreement is also asserted.  Treat either orphaned bit as malformed
    ;; rather than carrying an ambiguous permission into path validation.
    (when (and (or (member :encipher-only usages)
                   (member :decipher-only usages))
               (not (member :key-agreement usages)))
      (error 'tls-decode-error
             :message "KeyUsage encipherOnly/decipherOnly requires keyAgreement"))
    (nreverse usages)))

(defun parse-extended-key-usage (bytes)
  "Parse ExtendedKeyUsage extension value (RFC 5280 s4.2.1.12).
   ExtKeyUsageSyntax ::= SEQUENCE SIZE (1..MAX) OF KeyPurposeId
   KeyPurposeId ::= OBJECT IDENTIFIER
   Returns a list of purpose keywords (e.g. :server-auth, :client-auth,
   :any-extended-key-usage) or raw OID lists for unrecognized purposes."
  (let* ((node (parse-der bytes))
         (children (and node (asn1-sequence-p node) (asn1-children node))))
    ;; ExtKeyUsageSyntax is SEQUENCE SIZE (1..MAX) OF OBJECT IDENTIFIER.  Do
    ;; not collapse an empty/wrongly-typed/trailing-garbage encoding into NIL:
    ;; NIL is reserved for the genuinely absent and therefore unrestricted
    ;; extension.
    (unless (and children
                 (= (length (asn1-node-raw-bytes node)) (length bytes))
                 (every (lambda (child)
                          (and (= (asn1-node-class child) +asn1-class-universal+)
                               (= (asn1-node-tag child) +asn1-object-identifier+)
                               (not (asn1-node-constructed child))
                               (asn1-node-value child)))
                        children))
      (error 'tls-decode-error
             :message "ExtendedKeyUsage must contain at least one object identifier"))
    (loop for child in children
          collect (oid-name (asn1-node-value child)))))

(defun parse-crl-distribution-points (bytes)
  "Parse CRLDistributionPoints extension value (RFC 5280 s4.2.1.13).
   Returns a list of distribution point URIs.

   CRLDistributionPoints ::= SEQUENCE SIZE (1..MAX) OF DistributionPoint
   DistributionPoint ::= SEQUENCE {
       distributionPoint       [0]     DistributionPointName OPTIONAL,
       reasons                 [1]     ReasonFlags OPTIONAL,
       cRLIssuer               [2]     GeneralNames OPTIONAL }
   DistributionPointName ::= CHOICE {
       fullName                [0]     GeneralNames,
       nameRelativeToCRLIssuer [1]     RelativeDistinguishedName }"
  (let* ((node (parse-der bytes))
         (uris nil))
    (dolist (dp (asn1-children node))
      ;; Each DistributionPoint is a SEQUENCE
      (dolist (child (asn1-children dp))
        ;; Look for [0] distributionPoint
        (when (asn1-context-p child 0)
          ;; Inside distributionPoint, look for [0] fullName (GeneralNames)
          (dolist (dp-name-child (asn1-children child))
            (when (asn1-context-p dp-name-child 0)
              ;; GeneralNames is a SEQUENCE of GeneralName
              ;; Each GeneralName is context-tagged
              (dolist (general-name (asn1-children dp-name-child))
                ;; Tag 6 = uniformResourceIdentifier (URI)
                (when (and (= (asn1-node-class general-name) +asn1-class-context-specific+)
                           (= (asn1-node-tag general-name) 6))
                  (push (octets-to-string (asn1-node-value general-name)) uris))))))))
    (nreverse uris)))

;;;; Certificate Accessors

(defun certificate-subject-common-names (cert)
  "Get all Common Name values from the certificate subject."
  (loop for (oid . value) in (x509-name-rdns (x509-certificate-subject cert))
        when (eql oid :common-name)
          collect value))

(defun certificate-issuer-common-names (cert)
  "Get all Common Name values from the certificate issuer."
  (loop for (oid . value) in (x509-name-rdns (x509-certificate-issuer cert))
        when (eql oid :common-name)
          collect value))

(defun certificate-dns-names (cert)
  "Get all DNS names from Subject Alternative Name extension."
  (let ((san-ext (find :subject-alt-name (x509-certificate-extensions cert)
                       :key #'x509-extension-oid)))
    (when san-ext
      (loop for (type value) in (x509-extension-value san-ext)
            when (eql type :dns)
              collect value))))

(defun certificate-ip-addresses (cert)
  "Get all IP addresses from Subject Alternative Name extension.
   Returns a list of octet vectors (4 bytes for IPv4, 16 bytes for IPv6)."
  (let ((san-ext (find :subject-alt-name (x509-certificate-extensions cert)
                       :key #'x509-extension-oid)))
    (when san-ext
      (loop for (type value) in (x509-extension-value san-ext)
            when (eql type :ip)
              collect value))))

(defun certificate-not-before (cert)
  "Get the notBefore validity time as a universal-time."
  (x509-certificate-validity-not-before cert))

(defun certificate-not-after (cert)
  "Get the notAfter validity time as a universal-time."
  (x509-certificate-validity-not-after cert))

(defun certificate-fingerprint (cert &optional (algorithm :sha256))
  "Compute the fingerprint of the certificate."
  (ironclad:digest-sequence algorithm (x509-certificate-raw-der cert)))

(defun certificate-is-ca-p (cert)
  "Check if certificate is a CA certificate (BasicConstraints cA=true)."
  (let ((bc-ext (find :basic-constraints (x509-certificate-extensions cert)
                      :key #'x509-extension-oid)))
    (when bc-ext
      (getf (x509-extension-value bc-ext) :ca))))

(defun certificate-path-length-constraint (cert)
  "Get the path length constraint from BasicConstraints, or NIL if not set."
  (let ((bc-ext (find :basic-constraints (x509-certificate-extensions cert)
                      :key #'x509-extension-oid)))
    (when bc-ext
      (getf (x509-extension-value bc-ext) :path-length-constraint))))

(defun certificate-key-usage (cert)
  "Get the KeyUsage extension value as a list of keywords, or NIL if not present.
   Possible values: :digital-signature, :non-repudiation, :key-encipherment,
   :data-encipherment, :key-agreement, :key-cert-sign, :crl-sign,
   :encipher-only, :decipher-only."
  (let ((ku-ext (find :key-usage (x509-certificate-extensions cert)
                      :key #'x509-extension-oid)))
    (when ku-ext
      (x509-extension-value ku-ext))))

(defun certificate-crl-distribution-points (cert)
  "Get the CRL Distribution Points URIs from the certificate.
   Returns a list of URI strings where CRLs can be fetched, or NIL if not present."
  (let ((cdp-ext (find :crl-distribution-points (x509-certificate-extensions cert)
                       :key #'x509-extension-oid)))
    (when cdp-ext
      (x509-extension-value cdp-ext))))

(defun certificate-extended-key-usages (cert)
  "Get the ExtendedKeyUsage purposes as a list of keywords (or raw OID lists
   for unrecognized purposes), or NIL if the certificate has no EKU extension.
   Per RFC 5280, the absence of this extension means the certificate is not
   restricted to any particular purpose."
  (let ((eku-ext (find :extended-key-usage (x509-certificate-extensions cert)
                       :key #'x509-extension-oid)))
    (when eku-ext
      (x509-extension-value eku-ext))))

(defun certificate-valid-for-purpose-p (cert purpose)
  "Return T if CERT may be used for PURPOSE (e.g. :server-auth, :client-auth).
   A certificate with no ExtendedKeyUsage extension is unrestricted and is
   valid for any purpose (RFC 5280 s4.2.1.12).  When EKU is present, the
   certificate is valid for PURPOSE only if PURPOSE or anyExtendedKeyUsage is
   listed."
  (let* ((extension (find :extended-key-usage
                          (x509-certificate-extensions cert)
                          :key #'x509-extension-oid))
         (ekus (and extension (x509-extension-value extension))))
    (or (null extension)
        (member :any-extended-key-usage ekus)
        (member purpose ekus))))

(defun certificate-key-usage-valid-for-purpose-p (cert purpose)
  "Return true when CERT's KeyUsage permits PURPOSE in the supported TLS profile.
TLS 1.3 and Clun's TLS 1.2 ECDHE suites authenticate peers with signatures, so
a present server/client-auth KeyUsage must assert digitalSignature.  An absent
extension remains unrestricted."
  (let ((usages (certificate-key-usage cert)))
    (or (not (certificate-has-extension-p cert :key-usage))
        (not (member purpose '(:server-auth :client-auth)))
        (member :digital-signature usages))))

(defun certificate-has-extension-p (cert oid)
  "Return true when CERT contains extension OID, regardless of criticality."
  (not (null (find oid (x509-certificate-extensions cert)
                   :key #'x509-extension-oid :test #'equal))))

(defun certificate-has-key-usage-p (cert usage)
  "Check if certificate has a specific key usage bit set.
   USAGE is a keyword like :key-cert-sign or :digital-signature."
  (member usage (certificate-key-usage cert)))

(defun certificate-can-sign-certificates-p (cert)
  "Check if certificate can sign other certificates.
   Requires BasicConstraints cA=true AND KeyUsage keyCertSign (if KeyUsage present)."
  (and (certificate-is-ca-p cert)
       ;; If KeyUsage extension is present, keyCertSign must be set
       ;; If KeyUsage is absent, we allow signing (per RFC 5280 - absence means all usages)
       (let ((key-usage (certificate-key-usage cert)))
         (or (not (certificate-has-extension-p cert :key-usage))
             (member :key-cert-sign key-usage)))))

(defun certificate-critical-extensions (cert)
  "Get list of critical extensions from the certificate."
  (loop for ext in (x509-certificate-extensions cert)
        when (x509-extension-critical ext)
          collect (x509-extension-oid ext)))

(defun certificate-has-unknown-critical-extensions-p (cert)
  "Return critical extension OIDs whose semantics this verifier does not enforce."
  (loop for ext in (x509-certificate-extensions cert)
        when (and (x509-extension-critical ext)
                  (not (enforced-critical-certificate-extension-p
                        (x509-extension-oid ext))))
          collect (x509-extension-oid ext)))

;;;; Certificate Loading

(defun parse-certificate-from-file (path)
  "Load and parse a certificate from a file.
   Supports DER and PEM formats."
  (let ((bytes (read-file-bytes path)))
    (if (pem-encoded-p bytes)
        (parse-certificate (pem-decode bytes "CERTIFICATE"))
        (parse-certificate bytes))))

(defun read-file-bytes (path)
  "Read file contents as octet vector."
  (with-open-file (stream path :element-type '(unsigned-byte 8))
    (let ((bytes (make-octet-vector (file-length stream))))
      (read-sequence bytes stream)
      bytes)))

(defun pem-encoded-p (bytes)
  "Check if bytes look like PEM encoding.
   Handles files that start with comments before the PEM block."
  (and (>= (length bytes) 27)  ; Length of -----BEGIN CERTIFICATE-----
       (let ((text (octets-to-string bytes)))
         (search "-----BEGIN" text))))

(defun pem-decode (bytes label)
  "Decode PEM-encoded data, extracting the block with the given LABEL."
  (let* ((text (octets-to-string bytes))
         (begin-marker (format nil "-----BEGIN ~A-----" label))
         (end-marker (format nil "-----END ~A-----" label))
         (begin-pos (search begin-marker text))
         (end-pos (search end-marker text)))
    (unless (and begin-pos end-pos)
      (error 'tls-decode-error :message (format nil "PEM block '~A' not found" label)))
    (let* ((base64-start (+ begin-pos (length begin-marker)))
           (base64-text (subseq text base64-start end-pos))
           ;; Remove whitespace
           (clean-base64 (remove-if (lambda (c) (member c '(#\Newline #\Return #\Space)))
                                    base64-text)))
      (base64-decode clean-base64))))

(defun base64-decode (string)
  "Decode a Base64-encoded string to octets."
  (cl-base64:base64-string-to-usb8-array string))
