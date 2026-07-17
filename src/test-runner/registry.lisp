;;;; registry.lisp — the test tree (describe/test/hook nodes) and the JS globals that
;;;; register into it (PLAN.md Phase 15). describe(fn) is run at load time to build the
;;;; tree; test(fn) bodies are stashed and run later by the scheduler. Modes come from
;;;; the .skip/.todo/.only/.skipIf/.todoIf/.if variant used.

(in-package :clun.test-runner)

(defstruct (t-describe (:conc-name td-) (:predicate td-p))
  name parent (children '())            ; children in registration order (reversed on close)
  (before-all '()) (before-each '()) (after-all '()) (after-each '())
  (mode :normal))                       ; :normal :skip :todo :only

(defstruct (t-test (:conc-name tt-) (:predicate tt-p))
  name fn parent (mode :normal) (timeout nil)) ; :normal :skip :todo :only :failing

(defstruct (test-context (:conc-name ctx-))
  root current (default-timeout 5000) (has-only nil) (expect-calls 0)
  (mocks '()) (invocation-order 0))

(defun td-ordered-children (d)
  "Children in registration order (they are pushed, so reverse)."
  (reverse (td-children d)))

;;; --- registration helpers ---------------------------------------------------

(defun %opt-timeout (opts)
  "A per-test timeout from the 3rd test() arg: a number (ms) or { timeout }."
  (cond ((eng:js-number-p opts) (truncate (eng:to-number opts)))
        ((and (eng:js-object-p opts)
              (let ((v (eng:js-get opts "timeout"))) (and (eng:js-number-p v) (truncate (eng:to-number v))))))
        (t nil)))

(defun %register-describe (ctx name fn mode)
  (let ((d (make-t-describe :name name :parent (ctx-current ctx) :mode mode)))
    (push d (td-children (ctx-current ctx)))
    (when (eq mode :only) (setf (ctx-has-only ctx) t))
    (when (eng:callable-p fn)
      (let ((prev (ctx-current ctx)))
        (setf (ctx-current ctx) d)
        (unwind-protect (eng:js-call fn eng:+undefined+ '())
          (setf (ctx-current ctx) prev))))
    eng:+undefined+))

(defun %register-test (ctx name fn mode opts)
  (when (and (eq mode :failing) (not (eng:callable-p fn)))
    (eng:throw-type-error "test.failing expects a function as the second argument"))
  (let ((tt (make-t-test :name name :fn (and (eng:callable-p fn) fn)
                         :parent (ctx-current ctx) :mode mode :timeout (%opt-timeout opts))))
    (push tt (td-children (ctx-current ctx)))
    (when (eq mode :only) (setf (ctx-has-only ctx) t))
    eng:+undefined+))

(defun %each-rows (table)
  "The rows of a .each table (a JS array); each row is passed as args to the body."
  (if (eng:js-array-p table) (eng:array-like->list table) '()))

(defun %each-name (template row-args index)
  "Substitute %s/%d/%i/%j/%o/%p (positional, consuming ROW-ARGS in order), %# (index),
and %% in a .each name template. A documented subset of Bun's printf-style names."
  (let ((out (make-string-output-stream)) (i 0) (n (length template)) (args row-args))
    (loop while (< i n) do
      (let ((c (char template i)))
        (if (and (char= c #\%) (< (1+ i) n))
            (let ((d (char template (1+ i))))
              (case d
                (#\# (write-string (princ-to-string index) out))
                (#\% (write-char #\% out))
                ((#\s #\d #\i #\j #\o #\p)
                 (write-string (eng:to-string (if args (pop args) eng:+undefined+)) out))
                (t (write-char c out) (write-char d out)))
              (incf i 2))
            (progn (write-char c out) (incf i)))))
    (get-output-stream-string out)))

;;; --- the test()/describe() function objects (with .skip/.only/... variants) --

(defun %fn (name arity impl) (eng:make-native-function name arity impl))

(defun %make-test-callable (ctx)
  "Build the `test` function object with its modifier properties. `it` is an alias."
  (labels ((reg (mode) (lambda (this args) (declare (ignore this))
                         (%register-test ctx (eng:to-string (eng:arg args 0)) (eng:arg args 1)
                                         mode (eng:arg args 2))))
           (base (mode name) (%fn name 2 (reg mode)))
           (cond-variant (name true-mode false-mode)
             (%fn name 1 (lambda (this args) (declare (ignore this))
                           (let ((m (if (eng:js-truthy (eng:arg args 0)) true-mode false-mode)))
                             (base m "")))))
           (each-variant (mode)
             (%fn "each" 1
               (lambda (this args)
                 (declare (ignore this))
                 (let ((rows (%each-rows (eng:arg args 0))))
                   (%fn "" 2
                     (lambda (th a)
                       (declare (ignore th))
                       (let ((tmpl (eng:to-string (eng:arg a 0)))
                             (fn (eng:arg a 1))
                             (opts (eng:arg a 2))
                             (idx 0))
                         (when (and (eq mode :failing) (not (eng:callable-p fn)))
                           (eng:throw-type-error
                            "test.failing expects a function as the second argument"))
                         (dolist (row rows)
                           (let* ((rargs (if (eng:js-array-p row)
                                             (eng:array-like->list row)
                                             (list row)))
                                  (nm (%each-name tmpl rargs idx)))
                             (%register-test
                              ctx nm
                              (%fn "" 0
                                (lambda (tt2 aa2)
                                  (declare (ignore tt2 aa2))
                                  (eng:js-call fn eng:+undefined+ rargs)))
                              mode opts))
                           (incf idx))
                         eng:+undefined+))))))))
    (let ((test (base :normal "test"))
          (skip (base :skip "skip"))
          (only (base :only "only"))
          (todo (base :todo "todo"))
          (failing (base :failing "failing")))
      (eng:data-prop test "skip" skip)
      (eng:data-prop test "only" only)
      (eng:data-prop test "todo" todo)
      (eng:data-prop test "failing" failing)
      (eng:data-prop test "skipIf" (cond-variant "skipIf" :skip :normal))
      (eng:data-prop test "todoIf" (cond-variant "todoIf" :todo :normal))
      (eng:data-prop test "failingIf" (cond-variant "failingIf" :failing :normal))
      (eng:data-prop test "if" (cond-variant "if" :normal :skip))
      (eng:data-prop test "each" (each-variant :normal))
      (eng:data-prop skip "each" (each-variant :skip))
      (eng:data-prop only "each" (each-variant :only))
      (eng:data-prop todo "each" (each-variant :todo))
      (eng:data-prop failing "each" (each-variant :failing))
      test)))

(defun %make-describe-callable (ctx)
  (labels ((reg (mode) (lambda (this args) (declare (ignore this))
                         (%register-describe ctx (eng:to-string (eng:arg args 0)) (eng:arg args 1) mode))))
    (let ((d (%fn "describe" 2 (reg :normal))))
      (eng:data-prop d "skip" (%fn "skip" 2 (reg :skip)))
      (eng:data-prop d "only" (%fn "only" 2 (reg :only)))
      (eng:data-prop d "todo" (%fn "todo" 2 (reg :todo)))
      d)))

(defun %hook (ctx slot)
  "A before*/after* hook global: append the callback to the CURRENT describe's list."
  (%fn "" 1 (lambda (this args) (declare (ignore this))
              (let ((fn (eng:arg args 0)) (d (ctx-current ctx)))
                (when (eng:callable-p fn)
                  (ecase slot
                    (:before-all (push fn (td-before-all d)))
                    (:before-each (push fn (td-before-each d)))
                    (:after-all (push fn (td-after-all d)))
                    (:after-each (push fn (td-after-each d)))))
                eng:+undefined+))))

(defun install-test-globals (realm ctx)
  "Install describe/test/it + hooks + setDefaultTimeout on REALM's global, all
registering into CTX's tree. expect is installed separately (install-expect)."
  (let ((eng:*realm* realm) (g (eng:realm-global realm)))
    (eng:hidden-prop g "describe" (%make-describe-callable ctx))
    (let ((test (%make-test-callable ctx)))
      (eng:hidden-prop g "test" test)
      (eng:hidden-prop g "it" test))
    (eng:hidden-prop g "beforeAll" (%hook ctx :before-all))
    (eng:hidden-prop g "beforeEach" (%hook ctx :before-each))
    (eng:hidden-prop g "afterAll" (%hook ctx :after-all))
    (eng:hidden-prop g "afterEach" (%hook ctx :after-each))
    (eng:hidden-prop g "setDefaultTimeout"
      (%fn "setDefaultTimeout" 1
        (lambda (this args) (declare (ignore this))
          (setf (ctx-default-timeout ctx) (max 0 (truncate (eng:to-number (eng:arg args 0)))))
          eng:+undefined+)))
    (install-test-mocks realm ctx)
    (install-expect realm ctx)
    ctx))
