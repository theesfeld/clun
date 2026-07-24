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

(defun %os-priority ()
  "Nice value from /proc/self/stat field 19 on Linux; else 0."
  (or
   #+linux
   (ignore-errors
     (with-open-file (in "/proc/self/stat" :if-does-not-exist nil)
       (when in
         (let ((line (read-line in nil nil)))
           (when line
             (let* ((rparen (position #\) line :from-end t))
                    (fields (when rparen
                              (with-input-from-string (s (subseq line (1+ rparen)))
                                (loop repeat 17 collect (read s nil nil)))))
                    (nice (nth 16 fields)))
               (and (integerp nice) nice)))))))
   0))

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
           (declare (ignore this args))
           (coerce (%os-priority) 'double-float)))
      (m "setPriority" 2
         (lambda (this args)
           (declare (ignore this args))
           eng:+undefined+))
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
