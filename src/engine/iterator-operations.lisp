;;;; iterator-operations.lisp -- shared synchronous iterator abstract operations.

(in-package :clun.engine)

(defstruct (iterator-record
            (:constructor %make-iterator-record (iterator next-method))
            (:copier nil))
  iterator
  next-method
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
