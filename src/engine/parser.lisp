;;;; parser.lisp — reentrant recursive-descent + Pratt parser (PLAN.md Phase 02).
;;;; Produces the ast.lisp node tree. Every failure is a js-native-error
;;;; :syntax-error via the Phase 01 bridge — never a Lisp crash. Strict AND sloppy;
;;;; Script and Module goals. Post-ES2017 syntax is not accepted (clean SyntaxError).

(in-package :clun.engine)

(defstruct (parser (:constructor %make-parser) (:copier nil))
  lexer
  cur                          ; current (next-to-consume) token; the 1-token lookahead
  (prev-end 0 :type fixnum)    ; end offset of the last consumed token (for node spans)
  (strict nil)
  (in-function nil)
  (in-iteration nil)
  (in-switch nil)
  (allow-yield nil)
  (allow-await nil)
  (allow-in t)
  (in-parameters nil)
  (labels nil)                 ; active enclosing label names (reset per function)
  (allow-super-property nil)   ; super.x / super[x] (inside a method or lexical arrow)
  (allow-super-call nil)       ; super() (inside a derived constructor or lexical arrow)
  (source-type :script))

(defmacro with-iteration (p &body body)
  "Parse BODY with the parser's in-iteration flag set (for break/continue checks)."
  (let ((old (gensym)))
    `(let ((,old (parser-in-iteration ,p)))
       (setf (parser-in-iteration ,p) t)
       (unwind-protect (progn ,@body) (setf (parser-in-iteration ,p) ,old)))))

(defmacro with-in (p &body body)
  "Parse BODY with `in` re-enabled — the [~In] restriction of a for-init only
applies to its top-level relational chain, not to bracketed sub-expressions."
  (let ((old (gensym)))
    `(let ((,old (parser-allow-in ,p)))
       (setf (parser-allow-in ,p) t)
       (unwind-protect (progn ,@body) (setf (parser-allow-in ,p) ,old)))))

