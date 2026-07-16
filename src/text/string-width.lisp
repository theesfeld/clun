;;;; string-width.lisp -- pure Common Lisp terminal column measurement.
;;;;
;;;; The scanner is linear in UTF-16 code units. Unicode property lookups use
;;;; generated, sorted range vectors and never read UCD data at runtime.

(in-package :clun.text)

(declaim (inline %range-member-p %raw-unit %high-surrogate-p
                 %low-surrogate-p %control-p))

(defun %range-member-p (codepoint ranges)
  "Return true when CODEPOINT is in a flat #(LO HI ...) range vector."
  (let ((low 0)
        (high (ash (length ranges) -1)))
    (loop while (< low high)
          for middle = (ash (+ low high) -1)
          for offset = (ash middle 1)
          for range-low = (aref ranges offset)
          for range-high = (aref ranges (1+ offset))
          do (cond ((< codepoint range-low) (setf high middle))
                   ((> codepoint range-high) (setf low (1+ middle)))
                   (t (return t)))
          finally (return nil))))

(defun %raw-unit (input index)
  (let ((value (aref input index)))
    (etypecase value
      (character (char-code value))
      (integer value))))

(defun %high-surrogate-p (codepoint)
  (<= #xD800 codepoint #xDBFF))

(defun %low-surrogate-p (codepoint)
  (<= #xDC00 codepoint #xDFFF))

(defun %decode-at (input index end)
  "Decode one JS UTF-16 scalar. Also accepts scalar host characters.

Returns CODEPOINT, NEXT-INDEX, and SKIP-P. Lone surrogates are skipped, matching
Bun.stringWidth's JavaScript boundary."
  (let ((unit (%raw-unit input index)))
    (cond
      ((%high-surrogate-p unit)
       (if (< (1+ index) end)
           (let ((next (%raw-unit input (1+ index))))
             (if (%low-surrogate-p next)
                 (values (+ #x10000
                            (ash (- unit #xD800) 10)
                            (- next #xDC00))
                         (+ index 2) nil)
                 (values #xFFFD (1+ index) t)))
           (values #xFFFD (1+ index) t)))
      ((%low-surrogate-p unit)
       (values #xFFFD (1+ index) t))
      ((<= 0 unit #x10FFFF)
       (values unit (1+ index) nil))
      (t
       (error "Invalid Unicode code unit ~s at index ~d" unit index)))))

(defun %control-p (codepoint)
  (or (<= 0 codepoint #x1F)
      (<= #x7F codepoint #x9F)))

(defun %zero-width-codepoint-p (codepoint)
  "Bun-compatible invisible/control classification at the Unicode 17 pin."
  (or (%control-p codepoint)
      (= codepoint #xAD)
      (<= #x300 codepoint #x36F)
      (<= #x200B codepoint #x200F)
      (<= #x202A codepoint #x202E)
      (<= #x2060 codepoint #x206F)
      (= codepoint #x61C)
      (<= #x180B codepoint #x180F)
      (<= #x20D0 codepoint #x20FF)
      (<= #xFE00 codepoint #xFE0F)
      (<= #xFE20 codepoint #xFE2F)
      (= codepoint #xFEFF)
      (<= #xD800 codepoint #xDFFF)
      (<= #x1AB0 codepoint #x1AFF)
      (<= #x1DC0 codepoint #x1DFF)
      (<= #xE0000 codepoint #xE007F)
      (<= #xE0100 codepoint #xE01EF)
      (<= #x600 codepoint #x605)
      (member codepoint '(#x6DD #x70F #x8E2) :test #'=)
      (and (<= #x900 codepoint #xD4F)
           (let ((offset (logand codepoint #x7F)))
             (or (<= offset #x02)
                 (and (<= #x3A offset #x4D) (/= offset #x3D))
                 (<= #x51 offset #x57)
                 (<= #x62 offset #x63))))
      (= codepoint #xE31)
      (<= #xE34 codepoint #xE3A)
      (<= #xE47 codepoint #xE4E)
      (= codepoint #xEB1)
      (<= #xEB4 codepoint #xEBC)
      (<= #xEC8 codepoint #xECD)))

(defun codepoint-width (codepoint &key (ambiguous-is-narrow t))
  "Return terminal width 0, 1, or 2 for a Unicode scalar."
  (check-type codepoint (integer 0 #x10FFFF))
  (cond ((%zero-width-codepoint-p codepoint) 0)
        ((< codepoint #x7F) 1)
        ((%range-member-p codepoint +unicode-17-eaw-wide+) 2)
        ((%range-member-p codepoint +unicode-17-eaw-ambiguous+)
         (if ambiguous-is-narrow 1 2))
        (t 1)))

(defun %emoji-p (codepoint)
  ;; These early-outs are part of the frozen Bun implementation rather than a
  ;; claim that every UCD Emoji codepoint has default emoji presentation.
  (and (>= codepoint #x203C)
       (not (and (>= codepoint #x2C00) (< codepoint #x1F000)))
       (not (member codepoint '(#xFE0E #xFE0F #x200D) :test #'=))
       (%range-member-p codepoint +unicode-17-emoji+)))

;;; Grapheme classes. Generic GCB Extend is named :EXTEND; Indic Conjunct
;;; Break classes retain their distinct state-machine roles.

(defun %grapheme-class (codepoint)
  (cond
    ((%range-member-p codepoint +unicode-17-gcb-cr+) :cr)
    ((%range-member-p codepoint +unicode-17-gcb-lf+) :lf)
    ((%range-member-p codepoint +unicode-17-gcb-control+) :control)
    ((< codepoint #x80) :other)
    ((%range-member-p codepoint +unicode-17-gcb-zwj+) :zwj)
    ((%range-member-p codepoint +unicode-17-emoji-modifier+) :emoji-modifier)
    ((%range-member-p codepoint +unicode-17-emoji-modifier-base+) :emoji-base)
    ((%range-member-p codepoint +unicode-17-incb-consonant+) :incb-consonant)
    ((%range-member-p codepoint +unicode-17-incb-linker+) :incb-linker)
    ((%range-member-p codepoint +unicode-17-incb-extend+) :incb-extend)
    ((%range-member-p codepoint +unicode-17-extended-pictographic+)
     :extended-pictographic)
    ((%range-member-p codepoint +unicode-17-gcb-prepend+) :prepend)
    ((%range-member-p codepoint +unicode-17-gcb-regional-indicator+)
     :regional-indicator)
    ((%range-member-p codepoint +unicode-17-gcb-spacing-mark+) :spacing-mark)
    ((%range-member-p codepoint +unicode-17-gcb-l+) :l)
    ((%range-member-p codepoint +unicode-17-gcb-v+) :v)
    ((%range-member-p codepoint +unicode-17-gcb-t+) :t)
    ((%range-member-p codepoint +unicode-17-gcb-lv+) :lv)
    ((%range-member-p codepoint +unicode-17-gcb-lvt+) :lvt)
    ((%range-member-p codepoint +unicode-17-gcb-extend+) :extend)
    (t :other)))

(defconstant +break-default+ 0)
(defconstant +break-regional-indicator+ 1)
(defconstant +break-extended-pictographic+ 2)
(defconstant +break-incb-consonant+ 3)
(defconstant +break-incb-linker+ 4)

(defun %incb-extend-p (class)
  (or (eq class :incb-extend) (eq class :zwj)))

(defun %extend-p (class)
  ;; Emoji_Modifier has GCB=Extend. Its distinct class is retained for the
  ;; modifier-base width override, but GB9 still applies for every left class.
  (member class '(:extend :incb-extend :incb-linker :emoji-modifier)
          :test #'eq))

(defun %extended-pictographic-p (class)
  (member class '(:extended-pictographic :emoji-base) :test #'eq))

(defun %emoji-state-class-p (class)
  (member class '(:incb-extend :incb-linker :extend :zwj
                  :extended-pictographic :emoji-base :emoji-modifier)
          :test #'eq))

(defun %incb-state-class-p (class)
  (member class '(:incb-consonant :incb-linker :incb-extend :zwj)
          :test #'eq))

(defun %grapheme-break (left right state)
  "Return SHOULD-BREAK and the next state for one UAX #29 transition."
  ;; GB3-GB5: CR/LF is the sole control pair without a boundary.
  (when (and (eq left :cr) (eq right :lf))
    (return-from %grapheme-break (values nil +break-default+)))
  (when (member left '(:control :cr :lf) :test #'eq)
    (return-from %grapheme-break (values t +break-default+)))
  (when (member right '(:control :cr :lf) :test #'eq)
    (return-from %grapheme-break (values t +break-default+)))

  ;; Discard a carried context as soon as either side cannot belong to it.
  (setf state
        (case state
          (#.+break-regional-indicator+
           (if (and (eq left :regional-indicator)
                    (eq right :regional-indicator))
               state +break-default+))
          (#.+break-extended-pictographic+
           (if (and (%emoji-state-class-p left)
                    (%emoji-state-class-p right))
               state +break-default+))
          ((#.+break-incb-consonant+ #.+break-incb-linker+)
           (if (and (%incb-state-class-p left)
                    (%incb-state-class-p right))
               state +break-default+))
          (otherwise +break-default+)))

  ;; GB6-GB8: Hangul syllable sequences.
  (when (and (eq left :l) (member right '(:l :v :lv :lvt) :test #'eq))
    (return-from %grapheme-break (values nil state)))
  (when (and (member left '(:lv :v) :test #'eq)
             (member right '(:v :t) :test #'eq))
    (return-from %grapheme-break (values nil state)))
  (when (and (member left '(:lvt :t) :test #'eq) (eq right :t))
    (return-from %grapheme-break (values nil state)))

  ;; GB9a/GB9b.
  (when (eq right :spacing-mark)
    (return-from %grapheme-break (values nil state)))
  (when (eq left :prepend)
    (return-from %grapheme-break (values nil state)))

  ;; GB9c: Indic consonant [extend linker]* consonant.
  (cond
    ((eq left :incb-consonant)
     (cond ((%incb-extend-p right)
            (return-from %grapheme-break
              (values nil +break-incb-consonant+)))
           ((eq right :incb-linker)
            (return-from %grapheme-break
              (values nil +break-incb-linker+)))))
    ((= state +break-incb-consonant+)
     (cond ((eq right :incb-linker)
            (return-from %grapheme-break
              (values nil +break-incb-linker+)))
           ((%incb-extend-p right)
            (return-from %grapheme-break (values nil state)))
           (t (setf state +break-default+))))
    ((= state +break-incb-linker+)
     (cond ((or (eq right :incb-linker) (%incb-extend-p right))
            (return-from %grapheme-break (values nil state)))
           ((eq right :incb-consonant)
            (return-from %grapheme-break
              (values nil +break-default+)))
           (t (setf state +break-default+)))))

  ;; GB11 plus emoji modifier sequences.
  (cond
    ((%extended-pictographic-p left)
     (cond ((or (%extend-p right) (eq right :zwj))
            (return-from %grapheme-break
              (values nil +break-extended-pictographic+)))
           ((and (eq left :emoji-base) (eq right :emoji-modifier))
            (return-from %grapheme-break
              (values nil +break-extended-pictographic+)))))
    ((= state +break-extended-pictographic+)
     (cond ((and (or (%extend-p left) (eq left :emoji-modifier))
                 (or (%extend-p right) (eq right :zwj)))
            (return-from %grapheme-break (values nil state)))
           ((and (eq left :zwj) (%extended-pictographic-p right))
            (return-from %grapheme-break
              (values nil +break-default+)))
           (t (setf state +break-default+)))))

  ;; GB12/GB13: pair regional indicators.
  (when (and (eq left :regional-indicator)
             (eq right :regional-indicator))
    (if (= state +break-default+)
        (return-from %grapheme-break
          (values nil +break-regional-indicator+))
        (return-from %grapheme-break
          (values t +break-default+))))

  ;; GB9 and GB999.
  (if (or (%extend-p right) (eq right :zwj))
      (values nil state)
      (values t state)))

(defstruct (%grapheme (:constructor %make-grapheme ()))
  (first-codepoint 0 :type integer)
  (non-emoji-width 0 :type integer)
  (base-width 0 :type integer)
  (count 0 :type integer)
  (last-added-variation-selector 0 :type integer)
  variation-selector-15-p variation-selector-16-p
  emoji-base-p keycap-p regional-indicator-p skin-tone-p zwj-p)

(defun %reset-grapheme (grapheme codepoint ambiguous-is-narrow)
  (let ((width (codepoint-width codepoint
                                :ambiguous-is-narrow ambiguous-is-narrow)))
    (setf (%grapheme-first-codepoint grapheme) codepoint
          (%grapheme-non-emoji-width grapheme) width
          (%grapheme-base-width grapheme) width
          (%grapheme-count grapheme) 1
          (%grapheme-emoji-base-p grapheme) (%emoji-p codepoint)
          (%grapheme-keycap-p grapheme) (= codepoint #x20E3)
          (%grapheme-regional-indicator-p grapheme)
          (<= #x1F1E6 codepoint #x1F1FF)
          (%grapheme-skin-tone-p grapheme) (<= #x1F3FB codepoint #x1F3FF)
          (%grapheme-zwj-p grapheme) (= codepoint #x200D)
          ;; Bun's reset does not treat an initial selector as an added
          ;; presentation request.
          (%grapheme-last-added-variation-selector grapheme) 0
          (%grapheme-variation-selector-15-p grapheme) nil
          (%grapheme-variation-selector-16-p grapheme) nil)))

(defun %add-to-grapheme (grapheme codepoint ambiguous-is-narrow)
  (incf (%grapheme-count grapheme))
  (incf (%grapheme-non-emoji-width grapheme)
        (codepoint-width codepoint :ambiguous-is-narrow ambiguous-is-narrow))
  (setf (%grapheme-keycap-p grapheme)
        (or (%grapheme-keycap-p grapheme) (= codepoint #x20E3))
        (%grapheme-regional-indicator-p grapheme)
        (or (%grapheme-regional-indicator-p grapheme)
            (<= #x1F1E6 codepoint #x1F1FF))
        (%grapheme-skin-tone-p grapheme)
        (or (%grapheme-skin-tone-p grapheme)
            (<= #x1F3FB codepoint #x1F3FF))
        (%grapheme-zwj-p grapheme)
        (or (%grapheme-zwj-p grapheme) (= codepoint #x200D)))
  (cond ((= codepoint #xFE0E)
         (setf (%grapheme-variation-selector-15-p grapheme) t
               (%grapheme-last-added-variation-selector grapheme) 15))
        ((= codepoint #xFE0F)
         (setf (%grapheme-variation-selector-16-p grapheme) t
               (%grapheme-last-added-variation-selector grapheme) 16))))

(defun %grapheme-width (grapheme)
  (let ((count (%grapheme-count grapheme))
        (vs15-p (%grapheme-variation-selector-15-p grapheme))
        (vs16-p (%grapheme-variation-selector-16-p grapheme)))
    (cond
      ((zerop count) 0)
      ((and (%grapheme-regional-indicator-p grapheme) (>= count 2)) 2)
      ((%grapheme-keycap-p grapheme) 2)
      ((%grapheme-regional-indicator-p grapheme) 1)
      ((and (%grapheme-emoji-base-p grapheme)
            (or (%grapheme-skin-tone-p grapheme)
                (%grapheme-zwj-p grapheme)))
       2)
      ((and (zerop (%grapheme-base-width grapheme))
            (zerop (%grapheme-non-emoji-width grapheme))
            (or (and (not vs15-p) (not vs16-p))
                (= count 1)
                (= (%grapheme-last-added-variation-selector grapheme) 16)))
       0)
      ((or vs15-p vs16-p)
       (cond ((= (%grapheme-base-width grapheme) 2) 2)
             (vs16-p
              (let ((first (%grapheme-first-codepoint grapheme)))
                (if (or (< first #x80)
                        (<= #x30 first #x39)
                        (member first '(#x23 #x2A) :test #'=))
                    1 2)))
             (t 1)))
      (t (%grapheme-non-emoji-width grapheme)))))

(defun %skip-csi (input index end)
  ;; INDEX points just after ESC [. A final byte is any ASCII 0x40..0x7E.
  (loop while (< index end)
        do (multiple-value-bind (codepoint next skip-p)
               (%decode-at input index end)
             (setf index next)
             ;; A lone surrogate is not a scalar and cannot terminate CSI.
             (when (and (not skip-p)
                        (or (> codepoint #x7F)
                            (<= #x40 codepoint #x7E)))
               (return index)))
        finally (return end)))

(defun %skip-osc (input index end)
  ;; INDEX points just after ESC ]. OSC ends at BEL, C1 ST, or ESC backslash.
  (loop while (< index end)
        for unit = (%raw-unit input index)
        do (cond ((or (= unit #x07) (= unit #x9C))
                  (return (1+ index)))
                 ((and (= unit #x1B) (< (1+ index) end)
                       (= (%raw-unit input (1+ index)) #x5C))
                  (return (+ index 2)))
                 (t
                  (multiple-value-bind (codepoint next skip-p)
                      (%decode-at input index end)
                    (declare (ignore codepoint skip-p))
                    (setf index next))))
        finally (return end)))

(defun %skip-ansi-sequence (input index end)
  "Return the next raw index after an ANSI sequence beginning at ESC.

For a bare ESC only ESC is discarded. This intentionally accepts the same
broad CSI final-byte grammar and OSC terminators as the pinned Bun scanner."
  (loop with cursor = (1+ index)
        while (< cursor end)
        for scalar-start = cursor
        do (multiple-value-bind (codepoint next skip-p)
               (%decode-at input cursor end)
             (setf cursor next)
             ;; Lone surrogates do not consume the pending ESC decision.
             (unless skip-p
               (return (case codepoint
                         (#x5B (%skip-csi input cursor end))
                         (#x5D (%skip-osc input cursor end))
                         ;; Bare ESC drops only itself and skipped surrogates;
                         ;; process the first real scalar normally.
                         (otherwise scalar-start)))))
        finally (return end)))

(defun string-width (input &key (count-ansi-escape-codes nil)
                                (ambiguous-is-narrow t))
  "Measure INPUT in terminal columns with Bun.stringWidth-compatible rules.

INPUT is a CL string or a vector of UTF-16 code units. ANSI CSI/OSC sequences
are transparent unless COUNT-ANSI-ESCAPE-CODES is true. The default treats
East Asian Ambiguous codepoints as narrow."
  (check-type input vector)
  (let ((end (length input))
        (index 0)
        (total 0)
        (has-previous nil)
        (previous-class :other)
        (break-state +break-default+)
        (grapheme (%make-grapheme)))
    (labels ((flush-grapheme ()
               (incf total (%grapheme-width grapheme))
               (setf (%grapheme-count grapheme) 0))
             (feed (codepoint)
               (let ((class (%grapheme-class codepoint)))
                 (if has-previous
                     (multiple-value-bind (break-p next-state)
                         (%grapheme-break previous-class class break-state)
                       (setf break-state next-state)
                       ;; Bun's reducer has two width-only boundaries that do
                       ;; not alter Unicode 17 boundary state: its ASCII fast
                       ;; path seeds a fresh component, and a non-adjacent
                       ;; Emoji_Modifier starts one except directly after
                       ;; Prepend.
                       (if (or break-p
                               (< codepoint #x80)
                               (and (eq class :emoji-modifier)
                                    (not (member previous-class
                                                 '(:emoji-base :prepend)
                                                 :test #'eq))))
                           (progn
                             (flush-grapheme)
                             (%reset-grapheme grapheme codepoint
                                              ambiguous-is-narrow))
                           (%add-to-grapheme grapheme codepoint
                                             ambiguous-is-narrow)))
                     (%reset-grapheme grapheme codepoint ambiguous-is-narrow))
                 (setf has-previous t
                       previous-class class))))
      (loop while (< index end)
            do (if (and (not count-ansi-escape-codes)
                        (= (%raw-unit input index) #x1B))
                   ;; Escape sequences are transparent to grapheme boundaries.
                   (setf index (%skip-ansi-sequence input index end))
                   (multiple-value-bind (codepoint next skip-p)
                       (%decode-at input index end)
                     (setf index next)
                     (unless skip-p (feed codepoint)))))
      (flush-grapheme)
      total)))
