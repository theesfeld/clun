;;;; clun-fmt-lint.lisp — Clun.format / Clun.lint JavaScript surface (#190).
;;;;
;;;; Exceeds Bun (no first-party fmt/lint). Peer surface inspired by deno fmt/lint
;;;; plus programmatic APIs.

(in-package :clun.runtime)

(defun %fmt-js-string (value)
  (cond
    ((null value) nil)
    ((eng:js-undefined-p value) nil)
    ((eq value eng:+null+) nil)
    ((eng:js-string-p value) value)
    ((stringp value) value)
    (t (eng:to-string value))))

(defun %fmt-js-bool (value &optional default)
  (cond ((eng:js-undefined-p value) default)
        ((null value) default)
        ((eq value eng:+null+) nil)
        ((eq value eng:+true+) t)
        ((eq value eng:+false+) nil)
        (t (eng:js-truthy value))))

(defun %fmt-js-int (value &optional default)
  (cond ((eng:js-undefined-p value) default)
        ((eng:js-number-p value)
         (let ((n (eng:to-number value)))
           (if (or (eng:js-nan-p n) (eng:js-infinite-p n)) default (truncate n))))
        (t default)))

(defun %fmt-options-from-js (opts)
  (if (and opts (eng:js-object-p opts) (not (eng:js-undefined-p opts)))
      (clun.fmt:default-fmt-options
       :indent (%fmt-js-int (eng:js-get opts "indent") 2)
       :print-width (%fmt-js-int (eng:js-get opts "printWidth") 80)
       :semicolons (%fmt-js-bool (eng:js-get opts "semicolons") t)
       :single-quote (%fmt-js-bool (eng:js-get opts "singleQuote") nil)
       :trailing-comma (%fmt-js-bool (eng:js-get opts "trailingComma") t)
       :insert-final-newline (%fmt-js-bool (eng:js-get opts "insertFinalNewline") t)
       :language (let ((l (%fmt-js-string (eng:js-get opts "language"))))
                   (when l (intern (string-upcase l) :keyword))))
      (clun.fmt:default-fmt-options)))

(defun %diag->js (d)
  (let ((o (eng:new-object)))
    (eng:data-prop o "ruleId" (clun.lint:diag-rule d))
    (eng:data-prop o "severity"
                   (string-downcase (symbol-name (clun.lint:diag-severity d))))
    (eng:data-prop o "message" (clun.lint:diag-message d))
    (eng:data-prop o "line" (coerce (clun.lint:diag-line d) 'double-float))
    (eng:data-prop o "column" (coerce (clun.lint:diag-column d) 'double-float))
    (when (clun.lint:diag-path d)
      (eng:data-prop o "filePath" (clun.lint:diag-path d)))
    (when (clun.lint:diag-fix d)
      (eng:data-prop o "fix" (clun.lint:diag-fix d)))
    o))

(defun %diags->js-array (diags)
  (eng:new-array (mapcar #'%diag->js diags)))

(defun make-clun-format ()
  "Clun.format(source, opts?) function object with .check / .file / .version."
  (let ((fn (eng:make-native-function
             "format" 1
             (lambda (this args)
               (declare (ignore this))
               (let* ((source (%fmt-js-string (eng:arg args 0)))
                      (opts (eng:arg args 1))
                      (path (when (and opts (eng:js-object-p opts))
                              (%fmt-js-string (eng:js-get opts "filepath"))))
                      (fo (%fmt-options-from-js opts)))
                 (unless source
                   (eng:throw-type-error "Clun.format requires a source string"))
                 (handler-case
                     (clun.fmt:format-source source :path path :options fo)
                   (clun.fmt:fmt-error (e)
                     (eng:throw-native-error :error (clun.fmt:fmt-error-message e)))
                   (error (e)
                     (eng:throw-native-error :error (princ-to-string e)))))))))
    (eng:data-prop
     fn "check"
     (eng:make-native-function
      "check" 1
      (lambda (this args)
        (declare (ignore this))
        (let* ((source (%fmt-js-string (eng:arg args 0)))
               (opts (eng:arg args 1))
               (path (when (and opts (eng:js-object-p opts))
                       (%fmt-js-string (eng:js-get opts "filepath"))))
               (fo (%fmt-options-from-js opts))
               (formatted (clun.fmt:format-source source :path path :options fo)))
          (eng:js-boolean (string= source formatted))))))
    (eng:data-prop
     fn "file"
     (eng:make-native-function
      "file" 1
      (lambda (this args)
        (declare (ignore this))
        (let* ((path (%fmt-js-string (eng:arg args 0)))
               (opts (eng:arg args 1))
               (write (when (and opts (eng:js-object-p opts))
                        (%fmt-js-bool (eng:js-get opts "write") nil)))
               (fo (%fmt-options-from-js opts)))
          (unless path
            (eng:throw-type-error "Clun.format.file requires a path"))
          (multiple-value-bind (text changed)
              (clun.fmt:format-file path :options fo :write write)
            (let ((o (eng:new-object)))
              (eng:data-prop o "formatted" text)
              (eng:data-prop o "changed" (eng:js-boolean changed))
              o))))))
    (eng:data-prop fn "version" "1")
    fn))

(defun make-clun-lint ()
  "Clun.lint(source, opts?) function object with .file / .rules / .version."
  (let ((fn (eng:make-native-function
             "lint" 1
             (lambda (this args)
               (declare (ignore this))
               (let* ((source (%fmt-js-string (eng:arg args 0)))
                      (opts (eng:arg args 1))
                      (path (or (when (and opts (eng:js-object-p opts))
                                  (%fmt-js-string (eng:js-get opts "filepath")))
                                "<eval>")))
                 (unless source
                   (eng:throw-type-error "Clun.lint requires a source string"))
                 (handler-case
                     (%diags->js-array
                      (clun.lint:lint-source source :path path))
                   (clun.lint:lint-error (e)
                     (eng:throw-native-error :error (clun.lint:lint-error-message e)))
                   (error (e)
                     (eng:throw-native-error :error (princ-to-string e)))))))))
    (eng:data-prop
     fn "file"
     (eng:make-native-function
      "file" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((path (%fmt-js-string (eng:arg args 0))))
          (unless path
            (eng:throw-type-error "Clun.lint.file requires a path"))
          (%diags->js-array (clun.lint:lint-file path))))))
    (eng:data-prop
     fn "rules"
     (eng:make-native-function
      "rules" 0
      (lambda (this args)
        (declare (ignore this args))
        (eng:new-array
         (mapcar (lambda (pair)
                   (let ((o (eng:new-object)))
                     (eng:data-prop o "id" (car pair))
                     (eng:data-prop o "severity"
                                    (string-downcase (symbol-name (cdr pair))))
                     o))
                 clun.lint:*recommended-rules*)))))
    (eng:data-prop fn "version" "1")
    fn))

(defun install-clun-fmt-lint (clun g)
  "Install Clun.format and Clun.lint on the Clun object."
  (declare (ignore g))
  (eng:nonconfigurable-data-prop clun "format" (make-clun-format))
  (eng:nonconfigurable-data-prop clun "lint" (make-clun-lint))
  clun)
