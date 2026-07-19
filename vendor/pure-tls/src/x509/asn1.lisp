;;; asn1.lisp --- ASN.1/DER Parser for X.509 Certificates
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Anthony Green <green@moxielogic.com>
;;;
;;; Implements ASN.1 DER (Distinguished Encoding Rules) parsing
;;; for X.509 certificate processing.

(in-package #:pure-tls)

;;;; ASN.1 Tag Classes and Types

(defconstant +asn1-class-universal+ 0)
(defconstant +asn1-class-application+ 1)
(defconstant +asn1-class-context-specific+ 2)
(defconstant +asn1-class-private+ 3)

;; Universal tags
(defconstant +asn1-boolean+ 1)
(defconstant +asn1-integer+ 2)
(defconstant +asn1-bit-string+ 3)
(defconstant +asn1-octet-string+ 4)
(defconstant +asn1-null+ 5)
(defconstant +asn1-object-identifier+ 6)
(defconstant +asn1-utf8-string+ 12)
(defconstant +asn1-sequence+ 16)
(defconstant +asn1-set+ 17)
(defconstant +asn1-printable-string+ 19)
(defconstant +asn1-ia5-string+ 22)
(defconstant +asn1-utc-time+ 23)
(defconstant +asn1-generalized-time+ 24)

;;;; ASN.1 Node Structure

(defstruct asn1-node
  "An ASN.1 parsed node."
  (class +asn1-class-universal+ :type fixnum)
  (constructed nil :type boolean)
  (tag 0 :type fixnum)
  (value nil)
  ;; Length of the node's DER contents octets (excluding identifier/length).
  (content-length 0 :type fixnum)
  ;; For raw access
  (raw-bytes nil :type (or null octet-vector)))

;;;; DER Parsing

(defconstant +maximum-der-input-size+ (* 1024 1024)
  "Maximum DER object size accepted by the bounded certificate parser.")

(defconstant +maximum-der-nesting-depth+ 32
  "Maximum constructed-node nesting depth accepted by the DER parser.")

(defconstant +maximum-der-node-count+ 4096
  "Maximum ASN.1 nodes accepted in one DER object.")

(defun parse-der (data)
  "Parse DER-encoded data into an ASN1-NODE tree.
   DATA should be an octet vector."
  (unless (typep data 'octet-vector)
    (error 'tls-decode-error :message "DER input must be an octet vector"))
  (when (> (length data) +maximum-der-input-size+)
    (error 'tls-decode-error :message "DER object exceeds the configured size bound"))
  (let ((buf (make-tls-buffer data)))
    (when (zerop (buffer-remaining buf))
      (error 'tls-decode-error :message "DER object must not be empty"))
    (let ((node (parse-der-node buf 0 (vector 0))))
      (when (plusp (buffer-remaining buf))
        (error 'tls-decode-error
               :message "DER object contains trailing data"))
      node)))

(defun parse-der-node (buf &optional (depth 0) (parse-state (vector 0)))
  "Parse a single DER node from the buffer."
  (when (zerop (buffer-remaining buf))
    (return-from parse-der-node nil))
  (when (> depth +maximum-der-nesting-depth+)
    (error 'tls-decode-error :message "DER nesting depth exceeds the configured bound"))
  (incf (aref parse-state 0))
  (when (> (aref parse-state 0) +maximum-der-node-count+)
    (error 'tls-decode-error :message "DER node count exceeds the configured bound"))
  (let* ((start-pos (tls-buffer-position buf))
         ;; Parse identifier octet
         (id-byte (buffer-read-octet buf))
         (class (ldb (byte 2 6) id-byte))
         (constructed (logbitp 5 id-byte))
         (tag (ldb (byte 5 0) id-byte)))
    ;; Handle long-form tags
    (when (= tag 31)
      (let ((first-tag-octet t)
            (tag-octets 0))
        (setf tag 0)
        (loop for b = (buffer-read-octet buf)
              do (incf tag-octets)
                 (when (> tag-octets 4)
                   (error 'tls-decode-error
                          :message "DER high-tag-number exceeds the configured bound"))
                 (when (and first-tag-octet (= b #x80))
                   (error 'tls-decode-error
                          :message "DER high-tag-number form is not minimal"))
                 (setf first-tag-octet nil
                       tag (logior (ash tag 7) (logand b #x7f)))
              while (logbitp 7 b)))
      (when (< tag 31)
        (error 'tls-decode-error
               :message "DER high-tag-number form used for a short tag")))
    ;; DER uses constructed encoding for SEQUENCE/SET and primitive encoding
    ;; for the universal scalar/string types accepted by this X.509 profile.
    ;; Rejecting the opposite forms here prevents schema helpers from ever
    ;; interpreting a constructed scalar or primitive container ambiguously.
    (when (= class +asn1-class-universal+)
      (if (member tag (list +asn1-sequence+ +asn1-set+))
          (unless constructed
            (error 'tls-decode-error
                   :message "DER SEQUENCE/SET must use constructed encoding"))
          (when constructed
            (error 'tls-decode-error
                   :message "DER universal scalar must use primitive encoding"))))
    ;; Parse length
    (let ((length (parse-der-length buf)))
      (when (null length)
        (error 'tls-decode-error :message "Indefinite length not supported in DER"))
      (when (> length (buffer-remaining buf))
        (error 'tls-decode-error
               :message "DER value exceeds its enclosing object"))
      ;; Parse value
      (let* ((value (if constructed
                        ;; Parse contained elements
                        (parse-der-contents buf length (1+ depth) parse-state)
                        ;; Primitive: read raw bytes
                        (buffer-read-octets buf length)))
             (end-pos (tls-buffer-position buf))
             (raw (subseq (tls-buffer-data buf) start-pos end-pos)))
        (make-asn1-node :class class
                        :constructed constructed
                        :tag tag
                        :content-length length
                        :value (if constructed
                                   value
                                   (decode-primitive-value class tag value))
                        :raw-bytes raw)))))

(defun parse-der-length (buf)
  "Parse DER length field. Returns nil for indefinite length."
  (let ((first-byte (buffer-read-octet buf)))
    (cond
      ;; Short form: length < 128
      ((not (logbitp 7 first-byte))
       first-byte)
      ;; Indefinite length (not valid in DER)
      ((zerop (logand first-byte #x7f))
       nil)
      ;; Long form
      (t
       (let ((num-octets (logand first-byte #x7f))
             (length 0)
             (first-length-octet nil))
         (dotimes (i num-octets)
           (let ((octet (buffer-read-octet buf)))
             (when (zerop i)
               (setf first-length-octet octet))
             (setf length (logior (ash length 8) octet))))
         ;; DER requires the shortest definite-length encoding: no leading
         ;; zero length octet and no long form for values below 128.
         (when (zerop first-length-octet)
           (error 'tls-decode-error
                  :message "DER length has a redundant leading zero"))
         (when (< length 128)
           (error 'tls-decode-error
                  :message "DER length uses non-minimal long form"))
         length)))))

(defun parse-der-contents (buf length &optional (depth 1) (parse-state (vector 0)))
  "Parse the contents of a constructed type."
  ;; Parse inside a length-bounded child buffer.  A child can therefore never
  ;; consume bytes belonging to its parent or a following sibling.
  (let* ((contents (buffer-read-octets buf length))
         (child-buffer (make-tls-buffer contents))
         (nodes nil))
    (loop while (plusp (buffer-remaining child-buffer))
          do (push (parse-der-node child-buffer depth parse-state) nodes))
    (nreverse nodes)))

(defun decode-primitive-value (class tag raw-bytes)
  "Decode a primitive ASN.1 value."
  (if (= class +asn1-class-universal+)
      (case tag
        (#.+asn1-boolean+
         ;; X.690 DER canonical form: BOOLEAN has exactly one contents octet;
         ;; FALSE is 00 and TRUE is FF.  BER's other nonzero true values are
         ;; not valid DER and must not silently enable a certificate flag.
         (unless (= (length raw-bytes) 1)
           (error 'tls-decode-error
                  :message "BOOLEAN must contain exactly one octet"))
         (case (aref raw-bytes 0)
           (#x00 nil)
           (#xff t)
           (otherwise
            (error 'tls-decode-error
                   :message "BOOLEAN is not canonically encoded for DER"))))
        (#.+asn1-integer+
         (decode-der-integer raw-bytes))
        (#.+asn1-bit-string+
         ;; First byte is unused bits count
         ;; Per DER (X.690): unused bits in last byte must be zero
         (when (zerop (length raw-bytes))
           (error 'tls-decode-error
                  :message "BIT STRING must contain an unused-bits octet"))
         (let ((unused-bits (aref raw-bytes 0)))
           (when (> unused-bits 7)
             (error 'tls-decode-error
                    :message "BIT STRING unused bits count must be 0-7"))
           (when (and (plusp unused-bits) (= (length raw-bytes) 1))
             (error 'tls-decode-error
                    :message "Empty BIT STRING cannot declare unused bits"))
           (when (and (> unused-bits 0) (> (length raw-bytes) 1))
             (let* ((last-byte (aref raw-bytes (1- (length raw-bytes))))
                    (mask (1- (ash 1 unused-bits))))  ; e.g., unused=1 -> mask=1
               (unless (zerop (logand last-byte mask))
                 (error 'tls-decode-error
                        :message "BIT STRING has non-zero padding bits (invalid DER)"))))
           (list :unused-bits unused-bits
                 :data (subseq raw-bytes 1))))
        (#.+asn1-octet-string+
         raw-bytes)
        (#.+asn1-null+
         (unless (zerop (length raw-bytes))
           (error 'tls-decode-error :message "NULL must have zero length"))
         nil)
        (#.+asn1-object-identifier+
         (decode-der-oid raw-bytes))
        ((#.+asn1-utf8-string+ #.+asn1-printable-string+ #.+asn1-ia5-string+)
         (octets-to-string raw-bytes))
        (#.+asn1-utc-time+
         (decode-utc-time (octets-to-string raw-bytes)))
        (#.+asn1-generalized-time+
         (decode-generalized-time (octets-to-string raw-bytes)))
        (otherwise raw-bytes))
      ;; For non-universal, return raw bytes
      raw-bytes))

;;;; Integer Decoding

(defun decode-der-integer (bytes)
  "Decode a DER-encoded integer (two's complement, big-endian).
Per DER (X.690): integers must be minimally encoded."
  (when (zerop (length bytes))
    (error 'tls-decode-error :message "INTEGER must have at least one byte"))
  ;; Check for non-minimal encoding (leading 0x00 or 0xFF that isn't needed)
  (when (>= (length bytes) 2)
    (let ((first (aref bytes 0))
          (second (aref bytes 1)))
      ;; Leading 0x00 is only valid if next byte has high bit set (positive number)
      (when (and (zerop first) (not (logbitp 7 second)))
        (error 'tls-decode-error
               :message "INTEGER has non-minimal encoding (unnecessary leading zero)"))
      ;; Leading 0xFF is only valid if next byte has high bit clear (negative number)
      (when (and (= first #xff) (logbitp 7 second))
        (error 'tls-decode-error
               :message "INTEGER has non-minimal encoding (unnecessary leading 0xFF)"))))
  (let ((value 0)
        (negative (logbitp 7 (aref bytes 0))))
    (loop for byte across bytes
          do (setf value (logior (ash value 8) byte)))
    (if negative
        (- value (ash 1 (* 8 (length bytes))))
        value)))

;;;; OID Decoding

(defun decode-der-oid (bytes)
  "Decode a DER-encoded Object Identifier."
  (when (zerop (length bytes))
    (error 'tls-decode-error :message "OBJECT IDENTIFIER must not be empty"))
  ;; Every subidentifier, including the combined first two arcs, uses base-128
  ;; variable-length encoding.  Reject truncated and non-minimal encodings;
  ;; otherwise a malformed EKU OID could be silently decoded as a shorter,
  ;; different purpose.
  (let ((subidentifiers nil)
        (value 0)
        (first-octet-p t))
    (loop for byte across bytes
          do (when (and first-octet-p (= byte #x80))
               (error 'tls-decode-error
                      :message "OBJECT IDENTIFIER has a non-minimal subidentifier"))
             (setf value (logior (ash value 7) (logand byte #x7f)))
             (if (logbitp 7 byte)
                 (setf first-octet-p nil)
                 (progn
                   (push value subidentifiers)
                   (setf value 0
                         first-octet-p t))))
    (unless first-octet-p
      (error 'tls-decode-error
             :message "OBJECT IDENTIFIER ends in a truncated subidentifier"))
    (setf subidentifiers (nreverse subidentifiers))
    (let ((first (first subidentifiers)))
      (cond
        ((< first 40)
         (list* 0 first (rest subidentifiers)))
        ((< first 80)
         (list* 1 (- first 40) (rest subidentifiers)))
        (t
         (list* 2 (- first 80) (rest subidentifiers)))))))

(defun oid-to-string (oid)
  "Convert an OID list to dotted string notation."
  (format nil "~{~D~^.~}" oid))

(defun string-to-oid (string)
  "Convert a dotted string to an OID list."
  (mapcar #'parse-integer (split-string string #\.)))

(defun split-string (string delimiter)
  "Split STRING by DELIMITER character."
  (loop for start = 0 then (1+ pos)
        for pos = (position delimiter string :start start)
        collect (subseq string start (or pos (length string)))
        while pos))

;;;; Time Decoding

(defun decimal-time-string-p (string end)
  "Return true when STRING[0,END) contains only ASCII decimal digits."
  (and (>= (length string) end)
       (loop for index below end
             for char = (char string index)
             always (char<= #\0 char #\9))))

(defun leap-year-p (year)
  (and (zerop (mod year 4))
       (or (not (zerop (mod year 100)))
           (zerop (mod year 400)))))

(defun days-in-month (month year)
  (case month
    ((1 3 5 7 8 10 12) 31)
    ((4 6 9 11) 30)
    (2 (if (leap-year-p year) 29 28))
    (otherwise 0)))

(defun encode-rfc5280-time (year month day hour minute second)
  "Validate calendar fields and encode an RFC 5280 UTC instant."
  (unless (and (<= 1 month 12)
               (<= 1 day (days-in-month month year))
               (<= 0 hour 23)
               (<= 0 minute 59)
               (<= 0 second 59))
    (error 'tls-decode-error :message "Certificate time has invalid calendar fields"))
  (handler-case
      (encode-universal-time second minute hour day month year 0)
    (error ()
      (error 'tls-decode-error :message "Certificate time is outside the supported range"))))

(defun decode-utc-time (string)
  "Decode the exact RFC 5280 UTCTime form YYMMDDHHMMSSZ."
  (unless (and (= (length string) 13)
               (decimal-time-string-p string 12)
               (char= (char string 12) #\Z))
    (error 'tls-decode-error
           :message "UTCTime must use the exact YYMMDDHHMMSSZ form"))
  (let* ((short-year (parse-integer string :start 0 :end 2))
         (year (+ short-year (if (< short-year 50) 2000 1900))))
    (encode-rfc5280-time
     year
     (parse-integer string :start 2 :end 4)
     (parse-integer string :start 4 :end 6)
     (parse-integer string :start 6 :end 8)
     (parse-integer string :start 8 :end 10)
     (parse-integer string :start 10 :end 12))))

(defun decode-generalized-time (string)
  "Decode the exact RFC 5280 GeneralizedTime form YYYYMMDDHHMMSSZ."
  (unless (and (= (length string) 15)
               (decimal-time-string-p string 14)
               (char= (char string 14) #\Z))
    (error 'tls-decode-error
           :message "GeneralizedTime must use the exact YYYYMMDDHHMMSSZ form"))
  (let ((year (parse-integer string :start 0 :end 4)))
    (unless (>= year 2050)
      (error 'tls-decode-error
             :message "Dates through 2049 must use UTCTime in RFC 5280 certificates"))
    (encode-rfc5280-time
     year
     (parse-integer string :start 4 :end 6)
     (parse-integer string :start 6 :end 8)
     (parse-integer string :start 8 :end 10)
     (parse-integer string :start 10 :end 12)
     (parse-integer string :start 12 :end 14))))

;;;; ASN.1 Navigation Utilities

(defun asn1-sequence-p (node)
  "Check if node is a SEQUENCE."
  (and (= (asn1-node-class node) +asn1-class-universal+)
       (= (asn1-node-tag node) +asn1-sequence+)
       (asn1-node-constructed node)))

(defun asn1-set-p (node)
  "Check if node is a SET."
  (and (= (asn1-node-class node) +asn1-class-universal+)
       (= (asn1-node-tag node) +asn1-set+)
       (asn1-node-constructed node)))

(defun asn1-context-p (node tag)
  "Check if node is context-specific with given tag."
  (and (= (asn1-node-class node) +asn1-class-context-specific+)
       (= (asn1-node-tag node) tag)))

(defun asn1-get-child (node index)
  "Get child at index from a constructed node."
  (when (asn1-node-constructed node)
    (nth index (asn1-node-value node))))

(defun asn1-children (node)
  "Get all children of a constructed node."
  (when (asn1-node-constructed node)
    (asn1-node-value node)))

(defun asn1-find-child (node class tag)
  "Find first child with given class and tag."
  (find-if (lambda (child)
             (and (= (asn1-node-class child) class)
                  (= (asn1-node-tag child) tag)))
           (asn1-children node)))

;;;; Well-Known OIDs

(defparameter *well-known-oids*
  '(;; X.500 AttributeTypes
    ((2 5 4 3) . :common-name)
    ((2 5 4 6) . :country-name)
    ((2 5 4 7) . :locality-name)
    ((2 5 4 8) . :state-or-province-name)
    ((2 5 4 10) . :organization-name)
    ((2 5 4 11) . :organizational-unit-name)
    ;; X.509 Extensions
    ((2 5 29 14) . :subject-key-identifier)
    ((2 5 29 15) . :key-usage)
    ((2 5 29 17) . :subject-alt-name)
    ((2 5 29 19) . :basic-constraints)
    ;; These policy/path OIDs are named for diagnostics only.  The certificate
    ;; verifier's separately centralized enforced-critical set deliberately
    ;; excludes them until their cumulative path semantics are implemented.
    ((2 5 29 30) . :name-constraints)
    ((2 5 29 31) . :crl-distribution-points)
    ((2 5 29 32) . :certificate-policies)
    ((2 5 29 33) . :policy-mappings)
    ((2 5 29 35) . :authority-key-identifier)
    ((2 5 29 36) . :policy-constraints)
    ((2 5 29 37) . :extended-key-usage)
    ((2 5 29 54) . :inhibit-any-policy)
    ;; Extended Key Usage purposes (RFC 5280 s4.2.1.12)
    ((2 5 29 37 0) . :any-extended-key-usage)
    ((1 3 6 1 5 5 7 3 1) . :server-auth)
    ((1 3 6 1 5 5 7 3 2) . :client-auth)
    ((1 3 6 1 5 5 7 3 3) . :code-signing)
    ((1 3 6 1 5 5 7 3 4) . :email-protection)
    ((1 3 6 1 5 5 7 3 8) . :time-stamping)
    ((1 3 6 1 5 5 7 3 9) . :ocsp-signing)
    ;; Authority Information Access (RFC 5280)
    ((1 3 6 1 5 5 7 1 1) . :authority-info-access)
    ((1 3 6 1 5 5 7 48 1) . :ocsp)
    ((1 3 6 1 5 5 7 48 2) . :ca-issuers)
    ;; Signature Algorithms
    ((1 2 840 113549 1 1 1) . :rsa-encryption)
    ((1 2 840 113549 1 1 5) . :sha1-with-rsa-encryption)
    ((1 2 840 113549 1 1 11) . :sha256-with-rsa-encryption)
    ((1 2 840 113549 1 1 12) . :sha384-with-rsa-encryption)
    ((1 2 840 113549 1 1 13) . :sha512-with-rsa-encryption)
    ((1 2 840 113549 1 1 8) . :mgf1)
    ((1 2 840 10045 4 3 2) . :ecdsa-with-sha256)
    ((1 2 840 10045 4 3 3) . :ecdsa-with-sha384)
    ((1 2 840 10045 4 3 4) . :ecdsa-with-sha512)
    ;; EC Public Key
    ((1 2 840 10045 2 1) . :ec-public-key)
    ;; EC Curves
    ((1 2 840 10045 3 1 7) . :prime256v1)
    ((1 3 132 0 34) . :secp384r1)
    ((1 3 132 0 35) . :secp521r1)
    ;; EdDSA Keys (RFC 8410)
    ((1 3 101 112) . :ed25519)
    ((1 3 101 113) . :ed448)
    ;; RSA-PSS (RFC 4055)
    ((1 2 840 113549 1 1 10) . :rsassa-pss)
    ;; Digest algorithms used by RSASSA-PSS parameters
    ((1 3 14 3 2 26) . :sha1)
    ((2 16 840 1 101 3 4 2 1) . :sha256)
    ((2 16 840 1 101 3 4 2 2) . :sha384)
    ((2 16 840 1 101 3 4 2 3) . :sha512)
    ;; ML-DSA (FIPS 204 Post-Quantum Signatures)
    ((2 16 840 1 101 3 4 3 17) . :mldsa44)
    ((2 16 840 1 101 3 4 3 18) . :mldsa65)
    ((2 16 840 1 101 3 4 3 19) . :mldsa87))
  "Mapping of well-known OIDs to symbolic names.")

(defun oid-name (oid)
  "Get the symbolic name for an OID, or the OID itself if unknown."
  (or (rest (assoc oid *well-known-oids* :test #'equal))
      oid))
