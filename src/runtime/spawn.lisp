;;;; spawn.lisp — Clun.spawnSync, the blocking subprocess primitive (PLAN.md Phase 24, §3.3). A thin
;;;; wrapper over sb-ext:run-program :wait t. Piped stdout/stderr are redirected to TEMP FILES (a full
;;;; pipe would deadlock a synchronous read of any size — the file absorbs it), read back after exit as
;;;; Uint8Arrays; stdin data is written to a temp file used as :input. `spawn` (async, reactor pipes,
;;;; .exited/kill) is the next milestone. Pure CL (sb-ext:run-program is the sanctioned subprocess API,
;;;; PLAN §1.1). No zombies: run-program auto-reaps.

(in-package :clun.runtime)

(defparameter *signal-names*
  '((1 . "SIGHUP") (2 . "SIGINT") (3 . "SIGQUIT") (4 . "SIGILL") (6 . "SIGABRT") (8 . "SIGFPE")
    (9 . "SIGKILL") (11 . "SIGSEGV") (13 . "SIGPIPE") (14 . "SIGALRM") (15 . "SIGTERM"))
  "Signal number → name (the common set; unknown → SIGnn).")

(defun %signal-name (n) (or (cdr (assoc n *signal-names*)) (format nil "SIG~d" n)))

(defun %cmd->argv (cmd)
  "A JS array [program, ...args] → a non-empty CL list of strings, or a JS TypeError."
  (unless (eng:js-array-p cmd)
    (eng:throw-type-error "Clun.spawnSync: the first argument must be an array of strings"))
  (let ((argv (loop for i below (eng:array-length cmd)
                    collect (eng:to-string (eng:js-getv cmd (princ-to-string i))))))
    (when (null argv) (eng:throw-type-error "Clun.spawnSync: the command array is empty"))
    argv))

(defun %opt (opts key) (if (and opts (eng:js-object-p opts)) (eng:js-get opts key) eng:+undefined+))

(defun %opt-string (opts key)
  (let ((v (%opt opts key))) (unless (eng:js-undefined-p v) (eng:to-string v))))

(defun %stdio-mode (opts key)
  "The stdio mode for KEY (\"stdout\"/\"stderr\"): :pipe (default) / :inherit / :ignore."
  (let ((v (%opt-string opts key)))
    (cond ((null v) :pipe)
          ((string= v "inherit") :inherit)
          ((string= v "ignore") :ignore)
          (t :pipe))))

(defun %stdio-target (mode path)
  (ecase mode (:pipe path) (:inherit t) (:ignore nil)))

(defun %env-list (g opts)
  "opts.env (a JS object) → a list of \"K=V\" strings, or NIL to inherit the current environment."
  (let ((env (%opt opts "env")))
    (when (eng:js-object-p env)
      (let* ((object (eng:js-get g "Object"))
             (keys (eng:js-call (eng:js-get object "keys") object (list env))))
        (loop for i below (eng:array-length keys)
              for k = (eng:to-string (eng:js-getv keys (princ-to-string i)))
              collect (format nil "~a=~a" k (eng:to-string (eng:js-getv env k))))))))

(defun %stdin-octets (opts)
  "opts.stdin as octets to feed the child (a string / typed-array / ArrayBuffer), or NIL."
  (let ((v (%opt opts "stdin")))
    (cond ((eng:js-undefined-p v) nil)
          ((eng:js-typed-array-p v) (multiple-value-bind (a o l) (eng:ta-octets v) (subseq a o (+ o l))))
          ((eng:js-array-buffer-p v) (copy-seq (eng:js-array-buffer-bytes v)))
          ((eng:js-object-p v) nil)                 ; "inherit"/"ignore" objects unsupported in sync → ignore
          (t (eng:code-units->utf8 (eng:to-string v))))))

(defun %spawn-result (g proc stdout-octets stderr-octets)
  (let ((o (eng:new-object))
        (status (sb-ext:process-status proc))
        (code (sb-ext:process-exit-code proc)))
    (eng:data-prop o "pid" (coerce (or (sb-ext:process-pid proc) -1) 'double-float))
    (cond
      ((eq status :exited)
       (eng:data-prop o "exitCode" (coerce (or code 0) 'double-float))
       (eng:data-prop o "signalCode" eng:+null+)
       (eng:data-prop o "success" (eng:js-boolean (eql code 0))))
      ((eq status :signaled)
       (eng:data-prop o "exitCode" eng:+null+)
       (eng:data-prop o "signalCode" (%signal-name (or code 0)))
       (eng:data-prop o "success" eng:+false+))
      (t
       (eng:data-prop o "exitCode" (if code (coerce code 'double-float) eng:+null+))
       (eng:data-prop o "signalCode" eng:+null+)
       (eng:data-prop o "success" (eng:js-boolean (eql code 0)))))
    (eng:data-prop o "stdout" (if stdout-octets (eng:u8-from-octets stdout-octets) eng:+null+))
    (eng:data-prop o "stderr" (if stderr-octets (eng:u8-from-octets stderr-octets) eng:+null+))
    o))

(defun %spawn-sync (g cmd opts)
  (let* ((argv (%cmd->argv cmd))
         (program (first argv)) (args (rest argv))
         (cwd (%opt-string opts "cwd"))
         (env (%env-list g opts))
         (stdin-octets (%stdin-octets opts))
         (out-mode (%stdio-mode opts "stdout"))
         (err-mode (%stdio-mode opts "stderr"))
         (tmp (clun.sys:make-temp-dir "/tmp/clun-spawn-")))
    (unwind-protect
         (let* ((out-path (clun.sys:path-join tmp "out"))
                (err-path (clun.sys:path-join tmp "err"))
                (in-path (when stdin-octets (clun.sys:path-join tmp "in"))))
           (when stdin-octets (clun.sys:write-file-octets in-path stdin-octets))
           (let ((proc (handler-case
                           (apply #'sb-ext:run-program program args
                                  :search t :wait t
                                  :output (%stdio-target out-mode out-path)
                                  :error (%stdio-target err-mode err-path)
                                  :input in-path
                                  (append (when cwd (list :directory cwd))
                                          (when env (list :environment env))))
                         (error (e)
                           (eng:throw-js-value
                            (eng:js-construct (eng:js-get g "Error")
                                              (list (format nil "Clun.spawnSync ~a: ~a" program e))))))))
             (%spawn-result g proc
                            (and (eq out-mode :pipe) (clun.sys:read-file-octets out-path))
                            (and (eq err-mode :pipe) (clun.sys:read-file-octets err-path)))))
      (ignore-errors (clun.sys:remove-recursive tmp)))))

(defun install-spawn (clun g)
  "Install Clun.spawnSync onto the CLUN global object (G is the realm global)."
  (eng:install-method clun "spawnSync" 2
    (lambda (this args) (declare (ignore this))
      (%spawn-sync g (eng:arg args 0) (eng:arg args 1)))))
