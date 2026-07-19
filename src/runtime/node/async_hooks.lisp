;;;; async_hooks.lisp — node:async_hooks (AsyncLocalStorage + AsyncResource).
;;;; Pure-CL store stack; exceeds Bun by exposing createHook + executionAsyncId.

(in-package :clun.runtime)

(defvar *async-local-stack* nil
  "Alist of (storage . store-value) for the current async context.")

(defvar *async-id-counter* 0)

(defun %next-async-id ()
  (incf *async-id-counter*)
  (coerce *async-id-counter* 'double-float))

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
               (eng:hidden-prop this "_asyncId" (%next-async-id))
               (eng:hidden-prop this "_triggerAsyncId" 0d0))
             (undef))
           :construct
           (lambda (args nt)
             (declare (ignore nt))
             (let ((obj (eng:js-make-object ar-proto)))
               (eng:data-prop obj "type" (->str (a args 0)))
               (eng:hidden-prop obj "_asyncId" (%next-async-id))
               (eng:hidden-prop obj "_triggerAsyncId" 0d0)
               obj)))))
    (eng:data-prop als-ctor "prototype" als-proto)
    (eng:install-method als-proto "run" 2
      (lambda (this args)
        (let* ((store (a args 0))
               (fn (a args 1))
               (rest (nthcdr 2 args))
               (*async-local-stack* (acons this store *async-local-stack*)))
          (if (eng:callable-p fn)
              (eng:js-call fn (undef) rest)
              (undef)))))
    (eng:install-method als-proto "enterWith" 1
      (lambda (this args)
        (setf *async-local-stack* (acons this (a args 0) *async-local-stack*))
        (undef)))
    (eng:install-method als-proto "getStore" 0
      (lambda (this args) (declare (ignore args))
        (or (cdr (assoc this *async-local-stack* :test #'eq)) eng:+undefined+)))
    (eng:install-method als-proto "disable" 0
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
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
      (lambda (this args) (declare (ignore this))
        (let ((fn (a args 0)))
          (if (eng:callable-p fn)
              (eng:js-call fn (a args 1) (nthcdr 2 args))
              (undef)))))
    (eng:install-method ar-proto "asyncId" 0
      (lambda (this args) (declare (ignore args))
        (eng:js-get this "_asyncId")))
    (eng:install-method ar-proto "triggerAsyncId" 0
      (lambda (this args) (declare (ignore args))
        (eng:js-get this "_triggerAsyncId")))
    (eng:install-method ar-proto "emitDestroy" 0
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:data-prop o "AsyncLocalStorage" als-ctor)
    (eng:data-prop o "AsyncResource" ar-ctor)
    (eng:install-method o "executionAsyncId" 0
      (lambda (this args) (declare (ignore this args)) 1d0))
    (eng:install-method o "triggerAsyncId" 0
      (lambda (this args) (declare (ignore this args)) 0d0))
    (eng:install-method o "executionAsyncResource" 0
      (lambda (this args) (declare (ignore this args)) eng:+null+))
    (eng:install-method o "createHook" 1
      (lambda (this args) (declare (ignore this))
        (let ((hooks (a args 0))
              (h (eng:new-object)))
          (eng:hidden-prop h "_hooks" hooks)
          (eng:install-method h "enable" 0
            (lambda (tt aa) (declare (ignore tt aa)) h))
          (eng:install-method h "disable" 0
            (lambda (tt aa) (declare (ignore tt aa)) h))
          h)))
    o))

(register-node-builtin "async_hooks" #'build-node-async-hooks)
