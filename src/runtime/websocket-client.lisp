;;;; websocket-client.lisp — Phase 51: browser-shaped WebSocket global (ws:// + wss://).
;;;; Pure CL: cleartext over net:tcp-connect; wss: over pure-tls client stream on a
;;;; worker thread with loop-post event delivery. Framing via clun.websocket.
;;;; Event delivery uses onopen/onmessage/onerror/onclose slots (no full EventTarget).

(in-package :clun.runtime)

(defstruct (ws-client
            (:constructor %make-ws-client)
            (:conc-name ws-client-))
  connection
  js
  (ready-state 0)                       ; CONNECTING
  (buffer (make-array 0 :element-type '(unsigned-byte 8)
                        :adjustable t :fill-pointer 0))
  (handshake-done-p nil)
  (accept-key "")
  (close-sent-p nil)
  (close-received-p nil)
  (url "")
  (protocol ""))

(defun %ws-client-fire (client event-name &optional event-obj)
  "Invoke onEVENT and optional addEventListener-style single handler."
  (let* ((js (ws-client-js client))
         (prop (concatenate 'string "on" event-name))
         (handler (eng:js-get js prop)))
    (when (eng:callable-p handler)
      (handler-case
          (eng:js-call handler js (if event-obj (list event-obj) '()))
        (condition () nil)))))

(defun %ws-client-set-ready (client state)
  (setf (ws-client-ready-state client) state)
  (when (ws-client-js client)
    (eng:data-prop (ws-client-js client) "readyState"
                    (coerce state 'double-float))))

(defun %ws-client-message-event (data)
  (let ((ev (eng:new-object)))
    (eng:data-prop ev "data" data)
    (eng:data-prop ev "type" "message")
    ev))

(defun %ws-client-close-event (code reason was-clean)
  (let ((ev (eng:new-object)))
    (eng:data-prop ev "code" (coerce code 'double-float))
    (eng:data-prop ev "reason" (or reason ""))
    (eng:data-prop ev "wasClean" (eng:js-boolean was-clean))
    (eng:data-prop ev "type" "close")
    ev))

(defun %ws-client-write (client frame)
  (when (and client
             (ws-client-connection client)
             (not (eq (net:tcp-state (ws-client-connection client)) :closed))
             (< (ws-client-ready-state client) 3))
    (net:tcp-write (ws-client-connection client)
                   (ws:encode-frame frame :mask (ws:random-mask-key)))
    t))

(defun %ws-client-close (client code reason &key (send-close t))
  (when (>= (ws-client-ready-state client) 3)
    (return-from %ws-client-close nil))
  (when (and send-close (not (ws-client-close-sent-p client)))
    (handler-case
        (%ws-client-write client (ws:make-close-frame code reason))
      (condition () nil))
    (setf (ws-client-close-sent-p client) t)
    (%ws-client-set-ready client 2))
  (when (or (ws-client-close-received-p client) (not send-close))
    (%ws-client-set-ready client 3)
    (%ws-client-fire client "close"
                     (%ws-client-close-event code reason
                                             (ws-client-close-received-p client)))
    (ignore-errors
      (when (ws-client-connection client)
        (net:tcp-shutdown (ws-client-connection client)))))
  t)

(defun %ws-client-handle-frame (client frame)
  (let ((opcode (ws:ws-frame-opcode frame))
        (payload (ws:ws-frame-payload frame))
        (js (ws-client-js client)))
    (cond
      ((= opcode ws:+opcode-ping+)
       (%ws-client-write client (ws:make-pong-frame payload)))
      ((= opcode ws:+opcode-pong+))
      ((= opcode ws:+opcode-close+)
       (setf (ws-client-close-received-p client) t)
       (multiple-value-bind (code reason)
           (handler-case (ws:parse-close-payload payload)
             (ws:websocket-protocol-error () (values 1002 "protocol error")))
         (unless (ws-client-close-sent-p client)
           (%ws-client-write client (ws:make-close-frame code reason))
           (setf (ws-client-close-sent-p client) t))
         (%ws-client-close client code reason :send-close nil)))
      ((or (= opcode ws:+opcode-text+) (= opcode ws:+opcode-binary+))
       (unless (ws:ws-frame-fin frame)
         (%ws-client-close client 1003 "fragmented client messages unsupported")
         (return-from %ws-client-handle-frame nil))
       (let ((data
               (if (= opcode ws:+opcode-text+)
                   (handler-case
                       (sb-ext:octets-to-string payload :external-format :utf-8)
                     (error ()
                       (%ws-client-close client 1007 "invalid UTF-8")
                       (return-from %ws-client-handle-frame nil)))
                   (eng:new-array
                    (loop for b across payload
                          collect (coerce b 'double-float))))))
         (%ws-client-fire client "message" (%ws-client-message-event data))))
      (t
       (%ws-client-close client 1002 "unknown opcode")))
    js))

(defun %ws-client-on-data (client octets)
  (block client-data
    (when (>= (ws-client-ready-state client) 3)
      (return-from client-data nil))
    (let ((buf (ws-client-buffer client)))
      (loop for b across octets do (vector-push-extend b buf))
      (unless (ws-client-handshake-done-p client)
        (multiple-value-bind (status headers body-start)
            (ws:parse-http-response-head buf)
          (unless status (return-from client-data nil))
          (unless (and (= status 101)
                       (string= (ws-client-accept-key client)
                                (or (cdr (assoc "sec-websocket-accept" headers
                                                :test #'string-equal))
                                    "")))
            (%ws-client-fire client "error")
            (%ws-client-close client 1002 "bad handshake" :send-close nil)
            (return-from client-data nil))
          (let* ((remaining (- (length buf) body-start))
                 (kept (if (plusp remaining)
                           (subseq buf body-start)
                           (make-array 0 :element-type '(unsigned-byte 8)))))
            (setf (fill-pointer buf) 0)
            (loop for b across kept do (vector-push-extend b buf)))
          (setf (ws-client-handshake-done-p client) t)
          (%ws-client-set-ready client 1)
          (%ws-client-fire client "open")))
      (loop
        (multiple-value-bind (frame next)
            (handler-case
                (ws:decode-frame buf :start 0 :end (length buf))
              (ws:websocket-protocol-error ()
                (%ws-client-close client 1002 "protocol error" :send-close nil)
                (return-from client-data nil)))
          (unless frame (return))
          (let* ((remaining (- (length buf) next))
                 (kept (if (plusp remaining)
                           (subseq buf next)
                           (make-array 0 :element-type '(unsigned-byte 8)))))
            (setf (fill-pointer buf) 0)
            (loop for b across kept do (vector-push-extend b buf)))
          (%ws-client-handle-frame client frame)
          (when (>= (ws-client-ready-state client) 3)
            (return)))))))

(defun %ws-client-connect (client host port path)
  (let ((loop (eng:current-loop))
        (key (ws:make-client-key)))
    (setf (ws-client-accept-key client) (ws:handshake-accept-key key))
    (net:tcp-connect
     loop host port
     :on-connect
     (lambda (c)
       (setf (ws-client-connection client) c)
       (multiple-value-bind (req _)
           (ws:client-opening-handshake-request
            (if (and port (/= port 80))
                (format nil "~a:~d" host port)
                host)
            path
            :key key)
         (declare (ignore _))
         (net:tcp-write c req)))
     :on-data
     (lambda (c data)
       (declare (ignore c))
       (%ws-client-on-data client data))
     :on-close
     (lambda (c code)
       (declare (ignore c code))
       (when (< (ws-client-ready-state client) 3)
         (%ws-client-set-ready client 3)
         (%ws-client-fire client "close"
                          (%ws-client-close-event 1006 "" nil))))
     :on-error
     (lambda (c code)
       (declare (ignore c code))
       (%ws-client-fire client "error")
       (when (< (ws-client-ready-state client) 3)
         (%ws-client-close client 1006 "error" :send-close nil))))
    client))

(defun %ws-client-parse-url (url-string)
  "Return (values scheme host port path). Supports ws: and wss:."
  (let ((rec (handler-case (%parse-url url-string)
               (condition ()
                 (eng:throw-type-error
                  (format nil "WebSocket: invalid URL ~s" url-string))))))
    (let ((scheme (ur-scheme rec))
          (host (ur-host rec))
          (port (or (ur-port rec)
                    (if (string= (ur-scheme rec) "wss") 443 80)))
          (path (let ((p (ur-path rec))
                      (q (ur-query rec)))
                  (cond
                    ((and q (plusp (length q)))
                     (concatenate 'string
                                  (if (plusp (length p)) p "/")
                                  "?" q))
                    ((plusp (length p)) p)
                    (t "/")))))
      (unless (or (string= scheme "ws") (string= scheme "wss"))
        (eng:throw-type-error
         (format nil "WebSocket: unsupported scheme ~s" scheme)))
      (unless (and host (plusp (length host)))
        (eng:throw-type-error "WebSocket: URL host is required"))
      (values scheme host port path))))

(defun %ws-client-connect-wss (client host port path)
  "TLS WebSocket: pure-tls client stream on a worker thread; events via loop-post."
  (let ((eloop (eng:current-loop))
        (realm eng:*realm*)
        (key (ws:make-client-key)))
    (setf (ws-client-accept-key client) (ws:handshake-accept-key key))
    (lp:worker-submit
     eloop
     (lambda ()
       (let ((socket nil)
             (tls nil))
         (unwind-protect
              (handler-case
                  (progn
                    (setf socket
                          (usocket:socket-connect
                           host port :element-type '(unsigned-byte 8)))
                    (setf tls
                          (pure-tls:make-tls-client-stream
                           (usocket:socket-stream socket)
                           :hostname host
                           :verify pure-tls:+verify-required+))
                    (multiple-value-bind (req ignored)
                        (ws:client-opening-handshake-request
                         (if (and port (/= port 443))
                             (format nil "~a:~d" host port)
                             host)
                         path
                         :key key)
                      (declare (ignore ignored))
                      (write-sequence req tls)
                      (force-output tls))
                    (let ((buf (make-array 4096 :element-type '(unsigned-byte 8)))
                          (acc (make-array 0 :element-type '(unsigned-byte 8)
                                           :adjustable t :fill-pointer 0)))
                      (loop
                        (let ((got (read-sequence buf tls :end 1024)))
                          (when (zerop got) (return))
                          (let ((start (length acc)))
                            (adjust-array acc (+ start got)
                                          :fill-pointer (+ start got))
                            (replace acc buf :start1 start :end2 got))
                          (let ((txt (sb-ext:octets-to-string
                                      acc :external-format :latin-1)))
                            (when (search (format nil "~c~c~c~c"
                                                  #\Return #\Newline
                                                  #\Return #\Newline)
                                          txt)
                              (return)))))
                      (lp:loop-post
                       eloop
                       (lambda ()
                         (let ((eng:*realm* realm))
                           (%ws-client-set-ready client 1)
                           (%ws-client-fire client "open"))))
                      (loop
                        (let ((got (read-sequence buf tls :end 4096)))
                          (when (zerop got)
                            (lp:loop-post
                             eloop
                             (lambda ()
                               (let ((eng:*realm* realm))
                                 (when (< (ws-client-ready-state client) 3)
                                   (%ws-client-set-ready client 3)
                                   (%ws-client-fire
                                    client "close"
                                    (%ws-client-close-event 1006 "" nil))))))
                            (return))
                          (let ((chunk (subseq buf 0 got)))
                            (lp:loop-post
                             eloop
                             (lambda ()
                               (let ((eng:*realm* realm))
                                 (%ws-client-on-data client chunk)))))))))
                (error (e)
                  (declare (ignore e))
                  (lp:loop-post
                   eloop
                   (lambda ()
                     (let ((eng:*realm* realm))
                       (%ws-client-fire client "error")
                       (when (< (ws-client-ready-state client) 3)
                         (%ws-client-close client 1006 "wss error"
                                           :send-close nil)))))))
           (ignore-errors (when tls (close tls)))
           (ignore-errors (when socket (usocket:socket-close socket))))))
     (lambda (result)
       (declare (ignore result))
       nil))
    client))

(defun %make-js-websocket (url-string &optional protocols)
  (declare (ignore protocols))
  (multiple-value-bind (scheme host port path)
      (%ws-client-parse-url (eng:to-string url-string))
    (let* ((client (%make-ws-client :url (eng:to-string url-string)))
           (js (eng:new-object)))
      (setf (ws-client-js client) js)
      (eng:data-prop js "url" (ws-client-url client))
      (eng:data-prop js "readyState" 0d0)
      (eng:data-prop js "bufferedAmount" 0d0)
      (eng:data-prop js "extensions" "")
      (eng:data-prop js "protocol" "")
      (eng:data-prop js "binaryType" "nodebuffer")
      (eng:data-prop js "onopen" eng:+null+)
      (eng:data-prop js "onmessage" eng:+null+)
      (eng:data-prop js "onerror" eng:+null+)
      (eng:data-prop js "onclose" eng:+null+)
      (eng:install-method js "send" 1
        (lambda (this args)
          (declare (ignore this))
          (when (/= (ws-client-ready-state client) 1)
            (eng:throw-type-error "WebSocket is not open"))
          (multiple-value-bind (opcode payload)
              (cond
                ((eng:js-string-p (eng:arg args 0))
                 (values ws:+opcode-text+
                         (sb-ext:string-to-octets
                          (eng:to-string (eng:arg args 0))
                          :external-format :utf-8)))
                (t
                 (let ((v (eng:arg args 0)))
                   (if (typep v '(vector (unsigned-byte 8)))
                       (values ws:+opcode-binary+
                               (coerce v '(simple-array (unsigned-byte 8) (*))))
                       (values ws:+opcode-text+
                               (sb-ext:string-to-octets
                                (eng:to-string v) :external-format :utf-8))))))
            (%ws-client-write client
                              (ws:make-ws-frame :fin t :opcode opcode
                                                :payload payload))
            eng:+undefined+)))
      (eng:install-method js "close" 2
        (lambda (this args)
          (declare (ignore this))
          (let* ((code-v (eng:arg args 0))
                 (reason-v (eng:arg args 1))
                 (code (if (eng:js-number-p code-v)
                           (truncate (eng:to-number code-v))
                           1000))
                 (reason (if (eng:js-undefined-p reason-v)
                             ""
                             (eng:to-string reason-v))))
            (%ws-client-close client code reason)
            eng:+undefined+)))
      (if (string= scheme "wss")
          (%ws-client-connect-wss client host port path)
          (%ws-client-connect client host port path))
      js)))

(defun install-websocket-global (g)
  "Install the browser-shaped WebSocket constructor on the realm global."
  (let ((ctor
          (eng:make-native-function
           "WebSocket" 1
           (lambda (this args)
             (declare (ignore this))
             (%make-js-websocket (eng:arg args 0) (eng:arg args 1)))
           :construct
           (lambda (args _new-target)
             (declare (ignore _new-target))
             (%make-js-websocket (eng:arg args 0) (eng:arg args 1))))))
    (eng:data-prop ctor "CONNECTING" 0d0)
    (eng:data-prop ctor "OPEN" 1d0)
    (eng:data-prop ctor "CLOSING" 2d0)
    (eng:data-prop ctor "CLOSED" 3d0)
    (eng:data-prop g "WebSocket" ctor)
    ctor))
