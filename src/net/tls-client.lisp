;;;; tls-client.lisp — a BLOCKING TLS 1.3 HTTP/1.1 client over vendored pure-tls (PLAN.md
;;;; Phase 20, §3.2/§3.4). pure-tls does a blocking handshake + blocking byte I/O over a
;;;; gray stream, so HTTPS runs on the worker pool (off the JS loop). Reuses the plaintext
;;;; client's request serializer + the Phase-17 response parser + gzip decode. Certificates
;;;; always fail CLOSED (verify-required); the caller maps the signaled condition to a JS
;;;; error. Pure CL, no engine dep — the fetch layer drives it via lp:worker-submit.

(in-package :clun.net)

(defparameter *system-ca-candidates*
  '("/etc/ssl/certs/ca-certificates.crt"    ; debian/ubuntu/arch
    "/etc/ssl/certs/ca-bundle.crt"          ; nixos
    "/etc/pki/tls/certs/ca-bundle.crt"       ; rhel/fedora
    "/etc/ssl/cert.pem"                      ; alpine/openbsd/macos
    "/etc/ssl/ca-bundle.pem"                 ; suse
    "/opt/homebrew/etc/ca-certificates/cert.pem" ; homebrew arm64 macos
    "/usr/local/etc/ca-certificates/cert.pem")   ; homebrew x64 macos
  "Well-known Linux and macOS CA-bundle paths, probed in order (§3.4).")

