;;;; functions.lisp — [[Call]]/[[Construct]] for the callable object kinds
;;;; (PLAN.md Phase 03, §4/§10.2). User functions run their compiled-body closure;
;;;; native functions wrap a CL lambda. The compiled-body signature is
;;;; (lambda (fn this args new-target) -> js-value) — the emitter produces it and
;;;; owns frame setup, `this` coercion, and the arguments object.

(in-package :clun.engine)

(defmethod jm-call ((f js-native-function) this args)
  (funcall (js-native-function-fn f) this args))

(defmethod jm-call ((f js-function) this args)
  (funcall (js-function-compiled-body f) f this args +undefined+))

(defmethod jm-construct ((f js-native-function) args new-target)
  (let ((c (js-native-function-construct-fn f)))
    (if c (funcall c args new-target) (throw-type-error "not a constructor"))))

(defmethod jm-construct ((f js-function) args new-target)
  (let* ((proto (let ((p (js-get new-target "prototype")))
                  (if (js-object-p p) p (intrinsic :object-prototype))))
         (obj (js-make-object proto)))
    (let ((result (funcall (js-function-compiled-body f) f obj args new-target)))
      (if (js-object-p result) result obj))))

;;; --- constructing native functions -----------------------------------------

(defun make-native-function (name arity fn &key construct proto)
  "A built-in function wrapping CL lambda FN (this args) -> value."
  (let ((f (%make-native-function
            :fn fn :construct-fn construct :fname name :param-count arity
            :proto (or proto (and *realm* (intrinsic :function-prototype)) +null+))))
    (obj-set-desc f "length" (data-pd (coerce arity 'double-float)
                                      :writable nil :enumerable nil :configurable t))
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

;;; --- instantiating a user function (called by the emitter) -----------------

(defun instantiate-function (compiled-body env &key (fname "") (param-count 0) strict
                                                    (this-mode :normal) (constructable t)
                                                    (kind :normal))
  "Build a js-function object with the correct prototype wiring."
  (let ((f (%make-js-function
            :proto (intrinsic :function-prototype)
            :compiled-body compiled-body :env env :fname fname :param-count param-count
            :strict strict :this-mode this-mode :constructable constructable)))
    (obj-set-desc f "length" (data-pd (coerce param-count 'double-float)
                                      :writable nil :enumerable nil :configurable t))
    (obj-set-desc f "name" (data-pd fname :writable nil :enumerable nil :configurable t))
    (cond
      ;; a normal (non-arrow, non-method) function gets a fresh constructable .prototype
      ((and constructable (eq kind :normal))
       (let ((proto (js-make-object (intrinsic :object-prototype))))
         (obj-set-desc proto "constructor" (data-pd f :writable t :enumerable nil :configurable t))
         (obj-set-desc f "prototype" (data-pd proto :writable t :enumerable nil :configurable nil))))
      ;; a generator function's .prototype inherits %GeneratorPrototype% (instances' proto)
      ((eq kind :generator)
       (obj-set-desc f "prototype"
                     (data-pd (js-make-object (intrinsic :generator-prototype))
                              :writable t :enumerable nil :configurable nil))))
    f))
