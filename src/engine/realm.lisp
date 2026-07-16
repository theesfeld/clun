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
(defun fixed-data-prop (obj key value)
  (obj-set-desc obj key (data-pd value :writable nil :enumerable t :configurable nil)))
(defun hidden-prop (obj key value)
  (obj-set-desc obj key (data-pd value :writable t :enumerable nil :configurable t)))
(defun nonconfigurable-data-prop (obj key value)
  "Define a writable, enumerable, non-configurable data property."
  (obj-set-desc obj key (data-pd value :writable t :enumerable t :configurable nil)))

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
            (integer (make-wrapper :bigint-prototype :bigint v))
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

(defun make-wrapper (proto-key class primitive &optional proto)
  (let ((o (js-make-object (or proto (intrinsic proto-key)) class)))
    (obj-set-desc o "%primitive%" (data-pd primitive :writable nil :enumerable nil :configurable nil))
    o))
(defun wrapper-primitive (o) (pd-value (obj-own-desc o "%primitive%")))

(defun make-string-object (s &optional proto)
  (let ((o (make-wrapper :string-prototype :string s proto)))
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
      (def :object-prototype (%make-js-immutable-prototype-object :proto +null+))
      (def :function-prototype
           (%make-native-function :fn (lambda (this args) (declare (ignore this args)) +undefined+)
                                  :proto (intrinsic :object-prototype) :fname "" :param-count 0))
      (bootstrap-well-known-symbols)
      (install-conversion-hooks)
      (bootstrap-function-prototype)
      (bootstrap-object)
      ;; %AsyncFunction% inherits from the Function constructor, so construct
      ;; Function once as a realm intrinsic before the async intrinsic family.
      (bootstrap-function-constructor)
      (bootstrap-array)
      (bootstrap-errors)
      (bootstrap-primitives)
      (bootstrap-bigint)            ; BigInt reflective surface (Phase 11); needs primitives
      (bootstrap-symbol)
      (bootstrap-iterator)          ; needs Array/String prototypes
      (bootstrap-generator)         ; needs %IteratorPrototype%
      (bootstrap-promise)
      (bootstrap-async)             ; %AsyncIteratorPrototype% + %AsyncGeneratorPrototype%
      (bootstrap-reflect)
      (bootstrap-object-extra)
      (bootstrap-array-extra)
      (bootstrap-number-extra)
      (bootstrap-string-extra)
      (bootstrap-symbol-extra)
      (bootstrap-map)               ; collections need the iterator prototypes
      (bootstrap-set)
      (bootstrap-weakmap)
      (bootstrap-weakset)
      (bootstrap-date)
      (bootstrap-math)
      (bootstrap-json)
      (bootstrap-binary)            ; ArrayBuffer/TypedArray/DataView/Text codecs (Phase 11)
      (bootstrap-global)
      (bootstrap-regexp)            ; RegExp (Phase 10); needs the global + re-installs String regex methods
      (bootstrap-global-extra)
      (bootstrap-async-globals))    ; Promise + timers/microtask/nextTick globals
    *realm*))

(defparameter *well-known-symbol-names*
  ;; keyword → the spec [[Description]] tail (camelCase, per the Well-Known Symbols table).
  '((:iterator . "iterator") (:async-iterator . "asyncIterator")
    (:to-primitive . "toPrimitive") (:has-instance . "hasInstance")
    (:to-string-tag . "toStringTag") (:is-concat-spreadable . "isConcatSpreadable")
    (:species . "species") (:match . "match") (:match-all . "matchAll")
    (:replace . "replace") (:search . "search") (:split . "split")
    (:unscopables . "unscopables")))

(defun bootstrap-well-known-symbols ()
  (loop for (k . name) in *well-known-symbol-names* do
    (setf (gethash k *well-known-symbols*)
          (%make-js-symbol :description (format nil "Symbol.~a" name) :well-known k))))

