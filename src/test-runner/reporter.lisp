;;;; reporter.lisp — per-test result lines + the end-of-run summary (PLAN.md §3.6).
;;;; Plain (no color) and WITHOUT per-test timing so output is deterministic for the
;;;; meta-tests / fixtures (Bun prints `[N.NNms]` and colors on a TTY — documented
;;;; divergence: Clun omits timing so `clun test` output is byte-stable).

(in-package :clun.test-runner)

(defstruct (test-report-record
             (:constructor make-test-report-record (file status name detail assertions)))
  file status name detail assertions)

(defun make-reporter (stream &key (mode :console) on-result)
  "A closure (status full-name detail): print one result line; for :fail, print the
DETAIL indented beneath it."
  (let ((last-dot nil))
    (lambda (status full-name detail &optional (assertions 0))
      (when on-result (funcall on-result status full-name detail assertions))
      (if (and (eq mode :dots) (not (eq status :fail)))
          (progn
            (write-char #\. stream)
            (setf last-dot t))
          (progn
            (when last-dot
              (write-char #\Newline stream)
              (setf last-dot nil))
            (format stream "(~a) ~a~%"
                    (ecase status
                      (:pass "pass") (:fail "fail") (:skip "skip") (:todo "todo"))
                    full-name)
            (when (and (eq status :fail) detail (plusp (length detail)))
              (dolist (line (%detail-lines detail))
                (format stream "  ~a~%" line)))))
      (finish-output stream))))

(defun %detail-lines (s)
  (let ((lines '()) (start 0) (n (length s)))
    (dotimes (i n) (when (char= (char s i) #\Newline)
                     (push (subseq s start i) lines) (setf start (1+ i))))
    (push (subseq s start n) lines)
    (nreverse lines)))

(defun %plural (n word) (if (= n 1) word (concatenate 'string word "s")))

(defun %xml-escape (value)
  (with-output-to-string (output)
    (loop for character across (or value "") do
      (case character
        (#\& (write-string "&amp;" output))
        (#\< (write-string "&lt;" output))
        (#\> (write-string "&gt;" output))
        (#\" (write-string "&quot;" output))
        (#\' (write-string "&apos;" output))
        (#\Tab (write-string "&#9;" output))
        (#\Newline (write-string "&#10;" output))
        (#\Return (write-string "&#13;" output))
        (t
         (let ((code (char-code character)))
           (if (or (<= #x20 code #xd7ff)
                   (<= #xe000 code #xfffd)
                   (<= #x10000 code #x10ffff))
               (write-char character output)
               (write-string "&#xFFFD;" output))))))))

(defun %junit-count (records status)
  (count status records :key #'test-report-record-status))

(defun %junit-skipped-count (records)
  (+ (%junit-count records :skip) (%junit-count records :todo)))

(defun %junit-assertions (records)
  (reduce #'+ records :key #'test-report-record-assertions :initial-value 0))

(defun %junit-groups (records)
  (let ((order '()) (table (make-hash-table :test #'equal)))
    (dolist (record records)
      (let ((file (test-report-record-file record)))
        (unless (gethash file table)
          (push file order)
          (setf (gethash file table) '()))
        (push record (gethash file table))))
    (mapcar (lambda (file) (cons file (nreverse (gethash file table))))
            (nreverse order))))

(defun %junit-ci-value ()
  (let ((run (sys:getenv "GITHUB_RUN_ID"))
        (server (sys:getenv "GITHUB_SERVER_URL"))
        (repository (sys:getenv "GITHUB_REPOSITORY")))
    (cond
      ((and run server repository
            (plusp (length run)) (plusp (length server)) (plusp (length repository)))
       (format nil "~a/~a/actions/runs/~a" server repository run))
      ((let ((job (sys:getenv "CI_JOB_URL")))
         (and job (plusp (length job)) job))))))

(defun %junit-commit-value ()
  (dolist (name '("GITHUB_SHA" "CI_COMMIT_SHA" "GIT_SHA"))
    (let ((value (sys:getenv name)))
      (when (and value (plusp (length value)))
        (return value)))))

(defun %write-junit-properties (output)
  (let ((ci (%junit-ci-value)) (commit (%junit-commit-value)))
    (when (or ci commit)
      (write-string "    <properties>" output)
      (write-char #\Newline output)
      (when ci
        (format output "      <property name=\"ci\" value=\"~a\" />~%"
                (%xml-escape ci)))
      (when commit
        (format output "      <property name=\"commit\" value=\"~a\" />~%"
                (%xml-escape commit)))
      (write-string "    </properties>" output)
      (write-char #\Newline output))))

(defun %write-junit-case (output record)
  (let ((status (test-report-record-status record))
        (file (%xml-escape (test-report-record-file record)))
        (name (%xml-escape (test-report-record-name record)))
        (assertions (test-report-record-assertions record)))
    (format output
            "    <testcase name=\"~a\" classname=\"~a\" time=\"0\" file=\"~a\" assertions=\"~a\""
            name file file assertions)
    (case status
      (:pass (write-string " />" output) (write-char #\Newline output))
      (:fail
       (write-string ">" output)
       (write-char #\Newline output)
       (format output "      <failure type=\"AssertionError\" message=\"~a\" />~%"
               (%xml-escape (test-report-record-detail record)))
       (write-string "    </testcase>" output)
       (write-char #\Newline output))
      (:skip
       (write-string ">" output)
       (write-char #\Newline output)
       (write-string "      <skipped />" output)
       (write-char #\Newline output)
       (write-string "    </testcase>" output)
       (write-char #\Newline output))
      (:todo
       (write-string ">" output)
       (write-char #\Newline output)
       (write-string "      <skipped message=\"TODO\" />" output)
       (write-char #\Newline output)
       (write-string "    </testcase>" output)
       (write-char #\Newline output)))))

(defun write-junit-report (path records)
  "Write a deterministic Bun-shaped JUnit report for RECORDS to PATH."
  (let* ((tests (length records))
         (assertions (%junit-assertions records))
         (failures (%junit-count records :fail))
         (skipped (%junit-skipped-count records))
         (hostname (%xml-escape (or (ignore-errors (machine-instance)) "")))
         (text
           (with-output-to-string (output)
             (write-string "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" output)
             (write-char #\Newline output)
             (format output
                     "<testsuites name=\"clun test\" tests=\"~a\" assertions=\"~a\" failures=\"~a\" skipped=\"~a\" time=\"0\">~%"
                     tests assertions failures skipped)
             (dolist (group (%junit-groups records))
               (let* ((file (car group))
                      (suite-records (cdr group))
                      (suite-tests (length suite-records)))
                 (format output
                         "  <testsuite name=\"~a\" file=\"~a\" tests=\"~a\" assertions=\"~a\" failures=\"~a\" skipped=\"~a\" time=\"0\" hostname=\"~a\">~%"
                         (%xml-escape file) (%xml-escape file) suite-tests
                         (%junit-assertions suite-records)
                         (%junit-count suite-records :fail)
                         (%junit-skipped-count suite-records) hostname)
                 (%write-junit-properties output)
                 (dolist (record suite-records) (%write-junit-case output record))
                 (write-string "  </testsuite>" output)
                 (write-char #\Newline output)))
             (write-string "</testsuites>" output)
             (write-char #\Newline output))))
    (%snapshot-write-text-atomically path text)))

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
