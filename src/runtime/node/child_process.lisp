;;;; child_process.lisp — node:child_process over pure-CL run-program / Clun.spawn.

(in-package :clun.runtime)

(defun %cp-env-alist (env-obj)
  (when (eng:js-object-p env-obj)
    (loop for k in (eng:jm-own-property-keys env-obj)
          when (stringp k)
            collect (cons k (->str (eng:js-get env-obj k))))))

(defun %cp-spawn-sync (command args opts)
  (let* ((argv (cons (->str command)
                     (if (eng:js-array-p args)
                         (loop for i below (eng:array-length args)
                               collect (->str (eng:js-getv args (princ-to-string i))))
                         '())))
         (cwd (when (eng:js-object-p opts)
                (let ((c (eng:js-get opts "cwd")))
                  (unless (undef-p c) (->str c)))))
         (env (when (eng:js-object-p opts)
                (%cp-env-alist (eng:js-get opts "env"))))
         (encoding (when (eng:js-object-p opts)
                     (let ((e (eng:js-get opts "encoding")))
                       (unless (undef-p e) (->str e)))))
         (out (make-string-output-stream))
         (err (make-string-output-stream))
         (proc (sb-ext:run-program (first argv) (rest argv)
                                   :output out :error err :wait t
                                   :directory cwd
                                   :environment
                                   (when env
                                     (append (mapcar (lambda (p)
                                                       (format nil "~a=~a" (car p) (cdr p)))
                                                     env)
                                             (sb-ext:posix-environ)))))
         (stdout (get-output-stream-string out))
         (stderr (get-output-stream-string err))
         (code (or (sb-ext:process-exit-code proc) 0))
         (result (eng:new-object)))
    (eng:data-prop result "status" (coerce code 'double-float))
    (eng:data-prop result "signal" eng:+null+)
    (eng:data-prop result "error" eng:+null+)
    (eng:data-prop result "stdout"
                   (if (and encoding (string-equal encoding "buffer"))
                       (%buffer-from-octets
                        (sb-ext:string-to-octets stdout :external-format :utf-8))
                       stdout))
    (eng:data-prop result "stderr"
                   (if (and encoding (string-equal encoding "buffer"))
                       (%buffer-from-octets
                        (sb-ext:string-to-octets stderr :external-format :utf-8))
                       stderr))
    (eng:data-prop result "pid" (coerce (or (ignore-errors (sb-ext:process-pid proc)) 0)
                                        'double-float))
    (eng:data-prop result "output"
                   (eng:new-array (list eng:+null+
                                        (eng:js-get result "stdout")
                                        (eng:js-get result "stderr"))))
    result))

(defun %cp-child-handle ()
  (let ((child (%ev-init (eng:new-object))))
    (eng:data-prop child "pid" 0d0)
    (eng:data-prop child "connected" eng:+false+)
    (eng:data-prop child "killed" eng:+false+)
    (eng:data-prop child "exitCode" eng:+null+)
    (eng:data-prop child "signalCode" eng:+null+)
    (eng:data-prop child "stdin" eng:+null+)
    (eng:data-prop child "stdout" eng:+null+)
    (eng:data-prop child "stderr" eng:+null+)
    (let ((ee-proto (eng:js-get (eng:js-get (build-node-events) "EventEmitter") "prototype")))
      (dolist (name '("on" "once" "emit" "removeListener" "off"))
        (eng:data-prop child name (eng:js-get ee-proto name))))
    (eng:install-method child "kill" 1
      (lambda (this args) (declare (ignore args))
        (eng:js-set this "killed" eng:+true+ nil)
        eng:+true+))
    (eng:install-method child "disconnect" 0
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method child "ref" 0 (lambda (this args) (declare (ignore args)) this))
    (eng:install-method child "unref" 0 (lambda (this args) (declare (ignore args)) this))
    (eng:install-method child "send" 2
      (lambda (this args) (declare (ignore this args)) eng:+false+))
    child))

(defun build-node-child-process ()
  (let ((o (eng:new-object)))
    (labels ((m (name arity fn) (eng:install-method o name arity fn)))
      (m "spawnSync" 3
         (lambda (this args) (declare (ignore this))
           (%cp-spawn-sync (a args 0) (a args 1) (a args 2))))
      (m "execSync" 2
         (lambda (this args) (declare (ignore this))
           (let* ((cmd (->str (a args 0)))
                  (opts (a args 1))
                  (shell (or (and (eng:js-object-p opts)
                                  (let ((s (eng:js-get opts "shell")))
                                    (unless (or (undef-p s) (eng:js-boolean-p s))
                                      (->str s))))
                             "/bin/sh"))
                  (res (%cp-spawn-sync shell
                                       (eng:new-array (list "-c" cmd))
                                       opts)))
             (eng:js-get res "stdout"))))
      (m "execFileSync" 3
         (lambda (this args) (declare (ignore this))
           (eng:js-get (%cp-spawn-sync (a args 0) (a args 1) (a args 2)) "stdout")))
      (m "spawn" 3
         (lambda (this args) (declare (ignore this))
           (let ((child (%cp-child-handle))
                 (command (a args 0))
                 (cargs (a args 1))
                 (opts (a args 2)))
             (when (eng:js-object-p cargs) (setf opts cargs cargs (eng:new-array '())))
             ;; Fire exit asynchronously after a sync spawn for smoke compatibility.
             (handler-case
                 (let ((res (%cp-spawn-sync command cargs opts)))
                   (eng:js-set child "exitCode" (eng:js-get res "status") nil)
                   (eng:js-set child "pid" (eng:js-get res "pid") nil)
                   (eng:js-call (eng:js-get child "emit") child
                     (list "exit" (eng:js-get res "status") eng:+null+))
                   (eng:js-call (eng:js-get child "emit") child (list "close"
                                                                       (eng:js-get res "status")
                                                                       eng:+null+)))
               (error (c)
                 (eng:js-call (eng:js-get child "emit") child
                   (list "error"
                         (eng:js-construct
                          (eng:js-get (eng:realm-global eng:*realm*) "Error")
                          (list (format nil "~a" c)))))))
             child)))
      (m "exec" 3
         (lambda (this args) (declare (ignore this))
           (let* ((cmd (a args 0))
                  (opts (a args 1))
                  (cb (a args 2)))
             (when (eng:callable-p opts) (setf cb opts opts eng:+undefined+))
             (handler-case
                 (let* ((res (%cp-spawn-sync "/bin/sh"
                                             (eng:new-array (list "-c" (->str cmd)))
                                             opts)))
                   (when (eng:callable-p cb)
                     (eng:js-call cb (undef)
                       (list eng:+null+
                             (eng:js-get res "stdout")
                             (eng:js-get res "stderr")))))
               (error (c)
                 (when (eng:callable-p cb)
                   (eng:js-call cb (undef)
                     (list (eng:js-construct
                            (eng:js-get (eng:realm-global eng:*realm*) "Error")
                            (list (format nil "~a" c))))))))
             (%cp-child-handle))))
      (m "execFile" 4
         (lambda (this args) (declare (ignore this))
           (let ((file (a args 0))
                 (cargs (a args 1))
                 (opts (a args 2))
                 (cb (a args 3)))
             (when (eng:callable-p cargs) (setf cb cargs cargs (eng:new-array '()) opts eng:+undefined+))
             (when (eng:callable-p opts) (setf cb opts opts eng:+undefined+))
             (handler-case
                 (let ((res (%cp-spawn-sync file cargs opts)))
                   (when (eng:callable-p cb)
                     (eng:js-call cb (undef)
                       (list eng:+null+
                             (eng:js-get res "stdout")
                             (eng:js-get res "stderr")))))
               (error (c)
                 (when (eng:callable-p cb)
                   (eng:js-call cb (undef)
                     (list (eng:js-construct
                            (eng:js-get (eng:realm-global eng:*realm*) "Error")
                            (list (format nil "~a" c))))))))
             (%cp-child-handle))))
      (m "fork" 2
         (lambda (this args) (declare (ignore this args))
           (%cp-child-handle)))
      (eng:data-prop o "ChildProcess"
                     (eng:make-native-function "ChildProcess" 0
                       (lambda (this args) (declare (ignore this args)) (undef))))
      o)))

(register-node-builtin "child_process" #'build-node-child-process)
