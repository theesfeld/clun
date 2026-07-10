;;;; main.lisp — toplevel entry for the saved executable.
;;;; Phase 00 handles --version/--revision/--help only; full command dispatch,
;;;; the shared inspector, and condition->exit-code mapping arrive in Phase 08.

(in-package :clun)

(defun print-version (&optional (stream *standard-output*))
  (format stream "clun ~a~%" *clun-version*))

(defun print-help (&optional (stream *standard-output*))
  (format stream "clun ~a — Bun, rewritten in pure Common Lisp~%~
                  ~%~
                  Usage: clun <file>            run a .js/.mjs/.cjs/.ts/.mts/.cts/.json file~%~
                  ~8@Tclun run <script>      run a package.json script~%~
                  ~8@Tclun test             run tests~%~
                  ~8@Tclun install|add|remove  manage dependencies~%~
                  ~%~
                  Flags: -v, --version   print the version~%~
                  ~8@T--revision         print the build revision~%~
                  ~8@T-h, --help         print this help~%"
          *clun-version*))

(defun dispatch (args)
  "Return a process exit code for the parsed ARGS (executable name already dropped)."
  (let ((cmd (first args)))
    (cond
      ((null cmd)
       ;; No REPL in v1; a bare invocation prints usage.
       (print-help)
       0)
      ((member cmd '("-v" "--version" "version") :test #'string=)
       (print-version)
       0)
      ((string= cmd "--revision")
       (format t "~a~%" *clun-revision*)
       0)
      ((member cmd '("-h" "--help" "help") :test #'string=)
       (print-help)
       0)
      (t
       (format *error-output*
               "clun: unknown command ~s~%note: run `clun --help` for usage~%"
               cmd)
       2))))

(defun main ()
  "Toplevel for the saved executable (PLAN.md §3.6). Never lets a Lisp backtrace
reach the user; the full condition bridge lands in Phase 08."
  (sb-ext:exit
   :code (handler-case (dispatch (rest sb-ext:*posix-argv*))
           (error (e)
             (format *error-output* "clun: ~a~%" e)
             1))))