(defun syntax-error (p fmt &rest args)
  (let ((tok (parser-cur p)))
    (throw-syntax-error
     (format nil "~a (line ~a)" (apply #'format nil fmt args)
             (if tok (token-line tok) "?")))))

(defun make-parser (source &key (source-type :script) strict)
  (let* ((lx (make-lexer source))
         (p (%make-parser :lexer lx :source-type source-type :strict strict
                          :allow-await (eq source-type :module))))
    ;; skip a leading hashbang line (#! ...) before the first token
    (let ((src (lexer-src lx)))
      (when (and (>= (length src) 2) (char= (char src 0) #\#) (char= (char src 1) #\!))
        (loop until (or (>= (lexer-pos lx) (lexer-len lx))
                        (line-terminator-p (char-code (char src (lexer-pos lx)))))
              do (incf (lexer-pos lx)))))
    (setf (parser-cur p) (next-token lx strict))
    p))

;;; --- token cursor -----------------------------------------------------------

(declaim (inline cur-type cur-val))
(defun cur-type (p) (token-type (parser-cur p)))
(defun cur-val (p) (token-value (parser-cur p)))
(defun cur-start (p) (token-start (parser-cur p)))
(defun nl-before-p (p) (token-nl-before (parser-cur p)))

(defun advance (p)
  "Consume the current token and lex the next; returns the consumed token."
  (let ((tok (parser-cur p)))
    (setf (parser-prev-end p) (token-end tok)
          (parser-cur p) (next-token (parser-lexer p) (parser-strict p)))
    tok))

(defun peek (p)
  "Lex the token after CUR without consuming (lexer state snapshotted)."
  (let* ((lx (parser-lexer p))
         (pos (lexer-pos lx)) (line (lexer-line lx)) (ls (lexer-line-start lx))
         (tok (next-token lx (parser-strict p))))
    (setf (lexer-pos lx) pos (lexer-line lx) line (lexer-line-start lx) ls)
    tok))

(defun punct? (p str) (and (eq (cur-type p) :punct) (string= (cur-val p) str)))
(defun name? (p str)  (and (eq (cur-type p) :name) (string= (cur-val p) str)))
(defun name-tok? (p) (eq (cur-type p) :name))
(defun cur-escaped-p (p) (token-escaped (parser-cur p)))
(defun kw? (p str)
  "CUR is the keyword STR written WITHOUT escapes (an escaped keyword is an identifier)."
  (and (name? p str) (not (cur-escaped-p p))))

(defun eat-punct (p str)
  (unless (punct? p str) (syntax-error p "expected '~a' but got ~a" str (describe-cur p)))
  (advance p))
(defun eat-name (p str)
  (unless (name? p str) (syntax-error p "expected '~a'" str))
  (advance p))

(defun describe-cur (p)
  (let ((tok (parser-cur p)))
    (case (token-type tok)
      (:eof "end of input")
      (:punct (format nil "'~a'" (token-value tok)))
      (:name (format nil "'~a'" (token-value tok)))
      (:string "string literal") (:num "number") (:bigint "bigint")
      (:template "template") (:regexp "regexp")
      (t (princ-to-string (token-type tok))))))

;;; --- reserved words ---------------------------------------------------------

(defparameter *reserved*
  '("break" "case" "catch" "class" "const" "continue" "debugger" "default"
    "delete" "do" "else" "export" "extends" "finally" "for" "function" "if"
    "import" "in" "instanceof" "new" "return" "super" "switch" "this" "throw"
    "try" "typeof" "var" "void" "while" "with" "null" "true" "false"))
(defparameter *strict-reserved*
  '("implements" "interface" "let" "package" "private" "protected" "public"
    "static" "yield"))

(defun reserved-word-p (p name)
  (or (member name *reserved* :test #'string=)
      (and (parser-strict p) (member name *strict-reserved* :test #'string=))))

(defun check-binding-name (p name)
  "Error if NAME is not a legal BindingIdentifier in the current context."
  (when (reserved-word-p p name)
    (syntax-error p "'~a' is a reserved word" name))
  (when (and (parser-strict p) (or (string= name "eval") (string= name "arguments")))
    (syntax-error p "'~a' cannot be bound in strict mode" name))
  (when (and (parser-allow-yield p) (string= name "yield"))
    (syntax-error p "'yield' cannot be used as an identifier here"))
  (when (and (parser-allow-await p) (string= name "await"))
    (syntax-error p "'await' cannot be used as an identifier here"))
  name)

;;; --- program & directives ---------------------------------------------------

(defun parse-program (source &key (source-type :script))
  "Parse SOURCE, returning a `program` node. Signals a :syntax-error on bad input."
  (let ((p (make-parser source :source-type source-type
                               :strict (eq source-type :module))))
    (let ((start (cur-start p))
          (body (parse-statements-until p :eof t)))
      (unless (eq (cur-type p) :eof)
        (syntax-error p "unexpected ~a" (describe-cur p)))
      (analyze (finish (make-program :body body :source-type source-type :source source)
                       start (parser-prev-end p))))))

(defun parse-directive-prologue (p)
  "Consume a directive prologue; set strict if a 'use strict' directive appears.
Returns the directive statements. A string that turns out to head a larger
expression is not a directive — we snapshot and rewind so the caller parses it."
  (let ((dirs '()))
    (loop while (eq (cur-type p) :string)
          do (let* ((tok (parser-cur p))
                    (start (token-start tok))
                    (raw (subseq (lexer-src (parser-lexer p)) start (token-end tok)))
                    (val (token-value tok))
                    (save (snapshot p)))
               (advance p)
               (if (or (punct? p ";") (nl-before-p p) (punct? p "}") (eq (cur-type p) :eof))
                   (let ((dir (subseq raw 1 (1- (length raw)))))
                     (when (string= dir "use strict") (setf (parser-strict p) t))
                     (consume-semicolon p)
                     (push (finish (make-expression-statement
                                    :expression (finish (make-literal :value val :kind :string :raw raw)
                                                        start (token-end tok))
                                    :directive dir)
                                   start (parser-prev-end p))
                           dirs))
                   (progn (restore p save) (return)))))
    (nreverse dirs)))

;;; --- statements -------------------------------------------------------------

(defun parse-statements-until (p terminator &optional top-level)
  "Parse statements until CUR is TERMINATOR (a punct string) or :eof."
  (let ((body '()))
    (when top-level
      (setf body (nreverse (parse-directive-prologue p))))
    (loop until (if (eq terminator :eof)
                    (eq (cur-type p) :eof)
                    (or (eq (cur-type p) :eof) (punct? p terminator)))
          do (push (parse-statement-or-decl p) body))
    (nreverse body)))

(defun parse-statement-or-decl (p)
  (cond
    ((kw? p "function") (parse-function-declaration p nil))
    ((kw? p "class") (parse-class p t))
    ((or (kw? p "const") (name-let-decl-p p))
     (parse-variable-statement p (intern (string-upcase (cur-val p)) :keyword)))
    ((and (kw? p "async") (let ((n (peek p)))
                            (and (eq (token-type n) :name) (string= (token-value n) "function")
                                 (not (token-nl-before n)))))
     (parse-function-declaration p t))
    ((and (eq (parser-source-type p) :module)
          (or (kw? p "import") (kw? p "export"))
          ;; import( and import. are expressions, not declarations
          (not (and (kw? p "import")
                    (let ((n (peek p)))
                      (and (eq (token-type n) :punct)
                           (member (token-value n) '("(" ".") :test #'string=))))))
     (if (kw? p "import") (parse-import p) (parse-export p)))
    (t (parse-statement p))))

(defun name-let-decl-p (p)
  "True if CUR is `let` (unescaped) beginning a lexical declaration (let [ / { / name)."
  (and (kw? p "let")
       (let ((n (peek p)))
         (or (and (eq (token-type n) :punct) (member (token-value n) '("[" "{") :test #'string=))
             (eq (token-type n) :name)))))

(defun parse-statement (p)
  (let ((start (cur-start p)))
    (case (cur-type p)
      (:punct
       (cond
         ((punct? p "{") (parse-block p))
         ((punct? p ";") (advance p) (finish (make-empty-statement) start (parser-prev-end p)))
         (t (parse-expression-statement p))))
      (:name
       (let ((n (cur-val p)))
         (cond
           ;; an escaped keyword is never a keyword — it is a plain identifier
           ((cur-escaped-p p) (parse-expression-or-labeled p))
           ((string= n "var") (parse-variable-statement p :var))
           ((string= n "if") (parse-if p))
           ((string= n "for") (parse-for p))
           ((string= n "while") (parse-while p))
           ((string= n "do") (parse-do-while p))
           ((string= n "switch") (parse-switch p))
           ((string= n "return") (parse-return p))
           ((string= n "throw") (parse-throw p))
           ((string= n "try") (parse-try p))
           ((string= n "break") (parse-break-continue p t))
           ((string= n "continue") (parse-break-continue p nil))
           ((string= n "with") (parse-with p))
           ((string= n "debugger") (advance p) (consume-semicolon p)
            (finish (make-debugger-statement) start (parser-prev-end p)))
           ((string= n "function") (syntax-error p "function declaration not allowed here"))
           ((string= n "class") (parse-class p t))
           (t (parse-expression-or-labeled p)))))
      (t (parse-expression-statement p)))))

(defun parse-block (p)
  (let ((start (cur-start p)))
    (eat-punct p "{")
    (let ((body (parse-statements-until p "}")))
      (eat-punct p "}")
      (finish (make-block-statement :body body) start (parser-prev-end p)))))

(defun parse-expression-or-labeled (p)
  (let ((start (cur-start p)))
    (if (and (name-tok? p) (not (reserved-word-p p (cur-val p)))
             (let ((n (peek p))) (and (eq (token-type n) :punct) (string= (token-value n) ":"))))
        (let ((label (cur-val p)))
          (when (member label (parser-labels p) :test #'string=)
            (syntax-error p "label '~a' has already been declared" label))
          (advance p) (advance p)              ; name :
          (let ((body (let ((old (parser-labels p)))
                        (setf (parser-labels p) (cons label old))
                        (unwind-protect (parse-statement-or-decl p)
                          (setf (parser-labels p) old)))))
            (finish (make-labeled-statement :label label :body body) start (parser-prev-end p))))
        (parse-expression-statement p))))

(defun parse-expression-statement (p)
  (let ((start (cur-start p))
        (expr (parse-expression p)))
    (consume-semicolon p)
    (finish (make-expression-statement :expression expr) start (parser-prev-end p))))

(defun consume-semicolon (p)
  "Automatic Semicolon Insertion: consume a `;`, or accept ASI at }/EOF/newline."
  (cond
    ((punct? p ";") (advance p))
    ((or (punct? p "}") (eq (cur-type p) :eof) (nl-before-p p)) nil)
    (t (syntax-error p "missing semicolon before ~a" (describe-cur p)))))

(defun parse-variable-statement (p kind)
  (let ((start (cur-start p))
        (decl (parse-variable-declaration p kind)))
    (consume-semicolon p)
    (finish decl start (parser-prev-end p))))

(defun parse-variable-declaration (p kind &optional no-in)
  "Parse `var/let/const` declarator list (without the trailing semicolon)."
  (let ((start (cur-start p)))
    (advance p)                                ; kind keyword
    (let ((decls '()))
      (loop
        (let* ((dstart (cur-start p))
               (id (parse-binding-target p))
               (init nil))
          ;; a LexicalDeclaration may not bind `let` (§14.3.1)
          (when (and (member kind '(:let :const))
                     (member "let" (binding-bound-names id) :test #'string=))
            (syntax-error p "'let' is disallowed as a lexically-bound name"))
          (when (punct? p "=")
            (advance p)
            (setf init (if no-in (parse-assignment-no-in p) (parse-assignment p))))
          ;; a for-in/of ForBinding (no-in) may be a pattern without an initializer
          (when (and (null init) (not no-in) (not (identifier-p id)))
            (syntax-error p "destructuring declaration must have an initializer"))
          (when (and (null init) (eq kind :const) (not no-in))
            (syntax-error p "const declaration must have an initializer"))
          (push (finish (make-variable-declarator :id id :init init) dstart (parser-prev-end p))
                decls))
        (if (punct? p ",") (advance p) (return)))
      (finish (make-variable-declaration :kind kind :declarations (nreverse decls))
              start (parser-prev-end p)))))

(defun parse-if (p)
  (let ((start (cur-start p)))
    (advance p) (eat-punct p "(")
    (let ((test (parse-expression p)))
      (eat-punct p ")")
      (let ((cons (parse-statement p))
            (alt nil))
        (when (name? p "else") (advance p) (setf alt (parse-statement p)))
        (finish (make-if-statement :test test :consequent cons :alternate alt)
                start (parser-prev-end p))))))

(defun parse-while (p)
  (let ((start (cur-start p)))
    (advance p) (eat-punct p "(")
    (let ((test (parse-expression p)))
      (eat-punct p ")")
      (let ((body (with-iteration p (parse-statement p))))
        (finish (make-while-statement :test test :body body) start (parser-prev-end p))))))

(defun parse-do-while (p)
  (let ((start (cur-start p)))
    (advance p)
    (let ((body (with-iteration p (parse-statement p))))
      (eat-name p "while") (eat-punct p "(")
      (let ((test (parse-expression p)))
        (eat-punct p ")")
        (when (punct? p ";") (advance p))
        (finish (make-do-while-statement :body body :test test) start (parser-prev-end p))))))

(defun parse-for (p)
  (let ((start (cur-start p)) (await nil))
    (advance p)
    (when (name? p "await") (advance p) (setf await t))   ; for-await (async ctx)
    (eat-punct p "(")
    (let ((init nil) (kind nil))
      (cond
        ((punct? p ";") nil)                   ; empty init
        ((or (name? p "var") (name? p "const") (name-let-decl-p p))
         (setf kind (intern (string-upcase (cur-val p)) :keyword))
         (setf init (parse-variable-declaration p kind t)))
        (t (setf init (parse-expression-no-in p))))
      (cond
        ((name? p "in")
         (check-for-binding p init kind nil)
         (advance p)
         (let ((right (parse-expression p)))
           (eat-punct p ")")
           (finish (make-for-in-statement :left (for-target p init) :right right
                                          :body (with-iteration p (parse-statement p)))
                   start (parser-prev-end p))))
        ((name? p "of")
         (check-for-binding p init kind t)
         (advance p)
         (let ((right (parse-assignment p)))
           (eat-punct p ")")
           (finish (make-for-of-statement :left (for-target p init) :right right
                                          :await await
                                          :body (with-iteration p (parse-statement p)))
                   start (parser-prev-end p))))
        (t
         (eat-punct p ";")
         (let ((test (unless (punct? p ";") (parse-expression p))))
           (eat-punct p ";")
           (let ((update (unless (punct? p ")") (parse-expression p))))
             (eat-punct p ")")
             (finish (make-for-statement :init init :test test :update update
                                         :body (with-iteration p (parse-statement p)))
                     start (parser-prev-end p)))))))))

(defun for-target (p init)
  "Normalize a for-in/of left side (a declaration or an assignment target)."
  (if (variable-declaration-p init)
      init
      (check-assignment-target p (expr-to-pattern p init))))

(defun check-for-binding (p init kind for-of)
  "Early errors for a for-in/of head (§14.7.5). KIND is :var/:let/:const or NIL."
  (when (variable-declaration-p init)
    (let ((decls (variable-declaration-declarations init)))
      (when (> (length decls) 1)
        (syntax-error p "for-~a must declare a single binding" (if for-of "of" "in")))
      (let ((d (first decls)))
        (when (variable-declarator-init d)
          ;; only sloppy `for (var x = ... in ...)` is allowed (Annex B); never for-of/lexical
          (unless (and (not for-of) (eq kind :var) (not (parser-strict p)))
            (syntax-error p "for-~a binding may not have an initializer"
                          (if for-of "of" "in"))))
        ;; a lexical for-binding's bound names must be unique (§14.7.5)
        (when (member kind '(:let :const))
          (let ((names (binding-bound-names (variable-declarator-id d))))
            (unless (= (length names) (length (remove-duplicates names :test #'string=)))
              (syntax-error p "duplicate binding name in for-~a head"
                            (if for-of "of" "in"))))))))
  ;; `for (let ... of ...)` / `for (async of ...)` head restriction: an expression
  ;; left side must be a valid assignment target (checked by expr-to-pattern)
  (unless (or (variable-declaration-p init) init)
    (when for-of (syntax-error p "for-of requires a binding"))))

(defun parse-switch (p)
  (let ((start (cur-start p)))
    (advance p) (eat-punct p "(")
    (let ((disc (parse-expression p)))
      (eat-punct p ")") (eat-punct p "{")
      (let ((cases '()) (seen-default nil)
            (old (parser-in-switch p)))
        (setf (parser-in-switch p) t)
        (unwind-protect
             (loop until (punct? p "}")
                   do (let ((cstart (cur-start p)) (test nil))
                        (cond ((name? p "case") (advance p) (setf test (parse-expression p)))
                              ((name? p "default")
                               (when seen-default (syntax-error p "multiple default clauses"))
                               (setf seen-default t) (advance p))
                              (t (syntax-error p "expected case or default")))
                        (eat-punct p ":")
                        (let ((body '()))
                          (loop until (or (punct? p "}") (name? p "case") (name? p "default"))
                                do (push (parse-statement-or-decl p) body))
                          (push (finish (make-switch-case :test test :consequent (nreverse body))
                                        cstart (parser-prev-end p))
                                cases))))
          (setf (parser-in-switch p) old))
        (eat-punct p "}")
        (finish (make-switch-statement :discriminant disc :cases (nreverse cases))
                start (parser-prev-end p))))))

(defun parse-return (p)
  (let ((start (cur-start p)))
    (unless (parser-in-function p) (syntax-error p "'return' outside of a function"))
    (advance p)
    (let ((arg (unless (or (punct? p ";") (punct? p "}") (eq (cur-type p) :eof) (nl-before-p p))
                 (parse-expression p))))
      (consume-semicolon p)
      (finish (make-return-statement :argument arg) start (parser-prev-end p)))))

(defun parse-throw (p)
  (let ((start (cur-start p)))
    (advance p)
    (when (nl-before-p p) (syntax-error p "illegal newline after throw"))
    (let ((arg (parse-expression p)))
      (consume-semicolon p)
      (finish (make-throw-statement :argument arg) start (parser-prev-end p)))))

(defun parse-try (p)
  (let ((start (cur-start p)))
    (advance p)
    (let ((block (parse-block p)) (handler nil) (finalizer nil))
      (when (name? p "catch")
        (let ((cstart (cur-start p)))
          (advance p)
          (let ((param nil))
            (when (punct? p "(")
              (advance p) (setf param (parse-binding-target p)) (eat-punct p ")"))
            (setf handler (finish (make-catch-clause :param param :body (parse-block p))
                                  cstart (parser-prev-end p))))))
      (when (name? p "finally") (advance p) (setf finalizer (parse-block p)))
      (unless (or handler finalizer) (syntax-error p "missing catch or finally after try"))
      (finish (make-try-statement :block block :handler handler :finalizer finalizer)
              start (parser-prev-end p)))))

(defun parse-break-continue (p break-p)
  (let ((start (cur-start p)))
    (advance p)
    (let ((label nil))
      (when (and (name-tok? p) (not (nl-before-p p)) (not (reserved-word-p p (cur-val p))))
        (setf label (cur-val p)) (advance p))
      (consume-semicolon p)
      (if label
          (unless (member label (parser-labels p) :test #'string=)
            (syntax-error p "undefined label '~a'" label))
          (cond (break-p (unless (or (parser-in-iteration p) (parser-in-switch p))
                           (syntax-error p "illegal break")))
                (t (unless (parser-in-iteration p) (syntax-error p "illegal continue")))))
      (if break-p
          (finish (make-break-statement :label label) start (parser-prev-end p))
          (finish (make-continue-statement :label label) start (parser-prev-end p))))))

(defun parse-with (p)
  (when (parser-strict p) (syntax-error p "'with' is not allowed in strict mode"))
  (let ((start (cur-start p)))
    (advance p) (eat-punct p "(")
    (let ((obj (parse-expression p)))
      (eat-punct p ")")
      (finish (make-with-statement :object obj :body (parse-statement p))
              start (parser-prev-end p)))))

;;; --- expressions (Pratt + recursive descent) --------------------------------

(defun parse-expression (p)
  "Expression, possibly a comma SequenceExpression."
  (let ((start (cur-start p))
        (first (parse-assignment p)))
    (if (punct? p ",")
        (let ((exprs (list first)))
          (loop while (punct? p ",") do (advance p) (push (parse-assignment p) exprs))
          (finish (make-sequence-expression :expressions (nreverse exprs))
                  start (parser-prev-end p)))
        first)))

(defun parse-expression-no-in (p)
  (let ((old (parser-allow-in p)))
    (setf (parser-allow-in p) nil)
    (unwind-protect (parse-expression p) (setf (parser-allow-in p) old))))

(defun parse-assignment-no-in (p)
  (let ((old (parser-allow-in p)))
    (setf (parser-allow-in p) nil)
    (unwind-protect (parse-assignment p) (setf (parser-allow-in p) old))))

(defparameter *assign-ops*
  '("=" "+=" "-=" "*=" "/=" "%=" "**=" "<<=" ">>=" ">>>=" "&=" "|=" "^="))

(defun parse-assignment (p)
  (let ((start (cur-start p)))
    ;; yield (in generator)
    (when (and (parser-allow-yield p) (name? p "yield"))
      (when (parser-in-parameters p)
        (syntax-error p "yield is not allowed in generator parameters"))
      (return-from parse-assignment (parse-yield p)))
    ;; arrow fast paths
    (let ((arrow (try-parse-arrow p start)))
      (when arrow (return-from parse-assignment arrow)))
    (let ((left (parse-conditional p)))
      (if (and (eq (cur-type p) :punct) (member (cur-val p) *assign-ops* :test #'string=))
          (let ((op (cur-val p)))
            (advance p)
            (let ((target (if (string= op "=")
                              (check-assignment-target p (expr-to-pattern p left))
                              (check-simple-target p left))))
              (finish (make-assignment-expression :operator op :left target
                                                  :right (parse-assignment p))
                      start (parser-prev-end p))))
          left))))

(defun check-simple-target (p node)
  (unless (or (identifier-p node) (member-expression-p node))
    (syntax-error p "invalid assignment target"))
  (check-assignment-target p node))

(defun check-assignment-target (p node)
  "Apply strict-mode restrictions recursively to an assignment target or pattern."
  (when (parser-strict p)
    (labels ((walk (target)
               (typecase target
                 (identifier
                  (when (member (identifier-name target) '("eval" "arguments") :test #'string=)
                    (syntax-error p "'~a' cannot be assigned in strict mode"
                                  (identifier-name target))))
                 (member-expression nil)
                 (assignment-pattern (walk (assignment-pattern-left target)))
                 (rest-element (walk (rest-element-argument target)))
                 (array-pattern (dolist (element (array-pattern-elements target))
                                  (when element (walk element))))
                 (object-pattern
                  (dolist (property (object-pattern-properties target))
                    (if (rest-element-p property)
                        (walk property)
                        (walk (property-value property))))))))
      (walk node)))
  node)

(defun parse-yield (p)
  (let ((start (cur-start p)))
    (advance p)
    (let ((delegate nil) (arg nil))
      (when (and (punct? p "*") (not (nl-before-p p))) (advance p) (setf delegate t))
      (unless (or (nl-before-p p) (punct? p ")") (punct? p "]") (punct? p "}")
                  (punct? p ",") (punct? p ";") (punct? p ":") (eq (cur-type p) :eof))
        (setf arg (parse-assignment p)))
      (when (and delegate (null arg)) (syntax-error p "yield* requires an argument"))
      (finish (make-yield-expression :argument arg :delegate delegate)
              start (parser-prev-end p)))))

(defun parse-conditional (p)
  (let ((start (cur-start p))
        (test (parse-binary p 0)))
    (if (punct? p "?")
        (progn
          (advance p)
          (let ((cons (parse-assignment-allow-in p)))
            (eat-punct p ":")
            (let ((alt (parse-assignment p)))
              (finish (make-conditional-expression :test test :consequent cons :alternate alt)
                      start (parser-prev-end p)))))
        test)))

(defun parse-assignment-allow-in (p)
  (let ((old (parser-allow-in p)))
    (setf (parser-allow-in p) t)
    (unwind-protect (parse-assignment p) (setf (parser-allow-in p) old))))

(defparameter *bin-prec*
  '(("||" . 1) ("&&" . 2) ("|" . 3) ("^" . 4) ("&" . 5)
    ("==" . 6) ("!=" . 6) ("===" . 6) ("!==" . 6)
    ("<" . 7) (">" . 7) ("<=" . 7) (">=" . 7)
    ("<<" . 8) (">>" . 8) (">>>" . 8)
    ("+" . 9) ("-" . 9) ("*" . 10) ("/" . 10) ("%" . 10)))

(defun cur-bin-op (p)
  "Return (op . prec) if CUR is a binary operator usable now, else NIL."
  (cond
    ((eq (cur-type p) :punct)
     (let ((e (assoc (cur-val p) *bin-prec* :test #'string=)))
       (and e (cons (car e) (cdr e)))))
    ((name? p "instanceof") (cons "instanceof" 7))
    ((and (name? p "in") (parser-allow-in p)) (cons "in" 7))
    (t nil)))

(defun parse-binary (p min-prec)
  (let ((start (cur-start p))
        (left (parse-exponent p)))
    (loop
      (let ((opinfo (cur-bin-op p)))
        (unless (and opinfo (>= (cdr opinfo) min-prec)) (return left))
        (let ((op (car opinfo)) (prec (cdr opinfo)))
          (advance p)
          (let ((right (parse-binary p (1+ prec))))
            (setf left (finish (if (member op '("&&" "||") :test #'string=)
                                   (make-logical-expression :operator op :left left :right right)
                                   (make-binary-expression :operator op :left left :right right))
                               start (parser-prev-end p)))))))))

(defun parse-exponent (p)
  (let ((start (cur-start p))
        (left (parse-unary p)))
    (if (punct? p "**")
        (progn
          ;; a bare (unparenthesized) UnaryExpression is not a valid ** base (§13.6)
          (when (and (unary-expression-p left) (not (node-parenthesized left)))
            (syntax-error p "unary operand of ** must be parenthesized"))
          (advance p)
          (finish (make-binary-expression :operator "**" :left left :right (parse-exponent p))
                  start (parser-prev-end p)))
        left)))

(defparameter *unary-ops* '("+" "-" "!" "~"))
(defparameter *unary-kw* '("typeof" "void" "delete"))

(defun parse-unary (p)
  (let ((start (cur-start p)))
    (cond
      ((and (eq (cur-type p) :punct) (member (cur-val p) *unary-ops* :test #'string=))
       (let ((op (cur-val p))) (advance p)
         (finish (make-unary-expression :operator op :argument (parse-unary p))
                 start (parser-prev-end p))))
      ((and (name-tok? p) (member (cur-val p) *unary-kw* :test #'string=))
       (let ((op (cur-val p))) (advance p)
         (let ((arg (parse-unary p)))
           (when (and (parser-strict p) (string= op "delete") (identifier-p arg))
             (syntax-error p "cannot delete a variable in strict mode"))
           (finish (make-unary-expression :operator op :argument arg) start (parser-prev-end p)))))
      ((and (eq (cur-type p) :punct) (member (cur-val p) '("++" "--") :test #'string=))
       (let ((op (cur-val p))) (advance p)
         (finish (make-update-expression :operator op :prefix t
                                         :argument (check-simple-target p (parse-unary p)))
                 start (parser-prev-end p))))
      ((and (parser-allow-await p) (name? p "await"))
       (when (parser-in-parameters p)
         (syntax-error p "await is not allowed in async function parameters"))
       (advance p)
       (finish (make-await-expression :argument (parse-unary p)) start (parser-prev-end p)))
      (t (parse-postfix p)))))

(defun parse-postfix (p)
  (let ((start (cur-start p))
        (expr (parse-lhs p)))
    (if (and (not (nl-before-p p)) (eq (cur-type p) :punct)
             (member (cur-val p) '("++" "--") :test #'string=))
        (let ((op (cur-val p)))
          (check-simple-target p expr)
          (advance p)
          (finish (make-update-expression :operator op :prefix nil :argument expr)
                  start (parser-prev-end p)))
        expr)))

;;; --- left-hand-side: new / call / member ------------------------------------

(defun parse-lhs (p)
  (let ((start (cur-start p)))
    (let ((expr (if (name? p "new") (parse-new p) (parse-primary p))))
      (parse-call-member-tail p expr start))))

(defun parse-new (p)
  (let ((start (cur-start p)))
    (advance p)                                ; new
    (when (punct? p ".")                       ; new.target
      (advance p)
      (unless (name? p "target") (syntax-error p "expected 'target' after 'new.'"))
      (unless (parser-in-function p)
        (syntax-error p "new.target is only allowed inside functions"))
      (advance p)
      (return-from parse-new
        (finish (make-meta-property :meta "new" :property "target") start (parser-prev-end p))))
    (let ((callee (if (name? p "new") (parse-new p)
                      (parse-member-only p (parse-primary p) start))))
      ;; SuperCall is a CallExpression grammar form, never a NewExpression callee.
      ;; A SuperProperty remains valid here (`new super.Factory()`).
      (when (super-node-p callee)
        (syntax-error p "'new super()' is not valid"))
      (let ((args (if (punct? p "(") (parse-arguments p) '())))
        (finish (make-new-expression :callee callee :arguments args) start (parser-prev-end p))))))

(defun parse-member-only (p expr start)
  "Member accesses (no calls) — for the callee of `new`."
  (loop
    (cond
      ((punct? p ".") (advance p)
       (setf expr (finish (make-member-expression :object expr :property (parse-property-name p)
                                                  :computed nil)
                          start (parser-prev-end p))))
      ((punct? p "[") (advance p)
       (let ((prop (with-in p (parse-expression p)))) (eat-punct p "]")
         (setf expr (finish (make-member-expression :object expr :property prop :computed t)
                            start (parser-prev-end p)))))
      ((eq (cur-type p) :template)
       (setf expr (finish (make-tagged-template :tag expr :quasi (parse-template p t))
                          start (parser-prev-end p))))
      (t (return expr)))))

(defun parse-call-member-tail (p expr start)
  (loop
    (cond
      ((punct? p ".") (advance p)
       (setf expr (finish (make-member-expression :object expr :property (parse-property-name p)
                                                  :computed nil)
                          start (parser-prev-end p))))
      ((punct? p "[") (advance p)
       (let ((prop (with-in p (parse-expression p)))) (eat-punct p "]")
         (setf expr (finish (make-member-expression :object expr :property prop :computed t)
                            start (parser-prev-end p)))))
      ((punct? p "(")
       (setf expr (finish (make-call-expression :callee expr :arguments (parse-arguments p))
                          start (parser-prev-end p))))
      ((eq (cur-type p) :template)
       (setf expr (finish (make-tagged-template :tag expr :quasi (parse-template p t))
                          start (parser-prev-end p))))
      (t (return expr)))))

(defun parse-property-name (p)
  "An identifier-name after `.` (any name, reserved words allowed)."
  (unless (name-tok? p) (syntax-error p "expected property name after '.'"))
  (let ((name (cur-val p)) (start (cur-start p)))
    (advance p)
    (finish (make-identifier :name name) start (parser-prev-end p))))

(defun parse-arguments (p)
  (eat-punct p "(")
  (with-in p                                   ; `in` is allowed inside argument lists
    (let ((args '()))
      (loop until (punct? p ")")
            do (if (punct? p "...")
                   (let ((s (cur-start p))) (advance p)
                     (push (finish (make-spread-element :argument (parse-assignment p))
                                   s (parser-prev-end p))
                           args))
                   (push (parse-assignment p) args))
               (if (punct? p ",") (advance p) (return)))
      (eat-punct p ")")
      (nreverse args))))

;;; --- primary expressions ----------------------------------------------------

(defun parse-primary (p)
  (let ((start (cur-start p)))
    ;; regex re-scan: a `/` here begins a RegularExpressionLiteral
    (when (and (eq (cur-type p) :punct) (member (cur-val p) '("/" "/=") :test #'string=))
      (setf (parser-cur p) (reread-regexp (parser-lexer p) (parser-cur p))))
    (case (cur-type p)
      (:num (let ((v (cur-val p))) (advance p)
              (finish (make-literal :value v :kind :number) start (parser-prev-end p))))
      (:bigint (let ((v (cur-val p))) (advance p)
                 (finish (make-literal :value v :kind :bigint) start (parser-prev-end p))))
      (:string (let ((v (cur-val p))) (advance p)
                 (finish (make-literal :value v :kind :string) start (parser-prev-end p))))
      (:regexp (let ((pat (cur-val p)) (flags (token-raw (parser-cur p)))) (advance p)
                 (finish (make-reg-exp-literal :pattern pat :flags flags) start (parser-prev-end p))))
      (:template (parse-template p))
      (:punct
       (cond
         ((punct? p "(") (parse-paren-or-arrow-expr p))
         ((punct? p "[") (parse-array-literal p))
         ((punct? p "{") (parse-object-literal p))
         (t (syntax-error p "unexpected ~a" (describe-cur p)))))
      (:name (parse-primary-name p))
      (t (syntax-error p "unexpected ~a" (describe-cur p))))))

(defun parse-primary-name (p)
  (let ((start (cur-start p)) (name (cur-val p)))
    (cond
      ((string= name "this") (advance p)
       (finish (make-this-expression) start (parser-prev-end p)))
      ((string= name "super")
       (advance p)
       (cond
         ((punct? p "(")
          (unless (parser-allow-super-call p)
            (syntax-error p "'super()' is only allowed inside derived constructors")))
         ((or (punct? p ".") (punct? p "["))
          (unless (parser-allow-super-property p)
            (syntax-error p "super property access is only allowed inside methods")))
         (t (syntax-error p "'super' must be followed by a member access or arguments")))
       (finish (make-super-node) start (parser-prev-end p)))
      ((string= name "null") (advance p)
       (finish (make-literal :value +null+ :kind :null) start (parser-prev-end p)))
      ((string= name "true") (advance p)
       (finish (make-literal :value +true+ :kind :boolean) start (parser-prev-end p)))
      ((string= name "false") (advance p)
       (finish (make-literal :value +false+ :kind :boolean) start (parser-prev-end p)))
      ((string= name "function") (parse-function-expression p nil))
      ((string= name "class") (parse-class p nil))
      ;; `import.meta` (module meta-property). Dynamic `import(...)` is still out of
      ;; the v1 tier and rejected below.
      ((and (string= name "import")
            (let ((n (peek p))) (and (eq (token-type n) :punct) (string= (token-value n) "."))))
       ;; keywords in a meta-property must not carry an escape (`import` etc.).
       (when (cur-escaped-p p)
         (syntax-error p "'import' in import.meta must not contain an escape sequence"))
       (advance p)                       ; consume `import`
       (advance p)                       ; consume `.`
       (unless (and (eq (cur-type p) :name) (string= (cur-val p) "meta"))
         (syntax-error p "expected 'meta' after 'import.'"))
       (when (cur-escaped-p p)
         (syntax-error p "'meta' in import.meta must not contain an escape sequence"))
       (unless (eq (parser-source-type p) :module)
         (syntax-error p "import.meta is only valid in a module"))
       (advance p)                       ; consume `meta`
       (finish (make-meta-property :meta "import" :property "meta") start (parser-prev-end p)))
      ((and (string= name "async") (let ((n (peek p)))
                                     (and (eq (token-type n) :name)
                                          (string= (token-value n) "function")
                                          (not (token-nl-before n)))))
       (parse-function-expression p t))
      ((member name '("in" "instanceof" "new" "delete" "typeof" "void" "return"
                      "if" "else" "for" "while" "do" "switch" "case" "default"
                      "break" "continue" "var" "const" "with" "throw" "try" "catch"
                      "finally" "debugger" "export" "extends" "import" "catch"
                      "enum") :test #'string=)
       ;; `import` as an expression = dynamic import / import.meta — not in the v1
       ;; tier; reject cleanly (also rejects the dynamic-import negative-parse corpus).
       (syntax-error p "unexpected reserved word '~a'" name))
      (t (advance p)
         (finish (make-identifier :name name) start (parser-prev-end p))))))

(defun parse-template (p &optional tagged)
  "Assemble a TemplateLiteral. Untagged templates reject invalid escapes (cooked=nil);
tagged templates allow them (TRV survives, TV = undefined)."
  (let ((start (cur-start p))
        (quasis '()) (exprs '()))
    (flet ((check-cooked (tok)
             (when (and (not tagged) (null (token-value tok)))
               (syntax-error p "invalid escape sequence in template literal"))))
    (let ((head (parser-cur p)))
      (check-cooked head)
      (advance p)
      (push (te head) quasis)
      (when (eq (token-tmpl-part head) :full)
        (return-from parse-template
          (finish (make-template-literal :quasis (nreverse quasis) :expressions nil)
                  start (parser-prev-end p))))
      ;; head ended at ${ : parse expr, then `}`->reread middle/tail
      (loop
        (push (with-in p (parse-expression p)) exprs)
        (unless (punct? p "}") (syntax-error p "expected '}' in template"))
        ;; cur is the `}`; resume the template from just past it via reread-template,
        ;; then lex the token following the middle/tail into cur.
        (let* ((lx (parser-lexer p))
               (cont (progn (setf (lexer-pos lx) (1+ (token-start (parser-cur p))))
                            (reread-template lx))))
          (check-cooked cont)
          (setf (parser-prev-end p) (token-end cont)
                (parser-cur p) (next-token lx (parser-strict p)))
          (push (te cont) quasis)
          (when (eq (token-tmpl-part cont) :tail) (return))))
      (finish (make-template-literal :quasis (nreverse quasis) :expressions (nreverse exprs))
              start (parser-prev-end p))))))

(defun te (tok)
  (finish (make-template-element :cooked (token-value tok) :raw (token-raw tok)
                                 :tail (member (token-tmpl-part tok) '(:tail :full)))
          (token-start tok) (token-end tok)))

(defun parse-array-literal (p)
  (let ((start (cur-start p)))
    (eat-punct p "[")
    (with-in p                                 ; `in` is allowed inside array literals
     (let ((elts '()))
      (loop until (punct? p "]")
            do (cond
                 ((punct? p ",") (advance p) (push nil elts))   ; hole
                 ((punct? p "...")
                  (let ((s (cur-start p))) (advance p)
                    (push (finish (make-spread-element :argument (parse-assignment p))
                                  s (parser-prev-end p))
                          elts))
                  (unless (punct? p "]") (eat-punct p ",")))
                 (t (push (parse-assignment p) elts)
                    (unless (punct? p "]") (eat-punct p ",")))))
      (eat-punct p "]")
      (finish (make-array-expression :elements (nreverse elts)) start (parser-prev-end p))))))

(defun parse-object-literal (p)
  ;; NOTE: the duplicate-__proto__ early error is deferred — it applies to object
  ;; LITERALS but not to object destructuring PATTERNS, and the cover grammar parses
  ;; both as an object-expression first. A correct check belongs in a post-refinement
  ;; pass (future milestone), not here.
  (let ((start (cur-start p)))
    (eat-punct p "{")
    (with-in p                                 ; `in` is allowed inside object literals
     (let ((props '()))
      (loop until (punct? p "}")
            do (push (parse-object-member p) props)
               (unless (punct? p "}") (eat-punct p ",")))
      (eat-punct p "}")
      (finish (make-object-expression :properties (nreverse props)) start (parser-prev-end p))))))

(defun parse-object-member (p)
  (let ((start (cur-start p)))
    (when (punct? p "...")                     ; object spread (ES2018, accepted)
      (advance p)
      (return-from parse-object-member
        (finish (make-spread-element :argument (parse-assignment p)) start (parser-prev-end p))))
    (let ((async nil) (gen nil) (kind :init))
      (when (name? p "async")
        (let ((n (peek p)))
          (unless (or (token-nl-before n) (and (eq (token-type n) :punct)
                                               (member (token-value n) '(":" "," "}" "(" "=") :test #'string=)))
            (setf async t) (advance p))))
      (when (punct? p "*") (setf gen t) (advance p))
      (when (and (or (name? p "get") (name? p "set")) (not async) (not gen))
        (let ((n (peek p)))
          (unless (or (and (eq (token-type n) :punct)
                           (member (token-value n) '(":" "," "}" "(" "=") :test #'string=)))
            (setf kind (if (name? p "get") :get :set)) (advance p))))
      (multiple-value-bind (key computed) (parse-property-key p)
        (cond
          ((punct? p "(")                      ; method
           (let ((fn (parse-method-tail p async gen)))
             (check-accessor-arity p kind (function-node-params fn))
             (finish (make-property :key key :value fn :kind (if (member kind '(:get :set)) kind :init)
                                    :computed computed :method (eq kind :init))
                     start (parser-prev-end p))))
          ((member kind '(:get :set)) (syntax-error p "accessor must be a method"))
          ((or async gen) (syntax-error p "a generator/async object member must be a method"))
          ((punct? p ":")                      ; key: value
           (advance p)
           (finish (make-property :key key :value (parse-assignment p) :kind :init
                                  :computed computed)
                   start (parser-prev-end p)))
          ((punct? p "=")                      ; cover: shorthand with default (pattern only)
           (advance p)
           (let ((val (finish (make-assignment-pattern :left key :right (parse-assignment p))
                              start (parser-prev-end p))))
             (finish (make-property :key key :value val :kind :init :shorthand t) start
                     (parser-prev-end p))))
          (t                                   ; shorthand { x }
           (unless (identifier-p key) (syntax-error p "invalid shorthand property"))
           (finish (make-property :key key :value key :kind :init :shorthand t)
                   start (parser-prev-end p))))))))

(defun parse-property-key (p)
  "Return (values key computed?)."
  (cond
    ((punct? p "[") (advance p)
     (let ((e (with-in p (parse-assignment p)))) (eat-punct p "]") (values e t)))
    ((eq (cur-type p) :string)
     (let ((s (cur-start p)) (v (cur-val p))) (advance p)
       (values (finish (make-literal :value v :kind :string) s (parser-prev-end p)) nil)))
    ((eq (cur-type p) :num)
     (let ((s (cur-start p)) (v (cur-val p))) (advance p)
       (values (finish (make-literal :value v :kind :number) s (parser-prev-end p)) nil)))
    ((eq (cur-type p) :bigint)
     (let ((s (cur-start p)) (v (cur-val p))) (advance p)
       (values (finish (make-literal :value v :kind :bigint) s (parser-prev-end p)) nil)))
    ((name-tok? p)
     (let ((s (cur-start p)) (v (cur-val p))) (advance p)
       (values (finish (make-identifier :name v) s (parser-prev-end p)) nil)))
    (t (syntax-error p "expected property name"))))

;;; --- functions & classes ----------------------------------------------------

(defun parse-function-declaration (p async)
  (parse-function p async t))
(defun parse-function-expression (p async)
  (parse-function p async nil))

(defun parse-function (p async declaration &optional allow-anon)
  (let ((start (cur-start p)))
    (when async (advance p))                   ; async
    (advance p)                                ; function
    (let ((gen (when (punct? p "*") (advance p) t))
          (id nil))
      (when (name-tok? p)
        (setf id (parse-binding-identifier p)))
      ;; `export default function(){}` is an anonymous declaration (ALLOW-ANON).
      (when (and declaration (null id) (not allow-anon))
        (syntax-error p "function declaration requires a name"))
      (let ((old-y (parser-allow-yield p)) (old-a (parser-allow-await p))
            (old-f (parser-in-function p)) (old-i (parser-in-iteration p))
            (old-s (parser-in-switch p)) (old-strict (parser-strict p))
            (old-labels (parser-labels p))
            (old-super-property (parser-allow-super-property p))
            (old-super-call (parser-allow-super-call p)))
        (setf (parser-allow-yield p) gen (parser-allow-await p) async
              (parser-in-function p) t (parser-in-iteration p) nil (parser-in-switch p) nil
              (parser-labels p) nil
              (parser-allow-super-property p) nil (parser-allow-super-call p) nil)
        (unwind-protect
             (let* ((params (parse-params p))
                    (body (parse-function-body p)))    ; may set strict via prologue
               (when (and (function-body-has-use-strict-directive-p body)
                          (not (simple-params-p params)))
                 (syntax-error p "a 'use strict' directive is not allowed with non-simple parameters"))
               (check-parameter-body-lexical-conflicts p params body)
               (when (parser-strict p)
                 (check-strict-parameter-names p params)
                 (when id
                   (check-strict-binding-name p (identifier-name id))))
               ;; params must be unique if strict, generator, async, or non-simple
               (when (or (parser-strict p) gen async (not (simple-params-p params)))
                 (check-unique-params p params))
               (finish (make-function-node :id id :params params :body body :generator gen
                                           :async async :declaration declaration)
                       start (parser-prev-end p)))
          (setf (parser-allow-yield p) old-y (parser-allow-await p) old-a
                (parser-in-function p) old-f (parser-in-iteration p) old-i
                (parser-in-switch p) old-s (parser-strict p) old-strict
                (parser-labels p) old-labels
                (parser-allow-super-property p) old-super-property
                (parser-allow-super-call p) old-super-call))))))

(defun parse-method-tail (p async gen &key allow-super-call)
  "Parse `(params) { body }` for an object/class method with the given flags.
Method parameters must always be unique."
  (let ((start (cur-start p))
        (old-y (parser-allow-yield p)) (old-a (parser-allow-await p))
        (old-f (parser-in-function p)) (old-i (parser-in-iteration p)) (old-s (parser-in-switch p))
        (old-strict (parser-strict p)) (old-labels (parser-labels p))
        (old-super-property (parser-allow-super-property p))
        (old-super-call (parser-allow-super-call p)))
    (setf (parser-allow-yield p) gen (parser-allow-await p) async
          (parser-in-function p) t (parser-in-iteration p) nil (parser-in-switch p) nil
          (parser-labels p) nil (parser-allow-super-property p) t
          (parser-allow-super-call p) allow-super-call)
    (unwind-protect
         (let* ((params (parse-params p)) (body (parse-function-body p)))
           (when (and (function-body-has-use-strict-directive-p body)
                      (not (simple-params-p params)))
             (syntax-error p "a 'use strict' directive is not allowed with non-simple parameters"))
           (check-parameter-body-lexical-conflicts p params body)
           (when (parser-strict p)
             (check-strict-parameter-names p params))
           (check-unique-params p params)
           (finish (make-function-node :params params :body body :generator gen :async async)
                   start (parser-prev-end p)))
      (setf (parser-allow-yield p) old-y (parser-allow-await p) old-a
            (parser-in-function p) old-f (parser-in-iteration p) old-i (parser-in-switch p) old-s
            (parser-strict p) old-strict (parser-labels p) old-labels
            (parser-allow-super-property p) old-super-property
            (parser-allow-super-call p) old-super-call))))

(defun parse-function-body (p)
  "Parse `{ ... }`. May set the parser's strict flag via a directive prologue; the
caller is responsible for restoring it (functions/methods/arrows do so)."
  (let ((start (cur-start p)))
    (eat-punct p "{")
    (let ((body (parse-statements-until p "}" t)))
      (eat-punct p "}")
      (finish (make-block-statement :body body) start (parser-prev-end p)))))

(defun function-body-has-use-strict-directive-p (body)
  "True when BODY's own Directive Prologue contains a use-strict directive."
  (loop for statement in (block-statement-body body)
        while (and (expression-statement-p statement)
                   (expression-statement-directive statement))
        thereis (string= (expression-statement-directive statement) "use strict")))

(defun parse-params (p)
  (eat-punct p "(")
  (let ((params '()) (old-ip (parser-in-parameters p)))
    (setf (parser-in-parameters p) t)          ; forbid await/yield exprs in params
    (unwind-protect
         (loop until (punct? p ")")
               do (if (punct? p "...")
                      (let ((s (cur-start p))) (advance p)
                        (push (finish (make-rest-element :argument (parse-binding-target p))
                                      s (parser-prev-end p))
                              params)
                        (unless (punct? p ")") (syntax-error p "rest parameter must be last")))
                      (push (parse-binding-element p) params))
                  (if (punct? p ",") (advance p) (return)))
      (setf (parser-in-parameters p) old-ip))
    (eat-punct p ")")
    (nreverse params)))

(defun simple-params-p (params)
  (every #'identifier-p params))

(defun check-unique-params (p params)
  "Signal a SyntaxError on any duplicate bound parameter name."
  (let ((seen (make-hash-table :test 'equal)))
    (dolist (pp params)
      (dolist (n (binding-bound-names pp))
        (when (gethash n seen) (syntax-error p "duplicate parameter name '~a'" n))
        (setf (gethash n seen) t)))))

(defun check-parameter-body-lexical-conflicts (p params body)
  "Reject a parameter name redeclared lexically at the top level of BODY."
  (let ((parameter-names (make-hash-table :test 'equal)))
    (dolist (parameter params)
      (dolist (name (binding-bound-names parameter))
        (setf (gethash name parameter-names) t)))
    (dolist (statement (block-statement-body body))
      (dolist (name (stmt-lexical-names statement))
        (when (gethash name parameter-names)
          (syntax-error p "parameter '~a' conflicts with a lexical body declaration" name))))))

(defun check-strict-parameter-names (p params)
  "Validate names whose illegality may only become known after a strict body directive."
  (dolist (parameter params)
    (dolist (name (binding-bound-names parameter))
      (check-strict-binding-name p name))))

(defun check-strict-binding-name (p name)
  "Revalidate a BindingIdentifier parsed before a body established strict mode."
  (when (or (member name '("eval" "arguments") :test #'string=)
            (member name *strict-reserved* :test #'string=))
    (syntax-error p "'~a' cannot be bound in strict mode" name)))

(defun check-accessor-arity (p kind params)
  "Getter takes no params; setter takes exactly one non-rest param (§B / class)."
  (case kind
    (:get (when params (syntax-error p "getter must not have parameters")))
    (:set (unless (and (= 1 (length params)) (not (rest-element-p (first params))))
            (syntax-error p "setter must have exactly one parameter")))))

(defun parse-class (p declaration)
  (let ((start (cur-start p))
        (old-strict (parser-strict p)))
    (advance p)                                ; class
    (setf (parser-strict p) t)                 ; class bodies are strict
    (unwind-protect
         (let ((id (when (and (name-tok? p) (not (name? p "extends")))
                     (parse-binding-identifier p)))
               (super nil))
           (when (name? p "extends") (advance p) (setf super (parse-lhs p)))
           (eat-punct p "{")
           (let ((members '()) (ctors 0))
             (loop until (punct? p "}")
                   do (if (punct? p ";") (advance p)
                          (let ((m (parse-class-member p (not (null super)))))
                            (when (eq (method-definition-kind m) :constructor)
                              (when (> (incf ctors) 1)
                                (syntax-error p "a class may only have one constructor")))
                            (push m members))))
             (eat-punct p "}")
             (let ((cbody (finish (make-class-body :body (nreverse members))
                                  start (parser-prev-end p))))
               (finish (make-class-node :id id :super-class super :body cbody
                                        :declaration declaration)
                       start (parser-prev-end p)))))
      (setf (parser-strict p) old-strict))))

(defun parse-class-member (p derived-p)
  (let* ((start (cur-start p)) (source-start start)
         (static nil) (async nil) (gen nil) (kind :method))
    (when (and (name? p "static")
               (let ((n (peek p)))
                 (not (and (eq (token-type n) :punct)
                           (member (token-value n) '("(" "=" ";" "}") :test #'string=)))))
      (setf static t)
      (advance p)
      ;; `static` is not part of the function's source text. Starting at the
      ;; next token also excludes comments and whitespace between the modifier
      ;; and the method while retaining async/get/set/* prefixes.
      (setf source-start (cur-start p)))
    (when (and (name? p "async")
               (let ((n (peek p)))
                 (not (or (token-nl-before n)
                          (and (eq (token-type n) :punct)
                               (member (token-value n) '("(" "=" ";" "}") :test #'string=))))))
      (setf async t) (advance p))
    (when (punct? p "*") (setf gen t) (advance p))
    (when (and (or (name? p "get") (name? p "set")) (not async) (not gen)
               (let ((n (peek p)))
                 (not (and (eq (token-type n) :punct)
                           (member (token-value n) '("(" "=" ";" "}") :test #'string=)))))
      (setf kind (if (name? p "get") :get :set)) (advance p))
    (multiple-value-bind (key computed) (parse-property-key p)
      (unless (punct? p "(")
        (syntax-error p "class fields are not supported (ES2017 tier)"))
      (let* (;; a computed key is never the real constructor/prototype name
             (name (unless computed
                     (cond ((identifier-p key) (identifier-name key))
                           ((and (literal-p key) (eq (literal-kind key) :string)) (literal-value key))
                           (t nil))))
             (is-ctor (and (equal name "constructor") (not static)))
             (is-proto (and (equal name "prototype") static))
             (fn (parse-method-tail p async gen
                                    :allow-super-call
                                    (and derived-p is-ctor (not async) (not gen)
                                         (eq kind :method)))))
        (check-accessor-arity p kind (function-node-params fn))
        (when is-ctor
          (when (or async gen (member kind '(:get :set)))
            (syntax-error p "class constructor may not be an accessor, generator, or async")))
        (when is-proto
          (syntax-error p "a static class method may not be named 'prototype'"))
        (finish (make-method-definition :key key :value fn
                                        :kind (cond ((member kind '(:get :set)) kind)
                                                    (is-ctor :constructor)
                                                    (t :method))
                                        :static static :computed computed
                                        :source-start source-start)
                start (parser-prev-end p))))))

;;; --- arrow functions (cover-grammar) ---------------------------------------

(defun try-parse-arrow (p start)
  "If CUR begins an arrow function, parse and return it; else NIL (no consumption)."
  (cond
    ;; async x => ...   /   async (params) => ...
    ((name? p "async")
     (let ((n (peek p)))
       (cond
         ((and (eq (token-type n) :name) (not (token-nl-before n))
               (not (string= (token-value n) "function")))
          ;; maybe `async ident => …`: consume async, verify `ident =>` follows
          (let ((save (snapshot p)))
            (advance p)                        ; async
            (if (and (name-tok? p) (not (reserved-word-p p (cur-val p))) (arrow-after-ident-p p))
                (parse-arrow-ident p start t)
                (progn (restore p save) nil))))
         ((and (eq (token-type n) :punct) (string= (token-value n) "(")
               (not (token-nl-before n)))
          (let ((save (snapshot p)))
            (advance p)                        ; async
            (or (parse-arrow-paren p start t)
                (progn (restore p save) nil))))
         ;; `async => …`: `async` is itself the (non-async) single arrow parameter
         ((arrow-after-ident-p p) (parse-arrow-ident p start nil))
         (t nil))))
    ;; x => ...
    ((and (name-tok? p) (not (reserved-word-p p (cur-val p))) (arrow-after-ident-p p))
     (parse-arrow-ident p start nil))
    ;; (params) => ...
    ((punct? p "(")
     (let ((save (snapshot p)))
       (or (parse-arrow-paren p start nil)
           (progn (restore p save) nil))))
    (t nil)))

(defun arrow-after-ident-p (p)
  "CUR is an identifier; does `=> ` immediately follow it (same line)?"
  (let ((n (peek p)))
    (and (eq (token-type n) :punct) (string= (token-value n) "=>") (not (token-nl-before n)))))

(defun snapshot (p)
  (let ((lx (parser-lexer p)))
    (list (lexer-pos lx) (lexer-line lx) (lexer-line-start lx) (parser-cur p)
          (parser-prev-end p) (parser-strict p))))
(defun restore (p s)
  (let ((lx (parser-lexer p)))
    (setf (lexer-pos lx) (first s) (lexer-line lx) (second s) (lexer-line-start lx) (third s)
          (parser-cur p) (fourth s) (parser-prev-end p) (fifth s) (parser-strict p) (sixth s))))

(defun parse-arrow-ident (p start async)
  (let ((param (parse-binding-identifier p)))
    (unless (and (punct? p "=>") (not (nl-before-p p))) (syntax-error p "expected =>"))
    (advance p)
    (parse-arrow-body p start (list param) async)))

(defun parse-arrow-paren (p start async)
  "Speculatively parse `(params) =>`. Returns the arrow node, or NIL if not an arrow
(caller restores). Errors during param parsing mean 'not an arrow'; once `=>` is
seen the arrow is committed and body errors propagate."
  ;; catch js-condition (the base) — with a realm bound, syntax errors are real
  ;; Error objects wrapped in js-condition, not the bare js-native-error.
  (let ((params (handler-case (parse-params p)
                  (js-condition () (return-from parse-arrow-paren nil)))))
    (if (and (punct? p "=>") (not (nl-before-p p)))
        (progn (advance p) (parse-arrow-body p start params async))
        nil)))

(defun parse-arrow-body (p start params async)
  (check-unique-params p params)               ; arrow params are always unique
  (let ((old-a (parser-allow-await p)) (old-y (parser-allow-yield p))
        (old-f (parser-in-function p)) (old-i (parser-in-iteration p)) (old-s (parser-in-switch p))
        (old-strict (parser-strict p)) (old-labels (parser-labels p)))
    (setf (parser-allow-await p) async (parser-allow-yield p) nil
          (parser-in-function p) t (parser-in-iteration p) nil (parser-in-switch p) nil
          (parser-labels p) nil)
    (unwind-protect
         (if (punct? p "{")
             (let ((body (parse-function-body p)))
               (when (and (function-body-has-use-strict-directive-p body)
                          (not (simple-params-p params)))
                 (syntax-error p "a 'use strict' directive is not allowed with non-simple parameters"))
               (check-parameter-body-lexical-conflicts p params body)
               (when (parser-strict p)
                 (check-strict-parameter-names p params))
               (finish (make-arrow-function :params params :body body :async async :expression nil)
                       start (parser-prev-end p)))
             (let ((body (parse-assignment p)))
               (finish (make-arrow-function :params params :body body :async async :expression t)
                       start (parser-prev-end p))))
      (setf (parser-allow-await p) old-a (parser-allow-yield p) old-y
            (parser-in-function p) old-f (parser-in-iteration p) old-i (parser-in-switch p) old-s
            (parser-strict p) old-strict (parser-labels p) old-labels))))

(defun parse-paren-or-arrow-expr (p)
  "A `(` in primary position that was NOT an arrow (arrows are handled earlier):
a parenthesized expression."
  (eat-punct p "(")
  (when (punct? p ")") (syntax-error p "unexpected ')'"))
  (let ((expr (with-in p (parse-expression p))))   ; `in` is allowed inside parens
    (eat-punct p ")")
    (setf (node-parenthesized expr) t)             ; a valid ** base
    expr))

;;; --- bindings & patterns ----------------------------------------------------

(defun parse-binding-identifier (p)
  (unless (name-tok? p) (syntax-error p "expected a binding identifier, got ~a" (describe-cur p)))
  (let ((start (cur-start p)) (name (cur-val p)))
    (check-binding-name p name)
    (advance p)
    (finish (make-identifier :name name) start (parser-prev-end p))))

(defun parse-binding-target (p)
  "A BindingIdentifier or a binding pattern ([...] or {...})."
  (cond
    ((punct? p "[") (parse-array-pattern p))
    ((punct? p "{") (parse-object-pattern p))
    (t (parse-binding-identifier p))))

(defun parse-binding-element (p)
  "A parameter/binding element: target with an optional default."
  (let ((start (cur-start p))
        (target (parse-binding-target p)))
    (if (punct? p "=")
        (progn (advance p)
               (finish (make-assignment-pattern :left target :right (parse-assignment p))
                       start (parser-prev-end p)))
        target)))

(defun parse-array-pattern (p)
  (let ((start (cur-start p)))
    (eat-punct p "[")
    (let ((elts '()))
      (loop until (punct? p "]")
            do (cond
                 ((punct? p ",") (advance p) (push nil elts))
                 ((punct? p "...")
                  (let ((s (cur-start p))) (advance p)
                    (push (finish (make-rest-element :argument (parse-binding-target p))
                                  s (parser-prev-end p))
                          elts))
                  (return))
                 (t (push (parse-binding-element p) elts)
                    (unless (punct? p "]") (eat-punct p ",")))))
      (eat-punct p "]")
      (finish (make-array-pattern :elements (nreverse elts)) start (parser-prev-end p)))))

(defun parse-object-pattern (p)
  (let ((start (cur-start p)))
    (eat-punct p "{")
    (let ((props '()))
      (loop until (punct? p "}")
            do (cond
                 ((punct? p "...")
                  (let ((s (cur-start p))) (advance p)
                    (push (finish (make-rest-element :argument (parse-binding-identifier p))
                                  s (parser-prev-end p))
                          props))
                  (return))
                 (t (push (parse-object-pattern-prop p) props)
                    (unless (punct? p "}") (eat-punct p ","))))
            )
      (eat-punct p "}")
      (finish (make-object-pattern :properties (nreverse props)) start (parser-prev-end p)))))

(defun parse-object-pattern-prop (p)
  (let ((start (cur-start p)))
    (multiple-value-bind (key computed) (parse-property-key p)
      (cond
        ((punct? p ":") (advance p)
         (finish (make-property :key key :value (parse-binding-element p) :kind :init
                                :computed computed)
                 start (parser-prev-end p)))
        ((punct? p "=")
         (advance p)
         (finish (make-property :key key
                                :value (finish (make-assignment-pattern
                                                :left key :right (parse-assignment p))
                                              start (parser-prev-end p))
                                :kind :init :shorthand t)
                 start (parser-prev-end p)))
        (t (unless (identifier-p key) (syntax-error p "invalid destructuring target"))
           (finish (make-property :key key :value key :kind :init :shorthand t)
                   start (parser-prev-end p)))))))

;;; --- expression -> pattern (destructuring / assignment targets) -------------

(defun expr-to-pattern (p node)
  "Reinterpret an already-parsed expression NODE as an assignment/binding pattern."
  (typecase node
    (identifier node)
    (member-expression node)
    (array-pattern node)
    (object-pattern node)
    (array-expression
     (finish (make-array-pattern
              :elements (loop for rest on (array-expression-elements node)
                              for e = (car rest)
                              collect (cond ((null e) nil)
                                            ((spread-element-p e)
                                             (when (cdr rest)
                                               (syntax-error p "rest element must be last"))
                                             (finish (make-rest-element
                                                      :argument (expr-to-pattern p (spread-element-argument e)))
                                                     (node-start e) (node-end e)))
                                            (t (expr-to-pattern p e)))))
             (node-start node) (node-end node)))
    (object-expression
     (finish (make-object-pattern
              :properties (loop for rest on (object-expression-properties node)
                                for pr = (car rest)
                                collect (cond
                                          ((spread-element-p pr)
                                           (when (cdr rest)
                                             (syntax-error p "rest element must be last"))
                                           (finish (make-rest-element
                                                    :argument (expr-to-pattern p (spread-element-argument pr)))
                                                   (node-start pr) (node-end pr)))
                                          (t (setf (property-value pr)
                                                   (expr-to-pattern p (property-value pr)))
                                             pr))))
             (node-start node) (node-end node)))
    (assignment-expression
     (if (string= (assignment-expression-operator node) "=")
         (finish (make-assignment-pattern :left (expr-to-pattern p (assignment-expression-left node))
                                          :right (assignment-expression-right node))
                 (node-start node) (node-end node))
         (syntax-error p "invalid destructuring target")))
    (assignment-pattern node)
    (rest-element node)
    (t (syntax-error p "invalid assignment/destructuring target"))))

;;; --- modules ----------------------------------------------------------------

(defun parse-import (p)
  (let ((start (cur-start p)))
    (advance p)                                ; import
    (when (eq (cur-type p) :string)            ; import "mod";
      (let ((src (parse-module-string p)))
        (consume-semicolon p)
        (return-from parse-import
          (finish (make-import-declaration :specifiers nil :source src) start (parser-prev-end p)))))
    (let ((specs '()))
      (when (name-tok? p)                       ; default import
        (push (finish (make-import-default-specifier :local (parse-binding-identifier p))
                      start (parser-prev-end p))
              specs)
        (when (punct? p ",") (advance p)))
      (cond
        ((punct? p "*")
         (advance p) (eat-name p "as")
         (push (finish (make-import-namespace-specifier :local (parse-binding-identifier p))
                       start (parser-prev-end p))
               specs))
        ((punct? p "{")
         (advance p)
         (loop until (punct? p "}")
               do (let ((s (cur-start p)) (imported (parse-module-export-name p)) (local nil))
                    (if (name? p "as") (progn (advance p) (setf local (parse-binding-identifier p)))
                        (setf local imported))
                    (push (finish (make-import-specifier :imported imported :local local)
                                  s (parser-prev-end p))
                          specs))
                  (unless (punct? p "}") (eat-punct p ",")))
         (eat-punct p "}")))
      (eat-name p "from")
      (let ((src (parse-module-string p)))
        (consume-semicolon p)
        (finish (make-import-declaration :specifiers (nreverse specs) :source src)
                start (parser-prev-end p))))))

(defun parse-module-export-name (p)
  (cond
    ((eq (cur-type p) :string)
     (let ((s (cur-start p)) (v (cur-val p))) (advance p)
       (finish (make-literal :value v :kind :string) s (parser-prev-end p))))
    ((name-tok? p)
     (let ((s (cur-start p)) (v (cur-val p))) (advance p)
       (finish (make-identifier :name v) s (parser-prev-end p))))
    (t (syntax-error p "expected an export name"))))

(defun parse-module-string (p)
  (unless (eq (cur-type p) :string) (syntax-error p "expected a module specifier string"))
  (let ((s (cur-start p)) (v (cur-val p))) (advance p)
    (finish (make-literal :value v :kind :string) s (parser-prev-end p))))

(defun parse-export (p)
  (let ((start (cur-start p)))
    (advance p)                                ; export
    (cond
      ((name? p "default")
       (advance p)
       (let ((decl (cond ((name? p "function") (parse-function p nil t t))     ; allow anon
                         ((and (name? p "async")
                               (let ((n (peek p))) (and (eq (token-type n) :name)
                                                        (string= (token-value n) "function"))))
                          (parse-function p t t t))                            ; allow anon
                         ((name? p "class") (parse-class p t))
                         (t (prog1 (parse-assignment p) (consume-semicolon p))))))
         (finish (make-export-default-declaration :declaration decl) start (parser-prev-end p))))
      ((punct? p "*")
       (advance p)
       (let ((exported nil))
         (when (name? p "as") (advance p) (setf exported (parse-module-export-name p)))
         (eat-name p "from")
         (let ((src (parse-module-string p)))
           (consume-semicolon p)
           (finish (make-export-all-declaration :exported exported :source src)
                   start (parser-prev-end p)))))
      ((punct? p "{")
       (advance p)
       (let ((specs '()))
         (loop until (punct? p "}")
               do (let ((s (cur-start p)) (local (parse-module-export-name p)) (exported nil))
                    (if (name? p "as") (progn (advance p) (setf exported (parse-module-export-name p)))
                        (setf exported local))
                    (push (finish (make-export-specifier :local local :exported exported)
                                  s (parser-prev-end p))
                          specs))
                  (unless (punct? p "}") (eat-punct p ",")))
         (eat-punct p "}")
         (let ((src nil))
           (when (name? p "from") (advance p) (setf src (parse-module-string p)))
           (consume-semicolon p)
           (finish (make-export-named-declaration :specifiers (nreverse specs) :source src
                                                  :declaration nil)
                   start (parser-prev-end p)))))
      ((or (name? p "var") (name? p "const") (name-let-decl-p p))
       (let ((decl (parse-variable-statement p (intern (string-upcase (cur-val p)) :keyword))))
         (finish (make-export-named-declaration :declaration decl :specifiers nil :source nil)
                 start (parser-prev-end p))))
      ((name? p "function")
       (finish (make-export-named-declaration :declaration (parse-function-declaration p nil)
                                              :specifiers nil :source nil)
               start (parser-prev-end p)))
      ((name? p "class")
       (finish (make-export-named-declaration :declaration (parse-class p t)
                                              :specifiers nil :source nil)
               start (parser-prev-end p)))
      ((and (name? p "async")
            (let ((n (peek p))) (and (eq (token-type n) :name) (string= (token-value n) "function"))))
       (finish (make-export-named-declaration :declaration (parse-function-declaration p t)
                                              :specifiers nil :source nil)
               start (parser-prev-end p)))
      (t (syntax-error p "unexpected token after 'export'")))))
