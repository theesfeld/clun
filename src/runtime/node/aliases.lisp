;;;; aliases.lisp — node subpath aliases + residual module registration.
;;;; Loaded last so every parent builder is already defined.

(in-package :clun.runtime)

(defun build-node-fs-promises ()
  (eng:js-get (build-node-fs) "promises"))

(defun build-node-assert-strict ()
  (build-node-assert))

(defun build-node-path-posix ()
  (let ((p (build-node-path)))
    (or (eng:js-get p "posix") p)))

(defun build-node-path-win32 ()
  (let ((p (build-node-path)))
    (or (eng:js-get p "win32") p)))

(register-node-builtin "fs/promises" #'build-node-fs-promises)
(register-node-builtin "assert/strict" #'build-node-assert-strict)
(register-node-builtin "path/posix" #'build-node-path-posix)
(register-node-builtin "path/win32" #'build-node-path-win32)

;; Re-register residual modules if remaining.lisp load order skipped them.
(unless (gethash "vm" *node-builtins*)
  (register-node-builtin "vm" #'build-node-vm))
(unless (gethash "v8" *node-builtins*)
  (register-node-builtin "v8" #'build-node-v8))
(unless (gethash "wasi" *node-builtins*)
  (register-node-builtin "wasi" #'build-node-wasi))
(unless (gethash "inspector" *node-builtins*)
  (register-node-builtin "inspector" #'build-node-inspector)
  (register-node-builtin "inspector/promises" #'build-node-inspector))
(unless (gethash "trace_events" *node-builtins*)
  (register-node-builtin "trace_events" #'build-node-trace-events))
(unless (gethash "sqlite" *node-builtins*)
  (register-node-builtin "sqlite" #'build-node-sqlite))
(unless (gethash "test" *node-builtins*)
  (register-node-builtin "test" #'build-node-test))
(unless (gethash "repl" *node-builtins*)
  (register-node-builtin "repl" #'build-node-repl))
