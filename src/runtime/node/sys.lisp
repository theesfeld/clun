;;;; sys.lisp — node:sys (deprecated alias of node:util).

(in-package :clun.runtime)

(defun build-node-sys ()
  (build-node-util))

(register-node-builtin "sys" #'build-node-sys)
