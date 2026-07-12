;;;; conditions.lisp — the one error the stripper raises (PLAN.md §3.3, Phase 09).
;;;; Mirrors Node's ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX; the loader boundary maps it to
;;;; a JS SyntaxError carrying line:col.

(in-package :clun.transpiler)

(define-condition unsupported-ts-syntax (error)
  ((message :initarg :message :reader uts-message)
   (line    :initarg :line    :initform 1 :reader uts-line)
   (col     :initarg :col     :initform 0 :reader uts-col)
   (path    :initarg :path    :initform nil :reader uts-path))
  (:report (lambda (c s)
             (format s "~a (~a:~a)" (uts-message c) (uts-line c) (uts-col c)))))

(defun ts-error (tok message &optional path)
  "Signal an unsupported-ts-syntax at TOK's position."
  (error 'unsupported-ts-syntax :message message :path path
         :line (if tok (eng:token-line tok) 1)
         :col (if tok (1+ (eng:token-col tok)) 1)))
