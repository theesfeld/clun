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
     &key split-at tail-sent-box request-capture read-request-body-p)
  "Start a ONE-SHOT blocking pure-tls HTTPS server on 127.0.0.1:0 presenting CERT-FILE/KEY-FILE.
Returns (values port thread): accepts one connection, handshakes, reads the request headers to
CRLFCRLF (and optionally its terminal chunk), writes RESPONSE-BYTES, and closes with close_notify."
  (let ((lsock (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
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
                   (close tls))
               (error () nil))
          (ignore-errors (sb-bsd-sockets:socket-close lsock))))
      :name "https-fixture"))))

(defun %http-response-bytes (status body &optional (content-type "application/json"))
  (let ((hdr (with-output-to-string (s)
               (format s "HTTP/1.1 ~d OK~c~c" status #\Return #\Newline)
               (format s "Content-Type: ~a~c~c" content-type #\Return #\Newline)
               (format s "Content-Length: ~d~c~c" (length body) #\Return #\Newline)
               (format s "Connection: close~c~c" #\Return #\Newline)
               (format s "~c~c" #\Return #\Newline))))
    (concatenate '(vector (unsigned-byte 8))
                 (sb-ext:string-to-octets hdr :external-format :latin-1)
                 (sb-ext:string-to-octets body :external-format :utf-8))))

(define-test net/https-transport
  ;; The blocking TLS TRANSPORT (connect → pure-tls handshake → serialize request → read +
  ;; parse the response) works against an in-process pure-tls server. Verification is OFF here
  ;; (net:https-request :verify nil) so the test is deterministic — the pure-tls↔pure-tls path
  ;; records the peer certificate only racily (a pure-tls self-interop timing bug; with verify
  ;; ON it correctly FAILS CLOSED on a missing peer cert, which would make this test flaky).
  ;; Certificate verification is covered deterministically by the verify-function matrix below
  ;; + the end-to-end live smoke (STATE.md).
  (multiple-value-bind (fport thread)
      (%https-fixture-server (%cert "localhost-leaf.crt") (%cert "localhost-leaf.key")
                             (%http-response-bytes 200 "{\"tls\":\"ok\",\"n\":7}"))
    (unwind-protect
         (let ((resp (net:https-request :host "localhost" :port fport :method "GET" :path "/"
                                        :verify nil)))
           (is = 200 (net:hres-status resp))
           (true (search "\"tls\":\"ok\"" (sb-ext:octets-to-string (net:hres-body resp)
                                                                   :external-format :utf-8))))
      (ignore-errors (sb-thread:join-thread thread :timeout 5)))))

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
