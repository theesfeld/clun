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
  "Erase TypeScript type syntax from SOURCE (for a .ts/.mts/.cts PATH), returning a
JS string of identical length (line + column preserved). Signals
unsupported-ts-syntax on non-erasable constructs; the loader maps it to a JS error."
  (when (tsx-path-p path)
    (error 'unsupported-ts-syntax :message ".tsx is not supported" :path path))
  (let ((erasures (scan-erasures source path)))
    (render-erasures source erasures)))

(defun render-erasures (src erasures)
  "Copy SRC; space-fill each (start . end) erase span EXCEPT line terminators (so
line and column of every surviving token are byte-identical to the original)."
  (let ((out (copy-seq (coerce src 'simple-string))))
    (dolist (span erasures out)
      (loop for i from (car span) below (cdr span)
            unless (eng:line-terminator-p (char-code (char out i)))
              do (setf (char out i) #\Space)))))

;;; Install the hook so the engine loader strips TS before parse-program. Mapping
;;; the transpiler condition to a JS SyntaxError happens here (line:col carried).
(setf eng:*ts-strip-hook*
      (lambda (source path)
        (handler-case (strip-types source path)
          (unsupported-ts-syntax (e)
            (eng:throw-syntax-error
             (format nil "~a (~a:~a)" (uts-message e) (uts-line e) (uts-col e)))))))
