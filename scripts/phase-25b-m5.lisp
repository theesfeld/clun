;;;; Fail-closed focused Test262 gate for the Phase 25b milestone-5 entry slice.

(in-package :cl-user)
(defparameter *clun-test262-library* t)
(defparameter *clun-test262-distinguish-timeout* t)
(load (merge-pathnames "test262.lisp" *load-truename*))
(in-package :clun.engine)

(defparameter +m5-header+
  '("path" "entry_phase_owner" "entry_work_bucket" "milestone_owner"
    "root_cause" "entry_classification" "required_final"))

(defparameter +m5-generator-intrinsics+
  '("built-ins/Function/prototype/toString/GeneratorFunction.js"
    "built-ins/GeneratorFunction/instance-construct-throws.js"
    "built-ins/GeneratorFunction/instance-prototype.js"
    "built-ins/GeneratorFunction/instance-restricted-properties.js"
    "built-ins/GeneratorFunction/instance-yield-expr-in-param.js"
    "built-ins/GeneratorFunction/invoked-as-constructor-no-arguments.js"
    "built-ins/GeneratorFunction/invoked-as-function-multiple-arguments.js"
    "built-ins/GeneratorFunction/invoked-as-function-no-arguments.js"
    "built-ins/GeneratorFunction/invoked-as-function-single-argument.js"
    "built-ins/GeneratorFunction/name.js"
    "built-ins/GeneratorFunction/prototype/Symbol.toStringTag.js"
    "built-ins/GeneratorFunction/prototype/constructor.js"
    "built-ins/GeneratorFunction/prototype/not-callable.js"
    "built-ins/GeneratorFunction/prototype/prototype.js"
    "built-ins/GeneratorPrototype/constructor.js"
    "built-ins/GeneratorPrototype/next/length.js"
    "built-ins/GeneratorPrototype/next/name.js"
    "built-ins/GeneratorPrototype/next/property-descriptor.js"
    "built-ins/GeneratorPrototype/return/length.js"
    "built-ins/GeneratorPrototype/return/name.js"
    "built-ins/GeneratorPrototype/return/property-descriptor.js"
    "built-ins/GeneratorPrototype/throw/length.js"
    "built-ins/GeneratorPrototype/throw/name.js"
    "built-ins/GeneratorPrototype/throw/property-descriptor.js"
    "built-ins/Object/prototype/toString/symbol-tag-generators-builtin.js"
    "expressions/generators/default-proto.js"
    "expressions/generators/prototype-relation-to-function.js"
    "statements/class/subclass/builtin-objects/GeneratorFunction/instance-prototype.js"
    "statements/class/subclass/builtin-objects/GeneratorFunction/regular-subclassing.js"
    "statements/generators/default-proto.js"
    "statements/generators/prototype-relation-to-function.js"))

(defparameter +m5-direct-eval-with+
  '("expressions/generators/eval-var-scope-syntax-err.js"
    "expressions/generators/named-strict-error-reassign-fn-name-in-body-in-eval.js"
    "expressions/generators/scope-body-lex-distinct.js"
    "expressions/generators/unscopables-with-in-nested-fn.js"
    "expressions/generators/unscopables-with.js"
    "expressions/object/method-definition/gen-meth-eval-var-scope-syntax-err.js"
    "expressions/object/scope-gen-meth-body-lex-distinct.js"
    "expressions/yield/from-with.js"
    "statements/generators/eval-var-scope-syntax-err.js"
    "statements/generators/scope-body-lex-distinct.js"
    "statements/generators/unscopables-with-in-nested-fn.js"
    "statements/generators/unscopables-with.js"))

(defparameter +m5-binding-patterns+
  '("expressions/generators/eval-var-scope-syntax-err.js"
    "expressions/object/method-definition/gen-meth-eval-var-scope-syntax-err.js"
    "statements/generators/eval-var-scope-syntax-err.js"))

(defparameter +m5-yield-grammar+
  '("expressions/generators/yield-as-function-expression-binding-identifier.js"
    "expressions/generators/yield-star-before-newline.js"
    "expressions/object/method-definition/yield-as-function-expression-binding-identifier.js"
    "expressions/object/method-definition/yield-star-before-newline.js"
    "statements/class/definition/methods-gen-yield-star-before-newline.js"
    "statements/generators/yield-as-function-expression-binding-identifier.js"
    "statements/generators/yield-star-before-newline.js"))

(defparameter +m5-yield-delegation+
  '("expressions/yield/star-iterable.js"
    "expressions/yield/star-rhs-iter-nrml-res-done-no-value.js"
    "expressions/yield/star-rhs-iter-rtrn-res-done-no-value.js"
    "expressions/yield/star-rhs-iter-thrw-res-done-no-value.js"))

