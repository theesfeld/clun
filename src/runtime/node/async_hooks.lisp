;;;; async_hooks.lisp — node:async_hooks (AsyncLocalStorage + AsyncResource).
;;;; Pure-CL store stack; exceeds Bun by exposing createHook + executionAsyncId.
;;;; enterWith / run / getStore / exit / disable are real; createHook tracks enable.

(in-package :clun.runtime)

(defvar *async-local-stack* nil
  "Alist of (storage . store-value) for the current async context.")

(defvar *async-id-counter* 0)

(defvar *execution-async-id* 1d0
  "Current execution async id (updated by AsyncResource / createHook).")

(defvar *trigger-async-id* 0d0)

(defvar *enabled-async-hooks* nil
  "List of enabled hook objects (JS objects with _hooks).")

(defvar *disabled-als* nil
  "List of AsyncLocalStorage instances that have been disable()'d.")

(defun %next-async-id ()
  (incf *async-id-counter*)
  (coerce *async-id-counter* 'double-float))

(defun %als-disabled-p (storage)
  (member storage *disabled-als* :test #'eq))

(defun %fire-async-hook (phase async-id trigger-id type resource)
  "Invoke enabled createHook callbacks for PHASE (init/before/after/destroy/promiseResolve)."
  (dolist (h *enabled-async-hooks*)
    (let* ((hooks (eng:js-get h "_hooks"))
           (fn (and (eng:js-object-p hooks) (eng:js-get hooks phase))))
      (when (eng:callable-p fn)
        (ignore-errors
          (eng:js-call fn eng:+undefined+
                       (list async-id trigger-id type resource)))))))

(defun build-node-async-hooks ()
  (let* ((o (eng:new-object))
         (als-proto (eng:new-object))
         (als-ctor
          (eng:make-native-function
           "AsyncLocalStorage" 0
           (lambda (this args) (declare (ignore args))
             (when (eng:js-object-p this)
               (eng:hidden-prop this "_id" (%next-async-id)))
             (undef))
           :construct
           (lambda (args nt)
             (declare (ignore args nt))
             (let ((obj (eng:js-make-object als-proto)))
               (eng:hidden-prop obj "_id" (%next-async-id))
               obj))))
         (ar-proto (eng:new-object))
         (ar-ctor
          (eng:make-native-function
           "AsyncResource" 2
           (lambda (this args)
             (when (eng:js-object-p this)
               (eng:data-prop this "type" (->str (a args 0)))
               (let ((aid (%next-async-id)))
                 (eng:hidden-prop this "_asyncId" aid)
                 (eng:hidden-prop this "_triggerAsyncId" *execution-async-id*)
                 (%fire-async-hook "init" aid *execution-async-id*
                                   (->str (a args 0)) this)))
             (undef))
           :construct
           (lambda (args nt)
             (declare (ignore nt))
             (let ((obj (eng:js-make-object ar-proto))
                   (aid (%next-async-id)))
               (eng:data-prop obj "type" (->str (a args 0)))
               (eng:hidden-prop obj "_asyncId" aid)
               (eng:hidden-prop obj "_triggerAsyncId" *execution-async-id*)
               (%fire-async-hook "init" aid *execution-async-id*
                                 (->str (a args 0)) obj)
               obj)))))
    (eng:data-prop als-ctor "prototype" als-proto)
    (eng:install-method als-proto "run" 2
      (lambda (this args)
        (if (%als-disabled-p this)
            (let ((fn (a args 1)))
              (if (eng:callable-p fn)
                  (eng:js-call fn (undef) (nthcdr 2 args))
                  (undef)))
            (let* ((store (a args 0))
                   (fn (a args 1))
                   (rest (nthcdr 2 args))
                   (*async-local-stack* (acons this store *async-local-stack*))
                   (prev-eid *execution-async-id*)
                   (aid (or (eng:js-get this "_id") (%next-async-id))))
              (setf *execution-async-id* (if (numberp aid) (coerce aid 'double-float) aid))
              (unwind-protect
                   (if (eng:callable-p fn)
                       (eng:js-call fn (undef) rest)
                       (undef))
                (setf *execution-async-id* prev-eid))))))
    (eng:install-method als-proto "enterWith" 1
      (lambda (this args)
        (unless (%als-disabled-p this)
          (setf *async-local-stack* (acons this (a args 0) *async-local-stack*)))
        (undef)))
    (eng:install-method als-proto "getStore" 0
      (lambda (this args) (declare (ignore args))
        (if (%als-disabled-p this)
            eng:+undefined+
            (or (cdr (assoc this *async-local-stack* :test #'eq)) eng:+undefined+))))
    (eng:install-method als-proto "disable" 0
      (lambda (this args) (declare (ignore args))
        (pushnew this *disabled-als* :test #'eq)
        (setf *async-local-stack*
              (remove this *async-local-stack* :key #'car :test #'eq))
        (undef)))
    (eng:install-method als-proto "exit" 1
      (lambda (this args)
        (let ((fn (a args 0))
              (*async-local-stack*
                (remove this *async-local-stack* :key #'car :test #'eq)))
          (if (eng:callable-p fn)
              (eng:js-call fn (undef) (nthcdr 1 args))
              (undef)))))
    (eng:data-prop ar-ctor "prototype" ar-proto)
    (eng:install-method ar-proto "runInAsyncScope" 1
      (lambda (this args)
        (let* ((fn (a args 0))
               (this-arg (a args 1))
               (rest (nthcdr 2 args))
               (aid (eng:js-get this "_asyncId"))
               (prev *execution-async-id*)
               (prev-trig *trigger-async-id*))
          (setf *execution-async-id* (if (numberp aid) (coerce aid 'double-float) aid)
                *trigger-async-id* (or (eng:js-get this "_triggerAsyncId") 0d0))
          (%fire-async-hook "before" *execution-async-id* *trigger-async-id*
                            (->str (eng:js-get this "type")) this)
          (unwind-protect
               (if (eng:callable-p fn)
                   (eng:js-call fn this-arg rest)
                   (undef))
            (%fire-async-hook "after" *execution-async-id* *trigger-async-id*
                              (->str (eng:js-get this "type")) this)
            (setf *execution-async-id* prev
                  *trigger-async-id* prev-trig)))))
    (eng:install-method ar-proto "asyncId" 0
      (lambda (this args) (declare (ignore args))
        (eng:js-get this "_asyncId")))
    (eng:install-method ar-proto "triggerAsyncId" 0
      (lambda (this args) (declare (ignore args))
        (eng:js-get this "_triggerAsyncId")))
    (eng:install-method ar-proto "emitDestroy" 0
      (lambda (this args) (declare (ignore args))
        (let ((aid (eng:js-get this "_asyncId")))
          (%fire-async-hook "destroy" (if (numberp aid) aid 0d0)
                            *trigger-async-id*
                            (->str (eng:js-get this "type")) this))
        (undef)))
    (eng:data-prop o "AsyncLocalStorage" als-ctor)
    (eng:data-prop o "AsyncResource" ar-ctor)
    (eng:install-method o "executionAsyncId" 0
      (lambda (this args) (declare (ignore this args)) *execution-async-id*))
    (eng:install-method o "triggerAsyncId" 0
      (lambda (this args) (declare (ignore this args)) *trigger-async-id*))
    (eng:install-method o "executionAsyncResource" 0
      (lambda (this args) (declare (ignore this args)) eng:+null+))
    (eng:install-method o "createHook" 1
      (lambda (this args) (declare (ignore this))
        (let ((hooks (a args 0))
              (h (eng:new-object))
              (enabled nil))
          (eng:hidden-prop h "_hooks" hooks)
          (eng:install-method h "enable" 0
            (lambda (tt aa) (declare (ignore aa))
              (unless enabled
                (setf enabled t)
                (pushnew tt *enabled-async-hooks* :test #'eq))
              tt))
          (eng:install-method h "disable" 0
            (lambda (tt aa) (declare (ignore aa))
              (when enabled
                (setf enabled nil
                      *enabled-async-hooks*
                      (remove tt *enabled-async-hooks* :test #'eq)))
              tt))
          h)))
    o))

(register-node-builtin "async_hooks" #'build-node-async-hooks)
