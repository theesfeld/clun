;;;; translate.lisp — JS-regex AST → CL-PPCRE parse tree (PLAN.md §3.1, Phase 10).
;;;; The crux: undo PPCRE's non-JS semantics (\s \w . ^ $) with explicit char-classes /
;;;; modeless anchors, and error LOUDLY on the documented gaps (var-length lookbehind,
;;;; \p{}, astral-/u). i/m/s are passed to create-scanner (not the tree); g/y drive exec.

(in-package :clun.engine)

(defvar *tr-dotall* nil)   ; s flag: `.` matches line terminators
(defvar *tr-multiline* nil) ; m flag: ^/$ match at line boundaries

;;; JS WhiteSpace + LineTerminator set, as PPCRE char-class items (PPCRE's own
;;; whitespace class is only 5 chars — JS has ~25 code points).
(defparameter +js-whitespace-items+
  (list (code-char 9) (code-char 10) (code-char 11) (code-char 12) (code-char 13)
        (code-char #x20) (code-char #xA0) (code-char #x1680)
        (list :range (code-char #x2000) (code-char #x200A))
        (code-char #x2028) (code-char #x2029) (code-char #x202F)
        (code-char #x205F) (code-char #x3000) (code-char #xFEFF)))

(defparameter +js-word-items+
  (list (list :range #\A #\Z) (list :range #\a #\z) (list :range #\0 #\9) #\_))

;;; JS LineTerminator set (used by /m anchors and `.`): LF CR LS PS.
(defparameter +js-line-terminators+
  (list (code-char 10) (code-char 13) (code-char #x2028) (code-char #x2029)))

(defun complement-ranges (covered &optional (max #xFFFF))
  "COVERED = an ASCENDING list of (lo . hi) inclusive code-point ranges. Return the
complement over [0,MAX] as CL-PPCRE char-class items (a code-char or (:range lo hi)).
Used to express JS \\D/\\W/\\S INSIDE a character class as explicit ranges — PPCRE's
own :non-*-char-class symbols use the wrong (Unicode / 5-char) sets."
  (let ((items '()) (next 0))
    (flet ((emit (lo hi)
             (push (if (= lo hi) (code-char lo) (list :range (code-char lo) (code-char hi)))
                   items)))
      (dolist (r covered)
        (destructuring-bind (lo . hi) r
          (when (> lo next) (emit next (1- lo)))
          (setf next (max next (1+ hi)))))
      (when (<= next max) (emit next max)))
    (nreverse items)))

;; ASCENDING covered-sets for the JS shorthands (code points).
(defparameter +js-digit-covered+ '((48 . 57)))
(defparameter +js-word-covered+ '((48 . 57) (65 . 90) (95 . 95) (97 . 122)))
(defparameter +js-whitespace-covered+
  '((9 . 13) (32 . 32) (160 . 160) (5760 . 5760) (8192 . 8202) (8232 . 8233)
    (8239 . 8239) (8287 . 8287) (12288 . 12288) (65279 . 65279)))

(defun translate-regex (disjunction group-count name-alist flags)
  "Return a CL-PPCRE parse tree for the AST. FLAGS is the raw flag string."
  (declare (ignore group-count name-alist))
  (let ((*tr-dotall* (and (find #\s flags) t))
        (*tr-multiline* (and (find #\m flags) t)))
    (tr-node disjunction)))

(defun tr-node (n)
  (etypecase n
    (rx-disjunction
     (let ((alts (mapcar #'tr-node (rx-disjunction-alternatives n))))
       (if (= (length alts) 1) (first alts) (cons :alternation alts))))
    (rx-alternative
     (let ((terms (mapcar #'tr-node (rx-alternative-terms n))))
       (cond ((null terms) :void) ((= (length terms) 1) (first terms)) (t (cons :sequence terms)))))
    (rx-char (code-char (rx-char-code n)))
    (rx-dot (if *tr-dotall* :everything
                (cons :inverted-char-class +js-line-terminators+)))
    (rx-esc (tr-esc (rx-esc-kind n)))
    (rx-class (tr-class n))
    (rx-quant (list (if (rx-quant-greedy n) :greedy-repetition :non-greedy-repetition)
                    (rx-quant-min n) (rx-quant-max n) (tr-node (rx-quant-atom n))))
    (rx-group (ecase (rx-group-kind n)
                (:capture (if (rx-group-name n)
                              (list :named-register (rx-group-name n) (tr-node (rx-group-body n)))
                              (list :register (tr-node (rx-group-body n)))))
                (:non-capture (list :group (tr-node (rx-group-body n))))))
    (rx-backref
     ;; NOTE: a backref to a non-participating group matches empty in JS but FAILS in
     ;; PPCRE — a documented gap (regexp-gaps.txt). Participated backrefs are correct.
     (list :back-reference (rx-backref-index n)))
    (rx-anchor (ecase (rx-anchor-kind n)
                 ;; ^ / $ : without /m, only string start/end (modeless). With /m, also at
                 ;; JS LineTerminators — PPCRE's own multi-line-mode only breaks on LF, so
                 ;; we build the multiline anchors ourselves over the full LF/CR/LS/PS set.
                 (:start (if *tr-multiline* (tr-multiline-start) :modeless-start-anchor))
                 (:end (if *tr-multiline* (tr-multiline-end) :modeless-end-anchor-no-newline))
                 ;; \b / \B : JS IsWordChar is ASCII-only [A-Za-z0-9_]; PPCRE's native
                 ;; :word-boundary uses a Unicode set. Build boundaries from the ASCII set.
                 (:word-boundary (tr-word-boundary t))
                 (:non-word-boundary (tr-word-boundary nil))))
    (rx-look
     (when (eq (rx-look-dir n) :behind) (tr-check-fixed-length (rx-look-body n)))
     (list (ecase (rx-look-dir n)
             (:ahead (if (eq (rx-look-sense n) :pos) :positive-lookahead :negative-lookahead))
             (:behind (if (eq (rx-look-sense n) :pos) :positive-lookbehind :negative-lookbehind)))
           (tr-node (rx-look-body n))))))

(defun tr-esc (kind)
  "A class-shorthand escape OUTSIDE a character class → a JS-correct parse tree."
  (ecase kind
    (:digit :digit-class)
    (:non-digit :non-digit-class)
    (:word (cons :char-class +js-word-items+))
    (:non-word (cons :inverted-char-class +js-word-items+))
    (:space (cons :char-class +js-whitespace-items+))
    (:non-space (cons :inverted-char-class +js-whitespace-items+))))

(defun tr-class-esc-items (kind)
  "Class-shorthand INSIDE a character class → a list of char-class items to splice.
The negated shorthands emit the JS-correct complement as explicit ranges (PPCRE's own
:non-*-char-class symbols use the wrong Unicode/5-char sets — see complement-ranges)."
  (ecase kind
    (:digit (list (list :range #\0 #\9)))
    (:word (copy-list +js-word-items+))
    (:space (copy-list +js-whitespace-items+))
    (:non-digit (complement-ranges +js-digit-covered+))
    (:non-word (complement-ranges +js-word-covered+))
    (:non-space (complement-ranges +js-whitespace-covered+))))

(defun tr-class (n)
  (let ((items '()))
    (dolist (it (rx-class-items n))
      (cond
        ((integerp it) (push (code-char it) items))
        ((rx-class-range-p it) (push (list :range (code-char (rx-class-range-lo it))
                                           (code-char (rx-class-range-hi it))) items))
        ((rx-esc-p it) (dolist (x (tr-class-esc-items (rx-esc-kind it))) (push x items)))
        (t (error "bad class item ~a" it))))
    (if (null items)
        ;; §22.2.2: an EMPTY class is valid. [] matches nothing (always fails; a
        ;; never-matching zero-width assertion), [^] matches any char incl. terminators.
        ;; (PPCRE rejects a literally empty (:char-class), so special-case both.)
        (if (rx-class-negated n) :everything (list :negative-lookahead :void))
        (cons (if (rx-class-negated n) :inverted-char-class :char-class) (nreverse items)))))

;;; --- JS-correct anchors (multiline ^/$ and ASCII \b/\B) ---------------------

(defun tr-multiline-start ()
  "^ under /m: string start OR immediately after a JS LineTerminator."
  (list :alternation :modeless-start-anchor
        (list :positive-lookbehind (cons :char-class +js-line-terminators+))))

(defun tr-multiline-end ()
  "$ under /m: string end OR immediately before a JS LineTerminator."
  (list :alternation :modeless-end-anchor-no-newline
        (list :positive-lookahead (cons :char-class +js-line-terminators+))))

(defun tr-word-boundary (boundary-p)
  "\\b (BOUNDARY-P t) / \\B (nil), using the JS ASCII word set via lookarounds. A
boundary is a word/non-word transition; \\B is the two non-transition cases."
  (let ((w (cons :char-class +js-word-items+)))
    (if boundary-p
        (list :alternation
              (list :sequence (list :positive-lookbehind w) (list :negative-lookahead w))
              (list :sequence (list :negative-lookbehind w) (list :positive-lookahead w)))
        (list :alternation
              (list :sequence (list :positive-lookbehind w) (list :positive-lookahead w))
              (list :sequence (list :negative-lookbehind w) (list :negative-lookahead w))))))

;;; --- fixed-length check for lookbehind (loud gap) ---------------------------

(defun rx-len-bounds (n)
  "Return (values min max) code-unit length of what N matches; max NIL = unbounded."
  (typecase n
    (rx-disjunction
     (let ((bounds (mapcar #'(lambda (a) (multiple-value-list (rx-len-bounds a)))
                           (rx-disjunction-alternatives n))))
       (values (reduce #'min (mapcar #'first bounds))
               (if (some #'null (mapcar #'second bounds)) nil
                   (reduce #'max (mapcar #'second bounds))))))
    (rx-alternative
     (let ((lo 0) (hi 0))
       (dolist (tm (rx-alternative-terms n))
         (multiple-value-bind (a b) (rx-len-bounds tm)
           (incf lo a) (setf hi (and hi b (+ hi b)))))
       (values lo hi)))
    ((or rx-char rx-dot rx-esc rx-class) (values 1 1))
    (rx-group (rx-len-bounds (rx-group-body n)))
    (rx-anchor (values 0 0))
    (rx-look (values 0 0))
    (rx-backref (values 0 nil))                          ; unknown length → unbounded
    (rx-quant (multiple-value-bind (a b) (rx-len-bounds (rx-quant-atom n))
                (values (* a (rx-quant-min n))
                        (and b (rx-quant-max n) (* b (rx-quant-max n))))))
    (t (values 0 nil))))

(defun tr-check-fixed-length (body)
  (multiple-value-bind (lo hi) (rx-len-bounds body)
    (unless (and hi (= lo hi))
      (throw-syntax-error
       "Invalid regular expression: variable-length lookbehind is not supported (Phase 10)"))))
