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

(defun %dns-address-socket (address)
  (make-instance (if (dns-address-ipv6-p address)
                     'sb-bsd-sockets:inet6-socket
                     'sb-bsd-sockets:inet-socket)
                 :type :stream :protocol :tcp))

(defun %dns-address-native (address)
  (if (dns-address-ipv6-p address)
      (sb-bsd-sockets:make-inet6-address (dns-address-text address))
      (sb-bsd-sockets:make-inet-address (dns-address-text address))))

(defun %connect-happy-blocking (addresses port socket-box timeout-ms)
  "Connect a blocking-worker transport with the same staggered A/AAAA policy as the
reactor client. Candidate sockets are nonblocking while raced and no helper thread is
created. The winning socket is restored to blocking mode for pure-tls."
  (let* ((candidates (coerce addresses 'vector))
         (count (length candidates))
         (next-index 0)
         (attempts '())
         (start-ms (%monotonic-ms))
         (deadline (+ start-ms timeout-ms))
         (next-start start-ms)
         (last-code "ECONNREFUSED")
         (cancel-lock (sb-thread:make-mutex :name "clun-happy-eyeballs-abort"))
         (cancelled nil))
    (labels ((close-socket (socket)
               (ignore-errors (sb-bsd-sockets:socket-close socket :abort t)))
             (close-all (&optional except)
               (dolist (attempt attempts)
                 (unless (eq (car attempt) except)
                   (close-socket (car attempt)))))
             (abort-all ()
               (sb-thread:with-mutex (cancel-lock)
                 (setf cancelled t)
                 (close-all)))
             (start-candidate ()
               (when (< next-index count)
                 (let* ((address (aref candidates next-index))
                        (socket (%dns-address-socket address)))
                   (incf next-index)
                   (setf (sb-bsd-sockets:non-blocking-mode socket) t)
                   (handler-case
                       (progn
                         (sb-bsd-sockets:socket-connect
                          socket (%dns-address-native address) port)
                         (push (cons socket :connected) attempts))
                     (sb-bsd-sockets:operation-in-progress ()
                       (push (cons socket :pending) attempts))
                     (sb-bsd-sockets:socket-error (condition)
                       (setf last-code (socket-error-code condition "ECONNREFUSED"))
                       (close-socket socket))))))
             (poll-winner ()
               (dolist (attempt attempts)
                 (let ((socket (car attempt)))
                   (cond
                     ((eq (cdr attempt) :connected) (return-from poll-winner socket))
                     ((eq (cdr attempt) :pending)
                      (handler-case
                          (let ((errno (sb-bsd-sockets:sockopt-error socket)))
                            (cond
                              ((and (zerop errno)
                                    (ignore-errors
                                      (sb-bsd-sockets:socket-peername socket)))
                               (setf (cdr attempt) :connected)
                               (return-from poll-winner socket))
                              ((not (zerop errno))
                               (setf (cdr attempt) :failed
                                     last-code "ECONNREFUSED")
                               (close-socket socket))))
                        (sb-bsd-sockets:socket-error (condition)
                          (setf (cdr attempt) :failed
                                last-code (socket-error-code condition "ECONNREFUSED"))
                          (close-socket socket)))))))
               nil)
             (live-attempt-p ()
               (find-if (lambda (attempt)
                          (member (cdr attempt) '(:pending :connected)))
                        attempts)))
      (when socket-box (setf (car socket-box) #'abort-all))
      (unwind-protect
           (loop
             (when cancelled
               (error 'socket-open-error :code "ECANCELED" :op "connect"))
             (let ((now (%monotonic-ms)))
               (when (>= now deadline)
                 (error 'socket-open-error :code "ETIMEDOUT" :op "connect"))
               (when (and (< next-index count)
                          (or (>= now next-start) (not (live-attempt-p))))
                 (start-candidate)
                 (setf next-start (+ now *happy-eyeballs-delay-ms*)))
               (let ((winner (poll-winner)))
                 (when winner
                   (close-all winner)
                   (setf (sb-bsd-sockets:non-blocking-mode winner) nil)
                   (when socket-box
                     (setf (car socket-box)
                           (lambda ()
                             (sb-thread:with-mutex (cancel-lock)
                               (setf cancelled t)
                               (close-socket winner)))))
                   (return winner)))
               (when (and (= next-index count) (not (live-attempt-p)))
                 (error 'socket-open-error :code last-code :op "connect"))
               (sleep 0.005)))
        ;; On success the returned winner is removed from ATTEMPTS so cleanup leaves it open.
        (when (and attempts
                   (find-if (lambda (attempt) (eq (cdr attempt) :connected)) attempts))
          (setf attempts
                (remove-if (lambda (attempt) (eq (cdr attempt) :connected)) attempts)))
        (close-all)))))

(defun https-request (&key host port method path headers body host-header
                           (ca-file (%system-ca-file)) (verify t) socket-box
                           (connect-timeout-ms 30000))
  "Issue one BLOCKING HTTPS request (run on a worker thread) and return the parsed + decoded
http-response. Connects, does the pure-tls handshake + chain/hostname verification (unless
VERIFY is NIL), sends the serialized request, reads the response to EOF, parses + gunzips it.
Signals on connect / handshake / verification / parse failure — the caller maps the condition
(see tls-error-message). If SOCKET-BOX (a cons) is supplied, its car is set to the socket so
an abort can close it to unblock the blocking read."
  (let ((addresses (resolve-hostname-all host)) (sock nil) (raw nil) (tls nil)
        (request (%serialize-request method path (or host-header host) headers body)))
    (labels ((close-transport ()
               (ignore-errors (when tls (close tls)))
               (ignore-errors (when raw (close raw)))
               (ignore-errors (when sock (sb-bsd-sockets:socket-close sock)))
               (setf tls nil raw nil sock nil))
             (connect-transport ()
               (setf sock (%connect-happy-blocking addresses port socket-box
                                                   connect-timeout-ms))
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

(defun %make-https-response-stream-dispatcher
    (method on-headers on-data on-complete)
  "Return FEED and EOF closures for one authenticated HTTPS response."
  (let ((parser (make-http-response-stream-parser
                 :head-request-p (string-equal method "HEAD")))
        (content-format nil)
        (encoded-body nil)
        (message-complete-p nil)
        (finalized-p nil))
    (labels
        ((finalize ()
           (unless finalized-p
             (setf finalized-p t)
             (when encoded-body
               (let ((decoded
                       (%decompress-body-bounded
                        content-format
                        (subseq encoded-body 0 (fill-pointer encoded-body)))))
                 (when (and on-data (plusp (length decoded)))
                   (funcall on-data decoded))))
             (when on-complete (funcall on-complete))))
         (deliver (events)
           (dolist (event events)
             (case (car event)
               (:headers
                (let ((encoding (%response-content-encoding (cdr event))))
                  (cond
                    ((and encoding (search "gzip" encoding))
                     (setf content-format :gzip))
                    ((and encoding (search "deflate" encoding))
                     (setf content-format :zlib)))
                  (when content-format
                    (setf encoded-body
                          (make-array (* 64 1024)
                                      :element-type '(unsigned-byte 8)
                                      :adjustable t :fill-pointer 0)))
                  (when on-headers (funcall on-headers (cdr event)))))
               (:data
                (if encoded-body
                    (%stream-append-bounded
                     encoded-body (cdr event) *max-body-bytes*)
                    (when on-data (funcall on-data (cdr event)))))
               (:complete
                (setf message-complete-p t)
                (finalize))
               (:error
                (error "HTTP parse error ~a" (car (cdr event))))))
           message-complete-p)
         (feed (octets)
           (deliver (response-stream-feed parser octets)))
         (eof (clean-eof-p)
           (unless clean-eof-p
             (error "TLS peer closed without close_notify before the HTTP response completed"))
           (deliver (response-stream-finish parser))
           (unless message-complete-p
             (error "connection closed before a full response"))
           message-complete-p))
      (values #'feed #'eof))))

(defun https-request-stream
    (&key host port method path headers body host-header
          (ca-file (%system-ca-file)) (verify t) socket-box
          (connect-timeout-ms 30000) request-body-source
          on-headers on-data on-complete)
  "Issue one blocking HTTPS request and deliver its response incrementally.

This preserves HTTPS-REQUEST's DNS, Happy Eyeballs, TLS 1.3-to-1.2 fallback,
certificate/hostname verification, authenticated records, decompression bounds,
and abort socket. The caller must run it off the event-loop thread. Callbacks run
on that worker thread; an asynchronous caller is responsible for loop marshalling."
  (let ((addresses (resolve-hostname-all host))
        (sock nil)
        (raw nil)
        (tls nil)
        (request (%serialize-request method path (or host-header host)
                                     headers body "identity"
                                     (not (null request-body-source)))))
    (labels ((close-transport ()
               (ignore-errors (when tls (close tls)))
               (ignore-errors (when raw (close raw)))
               (ignore-errors (when sock (sb-bsd-sockets:socket-close sock)))
               (setf tls nil raw nil sock nil))
             (connect-transport ()
               (setf sock (%connect-happy-blocking addresses port socket-box
                                                   connect-timeout-ms))
               (setf raw
                     (sb-bsd-sockets:socket-make-stream
                      sock :input t :output t
                      :element-type '(unsigned-byte 8)))))
      (unwind-protect
           (progn
             (connect-transport)
             (multiple-value-bind (feed finish-at-eof)
                 (%make-https-response-stream-dispatcher
                  method on-headers on-data on-complete)
               (let ((fallback-p nil)
                     (context (if ca-file
                                  (pure-tls:make-tls-context :ca-file ca-file)
                                  (pure-tls:make-tls-context))))
                 (handler-case
                     (setf tls
                           (pure-tls:make-tls-client-stream
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
                       (close-transport)
                       (connect-transport)
                       (multiple-value-bind (termination clean-eof-p)
                           (https-request-tls12-stream
                            raw host request feed
                            :ca-file ca-file :verify verify
                            :request-body-source request-body-source)
                         (case termination
                           (:message-complete t)
                           (:close-notify (funcall finish-at-eof clean-eof-p))
                           (:eof (funcall finish-at-eof clean-eof-p)))))
                     (progn
                       (write-sequence request tls)
                       (force-output tls)
                       (when request-body-source
                         (let ((total 0))
                           (loop
                             (multiple-value-bind (chunk done-p)
                                 (funcall request-body-source)
                               (when done-p
                                 (write-sequence +chunked-request-end+ tls)
                                 (force-output tls)
                                 (return))
                               (when (plusp (length chunk))
                                 (incf total (length chunk))
                                 (when (> total *max-body-bytes*)
                                   (error
                                    "streaming request body exceeded the size limit"))
                                 (write-sequence
                                  (%chunked-request-frame chunk) tls)
                                 (force-output tls))))))
                       (let ((buffer
                               (make-array 65536
                                           :element-type '(unsigned-byte 8))))
                         (loop
                           (let ((count (read-sequence buffer tls)))
                             (when (zerop count)
                               (funcall finish-at-eof t)
                               (return))
                             (when (funcall feed (subseq buffer 0 count))
                               (return))))))))))
        (close-transport)))))
