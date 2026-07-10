;;;; lexer-tests.lisp — tokenizer: token types, escapes, templates, regexp, spans.

(in-package :clun-test)

(defun tok-list (src &optional strict)
  "Types+values of SRC's tokens (excluding EOF)."
  (mapcar (lambda (tk) (list (eng:token-type tk) (eng:token-value tk)))
          (butlast (eng:lex-all src strict))))

(define-test lexer/basic-tokens
  (is equal '((:name "let") (:name "x") (:punct "=") (:num 42d0) (:punct ";"))
      (tok-list "let x = 42;")))

(define-test lexer/numbers
  (is equal '((:num 255d0)) (tok-list "0xFF"))
  (is equal '((:num 15d0)) (tok-list "0o17"))
  (is equal '((:num 5d0)) (tok-list "0b101"))
  (is equal '((:num 1500d0)) (tok-list "1.5e3"))
  (is equal '((:num 0.5d0)) (tok-list ".5"))
  (is equal '((:bigint 123)) (tok-list "123n"))
  (is equal '((:num 493d0)) (tok-list "0755"))          ; legacy octal (sloppy)
  (is equal '((:num 89d0)) (tok-list "089")))           ; non-octal decimal (Annex B)

(define-test lexer/legacy-octal-strict-errors
  (fail (eng:lex-all "0755" t) eng:js-native-error))

(define-test lexer/string-escapes
  (is equal (list (list :string (concatenate 'string "a" (string #\Newline) "A" "B")))
      (tok-list "'a\\n\\x41\\u0042'"))
  ;; astral \u{} yields a surrogate PAIR (two UTF-16 code units), per Phase 01 repr
  (is equal (list (list :string (coerce (list (code-char #xD83D) (code-char #xDE00)) 'string)))
      (tok-list "'\\u{1F600}'")))

(define-test lexer/punctuators
  (is equal '((:punct ">>>=") (:punct "...") (:punct "=>") (:punct "**") (:punct "**="))
      (tok-list ">>>= ... => ** **=")))

(define-test lexer/keywords-are-names
  ;; keyword-ness is contextual — the lexer emits :name for all of them
  (is equal '((:name "if") (:name "function") (:name "yield") (:name "await") (:name "async"))
      (tok-list "if function yield await async")))

(define-test lexer/no-substitution-template
  (let ((tk (first (eng:lex-all "`abc`"))))
    (is eq :template (eng:token-type tk))
    (is eq :full (eng:token-tmpl-part tk))
    (is string= "abc" (eng:token-value tk))))

(define-test lexer/substitution-template
  ;; parser drives: head, expr, `}` punct, then reread-template for the tail
  (let ((lx (eng:make-lexer "`a${b}c`")))
    (let ((h (eng:next-token lx)))
      (eng:next-token lx)                 ; b
      (eng:next-token lx)                 ; }
      (let ((tail (eng:reread-template lx)))
        (is eq :head (eng:token-tmpl-part h))
        (is string= "a" (eng:token-value h))
        (is eq :tail (eng:token-tmpl-part tail))
        (is string= "c" (eng:token-value tail))))))

(define-test lexer/regexp-rescan
  (let ((lx (eng:make-lexer "/ab+[/]c/gi")))
    (let* ((slash (eng:next-token lx))
           (re (eng:reread-regexp lx slash)))
      (is eq :regexp (eng:token-type re))
      (is string= "ab+[/]c" (eng:token-value re))       ; / inside [] doesn't end it
      (is string= "gi" (eng:token-raw re)))))

(define-test lexer/nl-before-for-asi
  (let ((toks (eng:lex-all (format nil "a~%b"))))
    (is eq nil (eng:token-nl-before (first toks)))
    (is eq t (eng:token-nl-before (second toks)))))     ; newline before `b`

(define-test lexer/comments-are-trivia
  ;; comments produce no tokens but set nl-before and are recorded
  (is equal '((:name "a") (:name "b")) (tok-list "a /* c */ b"))
  (is equal '((:name "a")) (tok-list "a // trailing")))

(define-test lexer/token-span-property
  ;; the gate: slicing source by [start,end) reproduces each token's lexeme, and
  ;; tokens are contiguous modulo trivia (concatenating slices+gaps == source).
  (dolist (src (list "let x = 42 + foo.bar;"
                     "a>>>=b"
                     "f(1, 2, 'three')"
                     "x = a === b ? c : d"
                     "0xFF + 1.5e-3"
                     (format nil "line1~%  line2 // c~%line3")))
    (let ((lx (eng:make-lexer src)) (last-end 0) (reconstructed ""))
      (loop for tk = (eng:next-token lx)
            until (eq (eng:token-type tk) :eof)
            do (let ((s (eng:token-start tk)) (e (eng:token-end tk)))
                 (true (<= last-end s))                  ; ordered, non-overlapping
                 (true (< s e))                          ; non-empty span
                 (setf reconstructed
                       (concatenate 'string reconstructed
                                    (subseq src last-end e))) ; gap trivia + token
                 (setf last-end e)))
      (setf reconstructed (concatenate 'string reconstructed (subseq src last-end)))
      (is string= src reconstructed))))
