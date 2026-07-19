;;;; Focused deterministic tests for the Phase-28 TLS 1.2 transport profile.

(in-package :clun-test)

(defun %tls12-hex (string)
  (ironclad:hex-string-to-byte-array string))

(defun %tls-alert-record (level description)
  (make-array 7 :element-type '(unsigned-byte 8)
                :initial-contents
                (list 21 #x03 #x03 0 2 level description)))

(defun %tls-test-two-way-stream (input)
  (let ((output (ironclad:make-octet-output-stream)))
    (values (make-two-way-stream
             (ironclad:make-octet-input-stream input) output)
            output)))

(defun %tls-alert-fixture-certificate ()
  (pure-tls:parse-certificate-from-file
   (namestring
    (merge-pathnames "tests/fixtures/certs/localhost-leaf.crt"
                     (asdf:system-source-directory :clun)))))

(defun %tls12-server-hello-fixture (&rest extensions)
  (clun.net::%tls12-handshake-message
   2 (clun.net::%tls12-cat
      (clun.net::%tls12-u16 clun.net::+tls12-version+)
      (make-array 32 :element-type '(unsigned-byte 8) :initial-element 0)
      (clun.net::%tls12-u8 0)
      (clun.net::%tls12-u16
       clun.net::+tls12-suite-ecdhe-rsa-aes128-gcm-sha256+)
      (clun.net::%tls12-u8 0)
      (clun.net::%tls12-vector16
       (apply #'clun.net::%tls12-cat extensions)))))

(defun %capture-tls12-alert (thunk)
  (multiple-value-bind (stream output)
      (%tls-test-two-way-stream
       (make-array 0 :element-type '(unsigned-byte 8)))
    (let ((state (clun.net::make-tls12-state :stream stream)))
      (handler-case
          (clun.net::%tls12-call-with-alerts
           state (lambda () (funcall thunk state)))
        (error () nil))
      (values (ironclad:get-output-stream-octets output) state))))

(defun %capture-tls13-local-alert (condition)
  (let* ((output (ironclad:make-octet-output-stream))
         (layer (pure-tls::make-record-layer output)))
    (handler-case
        (pure-tls::call-with-client-local-alerts
         layer (lambda () (error condition)))
      (error () nil))
    (values (ironclad:get-output-stream-octets output) layer)))

(define-test net/tls12-prf-sha256
  ;; Independently reproduced with OpenSSL 3 EVP_KDF TLS1-PRF. The hex seed
  ;; supplied to OpenSSL is ASCII("master secret") || SEED; Clun's PRF accepts
  ;; LABEL and SEED separately as RFC 5246 section 5 specifies.
  (let ((secret (%tls12-hex "9bbe436ba940f017b17652849a71db35"))
        (seed (%tls12-hex "a0ba9f936cda311827a6f796ffd5198c"))
        (expected
          (%tls12-hex
           "7f28c8d468dd5cc00a4df3089fb8ef04ef6768d357aeb4a2216abf7c9ace2c1e55983e8b0d911b6cc8969b7ca37cfdc1")))
    (is equalp expected
        (clun.net::%tls12-prf secret "master secret" seed 48))))

(define-test net/tls12-record-authentication
  (let* ((key (%tls12-hex "000102030405060708090a0b0c0d0e0f"))
         (iv (%tls12-hex "a0a1a2a3"))
         (plaintext (%tls12-hex "00112233445566778899aabbccddeeff"))
         (sender (clun.net::make-tls12-state :client-key key :client-iv iv))
         (receiver (clun.net::make-tls12-state :server-key key :server-iv iv))
         (record (clun.net::%tls12-encrypt-record sender 23 plaintext)))
    (is = 40 (length record)) ; explicit nonce (8) + plaintext (16) + tag (16)
    (is equalp (%tls12-hex "0000000000000000") (subseq record 0 8))
    (is equalp plaintext (clun.net::%tls12-decrypt-record receiver 23 record))
    (is = 1 (clun.net::tls12-client-sequence sender))
    (is = 1 (clun.net::tls12-server-sequence receiver))
    ;; Every header field is authenticated. A changed content type or payload
    ;; must fail closed rather than release plaintext.
    (fail (clun.net::%tls12-decrypt-record
           (clun.net::make-tls12-state :server-key key :server-iv iv)
           22 record)
          clun.net::tls12-error)
    (let ((tampered (copy-seq record)))
      (setf (aref tampered (1- (length tampered)))
            (logxor #x01 (aref tampered (1- (length tampered)))))
      (fail (clun.net::%tls12-decrypt-record
             (clun.net::make-tls12-state :server-key key :server-iv iv)
             23 tampered)
            clun.net::tls12-error))))

(define-test net/tls12-local-fatal-alert-wire-contract
  ;; Handshake framing failures carry decode_error and emit exactly one
  ;; plaintext fatal alert before encryption is installed.
  (multiple-value-bind (wire state)
      (%capture-tls12-alert
       (lambda (state)
         (declare (ignore state))
         (clun.net::%tls12-parse-server-hello
          (make-array 4 :element-type '(unsigned-byte 8)
                        :initial-contents '(2 0 0 0)))))
    (is equalp (%tls-alert-record 2 clun.net::+tls12-alert-decode-error+) wire)
    (true (clun.net::tls12-fatal-alert-sent-p state)))
  ;; Record authentication failures use bad_record_mac.  A second nested
  ;; failure cannot duplicate the terminal alert.
  (multiple-value-bind (wire state)
      (%capture-tls12-alert
       (lambda (state)
         (setf (clun.net::tls12-server-key state)
               (make-array 16 :element-type '(unsigned-byte 8)
                              :initial-element 0)
               (clun.net::tls12-server-iv state)
               (make-array 4 :element-type '(unsigned-byte 8)
                             :initial-element 0))
         (clun.net::%tls12-decrypt-record
          state 23 (make-array 3 :element-type '(unsigned-byte 8)
                                  :initial-element 0))))
    (declare (ignore state))
    (is equalp (%tls-alert-record 2 clun.net::+tls12-alert-bad-record-mac+)
        wire))
  (multiple-value-bind (wire state)
      (%capture-tls12-alert
       (lambda (state)
         (setf (clun.net::tls12-server-key state)
               (make-array 16 :element-type '(unsigned-byte 8)
                              :initial-element 0)
               (clun.net::tls12-server-iv state)
               (make-array 4 :element-type '(unsigned-byte 8)
                             :initial-element 0))
         (clun.net::%tls12-decrypt-record
          state 23
          (make-array (+ 8 16 (1+ clun.net::+tls12-max-plaintext+))
                      :element-type '(unsigned-byte 8)
                      :initial-element 0))))
    (declare (ignore state))
    (is equalp (%tls-alert-record 2 clun.net::+tls12-alert-record-overflow+)
        wire))
  (multiple-value-bind (wire state)
      (%capture-tls12-alert
       (lambda (state)
         (clun.net::%tls12-send-fatal-alert
          state clun.net::+tls12-alert-decode-error+)
         (clun.net::%tls12-send-fatal-alert
          state clun.net::+tls12-alert-handshake-failure+)))
    (declare (ignore state))
    (is equalp (%tls-alert-record 2 clun.net::+tls12-alert-decode-error+)
        wire))
  ;; A fatal alert closes both normal record directions before its bytes are
  ;; written. Application output and later reads cannot follow it on the wire.
  (multiple-value-bind (stream output)
      (%tls-test-two-way-stream
       (make-array 0 :element-type '(unsigned-byte 8)))
    (let ((state (clun.net::make-tls12-state :stream stream)))
      (clun.net::%tls12-send-fatal-alert
       state clun.net::+tls12-alert-decode-error+)
      (fail (clun.net::%tls12-write-application-data
             state (%tls12-hex "010203"))
            clun.net::tls12-error)
      (fail (clun.net::%tls12-read-record state :eof-ok t)
            clun.net::tls12-error)
      (is equalp (%tls-alert-record 2 clun.net::+tls12-alert-decode-error+)
          (ironclad:get-output-stream-octets output))))
  ;; Terminal state is committed before transport I/O, including a failed
  ;; write, so cleanup cannot retry or append another record.
  (let* ((output (ironclad:make-octet-output-stream))
         (state (clun.net::make-tls12-state :stream output)))
    (close output)
    (clun.net::%tls12-send-fatal-alert
     state clun.net::+tls12-alert-internal-error+)
    (true (clun.net::tls12-fatal-alert-sent-p state))
    (clun.net::%tls12-send-fatal-alert
     state clun.net::+tls12-alert-decode-error+)
    (false (clun.net::tls12-local-close-sent-p state)))
  ;; Certificate trust and hostname failures are typed independently without
  ;; sending local diagnostic material over the wire.
  (multiple-value-bind (wire state)
      (%capture-tls12-alert
       (lambda (state)
         (declare (ignore state))
         (error 'pure-tls:tls-verification-error
                :reason :unknown-ca
                :message "fixture trust anchor missing")))
    (declare (ignore state))
    (is equalp (%tls-alert-record 2 clun.net::+tls12-alert-unknown-ca+) wire))
  (multiple-value-bind (wire state)
      (%capture-tls12-alert
       (lambda (state)
         (declare (ignore state))
         (error 'pure-tls:tls-verification-error
                :hostname "wrong.example"
                :message "fixture hostname mismatch")))
    (declare (ignore state))
    (is equalp (%tls-alert-record 2 clun.net::+tls12-alert-bad-certificate+)
        wire))
  ;; Negotiation errors retain distinct RFC dispositions rather than all
  ;; collapsing into decode_error.
  (multiple-value-bind (wire state)
      (%capture-tls12-alert
       (lambda (state)
         (declare (ignore state))
         (clun.net::%tls12-parse-server-hello
          (%tls12-server-hello-fixture
           (clun.net::%tls12-extension
            35 (make-array 0 :element-type '(unsigned-byte 8)))))))
    (declare (ignore state))
    (is equalp (%tls-alert-record
                2 clun.net::+tls12-alert-unsupported-extension+)
        wire))
  (multiple-value-bind (wire state)
      (%capture-tls12-alert
       (lambda (state)
         (declare (ignore state))
         (clun.net::%tls12-parse-server-hello
          (%tls12-server-hello-fixture))))
    (declare (ignore state))
    (is equalp (%tls-alert-record 2 clun.net::+tls12-alert-handshake-failure+)
        wire))
  (multiple-value-bind (wire state)
      (%capture-tls12-alert
       (lambda (state)
         (declare (ignore state))
         (clun.net::%tls12-parse-server-key-exchange
          (clun.net::%tls12-handshake-message
           12 (make-array 8 :element-type '(unsigned-byte 8)
                            :initial-contents '(3 0 24 1 4 0 0 0)))
          (list (%tls-alert-fixture-certificate))
          clun.net::+tls12-suite-ecdhe-rsa-aes128-gcm-sha256+
          (make-array 32 :element-type '(unsigned-byte 8) :initial-element 1)
          (make-array 32 :element-type '(unsigned-byte 8) :initial-element 2))))
    (declare (ignore state))
    (is equalp (%tls-alert-record 2 clun.net::+tls12-alert-illegal-parameter+)
        wire))
  ;; The P-256 shared-secret primitive rejects malformed/off-curve peer points
  ;; as illegal_parameter at the outer TLS 1.2 boundary.
  (multiple-value-bind (wire state)
      (%capture-tls12-alert
       (lambda (state)
         (declare (ignore state))
         (let ((bad-point (make-array 65 :element-type '(unsigned-byte 8)
                                         :initial-element 0)))
           (setf (aref bad-point 0) 4)
           (pure-tls::compute-shared-secret
            (pure-tls::generate-key-exchange #x0017) bad-point))))
    (declare (ignore state))
    (is equalp (%tls-alert-record 2 clun.net::+tls12-alert-illegal-parameter+)
        wire))
  ;; Feed a structurally complete Certificate handshake containing malformed
  ;; DER through the real TLS 1.2 certificate parser.
  (let* ((bad-der (%tls12-hex "010203"))
         (entry (clun.net::%tls12-cat
                 (clun.net::%tls12-u24 (length bad-der)) bad-der))
         (message (clun.net::%tls12-handshake-message
                   11 (clun.net::%tls12-cat
                       (clun.net::%tls12-u24 (length entry)) entry))))
    (multiple-value-bind (wire state)
        (%capture-tls12-alert
         (lambda (state)
           (declare (ignore state))
           (clun.net::%tls12-parse-certificates message)))
      (declare (ignore state))
      (is equalp (%tls-alert-record
                  2 clun.net::+tls12-alert-bad-certificate+)
          wire)))
  ;; Exercise the actual TLS 1.2 ServerKeyExchange signature verifier with an
  ;; invalid RSA signature. Signature proof failure is decrypt_error.
  (let* ((peer-key (make-array 65 :element-type '(unsigned-byte 8)
                                  :initial-element 0))
         (_ (setf (aref peer-key 0) 4))
         (params (clun.net::%tls12-cat
                  (clun.net::%tls12-u8 3)
                  (clun.net::%tls12-u16 #x0017)
                  (clun.net::%tls12-u8 (length peer-key))
                  peer-key))
         (signature (%tls12-hex "00"))
         (message
           (clun.net::%tls12-handshake-message
            12 (clun.net::%tls12-cat
                params
                (clun.net::%tls12-u16 #x0401)
                (clun.net::%tls12-u16 (length signature))
                signature))))
    (declare (ignore _))
    (multiple-value-bind (wire state)
        (%capture-tls12-alert
         (lambda (state)
           (declare (ignore state))
           (clun.net::%tls12-parse-server-key-exchange
            message (list (%tls-alert-fixture-certificate))
            clun.net::+tls12-suite-ecdhe-rsa-aes128-gcm-sha256+
            (make-array 32 :element-type '(unsigned-byte 8) :initial-element 1)
            (make-array 32 :element-type '(unsigned-byte 8) :initial-element 2))))
      (declare (ignore state))
      (is equalp (%tls-alert-record 2 clun.net::+tls12-alert-decrypt-error+)
          wire))))

(define-test net/tls12-peer-alert-and-close-wire-contract
  ;; %TLS12-ALERT itself marks a peer fatal before signaling. Even a direct
  ;; catch outside the outer handler cannot answer it or close normally.
  (multiple-value-bind (stream output)
      (%tls-test-two-way-stream
       (make-array 0 :element-type '(unsigned-byte 8)))
    (let ((state (clun.net::make-tls12-state :stream stream))
          (caught nil))
      (handler-case
          (clun.net::%tls12-alert
           (make-array 2 :element-type '(unsigned-byte 8)
                         :initial-contents '(2 42))
           state)
        (clun.net::tls12-peer-alert (condition)
          (setf caught condition)))
      (true caught)
      (true (clun.net::tls12-peer-fatal-alert-received-p state))
      (clun.net::%tls12-close-notify state)
      (fail (clun.net::%tls12-write-application-data state (%tls12-hex "01"))
            clun.net::tls12-error)
      (fail (clun.net::%tls12-read-record state :eof-ok t)
            clun.net::tls12-error)
      (false (clun.net::tls12-local-close-sent-p state))
      (is = 0 (length (ironclad:get-output-stream-octets output)))))
  ;; Peer receipt and local transmission are distinct. A valid close_notify
  ;; receives one, and only one, reciprocal warning alert.
  (multiple-value-bind (stream output)
      (%tls-test-two-way-stream
       (make-array 0 :element-type '(unsigned-byte 8)))
    (let ((state (clun.net::make-tls12-state :stream stream)))
      (is eq :close-notify
          (clun.net::%tls12-alert
           (make-array 2 :element-type '(unsigned-byte 8)
                         :initial-contents '(1 0))
           state))
      (true (clun.net::tls12-peer-close-received-p state))
      (false (clun.net::tls12-local-close-sent-p state))
      (fail (clun.net::%tls12-write-application-data state (%tls12-hex "01"))
            clun.net::tls12-error)
      (fail (clun.net::%tls12-read-record state :eof-ok t)
            clun.net::tls12-error)
      (clun.net::%tls12-close-notify state)
      (clun.net::%tls12-close-notify state)
      (true (clun.net::tls12-local-close-sent-p state))
      (is equalp (%tls-alert-record 1 0)
          (ironclad:get-output-stream-octets output))))
  ;; A locally initiated close likewise commits terminal state before I/O.
  (multiple-value-bind (stream output)
      (%tls-test-two-way-stream
       (make-array 0 :element-type '(unsigned-byte 8)))
    (let ((state (clun.net::make-tls12-state :stream stream)))
      (clun.net::%tls12-close-notify state)
      (fail (clun.net::%tls12-write-application-data state (%tls12-hex "01"))
            clun.net::tls12-error)
      (fail (clun.net::%tls12-read-record state :eof-ok t)
            clun.net::tls12-error)
      (is equalp (%tls-alert-record 1 0)
          (ironclad:get-output-stream-octets output))))
  ;; The close flag likewise survives a failed transport write and suppresses
  ;; all retries.
  (let* ((output (ironclad:make-octet-output-stream))
         (state (clun.net::make-tls12-state :stream output)))
    (close output)
    (clun.net::%tls12-close-notify state)
    (true (clun.net::tls12-local-close-sent-p state))
    (clun.net::%tls12-close-notify state)
    (false (clun.net::tls12-fatal-alert-sent-p state))))

(define-test net/tls13-fatal-alert-wire-contract
  (dolist (fixture
           (list
            (list (make-condition 'pure-tls:tls-verification-error
                                  :hostname "wrong.example"
                                  :message "hostname mismatch")
                  pure-tls:+alert-bad-certificate+)
            (list (make-condition 'pure-tls:tls-verification-error
                                  :reason :unknown-ca
                                  :message "untrusted root")
                  pure-tls:+alert-unknown-ca+)
            (list (make-condition 'pure-tls:tls-verification-error
                                  :reason :no-peer-certificate
                                  :message "server certificate missing")
                  pure-tls:+alert-decode-error+)
            (list (make-condition 'pure-tls::tls-certificate-expired
                                  :not-after 0 :message "expired")
                  pure-tls:+alert-certificate-expired+)
            (list (make-condition 'pure-tls:tls-certificate-error
                                  :message "invalid ExtendedKeyUsage")
                  pure-tls::+alert-unsupported-certificate+)
            (list (make-condition 'pure-tls:tls-certificate-error
                                  :message "malformed certificate DER")
                  pure-tls:+alert-bad-certificate+)))
    (destructuring-bind (condition expected-description) fixture
      (multiple-value-bind (wire layer)
          (%capture-tls13-local-alert condition)
        (true (pure-tls::record-layer-fatal-alert-sent-p layer))
        (is equalp (%tls-alert-record 2 expected-description) wire))))
  ;; The one-shot record-layer guard prevents duplicate terminal alerts from
  ;; nested parser/stream handlers.
  (let* ((output (ironclad:make-octet-output-stream))
         (layer (pure-tls::make-record-layer output)))
    (pure-tls::record-layer-write-alert
     layer pure-tls::+alert-level-fatal+ pure-tls:+alert-decode-error+)
    (pure-tls::record-layer-write-alert
     layer pure-tls::+alert-level-fatal+ pure-tls:+alert-handshake-failure+)
    (pure-tls::record-layer-write-alert
     layer pure-tls::+alert-level-warning+ pure-tls:+alert-close-notify+)
    (fail (pure-tls::record-layer-write-application-data
           layer (%tls12-hex "01"))
          pure-tls:tls-error)
    (fail (pure-tls::record-layer-read layer) pure-tls:tls-error)
    (is equalp (%tls-alert-record 2 pure-tls:+alert-decode-error+)
        (ironclad:get-output-stream-octets output)))
  ;; Exercise the real TLS 1.3 CertificateVerify signature helper. The outer
  ;; client disposition maps its BAD_SIGNATURE condition to decrypt_error.
  (let* ((output (ironclad:make-octet-output-stream))
         (layer (pure-tls::make-record-layer output)))
    (handler-case
        (pure-tls::call-with-client-local-alerts
         layer
         (lambda ()
           (pure-tls::verify-certificate-verify-signature
            (%tls-alert-fixture-certificate)
            pure-tls::+sig-rsa-pss-rsae-sha256+
            (%tls12-hex "00") (%tls12-hex "010203")
            :allowed-algorithms
            (pure-tls::supported-signature-algorithms-tls13))))
      (pure-tls:tls-handshake-error () nil))
    (is equalp (%tls-alert-record 2 pure-tls:+alert-decrypt-error+)
        (ironclad:get-output-stream-octets output)))
  ;; Exercise the TLS 1.3 Certificate message processor with malformed DER.
  ;; The local diagnostic remains a condition while the peer receives only
  ;; the standard bad_certificate disposition.
  (let* ((output (ironclad:make-octet-output-stream))
         (layer (pure-tls::make-record-layer output))
         (handshake (pure-tls::make-client-handshake
                     :record-layer layer
                     :verify-mode pure-tls:+verify-required+))
         (message
           (pure-tls::make-handshake-message
            :type pure-tls::+handshake-certificate+
            :body
            (pure-tls::make-certificate-message
             :certificate-request-context
             (make-array 0 :element-type '(unsigned-byte 8))
             :certificate-list
             (list
              (pure-tls::make-certificate-entry
               :cert-data (%tls12-hex "010203")
               :extensions nil))))))
    (handler-case
        (pure-tls::call-with-client-local-alerts
         layer (lambda () (pure-tls::process-certificate handshake message)))
      (pure-tls:tls-certificate-error () nil))
    (is equalp (%tls-alert-record 2 pure-tls:+alert-bad-certificate+)
        (ironclad:get-output-stream-octets output)))
  ;; RFC 9846 section 4.5.1.3 requires decode_error for an empty server
  ;; Certificate. Exercise the real processor after installing write keys and
  ;; independently decrypt the exact encrypted alert record disposition.
  (let* ((key (%tls12-hex "000102030405060708090a0b0c0d0e0f"))
         (iv (%tls12-hex "101112131415161718191a1b"))
         (output (ironclad:make-octet-output-stream))
         (layer (pure-tls::make-record-layer output))
         (handshake (pure-tls::make-client-handshake
                     :record-layer layer
                     :verify-mode pure-tls:+verify-required+))
         (message
           (pure-tls::make-handshake-message
            :type pure-tls::+handshake-certificate+
            :body
            (pure-tls::make-certificate-message
             :certificate-request-context
             (make-array 0 :element-type '(unsigned-byte 8))
             :certificate-list nil))))
    (pure-tls::record-layer-install-keys
     layer :write key iv pure-tls::+tls-aes-128-gcm-sha256+)
    (handler-case
        (pure-tls::call-with-client-local-alerts
         layer (lambda () (pure-tls::process-certificate handshake message)))
      (pure-tls:tls-decode-error () nil))
    (let* ((wire (ironclad:get-output-stream-octets output))
           (header (subseq wire 0 5))
           (ciphertext (subseq wire 5))
           (decoder (pure-tls::make-aead
                     pure-tls::+tls-aes-128-gcm-sha256+ key iv)))
      (is equalp
          (%tls12-hex "1703030013c61c16e03610d81433fceeee3bf782f00face0")
          wire)
      (is equalp (%tls12-hex "1703030013") header)
      (multiple-value-bind (plaintext content-type)
          (pure-tls::tls13-decrypt-record decoder ciphertext header)
        (is = pure-tls::+content-type-alert+ content-type)
        (is equalp
            (make-array 2 :element-type '(unsigned-byte 8)
                          :initial-contents
                          (list pure-tls::+alert-level-fatal+
                                pure-tls:+alert-decode-error+))
            plaintext)))))

(define-test net/tls13-peer-alert-and-close-wire-contract
  ;; Never answer a complete peer fatal, even when its description is unknown.
  (let* ((output (ironclad:make-octet-output-stream))
         (layer (pure-tls::make-record-layer output))
         (caught nil))
    (handler-case
        (pure-tls::process-alert
         (make-array 2 :element-type '(unsigned-byte 8)
                       :initial-contents '(2 222))
         layer)
      (pure-tls:tls-alert-error (condition)
        (setf caught condition)))
    (true caught)
    (is = 222 (pure-tls::tls-alert-error-description caught))
    (true (pure-tls::record-layer-peer-fatal-alert-received-p layer))
    (pure-tls::record-layer-write-alert
     layer pure-tls::+alert-level-fatal+ pure-tls:+alert-decode-error+)
    (pure-tls::record-layer-write-alert
     layer pure-tls::+alert-level-warning+ pure-tls:+alert-close-notify+)
    (fail (pure-tls::record-layer-write-application-data
           layer (%tls12-hex "01"))
          pure-tls:tls-error)
    (fail (pure-tls::record-layer-read layer) pure-tls:tls-error)
    (is = 0 (length (ironclad:get-output-stream-octets output))))
  ;; TLS 1.3 ignores the legacy level byte. An unknown description is a peer
  ;; fatal even when labeled warning and receives no response.
  (let* ((output (ironclad:make-octet-output-stream))
         (layer (pure-tls::make-record-layer output))
         (caught nil))
    (handler-case
        (pure-tls::process-alert
         (make-array 2 :element-type '(unsigned-byte 8)
                       :initial-contents '(1 222))
         layer)
      (pure-tls:tls-alert-error (condition)
        (setf caught condition)))
    (true caught)
    (true (pure-tls::record-layer-peer-fatal-alert-received-p layer))
    (is = 0 (length (ironclad:get-output-stream-octets output))))
  ;; The same rule makes close_notify clean for any legacy level. This direct
  ;; process fixture covers handshake-time close before a TLS stream exists.
  (let* ((output (ironclad:make-octet-output-stream))
         (layer (pure-tls::make-record-layer output))
         (clean nil))
    (handler-case
        (pure-tls::process-alert
         (make-array 2 :element-type '(unsigned-byte 8)
                       :initial-contents '(99 0))
         layer)
      (pure-tls::tls-connection-closed (condition)
        (setf clean (pure-tls::tls-connection-closed-clean-p condition))))
    (true clean)
    (true (pure-tls::record-layer-peer-close-received-p layer))
    (true (pure-tls::record-layer-local-close-sent-p layer))
    (fail (pure-tls::record-layer-write-application-data
           layer (%tls12-hex "01"))
          pure-tls:tls-error)
    (is equalp (%tls-alert-record 1 0)
        (ironclad:get-output-stream-octets output)))
  ;; Feed a real plaintext close_notify record through the TLS stream. The
  ;; input side reaches clean EOF and the output side contains one reciprocal.
  (multiple-value-bind (underlying output)
      (%tls-test-two-way-stream (%tls-alert-record 1 0))
    (let* ((stream (make-instance 'pure-tls::tls-client-stream
                                  :stream underlying))
           (layer (pure-tls::make-record-layer underlying)))
      (setf (pure-tls::tls-stream-record-layer stream) layer)
      (is eq :fixture-eof (read-byte stream nil :fixture-eof))
      (true (pure-tls::record-layer-peer-close-received-p layer))
      (true (pure-tls::record-layer-local-close-sent-p layer))
      (pure-tls::tls-stream-send-close-notify stream)
      (fail (write-byte 1 stream) pure-tls:tls-error)
      (true (close stream))
      (false (open-stream-p stream))
      (is equalp (%tls-alert-record 1 0)
          (ironclad:get-output-stream-octets output)))))

(define-test net/tls13-malformed-record-alert-wire-contract
  (dolist (input
           (list
            ;; Invalid outer content type, otherwise a complete empty record.
            (make-array 5 :element-type '(unsigned-byte 8)
                          :initial-contents '(25 3 3 0 0))
            ;; A malformed one-byte alert record.
            (make-array 6 :element-type '(unsigned-byte 8)
                          :initial-contents '(21 3 3 0 1 2))
            ;; Empty post-handshake record.
            (make-array 5 :element-type '(unsigned-byte 8)
                          :initial-contents '(22 3 3 0 0))))
    (multiple-value-bind (underlying output)
        (%tls-test-two-way-stream input)
      (let* ((stream (make-instance 'pure-tls::tls-client-stream
                                    :stream underlying))
             (layer (pure-tls::make-record-layer underlying)))
        (setf (pure-tls::tls-stream-record-layer stream) layer)
        (fail (read-byte stream) pure-tls:tls-error)
        (is equalp (%tls-alert-record 2 pure-tls:+alert-decode-error+)
            (ironclad:get-output-stream-octets output))))))

(define-test net/tls12-client-hello-contract
  (let* ((random (make-array 32 :element-type '(unsigned-byte 8) :initial-element #x5a))
         (message (clun.net::%tls12-client-hello "registry.npmjs.org" random))
         (body (subseq message 4)))
    (is = 1 (aref message 0))
    (is = (length body) (clun.net::%tls12-read-u24 message 1))
    (is = #x0303 (clun.net::%tls12-read-u16 body 0))
    (is equalp random (subseq body 2 34))
    ;; SNI and ALPN are present as bytes; EMS is a zero-length extension.
    (true (search (clun.net::%tls12-ascii "registry.npmjs.org") body))
    (true (search (clun.net::%tls12-ascii "http/1.1") body))
    (true (search (clun.net::%tls12-cat (clun.net::%tls12-u16 23)
                                        (clun.net::%tls12-u16 0))
                  body))
    (true (search (clun.net::%tls12-u16 clun.net::+tls12-fallback-scsv+)
                  body))))

(define-test net/tls-fallback-alert-is-exact
  (true (clun.net::%protocol-version-alert-p
         (make-condition 'pure-tls:tls-alert-error
                         :level pure-tls::+alert-level-fatal+
                         :description pure-tls:+alert-protocol-version+)))
  ;; TLS 1.3 ignores the legacy level byte; the description remains the exact
  ;; semantically fatal downgrade trigger.
  (true (clun.net::%protocol-version-alert-p
         (make-condition 'pure-tls:tls-alert-error
                         :level pure-tls::+alert-level-warning+
                         :description pure-tls:+alert-protocol-version+)))
  (false (clun.net::%protocol-version-alert-p
          (make-condition 'pure-tls:tls-alert-error
                          :level pure-tls::+alert-level-fatal+
                          :description pure-tls:+alert-bad-record-mac+))))

(define-test net/tls13-abrupt-eof-is-not-clean-eof
  (let* ((underlying
           (ironclad:make-octet-input-stream
            (make-array 0 :element-type '(unsigned-byte 8))))
         (stream (make-instance 'pure-tls::tls-client-stream
                                :stream underlying)))
    (setf (pure-tls::tls-stream-record-layer stream)
          (pure-tls::make-record-layer underlying))
    (fail (read-byte stream) pure-tls::tls-connection-closed)
    (fail (read-sequence
           (make-array 1 :element-type '(unsigned-byte 8)) stream)
          pure-tls::tls-connection-closed)))

(define-test net/tls12-server-hello-rejects-downgrade
  (flet ((hello (version suite compression &key random extensions)
           (clun.net::%tls12-handshake-message
            2 (clun.net::%tls12-cat
               (clun.net::%tls12-u16 version)
               (or random
                   (make-array 32 :element-type '(unsigned-byte 8)
                                  :initial-element 0))
               (clun.net::%tls12-u8 0)
               (clun.net::%tls12-u16 suite)
               (clun.net::%tls12-u8 compression)
               (clun.net::%tls12-vector16
                (or extensions
                    (make-array 0 :element-type '(unsigned-byte 8))))))))
    (fail (clun.net::%tls12-parse-server-hello
           (hello #x0302 clun.net::+tls12-suite-ecdhe-rsa-aes128-gcm-sha256+ 0))
          clun.net::tls12-error)
    (fail (clun.net::%tls12-parse-server-hello
           (hello #x0303 #x002f 0)) ; RSA key exchange/CBC are not accepted
          clun.net::tls12-error)
    (fail (clun.net::%tls12-parse-server-hello
           (hello #x0303 clun.net::+tls12-suite-ecdhe-rsa-aes128-gcm-sha256+ 1))
          clun.net::tls12-error)
    (dolist (sentinel '(#(#x44 #x4f #x57 #x4e #x47 #x52 #x44 #x01)
                        #(#x44 #x4f #x57 #x4e #x47 #x52 #x44 #x00)))
      (let ((random (make-array 32 :element-type '(unsigned-byte 8)
                                   :initial-element 0)))
        (replace random sentinel :start1 24)
        (fail (clun.net::%tls12-parse-server-hello
               (hello #x0303 clun.net::+tls12-suite-ecdhe-rsa-aes128-gcm-sha256+
                      0 :random random))
              clun.net::tls12-error)))
    (fail (clun.net::%tls12-parse-server-hello
           (hello #x0303 clun.net::+tls12-suite-ecdhe-rsa-aes128-gcm-sha256+ 0
                  :extensions
                  (clun.net::%tls12-cat
                   (clun.net::%tls12-extension
                    23 (make-array 0 :element-type '(unsigned-byte 8)))
                   (clun.net::%tls12-extension
                    23 (make-array 0 :element-type '(unsigned-byte 8))))))
          clun.net::tls12-error)
    (fail (clun.net::%tls12-parse-server-hello
           (hello #x0303 clun.net::+tls12-suite-ecdhe-rsa-aes128-gcm-sha256+ 0
                  :extensions
                  (clun.net::%tls12-extension
                   23 (make-array 1 :element-type '(unsigned-byte 8)
                                     :initial-element 0))))
          clun.net::tls12-error)))

(define-test net/tls12-server-hello-extension-policy
  (flet ((hello (&rest extensions)
           (clun.net::%tls12-handshake-message
            2 (clun.net::%tls12-cat
               (clun.net::%tls12-u16 #x0303)
               (make-array 32 :element-type '(unsigned-byte 8)
                              :initial-element 0)
               (clun.net::%tls12-u8 0)
               (clun.net::%tls12-u16
                clun.net::+tls12-suite-ecdhe-rsa-aes128-gcm-sha256+)
               (clun.net::%tls12-u8 0)
               (clun.net::%tls12-vector16
                (apply #'clun.net::%tls12-cat extensions))))))
    ;; The modern fallback profile requires EMS and accepts only extensions
    ;; legitimately offered by its ClientHello (plus renegotiation_info via
    ;; SCSV).
    (multiple-value-bind (random suite ems)
        (clun.net::%tls12-parse-server-hello
         (hello
          (clun.net::%tls12-extension
           11 (make-array 2 :element-type '(unsigned-byte 8)
                            :initial-contents '(1 0)))
          (clun.net::%tls12-extension
           16 (clun.net::%tls12-vector16
               (clun.net::%tls12-cat
                (clun.net::%tls12-u8 8)
                (clun.net::%tls12-ascii "http/1.1"))))
          (clun.net::%tls12-extension
           23 (make-array 0 :element-type '(unsigned-byte 8)))
          (clun.net::%tls12-extension
           #xff01 (make-array 1 :element-type '(unsigned-byte 8)
                                :initial-element 0))))
      (is = 32 (length random))
      (is = clun.net::+tls12-suite-ecdhe-rsa-aes128-gcm-sha256+ suite)
      (true ems))
    (fail
     (clun.net::%tls12-parse-server-hello
      (hello
       (clun.net::%tls12-extension
        23 (make-array 0 :element-type '(unsigned-byte 8)))
       ;; session_ticket was not offered by this non-resuming client.
       (clun.net::%tls12-extension
        35 (make-array 0 :element-type '(unsigned-byte 8)))))
     clun.net::tls12-error)
    ;; RFC 8422 section 5.2 uses a uint8-length vector and requires the
    ;; uncompressed point format (0) whenever the extension is present.
    (dolist (point-formats '(#()
                             #(0)
                             #(2 0)
                             #(1 1)))
      (fail
       (clun.net::%tls12-parse-server-hello
        (hello
         (clun.net::%tls12-extension 11 point-formats)
         (clun.net::%tls12-extension
          23 (make-array 0 :element-type '(unsigned-byte 8)))))
       clun.net::tls12-error))
    ;; RFC 7301 section 3.1 permits exactly one non-empty protocol in the
    ;; ServerHello response. Empty, truncated, and unoffered h2 responses fail.
    (dolist (alpn '(#()
                    #(0 9 8 104 116 116 112)
                    #(0 3 2 104 50)))
      (fail
       (clun.net::%tls12-parse-server-hello
        (hello
         (clun.net::%tls12-extension 16 alpn)
         (clun.net::%tls12-extension
          23 (make-array 0 :element-type '(unsigned-byte 8)))))
       clun.net::tls12-error))
    (fail
     (clun.net::%tls12-parse-server-hello (hello))
     clun.net::tls12-error)))

(define-test net/tls12-rejects-oversized-authenticated-plaintext
  (let ((payload (make-array (+ 8 16 (1+ clun.net::+tls12-max-plaintext+))
                             :element-type '(unsigned-byte 8)
                             :initial-element 0)))
    (fail (clun.net::%tls12-decrypt-record
           (clun.net::make-tls12-state
            :server-key (make-array 16 :element-type '(unsigned-byte 8)
                                       :initial-element 0)
            :server-iv (make-array 4 :element-type '(unsigned-byte 8)
                                     :initial-element 0))
           23 payload)
          clun.net::tls12-error)))

(define-test net/tls12-nonresuming-profile-rejects-session-ticket
  (let ((state (clun.net::make-tls12-state)))
    (fail
     (clun.net::%tls12-handle-server-pre-finished-message
      state 4 (clun.net::%tls12-handshake-message
               4 (make-array 0 :element-type '(unsigned-byte 8))))
     clun.net::tls12-error)
    (is eq :ccs
        (clun.net::%tls12-handle-server-pre-finished-message
         state :ccs (make-array 1 :element-type '(unsigned-byte 8)
                                  :initial-element 1)))
    (true (clun.net::tls12-server-encrypted-p state))))

(define-test net/tls12-eof-framing-requires-close-notify
  (flet ((wire (text)
           (sb-ext:string-to-octets text :external-format :utf-8)))
    (let ((until-close
            (wire (format nil "HTTP/1.1 200 OK~c~cConnection: close~c~c~c~cabc"
                          #\Return #\Linefeed #\Return #\Linefeed
                          #\Return #\Linefeed)))
          (content-length
            (wire (format nil "HTTP/1.1 200 OK~c~cContent-Length: 3~c~c~c~cabc"
                          #\Return #\Linefeed #\Return #\Linefeed
                          #\Return #\Linefeed))))
      (fail (clun.net::%parse-http-response-octets
             until-close :clean-eof-p nil)
            error)
      (is string= "abc"
          (sb-ext:octets-to-string
           (clun.net:hres-body
            (clun.net::%parse-http-response-octets
             until-close :clean-eof-p t))
           :external-format :utf-8))
      ;; Explicit HTTP framing proves completeness even when the peer omits
      ;; close_notify after the complete authenticated TLS application record.
      (is string= "abc"
          (sb-ext:octets-to-string
           (clun.net:hres-body
            (clun.net::%parse-http-response-octets
             content-length :clean-eof-p nil))
           :external-format :utf-8)))))

(define-test net/http-content-decoding-is-bounded-and-fail-closed
  (flet ((response (body)
           (clun.net::make-http-response
            :headers '(("content-encoding" . "gzip")) :body body)))
    (let ((clun.net:*max-decoded-body-bytes* 17))
      (is string= "gzip-decoded-body"
          (sb-ext:octets-to-string
           (clun.net:hres-body (clun.net::%decode-body (response *gz-blob*)))
           :external-format :utf-8)))
    (let ((clun.net:*max-decoded-body-bytes* 16))
      (fail (clun.net::%decode-body (response *gz-blob*))
            clun.net:http-content-decoding-error))
    (fail (clun.net::%decode-body
           (response (make-array 8 :element-type '(unsigned-byte 8)
                                   :initial-element #xff)))
          clun.net:http-content-decoding-error)))

(defun %https-identity-cert (common-name san-values)
  "Build a minimal certificate object for Clun HTTPS identity-policy tests."
  (pure-tls::make-x509-certificate
   :subject (pure-tls::make-x509-name
             :rdns (list (cons :common-name common-name)))
   :extensions (when san-values
                 (list (pure-tls::make-x509-extension
                        :oid :subject-alt-name :value san-values)))))

(define-test net/https-identity-is-san-only-and-chain-is-bounded
  "Both HTTPS transports share an eight-entry, SAN-only identity policy."
  (let* ((context (clun.net::%make-https-tls-context nil))
         (policy (pure-tls::tls-context-hostname-policy context)))
    (is = clun.net::+https-maximum-certificate-chain-depth+
        (pure-tls::tls-context-verify-depth context))
    ;; No SAN: matching Common Name is deliberately not an identity.
    (fail (pure-tls:verify-hostname
           (%https-identity-cert "www.example.test" nil)
           "www.example.test" :policy policy)
          pure-tls:tls-verification-error)
    ;; Email-only SAN: SAN is present, but carries no DNS/IP identity.
    (fail (pure-tls:verify-hostname
           (%https-identity-cert
            "www.example.test" '((:email "ops@example.test")))
           "www.example.test" :policy policy)
          pure-tls:tls-verification-error)
    ;; An explicitly empty SAN also cannot unlock Common Name fallback.
    (let ((empty-san
            (pure-tls::make-x509-certificate
             :subject (pure-tls::make-x509-name
                       :rdns '((:common-name . "www.example.test")))
             :extensions (list (pure-tls::make-x509-extension
                                :oid :subject-alt-name :value nil)))))
      (fail (pure-tls:verify-hostname empty-san "www.example.test"
                                      :policy policy)
            pure-tls:tls-verification-error))
    (true (pure-tls:verify-hostname
           (%https-identity-cert
            "ignored.example.test" '((:dns "www.example.test")))
           "www.example.test" :policy policy))
    ;; IP references match only the exact iPAddress SAN octets.
    (let ((ip-cert (%https-identity-cert
                    "127.0.0.2"
                    (list (list :ip #(127 0 0 1))))))
      (true (pure-tls:verify-hostname ip-cert "127.0.0.1" :policy policy))
      (fail (pure-tls:verify-hostname ip-cert "127.0.0.2" :policy policy)
            pure-tls:tls-verification-error))))

(define-test net/tls12-certificate-list-enforces-context-bound
  "TLS 1.2 refuses oversized peer certificate counts and bytes before validation."
  (let* ((pem (pure-tls::read-file-bytes
               (asdf:system-relative-pathname
                :pure-tls "test/certs/webpki-root.pem")))
         (der (pure-tls::pem-decode pem "CERTIFICATE"))
         (entry (clun.net::%tls12-cat
                 (clun.net::%tls12-u24 (length der)) der))
         (entries (apply #'clun.net::%tls12-cat
                         (loop repeat (1+ clun.net::+https-maximum-certificate-chain-depth+)
                               collect entry)))
         (message (clun.net::%tls12-handshake-message
                   11 (clun.net::%tls12-cat
                       (clun.net::%tls12-u24 (length entries)) entries))))
    (fail (clun.net::%tls12-parse-certificates message)
          clun.net::tls12-error)
    (let* ((oversized
             (make-array
              (1+ clun.net::+https-maximum-certificate-list-bytes+)
              :element-type '(unsigned-byte 8) :initial-element 0))
           (oversized-message
             (clun.net::%tls12-handshake-message
              11 (clun.net::%tls12-cat
                  (clun.net::%tls12-u24 (length oversized)) oversized))))
      (fail (clun.net::%tls12-parse-certificates oversized-message)
            clun.net::tls12-error))))
