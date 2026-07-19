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
as the parser would. `@` is a punctuator (experimental decorators)."
  (declare (ignore path))
  (let ((lx (eng:make-lexer source))
        (toks (make-array 128 :adjustable t :fill-pointer 0))
        (prev nil) (tmpl-stack '()))
    (loop
      (let ((tok (eng:next-token lx)))
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

(defstruct (walker (:conc-name w-))
  toks (i 0) src path (erasures '()) (replacements '())
  ;; when non-nil, parameter-property names collected by the latest constructor
  ;; param list (consumed when the constructor body `{` is entered).
  (param-props nil)
  ;; when non-nil, rewrite free identifiers that match these names to NS.name
  ;; inside a runtime namespace body emit pass.
  (ns-exports nil)
  (ns-name nil)
  ;; experimental decorator rewrite state
  (need-decorate-helper nil)
  ;; pending class-level decorator expressions (strings), outer-first order
  (class-decs nil)
  ;; member decorate plans: list of (:method|:property name static-p decs param-decs)
  (member-decs nil)
  ;; param decorator pairs (index . expr) for the in-progress constructor/method
  (param-decs nil)
  (param-index 0))

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

(defun w-replace-span (w start end text)
  "Replace SOURCE [START, END) with TEXT in the rewrite plan (may change length)."
  (push (list start end text) (w-replacements w)))

(defun w-char-start (w idx)
  (eng:token-start (aref (w-toks w) idx)))

(defun w-char-end (w idx)
  "End offset of token IDX (exclusive char index)."
  (eng:token-end (aref (w-toks w) idx)))

(defun w-prev-export-p (w start-idx)
  "True if token before START-IDX is bare `export` (for export enum/namespace)."
  (and (plusp start-idx)
       (let ((prev (aref (w-toks w) (1- start-idx))))
         (and (eq (eng:token-type prev) :name)
              (not (eng:token-escaped prev))
              (string= (eng:token-value prev) "export")))))

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
  (declare (ignore open))
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
      ;; angle-bracket cast `<T>expr` — erasable (Bun/tsc emit drops the cast)
      ((and (eq ty :punct) (string= v "<") (prev-allows-regex-p prev) (w-angle-cast-p w))
       (let ((start (w-i w)) (end (skip-type (w-toks w) (w-i w))))
         (w-erase-toks w start end) (setf (w-i w) end)))
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

;;; --- parameter lists (params may carry ?, : Type, and param-properties) -----

(defun param-prop-mod-p (w)
  (and (eq (w-cty w) :name) (not (eng:token-escaped (w-cur w)))
       (member (w-cv w) '("public" "private" "protected" "readonly" "override")
               :test #'string=)))

(defun scan-params (w &optional in-constructor)
  "Walk a `( … )` parameter list starting at `(`: erase per-param `?`/`: Type`.
Constructor parameter properties (accessibility/readonly) erase the modifiers and
record binding names on W for constructor-body `this.x=x` injection.
Parameter decorators (`@dec`) are recorded for experimental decorator emit."
  (setf (w-param-props w) nil
        (w-param-decs w) nil
        (w-param-index w) 0)
  (w-adv w)                                    ; consume (
  (let ((props '())
        (pidx 0))
    (loop until (or (w-eof w) (w-punct w ")"))
          do (cond
               ((w-punct w "@")
                ;; one or more param decorators for the next binding
                (loop while (w-punct w "@")
                      do (let ((expr (consume-decorator-expr w)))
                           (push (cons pidx expr) (w-param-decs w)))))
               ((param-prop-mod-p w)
                (if in-constructor
                    ;; erase all leading modifiers; capture the binding name.
                    (progn
                      (loop while (param-prop-mod-p w)
                            do (w-erase-1 w (w-i w)) (w-adv w))
                      (when (w-punct w "...")
                        (w-err w "TypeScript parameter property cannot be a rest element"))
                      (when (and (eq (w-cty w) :name) (not (eng:token-escaped (w-cur w))))
                        (push (w-cv w) props)
                        (w-adv w))
                      (w-maybe-optional w)
                      (w-maybe-annotation w)
                      ;; default value
                      (when (w-punct w "=")
                        (w-adv w)
                        (loop until (or (w-eof w) (w-punct w ",") (w-punct w ")"))
                              do (scan-token w))))
                    ;; invalid outside constructor — erase modifiers leniently
                    (progn (w-erase-1 w (w-i w)) (w-adv w))))
               ((w-maybe-optional w))
               ((w-maybe-annotation w))
               ((w-punct w ",") (w-adv w) (incf pidx))
               (t (scan-token w))))
    (unless (w-eof w) (w-adv w))               ; consume )
    (when in-constructor
      (setf (w-param-props w) (nreverse props)))
    (setf (w-param-decs w) (nreverse (w-param-decs w)))
    (w-param-props w)))

;;; --- experimental decorators ------------------------------------------------

(defun consume-decorator-expr (w)
  "At `@`: erase the decorator and return its expression source text.
Forms: @Name, @Name.Path, @Name(...), @(expr)."
  (let ((at-i (w-i w)))
    (unless (w-punct w "@")
      (w-err w "expected @ decorator"))
    (w-adv w)                                  ; @
    (let ((expr-start-i (w-i w)))
      (cond
        ((w-punct w "(")
         (w-skip-balanced w "(" ")"))
        ((eq (w-cty w) :name)
         (w-adv w)
         (loop while (and (w-punct w ".")
                          (let ((nx (w-at w 1)))
                            (and nx (eq (eng:token-type nx) :name))))
               do (w-adv w) (w-adv w))
         (when (w-punct w "(")
           (w-skip-balanced w "(" ")")))
        (t (w-err w "TypeScript decorator requires an expression")))
      (let* ((a (w-char-start w expr-start-i))
             (b (w-char-end w (1- (w-i w))))
             (text (subseq (w-src w) a b)))
        (w-erase-toks w at-i (w-i w))
        text))))

(defun consume-decorator-list (w)
  "Consume zero or more leading `@dec` forms; return expressions outer-first."
  (let ((decs '()))
    (loop while (w-punct w "@")
          do (push (consume-decorator-expr w) decs))
    (nreverse decs)))

(defun flush-decorate-emits (w class-name class-end-pos)
  "After a class body ends at CLASS-END-POS, emit __decorate calls for pending
class/member decorators. Injects the helper once per file when needed."
  (let ((class-decs (w-class-decs w))
        (members (nreverse (w-member-decs w)))
        (parts '()))
    (setf (w-class-decs w) nil
          (w-member-decs w) nil)
    (dolist (m members)
      (destructuring-bind (kind name static-p decs param-decs) m
        (let ((all (append (emit-param-decorate-entries param-decs) decs)))
          (when all
            (push (emit-member-decorate class-name name all
                                        :static-p static-p
                                        :property-p (eq kind :property))
                  parts)))))
    (when class-decs
      (push (emit-class-decorate class-name class-decs) parts))
    (when parts
      (setf (w-need-decorate-helper w) t)
      (w-replace-span w class-end-pos class-end-pos
                      (format nil "~{~a~}" (nreverse parts))))))

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

(defun scan-class (w &optional leading-decs)
  "class [Name] [<T>] [extends X] [implements I, J] { members }.
LEADING-DECS are class-level experimental decorator expressions already consumed."
  (w-adv w)                                    ; consume `class`
  (let ((class-name nil))
    (when (eq (w-cty w) :name)
      (setf class-name (w-cv w))
      (w-adv w))                               ; name
    (unless class-name
      (when leading-decs
        (w-err w "TypeScript class decorators require a named class")))
    (setf (w-class-decs w) leading-decs
          (w-member-decs w) nil)
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
    (when (w-punct w "{") (scan-class-body w class-name))
    (when (and class-name (or (w-class-decs w) (w-member-decs w)))
      (let ((end-pos (w-char-end w (1- (w-i w)))))
        (flush-decorate-emits w class-name end-pos)))))

(defun scan-class-body (w &optional class-name)
  (declare (ignore class-name))
  (w-adv w)                                    ; consume {
  (loop until (or (w-eof w) (w-punct w "}"))
        do (scan-class-member w))
  (unless (w-eof w) (w-adv w)))                ; consume }

(defun scan-class-member (w)
  (let ((member-start (w-i w))
        (member-decs (consume-decorator-list w)))
    (scan-class-member-1 w member-start member-decs)))

(defun scan-class-member-1 (w member-start &optional member-decs)
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
                                           (member (eng:token-value nx) '("[" "*") :test #'string=))
                                      (and (eq (eng:token-type nx) :punct)
                                           (string= (eng:token-value nx) "@"))))))))
       (when static (w-adv w))
       ;; decorators may also appear after `static`
       (when (w-punct w "@")
         (setf member-decs (append member-decs (consume-decorator-list w))))
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
       (let ((member-name nil))
         (cond ((w-punct w "[") (w-skip-balanced w "[" "]"))
               ((not (w-eof w))
                (setf member-name (if (eq (w-cty w) :string)
                                      (eng:token-value (w-cur w))
                                      (w-cv w)))
                (w-adv w)))
         ;; constructor?
         (let ((ctor (and (not static)
                          member-name
                          (string= member-name "constructor"))))
           (w-maybe-type-params w)
           (w-maybe-optional w)                  ; name?  (optional member)
           (when (w-punct w "!") (w-erase-1 w (w-i w)) (w-adv w))  ; definite-assign field
           (setf (w-param-decs w) nil)
           (cond
             ((w-punct w "<") (w-maybe-type-params w)
              (when (w-punct w "(") (scan-params w ctor) (scan-after-params-return w)))
             ((w-punct w "(") (scan-params w ctor) (scan-after-params-return w))
             (t (w-maybe-annotation w)))         ; a field type annotation
           (let ((param-decs (w-param-decs w)))
             (cond ((w-punct w "{")
                    ;; inject parameter-property assignments at the start of a constructor body
                    (when (and ctor (w-param-props w))
                      (let* ((brace-end (1+ (w-char-start w (w-i w))))
                             (insert (emit-param-prop-assigns (w-param-props w))))
                        (w-replace-span w brace-end brace-end insert)
                        (setf (w-param-props w) nil)))
                    (scan-block w)
                    (when (and member-name (or member-decs param-decs) (not ctor))
                      (push (list :method member-name static member-decs param-decs)
                            (w-member-decs w)))
                    (when (and ctor (or member-decs param-decs))
                      ;; constructor param/method decorators attach at class level
                      (setf (w-class-decs w)
                            (append (w-class-decs w)
                                    (emit-param-decorate-entries param-decs)
                                    member-decs))))
                   ((w-punct w "=") (w-adv w)
                    (loop until (or (w-eof w) (w-punct w ";") (w-cur-nl-terminates w))
                          do (scan-token w))
                    (when (w-punct w ";") (w-adv w))
                    (when (and member-name member-decs)
                      (push (list :property member-name static member-decs nil)
                            (w-member-decs w))))
                   ;; bodyless member (abstract method / overload signature / bare field
                   ;; annotation) → erase the WHOLE member so the class still parses,
                   ;; unless experimental field decorators require keeping the name.
                   (t (when (w-punct w ";") (w-adv w))
                      (if (and member-name member-decs)
                          (push (list :property member-name static member-decs nil)
                                (w-member-decs w))
                          (w-erase-toks w member-start (w-i w))))))))))))

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

(defun parse-enum-init-tokens (w)
  "Parse an enum member initializer into a token list for constant folding, plus
source text. Leaves the walker at the terminator (`,`/`}`)."
  (let ((start-i (w-i w))
        (depth 0)
        (tokens '()))
    (loop until (or (w-eof w)
                    (and (zerop depth) (or (w-punct w ",") (w-punct w "}"))))
          do (cond
               ((or (w-punct w "(") (w-punct w "[") (w-punct w "{"))
                (incf depth) (w-adv w))
               ((or (w-punct w ")") (w-punct w "]") (w-punct w "}"))
                (when (plusp depth) (decf depth))
                (w-adv w))
               (t
                (let ((ty (w-cty w)) (v (w-cv w)))
                  (cond ((eq ty :num)
                         (push (list :num (eng:token-value (w-cur w))) tokens))
                        ((eq ty :string)
                         (push (list :str (eng:token-value (w-cur w))) tokens))
                        ((and (eq ty :name) (not (eng:token-escaped (w-cur w))))
                         (push (list :id v) tokens))
                        ((and (eq ty :punct) (member v '("+" "-" "*" "/") :test #'string=))
                         (push (list :op v) tokens))
                        (t (push (list :raw v) tokens)))
                  (w-adv w)))))
    (let* ((end-i (w-i w))
           (src-text (if (< start-i end-i)
                         (subseq (w-src w)
                                 (w-char-start w start-i)
                                 (w-char-end w (1- end-i)))
                         ""))
           (toks (nreverse tokens)))
      ;; Prefer numeric token from the actual number token if simple
      (list :expr toks src-text))))

(defun parse-enum-members (w)
  "At `{` of an enum body: parse members, advance past closing `}`. Returns list of
(name-string init) where init is nil | (:num n) | (:str s) | (:expr tokens src)."
  (w-adv w)                                    ; {
  (let ((members '()))
    (loop until (or (w-eof w) (w-punct w "}"))
          do (cond
               ((w-punct w ",") (w-adv w))
               ((or (eq (w-cty w) :name) (eq (w-cty w) :string))
                (let ((mname (if (eq (w-cty w) :string)
                                 (eng:token-value (w-cur w))
                                 (w-cv w))))
                  (w-adv w)
                  (let ((init nil))
                    (when (w-punct w "=")
                      (w-adv w)
                      (let ((parsed (parse-enum-init-tokens w)))
                        ;; simplify single num/str
                        (let ((toks (cadr parsed)) (src (caddr parsed)))
                          (setf init
                                (cond ((and (= (length toks) 1) (eq (caar toks) :num))
                                       (car toks))
                                      ((and (= (length toks) 1) (eq (caar toks) :str))
                                       (car toks))
                                      (t (list :expr toks src)))))))
                    (push (list mname init) members))))
               (t (w-adv w))))                 ; progress guard
    (unless (w-eof w) (w-adv w))               ; }
    (nreverse members)))

(defun scan-enum (w)
  "Value `enum` / `const enum` → Bun/TS-shaped IIFE emit (const enums are also
emitted as runtime objects — inlining is optional optimization)."
  (let* ((start (w-i w))
         (export-p (w-prev-export-p w start))
         (span-start (if export-p
                         (w-char-start w (1- start))
                         (w-char-start w start))))
    (when (and (leader= w "const") (tname= (w-toks w) (1+ (w-i w)) "enum"))
      (w-adv w))                               ; const
    (w-adv w)                                  ; enum
    (unless (eq (w-cty w) :name)
      (w-err w "TypeScript enum requires a name"))
    (let ((name (w-cv w)))
      (w-adv w)
      (unless (w-punct w "{")
        (w-err w "TypeScript enum requires a body"))
      (let ((members (parse-enum-members w)))
        (when (w-punct w ";") (w-adv w))
        (let* ((span-end (w-char-end w (1- (w-i w))))
               (js (emit-enum-js name members :export-p export-p)))
          (w-replace-span w span-start span-end js))))))

(defun ns-collect-exports (toks body-start body-end)
  "Scan namespace body tokens [BODY-START, BODY-END) for exported value bindings."
  (let ((names '()) (i body-start) (depth 0))
    (loop while (< i body-end)
          do (let ((tok (tk toks i)))
               (cond
                 ((null tok) (return))
                 ((and (eq (eng:token-type tok) :punct)
                       (string= (eng:token-value tok) "{"))
                  (incf depth) (incf i))
                 ((and (eq (eng:token-type tok) :punct)
                       (string= (eng:token-value tok) "}"))
                  (decf depth) (incf i))
                 ((and (zerop depth) (tname= toks i "export"))
                  (incf i)
                  (cond
                    ((or (tname= toks i "type") (tname= toks i "interface")
                         (tname= toks i "declare"))
                     (incf i))
                    ((or (tname= toks i "const") (tname= toks i "let") (tname= toks i "var"))
                     (incf i)
                     (when (eq (ttype toks i) :name)
                       (push (tval toks i) names) (incf i)))
                    ((or (tname= toks i "function") (tname= toks i "class")
                         (tname= toks i "enum") (tname= toks i "namespace")
                         (tname= toks i "module"))
                     (incf i)
                     (when (eq (ttype toks i) :name)
                       (push (tval toks i) names) (incf i)))
                    ((and (tname= toks i "async") (tname= toks (1+ i) "function"))
                     (incf i) (incf i)
                     (when (eq (ttype toks i) :name)
                       (push (tval toks i) names) (incf i)))
                    ((and (tname= toks i "const") (tname= toks (1+ i) "enum"))
                     (incf i) (incf i)
                     (when (eq (ttype toks i) :name)
                       (push (tval toks i) names) (incf i)))
                    (t nil)))
                 (t (incf i)))))
    (nreverse names)))

(defun ns-skip-balanced (toks i end open close)
  "From index I at OPEN, return index past matching CLOSE (before END)."
  (let ((d 0))
    (loop while (< i end)
          do (cond ((tpunct= toks i open) (incf d) (incf i))
                   ((tpunct= toks i close)
                    (decf d) (incf i) (when (zerop d) (return-from ns-skip-balanced i)))
                   (t (incf i))))
    i))

(defun ns-skip-statement (toks i end)
  "Advance I past one top-level statement (rough; respects braces/parens)."
  (loop while (< i end)
        do (cond ((tpunct= toks i "{")
                  (setf i (ns-skip-balanced toks i end "{" "}")))
                 ((tpunct= toks i "(")
                  (setf i (ns-skip-balanced toks i end "(" ")")))
                 ((tpunct= toks i "[")
                  (setf i (ns-skip-balanced toks i end "[" "]")))
                 ((tpunct= toks i ";")
                  (return-from ns-skip-statement (1+ i)))
                 (t (incf i))))
  i)

(defun ns-slice (src toks a b)
  "Source text covering tokens [A, B)."
  (if (>= a b)
      ""
      (subseq src
              (eng:token-start (aref toks a))
              (if (< b (length toks))
                  (eng:token-start (aref toks b))
                  (eng:token-end (aref toks (1- (length toks))))))))

(defun ns-decl-keyword-p (tok)
  "True if TOK is a keyword that introduces a binding name (do not rewrite the name)."
  (and tok (eq (eng:token-type tok) :name) (not (eng:token-escaped tok))
       (member (eng:token-value tok)
               '("function" "class" "enum" "const" "let" "var" "namespace" "module"
                 "async" "get" "set" "interface" "type")
               :test #'string=)))

(defun ns-rewrite-idents (src toks start end ns-name exports)
  "Copy tokens [START, END) rewriting free EXPORTS identifiers to NS-NAME.id.
Skips property access after `.` and binding names after declaration keywords."
  (if (or (null exports) (>= start end))
      (ns-slice src toks start end)
      (with-output-to-string (o)
        (let ((pos (eng:token-start (aref toks start))))
          (loop for i from start below end
                for tok = (aref toks i)
                for prev = (and (> i start) (aref toks (1- i)))
                do (let ((ts (eng:token-start tok))
                         (te (eng:token-end tok)))
                     (when (< pos ts) (write-string (subseq src pos ts) o))
                     (if (and (eq (eng:token-type tok) :name)
                              (not (eng:token-escaped tok))
                              (member (eng:token-value tok) exports :test #'string=)
                              (not (and prev (eq (eng:token-type prev) :punct)
                                        (string= (eng:token-value prev) ".")))
                              (not (ns-decl-keyword-p prev)))
                         (format o "~a.~a" ns-name (eng:token-value tok))
                         (write-string (subseq src ts te) o))
                     (setf pos te)))
          (let ((end-pos (if (< end (length toks))
                             (eng:token-start (aref toks end))
                             (eng:token-end (aref toks (1- (length toks)))))))
            (when (< pos end-pos) (write-string (subseq src pos end-pos) o)))))))

(defun ns-strip-fragment (text path)
  "Strip/transform a synthetic JS/TS fragment; fall back to TEXT on error."
  (handler-case (strip-types text (or path "ns-frag.ts"))
    (error () text)))

(defun transform-namespace-body (w body-lo body-hi ns-name exports)
  "Build JS for a runtime namespace body: export decls become assignments on NS-NAME;
free refs to exported names rewrite to NS-NAME.name; remaining types are stripped."
  (let* ((src (w-src w))
         (toks (w-toks w))
         (end body-hi)
         (i body-lo)
         (out (make-string-output-stream)))
    (loop while (< i end)
          do (cond
               ((tname= toks i "export")
                (let ((ex i))
                  (incf i)
                  (cond
                    ((or (tname= toks i "type") (tname= toks i "interface")
                         (tname= toks i "declare"))
                     (setf i (ns-skip-statement toks ex end)))
                    ((or (tname= toks i "const") (tname= toks i "let") (tname= toks i "var"))
                     (incf i)
                     (if (eq (ttype toks i) :name)
                         (let ((bname (tval toks i)))
                           (incf i)
                           (when (tpunct= toks i ":")
                             (setf i (skip-type toks (1+ i))))
                           (if (tpunct= toks i "=")
                               (progn
                                 (incf i)
                                 (let ((init-start i)
                                       (j i))
                                   (loop while (< j end)
                                         do (cond ((tpunct= toks j "{")
                                                   (setf j (ns-skip-balanced toks j end "{" "}")))
                                                  ((tpunct= toks j "(")
                                                   (setf j (ns-skip-balanced toks j end "(" ")")))
                                                  ((tpunct= toks j "[")
                                                   (setf j (ns-skip-balanced toks j end "[" "]")))
                                                  ((or (tpunct= toks j ",")
                                                       (tpunct= toks j ";"))
                                                   (return))
                                                  (t (incf j))))
                                   (format out "~a.~a=~a;"
                                           ns-name bname
                                           (ns-rewrite-idents src toks init-start j
                                                              ns-name exports))
                                   (setf i j)
                                   (when (or (tpunct= toks i ";") (tpunct= toks i ","))
                                     (incf i))))
                               (progn
                                 (format out "~a.~a=void 0;" ns-name bname)
                                 (when (tpunct= toks i ";") (incf i)))))
                         (setf i (ns-skip-statement toks ex end))))
                    ((or (tname= toks i "function")
                         (and (tname= toks i "async") (tname= toks (1+ i) "function")))
                     (let ((fn-start i) (async-p (tname= toks i "async")))
                       (declare (ignore async-p))
                       (when (tname= toks i "async") (incf i))
                       (incf i)
                       (when (tpunct= toks i "*") (incf i))
                       (let ((fname (and (eq (ttype toks i) :name) (tval toks i))))
                         (when fname (incf i))
                         (when (tpunct= toks i "<")
                           (setf i (skip-type toks i)))
                         (when (tpunct= toks i "(")
                           (setf i (ns-skip-balanced toks i end "(" ")")))
                         (when (tpunct= toks i ":")
                           (setf i (skip-type toks (1+ i))))
                         (when (tpunct= toks i "{")
                           (setf i (ns-skip-balanced toks i end "{" "}")))
                         (let* ((raw (ns-rewrite-idents src toks fn-start i ns-name exports))
                                (stripped (ns-strip-fragment raw (w-path w))))
                           (write-string stripped out)
                           (unless (and (plusp (length stripped))
                                        (find (char stripped (1- (length stripped)))
                                              '(#\; #\} #\Newline)))
                             (write-char #\; out))
                           (when fname
                             (format out "~a.~a=~a;" ns-name fname fname))))))
                    ((or (tname= toks i "class")
                         (and (tname= toks i "abstract") (tname= toks (1+ i) "class")))
                     (let ((c-start i))
                       (when (tname= toks i "abstract") (incf i))
                       (incf i)
                       (let ((cname (and (eq (ttype toks i) :name) (tval toks i))))
                         (when cname (incf i))
                         (loop while (and (< i end) (not (tpunct= toks i "{")))
                               do (incf i))
                         (when (tpunct= toks i "{")
                           (setf i (ns-skip-balanced toks i end "{" "}")))
                         (let* ((raw (ns-rewrite-idents src toks c-start i ns-name exports))
                                (stripped (ns-strip-fragment raw (w-path w))))
                           (write-string stripped out)
                           (write-char #\; out)
                           (when cname
                             (format out "~a.~a=~a;" ns-name cname cname))))))
                    ((or (tname= toks i "enum")
                         (and (tname= toks i "const") (tname= toks (1+ i) "enum")))
                     (let ((e-start i))
                       (when (tname= toks i "const") (incf i))
                       (incf i)
                       (let ((ename (and (eq (ttype toks i) :name) (tval toks i))))
                         (when ename (incf i))
                         (when (tpunct= toks i "{")
                           (setf i (ns-skip-balanced toks i end "{" "}")))
                         (when (tpunct= toks i ";") (incf i))
                         (let* ((raw (ns-slice src toks e-start i))
                                (stripped (ns-strip-fragment raw (w-path w))))
                           (write-string stripped out)
                           (when ename
                             (format out "~a.~a=~a;" ns-name ename ename))))))
                    ((or (tname= toks i "namespace") (tname= toks i "module"))
                     (let ((n-start i))
                       (incf i)
                       (let ((nname (and (member (ttype toks i) '(:name :string))
                                         (tval toks i))))
                         (when nname (incf i))
                         (when (tpunct= toks i "{")
                           (setf i (ns-skip-balanced toks i end "{" "}")))
                         (let* ((raw (ns-slice src toks n-start i))
                                (stripped (ns-strip-fragment raw (w-path w))))
                           (write-string stripped out)
                           (when nname
                             (format out "~a.~a=~a;" ns-name nname nname))))))
                    (t
                     (let ((rest (ns-skip-statement toks i end)))
                       (write-string (ns-rewrite-idents src toks i rest ns-name exports) out)
                       (setf i rest))))))
               (t
                (let ((stmt-start i))
                  (setf i (ns-skip-statement toks i end))
                  (when (= i stmt-start) (incf i))
                  (let* ((raw (ns-rewrite-idents src toks stmt-start i ns-name exports))
                         (stripped (ns-strip-fragment raw (w-path w))))
                    (write-string stripped out))))))
    (get-output-stream-string out)))

(defun scan-namespace (w &optional ambient)
  "namespace/module N { … }: erase if type-only (or AMBIENT); else emit runtime IIFE."
  (let* ((start (w-i w))
         (export-p (w-prev-export-p w start))
         (span-start (if export-p
                         (w-char-start w (1- start))
                         (w-char-start w start))))
    (w-adv w)                                  ; namespace/module
    (unless (member (w-cty w) '(:name :string))
      (w-err w "TypeScript namespace requires a name"))
    (let ((name (if (eq (w-cty w) :string)
                    ;; string module name — rare; use a safe binder
                    (format nil "M_~a" (w-i w))
                    (w-cv w))))
      (w-adv w)
      (loop until (or (w-eof w) (w-punct w "{")) do (w-adv w))
      (cond
        ((not (w-punct w "{"))
         (w-err w "TypeScript namespace requires a body"))
        ((or ambient (namespace-type-only-p w))
         (w-skip-balanced-nostrip w)
         (w-erase-toks w (if export-p (1- start) start) (w-i w)))
        (t
         (let* ((brace-i (w-i w))
                (body-lo (1+ brace-i)))
           (w-skip-balanced-nostrip w)         ; leaves i past `}`
           (let* ((body-hi (1- (w-i w)))       ; index of `}`
                  (span-end (w-char-end w (1- (w-i w))))
                  (exports (ns-collect-exports (w-toks w) body-lo body-hi))
                  (body-js (transform-namespace-body w body-lo body-hi name exports))
                  (js (emit-namespace-js name body-js :export-p export-p)))
             (w-replace-span w span-start span-end js))))))))

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
      ;; import x = require(...) / import x = NS.Y → const x = …
      ((and (eq (ttype (w-toks w) (1+ (w-i w))) :name)
            (tpunct= (w-toks w) (+ (w-i w) 2) "="))
       (let* ((span-start (w-char-start w start))
              (name (tval (w-toks w) (1+ (w-i w)))))
         (setf (w-i w) (+ (w-i w) 3))          ; past import Name =
         (let ((rhs-start (w-i w)))
           (loop until (or (w-eof w) (w-punct w ";") (w-cur-nl-terminates w))
                 do (scan-token w))
           (let* ((rhs-end (w-i w))
                  (rhs (if (< rhs-start rhs-end)
                           (subseq (w-src w)
                                   (w-char-start w rhs-start)
                                   (w-char-end w (1- rhs-end)))
                           "void 0"))
                  (span-end (if (w-punct w ";")
                                (progn (w-adv w) (w-char-end w (1- (w-i w))))
                                (if (> rhs-end rhs-start)
                                    (w-char-end w (1- rhs-end))
                                    (w-char-end w start)))))
             (w-replace-span w span-start span-end
                             (emit-import-equals name (string-trim '(#\Space #\Tab #\Newline) rhs)))))))
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
      ;; export = foo → module.exports = foo
      ((tpunct= (w-toks w) (1+ (w-i w)) "=")
       (let ((span-start (w-char-start w start)))
         (setf (w-i w) (+ (w-i w) 2))          ; past export =
         (let ((rhs-start (w-i w)))
           (loop until (or (w-eof w) (w-punct w ";") (w-cur-nl-terminates w))
                 do (scan-token w))
           (let* ((rhs-end (w-i w))
                  (rhs (if (< rhs-start rhs-end)
                           (subseq (w-src w)
                                   (w-char-start w rhs-start)
                                   (w-char-end w (1- rhs-end)))
                           "void 0"))
                  (span-end (if (w-punct w ";")
                                (progn (w-adv w) (w-char-end w (1- (w-i w))))
                                (if (> rhs-end rhs-start)
                                    (w-char-end w (1- rhs-end))
                                    (w-char-end w start)))))
             (w-replace-span w span-start span-end
                             (emit-export-equals (string-trim '(#\Space #\Tab #\Newline) rhs)))))))
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
    ;; experimental decorators leading a declaration
    ((w-punct w "@")
     (let ((decs (consume-decorator-list w)))
       (cond
         ((and (leader= w "export")
               (or (tname= (w-toks w) (1+ (w-i w)) "class")
                   (and (tname= (w-toks w) (1+ (w-i w)) "default")
                        (tname= (w-toks w) (+ (w-i w) 2) "class"))
                   (and (tname= (w-toks w) (1+ (w-i w)) "abstract")
                        (tname= (w-toks w) (+ (w-i w) 2) "class"))))
          (w-adv w)                            ; export
          (when (w-name w "default") (w-adv w))
          (when (and (leader= w "abstract") (tname= (w-toks w) (1+ (w-i w)) "class"))
            (w-erase-1 w (w-i w)) (w-adv w))
          (scan-class w decs))
         ((and (leader= w "abstract") (tname= (w-toks w) (1+ (w-i w)) "class"))
          (w-erase-1 w (w-i w)) (w-adv w) (scan-class w decs))
         ((leader= w "class") (scan-class w decs))
         (t (w-err w "TypeScript decorators are only supported on classes and class members")))))
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
    ;; Value `enum` / `const enum` → runtime IIFE emit (Phase 39 / Yes strip).
    ;; Ambient forms under `declare` use scan-namespace-or-stmt → scan-enum-ambient.
    ((or (leader= w "enum")
         (and (leader= w "const") (tname= (w-toks w) (1+ (w-i w)) "enum")))
     (scan-enum w))
    ;; `abstract class …` — only before `class` (not `abstract` as a value binding)
    ((and (leader= w "abstract") (tname= (w-toks w) (1+ (w-i w)) "class"))
     (w-erase-1 w (w-i w)) (w-adv w) (scan-class w nil))
    ((leader= w "class") (scan-class w nil))
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
  "Tokenize SOURCE and return the ordered list of (start . end) char spans to erase.
Compatibility wrapper — prefers SCAN-TRANSFORMS for full rewrite plans."
  (nth-value 0 (scan-transforms source path)))

(defun scan-transforms (source path)
  "Tokenize SOURCE; return (values erasures replacements).
ERASURES are (start . end) char spans; REPLACEMENTS are (start end text) lists."
  (let ((w (make-walker :toks (tokenize source path) :src source :path path)))
    (scan-program w)
    (when (w-need-decorate-helper w)
      ;; inject __decorate/__param once at file start
      (w-replace-span w 0 0 *decorate-helper-js*))
    (values (sort (w-erasures w) #'< :key #'car)
            (sort (w-replacements w) #'< :key #'first))))
