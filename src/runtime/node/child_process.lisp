;;;; child_process.lisp — node:child_process over pure-CL run-program / real async.

(in-package :clun.runtime)

(defun %cp-env-alist (env-obj)
  (when (eng:js-object-p env-obj)
    (loop for k in (eng:jm-own-property-keys env-obj)
          when (stringp k)
            collect (cons k (->str (eng:js-get env-obj k))))))

(defun %cp-env-strings (env-alist)
  (when env-alist
    (append (mapcar (lambda (p) (format nil "~a=~a" (car p) (cdr p))) env-alist)
            (sb-ext:posix-environ))))

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
                                   :environment (%cp-env-strings env)))
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

(defun %cp-signal-number (sig)
  (cond
    ((eng:js-number-p sig) (truncate (eng:to-number sig)))
    ((stringp sig)
     (cond ((string-equal sig "SIGKILL") 9)
           ((string-equal sig "SIGTERM") 15)
           ((string-equal sig "SIGINT") 2)
           ((string-equal sig "SIGHUP") 1)
           ((string-equal sig "SIGUSR1") 10)
           ((string-equal sig "SIGUSR2") 12)
           (t 15)))
    (t 15)))

(defun %cp-wire-child (child proc)
  "Attach a live sb-ext process to CHILD and schedule exit polling."
  (eng:hidden-prop child "_proc" proc)
  (eng:js-set child "pid"
              (coerce (or (ignore-errors (sb-ext:process-pid proc)) 0) 'double-float)
              nil)
  (eng:js-set child "connected" eng:+true+ nil)
  (let ((loop (ignore-errors (eng:current-loop)))
        (realm eng:*realm*))
    (labels ((poll ()
               (cond
                 ((null (eng:js-get child "_proc")) nil)
                 ((not (sb-ext:process-alive-p proc))
                  (let ((code (or (sb-ext:process-exit-code proc) 0)))
                    (eng:js-set child "exitCode" (coerce code 'double-float) nil)
                    (eng:js-set child "connected" eng:+false+ nil)
                    (eng:js-call (eng:js-get child "emit") child
                                 (list "exit" (coerce code 'double-float) eng:+null+))
                    (eng:js-call (eng:js-get child "emit") child
                                 (list "close" (coerce code 'double-float) eng:+null+))))
                 (loop
                  (lp:set-timer loop 25
                                (lambda ()
                                  (let ((eng:*realm* realm))
                                    (poll)))))
                 (t
                  (sb-thread:make-thread
                   (lambda ()
                     (sb-ext:process-wait proc)
                     (when loop
                       (lp:loop-post loop
                                     (lambda ()
                                       (let ((eng:*realm* realm))
                                         (poll))))))
                   :name "clun-child-wait")))))
      (poll)))
  child)

(defun %cp-child-handle (&optional proc)
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
      (lambda (this args)
        (let* ((p (eng:js-get this "_proc"))
               (sig (%cp-signal-number (a args 0))))
          (when (and p (sb-ext:process-alive-p p))
            (ignore-errors (sb-ext:process-kill p sig :pid))
            (eng:js-set this "killed" eng:+true+ nil)
            (eng:js-set this "signalCode"
                        (if (eng:js-string-p (a args 0))
                            (->str (a args 0))
                            "SIGTERM")
                        nil))
          eng:+true+)))
    (eng:install-method child "disconnect" 0
      (lambda (this args)
        (declare (ignore args))
        (let ((p (eng:js-get this "_proc")))
          (when p
            (ignore-errors (close (sb-ext:process-input p) :abort t)))
          (eng:js-set this "connected" eng:+false+ nil)
          (eng:js-call (eng:js-get this "emit") this (list "disconnect"))
          eng:+undefined+)))
    (eng:install-method child "ref" 0 (lambda (this args) (declare (ignore args)) this))
    (eng:install-method child "unref" 0 (lambda (this args) (declare (ignore args)) this))
    (eng:install-method child "send" 2
      (lambda (this args)
        (let* ((p (eng:js-get this "_proc"))
               (msg (a args 0))
               (in (and p (ignore-errors (sb-ext:process-input p)))))
          (if (and in (open-stream-p in))
              (progn
                (write-line
                 (if (eng:js-string-p msg)
                     (->str msg)
                     (let* ((g (eng:realm-global eng:*realm*))
                            (json (eng:js-get g "JSON")))
                       (->str (eng:js-call (eng:js-get json "stringify") json
                                           (list msg)))))
                 in)
                (force-output in)
                eng:+true+)
              eng:+false+))))
    (when proc (%cp-wire-child child proc))
    child))

(defun %cp-argv (command args)
  (cons (->str command)
        (if (eng:js-array-p args)
            (loop for i below (eng:array-length args)
                  collect (->str (eng:js-getv args (princ-to-string i))))
            '())))

(defun %cp-spawn-async (command args opts)
  (let* ((argv (%cp-argv command args))
         (cwd (when (eng:js-object-p opts)
                (let ((c (eng:js-get opts "cwd")))
                  (unless (undef-p c) (->str c)))))
         (env (when (eng:js-object-p opts)
                (%cp-env-alist (eng:js-get opts "env"))))
         (proc (sb-ext:run-program (first argv) (rest argv)
                                   :wait nil
                                   :input :stream
                                   :output :stream
                                   :error :stream
                                   :directory cwd
                                   :environment (%cp-env-strings env))))
    (%cp-child-handle proc)))

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
           (let ((command (a args 0))
                 (cargs (a args 1))
                 (opts (a args 2)))
             (when (eng:js-object-p cargs) (setf opts cargs cargs (eng:new-array '())))
             (handler-case
                 (%cp-spawn-async command cargs opts)
               (error (c)
                 (let ((child (%cp-child-handle)))
                   (eng:js-call (eng:js-get child "emit") child
                     (list "error"
                           (eng:js-construct
                            (eng:js-get (eng:realm-global eng:*realm*) "Error")
                            (list (format nil "~a" c)))))
                   child))))))
      (m "exec" 3
         (lambda (this args) (declare (ignore this))
           (let* ((cmd (a args 0))
                  (opts (a args 1))
                  (cb (a args 2)))
             (when (eng:callable-p opts) (setf cb opts opts eng:+undefined+))
             (let ((child (%cp-spawn-async "/bin/sh"
                                           (eng:new-array (list "-c" (->str cmd)))
                                           opts)))
               (when (eng:callable-p cb)
                 (eng:js-call (eng:js-get child "once") child
                   (list "exit"
                         (eng:make-native-function
                          "" 2
                          (lambda (tt aa)
                            (declare (ignore tt aa))
                            (let* ((p (eng:js-get child "_proc"))
                                   (out (or (ignore-errors
                                              (with-output-to-string (s)
                                                (when p
                                                  (let ((st (sb-ext:process-output p)))
                                                    (when st
                                                      (loop for line = (read-line st nil nil)
                                                            while line
                                                            do (write-line line s)))))))
                                            ""))
                                   (err ""))
                              (eng:js-call cb (undef)
                                           (list eng:+null+ out err))
                              (undef)))))))
               child))))
      (m "execFile" 4
         (lambda (this args) (declare (ignore this))
           (let ((file (a args 0))
                 (cargs (a args 1))
                 (opts (a args 2))
                 (cb (a args 3)))
             (when (eng:callable-p cargs)
               (setf cb cargs cargs (eng:new-array '()) opts eng:+undefined+))
             (when (eng:callable-p opts) (setf cb opts opts eng:+undefined+))
             (let ((child (%cp-spawn-async file cargs opts)))
               (when (eng:callable-p cb)
                 (eng:js-call (eng:js-get child "once") child
                   (list "exit"
                         (eng:make-native-function
                          "" 2
                          (lambda (tt aa)
                            (declare (ignore tt aa))
                            (eng:js-call cb (undef)
                                         (list eng:+null+ "" ""))
                            (undef))))))
               child))))
      (m "fork" 2
         (lambda (this args) (declare (ignore this))
           ;; fork(modulePath) → spawn clun on the module with IPC env.
           (let* ((module-path (->str (a args 0)))
                  (opts (a args 1))
                  (bin (or (clun.sys:getenv "CLUN_BIN")
                           (ignore-errors
                             (namestring (truename (or (car sb-ext:*posix-argv*)
                                                       "build/clun"))))
                           "clun"))
                  (env-extra (list (format nil "CLUN_FORK=1")
                                   (format nil "CLUN_FORK_MODULE=~a" module-path)))
                  (env-alist (append
                              (mapcar (lambda (s)
                                        (let ((eq (position #\= s)))
                                          (cons (subseq s 0 eq) (subseq s (1+ eq)))))
                                      env-extra)
                              (when (eng:js-object-p opts)
                                (%cp-env-alist (eng:js-get opts "env")))))
                  (merged-opts (eng:new-object)))
             (when (eng:js-object-p opts)
               (dolist (k (eng:jm-own-property-keys opts))
                 (when (stringp k)
                   (eng:data-prop merged-opts k (eng:js-get opts k)))))
             (let ((env-obj (eng:new-object)))
               (dolist (p env-alist)
                 (eng:data-prop env-obj (car p) (cdr p)))
               (eng:data-prop merged-opts "env" env-obj))
             (%cp-spawn-async bin (eng:new-array (list module-path)) merged-opts))))
      (eng:data-prop o "ChildProcess"
                     (eng:make-native-function
                      "ChildProcess" 0
                      (lambda (this args)
                        (declare (ignore args))
                        (when (eng:js-object-p this)
                          (%ev-init this))
                        (undef))
                      :construct
                      (lambda (args nt)
                        (declare (ignore args nt))
                        (%cp-child-handle))))
      o)))

(register-node-builtin "child_process" #'build-node-child-process)
