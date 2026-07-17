;;;; snapshot.lisp -- file-owned external and inline snapshot state (Phase 66).

(in-package :clun.test-runner)

(defparameter +snapshot-header+
  (concatenate 'string
               "// Bun Snapshot v1, https://bun.sh/docs/test/snapshots"
               (string #\Newline)))

(define-condition snapshot-error (error)
  ((message :initarg :message :reader snapshot-error-message))
  (:report (lambda (condition stream)
             (write-string (snapshot-error-message condition) stream))))

(defun %snapshot-error (control &rest arguments)
  (error 'snapshot-error :message (apply #'format nil control arguments)))

(defstruct (inline-snapshot-edit (:conc-name ise-))
  start end replacement)

(defstruct (snapshot-state
             (:conc-name ss-)
             (:constructor %make-snapshot-state))
  test-path source-text snapshot-path
  (update-p nil) (ci-p nil)
  (values (make-hash-table :test #'equal))
  (order '())
  (output-values (make-hash-table :test #'equal))
  (output-order '())
  (counts (make-hash-table :test #'equal))
  (active-test nil)
  (inline-edits '())
  (external-seen-p nil) (external-dirty-p nil)
  (total 0) (added 0) (matched 0) (updated 0) (failed 0))

(defun %snapshot-file-path (test-path)
  (sys:path-join (sys:path-dirname test-path) "__snapshots__"
                 (concatenate 'string (sys:path-basename test-path) ".snap")))

(defun %snapshot-whitespace-p (character)
  (member character '(#\Space #\Tab #\Newline #\Return) :test #'char=))

(defun %snapshot-skip-whitespace (text position)
  (loop while (and (< position (length text))
                   (%snapshot-whitespace-p (char text position)))
        do (incf position)
        finally (return position)))

(defun %snapshot-prefix-at-p (text position prefix)
  (let ((end (+ position (length prefix))))
    (and (<= end (length text))
         (string= prefix text :start2 position :end2 end))))

(defun %snapshot-expect-at (text position expected)
  (unless (%snapshot-prefix-at-p text position expected)
    (%snapshot-error "Malformed snapshot file near byte ~a: expected ~s"
                     position expected))
  (+ position (length expected)))

(defun %snapshot-read-template (text position)
  (let ((output (make-string-output-stream)))
    (loop
      (when (>= position (length text))
        (%snapshot-error "Malformed snapshot file: unterminated template literal"))
      (let ((character (char text position)))
        (incf position)
        (cond
          ((char= character #\`)
           (return (values (get-output-stream-string output) position)))
          ((char= character #\\)
           (when (>= position (length text))
             (%snapshot-error "Malformed snapshot file: trailing escape"))
           (let ((escaped (char text position)))
             (incf position)
             (write-char
              (case escaped
                (#\n #\Newline)
                (#\r #\Return)
                (#\t #\Tab)
                (t escaped))
              output)))
          (t (write-char character output)))))))

(defun %snapshot-load-external (state)
  (let ((path (ss-snapshot-path state)))
    (unless (sys:file-p path)
      (return-from %snapshot-load-external state))
    (let* ((text (sys:read-file-string path))
           (position 0)
           (order '()))
      (unless (zerop (length text))
        (setf position (%snapshot-expect-at text position +snapshot-header+)))
      (loop
        (setf position (%snapshot-skip-whitespace text position))
        (when (= position (length text)) (return))
        (setf position (%snapshot-expect-at text position "exports[`"))
        (multiple-value-bind (key after-key)
            (%snapshot-read-template text position)
          (setf position (%snapshot-expect-at text after-key "] = `"))
          (multiple-value-bind (value after-value)
              (%snapshot-read-template text position)
            (setf position (%snapshot-expect-at text after-value ";"))
            (multiple-value-bind (old present-p) (gethash key (ss-values state))
              (declare (ignore old))
              (unless present-p (push key order)))
            (setf (gethash key (ss-values state)) value))))
      ;; Keep orders reversed internally so PUSH appends new snapshots in execution
      ;; order and rendering needs only one non-destructive NREVERSE.
      (setf (ss-order state) order)))
  state)

(defun make-file-snapshot-state (test-path update-p ci-p)
  (let ((state (%make-snapshot-state
                :test-path test-path
                :source-text (sys:read-file-string test-path)
                :snapshot-path (%snapshot-file-path test-path)
                :update-p update-p
                :ci-p ci-p)))
    (%snapshot-load-external state)))

(defun snapshot-reset-attempt (state test)
  (when state
    (setf (ss-active-test state) test)
    (clrhash (ss-counts state))))

(defun %snapshot-base-name (test hint)
  (let ((names (list (tt-name test)))
        (parent (tt-parent test)))
    (loop while (and parent (td-parent parent)) do
      (when (plusp (length (td-name parent)))
        (push (td-name parent) names))
      (setf parent (td-parent parent)))
    (let ((base (format nil "~{~a~^ ~}" names)))
      (if (zerop (length hint))
          base
          (concatenate 'string base ": " hint)))))

(defun %snapshot-next-key (state test hint)
  (unless test
    (%snapshot-error "Snapshot matchers cannot be used outside of a test"))
  (let* ((base (%snapshot-base-name test hint))
         (count (1+ (gethash base (ss-counts state) 0))))
    (setf (gethash base (ss-counts state)) count)
    (format nil "~a ~a" base count)))

(defun snapshot-format-value (value)
  "Return Clun's deterministic snapshot representation for VALUE."
  (eng:inspect-value value))

(defun %snapshot-record-output (state key value)
  (multiple-value-bind (old present-p) (gethash key (ss-output-values state))
    (declare (ignore old))
    (unless present-p (push key (ss-output-order state))))
  (setf (gethash key (ss-output-values state)) value))

(defun snapshot-match-external (state test hint value)
  "Return STATUS, EXPECTED, and KEY for one external snapshot assertion."
  (unless state (%snapshot-error "Snapshot state is unavailable"))
  (incf (ss-total state))
  (setf (ss-external-seen-p state) t)
  (let ((key (%snapshot-next-key state (or test (ss-active-test state)) hint)))
    (multiple-value-bind (expected present-p) (gethash key (ss-values state))
      (cond
        ((ss-update-p state)
         (%snapshot-record-output state key value)
         (setf (ss-external-dirty-p state) t)
         (if present-p
             (if (string= expected value)
                 (progn (incf (ss-matched state)) (values :matched expected key))
                 (progn (incf (ss-updated state)) (values :updated expected key)))
             (progn (incf (ss-added state)) (values :added nil key))))
        (present-p
         (if (string= expected value)
             (progn (incf (ss-matched state)) (values :matched expected key))
             (progn (incf (ss-failed state)) (values :mismatch expected key))))
        ((ss-ci-p state)
         (incf (ss-failed state))
         (values :ci-denied nil key))
        (t
         (setf (gethash key (ss-values state)) value
               (ss-external-dirty-p state) t)
         (push key (ss-order state))
         (incf (ss-added state))
         (values :added nil key))))))

(defun %snapshot-split-lines (text)
  (let ((lines '()) (start 0))
    (dotimes (index (length text))
      (when (char= (char text index) #\Newline)
        (push (subseq text start index) lines)
        (setf start (1+ index))))
    (push (subseq text start) lines)
    (nreverse lines)))

(defun %snapshot-blank-line-p (line)
  (every (lambda (character) (member character '(#\Space #\Tab #\Return))) line))

(defun %snapshot-line-indent (line)
  (or (position-if-not (lambda (character) (member character '(#\Space #\Tab))) line)
      (length line)))

(defun snapshot-normalize-inline (text)
  "Dedent Jest-style multiline inline snapshot strings; leave single lines exact."
  (unless (find #\Newline text) (return-from snapshot-normalize-inline text))
  (let ((lines (%snapshot-split-lines text)))
    (when (and lines (%snapshot-blank-line-p (first lines))) (pop lines))
    (when (and lines (%snapshot-blank-line-p (car (last lines))))
      (setf lines (butlast lines)))
    (let ((indent (loop for line in lines
                        unless (%snapshot-blank-line-p line)
                          minimize (%snapshot-line-indent line))))
      (with-output-to-string (output)
        (loop for line in lines
              for first-p = t then nil do
          (unless first-p (write-char #\Newline output))
          (if (%snapshot-blank-line-p line)
              (write-string "" output)
              (write-string (subseq line (min (or indent 0) (length line))) output)))))))

(defun %snapshot-template-escape (text)
  (with-output-to-string (output)
    (loop for index below (length text)
          for character = (char text index) do
      (cond
        ((or (char= character #\\) (char= character #\`))
         (write-char #\\ output)
         (write-char character output))
        ((and (char= character #\$)
              (< (1+ index) (length text))
              (char= (char text (1+ index)) #\{))
         (write-char #\\ output)
         (write-char character output))
        (t (write-char character output))))))

(defun %snapshot-top-level-comma (text)
  (let ((round 0) (square 0) (curly 0) (quote nil)
        (escaped nil) (line-comment nil) (block-comment nil))
    (loop for index below (length text)
          for character = (char text index)
          for next = (and (< (1+ index) (length text)) (char text (1+ index))) do
      (cond
        (line-comment
         (when (char= character #\Newline) (setf line-comment nil)))
        (block-comment
         (when (and (char= character #\*) next (char= next #\/))
           (setf block-comment nil)))
        (quote
         (cond (escaped (setf escaped nil))
               ((char= character #\\) (setf escaped t))
               ((char= character quote) (setf quote nil))))
        ((and (char= character #\/) next (char= next #\/))
         (setf line-comment t))
        ((and (char= character #\/) next (char= next #\*))
         (setf block-comment t))
        ((member character '(#\' #\" #\`) :test #'char=)
         (setf quote character))
        ((char= character #\() (incf round))
        ((char= character #\)) (decf round))
        ((char= character #\[) (incf square))
        ((char= character #\]) (decf square))
        ((char= character #\{) (incf curly))
        ((char= character #\}) (decf curly))
        ((and (char= character #\,) (zerop round) (zerop square) (zerop curly))
         (return index))))))

(defun %snapshot-inline-edit (state value has-property-matchers-p source-span)
  (multiple-value-bind (start end)
      (if source-span
          (values (first source-span) (second source-span))
          (eng:current-call-source-span))
    (unless (and start end (<= 0 start end (length (ss-source-text state))))
      (%snapshot-error "Inline snapshot matcher has no source location"))
    (let* ((source (ss-source-text state))
           (call (subseq source start end))
           (marker "toMatchInlineSnapshot")
           (marker-position (search marker call :from-end t)))
      (unless marker-position
        (%snapshot-error "Failed to locate toMatchInlineSnapshot at its call site"))
      (let* ((open (position #\( call :start (+ marker-position (length marker))))
             (close (position-if-not #'%snapshot-whitespace-p call :from-end t)))
        (unless (and open close (> close open) (char= (char call close) #\)))
          (%snapshot-error "Failed to locate inline snapshot argument boundaries"))
        (let* ((inside (subseq call (1+ open) close))
               (literal (format nil "`~a`" (%snapshot-template-escape value)))
               (replacement
                 (if has-property-matchers-p
                     (let* ((comma (%snapshot-top-level-comma inside))
                            (first-argument
                              (string-trim '(#\Space #\Tab #\Newline #\Return)
                                           (if comma (subseq inside 0 comma) inside))))
                       (when (zerop (length first-argument))
                         (%snapshot-error "Inline snapshot property matcher source is empty"))
                       (format nil "~a, ~a" first-argument literal))
                     literal)))
          (make-inline-snapshot-edit
           :start (+ start open 1)
           :end (+ start close)
           :replacement replacement))))))

(defun %snapshot-queue-inline-edit (state value has-property-matchers-p source-span)
  (let ((edit (%snapshot-inline-edit state value has-property-matchers-p source-span)))
    (dolist (existing (ss-inline-edits state))
      (when (and (= (ise-start existing) (ise-start edit))
                 (= (ise-end existing) (ise-end edit)))
        (unless (string= (ise-replacement existing) (ise-replacement edit))
          (%snapshot-error
           "Multiple inline snapshots at one call site produced different values"))
        (return-from %snapshot-queue-inline-edit existing)))
    (push edit (ss-inline-edits state))
    edit))

(defun snapshot-match-inline (state value expected has-property-matchers-p
                              &optional source-span)
  "Return STATUS and normalized EXPECTED for one inline snapshot assertion."
  (unless state (%snapshot-error "Snapshot state is unavailable"))
  (incf (ss-total state))
  (if expected
      (let ((normalized (snapshot-normalize-inline expected)))
        (cond
          ((string= value normalized)
           (incf (ss-matched state))
           (values :matched normalized))
          ((ss-update-p state)
           (%snapshot-queue-inline-edit state value has-property-matchers-p source-span)
           (incf (ss-updated state))
           (values :updated normalized))
          (t
           (incf (ss-failed state))
           (values :mismatch normalized))))
      (cond
        ((and (ss-ci-p state) (not (ss-update-p state)))
         (incf (ss-failed state))
         (values :ci-denied nil))
        (t
         (%snapshot-queue-inline-edit state value has-property-matchers-p source-span)
         (incf (ss-added state))
         (values :added nil)))))

(defun %snapshot-render-external (state)
  (let ((values (if (ss-update-p state)
                    (ss-output-values state)
                    (ss-values state)))
        (order (if (ss-update-p state)
                   (nreverse (copy-list (ss-output-order state)))
                   (nreverse (copy-list (ss-order state))))))
    (with-output-to-string (output)
      (write-string +snapshot-header+ output)
      (dolist (key order)
        (format output "~%exports[`~a`] = `~a`;~%"
                (%snapshot-template-escape key)
                (%snapshot-template-escape (gethash key values)))))))

(defun %snapshot-apply-inline-edits (state)
  (let ((text (ss-source-text state))
        (edits (sort (copy-list (ss-inline-edits state)) #'> :key #'ise-start))
        (higher-start (length (ss-source-text state))))
    (dolist (edit edits)
      (unless (<= (ise-end edit) higher-start)
        (%snapshot-error "Overlapping inline snapshot source edits"))
      (setf text (concatenate 'string
                              (subseq text 0 (ise-start edit))
                              (ise-replacement edit)
                              (subseq text (ise-end edit)))
            higher-start (ise-start edit)))
    text))

(defun %snapshot-write-text-atomically (path text)
  (let ((temporary (format nil "~a.clun-tmp-~a" path (sys:getpid))))
    (unwind-protect
         (progn
           (sys:write-file-octets temporary (eng:code-units->utf8 text))
           (sys:rename-path temporary path))
      (when (sys:path-exists-p temporary)
        (ignore-errors (sys:remove-file temporary))))))

(defun snapshot-finalize (state)
  "Commit deferred external and inline snapshot writes for one completed test file."
  (unless state (return-from snapshot-finalize nil))
  (let ((inline-text nil))
    (when (ss-inline-edits state)
      (let ((current (sys:read-file-string (ss-test-path state))))
        (unless (string= current (ss-source-text state))
          (%snapshot-error "Test file changed while inline snapshots were running")))
      (setf inline-text (%snapshot-apply-inline-edits state)))
    (when (and (ss-external-seen-p state)
               (or (ss-update-p state) (ss-external-dirty-p state)))
      (sys:make-directory (sys:path-dirname (ss-snapshot-path state)) :recursive t)
      (%snapshot-write-text-atomically
       (ss-snapshot-path state) (%snapshot-render-external state)))
    (when inline-text
      (%snapshot-write-text-atomically (ss-test-path state) inline-text)))
  t)
