;;;; lexer.lisp — the tokenizer (PLAN.md Phase 02, §3.3). Reentrant (all state in
;;;; the `lexer` struct), exact offsets, trivia tracked, parser-driven regex-vs-
;;;; divide via re-scan, template continuations via re-scan. Doubles as the TS-strip
;;;; lexer. Every lexical error is a js-native-error :syntax-error — never a crash.
;;;;
;;;; Unicode identifier classification is approximated (ASCII + any code >= #x80)
;;;; until the build-time UCD tables land (later phase); documented in phase-02.md.

(in-package :clun.engine)

(defstruct (token (:constructor %make-token) (:copier nil))
  (type :eof :type keyword)
  value                        ; :name/:punct string; :num double; :bigint integer;
                               ; :string cooked; :regexp pattern; :template cooked (nil if invalid)
  (raw nil)                    ; :regexp flags; :template raw chars; else nil
  (start 0 :type fixnum)
  (end 0 :type fixnum)
  (line 1 :type fixnum)
  (col 0 :type fixnum)
  (nl-before nil)
  (tmpl-part nil)              ; :full :head :middle :tail for templates
  (escaped nil))              ; :name contained a \u escape (so it is never a keyword)

(defstruct (lexer (:constructor %make-lexer) (:copier nil))
  (src "" :type simple-string)
  (pos 0 :type fixnum)
  (len 0 :type fixnum)
  (line 1 :type fixnum)
  (line-start 0 :type fixnum)
  (comments nil))              ; reverse list of (start . end) comment spans (trivia retention)

(defun make-lexer (source)
  (let ((s (coerce source 'simple-string)))
    (%make-lexer :src s :len (length s))))

(declaim (inline lx-peek lx-peek2 lx-eof-p lx-code))
(defun lx-eof-p (lx) (>= (lexer-pos lx) (lexer-len lx)))
(defun lx-peek (lx &optional (k 0))
  (let ((i (+ (lexer-pos lx) k)))
    (if (< i (lexer-len lx)) (char (lexer-src lx) i) nil)))
(defun lx-code (lx &optional (k 0))
  (let ((c (lx-peek lx k))) (if c (char-code c) -1)))

(defun lex-error (lx fmt &rest args)
  (throw-syntax-error
   (format nil "~a (~a:~a)" (apply #'format nil fmt args)
           (lexer-line lx) (1+ (- (lexer-pos lx) (lexer-line-start lx))))))

;;; --- character classes ------------------------------------------------------

(declaim (inline line-terminator-p ws-p digit-p hex-digit-p
                 id-start-code-p id-part-code-p))
(defun line-terminator-p (code)
  (or (= code 10) (= code 13) (= code #x2028) (= code #x2029)))
(defun ws-p (code)
  (or (= code #x20) (= code 9) (= code 11) (= code 12) (= code #xA0) (= code #xFEFF)
      (= code #x1680) (<= #x2000 code #x200A) (= code #x202F) (= code #x205F) (= code #x3000)))
(defun digit-p (ch) (and ch (char<= #\0 ch #\9)))
(defun hex-digit-p (ch)
  (and ch (or (char<= #\0 ch #\9) (char<= #\a ch #\f) (char<= #\A ch #\F))))
(defun id-start-code-p (code)
  ;; ASCII letters / $ / _, or any non-ASCII that is not whitespace or a line
  ;; terminator (a coarse approximation of ID_Start until the UCD tables land).
  (or (<= 65 code 90) (<= 97 code 122) (= code #x24) (= code #x5F)
      (and (>= code #x80) (not (ws-p code)) (not (line-terminator-p code)))))
(defun id-part-code-p (code)
  (or (id-start-code-p code) (<= 48 code 57) (= code #x200C) (= code #x200D)))

;;; --- position / line bookkeeping -------------------------------------------

(defun advance-line (lx)
  "Consume one line terminator at pos (handling CRLF), updating line counters."
  (let ((c (lx-peek lx)))
    (incf (lexer-pos lx))
    (when (and (eql c #\Return) (eql (lx-peek lx) #\Newline))
      (incf (lexer-pos lx)))
    (incf (lexer-line lx))
    (setf (lexer-line-start lx) (lexer-pos lx))))

;;; --- trivia (whitespace + comments); returns T if a newline was crossed -----

(defun skip-trivia (lx)
  (let ((saw-nl nil))
    (loop
      (let ((c (lx-peek lx)))
        (cond
          ((null c) (return))
          ((line-terminator-p (char-code c)) (setf saw-nl t) (advance-line lx))
          ((ws-p (char-code c)) (incf (lexer-pos lx)))
          ;; line comment
          ((and (eql c #\/) (eql (lx-peek lx 1) #\/))
           (let ((start (lexer-pos lx)))
             (loop until (or (lx-eof-p lx) (line-terminator-p (lx-code lx)))
                   do (incf (lexer-pos lx)))
             (push (cons start (lexer-pos lx)) (lexer-comments lx))))
          ;; block comment
          ((and (eql c #\/) (eql (lx-peek lx 1) #\*))
           (let ((start (lexer-pos lx)))
             (incf (lexer-pos lx) 2)
             (loop
               (when (lx-eof-p lx) (lex-error lx "unterminated comment"))
               (cond ((and (eql (lx-peek lx) #\*) (eql (lx-peek lx 1) #\/))
                      (incf (lexer-pos lx) 2) (return))
                     ((line-terminator-p (lx-code lx)) (setf saw-nl t) (advance-line lx))
                     (t (incf (lexer-pos lx)))))
             (push (cons start (lexer-pos lx)) (lexer-comments lx))))
          ;; Annex B HTML-open comment: <!-- ... (line comment, sloppy Script)
          ((and (eql c #\<) (eql (lx-peek lx 1) #\!)
                (eql (lx-peek lx 2) #\-) (eql (lx-peek lx 3) #\-))
           (let ((start (lexer-pos lx)))
             (loop until (or (lx-eof-p lx) (line-terminator-p (lx-code lx)))
                   do (incf (lexer-pos lx)))
             (push (cons start (lexer-pos lx)) (lexer-comments lx))))
          ;; Annex B HTML-close comment: --> at start of line (after only trivia)
          ((and saw-nl (eql c #\-) (eql (lx-peek lx 1) #\-) (eql (lx-peek lx 2) #\>))
           (let ((start (lexer-pos lx)))
             (loop until (or (lx-eof-p lx) (line-terminator-p (lx-code lx)))
                   do (incf (lexer-pos lx)))
             (push (cons start (lexer-pos lx)) (lexer-comments lx))))
          (t (return)))))
    saw-nl))

;;; --- token constructor ------------------------------------------------------

(defun make-tok (lx type value start nl &key raw tmpl-part escaped)
  (%make-token :type type :value value :raw raw :start start :end (lexer-pos lx)
               :line (lexer-line lx)
               :col (- start (lexer-line-start lx))
               :nl-before nl :tmpl-part tmpl-part :escaped escaped))

;;; --- identifiers & keywords -------------------------------------------------

(defun read-unicode-escape-value (lx)
  "At a backslash starting \\uXXXX or \\u{...}; return the code point, advancing."
  (unless (eql (lx-peek lx) #\\) (lex-error lx "expected unicode escape"))
  (incf (lexer-pos lx))
  (unless (eql (lx-peek lx) #\u) (lex-error lx "invalid identifier escape"))
  (incf (lexer-pos lx))
  (cond
    ((eql (lx-peek lx) #\{)
     (incf (lexer-pos lx))
     (let ((v 0) (any nil))
       (loop for c = (lx-peek lx)
             while (hex-digit-p c)
             do (setf v (+ (* v 16) (digit-char-p c 16)) any t) (incf (lexer-pos lx)))
       (unless (and any (eql (lx-peek lx) #\})) (lex-error lx "invalid unicode escape"))
       (incf (lexer-pos lx))
       (when (> v #x10FFFF) (lex-error lx "unicode escape out of range"))
       v))
    (t
     (let ((v 0))
       (dotimes (i 4)
         (let ((c (lx-peek lx)))
           (unless (hex-digit-p c) (lex-error lx "invalid unicode escape"))
           (setf v (+ (* v 16) (digit-char-p c 16)))
           (incf (lexer-pos lx))))
       v))))

(defun read-name (lx start nl)
  "Read an IdentifierName (value = cooked name with escapes resolved)."
  (let ((out (make-array 8 :element-type 'character :adjustable t :fill-pointer 0))
        (first t) (escaped nil))
    (loop
      (let ((c (lx-peek lx)))
        (cond
          ((and c (eql c #\\))
           (setf escaped t)
           (let ((cp (read-unicode-escape-value lx)))
             (unless (if first (id-start-code-p cp) (id-part-code-p cp))
               (lex-error lx "invalid identifier escape"))
             (%push-code-point cp out)))
          ((and c (if first (id-start-code-p (char-code c)) (id-part-code-p (char-code c))))
           (vector-push-extend c out) (incf (lexer-pos lx)))
          (t (return))))
      (setf first nil))
    (make-tok lx :name (coerce out 'simple-string) start nl :escaped escaped)))

;;; --- numbers ----------------------------------------------------------------

(defun read-radix-int (lx radix)
  "Read digits of RADIX at pos into an integer (>=1 digit required)."
  (let ((v 0) (any nil))
    (loop for c = (lx-peek lx)
          for d = (and c (digit-char-p c radix))
          while d do (setf v (+ (* v radix) d) any t) (incf (lexer-pos lx)))
    (unless any (lex-error lx "missing digits in numeric literal"))
    ;; the trailing id-start check is done by finish-int-number, AFTER the optional
    ;; BigInt `n` suffix (which is itself an id-start char).
    v))

(defun read-number (lx start nl strict)
  (let ((c0 (lx-peek lx)))
    (when (eql c0 #\0)
      (case (lx-peek lx 1)
        ((#\x #\X) (incf (lexer-pos lx) 2)
         (return-from read-number (finish-int-number lx (read-radix-int lx 16) start nl)))
        ((#\o #\O) (incf (lexer-pos lx) 2)
         (return-from read-number (finish-int-number lx (read-radix-int lx 8) start nl)))
        ((#\b #\B) (incf (lexer-pos lx) 2)
         (return-from read-number (finish-int-number lx (read-radix-int lx 2) start nl)))
        ((#\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9)
         ;; legacy octal / non-octal decimal (Annex B; strict -> error)
         (when strict (lex-error lx "octal literals are not allowed in strict mode"))
         (return-from read-number (read-legacy-octal lx start nl)))))
    ;; decimal / float
    (loop while (digit-p (lx-peek lx)) do (incf (lexer-pos lx)))
    (let ((is-float nil))
      (when (eql (lx-peek lx) #\.)
        (setf is-float t) (incf (lexer-pos lx))
        (loop while (digit-p (lx-peek lx)) do (incf (lexer-pos lx))))
      (when (member (lx-peek lx) '(#\e #\E))
        (setf is-float t) (incf (lexer-pos lx))
        (when (member (lx-peek lx) '(#\+ #\-)) (incf (lexer-pos lx)))
        (unless (digit-p (lx-peek lx)) (lex-error lx "missing exponent digits"))
        (loop while (digit-p (lx-peek lx)) do (incf (lexer-pos lx))))
      (when (and (not is-float) (eql (lx-peek lx) #\n))
        (let ((int (parse-integer (lexer-src lx) :start start :end (lexer-pos lx))))
          (incf (lexer-pos lx))
          (when (and (lx-peek lx) (id-start-code-p (lx-code lx)))
            (lex-error lx "identifier directly after number"))
          (return-from read-number (make-tok lx :bigint int start nl))))
      (when (and (lx-peek lx) (id-start-code-p (lx-code lx)))
        (lex-error lx "identifier directly after number"))
      (let ((lexeme (subseq (lexer-src lx) start (lexer-pos lx))))
        (make-tok lx :num (js-string->number lexeme) start nl)))))

(defun finish-int-number (lx int start nl)
  (cond
    ((eql (lx-peek lx) #\n)
     (incf (lexer-pos lx))
     (when (and (lx-peek lx) (id-start-code-p (lx-code lx)))
       (lex-error lx "identifier directly after number"))
     (make-tok lx :bigint int start nl))
    (t
     (when (and (lx-peek lx) (id-start-code-p (lx-code lx)))
       (lex-error lx "identifier directly after number"))
     (with-js-floats (make-tok lx :num (coerce int 'double-float) start nl)))))

(defun read-legacy-octal (lx start nl)
  ;; leading 0 then digits: octal if all 0-7, else NonOctalDecimal (Annex B)
  (let ((all-octal t))
    (loop for c = (lx-peek lx) while (digit-p c)
          do (when (member c '(#\8 #\9)) (setf all-octal nil))
             (incf (lexer-pos lx)))
    (when (and (lx-peek lx) (id-start-code-p (lx-code lx)))
      (lex-error lx "identifier directly after number"))
    (let* ((lexeme (subseq (lexer-src lx) start (lexer-pos lx)))
           (val (if all-octal (parse-integer lexeme :radix 8)
                    (parse-integer lexeme :radix 10))))
      (with-js-floats (make-tok lx :num (coerce val 'double-float) start nl)))))

;;; --- string escapes (shared by strings & templates) ------------------------

(defun read-string-escape (lx out strict template)
  "Consume a backslash escape at pos, appending cooked code point(s) to OUT.
Returns :ok, or :invalid for an escape only legal in tagged templates (cooked=nil)."
  (incf (lexer-pos lx))                                   ; the backslash
  (let ((c (lx-peek lx)))
    (cond
      ((null c) (lex-error lx "unterminated string"))
      ((line-terminator-p (char-code c)) (advance-line lx))          ; line continuation
      (t
       (incf (lexer-pos lx))
       (case c
         (#\n (vector-push-extend #\Newline out))
         (#\t (vector-push-extend #\Tab out))
         (#\r (vector-push-extend #\Return out))
         (#\b (vector-push-extend #\Backspace out))
         (#\f (vector-push-extend #\Page out))
         (#\v (vector-push-extend (code-char 11) out))
         (#\0 (if (digit-p (lx-peek lx))
                  (if template (return-from read-string-escape :invalid)
                      (read-legacy-octal-escape lx out (char-code c) strict))
                  (vector-push-extend (code-char 0) out)))
         ((#\1 #\2 #\3 #\4 #\5 #\6 #\7)
          (if template (return-from read-string-escape :invalid)
              (read-legacy-octal-escape lx out (char-code c) strict)))
         ((#\8 #\9)
          (when (or strict template) (return-from read-string-escape :invalid))
          (vector-push-extend c out))                    ; Annex B: \8 \9 -> the char
         (#\x
          (let ((v 0))
            (dotimes (i 2)
              (let ((h (lx-peek lx)))
                (unless (hex-digit-p h)
                  (if template (return-from read-string-escape :invalid)
                      (lex-error lx "invalid hex escape")))
                (setf v (+ (* v 16) (digit-char-p h 16))) (incf (lexer-pos lx))))
            (vector-push-extend (code-char v) out)))
         (#\u
          (decf (lexer-pos lx) 2)                        ; back to the backslash+u
          (let ((cp (handler-case (read-unicode-escape-value lx)
                      (js-native-error (e)
                        (if template (return-from read-string-escape :invalid)
                            (error e))))))
            (%push-code-point cp out)))
         (t (vector-push-extend c out)))))                ; \<other> -> the char
    :ok))

(defun read-legacy-octal-escape (lx out first-code strict)
  (when strict (lex-error lx "octal escape sequences are not allowed in strict mode"))
  (let ((v (- first-code (char-code #\0))))
    (loop repeat 2
          for c = (lx-peek lx)
          while (and c (char<= #\0 c #\7) (<= (+ (* v 8) (digit-char-p c 8)) 255))
          do (setf v (+ (* v 8) (digit-char-p c 8))) (incf (lexer-pos lx)))
    (vector-push-extend (code-char v) out)))

(defun read-string (lx start nl strict)
  (let ((quote (lx-peek lx))
        (out (make-array 8 :element-type 'character :adjustable t :fill-pointer 0)))
    (incf (lexer-pos lx))
    (loop
      (let ((c (lx-peek lx)))
        (cond
          ((null c) (lex-error lx "unterminated string literal"))
          ((eql c quote) (incf (lexer-pos lx)) (return))
          ;; only CR/LF terminate a string; LS/PS (U+2028/2029) are allowed (ES2019)
          ((or (= (char-code c) 10) (= (char-code c) 13))
           (lex-error lx "unterminated string literal"))
          ((eql c #\\) (read-string-escape lx out strict nil))
          (t (vector-push-extend c out) (incf (lexer-pos lx))))))
    (make-tok lx :string (coerce out 'simple-string) start nl)))

;;; --- templates --------------------------------------------------------------

(defun read-template-body (lx start nl head)
  "Read a template segment. HEAD=t consumes the opening backtick. Stops at ${ (part
:head/:middle) or ` (part :full/:tail). Cooked=nil if an invalid escape appears."
  (when head (incf (lexer-pos lx)))                       ; opening `
  (let ((out (make-array 8 :element-type 'character :adjustable t :fill-pointer 0))
        (cooked-ok t) (raw-start (lexer-pos lx)))
    (loop
      (let ((c (lx-peek lx)))
        (cond
          ((null c) (lex-error lx "unterminated template literal"))
          ((eql c #\`)
           (let ((raw (subseq (lexer-src lx) raw-start (lexer-pos lx))))
             (incf (lexer-pos lx))
             (return-from read-template-body
               (make-tok lx :template (and cooked-ok (coerce out 'simple-string)) start nl
                         :raw raw :tmpl-part (if head :full :tail)))))
          ((and (eql c #\$) (eql (lx-peek lx 1) #\{))
           (let ((raw (subseq (lexer-src lx) raw-start (lexer-pos lx))))
             (incf (lexer-pos lx) 2)
             (return-from read-template-body
               (make-tok lx :template (and cooked-ok (coerce out 'simple-string)) start nl
                         :raw raw :tmpl-part (if head :head :middle)))))
          ((eql c #\\)
           (when (eq (read-string-escape lx out nil t) :invalid) (setf cooked-ok nil)))
          ((line-terminator-p (char-code c))
           ;; TV/TRV normalize CR and CRLF to LF
           (advance-line lx) (vector-push-extend #\Newline out))
          (t (vector-push-extend c out) (incf (lexer-pos lx))))))))

(defun reread-template (lx)
  "After a substitution's closing `}` (already consumed by the parser as a punct),
resume the template from `}` — the caller passes us positioned AT the `}`."
  ;; The parser calls this positioned so that pos is just past the `}`. We read the
  ;; middle/tail starting here (raw begins after the `}`).
  (let ((start (lexer-pos lx)))
    (read-template-body lx start nil nil)))

;;; --- regexp (via re-scan) ---------------------------------------------------

(defun reread-regexp (lx tok)
  "Re-scan a `/` or `/=` punct TOK as a RegularExpressionLiteral. Repositions to the
token start; returns a :regexp token (value=pattern, raw=flags)."
  (setf (lexer-pos lx) (token-start tok))
  (let ((start (lexer-pos lx)) (nl (token-nl-before tok)) (in-class nil))
    (incf (lexer-pos lx))                                 ; the leading /
    (loop
      (let ((c (lx-peek lx)))
        (cond
          ((or (null c) (line-terminator-p (char-code c)))
           (lex-error lx "unterminated regular expression"))
          ((eql c #\\)
           (incf (lexer-pos lx))
           (when (or (lx-eof-p lx) (line-terminator-p (lx-code lx)))
             (lex-error lx "unterminated regular expression"))
           (incf (lexer-pos lx)))
          ((eql c #\[) (setf in-class t) (incf (lexer-pos lx)))
          ((eql c #\]) (setf in-class nil) (incf (lexer-pos lx)))
          ((and (eql c #\/) (not in-class)) (incf (lexer-pos lx)) (return))
          (t (incf (lexer-pos lx))))))
    (let ((pat-end (1- (lexer-pos lx)))
          (flags-start (lexer-pos lx)))
      ;; flags are IdentifierPart, but all real flags are ASCII letters — stopping at
      ;; ASCII letters avoids the Unicode-whitespace over-acceptance of id-part-code-p
      (loop for c = (lx-peek lx)
            while (and c (let ((cc (char-code c))) (or (<= 97 cc 122) (<= 65 cc 90))))
            do (incf (lexer-pos lx)))
      (let ((flags (subseq (lexer-src lx) flags-start (lexer-pos lx))) (seen '()))
        ;; validate flags: only g/i/m/s/u/y, no duplicates (pattern validation is Phase 10)
        (loop for ch across flags do
          (unless (find ch "gimsuy")
            (lex-error lx "invalid regular expression flag '~:c'" ch))
          (when (member ch seen) (lex-error lx "duplicate regular expression flag '~:c'" ch))
          (push ch seen))
        (make-tok lx :regexp (subseq (lexer-src lx) (1+ start) pat-end) start nl :raw flags)))))

;;; --- punctuators ------------------------------------------------------------

(defun read-punct (lx start nl)
  (let ((c (lx-peek lx)) (c1 (lx-peek lx 1)) (c2 (lx-peek lx 2)) (c3 (lx-peek lx 3)))
    (flet ((emit (n str) (incf (lexer-pos lx) n) (make-tok lx :punct str start nl)))
      (case c
        (#\{ (emit 1 "{")) (#\} (emit 1 "}")) (#\( (emit 1 "(")) (#\) (emit 1 ")"))
        (#\[ (emit 1 "[")) (#\] (emit 1 "]")) (#\; (emit 1 ";")) (#\, (emit 1 ","))
        (#\~ (emit 1 "~")) (#\: (emit 1 ":")) (#\? (emit 1 "?"))
        (#\. (if (and (eql c1 #\.) (eql c2 #\.)) (emit 3 "...") (emit 1 ".")))
        (#\< (cond ((and (eql c1 #\<) (eql c2 #\=)) (emit 3 "<<="))
                   ((eql c1 #\<) (emit 2 "<<")) ((eql c1 #\=) (emit 2 "<=")) (t (emit 1 "<"))))
        (#\> (cond ((and (eql c1 #\>) (eql c2 #\>) (eql c3 #\=)) (emit 4 ">>>="))
                   ((and (eql c1 #\>) (eql c2 #\>)) (emit 3 ">>>"))
                   ((and (eql c1 #\>) (eql c2 #\=)) (emit 3 ">>="))
                   ((eql c1 #\>) (emit 2 ">>")) ((eql c1 #\=) (emit 2 ">=")) (t (emit 1 ">"))))
        (#\= (cond ((and (eql c1 #\=) (eql c2 #\=)) (emit 3 "==="))
                   ((eql c1 #\=) (emit 2 "==")) ((eql c1 #\>) (emit 2 "=>")) (t (emit 1 "="))))
        (#\! (cond ((and (eql c1 #\=) (eql c2 #\=)) (emit 3 "!=="))
                   ((eql c1 #\=) (emit 2 "!=")) (t (emit 1 "!"))))
        (#\+ (cond ((eql c1 #\+) (emit 2 "++")) ((eql c1 #\=) (emit 2 "+=")) (t (emit 1 "+"))))
        (#\- (cond ((eql c1 #\-) (emit 2 "--")) ((eql c1 #\=) (emit 2 "-=")) (t (emit 1 "-"))))
        (#\* (cond ((and (eql c1 #\*) (eql c2 #\=)) (emit 3 "**="))
                   ((eql c1 #\*) (emit 2 "**")) ((eql c1 #\=) (emit 2 "*=")) (t (emit 1 "*"))))
        (#\% (if (eql c1 #\=) (emit 2 "%=") (emit 1 "%")))
        (#\& (cond ((eql c1 #\&) (emit 2 "&&")) ((eql c1 #\=) (emit 2 "&=")) (t (emit 1 "&"))))
        (#\| (cond ((eql c1 #\|) (emit 2 "||")) ((eql c1 #\=) (emit 2 "|=")) (t (emit 1 "|"))))
        (#\^ (if (eql c1 #\=) (emit 2 "^=") (emit 1 "^")))
        (#\/ (if (eql c1 #\=) (emit 2 "/=") (emit 1 "/")))
        (t (lex-error lx "unexpected character ~:c" c))))))

;;; --- the main entry ---------------------------------------------------------

(defun next-token (lx &optional strict)
  "Read and return the next token, skipping trivia. A leading `/` is lexed as a
punct; the parser calls reread-regexp to reinterpret it in expression position."
  (let ((nl (skip-trivia lx))
        (start (lexer-pos lx)))
    ;; hashbang only valid at position 0 — handled by parse entry, not here
    (when (lx-eof-p lx)
      (return-from next-token (make-tok lx :eof nil start nl)))
    (let ((c (lx-peek lx)) (code (lx-code lx)))
      (cond
        ((id-start-code-p code) (read-name lx start nl))
        ((eql c #\\) (read-name lx start nl))            ; \u-escaped identifier start
        ((digit-p c) (read-number lx start nl strict))
        ((and (eql c #\.) (digit-p (lx-peek lx 1))) (read-number lx start nl strict))
        ((or (eql c #\") (eql c #\')) (read-string lx start nl strict))
        ((eql c #\`) (read-template-body lx start nl t))
        (t (read-punct lx start nl))))))

(defun lex-all (source &optional strict)
  "Tokenize SOURCE fully into a list (regex-vs-divide left to default; for tests)."
  (let ((lx (make-lexer source)) (toks '()))
    (loop for tok = (next-token lx strict)
          do (push tok toks)
          until (eq (token-type tok) :eof))
    (nreverse toks)))