(defun bootstrap-function-prototype ()
  (let ((fp (intrinsic :function-prototype)))
    ;; Function.prototype is itself a callable built-in created before the normal
    ;; native-function helper can run. Finish its standard own surface here.
    (obj-set-desc fp "length" (data-pd 0d0 :writable nil :enumerable nil :configurable t))
    (obj-set-desc fp "name" (data-pd "" :writable nil :enumerable nil :configurable t))
    (let ((thrower
            (make-native-function "" 0
              (lambda (this args)
                (declare (ignore this args))
                (throw-type-error "restricted function property")))))
      ;; %ThrowTypeError% is shared by every restricted accessor in the realm.
      ;; Its length is non-configurable and the function is not extensible.
      (setf (pd-configurable (obj-own-desc thrower "length")) nil
            (realm-intrinsic *realm* :throw-type-error) thrower)
      (jm-prevent-extensions thrower)
      (obj-set-desc fp "caller"
                    (accessor-pd thrower thrower :enumerable nil :configurable t))
      (obj-set-desc fp "arguments"
                    (accessor-pd thrower thrower :enumerable nil :configurable t)))
    (install-method fp "call" 1
      (lambda (this args) (js-call this (arg args 0) (if args (rest args) '()))))
    (install-method fp "apply" 2
      (lambda (this args)
        (let ((array-arg (arg args 1)))
          (js-call this (arg args 0)
                   (cond ((js-nullish-p array-arg) '())
                         ((js-object-p array-arg) (array-like->list array-arg))
                         (t (throw-type-error "CreateListFromArrayLike called on non-object")))))))
    (install-method fp "bind" 1
      (lambda (this args)
        (make-bound-function this (arg args 0) (if args (rest args) '()))))
    (install-method fp "toString" 0
      (lambda (this args) (declare (ignore args))
        (unless (callable-p this)
          (throw-type-error "Function.prototype.toString called on incompatible receiver"))
        (if (and (js-function-p this) (js-function-source-text this))
            (js-function-source-text this)
            (format nil "function ~a() { [native code] }"
                    (native-function-property-name this)))))
    (obj-set-desc fp (well-known :has-instance)
                  (data-pd (make-native-function "[Symbol.hasInstance]" 1
                             (lambda (this args) (js-boolean (ordinary-has-instance this (arg args 0)))))
                           :writable nil :enumerable nil :configurable nil))))

(defun function-name (f)
  (cond ((js-function-p f) (js-function-fname f))
        ((js-native-function-p f) (js-native-function-fname f))
        ((js-bound-function-p f) (js-bound-function-fname f))
        (t "")))

(defun ascii-identifier-name-p (name)
  "Recognize the conservative ASCII subset of ECMAScript IdentifierName."
  (labels ((letter-p (char)
             (or (char<= #\A char #\Z) (char<= #\a char #\z)))
           (start-p (char)
             (or (letter-p char) (char= char #\_) (char= char #\$)))
           (part-p (char)
             (or (start-p char) (char<= #\0 char #\9))))
    (and (stringp name)
         (plusp (length name))
         (start-p (char name 0))
         (loop for char across name always (part-p char)))))

(defun native-symbol-property-name-p (name)
  "Recognize the well-known-symbol spelling used by native built-ins."
  (let ((length (and (stringp name) (length name))))
    (and length (> length 9)
         (string= name "[Symbol." :end1 8)
         (char= (char name (1- length)) #\])
         (ascii-identifier-name-p (subseq name 8 (1- length))))))

(defun native-function-property-name (function)
  "Return a NativeFunction-grammar property name, or the empty optional name.
Internal callable names are not source text: bound names contain spaces and
must not be interpolated into a syntactically invalid native representation."
  (let ((name (function-name function)))
    (labels ((property-name-p (candidate)
               (or (ascii-identifier-name-p candidate)
                   (native-symbol-property-name-p candidate))))
      (cond
        ((property-name-p name) name)
        ((and (> (length name) 4)
              (or (string= name "get " :end1 4)
                  (string= name "set " :end1 4))
              (property-name-p (subseq name 4)))
         name)
        (t "")))))

(defun array-like->list (o)
  (let ((len (length-of-array-like o)))    ; ToLength: NaN-safe (never traps on `floor`)
    (loop for i below len collect (js-getv o (princ-to-string i)))))

(defun nt-prototype (new-target default-proto)
  "OrdinaryCreateFromConstructor's [[Prototype]]: NEW-TARGET's .prototype when it is an
object (a subclass instance), else DEFAULT-PROTO. For a base `new X()` new-target is X
itself, so this returns X.prototype = DEFAULT-PROTO — subclassing changes nothing else."
  (let ((p (and (js-object-p new-target) (js-get new-target "prototype"))))
    (if (js-object-p p) p default-proto)))

;;; forward decls filled below
(defun bootstrap-object () (%bootstrap-object))
(defun bootstrap-function-constructor () (%bootstrap-function-constructor))
(defun bootstrap-array () (%bootstrap-array))
(defun bootstrap-errors () (%bootstrap-errors))
(defun bootstrap-primitives () (%bootstrap-primitives))
(defun bootstrap-bigint () (%bootstrap-bigint))
(defun bootstrap-symbol () (%bootstrap-symbol))
(defun bootstrap-iterator () (%bootstrap-iterator))
(defun bootstrap-generator () (%bootstrap-generator))
(defun bootstrap-promise () (%bootstrap-promise))
(defun bootstrap-async () (%bootstrap-async))
(defun bootstrap-async-globals () (%bootstrap-async-globals))
(defun bootstrap-reflect () (%bootstrap-reflect))
(defun bootstrap-object-extra () (%bootstrap-object-extra))
(defun bootstrap-array-extra () (%bootstrap-array-extra))
(defun bootstrap-number-extra () (%bootstrap-number-extra))
(defun bootstrap-string-extra () (%bootstrap-string-extra))
(defun bootstrap-regexp () (%bootstrap-regexp))
(defun bootstrap-symbol-extra () (%bootstrap-symbol-extra))
(defun bootstrap-map () (%bootstrap-map))
(defun bootstrap-set () (%bootstrap-set))
(defun bootstrap-weakmap () (%bootstrap-weakmap))
(defun bootstrap-weakset () (%bootstrap-weakset))
(defun bootstrap-date () (%bootstrap-date))
(defun bootstrap-math () (%bootstrap-math))
(defun bootstrap-json () (%bootstrap-json))
(defun bootstrap-binary () (%bootstrap-binary))
(defun bootstrap-global () (%bootstrap-global))
(defun bootstrap-global-extra () (%bootstrap-global-extra))
