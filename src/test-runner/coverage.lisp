;;;; coverage.lisp -- deterministic Bun-shaped text and LCOV reporters.

(in-package :clun.test-runner)

(defun %coverage-relative-path (path cwd)
  (let ((prefix (if (and (plusp (length cwd))
                         (char= (char cwd (1- (length cwd))) #\/))
                    cwd
                    (concatenate 'string cwd "/"))))
    (and (>= (length path) (length prefix))
         (string= prefix path :end2 (length prefix))
         (subseq path (length prefix)))))

(defun %coverage-node-modules-path-p (path)
  (or (search "/node_modules/" path)
      (and (>= (length path) 13)
           (string= "node_modules/" path :end2 13))))

(defun %coverage-ignored-p (relative patterns)
  (some (lambda (pattern)
          (or (clun.glob:glob-match-p pattern relative)
              (clun.glob:glob-match-p pattern (sys:path-basename relative))))
        patterns))

(defun %coverage-records (session cwd include-test-files-p ignore-patterns)
  (loop for record in (eng:coverage-results session)
        for path = (getf record :path)
        for relative = (%coverage-relative-path path cwd)
        when (and relative
                  (not (%coverage-node-modules-path-p relative))
                  (not (%coverage-ignored-p relative ignore-patterns))
                  (or include-test-files-p
                      (not (%test-file-p (sys:path-basename relative)))))
          collect (list* :display-path relative record)))

(defun %coverage-points (record kind)
  (remove-if-not (lambda (point) (eq (getf point :kind) kind))
                 (getf record :points)))

(defun %coverage-line-hits (record)
  (let ((table (make-hash-table :test #'eql)))
    (dolist (point (%coverage-points record :statement))
      (incf (gethash (getf point :line) table 0) (getf point :hits)))
    (sort (loop for line being the hash-keys of table using (hash-value hits)
                collect (cons line hits))
          #'< :key #'car)))

(defun %coverage-counts (record kind)
  (let* ((points (if (eq kind :line)
                     (%coverage-line-hits record)
                     (%coverage-points record kind)))
         (total (length points))
         (covered (count-if (lambda (point)
                              (plusp (if (eq kind :line)
                                         (cdr point)
                                         (getf point :hits))))
                            points)))
    (values covered total)))

(defun %coverage-percent (covered total)
  (if (zerop total) 100.0d0 (* 100.0d0 (/ covered total))))

(defun %coverage-uncovered-lines (record)
  (loop for (line . hits) in (%coverage-line-hits record)
        when (zerop hits) collect line))

(defun %coverage-line-ranges (lines)
  (with-output-to-string (output)
    (loop with first-range-p = t
          while lines
          for start = (pop lines)
          for end = start
          do (loop while (and lines (= (first lines) (1+ end)))
                   do (setf end (pop lines)))
             (unless first-range-p (write-char #\, output))
             (setf first-range-p nil)
             (if (= start end)
                 (princ start output)
                 (format output "~a-~a" start end)))))

(defun %coverage-pad-right (value width)
  (concatenate 'string value (make-string (max 0 (- width (length value)))
                                          :initial-element #\Space)))

(defun %coverage-pad-left (value width)
  (concatenate 'string (make-string (max 0 (- width (length value)))
                                    :initial-element #\Space)
               value))

(defun %coverage-percent-string (covered total)
  (format nil "~,2f" (%coverage-percent covered total)))

(defun %coverage-aggregate-counts (records kind)
  (loop with covered-total = 0
        with point-total = 0
        for record in records
        do (multiple-value-bind (covered total) (%coverage-counts record kind)
             (incf covered-total covered)
             (incf point-total total))
        finally (return (values covered-total point-total))))

(defun print-coverage-text (stream records)
  (let* ((file-width (max 12 (length "All files")
                          (loop for record in records
                                maximize (length (getf record :display-path)))))
         (rule (format nil "~a|---------|---------|-------------------"
                       (make-string (1+ file-width) :initial-element #\-))))
    (write-char #\Newline stream)
    (format stream "~a~%" rule)
    (format stream "~a | % Funcs | % Lines | Uncovered Line #s~%"
            (%coverage-pad-right "File" file-width))
    (format stream "~a~%" rule)
    (multiple-value-bind (function-covered function-total)
        (%coverage-aggregate-counts records :function)
      (multiple-value-bind (line-covered line-total)
          (%coverage-aggregate-counts records :line)
        (format stream "~a | ~a | ~a |~%"
                (%coverage-pad-right "All files" file-width)
                (%coverage-pad-left
                 (%coverage-percent-string function-covered function-total) 7)
                (%coverage-pad-left (%coverage-percent-string line-covered line-total) 7))))
    (dolist (record records)
      (multiple-value-bind (function-covered function-total)
          (%coverage-counts record :function)
        (multiple-value-bind (line-covered line-total)
            (%coverage-counts record :line)
          (format stream "~a | ~a | ~a | ~a~%"
                  (%coverage-pad-right (getf record :display-path) file-width)
                  (%coverage-pad-left
                   (%coverage-percent-string function-covered function-total) 7)
                  (%coverage-pad-left (%coverage-percent-string line-covered line-total) 7)
                  (%coverage-line-ranges (%coverage-uncovered-lines record))))))
    (format stream "~a~%" rule)
    (finish-output stream)))

(defun %coverage-lcov-name (point)
  (let ((name (getf point :name)))
    (if (plusp (length name)) name (format nil "anonymous_~a" (getf point :id)))))

(defun %coverage-lcov (records)
  (with-output-to-string (output)
    (dolist (record records)
      (format output "TN:~%SF:~a~%" (getf record :display-path))
      (let ((functions (%coverage-points record :function)))
        (dolist (point functions)
          (format output "FN:~a,~a~%" (getf point :line)
                  (%coverage-lcov-name point)))
        (dolist (point functions)
          (format output "FNDA:~a,~a~%" (getf point :hits)
                  (%coverage-lcov-name point)))
        (multiple-value-bind (covered total) (%coverage-counts record :function)
          (format output "FNF:~a~%FNH:~a~%" total covered)))
      (dolist (line (%coverage-line-hits record))
        (format output "DA:~a,~a~%" (car line) (cdr line)))
      (multiple-value-bind (covered total) (%coverage-counts record :line)
        (format output "LF:~a~%LH:~a~%" total covered))
      (write-string "end_of_record" output)
      (write-char #\Newline output))))

(defun coverage-threshold-failures (records line-threshold function-threshold
                                    statement-threshold)
  "Return human-readable failures for aggregate thresholds not met by RECORDS."
  (let ((failures '()))
    (dolist (spec (list (list "lines" :line line-threshold)
                        (list "functions" :function function-threshold)
                        (list "statements" :statement statement-threshold)))
      (when (third spec)
        (multiple-value-bind (covered total)
            (%coverage-aggregate-counts records (second spec))
          (let ((actual (if (zerop total) 1.0d0 (/ covered total))))
            (when (< actual (third spec))
              (push (format nil
                            "coverage for ~a (~,2f%) does not meet threshold (~,2f%)"
                            (first spec) (* 100 actual) (* 100 (third spec)))
                    failures))))))
    (nreverse failures)))

(defun write-test-coverage (session cwd reporters directory include-test-files-p
                            ignore-patterns stream)
  "Render REPORTERS for SESSION. Return the filtered report records."
  (let ((records (%coverage-records session cwd include-test-files-p ignore-patterns)))
    (when (member :text reporters) (print-coverage-text stream records))
    (when (member :lcov reporters)
      (let ((dir (if (sys:absolute-path-p directory)
                     directory
                     (sys:path-join cwd directory))))
        (sys:make-directory dir :recursive t)
        (%snapshot-write-text-atomically (sys:path-join dir "lcov.info")
                                         (%coverage-lcov records))))
    records))
