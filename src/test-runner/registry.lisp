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
  name fn parent (args '()) (mode :normal) (failing nil)
  (timeout nil) (retry nil) (repeats nil))

(defstruct (test-context (:conc-name ctx-))
  root current (default-timeout 5000) (has-only nil) (expect-calls 0)
  (mocks '()) (invocation-order 0)
  (custom-matchers (make-hash-table :test #'equal)))

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

(defun %opt-count (opts name)
  (when (eng:js-object-p opts)
    (let ((value (eng:js-get opts name)))
      (when (eng:js-number-p value)
        (max 0 (truncate (eng:to-number value)))))))

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

(defun %register-test (ctx name fn mode opts &optional failing call-args)
  (when (and failing (not (eng:callable-p fn)))
    (eng:throw-type-error "test.failing expects a function as the second argument"))
  (let ((retry (%opt-count opts "retry"))
        (repeats (%opt-count opts "repeats")))
    (when (and retry repeats)
      (eng:throw-type-error "Cannot set both retry and repeats on a test"))
    (let ((tt (make-t-test :name name :fn (and (eng:callable-p fn) fn)
                           :parent (ctx-current ctx) :args (or call-args '())
                           :mode mode :failing failing
                           :timeout (%opt-timeout opts) :retry retry :repeats repeats)))
      (push tt (td-children (ctx-current ctx)))
      (when (eq mode :only) (setf (ctx-has-only ctx) t))
      eng:+undefined+)))

(defun %each-rows (table)
  "The rows of a .each table (a JS array); each row is passed as args to the body."
  (if (eng:js-array-p table) (eng:array-like->list table) '()))

(defun %each-format-value (directive value)
  (case directive
    (#\s (eng:to-string value))
    ((#\d #\f) (eng:to-string (eng:to-number value)))
    (#\i
     (let ((number (eng:to-number value)))
       (if (eng:js-finite-p number)
           (princ-to-string (truncate number))
           (eng:to-string number))))
    (#\j
     (let* ((json (eng:js-get (eng:realm-global eng:*realm*) "JSON"))
            (stringify (eng:js-get json "stringify")))
       (eng:to-string (eng:js-call stringify json (list value)))))
    ((#\o #\p) (eng:inspect-value value))
    (t (eng:to-string value))))

(defun %each-path-value (root path)
  (let ((value root) (start 0) (length (length path)))
    (loop
      for dot = (position #\. path :start start)
      for end = (or dot length)
      do (setf value (eng:js-get value (subseq path start end)))
      when (null dot) return value
      do (setf start (1+ dot)))))

(defun %each-title-value (value)
  (if (eng:js-object-p value) (eng:inspect-value value) (eng:to-string value)))

(defun %each-path-char-p (char)
  (or (alphanumericp char) (char= char #\_) (char= char #\.)))

(defun %each-name (template row-args index)
  "Substitute %s/%d/%i/%f/%j/%o/%p (positional, consuming ROW-ARGS in order), %# (index),
%%, and object-row $property/$property.path/$# forms in a .each name template."
  (let ((out (make-string-output-stream)) (i 0) (n (length template)) (args row-args))
    (loop while (< i n) do
      (let ((c (char template i)))
        (cond
          ((and (char= c #\%) (< (1+ i) n))
           (let ((d (char template (1+ i))))
             (case d
               (#\# (write-string (princ-to-string index) out))
               (#\% (write-char #\% out))
               ((#\s #\d #\i #\f #\j #\o #\p)
                (write-string (%each-format-value
                               d (if args (pop args) eng:+undefined+))
                              out))
               (t (write-char c out) (write-char d out)))
             (incf i 2)))
          ((and (char= c #\$) (< (1+ i) n))
           (let ((next (char template (1+ i))))
             (cond
               ((char= next #\$)
                (write-char #\$ out)
                (incf i 2))
               ((char= next #\#)
                (write-string (princ-to-string index) out)
                (incf i 2))
               ((or (alpha-char-p next) (char= next #\_))
                (let ((end (+ i 2)))
                  (loop while (and (< end n) (%each-path-char-p (char template end)))
                        do (incf end))
                  (write-string
                   (%each-title-value
                    (%each-path-value (if row-args (first row-args) eng:+undefined+)
                                      (subseq template (1+ i) end)))
                   out)
                  (setf i end)))
               (t
                (write-char c out)
                (incf i)))))
          (t
           (write-char c out)
           (incf i)))))
    (get-output-stream-string out)))

;;; --- the test()/describe() function objects (with .skip/.only/... variants) --

(defun %fn (name arity impl) (eng:make-native-function name arity impl))

(defun %make-test-callable (ctx)
  "Build the `test` function object with its modifier properties. `it` is an alias."
  (labels
      ((member-name (mode failing)
         (if failing
             "failing"
             (ecase mode
               (:normal "test") (:skip "skip") (:only "only") (:todo "todo"))))
       (register-one (mode failing args)
         (%register-test ctx (eng:to-string (eng:arg args 0)) (eng:arg args 1)
                         mode (eng:arg args 2) failing))
       (make-member (mode failing rows bound-p)
         (%fn (member-name mode failing) 2
           (lambda (this args)
             (declare (ignore this))
             (if (not bound-p)
                 (register-one mode failing args)
                 (let ((tmpl (eng:to-string (eng:arg args 0)))
                       (fn (eng:arg args 1))
                       (opts (eng:arg args 2))
                       (idx 0))
                   (when (and failing (not (eng:callable-p fn)))
                     (eng:throw-type-error
                      "test.failing expects a function as the second argument"))
                   (dolist (row rows)
                     (let* ((rargs (if (eng:js-array-p row)
                                       (eng:array-like->list row)
                                       (list row)))
                            (nm (%each-name tmpl rargs idx)))
                       (%register-test ctx nm fn mode opts failing rargs))
                     (incf idx))
                   eng:+undefined+)))))
       (make-family (rows bound-p requested-mode requested-failing)
         (let ((members (make-hash-table :test #'equal)))
           (dolist (mode '(:normal :skip :only :todo))
             (dolist (failing '(nil t))
               (setf (gethash (list mode failing) members)
                     (make-member mode failing rows bound-p))))
           (flet ((lookup (mode failing)
                    (gethash (list mode failing) members)))
             (maphash
              (lambda (key member)
                (destructuring-bind (mode failing) key
                  (eng:data-prop member "skip" (lookup :skip failing))
                  (eng:data-prop member "only" (lookup :only failing))
                  (eng:data-prop member "todo" (lookup :todo failing))
                  (eng:data-prop member "failing" (lookup mode t))
                  (eng:data-prop member "if"
                    (%fn "if" 1
                      (lambda (this args)
                        (declare (ignore this))
                        (if (eng:js-truthy (eng:arg args 0))
                            member
                            (lookup :skip failing)))))
                  (eng:data-prop member "skipIf"
                    (%fn "skipIf" 1
                      (lambda (this args)
                        (declare (ignore this))
                        (if (eng:js-truthy (eng:arg args 0))
                            (lookup :skip failing)
                            member))))
                  (eng:data-prop member "todoIf"
                    (%fn "todoIf" 1
                      (lambda (this args)
                        (declare (ignore this))
                        (if (eng:js-truthy (eng:arg args 0))
                            (lookup :todo failing)
                            member))))
                  (eng:data-prop member "failingIf"
                    (%fn "failingIf" 1
                      (lambda (this args)
                        (declare (ignore this))
                        (if (eng:js-truthy (eng:arg args 0))
                            (lookup mode t)
                            member))))
                  (eng:data-prop member "each"
                    (%fn "each" 1
                      (lambda (this args)
                        (declare (ignore this))
                        (make-family (%each-rows (eng:arg args 0)) t
                                     mode failing))))))
              members)
             (lookup requested-mode requested-failing)))))
    (make-family '() nil :normal nil)))

(defun %make-describe-callable (ctx)
  (labels
      ((member-name (mode)
         (ecase mode
           (:normal "describe") (:skip "skip") (:only "only") (:todo "todo")))
       (make-member (mode rows bound-p)
         (%fn (member-name mode) 2
           (lambda (this args)
             (declare (ignore this))
             (if (not bound-p)
                 (%register-describe ctx (eng:to-string (eng:arg args 0))
                                     (eng:arg args 1) mode)
                 (let ((tmpl (eng:to-string (eng:arg args 0)))
                       (fn (eng:arg args 1))
                       (idx 0))
                   (unless (eng:callable-p fn)
                     (eng:throw-type-error
                      "describe.each expects a function as the second argument"))
                   (dolist (row rows)
                     (let* ((rargs (if (eng:js-array-p row)
                                       (eng:array-like->list row)
                                       (list row)))
                            (nm (%each-name tmpl rargs idx)))
                       (%register-describe
                        ctx nm
                        (%fn "" 0
                          (lambda (tt2 aa2)
                            (declare (ignore tt2 aa2))
                            (eng:js-call fn eng:+undefined+ rargs)))
                        mode))
                     (incf idx))
                   eng:+undefined+)))))
       (make-family (rows bound-p requested-mode)
         (let ((members (make-hash-table :test #'eq)))
           (dolist (mode '(:normal :skip :only :todo))
             (setf (gethash mode members) (make-member mode rows bound-p)))
           (flet ((lookup (mode) (gethash mode members)))
             (maphash
              (lambda (mode member)
                (eng:data-prop member "skip" (lookup :skip))
                (eng:data-prop member "only" (lookup :only))
                (eng:data-prop member "todo" (lookup :todo))
                (eng:data-prop member "if"
                  (%fn "if" 1
                    (lambda (this args)
                      (declare (ignore this))
                      (if (eng:js-truthy (eng:arg args 0)) member (lookup :skip)))))
                (eng:data-prop member "skipIf"
                  (%fn "skipIf" 1
                    (lambda (this args)
                      (declare (ignore this))
                      (if (eng:js-truthy (eng:arg args 0)) (lookup :skip) member))))
                (eng:data-prop member "todoIf"
                  (%fn "todoIf" 1
                    (lambda (this args)
                      (declare (ignore this))
                      (if (eng:js-truthy (eng:arg args 0)) (lookup :todo) member))))
                (eng:data-prop member "each"
                  (%fn "each" 1
                    (lambda (this args)
                      (declare (ignore this))
                      (make-family (%each-rows (eng:arg args 0)) t mode)))))
              members)
             (lookup requested-mode)))))
    (make-family '() nil :normal)))

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
