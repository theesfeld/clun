;;;; functions.lisp — [[Call]]/[[Construct]] for the callable object kinds
;;;; (PLAN.md Phase 03, §4/§10.2). User functions run their compiled-body closure;
;;;; native functions wrap a CL lambda. The compiled-body signature is
;;;; (lambda (fn this args new-target) -> js-value) — the emitter produces it and
;;;; owns frame setup, `this` coercion, and the arguments object.

(in-package :clun.engine)

;; WITH-JS-FLOATS at the call entry masks the JS float traps once per call chain; every arithmetic op
;; inside nests cheaply (§ Phase 25). The outermost CL->JS entry masks; nested calls see *fp-masked*.
(defmethod jm-call ((f js-native-function) this args)
  (when (member (js-native-function-function-kind f) '(:base-class :derived-class))
    (throw-type-error "class constructor cannot be invoked without 'new'"))
  (with-js-floats (funcall (js-native-function-fn f) this args)))

(defmethod jm-call ((f js-function) this args)
  (when (member (js-function-function-kind f) '(:base-class :derived-class))
    (throw-type-error "class constructor cannot be invoked without 'new'"))
  (with-js-floats (funcall (js-function-compiled-body f) f this args +undefined+)))

(defmethod jm-call ((f js-bound-function) this args)
  (declare (ignore this))
  (js-call (js-bound-function-target f)
           (js-bound-function-bound-this f)
           (append (js-bound-function-bound-args f) args)))

(defmethod jm-construct ((f js-native-function) args new-target)
  (let ((c (js-native-function-construct-fn f)))
    (if c (funcall c args new-target) (throw-type-error "not a constructor"))))

(defmethod jm-construct ((f js-function) args new-target)
  (if (eq (js-function-function-kind f) :derived-class)
      (let* ((binding (make-derived-this-binding))
             (result (with-js-floats
                       (funcall (js-function-compiled-body f) f binding args new-target))))
        (cond ((js-object-p result) result)
              ((js-undefined-p result) (get-this-binding binding))
              (t (throw-type-error "derived constructors may only return an object or undefined"))))
      (let* ((proto (let ((p (js-get new-target "prototype")))
                      (if (js-object-p p) p (intrinsic :object-prototype))))
             (obj (js-make-object proto)))
        (let ((result (with-js-floats
                        (funcall (js-function-compiled-body f) f obj args new-target))))
          (if (js-object-p result) result obj)))))

(defmethod jm-construct ((f js-bound-function) args new-target)
  (let ((target (js-bound-function-target f)))
    (js-construct target
                  (append (js-bound-function-bound-args f) args)
                  (if (eq new-target f) target new-target))))

;;; --- constructing native functions -----------------------------------------

(defun make-native-function (name arity fn &key construct proto (function-kind :ordinary))
  "A built-in function wrapping CL lambda FN (this args) -> value."
  (let ((f (%make-native-function
            :fn fn :construct-fn construct :fname name :param-count arity
            :function-kind function-kind
            :proto (or proto (and *realm* (intrinsic :function-prototype)) +null+))))
    (obj-set-desc f "length" (data-pd (coerce arity 'double-float)
                                      :writable nil :enumerable nil :configurable t))
    (obj-set-desc f "name" (data-pd name :writable nil :enumerable nil :configurable t))
    f))

(defun bound-function-length (target bound-argument-count)
  "Compute SetFunctionLength's value for Function.prototype.bind."
  (if (not (has-own-property target "length"))
      0d0
      (let ((value (js-get target "length")))
        (cond
          ((not (js-number-p value)) 0d0)
          ((or (js-nan-p value) (eql value +js-neg-infinity+)) 0d0)
          ((eql value +js-infinity+) +js-infinity+)
          (t (let ((remaining (- (to-integer-or-infinity value)
                                  bound-argument-count)))
               (if (plusp remaining) remaining 0d0)))))))

(defun make-bound-function (target bound-this bound-args)
  "BoundFunctionCreate plus the observable length/name initialization."
  (unless (callable-p target)
    (throw-type-error "Function.prototype.bind called on incompatible receiver"))
  ;; BoundFunctionCreate observes [[GetPrototypeOf]] before bind reads length/name.
  (let* ((proto (jm-get-prototype-of target))
         (args (copy-list bound-args))
         (length (bound-function-length target (length args)))
         (target-name (js-get target "name"))
         (name (format nil "bound ~a" (if (stringp target-name) target-name "")))
         (f (%make-bound-function :proto proto :target target
                                  :bound-this bound-this :bound-args args
                                  :fname name
                                  :param-count (if (and (js-finite-p length)
                                                        (<= 0d0 length
                                                            (coerce most-positive-fixnum
                                                                    'double-float)))
                                                   (floor length)
                                                   0))))
    (obj-set-desc f "length" (data-pd length :writable nil :enumerable nil :configurable t))
    (obj-set-desc f "name" (data-pd name :writable nil :enumerable nil :configurable t))
    f))

(defun install-method (obj name arity fn)
  "Define a non-enumerable native method NAME on OBJ."
  (obj-set-desc obj name (data-pd (make-native-function name arity fn)
                                  :writable t :enumerable nil :configurable t))
  obj)

(defun install-getter (obj name fn)
  (obj-set-desc obj name (accessor-pd (make-native-function (format nil "get ~a" name) 0 fn)
                                      +undefined+ :enumerable nil :configurable t)))

(defun install-accessor (obj name getter setter)
  "A get+set accessor property NAME on OBJ. GETTER/SETTER are CL fns of (this args)."
  (obj-set-desc obj name (accessor-pd (make-native-function (format nil "get ~a" name) 0 getter)
                                      (if setter (make-native-function (format nil "set ~a" name) 1 setter)
                                          +undefined+)
                                      :enumerable nil :configurable t)))

;;; --- instantiating a user function (called by the emitter) -----------------

(defun instantiate-function (compiled-body env &key (fname "") (param-count 0) strict
                                                    (this-mode :normal) (constructable t)
                                                    (kind :normal) function-kind source-text)
  "Build a js-function object with the correct prototype wiring."
  (let* ((resolved-kind (or function-kind
                            (case kind
                              (:method :method)
                              (:generator :generator)
                              (:async :async)
                              (t :ordinary))))
         ;; An explicit :ASYNC function-kind is useful to callers that must retain
         ;; a separate syntactic kind (for example, an async method).
         (generator-p (eq resolved-kind :generator))
         (async-p (eq resolved-kind :async))
         (async-generator-p (eq resolved-kind :async-generator))
         (can-construct (and constructable (not generator-p)
                                           (not async-p) (not async-generator-p)))
         (f (%make-js-function
             :proto (intrinsic (cond (generator-p :generator-function-prototype)
                                     (async-generator-p :async-generator-function-prototype)
                                     (async-p :async-function-prototype)
                                     (t :function-prototype)))
             :compiled-body compiled-body :env env :fname fname :param-count param-count
             :strict strict :this-mode this-mode :constructable can-construct
             :source-text source-text
             :function-kind resolved-kind)))
    (obj-set-desc f "length" (data-pd (coerce param-count 'double-float)
                                      :writable nil :enumerable nil :configurable t))
    (obj-set-desc f "name" (data-pd fname :writable nil :enumerable nil :configurable t))
    ;; Legacy caller is an optional extension. Expose the permitted unsupported
    ;; value on sloppy ordinary functions so it does not fall through to
    ;; Function.prototype's strict poison accessor.
    (when (and (not strict) (eq resolved-kind :ordinary))
      (obj-set-desc f "caller"
                    (data-pd +undefined+ :writable nil :enumerable nil :configurable nil)))
    (cond
      ;; a normal (non-arrow, non-method) function gets a fresh constructable .prototype
      ((and can-construct (eq kind :normal))
       (let ((proto (js-make-object (intrinsic :object-prototype))))
         (obj-set-desc proto "constructor" (data-pd f :writable t :enumerable nil :configurable t))
         (obj-set-desc f "prototype" (data-pd proto :writable t :enumerable nil :configurable nil))))
      ;; Every synchronous generator callable, including a generator method,
      ;; owns the prototype object used by its generator instances.
      (generator-p
       (obj-set-desc f "prototype"
                     (data-pd (js-make-object (intrinsic :generator-prototype))
                              :writable t :enumerable nil :configurable nil)))
      ;; Async generator declarations/expressions receive their own prototype
      ;; object. Async generator methods use KIND :METHOD and therefore do not.
      ((eq kind :async-generator)
       (obj-set-desc f "prototype"
                     (data-pd (js-make-object (intrinsic :async-generator-prototype))
                              :writable t :enumerable nil :configurable nil))))
    f))
