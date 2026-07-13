;;;; diff.lisp — LCS line diff for failing-matcher output (PLAN.md Phase 15, §3.6).
;;;; Produces Bun-flavored `- Expected` / `+ Received` blocks. Byte-exact match to
;;;; Bun's spacing is NOT a goal (documented); determinism + readability is.

(in-package :clun.test-runner)

(defun %split-lines (s)
  "Split S into a vector of lines (no trailing empty from a final newline)."
  (let ((lines '()) (start 0) (n (length s)))
    (dotimes (i n)
      (when (char= (char s i) #\Newline)
        (push (subseq s start i) lines) (setf start (1+ i))))
    (push (subseq s start n) lines)
    (coerce (nreverse lines) 'vector)))

(defun %lcs-table (a b)
  "DP table of LCS lengths for line vectors A and B (string= compares)."
  (let* ((na (length a)) (nb (length b))
         (tbl (make-array (list (1+ na) (1+ nb)) :element-type 'fixnum :initial-element 0)))
    (loop for i from (1- na) downto 0 do
      (loop for j from (1- nb) downto 0 do
        (setf (aref tbl i j)
              (if (string= (aref a i) (aref b j))
                  (1+ (aref tbl (1+ i) (1+ j)))
                  (max (aref tbl (1+ i) j) (aref tbl i (1+ j)))))))
    tbl))

(defun line-diff (expected received)
  "A unified line diff of EXPECTED vs RECEIVED strings: common lines prefixed '  ',
expected-only '- ', received-only '+ ', with a trailing count footer. Returns a string."
  (let* ((a (%split-lines expected)) (b (%split-lines received))
         (tbl (%lcs-table a b))
         (na (length a)) (nb (length b))
         (out (make-string-output-stream))
         (removed 0) (added 0) (i 0) (j 0))
    (loop while (and (< i na) (< j nb)) do
      (cond
        ((string= (aref a i) (aref b j))
         (format out "  ~a~%" (aref a i)) (incf i) (incf j))
        ((>= (aref tbl (1+ i) j) (aref tbl i (1+ j)))
         (format out "- ~a~%" (aref a i)) (incf removed) (incf i))
        (t (format out "+ ~a~%" (aref b j)) (incf added) (incf j))))
    (loop while (< i na) do (format out "- ~a~%" (aref a i)) (incf removed) (incf i))
    (loop while (< j nb) do (format out "+ ~a~%" (aref b j)) (incf added) (incf j))
    (format nil "- Expected  - ~a~%+ Received  + ~a~%~%~a" removed added
            (get-output-stream-string out))))
