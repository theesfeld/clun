;;;; test262.lisp — the Phase 02 parse-phase conformance runner (PLAN.md §3.1).
;;;; Parses every vendored test/language/**/*.js and classifies it. The gate
;;;; (make conformance) fails on ANY crash (a non-SyntaxError Lisp condition) or ANY
;;;; regression of the checked-in pass-list (tests/conformance/parse-passlist.txt).
;;;; With CLUN_GEN=1 it (re)writes the pass-list from the currently-passing set — the
;;;; list only grows; never hand-edit it to green a build.

(load (merge-pathnames "registry.lisp" *load-truename*))
(asdf:load-system :clun)
(in-package :clun.engine)

;; The conformance image is also the full-corpus COMPILE-tier differential gate.
;; Keep the default at :off, but make an explicit environment selection authoritative
;; so the shell harness can run identical corpora through both backends.
(setf *compile-tier-mode* (compile-tier-mode-from-environment))
(setf *cs-trace-executions* (compile-tier-trace-enabled-p))
(cs-reset-telemetry)

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

(defun fm-scalar-after (fm key start)
  (let ((position (and fm (search key fm :start2 start))))
    (when position
      (let* ((value-start (+ position (length key)))
             (value-end (or (position #\Newline fm :start value-start) (length fm))))
        (string-trim '(#\Space #\Tab #\Return) (subseq fm value-start value-end))))))

(defun neg-runtime-type (fm)
  "Return the declared runtime-negative constructor name, or NIL."
  (let ((negative (and fm (search "negative:" fm))))
    (when (and negative
               (string= "runtime" (or (fm-scalar-after fm "phase:" negative) "")))
      (fm-scalar-after fm "type:" negative))))

(defun read-source (path)
  "Read PATH as UTF-8 into a code-unit string (as clun loads source)."
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((bytes (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence bytes in)
      (utf8->code-units bytes))))

(defun classify (path)
  "Return :pass, :fail, :skip, or :crash for a single test file (parse phase)."
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

;;; --- execution phase (Phase 03): run harness + includes + test in a fresh realm

(defparameter *exec* (and (sb-ext:posix-getenv "CLUN_EXEC") t))
(defparameter *harness-root*
  (merge-pathnames "vendor-data/test262/harness/" cl-user::*clun-root*))
(defparameter *exec-passlist-path*
  (merge-pathnames "tests/conformance/exec-passlist.txt" cl-user::*clun-root*))
(defparameter *harness-cache* (make-hash-table :test 'equal))
(defun harness (name)
  (or (gethash name *harness-cache*)
      (setf (gethash name *harness-cache*)
            (read-source (merge-pathnames name *harness-root*)))))

;; Post-ES2017 + non-Phase-03 features skipped for the execution gate.
(defparameter *exec-skip*
  (append *skip-features*
          '("top-level-await" "class-fields-public"
            "class-fields-private" "class-methods-private" "class-static-methods-private"
            "class-static-fields-public" "class-static-fields-private" "class-static-block" "decorators"
            "Proxy" "Reflect" "SharedArrayBuffer" "Atomics" "object-spread" "object-rest"
            "iterator-helpers" "tail-call-optimization" "IsHTMLDDA" "cross-realm"
            "Array.prototype.flat" "Array.prototype.flatMap" "String.prototype.replaceAll"
            ;; Phase 11 RUNS BigInt + TypedArray/ArrayBuffer/DataView. Deliberate gaps kept
            ;; skipped (tests/conformance/bigint-binary-gaps.txt): resizable/growable buffers.
            "resizable-arraybuffer"
            ;; Phase 10 RUNS named-groups / lookbehind / dotall / sticky / u-flag (BMP).
            ;; Deliberate gaps kept skipped (tests/conformance/regexp-gaps.txt): \p{}
            ;; property escapes, the /v flag, inline modifiers, duplicate named groups
            ;; (all above via *skip-features*), and match-indices (the /d flag).
            "regexp-unicode-property-escapes" "regexp-match-indices")))

(defun %install-print (realm)
  "Install a capturing `print` global on REALM (async tests' $DONE uses it via
doneprintHandle.js). Returns a thunk fetching the accumulated output."
  (let ((buf (make-string-output-stream)))
    (let ((*realm* realm))
      (install-method (realm-global realm) "print" 1
        (lambda (this args) (declare (ignore this))
          (write-line (to-string (arg args 0)) buf) +undefined+)))
    (lambda () (get-output-stream-string buf))))

(defun expected-runtime-error-p (condition expected-name realm)
  "Whether CONDITION carries an instance of EXPECTED-NAME in REALM."
  (cond
    ((typep condition 'js-native-error)
     (string= expected-name (js-native-error-name (js-native-error-kind condition))))
    (t
     (let ((*realm* realm)
           (value (js-condition-value condition)))
       (handler-case
           (let ((constructor (js-get (realm-global realm) expected-name)))
             (and (callable-p constructor)
                  (ordinary-has-instance constructor value)))
         (js-condition () nil))))))

(defun classify-exec (path)
  "Run PATH's harness+includes+source in both modes; :pass/:fail/:skip/:crash/:tmo.
An `async`-flagged test passes iff $DONE printed AsyncTestComplete (and no Failure)."
  (let* ((src (read-source path))
         (fm (frontmatter src))
         (features (fm-list fm "features:"))
         (flags (fm-list fm "flags:"))
         (runtime-negative (neg-runtime-type fm)))
    (cond
      ((neg-parse-p fm) :skip)                              ; negative-parse handled by parse phase
      ((intersection features *exec-skip* :test #'string=) :skip)
      ((member "module" flags :test #'string=) :skip)       ; ESM linking lands in Phase 07
      ((member "raw" flags :test #'string=) :skip)          ; raw = no harness; handle rarely
      (t (let ((inc (apply #'concatenate 'string
                           (mapcar #'harness (fm-list fm "includes:"))))
               (asyncp (member "async" flags :test #'string=))
               (modes (cond ((member "onlyStrict" flags :test #'string=) '(t))
                            ((member "noStrict" flags :test #'string=) '(nil))
                            (t '(nil t))))
               (result :pass))
           (dolist (m modes result)
             (let* ((realm (make-realm))
                    (getout (when asyncp (%install-print realm)))
                    ;; test262 auto-includes doneprintHandle.js for async tests (defines
                    ;; $DONE via print) — it is not in the frontmatter includes list.
                    (full (concatenate 'string (if m "\"use strict\";" "")
                                       (harness "sta.js") (harness "assert.js")
                                       (if asyncp (harness "doneprintHandle.js") "") inc src)))
               (handler-case
                   (progn
                     (sb-ext:with-timeout 5
                       (run-source full :realm realm
                                        :report-unhandled-rejections-p (not (null asyncp))))
                     (when runtime-negative (return :fail)))
                 (sb-ext:timeout () (return :fail))
                 (js-condition (condition)
                   (unless (and runtime-negative
                                (expected-runtime-error-p condition runtime-negative realm))
                     (return :fail)))
                 (serious-condition () (return-from classify-exec :crash)))
               (when (and asyncp (not runtime-negative))
                 (let ((out (funcall getout)))
                   (unless (and (search "Test262:AsyncTestComplete" out)
                                (not (search "Test262:AsyncTestFailure" out)))
                     (return :fail)))))))))))

(defparameter *builtins-root*
  (merge-pathnames "vendor-data/test262/test/built-ins/" cl-user::*clun-root*))

(defun rel-name (path)
  "Language tests stay relative to lang-root (pass-list back-compat); built-ins are
prefixed 'built-ins/' so both live in one exec pass-list without collision."
  (let* ((full (namestring path)) (lr (namestring *lang-root*)) (br (namestring *builtins-root*)))
    (cond ((eql 0 (search lr full)) (subseq full (length lr)))
          ((eql 0 (search br full)) (concatenate 'string "built-ins/" (subseq full (length br))))
          (t full))))

(defun all-tests ()
  ;; Parse phase: language only (Phase 02 tier). Execution phase (Phase 03+): also
  ;; the built-ins slice (Phase 04), which the stdlib gate measures.
  (sort (remove-if (lambda (p) (search "_FIXTURE" (namestring p)))
                   (append (directory (merge-pathnames "**/*.js" *lang-root*))
                           (when *exec* (directory (merge-pathnames "**/*.js" *builtins-root*)))))
        #'string< :key #'namestring))

(defun run ()
  (let ((pass '()) (fail 0) (skip 0) (crash '()) (tmo 0) (n 0)
        (classifications '()))
    (dolist (path (all-tests))
      (incf n)
      ;; The exec phase runs ~21k program executions (language + built-ins × 2 modes)
      ;; in one image; a full GC every 500 keeps discarded realms/ASTs from
      ;; accumulating into an old generation and exhausting the heap.
      (when (and *exec* (zerop (mod n 500))) (sb-ext:gc :full t))
      (let* ((name (rel-name path))
             (classification (if *exec* (classify-exec path) (classify path))))
        (push (cons name classification) classifications)
        (case classification
          (:pass (push name pass))
          (:fail (incf fail))
          (:skip (incf skip))
          (:tmo (incf tmo) (incf fail))
          (:crash (push name crash)))))
    (values (nreverse pass) fail skip (nreverse crash) n
            (sort classifications #'string< :key #'car))))

(defun write-classifications (classifications)
  "Write the complete deterministic PATH<TAB>CLASSIFICATION ledger when requested."
  (let ((path (sb-ext:posix-getenv "CLUN_CONFORMANCE_CLASSIFICATIONS")))
    (when (and path (plusp (length path)))
      (ensure-directories-exist path)
      (with-open-file (out path :direction :output :if-exists :supersede
                                :if-does-not-exist :create)
        (dolist (entry classifications)
          (format out "~a~c~(~a~)~%" (car entry) #\Tab (cdr entry))))
      (format t "wrote classifications: ~a (~a files)~%" path (length classifications)))))

(defun passlist-file () (if *exec* *exec-passlist-path* *passlist-path*))

(defun load-passlist ()
  (when (probe-file (passlist-file))
    (with-open-file (in (passlist-file))
      (loop for line = (read-line in nil nil) while line
            for tt = (string-trim '(#\Space #\Return) line)
            unless (or (string= tt "") (char= (char tt 0) #\#)) collect tt))))

(multiple-value-bind (pass fail skip crash total classifications) (run)
  (write-classifications classifications)
  (format t "~&=== test262 ~a phase — ~a files ===~%" (if *exec* "execution" "parse") total)
  (format t "pass ~a | fail(gap) ~a | skip(unsupported syntax) ~a | CRASH ~a~%"
          (length pass) fail skip (length crash))
  (format t "COMPILE_TIER mode=~(~a~) compiled=~a ineligible=~a fallback=~a executed=~a~%"
          *compile-tier-mode* *cs-compiled-count* *cs-ineligible-count* *cs-fallback-count*
          *cs-executed-count*)
  (let ((eager-vacuous (and (eq *compile-tier-mode* :eager)
                            (zerop *cs-compiled-count*)))
        (eager-fallback (and (eq *compile-tier-mode* :eager)
                             (plusp *cs-fallback-count*))))
    (when eager-vacuous
      (format t "COMPILE-tier eager conformance compiled zero function bodies; refusing a vacuous pass.~%"))
    (when eager-fallback
      (format t "COMPILE-tier eager conformance recorded ~a compilation fallbacks; refusing a partial pass.~%"
              *cs-fallback-count*))
  (cond
    ((sb-ext:posix-getenv "CLUN_GEN")
     ;; UNION with the existing list so the pass-list can only grow — a correctness
     ;; fix that removes false-passes must be recorded as a dated DECISIONS.md entry,
     ;; not silently shrink the baseline. If crashes exist, refuse to regenerate.
     (when (or crash eager-vacuous eager-fallback)
       (when crash
         (format t "refusing to regenerate pass-list with ~a crashes present~%" (length crash)))
       (sb-ext:exit :code 1))
     (let* ((existing (load-passlist))
            (union (sort (remove-duplicates (append existing pass) :test #'string=) #'string<))
            (dropped (set-difference existing pass :test #'string=)))
       (when dropped
         (format t "~a pass-list entries no longer pass; KEEPING them (only-grows). If this is a~%~
                    deliberate false-pass correction, remove them by hand + log in DECISIONS.md:~%"
                 (length dropped))
         (dolist (d dropped) (format t "  - ~a~%" d)))
       (ensure-directories-exist (passlist-file))
       (with-open-file (out (passlist-file) :direction :output :if-exists :supersede
                                            :if-does-not-exist :create)
         (format out "# test262 ~a-phase pass-list (PLAN.md §3.1). Sorted; only grows.~%"
                 (if *exec* "execution" "parse"))
         (format out "# Regenerate: CLUN_GEN=1 ~:[~;CLUN_EXEC=1 ~]make conformance. ~a entries.~%"
                 *exec* (length union))
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
       (if (and (null crash) (null regressions) (not eager-vacuous) (not eager-fallback))
           (progn (format t "conformance: OK (~a pass-list entries hold, 0 crashes)~%"
                          (length expected))
                  (sb-ext:exit :code 0))
           (progn (format t "conformance: FAILED~%") (sb-ext:exit :code 1))))))))
