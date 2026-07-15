;;;; compile-source.lisp — Phase 25 COMPILE tier (m1): a SECOND emitter backend that, for a coverable
;;;; function body, generates ONE CL source form and cl:compiles it into a single native body-fn,
;;;; instead of the tree of per-node closures the default backend builds. It reuses every existing
;;;; runtime primitive (frame-ref/frame-set, %ic-read/%ic-write, js-getv/js-set, js-call, js-add & the
;;;; operators, js-truthy, the catch/throw return protocol) — no new semantics; the generated body is a
;;;; transcription of the closure backend, so it must be OBSERVABLY IDENTICAL. Non-coverable shapes fall
;;;; back to the closure tree, so the tier is purely additive and correctness is the interpreter's.
;;;; See docs/design/phase-25-compile-tier.md. m1 proves the mechanism on a small subset; m2 widens it
;;;; to cover deltablue and measures the eager ceiling (the decision gate).

(in-package :clun.engine)

(defvar *compile-tier-mode* :off
  ":off — closure tree only (default/production for now). :eager — compile every COVERABLE user
function's body at definition time (synchronous), for the differential coverage shake-out + the ceiling
measurement. :threshold — (future m3) background tier-up. Only :off and :eager exist in m1.")

;;; --- consts: compile-time data referenced from the generated body ----------
;;; The generated body is compiled in the null lexical environment, so live objects it must reference
;;; (per-site IC cells, the return tag, arbitrary JS literal values) are collected into a vector and
;;; reached at run time via (svref %consts K) — where %consts is bound by an outer lambda we funcall.

(defvar *cs-consts* nil "Adjustable vector of compile-time constants, bound during source generation.")

(defun cs-const (x)
  "Record X and return the source form that fetches it at run time."
  (vector-push-extend x *cs-consts*)
  `(svref %consts ,(1- (fill-pointer *cs-consts*))))

;;; --- coverability: decided once, conservatively (fall back when unsure) -----

(defun cs-simple-params-p (params)
  (every #'identifier-p params))

(defun cs-node-coverable-p (node)
  "Walk NODE; T iff every subnode is in the m1 source-backend subset. Conservative: anything not
explicitly handled makes the whole function fall back to the closure tree."
  (labels ((ok (n) (cs-node-coverable-p n))
           (all (ns) (every #'ok ns)))
    (typecase node
      (null t)
      (literal t)
      (this-expression t)
      (identifier (not (string= (identifier-name node) "arguments")))  ; arguments not covered in m1
      (member-expression (and (ok (member-expression-object node))
                              (or (not (member-expression-computed node))
                                  (ok (member-expression-property node)))))
      (binary-expression (and (ok (binary-expression-left node)) (ok (binary-expression-right node))))
      (logical-expression (and (ok (logical-expression-left node)) (ok (logical-expression-right node))))
      (unary-expression (and (member (unary-expression-operator node) '("!" "-" "+" "~" "void" "typeof")
                                     :test #'string=)
                             (ok (unary-expression-argument node))))
      (conditional-expression (and (ok (conditional-expression-test node))
                                   (ok (conditional-expression-consequent node))
                                   (ok (conditional-expression-alternate node))))
      (call-expression (and (ok (call-expression-callee node))
                            (notany #'spread-element-p (call-expression-arguments node))
                            (all (call-expression-arguments node))))
      (assignment-expression
       (and (string= (assignment-expression-operator node) "=")   ; compound ops not covered in m1
            (let ((tgt (assignment-expression-left node)))
              (or (identifier-p tgt)
                  (and (member-expression-p tgt) (ok tgt))))
            (ok (assignment-expression-right node))))
      (expression-statement (ok (expression-statement-expression node)))
      (block-statement (all (block-statement-body node)))
      (if-statement (and (ok (if-statement-test node)) (ok (if-statement-consequent node))
                         (ok (if-statement-alternate node))))
      (return-statement (ok (return-statement-argument node)))
      (empty-statement t)
      (t nil))))

(defun cs-compilable-p (params stmts)
  "T iff a function with these params + body statements is coverable by the m1 source backend."
  (and (cs-simple-params-p params)
       (every #'cs-node-coverable-p stmts)))

;;; --- source generation: node -> CL form (given `env` + `%consts`) ----------

(defun cs-node (comp node)
  "Return a CL FORM that, evaluated with the runtime frame bound to `env` and the consts vector to
`%consts`, computes NODE's JS value (or runs the statement for effect). Mirrors compile-* in emitter.lisp
using the SAME runtime primitives. Assumes NODE is coverable (checked by cs-compilable-p)."
  (typecase node
    (literal (cs-const (literal-value node)))
    (this-expression
     (multiple-value-bind (kind depth index) (comp-resolve comp "%this%")
       (if (eq kind :local) `(frame-ref env ,depth ,index "this") `(realm-global *realm*))))
    (identifier
     (let ((name (identifier-name node)))
       (multiple-value-bind (kind depth index) (comp-resolve comp name)
         (cond ((and (eq kind :local) (resolved-import-p comp depth name))
                `(funcall (frame-ref env ,depth ,index ,name)))
               ((eq kind :local) `(frame-ref env ,depth ,index ,name))
               (t `(global-get ,name))))))
    (member-expression
     (let ((obj (cs-node comp (member-expression-object node))))
       (if (member-expression-computed node)
           `(js-getv ,obj (to-property-key ,(cs-node comp (member-expression-property node))))
           `(%ic-read ,obj ,(identifier-name (member-expression-property node)) ,(cs-const (%make-ic))))))
    (unary-expression
     (let ((op (unary-expression-operator node)) (arg (unary-expression-argument node)))
       (if (and (string= op "typeof") (identifier-p arg))
           (multiple-value-bind (kind depth index) (comp-resolve comp (identifier-name arg))
             (if (eq kind :local) `(js-typeof (frame-ref env ,depth ,index ,(identifier-name arg)))
                 `(global-typeof ,(identifier-name arg))))
           (let ((a (cs-node comp arg)))
             (cond ((string= op "!") `(js-boolean (not (js-truthy ,a))))
                   ((string= op "-") `(js-neg ,a))
                   ((string= op "+") `(js-unary-plus ,a))
                   ((string= op "~") `(js-bit-not ,a))
                   ((string= op "void") `(progn ,a +undefined+))
                   ((string= op "typeof") `(js-typeof ,a)))))))
    (binary-expression
     (cs-binop (binary-expression-operator node)
               (cs-node comp (binary-expression-left node))
               (cs-node comp (binary-expression-right node))))
    (logical-expression
     (let ((l (cs-node comp (logical-expression-left node)))
           (r (cs-node comp (logical-expression-right node)))
           (op (logical-expression-operator node)))
       (cond ((string= op "&&") `(let ((v ,l)) (if (js-truthy v) ,r v)))
             ((string= op "||") `(let ((v ,l)) (if (js-truthy v) v ,r)))
             ((string= op "??") `(let ((v ,l)) (if (js-nullish-p v) ,r v))))))
    (conditional-expression
     `(if (js-truthy ,(cs-node comp (conditional-expression-test node)))
          ,(cs-node comp (conditional-expression-consequent node))
          ,(cs-node comp (conditional-expression-alternate node))))
    (call-expression
     (let* ((callee (call-expression-callee node))
            (args `(list ,@(mapcar (lambda (a) (cs-node comp a)) (call-expression-arguments node)))))
       (if (member-expression-p callee)
           (let ((obj (cs-node comp (member-expression-object callee))))
             (if (member-expression-computed callee)
                 `(let* ((o ,obj) (f (js-getv o (to-property-key ,(cs-node comp (member-expression-property callee))))))
                    (js-call f o ,args))
                 `(let* ((o ,obj) (f (%ic-read o ,(identifier-name (member-expression-property callee))
                                               ,(cs-const (%make-ic)))))
                    (js-call f o ,args))))
           `(js-call ,(cs-node comp callee) +undefined+ ,args))))
    (assignment-expression
     ;; compile-assignment binds the RHS value FIRST, then evaluates the target reference — so every
     ;; branch here is `(let ((val <rhs>)) <store> val)`, matching the closure backend's eval order.
     (let ((tgt (assignment-expression-left node)) (v (cs-node comp (assignment-expression-right node))))
       (if (identifier-p tgt)
           (let ((name (identifier-name tgt)))
             (multiple-value-bind (kind depth index) (comp-resolve comp name)
               `(let ((val ,v))
                  ,(cond ((and (eq kind :local) (resolved-import-p comp depth name))
                          `(throw-type-error "Assignment to constant variable."))
                         ((eq kind :local) `(frame-set env ,depth ,index val))
                         (t `(global-set ,name val ,(comp-strict comp))))
                  val)))
           ;; member target: RHS, then object, then (computed) property, then store.
           (let ((obj (cs-node comp (member-expression-object tgt))))
             (if (member-expression-computed tgt)
                 `(let* ((val ,v) (o (to-object ,obj))
                         (k (to-property-key ,(cs-node comp (member-expression-property tgt)))))
                    (js-set o k val ,(comp-strict comp))
                    val)
                 `(let* ((val ,v))
                    (%ic-write ,obj ,(identifier-name (member-expression-property tgt)) val
                               ,(cs-const (%make-ic)) ,(comp-strict comp))
                    val))))))
    ;; statements
    (expression-statement `(progn ,(cs-node comp (expression-statement-expression node)) :normal))
    (block-statement `(progn ,@(mapcar (lambda (s) (cs-node comp s)) (block-statement-body node)) :normal))
    (if-statement
     `(progn (if (js-truthy ,(cs-node comp (if-statement-test node)))
                 ,(cs-node comp (if-statement-consequent node))
                 ,(if (if-statement-alternate node) (cs-node comp (if-statement-alternate node)) :normal))
             :normal))
    (return-statement
     `(throw ,(cs-const *cs-return-tag*)
        ,(if (return-statement-argument node) (cs-node comp (return-statement-argument node)) '+undefined+)))
    (empty-statement :normal)
    (t (error "cs-node: uncovered node ~s (cs-compilable-p should have excluded it)" (type-of node)))))

(defun cs-binop (op l r)
  "Return the CL form for `L OP R`, transcribing compile-binary EXACTLY. The relational/equality
primitives return CL booleans, so the SAME (js-boolean …) wrapper is required to yield a JS value;
`!=`/`!==` are (js-boolean (not (js-loose-eq …))) with no standalone negated primitive."
  (flet ((arith (fn) `(,fn ,l ,r)))
    (cond ((string= op "+") (arith 'js-add)) ((string= op "-") (arith 'js-sub))
          ((string= op "*") (arith 'js-mul)) ((string= op "/") (arith 'js-div))
          ((string= op "%") (arith 'js-mod)) ((string= op "**") (arith 'js-exp))
          ((string= op "&") (arith 'js-bit-and)) ((string= op "|") (arith 'js-bit-or))
          ((string= op "^") (arith 'js-bit-xor)) ((string= op "<<") (arith 'js-shl))
          ((string= op ">>") (arith 'js-shr)) ((string= op ">>>") (arith 'js-ushr))
          ((string= op "==")  `(js-boolean (js-loose-eq ,l ,r)))
          ((string= op "!=")  `(js-boolean (not (js-loose-eq ,l ,r))))
          ((string= op "===") `(js-boolean (js-strict-eq ,l ,r)))
          ((string= op "!==") `(js-boolean (not (js-strict-eq ,l ,r))))
          ((string= op "<")  `(js-boolean (js-lt ,l ,r))) ((string= op ">")  `(js-boolean (js-gt ,l ,r)))
          ((string= op "<=") `(js-boolean (js-le ,l ,r))) ((string= op ">=") `(js-boolean (js-ge ,l ,r)))
          ((string= op "instanceof") `(js-boolean (js-instanceof ,l ,r)))
          ((string= op "in") `(js-boolean (js-in ,l ,r)))
          (t (error "cs: unsupported binary op ~a" op)))))

(defvar *cs-return-tag* nil "The catch tag the body's `return` throws to; bound during cs-compile-body.")
(defvar *cs-compiled-count* 0 "Telemetry: how many function bodies the source backend has compiled.")
(defvar *cs-fallback-count* 0 "Telemetry: how many coverable bodies fell back (cl:compile failure).")

(defun cs-compile-body (comp stmts return-tag)
  "Compile STMTS into a single native body-fn `(lambda (env) -> completion)` — the same contract as the
closure backend's body-fn (a `return` throws RETURN-TAG; falling off returns :normal, and run-body's
outer catch yields +undefined+). Returns NIL if compilation fails (caller falls back to the closure tree)."
  (handler-case
      (let ((*cs-consts* (make-array 8 :adjustable t :fill-pointer 0))
            (*cs-return-tag* return-tag))
        (let* ((body-form `(progn ,@(mapcar (lambda (s) (cs-node comp s)) stmts) :normal))
               (maker (handler-bind ((warning #'muffle-warning))
                        (compile nil `(lambda (%consts) (declare (ignorable %consts)) (lambda (env) ,body-form))))))
          (incf *cs-compiled-count*)
          (funcall maker (coerce *cs-consts* 'simple-vector))))
    (error () (incf *cs-fallback-count*) nil)))    ; any source-gen/compile failure -> fall back (fail closed)
