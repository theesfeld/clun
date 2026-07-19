;;;; process.lisp — node:process (requireable module re-exporting the global process).
;;;; Bun/Node both expose process as a module; Clun installs the global in install-process.

(in-package :clun.runtime)

(defun build-node-process ()
  "Return the realm global process object (shared identity with the global)."
  (let ((proc (eng:js-get (eng:realm-global eng:*realm*) "process")))
    (if (eng:js-object-p proc) proc (eng:new-object))))

(register-node-builtin "process" #'build-node-process)
