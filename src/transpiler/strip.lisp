;;;; strip.lisp — the public entry: strip-types (source path) -> stripped source of
;;;; identical length (type spans → whitespace, newlines kept). Installs the engine's
;;;; *ts-strip-hook* at load time so the module loader / CJS require apply it to
;;;; .ts/.mts/.cts. (Phase 09; M1 = identity + wiring; the scanner lands in ts-scan.)

(in-package :clun.transpiler)

(defun ts-source-p (path)
  "True iff PATH is a strippable TS source (.ts/.mts/.cts)."
  (let ((dot (position #\. path :from-end t)))
    (and dot (member (subseq path dot) '(".ts" ".mts" ".cts") :test #'string=))))

(defun tsx-path-p (path)
  (let ((dot (position #\. path :from-end t)))
    (and dot (string= (subseq path dot) ".tsx"))))

(defun strip-types (source path)
  "Transform TypeScript SOURCE (.ts/.mts/.cts, or post-JSX .tsx via spoofed .ts path)
to executable JS:
  - erasable type syntax → length-preserving whitespace when no runtime rewrite;
  - enums, runtime namespaces, and constructor parameter properties → Bun/TS-shaped
    emits (length may change).
Signals unsupported-ts-syntax on remaining non-supported forms (decorators,
import/export =, angle casts). JSX/TSX is lowered by TRANSFORM-JSX before this runs."
  (when (tsx-path-p path)
    (error 'unsupported-ts-syntax
           :message ".tsx must be JSX-transformed before type strip"
           :path path))
  (multiple-value-bind (erasures replacements) (scan-transforms source path)
    (render-plan source erasures replacements)))

(defun render-erasures (src erasures)
  "Copy SRC; space-fill each (start . end) erase span EXCEPT line terminators (so
line and column of every surviving token are byte-identical to the original)."
  (render-plan src erasures nil))

;;; Install hooks so the engine loader transforms JSX and strips TS before parse-program.
(setf eng:*ts-strip-hook*
      (lambda (source path)
        (handler-case (strip-types source path)
          (unsupported-ts-syntax (e)
            (eng:throw-syntax-error
             (format nil "~a (~a:~a)" (uts-message e) (uts-line e) (uts-col e)))))))

(setf eng:*jsx-transform-hook*
      (lambda (source path)
        (handler-case (transform-jsx-file source path)
          (unsupported-ts-syntax (e)
            (eng:throw-syntax-error
             (format nil "~a (~a:~a)" (uts-message e) (uts-line e) (uts-col e)))))))
