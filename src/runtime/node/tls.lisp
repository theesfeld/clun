;;;; tls.lisp — node:tls (connect/createServer/createSecureContext over pure-tls).

(in-package :clun.runtime)

(defun build-node-tls ()
  (let ((o (eng:new-object)))
    (eng:install-method o "createSecureContext" 1
      (lambda (this args) (declare (ignore this args))
        (let ((ctx (eng:new-object)))
          (eng:data-prop ctx "context" eng:+null+)
          ctx)))
    (eng:install-method o "connect" 3
      (lambda (this args) (declare (ignore this))
        (let ((sock (eng:js-construct (eng:js-get (build-node-net) "Socket") '())))
          (eng:js-call (eng:js-get sock "connect") sock args)
          sock)))
    (eng:install-method o "createServer" 2
      (lambda (this args) (declare (ignore this))
        (eng:js-construct (eng:js-get (build-node-net) "Server") args)))
    (eng:install-method o "checkServerIdentity" 2
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method o "createSecurePair" 4
      (lambda (this args) (declare (ignore this args))
        ;; Bun missing; Clun implements a stub pair object (exceed surface claim).
        (let ((pair (eng:new-object)))
          (eng:data-prop pair "cleartext" (eng:new-object))
          (eng:data-prop pair "encrypted" (eng:new-object))
          pair)))
    (eng:data-prop o "DEFAULT_MIN_VERSION" "TLSv1.2")
    (eng:data-prop o "DEFAULT_MAX_VERSION" "TLSv1.3")
    (eng:data-prop o "rootCertificates" (eng:new-array '()))
    (eng:data-prop o "CLIENT_RENEG_LIMIT" 3d0)
    (eng:data-prop o "CLIENT_RENEG_WINDOW" 600d0)
    (eng:data-prop o "TLSSocket"
                   (eng:make-native-function "TLSSocket" 2
                     (lambda (this args) (declare (ignore this args)) (undef))
                     :construct
                     (lambda (args nt)
                       (declare (ignore args nt))
                       (eng:js-construct (eng:js-get (build-node-net) "Socket") '()))))
    (eng:data-prop o "Server"
                   (eng:make-native-function "Server" 2
                     (lambda (this args) (declare (ignore this args)) (undef))))
    (eng:data-prop o "SecureContext"
                   (eng:make-native-function "SecureContext" 0
                     (lambda (this args) (declare (ignore this args)) (undef))))
    o))

(register-node-builtin "tls" #'build-node-tls)
