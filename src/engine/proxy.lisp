;;;; proxy.lisp -- Proxy exotic objects and the Proxy constructor (ECMA-262
;;;; sections 10.5 and 28.2).  Every observable operation routes through the
;;;; object internal-method protocol; the inherited js-object slots are inert.

(in-package :clun.engine)

(defun %proxy-state (proxy)
  "Return PROXY's captured target and handler, rejecting a revoked proxy first."
  (when (js-proxy-revoked-p proxy)
    (throw-type-error "Cannot perform operation on a revoked proxy"))
  (values (js-proxy-target proxy) (js-proxy-handler proxy)))

(defun %proxy-create (target handler)
  (unless (js-object-p target)
    (throw-type-error "Proxy target must be an object"))
  (unless (js-object-p handler)
    (throw-type-error "Proxy handler must be an object"))
  (%make-js-proxy :proto +null+
                  :target target
                  :handler handler
                  :callable-p (callable-p target)
                  :constructable-p (constructor-p target)))

(defun %proxy-revoke (proxy)
  (unless (js-proxy-revoked-p proxy)
    (setf (js-proxy-revoked-p proxy) t
          (js-proxy-target proxy) +null+
          (js-proxy-handler proxy) +null+))
  +undefined+)

(defun %property-key= (left right)
  (if (and (stringp left) (stringp right))
      (string= left right)
      (eq left right)))

