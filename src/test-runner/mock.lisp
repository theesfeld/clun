;;;; mock.lisp -- Jest/Bun-compatible function mocks and spies for `clun test`.
;;;; Mock state belongs to one test-context and is removed before realm teardown.

(in-package :clun.test-runner)

(defstruct (mock-action (:conc-name action-))
  (kind :call) value)

(defstruct (mock-result (:conc-name result-))
  kind value)

(defstruct (mock-record (:conc-name mock-))
  function context
  implementation
  (once '())
  (calls '())
  (results '())
  (contexts '())
  (instances '())
  (orders '())
  (name "mockConstructor")
  spy-owner spy-key spy-original (spy-had-own nil) (restored nil))

(defvar *mock-records* (make-hash-table :test #'eq))

(defun mock-record-for (value)
  (and (eng:js-object-p value) (gethash value *mock-records*)))

(defun %mock-array (values)
  (eng:new-array values))

(defun %mock-call-array (calls)
  (%mock-array (mapcar #'%mock-array calls)))

(defun %mock-result-object (entry)
  (let ((o (eng:new-object)))
    (eng:data-prop o "type" (ecase (result-kind entry)
                              (:return "return")
                              (:throw "throw")))
    (eng:data-prop o "value" (result-value entry))
    o))

(defun %mock-metadata (record)
  (let* ((calls (reverse (mock-calls record)))
         (results (reverse (mock-results record)))
         (contexts (reverse (mock-contexts record)))
         (instances (reverse (mock-instances record)))
         (orders (reverse (mock-orders record)))
         (o (eng:new-object)))
    (eng:data-prop o "calls" (%mock-call-array calls))
    (eng:data-prop o "results" (%mock-array (mapcar #'%mock-result-object results)))
    (eng:data-prop o "contexts" (%mock-array contexts))
    (eng:data-prop o "instances" (%mock-array instances))
    (eng:data-prop o "invocationCallOrder"
                   (%mock-array (mapcar (lambda (n) (coerce n 'double-float)) orders)))
    (eng:data-prop o "lastCall" (if calls (%mock-array (car (last calls))) eng:+undefined+))
    o))

(defun %mock-clear (record)
  (setf (mock-calls record) '()
        (mock-results record) '()
        (mock-contexts record) '()
        (mock-instances record) '()
        (mock-orders record) '())
  record)

(defun %mock-reset (record)
  (%mock-clear record)
  (setf (mock-implementation record) nil
        (mock-once record) '())
  record)

(defun %mock-restore (record)
  (unless (mock-restored record)
    (let ((owner (mock-spy-owner record)))
      (when owner
        (if (mock-spy-had-own record)
            (eng:js-set owner (mock-spy-key record) (mock-spy-original record) t)
            (eng:js-delete owner (mock-spy-key record) t))))
    (setf (mock-restored record) t))
  (%mock-reset record))

(defun %mock-promise (kind value)
  (let ((promise (eng:js-get (eng:realm-global eng:*realm*) "Promise")))
    (eng:js-call (eng:js-get promise (ecase kind (:resolve "resolve") (:reject "reject")))
                 promise (list value))))

(defun %mock-run-action (action this args)
  (if (null action)
      eng:+undefined+
      (ecase (action-kind action)
        (:call (eng:js-call (action-value action) this args))
        (:return (action-value action))
        (:return-this this)
        (:resolve (%mock-promise :resolve (action-value action)))
        (:reject (%mock-promise :reject (action-value action))))))

(defun %mock-invoke (record this args instance)
  (let* ((ctx (mock-context record))
         (action (if (mock-once record)
                     (pop (mock-once record))
                     (mock-implementation record))))
    (incf (ctx-invocation-order ctx))
    (push (copy-list args) (mock-calls record))
    (push this (mock-contexts record))
    (push instance (mock-instances record))
    (push (ctx-invocation-order ctx) (mock-orders record))
    (handler-case
        (let ((value (%mock-run-action action this args)))
          (push (make-mock-result :kind :return :value value) (mock-results record))
          value)
      (eng:js-condition (condition)
        (let ((value (eng:js-condition-value condition)))
          (push (make-mock-result :kind :throw :value value) (mock-results record))
          (eng:throw-js-value value))))))

(defun %queue-action (record kind value)
  (setf (mock-once record)
        (nconc (mock-once record) (list (make-mock-action :kind kind :value value)))))

(defun %set-action (record kind value)
  (setf (mock-implementation record) (make-mock-action :kind kind :value value)))

(defun %require-callable (value operation)
  (unless (eng:callable-p value)
    (eng:throw-type-error (format nil "~a requires a function" operation)))
  value)

(defun %install-mock-methods (record)
  (let ((fn (mock-function record)))
    (eng:install-getter fn "mock"
      (lambda (this args)
        (declare (ignore this args))
        (%mock-metadata record)))
    (eng:install-method fn "getMockName" 0
      (lambda (this args) (declare (ignore this args)) (mock-name record)))
    (eng:install-method fn "getMockImplementation" 0
      (lambda (this args)
        (declare (ignore this args))
        (let ((action (mock-implementation record)))
          (if (and action (eq (action-kind action) :call))
              (action-value action)
              eng:+undefined+))))
    (eng:install-method fn "mockName" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((name (eng:arg args 0)))
          (when (and (eng:js-string-p name) (plusp (length name)))
            (setf (mock-name record) name)))
        fn))
    (eng:install-method fn "mockClear" 0
      (lambda (this args) (declare (ignore this args)) (%mock-clear record) fn))
    (eng:install-method fn "mockReset" 0
      (lambda (this args) (declare (ignore this args)) (%mock-reset record) fn))
    (eng:install-method fn "mockRestore" 0
      (lambda (this args) (declare (ignore this args)) (%mock-restore record) fn))
    (eng:install-method fn "mockImplementation" 1
      (lambda (this args)
        (declare (ignore this))
        (%set-action record :call (%require-callable (eng:arg args 0) "mockImplementation"))
        fn))
    (eng:install-method fn "mockImplementationOnce" 1
      (lambda (this args)
        (declare (ignore this))
        (%queue-action record :call (%require-callable (eng:arg args 0) "mockImplementationOnce"))
        fn))
    (dolist (entry '(("mockReturnValue" :return nil)
                     ("mockReturnValueOnce" :return t)
                     ("mockResolvedValue" :resolve nil)
                     ("mockResolvedValueOnce" :resolve t)
                     ("mockRejectedValue" :reject nil)
                     ("mockRejectedValueOnce" :reject t)))
      (destructuring-bind (name kind once-p) entry
        (eng:install-method fn name 1
          (lambda (this args)
            (declare (ignore this))
            (if once-p
                (%queue-action record kind (eng:arg args 0))
                (%set-action record kind (eng:arg args 0)))
            fn))))
    (eng:install-method fn "mockReturnThis" 0
      (lambda (this args)
        (declare (ignore this args))
        (%set-action record :return-this eng:+undefined+)
        fn))
    (eng:install-method fn "withImplementation" 2
      (lambda (this args)
        (declare (ignore this))
        (let ((replacement (%require-callable (eng:arg args 0) "withImplementation"))
              (callback (%require-callable (eng:arg args 1) "withImplementation"))
              (saved (mock-implementation record)))
          (setf (mock-implementation record) (make-mock-action :kind :call :value replacement))
          (handler-case
              (let ((value (eng:js-call callback eng:+undefined+ '())))
                (if (eng:js-promise-p value)
                    (eng:js-call
                     (eng:js-get value "then") value
                     (list
                      (%fn "" 1 (lambda (th a)
                                   (declare (ignore th))
                                   (setf (mock-implementation record) saved)
                                   (eng:arg a 0)))
                      (%fn "" 1 (lambda (th a)
                                   (declare (ignore th))
                                   (setf (mock-implementation record) saved)
                                   (eng:throw-js-value (eng:arg a 0))))))
                    (progn (setf (mock-implementation record) saved) value)))
            (eng:js-condition (condition)
              (setf (mock-implementation record) saved)
              (eng:throw-js-value (eng:js-condition-value condition)))))))
    fn))

(defun %make-mock (ctx implementation)
  (when (and implementation (not (eng:js-undefined-p implementation)))
    (%require-callable implementation "mock"))
  (let ((record nil) (fn nil))
    (setf fn
          (eng:make-native-function
           (if (and implementation (eng:callable-p implementation))
               (let ((name (eng:function-name implementation)))
                 (if (and name (plusp (length name))) name "mockConstructor"))
               "mockConstructor")
           (if (and implementation (eng:callable-p implementation))
               (truncate (eng:to-number (eng:js-get implementation "length")))
               0)
           (lambda (this args)
             (%mock-invoke record this args eng:+undefined+))
           :construct
           (lambda (args new-target)
             (declare (ignore new-target))
             (let* ((proto (eng:js-get fn "prototype"))
                    (instance (eng:new-object (if (eng:js-object-p proto) proto
                                                 (eng:intrinsic :object-prototype))))
                    (value (%mock-invoke record instance args instance)))
               (if (eng:js-object-p value) value instance)))))
    (let ((proto (eng:new-object)))
      (eng:hidden-prop proto "constructor" fn)
      (eng:hidden-prop fn "prototype" proto))
    (setf record (make-mock-record
                  :function fn :context ctx
                  :implementation (and implementation
                                       (not (eng:js-undefined-p implementation))
                                       (make-mock-action :kind :call :value implementation))
                  :name (if (and implementation (eng:callable-p implementation))
                            (let ((name (eng:function-name implementation)))
                              (if (and name (plusp (length name))) name "mockConstructor"))
                            "mockConstructor")))
    (setf (gethash fn *mock-records*) record)
    (push record (ctx-mocks ctx))
    (%install-mock-methods record)))

(defun %find-spy (ctx owner key)
  (find-if (lambda (record)
             (and (eq owner (mock-spy-owner record))
                  (string= key (mock-spy-key record))
                  (not (mock-restored record))))
           (ctx-mocks ctx)))

(defun %spy-on (ctx owner raw-key)
  (unless (eng:js-object-p owner)
    (eng:throw-type-error "spyOn requires an object"))
  (let* ((key (eng:to-string raw-key))
         (prior (%find-spy ctx owner key)))
    (when prior (return-from %spy-on (mock-function prior)))
    (let* ((had-own (eng:has-own-property owner key))
           (original (eng:js-get owner key)))
      (%require-callable original "spyOn")
      (let* ((fn (%make-mock ctx original))
             (record (mock-record-for fn)))
        (setf (mock-spy-owner record) owner
              (mock-spy-key record) key
              (mock-spy-original record) original
              (mock-spy-had-own record) had-own)
        (eng:js-set owner key fn t)
        fn))))

(defun %for-each-mock (ctx function)
  (dolist (record (copy-list (ctx-mocks ctx)))
    (funcall function record)))

(defun restore-test-mocks (ctx)
  (restore-fake-timers ctx)
  (%for-each-mock ctx (lambda (record)
                        (when (mock-spy-owner record) (%mock-restore record))
                        (remhash (mock-function record) *mock-records*)))
  (setf (ctx-mocks ctx) '())
  ctx)

(defun %module-mock (realm ctx specifier factory)
  ;; Validate both arguments before resolution. This is observable for missing package
  ;; names because an invalid call must not enter the resolver or registry client.
  (unless (eng:js-string-p specifier)
    (eng:throw-type-error "mock(module, fn) requires a module name string"))
  (unless (eng:callable-p factory)
    (eng:throw-type-error "mock(module, fn) requires a function"))
  (multiple-value-bind (kind value)
      (eng:run-callback-to-settlement
       (lambda () (eng:js-call factory eng:+undefined+ '()))
       realm :timeout-ms (ctx-default-timeout ctx))
    (case kind
      (:rejected (eng:throw-js-value value))
      (:timeout (eng:throw-type-error "mock(module, fn) factory timed out"))
      (:fulfilled
       (unless (eng:js-object-p value)
         (eng:throw-type-error "mock(module, fn) must return an object"))
       (eng:register-module-mock realm specifier
                                 (sys:path-dirname (ctx-path ctx)) value)
       eng:+undefined+))))

(defun install-test-mocks (realm ctx)
  (let* ((eng:*realm* realm)
         (global (eng:realm-global realm))
         (mock-fn (%fn "mock" 1
                    (lambda (this args)
                      (declare (ignore this))
                      (%make-mock ctx (eng:arg args 0)))))
         (spy-fn (%fn "spyOn" 2
                   (lambda (this args)
                     (declare (ignore this))
                     (%spy-on ctx (eng:arg args 0) (eng:arg args 1)))))
         (module-fn (%fn "module" 2
                      (lambda (this args)
                        (declare (ignore this))
                        (%module-mock realm ctx (eng:arg args 0) (eng:arg args 1)))))
         (jest (eng:new-object)))
    (eng:hidden-prop mock-fn "module" module-fn)
    (eng:install-method mock-fn "restore" 0
      (lambda (this args)
        (declare (ignore this args))
        (%for-each-mock ctx (lambda (record)
                              (when (mock-spy-owner record) (%mock-restore record))))
        eng:+undefined+))
    (eng:data-prop jest "fn" mock-fn)
    (eng:data-prop jest "spyOn" spy-fn)
    (eng:data-prop jest "mock" module-fn)
    (eng:install-method jest "clearAllMocks" 0
      (lambda (this args)
        (declare (ignore this args))
        (%for-each-mock ctx #'%mock-clear)
        eng:+undefined+))
    (eng:install-method jest "resetAllMocks" 0
      (lambda (this args)
        (declare (ignore this args))
        (%for-each-mock ctx #'%mock-reset)
        eng:+undefined+))
    (eng:install-method jest "restoreAllMocks" 0
      (lambda (this args)
        (declare (ignore this args))
        (%for-each-mock ctx (lambda (record)
                              (when (mock-spy-owner record) (%mock-restore record))))
        eng:+undefined+))
    (install-fake-timers realm ctx jest)
    (eng:hidden-prop global "mock" mock-fn)
    (eng:hidden-prop global "spyOn" spy-fn)
    (eng:hidden-prop global "jest" jest)
    (eng:hidden-prop global "vi" jest)
    ctx))
