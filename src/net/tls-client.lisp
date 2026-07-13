;;;; tls-client.lisp — a BLOCKING TLS 1.3 HTTP/1.1 client over vendored pure-tls (PLAN.md
;;;; Phase 20, §3.2/§3.4). pure-tls does a blocking handshake + blocking byte I/O over a
;;;; gray stream, so HTTPS runs on the worker pool (off the JS loop). Reuses the plaintext
;;;; client's request serializer + the Phase-17 response parser + gzip decode. Certificates
;;;; always fail CLOSED (verify-required); the caller maps the signaled condition to a JS
;;;; error. Pure CL, no engine dep — the fetch layer drives it via lp:worker-submit.

(in-package :clun.net)

(defparameter *system-ca-candidates*
  '("/etc/ssl/certs/ca-certificates.crt"    ; debian/ubuntu/arch
    "/etc/pki/tls/certs/ca-bundle.crt"       ; rhel/fedora
    "/etc/ssl/cert.pem"                      ; alpine/openbsd
    "/etc/ssl/ca-bundle.pem")                ; suse
  "Well-known Linux system CA-bundle paths, probed in order (§3.4).")

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
    (pure-tls:tls-verification-error (format nil "certificate verification failed: ~a" c))
    (pure-tls:tls-alert-error        (format nil "TLS alert: ~a" c))
    (pure-tls:tls-certificate-error  (format nil "certificate rejected: ~a" c)) ; expired/not-yet-valid/…
    (pure-tls:tls-error              (format nil "TLS error: ~a" c))
    (socket-open-error               (format nil "connect failed: ~a" (socket-open-error-code c)))
    (t                               (format nil "TLS request failed: ~a" c))))

(defun %read-to-eof (stream)
  "Read STREAM to EOF into an octet vector. We send `Connection: close`, so the peer closes
after the response. A clean close_notify makes read-sequence return 0; an abrupt socket close
makes it SIGNAL — either way we stop and return what we've accumulated, letting the response
parser judge completeness (a truly truncated response then fails the parse, i.e. fails closed)."
  (let ((acc (make-array 65536 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
        (buf (make-array 65536 :element-type '(unsigned-byte 8))))
    (handler-case
        (loop
          (let ((n (read-sequence buf stream)))
            (when (zerop n) (return))
            (let ((old (fill-pointer acc)))
              (adjust-array acc (+ old n) :fill-pointer (+ old n))
              (replace acc buf :start1 old :end1 (+ old n) :end2 n))))
      (error () nil))              ; peer closed / stream error → end of the response
    (subseq acc 0 (fill-pointer acc))))

(defun https-request (&key host port method path headers body host-header
                           (ca-file (%system-ca-file)) (verify t) socket-box)
  "Issue one BLOCKING HTTPS request (run on a worker thread) and return the parsed + decoded
http-response. Connects, does the pure-tls handshake + chain/hostname verification (unless
VERIFY is NIL), sends the serialized request, reads the response to EOF, parses + gunzips it.
Signals on connect / handshake / verification / parse failure — the caller maps the condition
(see tls-error-message). If SOCKET-BOX (a cons) is supplied, its car is set to the socket so
an abort can close it to unblock the blocking read."
  (let ((ip (resolve-hostname host)) (sock nil) (tls nil))
    (unwind-protect
         (progn
           (setf sock (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
           ;; hand the caller a CLOSE THUNK (not the socket) so the fetch layer can abort a
           ;; blocking request by closing the fd — no sb-bsd-sockets reach-through in runtime.
           (when socket-box (setf (car socket-box) (lambda () (ignore-errors (sb-bsd-sockets:socket-close sock)))))
           (handler-case
               (sb-bsd-sockets:socket-connect sock (sb-bsd-sockets:make-inet-address ip) port)
             (sb-bsd-sockets:socket-error (e)
               (error 'socket-open-error :code (socket-error-code e "ECONNREFUSED") :op "connect")))
           (let* ((raw (sb-bsd-sockets:socket-make-stream sock :input t :output t
                                                               :element-type '(unsigned-byte 8)))
                  (ctx (if ca-file (pure-tls:make-tls-context :ca-file ca-file)
                           (pure-tls:make-tls-context))))
             (setf tls (pure-tls:make-tls-client-stream
                        raw :hostname host
                            :verify (if verify pure-tls:+verify-required+ pure-tls:+verify-none+)
                            :context ctx))
             (write-sequence (%serialize-request method path (or host-header host) headers body) tls)
             (force-output tls)
             (let ((parser (make-http-response-parser)))
               (multiple-value-bind (ev d) (parser-feed parser (%read-to-eof tls))
                 (case ev
                   (:response (%decode-body d))
                   (:error (error "HTTP parse error ~a" (car d)))
                   (t (multiple-value-bind (ev2 d2) (response-finish parser)  ; until-close body
                        (if (eq ev2 :response) (%decode-body d2)
                            (error "connection closed before a full response")))))))))
      (ignore-errors (when tls (close tls)))
      (ignore-errors (when sock (sb-bsd-sockets:socket-close sock))))))
