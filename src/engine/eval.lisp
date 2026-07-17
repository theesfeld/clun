;;;; eval.lisp — top-level: compile a Program in a realm and run it (Phase 03).
;;;; Script var/function declarations use the global object. Top-level lexical
;;;; declarations use a per-program declarative frame with TDZ and const metadata.

(in-package :clun.engine)

(defun program-strict-p (program)
  (dolist (s (program-body program) nil)
    (if (and (expression-statement-p s) (expression-statement-directive s))
        (when (string= (expression-statement-directive s) "use strict") (return t))
        (return nil))))

(defun prepare-script-lexical-environment (stmts comp &key outer-env (outer-scopes '()))
  "Create a script/eval lexical frame over the explicitly supplied ancestry."
  (let* ((names (collect-lexical-names stmts))
         (scope (and names (make-cscope :block)))
         (scopes (if scope (cons scope outer-scopes) outer-scopes))
         (env (if scope (new-frame (progn
                                     (dolist (name names) (cs-declare scope name))
                                     (mark-immutable-lexicals scope stmts)
                                     (cs-count scope))
                                   outer-env +tdz+)
                  outer-env)))
    (setf (comp-scopes comp) scopes)
    env))

(defun call-with-active-script-lexicals (realm env scopes thunk)
  "Expose one script's lexical ancestry to synchronous indirect eval only."
  (let ((old-env (realm-active-script-lexical-environment realm))
        (old-scopes (realm-active-script-lexical-scopes realm)))
    (unwind-protect
         (progn
           (setf (realm-active-script-lexical-environment realm) env
                 (realm-active-script-lexical-scopes realm) scopes)
           (funcall thunk))
      (setf (realm-active-script-lexical-environment realm) old-env
            (realm-active-script-lexical-scopes realm) old-scopes))))

(defun global-instantiate (stmts comp lexical-env)
  "Hoist top-level function and var declarations onto the global object."
  (let ((g (realm-global *realm*)))
    (dolist (fd (collect-function-decls stmts))
      (let* ((name (identifier-name (function-node-id fd)))
             (fn (funcall (compile-function-common comp (function-node-params fd)
                                                   (function-node-body fd) name
                                                   :generator (function-node-generator fd)
                                                   :async (function-node-async fd)
                                                   :source-text (node-source-text fd)
                                                   :source-start (node-start fd)
                                                   :source-end (node-end fd))
                          lexical-env)))
        (js-set g name fn t)))
    (multiple-value-bind (vars funcs) (collect-var-names stmts)
      (declare (ignore funcs))
      (dolist (v vars)
        (unless (has-own-property g v) (create-data-property g v +undefined+))))))

(defun run-program (program realm &key strict)
  (let ((*realm* realm)
        (*current-source-text* (program-source program))
        (comp (make-comp)))
    (when (or strict (program-strict-p program)) (setf (comp-strict comp) t))
    (let* ((stmts (program-body program))
           (lexical-env (prepare-script-lexical-environment stmts comp)))
      (call-with-active-script-lexicals
       realm lexical-env (comp-scopes comp)
       (lambda ()
         (global-instantiate stmts comp lexical-env)
         (funcall (compile-seq comp stmts) lexical-env)))))
  +undefined+)

(defun drive-jobs (realm)
  "Run the event loop (Promise microtasks, timers, nextTick) to idle, if one exists."
  (let ((l (realm-loop realm))) (when l (lp:run-loop l))))

(defun destroy-realm-loop (realm)
  (let ((l (realm-loop realm)))
    (when l (ignore-errors (lp:destroy-event-loop l)) (setf (realm-loop realm) nil))))

(defun run-callback-to-settlement (thunk realm &key (timeout-ms 5000))
  "Run THUNK (which JS-calls a callback) under REALM and, if it returns a pending
Promise, drive the loop until the promise settles or TIMEOUT-MS elapses. Returns
(values KIND VALUE), KIND ∈ :fulfilled :rejected :timeout. A synchronous JS throw →
(:rejected value). The test runner's one async seam — it keeps the loop alive across
tests (run-module-file :teardown nil) and this drives it per callback."
  (let ((*realm* realm))
    (handler-case
        (let ((result (funcall thunk)))
          (cond
            ((and (js-promise-p result) (eq (js-promise-pstate result) :pending))
             (%drive-promise-to-settlement result timeout-ms))
            (t
             ;; sync return / already-settled promise: run queued microtasks (an
             ;; assertion inside a .then), then report. Don't wait on timers.
             (let ((l (realm-loop realm))) (when l (lp:drain-microtasks l)))
             (if (js-promise-p result)
                 (values (if (eq (js-promise-pstate result) :rejected) :rejected :fulfilled)
                         (js-promise-value result))
                 (values :fulfilled result)))))
      (js-condition (c) (values :rejected (js-condition-value c)))
      ;; §6 safety net: a raw CL error from a hook/test/matcher (arithmetic-error,
      ;; no-applicable-method, …) becomes a clean test failure, never a backtrace.
      (error (c) (values :rejected (%cl-error->js c))))))

(defun %cl-error->js (c)
  "Wrap a CL condition as a JS Error value so the test runner reports it as a failure."
  (handler-case
      (js-construct (js-get (realm-global *realm*) "Error") (list (format nil "~a" c)))
    (error () (format nil "~a" c))))

(defun %drive-promise-to-settlement (promise timeout-ms)
  (let* ((loop (current-loop))              ; ensures the loop exists
         (outcome nil))                     ; (cons kind value), set by a reaction/timeout
    (let ((on-ok (make-native-function "" 1
                   (lambda (this a) (declare (ignore this))
                     (unless outcome (setf outcome (cons :fulfilled (arg a 0))))
                     (lp:loop-stop loop) +undefined+)))
          (on-err (make-native-function "" 1
                    (lambda (this a) (declare (ignore this))
                      (unless outcome (setf outcome (cons :rejected (arg a 0))))
                      (lp:loop-stop loop) +undefined+))))
      (js-call (js-get promise "then") promise (list on-ok on-err))
      (let ((timer (lp:set-timer loop (max 0 timeout-ms)
                                 (lambda () (unless outcome (setf outcome (cons :timeout +undefined+)))
                                   (lp:loop-stop loop)))))
        (unwind-protect (lp:run-loop loop) (lp:clear-timer timer))))
    (if outcome (values (car outcome) (cdr outcome)) (values :timeout +undefined+))))

(defun run-source (source &key (realm (make-realm)) strict (source-type :script)
                               (report-unhandled-rejections-p t))
  "Parse SOURCE, run top-level, drive the job loop to idle, then surface any
unhandled rejection as an uncaught error (§ Phase 06). Teardown force-finishes live
coroutines and destroys the loop (leak control). *realm* is bound around parsing too."
  ;; A :module source runs through the module loader (its own drive + teardown);
  ;; a :script source runs top-level directly here.
  (if (eq source-type :module)
      (run-module-source source :realm realm)
      (progn
        (let ((*realm* realm))
          (unwind-protect
               (progn
                 (run-program (parse-program source :source-type source-type) realm :strict strict)
                 (drive-jobs realm)
                 (if report-unhandled-rejections-p
                     (report-unhandled-rejections realm)
                     (let ((pending (realm-pending-rejections realm)))
                       (when pending (clrhash pending)))))
            (teardown-coroutines realm)
            (destroy-realm-loop realm)))
        realm)))

(defun indirect-eval (source)
  "Indirect eval: parse SOURCE and run it in the CURRENT realm's global scope,
returning the completion value (§19.2.1). *realm* is already bound by the caller."
  (let ((*current-source-text* source)
        (program (parse-program source :source-type :script))
        (comp (make-comp)))
    (when (program-strict-p program) (setf (comp-strict comp) t))
    (let* ((stmts (program-body program))
           (lexical-env
             (prepare-script-lexical-environment
              stmts comp
              :outer-env (realm-active-script-lexical-environment *realm*)
              :outer-scopes (realm-active-script-lexical-scopes *realm*))))
      (global-instantiate stmts comp lexical-env)
      (let ((result +undefined+))
        (dolist (s stmts result)
          (let ((c (compile-node comp s)))
            (if (expression-statement-p s)
                (setf result (funcall c lexical-env))
                (funcall c lexical-env))))))))

;;; convenience for the REPL/tests: evaluate an expression source, return the value
(defun eval-source (source &key (realm (make-realm)) strict)
  (let* ((*realm* realm)
         (*current-source-text* source)
         (program (parse-program source :source-type :script))
         (comp (make-comp)))
    (when (or strict (program-strict-p program)) (setf (comp-strict comp) t))
    (let* ((body (program-body program))
           (lexical-env (prepare-script-lexical-environment body comp)))
      (unwind-protect
           ;; The script frame is active only for synchronous program evaluation.
           ;; Jobs run after it has been restored, matching RUN-SOURCE's boundary.
           (let ((result
                   (call-with-active-script-lexicals
                    realm lexical-env (comp-scopes comp)
                    (lambda ()
                      (global-instantiate body comp lexical-env)
                      (let ((value +undefined+))
                        (dolist (s body value)
                          (let ((c (compile-node comp s)))
                            (if (expression-statement-p s)
                                (setf value (funcall c lexical-env))
                                (funcall c lexical-env)))))))))
             (drive-jobs realm)
             (report-unhandled-rejections realm)
             result)
        (teardown-coroutines realm)
        (destroy-realm-loop realm)))))
