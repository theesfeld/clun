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

(defun %proxy-connect-authority (host port)
  (if (find #\: host)
      (format nil "[~a]:~d" host port)
      (format nil "~a:~d" host port)))

(defun %proxy-connect-request (host port authorization &optional extra-headers)
  (let ((authority (%proxy-connect-authority host port)))
    (%client-ascii-octets
     (with-output-to-string (output)
       (format output "CONNECT ~a HTTP/1.1~c~c" authority #\Return #\Newline)
       (format output "Host: ~a~c~c" authority #\Return #\Newline)
       (format output "Proxy-Connection: keep-alive~c~c" #\Return #\Newline)
       (when authorization
         (format output "Proxy-Authorization: ~a~c~c"
                 (remove-if (lambda (character)
                              (member character '(#\Return #\Newline)))
                            authorization)
                 #\Return #\Newline))
       (dolist (header extra-headers)
         (let ((name (car header))
               (value (cdr header)))
           (when (and name value
                      (not (member name
                                   '("host" "proxy-authorization"
                                     "proxy-connection" "content-length"
                                     "transfer-encoding")
                                   :test #'string-equal)))
             (format output "~a: ~a~c~c"
                     (remove-if (lambda (character)
                                  (member character '(#\Return #\Newline)))
                                (string name))
                     (remove-if (lambda (character)
                                  (member character '(#\Return #\Newline)))
                                (string value))
                     #\Return #\Newline))))
       (format output "~c~c" #\Return #\Newline)))))

(defun %read-proxy-connect-head (stream cancelled-p)
  "Read exactly one bounded CONNECT response head, across any number of socket reads."
  (let ((head (make-array 256 :element-type '(unsigned-byte 8)
                              :adjustable t :fill-pointer 0))
        (w 0) (x 0) (y 0) (z 0))
    (loop
      (when (and cancelled-p (funcall cancelled-p))
        (error 'socket-open-error :code "ECANCELED" :op "proxy CONNECT"))
      (let ((byte (read-byte stream nil nil)))
        (unless byte
          (error "proxy closed before completing the CONNECT response"))
        (when (>= (fill-pointer head) *max-header-bytes*)
          (error "proxy CONNECT response headers exceed the size limit"))
        (vector-push-extend byte head)
        (setf w x x y y z z byte)
        (when (and (= w 13) (= x 10) (= y 13) (= z 10))
          (return))))
    (let* ((octets (subseq head 0 (fill-pointer head)))
           (text (sb-ext:octets-to-string octets :external-format :latin-1))
           (line-end (search (format nil "~c~c" #\Return #\Newline) text)))
      (unless line-end
        (error "malformed proxy CONNECT response"))
      (multiple-value-bind (version status reason)
          (%parse-status-line (subseq text 0 line-end))
        (declare (ignore reason))
        (unless version
          (error "malformed proxy CONNECT status line"))
        (values status octets)))))

(defun %establish-http-connect
    (stream host port authorization cancelled-p &optional extra-headers)
  (write-sequence
   (%proxy-connect-request host port authorization extra-headers) stream)
  (force-output stream)
  (%read-proxy-connect-head stream cancelled-p))

(defun %deliver-proxy-connect-response
    (stream head cancelled-p on-headers on-data on-complete)
  "Surface a non-2xx CONNECT reply as fetch's response without origin redirect handling."
  (multiple-value-bind (feed finish-at-eof)
      (%make-https-response-stream-dispatcher
       "CONNECT"
       (lambda (response)
         (setf (hres-proxy-response-p response) t)
         (when on-headers (funcall on-headers response)))
       on-data on-complete)
    (when (funcall feed head)
      (return-from %deliver-proxy-connect-response t))
    (let ((buffer (make-array 65536 :element-type '(unsigned-byte 8))))
      (loop
        (when (and cancelled-p (funcall cancelled-p))
          (error 'socket-open-error :code "ECANCELED" :op "proxy response"))
        (let ((count (read-sequence buffer stream)))
          (when (zerop count)
            (funcall finish-at-eof t)
            (return t))
          (when (funcall feed (subseq buffer 0 count))
            (return t)))))))

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
                           (connect-timeout-ms 30000) cancelled-p)
  "Issue one BLOCKING HTTPS request (run on a worker thread) and return the parsed + decoded
http-response. Connects, does the pure-tls handshake + chain/hostname verification (unless
VERIFY is NIL), sends the serialized request, reads the response to EOF, parses + gunzips it.
Signals on connect / handshake / verification / parse failure — the caller maps the condition
(see tls-error-message). If SOCKET-BOX (a cons) is supplied, its car is set to the socket so
an abort can close it to unblock the blocking read."
  (let ((addresses (resolve-hostname-all host :cancelled-p cancelled-p))
        (sock nil) (raw nil) (tls nil)
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

;;; --- per-loop HTTPS/TLS connection pool ------------------------------------
;;;
;;; Mirrors the plain HTTP pool's fail-closed reuse rules on the worker-side
;;; pure-tls transport. Keys include TLS configuration so a verified and an
;;; unverified session never mix. Proxy CONNECT tunnels stay one-shot.

(defparameter *tls-pool-max-idle-per-key* 8)
(defparameter *tls-pool-idle-timeout-ms* 30000)
(defconstant +tls-pool-extension-key+ 'tls-connection-pool)

(defstruct (tls-connection-pool (:constructor %make-tls-connection-pool (loop)))
  loop
  (lock (sb-thread:make-mutex :name "clun-tls-connection-pool"))
  (buckets (make-hash-table :test #'equal)))

(defstruct (tls-pool-entry
            (:constructor %make-tls-pool-entry
                (pool key sock raw tls family)))
  pool key sock raw tls family timer resource
  (idle-p t)
  (idle-since-ms 0 :type integer))

(defun %tls-pool (loop)
  (or (lp:loop-extension loop +tls-pool-extension-key+)
      (setf (lp:loop-extension loop +tls-pool-extension-key+)
            (%make-tls-connection-pool loop))))

(defun %socket-address-family (sock)
  (typecase sock
    (sb-bsd-sockets:inet6-socket :ipv6)
    (sb-bsd-sockets:inet-socket :ipv4)
    (t :unknown)))

(defun %tls-pool-key (host port family ca-file verify)
  ;; Unverified transports ignore the CA path so test fixtures and callers that
  ;; pass :verify nil do not fragment the idle pool by ambient SSL_CERT_FILE.
  (list (string-downcase host) port family :tls
        (and verify (or ca-file ""))
        (and verify t)))

(defun %tls-transport-close (sock raw tls &key abort)
  (ignore-errors (when tls (close tls :abort abort)))
  (ignore-errors
    (when (and raw (open-stream-p raw))
      (close raw :abort abort)))
  (ignore-errors
    (when sock
      (sb-bsd-sockets:socket-close sock :abort abort)))
  (values))

(defun %tls-socket-idle-dead-p (sock)
  "True when the idle TCP peer has data or has closed (fail-closed for reuse)."
  (handler-case
      (let ((buffer (make-array 1 :element-type '(unsigned-byte 8))))
        (multiple-value-bind (result length)
            (sb-bsd-sockets:socket-receive
             sock buffer 1
             :element-type '(unsigned-byte 8)
             :peek t
             :dontwait t)
          (declare (ignore result))
          ;; length 0 → peer FIN; positive → unsolicited idle bytes.
          (and length (not (minusp length)))))
    (sb-bsd-sockets:interrupted-error () nil)
    (error () t)))

(defun %tls-stream-pending-input-p (tls)
  (and tls
       (open-stream-p tls)
       (plusp (pure-tls::tls-stream-buffer-remaining tls))))

(defun %tls-pool-drop-entry-locked (entry &key close)
  (when (tls-pool-entry-idle-p entry)
    (setf (tls-pool-entry-idle-p entry) nil)
    (let* ((pool (tls-pool-entry-pool entry))
           (key (tls-pool-entry-key entry))
           (bucket (gethash key (tls-connection-pool-buckets pool)))
           (timer (tls-pool-entry-timer entry))
           (resource (tls-pool-entry-resource entry)))
      (setf (gethash key (tls-connection-pool-buckets pool))
            (delete entry bucket :test #'eq))
      (unless (gethash key (tls-connection-pool-buckets pool))
        (remhash key (tls-connection-pool-buckets pool)))
      (when timer
        (setf (tls-pool-entry-timer entry) nil)
        (ignore-errors (lp:clear-timer timer)))
      (when resource
        (setf (tls-pool-entry-resource entry) nil)
        (ignore-errors (lp:unregister-loop-resource resource)))
      (when close
        (%tls-transport-close (tls-pool-entry-sock entry)
                              (tls-pool-entry-raw entry)
                              (tls-pool-entry-tls entry))
        (setf (tls-pool-entry-sock entry) nil
              (tls-pool-entry-raw entry) nil
              (tls-pool-entry-tls entry) nil))))
  (values))

(defun %tls-pool-drop-entry (entry &key close)
  (let ((pool (tls-pool-entry-pool entry)))
    (sb-thread:with-mutex ((tls-connection-pool-lock pool))
      (%tls-pool-drop-entry-locked entry :close close)))
  (values))

(defun %tls-pool-release (loop host port ca-file verify sock raw tls)
  "Return an authenticated TLS transport to LOOP's origin/config pool.
Call only after a clean keep-alive response with no trailing application bytes.
Returns true when the transport was accepted into the idle pool."
  (unless (and loop sock raw tls
               (open-stream-p tls)
               (not (%tls-stream-pending-input-p tls))
               (not (%tls-socket-idle-dead-p sock)))
    (return-from %tls-pool-release nil))
  (let* ((pool (%tls-pool loop))
         (family (%socket-address-family sock))
         (key (%tls-pool-key host port family ca-file verify)))
    (sb-thread:with-mutex ((tls-connection-pool-lock pool))
      (let ((bucket (gethash key (tls-connection-pool-buckets pool))))
        (when (>= (length bucket) *tls-pool-max-idle-per-key*)
          (return-from %tls-pool-release nil))
        (let ((entry (%make-tls-pool-entry pool key sock raw tls family)))
          (setf (tls-pool-entry-idle-since-ms entry) (%monotonic-ms))
          (handler-case
              (setf (tls-pool-entry-resource entry)
                    (lp:register-loop-resource
                     loop entry
                     (lambda ()
                       (%tls-pool-drop-entry entry :close t))))
            (error ()
              (return-from %tls-pool-release nil)))
          (push entry (gethash key (tls-connection-pool-buckets pool)))
          (handler-case
              (setf (tls-pool-entry-timer entry)
                    (lp:set-timer
                     loop *tls-pool-idle-timeout-ms*
                     (lambda () (%tls-pool-drop-entry entry :close t))
                     :refd nil))
            (error ()
              (%tls-pool-drop-entry-locked entry :close t)
              (return-from %tls-pool-release nil)))
          t)))))

(defun %tls-pool-acquire (loop host port ca-file verify)
  "Take one live idle TLS transport for HOST:PORT and TLS config, preferring IPv6."
  (unless loop
    (return-from %tls-pool-acquire (values nil nil nil nil)))
  (let ((pool (%tls-pool loop)))
    (sb-thread:with-mutex ((tls-connection-pool-lock pool))
      (dolist (family '(:ipv6 :ipv4 :unknown))
        (let* ((key (%tls-pool-key host port family ca-file verify))
               (bucket (gethash key (tls-connection-pool-buckets pool)))
               (now (%monotonic-ms)))
          (loop while bucket do
            (let ((entry (pop bucket)))
              (setf (gethash key (tls-connection-pool-buckets pool)) bucket)
              (unless bucket
                (remhash key (tls-connection-pool-buckets pool)))
              (when (tls-pool-entry-idle-p entry)
                (setf (tls-pool-entry-idle-p entry) nil)
                (let ((timer (tls-pool-entry-timer entry))
                      (resource (tls-pool-entry-resource entry))
                      (sock (tls-pool-entry-sock entry))
                      (raw (tls-pool-entry-raw entry))
                      (tls (tls-pool-entry-tls entry))
                      (idle-since (tls-pool-entry-idle-since-ms entry)))
                  (when timer
                    (setf (tls-pool-entry-timer entry) nil)
                    (ignore-errors (lp:clear-timer timer)))
                  (when resource
                    (setf (tls-pool-entry-resource entry) nil)
                    (ignore-errors (lp:unregister-loop-resource resource)))
                  (cond
                    ((or (null sock) (null raw) (null tls)
                         (not (open-stream-p tls))
                         (>= (- now idle-since) *tls-pool-idle-timeout-ms*)
                         (%tls-stream-pending-input-p tls)
                         (%tls-socket-idle-dead-p sock))
                     (%tls-transport-close sock raw tls))
                    (t
                     (return-from %tls-pool-acquire
                       (values sock raw tls family))))))))))))
  (values nil nil nil nil))

(defun %tls-pool-idle-transports (loop host port &key ca-file (verify t))
  "Internal test probe: snapshot idle pure-tls streams for one HTTPS origin/config."
  (let ((pool (and loop (lp:loop-extension loop +tls-pool-extension-key+)))
        (result '()))
    (when pool
      (sb-thread:with-mutex ((tls-connection-pool-lock pool))
        (dolist (family '(:ipv6 :ipv4 :unknown))
          (dolist (entry (gethash (%tls-pool-key host port family ca-file verify)
                                  (tls-connection-pool-buckets pool)))
            (when (tls-pool-entry-idle-p entry)
              (push (tls-pool-entry-tls entry) result))))))
    result))

(defun %make-https-response-stream-dispatcher
    (method on-headers on-data on-complete)
  "Return FEED, EOF, and REUSABLE-P closures for one authenticated HTTPS response."
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
           message-complete-p)
         (reusable ()
           (response-stream-reusable-p parser)))
      (values #'feed #'eof #'reusable))))

(defun https-request-stream
    (&key host port method path headers body host-header
          proxy-host proxy-port proxy-authorization proxy-headers
          (ca-file (%system-ca-file)) (verify t) socket-box
          (connect-timeout-ms 30000) cancelled-p request-body-source
          pool-loop (pooling-p t)
          on-headers on-data on-complete)
  "Issue one blocking HTTPS request and deliver its response incrementally.

This preserves HTTPS-REQUEST's DNS, Happy Eyeballs, TLS 1.3-to-1.2 fallback,
certificate/hostname verification, authenticated records, decompression bounds,
and abort socket. The caller must run it off the event-loop thread. Callbacks run
on that worker thread; an asynchronous caller is responsible for loop marshalling.

When POOL-LOOP is supplied and POOLING-P is true (and no proxy is used), a clean
Content-Length/chunked/HEAD keep-alive response may return the pure-tls transport
to LOOP's origin-keyed idle pool under the same fail-closed rules as plain HTTP."
  (let* ((dial-host (or proxy-host host))
         (dial-port (or proxy-port port))
         (pool-eligible-p (and pooling-p pool-loop (null proxy-host)))
         (request-keep-alive-p
           (and pool-eligible-p (%request-keep-alive-p headers)))
         (request-finished-p (null request-body-source))
         (addresses nil)
         (sock nil)
         (raw nil)
         (tls nil)
         (pooled-p nil)
         (poolable-p nil)
         (request
           (%serialize-request method path (or host-header host)
                               headers body "identity"
                               (not (null request-body-source))
                               request-keep-alive-p)))
    (labels ((close-transport ()
               (%tls-transport-close sock raw tls)
               (setf tls nil raw nil sock nil pooled-p nil))
             (install-abort ()
               (when socket-box
                 (let ((held-sock sock))
                   (setf (car socket-box)
                         (lambda ()
                           (ignore-errors
                             (when held-sock
                               (sb-bsd-sockets:socket-close held-sock :abort t))))))))
             (adopt-transport (next-sock next-raw next-tls from-pool-p)
               (setf sock next-sock
                     raw next-raw
                     tls next-tls
                     pooled-p from-pool-p)
               (install-abort))
             (connect-transport ()
               (unless addresses
                 (setf addresses
                       (resolve-hostname-all dial-host :cancelled-p cancelled-p)))
               (let ((next-sock
                       (%connect-happy-blocking addresses dial-port socket-box
                                                 connect-timeout-ms))
                     (next-raw nil))
                 (setf next-raw
                       (sb-bsd-sockets:socket-make-stream
                        next-sock :input t :output t
                        :element-type '(unsigned-byte 8)))
                 (setf sock next-sock raw next-raw tls nil pooled-p nil)
                 (install-abort)
                 (if proxy-host
                     (multiple-value-bind (status head)
                         (%establish-http-connect
                          raw host port proxy-authorization cancelled-p
                          proxy-headers)
                       (when (= status 101)
                         (error "proxy CONNECT returned an unrequested protocol upgrade"))
                       (values (<= 200 status 299) head))
                     (values t nil))))
             (deliver-proxy-response (head)
               (%deliver-proxy-connect-response
                raw head cancelled-p on-headers on-data on-complete))
             (write-request-body ()
               (when request-body-source
                 (let ((total 0))
                   (loop
                     (multiple-value-bind (chunk done-p)
                         (funcall request-body-source)
                       (when done-p
                         (write-sequence +chunked-request-end+ tls)
                         (force-output tls)
                         (setf request-finished-p t)
                         (return))
                       (when (plusp (length chunk))
                         (incf total (length chunk))
                         (when (> total *max-body-bytes*)
                           (error
                            "streaming request body exceeded the size limit"))
                         (write-sequence
                          (%chunked-request-frame chunk) tls)
                         (force-output tls)))))))
             (read-tls-response (feed finish-at-eof reusable)
               (let ((buffer
                       (make-array 65536 :element-type '(unsigned-byte 8))))
                 (loop
                   (let ((count (read-sequence buffer tls)))
                     (when (zerop count)
                       (funcall finish-at-eof t)
                       (return))
                     (when (funcall feed (subseq buffer 0 count))
                       (return)))))
               (setf poolable-p
                     (and request-keep-alive-p
                          request-finished-p
                          (funcall reusable)
                          tls
                          (open-stream-p tls)
                          (not (%tls-stream-pending-input-p tls)))))
             (run-on-tls (feed finish-at-eof reusable)
               (write-sequence request tls)
               (force-output tls)
               (write-request-body)
               (read-tls-response feed finish-at-eof reusable))
             (handshake-tls13 (context)
               (pure-tls:make-tls-client-stream
                raw :hostname host
                    :verify (if verify
                                pure-tls:+verify-required+
                                pure-tls:+verify-none+)
                    :alpn-protocols '("http/1.1")
                    :context context)))
      (unwind-protect
           (multiple-value-bind (feed finish-at-eof reusable)
               (%make-https-response-stream-dispatcher
                method on-headers on-data on-complete)
             (when pool-eligible-p
               (multiple-value-bind (pooled-sock pooled-raw pooled-tls)
                   (%tls-pool-acquire pool-loop host port ca-file verify)
                 (when pooled-tls
                   (adopt-transport pooled-sock pooled-raw pooled-tls t)
                   (run-on-tls feed finish-at-eof reusable)
                   (return-from https-request-stream t))))
             (multiple-value-bind (tunnel-ready-p proxy-head)
                 (connect-transport)
               (if (not tunnel-ready-p)
                   (deliver-proxy-response proxy-head)
                   (let ((fallback-p nil)
                         (context (if ca-file
                                      (pure-tls:make-tls-context :ca-file ca-file)
                                      (pure-tls:make-tls-context))))
                     (handler-case
                         (setf tls (handshake-tls13 context)
                               pooled-p nil)
                       (pure-tls:tls-alert-error (condition)
                         (unless (%protocol-version-alert-p condition)
                           (error condition))
                         (setf fallback-p t)))
                     (if fallback-p
                         (progn
                           ;; TLS 1.2 fallback remains one-shot: a fresh CONNECT
                           ;; (when proxied) and a fresh TCP socket, never pooled.
                           (close-transport)
                           (multiple-value-bind (fallback-ready-p fallback-head)
                               (connect-transport)
                             (if fallback-ready-p
                                 (multiple-value-bind (termination clean-eof-p)
                                     (https-request-tls12-stream
                                      raw host request feed
                                      :ca-file ca-file :verify verify
                                      :request-body-source request-body-source)
                                   (when request-body-source
                                     (setf request-finished-p t))
                                   (case termination
                                     (:message-complete t)
                                     (:close-notify
                                      (funcall finish-at-eof clean-eof-p))
                                     (:eof
                                      (funcall finish-at-eof clean-eof-p))))
                                 (deliver-proxy-response fallback-head))))
                         (run-on-tls feed finish-at-eof reusable))))))
        (cond
          ((and poolable-p sock raw tls pool-eligible-p)
           (let ((held-sock sock)
                 (held-raw raw)
                 (held-tls tls))
             ;; Detach the abort thunk before parking the transport so a
             ;; settled Fetch cancel cannot close a pooled idle socket.
             (when socket-box (setf (car socket-box) nil))
             (setf sock nil raw nil tls nil)
             (unless (%tls-pool-release pool-loop host port ca-file verify
                                        held-sock held-raw held-tls)
               (%tls-transport-close held-sock held-raw held-tls))))
          (t
           (when socket-box (setf (car socket-box) nil))
           (close-transport)))))))
