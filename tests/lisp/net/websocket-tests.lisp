;;;; websocket-tests.lisp — Phase 51 M0: pure-CL scaffold + Clun.serve fail-closed.

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

(define-test net/websocket-protocol-stubs-fail-closed
  (handler-case
      (progn (ws:handshake-accept-key "dGhlIHNhbXBsZSBub25jZQ==")
             (true nil))
    (ws:websocket-unsupported (c)
      (true (search "Phase 51" (ws:websocket-error-message c)))
      (true (search "docs/design/phase-51.md" (ws:websocket-error-message c)))))
  (handler-case
      (progn (ws:encode-frame (ws:make-ws-frame))
             (true nil))
    (ws:websocket-unsupported (c)
      (true (search "framing" (ws:websocket-error-message c)))))
  (handler-case
      (progn (ws:decode-frame (make-array 0 :element-type '(unsigned-byte 8)))
             (true nil))
    (ws:websocket-unsupported (c)
      (true (search "not implemented" (ws:websocket-error-message c))))))

(define-test net/websocket-serve-option-rejected
  (let ((realm (eng:make-realm)))
    (rt:install-runtime realm :argv '(:script "[test]" :rest nil) :cwd "/tmp")
    (let ((eng:*realm* realm))
      (unwind-protect
           (let* ((g (eng:realm-global realm))
                  (fetch (eng:make-native-function "fetch" 1
                           (lambda (this args)
                             (declare (ignore this args))
                             (eng:js-construct (eng:js-get g "Response")
                                               (list "ok" eng:+undefined+)))))
                  (opts (eng:new-object))
                  (ws-opt (eng:new-object)))
             (eng:data-prop opts "port" 0d0)
             (eng:data-prop opts "hostname" "127.0.0.1")
             (eng:data-prop opts "fetch" fetch)
             (eng:data-prop opts "websocket" ws-opt)
             (handler-case
                 (progn
                   (clun.runtime::%clun-serve g opts)
                   (true nil "expected TypeError for websocket option"))
               (eng:js-condition (c)
                 (let* ((err (eng:js-condition-value c))
                        (name (eng:to-string (eng:js-get err "name")))
                        (msg (eng:to-string (eng:js-get err "message"))))
                   (is string= "TypeError" name)
                   (true (search "Phase 51" msg))
                   (true (search "websocket" msg :test #'char-equal))
                   (true (search "docs/design/phase-51.md" msg))))))
        (eng:teardown-realm realm)))))

(define-test net/websocket-server-methods-fail-closed
  (serve-and
   (lambda (g req loop)
     (declare (ignore g req loop))
     (%resp g "ok"))
   (lambda (loop port g server)
     (declare (ignore loop port g))
     (flet ((invoke-server-method (method-name)
              (handler-case
                  (progn
                    (eng:js-call (eng:js-get server method-name) server '())
                    :ok)
                (eng:js-condition (c)
                  (let* ((err (eng:js-condition-value c))
                         (name* (eng:to-string (eng:js-get err "name")))
                         (msg (eng:to-string (eng:js-get err "message"))))
                    (list name* msg))))))
       (let ((upgrade (invoke-server-method "upgrade"))
             (publish (invoke-server-method "publish"))
             (count (invoke-server-method "subscriberCount")))
         (true (consp upgrade))
         (is string= "TypeError" (first upgrade))
         (true (search "server.upgrade" (second upgrade)))
         (true (search "Phase 51" (second upgrade)))
         (true (consp publish))
         (is string= "TypeError" (first publish))
         (true (search "server.publish" (second publish)))
         (true (consp count))
         (is string= "TypeError" (first count))
         (true (search "server.subscriberCount" (second count))))))))
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
