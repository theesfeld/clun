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
                                                   (function-node-body fd) name
                                                   :generator (function-node-generator fd)
                                                   :async (function-node-async fd))
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

(defun drive-jobs (realm)
  "Run the event loop (Promise microtasks, timers, nextTick) to idle, if one exists."
  (let ((l (realm-loop realm))) (when l (lp:run-loop l))))

(defun destroy-realm-loop (realm)
  (let ((l (realm-loop realm)))
    (when l (ignore-errors (lp:destroy-event-loop l)) (setf (realm-loop realm) nil))))

(defun run-source (source &key (realm (make-realm)) strict (source-type :script))
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
                 (report-unhandled-rejections realm))
            (teardown-coroutines realm)
            (destroy-realm-loop realm)))
        realm)))

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
    (unwind-protect
         ;; return the completion value of the last expression statement, after
         ;; draining the job loop (so promise reactions/timers have run)
         (let ((body (program-body program)) (result +undefined+))
           (dolist (s body)
             (let ((c (compile-node comp s)))
               (if (expression-statement-p s)
                   (setf result (funcall c nil))
                   (funcall c nil))))
           (drive-jobs realm)
           (report-unhandled-rejections realm)
           result)
      (teardown-coroutines realm)
      (destroy-realm-loop realm))))
