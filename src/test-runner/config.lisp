;;;; config.lisp -- the bunfig.toml surface owned by `clun test`.
;;;; Clun does not otherwise consume bunfig yet, so this parser deliberately reads
;;;; only test-runner-owned keys and ignores unrelated TOML keys.

(in-package :clun.test-runner)

(define-condition test-config-error (error)
  ((message :initarg :message :reader test-config-error-message))
  (:report (lambda (condition stream)
             (write-string (test-config-error-message condition) stream))))

(defun %config-error (path control &rest arguments)
  (error 'test-config-error
         :message (format nil "~a: ~?" path control arguments)))

(defstruct (test-bunfig-config (:conc-name tbc-))
  (preloads '())
  (coverage nil) (coverage-present-p nil)
  (coverage-reporters nil) (coverage-dir nil)
  (coverage-skip-test-files t) (coverage-skip-test-files-present-p nil)
  (coverage-ignore-patterns '())
  (coverage-threshold-lines nil) (coverage-threshold-functions nil)
  (coverage-threshold-statements nil)
  ;; Bun test.concurrentTestGlob: files matching any pattern run with
  ;; default concurrent (as if --concurrent for that file only).
  (concurrent-test-globs '()))

(defun %toml-trim (string)
  (string-trim '(#\Space #\Tab #\Newline #\Return) string))

(defun %toml-without-comment (line)
  "Remove a TOML comment while preserving # inside basic and literal strings."
  (let ((quote nil) (escaped nil))
    (loop for index below (length line)
          for character = (char line index)
          do (cond
               (escaped (setf escaped nil))
               ((and quote (char= quote #\") (char= character #\\))
                (setf escaped t))
               (quote
                (when (char= character quote) (setf quote nil)))
               ((or (char= character #\") (char= character #\'))
                (setf quote character))
               ((char= character #\#)
                (return (subseq line 0 index))))
          finally (return line))))

(defun %toml-array-complete-p (value)
  (let ((depth 0) (quote nil) (escaped nil))
    (loop for character across value
          do (cond
               (escaped (setf escaped nil))
               ((and quote (char= quote #\") (char= character #\\))
                (setf escaped t))
               (quote
                (when (char= character quote) (setf quote nil)))
               ((or (char= character #\") (char= character #\'))
                (setf quote character))
               ((char= character #\[) (incf depth))
               ((char= character #\]) (decf depth))))
    (and (zerop depth) (null quote))))

(defun %toml-hex-codepoint (digits path)
  (handler-case
      (let ((code (parse-integer digits :radix 16)))
        (or (code-char code)
            (%config-error path "invalid Unicode escape \\u~a" digits)))
    (parse-error () (%config-error path "invalid Unicode escape \\u~a" digits))))

(defun %parse-toml-string (value path)
  (let* ((text (%toml-trim value))
         (length (length text)))
    (unless (and (>= length 2)
                 (member (char text 0) '(#\" #\') :test #'char=)
                 (char= (char text 0) (char text (1- length))))
      (%config-error path "test.preload entries must be strings (got ~s)" text))
    (if (char= (char text 0) #\')
        (subseq text 1 (1- length))
        (with-output-to-string (output)
          (loop with index = 1
                while (< index (1- length))
                for character = (char text index)
                do (if (char= character #\\)
                       (progn
                         (incf index)
                         (when (>= index (1- length))
                           (%config-error path "unterminated escape in test.preload"))
                         (let ((escaped (char text index)))
                           (case escaped
                             (#\" (write-char #\" output))
                             (#\\ (write-char #\\ output))
                             (#\b (write-char #\Backspace output))
                             (#\t (write-char #\Tab output))
                             (#\n (write-char #\Newline output))
                             (#\f (write-char #\Page output))
                             (#\r (write-char #\Return output))
                             (#\u
                              (let ((end (+ index 5)))
                                (when (> end (1- length))
                                  (%config-error path "short Unicode escape in test.preload"))
                                (write-char (%toml-hex-codepoint
                                             (subseq text (1+ index) end) path)
                                            output)
                                (setf index (1- end))))
                             (otherwise
                              (%config-error path "unsupported escape \\~a in test.preload"
                                             escaped)))))
                       (write-char character output))
                   (incf index))))))

(defun %toml-array-items (body path)
  (let ((items '()) (start 0) (quote nil) (escaped nil))
    (labels ((emit (end)
               (let ((item (%toml-trim (subseq body start end))))
                 (when (plusp (length item))
                   (push (%parse-toml-string item path) items)))))
      (loop for index below (length body)
            for character = (char body index)
            do (cond
                 (escaped (setf escaped nil))
                 ((and quote (char= quote #\") (char= character #\\))
                  (setf escaped t))
                 (quote
                  (when (char= character quote) (setf quote nil)))
                 ((or (char= character #\") (char= character #\'))
                  (setf quote character))
                 ((char= character #\,)
                  (emit index)
                  (setf start (1+ index)))))
      (emit (length body)))
    (nreverse items)))

(defun %parse-test-preload-value (value path)
  (let ((text (%toml-trim value)))
    (cond
      ((zerop (length text))
       (%config-error path "test.preload requires a string or array of strings"))
      ((char= (char text 0) #\[)
       (unless (and (char= (char text (1- (length text))) #\])
                    (%toml-array-complete-p text))
         (%config-error path "unterminated test.preload array"))
       (%toml-array-items (subseq text 1 (1- (length text))) path))
      (t (list (%parse-toml-string text path))))))

(defun %parse-toml-boolean (value path key)
  (let ((text (string-downcase (%toml-trim value))))
    (cond ((string= text "true") t)
          ((string= text "false") nil)
          (t (%config-error path "test.~a must be true or false" key)))))

(defun %parse-toml-number (value path key)
  (handler-case
      (let ((*read-eval* nil))
        (multiple-value-bind (number end) (read-from-string (%toml-trim value))
          (unless (and (realp number)
                       (= end (length (%toml-trim value)))
                       (<= 0 number 1))
            (%config-error path "test.~a must be a number from 0 through 1" key))
          (coerce number 'double-float)))
    (error () (%config-error path "test.~a must be a number from 0 through 1" key))))

(defun %toml-inline-table-fields (value path)
  (let* ((text (%toml-trim value))
         (length (length text)))
    (unless (and (>= length 2) (char= (char text 0) #\{)
                 (char= (char text (1- length)) #\}))
      (%config-error path "test.coverageThreshold must be a number or inline table"))
    (let ((body (subseq text 1 (1- length))) (fields '()) (start 0)
          (quote nil) (escaped nil))
      (labels ((emit (end)
                 (let* ((item (%toml-trim (subseq body start end)))
                        (equals (position #\= item)))
                   (when (plusp (length item))
                     (unless equals
                       (%config-error path "invalid test.coverageThreshold field ~s" item))
                     (push (cons (string-downcase (%toml-trim (subseq item 0 equals)))
                                 (%toml-trim (subseq item (1+ equals))))
                           fields)))))
        (loop for index below (length body)
              for character = (char body index)
              do (cond
                   (escaped (setf escaped nil))
                   ((and quote (char= quote #\") (char= character #\\))
                    (setf escaped t))
                   (quote (when (char= character quote) (setf quote nil)))
                   ((or (char= character #\") (char= character #\'))
                    (setf quote character))
                   ((char= character #\,)
                    (emit index)
                    (setf start (1+ index)))))
        (emit (length body)))
      (nreverse fields))))

(defun %set-coverage-threshold (config value path)
  (let ((text (%toml-trim value)))
    (if (and (plusp (length text)) (char= (char text 0) #\{))
        (let ((seen (make-hash-table :test #'equal)))
          (dolist (field (%toml-inline-table-fields text path))
            (let ((key (car field)))
              (unless (member key '("lines" "functions" "statements") :test #'string=)
                (%config-error path "unsupported test.coverageThreshold field ~s" key))
              (when (gethash key seen)
                (%config-error path "duplicate test.coverageThreshold field ~s" key))
              (setf (gethash key seen) t)
              (let ((number (%parse-toml-number (cdr field) path
                                                (concatenate 'string
                                                             "coverageThreshold." key))))
                (cond ((string= key "lines")
                       (setf (tbc-coverage-threshold-lines config) number))
                      ((string= key "functions")
                       (setf (tbc-coverage-threshold-functions config) number))
                      (t (setf (tbc-coverage-threshold-statements config) number)))))))
        (let ((number (%parse-toml-number text path "coverageThreshold")))
          (setf (tbc-coverage-threshold-lines config) number
                (tbc-coverage-threshold-functions config) number
                (tbc-coverage-threshold-statements config) number)))))

(defun %test-config-key (section key)
  (cond
    ((string= section "test") key)
    ((and (string= section "") (>= (length key) 5)
          (string= key "test." :end1 5 :end2 5))
     (subseq key 5))))

(defun %parse-coverage-reporters (value path)
  (let ((values (%parse-test-preload-value value path)))
    (dolist (reporter values)
      (unless (member reporter '("text" "lcov") :test #'string=)
        (%config-error path "unsupported test.coverageReporter value ~s" reporter)))
    (remove-duplicates
     (mapcar (lambda (value) (if (string= value "text") :text :lcov)) values))))

(defun read-test-config-from-bunfig (cwd)
  "Read Clun-owned [test] configuration from CWD/bunfig.toml."
  (let ((path (sys:path-join cwd "bunfig.toml")))
    (if (not (sys:file-p path))
        (make-test-bunfig-config)
        (with-open-file (input (sys:native->pathname path)
                               :direction :input :external-format :utf-8)
          (let ((section "") (config (make-test-bunfig-config))
                (seen (make-hash-table :test #'equal)))
            (loop for raw = (read-line input nil nil)
                  while raw
                  for line = (%toml-trim (%toml-without-comment raw))
                  do (cond
                       ((zerop (length line)) nil)
                       ((and (char= (char line 0) #\[)
                             (char= (char line (1- (length line))) #\]))
                        (setf section
                              (string-downcase
                               (%toml-trim (subseq line 1 (1- (length line)))))))
                       (t
                        (let ((equals (position #\= line)))
                          (when equals
                            (let* ((raw-key (string-downcase
                                            (%toml-trim (subseq line 0 equals))))
                                   (key (%test-config-key section raw-key)))
                              (when (member key
                                            '("preload" "coverage" "coveragereporter"
                                              "coveragedir" "coverageskiptestfiles"
                                              "coveragepathignorepatterns"
                                              "coveragethreshold"
                                              "concurrenttestglob")
                                            :test #'string=)
                                (when (gethash key seen)
                                  (%config-error path "test.~a is declared more than once" key))
                                (setf (gethash key seen) t)
                                (let ((value (%toml-trim (subseq line (1+ equals)))))
                                  (when (and (plusp (length value))
                                             (char= (char value 0) #\[))
                                    (loop until (%toml-array-complete-p value)
                                          for continuation = (read-line input nil nil)
                                          do (unless continuation
                                               (%config-error path
                                                              "unterminated test.preload array"))
                                             (setf value
                                                   (concatenate
                                                    'string value " "
                                                    (%toml-without-comment continuation)))))
                                  (cond
                                    ((string= key "preload")
                                     (setf (tbc-preloads config)
                                           (%parse-test-preload-value value path)))
                                    ((string= key "coverage")
                                     (setf (tbc-coverage config)
                                           (%parse-toml-boolean value path "coverage")
                                           (tbc-coverage-present-p config) t))
                                    ((string= key "coveragereporter")
                                     (setf (tbc-coverage-reporters config)
                                           (%parse-coverage-reporters value path)))
                                    ((string= key "coveragedir")
                                     (setf (tbc-coverage-dir config)
                                           (%parse-toml-string value path)))
                                    ((string= key "coverageskiptestfiles")
                                     (setf (tbc-coverage-skip-test-files config)
                                           (%parse-toml-boolean value path
                                                                "coverageSkipTestFiles")
                                           (tbc-coverage-skip-test-files-present-p config) t))
                                    ((string= key "coveragepathignorepatterns")
                                     (setf (tbc-coverage-ignore-patterns config)
                                           (%parse-test-preload-value value path)))
                                    ((string= key "concurrenttestglob")
                                     (setf (tbc-concurrent-test-globs config)
                                           (if (and (plusp (length value))
                                                    (char= (char value 0) #\[))
                                               (%parse-test-preload-value value path)
                                               (list (%parse-toml-string value path)))))
                                    (t (%set-coverage-threshold config value path)))))))))))
            config)))))

(defun read-test-preloads-from-bunfig (cwd)
  "Return test preload specifiers from CWD/bunfig.toml in declaration order."
  (tbc-preloads (read-test-config-from-bunfig cwd)))