(defun %system-ca-file ()
  "The CA bundle to trust: $SSL_CERT_FILE if set (OpenSSL/Node convention), else the first
existing well-known system bundle, else NIL (no anchor → verification fails closed)."
  (or (let ((e (sb-ext:posix-getenv "SSL_CERT_FILE"))) (and e (plusp (length e)) e))
      (find-if #'probe-file *system-ca-candidates*)))

(defun tls-error-message (c)
  "A descriptive, distinct message for a TLS / verify / connect failure. Verification errors
are checked before the base certificate-error (tls-verification-error subclasses it); the
condition's own report distinguishes expired vs wrong-host vs untrusted-CA vs bad-chain."
  (typecase c
    (tls12-error                     (format nil "TLS 1.2 error: ~a" c))
    (pure-tls:tls-verification-error (format nil "certificate verification failed: ~a" c))
    (pure-tls:tls-alert-error        (format nil "TLS alert: ~a" c))
    (pure-tls:tls-certificate-error  (format nil "certificate rejected: ~a" c)) ; expired/not-yet-valid/…
    (pure-tls:tls-error              (format nil "TLS error: ~a" c))
    (socket-open-error               (format nil "connect failed: ~a" (socket-open-error-code c)))
    (t                               (format nil "TLS request failed: ~a" c))))

(defun %protocol-version-alert-p (condition)
  "Whether CONDITION is the peer explicitly declining the TLS 1.3-only offer. Only
this alert enables the TLS 1.2 fallback; certificate, MAC, parse, and all other TLS
failures remain terminal and can never downgrade authentication."
  (and (typep condition 'pure-tls:tls-alert-error)
       (= (pure-tls::tls-alert-error-level condition)
          pure-tls::+alert-level-fatal+)
       (= (pure-tls::tls-alert-error-description condition)
          pure-tls:+alert-protocol-version+)))

(defun %read-to-eof (stream)
  "Read a bounded response to authenticated TLS EOF. TLS errors, including an
abrupt TCP close without close_notify, remain terminal rather than being mistaken
for response completion."
  (let* ((limit (+ *max-header-bytes* *max-body-bytes*))
         (initial-capacity (min 65536 (max 1 limit)))
         (acc (make-array initial-capacity :element-type '(unsigned-byte 8)
                                           :adjustable t :fill-pointer 0))
         (buf (make-array 65536 :element-type '(unsigned-byte 8))))
    (loop
      (let ((n (read-sequence buf stream)))
        (when (zerop n) (return))
        (let* ((old (fill-pointer acc))
               (new (+ old n)))
          (when (> new limit)
            (error "TLS HTTP response exceeds transport bound"))
          (when (> new (array-total-size acc))
            (adjust-array acc
                          (min limit
                               (max new (* 2 (array-total-size acc))))
                          :fill-pointer old))
          (setf (fill-pointer acc) new)
          (replace acc buf :start1 old :end1 new :end2 n))))
    (subseq acc 0 (fill-pointer acc))))

(defun %parse-http-response-octets (octets &key (clean-eof-p t))
  (let ((parser (make-http-response-parser)))
    (multiple-value-bind (event data) (parser-feed parser octets)
      (case event
        (:response (%decode-body data))
        (:error (error "HTTP parse error ~a" (car data)))
        (t (multiple-value-bind (final-event final-data) (response-finish parser)
             (cond
               ((and (eq final-event :response) clean-eof-p)
                (%decode-body final-data))
               ((eq final-event :response)
                (error "TLS peer closed without close_notify for an EOF-framed response"))
               (t (error "connection closed before a full response")))))))))

(defun https-request (&key host port method path headers body host-header
                           (ca-file (%system-ca-file)) (verify t) socket-box)
  "Issue one BLOCKING HTTPS request (run on a worker thread) and return the parsed + decoded
http-response. Connects, does the pure-tls handshake + chain/hostname verification (unless
VERIFY is NIL), sends the serialized request, reads the response to EOF, parses + gunzips it.
Signals on connect / handshake / verification / parse failure — the caller maps the condition
(see tls-error-message). If SOCKET-BOX (a cons) is supplied, its car is set to the socket so
an abort can close it to unblock the blocking read."
  (let ((ip (resolve-hostname host)) (sock nil) (raw nil) (tls nil)
        (request (%serialize-request method path (or host-header host) headers body)))
    (labels ((close-transport ()
               (ignore-errors (when tls (close tls)))
               (ignore-errors (when raw (close raw)))
               (ignore-errors (when sock (sb-bsd-sockets:socket-close sock)))
               (setf tls nil raw nil sock nil))
             (connect-transport ()
               (setf sock (make-instance 'sb-bsd-sockets:inet-socket
                                         :type :stream :protocol :tcp))
               ;; The thunk follows SOCK across a TLS-version retry, so abort always
               ;; closes the currently active descriptor rather than the first one.
               (when socket-box
                 (setf (car socket-box)
                       (lambda ()
                         (ignore-errors
                           (when sock (sb-bsd-sockets:socket-close sock))))))
               (handler-case
                   (sb-bsd-sockets:socket-connect
                    sock (sb-bsd-sockets:make-inet-address ip) port)
                 (sb-bsd-sockets:socket-error (error)
                   (error 'socket-open-error
                          :code (socket-error-code error "ECONNREFUSED") :op "connect")))
               (setf raw (sb-bsd-sockets:socket-make-stream
                          sock :input t :output t :element-type '(unsigned-byte 8)))))
    (unwind-protect
         (progn
           (connect-transport)
           (let ((fallback-p nil)
                 (context (if ca-file
                              (pure-tls:make-tls-context :ca-file ca-file)
                              (pure-tls:make-tls-context))))
             ;; make-tls-client-stream eagerly completes the handshake. Keep the
             ;; downgrade handler around construction only, before request bytes
             ;; can be sent; a later alert can therefore never replay a request.
             (handler-case
                 (setf tls (pure-tls:make-tls-client-stream
                            raw :hostname host
                                :verify (if verify
                                            pure-tls:+verify-required+
                                            pure-tls:+verify-none+)
                                :alpn-protocols '("http/1.1")
                                :context context))
               (pure-tls:tls-alert-error (condition)
                 (unless (%protocol-version-alert-p condition)
                   (error condition))
                 (setf fallback-p t)))
             (if fallback-p
                 (progn
                   ;; A fresh connection is mandatory: the first peer consumed
                   ;; the TLS 1.3 ClientHello and sent a fatal alert.
                   (close-transport)
                   (connect-transport)
                   (multiple-value-bind (wire clean-eof-p)
                       (https-request-tls12 raw host request
                                            :ca-file ca-file :verify verify)
                     (%parse-http-response-octets wire
                                                  :clean-eof-p clean-eof-p)))
                 (progn
                   (write-sequence request tls)
                   (force-output tls)
                   (%parse-http-response-octets (%read-to-eof tls))))))
      (close-transport)))))
