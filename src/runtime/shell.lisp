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

(defstruct shell-fragment kind value quoted)
(defstruct shell-word (fragments '()))
(defstruct shell-token kind value)
(defstruct shell-redirection kind target)
(defstruct shell-command (words '()) (assignments '()) (redirections '()))
(defstruct shell-pipeline (commands '()))
(defstruct shell-script (pipelines '()) (operators '()))
(defstruct shell-result
  (stdout #() :type vector)
  (stderr #() :type vector)
  (exit-code 0 :type integer))
(defstruct shell-state
  (env '()) cwd old-cwd (last-exit-code 0) (throws t) (quiet nil)
  (terminated nil))
(defstruct shell-job
  units state g result error (started nil))

(defparameter *shell-max-array-depth* 64)
(defparameter *shell-max-seq-items* 1000000)
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
                       (vector-push-extend (cons :interp value) pieces)))))
      (coerce pieces 'vector))))

(defun %shell-operator-at (units index)
  (flet ((matches (text)
           (and (<= (+ index (length text)) (length units))
                (loop for offset below (length text)
                      for unit = (aref units (+ index offset))
                      always (and (characterp unit)
                                  (char= unit (char text offset)))))))
    (or (find-if #'matches '("2>&1" "1>&2" "&>>" "2>>" "1>>" "&&" "||"
                             ">>" "&>" "2>" "1>" "|" ";" "<" ">" "&")))))

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
        (quote nil) (index 0))
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
                 (push (make-shell-token :kind :word
                                         :value (make-shell-word
                                                 :fragments (nreverse fragments)))
                       tokens))
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
                   (if (characterp next)
                       (progn
                         (unless (and (eq quote :double)
                                      (not (find next "$\\\"`")))
                           (setf index (1+ index)))
                         (emit-character (aref units index) (not (null quote)))
                         (incf index))
                       (progn (emit-character #\\ (not (null quote))) (incf index))))
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
               (if operator
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

(defun %shell-parse-command (tokens)
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

(defun %shell-split-tokens (tokens separator)
  (let ((groups '()) (current '()))
    (dolist (token tokens)
      (if (and (eq (shell-token-kind token) :operator)
               (string= (shell-token-value token) separator))
          (progn
            (when (null current) (%shell-syntax "empty command before ~a" separator))
            (push (nreverse current) groups) (setf current '()))
          (push token current)))
    (when (null current) (%shell-syntax "empty command after ~a" separator))
    (nreverse (cons (nreverse current) groups))))

(defun %shell-parse-pipeline (tokens)
  (make-shell-pipeline
   :commands (mapcar #'%shell-parse-command (%shell-split-tokens tokens "|"))))

(defun %shell-parse (units)
  (let ((tokens (%shell-lex units)) (pipelines '()) (operators '()) (current '()))
    (labels ((flush (operator)
               (when current
                 (push (%shell-parse-pipeline (nreverse current)) pipelines)
                 (setf current '())
                 (when operator (push operator operators)))))
      (dolist (token tokens)
        (if (and (eq (shell-token-kind token) :operator)
                 (member (shell-token-value token) '(";" "&&" "||") :test #'string=))
            (flush (cond ((string= (shell-token-value token) "&&") :and)
                         ((string= (shell-token-value token) "||") :or)
                         (t :sequence)))
            (push token current)))
      (flush nil))
    ;; A trailing separator records one extra operator; it has no right-hand side.
    (when (>= (length operators) (length pipelines))
      (setf operators (butlast operators)))
    (make-shell-script :pipelines (nreverse pipelines)
                       :operators (nreverse operators))))

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
    (eng:throw-range-error "Clun.$ interpolation arrays are nested too deeply"))
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
  (declare (ignore g))
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
              (result (%shell-execute-units (shell-fragment-value fragment) sub-state))
              (value (%shell-trim-command-output
                      (%shell-string (shell-result-stdout result)))))
         (setf (shell-state-last-exit-code state) (shell-result-exit-code result))
         (values (if quoted (list value) (%shell-whitespace-fields value)) (not quoted))))
      (otherwise (values (list "") nil)))))

(defun %shell-word-glob-p (word)
  (some (lambda (fragment)
          (and (eq (shell-fragment-kind fragment) :literal)
               (not (shell-fragment-quoted fragment))
               (find-if (lambda (character) (find character "*?[{"))
                        (shell-fragment-value fragment))))
        (shell-word-fragments word)))

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

(defun %shell-expand-glob (value state)
  (handler-case
      (let* ((options (clun.glob:make-glob-scan-options
                       :cwd (shell-state-cwd state) :dot nil :only-files nil))
             (matches (clun.glob:scan-glob value options)))
        (if (plusp (length matches)) (coerce matches 'list) (list value)))
    (error () (list value))))

(defun %shell-word-values (word state g)
  (let ((fields (list "")) (has-value nil))
    (dolist (fragment (shell-word-fragments word))
      (multiple-value-bind (values split-p) (%shell-fragment-values fragment state g)
        (declare (ignore split-p))
        (if values
            (setf fields
                  (loop for prefix in fields append
                    (loop for value in values collect (concatenate 'string prefix value)))
                  has-value t)
            (setf fields nil))))
    (when (and (null fields)
               (some #'shell-fragment-quoted (shell-word-fragments word)))
      (setf fields (list "")))
    (when (and fields (%shell-word-tilde-p word))
      (setf fields (mapcar (lambda (value) (%shell-expand-tilde value state)) fields)))
    (when (and fields (%shell-word-glob-p word))
      (setf fields (mapcan (lambda (value) (%shell-expand-glob value state)) fields)))
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
  '("echo" "pwd" "cd" "true" "false" ":" "export" "unset" "which" "exit"
    "basename" "dirname" "seq"))

(defun %shell-relative-path (path state)
  (if (clun.sys:absolute-path-p path)
      (clun.sys:normalize-path path)
      (clun.sys:normalize-path (clun.sys:path-join (shell-state-cwd state) path))))

(defun %shell-result-from-strings (stdout stderr code)
  (make-shell-result :stdout (%shell-octets stdout) :stderr (%shell-octets stderr)
                     :exit-code code))

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
        (loop with path = (%shell-env-get env "PATH" "")
              with start = 0
              for colon = (position #\: path :start start)
              for directory = (subseq path start (or colon (length path)))
              for candidate = (clun.sys:path-join (if (string= directory "") cwd directory)
                                                   name)
              when (usable candidate) return candidate
              while colon do (setf start (1+ colon))))))

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
             (make-string (if (= trailing 1) 2 (min trailing 2))
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

(defun %shell-run-builtin (argv state env)
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
      ((string= name "pwd")
       (values (%shell-result-from-strings
                (concatenate 'string (shell-state-cwd state) (string #\Newline)) "" 0) t))
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

(defun %shell-command-redirections (command state g stdin)
  "Apply input redirections and return stdin plus the ordered output redirections."
  (let ((input stdin) (output-redirections '()))
    (dolist (redirection (shell-command-redirections command))
      (if (eq (shell-redirection-kind redirection) :input)
          (setf input (%shell-read-target
                       (%shell-word-raw-target (shell-redirection-target redirection)
                                               state g)
                       state))
          (push redirection output-redirections)))
    (values input (nreverse output-redirections))))

(defun %shell-apply-output-redirections (result redirections state g)
  (let ((stdout (shell-result-stdout result))
        (stderr (shell-result-stderr result)))
    (dolist (redirection redirections)
      (let ((kind (shell-redirection-kind redirection)))
        (case kind
          ((:output :output-append)
           (%shell-write-target
            (%shell-word-raw-target (shell-redirection-target redirection) state g)
            state stdout (eq kind :output-append))
           (setf stdout *shell-empty-octets*))
          ((:error :error-append)
           (%shell-write-target
            (%shell-word-raw-target (shell-redirection-target redirection) state g)
            state stderr (eq kind :error-append))
           (setf stderr *shell-empty-octets*))
          ((:both :both-append)
           (%shell-write-target
            (%shell-word-raw-target (shell-redirection-target redirection) state g)
            state (%shell-concat-octets stdout stderr) (eq kind :both-append))
           (setf stdout *shell-empty-octets* stderr *shell-empty-octets*))
          (:error-to-output
           (setf stdout (%shell-concat-octets stdout stderr)
                 stderr *shell-empty-octets*))
          (:output-to-error
           (setf stderr (%shell-concat-octets stderr stdout)
                 stdout *shell-empty-octets*)))))
    (make-shell-result :stdout stdout :stderr stderr
                       :exit-code (shell-result-exit-code result))))

(defun %shell-execute-command (command state g stdin)
  (let ((env (%shell-env-copy (shell-state-env state))))
    (dolist (assignment (shell-command-assignments command))
      (setf env (%shell-env-set env (car assignment)
                                (%shell-assignment-value (cdr assignment) state g))))
    (if (null (shell-command-words command))
        (progn
          (setf (shell-state-env state) env)
          (make-shell-result))
        (let ((argv (mapcan (lambda (word) (%shell-word-values word state g))
                            (shell-command-words command))))
          (if (null argv)
              (make-shell-result)
              (multiple-value-bind (input output-redirections)
                  (%shell-command-redirections command state g stdin)
                (multiple-value-bind (builtin handled)
                    (%shell-run-builtin argv state env)
                  (%shell-apply-output-redirections
                   (if handled builtin
                       (%shell-run-external argv env (shell-state-cwd state) input))
                   output-redirections state g))))))))

(defun %shell-static-builtin-p (command)
  (let* ((word (first (shell-command-words command)))
         (fragments (and word (shell-word-fragments word))))
    (and (= (length fragments) 1)
         (eq (shell-fragment-kind (first fragments)) :literal)
         (member (shell-fragment-value (first fragments)) *shell-builtins*
                 :test #'string=))))

(defun %shell-concurrent-pipeline-p (pipeline)
  (let ((commands (shell-pipeline-commands pipeline)))
    (and (> (length commands) 1)
         (every (lambda (command)
                  (and (shell-command-words command)
                       (null (shell-command-redirections command))
                       (not (%shell-static-builtin-p command))))
                commands))))

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

(defun %shell-execute-sequential-pipeline (pipeline state g)
  (let ((input *shell-empty-octets*) (stderr *shell-empty-octets*)
        (result (make-shell-result)))
    (dolist (command (shell-pipeline-commands pipeline))
      (setf result (%shell-execute-command command state g input)
            input (shell-result-stdout result)
            stderr (%shell-concat-octets stderr (shell-result-stderr result))))
    (make-shell-result :stdout (shell-result-stdout result) :stderr stderr
                       :exit-code (shell-result-exit-code result))))

(defun %shell-execute-pipeline (pipeline state g)
  (if (%shell-concurrent-pipeline-p pipeline)
      (%shell-execute-concurrent-pipeline pipeline state g)
      (%shell-execute-sequential-pipeline pipeline state g)))

(defun %shell-execute-script (script state g)
  (let ((stdout *shell-empty-octets*) (stderr *shell-empty-octets*)
        (previous (make-shell-result)) (index 0))
    (dolist (pipeline (shell-script-pipelines script))
      (when (shell-state-terminated state) (return))
      (let ((operator (and (plusp index)
                           (nth (1- index) (shell-script-operators script)))))
        (when (or (zerop index)
                  (eq operator :sequence)
                  (and (eq operator :and) (zerop (shell-result-exit-code previous)))
                  (and (eq operator :or) (not (zerop (shell-result-exit-code previous)))))
          (setf previous (%shell-execute-pipeline pipeline state g))
          (setf stdout (%shell-concat-octets stdout (shell-result-stdout previous))
                stderr (%shell-concat-octets stderr (shell-result-stderr previous))
                (shell-state-last-exit-code state) (shell-result-exit-code previous))))
      (incf index))
    (make-shell-result :stdout stdout :stderr stderr
                       :exit-code (shell-result-exit-code previous))))

(defun %shell-execute-units (units state &optional (g (eng:realm-global eng:*realm*)))
  (%shell-execute-script (%shell-parse units) state g))

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
                 (list (format nil "Shell command exited with code ~d"
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
  (let ((lines '()) (start 0))
    (loop for newline = (position #\Newline text :start start)
          while newline
          do (push (string-right-trim '(#\Return) (subseq text start newline)) lines)
             (setf start (1+ newline)))
    (when (< start (length text))
      (push (subseq text start) lines))
    (nreverse lines)))

(defun %shell-promise-object (job)
  (let ((object (eng:new-object)) (state (shell-job-state job)))
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
        (setf (shell-state-cwd state)
              (%shell-relative-path (eng:to-string (eng:arg args 0)) state))
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
    (eng:install-method object "lines" 0
      (lambda (this args) (declare (ignore this args))
        (setf (shell-state-quiet state) t)
        (%shell-job-start job)
        (if (shell-job-error job)
            (eng:throw-js-value (shell-job-error job))
            (eng:new-array
             (%shell-lines
              (%shell-string (shell-result-stdout (shell-job-result job))))))))
    object))

(defun %shell-escape (value)
  (let ((string (eng:to-string value)))
    (if (and (plusp (length string))
             (every (lambda (character)
                      (or (alphanumericp character) (find character "_@%+=:,./-")))
                    string))
        string
        (with-output-to-string (output)
          (write-char #\" output)
          (loop for character across string do
            (when (find character "\\\"$`") (write-char #\\ output))
            (write-char character output))
          (write-char #\" output)))))

(defun %shell-brace-expand (pattern)
  (let ((open (position #\{ pattern)))
    (if (null open)
        (list pattern)
        (let ((close (position #\} pattern :start (1+ open))))
          (if (null close)
              (list pattern)
              (let* ((prefix (subseq pattern 0 open))
                     (body (subseq pattern (1+ open) close))
                     (suffix (subseq pattern (1+ close)))
                     (parts (loop with start = 0
                                  for comma = (position #\, body :start start)
                                  collect (subseq body start comma)
                                  while comma do (setf start (1+ comma)))))
                (mapcan (lambda (part)
                          (%shell-brace-expand
                           (concatenate 'string prefix part suffix)))
                        parts)))))))

(defun install-shell (clun g)
  "Install the realm-local Clun.$ tag and the global $ alias."
  (let ((default-env (clun.sys:environ-alist))
        (default-cwd (clun.sys:current-directory))
        (default-throws t)
        (tag nil)
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
    (setf tag
          (eng:make-native-function
           "$" 1
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
        (setf default-cwd
              (if (eng:js-undefined-p (eng:arg args 0))
                  (clun.sys:current-directory)
                  (let ((value (eng:to-string (eng:arg args 0))))
                    (if (clun.sys:absolute-path-p value) value
                        (clun.sys:normalize-path
                         (clun.sys:path-join (clun.sys:current-directory) value))))))
        this))
    (eng:install-method tag "nothrow" 0
      (lambda (this args) (declare (ignore args)) (setf default-throws nil) this))
    (eng:install-method tag "throws" 1
      (lambda (this args)
        (setf default-throws (eng:js-truthy (eng:arg args 0))) this))
    (eng:install-method tag "escape" 1
      (lambda (this args) (declare (ignore this)) (%shell-escape (eng:arg args 0))))
    (eng:install-method tag "braces" 1
      (lambda (this args) (declare (ignore this))
        (eng:new-array (%shell-brace-expand (eng:to-string (eng:arg args 0))))))
    (eng:data-prop tag "ShellError" shell-error-constructor)
    (eng:data-prop clun "$" tag)
    (eng:hidden-prop g "$" tag)
    tag))
