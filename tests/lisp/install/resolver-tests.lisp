;;;; resolver-tests.lisp — Phase 23 milestone 1a: dependency resolution + hoisted-layout placement
;;;; against the Phase-21 fixture registry. The diamond conflict (conflict-a → shared@1.0.0,
;;;; conflict-b → shared@2.0.0) is the discriminator: one `shared` hoists, the other nests. Placement
;;;; must be DETERMINISTIC despite async fetch-completion order.

(in-package :clun-test)

(defparameter *resolver-root-deps*
  '(("@scope/widget" . "^1.0.0") ("conflict-a" . "1.0.0") ("conflict-b" . "1.0.0"))
  "A root dependency set exercising a transitive dep (@scope/widget → left-pad ^1.1.0) and the
shared diamond conflict.")

(defun %resolve-plan (root-deps)
  "Start the fixture registry, resolve ROOT-DEPS, and return (values nodes edge-version plan err)."
  (let ((loop (lp:make-event-loop :workers 0)) nodes ev err)
    (unwind-protect
         (multiple-value-bind (listener reg base) (start-fixture-registry loop)
           (declare (ignore reg))
           (unwind-protect
                (progn
                  (inst:resolve-install loop root-deps :registry base :retries 0
                    :on-ok  (lambda (n e) (setf nodes n ev e) (lp:loop-stop loop))
                    :on-err (lambda (c) (setf err c) (lp:loop-stop loop)))
                  (lp:run-loop loop))
             (net:listener-close listener)))
      (lp:destroy-event-loop loop))
    (values nodes ev (and nodes (null err) (inst:plan-layout nodes ev root-deps)) err)))

(defun %placement-of (plan key)
  "The physical dir at which node KEY (name@version) is placed, or NIL."
  (car (rassoc key plan :test #'string=)))

(define-test resolver/resolves-graph
  (multiple-value-bind (nodes ev plan err) (%resolve-plan *resolver-root-deps*)
    (declare (ignore ev plan))
    (false err)
    (true nodes)
    ;; highest-satisfying: @scope/widget → left-pad ^1.1.0 resolves to 1.3.0 (not 1.0.0/1.1.0)
    (true (gethash "@scope/widget@1.0.0" nodes) "@scope/widget@1.0.0 resolved")
    (true (gethash "left-pad@1.3.0" nodes) "left-pad ^1.1.0 → 1.3.0")
    (false (gethash "left-pad@1.0.0" nodes) "1.0.0 not chosen")
    ;; the diamond: BOTH shared versions are resolved (a genuine conflict)
    (true (gethash "shared@1.0.0" nodes) "shared@1.0.0 (conflict-a)")
    (true (gethash "shared@2.0.0" nodes) "shared@2.0.0 (conflict-b)")
    (is = 6 (hash-table-count nodes) "6 resolved packages")))

(define-test resolver/hoists-and-nests-the-conflict
  (multiple-value-bind (nodes ev plan err) (%resolve-plan *resolver-root-deps*)
    (declare (ignore nodes ev))
    (false err)
    (is = 6 (length plan) "6 placements")
    ;; transitive + direct deps hoist to the root node_modules
    (is string= "node_modules/left-pad" (%placement-of plan "left-pad@1.3.0"))
    (is string= "node_modules/@scope/widget" (%placement-of plan "@scope/widget@1.0.0"))
    (is string= "node_modules/conflict-a" (%placement-of plan "conflict-a@1.0.0"))
    (is string= "node_modules/conflict-b" (%placement-of plan "conflict-b@1.0.0"))
    ;; the diamond: conflict-a is processed first (root-deps order) so shared@1.0.0 hoists;
    ;; shared@2.0.0 conflicts and nests under conflict-b.
    (is string= "node_modules/shared" (%placement-of plan "shared@1.0.0"))
    (is string= "node_modules/conflict-b/node_modules/shared" (%placement-of plan "shared@2.0.0"))))

(define-test resolver/placement-is-deterministic
  ;; async fetch-completion order varies run-to-run; the plan must not.
  (multiple-value-bind (n1 e1 plan1 err1) (%resolve-plan *resolver-root-deps*)
    (declare (ignore n1 e1))
    (multiple-value-bind (n2 e2 plan2 err2) (%resolve-plan *resolver-root-deps*)
      (declare (ignore n2 e2))
      (false err1) (false err2)
      (is equal plan1 plan2 "identical plan across two independent resolutions"))))

(define-test resolver/unsatisfiable-range-errors
  ;; a range no published version satisfies is a clean install-error, not a hang/crash
  (multiple-value-bind (nodes ev plan err) (%resolve-plan '(("left-pad" . "^9.0.0")))
    (declare (ignore nodes ev plan))
    (true (typep err 'inst:install-error) "unsatisfiable → install-error")))

(define-test resolver/missing-package-errors
  (multiple-value-bind (nodes ev plan err) (%resolve-plan '(("does-not-exist" . "1.0.0")))
    (declare (ignore nodes ev plan))
    ;; a 404 surfaces as the registry's package-not-found (preserved, not rewrapped) — a clean
    ;; catchable error, not a hang/crash.
    (true (typep err 'reg:package-not-found) "unknown package → package-not-found")))
