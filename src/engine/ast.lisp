;;;; ast.lisp — the analyzed-AST node types (PLAN.md Phase 02). Typed structs on a
;;;; `node` base carrying source offsets; `defnode` cuts the boilerplate. Analyzer,
;;;; printer, and the Phase 03 emitter dispatch via typecase. ESTree-ish names.

(in-package :clun.engine)

(defstruct (node (:constructor nil))
  (start 0 :type fixnum)
  (end 0 :type fixnum))

(defmacro defnode (name &rest slots)
  "Define an AST node struct NAME including `node`, with SLOTS (default NIL)."
  `(defstruct (,name (:include node) (:copier nil))
     ,@(mapcar (lambda (s) (if (listp s) s (list s nil))) slots)))

(declaim (inline finish))
(defun finish (n start end)
  "Stamp N's source span and return it."
  (setf (node-start n) start (node-end n) end)
  n)

;;; Programs & identifiers
(defnode program body (source-type :script))
(defnode identifier name)
(defnode private-name name)
(defnode literal value raw (kind :other))          ; kind: :null :boolean :number :string :regexp
(defnode reg-exp-literal pattern flags)
(defnode this-expression)
(defnode super-node)
(defnode meta-property meta property)              ; new.target, import.meta

;;; Templates
(defnode template-literal quasis expressions)
(defnode template-element cooked raw (tail nil))
(defnode tagged-template tag quasi)

;;; Literals with elements
(defnode array-expression elements)                ; NIL element = hole
(defnode object-expression properties)
(defnode property key value (kind :init) (computed nil) (shorthand nil) (method nil))
(defnode spread-element argument)

;;; Functions & classes
(defnode function-node id params body (generator nil) (async nil) (expression nil) (declaration nil))
(defnode arrow-function params body (async nil) (expression nil))
(defnode class-node id super-class body (declaration nil))
(defnode class-body body)
(defnode method-definition key value (kind :method) (static nil) (computed nil))

;;; Operators
(defnode unary-expression operator argument (prefix t))
(defnode update-expression operator argument prefix)
(defnode binary-expression operator left right)
(defnode logical-expression operator left right)
(defnode assignment-expression operator left right)
(defnode conditional-expression test consequent alternate)
(defnode sequence-expression expressions)
(defnode yield-expression argument (delegate nil))
(defnode await-expression argument)

;;; Access / call
(defnode member-expression object property (computed nil))
(defnode call-expression callee arguments)
(defnode new-expression callee arguments)

;;; Patterns
(defnode array-pattern elements)
(defnode object-pattern properties)
(defnode assignment-pattern left right)
(defnode rest-element argument)

;;; Statements
(defnode expression-statement expression (directive nil))
(defnode block-statement body)
(defnode empty-statement)
(defnode debugger-statement)
(defnode with-statement object body)
(defnode return-statement argument)
(defnode labeled-statement label body)
(defnode break-statement label)
(defnode continue-statement label)
(defnode if-statement test consequent alternate)
(defnode switch-statement discriminant cases)
(defnode switch-case test consequent)
(defnode throw-statement argument)
(defnode try-statement block handler finalizer)
(defnode catch-clause param body)
(defnode while-statement test body)
(defnode do-while-statement body test)
(defnode for-statement init test update body)
(defnode for-in-statement left right body)
(defnode for-of-statement left right body (await nil))

;;; Declarations
(defnode variable-declaration declarations (kind :var))
(defnode variable-declarator id init)

;;; Modules
(defnode import-declaration specifiers source)
(defnode import-specifier local imported)
(defnode import-default-specifier local)
(defnode import-namespace-specifier local)
(defnode export-named-declaration declaration specifiers source)
(defnode export-default-declaration declaration)
(defnode export-all-declaration exported source)
(defnode export-specifier local exported)
