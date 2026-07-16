;;;; builtins-object.lisp — Object statics + Object.prototype breadth (Phase 04,
;;;; §20.1). Extends the Phase 03 Object set with is / fromEntries /
;;;; getOwnPropertyDescriptors, the legacy accessor methods, and __proto__.

(in-package :clun.engine)

(defun object-prototype-lookup-accessor (this property-key kind)
  (let ((o (to-object this))
        (key (to-property-key property-key)))
    (loop
      (let ((desc (jm-get-own-property o key)))
        (when desc
          (return
            (if (accessor-descriptor-p desc)
                (ecase kind
                  (:get (defaulted (pd-get desc) +undefined+))
                  (:set (defaulted (pd-set desc) +undefined+)))
                +undefined+))))
      (setf o (jm-get-prototype-of o))
      (unless (js-object-p o)
        (return +undefined+)))))

(defun %bootstrap-object-extra ()
  (let ((oc (intrinsic :object-constructor)) (op (intrinsic :object-prototype)))
    (install-method oc "is" 2
      (lambda (this args) (declare (ignore this)) (js-boolean (js-same-value (arg args 0) (arg args 1)))))
    (install-method oc "fromEntries" 1
      (lambda (this args) (declare (ignore this))
        (let* ((o (new-object))
               (record (get-iterator-record (arg args 0))))
          (loop
            (multiple-value-bind (entry done) (iterator-step-value record)
              (when done (return o))
              (call-with-iterator-close-on-abrupt
               record
               (lambda ()
                 (unless (js-object-p entry)
                   (throw-type-error "iterable entry is not an object"))
                 (let ((key (js-getv entry "0"))
                       (value (js-getv entry "1")))
                   (create-data-property-or-throw
                    o (to-property-key key) value)))))))))
    (install-method oc "getOwnPropertyDescriptors" 1
      (lambda (this args) (declare (ignore this))
        (let* ((obj (to-object (arg args 0))) (result (new-object)))
          (dolist (k (jm-own-property-keys obj) result)
            (let ((d (jm-get-own-property obj k)))
              (when d (create-data-property result k (from-property-descriptor d))))))))
    (install-method oc "setPrototypeOf" 2
      (lambda (this args) (declare (ignore this))
        (let ((o (require-object-coercible (arg args 0))) (p (arg args 1)))
          (unless (or (js-object-p p) (js-null-p p)) (throw-type-error "prototype must be an object or null"))
          (when (js-object-p o)
            (unless (jm-set-prototype-of o p) (throw-type-error "cannot set prototype")))
          o)))
    (install-method op "__defineGetter__" 2
      (lambda (this args)
        (let ((o (to-object this))
              (getter (arg args 1)))
          (unless (callable-p getter)
            (throw-type-error "getter must be callable"))
          (define-property-or-throw
           o (to-property-key (arg args 0))
           (make-prop-desc :get getter :enumerable t :configurable t))
          +undefined+)))
    (install-method op "__defineSetter__" 2
      (lambda (this args)
        (let ((o (to-object this))
              (setter (arg args 1)))
          (unless (callable-p setter)
            (throw-type-error "setter must be callable"))
          (define-property-or-throw
           o (to-property-key (arg args 0))
           (make-prop-desc :set setter :enumerable t :configurable t))
          +undefined+)))
    (install-method op "__lookupGetter__" 1
      (lambda (this args)
        (object-prototype-lookup-accessor this (arg args 0) :get)))
    (install-method op "__lookupSetter__" 1
      (lambda (this args)
        (object-prototype-lookup-accessor this (arg args 0) :set)))
    ;; __proto__ accessor (Annex B, widely relied upon)
    (obj-set-desc op "__proto__"
      (accessor-pd
       (make-native-function "get __proto__" 0
         (lambda (this args) (declare (ignore args)) (let ((p (jm-get-prototype-of (to-object this)))) (if (js-object-p p) p +null+))))
       (make-native-function "set __proto__" 1
         (lambda (this args)
           (let ((o (require-object-coercible this)) (p (arg args 0)))
             (when (and (js-object-p o) (or (js-object-p p) (js-null-p p)))
               (unless (jm-set-prototype-of o p)
                 (throw-type-error "cannot set prototype")))
             +undefined+)))
       :enumerable nil :configurable t))))

