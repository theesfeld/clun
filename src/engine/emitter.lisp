;;;; emitter.lisp — compile analyzed AST -> CL closures (PLAN.md Phase 03, §1/§5).
;;;; Each node compiles ONCE to a closure. Expression closures take a runtime env and
;;;; return a js-value; statement closures execute for effect and use CL catch/throw
;;;; tags for break/continue/return and the js-condition bridge for throw.

(in-package :clun.engine)

;; Defined by compile-source.lisp, which follows this file in the ASDF load plan.
;; Proclaim the specials here so compiling the integration seam is warning-free.
(declaim (special *compile-tier-mode* *cs-ineligible-count*))

(defvar *current-source-text* nil
  "Source string associated with the AST currently being compiled.")

(defvar *current-call-start* nil
  "Source start of the JavaScript call currently invoking a host function.")

(defvar *current-call-end* nil
  "Source end of the JavaScript call currently invoking a host function.")

(defun current-call-source-span ()
  "Return the source START and END of the currently executing call expression."
  (values *current-call-start* *current-call-end*))

(defun %with-call-source-span (function start end)
  (lambda (environment)
    (let ((*current-call-start* start)
          (*current-call-end* end))
      (funcall function environment))))

(defun source-text-slice (start end)
  (when (and *current-source-text* start end
             (<= 0 start end (length *current-source-text*)))
    (subseq *current-source-text* start end)))

(defun node-source-text (node)
  "Return NODE's exact source slice while compiling a parsed program."
  (when node
    (source-text-slice (node-start node) (node-end node))))

(defun callable-source-node-text (node)
  "Return the source text represented by NODE when it creates a callable."
  (if (method-definition-p node)
      (source-text-slice (or (method-definition-source-start node) (node-start node))
                         (node-end node))
      (node-source-text node)))

;;; --- compile-time context ---------------------------------------------------

