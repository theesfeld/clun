;;;; main.lisp — the CLI toplevel (PLAN.md §3.6, Phase 08). Parses flags, installs
;;;; the runtime globals onto a fresh realm, autoloads .env, runs the entry, renders
;;;; uncaught errors (JS stack; Lisp backtrace only with --backtrace), maps to an
;;;; exit code (0 ok / 1 error / 2 usage).

(in-package :clun)

(defun print-version (&optional (stream *standard-output*))
  (format stream "clun ~a~%" *clun-version*))

(defun print-help (&optional (stream *standard-output*))
  (format stream "clun ~a — Bun, rewritten in pure Common Lisp~%~
                  ~%~
                  Usage: clun <file>              run a .js/.mjs/.cjs/.json file~%~
                  ~8@Tclun run <file>          run a file (package scripts: Phase 24)~%~
                  ~8@Tclun -e '<code>'         evaluate code~%~
                  ~8@Tclun -p '<code>'         evaluate and print the (awaited) result~%~
                  ~8@Tclun install            install package.json deps into node_modules~%~
                  ~8@Tclun add <pkg>          add a dependency (-d dev, -E exact) + install~%~
                  ~8@Tclun remove <pkg>       remove a dependency + reinstall~%~
                  ~%~
                  Flags: --cwd <dir>   set the working directory~%~
                  ~8@T--silent          suppress console.log/info/debug~%~
                  ~8@T--backtrace       show the Lisp backtrace on an internal error~%~
                  ~8@T-v, --version     print the version~%~
                  ~8@T--revision        print the build revision~%~
                  ~8@T-h, --help        print this help~%"
          *clun-version*))

;;; --- uncaught-error rendering ----------------------------------------------

(defun error-object-p (v)
  (and (eng:js-object-p v) (eq (eng:js-object-class v) :error)))

(defun render-uncaught (value)
  "Print an uncaught JS VALUE to stderr, Bun-style."
  (if (error-object-p value)
      (let ((stack (eng:js-get value "stack")))
        (if (stringp stack)
            (format *error-output* "~a~%" stack)
            (format *error-output* "Uncaught ~a: ~a~%"
                    (eng:to-string (eng:js-get value "name"))
                    (eng:to-string (eng:js-get value "message")))))
      (format *error-output* "Uncaught ~a~%" (eng:inspect-value value))))

;;; --- run helpers ------------------------------------------------------------

