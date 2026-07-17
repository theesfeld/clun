;;;; generator.lisp — Generator objects over the coroutine primitive (PLAN.md Phase
;;;; 06, §27.5). A generator wraps a suspended coroutine; next/return/throw drive it
;;;; and wrap the outcome as an iterator {value, done} result. %GeneratorPrototype%
;;;; inherits %IteratorPrototype%, including its exact @@iterator method.

(in-package :clun.engine)

(defstruct (js-generator (:include js-object (class :generator)) (:constructor %make-js-generator))
  coroutine
  producer
  (done nil))

(defstruct (generator-producer (:constructor %make-generator-producer (values)))
  values
  (index 0 :type fixnum))

(defun make-generator (fn co)
  "A generator instance whose [[Prototype]] is FN.prototype (the generator function's
.prototype, itself inheriting %GeneratorPrototype%), else %GeneratorPrototype%."
  (let ((proto (let ((p (and (js-object-p fn) (js-get fn "prototype"))))
                 (if (js-object-p p) p (intrinsic :generator-prototype)))))
    (%make-js-generator :proto proto :coroutine co)))

(defun make-producer-generator (values)
  "A real Generator over VALUES using the shared intrinsic prototype directly."
  (%make-js-generator
   :proto (intrinsic :generator-prototype)
   :producer (%make-generator-producer (coerce values 'vector))))

(defun %this-generator (this)
  (if (js-generator-p this) this
      (throw-type-error "Generator method called on an incompatible receiver")))

(defun %generator-step (gen mode value)
  "Resume GEN's coroutine (§27.5.3 GeneratorResume/Return/Throw) → iterator result."
  (let ((producer (js-generator-producer gen)))
    (when producer
      (return-from %generator-step
        (cond
          ((js-generator-done gen)
           (ecase mode
             (:next (make-iter-result +undefined+ t))
             (:return (make-iter-result value t))
             (:throw (throw-js-value value))))
          ((eq mode :return)
           (setf (js-generator-done gen) t
                 (js-generator-producer gen) nil)
           (make-iter-result value t))
          ((eq mode :throw)
           (setf (js-generator-done gen) t
                 (js-generator-producer gen) nil)
           (throw-js-value value))
          (t
           (let ((index (generator-producer-index producer))
                 (values (generator-producer-values producer)))
             (if (< index (length values))
                 (prog1 (make-iter-result (aref values index) nil)
                   (incf (generator-producer-index producer)))
                 (progn
                   (setf (js-generator-done gen) t
                         (js-generator-producer gen) nil)
                   (make-iter-result +undefined+ t)))))))))
  (let ((co (js-generator-coroutine gen)))
    (cond
      ((js-generator-done gen)
       ;; already completed: next → {undefined,true}; return → {value,true}; throw → throw
       (ecase mode
         (:next (make-iter-result +undefined+ t))
         (:return (make-iter-result value t))
         (:throw (throw-js-value value))))
      (t
       (multiple-value-bind (kind v) (coroutine-resume co mode value)
         (ecase kind
           (:yield (make-iter-result v nil))
           (:yield-result v)
           (:return (setf (js-generator-done gen) t) (make-iter-result v t))
           (:throw (setf (js-generator-done gen) t) (throw-js-value v))))))))

(defun build-generator-function (args new-target)
  "CreateDynamicFunction for the synchronous-generator kind in the current realm."
  (let ((function (indirect-eval (dynamic-function-source args "" t))))
    (setf (js-object-proto function)
          (nt-prototype new-target (intrinsic :generator-function-prototype))
          (js-function-function-kind function) :generator
          (js-function-constructable function) nil)
    function))

(defun bootstrap-generator-function (generator-prototype)
  "Install %GeneratorFunction% and its non-callable prototype object."
  (let* ((prototype (js-make-object (intrinsic :function-prototype)))
         (constructor nil))
    (setf constructor
          (make-native-function
           "GeneratorFunction" 1
           (lambda (this args)
             (declare (ignore this))
             (build-generator-function args constructor))
           :construct (lambda (args new-target)
                        (build-generator-function args new-target))
           :proto (intrinsic :function-constructor)))
    (obj-set-desc constructor "prototype"
                  (data-pd prototype :writable nil :enumerable nil :configurable nil))
    (obj-set-desc prototype "constructor"
                  (data-pd constructor :writable nil :enumerable nil :configurable t))
    (obj-set-desc prototype "prototype"
                  (data-pd generator-prototype
                           :writable nil :enumerable nil :configurable t))
    (obj-set-desc prototype (well-known :to-string-tag)
                  (data-pd "GeneratorFunction"
                           :writable nil :enumerable nil :configurable t))
    ;; %GeneratorPrototype%.constructor is the function-prototype object, not
    ;; the dynamic constructor itself.
    (obj-set-desc generator-prototype "constructor"
                  (data-pd prototype :writable nil :enumerable nil :configurable t))
    (setf (realm-intrinsic *realm* :generator-function-prototype) prototype
          (realm-intrinsic *realm* :generator-function-constructor) constructor)))

(defun %bootstrap-generator ()
  ;; %GeneratorPrototype% : %IteratorPrototype% (§27.5.1)
  (let ((gp (js-make-object (intrinsic :iterator-prototype))))
    (setf (realm-intrinsic *realm* :generator-prototype) gp)
    (install-method gp "next" 1
      (lambda (this args) (%generator-step (%this-generator this) :next (arg args 0))))
    (install-method gp "return" 1
      (lambda (this args) (%generator-step (%this-generator this) :return (arg args 0))))
    (install-method gp "throw" 1
      (lambda (this args) (%generator-step (%this-generator this) :throw (arg args 0))))
    (obj-set-desc gp (well-known :to-string-tag)
                  (data-pd "Generator" :writable nil :enumerable nil :configurable t))
    (bootstrap-generator-function gp)))
