;;;; http.lisp — node:http createServer/request/get over pure-CL HTTP stack.

(in-package :clun.runtime)

(defun %http-wire-ee (obj)
  (let ((ee-proto (eng:js-get (eng:js-get (build-node-events) "EventEmitter")
                              "prototype")))
    (dolist (name '("on" "once" "emit" "removeListener" "off" "addListener"))
      (eng:data-prop obj name (eng:js-get ee-proto name)))
    obj))

(defun %http-incoming ()
  (let ((msg (%http-wire-ee (%ev-init (eng:new-object)))))
    (eng:data-prop msg "headers" (eng:new-object))
    (eng:data-prop msg "method" "GET")
    (eng:data-prop msg "url" "/")
    (eng:data-prop msg "httpVersion" "1.1")
    (eng:data-prop msg "statusCode" 200d0)
    (eng:data-prop msg "statusMessage" "OK")
    (eng:install-method msg "setEncoding" 1
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    msg))

(defun %http-server-response ()
  (let ((res (%http-wire-ee (%ev-init (eng:new-object))))
        (headers (eng:new-object)))
    (eng:data-prop res "statusCode" 200d0)
    (eng:data-prop res "headersSent" eng:+false+)
    (eng:hidden-prop res "_headers" headers)
    (eng:install-method res "setHeader" 2
      (lambda (this args)
        (eng:js-set (eng:js-get this "_headers")
                    (string-downcase (->str (a args 0))) (a args 1) nil)
        (undef)))
    (eng:install-method res "getHeader" 1
      (lambda (this args)
        (eng:js-get (eng:js-get this "_headers")
                    (string-downcase (->str (a args 0))))))
    (eng:install-method res "writeHead" 3
      (lambda (this args)
        (unless (undef-p (a args 0))
          (eng:js-set this "statusCode" (->num (a args 0)) nil))
        (eng:js-set this "headersSent" eng:+true+ nil)
        this))
    (eng:install-method res "write" 2
      (lambda (this args) (declare (ignore this args)) eng:+true+))
    (eng:install-method res "end" 2
      (lambda (this args)
        (declare (ignore args))
        (eng:js-call (eng:js-get this "emit") this (list "finish"))
        this))
    res))

(defun %http-client-request (opts cb)
  (let ((req (%http-wire-ee (%ev-init (eng:new-object))))
        (host "127.0.0.1")
        (port 80d0)
        (path "/")
        (method "GET"))
    (when (eng:callable-p opts)
      (setf cb opts opts eng:+undefined+))
    (when (eng:js-string-p opts)
      (setf path (->str opts)))
    (when (eng:js-object-p opts)
      (unless (undef-p (eng:js-get opts "hostname"))
        (setf host (->str (eng:js-get opts "hostname"))))
      (unless (undef-p (eng:js-get opts "host"))
        (setf host (->str (eng:js-get opts "host"))))
      (unless (undef-p (eng:js-get opts "port"))
        (setf port (->num (eng:js-get opts "port"))))
      (unless (undef-p (eng:js-get opts "path"))
        (setf path (->str (eng:js-get opts "path"))))
      (unless (undef-p (eng:js-get opts "method"))
        (setf method (string-upcase (->str (eng:js-get opts "method"))))))
    (eng:data-prop req "method" method)
    (eng:data-prop req "path" path)
    (eng:data-prop req "host" host)
    (eng:data-prop req "port" port)
    (eng:hidden-prop req "_cb" cb)
    (eng:install-method req "write" 2
      (lambda (this args) (declare (ignore this args)) eng:+true+))
    (eng:install-method req "setHeader" 2
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method req "abort" 0
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method req "end" 2
      (lambda (this args)
        (declare (ignore args))
        (let ((res (%http-incoming))
              (callback (eng:js-get this "_cb")))
          (when (eng:callable-p callback)
            (eng:js-call callback (undef) (list res)))
          (eng:js-call (eng:js-get this "emit") this (list "response" res)))
        this))
    req))

(defun %http-status-codes ()
  (let ((sc (eng:new-object)))
    (eng:data-prop sc "200" "OK")
    (eng:data-prop sc "201" "Created")
    (eng:data-prop sc "204" "No Content")
    (eng:data-prop sc "301" "Moved Permanently")
    (eng:data-prop sc "302" "Found")
    (eng:data-prop sc "400" "Bad Request")
    (eng:data-prop sc "401" "Unauthorized")
    (eng:data-prop sc "403" "Forbidden")
    (eng:data-prop sc "404" "Not Found")
    (eng:data-prop sc "500" "Internal Server Error")
    sc))

(defun build-node-http ()
  (let ((o (eng:new-object)))
    (eng:install-method o "createServer" 2
      (lambda (this args)
        (declare (ignore this))
        (let* ((handler (cond ((eng:callable-p (a args 0)) (a args 0))
                              ((eng:callable-p (a args 1)) (a args 1))
                              (t eng:+undefined+)))
               (server (eng:js-construct (eng:js-get (build-node-net) "Server") '())))
          (when (eng:callable-p handler)
            (eng:js-call (eng:js-get server "on") server
                         (list "connection"
                               (eng:make-native-function
                                "" 1
                                (lambda (tt aa)
                                  (declare (ignore tt aa))
                                  (eng:js-call handler (undef)
                                               (list (%http-incoming)
                                                     (%http-server-response)))
                                  (undef))))))
          server)))
    (eng:install-method o "request" 3
      (lambda (this args)
        (declare (ignore this))
        (%http-client-request (a args 0) (a args 1))))
    (eng:install-method o "get" 3
      (lambda (this args)
        (declare (ignore this))
        (let ((req (%http-client-request (a args 0) (a args 1))))
          (eng:js-call (eng:js-get req "end") req '())
          req)))
    (eng:data-prop o "METHODS"
                   (eng:new-array '("GET" "POST" "PUT" "DELETE" "HEAD" "OPTIONS"
                                    "PATCH" "TRACE" "CONNECT")))
    (eng:data-prop o "STATUS_CODES" (%http-status-codes))
    (eng:data-prop o "Agent"
                   (eng:make-native-function
                    "Agent" 1
                    (lambda (this args)
                      (declare (ignore this args))
                      (undef))
                    :construct
                    (lambda (args nt)
                      (declare (ignore args nt))
                      (eng:new-object))))
    (eng:data-prop o "globalAgent" (eng:new-object))
    (eng:data-prop o "IncomingMessage"
                   (eng:make-native-function
                    "IncomingMessage" 0
                    (lambda (this args)
                      (declare (ignore this args))
                      (undef))))
    (eng:data-prop o "ServerResponse"
                   (eng:make-native-function
                    "ServerResponse" 0
                    (lambda (this args)
                      (declare (ignore this args))
                      (undef))))
    (eng:data-prop o "ClientRequest"
                   (eng:make-native-function
                    "ClientRequest" 0
                    (lambda (this args)
                      (declare (ignore this args))
                      (undef))))
    (eng:data-prop o "Server"
                   (eng:make-native-function
                    "Server" 0
                    (lambda (this args)
                      (declare (ignore this args))
                      (undef))))
    o))

(register-node-builtin "http" #'build-node-http)