(defun m5-split-row (line line-number)
  (when (or (zerop (length line)) (find #\Return line))
    (error "Malformed Phase 25b m5 manifest line ~d" line-number))
  (let ((fields (uiop:split-string line :separator '(#\Tab))))
    (unless (= 7 (length fields))
      (error "Phase 25b m5 manifest line ~d has ~d fields, expected 7"
             line-number (length fields)))
    (when (find "" fields :test #'string=)
      (error "Phase 25b m5 manifest line ~d contains an empty field" line-number))
    fields))

(defun m5-read-manifest (path)
  (with-open-file (input path)
    (let ((header (m5-split-row (or (read-line input nil nil)
                                    (error "Empty Phase 25b m5 manifest: ~a" path))
                                1))
          (rows '())
          (previous nil))
      (unless (equal +m5-header+ header)
        (error "Invalid Phase 25b m5 manifest header: ~s" header))
      (loop for line = (read-line input nil nil)
            for line-number from 2
            while line
            for fields = (m5-split-row line line-number)
            for current = (first fields)
            do (when (and previous (not (string< previous current)))
                 (error "Manifest paths are not strictly sorted and unique at line ~d: ~a"
                        line-number current))
               (setf previous current)
               (push fields rows))
      (nreverse rows))))

(defun m5-root-cause (path)
  (cond
    ((string= path "built-ins/Math/sumPrecise/takes-iterable.js")
     "math-sum-precise")
    ((string= path "expressions/object/method-definition/generator-prototype-prop.js")
     "generator-method-prototype")
    ((member path +m5-direct-eval-with+ :test #'string=) "direct-eval-with")
    ((member path +m5-yield-grammar+ :test #'string=) "yield-grammar")
    ((member path +m5-yield-delegation+ :test #'string=) "yield-delegation")
    ((member path +m5-generator-intrinsics+ :test #'string=) "generator-intrinsics")
    (t (error "Path is not in the frozen Phase 25b m5 selection: ~a" path))))

(defun m5-static-metadata (path)
  (let ((root (m5-root-cause path)))
    (cond
      ((string= root "math-sum-precise")
       (list "phase-37" "generators" "phase-37" root "fail" "fail"))
      ((string= root "direct-eval-with")
       (list "phase-25b"
             (if (member path +m5-binding-patterns+ :test #'string=)
                 "binding-patterns"
                 "generators")
             "m11" root "fail" "fail"))
      (t
       (list "phase-25b" "generators" "m5" root "fail" "pass")))))

(defun m5-count (rows column value)
  (count value rows :test #'string= :key (lambda (row) (nth column row))))

(defun m5-require-count (rows column value expected)
  (let ((actual (m5-count rows column value)))
    (unless (= actual expected)
      (error "Phase 25b m5 manifest count for ~a is ~d, expected ~d"
             value actual expected))))

(defun m5-pathname (name)
  (let ((prefix "built-ins/"))
    (if (and (>= (length name) (length prefix))
             (string= prefix name :end2 (length prefix)))
        (merge-pathnames (subseq name (length prefix)) *builtins-root*)
        (merge-pathnames name *lang-root*))))

(defun m5-validate-static (rows)
  (unless (= 56 (length rows))
    (error "Phase 25b m5 manifest has ~d rows, expected 56" (length rows)))
  (dolist (row rows)
    (let ((path (first row)))
      (unless (equal (rest row) (m5-static-metadata path))
        (error "Invalid static metadata for ~a:~%  got      ~s~%  expected ~s"
               path (rest row) (m5-static-metadata path)))
      (unless (probe-file (m5-pathname path))
        (error "Phase 25b m5 manifest path does not exist: ~a" path))))
  (dolist (entry '((3 "m5" 43) (3 "m11" 12) (3 "phase-37" 1)
                   (4 "generator-intrinsics" 31)
                   (4 "generator-method-prototype" 1)
                   (4 "yield-grammar" 7) (4 "yield-delegation" 4)
                   (4 "direct-eval-with" 12) (4 "math-sum-precise" 1)
                   (5 "fail" 56) (6 "pass" 43) (6 "fail" 13)))
    (apply #'m5-require-count rows entry))
  rows)

(defun m5-classification-name (classification)
  (string-downcase (symbol-name classification)))

(defun m5-print-counts (label names table)
  (dolist (name names)
    (format t "~a ~a: pass=~d fail=~d skip=~d tmo=~d crash=~d~%"
            label name
            (gethash (list name "pass") table 0)
            (gethash (list name "fail") table 0)
            (gethash (list name "skip") table 0)
            (gethash (list name "tmo") table 0)
            (gethash (list name "crash") table 0))))

(let* ((manifest-name (or (uiop:getenv "CLUN_PHASE_25B_M5_MANIFEST")
                          "tests/conformance/phase-25b-m5.tsv"))
       (manifest (merge-pathnames manifest-name cl-user::*clun-root*))
       (rows (m5-validate-static (m5-read-manifest manifest)))
       (owner-counts (make-hash-table :test #'equal))
       (root-counts (make-hash-table :test #'equal))
       (mismatches '()))
  (format t "=== Phase 25b milestone 5 Test262 slice -- ~d files ===~%" (length rows))
  (dolist (row rows)
    (destructuring-bind (path phase bucket owner root entry required) row
      (declare (ignore phase bucket entry))
      (let* ((actual (classify-exec (m5-pathname path)))
             (actual-name (m5-classification-name actual)))
        (incf (gethash (list owner actual-name) owner-counts 0))
        (incf (gethash (list root actual-name) root-counts 0))
        (unless (string= actual-name required)
          (push (list path owner root required actual-name) mismatches)))))
  (m5-print-counts "owner" '("m5" "m11" "phase-37") owner-counts)
  (m5-print-counts "root"
                   '("generator-intrinsics" "generator-method-prototype"
                     "yield-grammar" "yield-delegation" "direct-eval-with"
                     "math-sum-precise")
                   root-counts)
  (if mismatches
      (progn
        (format t "~%MISMATCHES (~d):~%" (length mismatches))
        (dolist (mismatch (nreverse mismatches))
          (destructuring-bind (path owner root required actual) mismatch
            (format t "  ~a [~a/~a]: required ~a, got ~a~%"
                    path owner root required actual)))
        (format t "phase-25b-m5: FAILED~%")
        (sb-ext:exit :code 1))
      (progn
        (format t "phase-25b-m5: OK (43 owned passes; 12 m11 + 1 phase-37 controls fail)~%")
        (sb-ext:exit :code 0))))
