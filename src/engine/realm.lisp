;;;; realm.lisp — realm bootstrap: intrinsics, global object, core built-ins
;;;; (PLAN.md Phase 03, §7). Everything is implemented in CL against the object API
;;;; (purity contract — no JS in the implementation). Phase 04 grows the breadth;
;;;; Phase 03 wires the minimum to run the test262 harness and the curated slice.

(in-package :clun.engine)

(declaim (inline arg))
(defun arg (args n) (if (< n (length args)) (nth n args) +undefined+))

(defun well-known (key) (gethash key *well-known-symbols*))

;;; --- object/array/value construction helpers (use *realm*) -----------------

(defun new-object (&optional (proto (intrinsic :object-prototype)))
  (js-make-object proto))
(defun new-array (&optional (elements '()))
  (array-of (intrinsic :array-prototype) elements))
(defun data-prop (obj key value)
  (obj-set-desc obj key (data-pd value :writable t :enumerable t :configurable t)))
(defun hidden-prop (obj key value)
  (obj-set-desc obj key (data-pd value :writable t :enumerable nil :configurable t)))

;;; --- ToPrimitive / ToObject / error hooks -----------------------------------

(defun ordinary-to-primitive (o hint)
  (dolist (name (if (eq hint :string) '("toString" "valueOf") '("valueOf" "toString"))
                (throw-type-error "cannot convert object to a primitive value"))
    (let ((m (js-get o name)))
      (when (callable-p m)
        (let ((r (js-call m o '())))
          (unless (js-object-p r) (return r)))))))

(defun install-conversion-hooks ()
  (setf *ordinary-to-primitive*
        (lambda (o hint)
          (let ((exotic (get-method o (well-known :to-primitive))))
            (if (js-undefined-p exotic)
                (ordinary-to-primitive o (if (eq hint :default) :number hint))
                (let ((r (js-call exotic o (list (ecase hint (:string "string")
                                                              (:number "number")
                                                              (:default "default"))))))
                  (if (js-object-p r) (throw-type-error "@@toPrimitive returned an object") r))))))
  (setf *to-object-hook*
        (lambda (v)
          (typecase v
            (double-float (make-wrapper :number-prototype :number v))
            (string (make-string-object v))
            (js-symbol (make-wrapper :symbol-prototype :symbol v))
            (t (cond ((js-boolean-p v) (make-wrapper :boolean-prototype :boolean v))
                     (t (throw-type-error "cannot convert to object")))))))
  (setf *make-error-object*
        (lambda (kind message)
          (make-error-object (ecase kind (:type-error :type-error-prototype)
                                         (:range-error :range-error-prototype)
                                         (:syntax-error :syntax-error-prototype)
                                         (:reference-error :reference-error-prototype)
                                         (:error :error-prototype))
                             (js-native-error-name kind) message))))

(defun make-wrapper (proto-key class primitive)
  (let ((o (js-make-object (intrinsic proto-key) class)))
    (obj-set-desc o "%primitive%" (data-pd primitive :writable nil :enumerable nil :configurable nil))
    o))
(defun wrapper-primitive (o) (pd-value (obj-own-desc o "%primitive%")))

(defun make-string-object (s)
  (let ((o (make-wrapper :string-prototype :string s)))
    (obj-set-desc o "length" (data-pd (coerce (length s) 'double-float)
                                      :writable nil :enumerable nil :configurable nil))
    (dotimes (i (length s))
      (obj-set-desc o (princ-to-string i)
                    (data-pd (string (char s i)) :writable nil :enumerable t :configurable nil)))
    o))

;;; --- Error objects ----------------------------------------------------------

(defun make-error-object (proto-key name message)
  (let ((e (js-make-object (intrinsic proto-key) :error)))
    (unless (js-undefined-p message)
      (hidden-prop e "message" (if (stringp message) message (to-string message))))
    (hidden-prop e "stack" (format nil "~a: ~a" name (if (js-undefined-p message) "" message)))
    e))

;;; --- descriptor <-> object (Object.defineProperty support) -----------------

(defun to-property-descriptor (obj)
  (unless (js-object-p obj) (throw-type-error "property descriptor must be an object"))
  (let ((d (make-prop-desc)))
    (when (has-property obj "enumerable") (setf (pd-enumerable d) (js-truthy (js-get obj "enumerable"))))
    (when (has-property obj "configurable") (setf (pd-configurable d) (js-truthy (js-get obj "configurable"))))
    (when (has-property obj "value") (setf (pd-value d) (js-get obj "value")))
    (when (has-property obj "writable") (setf (pd-writable d) (js-truthy (js-get obj "writable"))))
    (when (has-property obj "get")
      (let ((g (js-get obj "get")))
        (when (and (not (js-undefined-p g)) (not (callable-p g)))
          (throw-type-error "getter must be callable"))
        (setf (pd-get d) g)))
    (when (has-property obj "set")
      (let ((s (js-get obj "set")))
        (when (and (not (js-undefined-p s)) (not (callable-p s)))
          (throw-type-error "setter must be callable"))
        (setf (pd-set d) s)))
    (when (and (or (pd-set-p (pd-get d)) (pd-set-p (pd-set d)))
               (or (pd-set-p (pd-value d)) (pd-set-p (pd-writable d))))
      (throw-type-error "descriptor may not be both accessor and data"))
    d))

(defun from-property-descriptor (desc)
  (if (null desc)
      +undefined+
      (let ((o (new-object)))
        (if (data-descriptor-p desc)
            (progn (data-prop o "value" (defaulted (pd-value desc) +undefined+))
                   (data-prop o "writable" (js-boolean (defaulted (pd-writable desc) nil))))
            (progn (data-prop o "get" (defaulted (pd-get desc) +undefined+))
                   (data-prop o "set" (defaulted (pd-set desc) +undefined+))))
        (data-prop o "enumerable" (js-boolean (defaulted (pd-enumerable desc) nil)))
        (data-prop o "configurable" (js-boolean (defaulted (pd-configurable desc) nil)))
        o)))

;;; --- the bootstrap ----------------------------------------------------------

(defun make-realm ()
  (let ((*realm* (%make-realm)))
    (macrolet ((def (key val) `(setf (realm-intrinsic *realm* ,key) ,val)))
      ;; Object.prototype and Function.prototype are mutually referential.
      (def :object-prototype (make-js-object :proto +null+))
      (def :function-prototype
           (%make-native-function :fn (lambda (this args) (declare (ignore this args)) +undefined+)
                                  :proto (intrinsic :object-prototype) :fname "" :param-count 0))
      (bootstrap-well-known-symbols)
      (install-conversion-hooks)
      (bootstrap-function-prototype)
      (bootstrap-object)
      (bootstrap-array)
      (bootstrap-errors)
      (bootstrap-primitives)
      (bootstrap-symbol)
      (bootstrap-global))
    *realm*))

(defun bootstrap-well-known-symbols ()
  (dolist (k '(:iterator :async-iterator :to-primitive :has-instance :to-string-tag
               :is-concat-spreadable :species :match :replace :search :split :unscopables))
    (setf (gethash k *well-known-symbols*)
          (%make-js-symbol :description (format nil "Symbol.~a"
                                                (string-downcase (symbol-name k)))
                           :well-known k))))

(defun bootstrap-function-prototype ()
  (let ((fp (intrinsic :function-prototype)))
    (install-method fp "call" 1
      (lambda (this args) (js-call this (arg args 0) (if args (rest args) '()))))
    (install-method fp "apply" 2
      (lambda (this args)
        (let ((array-arg (arg args 1)))
          (js-call this (arg args 0)
                   (if (js-nullish-p array-arg) '() (array-like->list array-arg))))))
    (install-method fp "bind" 1
      (lambda (this args)
        (let ((target this) (bound-this (arg args 0)) (bound-args (if args (rest args) '())))
          (make-native-function "bound" 0
            (lambda (call-this call-args) (declare (ignore call-this))
              (js-call target bound-this (append bound-args call-args)))
            :construct (lambda (cargs nt) (declare (ignore nt))
                         (js-construct target (append bound-args cargs)))))))
    (install-method fp "toString" 0
      (lambda (this args) (declare (ignore args))
        (format nil "function ~a() { [native code] }"
                (if (callable-p this) (function-name this) ""))))
    (obj-set-desc fp (well-known :has-instance)
                  (data-pd (make-native-function "[Symbol.hasInstance]" 1
                             (lambda (this args) (js-boolean (ordinary-has-instance this (arg args 0)))))
                           :writable nil :enumerable nil :configurable nil))))

(defun function-name (f)
  (cond ((js-function-p f) (js-function-fname f))
        ((js-native-function-p f) (js-native-function-fname f))
        (t "")))

(defun array-like->list (o)
  (let ((len (floor (max 0 (to-number (js-getv o "length"))))))
    (loop for i below len collect (js-getv o (princ-to-string i)))))

;;; forward decls filled below
(defun bootstrap-object () (%bootstrap-object))
(defun bootstrap-array () (%bootstrap-array))
(defun bootstrap-errors () (%bootstrap-errors))
(defun bootstrap-primitives () (%bootstrap-primitives))
(defun bootstrap-symbol () (%bootstrap-symbol))
(defun bootstrap-global () (%bootstrap-global))
