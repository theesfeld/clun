;;;; https-tests.lisp — Phase 20 gate: HTTPS over pure-tls, hermetic.
;;;;
;;;; Two parts, both hermetic (no network):
;;;;  (1) TRANSPORT — net:https-request (blocking connect → pure-tls handshake → serialize
;;;;      request → read + parse the response) against an in-process pure-tls server, with
;;;;      verification OFF so it is deterministic.
;;;;  (2) VERIFICATION matrix — the verify functions net:https-request invokes, vs the
;;;;      checked-in test PKI: the good leaf verifies; expired / wrong-host / self-signed /
;;;;      bad-chain each FAIL CLOSED with a distinct, descriptive error; and a handshake with
;;;;      NO peer certificate under verify-required also fails closed (the security patch).
;;;;
;;;; Why the transport test turns verification off: on the pure-tls CLIENT ↔ pure-tls SERVER
;;;; path the client records the peer certificate only RACILY (a pure-tls self-interop timing
;;;; bug). With verification ON that (correctly) FAILS CLOSED on a missing peer cert — which
;;;; would make an in-process fetch round-trip non-deterministic. Certificate verification is
;;;; therefore proven here by the verify-function matrix, and END-TO-END against REAL servers
;;;; in the logged live smoke (example.com accepts under system trust, rejects under the test
;;;; CA — STATE.md). Clun never accepts an unverifiable certificate: fail closed, always.

(in-package :clun-test)

(defparameter *certs-dir*
  (namestring (merge-pathnames "tests/fixtures/certs/" (asdf:system-source-directory :clun)))
  "Absolute path to the checked-in test PKI.")
