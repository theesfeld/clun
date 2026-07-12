;;;; parser.lisp — recursive-descent JS-regex parser (PLAN.md §3.1, Phase 10). Operates
;;;; on the pattern as a code-unit string. Two passes: count-capturing-groups (for
;;;; backref validation + named-group indices), then parse to the AST. Malformed input
;;;; → throw-syntax-error (surfaces as a JS SyntaxError).

(in-package :clun.engine)

(defstruct (rxp (:conc-name rxp-) (:constructor %make-rxp (src ncap names uflag)))
  (src "" :type simple-string) (pos 0 :type fixnum) (ncap 0 :type fixnum)
  names (uflag nil) (cap 0 :type fixnum))

(declaim (inline rxp-peek rxp-peek2 rxp-eof))
(defun rxp-peek (p &optional (k 0))
  (let ((i (+ (rxp-pos p) k))) (when (< i (length (rxp-src p))) (char (rxp-src p) i))))
(defun rxp-eof (p) (>= (rxp-pos p) (length (rxp-src p))))
(defun rxp-adv (p) (prog1 (char (rxp-src p) (rxp-pos p)) (incf (rxp-pos p))))
(defun rxp-err (p fmt &rest args)
  (throw-syntax-error (format nil "Invalid regular expression: ~a" (apply #'format nil fmt args))))
(defun rxp-eat (p ch)
  (if (eql (rxp-peek p) ch) (incf (rxp-pos p)) (rxp-err p "expected '~a'" ch)))

;;; --- pass 1: capturing-group count + named-group index map ------------------

(defun count-capturing-groups (src)
  "Return (values NCAP NAME-ALIST). NAME-ALIST maps a named group's name -> its 1-based
capture index."
  (let ((n 0) (names '()) (i 0) (len (length src)) (in-class nil))
    (loop while (< i len) do
      (let ((c (char src i)))
        (cond
          ((char= c #\\) (incf i 2))
          ((and (char= c #\[) (not in-class)) (setf in-class t) (incf i))
          ((and (char= c #\]) in-class) (setf in-class nil) (incf i))
          ((and (char= c #\() (not in-class))
           (if (and (< (1+ i) len) (char= (char src (1+ i)) #\?))
               (if (and (< (+ i 2) len) (char= (char src (+ i 2)) #\<)
                        (< (+ i 3) len) (not (member (char src (+ i 3)) '(#\= #\!))))
                   (let ((end (position #\> src :start (+ i 3))))
                     (incf n)
                     (cond
                       (end
                        (let ((name (subseq src (+ i 3) end)))
                          ;; §22.2.1: GroupName is a RegExpIdentifierName. Reject malformed
                          ;; names (space, digit-start, escapes) and duplicates LOUDLY —
                          ;; never silently expose a bad key. (\u-escaped names: loud gap.)
                          (unless (valid-group-name-p name)
                            (throw-syntax-error
                             "Invalid regular expression: Invalid capture group name"))
                          (when (assoc name names :test #'string=)
                            (throw-syntax-error
                             "Invalid regular expression: Duplicate capture group name"))
                          (push (cons name n) names))
                        (setf i (1+ end)))
                       (t (incf i))))
                   (incf i))                          ; (?: (?= (?! (?<= (?<!
               (progn (incf n) (incf i))))            ; capturing (
          (t (incf i)))))
    (values n (nreverse names))))

(defun valid-group-name-p (name)
  "A RegExpIdentifierName (approx): non-empty, IdentifierStart then IdentifierPart*.
Excludes escapes (a leading backslash fails) — \\u-escaped names surface as a loud
SyntaxError (a documented gap), not a silent wrong key."
  (and (plusp (length name))
       (let ((c0 (char name 0))) (or (alpha-char-p c0) (char= c0 #\_) (char= c0 #\$)))
       (every (lambda (c) (or (alphanumericp c) (char= c #\_) (char= c #\$))) name)))

;;; --- pass 2: the grammar ----------------------------------------------------

(defun parse-js-regex (pattern flags)
  "Parse PATTERN (with FLAGS string) into (values disjunction group-count name-alist)."
  (multiple-value-bind (ncap names) (count-capturing-groups pattern)
    (let ((p (%make-rxp (coerce pattern 'simple-string) ncap names (find #\u flags))))
      (let ((d (parse-disjunction p)))
        (unless (rxp-eof p) (rxp-err p "unexpected '~a'" (rxp-peek p)))
        (values d ncap names)))))

(defun parse-disjunction (p)
  (let ((alts (list (parse-alternative p))))
    (loop while (eql (rxp-peek p) #\|)
          do (rxp-adv p) (push (parse-alternative p) alts))
    (make-rx-disjunction (nreverse alts))))

(defun parse-alternative (p)
  (let ((terms '()))
    (loop until (or (rxp-eof p) (member (rxp-peek p) '(#\| #\))))
          do (push (parse-term p) terms))
    (make-rx-alternative (nreverse terms))))

(defun parse-term (p)
  (let ((c (rxp-peek p)))
    (cond
      ;; assertions (no quantifier)
      ((eql c #\^) (rxp-adv p) (make-rx-anchor :start))
      ((eql c #\$) (rxp-adv p) (make-rx-anchor :end))
      ((and (eql c #\\) (member (rxp-peek p 1) '(#\b #\B)))
       (rxp-adv p) (make-rx-anchor (if (char= (rxp-adv p) #\b) :word-boundary :non-word-boundary)))
      ;; a lookaround assertion (also un-quantifiable in u-mode; Annex B allows in
      ;; non-u, but PPCRE quantified lookaround is rare — we allow a quantifier)
      (t (let ((atom (parse-atom p)))
           (let ((q (parse-quantifier p)))
             (if q (make-rx-quant atom (first q) (second q) (third q)) atom)))))))

(defun parse-quantifier (p)
  "Return (min max greedy) or NIL. A `{` that isn't a valid quantifier is not consumed."
  (let ((c (rxp-peek p)))
    (flet ((greedy () (if (eql (rxp-peek p) #\?) (progn (rxp-adv p) nil) t)))
      (cond
        ((eql c #\*) (rxp-adv p) (list 0 nil (greedy)))
        ((eql c #\+) (rxp-adv p) (list 1 nil (greedy)))
        ((eql c #\?) (rxp-adv p) (list 0 1 (greedy)))
        ((eql c #\{) (parse-brace-quantifier p))
        (t nil)))))

(defun parse-brace-quantifier (p)
  "Parse `{n}` `{n,}` `{n,m}` at `{`; if not well-formed, leave `{` unconsumed → NIL."
  (let ((save (rxp-pos p)))
    (rxp-adv p)                                          ; {
    (let ((min (parse-decimal p)))
      (if (null min)
          (progn (setf (rxp-pos p) save) nil)            ; `{` is a literal
          (let ((max min))
            (cond ((eql (rxp-peek p) #\,)
                   (rxp-adv p)
                   (setf max (if (eql (rxp-peek p) #\}) nil (parse-decimal p))))
                  (t nil))
            (if (eql (rxp-peek p) #\})
                (progn (rxp-adv p)
                       (when (and max (< max min)) (rxp-err p "numbers out of order in {} quantifier"))
                       (let ((greedy (if (eql (rxp-peek p) #\?) (progn (rxp-adv p) nil) t)))
                         (list min max greedy)))
                (progn (setf (rxp-pos p) save) nil)))))))

(defun parse-decimal (p)
  (when (and (rxp-peek p) (digit-char-p (rxp-peek p)))
    (let ((n 0))
      (loop while (and (rxp-peek p) (digit-char-p (rxp-peek p)))
            do (setf n (+ (* n 10) (digit-char-p (rxp-adv p)))))
      n)))

(defun parse-atom (p)
  (let ((c (rxp-peek p)))
    (cond
      ((null c) (rxp-err p "unexpected end of pattern"))
      ((eql c #\.) (rxp-adv p) (make-rx-dot))
      ((eql c #\() (parse-group p))
      ((eql c #\[) (rx-parse-class p))
      ((eql c #\\) (parse-atom-escape p))
      ((member c '(#\* #\+ #\?)) (rxp-err p "nothing to repeat"))
      ((eql c #\)) (rxp-err p "unmatched ')'"))
      ;; Annex B: bare ] and } are literals
      (t (make-rx-char (char-code (rxp-adv p)))))))

(defun parse-group (p)
  (rxp-adv p)                                            ; (
  (cond
    ((eql (rxp-peek p) #\?)
     (rxp-adv p)                                         ; ?
     (let ((c (rxp-peek p)))
       (cond
         ((eql c #\:) (rxp-adv p) (let ((body (parse-disjunction p))) (rxp-eat p #\)) (make-rx-group :non-capture nil nil body)))
         ((eql c #\=) (rxp-adv p) (let ((body (parse-disjunction p))) (rxp-eat p #\)) (make-rx-look :ahead :pos body)))
         ((eql c #\!) (rxp-adv p) (let ((body (parse-disjunction p))) (rxp-eat p #\)) (make-rx-look :ahead :neg body)))
         ((eql c #\<)
          (rxp-adv p)                                    ; <
          (let ((c2 (rxp-peek p)))
            (cond
              ((eql c2 #\=) (rxp-adv p) (let ((body (parse-disjunction p))) (rxp-eat p #\)) (make-rx-look :behind :pos body)))
              ((eql c2 #\!) (rxp-adv p) (let ((body (parse-disjunction p))) (rxp-eat p #\)) (make-rx-look :behind :neg body)))
              (t ;; (?<name>
               (let ((name (parse-group-name p)))
                 (let ((idx (incf (rxp-cap p))) (body (parse-disjunction p)))
                   (rxp-eat p #\)) (make-rx-group :capture idx name body)))))))
         (t (rxp-err p "invalid group")))))
    (t ;; capturing (
     (let ((idx (incf (rxp-cap p))) (body (parse-disjunction p)))
       (rxp-eat p #\)) (make-rx-group :capture idx nil body)))))

(defun parse-group-name (p)
  (let ((out (make-string-output-stream)))
    (loop for c = (rxp-peek p)
          until (or (null c) (char= c #\>))
          do (write-char (rxp-adv p) out))
    (rxp-eat p #\>)
    (let ((s (get-output-stream-string out)))
      (when (zerop (length s)) (rxp-err p "empty group name"))
      s)))

;;; --- escapes (outside a class) ----------------------------------------------

(defun parse-atom-escape (p)
  (rxp-adv p)                                            ; backslash
  (let ((c (rxp-peek p)))
    (when (null c) (rxp-err p "trailing backslash"))
    (cond
      ((member c '(#\d #\D #\w #\W #\s #\S))
       (rxp-adv p) (make-rx-esc (ecase c (#\d :digit) (#\D :non-digit) (#\w :word)
                                       (#\W :non-word) (#\s :space) (#\S :non-space))))
      ((member c '(#\p #\P))                             ; \p{…} — no UCD yet (loud gap)
       (throw-syntax-error "Invalid regular expression: Unicode property escapes are not supported (Phase 10)"))
      ((digit-char-p c)                                  ; backref or legacy escape (Annex B)
       (if (char= c #\0)
           (if (and (rxp-peek p 1) (char<= #\0 (rxp-peek p 1) #\7))
               (make-rx-char (parse-octal p))            ; \0dd → octal
               (progn (rxp-adv p) (make-rx-char 0)))     ; \0 → NUL
           ;; NonZeroDigit: read the whole decimal run to test for a backref. If it is
           ;; not a valid backref, re-interpret (Annex B B.1.4): \1..\7 = LegacyOctal
           ;; (1-3 octal digits), \8/\9 = NonOctalDecimal → the LITERAL digit char.
           (let ((save (rxp-pos p)) (n (parse-decimal p)))
             (if (<= n (rxp-ncap p))
                 (make-rx-backref n nil)
                 (progn (setf (rxp-pos p) save)
                        (if (char<= #\1 (rxp-peek p) #\7)
                            (make-rx-char (parse-octal p))
                            (make-rx-char (char-code (rxp-adv p)))))))))
      ((eql c #\c)                                       ; \cX control escape
       ;; Annex B: \c NOT followed by a ControlLetter → a literal backslash; 'c' is
       ;; left to parse as an ordinary character (so /\c/ matches the 2 chars "\c").
       (if (let ((x (rxp-peek p 1))) (and x (alpha-char-p x)))
           (progn (rxp-adv p) (make-rx-char (logand (char-code (rxp-adv p)) #x1F)))
           (make-rx-char (char-code #\\))))
      ((eql c #\k)                                       ; \k<name> (named backref)
       (if (rxp-names p)
           (progn (rxp-adv p) (rxp-eat p #\<)
                  (let ((name (parse-name-until-gt p)))
                    (make-rx-backref (or (cdr (assoc name (rxp-names p) :test #'string=))
                                         (rxp-err p "unknown group name ~s" name))
                                     name)))
           (progn (rxp-adv p) (make-rx-char (char-code #\k)))))  ; identity escape
      (t (make-rx-char (parse-char-escape p))))))

(defun parse-name-until-gt (p)
  (let ((out (make-string-output-stream)))
    (loop for c = (rxp-peek p) until (or (null c) (char= c #\>)) do (write-char (rxp-adv p) out))
    (rxp-eat p #\>) (get-output-stream-string out)))

(defun parse-octal (p)
  (let ((n 0) (cnt 0))
    (loop while (and (< cnt 3) (rxp-peek p) (char<= #\0 (rxp-peek p) #\7))
          do (setf n (+ (* n 8) (- (char-code (rxp-adv p)) 48))) (incf cnt))
    n))

(defun parse-char-escape (p)
  "A ControlEscape / hex / unicode / control / identity escape → a code (unit)."
  (let ((c (rxp-adv p)))
    (case c
      (#\n 10) (#\r 13) (#\t 9) (#\f 12) (#\v 11) (#\0 0)
      (#\x (let ((h (parse-hex p 2))) (if h h (char-code #\x))))
      (#\u (parse-unicode-escape p))
      (#\c (let ((x (rxp-peek p)))
             (if (and x (alpha-char-p x)) (progn (rxp-adv p) (logand (char-code x) #x1F))
                 (char-code #\c))))              ; Annex B: literal 'c'
      (t (char-code c)))))                        ; identity escape

(defun parse-hex (p n)
  (let ((save (rxp-pos p)) (v 0))
    (dotimes (i n)
      (let ((c (rxp-peek p)))
        (if (and c (digit-char-p c 16)) (progn (setf v (+ (* v 16) (digit-char-p (rxp-adv p) 16))))
            (progn (setf (rxp-pos p) save) (return-from parse-hex nil)))))
    v))

(defun parse-unicode-escape (p)
  "\\uHHHH or (u-flag) \\u{H…}. Returns a code unit (or a code point in u-mode)."
  (if (and (eql (rxp-peek p) #\{) (rxp-uflag p))
      (progn (rxp-adv p)
             (let ((v 0))
               (loop for c = (rxp-peek p) until (or (null c) (char= c #\}))
                     do (unless (digit-char-p c 16) (rxp-err p "invalid unicode escape"))
                        (setf v (+ (* v 16) (digit-char-p (rxp-adv p) 16))))
               (rxp-eat p #\})
               (when (> v #x10FFFF) (rxp-err p "unicode code point out of range"))
               (when (> v #xFFFF)
                 (throw-syntax-error "Invalid regular expression: astral code points under /u are not supported (Phase 10)"))
               v))
      (let ((h (parse-hex p 4))) (if h h (char-code #\u)))))

;;; --- character classes ------------------------------------------------------

(defun rx-parse-class (p)
  (rxp-adv p)                                            ; [
  (let ((negated (when (eql (rxp-peek p) #\^) (rxp-adv p) t)) (items '()))
    (loop
      (let ((c (rxp-peek p)))
        (when (null c) (rxp-err p "unterminated character class"))
        (when (char= c #\]) (rxp-adv p) (return))
        (let ((atom (parse-class-atom p)))
          ;; a range a-b (only when both ends are single chars and '-' isn't at the edge)
          (if (and (integerp atom) (eql (rxp-peek p) #\-)
                   (rxp-peek p 1) (not (char= (rxp-peek p 1) #\])))
              (progn (rxp-adv p)                          ; -
                     (let ((hi (parse-class-atom p)))
                       (if (integerp hi)
                           (progn (when (> atom hi) (rxp-err p "range out of order in character class"))
                                  (push (make-rx-class-range atom hi) items))
                           ;; `\d-z` etc. → not a range; push both + a literal '-'
                           (progn (push atom items) (push (char-code #\-) items) (push hi items)))))
              (push atom items)))))
    (make-rx-class negated (nreverse items))))

(defun parse-class-atom (p)
  "A class member: an integer code (literal), or an rx-esc (class escape)."
  (let ((c (rxp-peek p)))
    (if (char= c #\\)
        (progn (rxp-adv p)
               (let ((e (rxp-peek p)))
                 (cond
                   ((member e '(#\d #\D #\w #\W #\s #\S))
                    (rxp-adv p) (make-rx-esc (ecase e (#\d :digit) (#\D :non-digit) (#\w :word)
                                                    (#\W :non-word) (#\s :space) (#\S :non-space))))
                   ((member e '(#\p #\P))
                    (throw-syntax-error "Invalid regular expression: Unicode property escapes are not supported (Phase 10)"))
                   ((eql e #\b) (rxp-adv p) 8)             ; \b = backspace in a class
                   ;; ClassEscape has no backreferences: \0..\7 = LegacyOctal (1-3
                   ;; octal digits), \8/\9 = literal digit char (Annex B B.1.2).
                   ((char<= #\0 e #\7) (parse-octal p))
                   ((or (eql e #\8) (eql e #\9)) (char-code (rxp-adv p)))
                   ((eql e #\c)                            ; \cX / literal '\' fallback
                    (if (let ((x (rxp-peek p 1))) (and x (alpha-char-p x)))
                        (progn (rxp-adv p) (logand (char-code (rxp-adv p)) #x1F))
                        (char-code #\\)))
                   (t (parse-char-escape p)))))            ; returns a code
        (char-code (rxp-adv p)))))
