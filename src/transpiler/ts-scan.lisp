;;;; ts-scan.lisp — tokenizer (drives the engine lexer's regex/template context) +
;;;; the recursive-descent walker that records type-syntax erase spans (PLAN.md §3.3,
;;;; Phase 09). All type-position logic lives here; skip-type (ts-type.lisp) finds the
;;;; end of a type. Errors loudly (unsupported-ts-syntax) rather than mis-strip.

(in-package :clun.transpiler)

;;; --- tokenizer: produce a token vector with regex/template resolved -----------

(defparameter *regex-preceding-keywords*
  '("return" "typeof" "delete" "void" "in" "instanceof" "do" "else" "yield" "await"
    "case" "new" "of")
  "Keywords after which a `/` begins a regex, not division.")

(defun prev-allows-regex-p (tok)
  "True iff a `/` following TOK begins a RegExp literal (expression-start context)."
  (or (null tok)
      (case (eng:token-type tok)
        ((:num :bigint :string :regexp) nil)
        (:template (not (member (eng:token-tmpl-part tok) '(:full :tail))))
        ;; `!` here is a value-ending POSTFIX non-null (TS); treat as divide/value-end
        ;; so a following `/`, `as`, or `!` is not misread as expression-start.
        (:punct (not (member (eng:token-value tok) '(")" "]" "}" "++" "--" "!") :test #'string=)))
        (:name (and (not (eng:token-escaped tok))
                    (member (eng:token-value tok) *regex-preceding-keywords* :test #'string=)
                    t))
        (t t))))

(defun tokenize (source path)
  "Tokenize SOURCE into a vector, resolving regex-vs-divide and template `${}` exactly
as the parser would. A stray `@` (decorator) becomes an unsupported-ts-syntax error."
  (let ((lx (eng:make-lexer source))
        (toks (make-array 128 :adjustable t :fill-pointer 0))
        (prev nil) (tmpl-stack '()))
    (loop
      (let ((tok (handler-case (eng:next-token lx)
                   ;; the lexer lex-errors on `@` (decorators) → the documented TS
                   ;; error at that position. Catch ANY error (the lexer's error path
                   ;; can surface as a raw Lisp error when *realm* is unbound).
                   (error (e)
                     (let ((pos (eng:lexer-pos lx)))
                       (if (and (< pos (length source)) (char= (char source pos) #\@))
                           (error 'unsupported-ts-syntax :path path
                                  :message "TypeScript experimental decorators are not currently supported"
                                  :line 1 :col (1+ pos))
                           (error e)))))))
        (when (and (eq (eng:token-type tok) :punct)
                   (member (eng:token-value tok) '("/" "/=") :test #'string=)
                   (prev-allows-regex-p prev))
          (setf tok (eng:reread-regexp lx tok)))
        (when (and tmpl-stack (eq (eng:token-type tok) :punct))
          (let ((v (eng:token-value tok)))
            (cond ((string= v "{") (incf (car tmpl-stack)))
                  ((string= v "}")
                   (if (plusp (car tmpl-stack)) (decf (car tmpl-stack))
                       (progn (pop tmpl-stack)
                              (setf (eng:lexer-pos lx) (1+ (eng:token-start tok)))
                              (setf tok (eng:reread-template lx))
                              (when (eq (eng:token-tmpl-part tok) :middle) (push 0 tmpl-stack))))))))
        (when (and (eq (eng:token-type tok) :template) (eq (eng:token-tmpl-part tok) :head))
          (push 0 tmpl-stack))
        (vector-push-extend tok toks)
        (when (eq (eng:token-type tok) :eof) (return))
        (setf prev tok)))
    toks))

;;; --- walker -----------------------------------------------------------------

(defstruct (walker (:conc-name w-)) toks (i 0) src path (erasures '()))

(defun w-cur (w) (tk (w-toks w) (w-i w)))
(defun w-cty (w) (ttype (w-toks w) (w-i w)))
(defun w-cv (w) (tval (w-toks w) (w-i w)))
(defun w-at (w k) (tk (w-toks w) (+ (w-i w) k)))
(defun w-eof (w) (or (null (w-cur w)) (eq (w-cty w) :eof)))
(defun w-punct (w s) (tpunct= (w-toks w) (w-i w) s))
(defun w-name (w s) (tname= (w-toks w) (w-i w) s))
(defun w-adv (w) (incf (w-i w)))

(defun w-erase-toks (w a b)
  "Erase the char span covering tokens [A, B) (exclusive B); no-op if empty."
  (when (> b a)
    (push (cons (eng:token-start (aref (w-toks w) a))
                (eng:token-end (aref (w-toks w) (1- b))))
          (w-erasures w))))

(defun w-erase-1 (w idx)
  (push (cons (eng:token-start (aref (w-toks w) idx))
              (eng:token-end (aref (w-toks w) idx)))
        (w-erasures w)))

(defun w-skip-type (w)
  "Erase a type starting at the current token; advance past it."
  (let ((start (w-i w)) (end (skip-type (w-toks w) (w-i w))))
    (w-erase-toks w start end)
    (setf (w-i w) end)))

(defun w-err (w message)
  (ts-error (w-cur w) message (w-path w)))

;;; --- balanced skips (no erase) — used to walk value code ---------------------

(defun w-skip-balanced (w open close)
  "Advance from an OPEN punct (current) past its matching CLOSE, walking inner code
with scan-token so inline type syntax inside is still stripped."
  (w-adv w)                                   ; consume OPEN
  (loop until (or (w-eof w) (w-punct w close))
        do (scan-token w))
  (unless (w-eof w) (w-adv w)))               ; consume CLOSE

;;; --- generics: is `<` here a type-args/type-params list? --------------------

(defun w-type-args-p (w)
  "Heuristic: at a `<`, is it TS type-args/params (vs less-than)? True iff a balanced
`<…>` reaches a matching `>` whose next token is `(` or a template (a call/tag), with
only type-ish content between. Conservative: only when preceded by a callee."
  (let* ((toks (w-toks w)) (n (length toks)) (i (w-i w)) (depth 0) (ok t))
    (when (tpunct= toks i "<")
      (loop for j from i below n
            for tok = (aref toks j)
            for ty = (eng:token-type tok)
            do (cond
                 ((eq ty :eof) (return-from w-type-args-p nil))
                 ((eq ty :punct)
                  (let ((v (eng:token-value tok)))
                    (cond ((string= v "<") (incf depth))
                          ((plusp (angle-closers v))
                           (decf depth (angle-closers v))
                           (when (<= depth 0)
                             ;; matched — next token must be ( or a template
                             (let ((nx (tk toks (1+ j))))
                               (return-from w-type-args-p
                                 (and ok nx (or (and (eq (eng:token-type nx) :punct)
                                                     (string= (eng:token-value nx) "("))
                                                (eq (eng:token-type nx) :template)))))))
                          ;; only type-ish punct allowed between < > (incl `=` for a
                          ;; type-param default `<T = D>`)
                          ((member v '("," "." "[" "]" "|" "&" "=>" "extends" "{" "}"
                                       "(" ")" "?" ":" "..." "=") :test #'string=))
                          (t (setf ok nil)))))
                 ((member ty '(:name :string :num :bigint :template)))
                 (t (setf ok nil))))
      nil)))

(defun w-arrow-ahead-p (w)
  "At a `(`, does a balanced `(…)` (optionally followed by `: Type`) precede `=>`?
Non-destructive. Marks an arrow function whose params/return-type must be stripped."
  (let* ((toks (w-toks w)) (n (length toks)) (i (w-i w)) (depth 0))
    (when (tpunct= toks i "(")
      (loop for j from i below n
            for tok = (aref toks j)
            do (when (eq (eng:token-type tok) :punct)
                 (let ((v (eng:token-value tok)))
                   (cond ((string= v "(") (incf depth))
                         ((string= v ")")
                          (decf depth)
                          (when (zerop depth)
                            (let ((k (1+ j)))
                              (when (tpunct= toks k ":")
                                (setf k (skip-type toks (1+ k) :arrow-return t)))
                              (return-from w-arrow-ahead-p (tpunct= toks k "=>"))))))))
            finally (return nil)))))

(defun w-angle-cast-p (w)
  "At a `<` in expression-start position, is it an angle-bracket cast `<T>expr` (a
balanced type-ish `<…>` NOT followed by `(`/template)? Distinguished from `a < b > c`
by the caller's prev-allows-regex-p guard."
  (let* ((toks (w-toks w)) (n (length toks)) (i (w-i w)) (depth 0) (ok t))
    (when (tpunct= toks i "<")
      (loop for j from i below n for tok = (aref toks j)
            do (when (eq (eng:token-type tok) :punct)
                 (let ((v (eng:token-value tok)))
                   (cond ((string= v "<") (incf depth))
                         ((plusp (angle-closers v))
                          (decf depth (angle-closers v))
                          (when (<= depth 0)
                            (let ((nx (tk toks (1+ j))))
                              (return-from w-angle-cast-p
                                (and ok nx
                                     (not (and (eq (eng:token-type nx) :punct)
                                               (string= (eng:token-value nx) "(")))
                                     (not (eq (eng:token-type nx) :template)))))))
                         ((member v '("," "." "[" "]" "|" "&" "=>" "{" "}" "(" ")" "?" ":" "..." "=")
                                  :test #'string=))
                         (t (setf ok nil)))))
            finally (return nil)))))

;;; --- non-null `!` postfix ---------------------------------------------------

(defun w-maybe-nonnull (w prev)
  "If the current token is a postfix non-null `!` (prev ends a value), erase it — and
greedily the whole run (`x!!`), so no stray `!` is left."
  (when (and (w-punct w "!") (not (prev-allows-regex-p prev)))
    (loop while (w-punct w "!") do (w-erase-1 w (w-i w)) (w-adv w))
    t))

;;; --- the core token walk (expression / statement bodies) --------------------

(defun scan-block (w)
  "Walk a statement block `{ … }` (current token is `{`): scan-statement per item."
  (w-adv w)                                    ; consume {
  (loop until (or (w-eof w) (w-punct w "}"))
        do (let ((before (w-i w))) (scan-statement w)
                (when (= (w-i w) before) (w-adv w))))
  (unless (w-eof w) (w-adv w)))                ; consume }

(defun scan-token (w)
  "Walk one token of value/expression code, stripping inline type syntax (generics,
as/satisfies, non-null !), recursing into brackets. Advances the cursor."
  (let ((prev (and (plusp (w-i w)) (aref (w-toks w) (1- (w-i w)))))
        (ty (w-cty w)) (v (w-cv w)))
    (cond
      ((w-eof w) nil)
      ;; an arrow function's parameter list: strip `?`/`: Type` params + `: RetType`
      ((and (eq ty :punct) (string= v "(") (w-arrow-ahead-p w))
       (scan-params w) (scan-after-params-return w t))    ; t = arrow return type
      ;; arrow body: `=> { block }` is statements; `=> expr` continues in the loop
      ((and (eq ty :punct) (string= v "=>"))
       (w-adv w) (when (w-punct w "{") (scan-block w)))
      ;; recurse into bracket groups
      ((and (eq ty :punct) (string= v "(")) (w-skip-balanced w "(" ")"))
      ((and (eq ty :punct) (string= v "[")) (w-skip-balanced w "[" "]"))
      ((and (eq ty :punct) (string= v "{")) (w-skip-balanced w "{" "}"))   ; object literal
      ;; postfix non-null
      ((w-maybe-nonnull w prev))
      ;; type args / arrow type-params: foo<T>(…), new Foo<T>(), <T,>(x)=>…
      ;; (w-type-args-p already requires the matching `>` to be followed by `(`/tag
      ;; with type-list content, so `a < b` is never taken — regardless of prev.)
      ((and (eq ty :punct) (string= v "<") (w-type-args-p w))
       (let ((start (w-i w)) (end (skip-type (w-toks w) (w-i w))))
         (w-erase-toks w start end) (setf (w-i w) end)))
      ;; angle-bracket cast `<T>expr` (only `as` is erasable — amaro parity → error)
      ((and (eq ty :punct) (string= v "<") (prev-allows-regex-p prev) (w-angle-cast-p w))
       (w-err w "TypeScript type assertion using angle brackets is not supported; use `as`"))
      ;; `as` / `satisfies` <type>
      ((and (eq ty :name) (not (eng:token-escaped (w-cur w)))
            (member v '("as" "satisfies") :test #'string=)
            prev (not (prev-allows-regex-p prev)))
       (let ((start (w-i w)))
         (w-adv w)                              ; consume as/satisfies
         (let ((end (skip-type (w-toks w) (w-i w))))
           (w-erase-toks w start end) (setf (w-i w) end))))
      (t (w-adv w)))))

;;; --- type annotations (`: Type`) --------------------------------------------

(defun w-maybe-annotation (w &optional arrow-return)
  "If the current token is `:` in a type-annotation position, erase `: Type`. When
ARROW-RETURN, the type is an arrow's return type (a top-level `=>` ends it)."
  (when (w-punct w ":")
    (let ((start (w-i w)))
      (w-adv w)                                ; consume :
      (let ((end (skip-type (w-toks w) (w-i w) :arrow-return arrow-return)))
        (w-erase-toks w start end) (setf (w-i w) end))
      t)))

(defun w-maybe-optional (w)
  "Erase a TS optional `?` when it precedes `:`/`,`/`)`/`}`/`=` (param/field/prop)."
  (when (and (w-punct w "?")
             (let ((nx (w-at w 1)))
               (and nx (eq (eng:token-type nx) :punct)
                    (member (eng:token-value nx) '(":" "," ")" "}" "=" ";") :test #'string=))))
    (w-erase-1 w (w-i w)) (w-adv w) t))

;;; --- parameter lists (params may carry ?, : Type, and param-properties err) --

(defun scan-params (w &optional in-constructor)
  "Walk a `( … )` parameter list starting at `(`: erase per-param `?`/`: Type`;
a parameter property (accessibility/readonly modifier) errors in a constructor."
  (w-adv w)                                    ; consume (
  (loop until (or (w-eof w) (w-punct w ")"))
        do (cond
             ;; parameter property → hard error (in a constructor); elsewhere just a
             ;; modifier that TS disallows — treat as error too (only ctors allow them)
             ((and (member (w-cv w) '("public" "private" "protected" "readonly" "override")
                           :test #'string=)
                   (eq (w-cty w) :name) (not (eng:token-escaped (w-cur w))))
              (if in-constructor
                  (w-err w "TypeScript parameter property is not supported in strip-only mode")
                  ;; a modifier on a non-constructor param is invalid TS; erase it so we
                  ;; never emit `m(public x)` as JS (lenient — documented).
                  (progn (w-erase-1 w (w-i w)) (w-adv w))))
             ((w-maybe-optional w))
             ((w-maybe-annotation w))
             ((w-punct w ",") (w-adv w))
             (t (scan-token w))))
  (unless (w-eof w) (w-adv w)))                ; consume )

(defun scan-after-params-return (w &optional arrow-return)
  "After a `)` param list, erase a `: ReturnType` if present."
  (w-maybe-annotation w arrow-return))

;;; --- functions --------------------------------------------------------------

(defun w-maybe-type-params (w)
  "Erase a `<…>` type-parameter list at the current `<` (declaration position)."
  (when (w-punct w "<")
    (let ((start (w-i w)) (end (skip-type (w-toks w) (w-i w))))
      (w-erase-toks w start end) (setf (w-i w) end) t)))

(defun scan-function (w &optional (start (w-i w)))
  "From `function` (already possibly `async`): name, <TypeParams>, (params), :ret, body.
A bodyless declaration (overload signature) is erased whole."
  (w-adv w)                                    ; consume `function`
  (when (w-punct w "*") (w-adv w))             ; generator
  (when (eq (w-cty w) :name) (w-adv w))        ; name
  (w-maybe-type-params w)
  (when (w-punct w "(")
    (scan-params w)
    (scan-after-params-return w))
  (cond ((w-punct w "{") (scan-block w))
        (t ;; overload signature: no body → erase the whole declaration
         (when (w-punct w ";") (w-adv w))
         (w-erase-toks w start (w-i w)))))

;;; --- classes ----------------------------------------------------------------

(defun scan-class (w)
  "class [Name] [<T>] [extends X] [implements I, J] { members }."
  (w-adv w)                                    ; consume `class`
  (when (eq (w-cty w) :name) (w-adv w))        ; name
  (w-maybe-type-params w)
  (when (w-name w "extends")
    (w-adv w)
    ;; the superclass is a value expression, possibly with `<T>` type args (which
    ;; w-type-args-p won't catch since a `{`/`implements` follows, not `(`) → erase them.
    (loop until (or (w-eof w) (w-name w "implements") (w-punct w "{"))
          do (if (w-punct w "<") (w-maybe-type-params w) (scan-token w))))
  (when (w-name w "implements")
    (let ((start (w-i w)))
      (w-adv w)
      (loop until (or (w-eof w) (w-punct w "{"))
            do (setf (w-i w) (skip-type (w-toks w) (w-i w)))
               (when (w-punct w ",") (w-adv w)))
      (w-erase-toks w start (w-i w))))
  (when (w-punct w "{") (scan-class-body w)))

(defun scan-class-body (w)
  (w-adv w)                                    ; consume {
  (loop until (or (w-eof w) (w-punct w "}"))
        do (scan-class-member w))
  (unless (w-eof w) (w-adv w)))                ; consume }

(defun scan-class-member (w)
  (let ((member-start (w-i w)))
    (scan-class-member-1 w member-start)))

(defun scan-class-member-1 (w member-start)
  ;; leading member modifiers (erase); `abstract` field/method; `readonly`, access.
  (loop while (and (eq (w-cty w) :name) (not (eng:token-escaped (w-cur w)))
                   (member (w-cv w) '("public" "private" "protected" "readonly"
                                      "abstract" "override" "declare") :test #'string=)
                   ;; only when the NEXT token starts a member (name / [ / * / async /
                   ;; get / set / another modifier) — not when it is `(` (a method
                   ;; literally named e.g. `private()` is impossible after these)
                   (let ((nx (w-at w 1)))
                     (and nx (not (and (eq (eng:token-type nx) :punct)
                                       (member (eng:token-value nx) '("(" "=" ":" ";" "?")
                                               :test #'string=))))))
        do (w-erase-1 w (w-i w)) (w-adv w))
  (cond
    ((w-eof w) nil)
    ((w-punct w "}") nil)
    ((w-punct w ";") (w-adv w))
    (t
     ;; `static` is a modifier only when a member start follows — not when it is the
     ;; member name itself (`static() {}`, `static = 1`, `static: T`).
     (let ((static (and (w-name w "static")
                        (let ((nx (w-at w 1)))
                          (and nx (or (eq (eng:token-type nx) :name)
                                      (and (eq (eng:token-type nx) :punct)
                                           (member (eng:token-value nx) '("[" "*") :test #'string=))))))))
       (when static (w-adv w))
       (when (or (w-name w "get") (w-name w "set") (w-name w "async"))
         ;; could be accessor/async method modifier OR a field literally named so;
         ;; consume only if a member name / [ follows
         (let ((nx (w-at w 1)))
           (when (and nx (or (eq (eng:token-type nx) :name)
                             (and (eq (eng:token-type nx) :punct)
                                  (member (eng:token-value nx) '("[" "*") :test #'string=))))
             (w-adv w))))
       (when (w-punct w "*") (w-adv w))
       ;; member key
       (cond ((w-punct w "[") (w-skip-balanced w "[" "]"))
             ((not (w-eof w)) (w-adv w)))
       ;; constructor?
       (let ((ctor (and (not static)
                        (let ((k (aref (w-toks w) (max 0 (1- (w-i w))))))
                          (and (eq (eng:token-type k) :name) (string= (eng:token-value k) "constructor"))))))
         (w-maybe-type-params w)
         (w-maybe-optional w)                  ; name?  (optional member)
         (when (w-punct w "!") (w-erase-1 w (w-i w)) (w-adv w))  ; definite-assign field
         (cond
           ((w-punct w "<") (w-maybe-type-params w)
            (when (w-punct w "(") (scan-params w ctor) (scan-after-params-return w)))
           ((w-punct w "(") (scan-params w ctor) (scan-after-params-return w))
           (t (w-maybe-annotation w)))         ; a field type annotation
         ;; method body / field initializer / signature
         (cond ((w-punct w "{") (scan-block w))
               ((w-punct w "=") (w-adv w)
                (loop until (or (w-eof w) (w-punct w ";") (w-cur-nl-terminates w))
                      do (scan-token w))
                (when (w-punct w ";") (w-adv w)))
               ;; bodyless member (abstract method / overload signature / bare field
               ;; annotation) → erase the WHOLE member so the class still parses.
               (t (when (w-punct w ";") (w-adv w))
                  (w-erase-toks w member-start (w-i w)))))))))

(defun w-cur-nl-terminates (w)
  "True if the current token began on a new line (crude ASI for field initializers)."
  (and (w-cur w) (eng:token-nl-before (w-cur w))))

;;; --- variable declarations --------------------------------------------------

(defun scan-var-decls (w)
  (w-adv w)                                    ; consume var/let/const
  (loop
    (when (w-eof w) (return))
    ;; binding target: identifier or destructuring pattern
    (cond ((w-punct w "{") (w-skip-balanced w "{" "}"))
          ((w-punct w "[") (w-skip-balanced w "[" "]"))
          ((not (w-eof w)) (w-adv w)))
    (w-maybe-optional w)
    (when (w-punct w "!") (w-erase-1 w (w-i w)) (w-adv w))  ; definite assignment
    (w-maybe-annotation w)
    (when (w-punct w "=")
      (w-adv w)
      (loop until (or (w-eof w) (w-punct w ",") (w-punct w ";") (w-cur-nl-terminates w))
            do (scan-token w)))
    (if (w-punct w ",") (w-adv w) (return)))
  (when (w-punct w ";") (w-adv w)))

;;; --- interface / type / declare / namespace / enum --------------------------

(defun scan-interface (w)
  "interface X [<T>] [extends A, B] { … } → erase whole."
  (let ((start (w-i w)))
    (w-adv w)                                  ; interface
    (loop until (or (w-eof w) (w-punct w "{")) do (w-adv w))
    (when (w-punct w "{") (w-skip-balanced-nostrip w))
    (w-erase-toks w start (w-i w))))

(defun w-skip-balanced-nostrip (w)
  "Advance past a `{ … }` counting braces, WITHOUT recording inner erases (the whole
region is being erased by the caller)."
  (let ((depth 0))
    (loop until (w-eof w)
          do (cond ((w-punct w "{") (incf depth) (w-adv w))
                   ((w-punct w "}") (decf depth) (w-adv w) (when (zerop depth) (return)))
                   (t (w-adv w))))))

(defun scan-type-alias (w)
  "type X [<T>] = Type ; → erase whole."
  (let ((start (w-i w)))
    (w-adv w)                                  ; type
    (loop until (or (w-eof w) (w-punct w "=") (w-punct w ";")) do (w-adv w))
    (when (w-punct w "=")
      (w-adv w)
      (setf (w-i w) (skip-type (w-toks w) (w-i w))))
    (when (w-punct w ";") (w-adv w))
    (w-erase-toks w start (w-i w))))

(defun namespace-type-only-p (w)
  "Peek (non-destructive): is the namespace/module body at the current `{` purely
type-only? It is runtime iff it contains, at brace-depth 1, a value leader
(var/let/const/function/class/enum) or an export/import that is NOT type-only.
Bare `enum` is runtime (value object); `const enum` is already caught via `const`."
  (let ((save (w-i w)) (result t) (depth 0))
    (block scan
      (loop until (w-eof w)
            do (cond
                 ((w-punct w "{") (incf depth) (w-adv w))
                 ((w-punct w "}") (decf depth) (w-adv w) (when (zerop depth) (return-from scan)))
                 ((and (= depth 1) (eq (w-cty w) :name) (not (eng:token-escaped (w-cur w)))
                       (member (w-cv w) '("var" "let" "const" "function" "class" "enum")
                               :test #'string=))
                  (setf result nil) (return-from scan))
                 ((and (= depth 1) (or (w-name w "export") (w-name w "import")))
                  (if (or (tname= (w-toks w) (1+ (w-i w)) "type")
                          (tname= (w-toks w) (1+ (w-i w)) "interface")
                          (tname= (w-toks w) (1+ (w-i w)) "namespace")
                          (tname= (w-toks w) (1+ (w-i w)) "declare"))
                      (w-adv w)
                      (progn (setf result nil) (return-from scan))))
                 (t (w-adv w)))))
    (setf (w-i w) save)
    result))

(defun scan-namespace (w &optional ambient)
  "namespace/module N { … }: erase if type-only (or AMBIENT, i.e. under `declare`,
where the body never emits runtime code), else error at the keyword."
  (let* ((start (w-i w)) (kw (aref (w-toks w) start)))
    (w-adv w)                                  ; namespace/module
    (loop until (or (w-eof w) (w-punct w "{")) do (w-adv w))
    (if (and (w-punct w "{") (or ambient (namespace-type-only-p w)))
        (progn (w-skip-balanced-nostrip w) (w-erase-toks w start (w-i w)))
        (ts-error kw "TypeScript namespace declaration is not supported in strip-only mode"
                  (w-path w)))))

(defun scan-enum-ambient (w)
  "Advance past an ambient `enum` / `const enum` body. Caller (declare branch)
records the whole `declare …` erase span — no per-token erases here."
  (when (and (leader= w "const") (tname= (w-toks w) (1+ (w-i w)) "enum"))
    (w-adv w))                                 ; const
  (w-adv w)                                    ; enum
  (when (eq (w-cty w) :name) (w-adv w))        ; name
  (when (w-punct w "{") (w-skip-balanced-nostrip w))
  (when (w-punct w ";") (w-adv w)))

(defun scan-namespace-or-stmt (w &key ambient)
  "For the `declare` branch: nested namespace/module erases whole (ambient);
ambient enum / const enum advances past the body for the outer erase; any other
declaration recurses through scan-statement."
  (cond
    ((and (or (leader= w "namespace") (leader= w "module"))
          (member (ttype (w-toks w) (1+ (w-i w))) '(:name :string)))
     (scan-namespace w ambient))
    ((and ambient
          (or (leader= w "enum")
              (and (leader= w "const") (tname= (w-toks w) (1+ (w-i w)) "enum"))))
     (scan-enum-ambient w))
    (t (scan-statement w))))
;;; --- import / export --------------------------------------------------------

(defun scan-import (w)
  (let ((start (w-i w)))
    ;; import type … → whole statement erased
    (cond
      ((and (tname= (w-toks w) (1+ (w-i w)) "type")
            ;; not `import type from "x"` (a value binding named `type`)
            (let ((n2 (w-at w 2)))
              (and n2 (not (tname= (w-toks w) (+ (w-i w) 2) "from")))))
       (scan-to-stmt-end w) (w-erase-toks w start (w-i w)))
      ;; import x = require(...)  → error
      ((and (eq (ttype (w-toks w) (1+ (w-i w))) :name)
            (tpunct= (w-toks w) (+ (w-i w) 2) "="))
       (w-err w "TypeScript import = is not supported in strip-only mode"))
      (t
       ;; ordinary import — but strip inline `{ type X }` specifiers
       (w-adv w)                               ; import
       (scan-import-clause w)
       (scan-to-stmt-end w)))))

(defun scan-import-clause (w)
  "Walk to `from`/end, erasing inline `type` specifiers inside `{ … }`."
  (loop until (or (w-eof w) (w-name w "from") (w-punct w ";") (w-cur-nl-terminates-import w))
        do (if (w-punct w "{")
               (scan-named-specifiers w)
               (w-adv w))))

(defun w-cur-nl-terminates-import (w) nil)     ; imports don't ASI on newline mid-clause

(defun scan-named-specifiers (w)
  "Inside `{ a, type B, c as d }`: erase each `type X` specifier + one adjacent comma."
  (w-adv w)                                    ; consume {
  (loop until (or (w-eof w) (w-punct w "}"))
        do (cond
             ((w-name w "type")
              ;; but `{ type }` or `{ type as X }` = a binding named `type` → keep
              (let ((nx (w-at w 1)))
                (if (and nx (eq (eng:token-type nx) :name) (not (tname= (w-toks w) (1+ (w-i w)) "as")))
                    (let ((start (w-i w)))
                      (w-adv w)                ; type
                      (w-adv w)                ; name
                      (when (w-name w "as") (w-adv w) (unless (w-eof w) (w-adv w)))
                      (let ((end (w-i w)))
                        (if (w-punct w ",") (progn (w-adv w) (w-erase-toks w start (w-i w)))
                            (w-erase-toks w start end))))
                    (w-adv w))))
             ((w-punct w ",") (w-adv w))
             (t (w-adv w))))
  (unless (w-eof w) (w-adv w)))                ; consume }

(defun scan-export (w)
  (let ((start (w-i w)))
    (cond
      ;; export type … → erase whole
      ((tname= (w-toks w) (1+ (w-i w)) "type")
       (let ((n2 (w-at w 2)))
         (if (and n2 (or (and (eq (eng:token-type n2) :punct)
                              (member (eng:token-value n2) '("{" "*") :test #'string=))
                         (eq (eng:token-type n2) :name)))
             (progn (scan-to-stmt-end w) (w-erase-toks w start (w-i w)))
             (progn (w-adv w) (scan-statement w)))))
      ;; export = foo → error
      ((tpunct= (w-toks w) (1+ (w-i w)) "=")
       (w-err w "TypeScript export = is not supported in strip-only mode"))
      ((tname= (w-toks w) (1+ (w-i w)) "default")
       (w-adv w) (w-adv w) (scan-statement w))
      ;; export { … } possibly with inline type specifiers
      ((tpunct= (w-toks w) (1+ (w-i w)) "{")
       (w-adv w) (scan-named-specifiers w) (scan-to-stmt-end w))
      (t (w-adv w) (scan-statement w)))))      ; export <decl>

;;; --- statement dispatch -----------------------------------------------------

(defun scan-to-stmt-end (w)
  "Advance to the end of the current statement (`;` or a newline-before token at
depth 0 / EOF), without stripping."
  (loop until (or (w-eof w) (w-punct w ";"))
        do (cond ((w-punct w "{") (w-skip-balanced-nostrip w))
                 ((w-punct w "(") (w-skip-balanced w "(" ")"))
                 ((w-punct w "[") (w-skip-balanced w "[" "]"))
                 (t (w-adv w))))
  (when (w-punct w ";") (w-adv w)))

(defun leader= (w s) (and (eq (w-cty w) :name) (not (eng:token-escaped (w-cur w))) (string= (w-cv w) s)))

(defun w-skip-paren-header (w)
  "Walk a `( … )` control-flow header (current token `(`), stripping inline types."
  (when (w-punct w "(") (w-skip-balanced w "(" ")")))

(defun scan-statement (w)
  (cond
    ((w-eof w) nil)
    ((w-punct w ";") (w-adv w))
    ((w-punct w "{") (scan-block w))            ; statement block
    ;; control flow: header (paren, inline types stripped) + recursive bodies
    ((or (leader= w "if") (leader= w "while") (leader= w "switch"))
     (w-adv w) (w-skip-paren-header w) (scan-statement w))
    ((leader= w "for")                          ; for [await] ( [decl-with-annots] ; ; )
     (w-adv w) (when (w-name w "await") (w-adv w))
     (when (w-punct w "(")
       (w-adv w)                                ; (
       (let ((decl (and (member (w-cv w) '("let" "const" "var") :test #'equal) t))
             (depth 1))
         (when decl (w-adv w))
         ;; strip annotations in the (declaration) init part; the rest is expressions
         (loop until (or (w-eof w) (zerop depth))
               do (cond ((w-punct w "(") (incf depth) (w-adv w))
                        ((w-punct w ")") (decf depth) (w-adv w))
                        ((and decl (w-maybe-annotation w)))
                        ((and decl (w-maybe-optional w)))
                        (t (scan-token w))))))
     (scan-statement w))
    ((or (leader= w "else") (leader= w "do") (leader= w "try") (leader= w "finally"))
     (w-adv w) (scan-statement w))
    ((leader= w "catch")
     (w-adv w)
     (when (w-punct w "(")                      ; catch (e: Type)
       (w-adv w) (unless (or (w-eof w) (w-punct w ")")) (w-adv w))
       (w-maybe-annotation w)
       (unless (w-eof w) (w-adv w)))            ; consume )
     (scan-statement w))
    ((or (leader= w "case") (leader= w "default"))
     (let ((c (leader= w "case"))) (w-adv w)
          (when c (loop until (or (w-eof w) (w-punct w ":")) do (scan-token w)))
          (when (w-punct w ":") (w-adv w))))     ; following stmts handled by scan-block
    ((leader= w "return")
     (w-adv w) (scan-expression-statement w))
    ;; `interface X …` — but NOT `interface` as a value binding (`interface()` etc.)
    ((and (leader= w "interface") (eq (ttype (w-toks w) (1+ (w-i w))) :name))
     (scan-interface w))
    ((and (leader= w "type")                    ; `type X = …` (not `type` as an ident)
          (eq (ttype (w-toks w) (1+ (w-i w))) :name)
          (let ((n2 (w-at w 2)))
            (and n2 (eq (eng:token-type n2) :punct)
                 (member (eng:token-value n2) '("=" "<") :test #'string=))))
     (scan-type-alias w))
    ;; `declare <decl>` — only when a declaration leader follows (not `declare()`)
    ((and (leader= w "declare")
          (let ((nx (w-at w 1)))
            (and nx (eq (eng:token-type nx) :name) (not (eng:token-escaped nx))
                 (member (eng:token-value nx)
                         '("var" "let" "const" "function" "class" "namespace" "module"
                           "abstract" "enum" "global" "interface" "type" "async")
                         :test #'string=))))
     (let ((start (w-i w))) (w-adv w) (scan-namespace-or-stmt w :ambient t)
          (w-erase-toks w start (w-i w))))
    ;; `namespace N {`/`module N {` — require a name (module: name/string) then a body
    ((and (or (leader= w "namespace") (leader= w "module"))
          (member (ttype (w-toks w) (1+ (w-i w))) '(:name :string)))
     (scan-namespace w))
    ;; Value `enum` / `const enum` need emit (Phase 39). Ambient forms under
    ;; `declare` are handled by scan-namespace-or-stmt → scan-enum-ambient.
    ((or (leader= w "enum")
         (and (leader= w "const") (tname= (w-toks w) (1+ (w-i w)) "enum")))
     (w-err w "TypeScript enum is not supported in strip-only mode"))
    ;; `abstract class …` — only before `class` (not `abstract` as a value binding)
    ((and (leader= w "abstract") (tname= (w-toks w) (1+ (w-i w)) "class"))
     (w-erase-1 w (w-i w)) (w-adv w) (scan-statement w))
    ((leader= w "class") (scan-class w))
    ((leader= w "function") (scan-function w))
    ((and (leader= w "async") (tname= (w-toks w) (1+ (w-i w)) "function"))
     (let ((start (w-i w))) (w-adv w) (scan-function w start)))
    ((leader= w "import") (scan-import w))
    ((leader= w "export") (scan-export w))
    ((member (w-cv w) '("var" "let" "const") :test (lambda (a b) (and a (string= a b))))
     (if (and (eq (w-cty w) :name) (not (eng:token-escaped (w-cur w))))
         (scan-var-decls w)
         (scan-expression-statement w)))
    (t (scan-expression-statement w))))

(defun scan-expression-statement (w)
  "Walk an expression statement, stripping inline type syntax, to `;`/newline/EOF."
  (loop until (or (w-eof w) (w-punct w ";"))
        do (let ((before (w-i w)))
             (scan-token w)
             (when (= (w-i w) before) (w-adv w))))  ; progress guard
  (when (w-punct w ";") (w-adv w)))

(defun scan-program (w)
  (loop until (w-eof w)
        do (let ((before (w-i w)))
             (scan-statement w)
             (when (= (w-i w) before) (w-adv w)))))  ; progress guard

(defun scan-erasures (source path)
  "Tokenize SOURCE and return the ordered list of (start . end) char spans to erase."
  (let ((w (make-walker :toks (tokenize source path) :src source :path path)))
    (scan-program w)
    (sort (w-erasures w) #'< :key #'car)))