(defun %cert (name) (concatenate 'string *certs-dir* name))

;;; --- (1) transport round-trip ------------------------------------------------

(defun %https-fixture-server
    (cert-file key-file response-bytes
     &key split-at tail-sent-box request-capture read-request-body-p
          omit-close-notify-p error-box)
  "Start a ONE-SHOT blocking pure-tls HTTPS server on 127.0.0.1:0 presenting CERT-FILE/KEY-FILE.
Returns (values port thread error-box): accepts one connection, handshakes, reads the request
headers to CRLFCRLF (and optionally its terminal chunk), writes RESPONSE-BYTES, and normally
closes with close_notify. OMIT-CLOSE-NOTIFY-P closes the flushed TCP stream directly so tests
can distinguish HTTP message framing from authenticated EOF. Server conditions are retained
in ERROR-BOX instead of being silently discarded."
  (let ((lsock (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
        (server-error (or error-box (list nil))))
    (setf (sb-bsd-sockets:sockopt-reuse-address lsock) t)
    (sb-bsd-sockets:socket-bind lsock (sb-bsd-sockets:make-inet-address "127.0.0.1") 0)
    (sb-bsd-sockets:socket-listen lsock 5)
    (values
     (nth-value 1 (sb-bsd-sockets:socket-name lsock))
     (sb-thread:make-thread
      (lambda ()
        (unwind-protect
             (handler-case
                 (let* ((child (sb-bsd-sockets:socket-accept lsock))
                        (raw (sb-bsd-sockets:socket-make-stream child :input t :output t
                                                                    :element-type '(unsigned-byte 8)))
                        (tls (pure-tls:make-tls-server-stream raw :certificate cert-file :key key-file)))
                   (let ((w 0) (x 0) (y 0) (z 0)
                         (header-seen-p nil)
                         (captured
                           (or request-capture
                               (make-array 1024
                                           :element-type '(unsigned-byte 8)
                                           :adjustable t :fill-pointer 0))))
                     (loop for b = (read-byte tls nil nil) while b do
                       (vector-push-extend b captured)
                       (setf w x x y y z z b)
                       (cond
                         ((and (not header-seen-p)
                               (= w 13) (= x 10) (= y 13) (= z 10))
                          (setf header-seen-p t)
                          (unless read-request-body-p (return)))
                         ((and header-seen-p read-request-body-p
                               (>= (fill-pointer captured) 5)
                               (= 48 (aref captured (- (fill-pointer captured) 5)))
                               (= 13 (aref captured (- (fill-pointer captured) 4)))
                               (= 10 (aref captured (- (fill-pointer captured) 3)))
                               (= 13 (aref captured (- (fill-pointer captured) 2)))
                               (= 10 (aref captured (1- (fill-pointer captured)))))
                          (return)))))
                   (if split-at
                       (progn
                         (write-sequence response-bytes tls :end split-at)
                         (force-output tls)
                         (sleep 0.1)
                         (when tail-sent-box (setf (car tail-sent-box) t))
                         (write-sequence response-bytes tls :start split-at))
                       (write-sequence response-bytes tls))
                   (force-output tls)
                   (if omit-close-notify-p
                       (close raw)
                       (close tls)))
               (error (condition)
                 (setf (car server-error) condition)))
          (ignore-errors (sb-bsd-sockets:socket-close lsock))))
      :name "https-fixture")
     server-error)))

(defun %http-response-bytes (status body &optional (content-type "application/json")
                                         &key (connection "close")
                                              (content-length (length body))
                                              (include-content-length-p t))
  (let ((hdr (with-output-to-string (s)
               (format s "HTTP/1.1 ~d OK~c~c" status #\Return #\Newline)
               (format s "Content-Type: ~a~c~c" content-type #\Return #\Newline)
               (when include-content-length-p
                 (format s "Content-Length: ~d~c~c" content-length #\Return #\Newline))
               (format s "Connection: ~a~c~c" connection #\Return #\Newline)
               (format s "~c~c" #\Return #\Newline))))
    (concatenate '(vector (unsigned-byte 8))
                 (sb-ext:string-to-octets hdr :external-format :latin-1)
                 (sb-ext:string-to-octets body :external-format :utf-8))))

(defun %https-persistent-fixture-server
    (cert-file key-file
     &key (accepted-count (list 0))
          (request-count (list 0))
          (response-fn
           (lambda (request-index)
             (declare (ignore request-index))
             (%http-response-bytes 200 "ok" "text/plain"
                                   :connection "keep-alive")))
          (close-after-request-n nil)
          (stop-box (list nil)))
  "Multi-connection pure-tls HTTPS fixture that serves sequential keep-alive requests.

Each accepted TCP connection may handle many HTTP requests until the client closes
or CLOSE-AFTER-REQUEST-N forces a one-shot close after that 1-based request index.
Returns (values port thread stop-box accepted-count request-count)."
  (let ((lsock (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (setf (sb-bsd-sockets:sockopt-reuse-address lsock) t)
    (sb-bsd-sockets:socket-bind lsock (sb-bsd-sockets:make-inet-address "127.0.0.1") 0)
    (sb-bsd-sockets:socket-listen lsock 16)
    (values
     (nth-value 1 (sb-bsd-sockets:socket-name lsock))
     (sb-thread:make-thread
      (lambda ()
        (labels
            ((serve-connection (child)
               (handler-case
                   (let* ((raw (sb-bsd-sockets:socket-make-stream
                                child :input t :output t
                                :element-type '(unsigned-byte 8)))
                          (tls (pure-tls:make-tls-server-stream
                                raw :certificate cert-file :key key-file)))
                     (unwind-protect
                          (block connection
                            (loop
                              (when (car stop-box) (return-from connection))
                              (let ((w 0) (x 0) (y 0) (z 0)
                                    (header
                                      (make-array 256
                                                  :element-type '(unsigned-byte 8)
                                                  :adjustable t
                                                  :fill-pointer 0)))
                                (loop
                                  (let ((b (read-byte tls nil nil)))
                                    (unless b (return-from connection))
                                    (vector-push-extend b header)
                                    (setf w x x y y z z b)
                                    (when (and (= w 13) (= x 10)
                                               (= y 13) (= z 10))
                                      (return))))
                                (let* ((index
                                         (incf (car request-count)))
                                       (response (funcall response-fn index))
                                       (wire
                                         (sb-ext:octets-to-string
                                          (subseq header 0 (fill-pointer header))
                                          :external-format :latin-1))
                                       (client-close
                                         (search "connection: close" wire
                                                 :test #'char-equal)))
                                  (write-sequence response tls)
                                  (force-output tls)
                                  (when (or client-close
                                            (and close-after-request-n
                                                 (>= index close-after-request-n)))
                                    (return-from connection))))))
                       (ignore-errors (close tls))
                       (ignore-errors (sb-bsd-sockets:socket-close child))))
                 (error ()
                   (ignore-errors (sb-bsd-sockets:socket-close child))))))
          (unwind-protect
               (handler-case
                   (loop until (car stop-box) do
                     (setf (sb-bsd-sockets:non-blocking-mode lsock) t)
                     (let ((child
                             (handler-case (sb-bsd-sockets:socket-accept lsock)
                               (sb-bsd-sockets:interrupted-error () nil)
                               (error () nil))))
                       (cond
                         (child
                          (setf (sb-bsd-sockets:non-blocking-mode child) nil)
                          (incf (car accepted-count))
                          (serve-connection child))
                         (t (sleep 0.01)))))
                 (error () nil))
            (ignore-errors (sb-bsd-sockets:socket-close lsock)))))
      :name "https-persistent-fixture")
     stop-box accepted-count request-count)))

(defun %https-pooled-request
    (loop host port path
     &key (method "GET") headers body (timeout 5000) (verify nil)
          (on-headers nil) (on-data nil))
  "One pooled HTTPS request on LOOP; returns (values status body error-code complete-p)."
  (let ((status nil)
        (chunks '())
        (complete-p nil)
        (error-code nil))
    (rt::%https-request-stream-async
     loop :host host :port port :method method :path path
     :headers headers :body body :verify verify :timeout timeout
     :on-headers
     (lambda (head)
       (setf status (net:hres-status head))
       (when on-headers (funcall on-headers head)))
     :on-data
     (lambda (chunk)
       (push chunk chunks)
       (when on-data (funcall on-data chunk)))
     :on-complete (lambda () (setf complete-p t))
     :on-error (lambda (code) (setf error-code code)))
    (lp:run-loop loop)
    (values status
            (apply #'concatenate
                   '(vector (unsigned-byte 8))
                   (nreverse chunks))
            error-code
            complete-p)))

(defun %http-marker-response-bytes (body)
  (let ((header
          (with-output-to-string (output)
            (format output "HTTP/1.1 200 OK~c~c" #\Return #\Newline)
            (format output "Content-Type: text/event-stream~c~c" #\Return #\Newline)
            (format output "X-Upstream-Marker: from-upstream~c~c" #\Return #\Newline)
            (format output "Content-Length: ~d~c~c" (length body) #\Return #\Newline)
            (format output "Connection: close~c~c~c~c"
                    #\Return #\Newline #\Return #\Newline))))
    (concatenate '(vector (unsigned-byte 8))
                 (sb-ext:string-to-octets header :external-format :latin-1)
                 (sb-ext:string-to-octets body :external-format :utf-8))))

(defun %fixture-copy-stream (input output)
  ;; A blocking socket READ-SEQUENCE may wait to fill its whole buffer.  TLS
  ;; handshake records are smaller than that buffer, so a naive relay can
  ;; deadlock before forwarding the ClientHello.  Forward each available byte;
  ;; this fixture values deterministic framing over throughput.
  (handler-case
      (loop for byte = (read-byte input nil nil)
            while byte do
              (write-byte byte output)
              (force-output output))
    (error () nil)))

(defun %connect-proxy-fixture
    (upstream-port capture &key (status 200) split-at location error-box)
  "Start a one-shot blocking HTTP CONNECT proxy, optionally relaying to UPSTREAM-PORT."
  (let ((listener
          (make-instance 'sb-bsd-sockets:inet-socket
                         :type :stream :protocol :tcp)))
    (setf (sb-bsd-sockets:sockopt-reuse-address listener) t)
    (sb-bsd-sockets:socket-bind
     listener (sb-bsd-sockets:make-inet-address "127.0.0.1") 0)
    (sb-bsd-sockets:socket-listen listener 5)
    (values
     (nth-value 1 (sb-bsd-sockets:socket-name listener))
     (sb-thread:make-thread
      (lambda ()
        (let ((client nil) (client-stream nil)
              (upstream nil) (upstream-stream nil) (relay nil))
          (unwind-protect
               (handler-case
                   (progn
                     (setf client (sb-bsd-sockets:socket-accept listener)
                           client-stream
                           (sb-bsd-sockets:socket-make-stream
                            client :input t :output t
                            :element-type '(unsigned-byte 8)))
                     (let ((w 0) (x 0) (y 0) (z 0))
                       (loop for byte = (read-byte client-stream nil nil) do
                         (unless byte
                           (error "client closed during CONNECT request"))
                         (vector-push-extend byte capture)
                         (setf w x x y y z z byte)
                         (when (and (= w 13) (= x 10) (= y 13) (= z 10))
                           (return))))
                     (if (= status 200)
                         (progn
                           (setf upstream
                                 (make-instance 'sb-bsd-sockets:inet-socket
                                                :type :stream :protocol :tcp))
                           (sb-bsd-sockets:socket-connect
                            upstream
                            (sb-bsd-sockets:make-inet-address "127.0.0.1")
                            upstream-port)
                           (setf upstream-stream
                                 (sb-bsd-sockets:socket-make-stream
                                  upstream :input t :output t
                                  :element-type '(unsigned-byte 8)))
                           (let ((envelope
                                   (sb-ext:string-to-octets
                                    (format nil
                                            "HTTP/1.1 200 Connection established~c~cConnection: close~c~cProxy-Agent: splitproxy~c~c~c~c"
                                            #\Return #\Newline #\Return #\Newline
                                            #\Return #\Newline #\Return #\Newline)
                                    :external-format :latin-1)))
                             (if split-at
                                 (progn
                                   (write-sequence envelope client-stream
                                                   :end split-at)
                                   (force-output client-stream)
                                   (sleep 0.05)
                                   (write-sequence envelope client-stream
                                                   :start split-at))
                                 (write-sequence envelope client-stream))
                             (force-output client-stream))
                           (setf relay
                                 (sb-thread:make-thread
                                  (lambda ()
                                    (%fixture-copy-stream
                                     client-stream upstream-stream))
                                  :name "connect-proxy-client-to-origin"))
                           (%fixture-copy-stream upstream-stream client-stream))
                         (let ((body "auth-required"))
                           (write-sequence
                            (sb-ext:string-to-octets
                             (with-output-to-string (output)
                               (format output
                                       "HTTP/1.1 ~d Proxy Response~c~c"
                                       status #\Return #\Newline)
                               (format output
                                       "Proxy-Authenticate: Basic realm=fixture~c~c"
                                       #\Return #\Newline)
                               (when location
                                 (format output "Location: ~a~c~c"
                                         location #\Return #\Newline))
                               (format output "Content-Length: ~d~c~c"
                                       (length body) #\Return #\Newline)
                               (format output "Connection: close~c~c~c~c~a"
                                       #\Return #\Newline #\Return #\Newline body))
                             :external-format :latin-1)
                            client-stream)
                           (force-output client-stream))))
                 (error (condition)
                   (when error-box (setf (car error-box) condition))))
            (when relay
              (ignore-errors (sb-thread:join-thread relay :timeout 2)))
            (ignore-errors (when upstream-stream (close upstream-stream)))
            (ignore-errors (when client-stream (close client-stream)))
            (ignore-errors (when upstream
                             (sb-bsd-sockets:socket-close upstream)))
            (ignore-errors (when client
                             (sb-bsd-sockets:socket-close client)))
            (ignore-errors (sb-bsd-sockets:socket-close listener)))))
      :name "connect-proxy-fixture"))))

(define-test net/https-transport
  ;; The blocking TLS TRANSPORT (connect → pure-tls handshake → serialize request → read +
  ;; parse the response) works against an in-process pure-tls server. Verification is OFF here
  ;; (net:https-request :verify nil) so the test is deterministic — the pure-tls↔pure-tls path
  ;; records the peer certificate only racily (a pure-tls self-interop timing bug; with verify
  ;; ON it correctly FAILS CLOSED on a missing peer cert, which would make this test flaky).
  ;; Certificate verification is covered deterministically by the verify-function matrix below
  ;; + the end-to-end live smoke (STATE.md).
  (let ((server-error (list nil))
        (client-error nil)
        (request-capture
          (make-array 256 :element-type '(unsigned-byte 8)
                          :adjustable t :fill-pointer 0))
        (resp nil))
    (multiple-value-bind (fport thread)
        (%https-fixture-server (%cert "localhost-leaf.crt") (%cert "localhost-leaf.key")
                               (%http-response-bytes 200 "{\"tls\":\"ok\",\"n\":7}")
                               :error-box server-error
                               :request-capture request-capture)
      (unwind-protect
           (handler-case
               (setf resp
                     (net:https-request :host "localhost" :port fport
                                        :method "GET" :path "/" :verify nil))
             (error (condition) (setf client-error condition)))
        (ignore-errors (sb-thread:join-thread thread :timeout 5))))
    (false (car server-error)
           (format nil "HTTPS fixture server failed: ~a" (car server-error)))
    (false client-error
           (format nil "blocking HTTPS transport failed: ~a" client-error))
    (when resp
      (is = 200 (net:hres-status resp))
      (true (search "\"tls\":\"ok\""
                    (sb-ext:octets-to-string (net:hres-body resp)
                                              :external-format :utf-8)))
      (true (search "Accept-Encoding: gzip"
                    (sb-ext:octets-to-string request-capture
                                              :external-format :latin-1))
            "blocking HTTPS preserves its gzip negotiation default"))))

(define-test net/https-blocking-framed-response-does-not-require-close-notify
  ;; Content-Length authenticates the application message boundary. A transport
  ;; close after those bytes cannot truncate the response and must not make the
  ;; blocking compatibility API wait for TLS EOF.
  (let ((server-error (list nil)))
    (multiple-value-bind (fport thread)
        (%https-fixture-server
         (%cert "localhost-leaf.crt") (%cert "localhost-leaf.key")
         (%http-response-bytes 200 "framed" "text/plain")
         :omit-close-notify-p t :error-box server-error)
      (unwind-protect
           (let ((resp (net:https-request :host "localhost" :port fport
                                          :method "GET" :path "/framed"
                                          :verify nil)))
             (is = 200 (net:hres-status resp))
             (is string= "framed"
                 (sb-ext:octets-to-string (net:hres-body resp)
                                           :external-format :utf-8)))
        (ignore-errors (sb-thread:join-thread thread :timeout 5))))
    (false (car server-error)
           (format nil "HTTPS fixture server failed: ~a" (car server-error)))))

(define-test net/https-blocking-truncated-framing-fails-closed
  ;; The same abrupt transport close remains fatal when Content-Length has not
  ;; been satisfied; authenticated partial bytes are never accepted as a body.
  (let ((server-error (list nil))
        (client-error nil))
    (multiple-value-bind (fport thread)
        (%https-fixture-server
         (%cert "localhost-leaf.crt") (%cert "localhost-leaf.key")
         (%http-response-bytes 200 "short" "text/plain" :content-length 9)
         :omit-close-notify-p t :error-box server-error)
      (unwind-protect
           (handler-case
               (net:https-request :host "localhost" :port fport
                                  :method "GET" :path "/truncated" :verify nil)
             (error (condition) (setf client-error condition)))
        (ignore-errors (sb-thread:join-thread thread :timeout 5))))
    (false (car server-error)
           (format nil "HTTPS fixture server failed: ~a" (car server-error)))
    (true client-error "truncated Content-Length response must fail closed")))

(define-test net/https-blocking-until-close-requires-close-notify
  ;; Without HTTP message framing, only authenticated TLS EOF proves the body
  ;; complete. A bare TCP EOF remains a possible truncation and must be rejected.
  (let ((server-error (list nil))
        (client-error nil))
    (multiple-value-bind (fport thread)
        (%https-fixture-server
         (%cert "localhost-leaf.crt") (%cert "localhost-leaf.key")
         (%http-response-bytes 200 "until-close" "text/plain"
                               :include-content-length-p nil)
         :omit-close-notify-p t :error-box server-error)
      (unwind-protect
           (handler-case
               (net:https-request :host "localhost" :port fport
                                  :method "GET" :path "/until-close" :verify nil)
             (error (condition) (setf client-error condition)))
        (ignore-errors (sb-thread:join-thread thread :timeout 5))))
    (false (car server-error)
           (format nil "HTTPS fixture server failed: ~a" (car server-error)))
    (true client-error "until-close response without close_notify must fail closed")))

(define-test net/https-transport-streams-authenticated-response
  (multiple-value-bind (fport thread)
      (%https-fixture-server
       (%cert "localhost-leaf.crt") (%cert "localhost-leaf.key")
       (%http-response-bytes 200 "streamed over tls" "text/plain"))
    (unwind-protect
         (let ((events '())
               (chunks '()))
           (net:https-request-stream
            :host "localhost" :port fport :method "GET" :path "/stream"
            :verify nil
            :on-headers
            (lambda (head)
              (push :headers events)
              (is = 200 (net:hres-status head))
              (is = 0 (length (net:hres-body head))))
            :on-data
            (lambda (chunk)
              (push :data events)
              (push chunk chunks))
            :on-complete (lambda () (push :complete events)))
           (is eq :headers (car (last events)))
           (is eq :complete (first events))
           (is string= "streamed over tls"
               (sb-ext:octets-to-string
                (apply #'concatenate '(vector (unsigned-byte 8))
                       (nreverse chunks))
                :external-format :utf-8)))
      (ignore-errors (sb-thread:join-thread thread :timeout 5)))))

(define-test net/https-connect-proxy-split-envelope-is-not-origin-response
  ;; Frozen upstream regression:
  ;; oven-sh/bun@c1076ce95e
  ;; test/js/web/fetch/fetch-proxy-connect-tunnel-split-envelope.test.ts.
  (let ((capture
          (make-array 512 :element-type '(unsigned-byte 8)
                          :adjustable t :fill-pointer 0))
        (proxy-error (list nil)))
    (multiple-value-bind (origin-port origin-thread)
        (%https-fixture-server
         (%cert "localhost-leaf.crt") (%cert "localhost-leaf.key")
         (%http-marker-response-bytes "hello world"))
      (multiple-value-bind (proxy-port proxy-thread)
          (%connect-proxy-fixture
           origin-port capture :split-at 20 :error-box proxy-error)
        (unwind-protect
             (let ((head nil) (chunks '()) (complete-p nil))
               (net:https-request-stream
                :host "localhost" :port origin-port :method "GET" :path "/"
                :proxy-host "127.0.0.1" :proxy-port proxy-port
                :proxy-authorization "Basic dTpw" :verify nil
                :on-headers (lambda (response) (setf head response))
                :on-data (lambda (chunk) (push chunk chunks))
                :on-complete (lambda () (setf complete-p t)))
               (is = 200 (net:hres-status head))
               (is string= "from-upstream"
                   (net:%header (net:hres-headers head) "x-upstream-marker"))
               (false (net:%header (net:hres-headers head) "proxy-agent"))
               (is string= "hello world"
                   (sb-ext:octets-to-string
                    (apply #'concatenate '(vector (unsigned-byte 8))
                           (nreverse chunks))
                    :external-format :utf-8))
               (true complete-p)
               (let ((wire
                       (sb-ext:octets-to-string
                        (subseq capture 0 (fill-pointer capture))
                        :external-format :latin-1)))
                 (true (search (format nil "CONNECT localhost:~d HTTP/1.1"
                                       origin-port)
                               wire))
                 (true (search "Proxy-Authorization: Basic dTpw" wire)))
               (false (car proxy-error)))
          (ignore-errors (sb-thread:join-thread proxy-thread :timeout 5))
          (ignore-errors (sb-thread:join-thread origin-thread :timeout 5)))))))

(define-test net/https-connect-proxy-non-2xx-is-a-response
  ;; Pinned Bun proxy-stress-errors.test.ts requires CONNECT failures to
  ;; resolve as proxy responses and never be interpreted as origin redirects.
  (let ((capture
          (make-array 512 :element-type '(unsigned-byte 8)
                          :adjustable t :fill-pointer 0))
        (proxy-error (list nil)))
    (multiple-value-bind (proxy-port proxy-thread)
        (%connect-proxy-fixture
         nil capture :status 407 :error-box proxy-error)
      (unwind-protect
           (let ((head nil) (chunks '()) (complete-p nil))
             (net:https-request-stream
              :host "origin.invalid" :port 443 :method "HEAD" :path "/"
              :proxy-host "127.0.0.1" :proxy-port proxy-port :verify nil
              :on-headers (lambda (response) (setf head response))
              :on-data (lambda (chunk) (push chunk chunks))
              :on-complete (lambda () (setf complete-p t)))
             (is = 407 (net:hres-status head))
             (true (net::hres-proxy-response-p head))
             (is string= "auth-required"
                 (sb-ext:octets-to-string
                  (apply #'concatenate '(vector (unsigned-byte 8))
                         (nreverse chunks))
                  :external-format :utf-8))
             (true complete-p)
             (false (car proxy-error)))
        (ignore-errors (sb-thread:join-thread proxy-thread :timeout 5))))))

(define-test net/https-connect-proxy-101-is-rejected
  (let ((capture
          (make-array 512 :element-type '(unsigned-byte 8)
                          :adjustable t :fill-pointer 0))
        (proxy-error (list nil)))
    (multiple-value-bind (proxy-port proxy-thread)
        (%connect-proxy-fixture
         nil capture :status 101 :error-box proxy-error)
      (unwind-protect
           (let ((message
                   (handler-case
                       (progn
                         (net:https-request-stream
                          :host "origin.invalid" :port 443
                          :method "GET" :path "/"
                          :proxy-host "127.0.0.1" :proxy-port proxy-port
                          :verify nil)
                         nil)
                     (error (condition) (princ-to-string condition)))))
             (true message)
             (true (search "unrequested protocol upgrade" message))
             (false (car proxy-error)))
        (ignore-errors (sb-thread:join-thread proxy-thread :timeout 5))))))

(define-test net/fetch-https-connect-redirect-is-not-followed
  ;; A CONNECT 3xx is the proxy's response, not an origin redirect. Exercise
  ;; the complete Fetch -> worker -> CONNECT -> Response path.
  (let ((capture
          (make-array 512 :element-type '(unsigned-byte 8)
                          :adjustable t :fill-pointer 0))
        (proxy-error (list nil))
        (realm (eng:make-realm)))
    (rt:install-runtime realm :argv '(:script "[test]" :rest nil) :cwd "/tmp")
    (unwind-protect
         (let ((eng:*realm* realm)
               (rt::*fetch-environment-reader*
                 (lambda (name) (declare (ignore name)) nil)))
           (let ((g (eng:realm-global realm)))
             (eng:run-program (eng:parse-program +fetch-info-src+) realm)
             (multiple-value-bind (proxy-port proxy-thread)
                 (%connect-proxy-fixture
                  nil capture :status 302
                  :location "https://must-not-be-followed.invalid/"
                  :error-box proxy-error)
               (unwind-protect
                    (multiple-value-bind (kind info)
                        (fetch-info-url
                         g realm "https://origin.invalid/private"
                         (format nil "{proxy:'http://127.0.0.1:~d'}"
                                 proxy-port))
                      (is eq :fulfilled kind)
                      (is = 302 (info-num info "status"))
                      (is string= "auth-required" (info-str info "body"))
                      (false (car proxy-error)))
                 (ignore-errors
                   (sb-thread:join-thread proxy-thread :timeout 5))))))
      (eng:teardown-realm realm))))

(define-test net/https-transport-streams-request-body
  (let ((capture
          (make-array 1024 :element-type '(unsigned-byte 8)
                           :adjustable t :fill-pointer 0))
        (parts
          (list (sb-ext:string-to-octets "tls-" :external-format :utf-8)
                (sb-ext:string-to-octets "upload" :external-format :utf-8)))
        (pulls 0))
    (multiple-value-bind (fport thread)
        (%https-fixture-server
         (%cert "localhost-leaf.crt") (%cert "localhost-leaf.key")
         (%http-response-bytes 200 "ok" "text/plain")
         :request-capture capture :read-request-body-p t)
      (unwind-protect
           (let ((status nil)
                 (complete-p nil))
             (net:https-request-stream
              :host "localhost" :port fport :method "POST" :path "/upload"
              :verify nil
              :request-body-source
              (lambda ()
                (incf pulls)
                (if parts
                    (values (pop parts) nil)
                    (values nil t)))
              :on-headers (lambda (head) (setf status (net:hres-status head)))
              :on-data (lambda (chunk) (declare (ignore chunk)))
              :on-complete (lambda () (setf complete-p t)))
             (is = 200 status)
             (true complete-p)
             (is = 3 pulls)
             (let ((wire
                     (sb-ext:octets-to-string
                      (subseq capture 0 (fill-pointer capture))
                      :external-format :latin-1)))
               (true (search "Transfer-Encoding: chunked" wire))
               (false (search "Content-Length:" wire))
               (true
                (search
                 (format nil "4~c~ctls-~c~c6~c~cupload~c~c0~c~c~c~c"
                         #\Return #\Newline #\Return #\Newline
                         #\Return #\Newline #\Return #\Newline
                         #\Return #\Newline #\Return #\Newline)
                 wire))))
        (ignore-errors (sb-thread:join-thread thread :timeout 5))))))

(define-test net/https-async-stream-bridge-pauses-worker
  (let* ((body (make-string 40000 :initial-element #\x))
         (response (%http-response-bytes 200 body "text/plain"))
         (tail-sent (list nil)))
    (multiple-value-bind (fport thread)
        (%https-fixture-server
         (%cert "localhost-leaf.crt") (%cert "localhost-leaf.key")
         response :split-at 1000 :tail-sent-box tail-sent)
      (let ((loop (lp:make-event-loop :workers 1))
            (chunks '())
            (data-calls 0)
            (headers-before-tail nil)
            (complete-p nil)
            (error-code nil)
            (pause nil)
            (resume nil))
        (unwind-protect
             (progn
               (multiple-value-bind (cancel pause-function resume-function)
                   (rt::%https-request-stream-async
                    loop :host "localhost" :port fport :method "GET" :path "/"
                    :verify nil :timeout 5000
                    :on-headers
                    (lambda (head)
                      (is = 200 (net:hres-status head))
                      (setf headers-before-tail (not (car tail-sent))))
                    :on-data
                    (lambda (chunk)
                      (push chunk chunks)
                      (incf data-calls)
                      (when (= data-calls 1)
                        (funcall pause)
                        (lp:set-timer loop 10 (lambda () (funcall resume)))))
                    :on-complete (lambda () (setf complete-p t))
                    :on-error (lambda (code) (setf error-code code)))
                 (declare (ignore cancel))
                 (setf pause pause-function
                       resume resume-function))
               (lp:run-loop loop)
               (false error-code)
               (true complete-p)
               (true headers-before-tail)
               (true (plusp data-calls))
               (is = (length body)
                   (reduce #'+ chunks :key #'length :initial-value 0)))
          (lp:destroy-event-loop loop)
          (ignore-errors (sb-thread:join-thread thread :timeout 5)))))))

(define-test net/https-async-stream-bridge-pulls-request-body
  (let ((realm (eng:make-realm))
        (capture
          (make-array 1024 :element-type '(unsigned-byte 8)
                           :adjustable t :fill-pointer 0)))
    (rt:install-runtime realm :argv '(:script "[test]" :rest nil) :cwd "/tmp")
    (unwind-protect
         (let* ((eng:*realm* realm)
                (loop (eng:current-loop))
                (stream (rt::%new-body-stream))
                (reader nil)
                (status nil)
                (complete-p nil)
                (upload-complete-p nil)
                (error-code nil))
           (rt::%body-stream-enqueue
            stream (sb-ext:string-to-octets "async-" :external-format :utf-8))
           (rt::%body-stream-enqueue
            stream (sb-ext:string-to-octets "upload" :external-format :utf-8))
           (rt::%body-stream-close stream)
           (setf reader (rt::%body-stream-reader stream))
           (multiple-value-bind (fport thread)
               (%https-fixture-server
                (%cert "localhost-leaf.crt") (%cert "localhost-leaf.key")
                (%http-response-bytes 200 "ok" "text/plain")
                :request-capture capture :read-request-body-p t)
             (unwind-protect
                  (progn
                    (rt::%https-request-stream-async
                     loop :host "localhost" :port fport
                     :method "POST" :path "/async-upload" :verify nil
                     :request-body-reader reader
                     :on-request-complete
                     (lambda ()
                       (setf upload-complete-p t)
                       (rt::%body-reader-release reader))
                     :on-headers
                     (lambda (head) (setf status (net:hres-status head)))
                     :on-data (lambda (chunk) (declare (ignore chunk)))
                     :on-complete (lambda () (setf complete-p t))
                     :on-error (lambda (code) (setf error-code code)))
                    (lp:run-loop loop)
                    (false error-code)
                    (is = 200 status)
                    (true complete-p)
                    (true upload-complete-p)
                    (false (rt::js-body-stream-locked-p stream))
                    (let ((wire
                            (sb-ext:octets-to-string
                             (subseq capture 0 (fill-pointer capture))
                             :external-format :latin-1)))
                      (true (search "Transfer-Encoding: chunked" wire))
                      (true
                       (search
                        (format nil
                                "6~c~casync-~c~c6~c~cupload~c~c0~c~c~c~c"
                                #\Return #\Newline #\Return #\Newline
                                #\Return #\Newline #\Return #\Newline
                                #\Return #\Newline #\Return #\Newline)
                        wire))))
               (ignore-errors (sb-thread:join-thread thread :timeout 5)))))
      (eng:teardown-realm realm))))

;;; --- (2) verification matrix (direct verify functions vs the test PKI) --------

(defun %parse-cert (name) (pure-tls:parse-certificate-from-file (%cert name)))

(defun %verify-chain (leaf &optional (hostname "localhost"))
  "Verify LEAF's chain against the test CA at NOW; returns T or signals (the exact call
net:https-request's make-tls-client-stream makes)."
  (pure-tls::verify-certificate-chain (list (%parse-cert (concatenate 'string leaf ".crt")))
                                      (list (%parse-cert "test-ca.crt"))
                                      (get-universal-time) hostname :purpose :server-auth))

(defun %chain-signal (leaf)
  "The lowercased report of the condition signaled verifying LEAF's chain, or NIL if it verified."
  (handler-case (progn (%verify-chain leaf) nil)
    (error (e) (string-downcase (princ-to-string e)))))

(define-test net/https-verify-good-leaf
  ;; the good leaf (SAN localhost, chained to the test CA, in date) verifies cleanly
  (is eq t (%verify-chain "localhost-leaf"))
  (is eq t (pure-tls:verify-hostname (%parse-cert "localhost-leaf.crt") "localhost")))

(define-test net/https-verify-negatives-fail-closed
  ;; each bad cert type is rejected with a distinct, descriptive error
  (let ((exp (%chain-signal "expired"))
        (self (%chain-signal "self-signed"))
        (bad (%chain-signal "bad-chain")))
    (true exp)  (true (search "expire" (or exp "")))                 ; expired → certificate expired
    (true self) (true (search "anchor" (or self "")))                ; self-signed → not anchored (UNKNOWN-CA)
    (true bad)  (true (search "anchor" (or bad ""))))                ; bad-chain → not anchored (UNKNOWN-CA)
  ;; wrong-host: the chain is valid (signed by the CA) but the hostname must mismatch
  (is eq t (%verify-chain "wrong-host"))
  (true (handler-case (progn (pure-tls:verify-hostname (%parse-cert "wrong-host.crt") "localhost") nil)
          (error () t))))

;;; --- fetch integration: fail closed end-to-end (deterministic) ----------------

(define-test net/https-fetch-fails-closed
  ;; The FULL fetch → worker-pool → pure-tls → verify path, hermetic AND deterministic: the
  ;; fixture presents localhost-leaf (signed by the TEST CA, which is NOT in the system store,
  ;; and we do NOT inject it), so verification MUST reject — whether the peer cert is recorded
  ;; (UNKNOWN-CA) or races to nil (NO-PEER-CERTIFICATE). fetch must NEVER fulfill (accepting an
  ;; untrusted certificate would be a certificate-authentication bypass).
  (let ((realm (eng:make-realm)))
    (rt:install-runtime realm :argv '(:script "[test]" :rest nil) :cwd "/tmp")
    (unwind-protect
         (let* ((eng:*realm* realm) (g (eng:realm-global realm)))
           (eng:run-program
            (eng:parse-program
             "globalThis.__f = (u) => fetch(u).then(r => ({ok:true}), e => ({ok:false, name:e.name}))")
            realm)
           (multiple-value-bind (fport thread)
               (%https-fixture-server (%cert "localhost-leaf.crt") (%cert "localhost-leaf.key")
                                      (%http-response-bytes 200 "SHOULD-NOT-REACH-THE-CLIENT"))
             (unwind-protect
                  (multiple-value-bind (kind info)
                      (eng:run-callback-to-settlement
                       (lambda () (eng:js-call (eng:js-get g "__f") eng:+undefined+
                                               (list (format nil "https://localhost:~d/" fport))))
                       realm :timeout-ms 15000)
                    (is eq :fulfilled kind)                          ; the JS promise settles
                    (is eq eng:+false+ (eng:js-get info "ok")))      ; and the fetch REJECTED (fail closed)
               (ignore-errors (sb-thread:join-thread thread :timeout 5)))))
      (eng:teardown-realm realm))))

;;; --- Phase 28: origin-keyed HTTPS idle pool (fail-closed) --------------------

(defun %tls-pool-idle (loop host port)
  "Snapshot idle TLS streams using the same key defaults as the HTTPS client."
  (net::%tls-pool-idle-transports
   loop host port
   :ca-file (net::%system-ca-file)
   :verify nil))

(define-test net/https-reuses-an-idle-origin-connection
  (multiple-value-bind (port thread stop accepted requests)
      (%https-persistent-fixture-server
       (%cert "localhost-leaf.crt") (%cert "localhost-leaf.key")
       :response-fn
       (lambda (index)
         (%http-response-bytes 200 (format nil "body-~d" index) "text/plain"
                               :connection "keep-alive")))
    (declare (ignore requests))
    (let ((loop (lp:make-event-loop :workers 1)))
      (unwind-protect
           (progn
             (multiple-value-bind (status body error complete)
                 (%https-pooled-request loop "localhost" port "/one")
               (false error)
               (true complete)
               (is = 200 status)
               (is string= "body-1"
                   (sb-ext:octets-to-string body :external-format :utf-8)))
             (let ((first-idle (%tls-pool-idle loop "localhost" port)))
               (is = 1 (length first-idle))
               (is = 1 (car accepted))
               (multiple-value-bind (status body error complete)
                   (%https-pooled-request loop "localhost" port "/two")
                 (false error)
                 (true complete)
                 (is = 200 status)
                 (is string= "body-2"
                     (sb-ext:octets-to-string body :external-format :utf-8)))
               (let ((second-idle (%tls-pool-idle loop "localhost" port)))
                 (is = 1 (length second-idle))
                 (is eq (first first-idle) (first second-idle))
                 (is = 1 (car accepted)))))
        (setf (car stop) t)
        (lp:destroy-event-loop loop)
        (ignore-errors (sb-thread:join-thread thread :timeout 5))))))

(define-test net/https-connection-close-is-never-pooled
  (multiple-value-bind (port thread stop accepted requests)
      (%https-persistent-fixture-server
       (%cert "localhost-leaf.crt") (%cert "localhost-leaf.key"))
    (declare (ignore accepted requests))
    (let ((loop (lp:make-event-loop :workers 1)))
      (unwind-protect
           (progn
             (multiple-value-bind (status body error complete)
                 (%https-pooled-request
                  loop "localhost" port "/close"
                  :headers '(("connection" . "close")))
               (declare (ignore body))
               (false error)
               (true complete)
               (is = 200 status))
             (is = 0 (length (%tls-pool-idle loop "localhost" port))))
        (setf (car stop) t)
        (lp:destroy-event-loop loop)
        (ignore-errors (sb-thread:join-thread thread :timeout 5))))))

(define-test net/https-pool-isolates-distinct-origins
  (multiple-value-bind (port-a thread-a stop-a accepted-a requests-a)
      (%https-persistent-fixture-server
       (%cert "localhost-leaf.crt") (%cert "localhost-leaf.key")
       :response-fn
       (lambda (index)
         (declare (ignore index))
         (%http-response-bytes 200 "a" "text/plain" :connection "keep-alive")))
    (declare (ignore requests-a))
    (multiple-value-bind (port-b thread-b stop-b accepted-b requests-b)
        (%https-persistent-fixture-server
         (%cert "localhost-leaf.crt") (%cert "localhost-leaf.key")
         :response-fn
         (lambda (index)
           (declare (ignore index))
           (%http-response-bytes 200 "b" "text/plain" :connection "keep-alive")))
      (declare (ignore requests-b))
      (let ((loop (lp:make-event-loop :workers 1)))
        (unwind-protect
             (progn
               (multiple-value-bind (status body error complete)
                   (%https-pooled-request loop "localhost" port-a "/a")
                 (declare (ignore body))
                 (false error) (true complete) (is = 200 status))
               (multiple-value-bind (status body error complete)
                   (%https-pooled-request loop "localhost" port-b "/b")
                 (declare (ignore body))
                 (false error) (true complete) (is = 200 status))
               (let* ((idle-a (%tls-pool-idle loop "localhost" port-a))
                      (idle-b (%tls-pool-idle loop "localhost" port-b))
                      (first-a (first idle-a)))
                 (is = 1 (length idle-a))
                 (is = 1 (length idle-b))
                 (is = 1 (car accepted-a))
                 (is = 1 (car accepted-b))
                 (isnt eq first-a (first idle-b))
                 (multiple-value-bind (status body error complete)
                     (%https-pooled-request loop "localhost" port-a "/a2")
                   (declare (ignore body))
                   (false error) (true complete) (is = 200 status))
                 (is = 1 (car accepted-a))
                 (is eq first-a
                     (first (%tls-pool-idle loop "localhost" port-a)))))
          (setf (car stop-a) t (car stop-b) t)
          (lp:destroy-event-loop loop)
          (ignore-errors (sb-thread:join-thread thread-a :timeout 5))
          (ignore-errors (sb-thread:join-thread thread-b :timeout 5)))))))

(define-test net/https-evicts-peer-closed-idle-connections
  (multiple-value-bind (port thread stop accepted requests)
      (%https-persistent-fixture-server
       (%cert "localhost-leaf.crt") (%cert "localhost-leaf.key")
       :close-after-request-n 1
       :response-fn
       (lambda (index)
         (declare (ignore index))
         (%http-response-bytes 200 "once" "text/plain"
                               :connection "keep-alive")))
    (declare (ignore requests))
    (let ((loop (lp:make-event-loop :workers 1)))
      (unwind-protect
           (progn
             (multiple-value-bind (status body error complete)
                 (%https-pooled-request loop "localhost" port "/first")
               (false error)
               (true complete)
               (is = 200 status)
               (is string= "once"
                   (sb-ext:octets-to-string body :external-format :utf-8)))
             (is = 1 (car accepted))
             ;; Give the fixture time to close after the keep-alive response.
             (sleep 0.05)
             (multiple-value-bind (status body error complete)
                 (%https-pooled-request loop "localhost" port "/second")
               (false error)
               (true complete)
               (is = 200 status)
               (is string= "once"
                   (sb-ext:octets-to-string body :external-format :utf-8)))
             (is = 2 (car accepted)))
        (setf (car stop) t)
        (lp:destroy-event-loop loop)
        (ignore-errors (sb-thread:join-thread thread :timeout 5))))))
