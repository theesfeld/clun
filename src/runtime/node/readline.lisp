;;;; readline.lisp — node:readline + readline/promises.

(in-package :clun.runtime)

(defun build-node-readline ()
  (let ((o (eng:new-object)))
    (eng:install-method o "createInterface" 1
      (lambda (this args) (declare (ignore this))
        (let* ((opts (a args 0))
               (iface (%ev-init (eng:new-object))))
          (eng:data-prop iface "line" "")
          (eng:data-prop iface "cursor" 0d0)
          (when (eng:js-object-p opts)
            (eng:data-prop iface "input" (eng:js-get opts "input"))
            (eng:data-prop iface "output" (eng:js-get opts "output"))
            (eng:data-prop iface "terminal" (eng:js-get opts "terminal")))
          (let ((ee-proto (eng:js-get (eng:js-get (build-node-events) "EventEmitter")
                                      "prototype")))
            (dolist (name '("on" "once" "emit" "removeListener" "off"))
              (eng:data-prop iface name (eng:js-get ee-proto name))))
          (eng:install-method iface "question" 2
            (lambda (this args)
              (let ((query (a args 0)) (cb (a args 1))
                    (out (eng:js-get this "output")))
                (when (and (eng:js-object-p out)
                           (eng:callable-p (eng:js-get out "write")))
                  (eng:js-call (eng:js-get out "write") out (list query)))
                (when (eng:callable-p cb) (eng:js-call cb (undef) (list "")))
                (undef))))
          (eng:install-method iface "close" 0
            (lambda (this args) (declare (ignore args))
              (eng:js-call (eng:js-get this "emit") this (list "close"))
              (undef)))
          (eng:install-method iface "pause" 0
            (lambda (this args) (declare (ignore args)) this))
          (eng:install-method iface "resume" 0
            (lambda (this args) (declare (ignore args)) this))
          (eng:install-method iface "write" 2
            (lambda (this args)
              (let ((out (eng:js-get this "output")))
                (when (and (eng:js-object-p out)
                           (eng:callable-p (eng:js-get out "write")))
                  (eng:js-call (eng:js-get out "write") out (list (a args 0)))))
              (undef)))
          (eng:install-method iface "prompt" 1
            (lambda (this args) (declare (ignore this args)) eng:+undefined+))
          (eng:install-method iface "setPrompt" 1
            (lambda (this args)
              (eng:data-prop this "prompt" (->str (a args 0)))
              (undef)))
          iface)))
    (eng:install-method o "cursorTo" 3
      (lambda (this args) (declare (ignore this args)) eng:+true+))
    (eng:install-method o "moveCursor" 3
      (lambda (this args) (declare (ignore this args)) eng:+true+))
    (eng:install-method o "clearLine" 2
      (lambda (this args) (declare (ignore this args)) eng:+true+))
    (eng:install-method o "clearScreenDown" 1
      (lambda (this args) (declare (ignore this args)) eng:+true+))
    (eng:install-method o "emitKeypressEvents" 2
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:data-prop o "promises" (build-node-readline-promises))
    (eng:data-prop o "Interface"
                   (eng:make-native-function "Interface" 0
                     (lambda (this args) (declare (ignore this args)) (undef))))
    o))

(defun build-node-readline-promises ()
  (let ((o (eng:new-object)))
    (eng:install-method o "createInterface" 1
      (lambda (this args) (declare (ignore this))
        (let ((iface (eng:js-call (eng:js-get (build-node-readline) "createInterface")
                                  (build-node-readline) args)))
          (eng:install-method iface "question" 1
            (lambda (this args)
              (let ((g (eng:realm-global eng:*realm*))
                    (query (a args 0))
                    (out (eng:js-get this "output")))
                (eng:js-construct (eng:js-get g "Promise")
                  (list (eng:make-native-function "" 2
                          (lambda (tt aa) (declare (ignore tt))
                            (when (and (eng:js-object-p out)
                                       (eng:callable-p (eng:js-get out "write")))
                              (eng:js-call (eng:js-get out "write") out (list query)))
                            (eng:js-call (a aa 0) (undef) (list ""))
                            (undef))))))))
          iface)))
    o))

(register-node-builtin "readline" #'build-node-readline)
(register-node-builtin "readline/promises" #'build-node-readline-promises)
