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
      (:run (if (equal (cli:cli-get r :subcommand) "test")
                (run-test r)
                (run-file r (cli:cli-get r :file)))))))

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
