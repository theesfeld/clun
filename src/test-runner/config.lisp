;;;; config.lisp -- the bunfig.toml surface owned by `clun test`.
;;;; Clun does not otherwise consume bunfig yet, so this parser deliberately reads
;;;; only test.preload / [test] preload and ignores unrelated TOML keys.

(in-package :clun.test-runner)

(define-condition test-config-error (error)
  ((message :initarg :message :reader test-config-error-message))
  (:report (lambda (condition stream)
             (write-string (test-config-error-message condition) stream))))

(defun %config-error (path control &rest arguments)
  (error 'test-config-error
         :message (format nil "~a: ~?" path control arguments)))

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

(defun read-test-preloads-from-bunfig (cwd)
  "Return test preload specifiers from CWD/bunfig.toml in declaration order."
  (let ((path (sys:path-join cwd "bunfig.toml")))
    (if (not (sys:file-p path))
        '()
        (with-open-file (input (sys:native->pathname path)
                               :direction :input :external-format :utf-8)
          (let ((section "") (result nil) (seen nil))
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
                            (let* ((key (string-downcase
                                         (%toml-trim (subseq line 0 equals))))
                                   (target-p
                                     (or (and (string= section "")
                                              (string= key "test.preload"))
                                         (and (string= section "test")
                                              (string= key "preload")))))
                              (when target-p
                                (when seen
                                  (%config-error path "test.preload is declared more than once"))
                                (setf seen t)
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
                                  (setf result (%parse-test-preload-value value path))))))))))
            result)))))
