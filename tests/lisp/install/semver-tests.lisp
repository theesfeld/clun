;;;; semver-tests.lisp — replays node-semver's own test-vector fixtures against the
;;;; pure-CL port (clun.install). Each define-test reads one JSON fixture from
;;;; tests/fixtures/semver/ (a plain array of arrays) via sys:parse-json and asserts
;;;; the expected outcome for every vector. Fixtures + formats: see Phase 21 brief.
;;;; The 3 invalid-versions vectors whose input is a JS object ({}) are skipped and
;;;; counted (a CL string API has no non-string input to reject) — the sole deviation.

(in-package :clun-test)

(defvar *sv-fixtures*
  (merge-pathnames "tests/fixtures/semver/" (asdf:system-source-directory :clun))
  "Directory holding the node-semver JSON fixtures.")

(defun sv-load (name)
  "Read fixture NAME (e.g. \"comparisons.json\") into a simple-vector of vectors."
  (sys:parse-json (sys:read-file-string (merge-pathnames name *sv-fixtures*))))

;;; --- opt decoding -----------------------------------------------------------

;; An `opt` element is either a boolean (= loose) or a JSON object with loose /
;; includePrerelease keys. Missing → both nil. Returns (values loose includePre).
(defun sv-opt (opt)
  (cond
    ((or (null opt) (eq opt :sv-none)) (values nil nil))
    ((eq opt sys:json-true) (values t nil))
    ((eq opt sys:json-false) (values nil nil))
    ((eq opt :empty-object) (values nil nil))
    ((sys:jobject-p opt)
     ;; loose is truthy for any non-false/non-null value (node parseOptions).
     (values (sv-truthy (sys:jget opt "loose" :sv-absent))
             (sv-truthy (sys:jget opt "includePrerelease" :sv-absent))))
    (t (values nil nil))))

(defun sv-truthy (v)
  "JS truthiness for a parsed-JSON option value (absent/false/null/0/'' → nil)."
  (cond ((eq v :sv-absent) nil)
        ((eq v sys:json-true) t)
        ((eq v sys:json-false) nil)
        ((eq v sys:json-null) nil)
        ((numberp v) (/= v 0))
        ((stringp v) (plusp (length v)))
        (t t)))

(defun sv-nth (row i &optional (default :sv-none))
  "Nth element of a fixture row (simple-vector), or DEFAULT if out of range."
  (if (< i (length row)) (aref row i) default))

;;; --- prerelease/build component comparison ----------------------------------

(defun sv-component= (got expected)
  "Compare one parsed prerelease/build component against the JSON fixture value.
Fixture numbers are double-floats; our numeric ids are integers."
  (cond ((integerp got) (and (numberp expected) (= got expected)))
        ((stringp got) (and (stringp expected) (string= got expected)))
        (t nil)))

(defun sv-list=vector (list vec)
  "True iff LIST (parsed components) matches the JSON VEC element-wise."
  (and (= (length list) (length vec))
       (loop for x in list for i from 0 always (sv-component= x (aref vec i)))))

;;; --- valid-versions ---------------------------------------------------------

(define-test semver-valid-versions
  (let ((rows (sv-load "valid-versions.json")) (pass 0))
    (loop for row across rows
          for input = (aref row 0)
          do (let ((sv (clun.install:parse-version input)))
               (is = (aref row 1) (clun.install:semver-major sv) "~a major" input)
               (is = (aref row 2) (clun.install:semver-minor sv) "~a minor" input)
               (is = (aref row 3) (clun.install:semver-patch sv) "~a patch" input)
               (true (sv-list=vector (clun.install:semver-prerelease sv) (aref row 4))
                     "~a prerelease" input)
               (true (sv-list=vector (clun.install:semver-build sv) (aref row 5))
                     "~a build" input)
               (incf pass)))
    (is = (length rows) pass "valid-versions vectors run")))

;;; --- invalid-versions (skip the 3 {} object inputs) -------------------------

(define-test semver-invalid-versions
  (let ((rows (sv-load "invalid-versions.json")) (pass 0) (skipped 0))
    (loop for row across rows
          for input = (aref row 0)
          do (if (or (sys:jobject-p input) (eq input :empty-object))
                 (incf skipped) ; JS non-string input — N/A for a CL string API
                 (multiple-value-bind (loose incp) (sv-opt (sv-nth row 2))
                   (declare (ignore incp))
                   (false (clun.install:version-valid-p input :loose loose)
                          "~a should be invalid" input)
                   (incf pass))))
    (is = 3 skipped "documented {} deviations skipped")
    (is = (- (length rows) 3) pass "invalid-versions vectors run")))

