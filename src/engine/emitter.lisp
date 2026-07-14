;;;; emitter.lisp — compile analyzed AST -> CL closures (PLAN.md Phase 03, §1/§5).
;;;; Each node compiles ONCE to a closure. Expression closures take a runtime env and
;;;; return a js-value; statement closures execute for effect and use CL catch/throw
;;;; tags for break/continue/return and the js-condition bridge for throw.

(in-package :clun.engine)

;;; --- compile-time context ---------------------------------------------------

(defstruct (cscope (:conc-name cs-) (:constructor make-cscope (kind)))
  (names (make-hash-table :test 'equal))
  (count 0)
  (imports nil)                  ; name -> t for ESM import slots (deref via thunk, Phase 07)
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

(defun resolved-import-p (comp depth name)
  "True iff NAME, resolved to :local at DEPTH in COMP, lands on an import slot.
Because comp-resolve returns the INNERMOST binding, a shadowing local (in a closer
scope) makes this NIL automatically — the shadowing scope has no import mark."
  (let* ((scope (nth depth (comp-scopes comp)))
         (imps (and scope (cs-imports scope))))
    (and imps (gethash name imps))))

(defvar *current-return-tag* nil
  "The CL catch tag `return` throws to; bound while a function body is compiled.")

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
        (lambda (env) (frame-ref env depth index "this"))
        (lambda (env) (declare (ignore env)) (realm-global *realm*)))))

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
            (values (lambda (env) (frame-ref env depth index name))
                    (lambda (env v) (frame-set env depth index v))))
           (t (let ((strict (comp-strict comp)))
                (values (lambda (env) (declare (ignore env)) (global-get name))
                        (lambda (env v) (declare (ignore env)) (global-set name v strict)))))))))
    (member-expression
     (let ((obj-fn (compile-node comp (member-expression-object node))))
       (if (member-expression-computed node)
           (let ((prop-fn (compile-node comp (member-expression-property node))))
             (values (lambda (env) (js-getv (funcall obj-fn env) (to-property-key (funcall prop-fn env))))
                     (lambda (env v) (let ((o (funcall obj-fn env)))
                                       (js-set (to-object o) (to-property-key (funcall prop-fn env)) v (comp-strict comp))))))
           (let ((key (identifier-name (member-expression-property node)))
                 (cache (%make-ic)))
             (values (lambda (env) (%ic-read (funcall obj-fn env) key cache))
                     (lambda (env v) (js-set (to-object (funcall obj-fn env)) key v (comp-strict comp))))))))
    (t (values (lambda (env) (declare (ignore env)) (throw-reference-error "invalid reference"))
               (lambda (env v) (declare (ignore env v)) (throw-syntax-error "invalid assignment target"))))))

;;; --- member / call / new ----------------------------------------------------

(defun compile-member (comp node)
  (let ((obj-fn (compile-node comp (member-expression-object node))))
    (if (member-expression-computed node)
        (let ((prop-fn (compile-node comp (member-expression-property node))))
          (lambda (env) (js-getv (funcall obj-fn env) (to-property-key (funcall prop-fn env)))))
        (let ((key (identifier-name (member-expression-property node)))
              (cache (%make-ic)))                ; per-site monomorphic read inline cache
          (lambda (env) (%ic-read (funcall obj-fn env) key cache))))))

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
    (cond
      ;; method call: preserve `this`
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
           (lambda (env) (js-call (funcall fn env) +undefined+ (funcall args-fn env))))))))

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
  (if (member-expression-p arg)
      (let ((obj-fn (compile-node comp (member-expression-object arg))))
        (if (member-expression-computed arg)
            (let ((prop-fn (compile-node comp (member-expression-property arg))))
              (lambda (env) (js-boolean (jm-delete (to-object (funcall obj-fn env))
                                                   (to-property-key (funcall prop-fn env))))))
            (let ((key (identifier-name (member-expression-property arg))))
              (lambda (env) (js-boolean (jm-delete (to-object (funcall obj-fn env)) key))))))
      (lambda (env) (declare (ignore env)) +true+)))    ; delete of a non-reference -> true

