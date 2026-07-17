;;;; shell.lisp -- Clun.$ application shell.
;;;;
;;;; The language is parsed and executed directly in Common Lisp. External programs
;;;; are started only when the user asks the shell to run them; no host shell is used.
;;;; Template substitutions remain out-of-band lexer units, so ordinary values cannot
;;;; manufacture operators, expansions, redirections, or additional argv entries.

(in-package :clun.runtime)

(define-condition shell-syntax-error (error)
  ((message :initarg :message :reader shell-syntax-error-message))
  (:report (lambda (condition stream)
             (write-string (shell-syntax-error-message condition) stream))))

(define-condition shell-condition-evaluation-error (error)
  ((message :initarg :message :reader shell-condition-evaluation-error-message)
   (status :initarg :status :initform 2
           :reader shell-condition-evaluation-error-status)))

(defstruct shell-fragment kind value quoted)
(defstruct shell-word (fragments '()))
(defstruct shell-token kind value)
(defstruct shell-redirection kind target)
(defstruct shell-if-branch condition body)
(defstruct shell-if-form (branches '()) alternative)
(defstruct shell-command
  (words '()) (assignments '()) (redirections '()) group if-form negated)
(defstruct shell-pipeline (commands '()))
(defstruct shell-script (pipelines '()) (operators '()))
(defstruct shell-result
  (stdout #() :type vector)
  (stderr #() :type vector)
  (exit-code 0 :type integer))
(defstruct shell-output-sink kind target)
(defstruct shell-prepared-redirection kind target)
(defstruct shell-state
  (env '()) cwd old-cwd (last-exit-code 0) (throws t) (quiet nil)
  (terminated nil))
(defstruct shell-job
  units state g result error (started nil))
(defstruct (shell-condition-operand
            (:constructor %make-shell-condition-operand (value protected)))
  value protected)
(defstruct shell-brace-token kind value)
(defstruct shell-brace-atom kind value)
(defstruct shell-brace-group (atoms '()))

(defparameter *shell-max-array-depth* 100)
(defparameter *shell-max-seq-items* 1000000)
(defparameter *shell-max-builtin-bytes* (* 256 1024 1024))
(defparameter *shell-empty-octets*
  (make-array 0 :element-type '(unsigned-byte 8)))

(defun %shell-syntax (control &rest arguments)
  (error 'shell-syntax-error :message (apply #'format nil control arguments)))

(defun %shell-octets (string)
  (eng:code-units->utf8-replacing string))

(defun %shell-string (octets)
  (eng:utf8->code-units octets))

(defun %shell-concat-octets (&rest vectors)
  (let* ((size (reduce #'+ vectors :key #'length :initial-value 0))
         (output (make-array size :element-type '(unsigned-byte 8)))
         (offset 0))
    (dolist (vector vectors output)
      (replace output vector :start1 offset)
      (incf offset (length vector)))))

(defun %shell-env-copy (env)
  (mapcar (lambda (entry) (cons (car entry) (cdr entry))) env))

(defun %shell-env-get (env name &optional (default ""))
  (let ((entry (assoc name env :test #'string=)))
    (if entry (cdr entry) default)))

(defun %shell-env-set (env name value)
  (let ((entry (assoc name env :test #'string=)))
    (if entry
        (setf (cdr entry) value)
        (push (cons name value) env)))
  env)

(defun %shell-env-unset (env name)
  (delete name env :key #'car :test #'string=))

(defun %shell-env-vector (env)
  (mapcar (lambda (entry) (format nil "~a=~a" (car entry) (cdr entry))) env))

(defun %shell-valid-name-p (name)
  (and (plusp (length name))
       (or (alpha-char-p (char name 0)) (char= (char name 0) #\_))
       (loop for character across name
             always (or (alphanumericp character) (char= character #\_)))))

(defun %shell-raw-interpolation (value)
  "Return explicit raw source, or NIL when VALUE is an ordinary safe interpolation."
  (when (eng:js-object-p value)
    (let ((raw (eng:js-get value "raw")))
      (unless (eng:js-undefined-p raw)
        (eng:to-string raw)))))

(defun %shell-validate-interpolation-depth (value &optional (depth 0))
  (when (> depth *shell-max-array-depth*)
    (eng:throw-range-error
     "Shell script template arrays cannot be nested more than 100 levels deep"))
  (when (eng:js-array-p value)
    (loop for index below (eng:array-length value)
          do (%shell-validate-interpolation-depth
              (eng:js-getv value (princ-to-string index)) (1+ depth)))))

(defun %shell-template-units (strings expressions)
  "Build a vector of characters and (:INTERP . value) cells from a tag call."
  (unless (eng:js-array-p strings)
    (eng:throw-type-error "Clun.$ must be used as a tagged template literal"))
  (let* ((raw-value (eng:js-get strings "raw"))
         (source (if (eng:js-array-p raw-value) raw-value strings))
         (pieces (make-array 32 :adjustable t :fill-pointer 0)))
    (labels ((append-source (string)
               (loop for character across string do (vector-push-extend character pieces))))
      (loop for index below (eng:array-length source)
            for literal = (eng:to-string (eng:js-getv source (princ-to-string index)))
            do (append-source literal)
               (when (< index (length expressions))
                 (let* ((value (nth index expressions))
                        (raw (%shell-raw-interpolation value)))
                   (if raw
                       (append-source raw)
                       (progn
                         (%shell-validate-interpolation-depth value)
                         (vector-push-extend (cons :interp value) pieces))))))
      (coerce pieces 'vector))))

(defun %shell-operator-at (units index)
  (flet ((matches (text)
           (and (<= (+ index (length text)) (length units))
                (loop for offset below (length text)
                      for unit = (aref units (+ index offset))
                      always (and (characterp unit)
                                  (char= unit (char text offset)))))))
    (or (find-if #'matches '("2>&1" "1>&2" "&>>" "2>>" "1>>" "&&" "||"
                             ">>" "&>" "2>" "1>" "|" ";" "<" ">" "&"
                             "(" ")")))))

(defun %shell-read-substitution (units start)
  "Read the body after a consumed $(, returning its units and the next index."
  (let ((output (make-array 32 :adjustable t :fill-pointer 0))
        (index start) (depth 1) (quote nil) (escaped nil))
    (loop while (< index (length units)) do
      (let ((unit (aref units index)))
        (cond
          ((not (characterp unit))
           (vector-push-extend unit output) (incf index))
          (escaped
           (vector-push-extend unit output) (setf escaped nil) (incf index))
          ((and (not (eq quote :single)) (char= unit #\\))
           (vector-push-extend unit output) (setf escaped t) (incf index))
          ((and (not (eq quote :double)) (char= unit #\'))
           (vector-push-extend unit output)
           (setf quote (if (eq quote :single) nil :single))
           (incf index))
          ((and (not (eq quote :single)) (char= unit #\"))
           (vector-push-extend unit output)
           (setf quote (if (eq quote :double) nil :double))
           (incf index))
          ((and (null quote) (char= unit #\$)
                (< (1+ index) (length units))
                (characterp (aref units (1+ index)))
                (char= (aref units (1+ index)) #\())
           (incf depth)
           (vector-push-extend unit output)
           (vector-push-extend #\( output)
           (incf index 2))
          ((and (null quote) (char= unit #\)))
           (decf depth)
           (incf index)
           (if (zerop depth)
               (return-from %shell-read-substitution
                 (values (coerce output 'vector) index))
               (vector-push-extend unit output)))
          (t
           (vector-push-extend unit output) (incf index)))))
    (%shell-syntax "unterminated command substitution")))

(defun %shell-read-variable (units index quoted)
  "Read a variable beginning at the character after $, returning fragment and next index."
  (when (>= index (length units))
    (return-from %shell-read-variable
      (values (make-shell-fragment :kind :literal :value "$" :quoted quoted) index)))
  (let ((unit (aref units index)))
    (unless (characterp unit)
      (return-from %shell-read-variable
        (values (make-shell-fragment :kind :literal :value "$" :quoted quoted) index)))
    (cond
      ((char= unit #\?)
       (values (make-shell-fragment :kind :status :value "?" :quoted quoted) (1+ index)))
      ((char= unit #\{)
       (let ((end (loop for position from (1+ index) below (length units)
                        for candidate = (aref units position)
                        when (and (characterp candidate)
                                  (char= candidate #\}))
                          return position)))
         (unless end (%shell-syntax "unterminated variable expansion"))
         (unless (every #'characterp (subseq units (1+ index) end))
           (%shell-syntax "invalid interpolation in variable name"))
         (let ((name (coerce (subseq units (1+ index) end) 'string)))
           (unless (%shell-valid-name-p name)
             (%shell-syntax "invalid variable name: ~a" name))
           (values (make-shell-fragment :kind :variable :value name :quoted quoted)
                   (1+ end)))))
      ((or (alpha-char-p unit) (char= unit #\_))
       (let ((end index))
         (loop while (and (< end (length units))
                          (let ((character (aref units end)))
                            (and (characterp character)
                                 (or (alphanumericp character) (char= character #\_)))))
               do (incf end))
         (values (make-shell-fragment
                  :kind :variable :value (coerce (subseq units index end) 'string)
                  :quoted quoted)
                 end)))
      (t
       (values (make-shell-fragment :kind :literal :value "$" :quoted quoted) index)))))

(defun %shell-lex (units)
  (let ((tokens '()) (fragments '())
        (literal (make-string-output-stream))
        (literal-quoted nil) (word-started nil)
        (quote nil) (index 0) (in-condition nil))
    (labels ((flush-literal ()
               (let ((text (get-output-stream-string literal)))
                 (when (plusp (length text))
                   (push (make-shell-fragment :kind :literal :value text
                                              :quoted literal-quoted)
                         fragments))))
             (begin-literal (quoted)
               (when (and word-started (not (eql literal-quoted quoted)))
                 (flush-literal))
               (setf literal-quoted quoted word-started t))
             (emit-character (character quoted)
               (begin-literal quoted) (write-char character literal))
             (emit-fragment (fragment)
               (flush-literal) (push fragment fragments) (setf word-started t))
             (flush-word ()
               (flush-literal)
               (when word-started
                 (let* ((word (make-shell-word :fragments (nreverse fragments)))
                        (parts (shell-word-fragments word)))
                   (push (make-shell-token :kind :word :value word) tokens)
                   (when (and (= (length parts) 1)
                              (eq (shell-fragment-kind (first parts)) :literal)
                              (not (shell-fragment-quoted (first parts))))
                     (cond
                       ((string= (shell-fragment-value (first parts)) "[[")
                        (setf in-condition t))
                       ((string= (shell-fragment-value (first parts)) "]]")
                        (setf in-condition nil))))))
               (setf fragments '() word-started nil literal-quoted nil))
             (emit-operator (operator)
               (flush-word)
               (push (make-shell-token :kind :operator :value operator) tokens)))
      (loop while (< index (length units)) do
        (let ((unit (aref units index)))
          (cond
            ((not (characterp unit))
             (emit-fragment (make-shell-fragment :kind :interpolation
                                                 :value (cdr unit)
                                                 :quoted (not (null quote))))
             (incf index))
            ((eq quote :single)
             (if (char= unit #\')
                 (progn (setf quote nil word-started t) (incf index))
                 (progn (emit-character unit t) (incf index))))
            ((char= unit #\\)
             (if (< (1+ index) (length units))
                 (let ((next (aref units (1+ index))))
                   (cond
                     ((and (characterp next) (char= next #\Newline))
                      (incf index 2))
                     ((characterp next)
                      (let ((escaped
                              (not (and (eq quote :double)
                                        (not (find next "$\\\"`"))))))
                        (when escaped (setf index (1+ index)))
                        (emit-character (aref units index)
                                        (or escaped (not (null quote))))
                        (incf index)))
                     (t
                      (emit-character #\\ (not (null quote)))
                      (incf index))))
                 (progn (emit-character #\\ (not (null quote))) (incf index))))
            ((char= unit #\")
             (setf quote (if (eq quote :double) nil :double) word-started t)
             (incf index))
            ((and (null quote) (char= unit #\'))
             (setf quote :single word-started t) (incf index))
            ((char= unit #\$)
             (if (and (< (1+ index) (length units))
                      (characterp (aref units (1+ index)))
                      (char= (aref units (1+ index)) #\())
                 (multiple-value-bind (body next)
                     (%shell-read-substitution units (+ index 2))
                   (emit-fragment (make-shell-fragment :kind :substitution
                                                       :value body
                                                       :quoted (not (null quote))))
                   (setf index next))
                 (multiple-value-bind (fragment next)
                     (%shell-read-variable units (1+ index) (not (null quote)))
                   (emit-fragment fragment) (setf index next))))
            ((and (null quote)
                  (find unit '(#\Space #\Tab #\Return #\Newline)))
             (flush-word)
             (when (find unit '(#\Return #\Newline))
               (unless (and tokens
                            (eq (shell-token-kind (first tokens)) :operator)
                            (string= (shell-token-value (first tokens)) ";"))
                 (emit-operator ";")))
             (incf index))
            ((and (null quote) (char= unit #\#) (not word-started))
             (loop while (and (< index (length units))
                              (let ((value (aref units index)))
                                (not (and (characterp value)
                                          (find value '(#\Return #\Newline))))))
                   do (incf index)))
            ((null quote)
             (let ((operator (%shell-operator-at units index)))
               (if (and operator
                        (not (and in-condition
                                  (member operator '("(" ")" "|")
                                          :test #'string=))))
                   (progn (emit-operator operator) (incf index (length operator)))
                   (progn (emit-character unit nil) (incf index)))))
            (t
             (emit-character unit t) (incf index)))))
      (when quote (%shell-syntax "unterminated ~a quote" quote))
      (flush-word)
      (nreverse tokens))))

(defun %shell-assignment-word (word)
  "Return NAME and a value word when WORD statically starts NAME=."
  (let ((fragments (shell-word-fragments word)))
    (when fragments
      (let ((first (first fragments)))
        (when (and (eq (shell-fragment-kind first) :literal)
                   (not (shell-fragment-quoted first)))
          (let* ((text (shell-fragment-value first))
                 (equals (position #\= text)))
            (when equals
              (let ((name (subseq text 0 equals)))
                (when (%shell-valid-name-p name)
                  (let ((rest (subseq text (1+ equals))))
                    (values name
                            (make-shell-word
                             :fragments
                             (append (when (plusp (length rest))
                                       (list (make-shell-fragment
                                              :kind :literal :value rest :quoted nil)))
                                     (rest fragments))))))))))))))

(defun %shell-redirection-kind (operator)
  (cdr (assoc operator
              '(("<" . :input) (">" . :output) ("1>" . :output)
                (">>" . :output-append) ("1>>" . :output-append)
                ("2>" . :error) ("2>>" . :error-append)
                ("&>" . :both) ("&>>" . :both-append)
                ("2>&1" . :error-to-output) ("1>&2" . :output-to-error))
              :test #'string=)))

(defun %shell-static-token-word (token)
  (when (eq (shell-token-kind token) :word)
    (let ((fragments (shell-word-fragments (shell-token-value token))))
      (when (and (= (length fragments) 1)
                 (eq (shell-fragment-kind (first fragments)) :literal)
                 (not (shell-fragment-quoted (first fragments))))
        (shell-fragment-value (first fragments))))))

(defun %shell-command-start-after-token-p (token)
  (and (eq (shell-token-kind token) :operator)
       (member (shell-token-value token) '(";" "&&" "||" "|" "(")
               :test #'string=)))

(defun %shell-control-state-after-token (token control-depth at-command-start)
  (let ((word (and at-command-start (%shell-static-token-word token))))
    (cond
      ((and word (string= word "if"))
       (values (1+ control-depth) t))
      ((and word (string= word "fi"))
       (when (zerop control-depth) (%shell-syntax "unexpected fi"))
       (values (1- control-depth) nil))
      ((and word
            (member word '("then" "elif" "else") :test #'string=))
       (when (zerop control-depth) (%shell-syntax "unexpected ~a" word))
       (values control-depth t))
      (t
       (values control-depth
               (%shell-command-start-after-token-p token))))))

(defun %shell-parse-if-command (tokens)
  (let ((branches '()) (alternative nil) (condition nil)
        (phase :condition) (start 1) (depth 1) (at-command-start t)
        (close nil))
    (labels ((parse-section (end label)
               (let ((section (subseq tokens start end)))
                 (when (null section)
                   (%shell-syntax "if has an empty ~a section" label))
                 (let ((script (%shell-parse-tokens section)))
                   (when (null (shell-script-pipelines script))
                     (%shell-syntax "if has an empty ~a section" label))
                   script)))
             (finish-branch (end)
               (unless condition (%shell-syntax "if branch is missing then"))
               (push (make-shell-if-branch
                      :condition condition
                      :body (parse-section end "body"))
                     branches)
               (setf condition nil)))
      (loop for index from 1 below (length tokens)
            for token = (nth index tokens)
            for word = (and at-command-start (%shell-static-token-word token))
            do (cond
                 ((and word (string= word "if"))
                  (incf depth)
                  (setf at-command-start t))
                 ((and word (string= word "fi"))
                  (if (> depth 1)
                      (progn
                        (decf depth)
                        (setf at-command-start nil))
                      (progn
                        (case phase
                          (:condition (%shell-syntax "if is missing then"))
                          (:body (finish-branch index))
                          (:else
                           (setf alternative (parse-section index "else body"))))
                        (setf close index)
                        (loop-finish))))
                 ((and (= depth 1) word (string= word "then"))
                  (unless (eq phase :condition)
                    (%shell-syntax "unexpected then in if"))
                  (setf condition (parse-section index "condition")
                        phase :body
                        start (1+ index)
                        at-command-start t))
                 ((and (= depth 1) word (string= word "elif"))
                  (unless (eq phase :body)
                    (%shell-syntax "unexpected elif in if"))
                  (finish-branch index)
                  (setf phase :condition
                        start (1+ index)
                        at-command-start t))
                 ((and (= depth 1) word (string= word "else"))
                  (unless (eq phase :body)
                    (%shell-syntax "unexpected else in if"))
                  (finish-branch index)
                  (setf phase :else
                        start (1+ index)
                        at-command-start t))
                 (t
                  (setf at-command-start
                        (%shell-command-start-after-token-p token)))))
      (unless close (%shell-syntax "unterminated if"))
      (let* ((suffix (nthcdr (1+ close) tokens))
             (redirections
               (when suffix
                 (let ((parsed (%shell-parse-command suffix)))
                   (when (or (shell-command-group parsed)
                             (shell-command-if-form parsed)
                             (shell-command-words parsed)
                             (shell-command-assignments parsed)
                             (shell-command-negated parsed))
                     (%shell-syntax "unexpected token after fi"))
                   (shell-command-redirections parsed)))))
        (make-shell-command
         :if-form (make-shell-if-form
                   :branches (nreverse branches)
                   :alternative alternative)
         :redirections redirections)))))

(defun %shell-parse-command (tokens)
  (when (and tokens
             (string= (or (%shell-static-token-word (first tokens)) "") "if"))
    (return-from %shell-parse-command (%shell-parse-if-command tokens)))
  (when (and tokens
             (eq (shell-token-kind (first tokens)) :operator)
             (string= (shell-token-value (first tokens)) "("))
    (let ((depth 0) (close nil))
      (loop for token in tokens
            for index from 0
            when (eq (shell-token-kind token) :operator)
              do (cond
                   ((string= (shell-token-value token) "(") (incf depth))
                   ((string= (shell-token-value token) ")")
                    (decf depth)
                    (when (minusp depth) (%shell-syntax "unexpected )"))
                    (when (zerop depth) (setf close index) (loop-finish)))))
      (unless close (%shell-syntax "unterminated subshell group"))
      (let* ((inner (subseq tokens 1 close))
             (suffix (nthcdr (1+ close) tokens))
             (redirections
               (when suffix
                 (let ((parsed (%shell-parse-command suffix)))
                   (when (or (shell-command-group parsed)
                             (shell-command-if-form parsed)
                             (shell-command-words parsed)
                             (shell-command-assignments parsed)
                             (shell-command-negated parsed))
                     (%shell-syntax "unexpected token after subshell group"))
                   (shell-command-redirections parsed)))))
        (when (null inner) (%shell-syntax "empty subshell group"))
        (return-from %shell-parse-command
          (make-shell-command :group (%shell-parse-tokens inner)
                              :redirections redirections)))))
  (let ((words '()) (assignments '()) (redirections '()) (command-seen nil)
        (negated nil) (index 0))
    (when (and tokens
               (string= (or (%shell-static-token-word (first tokens)) "") "!"))
      (setf negated t index 1)
      (when (= index (length tokens))
        (%shell-syntax "! has no command")))
    (loop while (< index (length tokens)) do
      (let ((token (nth index tokens)))
        (cond
          ((eq (shell-token-kind token) :word)
           (let ((word (shell-token-value token)))
             (multiple-value-bind (name value-word)
                 (and (not command-seen) (%shell-assignment-word word))
               (if name
                   (push (cons name value-word) assignments)
                   (progn (setf command-seen t) (push word words)))))
           (incf index))
          ((eq (shell-token-kind token) :operator)
           (let* ((operator (shell-token-value token))
                  (kind (%shell-redirection-kind operator)))
             (unless kind (%shell-syntax "unexpected operator ~a" operator))
             (if (member kind '(:error-to-output :output-to-error))
                 (progn (push (make-shell-redirection :kind kind) redirections)
                        (incf index))
                 (progn
                   (when (>= (1+ index) (length tokens))
                     (%shell-syntax "redirection ~a has no target" operator))
                   (let ((target (nth (1+ index) tokens)))
                     (unless (eq (shell-token-kind target) :word)
                       (%shell-syntax "redirection ~a has no target" operator))
                     (push (make-shell-redirection
                            :kind kind :target (shell-token-value target))
                           redirections))
                   (incf index 2)))))
          (t (%shell-syntax "invalid command token")))))
    (make-shell-command :words (nreverse words)
                        :assignments (nreverse assignments)
                        :redirections (nreverse redirections)
                        :negated negated)))

(defun %shell-split-tokens (tokens separator)
  (let ((groups '()) (current '()) (depth 0) (control-depth 0)
        (at-command-start t))
    (dolist (token tokens)
      (when (eq (shell-token-kind token) :operator)
        (cond
          ((string= (shell-token-value token) "(") (incf depth))
          ((string= (shell-token-value token) ")")
           (decf depth)
           (when (minusp depth) (%shell-syntax "unexpected )")))))
      (multiple-value-setq (control-depth at-command-start)
        (%shell-control-state-after-token token control-depth at-command-start))
      (if (and (zerop depth)
               (zerop control-depth)
               (eq (shell-token-kind token) :operator)
               (string= (shell-token-value token) separator))
          (progn
            (when (null current) (%shell-syntax "empty command before ~a" separator))
            (push (nreverse current) groups) (setf current '()))
          (push token current)))
    (unless (zerop depth) (%shell-syntax "unterminated subshell group"))
    (unless (zerop control-depth) (%shell-syntax "unterminated if"))
    (when (null current) (%shell-syntax "empty command after ~a" separator))
    (nreverse (cons (nreverse current) groups))))

(defun %shell-parse-pipeline (tokens)
  (make-shell-pipeline
   :commands (mapcar #'%shell-parse-command (%shell-split-tokens tokens "|"))))

(defun %shell-operator-word-token (operator)
  (make-shell-token
   :kind :word
   :value (make-shell-word
           :fragments (list (make-shell-fragment
                             :kind :literal :value operator :quoted nil)))))

(defun %shell-parse-tokens (tokens)
  (let ((pipelines '()) (operators '()) (current '())
        (in-condition nil) (depth 0) (control-depth 0)
        (at-command-start t))
    (labels ((flush (operator)
               (when current
                 (push (%shell-parse-pipeline (nreverse current)) pipelines)
                 (setf current '())
                 (when operator (push operator operators)))))
      (dolist (token tokens)
        (let ((word (%shell-static-token-word token)))
          (multiple-value-setq (control-depth at-command-start)
            (%shell-control-state-after-token token control-depth at-command-start))
          (cond
            ((and (not in-condition) word (string= word "[["))
             (setf in-condition t)
             (push token current))
            ((and in-condition word (string= word "]]"))
             (setf in-condition nil)
             (push token current))
            ((and in-condition
                  (eq (shell-token-kind token) :operator)
                  (member (shell-token-value token) '("&&" "||" "<" ">" "(" ")")
                          :test #'string=))
             (push (%shell-operator-word-token (shell-token-value token)) current))
            ((and (not in-condition)
                  (eq (shell-token-kind token) :operator)
                  (string= (shell-token-value token) "("))
             (incf depth)
             (push token current))
            ((and (not in-condition)
                  (eq (shell-token-kind token) :operator)
                  (string= (shell-token-value token) ")"))
             (decf depth)
             (when (minusp depth) (%shell-syntax "unexpected )"))
             (push token current))
            ((and (not in-condition)
                  (zerop depth)
                  (zerop control-depth)
                  (eq (shell-token-kind token) :operator)
                  (member (shell-token-value token) '(";" "&&" "||") :test #'string=))
             (flush (cond ((string= (shell-token-value token) "&&") :and)
                          ((string= (shell-token-value token) "||") :or)
                          (t :sequence))))
            (t (push token current)))))
      (unless (zerop depth) (%shell-syntax "unterminated subshell group"))
      (unless (zerop control-depth) (%shell-syntax "unterminated if"))
      (flush nil))
    ;; A trailing separator records one extra operator; it has no right-hand side.
    (when (>= (length operators) (length pipelines))
      (setf operators (butlast operators)))
    (make-shell-script :pipelines (nreverse pipelines)
                       :operators (nreverse operators))))

(defun %shell-parse (units)
  (%shell-parse-tokens (%shell-lex units)))

;;; --- expansion -------------------------------------------------------------

(defun %shell-whitespace-fields (string)
  (let ((fields '()) (start nil))
    (loop for index from 0 to (length string)
          for whitespace = (or (= index (length string))
                               (find (char string index)
                                     '(#\Space #\Tab #\Return #\Newline)))
          do (cond
               ((and whitespace start)
                (push (subseq string start index) fields) (setf start nil))
               ((and (not whitespace) (null start)) (setf start index))))
    (nreverse fields)))

(defun %shell-flatten-interpolation (value &optional (depth 0))
  (when (> depth *shell-max-array-depth*)
    (eng:throw-range-error
     "Shell script template arrays cannot be nested more than 100 levels deep"))
  (if (eng:js-array-p value)
      (loop for index below (eng:array-length value)
            append (%shell-flatten-interpolation
                    (eng:js-getv value (princ-to-string index)) (1+ depth)))
      (list (cond
              ((eng:js-null-p value) "null")
              ((eng:js-undefined-p value) "undefined")
              ((and (eng:js-object-p value)
                    (not (eng:js-undefined-p (eng:js-get value "name")))
                    (stringp (eng:js-get value "name")))
               (eng:js-get value "name"))
              (t (eng:to-string value))))))

(defun %shell-trim-command-output (string)
  (string-right-trim '(#\Newline #\Return) string))

(defun %shell-fragment-values (fragment state g)
  "Return values for FRAGMENT and whether unquoted field splitting applies."
  (let ((quoted (shell-fragment-quoted fragment)))
    (case (shell-fragment-kind fragment)
      (:literal (values (list (shell-fragment-value fragment)) nil))
      (:interpolation
       (values (%shell-flatten-interpolation (shell-fragment-value fragment)) nil))
      (:variable
       (let ((value (%shell-env-get (shell-state-env state)
                                    (shell-fragment-value fragment) "")))
         (values (if quoted (list value) (%shell-whitespace-fields value)) (not quoted))))
      (:status
       (values (list (princ-to-string (shell-state-last-exit-code state))) nil))
      (:substitution
       (let* ((sub-state (copy-shell-state state))
              (result (%shell-execute-units
                       (shell-fragment-value fragment) sub-state g))
              (value (%shell-trim-command-output
                      (%shell-string (shell-result-stdout result)))))
         (setf (shell-state-last-exit-code state) (shell-result-exit-code result))
         (values (if quoted (list value) (%shell-whitespace-fields value)) (not quoted))))
      (otherwise (values (list "") nil)))))

(defun %shell-word-glob-p (word)
  (some (lambda (fragment)
          (and (eq (shell-fragment-kind fragment) :literal)
               (not (shell-fragment-quoted fragment))
               (find-if (lambda (character) (find character "*?["))
                        (shell-fragment-value fragment))))
        (shell-word-fragments word)))

(defun %shell-word-brace-p (word)
  (some (lambda (fragment)
          (and (eq (shell-fragment-kind fragment) :literal)
               (not (shell-fragment-quoted fragment))
               (find #\{ (shell-fragment-value fragment))))
        (shell-word-fragments word)))

(defun %shell-protect-pattern-value (value)
  "Escape syntax-bearing characters supplied by a non-literal shell fragment."
  (with-output-to-string (output)
    (loop for character across value do
      (when (find character "\\*?[]{}!,^-")
        (write-char #\\ output))
      (write-char character output))))

(defun %shell-word-tilde-p (word)
  (let ((first (first (shell-word-fragments word))))
    (and first (eq (shell-fragment-kind first) :literal)
         (not (shell-fragment-quoted first))
         (plusp (length (shell-fragment-value first)))
         (char= (char (shell-fragment-value first) 0) #\~))))

(defun %shell-expand-tilde (value state)
  (cond
    ((string= value "~") (%shell-env-get (shell-state-env state) "HOME" ""))
    ((and (> (length value) 1) (char= (char value 0) #\~)
          (char= (char value 1) #\/))
     (concatenate 'string (%shell-env-get (shell-state-env state) "HOME" "")
                  (subseq value 1)))
    (t value)))

(defun %shell-glob-matches (value state)
  (handler-case
      (let* ((options (clun.glob:make-glob-scan-options
                       :cwd (shell-state-cwd state) :dot nil :only-files nil))
             (matches (clun.glob:scan-glob value options)))
        (and (plusp (length matches)) (coerce matches 'list)))
    (error () nil)))

(defun %shell-expand-glob (pattern fallback state)
  (or (%shell-glob-matches pattern state) (list fallback)))

(defun %shell-expand-brace-pattern (pattern fallback)
  (let ((tokens (%shell-brace-tokenize pattern)))
    (if (find :open tokens :key #'shell-brace-token-kind)
        (%shell-brace-expand-parsed (%shell-brace-parse tokens))
        (list fallback))))

(defun %shell-word-values (word state g)
  (let ((fields (list "")) (patterns (list "")) (has-value nil))
    (dolist (fragment (shell-word-fragments word))
      (multiple-value-bind (values split-p) (%shell-fragment-values fragment state g)
        (declare (ignore split-p))
        (if values
            (let ((pattern-values
                    (if (and (eq (shell-fragment-kind fragment) :literal)
                             (not (shell-fragment-quoted fragment)))
                        values
                        (mapcar #'%shell-protect-pattern-value values))))
              (setf fields
                    (loop for prefix in fields append
                      (loop for value in values
                            collect (concatenate 'string prefix value)))
                    patterns
                    (loop for prefix in patterns append
                      (loop for value in pattern-values
                            collect (concatenate 'string prefix value)))
                    has-value t))
            (setf fields nil patterns nil))))
    (when (and (null fields)
               (some #'shell-fragment-quoted (shell-word-fragments word)))
      (setf fields (list "") patterns (list "")))
    (when (and fields (%shell-word-tilde-p word))
      (setf fields (mapcar (lambda (value) (%shell-expand-tilde value state)) fields)
            patterns (mapcar (lambda (value) (%shell-expand-tilde value state)) patterns)))
    (let ((brace-p (and fields (%shell-word-brace-p word)))
          (glob-p (and fields (%shell-word-glob-p word))))
      (when brace-p
        (let ((literal-variants
                (loop for value in fields
                      for pattern in patterns
                      append (%shell-expand-brace-pattern pattern value))))
          (setf fields
                (if glob-p
                    (append literal-variants
                            (mapcan (lambda (pattern)
                                      (%shell-glob-matches pattern state))
                                    patterns))
                    literal-variants))))
      (when (and glob-p (not brace-p))
        (setf fields
              (loop for value in fields
                    for pattern in patterns
                    append (%shell-expand-glob pattern value state)))))
    (if (or has-value (shell-word-fragments word)) fields nil)))

(defun %shell-word-raw-target (word state g)
  (let ((fragments (shell-word-fragments word)))
    (if (and (= (length fragments) 1)
             (eq (shell-fragment-kind (first fragments)) :interpolation))
        (shell-fragment-value (first fragments))
        (let ((values (%shell-word-values word state g)))
          (unless (= (length values) 1)
            (%shell-syntax "redirection target must expand to exactly one value"))
          (first values)))))

(defun %shell-assignment-value (word state g)
  (format nil "~{~a~}" (%shell-word-values word state g)))

;;; --- builtins and direct external execution --------------------------------

(defparameter *shell-builtins*
  '("echo" "pwd" "cd" "true" "false" ":" "export" "unset" "shopt" "which" "exit"
    "basename" "dirname" "seq" "cat" "mkdir" "touch" "rm" "mv" "ls" "cp" "yes"
    "[["))

(defun %shell-relative-path (path state)
  (if (clun.sys:absolute-path-p path)
      (clun.sys:normalize-path path)
      (clun.sys:normalize-path (clun.sys:path-join (shell-state-cwd state) path))))

(defun %shell-result-from-strings (stdout stderr code)
  (make-shell-result :stdout (%shell-octets stdout) :stderr (%shell-octets stderr)
                     :exit-code code))

(defun %shell-current-executable ()
  (loop for candidate in
          (list (ignore-errors
                  (clun.sys:pathname->native (truename sb-ext:*runtime-pathname*)))
                (first sb-ext:*posix-argv*))
        when candidate
          do (let ((path (if (clun.sys:absolute-path-p candidate)
                             candidate
                             (clun.sys:path-join
                              (clun.sys:current-directory) candidate))))
               (when (ignore-errors
                       (and (string= (clun.sys:path-basename path) "clun")
                            (clun.sys:file-p path)
                            (clun.sys:check-access path 1)))
                 (return path)))))

(defun %shell-which (name env cwd)
  (flet ((usable (path)
           (let ((resolved (if (clun.sys:absolute-path-p path)
                               path (clun.sys:path-join cwd path))))
             (and (ignore-errors
                    (and (clun.sys:file-p resolved)
                         (clun.sys:check-access resolved 1)))
                  resolved))))
    (if (find #\/ name)
        (usable name)
        (or (loop with path = (%shell-env-get env "PATH" "")
                  with start = 0
                  for colon = (position #\: path :start start)
                  for directory = (subseq path start (or colon (length path)))
                  for candidate = (clun.sys:path-join
                                   (if (string= directory "") cwd directory)
                                   name)
                  when (usable candidate) return candidate
                  while colon do (setf start (1+ colon)))
            (and (string= name "clun") (%shell-current-executable))))))

(defun %shell-path-separator-p (character)
  (or (char= character #\/) (char= character #\\)))

(defun %shell-trim-trailing-separators (path)
  (let ((end (length path)))
    (loop while (and (> end 1)
                     (%shell-path-separator-p (char path (1- end))))
          do (decf end))
    (subseq path 0 end)))

(defun %shell-basename (path)
  (let* ((trimmed (%shell-trim-trailing-separators path))
         (separator (position-if #'%shell-path-separator-p trimmed :from-end t)))
    (cond
      ((or (string= trimmed "/") (string= trimmed "\\")) trimmed)
      ((null separator) trimmed)
      (t (subseq trimmed (1+ separator))))))

(defun %shell-dirname (path)
  (let* ((trimmed (%shell-trim-trailing-separators path))
         (separator (position-if #'%shell-path-separator-p trimmed :from-end t)))
    (cond
      ((or (string= trimmed "/") (string= trimmed "\\")) trimmed)
      ((null separator) ".")
      ((zerop separator) (string (char trimmed 0)))
      (t (%shell-trim-trailing-separators (subseq trimmed 0 separator))))))

(defun %shell-echo-output (args newline)
  (let ((body (format nil "~{~a~^ ~}" args)))
    (if (not newline)
        body
        (let ((trailing 0))
          (loop for index downfrom (1- (length body)) to 0
                while (char= (char body index) #\Newline)
                do (incf trailing))
          (cond
            ((zerop trailing)
             (concatenate 'string body (string #\Newline)))
            ((= trailing (length body))
             (make-string (min trailing 2)
                          :initial-element #\Newline))
            (t
             (concatenate 'string (subseq body 0 (- (length body) trailing))
                          (string #\Newline))))))))

(defun %shell-parse-exit-code (argument)
  (handler-case
      (multiple-value-bind (value position) (parse-integer argument :junk-allowed t)
        (and value (= position (length argument)) (mod value 256)))
    (error () nil)))

(defun %shell-seq-number (text)
  (let ((number (eng:js-string->number text)))
    (when (and (eng:js-number-p number) (eng:js-finite-p number))
      (coerce number 'single-float))))

(defun %shell-seq-number-string (number)
  (eng:number->js-string (coerce number 'double-float)))

(defun %shell-seq-pad (text width)
  (let* ((negative (and (plusp (length text)) (char= (char text 0) #\-)))
         (digits (if negative (subseq text 1) text))
         (padding (max 0 (- width (length text)))))
    (if (zerop padding)
        text
        (concatenate 'string (if negative "-" "")
                     (make-string padding :initial-element #\0) digits))))

(defun %shell-seq-printf (control number)
  "Render NUMBER using seq's single printf-style floating conversion.
Returns NIL for an invalid control string.  Literal %% escapes are supported;
integer conversions are deliberately rejected because seq values are f32."
  (let ((output (make-string-output-stream))
        (index 0)
        (conversion-seen nil))
    (labels ((digit-p (character)
               (and character (digit-char-p character)))
             (read-digits ()
               (let ((start index))
                 (loop while (and (< index (length control))
                                  (digit-p (char control index)))
                       do (incf index))
                 (and (> index start)
                      (parse-integer control :start start :end index))))
             (emit-conversion ()
               (when conversion-seen (return-from %shell-seq-printf nil))
               (setf conversion-seen t)
               (let ((left nil) (plus nil) (space nil) (zero nil))
                 (loop while (< index (length control))
                       for flag = (char control index)
                       while (find flag "-+ 0" :test #'char=)
                       do (case flag
                            (#\- (setf left t))
                            (#\+ (setf plus t))
                            (#\Space (setf space t))
                            (#\0 (setf zero t)))
                          (incf index))
                 (let ((width (read-digits))
                       (precision nil))
                   (when (and (< index (length control))
                              (char= (char control index) #\.))
                     (incf index)
                     (setf precision (read-digits))
                     (unless precision (return-from %shell-seq-printf nil)))
                   (when (>= index (length control))
                     (return-from %shell-seq-printf nil))
                   (let* ((conversion (char control index))
                          (upper (upper-case-p conversion))
                          (raw
                            (case (char-downcase conversion)
                              (#\f (format nil "~,vF" (or precision 6) number))
                              (#\e (format nil "~,vE" (or precision 6) number))
                              (#\g (if precision
                                       (string-right-trim
                                        '(#\Space) (format nil "~,vG" precision number))
                                       (%shell-seq-number-string number)))
                              (otherwise
                               (return-from %shell-seq-printf nil))))
                          (signed
                            (if (or (minusp number)
                                    (and (not plus) (not space)))
                                raw
                                (concatenate 'string (if plus "+" " ") raw)))
                          (padding (max 0 (- (or width 0) (length signed))))
                          (pad-character (if (and zero (not left)) #\0 #\Space))
                          (formatted
                            (cond
                              ((zerop padding) signed)
                              (left
                               (concatenate 'string signed
                                            (make-string padding
                                                         :initial-element #\Space)))
                              ((and (char= pad-character #\0)
                                    (plusp (length signed))
                                    (find (char signed 0) "+- " :test #'char=))
                               (concatenate 'string (subseq signed 0 1)
                                            (make-string padding
                                                         :initial-element #\0)
                                            (subseq signed 1)))
                              (t
                               (concatenate 'string
                                            (make-string padding
                                                         :initial-element pad-character)
                                            signed)))))
                     (incf index)
                     (write-string (if upper (string-upcase formatted) formatted)
                                   output))))))
      (loop while (< index (length control)) do
        (let ((character (char control index)))
          (incf index)
          (if (char/= character #\%)
              (write-char character output)
              (cond
                ((and (< index (length control))
                      (char= (char control index) #\%))
                 (incf index)
                 (write-char #\% output))
                (t (emit-conversion))))))
      (and conversion-seen (get-output-stream-string output)))))

(defun %shell-run-seq (arguments)
  (let ((args arguments) (positionals '()) (separator (string #\Newline))
        (terminator "") (fixed-width nil) (format-control nil))
    (labels ((requires-argument (option)
               (return-from %shell-run-seq
                 (%shell-result-from-strings
                  "" (format nil "seq: option requires an argument -- ~a~%" option) 1)))
             (take-option-value (option)
               (unless args (requires-argument option))
               (pop args)))
      (loop while args do
        (let ((argument (pop args)))
          (cond
            ((or (string= argument "-w") (string= argument "--fixed-width"))
             (setf fixed-width t))
            ((string= argument "-s")
             (setf separator (take-option-value "s")))
            ((and (> (length argument) 2)
                  (string= argument "-s" :end1 2))
             (setf separator (subseq argument 2)))
            ((string= argument "--separator")
             (setf separator (take-option-value "s")))
            ((string= argument "-t")
             (setf terminator (take-option-value "t")))
            ((and (> (length argument) 2)
                  (string= argument "-t" :end1 2))
             (setf terminator (subseq argument 2)))
            ((string= argument "--terminator")
             (setf terminator (take-option-value "t")))
            ((string= argument "-f")
             (setf format-control (take-option-value "f")))
            ((and (> (length argument) 2)
                  (string= argument "-f" :end1 2))
             (setf format-control (subseq argument 2)))
            ((string= argument "--")
             (dolist (remaining args) (push remaining positionals))
             (setf args nil))
            (t (push argument positionals)))))
      (setf positionals (nreverse positionals))
      (when (or (null positionals) (> (length positionals) 3))
        (return-from %shell-run-seq
          (%shell-result-from-strings
           "" (format nil
                      "usage: seq [-w] [-f format] [-s string] [-t string] [first [incr]] last~%")
           1)))
      (let ((numbers (mapcar #'%shell-seq-number positionals)))
        (when (some #'null numbers)
          (return-from %shell-run-seq
            (%shell-result-from-strings "" (format nil "seq: invalid argument~%") 1)))
        (let* ((first (if (= (length numbers) 1) 1.0f0 (first numbers)))
               (last (car (last numbers)))
               (increment (cond
                            ((= (length numbers) 3) (second numbers))
                            ((<= first last) 1.0f0)
                            (t -1.0f0))))
          (when (zerop increment)
            (return-from %shell-run-seq
              (%shell-result-from-strings "" (format nil "seq: zero increment~%") 1)))
          (when (and (< first last) (minusp increment))
            (return-from %shell-run-seq
              (%shell-result-from-strings
               "" (format nil "seq: needs positive increment~%") 1)))
          (when (and (> first last) (plusp increment))
            (return-from %shell-run-seq
              (%shell-result-from-strings
               "" (format nil "seq: needs negative decrement~%") 1)))
          (let* ((first-text (%shell-seq-number-string first))
                 (last-text (%shell-seq-number-string last))
                 (width (max (length first-text) (length last-text)))
                 (output (make-string-output-stream))
                 (current first)
                 (count 0))
            (loop while (if (plusp increment) (<= current last) (>= current last)) do
              (when (>= count *shell-max-seq-items*)
                (return-from %shell-run-seq
                  (%shell-result-from-strings
                   "" (format nil "seq: output limit exceeded~%") 1)))
              (let ((text (%shell-seq-number-string current)))
                (when format-control
                  (let ((formatted (%shell-seq-printf format-control current)))
                    (unless formatted
                      (return-from %shell-run-seq
                        (%shell-result-from-strings
                         "" (format nil "seq: invalid format string~%") 1)))
                    (setf text formatted)))
                (write-string (if fixed-width (%shell-seq-pad text width) text) output)
                (write-string separator output))
              (incf count)
              (let ((next (+ current increment)))
                (when (= next current) (return))
                (setf current next)))
            (write-string terminator output)
            (%shell-result-from-strings (get-output-stream-string output) "" 0)))))))

(defun %shell-coreutils-message (code)
  (or (cdr (assoc code
                  '(("ENOENT" . "No such file or directory")
                    ("EEXIST" . "File exists")
                    ("EACCES" . "Permission denied")
                    ("ENOTDIR" . "Not a directory")
                    ("EISDIR" . "Is a directory")
                    ("ENOTEMPTY" . "Directory not empty")
                    ("EPERM" . "Operation not permitted")
                    ("ELOOP" . "Too many levels of symbolic links")
                    ("EROFS" . "Read-only file system")
                    ("ENOSPC" . "No space left on device"))
                  :test #'string=))
      (clun.sys:fs-code-message code)))

(defun %shell-builtin-error-string (name path message)
  (format nil "~a: ~a: ~a~%" name path message))

(defun %shell-fs-error-string (name display-path condition)
  (%shell-builtin-error-string
   name display-path (%shell-coreutils-message (clun.sys:fs-error-code condition))))

(defun %shell-append-octets (target source)
  (loop for byte across source do (vector-push-extend byte target))
  target)

(defun %shell-cat-visible-byte (byte output)
  (cond
    ((< byte 32)
     (vector-push-extend (char-code #\^) output)
     (vector-push-extend (+ byte 64) output))
    ((= byte 127)
     (vector-push-extend (char-code #\^) output)
     (vector-push-extend (char-code #\?) output))
    ((>= byte 128)
     (vector-push-extend (char-code #\M) output)
     (vector-push-extend (char-code #\-) output)
     (%shell-cat-visible-byte (- byte 128) output))
    (t (vector-push-extend byte output))))

(defun %shell-cat-transform (input number-all number-nonblank show-ends
                             squeeze-blank show-tabs show-nonprinting)
  (if (not (or number-all number-nonblank show-ends squeeze-blank
               show-tabs show-nonprinting))
      input
      (let ((output (make-array (max 32 (length input))
                                :element-type '(unsigned-byte 8)
                                :adjustable t :fill-pointer 0))
            (line-number 1)
            (at-line-start t)
            (newline-run 0))
        (labels ((emit-string (string)
                   (%shell-append-octets output (%shell-octets string)))
                 (emit-byte (byte)
                   (cond
                     ((and (= byte 9) show-tabs)
                      (emit-string "^I"))
                     ((and show-nonprinting (not (member byte '(9 10))))
                      (%shell-cat-visible-byte byte output))
                     (t (vector-push-extend byte output)))))
          (loop for byte across input do
            (if (= byte 10)
                (progn
                  (unless (and squeeze-blank (>= newline-run 2))
                    (when (and at-line-start number-all (not number-nonblank))
                      (emit-string (format nil "~6d~c" line-number #\Tab))
                      (incf line-number))
                    (when show-ends (vector-push-extend (char-code #\$) output))
                    (vector-push-extend byte output))
                  (incf newline-run)
                  (setf at-line-start t))
                (progn
                  (when (and at-line-start (or number-nonblank number-all))
                    (emit-string (format nil "~6d~c" line-number #\Tab))
                    (incf line-number))
                  (setf newline-run 0 at-line-start nil)
                  (emit-byte byte))))
          (coerce output '(simple-array (unsigned-byte 8) (*)))))))

(defun %shell-run-cat (arguments state stdin)
  (let ((args arguments) (files '())
        (number-all nil) (number-nonblank nil) (show-ends nil)
        (squeeze-blank nil) (show-tabs nil) (show-nonprinting nil))
    (labels ((option-error (option)
               (return-from %shell-run-cat
                 (%shell-result-from-strings
                  "" (format nil "cat: illegal option -- ~a~%" option) 1))))
      (loop while args do
        (let ((argument (pop args)))
          (cond
            ((string= argument "--")
             (setf files (append files args) args nil))
            ((or (string= argument "-")
                 (not (and (> (length argument) 1)
                           (char= (char argument 0) #\-))))
             (setf files (append files (list argument) args) args nil))
            ((and (> (length argument) 2)
                  (string= argument "--" :end1 2))
             (option-error argument))
            (t
             (loop for option across (subseq argument 1) do
               (case option
                 (#\b (setf number-nonblank t))
                 (#\e (setf show-ends t show-nonprinting t))
                 (#\n (setf number-all t))
                 (#\s (setf squeeze-blank t))
                 (#\t (setf show-tabs t show-nonprinting t))
                 (#\u nil)
                 (#\v (setf show-nonprinting t))
                 (otherwise (option-error (string option)))))))))
      (let ((collected (make-array 32 :element-type '(unsigned-byte 8)
                                   :adjustable t :fill-pointer 0))
            (stderr (make-string-output-stream))
            (exit-code 0)
            (sources (if files files (list "-"))))
        (dolist (file sources)
          (handler-case
              (let ((octets
                      (if (string= file "-")
                          stdin
                          (let ((path (%shell-relative-path file state)))
                            (let ((stat (clun.sys:stat* path)))
                              (when (> (clun.sys:fstat-size stat)
                                       *shell-max-builtin-bytes*)
                                (write-string
                                 (%shell-builtin-error-string
                                  "cat" file "File too large") stderr)
                                (setf exit-code 1)
                                (return))
                              (clun.sys:read-file-octets path))))))
                (when (> (+ (length collected) (length octets))
                         *shell-max-builtin-bytes*)
                  (write-string
                   (%shell-builtin-error-string "cat" file "Output limit exceeded")
                   stderr)
                  (setf exit-code 1)
                  (return))
                (%shell-append-octets collected octets))
            (clun.sys:fs-error (condition)
              (write-string (%shell-fs-error-string "cat" file condition) stderr)
              (setf exit-code 1)
              (return))))
        (make-shell-result
         :stdout (%shell-cat-transform
                  (coerce collected '(simple-array (unsigned-byte 8) (*)))
                  number-all number-nonblank show-ends squeeze-blank
                  show-tabs show-nonprinting)
         :stderr (%shell-octets (get-output-stream-string stderr))
         :exit-code exit-code)))))

(defun %shell-parse-octal-mode (text)
  (handler-case
      (multiple-value-bind (mode position) (parse-integer text :radix 8 :junk-allowed t)
        (and mode (= position (length text)) (<= 0 mode #o7777) mode))
    (error () nil)))

(defun %shell-missing-directories (path)
  (let ((missing '()) (current path))
    (loop while (and (plusp (length current))
                     (not (clun.sys:path-exists-p current)))
          do (push current missing)
             (let ((parent (clun.sys:path-dirname current)))
               (when (string= parent current) (return))
               (setf current parent)))
    missing))

(defun %shell-run-mkdir (arguments state)
  (let ((args arguments) (paths '()) (parents nil) (verbose nil) (mode #o777))
    (labels ((usage ()
               (return-from %shell-run-mkdir
                 (%shell-result-from-strings
                  "" (format nil "usage: mkdir [-pv] [-m mode] directory_name ...~%") 1)))
             (illegal (option)
               (return-from %shell-run-mkdir
                 (%shell-result-from-strings
                  "" (format nil "mkdir: illegal option -- ~a~%" option) 1)))
             (take-mode ()
               (unless args (usage))
               (let ((parsed (%shell-parse-octal-mode (pop args))))
                 (unless parsed
                   (return-from %shell-run-mkdir
                     (%shell-result-from-strings
                      "" (format nil "mkdir: invalid mode~%") 1)))
                 (setf mode parsed))))
      (loop while args do
        (let ((argument (pop args)))
          (cond
            ((string= argument "--")
             (setf paths (append paths args) args nil))
            ((or (string= argument "-")
                 (not (and (> (length argument) 1)
                           (char= (char argument 0) #\-))))
             (setf paths (append paths (list argument) args) args nil))
            ((string= argument "--parents") (setf parents t))
            ((or (string= argument "--verbose") (string= argument "--vebose"))
             (setf verbose t))
            ((string= argument "--mode") (take-mode))
            ((and (> (length argument) 7)
                  (string= argument "--mode=" :end1 7))
             (let ((parsed (%shell-parse-octal-mode (subseq argument 7))))
               (unless parsed
                 (return-from %shell-run-mkdir
                   (%shell-result-from-strings
                    "" (format nil "mkdir: invalid mode~%") 1)))
               (setf mode parsed)))
            ((and (> (length argument) 2)
                  (string= argument "-m" :end1 2))
             (let ((parsed (%shell-parse-octal-mode (subseq argument 2))))
               (unless parsed
                 (return-from %shell-run-mkdir
                   (%shell-result-from-strings
                    "" (format nil "mkdir: invalid mode~%") 1)))
               (setf mode parsed)))
            ((string= argument "-m") (take-mode))
            ((and (> (length argument) 2)
                  (string= argument "--" :end1 2))
             (illegal (subseq argument 2)))
            (t
             (loop for option across (subseq argument 1) do
               (case option
                 (#\p (setf parents t))
                 (#\v (setf verbose t))
                 (otherwise (illegal (string option)))))))))
      (unless paths (usage))
      (let ((stdout (make-string-output-stream))
            (stderr (make-string-output-stream))
            (exit-code 0))
        (dolist (path paths)
          (let* ((resolved (%shell-relative-path path state))
                 (missing (and parents (%shell-missing-directories resolved))))
            (handler-case
                (cond
                  ((and parents (clun.sys:directory-p resolved)) nil)
                  ((clun.sys:path-exists-p resolved)
                   (write-string
                    (%shell-builtin-error-string "mkdir" path "File exists") stderr)
                   (setf exit-code 1))
                  (t
                   (clun.sys:make-directory resolved :recursive parents :mode mode)
                   (when verbose
                     (dolist (created (if parents missing (list resolved)))
                       (format stdout "~a~%" created)))))
              (clun.sys:fs-error (condition)
                (write-string (%shell-fs-error-string "mkdir" path condition) stderr)
                (setf exit-code 1)))))
        (%shell-result-from-strings (get-output-stream-string stdout)
                                    (get-output-stream-string stderr) exit-code)))))

(defparameter *shell-touch-usage*
  (format nil
          "usage: touch [-A [-][[hh]mm]SS] [-achm] [-r file] [-t [[CC]YY]MMDDhhmm[.SS]]~%       [-d YYYY-MM-DDThh:mm:SS[.frac][tz]] file ...~%"))

(defun %shell-run-touch (arguments state)
  (let ((args arguments) (paths '()) (no-create nil))
    (labels ((usage ()
               (return-from %shell-run-touch
                 (%shell-result-from-strings "" *shell-touch-usage* 1)))
             (illegal (option)
               (return-from %shell-run-touch
                 (%shell-result-from-strings
                  "" (format nil "touch: illegal option -- ~a~%" option) 1)))
             (unsupported (option)
               (return-from %shell-run-touch
                 (%shell-result-from-strings
                  "" (format nil
                             "touch: unsupported option, please open a GitHub issue -- ~a~%"
                             option)
                  1))))
      (loop while args do
        (let ((argument (pop args)))
          (cond
            ((string= argument "--")
             (setf paths (append paths args) args nil))
            ((or (string= argument "-")
                 (not (and (> (length argument) 1)
                           (char= (char argument 0) #\-))))
             (setf paths (append paths (list argument) args) args nil))
            ((string= argument "--no-create") (setf no-create t))
            ((and (> (length argument) 2)
                  (string= argument "--" :end1 2))
             (illegal (subseq argument 2)))
            (t
             (loop for option across (subseq argument 1) do
               (case option
                 (#\c (setf no-create t))
                 (otherwise (unsupported (format nil "-~c" option)))))))))
      (unless paths (usage))
      (let ((stderr (make-string-output-stream)) (exit-code 0))
        (dolist (path paths)
          (handler-case
              (clun.sys:touch-file (%shell-relative-path path state)
                                   :no-create no-create)
            (clun.sys:fs-error (condition)
              (write-string (%shell-fs-error-string "touch" path condition) stderr)
              (setf exit-code 1))))
        (%shell-result-from-strings "" (get-output-stream-string stderr) exit-code)))))

(defparameter *shell-rm-usage*
  (format nil "usage: rm [-f | -i] [-dIPRrvWx] file ...~%       unlink [--] file~%"))

(defun %shell-rm-entry (resolved display recursive remove-empty-dirs verbose output)
  "Remove one lstat-classified entry. Directory output is postorder."
  (let ((stat (clun.sys:stat* resolved :lstat t)))
    (cond
      ((clun.sys:fstat-dir-p stat)
       (cond
         (recursive
          ;; MAP-DIRECTORY-ENTRIES retains dangling symlinks. Collect before
          ;; mutating so the directory stream is not live during recursion.
          (let ((entries '()))
            (clun.sys:map-directory-entries
             resolved (lambda (entry) (push entry entries)))
            (dolist (entry (nreverse entries))
              (%shell-rm-entry
               (clun.sys:path-join resolved entry)
               (clun.sys:path-join display entry)
               t remove-empty-dirs verbose output)))
          ;; Re-check the root entry after deleting children. If it was swapped
          ;; while the traversal ran, never follow or remove the replacement.
          (let ((after (clun.sys:stat* resolved :lstat t)))
            (unless (and (clun.sys:fstat-dir-p after)
                         (= (clun.sys:fstat-dev stat) (clun.sys:fstat-dev after))
                         (= (clun.sys:fstat-ino stat) (clun.sys:fstat-ino after)))
              (error 'clun.sys:fs-error
                     :code "ELOOP" :errno 0 :syscall "rm" :path resolved)))
          (clun.sys:remove-directory resolved))
         (remove-empty-dirs
          (clun.sys:remove-directory resolved))
         (t
          (error 'clun.sys:fs-error
                 :code "EISDIR" :errno 0 :syscall "rm" :path resolved))))
      (t (clun.sys:remove-file resolved)))
    (when verbose (format output "~a~%" display))))

(defun %shell-run-rm (arguments state)
  (let ((args arguments) (paths '())
        (force nil) (recursive nil) (verbose nil) (remove-empty-dirs nil))
    (labels ((usage ()
               (return-from %shell-run-rm
                 (%shell-result-from-strings "" *shell-rm-usage* 1)))
             (illegal (option)
               (return-from %shell-run-rm
                 (%shell-result-from-strings
                  "" (format nil "rm: illegal option -- ~a~%" option) 1)))
             (interactive ()
               (return-from %shell-run-rm
                 (%shell-result-from-strings
                  "" (format nil "rm: \"-i\" is not supported yet") 1))))
      (loop while args do
        (let ((argument (pop args)))
          (cond
            ((string= argument "--")
             (setf paths (append paths args) args nil))
            ((or (string= argument "-")
                 (not (and (> (length argument) 1)
                           (char= (char argument 0) #\-))))
             (setf paths (append paths (list argument) args) args nil))
            ((member argument '("--recursive") :test #'string=)
             (setf recursive t remove-empty-dirs t))
            ((string= argument "--force") (setf force t))
            ((string= argument "--verbose") (setf verbose t))
            ((string= argument "--dir") (setf remove-empty-dirs t))
            ((or (string= argument "--preserve-root")
                 (string= argument "--no-preserve-root"))
             ;; Clun's application shell never permits deletion of a filesystem
             ;; root, even when compatibility syntax asks to disable the guard.
             nil)
            ((string= argument "--interactive=never") nil)
            ((or (string= argument "--interactive=once")
                 (string= argument "--interactive=always"))
             (interactive))
            ((and (> (length argument) 2)
                  (string= argument "--" :end1 2))
             (illegal "-"))
            (t
             (loop for option across (subseq argument 1) do
               (case option
                 (#\f (setf force t))
                 ((#\r #\R) (setf recursive t remove-empty-dirs t))
                 (#\v (setf verbose t))
                 (#\d (setf remove-empty-dirs t))
                 ((#\i #\I) (interactive))
                 (otherwise (illegal (subseq argument 1)))))))))
      (unless paths (usage))
      (let ((stdout (make-string-output-stream))
            (stderr (make-string-output-stream))
            (exit-code 0))
        (dolist (path paths)
          (let ((resolved (%shell-relative-path path state)))
            (cond
              ((string= (clun.sys:normalize-path resolved) "/")
               (format stderr "rm: \"~a\" may not be removed~%" resolved)
               (setf exit-code 1))
              (t
               (handler-case
                   (%shell-rm-entry resolved path recursive remove-empty-dirs
                                    verbose stdout)
                 (clun.sys:fs-error (condition)
                   (unless (and force
                                (string= (clun.sys:fs-error-code condition) "ENOENT"))
                     (write-string (%shell-fs-error-string "rm" path condition) stderr)
                     (setf exit-code 1))))))))
        (%shell-result-from-strings (get-output-stream-string stdout)
                                    (get-output-stream-string stderr) exit-code)))))

(defparameter *shell-mv-usage*
  (format nil
          "usage: mv [-f | -i | -n] [-hv] source target~%       mv [-f | -i | -n] [-v] source ... directory~%"))

(defun %shell-path-stat (path &key lstat)
  "Return STAT, PRESENT-P, and a non-ENOENT filesystem condition."
  (handler-case
      (values (clun.sys:stat* path :lstat lstat) t nil)
    (clun.sys:fs-error (condition)
      (if (string= (clun.sys:fs-error-code condition) "ENOENT")
          (values nil nil nil)
          (values nil nil condition)))))

(defun %shell-run-mv (arguments state)
  (let ((args arguments) (paths nil)
        (no-dereference nil) (no-overwrite nil) (verbose nil))
    (labels ((usage ()
               (return-from %shell-run-mv
                 (%shell-result-from-strings "" *shell-mv-usage* 1)))
             (illegal ()
               (return-from %shell-run-mv
                 (%shell-result-from-strings
                  "" (format nil "mv: illegal option -- -~%") 1))))
      ;; Bun stops option parsing at the first pathname. A bare `--` is an
      ;; illegal option in its frozen builtin rather than an option terminator.
      (loop while args do
        (let ((argument (first args)))
          (if (or (zerop (length argument))
                  (not (char= (char argument 0) #\-)))
              (progn (setf paths args) (return))
              (progn
                (pop args)
                (loop for option across (subseq argument 1) do
                  (case option
                    (#\f (setf no-overwrite nil))
                    (#\h (setf no-dereference t))
                    ;; Interactive input is not surfaced by the frozen Bun
                    ;; implementation; its last-option-wins overwrite state is.
                    (#\i (setf no-overwrite nil))
                    (#\n (setf no-overwrite t))
                    (#\v (setf verbose t))
                    (otherwise (illegal))))))))
      (unless (and paths (rest paths)) (usage))
      (let* ((sources (butlast paths))
             (target-display (car (last paths)))
             (target (%shell-relative-path target-display state))
             (stdout (make-string-output-stream)))
        (multiple-value-bind (target-stat target-present target-error)
            (%shell-path-stat target :lstat no-dereference)
          (when target-error
            (return-from %shell-run-mv
              (%shell-result-from-strings
               "" (%shell-fs-error-string "mv" target-display target-error) 1)))
          (let ((target-directory (and target-present
                                       (clun.sys:fstat-dir-p target-stat))))
            (when (and (> (length sources) 1) (not target-directory))
              (return-from %shell-run-mv
                (%shell-result-from-strings
                 "" (if target-present
                        (format nil "mv: ~a is not a directory~%" target-display)
                        (%shell-builtin-error-string
                         "mv" target-display "No such file or directory"))
                 1)))
            (dolist (source-display sources)
              (let* ((source (%shell-relative-path source-display state))
                     (destination-display
                       (if target-directory
                           (clun.sys:path-join target-display
                                               (%shell-basename source-display))
                           target-display))
                     (destination
                       (if target-directory
                           (clun.sys:path-join target (%shell-basename source-display))
                           target)))
                (multiple-value-bind (ignored destination-present destination-error)
                    (%shell-path-stat destination :lstat t)
                  (declare (ignore ignored))
                  (when destination-error
                    (return-from %shell-run-mv
                      (%shell-result-from-strings
                       (get-output-stream-string stdout)
                       (%shell-fs-error-string "mv" destination-display destination-error)
                       1)))
                  (unless (and no-overwrite destination-present)
                    (handler-case
                        (progn
                          (clun.sys:rename-path source destination)
                          (when verbose
                            (format stdout "~a -> ~a~%" source-display destination-display)))
                      (clun.sys:fs-error (condition)
                        (let* ((code (clun.sys:fs-error-code condition))
                               (display (if (string= code "ENOTDIR")
                                            destination-display source-display))
                               (exit-code (clun.sys:fs-error-errno condition)))
                          (return-from %shell-run-mv
                            (%shell-result-from-strings
                             (get-output-stream-string stdout)
                             (%shell-fs-error-string "mv" display condition)
                             (if (plusp exit-code) exit-code 1))))))))))
            (%shell-result-from-strings (get-output-stream-string stdout) "" 0)))))))

(defparameter *shell-ls-recognized-options*
  "aAbBcCdDfFgGhHiIkLlmnNopqQRrsStTuUvwxXZ1")

(defun %shell-ls-entry-type (mode)
  (case (logand mode #o170000)
    (#o040000 #\d)
    (#o120000 #\l)
    (#o060000 #\b)
    (#o020000 #\c)
    (#o010000 #\p)
    (#o140000 #\s)
    (otherwise #\-)))

(defun %shell-ls-permissions (mode)
  (let ((result (make-string 9 :initial-element #\-)))
    (flet ((set-permission (mask index character)
             (when (plusp (logand mode mask))
               (setf (char result index) character))))
      (set-permission #o400 0 #\r)
      (set-permission #o200 1 #\w)
      (set-permission #o100 2 #\x)
      (set-permission #o040 3 #\r)
      (set-permission #o020 4 #\w)
      (set-permission #o010 5 #\x)
      (set-permission #o004 6 #\r)
      (set-permission #o002 7 #\w)
      (set-permission #o001 8 #\x)
      (when (plusp (logand mode #o4000))
        (setf (char result 2) (if (plusp (logand mode #o100)) #\s #\S)))
      (when (plusp (logand mode #o2000))
        (setf (char result 5) (if (plusp (logand mode #o010)) #\s #\S)))
      (when (plusp (logand mode #o1000))
        (setf (char result 8) (if (plusp (logand mode #o001)) #\t #\T))))
    result))

(defun %shell-ls-time (timestamp now)
  (handler-case
      (multiple-value-bind (second minute hour day month year)
          (decode-universal-time (+ timestamp 2208988800) 0)
        (declare (ignore second))
        (let* ((months #("Jan" "Feb" "Mar" "Apr" "May" "Jun"
                         "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))
               (name (aref months (1- month)))
               (six-months (* 180 24 60 60))
               (recent (and (> timestamp (- now six-months))
                            (<= timestamp (+ now six-months)))))
          (if recent
              (format nil "~a ~2,'0d ~2,'0d:~2,'0d" name day hour minute)
              (format nil "~a ~2,'0d  ~4d" name day year))))
    (error () "??? ?? ??:??")))

(defun %shell-ls-write-long-entry (name path now output)
  (handler-case
      (let* ((stat (clun.sys:stat* path :lstat t))
             (mode (clun.sys:fstat-mode stat))
             (timestamp (floor (clun.sys:fstat-mtime-ns stat) 1000000000)))
        (format output "~c~a ~3d ~5d ~5d ~8d ~a ~a~%"
                (%shell-ls-entry-type mode)
                (%shell-ls-permissions mode)
                (clun.sys:fstat-nlink stat)
                (clun.sys:fstat-uid stat)
                (clun.sys:fstat-gid stat)
                (clun.sys:fstat-size stat)
                (%shell-ls-time timestamp now)
                name))
    (clun.sys:fs-error ()
      (format output "?????????? ? ? ? ?            ? ~a~%" name))))

(defun %shell-run-ls (arguments state)
  (let ((args arguments) (paths nil)
        (show-all nil) (show-almost-all nil) (list-directories nil)
        (recursive nil) (reverse-order nil) (long-listing nil))
    (labels ((illegal (option)
               (return-from %shell-run-ls
                 (%shell-result-from-strings
                  "" (format nil "ls: illegal option -- ~a~%" option) 1))))
      (loop while args do
        (let ((argument (first args)))
          (cond
            ((or (zerop (length argument))
                 (not (char= (char argument 0) #\-)))
             (setf paths args)
             (return))
            ((= (length argument) 1) (illegal "-"))
            (t
             (pop args)
             (loop for option across (subseq argument 1) do
               (unless (find option *shell-ls-recognized-options*)
                 (illegal (string option)))
               (case option
                 (#\a (setf show-all t))
                 (#\A (setf show-almost-all t))
                 (#\d (setf list-directories t))
                 (#\l (setf long-listing t))
                 (#\R (setf recursive t))
                 (#\r (setf reverse-order t))))))))
      (unless paths (setf paths '(".")))
      (let ((stdout (make-string-output-stream))
            (stderr (make-string-output-stream))
            (exit-code 0)
            (now (truncate (clun.sys:unix-milliseconds) 1000))
            (multiple-paths (> (length paths) 1)))
        (labels
            ((visible-p (name)
               (cond
                 (show-all t)
                 (show-almost-all
                  (not (member name '("." "..") :test #'string=)))
                 (t (or (zerop (length name))
                        (not (char= (char name 0) #\.))))))
             (ordered (entries)
               (let ((result (sort entries #'string<)))
                 (if reverse-order (nreverse result) result)))
             (write-entry (name resolved-path)
               (if long-listing
                   (%shell-ls-write-long-entry
                    name resolved-path now stdout)
                   (format stdout "~a~%" name)))
             (record-error (display condition)
               (write-string (%shell-fs-error-string "ls" display condition) stderr)
               (setf exit-code 1))
             (entry-directory-p (resolved name)
               (handler-case
                   (clun.sys:fstat-dir-p
                    (clun.sys:stat-at* resolved name :lstat t))
                 (clun.sys:fs-error () nil)))
             (visit (display resolved print-directory)
               (handler-case
                   (let ((stat (clun.sys:stat* resolved)))
                     (cond
                       ((and (clun.sys:fstat-dir-p stat) (not list-directories))
                        (when print-directory (format stdout "~a:~%" display))
                        (let ((entries '()))
                          (handler-case
                              (clun.sys:map-directory-entries
                               resolved (lambda (entry) (push entry entries)))
                            (clun.sys:fs-error (condition)
                              (record-error display condition)
                              (return-from visit nil)))
                          (setf entries (ordered entries))
                          (when show-all
                            (write-entry "." (clun.sys:path-join resolved "."))
                            (write-entry ".." (clun.sys:path-join resolved "..")))
                          (dolist (entry entries)
                            (when (visible-p entry)
                              (write-entry entry (clun.sys:path-join resolved entry))))
                          (when recursive
                            (dolist (entry entries)
                              (when (and (visible-p entry)
                                         (entry-directory-p resolved entry))
                                (visit (clun.sys:path-join display entry)
                                       (clun.sys:path-join resolved entry) t))))))
                       (t (write-entry display resolved))))
                 (clun.sys:fs-error (condition)
                   (record-error display condition)))))
          (dolist (path paths)
            (visit path (if (zerop (length path)) "" (%shell-relative-path path state))
                   multiple-paths)))
        (%shell-result-from-strings (get-output-stream-string stdout)
                                    (get-output-stream-string stderr) exit-code)))))

(defparameter *shell-cp-usage*
  (format nil
          "usage: cp [-R [-H | -L | -P]] [-fi | -n] [-aclpsvXx] source_file target_file~%       cp [-R [-H | -L | -P]] [-fi | -n] [-aclpsvXx] source_file ... target_directory~%"))

(define-condition shell-cp-error (error)
  ((message :initarg :message :reader shell-cp-error-message)))

(defun %shell-cp-custom-error (control &rest arguments)
  (error 'shell-cp-error :message (apply #'format nil control arguments)))

(defun %shell-cp-existing-stat (path)
  (multiple-value-bind (stat present condition) (%shell-path-stat path :lstat t)
    (when condition (error condition))
    (values stat present)))

(defun %shell-cp-same-entry-p (source destination)
  (multiple-value-bind (source-stat source-present) (%shell-cp-existing-stat source)
    (declare (ignore source-present))
    (multiple-value-bind (destination-stat destination-present)
        (%shell-cp-existing-stat destination)
      (and destination-present
           (= (clun.sys:fstat-dev source-stat) (clun.sys:fstat-dev destination-stat))
           (= (clun.sys:fstat-ino source-stat) (clun.sys:fstat-ino destination-stat))))))

(defun %shell-cp-contained-p (source destination)
  (or (string= source destination)
      (let ((prefix (if (string= source "/") "/"
                        (concatenate 'string
                                     (%shell-trim-trailing-separators source) "/"))))
        (and (>= (length destination) (length prefix))
             (string= prefix destination :end2 (length prefix))))))

(defun %shell-cp-canonical-destination (destination)
  "Resolve the nearest existing ancestor, retaining nonexistent suffixes."
  (loop with cursor = destination
        with suffix = '()
        for resolved = (clun.sys:realpath cursor)
        when resolved
          return (reduce #'clun.sys:path-join suffix :initial-value resolved)
        do (let ((parent (clun.sys:path-dirname cursor)))
             (when (string= parent cursor)
               (return (clun.sys:normalize-path destination)))
             (push (clun.sys:path-basename cursor) suffix)
             (setf cursor parent))))

(defun %shell-cp-descendant-p (source destination)
  (let ((source-normal (clun.sys:normalize-path source))
        (destination-normal (clun.sys:normalize-path destination))
        (source-real (clun.sys:realpath source))
        (destination-real (%shell-cp-canonical-destination destination)))
    (or (%shell-cp-contained-p source-normal destination-normal)
        (and source-real destination-real
             (%shell-cp-contained-p source-real destination-real)))))

(defun %shell-cp-remove-destination-link (destination destination-stat)
  ;; Never open a destination symlink for writing. Replacing the link is both
  ;; cp-compatible and prevents a target swap from redirecting file contents.
  (when (and destination-stat (clun.sys:fstat-symlink-p destination-stat))
    (clun.sys:remove-file destination)
    t))

(defun %shell-cp-copy-entry (source destination recursive no-overwrite
                              verbose output &optional (depth 0))
  (when (> depth 1024)
    (%shell-cp-custom-error "directory nesting exceeds 1024 entries"))
  (let ((source-stat (clun.sys:stat* source :lstat t)))
    (multiple-value-bind (destination-stat destination-present)
        (%shell-cp-existing-stat destination)
      (when (and destination-present
                 (= (clun.sys:fstat-dev source-stat)
                    (clun.sys:fstat-dev destination-stat))
                 (= (clun.sys:fstat-ino source-stat)
                    (clun.sys:fstat-ino destination-stat)))
        (%shell-cp-custom-error "~a and ~a are identical (not copied)"
                                source source))
      (when (and no-overwrite destination-present
                 (not (and (clun.sys:fstat-dir-p source-stat)
                           (clun.sys:fstat-dir-p destination-stat))))
        (return-from %shell-cp-copy-entry nil))
      (cond
        ((clun.sys:fstat-dir-p source-stat)
         (unless recursive
           (%shell-cp-custom-error "~a is a directory (not copied)" source))
         (when (%shell-cp-descendant-p source destination)
           (%shell-cp-custom-error "cannot copy a directory into itself: ~a" source))
         (cond
           ((and destination-present
                 (not (clun.sys:fstat-dir-p destination-stat)))
            (error 'clun.sys:fs-error :code "ENOTDIR" :errno 0
                   :syscall "copyfile" :path destination))
           ((not destination-present)
            (clun.sys:make-directory destination
                                     :mode (logand (clun.sys:fstat-mode source-stat) #o777))))
         (when verbose (format output "~a -> ~a~%" source destination))
         (let ((entries '()))
           (clun.sys:map-directory-entries
            source (lambda (entry) (push entry entries)))
           (dolist (entry (sort entries #'string<))
             (%shell-cp-copy-entry
              (clun.sys:path-join source entry)
              (clun.sys:path-join destination entry)
              recursive no-overwrite verbose output (1+ depth)))))
        ((clun.sys:fstat-symlink-p source-stat)
         (when destination-present
           (if (clun.sys:fstat-dir-p destination-stat)
               (error 'clun.sys:fs-error :code "EISDIR" :errno 0
                      :syscall "copyfile" :path destination)
               (clun.sys:remove-file destination)))
         (clun.sys:make-symlink (clun.sys:read-symlink source) destination)
         (when verbose (format output "~a -> ~a~%" source destination)))
        ((clun.sys:fstat-file-p source-stat)
         (%shell-cp-remove-destination-link destination destination-stat)
         (clun.sys:copy-file-stream
          source destination :mode (logand (clun.sys:fstat-mode source-stat) #o7777))
         (when verbose (format output "~a -> ~a~%" source destination)))
        (t (%shell-cp-custom-error "~a has an unsupported file type" source))))))

(defun %shell-run-cp (arguments state)
  (let ((args arguments) (paths nil)
        (recursive nil) (verbose nil) (no-overwrite nil))
    (labels ((usage ()
               (return-from %shell-run-cp
                 (%shell-result-from-strings "" *shell-cp-usage* 1)))
             (illegal (option)
               (return-from %shell-run-cp
                 (%shell-result-from-strings
                  "" (format nil "cp: illegal option -- ~a~%" option) 1)))
             (unsupported (option)
               (return-from %shell-run-cp
                 (%shell-result-from-strings
                  "" (format nil
                             "cp: unsupported option, please open a GitHub issue -- -~a~%"
                             option)
                  1))))
      (loop while args do
        (let ((argument (first args)))
          (cond
            ((or (zerop (length argument))
                 (not (char= (char argument 0) #\-)))
             (setf paths args)
             (return))
            ((= (length argument) 1) (illegal "-"))
            (t
             (pop args)
             (loop for index from 1 below (length argument)
                   for option = (char argument index)
                   do (case option
                        (#\R (setf recursive t))
                        (#\v (setf verbose t))
                        (#\n (setf no-overwrite t))
                        ((#\f #\H #\i #\L #\P #\p) (unsupported option))
                        (otherwise (illegal (subseq argument index)))))))))
      (unless (and paths (rest paths)) (usage))
      (let* ((sources (butlast paths))
             (target-display (car (last paths)))
             (target (if (zerop (length target-display)) ""
                         (%shell-relative-path target-display state)))
             (operands (length paths))
             (stdout (make-string-output-stream))
             (stderr (make-string-output-stream))
             (exit-code 0))
        (dolist (source-display sources)
          (let ((source (if (zerop (length source-display)) ""
                            (%shell-relative-path source-display state))))
            (handler-case
                (let* ((source-stat (clun.sys:stat* source :lstat t))
                       (source-directory (clun.sys:fstat-dir-p source-stat)))
                  (when (and source-directory (not recursive))
                    (%shell-cp-custom-error "~a is a directory (not copied)"
                                            source-display))
                  (multiple-value-bind (target-stat target-present)
                      (%shell-cp-existing-stat target)
                    (let* ((target-directory
                             (and target-present (clun.sys:fstat-dir-p target-stat)))
                           (trailing-separator
                             (and (plusp (length target-display))
                                  (%shell-path-separator-p
                                   (char target-display (1- (length target-display))))))
                           (destination-display nil)
                           (destination nil))
                      (cond
                        (recursive
                         (cond
                           (target-present
                            (setf destination
                                  (clun.sys:path-join target (%shell-basename source-display))
                                  destination-display
                                  (clun.sys:path-join target-display
                                                      (%shell-basename source-display))))
                           ((= operands 2)
                            (setf destination target
                                  destination-display target-display))
                           (t (%shell-cp-custom-error
                               "directory ~a does not exist" target-display))))
                        (target-directory
                         (setf destination
                               (clun.sys:path-join target (%shell-basename source-display))
                               destination-display
                               (clun.sys:path-join target-display
                                                   (%shell-basename source-display))))
                        ((and (= operands 2) (not trailing-separator))
                         (setf destination target destination-display target-display))
                        (t (%shell-cp-custom-error "~a is not a directory"
                                                   target-display)))
                      (when (%shell-cp-same-entry-p source destination)
                        (%shell-cp-custom-error
                         "~a and ~a are identical (not copied)"
                         source-display source-display))
                      (%shell-cp-copy-entry source destination recursive no-overwrite
                                            verbose stdout))))
              (shell-cp-error (condition)
                (format stderr "cp: ~a~%" (shell-cp-error-message condition))
                (setf exit-code 1))
              (clun.sys:fs-error (condition)
                (let* ((path (clun.sys:fs-error-path condition))
                       (display (cond
                                  ((string= path source) source-display)
                                  ((string= path target) target-display)
                                  (t path))))
                  (write-string (%shell-fs-error-string "cp" display condition) stderr)
                  (setf exit-code 1))))))
        (%shell-result-from-strings (get-output-stream-string stdout)
                                    (get-output-stream-string stderr) exit-code)))))

(defun %shell-fill-pattern (array offset length pattern)
  (let ((pattern-length (length pattern)))
    (loop for index below length
          do (setf (aref array (+ offset index))
                   (aref pattern (mod index pattern-length)))))
  length)

(defun %shell-fill-byte-target (target pattern)
  (cond
    ((eng:js-typed-array-p target)
     (multiple-value-bind (array offset length) (eng:ta-octets target)
       (%shell-fill-pattern array offset length pattern)))
    ((eng:js-array-buffer-p target)
     (let ((array (eng:js-array-buffer-bytes target)))
       (%shell-fill-pattern array 0 (length array) pattern)))
    (t nil)))

(defun %shell-redirection-kind-value (redirection)
  (if (shell-prepared-redirection-p redirection)
      (shell-prepared-redirection-kind redirection)
      (shell-redirection-kind redirection)))

(defun %shell-redirection-target-value (redirection state g)
  (if (shell-prepared-redirection-p redirection)
      (shell-prepared-redirection-target redirection)
      (%shell-word-raw-target (shell-redirection-target redirection) state g)))

(defun %shell-bounded-output-target (redirections state g)
  ;; The frozen yes corpus has one direct byte-buffer stdout redirect. Keep the
  ;; eligibility strict until ordered descriptor redirects are generalized.
  (let ((stdout-redirections
          (remove-if-not
           (lambda (redirection)
             (member (%shell-redirection-kind-value redirection)
                     '(:output :output-append :both :both-append)))
           redirections)))
    (when (= (length stdout-redirections) 1)
      (let ((target (%shell-redirection-target-value
                     (first stdout-redirections) state g)))
        (when (or (eng:js-typed-array-p target) (eng:js-array-buffer-p target))
          target)))))

(defun %shell-yes-pattern (arguments)
  (let ((line (if arguments (format nil "~{~a~^ ~}" arguments) "y")))
    (%shell-octets (concatenate 'string line (string #\Newline)))))

(defun %shell-run-yes (arguments target)
  (unless target
    (return-from %shell-run-yes
      (%shell-result-from-strings
       "" (format nil "yes: unbounded output requires a streaming sink~%") 1)))
  (let ((pattern (%shell-yes-pattern arguments)))
    (%shell-fill-byte-target target pattern)
    (make-shell-result)))

(defun %shell-condition-as-operand (term)
  (if (shell-condition-operand-p term)
      term
      (%make-shell-condition-operand
       term (make-array (length term) :element-type 'bit :initial-element 0))))

(defun %shell-condition-operand-text (term)
  (shell-condition-operand-value (%shell-condition-as-operand term)))

(defun %shell-condition-protected-p (term index)
  (= 1 (aref (shell-condition-operand-protected
              (%shell-condition-as-operand term))
             index)))

(defun %shell-condition-operator-p (term operator)
  (let ((operand (%shell-condition-as-operand term)))
    (and (string= (shell-condition-operand-value operand) operator)
         (every #'zerop (shell-condition-operand-protected operand)))))

(defun %shell-condition-operand-slice (term start &optional end)
  (let* ((operand (%shell-condition-as-operand term))
         (value (shell-condition-operand-value operand))
         (end (or end (length value))))
    (%make-shell-condition-operand
     (subseq value start end)
     (subseq (shell-condition-operand-protected operand) start end))))

(defun %shell-condition-literal-operand (value)
  (%make-shell-condition-operand
   value (make-array (length value) :element-type 'bit :initial-element 0)))

(defun %shell-condition-pattern (term)
  (let* ((operand (%shell-condition-as-operand term))
         (value (shell-condition-operand-value operand)))
    (with-output-to-string (output)
      (loop for character across value
            for index from 0
            for protected = (%shell-condition-protected-p operand index)
            do (when (or (and protected (find character "\\*?[]{}!,-^"))
                         (and (zerop index) (char= character #\!)))
                 (write-char #\\ output))
               (write-char character output)))))

(defconstant +shell-condition-max-pattern-length+ 65536)
(defconstant +shell-condition-max-extglob-depth+ 64)

(defun %shell-condition-extglob-start-p (operand index)
  (let ((value (shell-condition-operand-value operand)))
    (and (< (1+ index) (length value))
         (not (%shell-condition-protected-p operand index))
         (not (%shell-condition-protected-p operand (1+ index)))
         (find (char value index) "?*+@")
         (char= (char value (1+ index)) #\())))

(defun %shell-condition-extglob-p (term)
  (let* ((operand (%shell-condition-as-operand term))
         (value (shell-condition-operand-value operand)))
    (loop for index below (length value)
          thereis (%shell-condition-extglob-start-p operand index))))

(defun %shell-condition-extglob-regex (term)
  "Translate positive Bash extglobs used by [[ == ]] to a bounded regex."
  (let* ((operand (%shell-condition-as-operand term))
         (value (shell-condition-operand-value operand))
         (length (length value))
         (index 0))
    (when (> length +shell-condition-max-pattern-length+)
      (error 'shell-condition-evaluation-error
             :message "pattern is too long" :status 2))
    (labels
        ((protected-p (position)
           (%shell-condition-protected-p operand position))
         (literal (character)
           (cl-ppcre:quote-meta-chars (string character)))
         (class-close (open)
           (loop for position from (1+ open) below length
                 when (and (char= (char value position) #\])
                           (not (protected-p position))
                           (> position (1+ open)))
                   return position))
         (parse-class ()
           (let ((close (class-close index)))
             (unless close
               (incf index)
               (return-from parse-class (literal #\[)))
             (prog1
                 (with-output-to-string (output)
                   (write-char #\[ output)
                   (incf index)
                   (when (and (< index close)
                              (not (protected-p index))
                              (char= (char value index) #\!))
                     (write-char #\^ output)
                     (incf index))
                   (loop while (< index close)
                         for character = (char value index)
                         do (when (or (protected-p index)
                                      (find character "\\]"))
                              (write-char #\\ output))
                            (write-char character output)
                            (incf index))
                   (write-char #\] output))
               (setf index (1+ close)))))
         (parse-extglob (depth)
           (when (> depth +shell-condition-max-extglob-depth+)
             (error 'shell-condition-evaluation-error
                    :message "extended glob nesting is too deep" :status 2))
           (let ((operator (char value index))
                 (alternatives '()))
             (incf index 2)
             (loop
               (push (parse-sequence depth) alternatives)
               (cond
                 ((and (< index length)
                       (not (protected-p index))
                       (char= (char value index) #\|))
                  (incf index))
                 ((and (< index length)
                       (not (protected-p index))
                       (char= (char value index) #\)))
                  (incf index)
                  (return))
                 (t
                  (error 'shell-condition-evaluation-error
                         :message "invalid extended glob" :status 2))))
             (format nil "(?:~{~a~^|~})~a"
                     (nreverse alternatives)
                     (case operator
                       (#\? "?")
                       (#\* "*")
                       (#\+ "+")
                       (otherwise "")))))
         (parse-sequence (depth)
           (with-output-to-string (output)
             (loop while (< index length)
                   for character = (char value index)
                   do (cond
                        ((and (not (protected-p index))
                              (find character "|)"))
                         (return))
                        ((%shell-condition-extglob-start-p operand index)
                         (write-string (parse-extglob (1+ depth)) output))
                        ((and (not (protected-p index))
                              (char= character #\*))
                         (write-string "(?s:.)*" output)
                         (incf index))
                        ((and (not (protected-p index))
                              (char= character #\?))
                         (write-string "(?s:.)" output)
                         (incf index))
                        ((and (not (protected-p index))
                              (char= character #\[))
                         (write-string (parse-class) output))
                        (t
                         (write-string (literal character) output)
                         (incf index)))))))
      (let ((regex (parse-sequence 0)))
        (unless (= index length)
          (error 'shell-condition-evaluation-error
                 :message "invalid extended glob" :status 2))
        (format nil "\\A(?:~a)\\z" regex)))))

(defun %shell-condition-pattern-match-p (term candidate)
  (if (%shell-condition-extglob-p term)
      (handler-case
          (not (null (cl-ppcre:scan (%shell-condition-extglob-regex term)
                                    candidate)))
        (cl-ppcre:ppcre-error (condition)
          (declare (ignore condition))
          (error 'shell-condition-evaluation-error
                 :message "invalid extended glob" :status 2)))
      (clun.glob:glob-match-p (%shell-condition-pattern term) candidate)))

(defun %shell-condition-regex (term)
  (let* ((operand (%shell-condition-as-operand term))
         (value (shell-condition-operand-value operand)))
    (with-output-to-string (output)
      (loop for character across value
            for index from 0
            do (write-string
                (if (%shell-condition-protected-p operand index)
                    (cl-ppcre:quote-meta-chars (string character))
                    (string character))
                output)))))

(defconstant +shell-arithmetic-modulus+ #x10000000000000000)
(defconstant +shell-arithmetic-sign-bit+ #x8000000000000000)
(defconstant +shell-arithmetic-max-depth+ 64)
(defconstant +shell-arithmetic-max-length+ 65536)

(defun %shell-arithmetic-wrap (value)
  (let ((unsigned (mod value +shell-arithmetic-modulus+)))
    (if (>= unsigned +shell-arithmetic-sign-bit+)
        (- unsigned +shell-arithmetic-modulus+)
        unsigned)))

(defun %shell-arithmetic-fail ()
  (error 'shell-condition-evaluation-error
         :message "invalid arithmetic expression" :status 1))

(defun %shell-arithmetic-digit-value (character base)
  (let ((value
          (cond
            ((digit-char-p character 10) (digit-char-p character 10))
            ((and (char>= character #\a) (char<= character #\z))
             (+ 10 (- (char-code character) (char-code #\a))))
            ((and (char>= character #\A) (char<= character #\Z))
             (+ (if (<= base 36) 10 36)
                (- (char-code character) (char-code #\A))))
            ((char= character #\@) 62)
            ((char= character #\_) 63)
            (t nil))))
    (and value (< value base) value)))

(defun %shell-arithmetic-based-integer (digits base)
  (when (zerop (length digits)) (%shell-arithmetic-fail))
  (let ((value 0))
    (loop for character across digits
          for digit = (%shell-arithmetic-digit-value character base)
          do (unless digit (%shell-arithmetic-fail))
             (setf value (%shell-arithmetic-wrap (+ (* value base) digit))))
    value))

(defun %shell-arithmetic-power (base exponent)
  (when (minusp exponent) (%shell-arithmetic-fail))
  (let ((result 1) (factor (%shell-arithmetic-wrap base)) (power exponent))
    (loop while (plusp power) do
      (when (oddp power)
        (setf result (%shell-arithmetic-wrap (* result factor))))
      (setf power (ash power -1))
      (when (plusp power)
        (setf factor (%shell-arithmetic-wrap (* factor factor)))))
    result))

(defun %shell-condition-arithmetic (source state &optional (seen '()) (depth 0))
  (when (or (> depth +shell-arithmetic-max-depth+)
            (> (length source) +shell-arithmetic-max-length+))
    (%shell-arithmetic-fail))
  (when (zerop (length source))
    (return-from %shell-condition-arithmetic 0))
  (let ((index 0) (length (length source)))
    (labels
        ((skip-space ()
           (loop while (and (< index length)
                            (find (char source index) '(#\Space #\Tab #\Return #\Newline)))
                 do (incf index)))
         (at (operator)
           (skip-space)
           (and (<= (+ index (length operator)) length)
                (string= operator source :start2 index :end2 (+ index (length operator)))))
         (take (operator)
           (when (at operator)
             (incf index (length operator))
             t))
         (name-start-p (character)
           (or (alpha-char-p character) (char= character #\_)))
         (name-part-p (character)
           (or (alphanumericp character) (char= character #\_)))
         (parse-number ()
           (let ((start index))
             (cond
               ((and (< (+ index 2) length)
                     (char= (char source index) #\0)
                     (find (char source (1+ index)) "xX"))
                (incf index 2)
                (let ((digits-start index))
                  (loop while (and (< index length)
                                   (digit-char-p (char source index) 16))
                        do (incf index))
                  (%shell-arithmetic-based-integer
                   (subseq source digits-start index) 16)))
               (t
                (loop while (and (< index length)
                                 (digit-char-p (char source index) 10))
                      do (incf index))
                (if (and (< index length) (char= (char source index) #\#))
                    (let ((base (parse-integer source :start start :end index)))
                      (unless (<= 2 base 64) (%shell-arithmetic-fail))
                      (incf index)
                      (let ((digits-start index))
                        (loop while (and (< index length)
                                         (or (alphanumericp (char source index))
                                             (find (char source index) "@_")))
                              do (incf index))
                        (%shell-arithmetic-based-integer
                         (subseq source digits-start index) base)))
                    (let* ((digits (subseq source start index))
                           (base (if (and (> (length digits) 1)
                                          (char= (char digits 0) #\0))
                                     8 10)))
                      (%shell-arithmetic-based-integer digits base)))))))
         (parse-name ()
           (let ((start index))
             (loop while (and (< index length)
                              (name-part-p (char source index)))
                   do (incf index))
             (let ((name (subseq source start index)))
               (when (member name seen :test #'string=) (%shell-arithmetic-fail))
               (%shell-condition-arithmetic
                (%shell-env-get (shell-state-env state) name "") state
                (cons name seen) (1+ depth)))))
         (primary ()
           (skip-space)
           (when (>= index length) (%shell-arithmetic-fail))
           (let ((character (char source index)))
             (cond
               ((char= character #\()
                (incf index)
                (let ((value (logical-or)))
                  (unless (take ")") (%shell-arithmetic-fail))
                  value))
               ((digit-char-p character 10) (parse-number))
               ((name-start-p character) (parse-name))
               (t (%shell-arithmetic-fail)))))
         (power ()
           (let ((value (primary)))
             (if (take "**")
                 (%shell-arithmetic-power value (unary))
                 value)))
         (unary ()
           (cond
             ((take "+") (unary))
             ((take "-") (%shell-arithmetic-wrap (- (unary))))
             ((take "!") (if (zerop (unary)) 1 0))
             ((take "~") (%shell-arithmetic-wrap (lognot (unary))))
             (t (power))))
         (multiplicative ()
           (let ((value (unary)))
             (loop
               (cond
                 ((and (at "*") (not (at "**")))
                  (take "*")
                  (setf value (%shell-arithmetic-wrap (* value (unary)))))
                 ((take "/")
                  (let ((right (unary)))
                    (when (zerop right) (%shell-arithmetic-fail))
                    (setf value (%shell-arithmetic-wrap (truncate value right)))))
                 ((take "%")
                  (let ((right (unary)))
                    (when (zerop right) (%shell-arithmetic-fail))
                    (setf value (%shell-arithmetic-wrap (rem value right)))))
                 (t (return value))))))
         (additive ()
           (let ((value (multiplicative)))
             (loop
               (cond
                 ((take "+")
                  (setf value (%shell-arithmetic-wrap (+ value (multiplicative)))))
                 ((take "-")
                  (setf value (%shell-arithmetic-wrap (- value (multiplicative)))))
                 (t (return value))))))
         (shift ()
           (let ((value (additive)))
             (loop
               (cond
                 ((take "<<")
                  (let ((right (additive)))
                    (unless (<= 0 right 63) (%shell-arithmetic-fail))
                    (setf value (%shell-arithmetic-wrap (ash value right)))))
                 ((take ">>")
                  (let ((right (additive)))
                    (unless (<= 0 right 63) (%shell-arithmetic-fail))
                    (setf value (%shell-arithmetic-wrap (ash value (- right))))))
                 (t (return value))))))
         (relational ()
           (let ((value (shift)))
             (loop
               (cond
                 ((take "<=") (setf value (if (<= value (shift)) 1 0)))
                 ((take ">=") (setf value (if (>= value (shift)) 1 0)))
                 ((take "<") (setf value (if (< value (shift)) 1 0)))
                 ((take ">") (setf value (if (> value (shift)) 1 0)))
                 (t (return value))))))
         (equality ()
           (let ((value (relational)))
             (loop
               (cond
                 ((take "==") (setf value (if (= value (relational)) 1 0)))
                 ((take "!=") (setf value (if (/= value (relational)) 1 0)))
                 (t (return value))))))
         (bitwise-and ()
           (let ((value (equality)))
             (loop while (and (at "&") (not (at "&&")))
                   do (take "&")
                      (setf value (%shell-arithmetic-wrap (logand value (equality))))
                   finally (return value))))
         (bitwise-xor ()
           (let ((value (bitwise-and)))
             (loop while (take "^")
                   do (setf value (%shell-arithmetic-wrap
                                  (logxor value (bitwise-and))))
                   finally (return value))))
         (bitwise-or ()
           (let ((value (bitwise-xor)))
             (loop while (and (at "|") (not (at "||")))
                   do (take "|")
                      (setf value (%shell-arithmetic-wrap
                                   (logior value (bitwise-xor))))
                   finally (return value))))
         (logical-and ()
           (let ((value (bitwise-or)))
             (loop while (take "&&")
                   do (let ((right (bitwise-or)))
                        (setf value (if (and (not (zerop value))
                                             (not (zerop right)))
                                        1 0)))
                   finally (return value))))
         (logical-or ()
           (let ((value (logical-and)))
             (loop while (take "||")
                   do (let ((right (logical-and)))
                        (setf value (if (or (not (zerop value))
                                            (not (zerop right)))
                                        1 0)))
                   finally (return value)))))
      (let ((value (logical-or)))
        (skip-space)
        (unless (= index length) (%shell-arithmetic-fail))
        (%shell-arithmetic-wrap value)))))

(defun %shell-condition-stat (path &key lstat)
  (and path (plusp (length path))
       (ignore-errors (clun.sys:stat* path :lstat lstat))))

(defun %shell-condition-path (value state)
  (and (plusp (length value)) (%shell-relative-path value state)))

(defun %shell-condition-unary-p (operator value state)
  (setf value (%shell-condition-operand-text value))
  (let ((path (and (member operator '("-e" "-f" "-d" "-c" "-L")
                           :test #'string=)
                   (%shell-condition-path value state))))
    (cond
      ((string= operator "-n") (plusp (length value)))
      ((string= operator "-z") (zerop (length value)))
      ((string= operator "-e") (not (null (%shell-condition-stat path))))
      ((string= operator "-f")
       (let ((stat (%shell-condition-stat path)))
         (and stat (clun.sys:fstat-file-p stat))))
      ((string= operator "-d")
       (let ((stat (%shell-condition-stat path)))
         (and stat (clun.sys:fstat-dir-p stat))))
      ((string= operator "-c")
       (let ((stat (%shell-condition-stat path)))
         (and stat (= (logand (clun.sys:fstat-mode stat) #o170000) #o020000))))
      ((string= operator "-L")
       (let ((stat (%shell-condition-stat path :lstat t)))
         (and stat (clun.sys:fstat-symlink-p stat))))
      (t nil))))

(defun %shell-condition-binary-p (left operator right state)
  (let ((left-value (%shell-condition-operand-text left))
        (right-value (%shell-condition-operand-text right)))
    (cond
      ((member operator '("=" "==") :test #'string=)
       (%shell-condition-pattern-match-p right left-value))
      ((string= operator "!=")
       (not (%shell-condition-pattern-match-p right left-value)))
      ((string= operator "=~")
       (handler-case
           (not (null (cl-ppcre:scan (%shell-condition-regex right) left-value)))
       (cl-ppcre:ppcre-error (condition)
         (declare (ignore condition))
         (error 'shell-condition-evaluation-error
                :message "invalid regular expression" :status 2))))
      ((string= operator "<") (string< left-value right-value))
      ((string= operator ">") (string> left-value right-value))
      ((string= operator "-ef")
       (let ((left-stat (%shell-condition-stat
                         (%shell-condition-path left-value state)))
             (right-stat (%shell-condition-stat
                          (%shell-condition-path right-value state))))
         (and left-stat right-stat
              (= (clun.sys:fstat-dev left-stat) (clun.sys:fstat-dev right-stat))
              (= (clun.sys:fstat-ino left-stat) (clun.sys:fstat-ino right-stat)))))
      ((member operator '("-eq" "-ne" "-lt" "-le" "-gt" "-ge")
               :test #'string=)
       (let ((left-number (%shell-condition-arithmetic left-value state))
             (right-number (%shell-condition-arithmetic right-value state)))
         (cond
           ((string= operator "-eq") (= left-number right-number))
           ((string= operator "-ne") (/= left-number right-number))
           ((string= operator "-lt") (< left-number right-number))
           ((string= operator "-le") (<= left-number right-number))
           ((string= operator "-gt") (> left-number right-number))
           (t (>= left-number right-number)))))
      (t nil))))

(defun %shell-condition-normalize-parentheses (terms)
  "Split grouping parentheses attached to operands without splitting balanced pattern text."
  (let ((output '()) (depth 0) (binary-rhs nil)
        (binary-operators '("=" "==" "!=" "=~" "<" ">" "-ef"
                            "-eq" "-ne" "-lt" "-le" "-gt" "-ge")))
    (dolist (term terms (nreverse output))
      (let* ((rhs binary-rhs)
             (term (%shell-condition-as-operand term))
             (text (%shell-condition-operand-text term))
             (length (length text))
             (leading (if rhs
                          0
                          (loop for index below length
                                while (and
                                       (not (%shell-condition-protected-p term index))
                                       (char= (char text index) #\())
                                count 1)))
             (body (%shell-condition-operand-slice term leading)))
        (setf binary-rhs nil)
        (dotimes (index leading)
          (declare (ignore index))
          (push (%shell-condition-literal-operand "(") output)
          (incf depth))
        (let ((balance 0) (unmatched 0))
          (loop for character across (%shell-condition-operand-text body)
                for index from 0 do
            (cond
              ((and (not (%shell-condition-protected-p body index))
                    (char= character #\())
               (incf balance))
              ((and (not (%shell-condition-protected-p body index))
                    (char= character #\)))
               (if (plusp balance) (decf balance) (incf unmatched)))))
          (let* ((body-text (%shell-condition-operand-text body))
                 (trailing (loop for index downfrom (1- (length body-text)) to 0
                                 while (and
                                        (not (%shell-condition-protected-p body index))
                                        (char= (char body-text index) #\)))
                                 count 1))
                 (closings (min depth unmatched trailing))
                 (value (%shell-condition-operand-slice
                         body 0 (- (length body-text) closings))))
            (when (or (plusp (length (%shell-condition-operand-text value)))
                      (and (zerop leading) (zerop closings)))
              (push value output))
            (dotimes (index closings)
              (declare (ignore index))
              (push (%shell-condition-literal-operand ")") output)
              (decf depth))))
        (when (some (lambda (operator)
                      (%shell-condition-operator-p term operator))
                    binary-operators)
          (setf binary-rhs t))))))

(defun %shell-condition-p (terms state)
  (let* ((terms (coerce (%shell-condition-normalize-parentheses terms) 'vector))
         (length (length terms))
         (unary-operators '("-n" "-z" "-e" "-f" "-d" "-c" "-L"))
         (binary-operators '("=" "==" "!=" "=~" "<" ">" "-ef"
                             "-eq" "-ne" "-lt" "-le" "-gt" "-ge")))
    (labels ((term (index) (and (< index length) (aref terms index)))
             (operator-p (operand operator)
               (and operand (%shell-condition-operator-p operand operator)))
             (operator-in-p (operand operators)
               (some (lambda (operator) (operator-p operand operator)) operators))
             (invalid (index) (values nil index nil))
             (parse-primary (index evaluate)
               (let ((current (term index)))
                 (cond
                   ((null current) (invalid index))
                   ((operator-p current "(")
                    (multiple-value-bind (value next valid)
                        (parse-or (1+ index) evaluate)
                      (if (and valid (operator-p (term next) ")"))
                          (values value (1+ next) t)
                          (invalid next))))
                   ((operator-p current ")") (invalid index))
                   ((operator-in-p current unary-operators)
                    (let ((operand (term (1+ index))))
                      (if (and operand
                               (not (operator-in-p operand '("&&" "||" ")"))))
                          (values (and evaluate
                                       (%shell-condition-unary-p
                                        (%shell-condition-operand-text current)
                                        operand state))
                                  (+ index 2) t)
                          (invalid index))))
                   ((and (term (1+ index))
                         (operator-in-p (term (1+ index)) binary-operators))
                    (let ((right (term (+ index 2))))
                      (if (and right
                               (not (operator-in-p right '("&&" "||" ")"))))
                          (values (and evaluate
                                       (%shell-condition-binary-p
                                        current
                                        (%shell-condition-operand-text (term (1+ index)))
                                        right state))
                                  (+ index 3) t)
                          (invalid index))))
                   (t (values (and evaluate
                                   (plusp
                                    (length (%shell-condition-operand-text current))))
                              (1+ index) t)))))
             (parse-not (index evaluate)
               (if (operator-p (term index) "!")
                   (multiple-value-bind (value next valid)
                       (parse-not (1+ index) evaluate)
                     (values (and evaluate valid (not value)) next valid))
                   (parse-primary index evaluate)))
             (parse-and (index evaluate)
               (multiple-value-bind (value next valid) (parse-not index evaluate)
                 (loop while (and valid (operator-p (term next) "&&")) do
                   (multiple-value-bind (right after right-valid)
                       (parse-not (1+ next) (and evaluate value))
                     (setf valid right-valid
                           value (and evaluate value right)
                           next after)))
                 (values value next valid)))
             (parse-or (index evaluate)
               (multiple-value-bind (value next valid) (parse-and index evaluate)
                 (loop while (and valid (operator-p (term next) "||")) do
                   (multiple-value-bind (right after right-valid)
                       (parse-and (1+ next) (and evaluate (not value)))
                     (setf valid right-valid
                           value (and evaluate (or value right))
                           next after)))
                 (values value next valid))))
      (multiple-value-bind (value next valid) (parse-or 0 t)
        (values (and valid (= next length) value)
                (and valid (= next length)))))))

(defun %shell-run-condition (arguments state)
  (if (and arguments (%shell-condition-operator-p (car (last arguments)) "]]"))
      (handler-case
          (multiple-value-bind (matches valid)
              (%shell-condition-p (butlast arguments) state)
            (if valid
                (%shell-result-from-strings "" "" (if matches 0 1))
                (%shell-result-from-strings
                 "" (format nil "clun: conditional expression: invalid expression~%") 2)))
        (shell-condition-evaluation-error (condition)
          (%shell-result-from-strings
           "" (format nil "clun: conditional expression: ~a~%"
                      (shell-condition-evaluation-error-message condition))
           (shell-condition-evaluation-error-status condition))))
      (%shell-result-from-strings
       "" (format nil "clun: conditional expression: expected ]]~%") 2)))

(defun %shell-run-builtin (argv state env stdin)
  "Return RESULT and true when ARGV names a builtin."
  (let ((name (first argv)) (args (rest argv)))
    (cond
      ((string= name "echo")
       (let ((newline t))
         (loop while (and args (string= (first args) "-n"))
               do (setf newline nil args (rest args)))
         (values (%shell-result-from-strings (%shell-echo-output args newline) "" 0) t)))
      ((string= name "basename")
       (if args
           (values (%shell-result-from-strings
                    (format nil "~{~a~%~}" (mapcar #'%shell-basename args)) "" 0) t)
           (values (%shell-result-from-strings
                    "" (format nil "usage: basename string~%") 1) t)))
      ((string= name "dirname")
       (if args
           (values (%shell-result-from-strings
                    (format nil "~{~a~%~}" (mapcar #'%shell-dirname args)) "" 0) t)
           (values (%shell-result-from-strings
                    "" (format nil "usage: dirname string~%") 1) t)))
      ((string= name "seq")
       (values (%shell-run-seq args) t))
      ((string= name "cat")
       (values (%shell-run-cat args state stdin) t))
      ((string= name "mkdir")
       (values (%shell-run-mkdir args state) t))
      ((string= name "touch")
       (values (%shell-run-touch args state) t))
      ((string= name "rm")
       (values (%shell-run-rm args state) t))
      ((string= name "mv")
       (values (%shell-run-mv args state) t))
      ((string= name "ls")
       (values (%shell-run-ls args state) t))
      ((string= name "cp")
       (values (%shell-run-cp args state) t))
      ((string= name "yes")
       ;; YES needs its bounded target and is dispatched by
       ;; %SHELL-EXECUTE-COMMAND before the ordinary builtin path.
       (values (%shell-run-yes args nil) t))
      ((string= name "[[")
       (values (%shell-run-condition args state) t))
      ((string= name "pwd")
       (values (if args
                   (%shell-result-from-strings
                    "" (format nil "pwd: too many arguments~%") 1)
                   (%shell-result-from-strings
                    (concatenate 'string (shell-state-cwd state) (string #\Newline)) "" 0))
               t))
      ((string= name "cd")
       (let* ((argument (or (first args) (%shell-env-get env "HOME" "")))
              (destination (if (string= argument "-")
                               (or (shell-state-old-cwd state) (shell-state-cwd state))
                               (%shell-relative-path argument state))))
         (if (ignore-errors (clun.sys:directory-p destination))
             (let ((previous (shell-state-cwd state)))
               (setf (shell-state-old-cwd state) previous
                     (shell-state-cwd state) destination
                     (shell-state-env state)
                     (%shell-env-set (shell-state-env state) "OLDPWD" previous)
                     (shell-state-env state)
                     (%shell-env-set (shell-state-env state) "PWD" destination))
               (values (%shell-result-from-strings
                        (if (string= argument "-")
                            (concatenate 'string destination (string #\Newline)) "")
                        "" 0) t))
             (values (%shell-result-from-strings
                      "" (format nil "clun: cd: ~a: No such directory~%" argument) 1) t))))
      ((or (string= name "true") (string= name ":"))
       (values (%shell-result-from-strings "" "" 0) t))
      ((string= name "false")
       (values (%shell-result-from-strings "" "" 1) t))
      ((string= name "export")
       (dolist (argument args)
         (let ((equals (position #\= argument)))
           (if equals
               (let ((key (subseq argument 0 equals)))
                 (when (%shell-valid-name-p key)
                   (setf (shell-state-env state)
                         (%shell-env-set (shell-state-env state) key
                                         (subseq argument (1+ equals))))))
               (unless (%shell-valid-name-p argument)
                 (return-from %shell-run-builtin
                   (values (%shell-result-from-strings
                            "" (format nil "clun: export: invalid name: ~a~%" argument) 1) t))))))
       (values (%shell-result-from-strings "" "" 0) t))
      ((string= name "unset")
       (dolist (argument args)
         (when (%shell-valid-name-p argument)
           (setf (shell-state-env state)
                 (%shell-env-unset (shell-state-env state) argument))))
       (values (%shell-result-from-strings "" "" 0) t))
      ((string= name "shopt")
       (if (and (= (length args) 2)
                (string= (first args) "-s")
                (string= (second args) "extglob"))
           (values (%shell-result-from-strings "" "" 0) t)
           (values (%shell-result-from-strings
                    "" (format nil "clun: shopt: unsupported option~%") 1) t)))
      ((string= name "which")
       (let ((found (loop for argument in args
                          for path = (%shell-which argument env (shell-state-cwd state))
                          when path collect path)))
         (values (%shell-result-from-strings
                  (if found (format nil "~{~a~%~}" found) "") ""
                  (if (= (length found) (length args)) 0 1)) t)))
      ((string= name "exit")
       (setf (shell-state-terminated state) t)
       (cond
         ((> (length args) 1)
          (values (%shell-result-from-strings
                   "" (format nil "exit: too many arguments~%") 1) t))
         ((null args)
          (values (%shell-result-from-strings "" "" 0) t))
         (t
          (let ((code (%shell-parse-exit-code (first args))))
            (if code
                (values (%shell-result-from-strings "" "" code) t)
                (values (%shell-result-from-strings
                         "" (format nil "exit: numeric argument required~%") 1) t))))))
      (t (values nil nil)))))

(defun %shell-temp-directory ()
  (clun.sys:make-temp-dir
   (clun.sys:path-join (clun.sys:tmpdir) "clun-shell-")))

(defun %shell-run-external (argv env cwd stdin)
  (let ((directory (%shell-temp-directory))
        (program (%shell-which (first argv) env cwd)))
    (unwind-protect
         (if (null program)
             (%shell-result-from-strings
              "" (format nil "clun: command not found: ~a~%" (first argv)) 127)
             (let* ((input-path (when (plusp (length stdin))
                              (clun.sys:path-join directory "stdin")))
                (output-path (clun.sys:path-join directory "stdout"))
                (error-path (clun.sys:path-join directory "stderr")))
           (when input-path (clun.sys:write-file-octets input-path stdin))
           (handler-case
               (let* ((process
                        (sb-ext:run-program
                         program (rest argv) :search nil :wait t
                         :input input-path :output output-path :error error-path
                         :if-output-exists :supersede :if-error-exists :supersede
                         :directory cwd :environment (%shell-env-vector env)))
                      (status (sb-ext:process-status process))
                      (code (or (sb-ext:process-exit-code process) 1)))
                 (make-shell-result
                  :stdout (if (clun.sys:path-exists-p output-path)
                              (clun.sys:read-file-octets output-path)
                              *shell-empty-octets*)
                  :stderr (if (clun.sys:path-exists-p error-path)
                              (clun.sys:read-file-octets error-path)
                              *shell-empty-octets*)
                  :exit-code (if (eq status :signaled) (+ 128 code) code)))
             (error ()
               (%shell-result-from-strings
                "" (format nil "clun: failed to execute: ~a~%" (first argv)) 126)))))
      (ignore-errors (clun.sys:remove-recursive directory)))))

(defun %shell-target-path (target state)
  (cond
    ((stringp target) (%shell-relative-path target state))
    ((eng:js-object-p target)
     (let ((name (eng:js-get target "name")))
       (unless (stringp name)
         (eng:throw-type-error "Clun.$ redirection target is not a path or byte buffer"))
       (%shell-relative-path name state)))
    (t nil)))

(defun %shell-read-target (target state)
  (cond
    ((eng:js-typed-array-p target)
     (multiple-value-bind (array offset length) (eng:ta-octets target)
       (subseq array offset (+ offset length))))
    ((eng:js-array-buffer-p target)
     (copy-seq (eng:js-array-buffer-bytes target)))
    ((js-blob-p target) (%blob-octets-copy target))
    ((js-response-p target) (%response-body-vector target))
    (t (clun.sys:read-file-octets (%shell-target-path target state)))))

(defun %shell-write-target (target state octets append)
  (cond
    ((eng:js-typed-array-p target)
     (multiple-value-bind (array offset length) (eng:ta-octets target)
       (let ((count (min length (length octets))))
         (replace array octets :start1 offset :end1 (+ offset count) :end2 count)
         count)))
    ((eng:js-array-buffer-p target)
     (let* ((array (eng:js-array-buffer-bytes target))
            (count (min (length array) (length octets))))
       (replace array octets :end1 count :end2 count) count))
    (t (clun.sys:write-file-octets (%shell-target-path target state) octets
                                   :append append))))

(defun %shell-prepare-output-redirection (redirection state g)
  (let ((kind (shell-redirection-kind redirection)))
    (if (member kind '(:output :output-append :error :error-append
                       :both :both-append))
        (let* ((target (%shell-word-raw-target
                        (shell-redirection-target redirection) state g))
               (append (member kind '(:output-append :error-append :both-append))))
          ;; Open output paths before executing the command. A failed redirect
          ;; must suppress command side effects and become a shell status.
          (%shell-write-target target state *shell-empty-octets* append)
          (make-shell-prepared-redirection :kind kind :target target))
        (make-shell-prepared-redirection :kind kind))))

(defun %shell-command-redirections (command state g stdin)
  "Apply input redirections and return stdin plus the ordered output redirections."
  (let ((input stdin) (output-redirections '()))
    (dolist (redirection (shell-command-redirections command))
      (if (eq (shell-redirection-kind redirection) :input)
          (setf input (%shell-read-target
                       (%shell-word-raw-target (shell-redirection-target redirection)
                                               state g)
                       state))
          (push (%shell-prepare-output-redirection redirection state g)
                output-redirections)))
    (values input (nreverse output-redirections))))

(defun %shell-apply-output-redirections (result redirections state g)
  (let* ((captured-output (make-shell-output-sink :kind :output))
         (captured-error (make-shell-output-sink :kind :error))
         (output-sink captured-output)
         (error-sink captured-error)
         (emissions '()))
    (labels ((target-sink (redirection append)
               (let ((target (%shell-redirection-target-value redirection state g)))
                 ;; Direct callers may still supply parser redirections. Command
                 ;; execution supplies pre-opened bindings so failures happen
                 ;; before the command and paths are not truncated twice.
                 (unless (shell-prepared-redirection-p redirection)
                   (%shell-write-target target state *shell-empty-octets* append))
                 (make-shell-output-sink :kind :target :target target)))
             (emit (sink octets)
               (let ((entry (assoc sink emissions :test #'eq)))
                 (if entry
                     (setf (cdr entry)
                           (%shell-concat-octets (cdr entry) octets))
                     (push (cons sink octets) emissions)))))
      (dolist (redirection redirections)
        (let ((kind (%shell-redirection-kind-value redirection)))
          (case kind
            ((:output :output-append)
             (setf output-sink
                   (target-sink redirection (eq kind :output-append))))
            ((:error :error-append)
             (setf error-sink
                   (target-sink redirection (eq kind :error-append))))
            ((:both :both-append)
             (let ((sink (target-sink redirection (eq kind :both-append))))
               (setf output-sink sink error-sink sink)))
            (:error-to-output
             ;; Descriptor duplication snapshots the destination at this point;
             ;; a later stdout redirect must not move stderr with it.
             (setf error-sink output-sink))
            (:output-to-error
             (setf output-sink error-sink)))))
      (emit output-sink (shell-result-stdout result))
      (emit error-sink (shell-result-stderr result))
      (let ((stdout *shell-empty-octets*)
            (stderr *shell-empty-octets*))
        (dolist (entry (nreverse emissions))
          (let ((sink (car entry)) (octets (cdr entry)))
            (case (shell-output-sink-kind sink)
              (:output (setf stdout octets))
              (:error (setf stderr octets))
              (:target
               ;; The target was already opened with its requested truncation
               ;; policy. Append here so delivery cannot truncate it a second time.
               (%shell-write-target
                (shell-output-sink-target sink) state octets t)))))
        (make-shell-result :stdout stdout :stderr stderr
                           :exit-code (shell-result-exit-code result))))))

(defun %shell-condition-fragment-string (fragment state g)
  (case (shell-fragment-kind fragment)
    (:literal (shell-fragment-value fragment))
    (:interpolation
     (format nil "~{~a~^ ~}"
             (%shell-flatten-interpolation (shell-fragment-value fragment))))
    (:variable
     (%shell-env-get (shell-state-env state) (shell-fragment-value fragment) ""))
    (:status (princ-to-string (shell-state-last-exit-code state)))
    (:substitution
     (let* ((sub-state (copy-shell-state state))
            (result (%shell-execute-units
                     (shell-fragment-value fragment) sub-state g)))
       (setf (shell-state-last-exit-code state)
             (shell-result-exit-code result))
       (%shell-trim-command-output (%shell-string (shell-result-stdout result)))))
    (otherwise "")))

(defun %shell-condition-word-operand (word state g)
  (let ((output (make-string-output-stream))
        (protected (make-array 16 :element-type 'bit
                                 :adjustable t :fill-pointer 0)))
    (dolist (fragment (shell-word-fragments word))
      (let* ((value (%shell-condition-fragment-string fragment state g))
             (protect (or (eq (shell-fragment-kind fragment) :interpolation)
                          (shell-fragment-quoted fragment))))
        (write-string value output)
        (dotimes (index (length value))
          (declare (ignore index))
          (vector-push-extend (if protect 1 0) protected))))
    (%make-shell-condition-operand
     (get-output-stream-string output) (copy-seq protected))))

(defun %shell-condition-word-value (word state g)
  (%shell-condition-operand-text (%shell-condition-word-operand word state g)))

(defun %shell-condition-command-p (command)
  (let* ((word (first (shell-command-words command)))
         (fragments (and word (shell-word-fragments word))))
    (and (= (length fragments) 1)
         (eq (shell-fragment-kind (first fragments)) :literal)
         (not (shell-fragment-quoted (first fragments)))
         (string= (shell-fragment-value (first fragments)) "[["))))

(defun %shell-command-argv (command state g)
  (if (%shell-condition-command-p command)
      (mapcar (lambda (word) (%shell-condition-word-value word state g))
              (shell-command-words command))
      (mapcan (lambda (word) (%shell-word-values word state g))
              (shell-command-words command))))

(defun %shell-append-results (left right &optional exit-code)
  (make-shell-result
   :stdout (%shell-concat-octets (shell-result-stdout left)
                                  (shell-result-stdout right))
   :stderr (%shell-concat-octets (shell-result-stderr left)
                                  (shell-result-stderr right))
   :exit-code (or exit-code (shell-result-exit-code right))))

(defun %shell-execute-if-form (form state g stdin)
  (let ((result (make-shell-result)) (pending-input stdin))
    (dolist (branch (shell-if-form-branches form))
      (let ((condition-result
              (%shell-execute-script
               (shell-if-branch-condition branch) state g pending-input)))
        (setf pending-input *shell-empty-octets*
              result (%shell-append-results result condition-result))
        (when (shell-state-terminated state)
          (return-from %shell-execute-if-form result))
        (when (zerop (shell-result-exit-code condition-result))
          (let ((body-result
                  (%shell-execute-script (shell-if-branch-body branch) state g)))
            (return-from %shell-execute-if-form
              (%shell-append-results result body-result))))))
    (if (shell-if-form-alternative form)
        (%shell-append-results
         result (%shell-execute-script (shell-if-form-alternative form) state g))
        (make-shell-result :stdout (shell-result-stdout result)
                           :stderr (shell-result-stderr result)
                           :exit-code 0))))

(defun %shell-execute-command-core (command state g stdin)
  (let ((env (%shell-env-copy (shell-state-env state))))
    (dolist (assignment (shell-command-assignments command))
      (setf env (%shell-env-set env (car assignment)
                                (%shell-assignment-value (cdr assignment) state g))))
    (cond
      ((shell-command-if-form command)
       (multiple-value-bind (input output-redirections)
           (%shell-command-redirections command state g stdin)
         (%shell-apply-output-redirections
          (%shell-execute-if-form (shell-command-if-form command) state g input)
          output-redirections state g)))
      ((shell-command-group command)
       (multiple-value-bind (input output-redirections)
           (%shell-command-redirections command state g stdin)
         (let ((sub-state (copy-shell-state state)))
           (setf (shell-state-env sub-state) (%shell-env-copy env)
                 (shell-state-terminated sub-state) nil)
           (%shell-apply-output-redirections
            (%shell-execute-script (shell-command-group command) sub-state g input)
            output-redirections state g))))
      ((null (shell-command-words command))
        (progn
          (setf (shell-state-env state) env)
          ;; Bun treats an assignment-only pipeline stage as an environment
          ;; boundary that forwards the pipe unchanged. Outside a pipeline the
          ;; input is empty, so a plain assignment remains silent.
          (make-shell-result :stdout stdin)))
      (t
       (let* ((condition-p (%shell-condition-command-p command))
              (condition-arguments
                (when condition-p
                  (mapcar (lambda (word)
                            (%shell-condition-word-operand word state g))
                          (rest (shell-command-words command)))))
              (argv (if condition-p
                        (cons "[[" (mapcar #'%shell-condition-operand-text
                                            condition-arguments))
                        (%shell-command-argv command state g))))
         (if (null argv)
             (make-shell-result :exit-code (shell-state-last-exit-code state))
             (multiple-value-bind (input output-redirections)
                 (%shell-command-redirections command state g stdin)
               (multiple-value-bind (builtin handled)
                   (cond
                     (condition-p
                      (values (%shell-run-condition condition-arguments state) t))
                     ((string= (first argv) "yes")
                      (values
                       (%shell-run-yes
                        (rest argv)
                        (%shell-bounded-output-target
                         output-redirections state g))
                       t))
                     (t (%shell-run-builtin argv state env input)))
                 (%shell-apply-output-redirections
                  (if handled builtin
                      (%shell-run-external argv env (shell-state-cwd state) input))
                  output-redirections state g)))))))))

(defun %shell-redirection-error-result (condition)
  (%shell-result-from-strings
   ""
   (format nil "clun: redirection: ~a: ~a~%"
           (%shell-coreutils-message (clun.sys:fs-error-code condition))
           (clun.sys:fs-error-path condition))
   1))

(defun %shell-execute-command (command state g stdin)
  (let ((result
          (handler-case (%shell-execute-command-core command state g stdin)
            (clun.sys:fs-error (condition)
              (%shell-redirection-error-result condition)))))
    (if (shell-command-negated command)
        (make-shell-result
         :stdout (shell-result-stdout result)
         :stderr (shell-result-stderr result)
         :exit-code (if (zerop (shell-result-exit-code result)) 1 0))
        result)))

(defun %shell-static-command-name (command)
  (let* ((word (and command (first (shell-command-words command))))
         (fragments (and word (shell-word-fragments word))))
    (and (= (length fragments) 1)
         (eq (shell-fragment-kind (first fragments)) :literal)
         (shell-fragment-value (first fragments)))))

(defun %shell-static-builtin-p (command)
  (let ((name (%shell-static-command-name command)))
    (and name (member name *shell-builtins* :test #'string=))))

(defun %shell-concurrent-pipeline-p (pipeline)
  (let ((commands (shell-pipeline-commands pipeline)))
    (and (> (length commands) 1)
         (every (lambda (command)
                  (and (shell-command-words command)
                       (not (shell-command-negated command))
                       (null (shell-command-redirections command))
                       (not (%shell-static-builtin-p command))))
                commands))))

(defun %shell-yes-pipeline-p (pipeline)
  (let ((commands (shell-pipeline-commands pipeline)))
    (and (> (length commands) 1)
         (string= (or (%shell-static-command-name (first commands)) "") "yes")
         (not (shell-command-negated (first commands)))
         (null (shell-command-redirections (first commands)))
         (every (lambda (command)
                  (and (shell-command-words command)
                       (not (shell-command-negated command))
                       (null (shell-command-redirections command))
                       (not (%shell-static-builtin-p command))))
                (rest commands)))))

(defun %shell-prepare-external (command state g)
  (let ((env (%shell-env-copy (shell-state-env state))))
    (dolist (assignment (shell-command-assignments command))
      (setf env (%shell-env-set env (car assignment)
                                (%shell-assignment-value (cdr assignment) state g))))
    (values (mapcan (lambda (word) (%shell-word-values word state g))
                    (shell-command-words command))
            env)))

(defun %shell-kill-processes (processes)
  (dolist (process processes)
    (when (member (sb-ext:process-status process) '(:running :stopped))
      (ignore-errors (sb-ext:process-kill process 9 :pid)))
    (ignore-errors (sb-ext:process-wait process))
    (ignore-errors (sb-ext:process-close process))))

(defun %shell-stream-yes-pattern (stream pattern)
  "Write a fixed-size repeated pattern until the consumer closes its pipe."
  (let* ((fd (clun.sys:stream-fd stream))
         (block (make-array 65536 :element-type '(unsigned-byte 8))))
    (unless fd (error "yes pipeline input is not an fd stream"))
    (%shell-fill-pattern block 0 (length block) pattern)
    (loop with offset = 0
          for written = (%write-fd fd block offset)
          do (cond
               ((and (integerp written) (plusp written))
                (if (= written (- (length block) offset))
                    (setf offset 0)
                    (incf offset written)))
               ((eq written :again) (sleep 0.001))
               (t (return))))))

(defun %shell-execute-yes-pipeline (pipeline state g)
  "Stream the internal YES producer into an otherwise external pipeline."
  (let ((directory (%shell-temp-directory)) (processes '())
        (previous nil) (producer nil))
    (unwind-protect
         (let ((stdout-path (clun.sys:path-join directory "stdout"))
               (stderr-path (clun.sys:path-join directory "stderr"))
               (commands (shell-pipeline-commands pipeline)))
           (clun.sys:write-file-octets stderr-path *shell-empty-octets*)
           (handler-case
               (multiple-value-bind (yes-argv yes-env)
                   (%shell-prepare-external (first commands) state g)
                 (declare (ignore yes-env))
                 (unless (and yes-argv (string= (first yes-argv) "yes"))
                   (%shell-syntax "yes pipeline command expanded unexpectedly"))
                 (loop for command in (rest commands)
                       for index from 0
                       for last = (= index (- (length commands) 2))
                       do (multiple-value-bind (argv env)
                              (%shell-prepare-external command state g)
                            (when (null argv)
                              (%shell-syntax "pipeline command expanded to no arguments"))
                            (let* ((program (%shell-which (first argv) env
                                                         (shell-state-cwd state)))
                                   (input (or previous :stream))
                                   (process
                                     (progn
                                       (unless program
                                         (error "command not found: ~a" (first argv)))
                                       (sb-ext:run-program
                                        program (rest argv) :search nil :wait nil
                                        :input input
                                        :output (if last stdout-path :stream)
                                        :error stderr-path
                                        :if-output-exists :supersede
                                        :if-error-exists :append
                                        :directory (shell-state-cwd state)
                                        :environment (%shell-env-vector env)))))
                              (push process processes)
                              (unless producer
                                (setf producer (sb-ext:process-input process)))
                              (when previous (ignore-errors (close previous)))
                              (setf previous
                                    (unless last (sb-ext:process-output process))))))
                 (%shell-stream-yes-pattern producer (%shell-yes-pattern (rest yes-argv)))
                 (ignore-errors (close producer))
                 (setf producer nil processes (nreverse processes))
                 (dolist (process processes) (sb-ext:process-wait process))
                 (let* ((last (car (last processes)))
                        (status (sb-ext:process-status last))
                        (raw-code (or (sb-ext:process-exit-code last) 1)))
                   (make-shell-result
                    :stdout (if (clun.sys:path-exists-p stdout-path)
                                (clun.sys:read-file-octets stdout-path)
                                *shell-empty-octets*)
                    :stderr (if (clun.sys:path-exists-p stderr-path)
                                (clun.sys:read-file-octets stderr-path)
                                *shell-empty-octets*)
                    :exit-code (if (eq status :signaled) (+ 128 raw-code) raw-code))))
             (error (condition)
               (%shell-kill-processes processes)
               (%shell-result-from-strings
                "" (format nil "clun: pipeline failed: ~a~%" condition) 127))))
      (when producer (ignore-errors (close producer)))
      (when previous (ignore-errors (close previous)))
      (dolist (process processes) (ignore-errors (sb-ext:process-close process)))
      (ignore-errors (clun.sys:remove-recursive directory)))))

(defun %shell-execute-concurrent-pipeline (pipeline state g)
  "Spawn an external-only pipeline at once and connect adjacent process streams.
The final stdout and every stderr are file-backed, so no undrained parent pipe can
deadlock even when commands produce output larger than kernel pipe capacity."
  (let ((directory (%shell-temp-directory)) (processes '()) (previous nil))
    (unwind-protect
         (let ((stdout-path (clun.sys:path-join directory "stdout"))
               (stderr-path (clun.sys:path-join directory "stderr"))
               (commands (shell-pipeline-commands pipeline)))
           (clun.sys:write-file-octets stderr-path *shell-empty-octets*)
           (handler-case
               (progn
                 (loop for command in commands
                       for index from 0
                       for last = (= index (1- (length commands)))
                       do (multiple-value-bind (argv env)
                              (%shell-prepare-external command state g)
                            (when (null argv)
                              (%shell-syntax "pipeline command expanded to no arguments"))
                            (let* ((program (%shell-which (first argv) env
                                                         (shell-state-cwd state)))
                                   (input previous)
                                   (process
                                     (progn
                                       (unless program
                                         (error "command not found: ~a" (first argv)))
                                       (sb-ext:run-program
                                      program (rest argv) :search nil :wait nil
                                      :input input
                                      :output (if last stdout-path :stream)
                                      :error stderr-path
                                      :if-output-exists :supersede
                                      :if-error-exists :append
                                      :directory (shell-state-cwd state)
                                      :environment (%shell-env-vector env)))))
                              (push process processes)
                              (when previous (ignore-errors (close previous)))
                              (setf previous (unless last (sb-ext:process-output process))))))
                 (setf processes (nreverse processes))
                 (dolist (process processes) (sb-ext:process-wait process))
                 (let* ((last (car (last processes)))
                        (status (sb-ext:process-status last))
                        (raw-code (or (sb-ext:process-exit-code last) 1)))
                   (make-shell-result
                    :stdout (if (clun.sys:path-exists-p stdout-path)
                                (clun.sys:read-file-octets stdout-path)
                                *shell-empty-octets*)
                    :stderr (if (clun.sys:path-exists-p stderr-path)
                                (clun.sys:read-file-octets stderr-path)
                                *shell-empty-octets*)
                    :exit-code (if (eq status :signaled) (+ 128 raw-code) raw-code))))
             (error (condition)
               (%shell-kill-processes processes)
               (%shell-result-from-strings
                "" (format nil "clun: pipeline failed: ~a~%" condition) 127))))
      (when previous (ignore-errors (close previous)))
      (dolist (process processes) (ignore-errors (sb-ext:process-close process)))
      (ignore-errors (clun.sys:remove-recursive directory)))))

(defparameter *shell-no-stdin-builtins*
  '("echo" "pwd" "cd" "true" "false" ":" "export" "unset" "shopt" "which" "exit"
    "basename" "dirname" "seq" "mkdir" "touch" "rm" "mv" "ls" "cp" "[["))

(defun %shell-no-stdin-builtin-p (command)
  (let ((name (%shell-static-command-name command)))
    (and name (member name *shell-no-stdin-builtins* :test #'string=))))

(defun %shell-discarded-yes-producer-p (commands command)
  ;; A downstream builtin that never reads stdin closes the conceptual pipe
  ;; immediately. Do not materialize or reject the infinite producer.
  (and (eq command (first commands))
       (rest commands)
       (string= (or (%shell-static-command-name command) "") "yes")
       (null (shell-command-redirections command))
       (%shell-no-stdin-builtin-p (second commands))))

(defun %shell-execute-sequential-pipeline (pipeline state g
                                           &optional (initial-input *shell-empty-octets*))
  (let* ((commands (shell-pipeline-commands pipeline))
         (isolated (> (length commands) 1))
         (input initial-input) (stderr *shell-empty-octets*)
         (result (make-shell-result)))
    (dolist (command commands)
      (let ((command-state (if isolated (copy-shell-state state) state)))
        (when isolated
          (setf (shell-state-env command-state)
                (%shell-env-copy (shell-state-env state))))
        (setf result
              (if (%shell-discarded-yes-producer-p commands command)
                  (make-shell-result)
                  (%shell-execute-command command command-state g input))
              input (shell-result-stdout result)
              stderr (%shell-concat-octets stderr
                                            (shell-result-stderr result)))))
    (make-shell-result :stdout (shell-result-stdout result) :stderr stderr
                       :exit-code (shell-result-exit-code result))))

(defun %shell-execute-pipeline (pipeline state g
                                &optional (initial-input *shell-empty-octets*))
  (cond
    ((plusp (length initial-input))
     (%shell-execute-sequential-pipeline pipeline state g initial-input))
    ((%shell-yes-pipeline-p pipeline)
     (%shell-execute-yes-pipeline pipeline state g))
    ((%shell-concurrent-pipeline-p pipeline)
     (%shell-execute-concurrent-pipeline pipeline state g))
    (t (%shell-execute-sequential-pipeline pipeline state g))))

(defun %shell-execute-script (script state g
                              &optional (initial-input *shell-empty-octets*))
  (let ((stdout *shell-empty-octets*) (stderr *shell-empty-octets*)
        (previous (make-shell-result)) (index 0) (pending-input initial-input))
    (dolist (pipeline (shell-script-pipelines script))
      (when (shell-state-terminated state) (return))
      (let ((operator (and (plusp index)
                           (nth (1- index) (shell-script-operators script)))))
        (when (or (zerop index)
                  (eq operator :sequence)
                  (and (eq operator :and) (zerop (shell-result-exit-code previous)))
                  (and (eq operator :or) (not (zerop (shell-result-exit-code previous)))))
          (setf previous (%shell-execute-pipeline pipeline state g pending-input)
                pending-input *shell-empty-octets*)
          (setf stdout (%shell-concat-octets stdout (shell-result-stdout previous))
                stderr (%shell-concat-octets stderr (shell-result-stderr previous))
                (shell-state-last-exit-code state) (shell-result-exit-code previous))))
      (incf index))
    (make-shell-result :stdout stdout :stderr stderr
                       :exit-code (shell-result-exit-code previous))))

(defun %shell-execute-units (units state &optional (g (eng:realm-global eng:*realm*)))
  (%shell-execute-script (%shell-parse units) state g))

(defun execute-shell-script (source &key (cwd (clun.sys:current-directory))
                                         (env (clun.sys:environ-alist)))
  "Execute SOURCE with Clun's shell engine and return stdout, stderr, and status values."
  (unless (stringp source)
    (error 'type-error :datum source :expected-type 'string))
  (let* ((state (make-shell-state :cwd cwd :env (%shell-env-copy env)))
         (result (%shell-execute-units (coerce source 'vector) state nil)))
    (values (copy-seq (shell-result-stdout result))
            (copy-seq (shell-result-stderr result))
            (shell-result-exit-code result))))

;;; --- JavaScript API --------------------------------------------------------

(defun %shell-object-env (g value)
  (if (eng:js-undefined-p value)
      (clun.sys:environ-alist)
      (progn
        (unless (eng:js-object-p value)
          (eng:throw-type-error "Clun.$.env expects an object or undefined"))
        (let* ((object (eng:js-get g "Object"))
               (keys (eng:js-call (eng:js-get object "keys") object (list value)))
               (env '()))
          (loop for index below (eng:array-length keys)
                for key = (eng:to-string (eng:js-getv keys (princ-to-string index)))
                for entry = (eng:js-get value key)
                unless (eng:js-undefined-p entry)
                  do (push (cons key (eng:to-string entry)) env))
          (nreverse env)))))

(defun %shell-output-methods (object g stdout)
  (eng:install-method object "text" 0
    (lambda (this args) (declare (ignore this args)) (%shell-string stdout)))
  (eng:install-method object "json" 0
    (lambda (this args) (declare (ignore this args))
      (let ((json (eng:js-get g "JSON")))
        (eng:js-call (eng:js-get json "parse") json (list (%shell-string stdout))))))
  (eng:install-method object "bytes" 0
    (lambda (this args) (declare (ignore this args))
      (eng:u8-from-octets (copy-seq stdout))))
  (eng:install-method object "arrayBuffer" 0
    (lambda (this args) (declare (ignore this args))
      (eng:js-get (eng:u8-from-octets (copy-seq stdout)) "buffer")))
  (eng:install-method object "blob" 0
    (lambda (this args) (declare (ignore this args))
      (%new-blob-from-octets stdout)))
  object)

(defun %shell-output-object (result g)
  (let ((object (eng:new-object))
        (stdout (shell-result-stdout result))
        (stderr (shell-result-stderr result)))
    (eng:data-prop object "stdout" (eng:u8-from-octets (copy-seq stdout)))
    (eng:data-prop object "stderr" (eng:u8-from-octets (copy-seq stderr)))
    (eng:data-prop object "exitCode" (coerce (shell-result-exit-code result) 'double-float))
    (%shell-output-methods object g stdout)))

(defun %shell-error-object (result g)
  (let* ((clun (eng:js-get g "Clun"))
         (tag (eng:js-get clun "$"))
         (constructor (eng:js-get tag "ShellError"))
         (error (eng:js-construct
                 constructor
                 (list (format nil "Failed with exit code ~d"
                               (shell-result-exit-code result)))))
        (stdout (shell-result-stdout result))
        (stderr (shell-result-stderr result)))
    (eng:data-prop error "stdout" (eng:u8-from-octets (copy-seq stdout)))
    (eng:data-prop error "stderr" (eng:u8-from-octets (copy-seq stderr)))
    (eng:data-prop error "exitCode" (coerce (shell-result-exit-code result) 'double-float))
    (%shell-output-methods error g stdout)))

(defun %shell-js-error (g control &rest arguments)
  (eng:js-construct (eng:js-get g "Error")
                    (list (apply #'format nil control arguments))))

(defun %shell-job-start (job)
  (unless (shell-job-started job)
    (setf (shell-job-started job) t)
    (handler-case
        (let ((result (%shell-execute-units (shell-job-units job)
                                            (shell-job-state job)
                                            (shell-job-g job))))
          (setf (shell-job-result job) result)
          (unless (shell-state-quiet (shell-job-state job))
            (when (plusp (length (shell-result-stdout result)))
              (write-string (%shell-string (shell-result-stdout result)) *standard-output*)
              (finish-output *standard-output*))
            (when (plusp (length (shell-result-stderr result)))
              (write-string (%shell-string (shell-result-stderr result)) *error-output*)
              (finish-output *error-output*)))
          (when (and (shell-state-throws (shell-job-state job))
                     (not (zerop (shell-result-exit-code result))))
            (setf (shell-job-error job)
                  (%shell-error-object result (shell-job-g job)))))
      (shell-syntax-error (condition)
        (setf (shell-job-error job)
              (%shell-js-error (shell-job-g job) "Clun.$: ~a"
                               (shell-syntax-error-message condition))))
      (clun.sys:fs-error (condition)
        (setf (shell-job-error job)
              (%fs-error->js (shell-job-g job) condition)))
      (eng:js-condition (condition)
        (setf (shell-job-error job) (eng:js-condition-value condition)))
      (error (condition)
        (setf (shell-job-error job)
              (%shell-js-error (shell-job-g job) "Clun.$: ~a" condition)))))
  job)

(defun %shell-job-value (job)
  (%shell-job-start job)
  (unless (shell-job-error job)
    (%shell-output-object (shell-job-result job) (shell-job-g job))))

(defun %shell-job-promise (job transform)
  (let ((g (shell-job-g job)))
    (eng:js-construct
     (eng:js-get g "Promise")
     (list
      (eng:make-native-function
       "" 2
       (lambda (this args)
         (declare (ignore this))
         (%shell-job-start job)
         (if (shell-job-error job)
             (eng:js-call (eng:arg args 1) eng:+undefined+
                          (list (shell-job-error job)))
             (eng:js-call (eng:arg args 0) eng:+undefined+
                          (list (funcall transform (shell-job-result job)))))
         eng:+undefined+))))))

(defun %shell-job-output-promise (job)
  (%shell-job-promise
   job (lambda (result)
         (%shell-output-object result (shell-job-g job)))))

(defun %shell-lines (text)
  (when (plusp (length text))
    (let ((lines '()) (start 0))
      (loop for newline = (position #\Newline text :start start)
            do (if newline
                   (progn
                     (push (subseq text start newline) lines)
                     (setf start (1+ newline)))
                   (progn
                     ;; String.split("\n") preserves the final empty field.
                     (push (subseq text start) lines)
                     (return))))
      (nreverse lines))))

(defun %shell-iterator-result (value done)
  (let ((result (eng:new-object)))
    (eng:data-prop result "value" value)
    (eng:data-prop result "done" (eng:js-boolean done))
    result))

(defun %shell-lines-iterator (job)
  "Create the lazy async iterator returned by ShellPromise.lines()."
  (let ((iterator (eng:new-object))
        (lines nil)
        (index 0)
        (initialized nil)
        (done nil)
        (g (shell-job-g job)))
    (labels ((promise (settler)
               (eng:js-construct
                (eng:js-get g "Promise")
                (list
                 (eng:make-native-function
                  "" 2
                  (lambda (this args)
                    (declare (ignore this))
                    (funcall settler (eng:arg args 0) (eng:arg args 1))
                    eng:+undefined+)))))
             (resolve-result (resolve value complete)
               (eng:js-call resolve eng:+undefined+
                            (list (%shell-iterator-result value complete)))))
      (eng:install-method iterator "next" 0
        (lambda (this args)
          (declare (ignore this args))
          (promise
           (lambda (resolve reject)
             (cond
               (done
                (resolve-result resolve eng:+undefined+ t))
               (t
                (unless initialized
                  (setf initialized t)
                  (%shell-job-start job)
                  (unless (shell-job-error job)
                    (setf lines
                          (%shell-lines
                           (%shell-string
                            (shell-result-stdout (shell-job-result job)))))))
                (cond
                  ((shell-job-error job)
                   (setf done t)
                   (eng:js-call reject eng:+undefined+
                                (list (shell-job-error job))))
                  ((< index (length lines))
                   (prog1
                       (resolve-result resolve (nth index lines) nil)
                     (incf index)))
                  (t
                   (setf done t)
                   (resolve-result resolve eng:+undefined+ t)))))))))
      (eng:install-method iterator "return" 0
        (lambda (this args)
          (declare (ignore this args))
          (setf done t)
          (promise (lambda (resolve reject)
                     (declare (ignore reject))
                     (resolve-result resolve eng:+undefined+ t)))))
      (eng:create-data-property
       iterator (eng:well-known :async-iterator)
       (eng:make-native-function
        "[Symbol.asyncIterator]" 0
        (lambda (this args) (declare (ignore args)) this)))
      iterator)))

(defun %shell-promise-object (job)
  (let ((object (eng:new-object)) (state (shell-job-state job)))
    (eng:install-method object "run" 0
      (lambda (this args)
        (declare (ignore args))
        (%shell-job-start job)
        this))
    (eng:install-method object "then" 2
      (lambda (this args) (declare (ignore this))
        (let ((promise (%shell-job-output-promise job)))
          (eng:js-call (eng:js-get promise "then") promise
                       (list (eng:arg args 0) (eng:arg args 1))))))
    (eng:install-method object "catch" 1
      (lambda (this args) (declare (ignore this))
        (let ((promise (%shell-job-output-promise job)))
          (eng:js-call (eng:js-get promise "catch") promise
                       (list (eng:arg args 0))))))
    (eng:install-method object "finally" 1
      (lambda (this args) (declare (ignore this))
        (let ((promise (%shell-job-output-promise job)))
          (eng:js-call (eng:js-get promise "finally") promise
                       (list (eng:arg args 0))))))
    (eng:install-method object "cwd" 1
      (lambda (this args)
        (let ((cwd (%shell-relative-path
                    (eng:to-string (eng:arg args 0)) state)))
          (setf (shell-state-cwd state) cwd
                (shell-state-env state)
                (%shell-env-set (shell-state-env state) "PWD" cwd)))
        this))
    (eng:install-method object "env" 1
      (lambda (this args)
        (setf (shell-state-env state)
              (%shell-object-env (shell-job-g job) (eng:arg args 0)))
        this))
    (eng:install-method object "quiet" 1
      (lambda (this args)
        (setf (shell-state-quiet state)
              (if (eng:js-undefined-p (eng:arg args 0))
                  t (eng:js-truthy (eng:arg args 0))))
        this))
    (eng:install-method object "nothrow" 0
      (lambda (this args) (declare (ignore args))
        (setf (shell-state-throws state) nil) this))
    (eng:install-method object "throws" 1
      (lambda (this args)
        (setf (shell-state-throws state) (eng:js-truthy (eng:arg args 0))) this))
    (eng:install-method object "text" 0
      (lambda (this args) (declare (ignore this args))
        (setf (shell-state-quiet state) t)
        (%shell-job-promise job
                            (lambda (result)
                              (%shell-string (shell-result-stdout result))))))
    (eng:install-method object "json" 0
      (lambda (this args) (declare (ignore this args))
        (setf (shell-state-quiet state) t)
        (%shell-job-promise
         job (lambda (result)
               (let ((json (eng:js-get (shell-job-g job) "JSON")))
                 (eng:js-call (eng:js-get json "parse") json
                              (list (%shell-string (shell-result-stdout result)))))))))
    (eng:install-method object "bytes" 0
      (lambda (this args) (declare (ignore this args))
        (setf (shell-state-quiet state) t)
        (%shell-job-promise job (lambda (result)
                                  (eng:u8-from-octets
                                   (copy-seq (shell-result-stdout result)))))))
    (eng:install-method object "arrayBuffer" 0
      (lambda (this args) (declare (ignore this args))
        (setf (shell-state-quiet state) t)
        (%shell-job-promise job (lambda (result)
                                  (eng:js-get
                                   (eng:u8-from-octets
                                    (copy-seq (shell-result-stdout result)))
                                   "buffer")))))
    (eng:install-method object "blob" 0
      (lambda (this args) (declare (ignore this args))
        (setf (shell-state-quiet state) t)
        (%shell-job-promise
         job (lambda (result)
               (%new-blob-from-octets (shell-result-stdout result))))))
    (eng:install-method object "lines" 0
      (lambda (this args) (declare (ignore this args))
        (setf (shell-state-quiet state) t)
        (%shell-lines-iterator job)))
    object))

(defun %shell-escape (value)
  (let ((string (eng:to-string value)))
    (if (and (plusp (length string))
             (every (lambda (character)
                      (or (alphanumericp character)
                          (> (char-code character) 127)
                          (find character "_@%+:,./-")))
                    string))
        string
        (with-output-to-string (output)
          (write-char #\" output)
          (loop for character across string do
            (when (find character "\\\"$`") (write-char #\\ output))
            (write-char character output))
          (write-char #\" output)))))

(defconstant +shell-max-brace-groups+ 256)
(defconstant +shell-max-brace-results+ 65536)

(defun %shell-brace-tokenize (pattern)
  (let ((tokens '()) (text (make-string-output-stream))
        (depth 0) (groups 0) (index 0))
    (labels ((flush-text ()
               (let ((value (get-output-stream-string text)))
                 (when (plusp (length value))
                   (push (make-shell-brace-token :kind :text :value value) tokens))))
             (emit (kind)
               (flush-text)
               (push (make-shell-brace-token :kind kind) tokens)))
      (loop while (< index (length pattern)) do
        (let ((character (char pattern index)))
          (cond
            ((and (char= character #\\) (< (1+ index) (length pattern)))
             (write-char (char pattern (1+ index)) text)
             (incf index 2))
            ((char= character #\{)
             (incf groups)
             (when (> groups +shell-max-brace-groups+)
               (eng:throw-range-error "Too many braces in brace expansion"))
             (incf depth)
             (emit :open)
             (incf index))
            ((and (char= character #\}) (plusp depth))
             (decf depth)
             (emit :close)
             (incf index))
            ((and (char= character #\,) (plusp depth))
             (emit :comma)
             (incf index))
            (t
             (write-char character text)
             (incf index)))))
      (flush-text)
      ;; An unmatched group is not an expansion. Returning one text token keeps
      ;; the original spelling, including escapes, as Bun does for a no-op.
      (when (plusp depth)
        (setf tokens
              (list (make-shell-brace-token :kind :text :value pattern))))
      (nreverse
       (cons (make-shell-brace-token :kind :eof) tokens)))))

(defun %shell-brace-parse (tokens)
  (let ((index 0) (length (length tokens)))
    (labels ((kind ()
               (shell-brace-token-kind (nth index tokens)))
             (parse-group ()
               (let ((atoms '()))
                 (loop while (and (< index length)
                                  (not (member (kind) '(:comma :close :eof))))
                       do (case (kind)
                            (:text
                             (push (make-shell-brace-atom
                                    :kind :text
                                    :value (shell-brace-token-value
                                            (nth index tokens)))
                                   atoms)
                             (incf index))
                            (:open
                             (incf index)
                             (push (make-shell-brace-atom
                                    :kind :expansion :value (parse-expansion))
                                   atoms))))
                 (make-shell-brace-group :atoms (nreverse atoms))))
             (parse-expansion ()
               (let ((variants '()))
                 (loop
                   (push (parse-group) variants)
                   (case (kind)
                     (:comma (incf index))
                     (:close (incf index) (return))
                     (:eof (return))))
                 (nreverse variants))))
      (parse-group))))

(defun %shell-brace-expand-group (group)
  (let ((results (list "")))
    (dolist (atom (shell-brace-group-atoms group) results)
      (let ((choices
              (case (shell-brace-atom-kind atom)
                (:text (list (shell-brace-atom-value atom)))
                (:expansion
                 (mapcan #'%shell-brace-expand-group
                         (shell-brace-atom-value atom))))))
        (let ((next '()) (count 0))
          (dolist (prefix results)
            (dolist (choice choices)
              (incf count)
              (when (> count +shell-max-brace-results+)
                (eng:throw-range-error
                 (format nil "Too many brace expansions (~d > ~d)"
                         count +shell-max-brace-results+)))
              (push (concatenate 'string prefix choice) next)))
          (setf results (nreverse next)))))))

(defun %shell-brace-expansion-count (group)
  (let ((count 1))
    (dolist (atom (shell-brace-group-atoms group) count)
      (when (eq (shell-brace-atom-kind atom) :expansion)
        (setf count
              (* count
                 (reduce #'+ (shell-brace-atom-value atom)
                         :key #'%shell-brace-expansion-count
                         :initial-value 0)))))))

(defun %shell-brace-expand-parsed (group)
  (let ((count (%shell-brace-expansion-count group)))
    (when (> count +shell-max-brace-results+)
      (eng:throw-range-error
       (format nil "Too many brace expansions (~d > ~d)"
               count +shell-max-brace-results+)))
    (%shell-brace-expand-group group)))

(defun %shell-json-quoted (value)
  (with-output-to-string (output)
    (write-char #\" output)
    (loop for character across value
          for code = (char-code character)
          do (case character
               (#\" (write-string "\\\"" output))
               (#\\ (write-string "\\\\" output))
               (#\Backspace (write-string "\\b" output))
               (#\Page (write-string "\\f" output))
               (#\Newline (write-string "\\n" output))
               (#\Return (write-string "\\r" output))
               (#\Tab (write-string "\\t" output))
               (otherwise
                (if (< code 32)
                    (format output "\\u~4,'0x" code)
                    (write-char character output)))))
    (write-char #\" output)))

(defun %shell-brace-tokens-json (tokens)
  (with-output-to-string (output)
    (write-char #\[ output)
    (loop for token in tokens
          for first = t then nil
          unless first do (write-char #\, output)
          do (case (shell-brace-token-kind token)
               (:open (write-string "{\"open\":{\"idx\":0,\"end\":0}}" output))
               (:comma (write-string "\"comma\"" output))
               (:close (write-string "\"close\"" output))
               (:eof (write-string "\"eof\"" output))
               (:text
                (format output "{\"text\":~a}"
                        (%shell-json-quoted (shell-brace-token-value token)))))
          finally (write-char #\] output))))

(defun %shell-brace-atom-json (atom output)
  (case (shell-brace-atom-kind atom)
    (:text
     (format output "{\"text\":~a}"
             (%shell-json-quoted (shell-brace-atom-value atom))))
    (:expansion
     (write-string "{\"expansion\":{\"variants\":[" output)
     (loop for group in (shell-brace-atom-value atom)
           for first = t then nil
           unless first do (write-char #\, output)
           do (%shell-brace-group-json group output))
     (write-string "]}}" output))))

(defun %shell-brace-group-json (group output)
  (let ((atoms (shell-brace-group-atoms group)))
    (write-string "{\"bubble_up\":null,\"bubble_up_next\":null,\"atoms\":" output)
    (if (= (length atoms) 1)
        (progn
          (write-string "{\"single\":" output)
          (%shell-brace-atom-json (first atoms) output)
          (write-string "}}" output))
        (progn
          (write-string "{\"many\":[" output)
          (loop for atom in atoms
                for first = t then nil
                unless first do (write-char #\, output)
                do (%shell-brace-atom-json atom output))
          (write-string "]}}" output)))))

(defun %shell-brace-ast-json (group)
  (with-output-to-string (output)
    (%shell-brace-group-json group output)))

(defun %shell-brace-expand (pattern)
  (let* ((tokens (%shell-brace-tokenize pattern))
         (expansion-p (find :open tokens :key #'shell-brace-token-kind)))
    (if expansion-p
        (%shell-brace-expand-parsed (%shell-brace-parse tokens))
        (list pattern))))

(defun %shell-make-tag (g name initial-env initial-cwd initial-throws)
  "Create one callable shell tag with instance-local defaults."
  (let ((default-env (%shell-env-copy initial-env))
        (default-cwd initial-cwd)
        (default-throws initial-throws)
        (tag nil))
    (setf tag
          (eng:make-native-function
           name 1
           (lambda (this args)
             (declare (ignore this))
             (let* ((strings (eng:arg args 0))
                    (expressions (rest args))
                    (state (make-shell-state
                            :env (%shell-env-copy default-env)
                            :cwd default-cwd :throws default-throws)))
               (%shell-promise-object
                (make-shell-job :units (%shell-template-units strings expressions)
                                :state state :g g))))))
    (eng:install-method tag "env" 1
      (lambda (this args)
        (setf default-env (%shell-object-env g (eng:arg args 0))) this))
    (eng:install-method tag "cwd" 1
      (lambda (this args)
        (let ((cwd
                (if (eng:js-undefined-p (eng:arg args 0))
                    (clun.sys:current-directory)
                    (let ((value (eng:to-string (eng:arg args 0))))
                      (if (clun.sys:absolute-path-p value) value
                          (clun.sys:normalize-path
                           (clun.sys:path-join
                            (clun.sys:current-directory) value)))))))
          (setf default-cwd cwd
                default-env (%shell-env-set default-env "PWD" cwd)))
        this))
    (eng:install-method tag "nothrow" 0
      (lambda (this args)
        (declare (ignore args))
        (setf default-throws nil)
        this))
    (eng:install-method tag "throws" 1
      (lambda (this args)
        (setf default-throws (eng:js-truthy (eng:arg args 0))) this))
    tag))

(defun install-shell (clun g)
  "Install the realm-local Clun.$ tag and the global $ alias."
  (let ((tag nil)
        (shell-error-constructor nil))
    (let* ((error-prototype (eng:js-get (eng:js-get g "Error") "prototype"))
           (shell-error-prototype (eng:js-make-object error-prototype :error)))
      (eng:hidden-prop shell-error-prototype "name" "ShellError")
      (eng:hidden-prop shell-error-prototype "message" "")
      (labels ((make-error (args)
                 (let* ((message (eng:arg args 0))
                        (error (eng:js-make-object shell-error-prototype :error)))
                   (unless (eng:js-undefined-p message)
                     (eng:hidden-prop error "message" (eng:to-string message)))
                   (eng:hidden-prop
                    error "stack"
                    (format nil "ShellError: ~a"
                            (if (eng:js-undefined-p message) ""
                                (eng:to-string message))))
                   error)))
        (setf shell-error-constructor
              (eng:make-native-function
               "ShellError" 1
               (lambda (this args) (declare (ignore this)) (make-error args))
               :construct (lambda (args new-target)
                            (declare (ignore new-target)) (make-error args)))))
      (eng:data-prop shell-error-constructor "prototype" shell-error-prototype)
      (eng:data-prop shell-error-prototype "constructor" shell-error-constructor))
    (setf tag (%shell-make-tag
               g "$" (clun.sys:environ-alist) (clun.sys:current-directory) t))
    (eng:install-method tag "escape" 1
      (lambda (this args) (declare (ignore this)) (%shell-escape (eng:arg args 0))))
    (eng:install-method tag "braces" 2
      (lambda (this args)
        (declare (ignore this))
        (let* ((pattern (eng:to-string (eng:arg args 0)))
               (options (eng:arg args 1))
               (tokens (%shell-brace-tokenize pattern)))
          (cond
            ((and (eng:js-object-p options)
                  (eng:js-truthy (eng:js-get options "tokenize")))
             (%shell-brace-tokens-json tokens))
            ((and (eng:js-object-p options)
                  (eng:js-truthy (eng:js-get options "parse")))
             (%shell-brace-ast-json (%shell-brace-parse tokens)))
            (t
             (eng:new-array
              (if (find :open tokens :key #'shell-brace-token-kind)
                  (%shell-brace-expand-parsed (%shell-brace-parse tokens))
                  (list pattern))))))))
    (let* ((shell-prototype (eng:new-object))
           (shell-constructor
             (eng:make-native-function
              "Shell" 0
              (lambda (this args)
                (declare (ignore this args))
                (eng:throw-type-error
                 "Class constructor Shell cannot be invoked without 'new'"))
              :construct
              (lambda (args new-target)
                (declare (ignore args new-target))
                (let ((instance
                        (%shell-make-tag
                         g "Shell" (clun.sys:environ-alist)
                         (clun.sys:current-directory) t)))
                  (eng::jm-set-prototype-of instance shell-prototype)
                  instance)))))
      (eng:data-prop shell-constructor "prototype" shell-prototype)
      (eng:data-prop shell-prototype "constructor" shell-constructor)
      (eng:data-prop tag "Shell" shell-constructor))
    (eng:data-prop tag "ShellError" shell-error-constructor)
    (eng:data-prop clun "$" tag)
    (eng:hidden-prop g "$" tag)
    tag))