(define-test semver-strict-equals-prefix-option
  (fail (clun.install:parse-version "=1.2.3") clun.install:invalid-version)
  (is equal "1.2.3"
      (clun.install:semver-version
       (clun.install:parse-version "= 1.2.3" :allow-equals-prefix t)))
  (dolist (input '("01.2.3" "1" "1.2"))
    (fail (clun.install:parse-version input :allow-equals-prefix t)
          clun.install:invalid-version)))

;;; --- comparisons (greater > lesser both directions) -------------------------

(define-test semver-comparisons
  (let ((rows (sv-load "comparisons.json")) (pass 0))
    (loop for row across rows
          for greater = (aref row 0)
          for lesser = (aref row 1)
          do (multiple-value-bind (loose incp) (sv-opt (sv-nth row 2))
               (declare (ignore incp))
               (is = 1 (clun.install:version-compare greater lesser :loose loose)
                   "~a > ~a" greater lesser)
               (is = -1 (clun.install:version-compare lesser greater :loose loose)
                   "~a < ~a" lesser greater)
               (incf pass)))
    (is = (length rows) pass "comparisons vectors run")))

;;; --- equality (build metadata ignored) --------------------------------------

(define-test semver-equality
  (let ((rows (sv-load "equality.json")) (pass 0))
    (loop for row across rows
          for a = (aref row 0)
          for b = (aref row 1)
          do (multiple-value-bind (loose incp) (sv-opt (sv-nth row 2))
               (declare (ignore incp))
               (true (clun.install:version-equal a b :loose loose) "~a == ~a" a b)
               (incf pass)))
    (is = (length rows) pass "equality vectors run")))

;;; --- increments -------------------------------------------------------------

;; [version, releaseType, result, opt?, identifier?, identifierBase?]. result may
;; be null (invalid). identifier is a string; identifierBase, when present as false,
;; disables the numeric suffix (maps to :false); a string base maps through.
(define-test semver-increments
  (let ((rows (sv-load "increments.json")) (pass 0))
    (loop for row across rows
          for version = (aref row 0)
          for release = (aref row 1)
          for result = (aref row 2)
          do (multiple-value-bind (loose incp) (sv-opt (sv-nth row 3))
               (declare (ignore incp))
               (let* ((id-raw (sv-nth row 4))
                      (identifier (cond ((eq id-raw :sv-none) nil)
                                        ((stringp id-raw) id-raw)
                                        (t nil)))
                      (base-raw (sv-nth row 5))
                      (identifier-base (cond ((eq base-raw :sv-none) :unset)
                                             ((eq base-raw sys:json-false) :false)
                                             (t base-raw)))
                      (expected (if (eq result sys:json-null) nil result))
                      (got (clun.install:version-inc version release
                                                     :loose loose
                                                     :identifier identifier
                                                     :identifier-base identifier-base)))
                 (if expected
                     (is equal expected got "inc ~a ~a id=~a base=~a" version release
                         identifier base-raw)
                     (false got "inc ~a ~a should be null" version release))
                 (incf pass))))
    (is = (length rows) pass "increments vectors run")))

;;; --- truncations ------------------------------------------------------------

(define-test semver-truncations
  (let ((rows (sv-load "truncations.json")) (pass 0))
    (loop for row across rows
          for version = (aref row 0)
          for truncation = (aref row 1)
          for result = (aref row 2)
          do (multiple-value-bind (loose incp) (sv-opt (sv-nth row 3))
               (declare (ignore incp))
               (let ((expected (if (eq result sys:json-null) nil result))
                     (got (clun.install:version-truncate version truncation :loose loose)))
                 (if expected
                     (is equal expected got "truncate ~a ~a" version truncation)
                     (false got "truncate ~a ~a should be null" version truncation))
                 (incf pass))))
    (is = (length rows) pass "truncations vectors run")))

;;; --- range-include / range-exclude ------------------------------------------

(define-test semver-range-include
  (let ((rows (sv-load "range-include.json")) (pass 0))
    (loop for row across rows
          for range = (aref row 0)
          for version = (aref row 1)
          do (multiple-value-bind (loose incp) (sv-opt (sv-nth row 2))
               (true (clun.install:version-satisfies version range
                                                     :loose loose :include-prerelease incp)
                     "~a satisfies ~a" version range)
               (incf pass)))
    (is = (length rows) pass "range-include vectors run")))

(define-test semver-range-exclude
  (let ((rows (sv-load "range-exclude.json")) (pass 0))
    (loop for row across rows
          for range = (aref row 0)
          for version = (aref row 1)
          do (multiple-value-bind (loose incp) (sv-opt (sv-nth row 2))
               ;; version may be a non-string (false) — treat non-strings as "not
               ;; satisfying" (node satisfies(false,…) → false).
               (if (stringp version)
                   (false (clun.install:version-satisfies version range
                                                          :loose loose :include-prerelease incp)
                          "~a excluded from ~a" version range)
                   (true t "non-string version excluded"))
               (incf pass)))
    (is = (length rows) pass "range-exclude vectors run")))

;;; --- range-parse (canonical string or null → reject) ------------------------

(define-test semver-range-parse
  (let ((rows (sv-load "range-parse.json")) (pass 0))
    (loop for row across rows
          for range = (aref row 0)
          for expected = (aref row 1)
          do (multiple-value-bind (loose incp) (sv-opt (sv-nth row 2))
               (if (eq expected sys:json-null)
                   (false (handler-case
                              (progn (clun.install:parse-range range :loose loose
                                                                     :include-prerelease incp)
                                     t)
                            (clun.install:invalid-range () nil))
                          "range ~a should be invalid" range)
                   ;; the fixture encodes validRange output, where the empty
                   ;; (any) range renders as "*" rather than "".
                   (let ((got (clun.install:range-valid-p range :loose loose
                                                                :include-prerelease incp)))
                     (is equal expected got "range ~a canonical" range)))
               (incf pass)))
    (is = (length rows) pass "range-parse vectors run")))

;;; --- gtr / ltr (true and the negated fixtures) ------------------------------

(define-test semver-version-gt-range
  (let ((rows (sv-load "version-gt-range.json")) (pass 0))
    (loop for row across rows
          for range = (aref row 0)
          for version = (aref row 1)
          do (multiple-value-bind (loose incp) (sv-opt (sv-nth row 2))
               (true (clun.install:range-gtr version range :loose loose
                                                           :include-prerelease incp)
                     "~a gtr ~a" version range)
               (incf pass)))
    (is = (length rows) pass "version-gt-range vectors run")))

(define-test semver-version-not-gt-range
  (let ((rows (sv-load "version-not-gt-range.json")) (pass 0))
    (loop for row across rows
          for range = (aref row 0)
          for version = (aref row 1)
          do (multiple-value-bind (loose incp) (sv-opt (sv-nth row 2))
               (false (clun.install:range-gtr version range :loose loose
                                                            :include-prerelease incp)
                      "~a not-gtr ~a" version range)
               (incf pass)))
    (is = (length rows) pass "version-not-gt-range vectors run")))

(define-test semver-version-lt-range
  (let ((rows (sv-load "version-lt-range.json")) (pass 0))
    (loop for row across rows
          for range = (aref row 0)
          for version = (aref row 1)
          do (multiple-value-bind (loose incp) (sv-opt (sv-nth row 2))
               (true (clun.install:range-ltr version range :loose loose
                                                           :include-prerelease incp)
                     "~a ltr ~a" version range)
               (incf pass)))
    (is = (length rows) pass "version-lt-range vectors run")))

(define-test semver-version-not-lt-range
  (let ((rows (sv-load "version-not-lt-range.json")) (pass 0))
    (loop for row across rows
          for range = (aref row 0)
          for version = (aref row 1)
          do (multiple-value-bind (loose incp) (sv-opt (sv-nth row 2))
               (false (clun.install:range-ltr version range :loose loose
                                                            :include-prerelease incp)
                      "~a not-ltr ~a" version range)
               (incf pass)))
    (is = (length rows) pass "version-not-lt-range vectors run")))

;;; --- comparator + range intersection ----------------------------------------

(define-test semver-comparator-intersection
  (let ((rows (sv-load "comparator-intersection.json")) (pass 0))
    (loop for row across rows
          for a = (aref row 0)
          for b = (aref row 1)
          for want = (aref row 2)
          do (multiple-value-bind (loose incp) (sv-opt (sv-nth row 3))
               (let ((expected (eq want sys:json-true))
                     (got (clun.install:comparators-intersect a b :loose loose
                                                                   :include-prerelease incp)))
                 (is eq expected (and got t) "~a intersects ~a" a b))
               (incf pass)))
    (is = (length rows) pass "comparator-intersection vectors run")))

(define-test semver-range-intersection
  (let ((rows (sv-load "range-intersection.json")) (pass 0))
    (loop for row across rows
          for a = (aref row 0)
          for b = (aref row 1)
          for want = (aref row 2)
          do (multiple-value-bind (loose incp) (sv-opt (sv-nth row 3))
               (let ((expected (eq want sys:json-true))
                     (got (clun.install:ranges-intersect a b :loose loose
                                                              :include-prerelease incp)))
                 (is eq expected (and got t) "range ~a intersects ~a" a b))
               (incf pass)))
    (is = (length rows) pass "range-intersection vectors run")))
