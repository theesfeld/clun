;;;; tls12-client.lisp -- bounded TLS 1.2 client transport for Phase 28.
;;;;
;;;; pure-tls provides the preferred TLS 1.3 path. Some production endpoints,
;;;; including registry.npmjs.org at the Phase-28 observation date, negotiate
;;;; TLS 1.2 only. This file implements the narrow interoperable TLS 1.2 client
;;;; profile needed by HTTP/1.1 without foreign libraries: authenticated
;;;; ECDHE (P-256), ECDSA/RSA signatures, AES-128-GCM records, EMS, SNI, ALPN,
;;;; system-root chain verification, hostname verification, and Finished
;;;; verification. It deliberately has no renegotiation or session resumption.

(in-package :clun.net)

(define-condition tls12-error (error)
  ((message :initarg :message :reader tls12-error-message))
  (:report (lambda (condition stream)
             (write-string (tls12-error-message condition) stream))))

(defconstant +tls12-change-cipher-spec+ 20)
(defconstant +tls12-alert+ 21)
(defconstant +tls12-handshake+ 22)
(defconstant +tls12-application-data+ 23)
(defconstant +tls12-version+ #x0303)
(defconstant +tls12-suite-ecdhe-ecdsa-aes128-gcm-sha256+ #xc02b)
(defconstant +tls12-suite-ecdhe-rsa-aes128-gcm-sha256+ #xc02f)
(defconstant +tls12-fallback-scsv+ #x5600)
(defconstant +tls12-max-plaintext+ 16384)
(defconstant +tls12-max-ciphertext+ (+ +tls12-max-plaintext+ 2048))
(defconstant +tls12-max-handshake-message+ (* 16 1024 1024))

(defstruct (tls12-state (:conc-name tls12-))
  stream
  client-random server-random
  client-key server-key client-iv server-iv
  (client-sequence 0 :type (unsigned-byte 64))
  (server-sequence 0 :type (unsigned-byte 64))
  (transcript (make-array 0 :element-type '(unsigned-byte 8)))
  (handshake-buffer (make-array 4096 :element-type '(unsigned-byte 8)
                                     :adjustable t :fill-pointer 0))
  (client-encrypted-p nil)
  (server-encrypted-p nil)
  (closed-p nil))

(defun %tls12-fail (control &rest arguments)
  (error 'tls12-error :message (apply #'format nil control arguments)))

(defun %tls12-cat (&rest vectors)
  (let* ((length (reduce #'+ vectors :key #'length :initial-value 0))
         (result (make-array length :element-type '(unsigned-byte 8)))
         (offset 0))
    (dolist (vector vectors result)
      (replace result vector :start1 offset)
      (incf offset (length vector)))))

(defun %tls12-append-bounded (buffer octets limit message)
  "Append OCTETS to an adjustable octet BUFFER with geometric growth."
  (let* ((old (fill-pointer buffer))
         (new (+ old (length octets))))
    (when (> new limit)
      (%tls12-fail "~a" message))
    (when (> new (array-total-size buffer))
      (adjust-array buffer
                    (min limit (max new (* 2 (array-total-size buffer))))
                    :fill-pointer old))
    (setf (fill-pointer buffer) new)
    (replace buffer octets :start1 old)
    buffer))

(defun %tls12-u8 (value)
  (make-array 1 :element-type '(unsigned-byte 8)
                :initial-element (logand value #xff)))

(defun %tls12-u16 (value)
  (make-array 2 :element-type '(unsigned-byte 8)
                :initial-contents (list (ldb (byte 8 8) value)
                                        (ldb (byte 8 0) value))))

(defun %tls12-u24 (value)
  (make-array 3 :element-type '(unsigned-byte 8)
                :initial-contents (list (ldb (byte 8 16) value)
                                        (ldb (byte 8 8) value)
                                        (ldb (byte 8 0) value))))

(defun %tls12-u64 (value)
  (let ((result (make-array 8 :element-type '(unsigned-byte 8))))
    (dotimes (index 8 result)
      (setf (aref result index) (ldb (byte 8 (* 8 (- 7 index))) value)))))

(defun %tls12-read-u16 (octets offset)
  (when (> (+ offset 2) (length octets))
    (%tls12-fail "truncated uint16"))
  (logior (ash (aref octets offset) 8) (aref octets (1+ offset))))

(defun %tls12-read-u24 (octets offset)
  (when (> (+ offset 3) (length octets))
    (%tls12-fail "truncated uint24"))
  (logior (ash (aref octets offset) 16)
          (ash (aref octets (+ offset 1)) 8)
          (aref octets (+ offset 2))))

(defun %tls12-ascii (string)
  (let ((result (make-array (length string) :element-type '(unsigned-byte 8))))
    (dotimes (index (length string) result)
      (let ((code (char-code (char string index))))
        (unless (< code 128)
          (%tls12-fail "TLS 1.2 SNI hostname is not ASCII"))
        (setf (aref result index) code)))))

(defun %tls12-vector16 (octets)
  (when (> (length octets) #xffff)
    (%tls12-fail "TLS vector16 exceeds 65535 bytes"))
  (%tls12-cat (%tls12-u16 (length octets)) octets))

(defun %tls12-extension (type data)
  (%tls12-cat (%tls12-u16 type) (%tls12-vector16 data)))

(defun %tls12-handshake-message (type body)
  (%tls12-cat (%tls12-u8 type) (%tls12-u24 (length body)) body))

(defun %tls12-append-transcript (state message)
  (setf (tls12-transcript state)
        (%tls12-cat (tls12-transcript state) message)))

(defun %tls12-digest (octets &optional (algorithm :sha256))
  (let ((digest (ironclad:make-digest algorithm)))
    (ironclad:update-digest digest octets)
    (ironclad:produce-digest digest)))

(defun %tls12-hmac (secret data &optional (algorithm :sha256))
  (let ((hmac (ironclad:make-hmac secret algorithm)))
    (ironclad:update-hmac hmac data)
    (ironclad:hmac-digest hmac)))

(defun %tls12-prf (secret label seed length &optional (algorithm :sha256))
  "TLS 1.2 P_hash PRF from RFC 5246 section 5."
  (let* ((full-seed (%tls12-cat (%tls12-ascii label) seed))
         (a (%tls12-hmac secret full-seed algorithm))
         (result (make-array length :element-type '(unsigned-byte 8)))
         (offset 0))
    (loop while (< offset length) do
      (let* ((block (%tls12-hmac secret (%tls12-cat a full-seed) algorithm))
             (count (min (length block) (- length offset))))
        (replace result block :start1 offset :end2 count)
        (incf offset count)
        (setf a (%tls12-hmac secret a algorithm))))
    result))

(defun %tls12-read-exactly (stream length &key eof-ok)
  (let ((result (make-array length :element-type '(unsigned-byte 8)))
        (offset 0))
    (loop while (< offset length) do
      (let ((end (read-sequence result stream :start offset)))
        (when (= end offset)
          (if (and eof-ok (zerop offset))
              (return-from %tls12-read-exactly nil)
              (%tls12-fail "truncated TLS record")))
        (setf offset end)))
    result))

(defun %tls12-write-plain-record (state type payload)
  (when (> (length payload) +tls12-max-plaintext+)
    (%tls12-fail "TLS plaintext record exceeds ~d bytes" +tls12-max-plaintext+))
  (write-sequence
   (%tls12-cat (%tls12-u8 type) (%tls12-u16 +tls12-version+)
               (%tls12-u16 (length payload)) payload)
   (tls12-stream state))
  (force-output (tls12-stream state)))

(defun %tls12-aad (sequence type plaintext-length)
  (%tls12-cat (%tls12-u64 sequence) (%tls12-u8 type)
              (%tls12-u16 +tls12-version+) (%tls12-u16 plaintext-length)))

(defun %tls12-encrypt-record (state type plaintext)
  (let* ((sequence (tls12-client-sequence state))
         (explicit (%tls12-u64 sequence))
         (nonce (%tls12-cat (tls12-client-iv state) explicit))
         (ciphertext (pure-tls::aes-gcm-encrypt
                      (tls12-client-key state) nonce plaintext
                      (%tls12-aad sequence type (length plaintext)))))
    (when (= sequence #xffffffffffffffff)
      (%tls12-fail "TLS 1.2 client sequence number exhausted"))
    (incf (tls12-client-sequence state))
    (%tls12-cat explicit ciphertext)))

(defun %tls12-decrypt-record (state type payload)
  (when (< (length payload) 24)
    (%tls12-fail "TLS 1.2 AEAD record is too short"))
  (let* ((sequence (tls12-server-sequence state))
         (explicit (subseq payload 0 8))
         (ciphertext (subseq payload 8))
         (plaintext-length (- (length ciphertext) 16))
         (nonce (%tls12-cat (tls12-server-iv state) explicit))
         (plaintext
           (progn
             (when (> plaintext-length +tls12-max-plaintext+)
               (%tls12-fail "TLS 1.2 plaintext record exceeds bound"))
           (handler-case
               (pure-tls::aes-gcm-decrypt
                (tls12-server-key state) nonce ciphertext
                (%tls12-aad sequence type plaintext-length))
             (error () (%tls12-fail "TLS 1.2 record authentication failed"))))))
    (when (= sequence #xffffffffffffffff)
      (%tls12-fail "TLS 1.2 server sequence number exhausted"))
    (incf (tls12-server-sequence state))
    plaintext))

(defun %tls12-write-record (state type payload)
  (if (tls12-client-encrypted-p state)
      (let ((ciphertext (%tls12-encrypt-record state type payload)))
        (write-sequence
         (%tls12-cat (%tls12-u8 type) (%tls12-u16 +tls12-version+)
                     (%tls12-u16 (length ciphertext)) ciphertext)
         (tls12-stream state))
        (force-output (tls12-stream state)))
      (%tls12-write-plain-record state type payload)))

(defun %tls12-read-record (state &key eof-ok)
  (let ((header (%tls12-read-exactly (tls12-stream state) 5 :eof-ok eof-ok)))
    (unless header (return-from %tls12-read-record (values nil nil)))
    (let ((type (aref header 0))
          (version (%tls12-read-u16 header 1))
          (length (%tls12-read-u16 header 3)))
      (unless (member version '(#x0301 #x0302 #x0303))
        (%tls12-fail "invalid TLS record version 0x~4,'0x" version))
      (when (> length +tls12-max-ciphertext+)
        (%tls12-fail "TLS ciphertext record exceeds bound"))
      (let ((payload (%tls12-read-exactly (tls12-stream state) length)))
        (values type (if (tls12-server-encrypted-p state)
                         (%tls12-decrypt-record state type payload)
                         payload))))))

(defun %tls12-alert (payload)
  (unless (= (length payload) 2)
    (%tls12-fail "invalid TLS alert length"))
  (let ((level (aref payload 0)) (description (aref payload 1)))
    (if (and (= level 1) (= description 0))
        :close-notify
        (%tls12-fail "TLS 1.2 alert level ~d description ~d" level description))))

(defun %tls12-next-handshake (state &key allow-ccs)
  "Return the next complete handshake message and its type. Handshake messages may
span records or share a record. When ALLOW-CCS is true, return (:ccs, payload)."
  (loop
    (let ((buffer (tls12-handshake-buffer state)))
      (when (>= (length buffer) 4)
        (let ((length (%tls12-read-u24 buffer 1)))
          (when (> length +tls12-max-handshake-message+)
            (%tls12-fail "TLS handshake message exceeds bound"))
          (when (>= (length buffer) (+ 4 length))
            (let* ((message-end (+ 4 length))
                   (message (subseq buffer 0 message-end))
                   (remaining (- (length buffer) message-end)))
              (replace buffer buffer :start1 0 :start2 message-end)
              (setf (fill-pointer buffer) remaining)
              (return (values (aref message 0) message)))))))
    (multiple-value-bind (record-type payload) (%tls12-read-record state)
      (case record-type
        (#.+tls12-handshake+
         (%tls12-append-bounded
          (tls12-handshake-buffer state) payload
          (+ 4 +tls12-max-handshake-message+ +tls12-max-plaintext+)
          "TLS handshake buffer exceeds bound"))
        (#.+tls12-change-cipher-spec+
         (if allow-ccs
             (return (values :ccs payload))
             (%tls12-fail "unexpected change_cipher_spec")))
        (#.+tls12-alert+ (%tls12-alert payload))
        (otherwise (%tls12-fail "unexpected TLS record type ~d during handshake"
                                record-type))))))

(defun %tls12-client-hello (hostname random)
  (let* ((host (%tls12-ascii hostname))
         (sni-name (%tls12-cat (%tls12-u8 0) (%tls12-vector16 host)))
         (sni (%tls12-vector16 sni-name))
         (groups (%tls12-vector16 (%tls12-u16 #x0017)))
         (points (%tls12-cat (%tls12-u8 1) (%tls12-u8 0)))
         (signatures (%tls12-vector16
                      (%tls12-cat (%tls12-u16 #x0403) ; ecdsa_secp256r1_sha256
                                  (%tls12-u16 #x0804) ; rsa_pss_rsae_sha256
                                  (%tls12-u16 #x0401)))) ; rsa_pkcs1_sha256
         (alpn-name (%tls12-cat (%tls12-u8 8) (%tls12-ascii "http/1.1")))
         (alpn (%tls12-vector16 alpn-name))
         (extensions
           (%tls12-cat (%tls12-extension 0 sni)
                       (%tls12-extension 10 groups)
                       (%tls12-extension 11 points)
                       (%tls12-extension 13 signatures)
                       (%tls12-extension 16 alpn)
                       (%tls12-extension 23 (make-array 0 :element-type '(unsigned-byte 8)))))
         (suites (%tls12-cat
                  (%tls12-u16 +tls12-suite-ecdhe-ecdsa-aes128-gcm-sha256+)
                  (%tls12-u16 +tls12-suite-ecdhe-rsa-aes128-gcm-sha256+)
                  (%tls12-u16 +tls12-fallback-scsv+)
                  (%tls12-u16 #x00ff))) ; TLS_EMPTY_RENEGOTIATION_INFO_SCSV
         (body (%tls12-cat (%tls12-u16 +tls12-version+) random
                           (%tls12-u8 0) ; no resumption session id
                           (%tls12-vector16 suites)
                           (%tls12-u8 1) (%tls12-u8 0)
                           (%tls12-vector16 extensions))))
    (%tls12-handshake-message 1 body)))

(defun %tls12-parse-extensions (body offset)
  (if (= offset (length body))
      '()
      (progn
        (when (> (+ offset 2) (length body))
          (%tls12-fail "truncated ServerHello extensions"))
        (let* ((length (%tls12-read-u16 body offset))
               (start (+ offset 2))
               (end (+ start length))
               (result '())
               (seen (make-hash-table)))
          (unless (= end (length body))
            (%tls12-fail "invalid ServerHello extension length"))
          (loop while (< start end) do
            (when (> (+ start 4) end)
              (%tls12-fail "truncated ServerHello extension"))
            (let* ((type (%tls12-read-u16 body start))
                   (data-length (%tls12-read-u16 body (+ start 2)))
                   (data-start (+ start 4))
                   (data-end (+ data-start data-length)))
              (when (> data-end end)
                (%tls12-fail "truncated ServerHello extension data"))
              (when (nth-value 1 (gethash type seen))
                (%tls12-fail "duplicate ServerHello extension ~d" type))
              (setf (gethash type seen) t)
              (push (cons type (subseq body data-start data-end)) result)
              (setf start data-end)))
          (nreverse result)))))

(defun %tls12-parse-server-hello (message)
  (let* ((body (subseq message 4))
         (minimum (+ 2 32 1 2 1)))
    (when (< (length body) minimum)
      (%tls12-fail "truncated ServerHello"))
    (unless (= (%tls12-read-u16 body 0) +tls12-version+)
      (%tls12-fail "server did not select TLS 1.2"))
    (let* ((server-random (subseq body 2 34))
           (session-length (aref body 34))
           (suite-offset (+ 35 session-length)))
      (when (> session-length 32)
        (%tls12-fail "invalid ServerHello session id length"))
      (when (equalp (subseq server-random 24)
                    #(#x44 #x4f #x57 #x4e #x47 #x52 #x44 #x01))
        (%tls12-fail "TLS 1.3 downgrade sentinel received during TLS 1.2 fallback"))
      (when (> (+ suite-offset 3) (length body))
        (%tls12-fail "truncated ServerHello session"))
      (let ((suite (%tls12-read-u16 body suite-offset))
            (compression (aref body (+ suite-offset 2)))
            (extensions (%tls12-parse-extensions body (+ suite-offset 3))))
        (unless (member suite
                        (list +tls12-suite-ecdhe-ecdsa-aes128-gcm-sha256+
                              +tls12-suite-ecdhe-rsa-aes128-gcm-sha256+))
          (%tls12-fail "server selected unsupported TLS 1.2 suite 0x~4,'0x" suite))
        (unless (zerop compression)
          (%tls12-fail "server selected TLS compression"))
        (let ((alpn (cdr (assoc 16 extensions))))
          (when (and alpn
                     (not (equalp alpn
                                  (%tls12-vector16
                                   (%tls12-cat (%tls12-u8 8)
                                               (%tls12-ascii "http/1.1"))))))
            (%tls12-fail "server selected an unsupported ALPN protocol")))
        (let ((ems (assoc 23 extensions))
              (renegotiation (assoc #xff01 extensions)))
          (when (and ems (plusp (length (cdr ems))))
            (%tls12-fail "extended_master_secret ServerHello extension is not empty"))
          (when (and renegotiation
                     (not (equalp (cdr renegotiation) #(#x00))))
            (%tls12-fail "invalid renegotiation_info ServerHello extension"))
          (values server-random suite (not (null ems))))))))

(defun %tls12-parse-certificates (message)
  (let* ((body (subseq message 4))
         (total (and (>= (length body) 3) (%tls12-read-u24 body 0))))
    (unless (and total (= total (- (length body) 3)))
      (%tls12-fail "invalid TLS 1.2 Certificate list length"))
    (let ((offset 3) (certificates '()))
      (loop while (< offset (length body)) do
        (let* ((length (%tls12-read-u24 body offset))
               (start (+ offset 3))
               (end (+ start length)))
          (when (or (zerop length) (> end (length body)))
            (%tls12-fail "invalid certificate entry length"))
          (push (pure-tls:parse-certificate (subseq body start end)) certificates)
          (setf offset end)))
      (unless certificates (%tls12-fail "server supplied no certificate"))
      (nreverse certificates))))

(defun %tls12-verify-chain (certificates hostname context)
  (let* ((leaf (first certificates))
         (store (pure-tls::tls-context-trust-store context))
         (roots (and store (pure-tls::trust-store-certificates store))))
    (unless roots
      (%tls12-fail "no trusted root certificates are available"))
    (pure-tls:verify-hostname
     leaf hostname :policy (pure-tls::tls-context-hostname-policy context))
    (pure-tls::verify-certificate-chain certificates roots
                                        (get-universal-time) hostname
                                        :purpose :server-auth)
    t))

(defun %tls12-parse-server-key-exchange (message certificates suite client-random server-random)
  (let* ((body (subseq message 4))
         (minimum 8))
    (when (< (length body) minimum)
      (%tls12-fail "truncated ServerKeyExchange"))
    (unless (= (aref body 0) 3)
      (%tls12-fail "server did not use named_curve ECDHE"))
    (let* ((group (%tls12-read-u16 body 1))
           (key-length (aref body 3))
           (key-end (+ 4 key-length)))
      (unless (= group #x0017)
        (%tls12-fail "server selected unsupported ECDHE group 0x~4,'0x" group))
      (when (> (+ key-end 4) (length body))
        (%tls12-fail "truncated ServerKeyExchange key or signature"))
      (let* ((peer-key (subseq body 4 key-end))
             (algorithm (%tls12-read-u16 body key-end))
             (signature-length (%tls12-read-u16 body (+ key-end 2)))
             (signature-start (+ key-end 4))
             (signature-end (+ signature-start signature-length))
             (params (subseq body 0 key-end)))
        (unless (= signature-end (length body))
          (%tls12-fail "invalid ServerKeyExchange signature length"))
        (unless (case suite
                  (#.+tls12-suite-ecdhe-ecdsa-aes128-gcm-sha256+ (= algorithm #x0403))
                  (#.+tls12-suite-ecdhe-rsa-aes128-gcm-sha256+
                   (member algorithm '(#x0401 #x0804))))
          (%tls12-fail "signature algorithm is incompatible with selected cipher suite"))
        (pure-tls::verify-certificate-verify-signature
         (first certificates) algorithm (subseq body signature-start signature-end)
         (%tls12-cat client-random server-random params)
         :allowed-algorithms '(#x0403 #x0804 #x0401)
         :protocol-version :tls12)
        peer-key))))

(defun %tls12-derive-keys (state premaster extended-master-secret-p)
  (let* ((session-hash (%tls12-digest (tls12-transcript state)))
         (master (%tls12-prf
                  premaster
                  (if extended-master-secret-p "extended master secret" "master secret")
                  (if extended-master-secret-p
                      session-hash
                      (%tls12-cat (tls12-client-random state) (tls12-server-random state)))
                  48))
         (key-block (%tls12-prf master "key expansion"
                                (%tls12-cat (tls12-server-random state)
                                            (tls12-client-random state))
                                40)))
    (setf (tls12-client-key state) (subseq key-block 0 16)
          (tls12-server-key state) (subseq key-block 16 32)
          (tls12-client-iv state) (subseq key-block 32 36)
          (tls12-server-iv state) (subseq key-block 36 40))
    master))

(defun %tls12-finished (master label transcript)
  (%tls12-prf master label (%tls12-digest transcript) 12))

(defun %tls12-handshake (stream hostname ca-file verify)
  (let* ((random (sys:os-random-bytes 32))
         (state (make-tls12-state :stream stream :client-random random))
         (hello (%tls12-client-hello hostname random))
         (context (if ca-file
                      (pure-tls:make-tls-context :ca-file ca-file)
                      (pure-tls:make-tls-context)))
         (certificates nil)
         (suite nil)
         (extended-master-secret-p nil)
         (server-key nil))
    (%tls12-write-plain-record state +tls12-handshake+ hello)
    (%tls12-append-transcript state hello)
    (multiple-value-bind (type message) (%tls12-next-handshake state)
      (unless (= type 2) (%tls12-fail "expected ServerHello, received handshake ~a" type))
      (multiple-value-bind (server-random selected-suite ems)
          (%tls12-parse-server-hello message)
        (setf (tls12-server-random state) server-random
              suite selected-suite
              extended-master-secret-p ems))
      (%tls12-append-transcript state message))
    (loop
      (multiple-value-bind (type message) (%tls12-next-handshake state)
        (case type
          (11
           (when certificates (%tls12-fail "duplicate Certificate message"))
           (setf certificates (%tls12-parse-certificates message)))
          (12
           (unless certificates (%tls12-fail "ServerKeyExchange preceded Certificate"))
           (setf server-key
                 (%tls12-parse-server-key-exchange
                  message certificates suite random (tls12-server-random state))))
          (22 (%tls12-fail "unsolicited TLS 1.2 CertificateStatus message"))
          (14
           (unless (and certificates server-key)
             (%tls12-fail "incomplete TLS 1.2 server flight"))
           (unless (= (length message) 4)
             (%tls12-fail "ServerHelloDone message is not empty"))
           (%tls12-append-transcript state message)
           (return))
          (otherwise (%tls12-fail "unexpected server handshake message ~a" type)))
        (unless (= type 14) (%tls12-append-transcript state message))))
    (when verify (%tls12-verify-chain certificates hostname context))
    (let* ((key-exchange (pure-tls::generate-key-exchange #x0017))
           (public-key (pure-tls::get-key-exchange-public-key key-exchange))
           (client-key-exchange
             (%tls12-handshake-message
              16 (%tls12-cat (%tls12-u8 (length public-key)) public-key))))
      (%tls12-write-plain-record state +tls12-handshake+ client-key-exchange)
      (%tls12-append-transcript state client-key-exchange)
      (let* ((premaster (pure-tls::compute-shared-secret key-exchange server-key))
             (master (%tls12-derive-keys state premaster extended-master-secret-p))
             (client-finished
               (%tls12-handshake-message
                20 (%tls12-finished master "client finished" (tls12-transcript state)))))
        (%tls12-write-plain-record state +tls12-change-cipher-spec+ (%tls12-u8 1))
        (setf (tls12-client-encrypted-p state) t)
        (%tls12-write-record state +tls12-handshake+ client-finished)
        (%tls12-append-transcript state client-finished)
        ;; A server may send NewSessionTicket before CCS. We decline resumption but
        ;; retain the message in the Finished transcript as TLS 1.2 requires.
        (loop
          (multiple-value-bind (type message) (%tls12-next-handshake state :allow-ccs t)
            (cond
              ((eq type :ccs)
               (unless (and (= (length message) 1) (= (aref message 0) 1))
                 (%tls12-fail "invalid server change_cipher_spec"))
               (setf (tls12-server-encrypted-p state) t)
               (return))
              ((= type 4) (%tls12-append-transcript state message))
              (t (%tls12-fail "expected server change_cipher_spec, received ~a" type)))))
        (multiple-value-bind (type server-finished) (%tls12-next-handshake state)
          (unless (and (= type 20) (= (length server-finished) 16))
            (%tls12-fail "invalid server Finished message"))
          (let ((expected (%tls12-finished master "server finished"
                                           (tls12-transcript state)))
                (actual (subseq server-finished 4)))
            (unless (ironclad:constant-time-equal expected actual)
              (%tls12-fail "server Finished verification failed")))
          (%tls12-append-transcript state server-finished))))
    state))

(defun %tls12-write-application-data (state octets)
  (loop for start from 0 below (length octets) by +tls12-max-plaintext+
        for end = (min (length octets) (+ start +tls12-max-plaintext+))
        do (%tls12-write-record state +tls12-application-data+
                                (subseq octets start end))))

(defun %tls12-read-application-data (state)
  (let ((result (make-array 65536 :element-type '(unsigned-byte 8)
                                  :adjustable t :fill-pointer 0)))
    (labels ((append-octets (octets)
               (let* ((old (fill-pointer result))
                      (new (+ old (length octets))))
                 (when (> new (+ *max-header-bytes* *max-body-bytes*))
                   (%tls12-fail "TLS HTTP response exceeds transport bound"))
                 (when (> new (array-total-size result))
                   (adjust-array result
                                 (min (+ *max-header-bytes* *max-body-bytes*)
                                      (max new (* 2 (array-total-size result))))
                                 :fill-pointer old))
                 (setf (fill-pointer result) new)
                 (replace result octets :start1 old))))
      (loop
        (multiple-value-bind (type payload) (%tls12-read-record state :eof-ok t)
          (unless type (return))
          (case type
            (#.+tls12-application-data+ (append-octets payload))
            (#.+tls12-alert+
             (when (eq (%tls12-alert payload) :close-notify)
               (setf (tls12-closed-p state) t)
               (return)))
            (#.+tls12-handshake+
             (%tls12-fail "post-handshake TLS messages are not supported"))
            (otherwise (%tls12-fail "unexpected TLS record type ~d" type))))))
    (values (subseq result 0 (fill-pointer result))
            (tls12-closed-p state))))

(defun %tls12-read-application-data-stream (state on-data)
  "Deliver authenticated application records incrementally to ON-DATA.

ON-DATA may return true once the HTTP message is complete, allowing the client
to send close_notify without waiting for the peer to close its side. Returns a
termination keyword and whether a peer close_notify was authenticated."
  (loop
    (multiple-value-bind (type payload) (%tls12-read-record state :eof-ok t)
      (unless type
        (return (values :eof (tls12-closed-p state))))
      (case type
        (#.+tls12-application-data+
         (when (and (plusp (length payload)) (funcall on-data payload))
           (return (values :message-complete (tls12-closed-p state)))))
        (#.+tls12-alert+
         (when (eq (%tls12-alert payload) :close-notify)
           (setf (tls12-closed-p state) t)
           (return (values :close-notify t))))
        (#.+tls12-handshake+
         (%tls12-fail "post-handshake TLS messages are not supported"))
        (otherwise (%tls12-fail "unexpected TLS record type ~d" type))))))

(defun %tls12-close-notify (state)
  (unless (tls12-closed-p state)
    (ignore-errors (%tls12-write-record state +tls12-alert+
                                        (make-array 2 :element-type '(unsigned-byte 8)
                                                      :initial-contents '(1 0))))
    (setf (tls12-closed-p state) t)))

(defun https-request-tls12 (stream hostname request-bytes &key ca-file (verify t))
  "Perform one TLS 1.2 HTTP exchange over an already-connected binary STREAM.
Returns the complete HTTP response wire bytes and whether the peer authenticated EOF
with close_notify. Certificate and hostname verification
are mandatory unless VERIFY is explicitly NIL for a hermetic fixture."
  (let ((state (%tls12-handshake stream hostname ca-file verify)))
    (unwind-protect
         (progn
           (%tls12-write-application-data state request-bytes)
           (%tls12-read-application-data state))
      (%tls12-close-notify state))))

(defun https-request-tls12-stream
    (stream hostname request-bytes on-data
     &key ca-file (verify t) request-body-source)
  "Perform a TLS 1.2 exchange and deliver authenticated HTTP wire chunks.

This is the streaming counterpart to HTTPS-REQUEST-TLS12. It preserves the
same handshake, certificate, hostname, record-MAC, and close-notify behavior."
  (let ((state (%tls12-handshake stream hostname ca-file verify)))
    (unwind-protect
         (progn
           (%tls12-write-application-data state request-bytes)
           (when request-body-source
             (let ((total 0))
               (loop
                 (multiple-value-bind (chunk done-p)
                     (funcall request-body-source)
                   (when done-p
                     (%tls12-write-application-data
                      state +chunked-request-end+)
                     (return))
                   (when (plusp (length chunk))
                     (incf total (length chunk))
                     (when (> total *max-body-bytes*)
                       (%tls12-fail
                        "streaming request body exceeded the size limit"))
                     (%tls12-write-application-data
                      state (%chunked-request-frame chunk)))))))
           (%tls12-read-application-data-stream state on-data))
      (%tls12-close-notify state))))
