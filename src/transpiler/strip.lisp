;;;; strip.lisp — the public entry: strip-types (source path) -> stripped/transformed
;;;; JS source. Type erasures space-fill in place (line+column preserved). Value/
;;;; const enum declarations are replaced with classic IIFE emit (may change length;
;;;; newline count is preserved so later lines keep their numbers). Installs the
;;;; engine's *ts-strip-hook* at load time so the module loader / CJS require apply
;;;; it to .ts/.mts/.cts. (Phase 09 + issue #133 enum emit.)

(in-package :clun.transpiler)

(defun ts-source-p (path)
  "True iff PATH is a strippable TS source (.ts/.mts/.cts)."
  (let ((dot (position #\. path :from-end t)))
    (and dot (member (subseq path dot) '(".ts" ".mts" ".cts") :test #'string=))))

(defun tsx-path-p (path)
  (let ((dot (position #\. path :from-end t)))
    (and dot (string= (subseq path dot) ".tsx"))))

(defun strip-types (source path)
  "Erase TypeScript type syntax from SOURCE (for a .ts/.mts/.cts PATH) and emit
value/const enums as classic JS IIFEs. Pure type erasures preserve length; enum
replacements may change length (newlines of each replaced span are preserved).
Signals unsupported-ts-syntax on non-erasable constructs; the loader maps it to a
JS error."
  (when (tsx-path-p path)
    (error 'unsupported-ts-syntax :message ".tsx is not supported" :path path))
  (multiple-value-bind (erasures replacements) (scan-plan source path)
    (render-plan source erasures replacements)))

(defun render-erasures (src erasures)
  "Copy SRC; space-fill each (start . end) erase span EXCEPT line terminators (so
line and column of every surviving token are byte-identical to the original)."
  (render-plan src erasures nil))

(defun render-plan (src erasures replacements)
  "Apply ERASE spans (space-fill, keep line terminators; may overlap each other)
then REPLACE spans (start end text). Replacements are applied right-to-left on
original offsets so earlier indices stay valid. Pure erasures remain
length-preserving; replacements may change length."
  (let ((out (copy-seq (coerce src 'simple-string))))
    (dolist (span erasures)
      (loop for i from (car span) below (cdr span)
            unless (eng:line-terminator-p (char-code (char out i)))
              do (setf (char out i) #\Space)))
    (dolist (r (sort (copy-list replacements) #'> :key #'first) out)
      (destructuring-bind (start end text) r
        (setf out (concatenate 'string
                               (subseq out 0 start)
                               text
                               (subseq out end)))))))

;;; Install the hook so the engine loader strips TS before parse-program. Mapping
;;; the transpiler condition to a JS SyntaxError happens here (line:col carried).
(setf eng:*ts-strip-hook*
      (lambda (source path)
        (handler-case (strip-types source path)
          (unsupported-ts-syntax (e)
            (eng:throw-syntax-error
             (format nil "~a (~a:~a)" (uts-message e) (uts-line e) (uts-col e)))))))
