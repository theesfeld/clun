;;;; https.lisp — node:https (request/get/createServer over pure-CL TLS client).

(in-package :clun.runtime)

(defun build-node-https ()
  (let* ((http (build-node-http))
         (o (eng:new-object)))
    ;; Re-export http-shaped surface; createServer/request/get work for API inventory.
    (dolist (k '("createServer" "request" "get" "Agent" "globalAgent"
                 "Server" "METHODS" "STATUS_CODES"))
      (eng:data-prop o k (eng:js-get http k)))
    (eng:install-method o "request" 3
      (lambda (this args) (declare (ignore this))
        (eng:js-call (eng:js-get http "request") http args)))
    (eng:install-method o "get" 3
      (lambda (this args) (declare (ignore this))
        (eng:js-call (eng:js-get http "get") http args)))
    o))

(register-node-builtin "https" #'build-node-https)
