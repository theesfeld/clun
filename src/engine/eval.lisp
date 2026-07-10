;;;; eval.lisp — top-level: compile a Program in a realm and run it (Phase 03).
;;;; Global-scope declarations become properties of the global object (a Phase 03
;;;; simplification of the split global environment record — documented in the design
;;;; doc); function bodies get proper declarative frames with TDZ.

(in-package :clun.engine)

(defun program-strict-p (program)
  (dolist (s (program-body program) nil)
    (if (and (expression-statement-p s) (expression-statement-directive s))
        (when (string= (expression-statement-directive s) "use strict") (return t))
        (return nil))))

(defun global-instantiate (stmts comp)
  "Hoist top-level function and var declarations onto the global object."
  (let ((g (realm-global *realm*)))
    (dolist (fd (collect-function-decls stmts))
      (let* ((name (identifier-name (function-node-id fd)))
             (fn (funcall (compile-function-common comp (function-node-params fd)
                                                   (function-node-body fd) name)
                          nil)))
        (js-set g name fn t)))
    (multiple-value-bind (vars funcs) (collect-var-names stmts)
      (declare (ignore funcs))
      (dolist (v vars)
        (unless (has-own-property g v) (create-data-property g v +undefined+))))
    ;; top-level let/const/class -> global property (TDZ approximated at global scope)
    (dolist (n (collect-lexical-names stmts))
      (unless (has-own-property g n) (create-data-property g n +undefined+)))))

(defun run-program (program realm &key strict)
  (let ((*realm* realm)
        (comp (make-comp)))
    (when (or strict (program-strict-p program)) (setf (comp-strict comp) t))
    (global-instantiate (program-body program) comp)
    (funcall (compile-seq comp (program-body program)) nil))
  +undefined+)

(defun run-source (source &key (realm (make-realm)) strict (source-type :script))
  "Parse and execute SOURCE in REALM (created if not given). Returns REALM.
Signals a js-condition on an uncaught JS throw; the caller inspects the value.
*realm* is bound around PARSING too so a SyntaxError builds a real Error object."
  (let ((*realm* realm))
    (run-program (parse-program source :source-type source-type) realm :strict strict))
  realm)

(defun indirect-eval (source)
  "Indirect eval: parse SOURCE and run it in the CURRENT realm's global scope,
returning the completion value (§19.2.1). *realm* is already bound by the caller."
  (let ((program (parse-program source :source-type :script))
        (comp (make-comp)))
    (when (program-strict-p program) (setf (comp-strict comp) t))
    (global-instantiate (program-body program) comp)
    (let ((result +undefined+))
      (dolist (s (program-body program) result)
        (let ((c (compile-node comp s)))
          (if (expression-statement-p s) (setf result (funcall c nil)) (funcall c nil)))))))

;;; convenience for the REPL/tests: evaluate an expression source, return the value
(defun eval-source (source &key (realm (make-realm)) strict)
  (let* ((*realm* realm)
         (program (parse-program source :source-type :script))
         (comp (make-comp)))
    (when (or strict (program-strict-p program)) (setf (comp-strict comp) t))
    (global-instantiate (program-body program) comp)
    ;; return the completion value of the last expression statement
    (let ((body (program-body program)) (result +undefined+))
      (dolist (s body result)
        (let ((c (compile-node comp s)))
          (if (expression-statement-p s)
              (setf result (funcall c nil))
              (funcall c nil)))))))
