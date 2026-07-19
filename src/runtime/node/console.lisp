;;;; console.lisp — node:console (requireable re-export of the global console).

(in-package :clun.runtime)

(defun build-node-console ()
  (let ((c (eng:js-get (eng:realm-global eng:*realm*) "console")))
    (if (eng:js-object-p c) c (eng:new-object))))

(register-node-builtin "console" #'build-node-console)
