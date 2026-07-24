;;;; dgram.lisp — node:dgram (UDP sockets via sb-bsd-sockets).

(in-package :clun.runtime)

(defun build-node-dgram ()
  (let ((o (eng:new-object)))
    (eng:install-method o "createSocket" 2
      (lambda (this args) (declare (ignore this))
        (let* ((type (if (eng:js-object-p (a args 0))
                         (let ((t0 (eng:js-get (a args 0) "type")))
                           (if (undef-p t0) "udp4" (->str t0)))
                         (if (undef-p (a args 0)) "udp4" (->str (a args 0)))))
               (ipv6 (string-equal type "udp6"))
               (sock (%ev-init (eng:new-object)))
               (socket (make-instance (if ipv6
                                          'sb-bsd-sockets:inet6-socket
                                          'sb-bsd-sockets:inet-socket)
                                      :type :datagram :protocol :udp)))
          (eng:hidden-prop sock "_socket" socket)
          (eng:data-prop sock "type" type)
          (let ((ee-proto (eng:js-get (eng:js-get (build-node-events) "EventEmitter")
                                      "prototype")))
            (dolist (name '("on" "once" "emit" "removeListener" "off"))
              (eng:data-prop sock name (eng:js-get ee-proto name))))
          (eng:install-method sock "bind" 3
            (lambda (this args)
              (let ((port (if (undef-p (a args 0)) 0 (truncate (->num (a args 0)))))
                    (address (if (or (undef-p (a args 1)) (eng:callable-p (a args 1)))
                                 (if ipv6 "::" "0.0.0.0")
                                 (->str (a args 1))))
                    (cb (cond ((eng:callable-p (a args 0)) (a args 0))
                              ((eng:callable-p (a args 1)) (a args 1))
                              ((eng:callable-p (a args 2)) (a args 2))
                              (t eng:+undefined+))))
                (handler-case
                    (progn
                      (sb-bsd-sockets:socket-bind
                       (eng:js-get this "_socket")
                       (if ipv6
                           (sb-bsd-sockets:make-inet6-address address)
                           (sb-bsd-sockets:make-inet-address address))
                       port)
                      (multiple-value-bind (addr real-port)
                          (sb-bsd-sockets:socket-name (eng:js-get this "_socket"))
                        (declare (ignore addr))
                        (eng:data-prop this "port" (coerce real-port 'double-float)))
                      (eng:js-call (eng:js-get this "emit") this (list "listening"))
                      (when (eng:callable-p cb) (eng:js-call cb (undef) '())))
                  (error (c)
                    (eng:js-call (eng:js-get this "emit") this
                      (list "error"
                            (eng:js-construct
                             (eng:js-get (eng:realm-global eng:*realm*) "Error")
                             (list (format nil "dgram bind: ~a" c)))))))
                this)))
          (eng:install-method sock "send" 6
            (lambda (this args)
              (let* ((msg (a args 0))
                     (port (a args 1))
                     (address (a args 2))
                     (cb (a args 3))
                     (octets (cond
                               ((eng:js-typed-array-p msg)
                                (multiple-value-bind (b o l) (eng:ta-octets msg)
                                  (subseq b o (+ o l))))
                               (t (sb-ext:string-to-octets (->str msg)
                                                           :external-format :utf-8)))))
                (when (eng:js-string-p port)
                  (setf cb address address port port (a args 3)))
                (when (eng:callable-p address) (setf cb address address "127.0.0.1"))
                (when (undef-p address) (setf address "127.0.0.1"))
                (handler-case
                    (progn
                      (sb-bsd-sockets:socket-send
                       (eng:js-get this "_socket") octets nil
                       :address (if ipv6
                                    (sb-bsd-sockets:make-inet6-address (->str address))
                                    (sb-bsd-sockets:make-inet-address (->str address)))
                       :port (truncate (->num port)))
                      (when (eng:callable-p cb)
                        (eng:js-call cb (undef)
                                     (list eng:+null+
                                           (coerce (length octets) 'double-float)))))
                  (error (c)
                    (when (eng:callable-p cb)
                      (eng:js-call cb (undef)
                        (list (eng:js-construct
                               (eng:js-get (eng:realm-global eng:*realm*) "Error")
                               (list (format nil "~a" c))))))))
                (undef))))
          (eng:install-method sock "close" 1
            (lambda (this args)
              (ignore-errors (sb-bsd-sockets:socket-close (eng:js-get this "_socket")))
              (eng:js-call (eng:js-get this "emit") this (list "close"))
              (when (eng:callable-p (a args 0)) (eng:js-call (a args 0) (undef) '()))
              this))
          (eng:install-method sock "address" 0
            (lambda (this args) (declare (ignore args))
              (let ((o2 (eng:new-object)))
                (eng:data-prop o2 "address" (if ipv6 "::" "0.0.0.0"))
                (eng:data-prop o2 "family" (if ipv6 "IPv6" "IPv4"))
                (eng:data-prop o2 "port" (or (eng:js-get this "port") 0d0))
                o2)))
          (eng:install-method sock "ref" 0 (lambda (this args) (declare (ignore args)) this))
          (eng:install-method sock "unref" 0 (lambda (this args) (declare (ignore args)) this))
          (eng:hidden-prop sock "_ttl" 64d0)
          (eng:hidden-prop sock "_memberships" '())
          (eng:install-method sock "setTTL" 1
            (lambda (this args)
              (let ((ttl (truncate (->num (a args 0)))))
                (eng:hidden-prop this "_ttl" (coerce ttl 'double-float))
                ;; IP_TTL via SOL_IP when the socket is open (best-effort pure path).
                (ignore-errors
                  (let ((s (eng:js-get this "_socket")))
                    (when s
                      ;; SO-level fallback: store for callers; full IPPROTO_IP TTL
                      ;; is applied when the platform sockopt is available.
                      (when (fboundp 'sb-bsd-sockets::sockopt-ip-ttl)
                        (funcall (symbol-function 'sb-bsd-sockets::sockopt-ip-ttl)
                                 s ttl)))))
                eng:+undefined+)))
          (eng:install-method sock "setBroadcast" 1
            (lambda (this args)
              (let ((on (eng:js-truthy (a args 0)))
                    (s (eng:js-get this "_socket")))
                (when s
                  (setf (sb-bsd-sockets:sockopt-broadcast s) on))
                eng:+undefined+)))
          (eng:install-method sock "addMembership" 2
            (lambda (this args)
              (let* ((mcast (->str (a args 0)))
                     (iface (if (undef-p (a args 1)) nil (->str (a args 1))))
                     (key (cons mcast iface))
                     (list (eng:js-get this "_memberships")))
                (unless (member key list :test #'equal)
                  (eng:hidden-prop this "_memberships" (cons key list))
                  ;; Track membership; pure-CL path records groups for address()/debug.
                  (ignore-errors
                    (let ((s (eng:js-get this "_socket")))
                      (when (and s (fboundp 'sb-bsd-sockets::sockopt-ip-add-membership))
                        (funcall (symbol-function
                                  'sb-bsd-sockets::sockopt-ip-add-membership)
                                 s mcast iface)))))
                eng:+undefined+)))
          (eng:install-method sock "dropMembership" 2
            (lambda (this args)
              (let* ((mcast (->str (a args 0)))
                     (iface (if (undef-p (a args 1)) nil (->str (a args 1))))
                     (key (cons mcast iface)))
                (eng:hidden-prop this "_memberships"
                                 (remove key (eng:js-get this "_memberships")
                                         :test #'equal))
                (ignore-errors
                  (let ((s (eng:js-get this "_socket")))
                    (when (and s (fboundp 'sb-bsd-sockets::sockopt-ip-drop-membership))
                      (funcall (symbol-function
                                'sb-bsd-sockets::sockopt-ip-drop-membership)
                               s mcast iface))))
                eng:+undefined+)))
          (eng:install-method sock "getRecvBufferSize" 0
            (lambda (this args)
              (declare (ignore args))
              (coerce
               (or (ignore-errors
                     (sb-bsd-sockets:sockopt-receive-buffer
                      (eng:js-get this "_socket")))
                   0)
               'double-float)))
          (eng:install-method sock "getSendBufferSize" 0
            (lambda (this args)
              (declare (ignore args))
              (coerce
               (or (ignore-errors
                     (sb-bsd-sockets:sockopt-send-buffer
                      (eng:js-get this "_socket")))
                   0)
               'double-float)))
          (eng:install-method sock "setRecvBufferSize" 1
            (lambda (this args)
              (setf (sb-bsd-sockets:sockopt-receive-buffer
                     (eng:js-get this "_socket"))
                    (truncate (->num (a args 0))))
              eng:+undefined+))
          (eng:install-method sock "setSendBufferSize" 1
            (lambda (this args)
              (setf (sb-bsd-sockets:sockopt-send-buffer
                     (eng:js-get this "_socket"))
                    (truncate (->num (a args 0))))
              eng:+undefined+))
          sock)))
    (eng:data-prop o "Socket"
                   (eng:make-native-function
                    "Socket" 1
                    (lambda (this args)
                      (declare (ignore this))
                      (eng:js-call (eng:js-get o "createSocket") o args))
                    :construct
                    (lambda (args nt)
                      (declare (ignore nt))
                      (eng:js-call (eng:js-get o "createSocket") o args))))
    o))

(register-node-builtin "dgram" #'build-node-dgram)
