;;;; https.lisp — node:https (request/get/createServer over pure-CL TLS client).

(in-package :clun.runtime)

(defun %https-make-agent (opts)
  (let ((agent (%http-make-agent opts)))
    (eng:js-set agent "protocol" "https:" nil)
    agent))

(defun build-node-https ()
  (let* ((http (build-node-http))
         (o (eng:new-object)))
    ;; Re-export shared constants/types; request/get/createServer are HTTPS-specific.
    (dolist (k '("METHODS" "STATUS_CODES" "IncomingMessage" "ServerResponse"
                 "ClientRequest"))
      (eng:data-prop o k (eng:js-get http k)))
    (eng:data-prop o "Agent"
                   (eng:make-native-function
                    "Agent" 1
                    (lambda (this args)
                      (when (eng:js-object-p this)
                        (let ((built (%https-make-agent (a args 0))))
                          (dolist (k (eng:jm-own-property-keys built))
                            (when (stringp k)
                              (eng:data-prop this k (eng:js-get built k))))))
                      (undef))
                    :construct
                    (lambda (args nt)
                      (declare (ignore nt))
                      (%https-make-agent (a args 0)))))
    (eng:data-prop o "globalAgent" (%https-make-agent eng:+undefined+))
    (eng:install-method o "createServer" 2
      (lambda (this args)
        (declare (ignore this))
        (let* ((arg0 (a args 0))
               (arg1 (a args 1))
               (handler (cond ((eng:callable-p arg0) arg0)
                              ((eng:callable-p arg1) arg1)
                              (t eng:+undefined+)))
               (options (if (and (eng:js-object-p arg0)
                                 (not (eng:callable-p arg0)))
                            arg0
                            eng:+undefined+))
               ;; TLS options (key/cert/ca/SNI) are stored on the server and applied
               ;; by the node:tls secure-context path when a handshake is performed.
               (server (eng:js-call (eng:js-get http "createServer") http
                                    (if (eng:callable-p handler)
                                        (list handler)
                                        '()))))
          (when (eng:js-object-p options)
            (eng:hidden-prop server "_tlsOptions" options)
            (let ((ctx (eng:js-call
                        (eng:js-get (build-node-tls) "createSecureContext")
                        (build-node-tls)
                        (list options))))
              (eng:hidden-prop server "_secureContext" ctx)))
          server)))
    (eng:install-method o "request" 3
      (lambda (this args)
        (declare (ignore this))
        (%http-client-request (a args 0) (a args 1)
                              :default-port 443 :secure t)))
    (eng:install-method o "get" 3
      (lambda (this args)
        (declare (ignore this))
        (let ((req (%http-client-request (a args 0) (a args 1)
                                         :default-port 443 :secure t)))
          (eng:js-call (eng:js-get req "end") req '())
          req)))
    (eng:data-prop o "Server" (eng:js-get http "Server"))
    o))

(register-node-builtin "https" #'build-node-https)
