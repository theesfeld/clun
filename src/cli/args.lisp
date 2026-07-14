;;;; args.lisp — CLI flag parsing (PLAN.md §3.6, Phase 08). Positional-stop grammar:
;;;; global flags are recognized until the FIRST non-flag positional; everything
;;;; after passes through to process.argv. Exact Bun flag spellings.

(in-package :clun.cli)

(defun cli-action (r) (getf r :action))
(defun cli-get (r key &optional default) (getf r key default))

(defun parse-cli-args (argv)
  "Parse ARGV (executable name already dropped) into a plist:
  :action  — :run :eval :print :version :revision :help :error
  :file :code :subcommand :args :cwd :silent :backtrace :error-msg"
  (let ((action nil) (code nil) (file nil) (subcommand nil)
        (args '()) (cwd nil) (silent nil) (backtrace nil) (err nil)
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
            ;; unknown flag → usage error
            ((and (> (length tok) 0) (char= (char tok 0) #\-))
             (setf err (format nil "unknown flag ~a" tok)))
            ;; first positional stops flag parsing
            (t
             (next)
             (if (member tok '("run" "test" "install" "add" "remove" "x" "create" "init")
                         :test #'string=)
                 (progn (setf subcommand tok action :run)
                        (setf file (next))     ; the file/script name after the subcommand
                        (setf args toks))       ; remaining verbatim
                 (progn (setf action :run file tok args toks)))
             (setf toks nil))))))
    (cond
      (err (list :action :error :error-msg err))
      ((and (member action '(:eval :print)) (null code) (null err))
       (list :action :error :error-msg "missing code for -e/-p"))
      (t (list :action (or action :help)
               :code code :file file :subcommand subcommand
               :args args :cwd cwd :silent silent :backtrace backtrace)))))
