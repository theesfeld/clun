;;;; tty.lisp — node:tty (isatty + ReadStream/WriteStream).

(in-package :clun.runtime)

(defun build-node-tty ()
  (let ((o (eng:new-object)))
    (eng:install-method o "isatty" 1
      (lambda (this args) (declare (ignore this))
        (let ((fd (truncate (->num (a args 0)))))
          (eng:js-boolean
           (cond ((= fd 0) (sys:tty-p *standard-input*))
                 ((= fd 1) (sys:tty-p *standard-output*))
                 ((= fd 2) (sys:tty-p *error-output*))
                 (t nil))))))
    (let* ((ws-proto (eng:new-object))
           (ws-ctor
            (eng:make-native-function
             "WriteStream" 1
             (lambda (this args)
               (when (eng:js-object-p this)
                 (eng:data-prop this "fd" (->num (a args 0)))
                 (eng:data-prop this "isTTY" eng:+true+)
                 (eng:data-prop this "columns" 80d0)
                 (eng:data-prop this "rows" 24d0))
               (undef))
             :construct
             (lambda (args nt)
               (declare (ignore nt))
               (let ((obj (eng:js-make-object ws-proto)))
                 (eng:data-prop obj "fd" (->num (a args 0)))
                 (eng:data-prop obj "isTTY" eng:+true+)
                 (eng:data-prop obj "columns" 80d0)
                 (eng:data-prop obj "rows" 24d0)
                 obj)))))
      (eng:data-prop ws-ctor "prototype" ws-proto)
      (eng:install-method ws-proto "getColorDepth" 0
        (lambda (this args) (declare (ignore this args)) 8d0))
      (eng:install-method ws-proto "hasColors" 1
        (lambda (this args) (declare (ignore this args)) eng:+true+))
      (eng:install-method ws-proto "clearLine" 1
        (lambda (this args) (declare (ignore this args)) eng:+true+))
      (eng:install-method ws-proto "cursorTo" 2
        (lambda (this args) (declare (ignore this args)) eng:+true+))
      (eng:data-prop o "WriteStream" ws-ctor))
    (let* ((rs-proto (eng:new-object))
           (rs-ctor
            (eng:make-native-function
             "ReadStream" 1
             (lambda (this args)
               (when (eng:js-object-p this)
                 (eng:data-prop this "fd" (->num (a args 0)))
                 (eng:data-prop this "isTTY" eng:+true+)
                 (eng:data-prop this "isRaw" eng:+false+))
               (undef))
             :construct
             (lambda (args nt)
               (declare (ignore nt))
               (let ((obj (eng:js-make-object rs-proto)))
                 (eng:data-prop obj "fd" (->num (a args 0)))
                 (eng:data-prop obj "isTTY" eng:+true+)
                 (eng:data-prop obj "isRaw" eng:+false+)
                 obj)))))
      (eng:data-prop rs-ctor "prototype" rs-proto)
      (eng:install-method rs-proto "setRawMode" 1
        (lambda (this args)
          (eng:js-set this "isRaw" (eng:js-boolean (eng:js-truthy (a args 0))) nil)
          this))
      (eng:data-prop o "ReadStream" rs-ctor))
    o))

(register-node-builtin "tty" #'build-node-tty)