(defun compile-update (comp node)
  (let ((op (update-expression-operator node)) (prefix (update-expression-prefix node)))
    (multiple-value-bind (get set) (compile-reference comp (update-expression-argument node))
      (let ((step (if (string= op "++") 1 -1)))
        (lambda (env)
          ;; ToNumeric so `let x=1n; x++` stays a BigInt (not a TypeError via to-number).
          (let* ((old (to-numeric (funcall get env)))
                 (new (if (integerp old) (+ old step)
                          (with-js-floats (+ old (coerce step 'double-float))))))
            (funcall set env new)
            (if prefix new old)))))))

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
    (if (string= op "&&")
        (lambda (env) (let ((a (funcall l env))) (if (js-truthy a) (funcall r env) a)))
        (lambda (env) (let ((a (funcall l env))) (if (js-truthy a) a (funcall r env)))))))

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
        (if (or (array-pattern-p target) (object-pattern-p target))
            (compile-destructuring-assignment comp target (assignment-expression-right node))
            (multiple-value-bind (get set) (compile-reference comp target)
              (declare (ignore get))
              (let ((rhs (compile-named-value comp (assignment-expression-right node)
                                              (and (identifier-p target) (identifier-name target)))))
                (lambda (env) (let ((v (funcall rhs env))) (funcall set env v) v)))))
        (multiple-value-bind (get set) (compile-reference comp target)
          (let ((rhs (compile-node comp (assignment-expression-right node)))
                (binop (subseq op 0 (1- (length op)))))
            (lambda (env)
              (let* ((a (funcall get env)) (d (funcall rhs env))
                     (v (apply-binop binop a d)))
                (funcall set env v) v)))))))

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
                       (create-data-property a (princ-to-string i) v) (incf i)))
            (:one (create-data-property a (princ-to-string i) (funcall fn env)) (incf i))))
        (js-set a "length" (coerce i 'double-float) t)
        a))))

(defun compile-object (comp node)
  (let ((parts (mapcar (lambda (p) (compile-object-property comp p))
                       (object-expression-properties node))))
    (lambda (env)
      (let ((o (new-object)))
        (dolist (p parts o) (funcall p env o))))))

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
            (let ((fn-fn (compile-method comp (property-value prop))))
              (lambda (env o)
                (let ((k (if computed (to-property-key (funcall key-fn env)) static-key))
                      (f (funcall fn-fn env)))
                  (let ((existing (obj-own-desc o k)))
                    (jm-define-own-property o k
                      (if (eq kind :get)
                          (accessor-pd f (if (and existing (accessor-descriptor-p existing)) (pd-set existing) +undefined+))
                          (accessor-pd (if (and existing (accessor-descriptor-p existing)) (pd-get existing) +undefined+) f))))))))
           (t (let ((val-fn (compile-node comp (property-value prop))))
                (lambda (env o)
                  (let ((k (if computed (to-property-key (funcall key-fn env)) static-key)))
                    (create-data-property o k (funcall val-fn env)))))))))))

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

(defun compile-tagged-template (comp node)
  (declare (ignore comp node))
  (lambda (env) (declare (ignore env)) (throw-type-error "tagged templates not supported yet")))

;;; --- iteration helpers ------------------------------------------------------

(defun iterable->list (obj)
  (cond ((js-array-p obj) (loop for i below (array-length obj) collect (js-getv obj (princ-to-string i))))
        ((stringp obj) (map 'list #'string obj))
        (t (iterable->list-protocol obj))))

