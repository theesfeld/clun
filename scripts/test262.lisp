;;;; test262.lisp — the Phase 02 parse-phase conformance runner (PLAN.md §3.1).
;;;; Parses every vendored test/language/**/*.js and classifies it. The gate
;;;; (make conformance) fails on ANY crash (a non-SyntaxError Lisp condition) or ANY
;;;; regression of the checked-in pass-list (tests/conformance/parse-passlist.txt).
;;;; With CLUN_GEN=1 it (re)writes the pass-list from the currently-passing set — the
;;;; list only grows; never hand-edit it to green a build.

(load (merge-pathnames "registry.lisp" *load-truename*))
(asdf:load-system :clun)
(in-package :clun.engine)

(defparameter *lang-root*
  (merge-pathnames "vendor-data/test262/test/language/" cl-user::*clun-root*))
(defparameter *passlist-path*
  (merge-pathnames "tests/conformance/parse-passlist.txt" cl-user::*clun-root*))

;; Post-ES2017 SYNTAX features the v1 parser does not accept (§3.1 tier). A positive
;; test tagged with any of these is a known gap (:skip), not a failure.
(defparameter *skip-features*
  '("class-fields-public" "class-fields-private" "class-methods-private"
    "class-static-methods-private" "class-static-fields-public" "class-static-fields-private"
    "class-static-block" "decorators" "top-level-await" "dynamic-import"
    "import-assertions" "import-attributes" "import-defer" "source-phase-imports"
    "source-phase-imports-module-source" "numeric-separator-literal"
    "logical-assignment-operators" "optional-chaining" "coalesce-expression"
    "explicit-resource-management" "regexp-v-flag" "import-meta" "hashbang"
    "regexp-modifiers" "regexp-duplicate-named-groups" "arbitrary-module-namespace-names"))

(defun frontmatter (src)
  (let ((s (search "/*---" src)) (e (search "---*/" src)))
    (when (and s e (< s e)) (subseq src (+ s 5) e))))

(defun fm-list (fm key)
  (let ((p (and fm (search key fm))))
    (when p
      (let* ((lb (position #\[ fm :start p)) (rb (and lb (position #\] fm :start lb))))
        (when (and lb rb)
          (loop for tok in (uiop:split-string (subseq fm (1+ lb) rb) :separator ",")
                for tt = (string-trim '(#\Space #\Tab #\Newline #\Return) tok)
                unless (string= tt "") collect tt))))))

(defun neg-parse-p (fm)
  (let ((n (and fm (search "negative:" fm))))
    (and n (search "phase: parse" fm :start2 n))))

(defun read-source (path)
  "Read PATH as UTF-8 into a code-unit string (as clun loads source)."
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((bytes (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence bytes in)
      (utf8->code-units bytes))))

(defun classify (path)
  "Return :pass, :fail, :skip, or :crash for a single test file."
  (let* ((src (read-source path))
         (fm (frontmatter src))
         (features (fm-list fm "features:"))
         (module (member "module" (fm-list fm "flags:") :test #'string=))
         (negp (neg-parse-p fm)))
    (handler-case
        (progn (parse-program src :source-type (if module :module :script))
               (if negp :fail :pass))          ; parsed ok
      (js-native-error ()
        (cond (negp :pass)                      ; correctly rejected
              ((intersection features *skip-features* :test #'string=) :skip)
              (t :fail)))                       ; positive we couldn't parse (gap)
      ;; serious-condition (not just error) so stack/heap exhaustion counts as a
      ;; crash rather than aborting the whole runner
      (serious-condition () :crash))))

(defun rel-name (path)
  (let ((full (namestring path)) (root (namestring *lang-root*)))
    (subseq full (length root))))

(defun all-tests ()
  (sort (remove-if (lambda (p) (search "_FIXTURE" (namestring p)))
                   (directory (merge-pathnames "**/*.js" *lang-root*)))
        #'string< :key #'namestring))

(defun run ()
  (let ((pass '()) (fail 0) (skip 0) (crash '()) (n 0))
    (dolist (path (all-tests))
      (incf n)
      (case (classify path)
        (:pass (push (rel-name path) pass))
        (:fail (incf fail))
        (:skip (incf skip))
        (:crash (push (rel-name path) crash))))
    (values (nreverse pass) fail skip (nreverse crash) n)))

(defun load-passlist ()
  (when (probe-file *passlist-path*)
    (with-open-file (in *passlist-path*)
      (loop for line = (read-line in nil nil) while line
            for tt = (string-trim '(#\Space #\Return) line)
            unless (or (string= tt "") (char= (char tt 0) #\#)) collect tt))))

(multiple-value-bind (pass fail skip crash total) (run)
  (format t "~&=== test262 parse phase — ~a files ===~%" total)
  (format t "pass ~a | fail(gap) ~a | skip(unsupported syntax) ~a | CRASH ~a~%"
          (length pass) fail skip (length crash))
  (cond
    ((sb-ext:posix-getenv "CLUN_GEN")
     ;; UNION with the existing list so the pass-list can only grow — a correctness
     ;; fix that removes false-passes must be recorded as a dated DECISIONS.md entry,
     ;; not silently shrink the baseline. If crashes exist, refuse to regenerate.
     (when crash
       (format t "refusing to regenerate pass-list with ~a crashes present~%" (length crash))
       (sb-ext:exit :code 1))
     (let* ((existing (load-passlist))
            (union (sort (remove-duplicates (append existing pass) :test #'string=) #'string<))
            (dropped (set-difference existing pass :test #'string=)))
       (when dropped
         (format t "~a pass-list entries no longer pass; KEEPING them (only-grows). If this is a~%~
                    deliberate false-pass correction, remove them by hand + log in DECISIONS.md:~%"
                 (length dropped))
         (dolist (d dropped) (format t "  - ~a~%" d)))
       (ensure-directories-exist *passlist-path*)
       (with-open-file (out *passlist-path* :direction :output :if-exists :supersede
                                            :if-does-not-exist :create)
         (format out "# test262 parse-phase pass-list (PLAN.md §3.1). Sorted; only grows.~%")
         (format out "# Regenerate: CLUN_GEN=1 make conformance. ~a entries.~%" (length union))
         (dolist (e union) (format out "~a~%" e)))
       (format t "wrote pass-list (~a entries; +~a new)~%"
               (length union) (- (length union) (length existing))))
     (sb-ext:exit :code 0))
    (t
     (let* ((current (let ((h (make-hash-table :test 'equal)))
                       (dolist (e pass) (setf (gethash e h) t)) h))
            (expected (load-passlist))
            (regressions (remove-if (lambda (e) (gethash e current)) expected)))
       (when crash
         (format t "~%CRASHES (must be 0):~%")
         (dolist (c crash) (format t "  ~a~%" c)))
       (when regressions
         (format t "~%PASS-LIST REGRESSIONS (~a):~%" (length regressions))
         (dolist (r regressions) (format t "  ~a~%" r)))
       (if (and (null crash) (null regressions))
           (progn (format t "conformance: OK (~a pass-list entries hold, 0 crashes)~%"
                          (length expected))
                  (sb-ext:exit :code 0))
           (progn (format t "conformance: FAILED~%") (sb-ext:exit :code 1)))))))
