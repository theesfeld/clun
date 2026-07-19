;;;; domain.lisp — node:domain (deprecated; EventEmitter-based Domain).

(in-package :clun.runtime)

(defun build-node-domain ()
  (let* ((ee (build-node-events))
         (ee-ctor (eng:js-get ee "EventEmitter"))
         (ee-proto (eng:js-get ee-ctor "prototype"))
         (proto (eng:js-make-object ee-proto))
         (ctor (eng:make-native-function
                "Domain" 0
                (lambda (this args) (declare (ignore args))
                  (when (eng:js-object-p this) (%ev-init this))
                  (undef))
                :construct
                (lambda (args nt)
                  (declare (ignore args nt))
                  (%ev-init (eng:js-make-object proto)))))
         (o (eng:new-object)))
    (eng:data-prop ctor "prototype" proto)
    (eng:install-method proto "run" 1
      (lambda (this args)
        (let ((fn (a args 0)))
          (if (eng:callable-p fn)
              (handler-case (eng:js-call fn (undef) (nthcdr 1 args))
                (eng:js-condition (c)
                  (eng:js-call (eng:js-get this "emit") this
                               (list "error" (eng:js-condition-value c)))
                  (undef)))
              (undef)))))
    (eng:install-method proto "add" 1
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method proto "remove" 1
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method proto "bind" 1
      (lambda (this args)
        (let ((fn (a args 0)))
          (eng:make-native-function "" 0
            (lambda (tt aa) (declare (ignore tt))
              (eng:js-call (eng:js-get this "run") this (cons fn aa)))))))
    (eng:install-method proto "intercept" 1
      (lambda (this args)
        (eng:js-call (eng:js-get this "bind") this (list (a args 0)))))
    (eng:install-method proto "enter" 0
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method proto "exit" 0
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:data-prop o "Domain" ctor)
    (eng:install-method o "create" 0
      (lambda (this args) (declare (ignore this args))
        (eng:js-construct ctor '())))
    (eng:install-method o "createDomain" 0
      (lambda (this args) (declare (ignore this args))
        (eng:js-construct ctor '())))
    (eng:data-prop o "active" eng:+null+)
    o))

(register-node-builtin "domain" #'build-node-domain)
