;;;; os.lisp — node:os. Host info via clun.sys (real /proc data on Linux).

(in-package :clun.runtime)

(defun %os-cpu-from-plist (plist)
  (let ((cpu (eng:new-object))
        (times (eng:new-object)))
    (eng:data-prop times "user" (float (getf plist :user 0d0) 1d0))
    (eng:data-prop times "nice" (float (getf plist :nice 0d0) 1d0))
    (eng:data-prop times "sys" (float (getf plist :sys 0d0) 1d0))
    (eng:data-prop times "idle" (float (getf plist :idle 0d0) 1d0))
    (eng:data-prop times "irq" (float (getf plist :irq 0d0) 1d0))
    (eng:data-prop cpu "model" (or (getf plist :model) "unknown"))
    (eng:data-prop cpu "speed" (coerce (or (getf plist :speed) 0) 'double-float))
    (eng:data-prop cpu "times" times)
    cpu))

(defun %os-user-info ()
  (let ((o (eng:new-object))
        (uid (or (clun.sys:getuid) -1))
        (gid (or (clun.sys:getgid) -1)))
    (eng:data-prop o "username"
                   (or (clun.sys:getenv "USER")
                       (clun.sys:getenv "LOGNAME")
                       "user"))
    (eng:data-prop o "uid" (coerce uid 'double-float))
    (eng:data-prop o "gid" (coerce gid 'double-float))
    (eng:data-prop o "shell" (or (clun.sys:getenv "SHELL") eng:+null+))
    (eng:data-prop o "homedir" (clun.sys:homedir))
    o))

(defparameter *os-priority-overrides* (make-hash-table :test 'eql)
  "Process-local nice overrides from os.setPriority (pid → integer).
sb-posix has no setpriority; pure path tracks self so get/set stay consistent.")

(defun %os-priority (&optional pid)
  "Nice value from /proc/<pid>/stat field 19 on Linux; else 0.
Uses process-local override when set via os.setPriority."
  (let* ((self (or (clun.sys:getpid) 0))
         (target (cond ((null pid) self)
                       ((zerop pid) self)
                       (t pid)))
         (override (gethash target *os-priority-overrides*)))
    (or override
        (and (= target self)
             (gethash self *os-priority-overrides*))
        #+linux
        (ignore-errors
          (with-open-file (in (if (and pid (not (zerop pid)) (/= pid self))
                                  (format nil "/proc/~d/stat" pid)
                                  "/proc/self/stat")
                              :if-does-not-exist nil)
            (when in
              (let ((line (read-line in nil nil)))
                (when line
                  (let* ((rparen (position #\) line :from-end t))
                         (fields (when rparen
                                   (with-input-from-string (s (subseq line (1+ rparen)))
                                     (loop repeat 17 collect (read s nil nil)))))
                         (nice (nth 16 fields)))
                    (and (integerp nice) nice)))))))
        0)))

(defun %os-system-error (syscall errno code message)
  "Build and throw a Node-shaped SystemError."
  (let ((err (eng:js-construct
              (eng:js-get (eng:realm-global eng:*realm*) "Error")
              (list message))))
    (eng:js-set err "name" "SystemError" nil)
    (eng:js-set err "code" code nil)
    (eng:js-set err "errno" (coerce errno 'double-float) nil)
    (eng:js-set err "syscall" syscall nil)
    (eng:throw-js-value err)))

(defun %os-network-interfaces ()
  (let ((out (eng:new-object))
        (lo (eng:new-array
             (list
              (let ((a (eng:new-object)))
                (eng:data-prop a "address" "127.0.0.1")
                (eng:data-prop a "netmask" "255.0.0.0")
                (eng:data-prop a "family" "IPv4")
                (eng:data-prop a "mac" "00:00:00:00:00:00")
                (eng:data-prop a "internal" eng:+true+)
                (eng:data-prop a "cidr" "127.0.0.1/8")
                a)))))
    (eng:data-prop out "lo" lo)
    #+linux
    (ignore-errors
      (with-open-file (in "/proc/net/dev" :if-does-not-exist nil)
        (when in
          (read-line in nil nil)
          (read-line in nil nil)
          (loop for line = (read-line in nil nil)
                while line
                for colon = (position #\: line)
                when colon
                  do (let ((name (string-trim " " (subseq line 0 colon))))
                       (unless (string= name "lo")
                         (eng:data-prop out name (eng:new-array '()))))))))
    out))

(defun build-node-os ()
  (let ((o (eng:new-object)))
    (labels ((m (name arity fn)
               (eng:install-method o name arity fn)))
      (eng:data-prop o "EOL" (string #\Newline))
      (m "platform" 0
         (lambda (this args)
           (declare (ignore this args))
           (clun.sys:platform-name)))
      (m "arch" 0
         (lambda (this args)
           (declare (ignore this args))
           (clun.sys:machine-arch)))
      (m "type" 0
         (lambda (this args)
           (declare (ignore this args))
           (clun.sys:os-type)))
      (m "release" 0
         (lambda (this args)
           (declare (ignore this args))
           (clun.sys:os-release)))
      (m "hostname" 0
         (lambda (this args)
           (declare (ignore this args))
           (clun.sys:hostname)))
      (m "tmpdir" 0
         (lambda (this args)
           (declare (ignore this args))
           (clun.sys:tmpdir)))
      (m "homedir" 0
         (lambda (this args)
           (declare (ignore this args))
           (clun.sys:homedir)))
      (m "endianness" 0
         (lambda (this args)
           (declare (ignore this args))
           "LE"))
      (m "uptime" 0
         (lambda (this args)
           (declare (ignore this args))
           (coerce (clun.sys:uptime-seconds) 'double-float)))
      (m "totalmem" 0
         (lambda (this args)
           (declare (ignore this args))
           (coerce (clun.sys:total-memory) 'double-float)))
      (m "freemem" 0
         (lambda (this args)
           (declare (ignore this args))
           (coerce (clun.sys:free-memory) 'double-float)))
      (m "loadavg" 0
         (lambda (this args)
           (declare (ignore this args))
           (eng:new-array (clun.sys:loadavg))))
      (m "cpus" 0
         (lambda (this args)
           (declare (ignore this args))
           (eng:new-array (mapcar #'%os-cpu-from-plist (clun.sys:cpu-infos)))))
      (m "userInfo" 1
         (lambda (this args)
           (declare (ignore this args))
           (%os-user-info)))
      (m "networkInterfaces" 0
         (lambda (this args)
           (declare (ignore this args))
           (%os-network-interfaces)))
      (m "getPriority" 1
         (lambda (this args)
           (declare (ignore this))
           (let ((pid (if (undef-p (a args 0))
                          nil
                          (truncate (eng:to-number (a args 0))))))
             (coerce (%os-priority pid) 'double-float))))
      (m "setPriority" 2
         (lambda (this args)
           (declare (ignore this))
           ;; Node: setPriority([pid], priority). No sb-posix setpriority;
           ;; track self in-process so getPriority reflects setPriority.
           ;; Other pids → honest SystemError (cannot change foreign niceness).
           (let* ((n (length (coerce args 'list)))
                  (self (or (clun.sys:getpid) 0))
                  (pid self)
                  (priority 0))
             (cond
               ((>= n 2)
                (setf pid (truncate (eng:to-number (a args 0)))
                      priority (truncate (eng:to-number (a args 1)))))
               ((>= n 1)
                (setf priority (truncate (eng:to-number (a args 0)))))
               (t
                (eng:throw-type-error
                 "The \"priority\" argument must be of type number.")))
             (unless (<= -20 priority 19)
               (let ((err (eng:js-construct
                           (eng:js-get (eng:realm-global eng:*realm*) "RangeError")
                           (list (format nil
                                         "The value of \"priority\" is out of range. It must be >= -20 && <= 19. Received ~d"
                                         priority)))))
                 (eng:js-set err "code" "ERR_OUT_OF_RANGE" nil)
                 (eng:throw-js-value err)))
             (let ((target (if (zerop pid) self pid)))
               (cond
                 ((= target self)
                  (setf (gethash self *os-priority-overrides*) priority)
                  eng:+undefined+)
                 (t
                  (%os-system-error
                   "uv_os_setpriority" -1 "ERR_SYSTEM_ERROR"
                   (format nil
                           "A system error occurred: uv_os_setpriority returned EPERM (cannot set priority of pid ~d without host setpriority)"
                           target))))))))
      (m "availableParallelism" 0
         (lambda (this args)
           (declare (ignore this args))
           (coerce (clun.sys:cpu-count) 'double-float)))
      (let ((constants (eng:new-object))
            (signals (eng:new-object))
            (errno (eng:new-object))
            (dlopen (eng:new-object))
            (priority (eng:new-object)))
        (eng:data-prop signals "SIGHUP" 1d0)
        (eng:data-prop signals "SIGINT" 2d0)
        (eng:data-prop signals "SIGQUIT" 3d0)
        (eng:data-prop signals "SIGKILL" 9d0)
        (eng:data-prop signals "SIGTERM" 15d0)
        (eng:data-prop errno "EPERM" 1d0)
        (eng:data-prop errno "ENOENT" 2d0)
        (eng:data-prop errno "EACCES" 13d0)
        (eng:data-prop errno "EEXIST" 17d0)
        (eng:data-prop errno "EINVAL" 22d0)
        (eng:data-prop priority "PRIORITY_LOW" 19d0)
        (eng:data-prop priority "PRIORITY_BELOW_NORMAL" 10d0)
        (eng:data-prop priority "PRIORITY_NORMAL" 0d0)
        (eng:data-prop priority "PRIORITY_ABOVE_NORMAL" -7d0)
        (eng:data-prop priority "PRIORITY_HIGH" -14d0)
        (eng:data-prop priority "PRIORITY_HIGHEST" -20d0)
        (eng:data-prop constants "signals" signals)
        (eng:data-prop constants "errno" errno)
        (eng:data-prop constants "dlopen" dlopen)
        (eng:data-prop constants "priority" priority)
        (eng:data-prop o "constants" constants))
      (eng:data-prop o "devNull" "/dev/null")
      o)))

(register-node-builtin "os" #'build-node-os)
