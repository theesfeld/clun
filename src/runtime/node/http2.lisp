;;;; http2.lisp — node:http2 client/server constants + session surface (pure-CL).

(in-package :clun.runtime)

(defun build-node-http2 ()
  (let ((o (eng:new-object))
        (constants (eng:new-object)))
    (flet ((c (k v) (eng:data-prop constants k (coerce v 'double-float))))
      (c "NGHTTP2_SESSION_SERVER" 0)
      (c "NGHTTP2_SESSION_CLIENT" 1)
      (c "NGHTTP2_STREAM_STATE_IDLE" 1)
      (c "NGHTTP2_STREAM_STATE_OPEN" 2)
      (c "NGHTTP2_FLAG_END_STREAM" 1)
      (c "NGHTTP2_FLAG_END_HEADERS" 4)
      (c "NGHTTP2_DATA" 0)
      (c "NGHTTP2_HEADERS" 1)
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
      (lambda (this args) (declare (ignore this))
        (let ((server (%ev-init (eng:new-object))))
          (let ((ee-proto (eng:js-get (eng:js-get (build-node-events) "EventEmitter")
                                      "prototype")))
            (dolist (name '("on" "once" "emit" "removeListener" "off"))
              (eng:data-prop server name (eng:js-get ee-proto name))))
          (eng:install-method server "listen" 3
            (lambda (this args)
              (eng:js-call (eng:js-get (build-node-net) "createServer")
                           (build-node-net) args)
              (eng:js-call (eng:js-get this "emit") this (list "listening"))
              this))
          (eng:install-method server "close" 1
            (lambda (this args)
              (when (eng:callable-p (a args 0)) (eng:js-call (a args 0) (undef) '()))
              (or this eng:+undefined+)))
          (when (eng:callable-p (a args 0))
            (eng:js-call (eng:js-get server "on") server
                         (list "stream" (a args 0))))
          (when (eng:callable-p (a args 1))
            (eng:js-call (eng:js-get server "on") server
                         (list "stream" (a args 1))))
          server)))
    (eng:install-method o "connect" 3
      (lambda (this args) (declare (ignore this args))
        (let ((session (%ev-init (eng:new-object))))
          (let ((ee-proto (eng:js-get (eng:js-get (build-node-events) "EventEmitter")
                                      "prototype")))
            (dolist (name '("on" "once" "emit" "removeListener" "off"))
              (eng:data-prop session name (eng:js-get ee-proto name))))
          (eng:install-method session "request" 2
            (lambda (this args) (declare (ignore this args))
              (let ((stream (%ev-init (eng:new-object))))
                (let ((ee-proto (eng:js-get (eng:js-get (build-node-events) "EventEmitter")
                                            "prototype")))
                  (dolist (name '("on" "once" "emit" "removeListener" "off"))
                    (eng:data-prop stream name (eng:js-get ee-proto name))))
                (eng:install-method stream "end" 2
                  (lambda (this args) (declare (ignore args)) this))
                (eng:install-method stream "write" 2
                  (lambda (this args) (declare (ignore this args)) eng:+true+))
                stream)))
          (eng:install-method session "close" 0
            (lambda (this args) (declare (ignore this args)) eng:+undefined+))
          (eng:install-method session "ping" 2
            (lambda (this args) (declare (ignore this args)) eng:+undefined+))
          session)))
    (eng:install-method o "getDefaultSettings" 0
      (lambda (this args) (declare (ignore this args))
        (let ((s (eng:new-object)))
          (eng:data-prop s "headerTableSize" 4096d0)
          (eng:data-prop s "enablePush" eng:+true+)
          (eng:data-prop s "initialWindowSize" 65535d0)
          (eng:data-prop s "maxFrameSize" 16384d0)
          s)))
    (eng:install-method o "getPackedSettings" 1
      (lambda (this args) (declare (ignore this args))
        (%buffer-from-octets #(0 0 0 0))))
    (eng:install-method o "getUnpackedSettings" 1
      (lambda (this args) (declare (ignore this args))
        (eng:js-call (eng:js-get o "getDefaultSettings") o '())))
    o))

(register-node-builtin "http2" #'build-node-http2)
