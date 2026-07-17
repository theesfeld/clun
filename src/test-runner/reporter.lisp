;;;; reporter.lisp — per-test result lines + the end-of-run summary (PLAN.md §3.6).
;;;; Plain (no color) and WITHOUT per-test timing so output is deterministic for the
;;;; meta-tests / fixtures (Bun prints `[N.NNms]` and colors on a TTY — documented
;;;; divergence: Clun omits timing so `clun test` output is byte-stable).

(in-package :clun.test-runner)

(defun make-reporter (stream)
  "A closure (status full-name detail): print one result line; for :fail, print the
DETAIL indented beneath it."
  (lambda (status full-name detail)
    (format stream "(~a) ~a~%"
            (ecase status (:pass "pass") (:fail "fail") (:skip "skip") (:todo "todo"))
            full-name)
    (when (and (eq status :fail) detail (plusp (length detail)))
      (dolist (line (%detail-lines detail))
        (format stream "  ~a~%" line)))
    (finish-output stream)))

(defun %detail-lines (s)
  (let ((lines '()) (start 0) (n (length s)))
    (dotimes (i n) (when (char= (char s i) #\Newline)
                     (push (subseq s start i) lines) (setf start (1+ i))))
    (push (subseq s start n) lines)
    (nreverse lines)))

(defun %plural (n word) (if (= n 1) word (concatenate 'string word "s")))

(defun print-summary (stream stats file-count expect-calls &optional random-seed)
  "Bun-shaped summary block. Counts: pass/fail always; skip/todo when > 0; expect()
calls; then the `Ran N tests across M files.` line (timing omitted for determinism)."
  (let ((total (+ (st-pass stats) (st-fail stats) (st-skip stats) (st-todo stats))))
    (format stream "~%")
    (when random-seed (format stream " --seed=~a~%" random-seed))
    (format stream " ~a pass~%" (st-pass stats))
    (format stream " ~a fail~%" (st-fail stats))
    (when (plusp (st-skip stats)) (format stream " ~a skip~%" (st-skip stats)))
    (when (plusp (st-todo stats)) (format stream " ~a todo~%" (st-todo stats)))
    (when (plusp (st-snapshots stats))
      (format stream " ~a snapshot~:p~%" (st-snapshots stats)))
    (format stream " ~a expect() calls~%" expect-calls)
    (when (st-bailed stats) (format stream "Bailed out after ~a failure~:p~%" (st-fail stats)))
    (format stream "Ran ~a ~a across ~a ~a.~%"
            total (%plural total "test") file-count (%plural file-count "file"))
    (finish-output stream)))
