;;;; websocket-tests.lisp — Phase 51: handshake, framing, echo, Pub/Sub hub.

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

(define-test net/websocket-topic-hub-pure
  "Pure-CL topic hub: subscribe, count, unsubscribe, close cleanup."
  (let ((hub (ws:make-ws-topic-hub))
        (a (list :a))
        (b (list :b)))
    (is = 0 (ws:topic-hub-subscriber-count hub "chat"))
    (true (ws:topic-hub-subscribe hub a "chat"))
    (false (ws:topic-hub-subscribe hub a "chat")) ; idempotent
    (true (ws:topic-hub-subscribe hub b "chat"))
    (true (ws:topic-hub-subscribe hub a "alerts"))
    (is = 2 (ws:topic-hub-subscriber-count hub "chat"))
    (is = 1 (ws:topic-hub-subscriber-count hub "alerts"))
    (true (ws:topic-hub-subscribed-p hub a "chat"))
    (false (ws:topic-hub-subscribed-p hub b "alerts"))
    (true (member "chat" (ws:topic-hub-subscriptions hub a) :test #'string=))
    (true (member "alerts" (ws:topic-hub-subscriptions hub a) :test #'string=))
    (true (ws:topic-hub-unsubscribe hub a "chat"))
    (is = 1 (ws:topic-hub-subscriber-count hub "chat"))
    ;; b still on chat only → unsubscribe-all clears 1 topic
    (is = 1 (ws:topic-hub-unsubscribe-all hub b))
    (is = 0 (ws:topic-hub-subscriber-count hub "chat"))
    (ws:topic-hub-subscribe hub b "chat")
    (ws:topic-hub-subscribe hub b "room")
    (is = 2 (ws:topic-hub-unsubscribe-all hub b))
    (is = 0 (ws:topic-hub-subscriber-count hub "chat"))
    (is = 0 (ws:topic-hub-subscriber-count hub "room"))
    (is = 1 (ws:topic-hub-subscriber-count hub "alerts"))))

(define-test net/websocket-publish-empty-ok
  "server.publish / subscriberCount work without subscribers (Bun-shaped zeros)."
  (let ((realm (eng:make-realm)))
    (rt:install-runtime realm :argv '(:script "[test]" :rest nil) :cwd "/tmp")
    (let ((eng:*realm* realm))
      (unwind-protect
           (let* ((g (eng:realm-global realm))
                  (fetch (eng:make-native-function "fetch" 2
                           (lambda (this args)
                             (declare (ignore this args))
                             eng:+undefined+)))
                  (ws-opt (eng:new-object))
                  (opts (eng:new-object)))
             (eng:data-prop ws-opt "message"
                            (eng:make-native-function "message" 2
                              (lambda (this args)
                                (declare (ignore this args))
                                eng:+undefined+)))
             (eng:data-prop opts "port" 0d0)
             (eng:data-prop opts "hostname" "127.0.0.1")
             (eng:data-prop opts "fetch" fetch)
             (eng:data-prop opts "websocket" ws-opt)
             (let ((server (clun.runtime::%clun-serve g opts)))
               (is = 0d0
                   (eng:js-call (eng:js-get server "subscriberCount")
                                server (list "chat")))
               (is = 0d0
                   (eng:js-call (eng:js-get server "publish")
                                server (list "chat" "hello")))))
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

(define-test net/websocket-pubsub-server-publish
  "Two clients subscribe; server.publish fans out text; subscriberCount tracks membership."
  (let ((realm (eng:make-realm)))
    (rt:install-runtime realm :argv '(:script "[test]" :rest nil) :cwd "/tmp")
    (let ((eng:*realm* realm))
      (unwind-protect
           (let* ((g (eng:realm-global realm))
                  (loop (eng:current-loop))
                  (opened (list 0))
                  (ws-opt (eng:new-object))
                  (opts (eng:new-object))
                  (server-box (list nil))
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
                                  (incf (car opened))
                                  eng:+undefined+))))
             (eng:data-prop ws-opt "message"
                            (eng:make-native-function "message" 2
                              (lambda (this args)
                                (declare (ignore this args))
                                eng:+undefined+)))
             (eng:data-prop opts "port" 0d0)
             (eng:data-prop opts "hostname" "127.0.0.1")
             (eng:data-prop opts "fetch" fetch)
             (eng:data-prop opts "websocket" ws-opt)
             (let* ((server (clun.runtime::%clun-serve g opts))
                    (port (truncate (eng:js-get server "port")))
                    (got-a (make-array 0 :element-type '(unsigned-byte 8)
                                         :adjustable t :fill-pointer 0))
                    (got-b (make-array 0 :element-type '(unsigned-byte 8)
                                         :adjustable t :fill-pointer 0))
                    (hs-a (list nil))
                    (hs-b (list nil))
                    (msg-a (list nil))
                    (msg-b (list nil)))
               (setf (car server-box) server)
               (labels ((drain-frames (got msg)
                          (loop
                            (multiple-value-bind (frame next)
                                (ws:decode-frame got :start 0 :end (length got))
                              (unless frame (return))
                              (let* ((remaining (- (length got) next))
                                     (kept (if (plusp remaining)
                                               (subseq got next)
                                               (make-array 0 :element-type '(unsigned-byte 8)))))
                                (setf (fill-pointer got) 0)
                                (loop for b across kept do (vector-push-extend b got)))
                              (when (and frame
                                         (= (ws:ws-frame-opcode frame)
                                            ws:+opcode-text+))
                                (is string= "broadcast"
                                    (sb-ext:octets-to-string
                                     (ws:ws-frame-payload frame)
                                     :external-format :utf-8))
                                (setf (car msg) t)))))
                        (client (got hs msg)
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
                              (loop for b across data do (vector-push-extend b got))
                              (unless (car hs)
                                (let* ((text (sb-ext:octets-to-string
                                              got :external-format :latin-1))
                                       (sep (search (format nil "~c~c~c~c"
                                                            #\Return #\Newline
                                                            #\Return #\Newline)
                                                    text)))
                                  (when sep
                                    (let* ((body-start (+ sep 4))
                                           (body (subseq got body-start)))
                                      (setf (car hs) t
                                            (fill-pointer got) 0)
                                      (loop for b across body
                                            do (vector-push-extend b got))))))
                              (when (car hs)
                                (drain-frames got msg)))
                            :on-close
                            (lambda (c code)
                              (declare (ignore c code))))))
                 (client got-a hs-a msg-a)
                 (client got-b hs-b msg-b)
                 (lp:set-timer loop 4000 (lambda () (lp:loop-stop loop)))
                 ;; Wait for both sockets to subscribe, then server.publish.
                 (let ((published (list nil)))
                   (labels ((tick ()
                              (cond
                                ((and (not (car published))
                                      (>= (car opened) 2))
                                 (is = 2d0
                                     (eng:js-call (eng:js-get server "subscriberCount")
                                                  server (list "room")))
                                 (let ((n (eng:js-call
                                           (eng:js-get server "publish")
                                           server
                                           (list "room" "broadcast"))))
                                   (true (plusp n) "publish delivered bytes")
                                   (setf (car published) t))
                                 (lp:set-timer loop 200 #'tick))
                                ((and (car published) (car msg-a) (car msg-b))
                                 (lp:loop-stop loop))
                                (t
                                 (lp:set-timer loop 50 #'tick)))))
                     (lp:set-timer loop 50 #'tick)))
                 (lp:run-loop loop)
                 (true (car hs-a))
                 (true (car hs-b))
                 (true (car msg-a))
                 (true (car msg-b))
                 (is = 2 (car opened)))))
        (eng:teardown-realm realm)))))
