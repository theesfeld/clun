;;;; analyzer.lisp — scope analysis (PLAN.md Phase 02, §3.1). A post-parse pass over
;;;; statement scopes catching lexical-redeclaration early errors (§14.2.1 etc.).
;;;; Conservative: it only flags certain duplicates, so it never rejects valid code
;;;; (a miss is safe, a false positive is not). Full hoisting/slot-index/TDZ metadata
;;;; grows here as the evaluator (Phase 03) needs it.

(in-package :clun.engine)

(defun binding-bound-names (node)
  "The identifier names bound by a binding target / pattern NODE."
  (typecase node
    (identifier (list (identifier-name node)))
    (array-pattern (loop for e in (array-pattern-elements node)
                         when e append (binding-bound-names e)))
    (object-pattern (loop for pr in (object-pattern-properties node)
                          append (if (rest-element-p pr)
                                     (binding-bound-names (rest-element-argument pr))
                                     (binding-bound-names (property-value pr)))))
    (assignment-pattern (binding-bound-names (assignment-pattern-left node)))
    (rest-element (binding-bound-names (rest-element-argument node)))
    (t nil)))

(defun stmt-lexical-names (s)
  "Lexically-declared names introduced directly by statement S (let/const/class)."
  (typecase s
    (variable-declaration
     (when (member (variable-declaration-kind s) '(:let :const))
       (loop for d in (variable-declaration-declarations s)
             append (binding-bound-names (variable-declarator-id d)))))
    (class-node (when (and (class-node-declaration s) (class-node-id s))
                  (list (identifier-name (class-node-id s)))))
    (export-named-declaration (when (export-named-declaration-declaration s)
                                (stmt-lexical-names (export-named-declaration-declaration s))))
    (export-default-declaration (when (class-node-p (export-default-declaration-declaration s))
                                  nil))
    (t nil)))

(defun check-lexical-scope (stmts)
  "Signal a SyntaxError on duplicate lexical declarations directly in STMTS."
  (let ((seen (make-hash-table :test 'equal)))
    (dolist (s stmts)
      (dolist (n (stmt-lexical-names s))
        (when (gethash n seen)
          (throw-syntax-error (format nil "duplicate lexical declaration '~a'" n)))
        (setf (gethash n seen) t)))))

(defun analyze-scope-body (stmts)
  "Check STMTS as one lexical scope, then recurse into sub-scopes."
  (check-lexical-scope stmts)
  (mapc #'analyze-node stmts))

(defun analyze-node (node)
  "Recurse to statement sub-scopes, checking lexical duplicates at each."
  (typecase node
    (null nil)
    (program (analyze-scope-body (program-body node)))
    (block-statement (analyze-scope-body (block-statement-body node)))
    (function-node (analyze-node (function-node-body node)))
    (arrow-function (analyze-node (arrow-function-body node)))
    (if-statement (analyze-node (if-statement-consequent node))
                  (analyze-node (if-statement-alternate node)))
    (labeled-statement (analyze-node (labeled-statement-body node)))
    (with-statement (analyze-node (with-statement-body node)))
    (while-statement (analyze-node (while-statement-body node)))
    (do-while-statement (analyze-node (do-while-statement-body node)))
    (for-statement (analyze-node (for-statement-body node)))
    (for-in-statement (analyze-node (for-in-statement-body node)))
    (for-of-statement (analyze-node (for-of-statement-body node)))
    (switch-statement
     ;; all case consequents share one lexical scope (§14.12)
     (let ((all (loop for c in (switch-statement-cases node)
                      append (switch-case-consequent c))))
       (analyze-scope-body all)))
    (try-statement (analyze-node (try-statement-block node))
                   (when (try-statement-handler node)
                     (analyze-node (catch-clause-body (try-statement-handler node))))
                   (analyze-node (try-statement-finalizer node)))
    (variable-declaration
     (dolist (d (variable-declaration-declarations node))
       (analyze-node (variable-declarator-init d))))
    (expression-statement (analyze-node (expression-statement-expression node)))
    (return-statement (analyze-node (return-statement-argument node)))
    (throw-statement (analyze-node (throw-statement-argument node)))
    (export-named-declaration (analyze-node (export-named-declaration-declaration node)))
    (export-default-declaration (analyze-node (export-default-declaration-declaration node)))
    (class-node (analyze-node (class-node-body node)))
    (class-body (dolist (m (class-body-body node)) (analyze-node m)))
    (method-definition (analyze-node (method-definition-value node)))
    ;; descend into a few expression positions that commonly hold functions
    (call-expression (analyze-node (call-expression-callee node))
                     (mapc #'analyze-node (call-expression-arguments node)))
    (new-expression (mapc #'analyze-node (new-expression-arguments node)))
    (assignment-expression (analyze-node (assignment-expression-right node)))
    (sequence-expression (mapc #'analyze-node (sequence-expression-expressions node)))
    (conditional-expression (analyze-node (conditional-expression-consequent node))
                            (analyze-node (conditional-expression-alternate node)))
    (t nil)))

(defun analyze (program)
  "Run scope analysis on PROGRAM (in place); returns it. Signals :syntax-error on
lexical early errors."
  (analyze-node program)
  program)
