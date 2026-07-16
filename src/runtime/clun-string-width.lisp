;;;; clun-string-width.lisp — the public Clun.stringWidth bridge.

(in-package :clun.runtime)

(defun %string-width-option (options key)
  "Get KEY without inheriting from Object.prototype, preserving a getter's receiver."
  (loop with object-prototype = (eng:intrinsic :object-prototype)
        with current = options
        do (when (eng::jm-get-own-property current key)
             (return (eng::jm-get current key options)))
           (let ((parent (eng::jm-get-prototype-of current)))
             ;; An explicitly supplied Object.prototype remains observable;
             ;; only an inherited traversal stops before reaching it.
             (when (or (not (eng:js-object-p parent))
                       (eq parent object-prototype))
               (return eng:+undefined+))
             (setf current parent))))

(defun %string-width-option-boolean (value default)
  ;; Bun's option parser leaves the default unchanged for nullish values and
  ;; the empty string. Every other value receives ordinary ToBoolean semantics.
  (cond
    ((eng:js-nullish-p value) default)
    ((and (stringp value) (zerop (length value))) default)
    (t (eng:js-truthy value))))

(defun %string-width-to-string (input)
  "Apply ToString while preserving Bun's exact Symbol conversion error."
  (let ((primitive (if (eng:js-object-p input)
                       (eng:to-primitive input :string)
                       input)))
    (when (eng:js-symbol-p primitive)
      (eng:throw-type-error "Cannot convert a symbol to a string"))
    (eng:to-string primitive)))

(defun %make-clun-string-width ()
  (eng:make-native-function
   "stringWidth" 2
   (lambda (this args)
     (declare (ignore this))
     (let ((input (eng:arg args 0)))
       (if (eng:js-undefined-p input)
           0d0
           (let ((string (%string-width-to-string input)))
             ;; This precedes all option access in Bun, including getters.
             (if (zerop (length string))
                 0d0
                 (let ((count-ansi-escape-codes nil)
                       (ambiguous-is-narrow t)
                       (options (eng:arg args 1)))
                   (when (eng:js-object-p options)
                     (setf count-ansi-escape-codes
                           (%string-width-option-boolean
                            (%string-width-option options "countAnsiEscapeCodes")
                            count-ansi-escape-codes)
                           ambiguous-is-narrow
                           (%string-width-option-boolean
                            (%string-width-option options "ambiguousIsNarrow")
                            ambiguous-is-narrow)))
                   (coerce
                    (clun.text.string-width:string-width
                     string
                     :count-ansi-escape-codes count-ansi-escape-codes
                     :ambiguous-is-narrow ambiguous-is-narrow)
                    'double-float)))))))))

(defun install-clun-string-width (clun)
  "Install Bun-shaped Clun.stringWidth: writable/enumerable/non-configurable."
  (eng::obj-set-desc
   clun "stringWidth"
   (eng::data-pd (%make-clun-string-width)
                 :writable t :enumerable t :configurable nil))
  clun)
