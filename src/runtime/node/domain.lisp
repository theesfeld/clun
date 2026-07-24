;;;; domain.lisp — node:domain (deprecated; real active stack + member tracking).

(in-package :clun.runtime)

(defparameter *domain-stack* nil
  "List of currently entered domains (most recent first).")

(defun %domain-members (dom)
  (or (eng:js-get dom "_members") '()))

(defun %domain-set-members (dom list)
  (eng:hidden-prop dom "_members" list))

(defun build-node-domain ()
  (let* ((ee (build-node-events))
         (ee-ctor (eng:js-get ee "EventEmitter"))
         (ee-proto (eng:js-get ee-ctor "prototype"))
         (proto (eng:js-make-object ee-proto))
         (module (eng:new-object))
         (ctor (eng:make-native-function
                "Domain" 0
                (lambda (this args)
                  (declare (ignore args))
                  (when (eng:js-object-p this)
                    (%ev-init this)
                    (%domain-set-members this '())
                    (eng:data-prop this "members" (eng:new-array '())))
                  (undef))
                :construct
                (lambda (args nt)
                  (declare (ignore args nt))
                  (let ((d (%ev-init (eng:js-make-object proto))))
                    (%domain-set-members d '())
                    (eng:data-prop d "members" (eng:new-array '()))
                    d)))))
    (eng:data-prop ctor "prototype" proto)
    (eng:install-method proto "run" 1
      (lambda (this args)
        (let ((fn (a args 0)))
          (eng:js-call (eng:js-get this "enter") this '())
          (unwind-protect
               (if (eng:callable-p fn)
                   (handler-case
                       (eng:js-call fn (undef) (nthcdr 1 args))
                     (eng:js-condition (c)
                       (eng:js-call (eng:js-get this "emit") this
                                    (list "error" (eng:js-condition-value c)))
                       (undef))
                     (error (e)
                       (eng:js-call (eng:js-get this "emit") this
                                    (list "error"
                                          (eng:js-construct
                                           (eng:js-get (eng:realm-global eng:*realm*)
                                                       "Error")
                                           (list (format nil "~a" e)))))
                       (undef)))
                   (undef))
            (eng:js-call (eng:js-get this "exit") this '())))))
    (eng:install-method proto "add" 1
      (lambda (this args)
        (let ((ee (a args 0)))
          (when (eng:js-object-p ee)
            (unless (member ee (%domain-members this) :test #'eq)
              (%domain-set-members this (cons ee (%domain-members this)))
              (eng:data-prop this "members"
                             (eng:new-array (%domain-members this)))
              ;; Route emitter 'error' into domain when present.
              (when (eng:callable-p (eng:js-get ee "on"))
                (eng:js-call (eng:js-get ee "on") ee
                             (list "error"
                                   (eng:make-native-function
                                    "" 1
                                    (lambda (tt aa)
                                      (declare (ignore tt))
                                      (eng:js-call (eng:js-get this "emit") this
                                                   (list "error" (a aa 0)))
                                      (undef))))))))
          eng:+undefined+)))
    (eng:install-method proto "remove" 1
      (lambda (this args)
        (let ((ee (a args 0)))
          (%domain-set-members this
                               (remove ee (%domain-members this) :test #'eq))
          (eng:data-prop this "members"
                         (eng:new-array (%domain-members this)))
          eng:+undefined+)))
    (eng:install-method proto "bind" 1
      (lambda (this args)
        (let ((fn (a args 0)))
          (eng:make-native-function "" 0
            (lambda (tt aa)
              (declare (ignore tt))
              (eng:js-call (eng:js-get this "run") this (cons fn aa)))))))
    (eng:install-method proto "intercept" 1
      (lambda (this args)
        ;; Node: like bind, but if the first arg is an Error it is emitted on
        ;; the domain instead of being passed through to the callback.
        (let ((fn (a args 0)))
          (eng:make-native-function "" 0
            (lambda (tt aa)
              (declare (ignore tt))
              (let ((first (a aa 0)))
                (if (and (eng:js-object-p first)
                         (not (eng:js-null-p first))
                         (or (eng:js-truthy (eng:js-get first "message"))
                             (let ((name (eng:js-get first "name")))
                               (and (not (undef-p name))
                                    (search "Error" (->str name))))))
                    (progn
                      (eng:js-call (eng:js-get this "emit") this
                                   (list "error" first))
                      (undef))
                    (eng:js-call (eng:js-get this "run") this
                                 (cons fn (coerce aa 'list))))))))))
    (eng:install-method proto "enter" 0
      (lambda (this args)
        (declare (ignore args))
        (push this *domain-stack*)
        (eng:data-prop module "active" this)
        eng:+undefined+))
    (eng:install-method proto "exit" 0
      (lambda (this args)
        (declare (ignore args))
        (setf *domain-stack* (remove this *domain-stack* :count 1 :test #'eq))
        (eng:data-prop module "active"
                       (or (car *domain-stack*) eng:+null+))
        eng:+undefined+))
    (eng:data-prop module "Domain" ctor)
    (eng:install-method module "create" 0
      (lambda (this args)
        (declare (ignore this args))
        (eng:js-construct ctor '())))
    (eng:install-method module "createDomain" 0
      (lambda (this args)
        (declare (ignore this args))
        (eng:js-construct ctor '())))
    (eng:data-prop module "active" eng:+null+)
    module))

(register-node-builtin "domain" #'build-node-domain)
