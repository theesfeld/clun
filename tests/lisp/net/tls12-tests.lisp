;;;; Focused deterministic tests for the Phase-28 TLS 1.2 transport profile.

(in-package :clun-test)

(defun %tls12-hex (string)
  (ironclad:hex-string-to-byte-array string))

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
  (false (clun.net::%protocol-version-alert-p
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
    (let ((random (make-array 32 :element-type '(unsigned-byte 8)
                                 :initial-element 0)))
      (replace random #(#x44 #x4f #x57 #x4e #x47 #x52 #x44 #x01) :start1 24)
      (fail (clun.net::%tls12-parse-server-hello
             (hello #x0303 clun.net::+tls12-suite-ecdhe-rsa-aes128-gcm-sha256+
                    0 :random random))
            clun.net::tls12-error))
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
