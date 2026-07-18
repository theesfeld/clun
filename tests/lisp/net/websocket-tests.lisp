;;;; websocket-tests.lisp — Phase 51 M1: handshake, framing, echo over Clun.serve.

(in-package :clun-test)

(define-test net/websocket-scaffold-types
  (true (plusp ws:+opcode-text+))
  (is = 1 ws:+opcode-text+)
  (is = 2 ws:+opcode-binary+)
  (is = 8 ws:+opcode-close+)
  (true (search "258EAFA5" ws:+ws-guid+))
  (let ((frame (ws:make-ws-frame :opcode ws:+opcode-text+
                                 :payload (make-array 0 :element-type '(unsigned-byte 8)))))
    (true (ws:ws-frame-p frame))
    (true (ws:ws-frame-fin frame))
    (is = ws:+opcode-text+ (ws:ws-frame-opcode frame)))
  (let ((opts (ws:make-ws-handler-options)))
    (true (ws:ws-handler-options-p opts))
    (is = ws:+default-max-payload-bytes+
        (ws:ws-handler-options-max-payload-length opts))))

(define-test net/websocket-handshake-accept-key
  "RFC 6455 §1.3 example: key dGhlIHNhbXBsZSBub25jZQ== → s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
  (is string= "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
      (ws:handshake-accept-key "dGhlIHNhbXBsZSBub25jZQ=="))
  (true (ws:websocket-upgrade-request-p
         '(("Upgrade" . "websocket")
           ("Connection" . "Upgrade")
           ("Sec-WebSocket-Key" . "dGhlIHNhbXBsZSBub25jZQ==")
           ("Sec-WebSocket-Version" . "13"))))
  (false (ws:websocket-upgrade-request-p
          '(("Upgrade" . "websocket")
            ("Connection" . "keep-alive")
            ("Sec-WebSocket-Key" . "dGhlIHNhbXBsZSBub25jZQ==")
            ("Sec-WebSocket-Version" . "13"))))
  (let ((resp (ws:opening-handshake-response "dGhlIHNhbXBsZSBub25jZQ==")))
    (let ((s (sb-ext:octets-to-string resp :external-format :latin-1)))
      (true (search "101 Switching Protocols" s))
      (true (search "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" s))
      (true (search "Upgrade: websocket" s)))))

(define-test net/websocket-frame-roundtrip-text
  (let* ((frame (ws:make-text-frame "hello"))
         (wire (ws:encode-frame frame))
         (mask (make-array 4 :element-type '(unsigned-byte 8)
                             :initial-contents '(1 2 3 4)))
         (masked-wire (ws:encode-frame frame :mask mask)))
    (multiple-value-bind (decoded next) (ws:decode-frame wire)
      (true (ws:ws-frame-p decoded))
      (is = (length wire) next)
      (is = ws:+opcode-text+ (ws:ws-frame-opcode decoded))
      (true (ws:ws-frame-fin decoded))
      (false (ws:ws-frame-masked decoded))
      (is string= "hello"
          (sb-ext:octets-to-string (ws:ws-frame-payload decoded)
                                   :external-format :utf-8)))
    (multiple-value-bind (decoded next) (ws:decode-frame masked-wire)
      (true (ws:ws-frame-p decoded))
      (is = (length masked-wire) next)
      (true (ws:ws-frame-masked decoded))
      (is string= "hello"
          (sb-ext:octets-to-string (ws:ws-frame-payload decoded)
                                   :external-format :utf-8)))
    ;; Incomplete buffer → need more.
    (multiple-value-bind (decoded next) (ws:decode-frame (subseq wire 0 1))
      (true (null decoded))
      (is = 0 next))))

(define-test net/websocket-frame-control-ping-pong-close
  (let* ((ping (ws:encode-frame (ws:make-ping-frame #(9 9))))
         (pong (ws:encode-frame (ws:make-pong-frame #(9 9))))
         (close (ws:encode-frame (ws:make-close-frame 1000 "bye"))))
    (multiple-value-bind (f n) (ws:decode-frame ping)
      (is = ws:+opcode-ping+ (ws:ws-frame-opcode f))
      (is equalp #(9 9) (ws:ws-frame-payload f))
      (is = (length ping) n))
    (multiple-value-bind (f n) (ws:decode-frame pong)
      (is = ws:+opcode-pong+ (ws:ws-frame-opcode f))
      (is = (length pong) n))
    (multiple-value-bind (f n) (ws:decode-frame close)
      (is = ws:+opcode-close+ (ws:ws-frame-opcode f))
      (is = (length close) n)
      (multiple-value-bind (code reason) (ws:parse-close-payload (ws:ws-frame-payload f))
        (is = 1000 code)
        (is string= "bye" reason)))))

(define-test net/websocket-pubsub-helpers
  "Topic hub subscribe/publish/count pure-CL substrate."
  (let ((hub (ws:make-ws-topic-hub))
        (a (list :a))
        (b (list :b)))
    (ws:topic-subscribe hub a "chat")
    (ws:topic-subscribe hub b "chat")
    (ws:topic-subscribe hub a "news")
    (is = 2 (ws:topic-subscriber-count hub "chat"))
    (is = 1 (ws:topic-subscriber-count hub "news"))
    (true (ws:topic-subscribed-p hub a "chat"))
    (false (ws:topic-subscribed-p hub b "news"))
    (is equal '("chat" "news") (ws:topic-subscriptions hub a))
    (ws:topic-unsubscribe hub a "chat")
    (is = 1 (ws:topic-subscriber-count hub "chat"))
    (ws:topic-unsubscribe-all hub b)
    (is = 0 (ws:topic-subscriber-count hub "chat"))))

(define-test net/websocket-fragment-reassembly
  "Fragmented text frames reassemble under maxPayloadLength."
  (let ((state (ws:make-ws-fragment-state)))
    (is eq :need-more
        (ws:fragment-feed state (ws:make-text-frame "hel" :fin nil)))
    (multiple-value-bind (tag opcode payload rsv1)
        (ws:fragment-feed state
                          (ws:make-ws-frame :fin t
                                            :opcode ws:+opcode-continuation+
                                            :payload (sb-ext:string-to-octets
                                                      "lo" :external-format :utf-8)))
      (is eq :message tag)
      (is = ws:+opcode-text+ opcode)
      (false rsv1)
      (is string= "hello"
          (sb-ext:octets-to-string payload :external-format :utf-8)))))

(define-test net/websocket-permessage-deflate-roundtrip
  "chipz inflate + stored-block compress round-trip for permessage-deflate."
  (let* ((raw (sb-ext:string-to-octets "deflate-me-please"
                                       :external-format :utf-8))
         (compressed (ws:compress-permessage-deflate raw))
         (out (ws:inflate-permessage-deflate compressed)))
    (is equalp raw out)
    (true (ws:client-offers-permessage-deflate-p
           '(("Sec-WebSocket-Extensions" . "permessage-deflate; client_max_window_bits"))))))

(define-test net/websocket-pubsub-echo-and-count
  "server.publish / subscriberCount and ws.subscribe deliver fan-out."
  (let ((realm (eng:make-realm)))
    (rt:install-runtime realm :argv '(:script "[test]" :rest nil) :cwd "/tmp")
    (let ((eng:*realm* realm))
      (unwind-protect
           (let* ((g (eng:realm-global realm))
                  (loop (eng:current-loop))
                  (opened (list nil))
                  (got (list nil))
                  (ws-opt (eng:new-object))
                  (opts (eng:new-object))
                  (fetch
                    (eng:make-native-function "fetch" 2
                      (lambda (this args)
                        (declare (ignore this))
                        (let ((req (eng:arg args 0))
                              (server (eng:arg args 1)))
                          (if (eng:js-truthy
                               (eng:js-call (eng:js-get server "upgrade")
                                            server (list req)))
                              eng:+undefined+
                              (%resp g "upgrade-failed")))))))
             (eng:data-prop ws-opt "open"
                            (eng:make-native-function "open" 1
                              (lambda (this args)
                                (declare (ignore this))
                                (let ((sock (eng:arg args 0)))
                                  (eng:js-call (eng:js-get sock "subscribe")
                                               sock (list "room"))
                                  (setf (car opened) t))
                                eng:+undefined+)))
             (eng:data-prop ws-opt "message"
                            (eng:make-native-function "message" 2
                              (lambda (this args)
                                (declare (ignore this))
                                (setf (car got) (eng:to-string (eng:arg args 1)))
                                eng:+undefined+)))
             (eng:data-prop opts "port" 0d0)
             (eng:data-prop opts "hostname" "127.0.0.1")
             (eng:data-prop opts "fetch" fetch)
             (eng:data-prop opts "websocket" ws-opt)
             (let* ((server (clun.runtime::%clun-serve g opts))
                    (port (truncate (eng:js-get server "port")))
                    (buf (make-array 0 :element-type '(unsigned-byte 8)
                                       :adjustable t :fill-pointer 0))
                    (handshake-done (list nil))
                    (published (list nil)))
               (net:tcp-connect loop "127.0.0.1" port
                 :on-connect
                 (lambda (c)
                   (net:tcp-write
                    c
                    (req (crlf "GET /chat HTTP/1.1"
                               "Host: 127.0.0.1"
                               "Upgrade: websocket"
                               "Connection: Upgrade"
                               "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="
                               "Sec-WebSocket-Version: 13"))))
                 :on-data
                 (lambda (c data)
                   (declare (ignore c))
                   (loop for b across data do (vector-push-extend b buf))
                   (cond
                     ((not (car handshake-done))
                      (let ((text (sb-ext:octets-to-string
                                   buf :external-format :latin-1)))
                        (when (search (format nil "~c~c~c~c"
                                              #\Return #\Newline
                                              #\Return #\Newline)
                                      text)
                          (setf (car handshake-done) t
                                (fill-pointer buf) 0)
                          (lp:set-timer loop 30
                            (lambda ()
                              (let ((n (eng:js-call
                                        (eng:js-get server "subscriberCount")
                                        server (list "room")))
                                    (p (eng:js-call
                                        (eng:js-get server "publish")
                                        server (list "room" "fanout"))))
                                (is = 1 (truncate n))
                                (true (>= (truncate p) 1))
                                (setf (car published) t)))))))
                     (t
                      (multiple-value-bind (frame next)
                          (ws:decode-frame buf :start 0 :end (length buf))
                        (declare (ignore next))
                        (when frame
                          (is string= "fanout"
                              (sb-ext:octets-to-string
                               (ws:ws-frame-payload frame)
                               :external-format :utf-8))
                          (setf (car got) "fanout")
                          (lp:set-timer loop 20
                            (lambda () (lp:loop-stop loop))))))))
                 :on-close
                 (lambda (c code)
                   (declare (ignore c code))
                   (lp:loop-stop loop)))
               (lp:set-timer loop 4000 (lambda () (lp:loop-stop loop)))
               (lp:run-loop loop)
               (true (car opened))
               (true (car handshake-done))
               (true (car published))
               (is string= "fanout" (car got))))
        (eng:teardown-realm realm)))))

(define-test net/websocket-http-serve-still-works
  "HTTP-only Clun.serve is unchanged when websocket is not requested."
  (serve-and
   (lambda (g req loop)
     (declare (ignore req loop))
     (%resp g "plain-http"))
   (lambda (loop port g server)
     (declare (ignore g server))
     (let ((resp (client-request loop port
                   (req (crlf "GET / HTTP/1.1" "Host: x" "Connection: close")))))
       (true (search "200 OK" resp))
       (true (search "plain-http" resp))))))

(defun %ws-client-mask ()
  (make-array 4 :element-type '(unsigned-byte 8)
              :initial-contents '(#x12 #x34 #x56 #x78)))

(defun %ws-client-frame (frame)
  (ws:encode-frame frame :mask (%ws-client-mask)))

(define-test net/websocket-echo-server
  "Minimal echo: upgrade → open → text message → echoed text frame."
  (let ((realm (eng:make-realm)))
    (rt:install-runtime realm :argv '(:script "[test]" :rest nil) :cwd "/tmp")
    (let ((eng:*realm* realm))
      (unwind-protect
           (let* ((g (eng:realm-global realm))
                  (loop (eng:current-loop))
                  (opened (list nil))
                  (ws-opt (eng:new-object))
                  (opts (eng:new-object))
                  (fetch
                    (eng:make-native-function "fetch" 2
                      (lambda (this args)
                        (declare (ignore this))
                        (let ((req (eng:arg args 0))
                              (server (eng:arg args 1)))
                          (if (eng:js-truthy
                               (eng:js-call (eng:js-get server "upgrade")
                                            server (list req)))
                              eng:+undefined+
                              (%resp g "upgrade-failed")))))))
             (eng:data-prop ws-opt "open"
                            (eng:make-native-function "open" 1
                              (lambda (this args)
                                (declare (ignore this args))
                                (setf (car opened) t)
                                eng:+undefined+)))
             (eng:data-prop ws-opt "message"
                            (eng:make-native-function "message" 2
                              (lambda (this args)
                                (declare (ignore this))
                                (let ((sock (eng:arg args 0))
                                      (msg (eng:arg args 1)))
                                  (eng:js-call (eng:js-get sock "send")
                                               sock (list msg))
                                  eng:+undefined+))))
             (eng:data-prop opts "port" 0d0)
             (eng:data-prop opts "hostname" "127.0.0.1")
             (eng:data-prop opts "fetch" fetch)
             (eng:data-prop opts "websocket" ws-opt)
             (let* ((server (clun.runtime::%clun-serve g opts))
                    (port (truncate (eng:js-get server "port")))
                    (got (make-array 0 :element-type '(unsigned-byte 8)
                                       :adjustable t :fill-pointer 0))
                    (handshake-done (list nil))
                    (echoed (list nil)))
               (net:tcp-connect loop "127.0.0.1" port
                 :on-connect
                 (lambda (c)
                   (net:tcp-write
                    c
                    (req (crlf "GET /chat HTTP/1.1"
                               "Host: 127.0.0.1"
                               "Upgrade: websocket"
                               "Connection: Upgrade"
                               "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="
                               "Sec-WebSocket-Version: 13"))))
                 :on-data
                 (lambda (c data)
                   (loop for b across data do (vector-push-extend b got))
                   (cond
                     ((not (car handshake-done))
                      (let ((text (sb-ext:octets-to-string
                                   got :external-format :latin-1)))
                        (when (search (format nil "~c~c~c~c"
                                              #\Return #\Newline
                                              #\Return #\Newline)
                                      text)
                          (true (search "101 Switching Protocols" text))
                          (true (search
                                 "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
                                 text))
                          (setf (car handshake-done) t
                                (fill-pointer got) 0)
                          (net:tcp-write
                           c (%ws-client-frame (ws:make-text-frame "ping-echo"))))))
                     (t
                      (multiple-value-bind (frame next)
                          (ws:decode-frame got :start 0 :end (length got))
                        (declare (ignore next))
                        (when frame
                          (is = ws:+opcode-text+ (ws:ws-frame-opcode frame))
                          (is string= "ping-echo"
                              (sb-ext:octets-to-string
                               (ws:ws-frame-payload frame)
                               :external-format :utf-8))
                          (setf (car echoed) t)
                          (net:tcp-write
                           c (%ws-client-frame (ws:make-close-frame 1000 "done")))
                          (lp:set-timer loop 50
                            (lambda () (lp:loop-stop loop))))))))
                 :on-close
                 (lambda (c code)
                   (declare (ignore c code))
                   (lp:loop-stop loop)))
               (lp:set-timer loop 4000 (lambda () (lp:loop-stop loop)))
               (lp:run-loop loop)
               (true (car opened) "websocket open handler fired")
               (true (car handshake-done) "101 handshake completed")
               (true (car echoed) "echoed text frame received")))
        (eng:teardown-realm realm)))))

(define-test net/websocket-upgrade-without-option-fails
  "server.upgrade without a websocket option stays fail-closed."
  (serve-and
   (lambda (g req loop)
     (declare (ignore g req loop))
     eng:+undefined+)
   (lambda (loop port g server)
     (declare (ignore loop port g))
     (handler-case
         (progn
           (eng:js-call (eng:js-get server "upgrade") server '())
           (true nil "expected TypeError"))
       (eng:js-condition (c)
         (let* ((err (eng:js-condition-value c))
                (msg (eng:to-string (eng:js-get err "message"))))
           (true (search "Phase 51" msg))
           (true (search "server.upgrade" msg))))))))

(define-test net/websocket-client-global-present
  "WebSocket constructor is installed on the realm global."
  (let ((realm (eng:make-realm)))
    (rt:install-runtime realm :argv '(:script "[test]" :rest nil) :cwd "/tmp")
    (let ((eng:*realm* realm))
      (unwind-protect
           (let* ((g (eng:realm-global realm))
                  (ctor (eng:js-get g "WebSocket")))
             (true (eng:callable-p ctor))
             (is = 0 (truncate (eng:js-get ctor "CONNECTING")))
             (is = 1 (truncate (eng:js-get ctor "OPEN")))
             (is = 2 (truncate (eng:js-get ctor "CLOSING")))
             (is = 3 (truncate (eng:js-get ctor "CLOSED"))))
        (eng:teardown-realm realm)))))

(define-test net/websocket-client-echo-roundtrip
  "Client WebSocket global connects to Clun.serve echo and receives a reply."
  (let ((realm (eng:make-realm)))
    (rt:install-runtime realm :argv '(:script "[test]" :rest nil) :cwd "/tmp")
    (let ((eng:*realm* realm))
      (unwind-protect
           (let* ((g (eng:realm-global realm))
                  (loop (eng:current-loop))
                  (opened (list nil))
                  (got (list nil))
                  (ws-opt (eng:new-object))
                  (opts (eng:new-object))
                  (fetch
                    (eng:make-native-function "fetch" 2
                      (lambda (this args)
                        (declare (ignore this))
                        (let ((req (eng:arg args 0))
                              (server (eng:arg args 1)))
                          (if (eng:js-truthy
                               (eng:js-call (eng:js-get server "upgrade")
                                            server (list req)))
                              eng:+undefined+
                              (%resp g "fail")))))))
             (eng:data-prop ws-opt "message"
                            (eng:make-native-function "message" 2
                              (lambda (this args)
                                (declare (ignore this))
                                (let ((sock (eng:arg args 0))
                                      (msg (eng:arg args 1)))
                                  (eng:js-call (eng:js-get sock "send")
                                               sock (list msg))
                                  eng:+undefined+))))
             (eng:data-prop opts "port" 0d0)
             (eng:data-prop opts "hostname" "127.0.0.1")
             (eng:data-prop opts "fetch" fetch)
             (eng:data-prop opts "websocket" ws-opt)
             (let* ((server (clun.runtime::%clun-serve g opts))
                    (port (truncate (eng:js-get server "port")))
                    (ctor (eng:js-get g "WebSocket"))
                    (url (format nil "ws://127.0.0.1:~d/echo" port))
                    (client (eng:js-construct ctor (list url))))
               (eng:data-prop client "onopen"
                              (eng:make-native-function "onopen" 1
                                (lambda (this args)
                                  (declare (ignore this args))
                                  (setf (car opened) t)
                                  (eng:js-call (eng:js-get client "send")
                                               client (list "client-hi"))
                                  eng:+undefined+)))
               (eng:data-prop client "onmessage"
                              (eng:make-native-function "onmessage" 1
                                (lambda (this args)
                                  (declare (ignore this))
                                  (let* ((ev (eng:arg args 0))
                                         (data (eng:js-get ev "data")))
                                    (setf (car got) (eng:to-string data))
                                    (eng:js-call (eng:js-get client "close")
                                                 client (list 1000 "done"))
                                    (lp:set-timer loop 20
                                      (lambda () (lp:loop-stop loop))))
                                  eng:+undefined+)))
               (lp:set-timer loop 4000 (lambda () (lp:loop-stop loop)))
               (lp:run-loop loop)
               (true (car opened) "client open")
               (is string= "client-hi" (car got))))
        (eng:teardown-realm realm)))))
