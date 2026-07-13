;;;; registry.lisp — the node builtin-module registry (PLAN.md Phase 12, §3.7 runtime/node/).
;;;; Each module file calls (register-node-builtin "name" #'builder) at load time; the
;;;; builder builds a fresh exports object in the CURRENT realm on first require/import.
;;;; install-node-builtins wires the engine's *builtin-module-builder* hook to us.

(in-package :clun.runtime)

(defvar *node-builtins* (make-hash-table :test 'equal)
  "name -> (lambda () -> exports js-object in the current *realm*).")

(defun register-node-builtin (name builder)
  (setf (gethash name *node-builtins*) builder))

(defun node-builtin-dispatch (name)
  "Engine hook: a fresh exports object for builtin NAME in *realm*, or NIL if unknown."
  (let ((builder (gethash name *node-builtins*)))
    (when builder (funcall builder))))

(defun install-node-builtins ()
  "Point the engine's builtin-module hook at our registry (idempotent, process-global)."
  (setf eng:*builtin-module-builder* #'node-builtin-dispatch))

;;; --- terse helpers used by the module files --------------------------------

(defun a (args n) (eng:arg args n))
(defun ->str (v) (eng:to-string v))
(defun ->num (v) (eng:to-number v))
(defun undef () eng:+undefined+)
(defun undef-p (v) (eng:js-undefined-p v))
