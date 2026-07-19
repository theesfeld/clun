;;;; ts-type.lisp — the balanced type-expression skipper (PLAN.md §3.3, Phase 09).
;;;; Operates on a token VECTOR produced by ts-scan's tokenizer (regex/template
;;;; already resolved). skip-type returns the index of the first token PAST a
;;;; complete TS type; > / >> / >>> over-close is split against the <-depth.

(in-package :clun.transpiler)

(declaim (inline tk ttype tval))
(defun tk (toks i) (when (< i (length toks)) (aref toks i)))
(defun ttype (toks i) (let ((tok (tk toks i))) (and tok (eng:token-type tok))))
(defun tval (toks i) (let ((tok (tk toks i)))
                       (and tok (member (eng:token-type tok) '(:punct :name))
                            (eng:token-value tok))))
(defun tpunct= (toks i s) (and (eq (ttype toks i) :punct) (string= (tval toks i) s)))
(defun tname= (toks i s) (and (eq (ttype toks i) :name) (not (eng:token-escaped (tk toks i)))
                              (string= (tval toks i) s)))

(defparameter *type-continuers*
  '("|" "&" "." "extends" "keyof" "typeof" "infer" "readonly" "is" "asserts" "in" "new" "out")
  "Tokens that, at type depth 0, keep us inside a type (so `expect` becomes true).")

(defun angle-closers (v)
  "How many `>` a `>`-family punct V closes (0 if it is not one)."
  (cond ((string= v ">") 1)
        ((string= v ">>") 2)
        ((string= v ">>>") 3)
        ((string= v ">=") 1)          ; the residual `=` is not our concern (type-arg > then =)
        ((string= v ">>=") 2)
        ((string= v ">>>=") 3)
        (t 0)))

(defun skip-type (toks i &key arrow-return)
  "Return the index just past a complete type starting at token I. Balanced across
() [] {} <>; stays in-type across | & => extends ?: (conditional). Terminates at a
top-level , ; = or an unmatched ) ] } or EOF. When ARROW-RETURN, a top-level `=>` also
terminates (it is the enclosing arrow's `=>`, not a function-type arrow). Signals on
gross underflow."
  (let ((n (length toks)) (angle 0) (paren 0) (bracket 0) (brace 0)
        (expect t))                    ; t => next token starts a type atom
    (loop
      (when (>= i n) (return i))
      (let* ((tok (aref toks i)) (ty (eng:token-type tok))
             (top (and (zerop angle) (zerop paren) (zerop bracket) (zerop brace))))
        (case ty
          (:eof (return i))
          (:punct
           (let ((v (eng:token-value tok)))
             (cond
               ;; `(` starts a function-type param list only at a type-atom start
               ;; (expect) or when nested; after a complete top-level type it is a
               ;; CALL and terminates the type (e.g. `foo<T>(…)`).
               ((string= v "(") (if (or expect (not top))
                                    (progn (incf paren) (incf i) (setf expect t))
                                    (return i)))
               ((string= v "[") (incf bracket) (incf i) (setf expect t))  ; T[] / tuple / index always continues
               ((string= v "{") (if (or expect (not top))
                                    (progn (incf brace) (incf i) (setf expect t))
                                    (return i)))  ; `{` after a complete top type = a body
               ((string= v "<") (incf angle) (incf i) (setf expect t))
               ((string= v ")") (if (plusp paren) (progn (decf paren) (incf i) (setf expect nil))
                                    (return i)))
               ((string= v "]") (if (plusp bracket) (progn (decf bracket) (incf i) (setf expect nil))
                                    (return i)))
               ((string= v "}") (if (plusp brace) (progn (decf brace) (incf i) (setf expect nil))
                                    (return i)))
               ((plusp (angle-closers v))
                (if (plusp angle)
                    (progn (decf angle (min angle (angle-closers v))) (incf i) (setf expect nil))
                    (return i)))         ; a `>` with no open `<` ends the type
               ;; combinators / punctuation that continue a type
               ((member v '("|" "&" "=>" "?" ":" "," ";" "=" "..." "-" "+") :test #'string=)
                (cond
                  ;; a top-level terminator (not inside any group)
                  ((and top (member v '("," ";" "=") :test #'string=)) (return i))
                  ;; `=>` continues a type only as a FUNCTION-TYPE arrow — i.e. right
                  ;; after a `)` param list; otherwise it is the outer arrow => body.
                  ;; In ARROW-RETURN mode a top-level `=>` always terminates (it is the
                  ;; enclosing arrow); a parenthesized return type already closed its `)`.
                  ((string= v "=>")
                   (if (and (not (and arrow-return top))
                            (plusp i) (tpunct= toks (1- i) ")"))
                       (progn (incf i) (setf expect t))
                       (return i)))
                  ((member v '("|" "&" "extends") :test #'string=) (incf i) (setf expect t))
                  ((member v '("?" ":") :test #'string=) (incf i) (setf expect t)) ; conditional
                  ((string= v ",") (incf i) (setf expect t))   ; inside a group
                  ((member v '("..." "-" "+") :test #'string=) (incf i) (setf expect t))
                  (t (incf i))))
               (t (incf i) (setf expect nil)))))
          (:name
           (let ((v (eng:token-value tok)))
             (cond
               ;; `extends` at depth 0 after a type = conditional/constraint → continue
               ((member v *type-continuers* :test #'string=) (incf i) (setf expect t))
               ;; `import("...")` type
               ((and (string= v "import") (tpunct= toks (1+ i) "(")) (incf i) (setf expect nil))
               ;; After a complete top-level type atom, a bare name starts a value
               ;; expression (e.g. angle-cast `<T>expr` must not swallow `expr`).
               ((and top (not expect)) (return i))
               (t (incf i) (setf expect nil)))))    ; a type-name atom
          ;; string/number/bigint literal types, and a template-literal type — but a
          ;; `:template` is a type ONLY at an atom position (expect); after a complete
          ;; type it is a tagged-template argument / the substitution tail → terminate.
          ((:string :num :bigint)
           (if (and top (not expect))
               (return i)
               (progn (incf i) (setf expect nil))))
          (:template (if expect (progn (incf i) (setf expect nil)) (return i)))
          (t (incf i) (setf expect nil)))))))
