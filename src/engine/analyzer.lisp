;;;; analyzer.lisp — scope analysis (PLAN.md Phase 02, §3.1). A post-parse pass over
;;;; statement scopes catching lexical-redeclaration early errors (§14.2.1 etc.).
;;;; Conservative: it only flags certain duplicates, so it never rejects valid code
;;;; (a miss is safe, a false positive is not). Full hoisting/slot-index/TDZ metadata
;;;; grows here as the evaluator (Phase 03) needs it.

(in-package :clun.engine)

(defun var-declared-names (stmts)
  "VarDeclaredNames of a StatementList: `var` names recursing through nested
statements but NOT into function/arrow/class bodies (§ static semantics)."
  (let ((names '()))
    (labels ((walk (node)
               (typecase node
                 (null nil)
                 (variable-declaration
                  (when (eq (variable-declaration-kind node) :var)
                    (dolist (d (variable-declaration-declarations node))
                      (setf names (nconc names (binding-bound-names (variable-declarator-id d)))))))
                 (block-statement (mapc #'walk (block-statement-body node)))
                 (if-statement (walk (if-statement-consequent node))
                               (walk (if-statement-alternate node)))
                 (for-statement (walk (for-statement-init node)) (walk (for-statement-body node)))
                 (for-in-statement (walk (for-in-statement-left node))
                                   (walk (for-in-statement-body node)))
                 (for-of-statement (walk (for-of-statement-left node))
                                   (walk (for-of-statement-body node)))
                 (while-statement (walk (while-statement-body node)))
                 (do-while-statement (walk (do-while-statement-body node)))
                 (with-statement (walk (with-statement-body node)))
                 (labeled-statement (walk (labeled-statement-body node)))
                 (switch-statement (dolist (c (switch-statement-cases node))
                                     (mapc #'walk (switch-case-consequent c))))
                 (try-statement (walk (try-statement-block node))
                                (when (try-statement-handler node)
                                  (walk (catch-clause-body (try-statement-handler node))))
                                (walk (try-statement-finalizer node)))
                 (t nil))))                     ; do NOT descend into function/class bodies
      (mapc #'walk stmts))
    names))

(defun check-lexical-scope (stmts)
  "SyntaxError on duplicate lexical declarations directly in STMTS, or a lexical
name that also appears among the block's VarDeclaredNames (§14.2.1)."
  (let ((lex (make-hash-table :test 'equal)))
    (dolist (s stmts)
      (dolist (n (stmt-lexical-names s))
        (when (gethash n lex)
          (throw-syntax-error (format nil "duplicate lexical declaration '~a'" n)))
        (setf (gethash n lex) t)))
    (when (plusp (hash-table-count lex))
      (dolist (v (var-declared-names stmts))
        (when (gethash v lex)
          (throw-syntax-error
           (format nil "'~a' is declared both lexically and with var" v)))))))

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