(defun resolve-cwd (r)
  (let ((cwd (cli:cli-get r :cwd)))
    (when cwd
      (handler-case (sys:change-directory cwd)
        (error () (error 'bad-cwd :dir cwd))))
    (sys:current-directory)))

(define-condition bad-cwd (error)
  ((dir :initarg :dir :reader bad-cwd-dir)))

(defun make-runtime-realm (r cwd &key script rest)
  "A fresh realm with the runtime globals installed + .env autoloaded."
  (let ((realm (eng:make-realm)))
    (rt:install-runtime realm
                        :argv (list :script script :rest rest)
                        :cwd cwd
                        :silent (cli:cli-get r :silent))
    (let ((proc (eng:js-get (eng:realm-global realm) "process")))
      (when (eng:js-object-p proc)
        (cli:load-dotenv (eng:js-get proc "env") cwd)))
    realm))

(defun tsx-extension-p (path)
  (let ((dot (position #\. path :from-end t)))
    (and dot (string= (subseq path dot) ".tsx"))))

(defun run-file (r file)
  "Execute FILE (a path). Returns an exit code. .ts/.mts/.cts are stripped by the
loader's *ts-strip-hook*; .tsx is rejected."
  (cond
    ((null file)
     (format *error-output* "clun: no file to run~%") 2)
    ((tsx-extension-p file)
     (format *error-output* "clun: .tsx is not supported~%") 1)
    (t
     (let* ((cwd (resolve-cwd r))
            (abs (if (sys:absolute-path-p file) file (sys:path-join cwd file))))
       (if (not (sys:file-p abs))
           (progn (format *error-output* "clun: cannot find module '~a'~%" file) 1)
           (let ((realm (make-runtime-realm r cwd :script abs :rest (cli:cli-get r :args))))
             (let ((clun-g (eng:js-get (eng:realm-global realm) "Clun")))
               (when (eng:js-object-p clun-g) (eng:data-prop clun-g "main" abs)))
             (eng:run-module-file abs :realm realm)
             (finish-exit realm)))))))

(defun run-test (r)
  "`clun test` — resolve cwd (honouring --cwd), then hand the test-subcommand argv
(file + trailing args, verbatim) to the test runner."
  (let ((cwd (resolve-cwd r))
        (argv (remove nil (cons (cli:cli-get r :file) (cli:cli-get r :args)))))
    (clun.test-runner:run-test-command argv cwd)))

;;; --- install / add / remove -------------------------------------------------

(defun %flag-p (tok) (and (plusp (length tok)) (char= (char tok 0) #\-)))

(defun run-install-command (r)
  "Handle `clun install` / `add <pkg…>` / `remove <pkg…>`: edit package.json for add/remove, then
install. Flags: -d/-D/--dev, -E/--exact, --frozen-lockfile, --production, --dry-run, --registry."
  (let ((sub (cli:cli-get r :subcommand))
        (cwd (resolve-cwd r))
        (names '()) (registry nil)
        (dev nil) (exact nil) (frozen nil) (production nil) (dry-run nil))
    ;; walk the tokens: --registry consumes its value (a bare URL is NOT a package name), other
    ;; flags set booleans, everything else is a package name.
    (loop with rest = (remove nil (cons (cli:cli-get r :file) (cli:cli-get r :args)))
          while rest
          for tok = (pop rest) do
            (cond
              ((member tok '("-d" "-D" "--dev" "--development") :test #'string=) (setf dev t))
              ((member tok '("-E" "--exact") :test #'string=) (setf exact t))
              ((string= tok "--frozen-lockfile") (setf frozen t))
              ((string= tok "--production") (setf production t))
              ((string= tok "--dry-run") (setf dry-run t))
              ((string= tok "--no-save") nil)                 ; accepted; no-op here
              ((string= tok "--registry")
               (if (and rest (not (%flag-p (car rest))))
                   (setf registry (pop rest))
                   (error 'clun.installer:install-error :message "--registry requires a value")))
              ((and (> (length tok) 11) (string= "--registry=" tok :end2 11)) (setf registry (subseq tok 11)))
              ((%flag-p tok) nil)                             ; ignore any other flag
              (t (push tok names))))
    (setf names (nreverse names))
    (handler-case
        (progn
          (cond
            ((string= sub "add")
             (when (null names) (error 'clun.installer:install-error :message "add: no packages given"))
             (if dry-run
                 (format t "clun add (dry-run): ~{~a~^, ~}~%" names)
                 (progn (clun.installer:add-dependencies cwd names :dev dev :exact exact :registry registry)
                        (clun.installer:install cwd :registry registry :production production)
                        (format t "installed ~{~a~^, ~}~%" names))))
            ((string= sub "remove")
             (when (null names) (error 'clun.installer:install-error :message "remove: no packages given"))
             (if dry-run
                 (format t "clun remove (dry-run): ~{~a~^, ~}~%" names)
                 (progn (clun.installer:remove-dependencies cwd names)
                        (clun.installer:install cwd :registry registry :production production)
                        (format t "removed ~{~a~^, ~}~%" names))))
            (t
             (if dry-run
                 (format t "clun install (dry-run)~%")
                 (let ((res (clun.installer:install cwd :registry registry :frozen frozen
                                                        :production production)))
                   (format t "clun install: ~(~a~), ~d package~:p~%"
                           (clun.installer:ir-source res) (clun.installer:ir-node-count res))
                   (dolist (s (clun.installer:ir-lifecycle-skipped res))
                     (format t "  note: lifecycle scripts skipped for ~a (clun never runs them)~%" s))))))
          0)
      (clun.installer:install-error (e)
        (format *error-output* "clun: ~a~%" (clun.installer:install-error-message e)) 1)
      (clun.registry:registry-error (e)
        (format *error-output* "clun: ~a~%" (clun.registry:registry-error-message e)) 1)
      (clun.integrity:integrity-error (e)
        (format *error-output* "clun: integrity error: ~a~%" (clun.integrity:integrity-error-message e)) 1)
      (clun.tarball:tarball-error (e)
        (format *error-output* "clun: tarball error: ~a~%" (clun.tarball:tarball-error-message e)) 1))))

(defun run-eval (r code print)
  "Evaluate CODE (script semantics; drives the loop). If PRINT, print the completion."
  (let* ((cwd (resolve-cwd r))
         (realm (make-runtime-realm r cwd :script "[eval]" :rest (cli:cli-get r :args)))
         (value (eng:eval-source code :realm realm)))
    (when print
      (let ((v (if (and (eng:js-promise-p value)
                        (not (eq (eng:js-promise-pstate value) :pending)))
                   (eng:js-promise-value value)   ; -p awaits the promise
                   value)))
        ;; a top-level string prints RAW (Node/Bun `-p '"x"'` → x); else inspected
        (%write-out (if (stringp v) v (eng:inspect-value v)))))
    (finish-exit realm)))

(defun %write-out (text)
  (write-string text *standard-output*) (write-char #\Newline *standard-output*)
  (finish-output *standard-output*))

(defun finish-exit (realm)
  "Normal completion: fire process 'exit' handlers with process.exitCode, return it."
  (let* ((proc (eng:js-get (eng:realm-global realm) "process"))
         (code (if (eng:js-object-p proc) (rt:safe-integer (eng:js-get proc "exitCode")) 0)))
    (rt:run-exit-handlers code)
    code))

;;; --- dispatch ---------------------------------------------------------------

(defun dispatch (argv)
  "Return a process exit code for ARGV (executable name already dropped)."
  (let ((r (cli:parse-cli-args argv)))
    (ecase (cli:cli-action r)
      (:version (print-version) 0)
      (:revision (format t "~a~%" *clun-revision*) 0)
      (:help (print-help) 0)
      (:error (format *error-output* "clun: ~a~%note: run `clun --help` for usage~%"
                      (cli:cli-get r :error-msg))
              2)
      (:eval (run-eval r (cli:cli-get r :code) nil))
      (:print (run-eval r (cli:cli-get r :code) t))
      (:run (let ((sub (cli:cli-get r :subcommand)))
              (cond
                ((equal sub "test") (run-test r))
                ((member sub '("install" "add" "remove") :test #'equal) (run-install-command r))
                (t (run-file r (cli:cli-get r :file)))))))))

(defun main ()
  "Toplevel for the saved executable. Never lets a Lisp backtrace reach the user
unless --backtrace was passed; JS throws render as the value + stack."
  (let* ((argv (rest sb-ext:*posix-argv*))
         (backtrace (and (member "--backtrace" argv :test #'string=) t)))
    (sb-ext:exit
     :code
     (handler-case (dispatch argv)
       (rt:process-exit (c) (rt:process-exit-code c))
       (eng:js-condition (c)
         (render-uncaught (eng:js-condition-value c))
         (ignore-errors (rt:run-exit-handlers 1))       ; 'exit' fires on uncaught too
         1)
       (bad-cwd (c)
         (format *error-output* "clun: cannot change directory to '~a'~%" (bad-cwd-dir c))
         2)
       ;; stack/heap exhaustion → a JS RangeError, never a raw Lisp backtrace
       (storage-condition ()
         (format *error-output* "RangeError: Maximum call stack size exceeded~%")
         (when backtrace (sb-debug:print-backtrace :stream *error-output* :count 30))
         1)
       (error (c)
         (format *error-output* "clun: ~a~%" c)
         (when backtrace (sb-debug:print-backtrace :stream *error-output* :count 30))
         1)))))
