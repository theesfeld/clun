;;;; compile-source.lisp — Phase 25 COMPILE tier: a SECOND emitter backend that, for a coverable
;;;; function body, generates ONE CL source form and cl:compiles it into a single native body-fn,
;;;; instead of the tree of per-node closures the default backend builds. It reuses every existing
;;;; runtime primitive (frame-ref/frame-set, %ic-read/%ic-write, js-getv/js-set, js-call, js-add & the
;;;; operators, js-truthy, the catch/throw return protocol) — no new semantics; the generated body is a
;;;; transcription of the closure backend, so it must be OBSERVABLY IDENTICAL. Non-coverable shapes fall
;;;; back to the closure tree, so the tier is purely additive and correctness is the interpreter's.
;;;; See docs/design/phase-25-compile-tier.md. m1 proved the mechanism on a small subset; m2 widens it
;;;; to cover DeltaBlue and measures the eager ceiling (the decision gate).

(in-package :clun.engine)

(defvar *compile-tier-mode* :off
  ":off — closure tree only (default/production for now). :eager — compile every COVERABLE user
function's body at definition time (synchronous), for the differential coverage shake-out + the ceiling
measurement. :threshold — (future m3) background tier-up. Only :off and :eager exist through m2.")

(defvar *cs-compiled-count* 0 "Successfully instantiated source-compiled bodies.")
(defvar *cs-ineligible-count* 0 "Bodies rejected by the conservative coverability predicate.")
(defvar *cs-fallback-count* 0 "Coverable bodies whose source generation or CL compilation failed.")
(defvar *cs-executed-count* 0 "Compiled-body invocations while diagnostic execution tracing is enabled.")
(defvar *cs-trace-executions* nil
  "When true at source-generation time, instrument compiled bodies with per-function execution counts.")
(defvar *cs-function-status* (make-hash-table :test 'equal)
  "Diagnostic function-id -> (:compiled), (:ineligible blockers), or (:compile-error condition).")
(defvar *cs-function-executions* (make-hash-table :test 'equal)
  "Diagnostic function-id -> compiled-body invocation count.")
(defvar *cs-function-sequence* 0
  "Definition-order suffix used to keep diagnostic IDs unique across modules in one process.")
(defvar *cs-return-tag* nil "The catch tag the body's `return` throws to; bound during cs-compile-body.")

(defun compile-tier-mode-from-environment ()
  "Return the debug COMPILE-tier mode requested by CLUN_COMPILE_TIER.
The production default is :OFF. Reject misspellings so a gate cannot silently measure the wrong backend."
  (let ((raw (sb-ext:posix-getenv "CLUN_COMPILE_TIER")))
    (cond ((or (null raw) (string= raw "") (string-equal raw "off")) :off)
          ((string-equal raw "eager") :eager)
          (t (error "CLUN_COMPILE_TIER must be 'off' or 'eager', got ~s" raw)))))

(defun compile-tier-report-enabled-p ()
  (let ((raw (sb-ext:posix-getenv "CLUN_COMPILE_TIER_REPORT")))
    (and raw (not (string= raw "")) (not (string= raw "0")))))

(defun compile-tier-trace-enabled-p ()
  (let ((raw (sb-ext:posix-getenv "CLUN_COMPILE_TIER_TRACE")))
    (and raw (not (string= raw "")) (not (string= raw "0")))))

(defun compile-tier-details-enabled-p ()
  (let ((raw (sb-ext:posix-getenv "CLUN_COMPILE_TIER_DETAILS")))
    (and raw (not (string= raw "")) (not (string= raw "0")))))

(defun cs-reset-telemetry ()
  (setf *cs-compiled-count* 0
        *cs-ineligible-count* 0
        *cs-fallback-count* 0
        *cs-executed-count* 0
        *cs-function-sequence* 0)
  (clrhash *cs-function-status*)
  (clrhash *cs-function-executions*)
  nil)

(defun cs-function-id (fname body)
  (format nil "~a@~d:~d#~d"
          (if (and fname (plusp (length fname))) fname "<anonymous>")
          (node-start body) (node-end body) (incf *cs-function-sequence*)))

(defun cs-note-status (function-id status &optional detail)
  (setf (gethash function-id *cs-function-status*)
        (if detail (list status detail) (list status)))
  status)

(defun cs-note-executed (function-id)
  (incf *cs-executed-count*)
  (incf (gethash function-id *cs-function-executions* 0))
  :normal)

(defun write-compile-tier-report (&optional (stream *error-output*))
  "Write the stable one-line integration-gate contract. Named details remain available in the hash ledgers."
  (format stream "COMPILE_TIER mode=~(~a~) compiled=~d ineligible=~d fallback=~d executed=~d~%"
          *compile-tier-mode* *cs-compiled-count* *cs-ineligible-count* *cs-fallback-count*
          *cs-executed-count*)
  (finish-output stream))

(defun write-compile-tier-details (&optional (stream *error-output*))
  "Write deterministic per-function diagnostic lines for coverage gates.
This is deliberately separate from the one-line timing report and is never enabled by default."
  (let ((ids (sort (loop for id being the hash-keys of *cs-function-status* collect id) #'string<)))
    (dolist (id ids)
      (let* ((entry (gethash id *cs-function-status*))
             (status (first entry))
             (detail (second entry)))
        (format stream "COMPILE_TIER_FUNCTION id=~a status=~(~a~) executed=~d detail=~a~%"
                id status (gethash id *cs-function-executions* 0)
                (cond ((null detail) "-")
                      ((listp detail) (format nil "~{~a~^,~}" detail))
                      (t (substitute #\Space #\Newline (princ-to-string detail))))))))
  (finish-output stream))

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

(defun cs-node-blockers (node &optional (break-depth 0) (continue-depth 0))
  "Return a de-duplicated list of unsupported m2 source-backend shapes below NODE.
BREAK-DEPTH and CONTINUE-DEPTH admit only unlabeled control transfers with a
source-emitted target; switches increment only the former."
  (labels ((one (n &optional (b break-depth) (c continue-depth)) (cs-node-blockers n b c))
           (many (nodes &optional (b break-depth) (c continue-depth))
             (mapcan (lambda (n) (one n b c)) nodes))
           (target (n)
             (if (or (identifier-p n) (member-expression-p n)) (one n) '("assignment-target"))))
    (remove-duplicates
     (typecase node
       (null nil)
       ((or literal this-expression identifier) nil)
       (meta-property
        (unless (or (string= (meta-property-meta node) "new")
                    (string= (meta-property-meta node) "import"))
          '("meta-property")))
       (member-expression
        (append (one (member-expression-object node))
                (when (member-expression-computed node) (one (member-expression-property node)))))
       (array-expression
        (loop for e in (array-expression-elements node)
              append (cond ((null e) nil) ((spread-element-p e) '("array-spread")) (t (one e)))))
       (object-expression
        (loop for p in (object-expression-properties node)
              append (cond
                       ((spread-element-p p) '("object-spread"))
                       ((or (not (eq (property-kind p) :init)) (property-method p)) '("object-method"))
                       (t (append (when (property-computed p) (one (property-key p)))
                                  (one (property-value p)))))))
       (binary-expression (append (one (binary-expression-left node)) (one (binary-expression-right node))))
       (logical-expression (append (one (logical-expression-left node)) (one (logical-expression-right node))))
       (unary-expression
        (if (member (unary-expression-operator node) '("!" "-" "+" "~" "void" "typeof") :test #'string=)
            (one (unary-expression-argument node))
            (list (format nil "unary-~a" (unary-expression-operator node)))))
       (update-expression (target (update-expression-argument node)))
       (conditional-expression
        (append (one (conditional-expression-test node))
                (one (conditional-expression-consequent node))
                (one (conditional-expression-alternate node))))
       (call-expression
        (append (when (and (identifier-p (call-expression-callee node))
                           (string= (identifier-name (call-expression-callee node)) "eval"))
                  '("direct-eval"))
                (one (call-expression-callee node))
                (if (some #'spread-element-p (call-expression-arguments node)) '("call-spread")
                    (many (call-expression-arguments node)))))
       (new-expression
        (append (one (new-expression-callee node))
                (if (some #'spread-element-p (new-expression-arguments node)) '("new-spread")
                    (many (new-expression-arguments node)))))
       (assignment-expression
        (append (if (member (assignment-expression-operator node)
                            '("=" "+=" "-=" "*=" "/=" "%=" "**=" "&=" "|=" "^=" "<<=" ">>=" ">>>=")
                            :test #'string=)
                    nil
                    (list (format nil "assignment-~a" (assignment-expression-operator node))))
                (target (assignment-expression-left node))
                (one (assignment-expression-right node))))
       (sequence-expression (many (sequence-expression-expressions node)))
       (expression-statement (one (expression-statement-expression node)))
       (block-statement (many (block-statement-body node)))
       (variable-declaration
        (loop for d in (variable-declaration-declarations node)
              append (if (identifier-p (variable-declarator-id d))
                         (one (variable-declarator-init d))
                         '("destructuring-declaration"))))
       (if-statement
        (append (one (if-statement-test node)) (one (if-statement-consequent node))
                (one (if-statement-alternate node))))
       (while-statement
        (append (one (while-statement-test node))
                (one (while-statement-body node) (1+ break-depth) (1+ continue-depth))))
       (do-while-statement
        (append (one (do-while-statement-body node) (1+ break-depth) (1+ continue-depth))
                (one (do-while-statement-test node))))
       (for-statement
        (append (one (for-statement-init node)) (one (for-statement-test node))
                (one (for-statement-update node))
                (one (for-statement-body node) (1+ break-depth) (1+ continue-depth))))
       (switch-statement
        (append (one (switch-statement-discriminant node))
                (loop for c in (switch-statement-cases node)
                      append (append (one (switch-case-test c))
                                     (many (switch-case-consequent c)
                                           (1+ break-depth) continue-depth)))))
       (break-statement
        (cond ((break-statement-label node) '("labeled-break"))
              ((zerop break-depth) '("orphan-break"))
              (t nil)))
       (continue-statement
        (cond ((continue-statement-label node) '("labeled-continue"))
              ((zerop continue-depth) '("orphan-continue"))
              (t nil)))
       (return-statement (one (return-statement-argument node)))
       (throw-statement (one (throw-statement-argument node)))
       (try-statement
        (let ((handler (try-statement-handler node)))
          (append (when (try-statement-finalizer node) '("try-finally"))
                  (one (try-statement-block node))
                  (when handler
                    (append (unless (or (null (catch-clause-param handler))
                                        (identifier-p (catch-clause-param handler)))
                              '("destructuring-catch"))
                            (one (catch-clause-body handler)))))))
       (function-node (unless (function-node-declaration node) '("function-expression")))
       ((or empty-statement debugger-statement) nil)
       (t (list (string-downcase (symbol-name (type-of node))))))
     :test #'string=)))

(defun cs-node-coverable-p (node)
  (null (cs-node-blockers node)))

(defun cs-function-blockers (params stmts)
  (remove-duplicates
   (append (unless (cs-simple-params-p params) '("non-simple-parameters"))
           (mapcan #'cs-node-blockers stmts))
   :test #'string=))

(defun cs-compilable-p (params stmts)
  "T iff a function with these params + body statements is coverable by the m2 source backend."
  (null (cs-function-blockers params stmts)))

;;; --- source generation: node -> CL form (given `env` + `%consts`) ----------

(defun cs-seq (comp stmts)
  `(progn ,@(mapcar (lambda (s) (cs-node comp s)) stmts) :normal))

(defun cs-reference (comp node)
  "Return GET-FORM and a source-generator function accepting a VALUE-FORM for NODE's setter."
  (typecase node
    (identifier
     (let ((name (identifier-name node)))
       (multiple-value-bind (kind depth index) (comp-resolve comp name)
         (values
          (cond ((and (eq kind :local) (resolved-import-p comp depth name))
                 `(funcall (frame-ref env ,depth ,index ,name)))
                ((eq kind :local) `(frame-ref env ,depth ,index ,name))
                (t `(global-get ,name)))
          (lambda (value)
            (cond ((and (eq kind :local) (resolved-import-p comp depth name))
                   `(progn ,value (throw-type-error "Assignment to constant variable.")))
                  ((eq kind :local) `(frame-set env ,depth ,index ,value))
                  (t `(global-set ,name ,value ,(comp-strict comp)))))))))
    (member-expression
     (if (member-expression-computed node)
         (values
          `(js-getv ,(cs-node comp (member-expression-object node))
                    (to-property-key ,(cs-node comp (member-expression-property node))))
          (lambda (value)
            `(let ((o ,(cs-node comp (member-expression-object node))))
               (js-set (to-object o)
                       (to-property-key ,(cs-node comp (member-expression-property node)))
                       ,value ,(comp-strict comp)))))
         (let ((key (identifier-name (member-expression-property node))))
           (values `(%ic-read ,(cs-node comp (member-expression-object node)) ,key
                              ,(cs-const (%make-ic)))
                   (lambda (value)
                     `(%ic-write ,(cs-node comp (member-expression-object node)) ,key ,value
                                 ,(cs-const (%make-ic)) ,(comp-strict comp)))))))
    (t (error "cs-reference: unsupported target ~s" (type-of node)))))

(defun cs-with-reference (comp node builder)
  "Call BUILDER with a generated get form and setter generator, wrapping the
result so a member base/key is evaluated exactly once before the operation."
  (typecase node
    (identifier
     (multiple-value-bind (get set) (cs-reference comp node)
       (funcall builder get set)))
    (member-expression
     (let ((o (gensym "REF-OBJECT-")) (k (gensym "REF-KEY-"))
           (computed (member-expression-computed node)))
       (if computed
           `(let* ((,o ,(cs-node comp (member-expression-object node)))
                   (,k (to-property-key ,(cs-node comp (member-expression-property node)))))
              ,(funcall builder `(js-getv ,o ,k)
                        (lambda (value) `(js-set (to-object ,o) ,k ,value ,(comp-strict comp)))))
           (let ((key (identifier-name (member-expression-property node)))
                 (rcache (cs-const (%make-ic))) (wcache (cs-const (%make-ic))))
             `(let* ((,o ,(cs-node comp (member-expression-object node))) (,k ,key))
                ,(funcall builder `(%ic-read ,o ,k ,rcache)
                          (lambda (value) `(%ic-write ,o ,k ,value ,wcache ,(comp-strict comp)))))))))
    (t (error "cs-with-reference: unsupported target ~s" (type-of node)))))

(defun cs-bind-identifier (comp id value)
  (let ((name (identifier-name id)))
    (multiple-value-bind (kind depth index) (comp-resolve comp name)
      (if (eq kind :local)
          `(frame-init env ,depth ,index ,value)
          `(global-set ,name ,value ,(comp-strict comp))))))

(defun cs-var-decl (comp node)
  `(progn
     ,@(loop for d in (variable-declaration-declarations node)
             when (or (variable-declarator-init d)
                      (not (eq (variable-declaration-kind node) :var)))
               collect (cs-bind-identifier
                        comp (variable-declarator-id d)
                        (if (variable-declarator-init d)
                            (cs-node comp (variable-declarator-init d))
                            '+undefined+)))
     :normal))

(defun cs-copy-comp (comp &key scopes loops labels)
  (let ((sub (make-comp)))
    (setf (comp-scopes sub) (or scopes (comp-scopes comp))
          (comp-strict sub) (comp-strict comp)
          (comp-loops sub) (or loops (comp-loops comp))
          (comp-labels sub) (or labels (comp-labels comp))
          (comp-module sub) (comp-module comp))
    sub))

(defun cs-block (comp node)
  "Transcribe compile-block, including its lexical frame and hoisted block functions."
  (let ((stmts (block-statement-body node)))
    (if (not (block-has-lexical-p stmts))
        (cs-seq comp stmts)
        (let* ((scope (make-cscope :block))
               (lex-names (collect-lexical-names stmts))
               (func-decls (collect-function-decls stmts)))
          (dolist (n lex-names) (cs-declare scope n))
          (dolist (fd func-decls) (cs-declare scope (identifier-name (function-node-id fd))))
          (let* ((sub (cs-copy-comp comp :scopes (cons scope (comp-scopes comp))))
                 (lexical-idxs (mapcar (lambda (n) (gethash n (cs-names scope))) lex-names))
                 (func-compiled
                   (loop for fd in func-decls
                         collect (cons (gethash (identifier-name (function-node-id fd)) (cs-names scope))
                                       (compile-function-common
                                        sub (function-node-params fd) (function-node-body fd)
                                        (identifier-name (function-node-id fd))
                                        :generator (function-node-generator fd)
                                        :async (function-node-async fd)))))
                 (body (cs-seq sub stmts))
                 (count (cs-count scope)))
            `(let ((env (new-frame ,count env)))
               ,@(mapcar (lambda (i) `(setf (svref (env-slots env) ,i) +tdz+)) lexical-idxs)
               ,@(mapcar (lambda (fc)
                           `(setf (svref (env-slots env) ,(car fc))
                                  (funcall ,(cs-const (cdr fc)) env)))
                         func-compiled)
               ,body))))))

(defun cs-array (comp node)
  `(let ((a (new-array)) (i 0))
     ,@(loop for e in (array-expression-elements node)
             collect (if e
                         `(progn (create-data-property a (int->string i) ,(cs-node comp e)) (incf i))
                         '(incf i)))
     (js-set a "length" (coerce i 'double-float) t)
     a))

(defun cs-object (comp node)
  `(let ((o (new-object)))
     ,@(loop for p in (object-expression-properties node)
             collect
             (let ((key (if (property-computed p)
                            `(to-property-key ,(cs-node comp (property-key p)))
                            (property-key-string (property-key p))))
                   (value (cs-node comp (property-value p))))
               `(let ((k ,key)) (create-data-property o k ,value))))
     o))

(defun cs-loop-comp (comp break-tag continue-tag)
  (copy-comp-for-loop comp break-tag continue-tag nil))

(defun cs-while (comp node)
  (let* ((bt (list 'break)) (ct (list 'continue)) (sub (cs-loop-comp comp bt ct)))
    `(progn
       (catch ,(cs-const bt)
         (loop while (js-truthy ,(cs-node sub (while-statement-test node)))
               do (catch ,(cs-const ct) ,(cs-node sub (while-statement-body node)))))
       :normal)))

(defun cs-do-while (comp node)
  (let* ((bt (list 'break)) (ct (list 'continue)) (sub (cs-loop-comp comp bt ct)))
    `(progn
       (catch ,(cs-const bt)
         (loop (catch ,(cs-const ct) ,(cs-node sub (do-while-statement-body node)))
               (unless (js-truthy ,(cs-node sub (do-while-statement-test node))) (return))))
       :normal)))

(defun cs-for-body (sub node bt ct)
  `(progn
     ,(when (for-statement-init node) (cs-node sub (for-statement-init node)))
     (catch ,(cs-const bt)
       (loop while ,(if (for-statement-test node)
                        `(js-truthy ,(cs-node sub (for-statement-test node)))
                        t)
             do (catch ,(cs-const ct) ,(cs-node sub (for-statement-body node)))
                ,@(when (for-statement-update node)
                    (list (cs-node sub (for-statement-update node))))))
     :normal))

(defun cs-for (comp node)
  (let* ((init (for-statement-init node))
         (lexical (and (variable-declaration-p init)
                       (member (variable-declaration-kind init) '(:let :const))))
         (bt (list 'break)) (ct (list 'continue))
         (loop-comp (cs-loop-comp comp bt ct)))
    (if (not lexical)
        (cs-for-body loop-comp node bt ct)
        (let* ((names (loop for d in (variable-declaration-declarations init)
                            collect (identifier-name (variable-declarator-id d))))
               (scope (make-cscope :block)))
          (dolist (n names) (cs-declare scope n))
          (let* ((sub (cs-copy-comp loop-comp :scopes (cons scope (comp-scopes loop-comp))))
                 (count (cs-count scope))
                 (body (cs-for-body sub node bt ct)))
            ;; Mirror compile-for-lexical's current one-frame approximation, including its undefined
            ;; initial fill. Correct per-iteration environments are an interpreter-wide concern.
            `(let ((env (new-frame ,count env)))
               ,@(loop for i below count collect `(setf (svref (env-slots env) ,i) +tdz+))
               ,body))))))

(defun cs-switch (comp node)
  (let* ((bt (list 'break))
         (base (copy-comp-for-switch comp bt))
         (stmts (loop for c in (switch-statement-cases node)
                      append (switch-case-consequent c)))
         (lex-names (collect-lexical-names stmts))
         (func-decls (collect-function-decls stmts))
         (scope (and (block-has-lexical-p stmts) (make-cscope :block))))
    (when scope
      (dolist (n lex-names) (cs-declare scope n))
      (dolist (fd func-decls) (cs-declare scope (identifier-name (function-node-id fd)))))
    (let* ((sub (if scope (cs-copy-comp base :scopes (cons scope (comp-scopes base))) base))
           (cases (loop for c in (switch-statement-cases node)
                        collect (cons (and (switch-case-test c) (cs-node sub (switch-case-test c)))
                                      (cs-seq sub (switch-case-consequent c)))))
           (default-tail (member-if (lambda (c) (null (car c))) cases))
           (lexical-idxs (and scope (mapcar (lambda (n) (gethash n (cs-names scope))) lex-names)))
           (func-compiled
             (and scope
                  (loop for fd in func-decls
                        collect (cons (gethash (identifier-name (function-node-id fd)) (cs-names scope))
                                      (compile-function-common
                                       sub (function-node-params fd) (function-node-body fd)
                                       (identifier-name (function-node-id fd))
                                       :generator (function-node-generator fd)
                                       :async (function-node-async fd))))))
           (count (and scope (cs-count scope)))
           (case-form
             `(catch ,(cs-const bt)
                ,@(loop for (test . body) in cases
                        append (if test
                                   (list `(when (and (not matched) (js-strict-eq d ,test))
                                            (setf matched t))
                                         `(when matched ,body))
                                   (list `(when matched ,body))))
                ,(when default-tail `(unless matched ,@(mapcar #'cdr default-tail))))))
      `(progn
         ;; Evaluate the discriminant before entering the shared CaseBlock scope.
         (let ((d ,(cs-node comp (switch-statement-discriminant node))))
           ,(if (not scope)
                `(let ((matched nil)) ,case-form)
                `(let ((env (new-frame ,count env)))
                   ,@(mapcar (lambda (i) `(setf (svref (env-slots env) ,i) +tdz+)) lexical-idxs)
                   ,@(mapcar (lambda (fc)
                               `(setf (svref (env-slots env) ,(car fc))
                                      (funcall ,(cs-const (cdr fc)) env)))
                             func-compiled)
                   (let ((matched nil)) ,case-form))))
         :normal))))

(defun cs-try (comp node)
  (let ((block (cs-node comp (try-statement-block node)))
        (handler (try-statement-handler node)))
    (if (null handler)
        `(progn ,block :normal)
        (let ((param (catch-clause-param handler)))
          (if (null param)
              `(progn
                 (handler-case ,block
                   (js-condition (c) (declare (ignore c)) ,(cs-node comp (catch-clause-body handler))))
                 :normal)
              (let ((scope (make-cscope :block)))
                (cs-declare scope (identifier-name param))
                (let* ((sub (cs-copy-comp comp :scopes (cons scope (comp-scopes comp))))
                       (index (gethash (identifier-name param) (cs-names scope)))
                       (body (cs-node sub (catch-clause-body handler))))
                  `(progn
                     (handler-case ,block
                       (js-condition (c)
                         (let ((env (new-frame ,(cs-count scope) env)))
                           (frame-init env 0 ,index (js-condition-value c))
                           ,body)))
                     :normal))))))))

(defun cs-node (comp node)
  "Return a CL form computing coverable NODE with the closure backend's runtime primitives."
  (typecase node
    (literal (cs-const (literal-value node)))
    (this-expression
     (multiple-value-bind (kind depth index) (comp-resolve comp "%this%")
       (if (eq kind :local) `(frame-ref env ,depth ,index "this") `(realm-global *realm*))))
    (meta-property
     (let ((name (if (string= (meta-property-meta node) "import") "%import.meta%" "%new.target%"))
           (display (if (string= (meta-property-meta node) "import") "import.meta" "new.target")))
       (multiple-value-bind (kind depth index) (comp-resolve comp name)
         (if (eq kind :local) `(frame-ref env ,depth ,index ,display) '+undefined+))))
    (identifier
     (let ((name (identifier-name node)))
       (multiple-value-bind (kind depth index) (comp-resolve comp name)
         (cond ((and (eq kind :local) (resolved-import-p comp depth name))
                `(funcall (frame-ref env ,depth ,index ,name)))
               ((eq kind :local) `(frame-ref env ,depth ,index ,name))
               (t `(global-get ,name))))))
    (array-expression (cs-array comp node))
    (object-expression (cs-object comp node))
    (member-expression (nth-value 0 (cs-reference comp node)))
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
    (update-expression
     (let ((step (if (string= (update-expression-operator node) "++") 1 -1)))
       (cs-with-reference
        comp (update-expression-argument node)
        (lambda (get set)
          `(let* ((old (to-numeric ,get))
                  (new (if (integerp old) (+ old ,step)
                           (with-js-floats (+ old (coerce ,step 'double-float))))))
             ,(funcall set 'new)
             ,(if (update-expression-prefix node) 'new 'old))))))
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
    (sequence-expression
     `(let ((v +undefined+))
        ,@(mapcar (lambda (e) `(setf v ,(cs-node comp e))) (sequence-expression-expressions node))
        v))
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
    (new-expression
     `(js-construct ,(cs-node comp (new-expression-callee node))
                    (list ,@(mapcar (lambda (a) (cs-node comp a)) (new-expression-arguments node)))))
    (assignment-expression
     (let ((rhs (cs-node comp (assignment-expression-right node)))
           (op (assignment-expression-operator node)))
       (cs-with-reference
        comp (assignment-expression-left node)
        (lambda (get set)
          (if (string= op "=")
              `(let ((val ,rhs)) ,(funcall set 'val) val)
              `(let* ((a ,get) (d ,rhs)
                      (val (apply-binop ,(subseq op 0 (1- (length op))) a d)))
                 ,(funcall set 'val)
                 val))))))
    ;; statements
    (expression-statement `(progn ,(cs-node comp (expression-statement-expression node)) :normal))
    (block-statement (cs-block comp node))
    (variable-declaration (cs-var-decl comp node))
    (if-statement
     `(progn (if (js-truthy ,(cs-node comp (if-statement-test node)))
                 ,(cs-node comp (if-statement-consequent node))
                 ,(if (if-statement-alternate node) (cs-node comp (if-statement-alternate node)) :normal))
             :normal))
    (while-statement (cs-while comp node))
    (do-while-statement (cs-do-while comp node))
    (for-statement (cs-for comp node))
    (switch-statement (cs-switch comp node))
    (break-statement
     `(throw ,(cs-const (car (first (comp-loops comp)))) :break))
    (continue-statement
     `(throw ,(cs-const (cdr (first (comp-loops comp)))) :continue))
    (return-statement
     `(throw ,(cs-const *cs-return-tag*)
        ,(if (return-statement-argument node) (cs-node comp (return-statement-argument node)) '+undefined+)))
    (throw-statement `(throw-js-value ,(cs-node comp (throw-statement-argument node))))
    (try-statement (cs-try comp node))
    (function-node :normal)
    ((or empty-statement debugger-statement) :normal)
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

(defun cs-compile-body (comp stmts return-tag function-id)
  "Compile STMTS into a single native body-fn `(lambda (env) -> completion)` — the same contract as the
closure backend's body-fn (a `return` throws RETURN-TAG; falling off returns :normal, and run-body's
outer catch yields +undefined+). Returns NIL if compilation fails (caller falls back to the closure tree)."
  (handler-case
      (let ((*cs-consts* (make-array 8 :adjustable t :fill-pointer 0))
            (*cs-return-tag* return-tag))
        (let* ((run-form `(progn ,@(mapcar (lambda (s) (cs-node comp s)) stmts) :normal))
               (body-form (if *cs-trace-executions*
                              `(progn (cs-note-executed ,(cs-const function-id)) ,run-form)
                              run-form)))
          (multiple-value-bind (maker warnings-p failure-p)
              (handler-bind ((warning #'muffle-warning)
                             (sb-ext:compiler-note #'muffle-warning))
                (compile nil `(lambda (%consts)
                                (declare (ignorable %consts))
                                (lambda (env) ,body-form))))
            (declare (ignore warnings-p))
            (when failure-p (error "SBCL reported failure while compiling ~a" function-id))
            (let ((body (funcall maker (coerce *cs-consts* 'simple-vector))))
              (unless (functionp body) (error "compiled maker for ~a returned ~s" function-id body))
              (incf *cs-compiled-count*)
              (cs-note-status function-id :compiled)
              body))))
    (error (c)
      (incf *cs-fallback-count*)
      (cs-note-status function-id :compile-error (princ-to-string c))
      nil)))                              ; source-gen/compile failure -> closure backend (fail closed)
