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
The result capability is a throwaway — the async driver only wants the handler side.
Return true when reactions were installed. A PromiseResolve setup failure returns
false plus its reason synchronously; callers feed that abrupt completion directly
back into their iterative driver."
  (handler-case
      (let ((ap (base-resolve value)))
        (multiple-value-bind (rp res rej) (promise-and-caps)
          (declare (ignore rp))
          (perform-promise-then
           ap
           (make-native-function "" 1
             (lambda (th a)
               (declare (ignore th))
               (funcall on-step :next (arg a 0))
               +undefined+))
           (make-native-function "" 1
             (lambda (th a)
               (declare (ignore th))
               (funcall on-step :throw (arg a 0))
               +undefined+))
           res rej)
          (values t +undefined+)))
    ;; PromiseResolve can fail while reading a Promise subclass's constructor.
    (js-condition (condition)
      (values nil (js-condition-value condition)))))

;;; --- async functions ---------------------------------------------------------

(defun drive-async-function (co &optional (p (make-promise)))
  "Call an async function: run its body in CO up to the first await synchronously,
return the result promise, and resume across awaits via microtasks."
  (labels ((%step (mode value)
             (loop
               (multiple-value-bind (kind v) (coroutine-resume co mode value)
                 (ecase kind
                   (:await
                    (multiple-value-bind (pending-p reason)
                        (%resume-on-settle v #'%step)
                      (when pending-p (return))
                      (setf mode :throw value reason)))
                   (:return (%resolve-promise p v) (return))
                   (:throw (%reject-promise p v) (return)))))))
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

(defstruct (async-generator-request (:constructor make-async-generator-request
                                                   (mode value promise resolve reject)))
  mode value promise resolve reject)

(defstruct (js-async-generator (:include js-object (class :async-generator))
                               (:constructor %make-js-async-generator))
  coroutine
  producer
  (state :suspended-start)
  request-head
  request-tail)

(defstruct (async-generator-producer
            (:constructor %make-async-generator-producer (&key cancel)))
  (state :traversing)
  (values #())
  (index 0 :type fixnum)
  failure
  cancel)

(defun make-async-generator (fn co)
  "Create an async generator using FN.prototype when it is an object."
  (let ((prototype (let ((value (and (js-object-p fn) (js-get fn "prototype"))))
                     (if (js-object-p value)
                         value
                         (intrinsic :async-generator-prototype)))))
    (%make-js-async-generator :proto prototype :coroutine co)))

(defun make-producer-async-generator (&key cancel)
  "A real AsyncGenerator with no coroutine or per-instance thread."
  (%make-js-async-generator
   :proto (intrinsic :async-generator-prototype)
   :producer (%make-async-generator-producer :cancel cancel)))

(defun async-generator-producer-ready (generator values)
  "Commit worker VALUES to a traversing producer and drain queued requests."
  (let ((producer (and (js-async-generator-p generator)
                       (js-async-generator-producer generator))))
    (when (and producer (eq (async-generator-producer-state producer) :traversing))
      (setf (async-generator-producer-values producer) (coerce values 'vector)
            (async-generator-producer-state producer) :ready)
      (%async-gen-resume-next generator)
      t)))

(defun async-generator-producer-failed (generator reason)
  "Commit worker failure REASON to a traversing producer."
  (let ((producer (and (js-async-generator-p generator)
                       (js-async-generator-producer generator))))
    (when (and producer (eq (async-generator-producer-state producer) :traversing))
      (setf (async-generator-producer-failure producer) reason
            (async-generator-producer-state producer) :failed)
      (%async-gen-resume-next generator)
      t)))

(defun %async-gen-enqueue-request (agen request)
  (let ((cell (list request)))
    (if (js-async-generator-request-tail agen)
        (setf (cdr (js-async-generator-request-tail agen)) cell)
        (setf (js-async-generator-request-head agen) cell))
    (setf (js-async-generator-request-tail agen) cell)))

(defun %async-gen-current-request (agen)
  (car (js-async-generator-request-head agen)))

(defun %async-gen-pop-request (agen)
  (let ((request (%async-gen-current-request agen)))
    (setf (js-async-generator-request-head agen)
          (cdr (js-async-generator-request-head agen)))
    (unless (js-async-generator-request-head agen)
      (setf (js-async-generator-request-tail agen) nil))
    request))

(defun %async-gen-resolve-current (agen value done)
  (let ((request (%async-gen-pop-request agen)))
    (js-call (async-generator-request-resolve request) +undefined+
             (list (make-iter-result value done)))))

(defun %async-gen-reject-current (agen reason)
  (let ((request (%async-gen-pop-request agen)))
    (js-call (async-generator-request-reject request) +undefined+ (list reason))))

(defun %async-gen-active-p (agen)
  (member (js-async-generator-state agen)
          '(:executing :awaiting-value :awaiting-return)))

(defun %producer-abrupt-request-p (agen)
  (loop for cell on (js-async-generator-request-head agen)
        thereis (not (eq (async-generator-request-mode (car cell)) :next))))

(defun %complete-producer (agen)
  (setf (js-async-generator-state agen) :completed
        (js-async-generator-producer agen) nil))

(defun %async-producer-resume-next (agen producer)
  (case (async-generator-producer-state producer)
    (:traversing
     ;; An abrupt request wins cancellation even behind already-pending nexts.
     (when (%producer-abrupt-request-p agen)
       (setf (async-generator-producer-state producer) :cancelling)
       (let ((cancel (async-generator-producer-cancel producer)))
         (when cancel (funcall cancel)))
       (%complete-producer agen)
       (%async-gen-resume-next agen)))
    (:ready
     (loop while (js-async-generator-request-head agen) do
       (let* ((request (%async-gen-current-request agen))
              (mode (async-generator-request-mode request))
              (index (async-generator-producer-index producer))
              (values (async-generator-producer-values producer)))
         (cond
           ((not (eq mode :next))
            (%complete-producer agen)
            (%async-gen-resume-next agen)
            (return))
           ((< index (length values))
            (incf (async-generator-producer-index producer))
            (%async-gen-resolve-current agen (aref values index) nil))
           (t
            (%complete-producer agen)
            (%async-gen-resolve-current agen +undefined+ t)
            (%async-gen-resume-next agen)
            (return))))))
    (:failed
     (when (js-async-generator-request-head agen)
       (let ((request (%async-gen-current-request agen)))
         (if (eq (async-generator-request-mode request) :next)
             (progn
               (%async-gen-reject-current agen
                                          (async-generator-producer-failure producer))
               (%complete-producer agen))
             (%complete-producer agen))
         (%async-gen-resume-next agen)))))
  nil)

(defun %async-gen-resume-next (agen)
  "Run queued requests in FIFO order until the coroutine or an adopted value waits."
  (let ((producer (js-async-generator-producer agen)))
    (when producer
      (%async-producer-resume-next agen producer)
      (return-from %async-gen-resume-next nil)))
  (loop
    (when (or (null (js-async-generator-request-head agen))
              (%async-gen-active-p agen))
      (return))
    (let* ((request (%async-gen-current-request agen))
           (mode (async-generator-request-mode request))
           (value (async-generator-request-value request))
           (state (js-async-generator-state agen)))
      (cond
        ((eq state :completed)
         (ecase mode
           (:next (%async-gen-resolve-current agen +undefined+ t))
           (:throw (%async-gen-reject-current agen value))
           (:return
            (setf (js-async-generator-state agen) :awaiting-return)
            (multiple-value-bind (pending-p reason)
                (%resume-on-settle
                 value
                 (lambda (settled-mode settled-value)
                   (setf (js-async-generator-state agen) :completed)
                   (if (eq settled-mode :next)
                       (%async-gen-resolve-current agen settled-value t)
                       (%async-gen-reject-current agen settled-value))
                   (%async-gen-resume-next agen)))
              (if pending-p
                  (return)
                  (progn
                    (setf (js-async-generator-state agen) :completed)
                    (%async-gen-reject-current agen reason)))))))
        ((and (eq state :suspended-start) (not (eq mode :next)))
         ;; An abrupt request before the first next closes without starting the
         ;; coroutine. A return still Await-adopts its value.
         (complete-unstarted-coroutine (js-async-generator-coroutine agen))
         (setf (js-async-generator-state agen) :completed)
         (if (eq mode :throw)
             (%async-gen-reject-current agen value)
             (progn
               (setf (js-async-generator-state agen) :awaiting-return)
               (multiple-value-bind (pending-p reason)
                   (%resume-on-settle
                    value
                    (lambda (settled-mode settled-value)
                      (setf (js-async-generator-state agen) :completed)
                      (if (eq settled-mode :next)
                          (%async-gen-resolve-current agen settled-value t)
                          (%async-gen-reject-current agen settled-value))
                      (%async-gen-resume-next agen)))
                 (if pending-p
                     (return)
                     (progn
                       (setf (js-async-generator-state agen) :completed)
                       (%async-gen-reject-current agen reason)))))))
        ((and (eq state :suspended-yield) (eq mode :return))
         ;; AsyncGeneratorYield awaits the return resumption value before the
         ;; completion is injected at the suspended yield expression.
         (setf (js-async-generator-state agen) :awaiting-return)
         (multiple-value-bind (pending-p reason)
             (%resume-on-settle
              value
              (lambda (settled-mode settled-value)
                (%async-gen-drive agen
                                  (if (eq settled-mode :next) :return :throw)
                                  settled-value)))
           (if pending-p
               (return)
               (%async-gen-drive agen :throw reason nil)))
         (when (%async-gen-active-p agen) (return)))
        (t
         (%async-gen-drive agen mode value nil)
         (when (%async-gen-active-p agen) (return)))))))

(defun %async-gen-drive (agen mode value &optional (drain-queue-p t))
  "Resume the single coroutine driver for the current queued request."
  (loop
    (setf (js-async-generator-state agen) :executing)
    (multiple-value-bind (kind result)
        (coroutine-resume (js-async-generator-coroutine agen) mode value)
      (ecase kind
        (:yield
         ;; AsyncGeneratorYield awaits even a plain yield operand. A rejection is
         ;; thrown back into the same suspension and therefore may be caught there.
         (setf (js-async-generator-state agen) :awaiting-value)
         (multiple-value-bind (pending-p reason)
             (%resume-on-settle
              result
              (lambda (settled-mode settled-value)
                (if (eq settled-mode :next)
                    (progn
                      (setf (js-async-generator-state agen) :suspended-yield)
                      (%async-gen-resolve-current agen settled-value nil)
                      (%async-gen-resume-next agen))
                    (%async-gen-drive agen :throw settled-value))))
           (when pending-p (return))
           (setf mode :throw value reason)))
        (:yield-no-await
         ;; Async yield* has already Awaited the iterator result's value.
         (setf (js-async-generator-state agen) :suspended-yield)
         (%async-gen-resolve-current agen result nil)
         (return))
        (:await
         (setf (js-async-generator-state agen) :awaiting-value)
         (multiple-value-bind (pending-p reason)
             (%resume-on-settle
              result
              (lambda (settled-mode settled-value)
                (%async-gen-drive agen settled-mode settled-value)))
           (when pending-p (return))
           (setf mode :throw value reason)))
        (:return
         ;; Explicit async-generator return expressions are Awaited in the emitter;
         ;; an implicit fallthrough is resolved directly without an extra tick.
         (setf (js-async-generator-state agen) :completed)
         (%async-gen-resolve-current agen result t)
         (return))
        (:throw
         (setf (js-async-generator-state agen) :completed)
         (%async-gen-reject-current agen result)
         (return)))))
  (when (and drain-queue-p (not (%async-gen-active-p agen)))
    (%async-gen-resume-next agen)))

(defun %async-gen-enqueue (this mode value)
  "AsyncGeneratorEnqueue: always return a promise, rejecting invalid receivers."
  (multiple-value-bind (promise resolve reject) (promise-and-caps)
    (if (not (js-async-generator-p this))
        (js-call reject +undefined+
                 (list (%promise-type-error
                        "AsyncGenerator method called on an incompatible receiver")))
        (progn
          (%async-gen-enqueue-request
           this (make-async-generator-request mode value promise resolve reject))
          (unless (%async-gen-active-p this)
            (%async-gen-resume-next this))))
    promise))

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
        (lambda (this args) (%async-gen-enqueue this :next (arg args 0))))
      (install-method agp "return" 1
        (lambda (this args) (%async-gen-enqueue this :return (arg args 0))))
      (install-method agp "throw" 1
        (lambda (this args) (%async-gen-enqueue this :throw (arg args 0))))
      (obj-set-desc agp (well-known :to-string-tag)
                    (data-pd "AsyncGenerator" :writable nil :enumerable nil :configurable t))
      (bootstrap-async-generator-function agp))))
