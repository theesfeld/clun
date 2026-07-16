;;;; iterator-operations.lisp -- shared iterator abstract operations.

(in-package :clun.engine)

(defstruct (iterator-record
            (:constructor %make-iterator-record (iterator next-method))
            (:copier nil))
  iterator
  next-method
  (done nil))

;;; Async-from-sync is a real iterator adapter, not a flag on a synchronous
;;; record.  Its methods return promises and normalize each synchronous result
;;; into a fresh iterator-result object after adopting its value.

(defstruct (async-from-sync-iterator-record
            (:constructor %make-async-from-sync-iterator-record
                (iterator next-method))
            (:copier nil))
  iterator
  next-method
  (done nil))

(defstruct (async-iterator-record
            (:constructor %make-async-iterator-record
                (iterator next-method &optional from-sync))
            (:copier nil))
  iterator
  next-method
  from-sync
  (done nil))

(defun get-iterator-record (obj &optional method)
  "Return a synchronous iterator record for OBJ, caching its next method once."
  (let ((iterator-method (or method (get-method obj (well-known :iterator)))))
    (when (js-undefined-p iterator-method)
      (throw-type-error "value is not iterable"))
    (unless (callable-p iterator-method)
      (throw-type-error "iterator method is not callable"))
    (let ((iterator (js-call iterator-method obj '())))
      (unless (js-object-p iterator)
        (throw-type-error "iterator is not an object"))
      (let ((next-method (js-get iterator "next")))
        (%make-iterator-record iterator next-method)))))

(defun iterator-next (record &optional (value +undefined+ value-supplied-p))
  "Call the cached next method and validate the iterator result object."
  (handler-case
      (let ((result (js-call (iterator-record-next-method record)
                             (iterator-record-iterator record)
                             (if value-supplied-p (list value) '()))))
        (unless (js-object-p result)
          (setf (iterator-record-done record) t)
          (throw-type-error "iterator result is not an object"))
        result)
    (js-condition (condition)
      (setf (iterator-record-done record) t)
      (error condition))))

(defun iterator-complete (record result)
  "Read and coerce RESULT.done, marking protocol failures terminal."
  (handler-case
      (let ((done (js-truthy (js-get result "done"))))
        (when done (setf (iterator-record-done record) t))
        done)
    (js-condition (condition)
      (setf (iterator-record-done record) t)
      (error condition))))

(defun iterator-value (record result)
  "Read RESULT.value, marking a throwing getter terminal."
  (handler-case (js-get result "value")
    (js-condition (condition)
      (setf (iterator-record-done record) t)
      (error condition))))

(defun iterator-step (record &optional (value +undefined+ value-supplied-p))
  "Return the next iterator result, or NIL after marking RECORD done."
  (unless (iterator-record-done record)
    (let ((result (if value-supplied-p
                      (iterator-next record value)
                      (iterator-next record))))
      (unless (iterator-complete record result) result))))

(defun iterator-step-value (record)
  "Return VALUE,DONE for one iterator step, marking protocol failures terminal."
  (let ((result (iterator-step record)))
    (if (null result)
        (values +undefined+ t)
        (values (iterator-value record result) nil))))

(defun %perform-iterator-close (record)
  (setf (iterator-record-done record) t)
  (let ((return-method (get-method (iterator-record-iterator record) "return")))
    (unless (js-undefined-p return-method)
      (let ((result (js-call return-method (iterator-record-iterator record) '())))
        (unless (js-object-p result)
          (throw-type-error "iterator return result is not an object")))))
  +undefined+)

(defun iterator-close (record &key throw-completion-p)
  "Close RECORD once. An in-flight JS throw has precedence over close failures."
  (unless (iterator-record-done record)
    (if throw-completion-p
        (handler-case (%perform-iterator-close record)
          (js-condition () +undefined+))
        (%perform-iterator-close record)))
  +undefined+)

(defun call-with-iterator-close-on-abrupt (record thunk)
  "Run THUNK and close RECORD only when control leaves it abruptly."
  (let ((completed nil)
        (throw-completion-p nil))
    (unwind-protect
         (multiple-value-prog1
             (handler-case (funcall thunk)
               (js-condition (condition)
                 (setf throw-completion-p t)
                 (error condition)))
           (setf completed t))
      (unless completed
        (iterator-close record :throw-completion-p throw-completion-p)))))

(defun iterator-record->list (record)
  (let ((values '()))
    (loop
      (multiple-value-bind (value done) (iterator-step-value record)
        (when done (return (nreverse values)))
        (push value values)))))

(defun iterable->list (obj)
  "Consume OBJ through its observable synchronous iterator protocol."
  (iterator-record->list (get-iterator-record obj)))

(defun iterable->list-protocol (obj)
  (iterable->list obj))

;;; --- asynchronous iteration -------------------------------------------------

(defun %new-iterator-result (value done)
  ;; Kept local because this file loads before builtins-iterator.lisp.
  (let ((result (new-object)))
    (create-data-property result "value" value)
    (create-data-property result "done" (js-boolean done))
    result))

(defun %reject-iterator-promise (promise condition)
  (%reject-promise promise (js-condition-value condition))
  promise)

(defun %close-sync-iterator (record &key throw-completion-p)
  "Close an AsyncFromSync adapter's underlying iterator synchronously."
  (unless (async-from-sync-iterator-record-done record)
    (setf (async-from-sync-iterator-record-done record) t)
    (flet ((finish-close ()
             (let ((return-method
                     (get-method
                      (async-from-sync-iterator-record-iterator record)
                      "return")))
               (unless (js-undefined-p return-method)
                 (let ((result
                         (js-call
                          return-method
                          (async-from-sync-iterator-record-iterator record)
                          '())))
                   (unless (js-object-p result)
                     (throw-type-error
                      "iterator return result is not an object")))))))
      (if throw-completion-p
          (handler-case (finish-close)
            (js-condition () +undefined+))
          (finish-close))))
  +undefined+)

(defun %async-from-sync-continuation
    (record result promise &key close-on-rejection)
  "Adopt RESULT.value and settle PROMISE with a fresh iterator result."
  (unless (js-object-p result)
    (throw-type-error "iterator result is not an object"))
  (let* ((done (js-truthy (js-get result "done")))
         (value (js-get result "value"))
         (value-promise
           (handler-case (base-resolve value)
             (js-condition (condition)
               (when (and close-on-rejection (not done))
                 (%close-sync-iterator record :throw-completion-p t))
               (%reject-promise promise (js-condition-value condition))
               (return-from %async-from-sync-continuation promise)))))
    (when done
      (setf (async-from-sync-iterator-record-done record) t))
    (multiple-value-bind (resolve reject) (make-resolving-functions promise)
      (perform-promise-then
       value-promise
       (make-native-function
        "" 1
        (lambda (this args)
          (declare (ignore this))
          (%new-iterator-result (arg args 0) done)))
       (and close-on-rejection
            (not done)
            (make-native-function
             "" 1
             (lambda (this args)
               (declare (ignore this))
               ;; A rejected yielded value closes the synchronous source, but
               ;; the rejection itself retains precedence over close failures.
               (%close-sync-iterator record :throw-completion-p t)
               (throw-js-value (arg args 0)))))
       resolve reject)))
  promise)

(defun async-from-sync-iterator-next
    (record &optional (value +undefined+ value-supplied-p))
  (let ((promise (make-promise)))
    (handler-case
        (%async-from-sync-continuation
         record
         (js-call (async-from-sync-iterator-record-next-method record)
                  (async-from-sync-iterator-record-iterator record)
                  (if value-supplied-p (list value) '()))
         promise
         :close-on-rejection t)
      (js-condition (condition)
        (%reject-iterator-promise promise condition)))
    promise))

(defun async-from-sync-iterator-return
    (record &optional (value +undefined+ value-supplied-p))
  (let ((promise (make-promise)))
    (handler-case
        (let ((return-method
                (get-method
                 (async-from-sync-iterator-record-iterator record)
                 "return")))
          (if (js-undefined-p return-method)
              (progn
                (setf (async-from-sync-iterator-record-done record) t)
                (%resolve-promise promise (%new-iterator-result value t)))
              (%async-from-sync-continuation
               record
               (js-call return-method
                        (async-from-sync-iterator-record-iterator record)
                        (if value-supplied-p (list value) '()))
               promise)))
      (js-condition (condition)
        (%reject-iterator-promise promise condition)))
    promise))

(defun async-from-sync-iterator-throw
    (record &optional (value +undefined+ value-supplied-p))
  (let ((promise (make-promise)))
    (handler-case
        (let ((throw-method
                (get-method
                 (async-from-sync-iterator-record-iterator record)
                 "throw")))
          (if (js-undefined-p throw-method)
              (progn
                ;; Missing throw performs a normal IteratorClose first.  A
                ;; close failure wins; otherwise reject with the protocol error.
                (%close-sync-iterator record)
                (%reject-promise
                 promise
                 (%promise-type-error "iterator has no throw method")))
              (%async-from-sync-continuation
               record
               (js-call throw-method
                        (async-from-sync-iterator-record-iterator record)
                        (if value-supplied-p (list value) '()))
               promise
               :close-on-rejection t)))
      (js-condition (condition)
        (%reject-iterator-promise promise condition)))
    promise))

(defun get-async-iterator-record (obj)
  "GetAsyncIterator: prefer @@asyncIterator, otherwise create AsyncFromSync."
  (let ((async-method (get-method obj (well-known :async-iterator))))
    (if (not (js-undefined-p async-method))
        (let ((iterator (js-call async-method obj '())))
          (unless (js-object-p iterator)
            (throw-type-error "iterator is not an object"))
          (%make-async-iterator-record iterator (js-get iterator "next")))
        (let* ((sync-record (get-iterator-record obj))
               (adapter
                 (%make-async-from-sync-iterator-record
                  (iterator-record-iterator sync-record)
                  (iterator-record-next-method sync-record))))
          (%make-async-iterator-record
           (async-from-sync-iterator-record-iterator adapter)
           (async-from-sync-iterator-record-next-method adapter)
           adapter)))))

(defun async-iterator-next
    (record &optional (value +undefined+ value-supplied-p))
  "Invoke an async iterator's cached next method, returning its raw promise/value."
  (let ((adapter (async-iterator-record-from-sync record)))
    (if adapter
        (if value-supplied-p
            (async-from-sync-iterator-next adapter value)
            (async-from-sync-iterator-next adapter))
        (js-call (async-iterator-record-next-method record)
                 (async-iterator-record-iterator record)
                 (if value-supplied-p (list value) '())))))

(defun async-iterator-return
    (record &optional (value +undefined+ value-supplied-p))
  "Invoke return. The second value says whether the async iterator has the method."
  (let ((adapter (async-iterator-record-from-sync record)))
    (if adapter
        (values
         (if value-supplied-p
             (async-from-sync-iterator-return adapter value)
             (async-from-sync-iterator-return adapter))
         t)
        (let ((return-method
                (get-method (async-iterator-record-iterator record) "return")))
          (if (js-undefined-p return-method)
              (values +undefined+ nil)
              (values
               (js-call return-method
                        (async-iterator-record-iterator record)
                        (if value-supplied-p (list value) '()))
               t))))))

(defun async-iterator-throw
    (record &optional (value +undefined+ value-supplied-p))
  "Invoke throw. AsyncFromSync always exposes the adapter's throwing method."
  (let ((adapter (async-iterator-record-from-sync record)))
    (if adapter
        (values
         (if value-supplied-p
             (async-from-sync-iterator-throw adapter value)
             (async-from-sync-iterator-throw adapter))
         t)
        (let ((throw-method
                (get-method (async-iterator-record-iterator record) "throw")))
          (if (js-undefined-p throw-method)
              (values +undefined+ nil)
              (values
               (js-call throw-method
                        (async-iterator-record-iterator record)
                        (if value-supplied-p (list value) '()))
               t))))))
