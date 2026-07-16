;;;; Fail-closed focused Test262 gate for the Phase 25b milestone-6 entry slice.

(in-package :cl-user)
(defparameter *clun-test262-library* t)
(defparameter *clun-test262-distinguish-timeout* t)
(load (merge-pathnames "test262.lisp" *load-truename*))
(in-package :clun.engine)

(defparameter +m6-header+
  '("path" "entry_phase_owner" "entry_work_bucket" "milestone_owner"
    "root_cause" "entry_classification" "required_final"))

(defconstant +m6-path-fnv1a-64+ #xD9A872B337562D21)
(defconstant +m6-fnv1a-64-offset+ #xcbf29ce484222325)
(defconstant +m6-fnv1a-64-prime+ #x100000001b3)
(defconstant +m6-uint64-mask+ #xffffffffffffffff)

(defun m6-prefix-p (prefix string)
  (and (<= (length prefix) (length string))
       (string= prefix string :end2 (length prefix))))

(defun m6-contains-p (needle string)
  (not (null (search needle string))))

(defun m6-split-row (line line-number)
  (when (or (zerop (length line)) (find #\Return line))
    (error "Malformed Phase 25b m6 manifest line ~d" line-number))
  (let ((fields (uiop:split-string line :separator '(#\Tab))))
    (unless (= 7 (length fields))
      (error "Phase 25b m6 manifest line ~d has ~d fields, expected 7"
             line-number (length fields)))
    (when (find "" fields :test #'string=)
      (error "Phase 25b m6 manifest line ~d contains an empty field" line-number))
    fields))

(defun m6-read-manifest (path)
  (with-open-file (input path)
    (let ((header (m6-split-row (or (read-line input nil nil)
                                    (error "Empty Phase 25b m6 manifest: ~a" path))
                                1))
          (rows '())
          (previous nil))
      (unless (equal +m6-header+ header)
        (error "Invalid Phase 25b m6 manifest header: ~s" header))
      (loop for line = (read-line input nil nil)
            for line-number from 2
            while line
            for fields = (m6-split-row line line-number)
            for current = (first fields)
            do (when (and previous (not (string< previous current)))
                 (error "Manifest paths are not strictly sorted and unique at line ~d: ~a"
                        line-number current))
               (setf previous current)
               (push fields rows))
      (nreverse rows))))

(defun m6-root-cause (path)
  (cond
    ((m6-prefix-p "built-ins/Array/fromAsync/" path)
     "array-from-async")
    ((and (m6-contains-p "/async-generator/" path)
          (or (m6-contains-p "eval" path)
              (m6-contains-p "unscopables" path)))
     "direct-eval-with")
    ((m6-prefix-p "built-ins/AsyncFromSyncIteratorPrototype/" path)
     "async-from-sync")
    ((or (m6-prefix-p "statements/for-await-of/" path)
         (string= path "expressions/await/for-await-of-interleaved.js"))
     "for-await-close-order")
    ((and (m6-prefix-p "built-ins/AsyncGeneratorPrototype/" path)
          (m6-contains-p "request-queue" path))
     "async-generator-request-queue")
    ((and (m6-prefix-p "built-ins/AsyncGeneratorPrototype/" path)
          (m6-contains-p "this-val-not-" path))
     "async-generator-brand-rejection")
    ((m6-prefix-p "built-ins/AsyncGeneratorPrototype/return/" path)
     "async-generator-return-await")
    ((and (or (m6-prefix-p "expressions/" path)
              (m6-prefix-p "statements/" path))
          (m6-contains-p "async-gen" path))
     ;; These tests first reject an ordinary yielded promise, then use yield* only
     ;; as the observable continuation. All other yield-star rows enter delegation.
     (if (and (m6-contains-p "yield-star" path)
              (not (m6-contains-p "yield-promise-reject-next-yield-star-" path)))
         "async-generator-delegation"
         "async-generator-yield-await"))
    (t (error "Path is not in the frozen Phase 25b m6 selection: ~a" path))))

(defun m6-static-metadata (path)
  (let ((root (m6-root-cause path)))
    (cond
      ((string= root "array-from-async")
       (list "phase-37" "async-iteration" "phase-37" root "fail" "fail"))
      ((string= root "direct-eval-with")
       (list "phase-25b" "async-iteration" "m11" root "fail" "fail"))
      (t
       (list "phase-25b" "async-iteration" "m6" root "fail" "pass")))))

(defun m6-count (rows column value)
  (count value rows :test #'string= :key (lambda (row) (nth column row))))

(defun m6-require-count (rows column value expected)
  (let ((actual (m6-count rows column value)))
    (unless (= actual expected)
      (error "Phase 25b m6 manifest count for ~a is ~d, expected ~d"
             value actual expected))))

(defun m6-pathname (name)
  (let ((prefix "built-ins/"))
    (if (m6-prefix-p prefix name)
        (merge-pathnames (subseq name (length prefix)) *builtins-root*)
        (merge-pathnames name *lang-root*))))

(defun m6-path-digest (rows)
  (loop with hash = +m6-fnv1a-64-offset+
        for row in rows
        do (loop for character across (concatenate 'string (first row) (string #\Newline))
                 for code = (char-code character)
                 do (unless (< code 256)
                      (error "Non-octet character in Phase 25b m6 path: ~s" character))
                    (setf hash
                          (logand +m6-uint64-mask+
                                  (* (logxor hash code) +m6-fnv1a-64-prime+))))
        finally (return hash)))

(defun m6-validate-static (rows)
  (unless (= 509 (length rows))
    (error "Phase 25b m6 manifest has ~d rows, expected 509" (length rows)))
  (dolist (row rows)
    (let ((path (first row)))
      (unless (equal (rest row) (m6-static-metadata path))
        (error "Invalid static metadata for ~a:~%  got      ~s~%  expected ~s"
               path (rest row) (m6-static-metadata path)))
      (unless (probe-file (m6-pathname path))
        (error "Phase 25b m6 manifest path does not exist: ~a" path))))
  (let ((digest (m6-path-digest rows)))
    (unless (= digest +m6-path-fnv1a-64+)
      (error "Phase 25b m6 path digest is ~16,'0X, expected ~16,'0X"
             digest +m6-path-fnv1a-64+)))
  (dolist (entry '((3 "m6" 407) (3 "m11" 7) (3 "phase-37" 95)
                   (4 "async-generator-delegation" 328)
                   (4 "async-generator-yield-await" 47)
                   (4 "async-from-sync" 9)
                   (4 "for-await-close-order" 6)
                   (4 "async-generator-request-queue" 6)
                   (4 "async-generator-brand-rejection" 6)
                   (4 "async-generator-return-await" 5)
                   (4 "direct-eval-with" 7) (4 "array-from-async" 95)
                   (5 "fail" 509) (6 "pass" 407) (6 "fail" 102)))
    (apply #'m6-require-count rows entry))
  rows)

(defun m6-classification-name (classification)
  (string-downcase (symbol-name classification)))

(defun m6-print-counts (label names table)
  (dolist (name names)
    (format t "~a ~a: pass=~d fail=~d skip=~d tmo=~d crash=~d~%"
            label name
            (gethash (list name "pass") table 0)
            (gethash (list name "fail") table 0)
            (gethash (list name "skip") table 0)
            (gethash (list name "tmo") table 0)
            (gethash (list name "crash") table 0))))

(defun m6-mode ()
  (let ((mode (string-downcase (or (uiop:getenv "CLUN_PHASE_25B_M6_MODE") "final"))))
    (unless (member mode '("entry" "final") :test #'string=)
      (error "CLUN_PHASE_25B_M6_MODE must be entry or final, got ~s" mode))
    mode))

(let* ((manifest-name (or (uiop:getenv "CLUN_PHASE_25B_M6_MANIFEST")
                          "tests/conformance/phase-25b-m6.tsv"))
       (manifest (merge-pathnames manifest-name cl-user::*clun-root*))
       (mode (m6-mode))
       (expected-column (if (string= mode "entry") 5 6))
       (rows (m6-validate-static (m6-read-manifest manifest)))
       (owner-counts (make-hash-table :test #'equal))
       (root-counts (make-hash-table :test #'equal))
       (mismatches '()))
  (format t "=== Phase 25b milestone 6 Test262 ~a slice -- ~d files ===~%"
          mode (length rows))
  (dolist (row rows)
    (destructuring-bind (path phase bucket owner root entry required) row
      (declare (ignore phase bucket entry required))
      (let* ((actual (classify-exec (m6-pathname path)))
             (actual-name (m6-classification-name actual))
             (expected (nth expected-column row)))
        (incf (gethash (list owner actual-name) owner-counts 0))
        (incf (gethash (list root actual-name) root-counts 0))
        (unless (string= actual-name expected)
          (push (list path owner root expected actual-name) mismatches)))))
  (m6-print-counts "owner" '("m6" "m11" "phase-37") owner-counts)
  (m6-print-counts "root"
                   '("async-generator-delegation" "async-generator-yield-await"
                     "async-from-sync" "for-await-close-order"
                     "async-generator-request-queue" "async-generator-brand-rejection"
                     "async-generator-return-await" "direct-eval-with"
                     "array-from-async")
                   root-counts)
  (if mismatches
      (progn
        (format t "~%MISMATCHES (~d):~%" (length mismatches))
        (dolist (mismatch (nreverse mismatches))
          (destructuring-bind (path owner root expected actual) mismatch
            (format t "  ~a [~a/~a]: expected ~a, got ~a~%"
                    path owner root expected actual)))
        (format t "phase-25b-m6 (~a): FAILED~%" mode)
        (sb-ext:exit :code 1))
      (progn
        (if (string= mode "entry")
            (format t "phase-25b-m6 (entry): OK (509 failures; no skip, timeout, or crash)~%")
            (format t "phase-25b-m6 (final): OK (407 owned passes; 7 m11 + 95 Phase-37 controls fail)~%"))
        (sb-ext:exit :code 0))))
