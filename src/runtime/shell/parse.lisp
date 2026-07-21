;;;; shell/parse.lisp — types, lexer, and parser for Clun.$ (split from shell.lisp; Elon P3 / #318).
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
  (words '()) (assignments '()) (redirections '()) group brace-group if-form negated)
(defstruct shell-pipeline (commands '()) (merge-stderr '()) (background nil))
(defstruct shell-script (pipelines '()) (operators '()))
(defstruct shell-result
  (stdout #() :type vector)
  (stderr #() :type vector)
  (exit-code 0 :type integer))
(defstruct shell-output-sink kind target)
(defstruct shell-prepared-redirection kind target)
(defstruct shell-state
  (env '())
  ;; Names marked for child-process inheritance. Bun keeps ordinary shell
  ;; assignments shell-local until `export`; the initial process environment is
  ;; treated as already exported.
  (exported '())
  cwd old-cwd (last-exit-code 0) (throws t) (quiet nil)
  (terminated nil) (positionals '())
  ;; Stderr produced while expanding command substitutions is attributed to the
  ;; surrounding command (Bun Expansion / shell-var-3).
  (pending-stderr (make-array 0 :element-type '(unsigned-byte 8)))
  ;; Background (&) jobs: finished SHELL-RESULT values or running process plists
  ;; (:process :directory :stdout :stderr).
  (background-jobs '()))
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

(defun %shell-exported-names (env)
  "Every key in ENV is considered exported (used for process-env bootstrap)."
  (mapcar #'car env))

(defun %shell-env-vector-exported (env exported &optional (extra-keys '()))
  "Serialize ENV for a child process: exported names plus command-local keys."
  (loop for (name . value) in env
        when (or (member name exported :test #'string=)
                 (member name extra-keys :test #'string=))
          collect (format nil "~a=~a" name value)))

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
    (or (find-if #'matches '("2>&1" "1>&2" "&>>" "2>>" "1>>" "&&" "||" "|&"
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

(defun %shell-read-backtick-substitution (units start)
  "Read an old-style command substitution after a consumed backtick."
  (let ((output (make-array 32 :adjustable t :fill-pointer 0))
        (index start))
    (loop while (< index (length units)) do
      (let ((unit (aref units index)))
        (cond
          ((not (characterp unit))
           (vector-push-extend unit output)
           (incf index))
          ((char= unit #\\)
           (if (< (1+ index) (length units))
               (let ((next (aref units (1+ index))))
                 (if (and (characterp next) (char= next #\Newline))
                     ;; Historical backticks remove line continuations before
                     ;; parsing their body, including continuations in quotes.
                     (incf index 2)
                     (progn
                       (vector-push-extend unit output)
                       (vector-push-extend next output)
                       (incf index 2))))
               (progn
                 (vector-push-extend unit output)
                 (incf index))))
          ((char= unit #\`)
           (return-from %shell-read-backtick-substitution
             (values (coerce output 'vector) (1+ index))))
          (t
           (vector-push-extend unit output)
           (incf index)))))
    (%shell-syntax "unterminated backtick command substitution")))

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
      ((digit-char-p unit)
       ;; Unbraced shell positionals consume one digit: $10 is $1 followed by
       ;; the literal 0, matching the pinned Bun standalone-script contract.
       (values (make-shell-fragment :kind :positional
                                    :value (- (char-code unit) (char-code #\0))
                                    :quoted quoted)
               (1+ index)))
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
            ((char= unit #\`)
             (multiple-value-bind (body next)
                 (%shell-read-backtick-substitution units (1+ index))
               (emit-fragment (make-shell-fragment :kind :substitution
                                                   :value body
                                                   :quoted (not (null quote))))
               (setf index next)))
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
       (member (shell-token-value token) '(";" "&&" "||" "&" "|" "|&" "(")
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
      ((and word (string= word "!"))
       (values control-depth t))
      (t
       (values control-depth
               (%shell-command-start-after-token-p token))))))

(defun %shell-parse-if-command (tokens)
  (let ((branches '()) (alternative nil) (condition nil)
        (phase :condition) (start 1) (depth 1) (at-command-start t)
        (brace-depth 0) (paren-depth 0) (close nil))
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
                 ((and word (string= word "{"))
                  (incf brace-depth)
                  (setf at-command-start t))
                 ((and word (string= word "}"))
                  (when (zerop brace-depth) (%shell-syntax "unexpected }"))
                  (decf brace-depth)
                  (setf at-command-start t))
                 ((and (eq (shell-token-kind token) :operator)
                       (string= (shell-token-value token) "("))
                  (incf paren-depth)
                  (setf at-command-start t))
                 ((and (eq (shell-token-kind token) :operator)
                       (string= (shell-token-value token) ")"))
                  (when (zerop paren-depth) (%shell-syntax "unexpected )"))
                  (decf paren-depth)
                  (setf at-command-start t))
                 ((and (zerop brace-depth) (zerop paren-depth)
                       word (string= word "if"))
                  (incf depth)
                  (setf at-command-start t))
                 ((and (zerop brace-depth) (zerop paren-depth)
                       word (string= word "fi"))
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
                 ((and (= depth 1) (zerop brace-depth) (zerop paren-depth)
                       word (string= word "then"))
                  (unless (eq phase :condition)
                    (%shell-syntax "unexpected then in if"))
                  (setf condition (parse-section index "condition")
                        phase :body
                        start (1+ index)
                        at-command-start t))
                 ((and (= depth 1) (zerop brace-depth) (zerop paren-depth)
                       word (string= word "elif"))
                  (unless (eq phase :body)
                    (%shell-syntax "unexpected elif in if"))
                  (finish-branch index)
                  (setf phase :condition
                        start (1+ index)
                        at-command-start t))
                 ((and (= depth 1) (zerop brace-depth) (zerop paren-depth)
                       word (string= word "else"))
                  (unless (eq phase :body)
                    (%shell-syntax "unexpected else in if"))
                  (finish-branch index)
                  (setf phase :else
                        start (1+ index)
                        at-command-start t))
                 (t
                  (setf at-command-start
                        (or (and word (string= word "!"))
                            (%shell-command-start-after-token-p token))))))
      (unless close (%shell-syntax "unterminated if"))
      (let* ((suffix (nthcdr (1+ close) tokens))
             (redirections
               (when suffix
                 (let ((parsed (%shell-parse-command suffix)))
                   (when (or (shell-command-group parsed)
                             (shell-command-brace-group parsed)
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
             (string= (or (%shell-static-token-word (first tokens)) "") "!"))
    (when (null (rest tokens))
      (%shell-syntax "! has no command"))
    (let ((command (%shell-parse-command (rest tokens))))
      (setf (shell-command-negated command)
            (not (shell-command-negated command)))
      (return-from %shell-parse-command command)))
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
                             (shell-command-brace-group parsed)
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
  (when (and tokens
             (string= (or (%shell-static-token-word (first tokens)) "") "{"))
    (let ((depth 0) (control-depth 0) (at-command-start t) (close nil))
      (loop for token in tokens
            for index from 0
            for command-start = at-command-start
            for word = (and command-start (%shell-static-token-word token))
            do (cond
                 ((and word (string= word "{"))
                  (incf depth)
                  (setf at-command-start t))
                 ((and word (string= word "}"))
                  (decf depth)
                  (when (minusp depth) (%shell-syntax "unexpected }"))
                  (if (zerop depth)
                      (progn (setf close index) (loop-finish))
                      (setf at-command-start nil)))
                 (t
                  (multiple-value-setq (control-depth at-command-start)
                    (%shell-control-state-after-token
                     token control-depth at-command-start)))))
      (unless close (%shell-syntax "unterminated brace group"))
      (let* ((inner (subseq tokens 1 close))
             (suffix (nthcdr (1+ close) tokens))
             (redirections
               (when suffix
                 (let ((parsed (%shell-parse-command suffix)))
                   (when (or (shell-command-group parsed)
                             (shell-command-brace-group parsed)
                             (shell-command-if-form parsed)
                             (shell-command-words parsed)
                             (shell-command-assignments parsed)
                             (shell-command-negated parsed))
                     (%shell-syntax "unexpected token after brace group"))
                   (shell-command-redirections parsed)))))
        (when (null inner) (%shell-syntax "empty brace group"))
        (return-from %shell-parse-command
          (make-shell-command :brace-group (%shell-parse-tokens inner)
                              :redirections redirections)))))
  (let ((words '()) (assignments '()) (redirections '()) (command-seen nil)
        (index 0))
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
                        :redirections (nreverse redirections))))

(defun %shell-split-pipeline-tokens (tokens)
  (let ((groups '()) (merge-stderr '()) (current '())
        (depth 0) (brace-depth 0) (control-depth 0) (at-command-start t))
    (dolist (token tokens)
      (let* ((command-start at-command-start)
             (word (and command-start (%shell-static-token-word token)))
             (brace-open-p (and word (string= word "{")))
             (brace-close-p (and word (string= word "}"))))
        (cond
          (brace-open-p
           (incf brace-depth))
          (brace-close-p
           (decf brace-depth)
           (when (minusp brace-depth) (%shell-syntax "unexpected }"))))
        (when (eq (shell-token-kind token) :operator)
          (cond
            ((string= (shell-token-value token) "(") (incf depth))
            ((string= (shell-token-value token) ")")
             (decf depth)
             (when (minusp depth) (%shell-syntax "unexpected )")))))
        (multiple-value-setq (control-depth at-command-start)
          (%shell-control-state-after-token token control-depth at-command-start))
        (when (or brace-open-p brace-close-p)
          (setf at-command-start t))
        (if (and (zerop depth)
                 (zerop brace-depth)
                 (zerop control-depth)
                 (eq (shell-token-kind token) :operator)
                 (member (shell-token-value token) '("|" "|&")
                         :test #'string=))
            (progn
              (when (null current)
                (%shell-syntax "empty command before ~a"
                               (shell-token-value token)))
              (push (nreverse current) groups)
              (push (string= (shell-token-value token) "|&") merge-stderr)
              (setf current '()))
            (push token current))))
    (unless (zerop depth) (%shell-syntax "unterminated subshell group"))
    (unless (zerop brace-depth) (%shell-syntax "unterminated brace group"))
    (unless (zerop control-depth) (%shell-syntax "unterminated if"))
    (when (null current) (%shell-syntax "empty command after pipeline operator"))
    (values (nreverse (cons (nreverse current) groups))
            (nreverse merge-stderr))))

(defun %shell-parse-pipeline (tokens)
  (multiple-value-bind (commands merge-stderr)
      (%shell-split-pipeline-tokens tokens)
    (make-shell-pipeline
     :commands (mapcar #'%shell-parse-command commands)
     :merge-stderr merge-stderr)))

(defun %shell-operator-word-token (operator)
  (make-shell-token
   :kind :word
   :value (make-shell-word
           :fragments (list (make-shell-fragment
                             :kind :literal :value operator :quoted nil)))))

(defun %shell-parse-tokens (tokens)
  (let ((pipelines '()) (operators '()) (current '())
        (in-condition nil) (depth 0) (brace-depth 0) (control-depth 0)
        (at-command-start t))
    (labels ((flush (operator)
               (when current
                 (push (%shell-parse-pipeline (nreverse current)) pipelines)
                 (setf current '())
                 (when operator (push operator operators)))))
      (dolist (token tokens)
        (let* ((word (%shell-static-token-word token))
               (command-start at-command-start)
               (reserved-word (and command-start word)))
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
            ((and (not in-condition) reserved-word (string= reserved-word "{"))
             (incf brace-depth)
             (setf at-command-start t)
             (push token current))
            ((and (not in-condition) reserved-word (string= reserved-word "}"))
             (decf brace-depth)
             (when (minusp brace-depth) (%shell-syntax "unexpected }"))
             (setf at-command-start t)
             (push token current))
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
                  (zerop brace-depth)
                  (zerop control-depth)
                  (eq (shell-token-kind token) :operator)
                  (string= (shell-token-value token) "&"))
             ;; Background list terminator (bash / Bun application-shell parity).
             (flush :background)
             (setf at-command-start t))
            ((and (not in-condition)
                  (zerop depth)
                  (zerop brace-depth)
                  (zerop control-depth)
                  (eq (shell-token-kind token) :operator)
                  (member (shell-token-value token) '(";" "&&" "||") :test #'string=))
             (flush (cond ((string= (shell-token-value token) "&&") :and)
                          ((string= (shell-token-value token) "||") :or)
                          (t :sequence))))
            (t (push token current)))))
      (when (plusp depth)
        ;; Bun surfaces multiple unclosed-subshell diagnostics with a leading
        ;; Unexpected EOF when several opens remain (engineering lex L751).
        (if (> depth 1)
            (%shell-syntax
             (with-output-to-string (out)
               (write-string "Unexpected EOF" out)
               (dotimes (_ (1- depth))
                 (write-char #\Newline out)
                 (write-string "Unclosed subshell" out))))
            (%shell-syntax "unterminated subshell group")))
      (unless (zerop brace-depth) (%shell-syntax "unterminated brace group"))
      (unless (zerop control-depth) (%shell-syntax "unterminated if"))
      (flush nil))
    ;; A trailing separator records one extra operator; it has no right-hand side.
    ;; Trailing `&` is meaningful (marks the final AND-OR list background) and is kept.
    (when (>= (length operators) (length pipelines))
      (unless (eq (first operators) :background)
        (setf operators (butlast operators))))
    (make-shell-script :pipelines (nreverse pipelines)
                       :operators (nreverse operators))))

(defun %shell-parse (units)
  (%shell-parse-tokens (%shell-lex units)))

;;; --- expansion -------------------------------------------------------------

