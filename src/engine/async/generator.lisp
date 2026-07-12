;;;; generator.lisp — Generator objects over the coroutine primitive (PLAN.md Phase
;;;; 06, §27.5). A generator wraps a suspended coroutine; next/return/throw drive it
;;;; and wrap the outcome as an iterator {value, done} result. %GeneratorPrototype%
;;;; inherits %IteratorPrototype% (so @@iterator returning this comes for free, but we
;;;; also install it explicitly to be robust to prototype swaps).

(in-package :clun.engine)

(defstruct (js-generator (:include js-object (class :generator)) (:constructor %make-js-generator))
  coroutine
  (done nil))

(defun make-generator (fn co)
  "A generator instance whose [[Prototype]] is FN.prototype (the generator function's
.prototype, itself inheriting %GeneratorPrototype%), else %GeneratorPrototype%."
  (let ((proto (let ((p (and (js-object-p fn) (js-get fn "prototype"))))
                 (if (js-object-p p) p (intrinsic :generator-prototype)))))
    (%make-js-generator :proto proto :coroutine co)))

(defun %this-generator (this)
  (if (js-generator-p this) this
      (throw-type-error "Generator method called on an incompatible receiver")))

(defun %generator-step (gen mode value)
  "Resume GEN's coroutine (§27.5.3 GeneratorResume/Return/Throw) → iterator result."
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
           (:return (setf (js-generator-done gen) t) (make-iter-result v t))
           (:throw (setf (js-generator-done gen) t) (throw-js-value v))))))))

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
    (obj-set-desc gp (well-known :iterator)
                  (data-pd (make-native-function "[Symbol.iterator]" 0
                             (lambda (this args) (declare (ignore args)) this))
                           :writable t :enumerable nil :configurable t))
    (obj-set-desc gp (well-known :to-string-tag)
                  (data-pd "Generator" :writable nil :enumerable nil :configurable t))))
