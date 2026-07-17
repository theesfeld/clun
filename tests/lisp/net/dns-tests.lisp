;;;; Deterministic Phase-28 DNS wire and resolver-boundary tests.

(in-package :clun-test)

(defun %dns-test-octets (&rest values)
  (make-array (length values) :element-type '(unsigned-byte 8)
              :initial-contents values))

(defun %dns-test-concat (&rest vectors)
  (apply #'concatenate '(vector (unsigned-byte 8)) vectors))

(defun %dns-test-u16 (value)
  (%dns-test-octets (ldb (byte 8 8) value) (ldb (byte 8 0) value)))

(defun %dns-test-u32 (value)
  (%dns-test-octets (ldb (byte 8 24) value) (ldb (byte 8 16) value)
                     (ldb (byte 8 8) value) (ldb (byte 8 0) value)))

(defun %dns-test-header (id flags questions answers &optional (authority 0) (additional 0))
  (%dns-test-concat (%dns-test-u16 id) (%dns-test-u16 flags)
                    (%dns-test-u16 questions) (%dns-test-u16 answers)
                    (%dns-test-u16 authority) (%dns-test-u16 additional)))

(defun %dns-test-question (name type)
  (subseq (clun.net::%dns-encode-query name type 0) 12))

(defun %dns-test-rr (owner type ttl rdata)
  (%dns-test-concat owner (%dns-test-u16 type) (%dns-test-u16 1)
                    (%dns-test-u32 ttl) (%dns-test-u16 (length rdata)) rdata))

(defun %dns-test-error-code (thunk)
  (handler-case
      (progn (funcall thunk) :no-error)
    (clun.net::dns-error (condition)
      (clun.net::socket-open-error-code condition))))

(defun %dns-test-address-texts (addresses)
  (mapcar #'clun.net::dns-address-text addresses))

(define-test net/dns-query-encoding
  (multiple-value-bind (query id)
      (clun.net::%dns-encode-query "www.example.com" 1 #x1234)
    (is = #x1234 id)
    (is equalp
        (%dns-test-octets
         #x12 #x34 #x01 #x00 #x00 #x01 #x00 #x00 #x00 #x00 #x00 #x00
         3 #x77 #x77 #x77 7 #x65 #x78 #x61 #x6d #x70 #x6c #x65
         3 #x63 #x6f #x6d 0 #x00 #x01 #x00 #x01)
        query)
    (is equalp query
        (clun.net::%dns-encode-query "www.example.com." 1 #x1234))
    (multiple-value-bind (aaaa aaaa-id)
        (clun.net::%dns-encode-query "www.example.com" 28 #xbeef)
      (is = #xbeef aaaa-id)
      (is = #xbe (aref aaaa 0))
      (is = #xef (aref aaaa 1))
      (is = 28 (aref aaaa (- (length aaaa) 3))))
    (is equal "EINVAL"
        (%dns-test-error-code
         (lambda ()
           (clun.net::%dns-encode-query
            (concatenate 'string (make-string 64 :initial-element #\a) ".example")
            1 1))))))

(define-test net/dns-parse-compressed-cname-a
  ;; alias.example.com -> real.example.com, where both owner names and the CNAME
  ;; suffix use RFC 1035 compression pointers into the original question.
  (let* ((id #x4142)
         (question (%dns-test-question "alias.example.com" 1))
         (owner-alias (%dns-test-octets #xc0 #x0c))
         ;; "example.com" begins at packet offset 18 (#x12).
         (real-name (%dns-test-octets 4 #x72 #x65 #x61 #x6c #xc0 #x12))
         (cname (%dns-test-rr owner-alias 5 60 real-name))
         (address (%dns-test-rr real-name 1 30
                                (%dns-test-octets 192 0 2 10)))
         (packet (%dns-test-concat (%dns-test-header id #x8180 1 2)
                                   question cname address)))
    (multiple-value-bind (addresses ttl canonical-name truncated-p)
        (clun.net::%dns-parse-response packet id "alias.example.com" 1)
      (false truncated-p)
      (is equal '("192.0.2.10") (%dns-test-address-texts addresses))
      (is string= "real.example.com" canonical-name)
      (is = 30 ttl)
      (false (clun.net::dns-address-ipv6-p (first addresses))))))

(define-test net/dns-parse-compressed-aaaa
  (let* ((id #x5152)
         (question (%dns-test-question "v6.example.com" 28))
         (rdata (%dns-test-octets
                 #x20 #x01 #x0d #xb8 0 0 0 0 0 0 0 0 0 0 0 1))
         (answer (%dns-test-rr (%dns-test-octets #xc0 #x0c) 28 120 rdata))
         (packet (%dns-test-concat (%dns-test-header id #x8180 1 1)
                                   question answer)))
    (multiple-value-bind (addresses ttl canonical-name truncated-p)
        (clun.net::%dns-parse-response packet id "v6.example.com" 28)
      (false truncated-p)
      (is equal '("2001:db8::1") (%dns-test-address-texts addresses))
      (is string= "v6.example.com" canonical-name)
      (is = 120 ttl)
      (true (clun.net::dns-address-ipv6-p (first addresses))))))

(define-test net/dns-truncated-response-is-explicit
  (let* ((id #x6162)
         (packet (%dns-test-concat
                  (%dns-test-header id #x8380 1 0)
                  (%dns-test-question "large.example.com" 1))))
    (multiple-value-bind (addresses ttl canonical-name truncated-p)
        (clun.net::%dns-parse-response packet id "large.example.com" 1)
      (declare (ignore canonical-name ttl))
      (false addresses)
      (true truncated-p))))

(define-test net/dns-malformed-packets-fail-boundedly
  (is equal "EBADRESP"
      (%dns-test-error-code
       (lambda ()
         (clun.net::%dns-parse-response (%dns-test-octets 0 1 2) 1 "x.test" 1))))
  ;; The question name points to itself. A decoder without a pointer-jump/visited
  ;; bound loops forever here.
  (let ((pointer-loop
          (%dns-test-concat (%dns-test-header #x1010 #x8180 1 0)
                            (%dns-test-octets #xc0 #x0c 0 1 0 1))))
    (is equal "EBADRESP"
        (%dns-test-error-code
         (lambda ()
           (clun.net::%dns-parse-response pointer-loop #x1010 "x.test" 1)))))
  ;; RDLENGTH claims four bytes, but only three bytes remain.
  (let* ((question (%dns-test-question "short.test" 1))
         (bad-answer
           (%dns-test-concat (%dns-test-octets #xc0 #x0c)
                             (%dns-test-u16 1) (%dns-test-u16 1)
                             (%dns-test-u32 60) (%dns-test-u16 4)
                             (%dns-test-octets 192 0 2)))
         (packet (%dns-test-concat (%dns-test-header #x2020 #x8180 1 1)
                                   question bad-answer)))
    (is equal "EBADRESP"
        (%dns-test-error-code
         (lambda ()
           (clun.net::%dns-parse-response packet #x2020 "short.test" 1)))))
  ;; A valid response for another transaction must not be accepted.
  (let ((packet (%dns-test-concat
                 (%dns-test-header #x3030 #x8180 1 0)
                 (%dns-test-question "id.test" 1))))
    (is equal "EBADRESP"
        (%dns-test-error-code
         (lambda ()
           (clun.net::%dns-parse-response packet #x3031 "id.test" 1))))))

(define-test net/dns-rcode-errors-are-exact
  (let ((nxdomain
          (%dns-test-concat (%dns-test-header #x4040 #x8183 1 0)
                            (%dns-test-question "missing.test" 1)))
        (servfail
          (%dns-test-concat (%dns-test-header #x5050 #x8182 1 0)
                            (%dns-test-question "retry.test" 1))))
    (is equal "ENOTFOUND"
        (%dns-test-error-code
         (lambda ()
           (clun.net::%dns-parse-response nxdomain #x4040 "missing.test" 1))))
    (is equal "EAI_AGAIN"
        (%dns-test-error-code
         (lambda ()
           (clun.net::%dns-parse-response servfail #x5050 "retry.test" 1))))))

(define-test net/dns-family-interleave
  (let* ((v4a (clun.net::make-dns-address :text "192.0.2.1" :ipv6-p nil :ttl 60))
         (v4b (clun.net::make-dns-address :text "192.0.2.2" :ipv6-p nil :ttl 60))
         (v6a (clun.net::make-dns-address :text "2001:db8::1" :ipv6-p t :ttl 60))
         (v6b (clun.net::make-dns-address :text "2001:db8::2" :ipv6-p t :ttl 60)))
    (is equal '("2001:db8::1" "192.0.2.1" "2001:db8::2" "192.0.2.2")
        (%dns-test-address-texts
         (clun.net::%interleave-dns-addresses (list v6a v6b) (list v4a v4b))))))

(define-test net/dns-literals-and-localhost-avoid-network
  (let ((v4 (clun.net::resolve-hostname-all "127.0.0.1" :nameservers '() :use-cache nil))
        (v6 (clun.net::resolve-hostname-all "2001:db8::1" :nameservers '() :use-cache nil))
        (bracketed-v6
          (clun.net::resolve-hostname-all "[2001:db8::1]" :nameservers '()
                                                        :use-cache nil))
        (local (clun.net::resolve-hostname-all "localhost" :nameservers '() :use-cache nil)))
    (is equal '("127.0.0.1") (%dns-test-address-texts v4))
    (false (clun.net::dns-address-ipv6-p (first v4)))
    (is equal '("2001:db8::1") (%dns-test-address-texts v6))
    (true (clun.net::dns-address-ipv6-p (first v6)))
    (is equal '("2001:db8::1") (%dns-test-address-texts bracketed-v6))
    (is equal '("::1" "127.0.0.1") (%dns-test-address-texts local))
    (is string= "::1" (clun.net::resolve-hostname "localhost"))))

(define-test net/dns-resolver-udp-fixture
  (let ((socket (make-instance 'sb-bsd-sockets:inet-socket
                               :type :datagram :protocol :udp))
        (thread nil)
        (server-error nil)
        (query-types '())
        (done (sb-thread:make-semaphore :count 0)))
    (unwind-protect
         (progn
           (sb-bsd-sockets:socket-bind
            socket (sb-bsd-sockets:make-inet-address "127.0.0.1") 0)
           (multiple-value-bind (address port)
               (sb-bsd-sockets:socket-name socket)
             (declare (ignore address))
             (setf thread
                   (sb-thread:make-thread
                    (lambda ()
                      (unwind-protect
                           (handler-case
                               (loop repeat 2 do
                                 (unless (sb-sys:wait-until-fd-usable
                                          (sb-bsd-sockets:socket-file-descriptor socket)
                                          :input 2 nil)
                                   (error "timed out waiting for DNS query"))
                                 (let ((buffer
                                         (make-array 512
                                                     :element-type '(unsigned-byte 8))))
                                   (multiple-value-bind (ignored count peer peer-port)
                                       (sb-bsd-sockets:socket-receive
                                        socket buffer (length buffer)
                                        :element-type '(unsigned-byte 8))
                                     (declare (ignore ignored))
                                     (when (or (null count) (< count 16))
                                       (error "invalid DNS fixture query length"))
                                     (let* ((query (subseq buffer 0 count))
                                            (id (clun.net::%dns-u16 query 0))
                                            (qtype (clun.net::%dns-u16 query (- count 4)))
                                            (rdata
                                              (case qtype
                                                (1 (%dns-test-octets 192 0 2 20))
                                                (28 (%dns-test-octets
                                                     #x20 #x01 #x0d #xb8
                                                     0 0 0 0 0 0 0 0 0 0 0 1))
                                                (t (error "unexpected query type ~d"
                                                          qtype))))
                                            (response
                                              (%dns-test-concat
                                               (%dns-test-header id #x8180 1 1)
                                               (subseq query 12)
                                               (%dns-test-rr
                                                (%dns-test-octets #xc0 #x0c)
                                                qtype 60 rdata))))
                                       (push qtype query-types)
                                       (sb-bsd-sockets:socket-send
                                        socket response (length response)
                                        :address (list peer peer-port))))))
                             (error (condition)
                               (setf server-error condition)))
                        (sb-thread:signal-semaphore done)))
                    :name "clun-dns-test-server"))
             (let ((addresses nil)
                   (resolver-error nil))
               (handler-case
                   (setf addresses
                         (clun.net::resolve-hostname-all
                          "fixture.test" :nameservers '("127.0.0.1")
                                         :port port :timeout-ms 500 :use-cache nil))
                 (error (condition)
                   (setf resolver-error condition)))
               (true (sb-thread:wait-on-semaphore done :timeout 2))
               (sb-thread:join-thread thread)
               (setf thread nil)
               (false server-error)
               (false resolver-error)
               (is equal '(28 1) (nreverse query-types))
               (is equal '("2001:db8::1" "192.0.2.20")
                   (%dns-test-address-texts addresses))
               (true (clun.net::dns-address-ipv6-p (first addresses)))
               (false (clun.net::dns-address-ipv6-p (second addresses))))))
      (ignore-errors (sb-bsd-sockets:socket-close socket :abort t))
      (when thread
        (ignore-errors
          (sb-thread:join-thread thread :timeout 2 :default nil))))))

(define-test net/happy-eyeballs-falls-back-to-ipv4
  (let ((loop (lp:make-event-loop :workers 0))
        (server nil)
        (accepted nil)
        (winner nil)
        (failure-code nil)
        (cancel nil)
        (watchdog nil))
    (labels ((maybe-stop ()
               (when (and accepted winner)
                 (when watchdog
                   (lp:clear-timer watchdog)
                   (setf watchdog nil))
                 (lp:loop-stop loop))))
      (unwind-protect
           (progn
             ;; Only AF_INET is listening. The leading ::1 candidate must fail,
             ;; after which the IPv4 candidate connects to this listener.
             (setf server
                   (net:tcp-listen
                    loop "127.0.0.1" 0
                    :on-connection
                    (lambda (tcp)
                      (setf accepted tcp)
                      (maybe-stop))))
             (setf watchdog
                   (lp:set-timer loop 1000 (lambda () (lp:loop-stop loop))))
             (setf cancel
                   (net:tcp-connect-happy
                    loop
                    (list (clun.net::make-dns-address
                           :text "::1" :ipv6-p t :ttl 60)
                          (clun.net::make-dns-address
                           :text "127.0.0.1" :ipv6-p nil :ttl 60))
                    (net:listener-port server)
                    :delay-ms 10
                    :on-connect
                    (lambda (tcp)
                      (setf winner tcp)
                      (maybe-stop))
                    :on-error
                    (lambda (tcp code)
                      (declare (ignore tcp))
                      (setf failure-code code)
                      (lp:loop-stop loop))))
             (lp:run-loop loop)
             (false failure-code)
             (true winner)
             (true accepted)
             (multiple-value-bind (peer peer-port) (net:tcp-peer winner)
               (declare (ignore peer-port))
               (is equalp (sb-bsd-sockets:make-inet-address "127.0.0.1") peer)))
        (when watchdog (ignore-errors (lp:clear-timer watchdog)))
        (when cancel (ignore-errors (funcall cancel)))
        (when accepted (ignore-errors (net:tcp-close accepted)))
        (when server (ignore-errors (net:listener-close server)))
        (lp:destroy-event-loop loop)))))
