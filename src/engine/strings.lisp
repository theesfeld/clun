;;;; strings.lisp — UTF-8 <-> UTF-16-code-unit (WTF-8) host boundary (Phase 01, §3.1).
;;;; A JS string is UTF-16 code units, one CL char each; astral scalars live as
;;;; surrogate PAIRS (two chars). SBCL's built-in :utf-8 can't bridge this (it errors
;;;; on lone surrogates and CESU-8-splits pairs), so we hand-roll WTF-8:
;;;;   encode: valid hi+lo pair -> 4-byte UTF-8 of the combined scalar; lone surrogate
;;;;           -> its own 3-byte encoding; other -> standard 1-3 byte.
;;;;   decode: 4-byte scalar -> two surrogate code units; 3-byte in D800..DFFF -> lone
;;;;           surrogate char (legal, Appendix C); invalid/overlong -> U+FFFD (lossy).

(in-package :clun.engine)

(defconstant +high-surrogate-start+ #xD800)
(defconstant +high-surrogate-end+   #xDBFF)
(defconstant +low-surrogate-start+  #xDC00)
(defconstant +low-surrogate-end+    #xDFFF)
(defconstant +replacement-char+     #xFFFD)
(defconstant +max-code-point+       #x10FFFF)

(declaim (inline high-surrogate-p low-surrogate-p))
(defun high-surrogate-p (cp) (<= +high-surrogate-start+ cp +high-surrogate-end+))
(defun low-surrogate-p  (cp) (<= +low-surrogate-start+ cp +low-surrogate-end+))

(defun well-formed-code-unit-string-p (string)
  "Whether STRING contains only Unicode scalar values encoded as UTF-16 code units."
  (let ((i 0) (length (length string)))
    (loop while (< i length) do
      (let ((code (char-code (char string i))))
        (cond
          ((high-surrogate-p code)
           (unless (and (< (1+ i) length)
                        (low-surrogate-p (char-code (char string (1+ i)))))
             (return-from well-formed-code-unit-string-p nil))
           (incf i 2))
          ((low-surrogate-p code)
           (return-from well-formed-code-unit-string-p nil))
          (t (incf i)))))
    t))

(defun to-well-formed-code-unit-string (string)
  "Replace each unpaired UTF-16 surrogate in STRING with U+FFFD."
  (when (well-formed-code-unit-string-p string)
    (return-from to-well-formed-code-unit-string string))
  (with-output-to-string (out)
    (let ((i 0) (length (length string)))
      (loop while (< i length) do
        (let ((char (char string i))
              (code (char-code (char string i))))
          (cond
            ((and (high-surrogate-p code)
                  (< (1+ i) length)
                  (low-surrogate-p (char-code (char string (1+ i)))))
             (write-char char out)
             (write-char (char string (1+ i)) out)
             (incf i 2))
            ((or (high-surrogate-p code) (low-surrogate-p code))
             (write-char (code-char +replacement-char+) out)
             (incf i))
            (t
             (write-char char out)
             (incf i))))))))

(defun %push-utf8 (cp out)
  "Append the UTF-8 bytes of code point CP to fill-pointer byte vector OUT."
  (cond
    ((< cp #x80)
     (vector-push-extend cp out))
    ((< cp #x800)
     (vector-push-extend (logior #xC0 (ash cp -6)) out)
     (vector-push-extend (logior #x80 (logand cp #x3F)) out))
    ((< cp #x10000)
     (vector-push-extend (logior #xE0 (ash cp -12)) out)
     (vector-push-extend (logior #x80 (logand (ash cp -6) #x3F)) out)
     (vector-push-extend (logior #x80 (logand cp #x3F)) out))
    (t
     (vector-push-extend (logior #xF0 (ash cp -18)) out)
     (vector-push-extend (logior #x80 (logand (ash cp -12) #x3F)) out)
     (vector-push-extend (logior #x80 (logand (ash cp -6) #x3F)) out)
     (vector-push-extend (logior #x80 (logand cp #x3F)) out))))

(defun code-units->utf8 (string)
  "STRING (UTF-16 code units) -> (unsigned-byte 8) vector, WTF-8 encoded."
  (let ((out (make-array (length string) :element-type '(unsigned-byte 8)
                                         :adjustable t :fill-pointer 0))
        (i 0)
        (n (length string)))
    (loop while (< i n) do
      (let ((cp (char-code (char string i))))
        (cond
          ;; valid surrogate pair -> combined astral scalar
          ((and (high-surrogate-p cp) (< (1+ i) n)
                (low-surrogate-p (char-code (char string (1+ i)))))
           (let* ((lo (char-code (char string (1+ i))))
                  (scalar (+ #x10000
                             (ash (- cp +high-surrogate-start+) 10)
                             (- lo +low-surrogate-start+))))
             (%push-utf8 scalar out)
             (incf i 2)))
          ;; lone surrogate or BMP char -> encode cp directly (WTF-8 for surrogates)
          (t
           (%push-utf8 cp out)
           (incf i)))))
    (coerce out '(simple-array (unsigned-byte 8) (*)))))

(defun code-units->utf8-replacing (string)
  "Encode UTF-16 code units as UTF-8, replacing every lone surrogate with U+FFFD.
Unlike CODE-UNITS->UTF8 this is scalar-value UTF-8, not WTF-8."
  (let ((out (make-array (length string) :element-type '(unsigned-byte 8)
                                         :adjustable t :fill-pointer 0))
        (i 0)
        (n (length string)))
    (loop while (< i n) do
      (let ((cp (char-code (char string i))))
        (cond
          ((and (high-surrogate-p cp) (< (1+ i) n)
                (low-surrogate-p (char-code (char string (1+ i)))))
           (let* ((lo (char-code (char string (1+ i))))
                  (scalar (+ #x10000
                             (ash (- cp +high-surrogate-start+) 10)
                             (- lo +low-surrogate-start+))))
             (%push-utf8 scalar out)
             (incf i 2)))
          ((or (high-surrogate-p cp) (low-surrogate-p cp))
           (%push-utf8 +replacement-char+ out)
           (incf i))
          (t
           (%push-utf8 cp out)
           (incf i)))))
    (coerce out '(simple-array (unsigned-byte 8) (*)))))

(defun %push-code-point (cp out)
  "Append code point CP to fill-pointer string OUT as 1 or 2 code units."
  (if (>= cp #x10000)
      (let ((v (- cp #x10000)))
        (vector-push-extend (code-char (+ +high-surrogate-start+ (ash v -10))) out)
        (vector-push-extend (code-char (+ +low-surrogate-start+ (logand v #x3FF))) out))
      (vector-push-extend (code-char cp) out)))

(defun %utf8-lead-info (b0)
  "For lead byte B0 return (values length lo2 hi2 bits0): total sequence LENGTH,
the allowed range [LO2,HI2] of the *second* byte, and the data bits from B0.
LENGTH 0 means B0 cannot begin a sequence. Surrogate second-byte range for ED is
left open (A0..BF) — WTF-8 accepts lone surrogates."
  (cond
    ((< b0 #xC2) (values 0 0 0 0))                       ; 80-BF stray, C0/C1 overlong lead
    ((< b0 #xE0) (values 2 #x80 #xBF (logand b0 #x1F)))  ; C2-DF
    ((< b0 #xF0) (values 3 (if (= b0 #xE0) #xA0 #x80)    ; E0 forbids overlong
                           #xBF (logand b0 #x0F)))       ; ED surrogates allowed (WTF-8)
    ((< b0 #xF5) (values 4 (if (= b0 #xF0) #x90 #x80)    ; F0 forbids overlong
                           (if (= b0 #xF4) #x8F #xBF)    ; F4 caps at U+10FFFF
                           (logand b0 #x07)))
    (t (values 0 0 0 0))))                               ; F5-FF invalid

(defun utf8->code-units (bytes)
  "(unsigned-byte 8) vector (WTF-8) -> string of UTF-16 code units. Malformed input
is replaced per the WHATWG maximal-subpart rule (one U+FFFD per error, the offending
byte reprocessed), never crashing."
  (let ((out (make-array (length bytes) :element-type 'character
                                        :adjustable t :fill-pointer 0))
        (i 0)
        (n (length bytes)))
    (loop while (< i n) do
      (let ((b0 (aref bytes i)))
        (if (< b0 #x80)
            (progn (%push-code-point b0 out) (incf i))
            (multiple-value-bind (len lo2 hi2 cp) (%utf8-lead-info b0)
              (if (zerop len)
                  (progn (%push-code-point +replacement-char+ out) (incf i)) ; bad lead
                  (let ((j (1+ i)) (ok t))
                    (dotimes (c (1- len))               ; gather continuation bytes
                      (let ((lo (if (zerop c) lo2 #x80))
                            (hi (if (zerop c) hi2 #xBF)))
                        (if (and (< j n) (<= lo (aref bytes j) hi))
                            (progn (setf cp (logior (ash cp 6) (logand (aref bytes j) #x3F)))
                                   (incf j))
                            (progn (setf ok nil) (return)))))
                    ;; consume the maximal valid subpart (i..j); a bad/absent byte at j
                    ;; is left for the next iteration (maximal-subpart semantics).
                    (%push-code-point (if ok cp +replacement-char+) out)
                    (setf i j)))))))
    (coerce out '(simple-array character (*)))))