(defstruct (cscope (:conc-name cs-) (:constructor make-cscope (kind)))
  (names (make-hash-table :test 'equal))
  (count 0)
  (imports nil)                  ; name -> t for ESM import slots (deref via thunk, Phase 07)
  (immutable nil)                ; name -> t for initialized const bindings
  (silent-immutable nil)         ; named-function self binding: silent write unless strict
  (uses-arguments nil)           ; T once `arguments` resolves to this function scope (Phase 25 m5)
  kind)                          ; :function :block

(defstruct (comp (:conc-name comp-) (:constructor make-comp ()))
  (scopes '())                   ; innermost first; empty => global
  (strict nil)
  (labels '())                   ; (name break-tag . continue-tag)
  (loops '())                    ; (break-tag . continue-tag) for unlabelled targets
  (pending-label nil)            ; a label to attach to the next loop's own tags
  (module nil))                  ; the module-record being compiled, or NIL (Phase 07)

(defun cs-mark-import (scope name)
  "Mark NAME (already declared as a slot in SCOPE) as an ESM import binding."
  (unless (cs-imports scope) (setf (cs-imports scope) (make-hash-table :test 'equal)))
  (setf (gethash name (cs-imports scope)) t))

(defun cs-mark-immutable (scope name)
  (unless (cs-immutable scope)
    (setf (cs-immutable scope) (make-hash-table :test 'equal)))
  (setf (gethash name (cs-immutable scope)) t))

(defun cs-mark-silent-immutable (scope name)
  (unless (cs-silent-immutable scope)
    (setf (cs-silent-immutable scope) (make-hash-table :test 'equal)))
  (setf (gethash name (cs-silent-immutable scope)) t))

(defun resolved-import-p (comp depth name)
  "True iff NAME, resolved to :local at DEPTH in COMP, lands on an import slot.
Because comp-resolve returns the INNERMOST binding, a shadowing local (in a closer
scope) makes this NIL automatically — the shadowing scope has no import mark."
  (let* ((scope (nth depth (comp-scopes comp)))
         (imps (and scope (cs-imports scope))))
    (and imps (gethash name imps))))

(defun resolved-immutable-p (comp depth name)
  (let* ((scope (nth depth (comp-scopes comp)))
         (bindings (and scope (cs-immutable scope))))
    (and bindings (gethash name bindings))))

(defun resolved-silent-immutable-p (comp depth name)
  (let* ((scope (nth depth (comp-scopes comp)))
         (bindings (and scope (cs-silent-immutable scope))))
    (and bindings (gethash name bindings))))

(defvar *current-return-tag* nil
  "The CL catch tag `return` throws to; bound while a function body is compiled.")

(defvar *current-generator-kind* nil
  "The enclosing generator kind (:SYNC or :ASYNC) while its body is compiled.")

(defun cs-declare (scope name)
  (or (gethash name (cs-names scope))
      (setf (gethash name (cs-names scope)) (prog1 (cs-count scope) (incf (cs-count scope))))))

(defun comp-resolve (comp name)
  "Resolve NAME to (values :local depth index) or (values :global name nil). As a side effect, records
when `arguments` resolves to a FUNCTION scope's slot — precise because compilation is a full traversal
and every identifier reference (read or write) routes through here; this lets the callee skip building
the `arguments` object when nothing references it (Phase 25 m5)."
  (loop for depth from 0 for s in (comp-scopes comp)
        for idx = (gethash name (cs-names s))
        when idx do
          (when (and (eq (cs-kind s) :function) (string= name "arguments"))
            (setf (cs-uses-arguments s) t))
          (return-from comp-resolve (values :local depth idx)))
  (values :global name nil))

;;; --- global object access ---------------------------------------------------

(defun global-get (name)
  (let ((g (realm-global *realm*)))
    (if (has-property g name) (jm-get g name g)
        (throw-reference-error (format nil "~a is not defined" name)))))

(defun global-typeof (name)
  (let ((g (realm-global *realm*)))
    (if (has-property g name) (js-typeof (jm-get g name g)) "undefined")))

(defun global-set (name value strict)
  (let ((g (realm-global *realm*)))
    (if (or (has-property g name) (not strict))
        (js-set g name value strict)
        (throw-reference-error (format nil "~a is not defined" name)))))

;;; --- scope collection -------------------------------------------------------

(defun collect-var-names (stmts)
  "VarDeclaredNames + top-level function-declaration names (function-scoped)."
  (let ((vars '()) (funcs '()))
    (labels ((walk (node &optional top)
               (typecase node
                 (null nil)
                 (variable-declaration
                  (when (eq (variable-declaration-kind node) :var)
                    (dolist (d (variable-declaration-declarations node))
                      (setf vars (nconc vars (binding-bound-names (variable-declarator-id d)))))))
                 (function-node (when (and top (function-node-declaration node) (function-node-id node))
                                  (push (identifier-name (function-node-id node)) funcs)))
                 ;; `export var x` / `export function f` hoist through the wrapper (Phase 07).
                 (export-named-declaration (walk (export-named-declaration-declaration node) top))
                 ;; `export default function foo(){}` hoists `foo` like a normal decl.
                 (export-default-declaration (walk (export-default-declaration-declaration node) top))
                 (block-statement (mapc #'walk (block-statement-body node)))
                 (if-statement (walk (if-statement-consequent node)) (walk (if-statement-alternate node)))
                 (for-statement (walk (for-statement-init node)) (walk (for-statement-body node)))
                 (for-in-statement (walk (for-in-statement-left node)) (walk (for-in-statement-body node)))
                 (for-of-statement (walk (for-of-statement-left node)) (walk (for-of-statement-body node)))
                 (while-statement (walk (while-statement-body node)))
                 (do-while-statement (walk (do-while-statement-body node)))
                 (with-statement (walk (with-statement-body node)))
                 (labeled-statement (walk (labeled-statement-body node)))
                 (switch-statement (dolist (c (switch-statement-cases node)) (mapc #'walk (switch-case-consequent c))))
                 (try-statement (walk (try-statement-block node))
                                (when (try-statement-handler node) (walk (catch-clause-body (try-statement-handler node))))
                                (walk (try-statement-finalizer node)))
                 (t nil))))
      (dolist (s stmts) (walk s t)))
    (values vars (nreverse funcs))))

(defun collect-lexical-names (stmts)
  (loop for s in stmts append (stmt-lexical-names s)))

(defun stmt-immutable-lexical-names (statement)
  "Immutable lexical names introduced directly by STATEMENT."
  (typecase statement
    (variable-declaration
     (when (eq (variable-declaration-kind statement) :const)
       (loop for declaration in (variable-declaration-declarations statement)
             append (binding-bound-names (variable-declarator-id declaration)))))
    (export-named-declaration
     (when (export-named-declaration-declaration statement)
       (stmt-immutable-lexical-names (export-named-declaration-declaration statement))))
    (export-default-declaration
     (stmt-immutable-lexical-names (export-default-declaration-declaration statement)))
    (t nil)))

(defun collect-immutable-lexical-names (statements)
  (loop for statement in statements
        append (stmt-immutable-lexical-names statement)))

(defun mark-immutable-lexicals (scope statements)
  (dolist (name (collect-immutable-lexical-names statements))
    (cs-mark-immutable scope name)))

;;; --- the dispatcher ---------------------------------------------------------

(defun compile-node (comp node)
  (etypecase node
    (literal (compile-literal node))
    (identifier (compile-identifier comp node))
    (this-expression (compile-this comp))
    (meta-property (compile-meta comp node))
    (template-literal (compile-template comp node))
    (tagged-template (compile-tagged-template comp node))
    (reg-exp-literal (compile-regexp node))
    (array-expression (compile-array comp node))
    (object-expression (compile-object comp node))
    (unary-expression (compile-unary comp node))
    (update-expression (compile-update comp node))
    (binary-expression (compile-binary comp node))
    (logical-expression (compile-logical comp node))
    (assignment-expression (compile-assignment comp node))
    (conditional-expression (compile-conditional comp node))
    (sequence-expression (compile-sequence comp node))
    (member-expression (compile-member comp node))
    (call-expression (compile-call comp node))
    (new-expression (compile-new comp node))
    (function-node (if (function-node-declaration node)
                       (lambda (env) (declare (ignore env)) :normal)   ; hoisted separately
                       (compile-function-expr comp node)))
    (class-node (if (and (class-node-declaration node) (class-node-id node))
                    (let ((class-fn (compile-class comp node))
                          (binder (compile-bind-target comp (class-node-id node))))
                      (lambda (env) (funcall binder env (funcall class-fn env)) :normal))
                    (compile-class comp node)))
    (arrow-function (compile-arrow comp node))
    (super-node (lambda (env) (declare (ignore env)) (throw-syntax-error "super outside method")))
    (yield-expression (compile-yield comp node))
    (await-expression (compile-await comp node))
    ;; statements
    (expression-statement (compile-node comp (expression-statement-expression node)))
    (block-statement (compile-block comp node))
    (empty-statement (lambda (env) (declare (ignore env)) :normal))
    (debugger-statement (lambda (env) (declare (ignore env)) :normal))
    (variable-declaration (compile-var-decl comp node))
    (if-statement (compile-if comp node))
    (while-statement (compile-while comp node))
    (do-while-statement (compile-do-while comp node))
    (for-statement (compile-for comp node))
    (for-in-statement (compile-for-in comp node))
    (for-of-statement (compile-for-of comp node))
    (switch-statement (compile-switch comp node))
    (return-statement (compile-return comp node))
    (throw-statement (compile-throw comp node))
    (try-statement (compile-try comp node))
    (break-statement (compile-break comp node))
    (continue-statement (compile-continue comp node))
    (labeled-statement (compile-labeled comp node))
    (with-statement (compile-with comp node))
    ;; --- ESM module declarations (Phase 07) ---------------------------------
    ;; imports + `export {..}` / `export * from` are pure link-time metadata: the
    ;; import slots are filled by the linker before the body runs, and re-exports
    ;; are resolved in the export map — so the runtime closures are no-ops.
    (import-declaration (lambda (env) (declare (ignore env)) :normal))
    (export-all-declaration (lambda (env) (declare (ignore env)) :normal))
    (export-named-declaration
     (let ((decl (export-named-declaration-declaration node)))
       (if decl
           (compile-node comp decl)     ; `export const x = …` / `export function f`
           (lambda (env) (declare (ignore env)) :normal))))
    (export-default-declaration (compile-export-default comp node))))

(defun compile-export-default (comp node)
  "Compile `export default <decl|expr>`. A NAMED function default is hoisted like a
normal function declaration (runtime no-op here); a NAMED class default binds its
own name slot; an anonymous fn/class or an expression binds the reserved `*default*`
slot."
  (let ((decl (export-default-declaration-declaration node)))
    (cond
      ((and (function-node-p decl) (function-node-id decl))
       (lambda (env) (declare (ignore env)) :normal))       ; hoisted as `foo`
      ((and (class-node-p decl) (class-node-id decl))
       (let ((val-fn (compile-class comp decl))
             (binder (compile-bind-target comp (class-node-id decl))))
         (lambda (env) (funcall binder env (funcall val-fn env)) :normal)))
      (t (let ((val-fn (cond ((function-node-p decl) (compile-function-expr comp decl))
                             ((class-node-p decl) (compile-class comp decl))
                             (t (compile-node comp decl))))
               (binder (compile-bind-target comp (make-identifier :name "*default*"))))
           (lambda (env) (funcall binder env (funcall val-fn env)) :normal))))))

(defun compile-seq (comp stmts)
  "Compile a statement list into one closure returning the last completion."
  (let ((cs (mapcar (lambda (s) (compile-node comp s)) stmts)))
    (case (length cs)
      (0 (lambda (env) (declare (ignore env)) :normal))
      (1 (first cs))
      (t (let ((v (coerce cs 'simple-vector)))
           (lambda (env) (loop for c across v do (funcall c env)) :normal))))))

;;; --- literals & identifiers -------------------------------------------------

(defun compile-literal (node)
  (let ((v (literal-value node)))
    (lambda (env) (declare (ignore env)) v)))

(defun compile-regexp (node)
  ;; Parse + translate + compile the scanner ONCE at emit time (a SyntaxError in the
  ;; pattern surfaces here, the correct timing); each evaluation allocates a fresh
  ;; RegExp object sharing that immutable compiled data (ES fresh-object-per-eval).
  (let ((rxc (compile-regexp-literal (reg-exp-literal-pattern node)
                                     (reg-exp-literal-flags node))))
    (lambda (env) (declare (ignore env)) (regexp-from-compiled rxc))))

(defun compile-identifier (comp node)
  (let ((name (identifier-name node)))
    (multiple-value-bind (kind depth index) (comp-resolve comp name)
      (cond
        ;; ESM import binding: the slot holds a getter thunk into the exporter.
        ((and (eq kind :local) (resolved-import-p comp depth name))
         (lambda (env) (funcall (frame-ref env depth index name))))
        ((eq kind :local)
         (lambda (env) (frame-ref env depth index name)))
        (t (lambda (env) (declare (ignore env)) (global-get name)))))))

(defun compile-this (comp)
  (multiple-value-bind (kind depth index) (comp-resolve comp "%this%")
    (if (eq kind :local)
        (lambda (env) (get-this-binding (frame-ref env depth index "this")))
        (lambda (env) (declare (ignore env)) (realm-global *realm*)))))

(defun super-member-p (node)
  (and (member-expression-p node)
       (super-node-p (member-expression-object node))))

(defun compile-super-reference (comp node)
  "Compile SuperProperty into a prepared (base, key, receiver) reference.
The returned closure snapshots each observable component exactly once."
  (multiple-value-bind (this-kind this-depth this-index) (comp-resolve comp "%this%")
    (multiple-value-bind (fn-kind fn-depth fn-index) (comp-resolve comp "%active.function%")
      (unless (and (eq this-kind :local) (eq fn-kind :local))
        (error "super reference compiled without a method environment"))
      (let ((property-fn (and (member-expression-computed node)
                              (compile-node comp (member-expression-property node))))
            (static-key (unless (member-expression-computed node)
                          (identifier-name (member-expression-property node)))))
        (lambda (env)
          ;; GetThisBinding precedes the computed expression. GetSuperBase is
          ;; then snapshotted before ToPropertyKey can mutate the home object.
          (let* ((receiver (get-this-binding
                            (frame-ref env this-depth this-index "this")))
                 (property (if property-fn (funcall property-fn env) static-key))
                 (active (frame-ref env fn-depth fn-index "active function"))
                 (home (if (js-function-p active)
                           (js-function-home-object active)
                           +undefined+))
                 (base (if (js-object-p home) (jm-get-prototype-of home) +null+)))
            (unless (js-object-p base)
              (throw-type-error "super base is null"))
            (values base property receiver)))))))

(defun super-reference-get (reference env)
  (multiple-value-bind (base property receiver) (funcall reference env)
    (jm-get base (to-property-key property) receiver)))

(defun super-reference-set (reference env value strict)
  (multiple-value-bind (base property receiver) (funcall reference env)
    (unless (jm-set base (to-property-key property) value receiver)
      (when strict (throw-type-error "cannot assign to super property")))
    value))

(defun compile-meta (comp node)
  (if (string= (meta-property-meta node) "import")
      ;; import.meta -> the per-module object stashed in the reserved module slot.
      (multiple-value-bind (kind depth index) (comp-resolve comp "%import.meta%")
        (if (eq kind :local)
            (lambda (env) (frame-ref env depth index "import.meta"))
            (lambda (env) (declare (ignore env)) +undefined+)))
      ;; new.target
      (multiple-value-bind (kind depth index) (comp-resolve comp "%new.target%")
        (if (eq kind :local)
            (lambda (env) (frame-ref env depth index "new.target"))
            (lambda (env) (declare (ignore env)) +undefined+)))))

;;; --- references (get/set pairs for assignment targets) ----------------------

(defun compile-reference (comp node)
  "Return (values get-fn set-fn) for an assignment target NODE."
  (typecase node
    (identifier
     (let ((name (identifier-name node)))
       (multiple-value-bind (kind depth index) (comp-resolve comp name)
         (cond
           ;; ESM import: reads deref the thunk; writes are a TypeError (const binding).
           ((and (eq kind :local) (resolved-import-p comp depth name))
            (values (lambda (env) (funcall (frame-ref env depth index name)))
                    (lambda (env v) (declare (ignore env v))
                      (throw-type-error "Assignment to constant variable."))))
           ((eq kind :local)
            (values
             (lambda (env) (frame-ref env depth index name))
             (cond
               ((resolved-immutable-p comp depth name)
                (lambda (env v)
                  (declare (ignore v))
                  (frame-ref env depth index name)
                  (throw-type-error "Assignment to constant variable.")))
               ((resolved-silent-immutable-p comp depth name)
                (if (comp-strict comp)
                    (lambda (env v)
                      (declare (ignore v))
                      (frame-ref env depth index name)
                      (throw-type-error "Assignment to immutable function name."))
                    (lambda (env v)
                      (frame-ref env depth index name)
                      v)))
               (t (lambda (env v) (frame-set env depth index v name))))))
           (t (let ((strict (comp-strict comp)))
                (values (lambda (env) (declare (ignore env)) (global-get name))
                        (lambda (env v) (declare (ignore env)) (global-set name v strict)))))))))
    (member-expression
     (if (super-member-p node)
         (let ((reference (compile-super-reference comp node))
               (strict (comp-strict comp)))
           (values (lambda (env) (super-reference-get reference env))
                   (lambda (env value)
                     (super-reference-set reference env value strict))))
         (let ((obj-fn (compile-node comp (member-expression-object node))))
           (if (member-expression-computed node)
               (let ((prop-fn (compile-node comp (member-expression-property node))))
                 (values (lambda (env) (js-getv (funcall obj-fn env) (to-property-key (funcall prop-fn env))))
                         (lambda (env v) (let ((o (funcall obj-fn env)))
                                           (js-set (to-object o) (to-property-key (funcall prop-fn env)) v (comp-strict comp))))))
               (let ((key (identifier-name (member-expression-property node)))
                     (rcache (%make-ic)) (wcache (%make-ic)) (strict (comp-strict comp)))
                 (values (lambda (env) (%ic-read (funcall obj-fn env) key rcache))
                         (lambda (env v) (%ic-write (funcall obj-fn env) key v wcache strict))))))))
    (t (values (lambda (env) (declare (ignore env)) (throw-reference-error "invalid reference"))
               (lambda (env v) (declare (ignore env v)) (throw-syntax-error "invalid assignment target"))))))

(defun compile-member-reference-parts (comp node)
  "Compile the pieces of a member reference so assignment/update can snapshot its
base and computed key exactly once, before evaluating a right-hand side."
  (let ((obj-fn (compile-node comp (member-expression-object node)))
        (strict (comp-strict comp)))
    (if (member-expression-computed node)
        (values obj-fn t (compile-node comp (member-expression-property node)) nil nil strict)
        (values obj-fn nil (identifier-name (member-expression-property node))
                (%make-ic) (%make-ic) strict))))

;;; --- member / call / new ----------------------------------------------------

(defun compile-member (comp node)
  (if (super-member-p node)
      (let ((reference (compile-super-reference comp node)))
        (lambda (env) (super-reference-get reference env)))
      (let ((obj-fn (compile-node comp (member-expression-object node))))
        (if (member-expression-computed node)
            (let ((prop-fn (compile-node comp (member-expression-property node))))
              (lambda (env) (js-getv (funcall obj-fn env) (to-property-key (funcall prop-fn env)))))
            (let ((key (identifier-name (member-expression-property node)))
                  (cache (%make-ic)))                ; per-site monomorphic read inline cache
              (lambda (env) (%ic-read (funcall obj-fn env) key cache)))))))

(defun compile-arguments-list (comp args)
  (let ((simple (notany #'spread-element-p args)))
    (if simple
        (let ((fns (mapcar (lambda (a) (compile-node comp a)) args)))
          (lambda (env) (mapcar (lambda (f) (funcall f env)) fns)))
        (let ((parts (mapcar (lambda (a)
                               (if (spread-element-p a)
                                   (cons :spread (compile-node comp (spread-element-argument a)))
                                   (cons :one (compile-node comp a))))
                             args)))
          (lambda (env)
            (loop for (kind . fn) in parts
                  if (eq kind :spread) append (iterable->list (funcall fn env))
                  else collect (funcall fn env)))))))

(defun compile-call (comp node)
  (let ((callee (call-expression-callee node))
        (args-fn (compile-arguments-list comp (call-expression-arguments node))))
    (%with-call-source-span
     (cond
       ((super-node-p callee)
        (compile-super-call comp args-fn))
       ;; method call: preserve `this`
       ((super-member-p callee)
        (let ((reference (compile-super-reference comp callee)))
          (lambda (env)
            (multiple-value-bind (base property receiver) (funcall reference env)
              (let ((function (jm-get base (to-property-key property) receiver)))
                (js-call function receiver (funcall args-fn env)))))))
       ((member-expression-p callee)
        (let ((obj-fn (compile-node comp (member-expression-object callee))))
          (if (member-expression-computed callee)
              (let ((prop-fn (compile-node comp (member-expression-property callee))))
                (lambda (env) (let* ((o (funcall obj-fn env))
                                     (f (js-getv o (to-property-key (funcall prop-fn env)))))
                                (js-call f o (funcall args-fn env)))))
              (let ((key (identifier-name (member-expression-property callee)))
                    (cache (%make-ic)))         ; method reads are usually a depth-1 proto IC hit
                (lambda (env) (let* ((o (funcall obj-fn env)) (f (%ic-read o key cache)))
                                (js-call f o (funcall args-fn env))))))))
       ;; direct eval is not supported (Phase 03) — treat `eval(...)` as an ordinary call
       (t (let ((fn (compile-node comp callee)))
            (lambda (env) (js-call (funcall fn env) +undefined+ (funcall args-fn env))))))
     (node-start node)
     (node-end node))))

(defun compile-super-call (comp args-fn)
  (multiple-value-bind (fn-kind fn-depth fn-index) (comp-resolve comp "%active.function%")
    (multiple-value-bind (this-kind this-depth this-index) (comp-resolve comp "%this%")
      (multiple-value-bind (nt-kind nt-depth nt-index) (comp-resolve comp "%new.target%")
        (unless (and (eq fn-kind :local) (eq this-kind :local) (eq nt-kind :local))
          (error "super() compiled without a derived constructor environment"))
        (lambda (env)
          (let* ((active (frame-ref env fn-depth fn-index "active function"))
                 (super-constructor (jm-get-prototype-of active))
                 (args (funcall args-fn env)))
            (unless (constructor-p super-constructor)
              (throw-type-error "superclass is not a constructor"))
            (let* ((new-target (frame-ref env nt-depth nt-index "new.target"))
                   (result (js-construct super-constructor args new-target))
                   (binding (frame-ref env this-depth this-index "this")))
              (bind-derived-this binding result))))))))

(defun compile-new (comp node)
  (let ((callee-fn (compile-node comp (new-expression-callee node)))
        (args-fn (compile-arguments-list comp (new-expression-arguments node))))
    (lambda (env) (js-construct (funcall callee-fn env) (funcall args-fn env)))))

;;; --- operators --------------------------------------------------------------

(defun compile-unary (comp node)
  (let ((op (unary-expression-operator node)) (arg (unary-expression-argument node)))
    (cond
      ((string= op "typeof")
       (if (identifier-p arg)
           (let ((name (identifier-name arg)))
             (multiple-value-bind (kind depth index) (comp-resolve comp name)
               (if (eq kind :local)
                   (lambda (env) (js-typeof (frame-ref env depth index name)))
                   (lambda (env) (declare (ignore env)) (global-typeof name)))))
           (let ((f (compile-node comp arg))) (lambda (env) (js-typeof (funcall f env))))))
      ((string= op "delete") (compile-delete comp arg))
      (t (let ((f (compile-node comp arg)))
           (macrolet ((u (form) `(lambda (env) (let ((v (funcall f env))) ,form))))
             (cond ((string= op "!") (u (js-boolean (not (js-truthy v)))))
                   ((string= op "-") (u (js-neg v)))
                   ((string= op "+") (u (js-unary-plus v)))
                   ((string= op "~") (u (js-bit-not v)))
                   ((string= op "void") (u (progn v +undefined+)))
                   (t (error "bad unary op ~a" op)))))))))

(defun compile-delete (comp arg)
  (cond
    ((super-member-p arg)
     ;; Evaluating a SuperProperty first resolves `this`, then evaluates a
     ;; computed key. Delete rejects that reference before ToPropertyKey or any
     ;; super-base coercion is performed.
     (multiple-value-bind (this-kind this-depth this-index) (comp-resolve comp "%this%")
       (unless (eq this-kind :local)
         (error "super delete compiled without a method environment"))
       (let ((property-fn (and (member-expression-computed arg)
                               (compile-node comp (member-expression-property arg)))))
         (lambda (env)
           (get-this-binding (frame-ref env this-depth this-index "this"))
           (when property-fn (funcall property-fn env))
           (throw-reference-error "cannot delete a super property")))))
    ((member-expression-p arg)
     (let ((obj-fn (compile-node comp (member-expression-object arg)))
           (strict (comp-strict comp)))
       (if (member-expression-computed arg)
           (let ((prop-fn (compile-node comp (member-expression-property arg))))
             (lambda (env)
               (let ((base (funcall obj-fn env))
                     (property (funcall prop-fn env)))
                 (js-boolean (js-delete (to-object base)
                                        (to-property-key property)
                                        strict)))))
           (let ((key (identifier-name (member-expression-property arg))))
             (lambda (env) (js-boolean (js-delete (to-object (funcall obj-fn env)) key strict)))))))
    ((identifier-p arg)
     ;; A resolved environment binding is not deletable. This covers the
     ;; function-local `arguments` binding without changing global-property
     ;; deletion, whose declaration records belong to the later global-env work.
     (multiple-value-bind (kind depth index) (comp-resolve comp (identifier-name arg))
       (declare (ignore depth index))
       (let ((result (if (eq kind :local) +false+ +true+)))
         (lambda (env) (declare (ignore env)) result))))
    (t (lambda (env) (declare (ignore env)) +true+)))) ; non-reference -> true

(defun compile-update (comp node)
  (let ((op (update-expression-operator node)) (prefix (update-expression-prefix node))
        (target (update-expression-argument node)))
    (let ((step (if (string= op "++") 1 -1)))
      (cond
        ((super-member-p target)
         (let ((reference (compile-super-reference comp target))
               (strict (comp-strict comp)))
           (lambda (env)
             (multiple-value-bind (base property receiver) (funcall reference env)
               (let* ((key (to-property-key property))
                      (old (to-numeric (jm-get base key receiver)))
                      (new (if (integerp old) (+ old step)
                               (with-js-floats (+ old (coerce step 'double-float))))))
                 (unless (jm-set base key new receiver)
                   (when strict (throw-type-error "cannot assign to super property")))
                 (if prefix new old))))))
        ((member-expression-p target)
         (multiple-value-bind (obj-fn computed key-part rcache wcache strict)
             (compile-member-reference-parts comp target)
           (lambda (env)
             (let* ((o (funcall obj-fn env))
                    (k (if computed (to-property-key (funcall key-part env)) key-part))
                    (old (to-numeric (if computed (js-getv o k) (%ic-read o k rcache))))
                    (new (if (integerp old) (+ old step)
                             (with-js-floats (+ old (coerce step 'double-float))))))
               (if computed (js-set (to-object o) k new strict)
                   (%ic-write o k new wcache strict))
               (if prefix new old)))))
        (t
         (multiple-value-bind (get set) (compile-reference comp target)
           (lambda (env)
             ;; ToNumeric so `let x=1n; x++` stays a BigInt (not a TypeError via to-number).
             (let* ((old (to-numeric (funcall get env)))
                    (new (if (integerp old) (+ old step)
                             (with-js-floats (+ old (coerce step 'double-float))))))
               (funcall set env new)
               (if prefix new old)))))))))

(defun compile-binary (comp node)
  (let ((l (compile-node comp (binary-expression-left node)))
        (r (compile-node comp (binary-expression-right node)))
        (op (binary-expression-operator node)))
    (macrolet ((b (form) `(lambda (env) (let ((a (funcall l env)) (d (funcall r env))) ,form))))
      (cond
        ((string= op "+") (b (js-add a d)))
        ((string= op "-") (b (js-sub a d)))
        ((string= op "*") (b (js-mul a d)))
        ((string= op "/") (b (js-div a d)))
        ((string= op "%") (b (js-mod a d)))
        ((string= op "**") (b (js-exp a d)))
        ((string= op "==") (b (js-boolean (js-loose-eq a d))))
        ((string= op "!=") (b (js-boolean (not (js-loose-eq a d)))))
        ((string= op "===") (b (js-boolean (js-strict-eq a d))))
        ((string= op "!==") (b (js-boolean (not (js-strict-eq a d)))))
        ((string= op "<") (b (js-boolean (js-lt a d))))
        ((string= op ">") (b (js-boolean (js-gt a d))))
        ((string= op "<=") (b (js-boolean (js-le a d))))
        ((string= op ">=") (b (js-boolean (js-ge a d))))
        ((string= op "&") (b (js-bit-and a d)))
        ((string= op "|") (b (js-bit-or a d)))
        ((string= op "^") (b (js-bit-xor a d)))
        ((string= op "<<") (b (js-shl a d)))
        ((string= op ">>") (b (js-shr a d)))
        ((string= op ">>>") (b (js-ushr a d)))
        ((string= op "instanceof") (b (js-boolean (js-instanceof a d))))
        ((string= op "in") (b (js-boolean (js-in a d))))
        (t (error "bad binary op ~a" op))))))

(defun compile-logical (comp node)
  (let ((l (compile-node comp (logical-expression-left node)))
        (r (compile-node comp (logical-expression-right node)))
        (op (logical-expression-operator node)))
    (cond ((string= op "&&")
           (lambda (env) (let ((a (funcall l env))) (if (js-truthy a) (funcall r env) a))))
          ((string= op "??")
           (lambda (env) (let ((a (funcall l env))) (if (js-nullish-p a) (funcall r env) a))))
          (t
           (lambda (env) (let ((a (funcall l env))) (if (js-truthy a) a (funcall r env))))))))

(defun compile-conditional (comp node)
  (let ((test (compile-node comp (conditional-expression-test node)))
        (con (compile-node comp (conditional-expression-consequent node)))
        (alt (compile-node comp (conditional-expression-alternate node))))
    (lambda (env) (if (js-truthy (funcall test env)) (funcall con env) (funcall alt env)))))

(defun compile-sequence (comp node)
  (let ((fns (coerce (mapcar (lambda (e) (compile-node comp e)) (sequence-expression-expressions node))
                     'simple-vector)))
    (lambda (env) (let ((v +undefined+)) (loop for f across fns do (setf v (funcall f env))) v))))

(defun compile-assignment (comp node)
  (let ((op (assignment-expression-operator node)) (target (assignment-expression-left node)))
    (if (string= op "=")
        (cond
          ((or (array-pattern-p target) (object-pattern-p target))
           (compile-destructuring-assignment comp target (assignment-expression-right node)))
          ((super-member-p target)
           (let ((reference (compile-super-reference comp target))
                 (rhs (compile-node comp (assignment-expression-right node)))
                 (strict (comp-strict comp)))
             (lambda (env)
               (multiple-value-bind (base property receiver) (funcall reference env)
                 (let ((value (funcall rhs env)))
                   (unless (jm-set base (to-property-key property) value receiver)
                     (when strict (throw-type-error "cannot assign to super property")))
                   value)))))
          (t
           (let ((rhs (compile-named-value comp (assignment-expression-right node)
                                           (and (identifier-p target) (identifier-name target)))))
             (if (member-expression-p target)
                 (multiple-value-bind (obj-fn computed key-part rcache wcache strict)
                     (compile-member-reference-parts comp target)
                   (declare (ignore rcache))
                   (lambda (env)
                     (let* ((o (funcall obj-fn env))
                            (k (if computed (to-property-key (funcall key-part env)) key-part))
                            (v (funcall rhs env)))
                       (if computed (js-set (to-object o) k v strict)
                           (%ic-write o k v wcache strict))
                       v)))
                 (multiple-value-bind (get set) (compile-reference comp target)
                   (declare (ignore get))
                   (lambda (env) (let ((v (funcall rhs env))) (funcall set env v) v)))))))
        (let ((rhs (compile-node comp (assignment-expression-right node)))
              (binop (subseq op 0 (1- (length op)))))
          (cond
            ((super-member-p target)
             (let ((reference (compile-super-reference comp target))
                   (strict (comp-strict comp)))
               (lambda (env)
                 (multiple-value-bind (base property receiver) (funcall reference env)
                   (let* ((key (to-property-key property))
                          (left (jm-get base key receiver))
                          (right (funcall rhs env))
                          (value (apply-binop binop left right)))
                     (unless (jm-set base key value receiver)
                       (when strict (throw-type-error "cannot assign to super property")))
                     value)))))
            ((member-expression-p target)
             (multiple-value-bind (obj-fn computed key-part rcache wcache strict)
                 (compile-member-reference-parts comp target)
               (lambda (env)
                 (let* ((o (funcall obj-fn env))
                        (k (if computed (to-property-key (funcall key-part env)) key-part))
                        (a (if computed (js-getv o k) (%ic-read o k rcache)))
                        (d (funcall rhs env))
                        (v (apply-binop binop a d)))
                   (if computed (js-set (to-object o) k v strict)
                       (%ic-write o k v wcache strict))
                   v))))
            (t
             (multiple-value-bind (get set) (compile-reference comp target)
               (lambda (env)
                 (let* ((a (funcall get env)) (d (funcall rhs env))
                        (v (apply-binop binop a d)))
                   (funcall set env v) v)))))))))

(defun apply-binop (op a d)
  (cond ((string= op "+") (js-add a d)) ((string= op "-") (js-sub a d))
        ((string= op "*") (js-mul a d)) ((string= op "/") (js-div a d))
        ((string= op "%") (js-mod a d)) ((string= op "**") (js-exp a d))
        ((string= op "&") (js-bit-and a d)) ((string= op "|") (js-bit-or a d))
        ((string= op "^") (js-bit-xor a d)) ((string= op "<<") (js-shl a d))
        ((string= op ">>") (js-shr a d)) ((string= op ">>>") (js-ushr a d))
        (t (error "bad compound op ~a" op))))

;;; --- array / object literals ------------------------------------------------

(defun compile-array (comp node)
  (let ((parts (mapcar (lambda (e)
                         (cond ((null e) (cons :hole nil))
                               ((spread-element-p e) (cons :spread (compile-node comp (spread-element-argument e))))
                               (t (cons :one (compile-node comp e)))))
                       (array-expression-elements node))))
    (lambda (env)
      (let ((a (new-array)) (i 0))
        (loop for (kind . fn) in parts do
          (case kind
            (:hole (incf i))
            (:spread (dolist (v (iterable->list (funcall fn env)))
                       (create-data-property a (int->string i) v) (incf i)))
            (:one (create-data-property a (int->string i) (funcall fn env)) (incf i))))
        (js-set a "length" (coerce i 'double-float) t)
        a))))

(defun compile-object (comp node)
  (let ((parts (mapcar (lambda (p) (compile-object-property comp p))
                       (object-expression-properties node))))
    (lambda (env)
      (let ((o (new-object)))
        (dolist (p parts o) (funcall p env o))))))

(defun set-callable-home-object (function home)
  (when (js-function-p function)
    (setf (js-function-home-object function) home))
  function)

(defun function-property-name (key)
  (if (js-symbol-p key)
      (let ((description (js-symbol-description key)))
        (if (js-undefined-p description)
            ""
            (format nil "[~a]" description)))
      key))

(defun set-function-name (function key &optional prefix)
  (let* ((base (function-property-name key))
         (name (if prefix (format nil "~a ~a" prefix base) base)))
    (cond ((js-function-p function) (setf (js-function-fname function) name))
          ((js-native-function-p function) (setf (js-native-function-fname function) name))
          ((js-bound-function-p function) (setf (js-bound-function-fname function) name)))
    (obj-set-desc function "name"
                  (data-pd name :writable nil :enumerable nil :configurable t))
    function))

(defun compile-object-property (comp prop)
  (cond
    ((spread-element-p prop)
     (let ((fn (compile-node comp (spread-element-argument prop))))
       (lambda (env o) (let ((src (funcall fn env)))
                         (unless (js-nullish-p src)
                           (let ((from (to-object src)))
                             (dolist (k (jm-own-property-keys from))
                               (let ((d (jm-get-own-property from k)))
                                 (when (and d (eq (pd-enumerable d) t))
                                   (create-data-property o k (js-get from k)))))))))))
    (t (let* ((key (property-key prop)) (computed (property-computed prop))
              (key-fn (if computed (compile-node comp key) nil))
              (static-key (unless computed (property-key-string key)))
              (kind (property-kind prop)))
         (case kind
           ((:get :set)
            (let ((fn-fn (compile-method comp (property-value prop) :source-node prop)))
              (lambda (env o)
                (let ((k (if computed (to-property-key (funcall key-fn env)) static-key))
                      (f (funcall fn-fn env)))
                  (set-callable-home-object f o)
                  (set-function-name f k (if (eq kind :get) "get" "set"))
                  (let ((existing (obj-own-desc o k)))
                    (jm-define-own-property o k
                      (if (eq kind :get)
                          (accessor-pd f (if (and existing (accessor-descriptor-p existing)) (pd-set existing) +undefined+))
                          (accessor-pd (if (and existing (accessor-descriptor-p existing)) (pd-get existing) +undefined+) f))))))))
           (t
            (let* ((method-p (property-method prop))
                   (anonymous-p (anon-fn-node-p (property-value prop)))
                   (val-fn (if method-p
                               (compile-method comp (property-value prop) :source-node prop)
                               (compile-node comp (property-value prop)))))
              (if (and (not computed) (not method-p) (not (property-shorthand prop))
                       (string= static-key "__proto__"))
                  (lambda (env o)
                    (let ((value (funcall val-fn env)))
                      (when (or (js-object-p value) (js-null-p value))
                        (unless (jm-set-prototype-of o value)
                          (throw-type-error "cannot set object literal prototype")))))
                  (lambda (env o)
                    (let* ((k (if computed (to-property-key (funcall key-fn env)) static-key))
                           (value (funcall val-fn env)))
                      (when method-p
                        (set-callable-home-object value o)
                        (set-function-name value k))
                      (when (and anonymous-p (callable-p value))
                        (set-function-name value k))
                      (create-data-property o k value)))))))))))

(defun property-key-string (key)
  (typecase key
    (identifier (identifier-name key))
    (literal (if (eq (literal-kind key) :number) (number->js-string (literal-value key))
                 (to-string (literal-value key))))
    (t (to-string key))))

;;; --- templates --------------------------------------------------------------

(defun compile-template (comp node)
  (let ((quasis (mapcar (lambda (q) (or (template-element-cooked q) "")) (template-literal-quasis node)))
        (exprs (mapcar (lambda (e) (compile-node comp e)) (template-literal-expressions node))))
    (lambda (env)
      (with-output-to-string (out)
        (loop for q in quasis for i from 0 do
          (write-string q out)
          (when (< i (length exprs)) (write-string (to-string (funcall (nth i exprs) env)) out)))))))

(defun normalize-template-raw (string)
  "Apply Template Raw Value's CR and CRLF normalization without cooking escapes."
  (with-output-to-string (out)
    (loop with index = 0
          while (< index (length string))
          for character = (char string index)
          do (cond
               ((char= character #\Return)
                (write-char #\Newline out)
                (incf index)
                (when (and (< index (length string))
                           (char= (char string index) #\Newline))
                  (incf index)))
               (t
                (write-char character out)
                (incf index))))))

(defun make-template-object (template)
  "Create the frozen cooked/raw arrays for one TemplateLiteral parse node."
  (let* ((quasis (template-literal-quasis template))
         (raw (new-array
               (mapcar (lambda (quasi)
                         (normalize-template-raw (template-element-raw quasi)))
                       quasis)))
         (cooked (new-array
                  (mapcar (lambda (quasi)
                            (or (template-element-cooked quasi) +undefined+))
                          quasis))))
    (unless (set-integrity-level raw :frozen)
      (throw-type-error "cannot freeze template raw strings"))
    (obj-set-desc cooked "raw"
                  (data-pd raw :writable nil :enumerable nil :configurable nil))
    (unless (set-integrity-level cooked :frozen)
      (throw-type-error "cannot freeze template strings"))
    cooked))

(defun get-template-object (template)
  "Return the realm-local cached template object for TEMPLATE's parse-node identity."
  (let ((registry (realm-template-registry *realm*)))
    (multiple-value-bind (object present-p) (gethash template registry)
      (if present-p
          object
          (setf (gethash template registry) (make-template-object template))))))

(defun compile-tagged-template-callee (comp tag)
  "Compile TAG as a call reference and preserve a member reference's receiver."
  (cond
    ((super-member-p tag)
     (let ((reference (compile-super-reference comp tag)))
       (lambda (env)
         (multiple-value-bind (base property receiver) (funcall reference env)
           (values (jm-get base (to-property-key property) receiver) receiver)))))
    ((member-expression-p tag)
     (let ((object-fn (compile-node comp (member-expression-object tag))))
       (if (member-expression-computed tag)
           (let ((property-fn (compile-node comp (member-expression-property tag))))
             (lambda (env)
               (let* ((object (funcall object-fn env))
                      (property (to-property-key (funcall property-fn env))))
                 (values (js-getv object property) object))))
           (let ((property (identifier-name (member-expression-property tag)))
                 (cache (%make-ic)))
             (lambda (env)
               (let ((object (funcall object-fn env)))
                 (values (%ic-read object property cache) object)))))))
    (t
     (let ((function-fn (compile-node comp tag)))
       (lambda (env) (values (funcall function-fn env) +undefined+))))))

(defun compile-tagged-template (comp node)
  (let* ((template (tagged-template-quasi node))
         (callee-fn (compile-tagged-template-callee comp (tagged-template-tag node)))
         (expression-fns
           (mapcar (lambda (expression) (compile-node comp expression))
                   (template-literal-expressions template))))
    (lambda (env)
      (multiple-value-bind (function receiver) (funcall callee-fn env)
        ;; IsCallable precedes GetTemplateObject and substitution evaluation.
        (unless (callable-p function)
          (throw-type-error "tagged template target is not callable"))
        (let ((arguments
                (cons (get-template-object template)
                      (mapcar (lambda (expression-fn)
                                (funcall expression-fn env))
                              expression-fns))))
          (js-call function receiver arguments))))))

;;; --- binding targets (params, declarations, destructuring) ------------------

(defun target-inference-name (target)
  (and (identifier-p target) (identifier-name target)))

(defun compile-array-pattern-binder (comp elements assignment-p)
  "Compile a lazy array-pattern binder. Assignment entries prepare references before stepping."
  (let ((entries
          (mapcar (lambda (element)
                    (cond
                      ((null element) (cons :elision nil))
                      ((rest-element-p element)
                       (cons :rest
                             (if assignment-p
                                 (compile-prepared-assign-target comp (rest-element-argument element))
                                 (compile-bind-target comp (rest-element-argument element)))))
                      (t (cons :element
                               (if assignment-p
                                   (compile-prepared-assign-target comp element)
                                   (compile-bind-target comp element))))))
                  elements)))
    (lambda (env value)
      (let ((record (get-iterator-record value)))
        (call-with-iterator-close-on-abrupt
         record
         (lambda ()
           (dolist (entry entries)
             (case (car entry)
               (:elision
                (iterator-step record))
               (:element
                (if assignment-p
                    (let ((setter (funcall (cdr entry) env)))
                      (multiple-value-bind (element-value done) (iterator-step-value record)
                        (declare (ignore done))
                        (funcall setter element-value)))
                    (multiple-value-bind (element-value done) (iterator-step-value record)
                      (declare (ignore done))
                      (funcall (cdr entry) env element-value))))
               (:rest
                (if assignment-p
                    (let ((setter (funcall (cdr entry) env)))
                      (funcall setter (new-array (iterator-record->list record))))
                    (funcall (cdr entry) env (new-array (iterator-record->list record)))))))
           (unless (iterator-record-done record)
             (iterator-close record))
           +undefined+))))))

(defun compile-bind-target (comp target)
  "Return (lambda (env value)) binding VALUE into TARGET via declaration semantics."
  (typecase target
    (identifier
     (multiple-value-bind (kind depth index) (comp-resolve comp (identifier-name target))
       (if (eq kind :local)
           (lambda (env value) (frame-init env depth index value))
           (let ((strict (comp-strict comp)) (name (identifier-name target)))
             (lambda (env value) (declare (ignore env)) (global-set name value strict))))))
    (assignment-pattern
     (let ((inner (compile-bind-target comp (assignment-pattern-left target)))
           (default (compile-named-value comp (assignment-pattern-right target)
                                         (target-inference-name (assignment-pattern-left target)))))
       (lambda (env value) (funcall inner env (if (js-undefined-p value) (funcall default env) value)))))
    (rest-element (compile-bind-target comp (rest-element-argument target)))
    (array-pattern
     (compile-array-pattern-binder comp (array-pattern-elements target) nil))
    (object-pattern
     (let ((binders (loop for pr in (object-pattern-properties target)
                          collect (if (rest-element-p pr)
                                      (cons :rest (compile-bind-target comp (rest-element-argument pr)))
                                      (cons (property-key-target comp pr)
                                            (compile-bind-target comp (property-value pr)))))))
       (lambda (env value)
         (when (js-nullish-p value) (throw-type-error "cannot destructure null or undefined"))
         (let ((o (to-object value)) (seen '()))
           (dolist (b binders)
             (if (eq (car b) :rest)
                 (let ((rest (new-object)))
                   (dolist (k (jm-own-property-keys o))
                     (let ((d (jm-get-own-property o k)))
                       (when (and d (eq (pd-enumerable d) t) (not (member k seen :test #'equal)))
                         (create-data-property rest k (js-get o k)))))
                   (funcall (cdr b) env rest))
                 (let ((k (funcall (car b) env)))
                   (push k seen)
                   (funcall (cdr b) env (js-getv o k)))))))))
    (t (error "bad binding target: ~a" (type-of target)))))

(defun property-key-target (comp pr)
  "Return (lambda (env) -> key) for an object-pattern property key."
  (let ((key (property-key pr)))
    (if (property-computed pr)
        (let ((f (compile-node comp key))) (lambda (env) (to-property-key (funcall f env))))
        (let ((k (property-key-string key))) (lambda (env) (declare (ignore env)) k)))))

(defun compile-destructuring-assignment (comp target rhs)
  ;; reuse the declaration binder but with assignment (set) semantics for identifiers:
  ;; wrap so identifiers use compile-reference's setter.
  (let ((binder (compile-assign-target comp target))
        (rhs-fn (compile-node comp rhs)))
    (lambda (env) (let ((v (funcall rhs-fn env))) (funcall binder env v) v))))

(defun compile-prepared-assign-target (comp target)
  "Return (lambda (env) -> setter), preserving reference-before-value ordering."
  (typecase target
    (identifier
     (multiple-value-bind (get set) (compile-reference comp target)
       (declare (ignore get))
       (lambda (env)
         (lambda (value) (funcall set env value)))))
    (member-expression
     (if (super-member-p target)
         (let ((reference (compile-super-reference comp target))
               (strict (comp-strict comp)))
           (lambda (env)
             (multiple-value-bind (base property receiver) (funcall reference env)
               (lambda (value)
                 (unless (jm-set base (to-property-key property) value receiver)
                   (when strict (throw-type-error "cannot assign to super property")))))))
         (multiple-value-bind (obj-fn computed key-part rcache wcache strict)
             (compile-member-reference-parts comp target)
           (declare (ignore rcache))
           (lambda (env)
             (let ((object (funcall obj-fn env))
                   (key-value (if computed (funcall key-part env) key-part)))
               (lambda (value)
                 (if computed
                     (js-set (to-object object) (to-property-key key-value) value strict)
                     (%ic-write object key-value value wcache strict))))))))
    (assignment-pattern
     (let ((inner (compile-prepared-assign-target comp (assignment-pattern-left target)))
           (default (compile-named-value comp (assignment-pattern-right target)
                                         (target-inference-name (assignment-pattern-left target)))))
       (lambda (env)
         (let ((setter (funcall inner env)))
           (lambda (value)
             (funcall setter (if (js-undefined-p value) (funcall default env) value)))))))
    (rest-element (compile-prepared-assign-target comp (rest-element-argument target)))
    (array-pattern
     (let ((binder (compile-array-pattern-binder comp (array-pattern-elements target) t)))
       (lambda (env) (lambda (value) (funcall binder env value)))))
    (object-pattern
     (let ((entries
             (loop for property in (object-pattern-properties target)
                   collect (if (rest-element-p property)
                               (list :rest nil
                                     (compile-prepared-assign-target comp
                                                                    (rest-element-argument property)))
                               (list :property (property-key-target comp property)
                                     (compile-prepared-assign-target comp (property-value property)))))))
       (lambda (env)
         (lambda (value)
           (let ((object (to-object value)) (seen '()))
             (dolist (entry entries)
               (if (eq (first entry) :rest)
                   (let ((setter (funcall (third entry) env))
                         (rest (new-object)))
                     (dolist (key (jm-own-property-keys object))
                       (let ((descriptor (jm-get-own-property object key)))
                         (when (and descriptor (eq (pd-enumerable descriptor) t)
                                    (not (member key seen :test #'equal)))
                           (create-data-property rest key (js-get object key)))))
                     (funcall setter rest))
                   (let* ((key (funcall (second entry) env))
                          (setter (funcall (third entry) env)))
                     (push key seen)
                     (funcall setter (js-getv object key))))))))))
    (t (error "bad assignment target"))))

(defun compile-assign-target (comp target)
  (let ((prepare (compile-prepared-assign-target comp target)))
    (lambda (env value)
      (funcall (funcall prepare env) value))))

;;; --- functions --------------------------------------------------------------

(defun function-body-strict-p (block)
  (dolist (s (block-statement-body block) nil)
    (if (and (expression-statement-p s) (expression-statement-directive s))
        (when (string= (expression-statement-directive s) "use strict") (return t))
        (return nil))))

(defun expected-argument-count (params)
  "ECMAScript function length: parameters before the first default or rest parameter."
  (loop for parameter in params
        for count from 0
        when (or (assignment-pattern-p parameter) (rest-element-p parameter))
          return count
        finally (return (length params))))

(defun binding-contains-expression-p (binding)
  "Implement ContainsExpression for formal-parameter binding syntax."
  (typecase binding
    (assignment-pattern t)
    (rest-element (binding-contains-expression-p (rest-element-argument binding)))
    (array-pattern
     (some (lambda (element)
             (and element (binding-contains-expression-p element)))
           (array-pattern-elements binding)))
    (object-pattern
     (some (lambda (property)
             (typecase property
               (rest-element
                (binding-contains-expression-p (rest-element-argument property)))
               (property
                (or (property-computed property)
                    (binding-contains-expression-p (property-value property))))
               (t nil)))
           (object-pattern-properties binding)))
    (t nil)))

(defun compile-function-common (comp params body fname &key arrow method generator async function-kind
                                                       source-text)
  "Return (lambda (env) -> js-function). Sets up the function scope and body closure.
GENERATOR/ASYNC bodies run in a coroutine (Phase 06): a hidden %coro% frame slot holds
the live coroutine that yield/await suspend."
  (let* ((strict (or (comp-strict comp) (function-body-strict-p body)))
         (parameter-scope (make-cscope :function))
         (stmts (block-statement-body body))
         (coro-p (or generator async))
         (simple-params (every #'identifier-p params))
         (has-parameter-expressions (some #'binding-contains-expression-p params))
         (body-scope (when has-parameter-expressions (make-cscope :block)))
         (runtime-body-scope (or body-scope parameter-scope)))
    ;; reserved bindings
    (let ((this-idx (unless arrow (cs-declare parameter-scope "%this%")))
          (nt-idx (unless arrow (cs-declare parameter-scope "%new.target%")))
          (active-fn-idx (unless arrow (cs-declare parameter-scope "%active.function%")))
          (args-idx (unless arrow (cs-declare parameter-scope "arguments")))
          (coro-idx (when coro-p (cs-declare parameter-scope "%coro%"))))
      ;; parameters
      (let ((param-binders '())
            (param-indices '())
            (mapped-parameters nil)
            (param-names (loop for parameter in params append (binding-bound-names parameter))))
        ;; Parameter expressions resolve only through this scope and its outer
        ;; environment. For a non-simple list, body declarations do not exist yet.
        (dolist (name param-names)
          (pushnew (cs-declare parameter-scope name) param-indices))
        ;; Sloppy simple parameter lists alias supplied arguments to bindings.
        ;; Walk right-to-left so only the last duplicate parameter remains mapped.
        (when (and simple-params (not strict))
          (let ((seen (make-hash-table :test 'equal))
                (mapping (make-array (length params) :initial-element nil)))
            (loop for parameter in (reverse params)
                  for index downfrom (1- (length params))
                  for name = (identifier-name parameter)
                  unless (gethash name seen)
                    do (setf (gethash name seen) t
                             (aref mapping index)
                             (cons (gethash name (cs-names parameter-scope)) name)))
            (setf mapped-parameters mapping)))
        ;; hoisted vars / funcs / lexicals of the body
        (multiple-value-bind (vars funcs) (collect-var-names stmts)
          (dolist (name vars) (cs-declare runtime-body-scope name))
          (dolist (name funcs) (cs-declare runtime-body-scope name))
          (dolist (name (collect-lexical-names stmts))
            (cs-declare runtime-body-scope name))
          (mark-immutable-lexicals runtime-body-scope stmts)
          (let ((parameter-comp (make-comp))
                (body-comp (make-comp))
                (return-tag (gensym "RET")))
            (setf (comp-scopes parameter-comp)
                  (cons parameter-scope (comp-scopes comp))
                  (comp-strict parameter-comp) strict
                  (comp-module parameter-comp) (comp-module comp)
                  (comp-scopes body-comp)
                  (if body-scope
                      (cons body-scope (comp-scopes parameter-comp))
                      (comp-scopes parameter-comp))
                  (comp-strict body-comp) strict
                  (comp-module body-comp) (comp-module comp))
            ;; compile param binders + body with this function's return tag active
            (let ((*current-return-tag* return-tag)
                  (*current-generator-kind*
                    (cond ((and generator async) :async)
                          (generator :sync))))
              (setf param-binders
                    (loop for parameter in params
                          for index from 0
                          collect
                          (if (rest-element-p parameter)
                              (cons :rest
                                    (compile-bind-target
                                     parameter-comp (rest-element-argument parameter)))
                              (cons index
                                    (compile-bind-target parameter-comp parameter)))))
              (let* ((lexical-idxs
                       (loop for name in (collect-lexical-names stmts)
                             collect (gethash name (cs-names runtime-body-scope))))
                     (body-copy-pairs
                       (when body-scope
                         (loop for name in (remove-duplicates (append vars funcs)
                                                              :test #'string=)
                               for parameter-index = (gethash name (cs-names parameter-scope))
                               when parameter-index
                                 collect (cons (gethash name (cs-names body-scope))
                                               parameter-index))))
                     (func-decls (collect-function-decls stmts))
                     (func-compiled
                       (loop for declaration in func-decls
                             for name = (identifier-name (function-node-id declaration))
                             collect
                             (cons (gethash name (cs-names runtime-body-scope))
                                   (compile-function-common
                                    body-comp
                                    (function-node-params declaration)
                                    (function-node-body declaration)
                                    name
                                    :generator (function-node-generator declaration)
                                    :async (function-node-async declaration)
                                    :source-text (node-source-text declaration)))))
                     ;; Phase-25 COMPILE tier: eager mode classifies every body and records a named
                     ;; outcome. A coverable non-coroutine body invokes ONE cl:compiled native form;
                     ;; rejection or any compile failure falls back to the unchanged closure emitter.
                     (source-requested (eq *compile-tier-mode* :eager))
                     (source-id (and source-requested (cs-function-id fname body)))
                     (source-blockers
                       (and source-requested
                            (if coro-p '("coroutine")
                                (cs-function-blockers params stmts))))
                     (source-body
                       (when source-requested
                         (if source-blockers
                             (progn
                               (incf *cs-ineligible-count*)
                               (cs-note-status source-id :ineligible source-blockers)
                               nil)
                             (cs-compile-body body-comp stmts return-tag source-id))))
                     (body-fn (or source-body (compile-seq body-comp stmts)))
                     ;; Read after parameter and body compilation. A non-simple `var arguments`
                     ;; needs the parameter-environment object copied into the body frame even
                     ;; though body references resolve to the child binding.
                     (needs-args
                       (and (not arrow)
                            (or (cs-uses-arguments parameter-scope)
                                (and body-scope
                                     (member "arguments" vars :test #'string=)))))
                     (parameter-count (cs-count parameter-scope))
                     (body-count (and body-scope (cs-count body-scope)))
                     (this-mode (cond (arrow :lexical) (strict :strict) (t :global)))
                     (resolved-function-kind
                       (or function-kind
                           (cond ((and generator async) :async-generator)
                                 (generator :generator) (async :async) (arrow :arrow)
                                 (method :method) (t :ordinary)))))
                (lambda (defenv)
                  (labels
                      ((setup-frame (fn this args new-target)
                         (let ((parameter-frame (new-frame parameter-count defenv)))
                           (dolist (parameter-index param-indices)
                             (setf (svref (env-slots parameter-frame) parameter-index) +tdz+))
                           (unless arrow
                             (setf (svref (env-slots parameter-frame) this-idx)
                                   (coerce-this this this-mode)
                                   (svref (env-slots parameter-frame) nt-idx) new-target
                                   (svref (env-slots parameter-frame) active-fn-idx) fn)
                             (when (and needs-args
                                        (not (member "arguments" param-names :test #'string=)))
                               (setf (svref (env-slots parameter-frame) args-idx)
                                     (make-arguments-object
                                      args fn parameter-frame
                                      :mapped-parameters mapped-parameters))))
                           (unless body-scope
                             (dolist (lexical-index lexical-idxs)
                               (setf (svref (env-slots parameter-frame) lexical-index) +tdz+)))
                           (bind-parameters param-binders args parameter-frame simple-params)
                           (let ((body-frame
                                   (if body-scope
                                       (new-frame body-count parameter-frame)
                                       parameter-frame)))
                             (when body-scope
                               (dolist (lexical-index lexical-idxs)
                                 (setf (svref (env-slots body-frame) lexical-index) +tdz+))
                               (dolist (pair body-copy-pairs)
                                 (setf (svref (env-slots body-frame) (car pair))
                                       (frame-ref parameter-frame 0 (cdr pair) "parameter"))))
                             (dolist (compiled func-compiled)
                               (setf (svref (env-slots body-frame) (car compiled))
                                     (funcall (cdr compiled) body-frame)))
                             body-frame)))
                       (function-frame (body-frame)
                         (if body-scope (env-parent body-frame) body-frame))
                       (run-body (frame)
                         (catch return-tag (funcall body-fn frame) +undefined+)))
                    (instantiate-function
                     (cond
                       ((and generator async)
                        (lambda (fn this args new-target)
                          (let ((frame (setup-frame fn this args new-target)))
                            (let ((coroutine (make-coroutine (lambda () (run-body frame)))))
                              (setf (svref (env-slots (function-frame frame)) coro-idx)
                                    coroutine)
                              (make-async-generator fn coroutine)))))
                       (generator
                        (lambda (fn this args new-target)
                          (let ((frame (setup-frame fn this args new-target)))
                            (let ((coroutine (make-coroutine (lambda () (run-body frame)))))
                              (setf (svref (env-slots (function-frame frame)) coro-idx)
                                    coroutine)
                              (make-generator fn coroutine)))))
                       (async
                        (lambda (fn this args new-target)
                          (start-async-function
                           (lambda ()
                             (let ((frame (setup-frame fn this args new-target)))
                               (let ((coroutine
                                       (make-coroutine (lambda () (run-body frame)))))
                                 (setf (svref (env-slots (function-frame frame)) coro-idx)
                                       coroutine)
                                 coroutine))))))
                       (t
                        (lambda (fn this args new-target)
                          (run-body (setup-frame fn this args new-target)))))
                     defenv
                     :fname fname :param-count (expected-argument-count params)
                     :strict strict :this-mode this-mode
                     :source-text source-text
                     :constructable
                     (or (member resolved-function-kind '(:base-class :derived-class))
                         (and (not arrow) (not method) (not coro-p)))
                     :function-kind resolved-function-kind
                     :kind (cond ((or arrow method) :method)
                                 ((and generator async) :async-generator)
                                 (generator :generator)
                                 (async :async)
                                 (t :normal)))))))))))))

(defun bind-parameters (binders args frame simple)
  (declare (ignore simple))
  (dolist (b binders)
    (if (eq (car b) :rest)
        (funcall (cdr b) frame (new-array (nthcdr (position :rest binders :key #'car) args)))
        (funcall (cdr b) frame (or (nth (car b) args) +undefined+)))))

(defun coerce-this (this mode)
  (case mode
    (:strict this)
    (:lexical this)
    (t (cond ((js-nullish-p this) (realm-global *realm*))
             ((js-object-p this) this)
             (t (to-object this))))))

(defun collect-function-decls (stmts)
  (loop for s in stmts
        ;; unwrap `export function f(){}` / `export default function f(){}` (Phase 07)
        for node = (cond ((and (export-named-declaration-p s)
                               (export-named-declaration-declaration s))
                          (export-named-declaration-declaration s))
                         ((export-default-declaration-p s)
                          (export-default-declaration-declaration s))
                         (t s))
        when (and (function-node-p node) (function-node-declaration node) (function-node-id node))
        collect node))

(defun compile-function-expr (comp node)
  (let ((id (function-node-id node)))
    (if (null id)
        (compile-function-common comp (function-node-params node) (function-node-body node) ""
                                 :generator (function-node-generator node)
                                 :async (function-node-async node)
                                 :source-text (node-source-text node))
        (let* ((name (identifier-name id))
               (name-scope (make-cscope :block))
               (name-index (cs-declare name-scope name))
               (sub (make-comp)))
          (cs-mark-silent-immutable name-scope name)
          (setf (comp-scopes sub) (cons name-scope (comp-scopes comp))
                (comp-strict sub) (comp-strict comp)
                (comp-labels sub) (comp-labels comp)
                (comp-loops sub) (comp-loops comp)
                (comp-module sub) (comp-module comp))
          (let ((factory
                  (compile-function-common
                   sub (function-node-params node) (function-node-body node) name
                   :generator (function-node-generator node)
                   :async (function-node-async node)
                   :source-text (node-source-text node))))
            (lambda (env)
              (let* ((name-env (new-frame 1 env +tdz+))
                     (function (funcall factory name-env)))
                (frame-init name-env 0 name-index function)
                function)))))))

(defun compile-arrow (comp node &optional (name ""))
  (let ((body (arrow-function-body node)))
    (if (block-statement-p body)
        (compile-function-common comp (arrow-function-params node) body name :arrow t
                                 :async (arrow-function-async node)
                                 :source-text (node-source-text node))
        ;; expression-bodied arrow: wrap the expression in a return
        (compile-function-common comp (arrow-function-params node)
                                 (make-block-statement :body (list (make-return-statement :argument body)))
                                 name :arrow t :async (arrow-function-async node)
                                 :source-text (node-source-text node)))))

(defun anon-fn-node-p (node)
  "An anonymous function/arrow/class expression eligible for NamedEvaluation."
  (or (arrow-function-p node)
      (and (function-node-p node) (null (function-node-id node)))
      (and (class-node-p node) (null (class-node-id node)))))

(defun compile-named-value (comp node name)
  "Like compile-node, but names an anonymous function/arrow/class after NAME (§ NamedEvaluation)."
  (cond
    ((or (null name) (string= name "")) (compile-node comp node))
    ((arrow-function-p node) (compile-arrow comp node name))
    ((and (function-node-p node) (null (function-node-id node)))
     (compile-function-common comp (function-node-params node) (function-node-body node) name
                               :generator (function-node-generator node)
                               :async (function-node-async node)
                               :source-text (node-source-text node)))
    ((and (class-node-p node) (null (class-node-id node)))
     (compile-class comp node name))
    (t (compile-node comp node))))

(defun compile-method (comp fn-node &key function-kind source-node)
  (compile-function-common comp (function-node-params fn-node) (function-node-body fn-node) "" :method t
                           :generator (function-node-generator fn-node)
                           :async (function-node-async fn-node)
                           :function-kind function-kind
                           :source-text (callable-source-node-text (or source-node fn-node))))

;;; --- yield / await (Phase 06) ------------------------------------------------
;;; yield/await are plain calls into the coroutine primitive: they return a js-value
;;; on the real CL stack, so they compose inside any expression with no special case.
;;; The enclosing generator/async function's live coroutine is read from %coro%.

(defun compile-coro-ref (comp)
  (multiple-value-bind (kind depth index) (comp-resolve comp "%coro%")
    (if (eq kind :local)
        (lambda (env) (frame-ref env depth index "%coro%"))
        (lambda (env) (declare (ignore env))
          (throw-syntax-error "yield/await outside a generator or async function")))))

(defun compile-yield (comp node)
  (let ((arg-fn (and (yield-expression-argument node)
                     (compile-node comp (yield-expression-argument node))))
        (coro-ref (compile-coro-ref comp))
        (generator-kind *current-generator-kind*))
    (if (yield-expression-delegate node)
        (lambda (env)
          (let ((value (funcall arg-fn env)))
            (%yield-delegate
             (funcall coro-ref env)
             (if (eq generator-kind :async)
                 (get-async-iterator-record value)
                 (get-iterator-record value))
             generator-kind)))
        (lambda (env)
          (coroutine-suspend (funcall coro-ref env) :yield
                             (if arg-fn (funcall arg-fn env) +undefined+))))))

(defun compile-await (comp node)
  (let ((arg-fn (compile-node comp (await-expression-argument node)))
        (coro-ref (compile-coro-ref comp)))
    (lambda (env) (await-value (funcall coro-ref env) (funcall arg-fn env)))))

;;; --- lazy iterator protocol (yield*, for-of/for-await) -----------------------

(defun %await-async-iterator-result (co value)
  (let ((result (await-value co value)))
    (unless (js-object-p result)
      (throw-type-error "iterator result is not an object"))
    result))

(defun %async-iterator-complete (record result)
  (let ((done (js-truthy (js-get result "done"))))
    (when done
      (setf (async-iterator-record-done record) t))
    done))

(defun %async-iterator-value (result)
  (js-get result "value"))

(defun %perform-async-iterator-close (co record)
  (unless (async-iterator-record-done record)
    ;; The close is attempted at most once even if its getter, call, await, or
    ;; result validation fails.
    (setf (async-iterator-record-done record) t)
    (multiple-value-bind (result present-p) (async-iterator-return record)
      (when present-p
        (%await-async-iterator-result co result))))
  +undefined+)

(defun async-iterator-close (co record &key throw-completion-p)
  "AsyncIteratorClose. An in-flight throw retains precedence over close errors."
  (if throw-completion-p
      (handler-case (%perform-async-iterator-close co record)
        (js-condition () +undefined+))
      (%perform-async-iterator-close co record))
  +undefined+)

(defun call-with-async-iterator-close-on-abrupt (co record thunk)
  "Run one loop binding/body step and close if control leaves it abruptly."
  (let ((completed nil)
        (throw-completion-p nil))
    (unwind-protect
         (multiple-value-prog1
             (handler-case (funcall thunk)
               (js-condition (condition)
                 (setf throw-completion-p t)
                 (error condition)))
           (setf completed t))
      (unless completed
        (async-iterator-close
         co record :throw-completion-p throw-completion-p)))))

(defun %sync-yield-delegate (co iter)
  "yield* (§15.5.5): forward next/throw/return to the inner iterator, yielding each
value to the outer driver and returning the inner iterator's final value."
  (let ((sent (cons :next +undefined+)))
    (loop
      (let* ((mode (car sent)) (v (cdr sent))
             (result
              (ecase mode
                (:next (iterator-next iter v))
                (:throw
                 (let* ((iterator (iterator-record-iterator iter))
                        (m (get-method iterator "throw")))
                   (if (js-undefined-p m)
                       (progn
                         ;; The protocol TypeError is created only after IteratorClose
                         ;; completes normally; a return getter/call/result error wins.
                         (iterator-close iter)
                         (throw-type-error "iterator has no throw method"))
                       (js-call m iterator (list v)))))
                (:return
                 (let* ((iterator (iterator-record-iterator iter))
                        (m (get-method iterator "return")))
                   (if (js-undefined-p m)
                       (throw *coroutine-return-tag* (cons :return v))
                       (js-call m iterator (list v))))))))
        (unless (js-object-p result) (throw-type-error "iterator result is not an object"))
        (when (iterator-complete iter result)
          (let ((rv (iterator-value iter result)))
            ;; a forwarded .return whose inner iterator finished completes the outer generator
            (if (eq mode :return) (throw *coroutine-return-tag* (cons :return rv)) (return rv))))
        ;; Sync yield* exposes this validated result object by identity.
        (setf sent (coroutine-suspend-raw co result :yield-result))))))

(defun %async-yield-delegate (co iter)
  "Async yield*: await iterator results, but do not re-adopt their settled values."
  (let ((sent (cons :next +undefined+)))
    (loop
      (let ((mode (car sent))
            (value (cdr sent))
            (result nil)
            (method-present-p t))
        (multiple-value-setq (result method-present-p)
          (ecase mode
            (:next (values (async-iterator-next iter value) t))
            (:throw (async-iterator-throw iter value))
            (:return (async-iterator-return iter value))))
        (unless method-present-p
          (ecase mode
            (:throw
             ;; Missing throw closes normally first. Any close error wins over
             ;; the protocol TypeError.
             (async-iterator-close co iter)
             (throw-type-error "iterator has no throw method"))
            (:return
             ;; AsyncGeneratorUnwrapYieldResumption already awaited this value
             ;; once. A missing delegate return method requires the separate
             ;; Await in yield* before propagating the outer Return completion.
             (throw *coroutine-return-tag*
                    (cons :return (await-value co value))))))
        (setf result (%await-async-iterator-result co result))
        (when (%async-iterator-complete iter result)
          (let ((return-value (%async-iterator-value result)))
            ;; The throw and return branches each perform a second Await after
            ;; the iterator result itself settles. A normal next completion
            ;; deliberately returns its value without adopting it.
            (when (member mode '(:throw :return))
              (setf return-value (await-value co return-value)))
            (if (eq mode :return)
                (throw *coroutine-return-tag* (cons :return return-value))
                (return return-value))))
        ;; The iterator result was already awaited. AsyncFromSync also adopted
        ;; its value before creating this result, so the outer driver must wrap
        ;; the value without a second PromiseResolve.
        (setf sent
              (coroutine-suspend-raw
               co (%async-iterator-value result) :yield-no-await))))))

(defun %yield-delegate (co iter generator-kind)
  (if (eq generator-kind :async)
      (%async-yield-delegate co iter)
      (%sync-yield-delegate co iter)))

;;; --- statements -------------------------------------------------------------

(defun compile-block (comp node)
  (let ((stmts (block-statement-body node)))
    (multiple-value-bind (has-lexical) (block-has-lexical-p stmts)
      (if (not has-lexical)
          (compile-seq comp stmts)
          (let* ((scope (make-cscope :block))
                 (lex-names (collect-lexical-names stmts))
                 (func-names (mapcar (lambda (fd) (identifier-name (function-node-id fd)))
                                     (collect-function-decls stmts))))
            (dolist (n lex-names) (cs-declare scope n))
            (mark-immutable-lexicals scope stmts)
            (dolist (n func-names) (cs-declare scope n))
            (let ((sub (make-comp)))
              (setf (comp-scopes sub) (cons scope (comp-scopes comp))
                    (comp-strict sub) (comp-strict comp)
                    (comp-labels sub) (comp-labels comp) (comp-loops sub) (comp-loops comp))
              (let* ((lexical-idxs (mapcar (lambda (n) (gethash n (cs-names scope))) lex-names))
                     (func-decls (collect-function-decls stmts))
                     (func-compiled (loop for fd in func-decls
                                          collect (cons (gethash (identifier-name (function-node-id fd)) (cs-names scope))
                                                        (compile-function-common sub (function-node-params fd)
                                                                                 (function-node-body fd)
                                                                                 (identifier-name (function-node-id fd))
                                                                                 :generator (function-node-generator fd)
                                                                                 :async (function-node-async fd)
                                                                                 :source-text (node-source-text fd)))))
                     (body-fn (compile-seq sub stmts))
                     (count (cs-count scope)))
                (lambda (env)
                  (let ((frame (new-frame count env)))
                    (dolist (li lexical-idxs) (setf (svref (env-slots frame) li) +tdz+))
                    (dolist (fc func-compiled) (setf (svref (env-slots frame) (car fc)) (funcall (cdr fc) frame)))
                    (funcall body-fn frame)
                    :normal)))))))))

(defun block-has-lexical-p (stmts)
  (some (lambda (s) (or (and (variable-declaration-p s) (member (variable-declaration-kind s) '(:let :const)))
                        (and (class-node-p s) (class-node-declaration s))
                        (function-node-p s)))
        stmts))

(defun compile-var-decl (comp node)
  (let ((kind (variable-declaration-kind node))
        (binders (loop for d in (variable-declaration-declarations node)
                       for id = (variable-declarator-id d)
                       collect (cons (compile-bind-target comp id)
                                     (and (variable-declarator-init d)
                                          (compile-named-value comp (variable-declarator-init d)
                                                               (and (identifier-p id) (identifier-name id))))))))
    (lambda (env)
      (dolist (b binders :normal)
        ;; `var x;` is a runtime no-op: declaration instantiation already
        ;; initialized its slot, and overwriting here would erase a parameter or
        ;; hoisted function. `let x;` performs InitializeBinding(undefined).
        (when (or (cdr b) (not (eq kind :var)))
          (funcall (car b) env (if (cdr b) (funcall (cdr b) env) +undefined+)))))))

(defun compile-if (comp node)
  (let ((test (compile-node comp (if-statement-test node)))
        (con (compile-node comp (if-statement-consequent node)))
        (alt (and (if-statement-alternate node) (compile-node comp (if-statement-alternate node)))))
    (lambda (env)
      (if (js-truthy (funcall test env)) (funcall con env) (when alt (funcall alt env)))
      :normal)))

(defmacro with-loop ((comp break-tag continue-tag &optional label) &body body)
  `(let ((,break-tag (list 'break)) (,continue-tag (list 'continue)))
     (let ((,comp (copy-comp-for-loop ,comp ,break-tag ,continue-tag ,label)))
       ,@body)))

(defun copy-comp-for-loop (comp break-tag continue-tag label)
  (let ((c (make-comp)) (lbl (or label (comp-pending-label comp))))
    (setf (comp-scopes c) (comp-scopes comp) (comp-strict c) (comp-strict comp)
          (comp-loops c) (cons (cons break-tag continue-tag) (comp-loops comp))
          (comp-labels c) (if lbl (cons (list* lbl break-tag continue-tag) (comp-labels comp))
                              (comp-labels comp)))
    c))

(defun copy-comp-for-switch (comp break-tag)
  "Add a switch break target while preserving the nearest enclosing iteration's
continue target. A switch is breakable but is not itself an iteration statement."
  (let ((c (make-comp)))
    (setf (comp-scopes c) (comp-scopes comp)
          (comp-strict c) (comp-strict comp)
          (comp-loops c) (cons (cons break-tag (and (comp-loops comp)
                                                    (cdr (first (comp-loops comp)))))
                               (comp-loops comp))
          (comp-labels c) (comp-labels comp))
    c))

(defun compile-while (comp node)
  (with-loop (comp bt ct)
    (let ((test (compile-node comp (while-statement-test node)))
          (body (compile-node comp (while-statement-body node))))
      (lambda (env)
        (catch bt
          (loop while (js-truthy (funcall test env))
                do (catch ct (funcall body env))))
        :normal))))

(defun compile-do-while (comp node)
  (with-loop (comp bt ct)
    (let ((body (compile-node comp (do-while-statement-body node)))
          (test (compile-node comp (do-while-statement-test node))))
      (lambda (env)
        (catch bt
          (loop (catch ct (funcall body env))
                (unless (js-truthy (funcall test env)) (return))))
        :normal))))

(defun compile-for (comp node)
  ;; a `let`/`const` for-init gets its own per-iteration scope (approximated: one scope)
  (let* ((init (for-statement-init node))
         (lexical (and (variable-declaration-p init) (member (variable-declaration-kind init) '(:let :const)))))
    (if lexical
        (compile-for-lexical comp node)
        (with-loop (comp bt ct)
          (let ((init-fn (and init (compile-node comp init)))
                (test-fn (and (for-statement-test node) (compile-node comp (for-statement-test node))))
                (update-fn (and (for-statement-update node) (compile-node comp (for-statement-update node))))
                (body-fn (compile-node comp (for-statement-body node))))
            (lambda (env)
              (when init-fn (funcall init-fn env))
              (catch bt
                (loop while (or (null test-fn) (js-truthy (funcall test-fn env)))
                      do (catch ct (funcall body-fn env))
                         (when update-fn (funcall update-fn env))))
              :normal))))))

(defun compile-for-lexical (comp node)
  (let* ((init (for-statement-init node))
         (names (loop for d in (variable-declaration-declarations init)
                      append (binding-bound-names (variable-declarator-id d))))
         (scope (make-cscope :block)))
    (dolist (n names) (cs-declare scope n))
    (when (eq (variable-declaration-kind init) :const)
      (dolist (n names) (cs-mark-immutable scope n)))
    (with-loop (comp bt ct)
      (let ((sub (make-comp)))
        (setf (comp-scopes sub) (cons scope (comp-scopes comp)) (comp-strict sub) (comp-strict comp)
              (comp-loops sub) (comp-loops comp) (comp-labels sub) (comp-labels comp))
        (let ((init-fn (compile-node sub init))
              (test-fn (and (for-statement-test node) (compile-node sub (for-statement-test node))))
              (update-fn (and (for-statement-update node) (compile-node sub (for-statement-update node))))
              (body-fn (compile-node sub (for-statement-body node)))
              (count (cs-count scope)))
          (lambda (env)
            (let ((frame (new-frame count env)))
              (dotimes (i count) (setf (svref (env-slots frame) i) +tdz+))
              (funcall init-fn frame)
              (catch bt
                (loop while (or (null test-fn) (js-truthy (funcall test-fn frame)))
                      do (catch ct (funcall body-fn frame))
                         (when update-fn (funcall update-fn frame))))
              :normal)))))))

(defun compile-for-in (comp node)
  (compile-for-each comp node (for-in-statement-left node) (for-in-statement-right node)
                    (for-in-statement-body node) :in))

(defun compile-for-of (comp node)
  (if (for-of-statement-await node)
      (compile-for-await comp node)
      (compile-for-each comp node (for-of-statement-left node) (for-of-statement-right node)
                        (for-of-statement-body node) :of)))

(defun compile-for-await (comp node)
  "for await (x of obj): lazily step an async iterator, awaiting each next() result.
Runs inside the enclosing async function/generator's coroutine (%coro%)."
  (with-loop (comp bt ct)
    (let* ((left (for-of-statement-left node)) (right (for-of-statement-right node))
           (body (for-of-statement-body node))
           (lexical (and (variable-declaration-p left) (member (variable-declaration-kind left) '(:let :const))))
           (names (when lexical (loop for d in (variable-declaration-declarations left)
                                      append (binding-bound-names (variable-declarator-id d)))))
           (scope (when lexical (make-cscope :block))))
      (when lexical
        (dolist (n names) (cs-declare scope n))
        (when (eq (variable-declaration-kind left) :const)
          (dolist (n names) (cs-mark-immutable scope n))))
      (let ((sub comp))
        (when lexical
          (setf sub (make-comp))
          (setf (comp-scopes sub) (cons scope (comp-scopes comp)) (comp-strict sub) (comp-strict comp)
                (comp-loops sub) (comp-loops comp) (comp-labels sub) (comp-labels comp)))
        (let* ((coro-ref (compile-coro-ref comp))
               (right-fn (compile-node comp right))
               (binder (for-each-binder sub left))
               (body-fn (compile-node sub body))
               (count (and lexical (cs-count scope))))
          (lambda (env)
            (let ((co (funcall coro-ref env)))
              (let ((iter (get-async-iterator-record (funcall right-fn env))))
                (catch bt
                  (loop
                    ;; Errors while acquiring/awaiting the next result propagate
                    ;; directly. AsyncFromSync itself closes when adoption of a
                    ;; yielded value rejects.
                    (let ((result
                            (%await-async-iterator-result
                             co (async-iterator-next iter))))
                      (when (%async-iterator-complete iter result)
                        (return))
                      (let ((value (%async-iterator-value result))
                            (frame (if lexical
                                       (new-frame count env +tdz+)
                                       env)))
                        ;; Binding, body, break, outer continue, and return are
                        ;; inside the close boundary. A local continue is caught
                        ;; and therefore does not close the iterator.
                        (call-with-async-iterator-close-on-abrupt
                         co iter
                         (lambda ()
                           (funcall binder frame value)
                           (catch ct (funcall body-fn frame)))))))))
              :normal)))))))

(defun compile-for-each (comp node left right body kind)
  (declare (ignore node))
  (with-loop (comp bt ct)
    (let* ((lexical (and (variable-declaration-p left) (member (variable-declaration-kind left) '(:let :const))))
           (names (when lexical (loop for d in (variable-declaration-declarations left)
                                      append (binding-bound-names (variable-declarator-id d)))))
           (scope (when lexical (make-cscope :block))))
      (when lexical
        (dolist (n names) (cs-declare scope n))
        (when (eq (variable-declaration-kind left) :const)
          (dolist (n names) (cs-mark-immutable scope n))))
      (let ((sub comp))
        (when lexical
          (setf sub (make-comp))
          (setf (comp-scopes sub) (cons scope (comp-scopes comp)) (comp-strict sub) (comp-strict comp)
                (comp-loops sub) (comp-loops comp) (comp-labels sub) (comp-labels comp)))
        (let* ((right-fn (compile-node comp right))
               (binder (for-each-binder sub left))
               (body-fn (compile-node sub body))
               (count (and lexical (cs-count scope))))
          (lambda (env)
            (let ((rv (funcall right-fn env)))
              (if (eq kind :in)
                  (catch bt
                    (dolist (item (if (js-nullish-p rv) '() (for-in-keys (to-object rv))))
                      (let ((frame (if lexical (new-frame count env +tdz+) env)))
                        (funcall binder frame item)
                        (catch ct (funcall body-fn frame)))))
                  (let ((record (get-iterator-record rv)))
                    (catch bt
                      (loop
                        (multiple-value-bind (item done) (iterator-step-value record)
                          (when done (return))
                          (call-with-iterator-close-on-abrupt
                           record
                           (lambda ()
                             (let ((frame (if lexical (new-frame count env +tdz+) env)))
                               (funcall binder frame item)
                               (catch ct (funcall body-fn frame))))))))))
              :normal)))))))

(defun for-each-binder (comp left)
  (cond ((variable-declaration-p left)
         (compile-bind-target comp (variable-declarator-id (first (variable-declaration-declarations left)))))
        (t (compile-assign-target comp left))))

(defun for-in-keys (o)
  "Enumerable string keys along the prototype chain, no duplicates (§14.7.5.9)."
  (let ((seen (make-hash-table :test 'equal)) (result '()))
    (loop for obj = o then (jm-get-prototype-of obj) while (js-object-p obj) do
      (dolist (k (jm-own-property-keys obj))
        (when (and (stringp k) (not (gethash k seen)))
          (setf (gethash k seen) t)
          (let ((d (jm-get-own-property obj k)))
            (when (and d (eq (pd-enumerable d) t)) (push k result))))))
    (nreverse result)))

(defun compile-switch (comp node)
  (let* ((bt (list 'break))
         (disc (compile-node comp (switch-statement-discriminant node)))
         (base (copy-comp-for-switch comp bt))
         (stmts (loop for c in (switch-statement-cases node)
                      append (switch-case-consequent c)))
         (lex-names (collect-lexical-names stmts))
         (func-decls (collect-function-decls stmts))
         (scope (and (block-has-lexical-p stmts) (make-cscope :block))))
    (when scope
      (dolist (n lex-names) (cs-declare scope n))
      (mark-immutable-lexicals scope stmts)
      (dolist (fd func-decls) (cs-declare scope (identifier-name (function-node-id fd)))))
    (let* ((sub (if scope
                    (let ((c (make-comp)))
                      (setf (comp-scopes c) (cons scope (comp-scopes base))
                            (comp-strict c) (comp-strict base)
                            (comp-loops c) (comp-loops base)
                            (comp-labels c) (comp-labels base))
                      c)
                    base))
           (cases (loop for c in (switch-statement-cases node)
                        collect (list (and (switch-case-test c) (compile-node sub (switch-case-test c)))
                                      (compile-seq sub (switch-case-consequent c)))))
           (lexical-idxs (and scope (mapcar (lambda (n) (gethash n (cs-names scope))) lex-names)))
           (func-compiled
             (and scope
                  (loop for fd in func-decls
                        collect (cons (gethash (identifier-name (function-node-id fd)) (cs-names scope))
                                      (compile-function-common
                                       sub (function-node-params fd) (function-node-body fd)
                                       (identifier-name (function-node-id fd))
                                       :generator (function-node-generator fd)
                                       :async (function-node-async fd)
                                       :source-text (node-source-text fd))))))
           (count (and scope (cs-count scope))))
      (labels ((run-cases (frame d)
                 (catch bt
                   (let ((matched nil))
                     (dolist (c cases)
                       (when (and (not matched) (first c)
                                  (js-strict-eq d (funcall (first c) frame)))
                         (setf matched t))
                       (when matched (funcall (second c) frame)))
                     (unless matched
                       (let ((run nil))
                         (dolist (c cases)
                           (when (null (first c)) (setf run t))
                           (when run (funcall (second c) frame)))))))))
        (lambda (env)
          ;; The discriminant is outside the CaseBlock lexical environment.
          (let ((d (funcall disc env)))
            (if (not scope)
                (run-cases env d)
                (let ((frame (new-frame count env)))
                  (dolist (i lexical-idxs) (setf (svref (env-slots frame) i) +tdz+))
                  (dolist (fc func-compiled)
                    (setf (svref (env-slots frame) (car fc)) (funcall (cdr fc) frame)))
                  (run-cases frame d))))
          :normal)))))

(defun compile-return (comp node)
  (let ((arg (and (return-statement-argument node) (compile-node comp (return-statement-argument node))))
        (tag (comp-return-tag comp))
        (async-generator-p
          (and (return-statement-argument node)
               (eq *current-generator-kind* :async)))
        (coro-ref
          (and (return-statement-argument node)
               (eq *current-generator-kind* :async)
               (compile-coro-ref comp))))
    (lambda (env)
      (let ((value (if arg (funcall arg env) +undefined+)))
        ;; Async-generator ReturnStatement awaits an explicit expression before
        ;; completing. The queue driver then wraps this settled value directly.
        (throw tag
               (if async-generator-p
                   (await-value (funcall coro-ref env) value)
                   value))))))

(defun comp-return-tag (comp)
  ;; the return tag is the symbol we threw to in compile-function-common; we look it
  ;; up via a special variable bound during body compilation.
  (declare (ignore comp))
  *current-return-tag*)

(defun compile-throw (comp node)
  (let ((arg (compile-node comp (throw-statement-argument node))))
    (lambda (env) (throw-js-value (funcall arg env)))))

(defun compile-break (comp node)
  (let ((label (break-statement-label node)))
    (if label
        (let ((entry (assoc label (comp-labels comp) :test #'string=)))
          (unless entry (error "unresolved break label"))
          (let ((tag (cadr entry))) (lambda (env) (declare (ignore env)) (throw tag :break))))
        (let ((tag (car (first (comp-loops comp)))))
          (lambda (env) (declare (ignore env)) (throw tag :break))))))

(defun compile-continue (comp node)
  (let ((label (continue-statement-label node)))
    (if label
        (let ((entry (assoc label (comp-labels comp) :test #'string=)))
          (unless entry (error "unresolved continue label"))
          (let ((tag (cddr entry))) (lambda (env) (declare (ignore env)) (throw tag :continue))))
        (let ((tag (cdr (first (comp-loops comp)))))
          (lambda (env) (declare (ignore env)) (throw tag :continue))))))

(defun compile-labeled (comp node)
  (let* ((label (labeled-statement-label node))
         (body (labeled-statement-body node)))
    (if (loop-statement-p body)
        ;; a labelled loop attaches LABEL to its OWN break/continue tags (via
        ;; pending-label), so `break/continue LABEL` resolve to this loop.
        (let ((c (make-comp)))
          (setf (comp-scopes c) (comp-scopes comp) (comp-strict c) (comp-strict comp)
                (comp-loops c) (comp-loops comp) (comp-labels c) (comp-labels comp)
                (comp-pending-label c) label)
          (compile-node c body))
        ;; a labelled non-loop supports only `break LABEL`
        (let ((bt (list 'break)) (c (make-comp)))
          (setf (comp-scopes c) (comp-scopes comp) (comp-strict c) (comp-strict comp)
                (comp-loops c) (comp-loops comp)
                (comp-labels c) (cons (list* label bt nil) (comp-labels comp)))
          (let ((body-fn (compile-node c body)))
            (lambda (env) (catch bt (funcall body-fn env)) :normal))))))

(defun loop-statement-p (node)
  (or (while-statement-p node) (do-while-statement-p node) (for-statement-p node)
      (for-in-statement-p node) (for-of-statement-p node)))

(defun compile-try (comp node)
  (let ((block-fn (compile-node comp (try-statement-block node)))
        (handler (try-statement-handler node))
        (finalizer (and (try-statement-finalizer node) (compile-node comp (try-statement-finalizer node)))))
    (let ((catch-fn
            (when handler
              (let* ((param (catch-clause-param handler)))
                (if param
                    (let* ((scope (make-cscope :block)))
                      (dolist (n (binding-bound-names param)) (cs-declare scope n))
                      (let ((sub (make-comp)))
                        (setf (comp-scopes sub) (cons scope (comp-scopes comp)) (comp-strict sub) (comp-strict comp)
                              (comp-loops sub) (comp-loops comp) (comp-labels sub) (comp-labels comp))
                        (let ((binder (compile-bind-target sub param))
                              (body-fn (compile-node sub (catch-clause-body handler)))
                              (count (cs-count scope)))
                          (lambda (env err) (let ((frame (new-frame count env)))
                                              (dotimes (i count)
                                                (setf (svref (env-slots frame) i) +tdz+))
                                              (funcall binder frame err) (funcall body-fn frame))))))
                    (let ((body-fn (compile-node comp (catch-clause-body handler))))
                      (lambda (env err) (declare (ignore err)) (funcall body-fn env))))))))
      (lambda (env)
        (if finalizer
            (unwind-protect
                 (if catch-fn
                     (handler-case (funcall block-fn env)
                       (js-condition (c) (funcall catch-fn env (js-condition-value c))))
                     (funcall block-fn env))
              (funcall finalizer env))
            (if catch-fn
                (handler-case (funcall block-fn env)
                  (js-condition (c) (funcall catch-fn env (js-condition-value c))))
                (funcall block-fn env)))
        :normal))))

(defun compile-with (comp node)
  ;; `with` is sloppy-only and rare; unsupported for Phase 03 (loud error, not a crash)
  (declare (ignore node))
  (lambda (env) (declare (ignore env)) (throw-type-error "with statement is not supported yet")))

;;; --- classes ---------------------------------------------------------------

(defun compile-class (comp node &optional inferred-name)
  (let* ((id (class-node-id node))
         (class-name (if id (identifier-name id) (or inferred-name "")))
         (name-scope (and id (make-cscope :block)))
         (name-index (and name-scope (cs-declare name-scope class-name)))
         (class-comp (make-comp))
         (super-node (class-node-super-class node))
         (super-present-p (not (null super-node)))
         (members (class-body-body (class-node-body node)))
         (ctor-member (find :constructor members :key #'method-definition-kind)))
    ;; A named class has a private immutable binding visible to heritage,
    ;; computed keys, and method closures. It starts in TDZ and is initialized
    ;; only after the constructor object exists.
    (when name-scope (cs-mark-immutable name-scope class-name))
    (setf (comp-scopes class-comp)
          (if name-scope (cons name-scope (comp-scopes comp)) (comp-scopes comp))
          (comp-strict class-comp) t
          (comp-labels class-comp) (comp-labels comp)
          (comp-loops class-comp) (comp-loops comp)
          (comp-module class-comp) (comp-module comp))
    (let* ((super-fn (and super-present-p (compile-node class-comp super-node)))
           (ctor-fn
             (and ctor-member
                  (compile-method class-comp (method-definition-value ctor-member)
                                  :source-node node
                                  :function-kind (if super-present-p
                                                     :derived-class
                                                     :base-class))))
           (methods
             (loop for member in members
                   unless (eq (method-definition-kind member) :constructor)
                     collect
                     (list (method-definition-static member)
                           (method-definition-kind member)
                           (class-member-key-fn class-comp member)
                           (compile-method class-comp (method-definition-value member)
                                           :source-node member)))))
      (lambda (env)
        (let* ((class-env (if name-scope (new-frame 1 env +tdz+) env))
               (super (and super-fn (funcall super-fn class-env)))
               (super-proto
                 (cond
                   ((not super-present-p) (intrinsic :object-prototype))
                   ((js-null-p super) +null+)
                   ((not (constructor-p super))
                    (throw-type-error "class extends value is not a constructor"))
                   (t
                    (let ((prototype (js-get super "prototype")))
                      (unless (or (js-object-p prototype) (js-null-p prototype))
                        (throw-type-error "superclass prototype must be an object or null"))
                      prototype))))
               (proto (js-make-object super-proto))
               (ctor
                 (if ctor-fn
                     (funcall ctor-fn class-env)
                     (if super-present-p
                         (make-native-function
                          class-name 0
                          (lambda (this args)
                            (declare (ignore this args))
                            (throw-type-error "class constructor cannot be invoked without 'new'"))
                          :construct (lambda (args new-target)
                                       (js-construct super args new-target))
                          :function-kind :derived-class)
                         (make-native-function
                          class-name 0
                          (lambda (this args)
                            (declare (ignore this args))
                            (throw-type-error "class constructor cannot be invoked without 'new'"))
                          :construct (lambda (args new-target)
                                       (declare (ignore args))
                                       (js-make-object (nt-prototype new-target proto)))
                          :function-kind :base-class)))))
          (set-callable-home-object ctor proto)
          (define-property-or-throw
           ctor "prototype"
           (data-pd proto :writable nil :enumerable nil :configurable nil))
          (define-property-or-throw
           proto "constructor"
           (data-pd ctor :writable t :enumerable nil :configurable t))
          (when (constructor-p super)
            (unless (jm-set-prototype-of ctor super)
              (throw-type-error "cannot set class constructor prototype")))
          (set-function-name ctor class-name)
          (when name-scope
            (frame-init class-env 0 name-index ctor))
          ;; Method definitions are observable and therefore remain sequential:
          ;; compute the key, instantiate the closure, then define the property.
          (dolist (method methods)
            (destructuring-bind (static kind key-fn fn-fn) method
              (let* ((target (if static ctor proto))
                     (key (funcall key-fn class-env))
                     (function (funcall fn-fn class-env)))
                (set-callable-home-object function target)
                (set-function-name function key
                                   (case kind (:get "get") (:set "set")))
                (case kind
                  (:get
                   (define-property-or-throw
                    target key
                    (accessor-pd function (accessor-existing target key :set)
                                 :enumerable nil :configurable t)))
                  (:set
                   (define-property-or-throw
                    target key
                    (accessor-pd (accessor-existing target key :get) function
                                 :enumerable nil :configurable t)))
                  (t
                   (define-property-or-throw
                    target key
                    (data-pd function :writable t :enumerable nil :configurable t)))))))
          ctor)))))

(defun accessor-existing (obj key which)
  (let ((d (obj-own-desc obj key)))
    (if (and d (accessor-descriptor-p d)) (if (eq which :get) (pd-get d) (pd-set d)) +undefined+)))

(defun class-member-key-fn (comp m)
  (let ((key (method-definition-key m)))
    (if (method-definition-computed m)
        (let ((f (compile-node comp key))) (lambda (env) (to-property-key (funcall f env))))
        (let ((k (property-key-string key))) (lambda (env) (declare (ignore env)) k)))))
