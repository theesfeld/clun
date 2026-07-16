;;;; async-function.lisp — async functions, await, async generators (PLAN.md Phase
;;;; 06, §27.7). All run on the coroutine primitive: `await e` suspends with kind
;;;; :await, and the driver resumes the coroutine (as a microtask) when e settles.
;;;; An async function returns a promise; an async generator is an async iterator.

(in-package :clun.engine)

;;; --- await -------------------------------------------------------------------

(defun await-value (co value)
  "Runs on the coroutine thread: suspend with the awaited value; the driver resumes
us with the settled result (:next) or the rejection (:throw)."
  (coroutine-suspend co :await value))

(defun %resume-on-settle (value on-step)
  "Schedule ON-STEP (a 2-arg fn of mode+value) to run when VALUE's promise settles.
The result capability is a throwaway — the async driver only wants the handler side."
  (let ((ap (base-resolve value)))
    (multiple-value-bind (rp res rej) (promise-and-caps)
      (declare (ignore rp))
      (perform-promise-then
       ap
       (make-native-function "" 1 (lambda (th a) (declare (ignore th)) (funcall on-step :next (arg a 0)) +undefined+))
       (make-native-function "" 1 (lambda (th a) (declare (ignore th)) (funcall on-step :throw (arg a 0)) +undefined+))
       res rej))))

;;; --- async functions ---------------------------------------------------------

