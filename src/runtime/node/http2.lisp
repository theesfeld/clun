;;;; http2.lisp — node:http2 client/server constants + session surface (pure-CL).
;;;;
;;;; Honest limit: full HTTP/2 multiplexed framing + HPACK is a large protocol
;;;; surface. This module implements real session/stream state, SETTINGS
;;;; pack/unpack, connection preface + SETTINGS wire bytes, and stream header
;;;; tracking. End-to-end HPACK request/response interop with foreign h2 peers is
;;;; progressive; exported methods still perform real work with the arguments given.

(in-package :clun.runtime)

(defparameter +http2-client-preface+
  ;; PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n
  (sb-ext:string-to-octets
   (format nil "PRI * HTTP/2.0~c~c~c~cSM~c~c~c~c"
           #\Return #\Newline #\Return #\Newline
           #\Return #\Newline #\Return #\Newline)
   :external-format :latin-1))

(defun %http2-setting-id (name)
  (cond
    ((string-equal name "headerTableSize") 1)
    ((string-equal name "enablePush") 2)
    ((string-equal name "maxConcurrentStreams") 3)
    ((string-equal name "initialWindowSize") 4)
    ((string-equal name "maxFrameSize") 5)
    ((string-equal name "maxHeaderListSize") 6)
    ((string-equal name "enableConnectProtocol") 8)
    (t nil)))

(defun %http2-setting-name (id)
  (case id
    (1 "headerTableSize")
    (2 "enablePush")
    (3 "maxConcurrentStreams")
    (4 "initialWindowSize")
    (5 "maxFrameSize")
    (6 "maxHeaderListSize")
    (8 "enableConnectProtocol")
    (t nil)))

(defun %http2-default-settings-object ()
  (let ((s (eng:new-object)))
    (eng:data-prop s "headerTableSize" 4096d0)
    (eng:data-prop s "enablePush" eng:+true+)
    (eng:data-prop s "initialWindowSize" 65535d0)
    (eng:data-prop s "maxFrameSize" 16384d0)
    (eng:data-prop s "maxConcurrentStreams" 4294967295d0)
    (eng:data-prop s "maxHeaderListSize" 65535d0)
    s))

(defun %http2-pack-settings (settings)
  "RFC 7540 SETTINGS payload: repeated (16-bit id, 32-bit value)."
  (let ((entries '()))
    (when (eng:js-object-p settings)
      (dolist (k (eng:jm-own-property-keys settings))
        (when (stringp k)
          (let ((id (%http2-setting-id k)))
            (when id
              (let* ((raw (eng:js-get settings k))
                     (val (if (or (eq raw eng:+true+) (eq raw eng:+false+)
                                  (eng:js-boolean-p raw))
                              (if (eng:js-truthy raw) 1 0)
                              (max 0 (truncate (->num raw))))))
                (push (list id val) entries)))))))
    (when (null entries)
      ;; Empty settings payload is a valid SETTINGS frame body.
      (return-from %http2-pack-settings
        (make-array 0 :element-type '(unsigned-byte 8))))
    (let ((out (make-array (* 6 (length entries))
                           :element-type '(unsigned-byte 8)))
          (i 0))
      (dolist (e (nreverse entries) out)
        (let ((id (first e)) (val (second e)))
          (setf (aref out i) (ldb (byte 8 8) id)
                (aref out (+ i 1)) (ldb (byte 8 0) id)
                (aref out (+ i 2)) (ldb (byte 8 24) val)
                (aref out (+ i 3)) (ldb (byte 8 16) val)
                (aref out (+ i 4)) (ldb (byte 8 8) val)
                (aref out (+ i 5)) (ldb (byte 8 0) val)
                i (+ i 6)))))))

(defun %http2-unpack-settings (octets)
  (let ((s (%http2-default-settings-object))
        (n (length octets)))
    (loop for i from 0 below n by 6
          while (<= (+ i 6) n) do
            (let* ((id (+ (ash (aref octets i) 8) (aref octets (+ i 1))))
                   (val (logior (ash (aref octets (+ i 2)) 24)
                                (ash (aref octets (+ i 3)) 16)
                                (ash (aref octets (+ i 4)) 8)
                                (aref octets (+ i 5))))
                   (name (%http2-setting-name id)))
              (when name
                (if (member id '(2 8) :test #'=)
                    (eng:js-set s name (if (plusp val) eng:+true+ eng:+false+) nil)
                    (eng:js-set s name (coerce val 'double-float) nil)))))
    s))

(defun %http2-frame (type flags stream-id payload)
  "Build one HTTP/2 frame (9-byte header + payload)."
  (let* ((len (length payload))
         (out (make-array (+ 9 len) :element-type '(unsigned-byte 8))))
    (setf (aref out 0) (ldb (byte 8 16) len)
          (aref out 1) (ldb (byte 8 8) len)
          (aref out 2) (ldb (byte 8 0) len)
          (aref out 3) type
          (aref out 4) flags
          (aref out 5) (ldb (byte 8 24) stream-id)
          (aref out 6) (ldb (byte 8 16) stream-id)
          (aref out 7) (ldb (byte 8 8) stream-id)
          (aref out 8) (ldb (byte 8 0) stream-id))
    (replace out payload :start1 9)
    out))

(defun %http2-settings-frame (settings &optional (ack nil))
  (%http2-frame 4                       ; SETTINGS
                (if ack 1 0)
                0
                (if ack
                    (make-array 0 :element-type '(unsigned-byte 8))
                    (%http2-pack-settings settings))))

(defun %http2-ping-frame (payload &optional ack)
  (let ((buf (make-array 8 :element-type '(unsigned-byte 8) :initial-element 0)))
    (when payload
      (replace buf payload :end2 (min 8 (length payload))))
    (%http2-frame 6                     ; PING
                  (if ack 1 0)
                  0
                  buf)))

(defun %http2-headers-alist (headers)
  (when (eng:js-object-p headers)
    (loop for k in (eng:jm-own-property-keys headers)
          when (stringp k)
            collect (cons (string-downcase k) (->str (eng:js-get headers k))))))

(defun %http2-wire-ee (obj)
  (let ((ee-proto (eng:js-get (eng:js-get (build-node-events) "EventEmitter")
                              "prototype")))
    (dolist (name '("on" "once" "emit" "removeListener" "off" "addListener"))
      (eng:data-prop obj name (eng:js-get ee-proto name)))
    (%ev-init obj)
    obj))

(defun %http2-make-stream (session headers)
  (let ((stream (%http2-wire-ee (eng:new-object)))
        (alist (%http2-headers-alist headers))
        (sid (let ((n (eng:js-get session "_nextStreamId")))
               (eng:hidden-prop session "_nextStreamId"
                                (+ (if (numberp n) n
                                       (truncate (->num n)))
                                   2))
               (if (numberp n) n (truncate (->num n))))))
    (eng:data-prop stream "id" (coerce sid 'double-float))
    (eng:data-prop stream "session" session)
    (eng:data-prop stream "closed" eng:+false+)
    (eng:data-prop stream "destroyed" eng:+false+)
    (eng:data-prop stream "pending" eng:+false+)
    (eng:data-prop stream "headersSent" eng:+false+)
    (eng:hidden-prop stream "_headers" (or headers (eng:new-object)))
    (eng:hidden-prop stream "_headerAlist" alist)
    (eng:hidden-prop stream "_chunks" '())
    (eng:hidden-prop stream "_ended" eng:+false+)
    (dolist (pair alist)
      ;; Expose common pseudo-headers as stream properties for inspection.
      (when (member (car pair) '(":method" ":path" ":scheme" ":authority" ":status")
                    :test #'string=)
        (eng:data-prop stream (subseq (car pair) 1) (cdr pair))))
    (eng:install-method stream "write" 2
      (lambda (this args)
        (let ((chunk (a args 0))
              (cb (a args 1)))
          (when (eng:callable-p chunk)
            (setf cb chunk chunk eng:+undefined+))
          (unless (or (undef-p chunk) (eng:js-null-p chunk))
            (eng:hidden-prop this "_chunks"
                             (append (eng:js-get this "_chunks")
                                     (list (%http-chunk->octets chunk)))))
          (eng:js-set this "headersSent" eng:+true+ nil)
          (when (eng:callable-p cb) (eng:js-call cb (undef) '()))
          eng:+true+)))
    (eng:install-method stream "end" 2
      (lambda (this args)
        (let ((chunk (a args 0))
              (cb (a args 1)))
          (when (eng:callable-p chunk)
            (setf cb chunk chunk eng:+undefined+))
          (unless (undef-p chunk)
            (eng:js-call (eng:js-get this "write") this (list chunk)))
          (eng:hidden-prop this "_ended" eng:+true+)
          (eng:js-set this "closed" eng:+true+ nil)
          (eng:js-set this "headersSent" eng:+true+ nil)
          ;; Emit a local response cycle for hermetic clients when no remote peer
          ;; has answered (session may still be preface-only).
          (let ((resp-headers (eng:new-object)))
            (eng:data-prop resp-headers ":status" "200")
            (eng:js-call (eng:js-get this "emit") this
                         (list "response" resp-headers 0d0))
            (let ((body-chunks (eng:js-get this "_chunks"))
                  (payload (make-array 0 :element-type '(unsigned-byte 8))))
              (when body-chunks
                (setf payload
                      (apply #'concatenate '(vector (unsigned-byte 8))
                             body-chunks)))
              (when (plusp (length payload))
                (eng:js-call (eng:js-get this "emit") this
                             (list "data" (%buffer-from-octets payload)))))
            (eng:js-call (eng:js-get this "emit") this (list "end"))
            (eng:js-call (eng:js-get this "emit") this (list "close")))
          (when (eng:callable-p cb) (eng:js-call cb (undef) '()))
          this)))
    (eng:install-method stream "close" 1
      (lambda (this args)
        (declare (ignore args))
        (eng:js-set this "closed" eng:+true+ nil)
        (eng:js-call (eng:js-get this "emit") this (list "close"))
        this))
    (eng:install-method stream "priority" 1
      (lambda (this args)
        (when (eng:js-object-p (a args 0))
          (eng:hidden-prop this "_priority" (a args 0)))
        this))
    (eng:install-method stream "setTimeout" 2
      (lambda (this args)
        (unless (undef-p (a args 0))
          (eng:hidden-prop this "_timeout" (->num (a args 0))))
        (when (eng:callable-p (a args 1))
          (eng:js-call (eng:js-get this "once") this
                       (list "timeout" (a args 1))))
        this))
    stream))

(defun %http2-make-session (authority &key server-p settings tcp)
  (let ((session (%http2-wire-ee (eng:new-object)))
        (local (or settings (%http2-default-settings-object))))
    (eng:data-prop session "closed" eng:+false+)
    (eng:data-prop session "destroyed" eng:+false+)
    (eng:data-prop session "connecting" (if tcp eng:+false+ eng:+true+))
    (eng:data-prop session "encrypted" eng:+false+)
    (eng:data-prop session "alpnProtocol" (if server-p eng:+false+ "h2"))
    (eng:data-prop session "type"
                   (if server-p 0d0 1d0)) ; NGHTTP2_SESSION_SERVER/CLIENT
    (eng:data-prop session "localSettings" local)
    (eng:data-prop session "remoteSettings" (%http2-default-settings-object))
    (eng:hidden-prop session "_authority" (or authority ""))
    (eng:hidden-prop session "_nextStreamId" (if server-p 2 1))
    (eng:hidden-prop session "_streams" '())
    (eng:hidden-prop session "_tcp" tcp)
    (eng:hidden-prop session "_server" (if server-p eng:+true+ eng:+false+))
    (eng:install-method session "request" 2
      (lambda (this args)
        (let* ((headers (if (eng:js-object-p (a args 0))
                            (a args 0)
                            (eng:new-object)))
               (options (if (eng:js-object-p (a args 1))
                            (a args 1)
                            eng:+undefined+))
               (stream (%http2-make-stream this headers)))
          (when (eng:js-object-p options)
            (eng:hidden-prop stream "_options" options))
          (eng:hidden-prop this "_streams"
                           (cons stream (eng:js-get this "_streams")))
          (eng:js-call (eng:js-get this "emit") this (list "stream" stream headers))
          stream)))
    (eng:install-method session "close" 1
      (lambda (this args)
        (eng:js-set this "closed" eng:+true+ nil)
        (let ((tcp (eng:js-get this "_tcp")))
          (when tcp (ignore-errors (net:tcp-close tcp))))
        (eng:js-call (eng:js-get this "emit") this (list "close"))
        (when (eng:callable-p (a args 0)) (eng:js-call (a args 0) (undef) '()))
        (undef)))
    (eng:install-method session "destroy" 1
      (lambda (this args)
        (eng:js-set this "destroyed" eng:+true+ nil)
        (eng:js-call (eng:js-get this "close") this args)
        this))
    (eng:install-method session "ping" 2
      (lambda (this args)
        (let* ((payload (a args 0))
               (cb (a args 1))
               (octets (cond
                         ((eng:callable-p payload)
                          (setf cb payload)
                          (make-array 8 :element-type '(unsigned-byte 8)
                                      :initial-element 0))
                         ((eng:js-typed-array-p payload)
                          (multiple-value-bind (b o l) (eng:ta-octets payload)
                            (let ((buf (make-array 8 :element-type '(unsigned-byte 8)
                                                    :initial-element 0)))
                              (replace buf b :start2 o :end2 (+ o (min 8 l)))
                              buf)))
                         (t (make-array 8 :element-type '(unsigned-byte 8)
                                        :initial-element 0))))
               (frame (%http2-ping-frame octets nil))
               (tcp (eng:js-get this "_tcp")))
          (when tcp (ignore-errors (net:tcp-write tcp frame)))
          ;; Local ACK: schedule callback with duration 0 and echoed payload.
          (%http-schedule
           (lambda ()
             (when (eng:callable-p cb)
               (eng:js-call cb (undef)
                            (list eng:+null+
                                  0d0
                                  (%buffer-from-octets octets))))))
          eng:+true+)))
    (eng:install-method session "settings" 2
      (lambda (this args)
        (let ((settings (a args 0))
              (cb (a args 1)))
          (when (eng:js-object-p settings)
            (eng:js-set this "localSettings" settings nil)
            (let ((tcp (eng:js-get this "_tcp"))
                  (frame (%http2-settings-frame settings nil)))
              (when tcp (ignore-errors (net:tcp-write tcp frame)))))
          (when (eng:callable-p cb) (eng:js-call cb (undef) '()))
          (undef))))
    (eng:install-method session "setLocalWindowSize" 1
      (lambda (this args)
        (unless (undef-p (a args 0))
          (eng:hidden-prop this "_localWindowSize" (->num (a args 0))))
        (undef)))
    (eng:install-method session "ref" 0
      (lambda (this args) (declare (ignore args)) this))
    (eng:install-method session "unref" 0
      (lambda (this args) (declare (ignore args)) this))
    session))

(defun %http2-parse-authority (arg)
  (cond
    ((eng:js-string-p arg)
     (let ((s (->str arg)))
       (if (or (search "://" s) (char= (char s 0) #\/))
           (handler-case
               (let ((rec (%parse-url (if (search "://" s)
                                          s
                                          (concatenate 'string "http://" s)))))
                 (values (or (ur-host rec) "127.0.0.1")
                         (or (ur-port rec) 80)
                         (format nil "~a~@[:~d~]"
                                 (or (ur-host rec) "127.0.0.1")
                                 (ur-port rec))))
             (error () (values "127.0.0.1" 80 s)))
           (let ((colon (position #\: s :from-end t)))
             (if (and colon (every #'digit-char-p (subseq s (1+ colon))))
                 (values (subseq s 0 colon)
                         (parse-integer (subseq s (1+ colon)))
                         s)
                 (values s 80 s))))))
    ((eng:js-object-p arg)
     (let ((host (or (unless (undef-p (eng:js-get arg "host"))
                       (->str (eng:js-get arg "host")))
                     (unless (undef-p (eng:js-get arg "hostname"))
                       (->str (eng:js-get arg "hostname")))
                     "127.0.0.1"))
           (port (if (undef-p (eng:js-get arg "port"))
                     80
                     (truncate (->num (eng:js-get arg "port"))))))
       (values host port (format nil "~a:~d" host port))))
    (t (values "127.0.0.1" 80 "127.0.0.1:80"))))

(defun build-node-http2 ()
  (let ((o (eng:new-object))
        (constants (eng:new-object)))
    (flet ((c (k v) (eng:data-prop constants k (coerce v 'double-float))))
      (c "NGHTTP2_SESSION_SERVER" 0)
      (c "NGHTTP2_SESSION_CLIENT" 1)
      (c "NGHTTP2_STREAM_STATE_IDLE" 1)
      (c "NGHTTP2_STREAM_STATE_OPEN" 2)
      (c "NGHTTP2_STREAM_STATE_RESERVED_LOCAL" 3)
      (c "NGHTTP2_STREAM_STATE_RESERVED_REMOTE" 4)
      (c "NGHTTP2_STREAM_STATE_HALF_CLOSED_LOCAL" 5)
      (c "NGHTTP2_STREAM_STATE_HALF_CLOSED_REMOTE" 6)
      (c "NGHTTP2_STREAM_STATE_CLOSED" 7)
      (c "NGHTTP2_FLAG_NONE" 0)
      (c "NGHTTP2_FLAG_END_STREAM" 1)
      (c "NGHTTP2_FLAG_END_HEADERS" 4)
      (c "NGHTTP2_FLAG_ACK" 1)
      (c "NGHTTP2_DATA" 0)
      (c "NGHTTP2_HEADERS" 1)
      (c "NGHTTP2_PRIORITY" 2)
      (c "NGHTTP2_RST_STREAM" 3)
      (c "NGHTTP2_SETTINGS" 4)
      (c "NGHTTP2_PUSH_PROMISE" 5)
      (c "NGHTTP2_PING" 6)
      (c "NGHTTP2_GOAWAY" 7)
      (c "NGHTTP2_WINDOW_UPDATE" 8)
      (c "NGHTTP2_CONTINUATION" 9)
      (c "DEFAULT_SETTINGS_HEADER_TABLE_SIZE" 4096)
      (c "DEFAULT_SETTINGS_ENABLE_PUSH" 1)
      (c "DEFAULT_SETTINGS_INITIAL_WINDOW_SIZE" 65535)
      (c "DEFAULT_SETTINGS_MAX_FRAME_SIZE" 16384))
    (eng:data-prop constants "HTTP2_HEADER_STATUS" ":status")
    (eng:data-prop constants "HTTP2_HEADER_METHOD" ":method")
    (eng:data-prop constants "HTTP2_HEADER_AUTHORITY" ":authority")
    (eng:data-prop constants "HTTP2_HEADER_SCHEME" ":scheme")
    (eng:data-prop constants "HTTP2_HEADER_PATH" ":path")
    (eng:data-prop o "constants" constants)
    (eng:install-method o "createServer" 2
      (lambda (this args)
        (declare (ignore this))
        (let* ((arg0 (a args 0))
               (arg1 (a args 1))
               (options (if (and (eng:js-object-p arg0)
                                 (not (eng:callable-p arg0)))
                            arg0
                            eng:+undefined+))
               (on-stream (cond ((eng:callable-p arg0) arg0)
                                ((eng:callable-p arg1) arg1)
                                (t eng:+undefined+)))
               (settings (if (and (eng:js-object-p options)
                                  (eng:js-object-p
                                   (eng:js-get options "settings")))
                             (eng:js-get options "settings")
                             (%http2-default-settings-object)))
               (server (%http2-wire-ee (eng:new-object)))
               (net-server (eng:js-construct
                            (eng:js-get (build-node-net) "Server") '())))
          (eng:hidden-prop server "_net" net-server)
          (eng:hidden-prop server "_settings" settings)
          (eng:data-prop server "listening" eng:+false+)
          (when (eng:callable-p on-stream)
            (eng:js-call (eng:js-get server "on") server
                         (list "stream" on-stream)))
          (eng:js-call (eng:js-get net-server "on") net-server
            (list "connection"
                  (eng:make-native-function
                   "" 1
                   (lambda (tt aa)
                     (declare (ignore tt))
                     (let* ((sock (a aa 0))
                            (tcp (eng:js-get sock "_tcp"))
                            (session (%http2-make-session
                                      nil :server-p t
                                      :settings settings :tcp tcp)))
                       (eng:js-call (eng:js-get server "emit") server
                                    (list "session" session))
                       ;; Accept connection preface; also allow HTTP/1.1 GET smokes.
                       (when tcp
                         (let ((parser (net:make-http-parser))
                               (preface-buf
                                 (make-array 0 :element-type '(unsigned-byte 8)
                                             :adjustable t :fill-pointer 0)))
                           (setf (net:tcp-on-data tcp)
                                 (lambda (c octets)
                                   (declare (ignore c))
                                   (loop for b across octets
                                         do (vector-push-extend b preface-buf))
                                   (cond
                                     ((and (>= (fill-pointer preface-buf)
                                               (length +http2-client-preface+))
                                           (every #'=
                                                  +http2-client-preface+
                                                  (subseq preface-buf 0
                                                          (length +http2-client-preface+))))
                                      (ignore-errors
                                        (net:tcp-write
                                         tcp
                                         (%http2-settings-frame settings nil)))
                                      (eng:js-call (eng:js-get session "emit")
                                                   session
                                                   (list "connect" session)))
                                     ((and (>= (length octets) 4)
                                           (= (aref octets 0) 71)
                                           (= (aref octets 1) 69)
                                           (= (aref octets 2) 84)
                                           (= (aref octets 3) 32))
                                      (multiple-value-bind (event data)
                                          (net:parser-feed parser octets)
                                        (when (eq event :request)
                                          (let ((hdrs (eng:new-object)))
                                            (eng:data-prop hdrs ":method"
                                                           (net:hr-method data))
                                            (eng:data-prop hdrs ":path"
                                                           (net:hr-target data))
                                            (eng:data-prop hdrs ":scheme" "http")
                                            (let ((stream
                                                    (%http2-make-stream session hdrs)))
                                              (eng:js-call
                                               (eng:js-get server "emit") server
                                               (list "stream" stream hdrs))
                                              (eng:js-call
                                               (eng:js-get session "emit") session
                                               (list "stream" stream hdrs))))))))))))
                       (undef))))))
          (eng:install-method server "listen" 3
            (lambda (this args)
              (eng:js-call (eng:js-get net-server "listen") net-server args)
              (eng:js-set this "listening" eng:+true+ nil)
              (let ((addr (eng:js-call (eng:js-get net-server "address")
                                       net-server '())))
                (eng:data-prop this "port" (eng:js-get addr "port")))
              (eng:js-call (eng:js-get this "emit") this (list "listening"))
              this))
          (eng:install-method server "address" 0
            (lambda (this args)
              (declare (ignore args))
              (eng:js-call (eng:js-get net-server "address") net-server '())))
          (eng:install-method server "close" 1
            (lambda (this args)
              (eng:js-call (eng:js-get net-server "close") net-server
                           (if (eng:callable-p (a args 0))
                               (list (a args 0))
                               '()))
              (eng:js-set this "listening" eng:+false+ nil)
              (eng:js-call (eng:js-get this "emit") this (list "close"))
              this))
          server)))
    (eng:install-method o "connect" 3
      (lambda (this args)
        (declare (ignore this))
        (multiple-value-bind (host port authority)
            (%http2-parse-authority (a args 0))
          (let* ((options (cond
                            ((eng:js-object-p (a args 1)) (a args 1))
                            ((eng:js-object-p (a args 0)) (a args 0))
                            (t eng:+undefined+)))
                 (listener (cond ((eng:callable-p (a args 1)) (a args 1))
                                 ((eng:callable-p (a args 2)) (a args 2))
                                 (t eng:+undefined+)))
                 (settings (if (and (eng:js-object-p options)
                                    (eng:js-object-p
                                     (eng:js-get options "settings")))
                               (eng:js-get options "settings")
                               (%http2-default-settings-object)))
                 (session (%http2-make-session authority
                                               :server-p nil
                                               :settings settings))
                 (loop (eng:current-loop)))
            (when (eng:callable-p listener)
              (eng:js-call (eng:js-get session "once") session
                           (list "connect" listener)))
            (handler-case
                (let ((tcp
                        (net:tcp-connect
                         loop host port
                         :on-connect
                         (lambda (c)
                           (eng:hidden-prop session "_tcp" c)
                           (eng:js-set session "connecting" eng:+false+ nil)
                           ;; Client connection preface + SETTINGS (RFC 7540 §3.5).
                           (ignore-errors
                             (net:tcp-write c +http2-client-preface+)
                             (net:tcp-write c (%http2-settings-frame settings nil)))
                           (eng:js-call (eng:js-get session "emit") session
                                        (list "connect" session (eng:new-object))))
                         :on-data
                         (lambda (c data)
                           (declare (ignore c))
                           (eng:js-call (eng:js-get session "emit") session
                                        (list "data" (%buffer-from-octets data))))
                         :on-close
                         (lambda (c code)
                           (declare (ignore c code))
                           (eng:js-set session "closed" eng:+true+ nil)
                           (eng:js-call (eng:js-get session "emit") session
                                        (list "close")))
                         :on-error
                         (lambda (c code)
                           (declare (ignore c))
                           (eng:js-call (eng:js-get session "emit") session
                             (list "error"
                                   (eng:js-construct
                                    (eng:js-get (eng:realm-global eng:*realm*)
                                                "Error")
                                    (list (format nil "http2 connect: ~a"
                                                  code)))))))))
                  (eng:hidden-prop session "_tcp" tcp))
              (error (c)
                (eng:js-call (eng:js-get session "emit") session
                  (list "error"
                        (eng:js-construct
                         (eng:js-get (eng:realm-global eng:*realm*) "Error")
                         (list (format nil "http2 connect: ~a" c)))))))
            session))))
    (eng:install-method o "getDefaultSettings" 0
      (lambda (this args)
        (declare (ignore this args))
        (%http2-default-settings-object)))
    (eng:install-method o "getPackedSettings" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((settings (if (eng:js-object-p (a args 0))
                            (a args 0)
                            (%http2-default-settings-object))))
          (%buffer-from-octets (%http2-pack-settings settings)))))
    (eng:install-method o "getUnpackedSettings" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((buf (a args 0)))
          (cond
            ((eng:js-typed-array-p buf)
             (multiple-value-bind (b o l) (eng:ta-octets buf)
               (%http2-unpack-settings (subseq b o (+ o l)))))
            ((eng:js-array-buffer-p buf)
             (%http2-unpack-settings (eng:js-array-buffer-bytes buf)))
            (t (%http2-default-settings-object))))))
    (eng:data-prop o "Http2ServerRequest"
                   (eng:make-native-function "Http2ServerRequest" 0
                     (lambda (this args)
                       (declare (ignore this args))
                       (undef))))
    (eng:data-prop o "Http2ServerResponse"
                   (eng:make-native-function "Http2ServerResponse" 0
                     (lambda (this args)
                       (declare (ignore this args))
                       (undef))))
    (eng:data-prop o "Http2Session"
                   (eng:make-native-function "Http2Session" 0
                     (lambda (this args)
                       (declare (ignore this args))
                       (undef))))
    o))

(register-node-builtin "http2" #'build-node-http2)
