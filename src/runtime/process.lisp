;;;; process.lisp — the process object (PLAN.md §3.6, Phase 08). Augments the
;;;; engine's stub `process` (which already carries nextTick). All host access is
;;;; via clun.sys platform primitives (pure SBCL). process.env is a plain snapshot
;;;; object (no live OS interceptor — documented divergence).

(in-package :clun.runtime)

(defparameter *node-version* "22.11.0"
  "Pinned Node LTS whose docs we target (process.versions.node). See DECISIONS.md.")

(defun %env-object ()
  (let ((o (eng:new-object)))
    (loop for (k . v) in (sys:environ-alist) do (eng:data-prop o k v))
    o))

(defun %writable-stream (stream fd)
  "A minimal Writable: .write(chunk)->bool, .isTTY, .fd, .end()."
  (let ((w (eng:new-object)))
    (eng:install-method w "write" 1
      (lambda (this args) (declare (ignore this))
        (write-string (eng:to-string (eng:arg args 0)) stream)
        (finish-output stream)
        eng:+true+))
    (when (sys:tty-p stream) (eng:data-prop w "isTTY" eng:+true+))
    (eng:data-prop w "fd" (coerce fd 'double-float))
    (eng:install-method w "end" 0 (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    w))

(defun %exec-path ()
  "argv[0]/execPath resolved to an absolute path when possible (Node's execPath is
always absolute); a bare PATH-resolved name that can't be truename'd is left as-is."
  (let ((a0 (or (first sb-ext:*posix-argv*) "clun")))
    (or (ignore-errors (sys:pathname->native (truename (sys:native->pathname a0)))) a0)))

(defun install-process (realm rt &key argv cwd)
  (let* ((eng:*realm* realm)
         (g (eng:realm-global realm))
         ;; augment the engine-installed stub if present, else make one
         (proc (let ((existing (eng:js-get g "process")))
                 (if (eng:js-object-p existing) existing (eng:new-object)))))
    (setf (runtime-process rt) proc)
    ;; argv: [execPath, scriptAbsPath, ...rest]
    (let ((exec (%exec-path)))
      (eng:data-prop proc "argv"
                     (eng:new-array (list* exec (or (getf argv :script) "[eval]")
                                           (getf argv :rest))))
      (eng:data-prop proc "execPath" exec)
      (eng:data-prop proc "argv0" exec))
    (eng:data-prop proc "env" (%env-object))
    (eng:data-prop proc "platform" (sys:platform-name))
    (eng:data-prop proc "arch" (sys:machine-arch))
    (eng:data-prop proc "pid" (coerce (sys:getpid) 'double-float))
    (eng:data-prop proc "exitCode" eng:+undefined+)
    ;; versions
    (let ((versions (eng:new-object)))
      (eng:data-prop versions "node" *node-version*)
      (eng:data-prop versions "clun" clun::*clun-version*)
      (eng:data-prop proc "versions" versions))
    (eng:data-prop proc "version" (concatenate 'string "v" *node-version*))
    (eng:data-prop proc "title" "clun")
    ;; cwd / chdir
    (eng:install-method proc "cwd" 0
      (lambda (this args) (declare (ignore this args)) (sys:current-directory)))
    (eng:install-method proc "chdir" 1
      (lambda (this args) (declare (ignore this))
        (let ((dir (eng:to-string (eng:arg args 0))))
          (handler-case (sys:change-directory dir)
            (error () (eng:throw-type-error
                       (format nil "ENOENT: no such file or directory, chdir '~a'" dir)))))
        eng:+undefined+))
    ;; stdout / stderr
    (eng:data-prop proc "stdout" (%writable-stream *standard-output* 1))
    (eng:data-prop proc "stderr" (%writable-stream *error-output* 2))
    ;; hrtime  (microsecond resolution — documented)
    (let ((hrtime (eng:make-native-function "hrtime" 1
                    (lambda (this args) (declare (ignore this))
                      (let* ((now (sys:monotonic-nanoseconds))
                             (prev (eng:arg args 0))
                             (base (cond ((eng:js-array-p prev)
                                          (let ((l (eng:array-like->list prev)))
                                            (+ (* (safe-integer (first l)) 1000000000)
                                               (safe-integer (second l)))))
                                         ((eng:js-undefined-p prev) 0)
                                         (t (eng:throw-type-error
                                             "The \"time\" argument must be an Array"))))
                             (delta (- now base)))
                        (eng:new-array (list (coerce (floor delta 1000000000) 'double-float)
                                             (coerce (mod delta 1000000000) 'double-float))))))))
      (eng:install-method hrtime "bigint" 0
        ;; BigInt lands in Phase 11; return a Number for now (documented).
        (lambda (this args) (declare (ignore this args))
          (coerce (sys:monotonic-nanoseconds) 'double-float)))
      (eng:data-prop proc "hrtime" hrtime))
    ;; memoryUsage (RSS plus SBCL dynamic-space approximations)
    (eng:install-method proc "memoryUsage" 0
      (lambda (this args) (declare (ignore this args))
        (let ((o (eng:new-object))
              (rss (coerce (sys:resident-set-bytes) 'double-float))
              (used (coerce (sys:heap-bytes-used) 'double-float)))
          (eng:data-prop o "rss" rss)
          (eng:data-prop o "heapTotal" used)
          (eng:data-prop o "heapUsed" used)
          (eng:data-prop o "external" 0d0)
          (eng:data-prop o "arrayBuffers" 0d0)
          o)))
    ;; exit / exitCode
    (eng:install-method proc "exit" 1
      (lambda (this args) (declare (ignore this))
        (let ((code (if (and args (not (eng:js-undefined-p (eng:arg args 0))))
                        (safe-integer (eng:arg args 0))     ; NaN/Inf/non-number → 0
                        (%read-exit-code proc))))
          (run-exit-handlers code)
          (error 'process-exit :code code))))
    ;; minimal 'exit' emitter (only 'exit' fires)
    (eng:install-method proc "on" 2
      (lambda (this args) (declare (ignore this))
        (when (and (string= (eng:to-string (eng:arg args 0)) "exit")
                   (eng:callable-p (eng:arg args 1)))
          (push (eng:arg args 1) (runtime-exit-listeners rt)))
        proc))
    (eng:install-method proc "once" 2
      (lambda (this args) (declare (ignore this))
        (when (and (string= (eng:to-string (eng:arg args 0)) "exit")
                   (eng:callable-p (eng:arg args 1)))
          (push (eng:arg args 1) (runtime-exit-listeners rt)))
        proc))
    (eng:install-method proc "emit" 1
      (lambda (this args) (declare (ignore this))
        (when (string= (eng:to-string (eng:arg args 0)) "exit")
          (run-exit-handlers (%read-exit-code proc)))
        eng:+true+))
    (eng:install-method proc "removeListener" 2 (lambda (this args) (declare (ignore this args)) proc))
    (eng:hidden-prop g "process" proc)
    proc))

(defun %read-exit-code (proc)
  "The current process.exitCode as an integer (undefined/NaN/Infinity → 0)."
  (let ((v (eng:js-get proc "exitCode")))
    (if (eng:js-undefined-p v) 0 (safe-integer v))))
