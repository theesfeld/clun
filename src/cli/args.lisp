;;;; args.lisp — CLI flag parsing (PLAN.md §3.6, Phase 08). Positional-stop grammar:
;;;; global flags are recognized until the FIRST non-flag positional; everything
;;;; after passes through to process.argv. Exact Bun flag spellings.

(in-package :clun.cli)

(defun cli-action (r) (getf r :action))
(defun cli-get (r key &optional default) (getf r key default))

(defun parse-cli-args (argv)
  "Parse ARGV (executable name already dropped) into a plist:
  :action  — :run :eval :print :version :revision :help :error (build/compile via :run subcommand)
  :file :code :subcommand :args :cwd :silent :backtrace :error-msg
  :hot :watch :no-clear-screen"
  (let ((action nil) (code nil) (file nil) (subcommand nil)
        (args '()) (cwd nil) (silent nil) (backtrace nil) (err nil)
        (hot nil) (watch nil) (no-clear-screen nil)
        (toks argv))
    (labels ((next () (pop toks))
             (need (flag) (or (next) (progn (setf err (format nil "flag ~a needs a value" flag)) nil))))
      ;; --- flag phase ---
      (loop
        (when (or err action file) (return))
        (let ((tok (car toks)))
          (when (null tok) (return))
          (cond
            ((member tok '("-v" "--version" "version") :test #'string=) (next) (setf action :version))
            ((string= tok "--revision") (next) (setf action :revision))
            ((member tok '("-h" "--help" "help") :test #'string=) (next) (setf action :help))
            ((member tok '("-e" "--eval") :test #'string=)
             (next) (setf action :eval code (need tok) args toks toks nil))
            ((member tok '("-p" "--print") :test #'string=)
             (next) (setf action :print code (need tok) args toks toks nil))
            ((string= tok "--cwd") (next) (setf cwd (need tok)))
            ((string= tok "--silent") (next) (setf silent t))
            ((string= tok "--backtrace") (next) (setf backtrace t))
            ;; Phase 67 / #188 — state-preserving hot reload + hard watch restart.
            ((string= tok "--hot") (next) (setf hot t))
            ((string= tok "--watch") (next) (setf watch t))
            ((string= tok "--no-clear-screen") (next) (setf no-clear-screen t))
            ;; unknown flag → usage error
            ((and (> (length tok) 0) (char= (char tok 0) #\-))
             (setf err (format nil "unknown flag ~a" tok)))
            ;; first positional stops flag parsing
            (t
             (next)
             (if (member tok '("run" "test" "install" "add" "remove" "exec"
                              "build" "compile" "fmt" "format" "lint" "x" "create" "init" "tsc" "typecheck")
                         :test #'string=)
                 (progn (setf subcommand tok action :run)
                        ;; tsc/typecheck take zero or more path args (not a single file slot)
                        (if (member tok '("tsc" "typecheck") :test #'string=)
                            (progn (setf file nil args toks))
                            (progn (setf file (next))
                                   (setf args toks))))
                 (progn (setf action :run file tok args toks)))
             (setf toks nil))))))
    (cond
      (err (list :action :error :error-msg err))
      ((and (member action '(:eval :print)) (null code) (null err))
       (list :action :error :error-msg "missing code for -e/-p"))
      ((and hot watch)
       (list :action :error :error-msg "use either --hot or --watch, not both"))
      (t (list :action (or action :help)
               :code code :file file :subcommand subcommand
               :args args :cwd cwd :silent silent :backtrace backtrace
               :hot hot :watch watch :no-clear-screen no-clear-screen)))))

(defun parse-build-args (argv)
  "Parse `clun build|compile` trailing ARGV (after the subcommand token).
   Returns plist :entry :outfile :target :template :assets :defines :minify
   :bytecode :sign :all-targets :verify :error :compile."
  (let ((entry nil) (outfile nil) (target nil) (template nil)
        (assets '()) (defines '()) (minify nil) (bytecode nil)
        (sign nil) (all-targets nil) (verify nil) (compile-flag nil)
        (err nil) (toks argv))
    (labels ((next () (pop toks))
             (need (flag)
               (or (next)
                   (progn (setf err (format nil "flag ~a needs a value" flag)) nil))))
      (loop
        (let ((tok (car toks)))
          (when (or err (null tok)) (return))
          (cond
            ((string= tok "--compile") (next) (setf compile-flag t))
            ((or (string= tok "--outfile") (string= tok "-o"))
             (next) (setf outfile (need tok)))
            ((string= tok "--target") (next) (setf target (need tok)))
            ((string= tok "--template") (next) (setf template (need tok)))
            ((string= tok "--asset") (next)
             (let ((a (need tok))) (when a (push a assets))))
            ((string= tok "--define") (next)
             (let ((d (need tok)))
               (when d
                 (let ((eq (position #\= d)))
                   (if eq
                       (push (cons (subseq d 0 eq) (subseq d (1+ eq))) defines)
                       (setf err (format nil "define must be name=value, got ~a" d)))))))
            ((string= tok "--minify") (next) (setf minify t))
            ((string= tok "--bytecode") (next) (setf bytecode t))
            ((string= tok "--sign") (next) (setf sign t))
            ((string= tok "--targets") (next)
             (let ((v (need tok)))
               (when (and v (or (string= v "all") (string= v "*")))
                 (setf all-targets t))))
            ((string= tok "--verify") (next) (setf verify (need tok)))
            ((and (> (length tok) 0) (char= (char tok 0) #\-))
             (next)
             (setf err (format nil "unknown build flag ~a" tok)))
            (t
             (next)
             (if entry
                 (setf err (format nil "unexpected extra argument ~a" tok))
                 (setf entry tok)))))))
    (cond
      (err (list :error err))
      (verify (list :verify verify))
      ((null entry)
       (list :error "build requires an entry file (or --verify <path>)"))
      (t (list :entry entry
               :outfile outfile
               :target target
               :template template
               :assets (nreverse assets)
               :defines (nreverse defines)
               :minify minify
               :bytecode bytecode
               :sign sign
               :all-targets all-targets
               :compile compile-flag)))))