(defun drive-async-function (co &optional (p (make-promise)))
  "Call an async function: run its body in CO up to the first await synchronously,
return the result promise, and resume across awaits via microtasks."
  (labels ((%step (mode value)
             (multiple-value-bind (kind v) (coroutine-resume co mode value)
               (ecase kind
                 (:await (%resume-on-settle v #'%step))
                 (:return (%resolve-promise p v))
                 (:throw (%reject-promise p v))))))
    (%step :next +undefined+))
  p)

(defun start-async-function (coroutine-thunk)
  "Create the result promise before parameter initialization and coroutine setup.
Any JavaScript abrupt completion from that setup rejects the promise instead of
escaping synchronously from the async call."
  (let ((promise (make-promise)))
    (handler-case
        (drive-async-function (funcall coroutine-thunk) promise)
      (js-condition (condition)
        (%reject-promise promise (js-condition-value condition))))
    promise))

;;; --- async generators --------------------------------------------------------
;;; A simplified AsyncGenerator: next/return/throw return promises. Serialized use
;;; (for-await awaits each next() before the next call) is fully supported; the spec
;;; request-queue for concurrent next() calls is deferred (Phase 25 if profiling shows).

(defstruct (js-async-generator (:include js-object (class :async-generator))
                               (:constructor %make-js-async-generator))
  coroutine (done nil))

(defun make-async-generator (fn co)
  "Create an async generator using FN.prototype when it is an object."
  (let ((prototype (let ((value (and (js-object-p fn) (js-get fn "prototype"))))
                     (if (js-object-p value)
                         value
                         (intrinsic :async-generator-prototype)))))
    (%make-js-async-generator :proto prototype :coroutine co)))

(defun this-async-generator (this)
  (if (js-async-generator-p this) this
      (throw-type-error "AsyncGenerator method called on an incompatible receiver")))

(defun %async-gen-drive (agen p mode value)
  (let ((co (js-async-generator-coroutine agen)))
    (labels ((%step (mode value)
               (multiple-value-bind (kind v) (coroutine-resume co mode value)
                 (ecase kind
                   (:yield (%resolve-promise p (make-iter-result v nil)))
                   (:await (%resume-on-settle v #'%step))
                   (:return (setf (js-async-generator-done agen) t) (%resolve-promise p (make-iter-result v t)))
                   (:throw (setf (js-async-generator-done agen) t) (%reject-promise p v))))))
      (%step mode value))))

(defun %async-gen-step (agen mode value)
  (let ((p (make-promise)))
    (if (js-async-generator-done agen)
        (ecase mode
          (:next (%resolve-promise p (make-iter-result +undefined+ t)))
          (:return (%resolve-promise p (make-iter-result value t)))
          (:throw (%reject-promise p value)))
        (%async-gen-drive agen p mode value))
    p))

;;; --- bootstrap: %AsyncIteratorPrototype% + %AsyncGeneratorPrototype% ---------

(defun build-async-function (args new-target)
  "CreateDynamicFunction for the async kind in the current realm."
  (let ((function (indirect-eval (dynamic-function-source args "async "))))
    ;; The emitter also selects this metadata for ordinary async syntax. Keep the
    ;; dynamic constructor explicit so its NewTarget-derived prototype is honored.
    (setf (js-object-proto function)
          (nt-prototype new-target (intrinsic :async-function-prototype))
          (js-function-function-kind function) :async
          (js-function-constructable function) nil)
    function))

(defun bootstrap-async-function ()
  (let* ((prototype (js-make-object (intrinsic :function-prototype)))
         (constructor nil))
    (setf constructor
          (make-native-function
           "AsyncFunction" 1
           (lambda (this args)
             (declare (ignore this))
             (build-async-function args constructor))
           :construct (lambda (args new-target)
                        (build-async-function args new-target))
           :proto (intrinsic :function-constructor)))
    (obj-set-desc constructor "prototype"
                  (data-pd prototype :writable nil :enumerable nil :configurable nil))
    (obj-set-desc prototype "constructor"
                  (data-pd constructor :writable nil :enumerable nil :configurable t))
    (obj-set-desc prototype (well-known :to-string-tag)
                  (data-pd "AsyncFunction" :writable nil :enumerable nil :configurable t))
    (setf (realm-intrinsic *realm* :async-function-prototype) prototype
          (realm-intrinsic *realm* :async-function-constructor) constructor)))

(defun build-async-generator-function (args new-target)
  "CreateDynamicFunction for the async-generator kind in the current realm."
  (let ((function
          (indirect-eval (dynamic-function-source args "async " t))))
    (setf (js-object-proto function)
          (nt-prototype new-target (intrinsic :async-generator-function-prototype))
          (js-function-function-kind function) :async-generator
          (js-function-constructable function) nil)
    function))

(defun bootstrap-async-generator-function (async-generator-prototype)
  "Install %AsyncGeneratorFunction% and its non-callable prototype object."
  (let* ((prototype (js-make-object (intrinsic :function-prototype)))
         (constructor nil))
    (setf constructor
          (make-native-function
           "AsyncGeneratorFunction" 1
           (lambda (this args)
             (declare (ignore this))
             (build-async-generator-function args constructor))
           :construct (lambda (args new-target)
                        (build-async-generator-function args new-target))
           :proto (intrinsic :function-constructor)))
    (obj-set-desc constructor "prototype"
                  (data-pd prototype :writable nil :enumerable nil :configurable nil))
    (obj-set-desc prototype "constructor"
                  (data-pd constructor :writable nil :enumerable nil :configurable t))
    (obj-set-desc prototype "prototype"
                  (data-pd async-generator-prototype
                           :writable nil :enumerable nil :configurable t))
    (obj-set-desc prototype (well-known :to-string-tag)
                  (data-pd "AsyncGeneratorFunction"
                           :writable nil :enumerable nil :configurable t))
    ;; %AsyncGeneratorPrototype%.constructor is the function-prototype object,
    ;; not the dynamic constructor itself.
    (obj-set-desc async-generator-prototype "constructor"
                  (data-pd prototype :writable nil :enumerable nil :configurable t))
    (setf (realm-intrinsic *realm* :async-generator-function-prototype) prototype
          (realm-intrinsic *realm* :async-generator-function-constructor) constructor)))

(defun %bootstrap-async ()
  (bootstrap-async-function)
  ;; %AsyncIteratorPrototype% (§27.1.3): @@asyncIterator returns this
  (let ((aip (js-make-object (intrinsic :object-prototype))))
    (setf (realm-intrinsic *realm* :async-iterator-prototype) aip)
    (obj-set-desc aip (well-known :async-iterator)
                  (data-pd (make-native-function "[Symbol.asyncIterator]" 0
                             (lambda (this args) (declare (ignore args)) this))
                           :writable t :enumerable nil :configurable t))
    ;; %AsyncGeneratorPrototype% : %AsyncIteratorPrototype%
    (let ((agp (js-make-object aip)))
      (setf (realm-intrinsic *realm* :async-generator-prototype) agp)
      (install-method agp "next" 1
        (lambda (this args) (%async-gen-step (this-async-generator this) :next (arg args 0))))
      (install-method agp "return" 1
        (lambda (this args) (%async-gen-step (this-async-generator this) :return (arg args 0))))
      (install-method agp "throw" 1
        (lambda (this args) (%async-gen-step (this-async-generator this) :throw (arg args 0))))
      (obj-set-desc agp (well-known :to-string-tag)
                    (data-pd "AsyncGenerator" :writable nil :enumerable nil :configurable t))
      (bootstrap-async-generator-function agp))))
