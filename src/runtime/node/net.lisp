;;;; net.lisp — node:net Socket/Server over pure-CL clun.net TCP.

(in-package :clun.runtime)

(defun %net-is-ip (s)
  (let ((str (->str s)))
    (cond
      ((and (find #\. str) (every (lambda (c) (or (digit-char-p c) (char= c #\.))) str))
       4)
      ((find #\: str) 6)
      (t 0))))

(defun build-node-net ()
  (let* ((o (eng:new-object))
         (sock-proto (eng:new-object))
         (sock-ctor
          (eng:make-native-function
           "Socket" 1
           (lambda (this args) (declare (ignore args))
             (when (eng:js-object-p this) (%ev-init this)
               (eng:data-prop this "connecting" eng:+false+)
               (eng:data-prop this "destroyed" eng:+false+)
               (eng:data-prop this "pending" eng:+false+)
               (eng:data-prop this "bytesRead" 0d0)
               (eng:data-prop this "bytesWritten" 0d0))
             (undef))
           :construct
           (lambda (args nt)
             (declare (ignore args nt))
             (let ((obj (%ev-init (eng:js-make-object sock-proto))))
               (eng:data-prop obj "connecting" eng:+false+)
               (eng:data-prop obj "destroyed" eng:+false+)
               (eng:data-prop obj "pending" eng:+false+)
               (eng:data-prop obj "bytesRead" 0d0)
               (eng:data-prop obj "bytesWritten" 0d0)
               obj))))
         (srv-proto (eng:new-object))
         (srv-ctor
          (eng:make-native-function
           "Server" 2
           (lambda (this args)
             (when (eng:js-object-p this)
               (%ev-init this)
               (when (eng:callable-p (a args 0))
                 (eng:js-call (eng:js-get this "on") this
                              (list "connection" (a args 0)))))
             (undef))
           :construct
           (lambda (args nt)
             (declare (ignore nt))
             (let ((obj (%ev-init (eng:js-make-object srv-proto))))
               (when (eng:callable-p (a args 0))
                 (eng:js-call (eng:js-get obj "on") obj
                              (list "connection" (a args 0))))
               obj)))))
    (eng:data-prop sock-ctor "prototype" sock-proto)
    (labels ((m (proto name arity fn) (eng:install-method proto name arity fn)))
      (m sock-proto "connect" 3
         (lambda (this args)
           (let ((port (a args 0)) (host (a args 1)) (cb (a args 2)))
             (when (eng:js-object-p port)
               (let ((opts port))
                 (setf port (eng:js-get opts "port")
                       host (eng:js-get opts "host")
                       cb (a args 1))))
             (when (eng:callable-p host) (setf cb host host "127.0.0.1"))
             (when (undef-p host) (setf host "127.0.0.1"))
             (eng:data-prop this "connecting" eng:+true+)
             (handler-case
                 (let* ((h (->str host))
                        (p (truncate (->num port)))
                        (loop (eng:current-loop))
                        (tcp (net:tcp-connect loop h p
                              :on-connect
                              (lambda (tcp)
                                (declare (ignore tcp))
                                (eng:data-prop this "connecting" eng:+false+)
                                (eng:js-call (eng:js-get this "emit") this
                                             (list "connect"))
                                (when (eng:callable-p cb)
                                  (eng:js-call cb (undef) '())))
                              :on-error
                              (lambda (code)
                                (eng:js-call (eng:js-get this "emit") this
                                  (list "error"
                                        (eng:js-construct
                                         (eng:js-get (eng:realm-global eng:*realm*)
                                                     "Error")
                                         (list (format nil "connect ~a" code)))))))))
                   (eng:hidden-prop this "_tcp" tcp)
                   (let ((lh (lp:make-handle loop)))
                     (lp:handle-activate lh)
                     (lp:handle-ref lh)
                     (eng:hidden-prop this "_loopHandle" lh))
                   (eng:data-prop this "remoteAddress" h)
                   (eng:data-prop this "remotePort" (coerce p 'double-float))
                   ;; Apply deferred sockopts if set before connect completed.
                   (let ((nd (eng:js-get this "noDelay"))
                         (ka (eng:js-get this "keepAlive"))
                         (kad (eng:js-get this "keepAliveInitialDelay")))
                     (unless (or (undef-p nd) (eng:js-undefined-p nd))
                       (net:tcp-set-nodelay tcp (eng:js-truthy nd)))
                     (when (eng:js-truthy ka)
                       (net:tcp-set-keepalive
                        tcp t
                        (if (or (undef-p kad) (eng:js-undefined-p kad))
                            0 (truncate (->num kad)))))))
               (error (c)
                 (eng:js-call (eng:js-get this "emit") this
                   (list "error"
                         (eng:js-construct
                          (eng:js-get (eng:realm-global eng:*realm*) "Error")
                          (list (format nil "connect: ~a" c)))))))
             this)))
      (m sock-proto "write" 3
         (lambda (this args)
           (let ((chunk (a args 0))
                 (tcp (eng:js-get this "_tcp")))
             (when tcp
               (let ((octets (if (eng:js-typed-array-p chunk)
                                 (multiple-value-bind (b o l) (eng:ta-octets chunk)
                                   (subseq b o (+ o l)))
                                 (sb-ext:string-to-octets (->str chunk)
                                                          :external-format :utf-8))))
                 (ignore-errors (net:tcp-write tcp octets))
                 (eng:js-set this "bytesWritten"
                             (+ (->num (eng:js-get this "bytesWritten"))
                                (length octets))
                             nil)))
             (let ((cb (a args 2)))
               (when (eng:callable-p (a args 1)) (setf cb (a args 1)))
               (when (eng:callable-p cb) (eng:js-call cb (undef) '())))
             eng:+true+)))
      (m sock-proto "end" 3
         (lambda (this args)
           (unless (undef-p (a args 0))
             (eng:js-call (eng:js-get this "write") this (list (a args 0))))
           (let ((tcp (eng:js-get this "_tcp")))
             (when tcp (ignore-errors (net:tcp-shutdown tcp))))
           (eng:js-call (eng:js-get this "emit") this (list "end"))
           this))
      (m sock-proto "destroy" 1
         (lambda (this args)
           (let ((tcp (eng:js-get this "_tcp")))
             (when tcp (ignore-errors (net:tcp-close tcp))))
           (eng:data-prop this "destroyed" eng:+true+)
           (unless (undef-p (a args 0))
             (eng:js-call (eng:js-get this "emit") this (list "error" (a args 0))))
           (eng:js-call (eng:js-get this "emit") this (list "close"))
           this))
      (m sock-proto "setTimeout" 2
         (lambda (this args)
           (let ((ms (if (undef-p (a args 0)) 0 (max 0 (truncate (->num (a args 0))))))
                 (cb (a args 1))
                 (old (eng:js-get this "_timeoutTimer")))
             (when (and old (not (eng:js-undefined-p old)) (not (eng:js-null-p old)))
               (ignore-errors (lp:clear-timer old)))
             (eng:hidden-prop this "_timeoutTimer" eng:+undefined+)
             (when (eng:callable-p cb)
               (eng:js-call (eng:js-get this "once") this (list "timeout" cb)))
             (when (plusp ms)
               (let* ((loop (eng:current-loop))
                      (timer (lp:set-timer loop ms
                                           (lambda ()
                                             (eng:js-call (eng:js-get this "emit") this
                                                          (list "timeout")))
                                           :refd nil)))
                 (eng:hidden-prop this "_timeoutTimer" timer)
                 (eng:data-prop this "timeout" (coerce ms 'double-float))))
             (when (zerop ms)
               (eng:data-prop this "timeout" 0d0))
             this)))
      (m sock-proto "setNoDelay" 1
         (lambda (this args)
           (let ((enabled (if (undef-p (a args 0)) t (eng:js-truthy (a args 0))))
                 (tcp (eng:js-get this "_tcp")))
             (eng:data-prop this "noDelay" (eng:js-boolean enabled))
             (when tcp (net:tcp-set-nodelay tcp enabled))
             this)))
      (m sock-proto "setKeepAlive" 2
         (lambda (this args)
           (let ((enabled (eng:js-truthy (a args 0)))
                 (initial (if (undef-p (a args 1)) 0 (truncate (->num (a args 1)))))
                 (tcp (eng:js-get this "_tcp")))
             (eng:data-prop this "keepAlive" (eng:js-boolean enabled))
             (eng:data-prop this "keepAliveInitialDelay" (coerce initial 'double-float))
             (when tcp (net:tcp-set-keepalive tcp enabled initial))
             this)))
      (m sock-proto "ref" 0
         (lambda (this args)
           (declare (ignore args))
           (let ((h (eng:js-get this "_loopHandle")))
             (when h (ignore-errors (lp:handle-ref h))))
           this))
      (m sock-proto "unref" 0
         (lambda (this args)
           (declare (ignore args))
           (let ((h (eng:js-get this "_loopHandle")))
             (when h (ignore-errors (lp:handle-unref h))))
           this))
      (m sock-proto "address" 0
         (lambda (this args) (declare (ignore args))
           (let ((o2 (eng:new-object)))
             (eng:data-prop o2 "port" (or (eng:js-get this "localPort") 0d0))
             (eng:data-prop o2 "family" "IPv4")
             (eng:data-prop o2 "address" (or (eng:js-get this "localAddress") "0.0.0.0"))
             o2)))
      ;; wire EventEmitter methods
      (let ((ee-proto (eng:js-get (eng:js-get (build-node-events) "EventEmitter") "prototype")))
        (dolist (name '("on" "once" "emit" "removeListener" "off" "addListener"))
          (eng:data-prop sock-proto name (eng:js-get ee-proto name))
          (eng:data-prop srv-proto name (eng:js-get ee-proto name)))))
    (eng:data-prop srv-ctor "prototype" srv-proto)
    (eng:install-method srv-proto "listen" 3
      (lambda (this args)
        (let ((port (a args 0)) (host (a args 1)) (cb (a args 2)))
          (when (eng:callable-p host) (setf cb host host "0.0.0.0"))
          (when (eng:js-object-p port)
            (let ((opts port))
              (setf port (eng:js-get opts "port")
                    host (or (eng:js-get opts "host") "0.0.0.0")
                    cb (a args 1))))
          (when (undef-p host) (setf host "0.0.0.0"))
          (handler-case
              (let* ((p (if (undef-p port) 0 (truncate (->num port))))
                     (loop (eng:current-loop))
                     (listener (net:tcp-listen loop (->str host) p
                                :on-connection
                                (lambda (tcp)
                                  (let ((sock (eng:js-construct sock-ctor '())))
                                    (eng:hidden-prop sock "_tcp" tcp)
                                    (eng:js-call (eng:js-get this "emit") this
                                                 (list "connection" sock)))))))
                (eng:hidden-prop this "_listener" listener)
                (let ((lh (lp:make-handle loop)))
                  (lp:handle-activate lh)
                  (lp:handle-ref lh)
                  (eng:hidden-prop this "_loopHandle" lh))
                (eng:data-prop this "listening" eng:+true+)
                (eng:data-prop this "port"
                               (coerce (or (ignore-errors (net:listener-port listener)) p)
                                       'double-float))
                (eng:js-call (eng:js-get this "emit") this (list "listening"))
                (when (eng:callable-p cb) (eng:js-call cb (undef) '())))
            (error (c)
              (eng:js-call (eng:js-get this "emit") this
                (list "error"
                      (eng:js-construct
                       (eng:js-get (eng:realm-global eng:*realm*) "Error")
                       (list (format nil "listen: ~a" c)))))))
          this)))
    (eng:install-method srv-proto "close" 1
      (lambda (this args)
        (let ((listener (eng:js-get this "_listener")))
          (when listener (ignore-errors (net:listener-close listener))))
        (eng:data-prop this "listening" eng:+false+)
        (eng:js-call (eng:js-get this "emit") this (list "close"))
        (when (eng:callable-p (a args 0)) (eng:js-call (a args 0) (undef) '()))
        this))
    (eng:install-method srv-proto "address" 0
      (lambda (this args) (declare (ignore args))
        (let ((o2 (eng:new-object)))
          (eng:data-prop o2 "port" (or (eng:js-get this "port") 0d0))
          (eng:data-prop o2 "family" "IPv4")
          (eng:data-prop o2 "address" "0.0.0.0")
          o2)))
    (eng:install-method srv-proto "ref" 0
      (lambda (this args)
        (declare (ignore args))
        (let ((h (eng:js-get this "_loopHandle")))
          (when h (ignore-errors (lp:handle-ref h))))
        this))
    (eng:install-method srv-proto "unref" 0
      (lambda (this args)
        (declare (ignore args))
        (let ((h (eng:js-get this "_loopHandle")))
          (when h (ignore-errors (lp:handle-unref h))))
        this))
    (eng:data-prop o "Socket" sock-ctor)
    (eng:data-prop o "Server" srv-ctor)
    (eng:install-method o "createServer" 2
      (lambda (this args) (declare (ignore this))
        (eng:js-construct srv-ctor args)))
    (eng:install-method o "createConnection" 3
      (lambda (this args) (declare (ignore this))
        (let ((sock (eng:js-construct sock-ctor '())))
          (eng:js-call (eng:js-get sock "connect") sock args)
          sock)))
    (eng:install-method o "connect" 3
      (lambda (this args) (declare (ignore this))
        (eng:js-call (eng:js-get o "createConnection") o args)))
    (eng:install-method o "isIP" 1
      (lambda (this args) (declare (ignore this))
        (coerce (%net-is-ip (a args 0)) 'double-float)))
    (eng:install-method o "isIPv4" 1
      (lambda (this args) (declare (ignore this))
        (eng:js-boolean (= 4 (%net-is-ip (a args 0))))))
    (eng:install-method o "isIPv6" 1
      (lambda (this args) (declare (ignore this))
        (eng:js-boolean (= 6 (%net-is-ip (a args 0))))))
    o))

(register-node-builtin "net" #'build-node-net)