(defun iterable->list-protocol (obj)
  (when (js-nullish-p obj) (throw-type-error "value is not iterable"))
  (let ((iter-fn (get-method obj (well-known :iterator))))
    (when (js-undefined-p iter-fn) (throw-type-error "value is not iterable"))
    (let ((iter (js-call iter-fn obj '())))
      (unless (js-object-p iter) (throw-type-error "iterator is not an object"))
      (let ((next (js-get iter "next")) (result '()))
        (unless (callable-p next) (throw-type-error "iterator.next is not a function"))
        (loop (let ((r (js-call next iter '())))
                (unless (js-object-p r) (throw-type-error "iterator result is not an object"))
                (when (js-truthy (js-get r "done")) (return (nreverse result)))
                (push (js-get r "value") result)))))))

;;; --- binding targets (params, declarations, destructuring) ------------------

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
           (default (compile-node comp (assignment-pattern-right target))))
       (lambda (env value) (funcall inner env (if (js-undefined-p value) (funcall default env) value)))))
    (rest-element (compile-bind-target comp (rest-element-argument target)))
    (array-pattern
     (let ((binders (loop for e in (array-pattern-elements target) for i from 0
                          collect (cons (and (rest-element-p e) :rest)
                                        (if e (compile-bind-target comp e) nil))
                          into acc
                          finally (return acc))))
       (lambda (env value)
         (let ((items (if (js-nullish-p value)
                          (throw-type-error "cannot destructure null or undefined")
                          (iterable->list value)))
               (i 0))
           (dolist (b binders)
             (cond ((eq (car b) :rest)
                    (when (cdr b) (funcall (cdr b) env (new-array (nthcdr i items)))))
                   ((cdr b) (funcall (cdr b) env (or (nth i items) +undefined+)) (incf i))
                   (t (incf i))))))))
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

(defun compile-assign-target (comp target)
  (typecase target
    ((or identifier member-expression)
     (multiple-value-bind (get set) (compile-reference comp target)
       (declare (ignore get)) (lambda (env value) (funcall set env value))))
    (assignment-pattern
     (let ((inner (compile-assign-target comp (assignment-pattern-left target)))
           (default (compile-node comp (assignment-pattern-right target))))
       (lambda (env value) (funcall inner env (if (js-undefined-p value) (funcall default env) value)))))
    (rest-element (compile-assign-target comp (rest-element-argument target)))
    (array-pattern
     (let ((binders (loop for e in (array-pattern-elements target)
                          collect (cons (and (rest-element-p e) :rest) (and e (compile-assign-target comp e))))))
       (lambda (env value)
         (let ((items (iterable->list value)) (i 0))
           (dolist (b binders)
             (cond ((eq (car b) :rest) (when (cdr b) (funcall (cdr b) env (new-array (nthcdr i items)))))
                   ((cdr b) (funcall (cdr b) env (or (nth i items) +undefined+)) (incf i))
                   (t (incf i))))))))
    (object-pattern
     (let ((binders (loop for pr in (object-pattern-properties target)
                          collect (if (rest-element-p pr)
                                      (cons :rest (compile-assign-target comp (rest-element-argument pr)))
                                      (cons (property-key-target comp pr)
                                            (compile-assign-target comp (property-value pr)))))))
       (lambda (env value)
         (let ((o (to-object value)))
           (dolist (b binders)
             (if (eq (car b) :rest) (funcall (cdr b) env (new-object))
                 (funcall (cdr b) env (js-getv o (funcall (car b) env)))))))))
    (t (error "bad assignment target"))))

;;; --- functions --------------------------------------------------------------

(defun function-body-strict-p (block)
  (dolist (s (block-statement-body block) nil)
    (if (and (expression-statement-p s) (expression-statement-directive s))
        (when (string= (expression-statement-directive s) "use strict") (return t))
        (return nil))))

(defun compile-function-common (comp params body fname &key arrow method generator async)
  "Return (lambda (env) -> js-function). Sets up the function scope and body closure.
GENERATOR/ASYNC bodies run in a coroutine (Phase 06): a hidden %coro% frame slot holds
the live coroutine that yield/await suspend."
  (let* ((strict (or (comp-strict comp) (function-body-strict-p body)))
         (scope (make-cscope :function))
         (stmts (block-statement-body body))
         (coro-p (or generator async)))  ; generator/async bodies run in a coroutine
    ;; reserved bindings
    (let ((this-idx (unless arrow (cs-declare scope "%this%")))
          (nt-idx (unless arrow (cs-declare scope "%new.target%")))
          (args-idx (unless arrow (cs-declare scope "arguments")))
          (coro-idx (when coro-p (cs-declare scope "%coro%"))))
      ;; parameters
      (let ((param-binders '()) (simple-params (every #'identifier-p params)))
        ;; declare param names in the scope
        (dolist (p params) (dolist (n (binding-bound-names p)) (cs-declare scope n)))
        ;; hoisted vars / funcs / lexicals of the body
        (multiple-value-bind (vars funcs) (collect-var-names stmts)
          (dolist (n vars) (cs-declare scope n))
          (dolist (n funcs) (cs-declare scope n))
          (dolist (n (collect-lexical-names stmts)) (cs-declare scope n))
          (let ((sub (make-comp)) (return-tag (gensym "RET")))
            (setf (comp-scopes sub) (cons scope (comp-scopes comp))
                  (comp-strict sub) strict)
            ;; compile param binders + body with this function's return tag active
            (let ((*current-return-tag* return-tag))
             (setf param-binders
                  (loop for p in params for i from 0
                        collect (if (rest-element-p p)
                                    (cons :rest (compile-bind-target sub (rest-element-argument p)))
                                    (cons i (compile-bind-target sub p)))))
             (let* ((lexical-idxs (loop for n in (collect-lexical-names stmts)
                                       collect (gethash n (cs-names scope))))
                   (func-decls (collect-function-decls stmts))
                   (func-compiled (loop for fd in func-decls
                                        collect (cons (gethash (identifier-name (function-node-id fd)) (cs-names scope))
                                                      (compile-function-common sub (function-node-params fd)
                                                                               (function-node-body fd)
                                                                               (identifier-name (function-node-id fd))
                                                                               :generator (function-node-generator fd)
                                                                               :async (function-node-async fd)))))
                   (body-fn (compile-seq sub stmts))
                   ;; read AFTER the body is compiled: set iff `arguments` was referenced (m5)
                   (needs-args (and (not arrow) (cs-uses-arguments scope)))
                   (count (cs-count scope))
                   (this-mode (cond (arrow :lexical) (strict :strict) (t :global))))
              (declare (ignore method))
              (lambda (defenv)
                (labels ((setup-frame (this args new-target)
                           (let ((frame (new-frame count defenv)))
                             (unless arrow
                               (setf (svref (env-slots frame) this-idx) (coerce-this this this-mode)
                                     (svref (env-slots frame) nt-idx) new-target)
                               ;; build the `arguments` object ONLY if the body references it (m5):
                               ;; skipping it for the common case avoids an object allocation per call.
                               (when needs-args
                                 (setf (svref (env-slots frame) args-idx) (make-arguments-object args))))
                             (dolist (li lexical-idxs) (setf (svref (env-slots frame) li) +tdz+))
                             (bind-parameters param-binders args frame simple-params)
                             (dolist (fc func-compiled)
                               (setf (svref (env-slots frame) (car fc)) (funcall (cdr fc) frame)))
                             frame))
                         (run-body (frame) (catch return-tag (funcall body-fn frame) +undefined+)))
                  (instantiate-function
                   (cond
                     ((and generator async)
                      (lambda (fn this args new-target)
                        (declare (ignore fn))
                        (let ((frame (setup-frame this args new-target)))
                          (let ((co (make-coroutine (lambda () (run-body frame)))))
                            (setf (svref (env-slots frame) coro-idx) co)
                            (make-async-generator co)))))
                     (generator
                      (lambda (fn this args new-target)
                        (let ((frame (setup-frame this args new-target)))
                          (let ((co (make-coroutine (lambda () (run-body frame)))))
                            (setf (svref (env-slots frame) coro-idx) co)
                            (make-generator fn co)))))
                     (async
                      (lambda (fn this args new-target)
                        (declare (ignore fn))
                        (let ((frame (setup-frame this args new-target)))
                          (let ((co (make-coroutine (lambda () (run-body frame)))))
                            (setf (svref (env-slots frame) coro-idx) co)
                            (drive-async-function co)))))
                     (t
                      (lambda (fn this args new-target)
                        (declare (ignore fn))
                        (run-body (setup-frame this args new-target)))))
                   defenv
                   :fname fname :param-count (count-if (lambda (p) (and (identifier-p p))) params)
                   :strict strict :this-mode this-mode
                   :constructable (and (not arrow) (not coro-p))
                   :kind (cond (generator :generator)
                               ((or arrow method) :method) (t :normal)))))))))))))

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

(defun make-arguments-object (args)
  (let ((o (js-make-object (intrinsic :object-prototype) :arguments)))
    (loop for a in args for i from 0 do (create-data-property o (princ-to-string i) a))
    (obj-set-desc o "length" (data-pd (coerce (length args) 'double-float)
                                      :writable t :enumerable nil :configurable t))
    o))

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
  (compile-function-common comp (function-node-params node) (function-node-body node)
                           (if (function-node-id node) (identifier-name (function-node-id node)) "")
                           :generator (function-node-generator node)
                           :async (function-node-async node)))

(defun compile-arrow (comp node &optional (name ""))
  (let ((body (arrow-function-body node)))
    (if (block-statement-p body)
        (compile-function-common comp (arrow-function-params node) body name :arrow t
                                 :async (arrow-function-async node))
        ;; expression-bodied arrow: wrap the expression in a return
        (compile-function-common comp (arrow-function-params node)
                                 (make-block-statement :body (list (make-return-statement :argument body)))
                                 name :arrow t :async (arrow-function-async node)))))

(defun anon-fn-node-p (node)
  "An anonymous function/arrow/class expression eligible for NamedEvaluation."
  (or (arrow-function-p node)
      (and (function-node-p node) (null (function-node-id node)))
      (and (class-node-p node) (null (class-node-id node)))))

(defun compile-named-value (comp node name)
  "Like compile-node, but names an anonymous function/arrow after NAME (§ NamedEvaluation)."
  (cond
    ((or (null name) (string= name "")) (compile-node comp node))
    ((arrow-function-p node) (compile-arrow comp node name))
    ((and (function-node-p node) (null (function-node-id node)))
     (compile-function-common comp (function-node-params node) (function-node-body node) name
                               :generator (function-node-generator node)
                               :async (function-node-async node)))
    (t (compile-node comp node))))

(defun compile-method (comp fn-node)
  (compile-function-common comp (function-node-params fn-node) (function-node-body fn-node) "" :method t
                           :generator (function-node-generator fn-node)
                           :async (function-node-async fn-node)))

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
        (coro-ref (compile-coro-ref comp)))
    (if (yield-expression-delegate node)
        (lambda (env)
          (%yield-delegate (funcall coro-ref env) (get-iterator (funcall arg-fn env))))
        (lambda (env)
          (coroutine-suspend (funcall coro-ref env) :yield
                             (if arg-fn (funcall arg-fn env) +undefined+))))))

(defun compile-await (comp node)
  (let ((arg-fn (compile-node comp (await-expression-argument node)))
        (coro-ref (compile-coro-ref comp)))
    (lambda (env) (await-value (funcall coro-ref env) (funcall arg-fn env)))))

;;; --- lazy iterator protocol (yield*, for-of/for-await) -----------------------

(defun get-iterator (obj &optional async)
  "Returns (values iterator async-from-sync-p). ASYNC-FROM-SYNC-P is true when an
async iterator was requested but only a sync @@iterator exists — the caller must
then Await each yielded value (§27.1.4.1)."
  (let ((iter-fn (and async (get-method obj (well-known :async-iterator)))))
    (when (or (null iter-fn) (js-undefined-p iter-fn))
      (let ((sync-fn (get-method obj (well-known :iterator))))
        (when (js-undefined-p sync-fn) (throw-type-error "value is not iterable"))
        (let ((iter (js-call sync-fn obj '())))
          (unless (js-object-p iter) (throw-type-error "iterator is not an object"))
          (return-from get-iterator (values iter async)))))
    (let ((iter (js-call iter-fn obj '())))
      (unless (js-object-p iter) (throw-type-error "iterator is not an object"))
      (values iter nil))))

(defun iterator-step (iter &optional (value +undefined+))
  "Call iter.next(value); returns the result object (validated)."
  (let ((r (js-call (js-get iter "next") iter (list value))))
    (unless (js-object-p r) (throw-type-error "iterator result is not an object"))
    r))

(defun %yield-delegate (co iter)
  "yield* (§15.5.5): forward next/throw/return to the inner iterator, yielding each
value to the outer driver and returning the inner iterator's final value."
  (let ((sent (cons :next +undefined+)))
    (loop
      (let* ((mode (car sent)) (v (cdr sent))
             (result
              (ecase mode
                (:next (iterator-step iter v))
                (:throw
                 (let ((m (js-get iter "throw")))
                   (if (callable-p m) (js-call m iter (list v))
                       (progn (%iterator-close iter) (throw-type-error "iterator has no throw method")))))
                (:return
                 (let ((m (js-get iter "return")))
                   (if (callable-p m) (js-call m iter (list v))
                       (throw *coroutine-return-tag* (cons :return v))))))))
        (unless (js-object-p result) (throw-type-error "iterator result is not an object"))
        (when (js-truthy (js-get result "done"))
          (let ((rv (js-get result "value")))
            ;; a forwarded .return whose inner iterator finished completes the outer generator
            (if (eq mode :return) (throw *coroutine-return-tag* (cons :return rv)) (return rv))))
        (setf sent (coroutine-suspend-raw co (js-get result "value")))))))

(defun %iterator-close (iter)
  (let ((m (js-get iter "return")))
    (when (callable-p m) (ignore-errors (js-call m iter '())))))

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
                                                                                 :async (function-node-async fd)))))
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
    (declare (ignore kind))
    (lambda (env)
      (dolist (b binders :normal)
        (when (or (cdr b) t)
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
      (when lexical (dolist (n names) (cs-declare scope n)))
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
              (multiple-value-bind (iter from-sync) (get-iterator (funcall right-fn env) t)
                ;; IteratorClose on abrupt completion: break/return/throw must call the
                ;; iterator's return() so lazy sources (e.g. timers/promises setInterval)
                ;; release their resources. DONE-NORMALLY is set only on exhaustion.
                (let ((done-normally nil))
                  (unwind-protect
                       (catch bt
                         (loop
                           (let ((result (await-value co (iterator-step iter))))
                             (unless (js-object-p result) (throw-type-error "iterator result is not an object"))
                             (when (js-truthy (js-get result "done")) (return))
                             ;; async-from-sync: Await the value too (§27.1.4.1); a native
                             ;; async iterator yields already-settled values (no re-Await).
                             (let ((val (if from-sync (await-value co (js-get result "value")) (js-get result "value")))
                                   (frame (if lexical (new-frame count env) env)))
                               (funcall binder frame val)
                               (catch ct (funcall body-fn frame)))))
                         (setf done-normally t))
                    (unless done-normally
                      ;; IteratorClose: suppress errors from BOTH get(return) and return()
                      ;; itself — when unwinding a throw the ORIGINAL must propagate (test262
                      ;; iterator-close-throw-get-method-abrupt), and on break/return freeing
                      ;; the source best-effort beats leaking it. (get(return) is inside the
                      ;; ignore-errors, not just the call — a throwing return getter must not
                      ;; escape the cleanup and mask the in-flight completion.)
                      (ignore-errors
                       (let ((m (js-get iter "return")))
                         (when (callable-p m) (js-call m iter '()))))))))
              :normal)))))))

(defun compile-for-each (comp node left right body kind)
  (declare (ignore node))
  (with-loop (comp bt ct)
    (let* ((lexical (and (variable-declaration-p left) (member (variable-declaration-kind left) '(:let :const))))
           (names (when lexical (loop for d in (variable-declaration-declarations left)
                                      append (binding-bound-names (variable-declarator-id d)))))
           (scope (when lexical (make-cscope :block))))
      (when lexical (dolist (n names) (cs-declare scope n)))
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
            (let* ((rv (funcall right-fn env))
                   (items (if (eq kind :in)
                              (if (js-nullish-p rv) '() (for-in-keys (to-object rv)))
                              (iterable->list rv))))
              (catch bt
                (dolist (item items)
                  (let ((frame (if lexical (new-frame count env) env)))
                    (funcall binder frame item)
                    (catch ct (funcall body-fn frame)))))
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
  (with-loop (comp bt ct)
    (declare (ignore ct))
    (let* ((disc (compile-node comp (switch-statement-discriminant node)))
           (cases (loop for c in (switch-statement-cases node)
                        collect (list (and (switch-case-test c) (compile-node comp (switch-case-test c)))
                                      (compile-seq comp (switch-case-consequent c))))))
      (lambda (env)
        (let ((d (funcall disc env)))
          (catch bt
            (let ((matched nil))
              (dolist (c cases)
                (when (and (not matched) (first c) (js-strict-eq d (funcall (first c) env)))
                  (setf matched t))
                (when matched (funcall (second c) env)))
              (unless matched                 ; run default and following
                (let ((run nil))
                  (dolist (c cases)
                    (when (null (first c)) (setf run t))
                    (when run (funcall (second c) env))))))))
        :normal))))

(defun compile-return (comp node)
  (let ((arg (and (return-statement-argument node) (compile-node comp (return-statement-argument node))))
        (tag (comp-return-tag comp)))
    (lambda (env) (throw tag (if arg (funcall arg env) +undefined+)))))

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

;;; --- classes (basic: constructor + methods + extends) -----------------------

(defun compile-class (comp node)
  (let* ((super-fn (and (class-node-super-class node) (compile-node comp (class-node-super-class node))))
         (members (class-body-body (class-node-body node)))
         (ctor-m (find :constructor members :key #'method-definition-kind))
         (ctor-fn (and ctor-m (compile-method comp (method-definition-value ctor-m))))
         (id (class-node-id node))
         (methods (loop for m in members
                        unless (eq (method-definition-kind m) :constructor)
                        collect (list (method-definition-static m)
                                      (method-definition-kind m)
                                      (class-member-key-fn comp m)
                                      (compile-method comp (method-definition-value m))))))
    (lambda (env)
      (let* ((super (and super-fn (funcall super-fn env)))
             (super-proto (cond ((null super-fn) (intrinsic :object-prototype))
                                ((js-null-p super) +null+)
                                ((js-object-p super) (js-get super "prototype"))
                                (t (throw-type-error "class extends value is not a constructor"))))
             (proto (js-make-object super-proto))
             (ctor (if ctor-fn (funcall ctor-fn env)
                       (make-native-function (if id (identifier-name id) "") 0
                         (lambda (this args)
                           (when super (js-construct super args))
                           this)
                         ;; default ctor: a DERIVED class binds `this` to super()'s
                         ;; return (new-target threaded so the instance gets this
                         ;; class's prototype) — else builtin subclasses (Promise,
                         ;; Error, …) lose their exotic/struct identity.
                         :construct (lambda (args nt)
                                      (if super
                                          (js-construct super args nt)
                                          (js-make-object proto)))))))
        (when (js-function-p ctor)
          (setf (js-function-home-object ctor) proto))
        (obj-set-desc ctor "prototype" (data-pd proto :writable nil :enumerable nil :configurable nil))
        (obj-set-desc proto "constructor" (data-pd ctor :writable t :enumerable nil :configurable t))
        (when (js-object-p super) (jm-set-prototype-of ctor super))
        (obj-set-desc ctor "name" (data-pd (if id (identifier-name id) "") :writable nil :enumerable nil :configurable t))
        (dolist (m methods)
          (destructuring-bind (static kind key-fn fn-fn) m
            (let ((target (if static ctor proto)) (k (funcall key-fn env)) (f (funcall fn-fn env)))
              (case kind
                (:get (obj-set-desc target k (accessor-pd f (accessor-existing target k :set) :enumerable nil)))
                (:set (obj-set-desc target k (accessor-pd (accessor-existing target k :get) f :enumerable nil)))
                (t (obj-set-desc target k (data-pd f :writable t :enumerable nil :configurable t)))))))
        ctor))))

(defun accessor-existing (obj key which)
  (let ((d (obj-own-desc obj key)))
    (if (and d (accessor-descriptor-p d)) (if (eq which :get) (pd-get d) (pd-set d)) +undefined+)))

(defun class-member-key-fn (comp m)
  (let ((key (method-definition-key m)))
    (if (method-definition-computed m)
        (let ((f (compile-node comp key))) (lambda (env) (to-property-key (funcall f env))))
        (let ((k (property-key-string key))) (lambda (env) (declare (ignore env)) k)))))