(defun %key-member-p (key keys)
  (and (find key keys :test #'%property-key=) t))

(defun %complete-property-descriptor (descriptor)
  "CompletePropertyDescriptor, returning a fresh descriptor."
  (let ((complete (copy-pd descriptor)))
    (if (or (generic-descriptor-p complete) (data-descriptor-p complete))
        (progn
          (unless (pd-set-p (pd-value complete))
            (setf (pd-value complete) +undefined+))
          (unless (pd-set-p (pd-writable complete))
            (setf (pd-writable complete) nil)))
        (progn
          (unless (pd-set-p (pd-get complete))
            (setf (pd-get complete) +undefined+))
          (unless (pd-set-p (pd-set complete))
            (setf (pd-set complete) +undefined+))))
    (unless (pd-set-p (pd-enumerable complete))
      (setf (pd-enumerable complete) nil))
    (unless (pd-set-p (pd-configurable complete))
      (setf (pd-configurable complete) nil))
    complete))

(defun %compatible-property-descriptor-p (extensible descriptor current)
  (validate-and-apply-property-descriptor nil nil extensible descriptor current))

(defun %descriptor-object (descriptor)
  "FromPropertyDescriptor for a possibly incomplete descriptor."
  (let ((object (new-object)))
    (when (pd-set-p (pd-value descriptor))
      (create-data-property object "value" (pd-value descriptor)))
    (when (pd-set-p (pd-writable descriptor))
      (create-data-property object "writable" (js-boolean (pd-writable descriptor))))
    (when (pd-set-p (pd-get descriptor))
      (create-data-property object "get" (pd-get descriptor)))
    (when (pd-set-p (pd-set descriptor))
      (create-data-property object "set" (pd-set descriptor)))
    (when (pd-set-p (pd-enumerable descriptor))
      (create-data-property object "enumerable" (js-boolean (pd-enumerable descriptor))))
    (when (pd-set-p (pd-configurable descriptor))
      (create-data-property object "configurable" (js-boolean (pd-configurable descriptor))))
    object))

(defun %proxy-create-key-list (trap-result)
  "CreateListFromArrayLike(TRAP-RESULT, String|Symbol), including duplicate rejection."
  (unless (js-object-p trap-result)
    (throw-type-error "Proxy ownKeys trap must return an object"))
  (let ((keys '()))
    ;; CreateListFromArrayLike completes every indexed Get and element-type
    ;; validation before Proxy [[OwnPropertyKeys]] performs its separate
    ;; duplicate check.  Rejecting a duplicate during collection would skip
    ;; later observable getters.
    (dotimes (index (length-of-array-like trap-result))
      (let ((key (js-getv trap-result (princ-to-string index))))
        (unless (or (stringp key) (js-symbol-p key))
          (throw-type-error "Proxy ownKeys trap returned a non-property key"))
        (push key keys)))
    (setf keys (nreverse keys))
    (let ((seen (make-hash-table :test #'equal)))
      (dolist (key keys)
        (multiple-value-bind (ignored present-p) (gethash key seen)
          (declare (ignore ignored))
          (when present-p
            (throw-type-error "Proxy ownKeys trap returned duplicate entries"))
          (setf (gethash key seen) t))))
    keys))

(defun is-array (value)
  "IsArray: recursively unwrap Proxy targets and reject revoked proxies."
  (cond
    ((js-array-p value) t)
    ((js-proxy-p value)
     (multiple-value-bind (target handler) (%proxy-state value)
       (declare (ignore handler))
       (is-array target)))
    (t nil)))

;;; --- Proxy object internal methods -----------------------------------------

(defmethod jm-get-prototype-of ((proxy js-proxy))
  (multiple-value-bind (target handler) (%proxy-state proxy)
    (let ((trap (get-method handler "getPrototypeOf")))
      (when (js-undefined-p trap)
        (return-from jm-get-prototype-of (jm-get-prototype-of target)))
      (let ((result (js-call trap handler (list target))))
        (unless (or (js-object-p result) (js-null-p result))
          (throw-type-error "Proxy getPrototypeOf trap returned an invalid prototype"))
        (when (jm-is-extensible target)
          (return-from jm-get-prototype-of result))
        (unless (js-same-value result (jm-get-prototype-of target))
          (throw-type-error "Proxy getPrototypeOf trap violated a target invariant"))
        result))))

(defmethod jm-set-prototype-of ((proxy js-proxy) prototype)
  (multiple-value-bind (target handler) (%proxy-state proxy)
    (let ((trap (get-method handler "setPrototypeOf")))
      (when (js-undefined-p trap)
        (return-from jm-set-prototype-of (jm-set-prototype-of target prototype)))
      (unless (js-truthy (js-call trap handler (list target prototype)))
        (return-from jm-set-prototype-of nil))
      (when (jm-is-extensible target)
        (return-from jm-set-prototype-of t))
      (unless (js-same-value prototype (jm-get-prototype-of target))
        (throw-type-error "Proxy setPrototypeOf trap violated a target invariant"))
      t)))

(defmethod jm-is-extensible ((proxy js-proxy))
  (multiple-value-bind (target handler) (%proxy-state proxy)
    (let ((trap (get-method handler "isExtensible")))
      (when (js-undefined-p trap)
        (return-from jm-is-extensible (jm-is-extensible target)))
      (let ((result (js-truthy (js-call trap handler (list target))))
            (actual (jm-is-extensible target)))
        (unless (eq result actual)
          (throw-type-error "Proxy isExtensible trap contradicted the target"))
        result))))

(defmethod jm-prevent-extensions ((proxy js-proxy))
  (multiple-value-bind (target handler) (%proxy-state proxy)
    (let ((trap (get-method handler "preventExtensions")))
      (when (js-undefined-p trap)
        (return-from jm-prevent-extensions (jm-prevent-extensions target)))
      (let ((result (js-truthy (js-call trap handler (list target)))))
        (when (and result (jm-is-extensible target))
          (throw-type-error "Proxy preventExtensions trap contradicted the target"))
        result))))

(defmethod jm-get-own-property ((proxy js-proxy) key)
  (multiple-value-bind (target handler) (%proxy-state proxy)
    (let ((trap (get-method handler "getOwnPropertyDescriptor")))
      (when (js-undefined-p trap)
        (return-from jm-get-own-property (jm-get-own-property target key)))
      (let ((trap-result (js-call trap handler (list target key))))
        (unless (or (js-object-p trap-result) (js-undefined-p trap-result))
          (throw-type-error "Proxy getOwnPropertyDescriptor trap returned an invalid descriptor"))
        (let ((target-descriptor (jm-get-own-property target key)))
          (when (js-undefined-p trap-result)
            (when target-descriptor
              (when (eq (pd-configurable target-descriptor) nil)
                (throw-type-error "Proxy cannot hide a non-configurable property"))
              (unless (jm-is-extensible target)
                (throw-type-error "Proxy cannot hide a property of a non-extensible target")))
            (return-from jm-get-own-property nil))
          (let* ((extensible (jm-is-extensible target))
                 (result-descriptor
                   (%complete-property-descriptor
                    (to-property-descriptor trap-result))))
            (unless (%compatible-property-descriptor-p
                     extensible result-descriptor target-descriptor)
              (throw-type-error "Proxy reported an incompatible property descriptor"))
            (when (eq (pd-configurable result-descriptor) nil)
              (when (or (null target-descriptor)
                        (eq (pd-configurable target-descriptor) t))
                (throw-type-error "Proxy cannot report a new non-configurable property"))
              (when (and (data-descriptor-p result-descriptor)
                         (eq (pd-writable result-descriptor) nil)
                         (data-descriptor-p target-descriptor)
                         (eq (pd-writable target-descriptor) t))
                (throw-type-error "Proxy cannot report a writable target property as non-writable")))
            result-descriptor))))))

(defmethod jm-define-own-property ((proxy js-proxy) key descriptor)
  (multiple-value-bind (target handler) (%proxy-state proxy)
    (let ((trap (get-method handler "defineProperty")))
      (when (js-undefined-p trap)
        (return-from jm-define-own-property
          (jm-define-own-property target key descriptor)))
      (unless (js-truthy
               (js-call trap handler
                        (list target key (%descriptor-object descriptor))))
        (return-from jm-define-own-property nil))
      (let* ((target-descriptor (jm-get-own-property target key))
             (extensible (jm-is-extensible target))
             (setting-config-false
               (and (pd-set-p (pd-configurable descriptor))
                    (eq (pd-configurable descriptor) nil))))
        (cond
          ((null target-descriptor)
           (unless extensible
             (throw-type-error "Proxy cannot define a property on a non-extensible target"))
           (when setting-config-false
             (throw-type-error "Proxy cannot define a new non-configurable property")))
          (t
           (unless (%compatible-property-descriptor-p
                    extensible descriptor target-descriptor)
             (throw-type-error "Proxy defineProperty trap reported an incompatible descriptor"))
           (when (and setting-config-false
                      (eq (pd-configurable target-descriptor) t))
             (throw-type-error "Proxy cannot make a configurable property non-configurable"))
           (when (and (data-descriptor-p target-descriptor)
                      (eq (pd-configurable target-descriptor) nil)
                      (eq (pd-writable target-descriptor) t)
                      (pd-set-p (pd-writable descriptor))
                      (eq (pd-writable descriptor) nil))
             (throw-type-error "Proxy cannot make a writable target property non-writable"))))
        t))))

(defmethod jm-has-property ((proxy js-proxy) key)
  (multiple-value-bind (target handler) (%proxy-state proxy)
    (let ((trap (get-method handler "has")))
      (when (js-undefined-p trap)
        (return-from jm-has-property (jm-has-property target key)))
      (let ((result (js-truthy (js-call trap handler (list target key)))))
        (unless result
          (let ((target-descriptor (jm-get-own-property target key)))
            (when target-descriptor
              (when (eq (pd-configurable target-descriptor) nil)
                (throw-type-error "Proxy cannot hide a non-configurable property"))
              (unless (jm-is-extensible target)
                (throw-type-error "Proxy cannot hide a property of a non-extensible target")))))
        result))))

(defmethod jm-get ((proxy js-proxy) key receiver)
  (multiple-value-bind (target handler) (%proxy-state proxy)
    (let ((trap (get-method handler "get")))
      (when (js-undefined-p trap)
        (return-from jm-get (jm-get target key receiver)))
      (let ((result (js-call trap handler (list target key receiver)))
            (target-descriptor (jm-get-own-property target key)))
        (when (and target-descriptor
                   (eq (pd-configurable target-descriptor) nil))
          (cond
            ((and (data-descriptor-p target-descriptor)
                  (eq (pd-writable target-descriptor) nil)
                  (not (js-same-value result (pd-value target-descriptor))))
             (throw-type-error "Proxy get trap changed a frozen data property"))
            ((and (accessor-descriptor-p target-descriptor)
                  (js-undefined-p (defaulted (pd-get target-descriptor) +undefined+))
                  (not (js-undefined-p result)))
             (throw-type-error "Proxy get trap exposed a getter-less property"))))
        result))))

(defmethod jm-set ((proxy js-proxy) key value receiver)
  (multiple-value-bind (target handler) (%proxy-state proxy)
    (let ((trap (get-method handler "set")))
      (when (js-undefined-p trap)
        (return-from jm-set (jm-set target key value receiver)))
      (unless (js-truthy (js-call trap handler (list target key value receiver)))
        (return-from jm-set nil))
      (let ((target-descriptor (jm-get-own-property target key)))
        (when (and target-descriptor
                   (eq (pd-configurable target-descriptor) nil))
          (cond
            ((and (data-descriptor-p target-descriptor)
                  (eq (pd-writable target-descriptor) nil)
                  (not (js-same-value value (pd-value target-descriptor))))
             (throw-type-error "Proxy set trap changed a frozen data property"))
            ((and (accessor-descriptor-p target-descriptor)
                  (js-undefined-p (defaulted (pd-set target-descriptor) +undefined+)))
             (throw-type-error "Proxy set trap wrote a setter-less property")))))
      t)))

(defmethod jm-delete ((proxy js-proxy) key)
  (multiple-value-bind (target handler) (%proxy-state proxy)
    (let ((trap (get-method handler "deleteProperty")))
      (when (js-undefined-p trap)
        (return-from jm-delete (jm-delete target key)))
      (unless (js-truthy (js-call trap handler (list target key)))
        (return-from jm-delete nil))
      (let ((target-descriptor (jm-get-own-property target key)))
        (when target-descriptor
          (when (eq (pd-configurable target-descriptor) nil)
            (throw-type-error "Proxy cannot delete a non-configurable property"))
          (unless (jm-is-extensible target)
            (throw-type-error "Proxy cannot delete a property of a non-extensible target"))))
      t)))

(defmethod jm-own-property-keys ((proxy js-proxy))
  (multiple-value-bind (target handler) (%proxy-state proxy)
    (let ((trap (get-method handler "ownKeys")))
      (when (js-undefined-p trap)
        (return-from jm-own-property-keys (jm-own-property-keys target)))
      (let* ((trap-keys
               (%proxy-create-key-list (js-call trap handler (list target))))
             ;; The algorithm observes extensibility before OwnPropertyKeys and
             ;; caches the answer; a target may itself be a side-effecting Proxy.
             (extensible (jm-is-extensible target))
             (target-keys (jm-own-property-keys target))
             (non-configurable '())
             (configurable '()))
        (dolist (key target-keys)
          (let ((descriptor (jm-get-own-property target key)))
            (if (and descriptor (eq (pd-configurable descriptor) nil))
                (push key non-configurable)
                (push key configurable))))
        (setf non-configurable (nreverse non-configurable)
              configurable (nreverse configurable))
        (when (and extensible (null non-configurable))
          (return-from jm-own-property-keys trap-keys))
        (let ((unchecked (copy-list trap-keys)))
          (dolist (key non-configurable)
            (unless (%key-member-p key unchecked)
              (throw-type-error "Proxy ownKeys trap omitted a non-configurable key"))
            (setf unchecked (remove key unchecked :test #'%property-key= :count 1)))
          (when extensible
            (return-from jm-own-property-keys trap-keys))
          (dolist (key configurable)
            (unless (%key-member-p key unchecked)
              (throw-type-error "Proxy ownKeys trap omitted a target key"))
            (setf unchecked (remove key unchecked :test #'%property-key= :count 1)))
          (when unchecked
            (throw-type-error "Proxy ownKeys trap added a key to a non-extensible target"))
          trap-keys)))))

(defmethod jm-call ((proxy js-proxy) this args)
  (unless (js-proxy-callable-p proxy)
    (throw-type-error "Proxy target is not callable"))
  (multiple-value-bind (target handler) (%proxy-state proxy)
    (let ((trap (get-method handler "apply")))
      (if (js-undefined-p trap)
          (js-call target this args)
          (js-call trap handler (list target this (new-array args)))))))

(defmethod jm-construct ((proxy js-proxy) args new-target)
  (unless (js-proxy-constructable-p proxy)
    (throw-type-error "Proxy target is not a constructor"))
  (multiple-value-bind (target handler) (%proxy-state proxy)
    (let ((trap (get-method handler "construct")))
      (if (js-undefined-p trap)
          (js-construct target args new-target)
          (let ((result
                  (js-call trap handler
                           (list target (new-array args) new-target))))
            (unless (js-object-p result)
              (throw-type-error "Proxy construct trap must return an object"))
            result)))))

;;; --- Proxy constructor -----------------------------------------------------

(defun %bootstrap-proxy ()
  (let ((constructor
          (make-native-function
           "Proxy" 2
           (lambda (this args)
             (declare (ignore this args))
             (throw-type-error "Proxy constructor requires 'new'"))
           :construct
           (lambda (args new-target)
             (declare (ignore new-target))
             (%proxy-create (arg args 0) (arg args 1))))))
    (install-method
     constructor "revocable" 2
     (lambda (this args)
       (declare (ignore this))
       (let* ((proxy (%proxy-create (arg args 0) (arg args 1)))
              (revocable-proxy proxy)
              (revoke
                (make-native-function
                 "" 0
                 (lambda (this revoke-args)
                   (declare (ignore this revoke-args))
                   (when revocable-proxy
                     (%proxy-revoke revocable-proxy)
                     (setf revocable-proxy nil))
                   +undefined+)))
              (result (new-object)))
         (create-data-property result "proxy" proxy)
         (create-data-property result "revoke" revoke)
         result)))
    (setf (realm-intrinsic *realm* :proxy-constructor) constructor)))
