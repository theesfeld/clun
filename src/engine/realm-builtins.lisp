;;;; realm-builtins.lisp — the individual intrinsic objects (PLAN.md Phase 03).
;;;; Object/Function/Array/Error/Boolean/Number/String/Symbol + the global object.
;;;; Minimum breadth to run the test262 harness and the curated slice; Phase 04 grows it.

(in-package :clun.engine)

(defun make-constructor (name arity call-fn &key construct-fn prototype)
  "A constructor native function with .prototype wired to PROTOTYPE."
  (let ((ctor (make-native-function name arity call-fn
                                    :construct (or construct-fn
                                                   (lambda (args nt) (declare (ignore args nt))
                                                     (throw-type-error
                                                      (format nil "~a is not a constructor" name)))))))
    (when prototype
      (obj-set-desc ctor "prototype" (data-pd prototype :writable nil :enumerable nil :configurable nil))
      (obj-set-desc prototype "constructor" (data-pd ctor :writable t :enumerable nil :configurable t)))
    ctor))

;;; --- Object -----------------------------------------------------------------

(defun %bootstrap-object ()
  (let ((op (intrinsic :object-prototype)))
    (install-method op "hasOwnProperty" 1
      (lambda (this args) (js-boolean (has-own-property (to-object this) (to-property-key (arg args 0))))))
    (install-method op "isPrototypeOf" 1
      (lambda (this args)
        (let ((v (arg args 0)))
          (if (not (js-object-p v)) +false+
              (let ((o (to-object this)))
                (loop for p = (jm-get-prototype-of v) then (jm-get-prototype-of p)
                      while (js-object-p p) when (eq p o) do (return +true+)
                      finally (return +false+)))))))
    (install-method op "propertyIsEnumerable" 1
      (lambda (this args)
        (let ((d (jm-get-own-property (to-object this) (to-property-key (arg args 0)))))
          (js-boolean (and d (eq (pd-enumerable d) t))))))
    (install-method op "toString" 0
      (lambda (this args) (declare (ignore args))
        (cond ((js-undefined-p this) "[object Undefined]")
              ((js-null-p this) "[object Null]")
              (t (let* ((o (to-object this))
                        ;; builtin tag from the brand (§20.1.3.6), then @@toStringTag override
                        (builtin (cond ((is-array o) "Array")
                                       ((eq (js-object-class o) :arguments) "Arguments")
                                       ((callable-p o) "Function")
                                       ((eq (js-object-class o) :error) "Error")
                                       ((eq (js-object-class o) :boolean) "Boolean")
                                       ((eq (js-object-class o) :number) "Number")
                                       ((eq (js-object-class o) :string) "String")
                                       ((eq (js-object-class o) :date) "Date")
                                       (t "Object")))
                        (tag (js-get o (well-known :to-string-tag))))
                   (format nil "[object ~a]" (if (stringp tag) tag builtin)))))))
    (install-method op "valueOf" 0 (lambda (this args) (declare (ignore args)) (to-object this)))
    (install-method op "toLocaleString" 0
      (lambda (this args) (declare (ignore args)) (js-call (js-get (to-object this) "toString") this '())))
    (let ((object-ctor
            (make-constructor "Object" 1
              (lambda (this args) (declare (ignore this))
                (let ((v (arg args 0))) (if (js-nullish-p v) (new-object) (to-object v))))
              :prototype op
              :construct-fn (lambda (args nt)
                              (let ((v (arg args 0)))
                                (if (js-nullish-p v)
                                    (js-make-object (nt-prototype nt (intrinsic :object-prototype)))
                                    (to-object v)))))))
      (macrolet ((m (name arity &body body) `(install-method object-ctor ,name ,arity ,@body)))
        (m "defineProperty" 3
           (lambda (this args) (declare (ignore this))
             (let ((o (arg args 0)))
               (unless (js-object-p o) (throw-type-error "Object.defineProperty called on non-object"))
               (define-property-or-throw o (to-property-key (arg args 1))
                                         (to-property-descriptor (arg args 2)))
               o)))
        (m "getOwnPropertyDescriptor" 2
           (lambda (this args) (declare (ignore this))
             (from-property-descriptor
              (jm-get-own-property (to-object (arg args 0)) (to-property-key (arg args 1))))))
        (m "getPrototypeOf" 1
           (lambda (this args) (declare (ignore this)) (jm-get-prototype-of (to-object (arg args 0)))))
        (m "setPrototypeOf" 2
           (lambda (this args) (declare (ignore this))
             (let ((o (arg args 0)) (p (arg args 1)))
               (when (js-object-p o)
                 (unless (or (js-object-p p) (js-null-p p))
                   (throw-type-error "prototype must be an object or null"))
                 (unless (jm-set-prototype-of o p) (throw-type-error "cannot set prototype")))
               o)))
        (m "getOwnPropertyNames" 1
           (lambda (this args) (declare (ignore this))
             (new-array (remove-if #'js-symbol-p (jm-own-property-keys (to-object (arg args 0)))))))
        (m "keys" 1
           (lambda (this args) (declare (ignore this)) (new-array (enum-own-keys (to-object (arg args 0)) :key))))
        (m "values" 1
           (lambda (this args) (declare (ignore this)) (new-array (enum-own-keys (to-object (arg args 0)) :value))))
        (m "entries" 1
           (lambda (this args) (declare (ignore this)) (new-array (enum-own-keys (to-object (arg args 0)) :entry))))
        (m "create" 2
           (lambda (this args) (declare (ignore this))
             (let ((proto (arg args 0)))
               (unless (or (js-object-p proto) (js-null-p proto))
                 (throw-type-error "Object.create proto must be object or null"))
               (let ((o (js-make-object proto)))
                 (unless (js-undefined-p (arg args 1)) (object-define-properties o (arg args 1)))
                 o))))
        (m "defineProperties" 2
           (lambda (this args) (declare (ignore this)) (object-define-properties (arg args 0) (arg args 1))))
        (m "freeze" 1
           (lambda (this args) (declare (ignore this))
             (let ((o (arg args 0)))
               (when (and (js-object-p o) (not (set-integrity-level o :frozen)))
                 (throw-type-error "cannot freeze object"))
               o)))
        (m "isFrozen" 1
           (lambda (this args) (declare (ignore this))
             (let ((o (arg args 0)))
               (if (js-object-p o)
                   (js-boolean (test-integrity-level o :frozen))
                   +true+))))
        (m "seal" 1
           (lambda (this args) (declare (ignore this))
             (let ((o (arg args 0)))
               (when (and (js-object-p o) (not (set-integrity-level o :sealed)))
                 (throw-type-error "cannot seal object"))
               o)))
        (m "isSealed" 1
           (lambda (this args) (declare (ignore this))
             (let ((o (arg args 0)))
               (if (js-object-p o)
                   (js-boolean (test-integrity-level o :sealed))
                   +true+))))
        (m "preventExtensions" 1
           (lambda (this args) (declare (ignore this))
             (let ((o (arg args 0)))
               (when (and (js-object-p o) (not (jm-prevent-extensions o)))
                 (throw-type-error "cannot prevent extensions"))
               o)))
        (m "isExtensible" 1
           (lambda (this args) (declare (ignore this))
             (let ((o (arg args 0))) (js-boolean (and (js-object-p o) (jm-is-extensible o))))))
        (m "assign" 2
           (lambda (this args) (declare (ignore this))
             (let ((target (to-object (arg args 0))))
               (dolist (src (rest args) target)
                 (unless (js-nullish-p src)
                   (let ((from (to-object src)))
                     (dolist (k (jm-own-property-keys from))
                       (let ((d (jm-get-own-property from k)))
                         (when (and d (eq (pd-enumerable d) t))
                           (js-set target k (js-get from k) t))))))))))
        (m "getOwnPropertySymbols" 1
           (lambda (this args) (declare (ignore this))
             (new-array (remove-if-not #'js-symbol-p (jm-own-property-keys (to-object (arg args 0))))))))
      (setf (realm-intrinsic *realm* :object-constructor) object-ctor))))

(defun enum-own-keys (o mode)
  (loop for k in (jm-own-property-keys o)
        for d = (and (stringp k) (jm-get-own-property o k))
        when (and d (eq (pd-enumerable d) t))
        collect (ecase mode (:key k) (:value (js-get o k))
                       (:entry (new-array (list k (js-get o k)))))))

(defun object-define-properties (o props)
  (unless (js-object-p o) (throw-type-error "Object.defineProperties called on non-object"))
  (let ((props-obj (to-object props)))
    (dolist (k (jm-own-property-keys props-obj) o)
      (let ((d (jm-get-own-property props-obj k)))
        (when (and d (eq (pd-enumerable d) t))
          (define-property-or-throw o k (to-property-descriptor (js-get props-obj k))))))))

;;; --- Array ------------------------------------------------------------------

(defun %bootstrap-array ()
  (let ((ap (js-make-array (intrinsic :object-prototype))))
    (setf (realm-intrinsic *realm* :array-prototype) ap)
    (macrolet ((m (name arity &body body) `(install-method ap ,name ,arity ,@body)))
      (m "push" 1
         (lambda (this args)
           (let* ((o (to-object this)) (len (length-of-array-like o)))
             (dolist (v args) (js-set o (princ-to-string len) v t) (incf len))
             (js-set o "length" (coerce len 'double-float) t)
             (coerce len 'double-float))))
      (m "pop" 0
         (lambda (this args) (declare (ignore args))
           (let* ((o (to-object this)) (len (length-of-array-like o)))
             (if (zerop len) (progn (js-set o "length" 0d0 t) +undefined+)
                 (let* ((i (1- len)) (v (js-getv o (princ-to-string i))))
                   (jm-delete o (princ-to-string i))
                   (js-set o "length" (coerce i 'double-float) t) v)))))
      (m "join" 1
         (lambda (this args)
           (let* ((o (to-object this)) (len (length-of-array-like o))
                  (sep (let ((s (arg args 0))) (if (js-undefined-p s) "," (to-string s)))))
             (with-output-to-string (out)
               (dotimes (i len)
                 (when (plusp i) (write-string sep out))
                 (let ((e (js-getv o (princ-to-string i))))
                   (unless (js-nullish-p e) (write-string (to-string e) out))))))))
      (m "indexOf" 1
         (lambda (this args)
           (let* ((o (to-object this)) (len (length-of-array-like o)) (target (arg args 0)))
             (coerce (or (loop for i below len
                               when (and (has-property o (princ-to-string i))
                                         (js-strict-eq (js-getv o (princ-to-string i)) target))
                               do (return i))
                         -1) 'double-float))))
      (m "includes" 1
         (lambda (this args)
           (let* ((o (to-object this)) (len (length-of-array-like o)) (target (arg args 0)))
             (js-boolean (loop for i below len
                               thereis (js-same-value-zero (js-getv o (princ-to-string i)) target))))))
      (m "slice" 2
         (lambda (this args)
           (let* ((o (to-object this)) (len (length-of-array-like o))
                  (start (clamp-index (arg args 0) len 0)) (end (clamp-index (arg args 1) len len)))
             (new-array (loop for i from start below end collect (js-getv o (princ-to-string i)))))))
      (m "forEach" 1
         (lambda (this args)
           (let* ((o (to-object this)) (len (length-of-array-like o))
                  (f (arg args 0)) (that (arg args 1)))
             (dotimes (i len +undefined+)
               (when (has-property o (princ-to-string i))
                 (js-call f that (list (js-getv o (princ-to-string i)) (coerce i 'double-float) o)))))))
      (m "map" 1
         (lambda (this args)
           (let* ((o (to-object this)) (len (length-of-array-like o))
                  (f (arg args 0)) (that (arg args 1)))
             (new-array (loop for i below len
                              collect (js-call f that (list (js-getv o (princ-to-string i))
                                                            (coerce i 'double-float) o)))))))
      (m "concat" 1
         (lambda (this args)
           (let ((result '()))
             (dolist (item (cons (to-object this) args))
               (if (is-array item)
                   (dotimes (i (length-of-array-like item))
                     (push (js-getv item (princ-to-string i)) result))
                   (push item result)))
             (new-array (nreverse result)))))
      (m "toString" 0
         (lambda (this args) (declare (ignore args))
           (js-call (js-get (intrinsic :array-prototype) "join") this '()))))
    (let ((array-ctor
            (make-constructor "Array" 1
              (lambda (this args) (declare (ignore this)) (array-constructor args))
              :prototype ap
              :construct-fn (lambda (args nt) (array-constructor args nt)))))
      (install-method array-ctor "isArray" 1
        (lambda (this args) (declare (ignore this)) (js-boolean (is-array (arg args 0)))))
      (install-method array-ctor "of" 0
        (lambda (this args) (declare (ignore this)) (new-array args)))
      (setf (realm-intrinsic *realm* :array-constructor) array-ctor))))

(defun array-constructor (args &optional nt)
  (let ((proto (nt-prototype nt (intrinsic :array-prototype))))
    (if (and (= 1 (length args)) (js-number-p (first args)))
        (let ((n (double->uint32 (first args))))
          ;; NaN-safe: ToUint32(len) must equal len exactly, else RangeError.
          (unless (and (not (js-nan-p (first args))) (= (coerce n 'double-float) (first args)))
            (throw-range-error "invalid array length"))
          (js-make-array proto n))
        (array-of proto args))))

(defun clamp-index (v len default)
  (if (js-undefined-p v) default
      (let ((n (%int v)))
        (cond ((minusp n) (max 0 (+ len n))) (t (min n len))))))

;;; --- Errors -----------------------------------------------------------------

(defun %bootstrap-errors ()
  (let ((ep (js-make-object (intrinsic :object-prototype) :error)))
    (setf (realm-intrinsic *realm* :error-prototype) ep)
    (hidden-prop ep "name" "Error")
    (hidden-prop ep "message" "")
    (install-method ep "toString" 0
      (lambda (this args) (declare (ignore args))
        (unless (js-object-p this) (throw-type-error "Error.prototype.toString on non-object"))
        (let* ((name (let ((n (js-get this "name"))) (if (js-undefined-p n) "Error" (to-string n))))
               (msg (let ((m (js-get this "message"))) (if (js-undefined-p m) "" (to-string m)))))
          (cond ((string= msg "") name) ((string= name "") msg)
                (t (format nil "~a: ~a" name msg))))))
    (let ((error-ctor (make-error-constructor "Error" ep)))
      (setf (realm-intrinsic *realm* :error-constructor) error-ctor)
      (install-method error-ctor "isError" 1
        (lambda (this args)
          (declare (ignore this))
          (let ((value (arg args 0)))
            (js-boolean
             (and (js-object-p value)
                  (not (js-proxy-p value))
                  (eq (js-object-class value) :error))))))
      (dolist (spec '(("TypeError" :type-error-prototype :type-error-constructor)
                      ("RangeError" :range-error-prototype :range-error-constructor)
                      ("SyntaxError" :syntax-error-prototype :syntax-error-constructor)
                      ("ReferenceError" :reference-error-prototype :reference-error-constructor)
                      ("EvalError" :eval-error-prototype :eval-error-constructor)
                      ("URIError" :uri-error-prototype :uri-error-constructor)))
        (destructuring-bind (name proto-key ctor-key) spec
          (let ((proto (js-make-object ep :error)))
            (hidden-prop proto "name" name)
            (hidden-prop proto "message" "")
            (setf (realm-intrinsic *realm* proto-key) proto)
            (let ((ctor (make-error-constructor name proto)))
              (obj-set-desc ctor "prototype" (data-pd proto :writable nil :enumerable nil :configurable nil))
              (setf (realm-intrinsic *realm* ctor-key) ctor))))))))

(defun make-error-constructor (name proto)
  (make-constructor name 1
    (lambda (this args) (declare (ignore this)) (build-error proto args))
    :prototype proto
    :construct-fn (lambda (args nt) (build-error proto args nt))))

(defun build-error (proto args &optional nt)
  "NewError: message + ES2022 options.cause (InstallErrorCause, §20.5.8.1)."
  (let* ((e (js-make-object (nt-prototype nt proto) :error))
         (message (arg args 0)) (options (arg args 1))
         ;; coerce the message ONCE — a message object's toString is observable
         ;; (test262 built-ins/Error/constructor.js asserts the access sequence).
         (msg (unless (js-undefined-p message) (to-string message))))
    (when msg (hidden-prop e "message" msg))
    (when (and (js-object-p options) (has-property options "cause"))
      (hidden-prop e "cause" (js-get options "cause")))
    ;; `.stack` first line is "Name: message" (or just "Name" when no message),
    ;; matching V8/Node's stack header (Phase 08 has no frames yet).
    (let ((name (to-string (js-get proto "name"))))
      (hidden-prop e "stack" (if (and msg (plusp (length msg)))
                                 (format nil "~a: ~a" name msg)
                                 name)))
    e))

;;; --- Boolean / Number / String ---------------------------------------------

(defun symbol-descriptive-string (symbol)
  (format nil "Symbol(~a)"
          (let ((description (js-symbol-description symbol)))
            (if (js-undefined-p description) "" description))))

(defun %bootstrap-primitives ()
  ;; Boolean
  (let ((bp (make-wrapper-prototype :boolean-prototype :boolean +false+)))
    (install-method bp "valueOf" 0 (lambda (this args) (declare (ignore args)) (this-boolean this)))
    (install-method bp "toString" 0
      (lambda (this args) (declare (ignore args)) (if (eq (this-boolean this) +true+) "true" "false")))
    (setf (realm-intrinsic *realm* :boolean-constructor)
          (make-constructor "Boolean" 1 (lambda (this args) (declare (ignore this)) (to-boolean (arg args 0)))
                            :prototype bp
                            :construct-fn (lambda (args nt)
                                            (make-wrapper :boolean-prototype :boolean (to-boolean (arg args 0))
                                                          (nt-prototype nt (intrinsic :boolean-prototype)))))))
  ;; Number
  (let ((np (make-wrapper-prototype :number-prototype :number 0d0)))
    (install-method np "valueOf" 0 (lambda (this args) (declare (ignore args)) (this-number this)))
    (install-method np "toString" 0
      (lambda (this args) (declare (ignore args)) (number->js-string (this-number this))))
    (setf (realm-intrinsic *realm* :number-constructor)
          (let ((c (make-constructor "Number" 1
                     (lambda (this args) (declare (ignore this)) (if args (to-number (arg args 0)) 0d0))
                     :prototype np
                     :construct-fn (lambda (args nt)
                                     (make-wrapper :number-prototype :number (if args (to-number (arg args 0)) 0d0)
                                                   (nt-prototype nt (intrinsic :number-prototype)))))))
            (hidden-prop c "MAX_SAFE_INTEGER" 9007199254740991d0)
            (hidden-prop c "MIN_SAFE_INTEGER" -9007199254740991d0)
            (hidden-prop c "POSITIVE_INFINITY" +js-infinity+)
            (hidden-prop c "NEGATIVE_INFINITY" +js-neg-infinity+)
            (hidden-prop c "NaN" *js-nan*)
            (hidden-prop c "EPSILON" (expt 2d0 -52))
            (install-method c "isNaN" 1 (lambda (this args) (declare (ignore this)) (js-boolean (js-nan-p (arg args 0)))))
            (install-method c "isFinite" 1 (lambda (this args) (declare (ignore this)) (js-boolean (js-finite-p (arg args 0)))))
            (install-method c "isInteger" 1
              (lambda (this args) (declare (ignore this))
                (let ((v (arg args 0))) (js-boolean (and (js-number-p v) (js-finite-p v) (= v (ftruncate v)))))))
            c)))
  ;; String
  (let ((sp (make-wrapper-prototype :string-prototype :string "")))
    (install-method sp "valueOf" 0 (lambda (this args) (declare (ignore args)) (this-string this)))
    (install-method sp "toString" 0 (lambda (this args) (declare (ignore args)) (this-string this)))
    (install-method sp "charAt" 1
      (lambda (this args) (let ((s (this-string this)) (i (%int (arg args 0))))
                            (if (and (<= 0 i) (< i (length s))) (string (char s i)) ""))))
    (install-method sp "charCodeAt" 1
      (lambda (this args) (let ((s (this-string this)) (i (%int (arg args 0))))
                            (if (and (<= 0 i) (< i (length s))) (coerce (char-code (char s i)) 'double-float) *js-nan*))))
    (install-method sp "indexOf" 1
      (lambda (this args) (let ((s (this-string this)) (sub (to-string (arg args 0))))
                            (coerce (or (search sub s) -1) 'double-float))))
    (install-method sp "slice" 2
      (lambda (this args) (let* ((s (this-string this)) (len (length s))
                                 (start (clamp-index (arg args 0) len 0)) (end (clamp-index (arg args 1) len len)))
                            (if (< start end) (subseq s start end) ""))))
    (setf (realm-intrinsic *realm* :string-constructor)
          (make-constructor "String" 1
            (lambda (this args)
              (declare (ignore this))
              (if args
                  (let ((value (arg args 0)))
                    (if (js-symbol-p value) (symbol-descriptive-string value) (to-string value)))
                  ""))
            :prototype sp
            :construct-fn (lambda (args nt)
                            (make-string-object (if args (to-string (arg args 0)) "")
                                                (nt-prototype nt (intrinsic :string-prototype))))))))

(defun make-wrapper-prototype (key class primitive)
  (let ((p (js-make-object (intrinsic :object-prototype) class)))
    (obj-set-desc p "%primitive%" (data-pd primitive :writable nil :enumerable nil :configurable nil))
    (setf (realm-intrinsic *realm* key) p) p))

(defun this-boolean (this)
  (cond ((js-boolean-p this) this)
        ((and (js-object-p this) (eq (js-object-class this) :boolean)) (wrapper-primitive this))
        (t (throw-type-error "not a Boolean"))))
(defun this-number (this)
  (cond ((js-number-p this) this)
        ((and (js-object-p this) (eq (js-object-class this) :number)) (wrapper-primitive this))
        (t (throw-type-error "not a Number"))))
(defun this-string (this)
  (cond ((stringp this) this)
        ((and (js-object-p this) (eq (js-object-class this) :string)) (wrapper-primitive this))
        (t (throw-type-error "not a String"))))

;;; --- Symbol -----------------------------------------------------------------

(defun %bootstrap-symbol ()
  (let ((sp (js-make-object (intrinsic :object-prototype))))
    (setf (realm-intrinsic *realm* :symbol-prototype) sp)
    (install-method sp "toString" 0
      (lambda (this args) (declare (ignore args))
        (symbol-descriptive-string (this-symbol this))))
    (let ((ctor (make-native-function
                 "Symbol" 0
                 (lambda (this args) (declare (ignore this))
                   (%make-js-symbol :description (let ((d (arg args 0)))
                                                   (if (js-undefined-p d) +undefined+ (to-string d)))))
                 ;; Symbol has [[Construct]] for constructor inheritance, but the
                 ;; operation always throws. This lets `class C extends Symbol {}`
                 ;; be defined while preserving the `new Symbol()` TypeError.
                 :construct (lambda (args new-target)
                              (declare (ignore args new-target))
                              (throw-type-error "Symbol is not a constructor")))))
      (obj-set-desc ctor "prototype" (data-pd sp :writable nil :enumerable nil :configurable nil))
      (dolist (entry `(("iterator" . ,(well-known :iterator))
                       ("hasInstance" . ,(well-known :has-instance))
                       ("toPrimitive" . ,(well-known :to-primitive))
                       ("toStringTag" . ,(well-known :to-string-tag))
                       ("asyncIterator" . ,(well-known :async-iterator))))
        (obj-set-desc ctor (car entry)
                      (data-pd (cdr entry) :writable nil :enumerable nil :configurable nil)))
      (setf (realm-intrinsic *realm* :symbol-constructor) ctor))))

(defun this-symbol (this)
  (cond ((js-symbol-p this) this)
        ((and (js-object-p this) (eq (js-object-class this) :symbol)) (wrapper-primitive this))
        (t (throw-type-error "not a Symbol"))))

;;; --- global object ----------------------------------------------------------

(defun %bootstrap-global ()
  (let ((g (js-make-object (intrinsic :object-prototype))))
    (setf (realm-global *realm*) g)
    (macrolet ((glob (name val) `(hidden-prop g ,name ,val)))
      (obj-set-desc g "undefined" (data-pd +undefined+ :writable nil :enumerable nil :configurable nil))
      (obj-set-desc g "NaN" (data-pd *js-nan* :writable nil :enumerable nil :configurable nil))
      (obj-set-desc g "Infinity" (data-pd +js-infinity+ :writable nil :enumerable nil :configurable nil))
      (glob "globalThis" g)
      (glob "Object" (intrinsic :object-constructor))
      (glob "Function" (intrinsic :function-constructor))
      (glob "Array" (intrinsic :array-constructor))
      (glob "Boolean" (intrinsic :boolean-constructor))
      (glob "Number" (intrinsic :number-constructor))
      (glob "BigInt" (intrinsic :bigint-constructor))
      (glob "String" (intrinsic :string-constructor))
      (glob "Symbol" (intrinsic :symbol-constructor))
      (glob "Math" (intrinsic :math))
      (glob "JSON" (intrinsic :json))
      (glob "Map" (intrinsic :map-constructor))
      (glob "Set" (intrinsic :set-constructor))
      (glob "WeakMap" (intrinsic :weakmap-constructor))
      (glob "WeakSet" (intrinsic :weakset-constructor))
      (glob "Date" (intrinsic :date-constructor))
      ;; binary data (Phase 11)
      (glob "ArrayBuffer" (intrinsic :array-buffer-constructor))
      (glob "DataView" (intrinsic :data-view-constructor))
      (glob "TextEncoder" (intrinsic :text-encoder-constructor))
      (glob "TextDecoder" (intrinsic :text-decoder-constructor))
      (dolist (entry *typed-array-kinds*)
        (glob (kind-name (car entry))
              (intrinsic (intern (format nil "~a-CONSTRUCTOR" (symbol-name (car entry))) :keyword))))
      (glob "Reflect" (intrinsic :reflect))
      (glob "Proxy" (intrinsic :proxy-constructor))
      (glob "Error" (intrinsic :error-constructor))
      (dolist (k '(:type-error-constructor :range-error-constructor :syntax-error-constructor
                   :reference-error-constructor :eval-error-constructor :uri-error-constructor))
        (glob (function-name (intrinsic k)) (intrinsic k)))
      (install-method g "parseInt" 2
        (lambda (this args) (declare (ignore this)) (js-parse-int (to-string (arg args 0)) (arg args 1))))
      (install-method g "parseFloat" 1
        (lambda (this args) (declare (ignore this)) (js-parse-float (to-string (arg args 0)))))
      (install-method g "isNaN" 1 (lambda (this args) (declare (ignore this)) (js-boolean (js-nan-p (to-number (arg args 0))))))
      (install-method g "isFinite" 1 (lambda (this args) (declare (ignore this)) (js-boolean (js-finite-p (to-number (arg args 0))))))
      (install-method g "eval" 1
        (lambda (this args) (declare (ignore this))
          (let ((code (arg args 0))) (if (stringp code) (indirect-eval code) code)))))
    g))

(defun %bootstrap-function-constructor ()
  (setf (realm-intrinsic *realm* :function-constructor)
        (make-function-constructor)))

(defun make-function-constructor ()
  (make-constructor "Function" 1
    (lambda (this args) (declare (ignore this)) (%build-function args))
    :prototype (intrinsic :function-prototype)
    :construct-fn (lambda (args nt)
                    (let ((f (%build-function args)))
                      (when (js-object-p f)
                        (setf (js-object-proto f) (nt-prototype nt (intrinsic :function-prototype))))
                      f))))

(defun %build-function (args)
  "new Function(p1, …, pN, body): join params, wrap body, compile in global scope
(§20.2.1.1). SyntaxError in either part propagates as a JS SyntaxError."
  (indirect-eval (dynamic-function-source args "")))

(defun dynamic-function-wrapper-source (params body prefix generator)
  "Assemble the wrapper used to parse and instantiate a dynamic function."
  (format nil "(~afunction~:[~;*~] anonymous(~a~%) {~%~a~%})"
          prefix generator params body))

(defun validate-dynamic-function-segments (params body prefix generator)
  "Parse FormalParameters and FunctionBody as separate source-text segments.
The final wrapper is parsed again for early errors that depend on both segments,
but comments and other tokens must never bridge the parameter/body boundary."
  (let ((async (plusp (length prefix))))
    (flet ((segment-parser (source)
             (let ((parser (make-parser source)))
               (setf (parser-allow-yield parser) generator
                     (parser-allow-await parser) async
                     (parser-in-function parser) t)
               parser))
           (require-end (parser)
             (unless (eq (cur-type parser) :eof)
               (syntax-error parser "unexpected token after dynamic function segment"))))
      ;; The synthetic delimiters belong to each independent parse goal. A
      ;; segment that closes one early leaves trailing tokens and is rejected.
      (let ((parser (segment-parser (format nil "(~a~%)" params))))
        (parse-params parser)
        (require-end parser))
      (let ((parser (segment-parser (format nil "{~%~a~%}" body))))
        (parse-function-body parser)
        (require-end parser)))))

(defun dynamic-function-source (args prefix &optional generator)
  "Build the source text shared by Function and AsyncFunction constructors."
  (let* ((n (length args))
         ;; CreateDynamicFunction performs parameter ToString operations from
         ;; left to right before converting the body. Keep those observable
         ;; conversions separate from source assembly.
         (parameter-strings (if (<= n 1) '() (mapcar #'to-string (butlast args))))
         (body (if (zerop n) "" (to-string (car (last args)))))
         (params (with-output-to-string (out)
                   (loop for value in parameter-strings
                         for first = t then nil
                         do (unless first (write-char #\, out))
                            (write-string value out)))))
    (validate-dynamic-function-segments params body prefix generator)
    (dynamic-function-wrapper-source params body prefix generator)))

(defun js-parse-int (s radix)
  ;; RADIX is a raw JS value → ToInt32 (§19.2.5). Trim JS whitespace, not just ASCII.
  (let* ((str (%trim-js-whitespace s))
         (r (if (js-undefined-p radix) 0 (to-int32 radix)))
         (sign 1) (i 0) (n (length str)))
    (when (zerop n) (return-from js-parse-int *js-nan*))
    (case (char str 0) (#\+ (incf i)) (#\- (setf sign -1) (incf i)))
    (when (zerop r) (setf r 10))
    (when (and (= r 16) (< (+ i 1) n) (char= (char str i) #\0)
               (member (char str (1+ i)) '(#\x #\X)))
      (incf i 2))
    (when (and (= r 10) (< (+ i 1) n) (char= (char str i) #\0)
               (member (char str (1+ i)) '(#\x #\X)))
      (incf i 2) (setf r 16))
    (unless (<= 2 r 36) (return-from js-parse-int *js-nan*))   ; out-of-range radix -> NaN
    (let ((acc nil) (any nil))
      (loop for j from i below n
            for d = (%radix-digit (char str j) r)             ; ASCII digits only (§19.2.5)
            while d do (setf acc (+ (* (or acc 0) r) d) any t))
      (if any (coerce (* sign acc) 'double-float) *js-nan*))))

(defun %radix-digit (ch radix)
  "Weight of ASCII digit CH in RADIX (2..36), or NIL. 0-9 then a-z/A-Z; ASCII-only."
  (let ((c (char-code ch)))
    (cond ((<= 48 c 57) (let ((d (- c 48))) (and (< d radix) d)))                    ; 0-9
          ((<= 97 (logior c 32) 122) (let ((d (- (logior c 32) 87))) (and (< d radix) d))) ; a-z/A-Z
          (t nil))))
