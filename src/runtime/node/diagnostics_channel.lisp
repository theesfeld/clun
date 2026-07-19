;;;; diagnostics_channel.lisp — node:diagnostics_channel pure-CL.

(in-package :clun.runtime)

(defvar *diag-channels* (make-hash-table :test 'equal)
  "name -> channel object")

(defun %diag-channel (name)
  (or (gethash name *diag-channels*)
      (let ((ch (eng:new-object)))
        (eng:data-prop ch "name" name)
        (eng:hidden-prop ch "_subs" '())
        (eng:install-method ch "hasSubscribers" 0
          (lambda (this args) (declare (ignore args))
            (eng:js-boolean (not (null (eng:js-get this "_subs"))))))
        (eng:install-method ch "subscribe" 1
          (lambda (this args)
            (eng:hidden-prop this "_subs"
                             (cons (a args 0) (eng:js-get this "_subs")))
            (undef)))
        (eng:install-method ch "unsubscribe" 1
          (lambda (this args)
            (eng:hidden-prop this "_subs"
                             (remove (a args 0) (eng:js-get this "_subs")
                                     :test #'eng:js-strict-eq))
            (undef)))
        (eng:install-method ch "publish" 1
          (lambda (this args)
            (dolist (fn (eng:js-get this "_subs"))
              (when (eng:callable-p fn)
                (eng:js-call fn (undef) (list (a args 0)))))
            (undef)))
        (eng:install-method ch "bindStore" 2
          (lambda (this args) (declare (ignore this args)) eng:+undefined+))
        (eng:install-method ch "unbindStore" 1
          (lambda (this args) (declare (ignore this args)) eng:+undefined+))
        (eng:install-method ch "runStores" 3
          (lambda (this args) (declare (ignore this))
            (let ((fn (a args 1)))
              (if (eng:callable-p fn)
                  (eng:js-call fn (undef) (list (a args 2)))
                  (undef)))))
        (setf (gethash name *diag-channels*) ch)
        ch)))

(defun build-node-diagnostics-channel ()
  (let ((o (eng:new-object)))
    (eng:install-method o "channel" 1
      (lambda (this args) (declare (ignore this))
        (%diag-channel (->str (a args 0)))))
    (eng:install-method o "hasSubscribers" 1
      (lambda (this args) (declare (ignore this))
        (let ((ch (gethash (->str (a args 0)) *diag-channels*)))
          (eng:js-boolean
           (and ch (not (null (eng:js-get ch "_subs"))))))))
    (eng:install-method o "subscribe" 2
      (lambda (this args) (declare (ignore this))
        (eng:js-call (eng:js-get (%diag-channel (->str (a args 0))) "subscribe")
                     (%diag-channel (->str (a args 0)))
                     (list (a args 1)))
        (undef)))
    (eng:install-method o "unsubscribe" 2
      (lambda (this args) (declare (ignore this))
        (eng:js-call (eng:js-get (%diag-channel (->str (a args 0))) "unsubscribe")
                     (%diag-channel (->str (a args 0)))
                     (list (a args 1)))
        (undef)))
    (eng:install-method o "tracingChannel" 1
      (lambda (this args) (declare (ignore this))
        (let ((name (->str (a args 0)))
              (tc (eng:new-object)))
          (eng:data-prop tc "start" (%diag-channel (concatenate 'string name ":start")))
          (eng:data-prop tc "end" (%diag-channel (concatenate 'string name ":end")))
          (eng:data-prop tc "asyncStart" (%diag-channel (concatenate 'string name ":asyncStart")))
          (eng:data-prop tc "asyncEnd" (%diag-channel (concatenate 'string name ":asyncEnd")))
          (eng:data-prop tc "error" (%diag-channel (concatenate 'string name ":error")))
          tc)))
    o))

(register-node-builtin "diagnostics_channel" #'build-node-diagnostics-channel)