;;; Reflect (§28.1) — thin wrappers over the object internal methods. Not in the
;;; literal Phase 04 list but uncontroversially stdlib-core, and it unblocks the
;;; isConstructor.js harness (Reflect.construct) used by is-a-constructor tests
;;; across every intrinsic. Proxy stays deferred.
(defun %require-object (v what) (if (js-object-p v) v (throw-type-error (format nil "Reflect.~a called on non-object" what))))

(defun %bootstrap-reflect ()
  (let ((r (js-make-object (intrinsic :object-prototype))))
    (setf (realm-intrinsic *realm* :reflect) r)
    (obj-set-desc r (well-known :to-string-tag) (data-pd "Reflect" :writable nil :enumerable nil :configurable t))
    (macrolet ((m (name arity &body body) `(install-method r ,name ,arity ,@body)))
      (m "apply" 3 (lambda (this args) (declare (ignore this))
                     (js-call (arg args 0) (arg args 1) (array-like->list (%require-object (arg args 2) "apply")))))
      (m "construct" 2 (lambda (this args) (declare (ignore this))
                         (let ((target (arg args 0)) (nt (if (>= (length args) 3) (arg args 2) (arg args 0))))
                           (unless (constructor-p target) (throw-type-error "Reflect.construct target is not a constructor"))
                           (unless (constructor-p nt) (throw-type-error "Reflect.construct newTarget is not a constructor"))
                           (js-construct target (array-like->list (%require-object (arg args 1) "construct")) nt))))
      (m "get" 2 (lambda (this args) (declare (ignore this))
                   (let ((o (%require-object (arg args 0) "get")))
                     (jm-get o (to-property-key (arg args 1)) (if (>= (length args) 3) (arg args 2) o)))))
      (m "set" 3 (lambda (this args) (declare (ignore this))
                   (let ((o (%require-object (arg args 0) "set")))
                     (js-boolean (jm-set o (to-property-key (arg args 1)) (arg args 2) (if (>= (length args) 4) (arg args 3) o))))))
      (m "has" 2 (lambda (this args) (declare (ignore this))
                   (js-boolean (jm-has-property (%require-object (arg args 0) "has") (to-property-key (arg args 1))))))
      (m "deleteProperty" 2 (lambda (this args) (declare (ignore this))
                              (js-boolean (jm-delete (%require-object (arg args 0) "deleteProperty") (to-property-key (arg args 1))))))
      (m "ownKeys" 1 (lambda (this args) (declare (ignore this))
                       (new-array (jm-own-property-keys (%require-object (arg args 0) "ownKeys")))))
      (m "getPrototypeOf" 1 (lambda (this args) (declare (ignore this))
                              (let ((p (jm-get-prototype-of (%require-object (arg args 0) "getPrototypeOf")))) (if (js-object-p p) p +null+))))
      (m "setPrototypeOf" 2 (lambda (this args) (declare (ignore this))
                              (let ((o (%require-object (arg args 0) "setPrototypeOf")) (p (arg args 1)))
                                (unless (or (js-object-p p) (js-null-p p)) (throw-type-error "proto must be object or null"))
                                (js-boolean (jm-set-prototype-of o p)))))
      (m "defineProperty" 3 (lambda (this args) (declare (ignore this))
                              (js-boolean (jm-define-own-property (%require-object (arg args 0) "defineProperty")
                                                                  (to-property-key (arg args 1)) (to-property-descriptor (arg args 2))))))
      (m "getOwnPropertyDescriptor" 2 (lambda (this args) (declare (ignore this))
                                        (from-property-descriptor (jm-get-own-property (%require-object (arg args 0) "getOwnPropertyDescriptor")
                                                                                       (to-property-key (arg args 1))))))
      (m "isExtensible" 1 (lambda (this args) (declare (ignore this)) (js-boolean (jm-is-extensible (%require-object (arg args 0) "isExtensible")))))
      (m "preventExtensions" 1 (lambda (this args) (declare (ignore this)) (js-boolean (jm-prevent-extensions (%require-object (arg args 0) "preventExtensions"))))))
    r))
