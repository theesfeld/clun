;;;; strings-tests.lisp — UTF-8 <-> UTF-16-code-unit (WTF-8) boundary.

(in-package :clun-test)

(defun units (&rest codes)
  "Build a string from UTF-16 code-unit CODES."
  (map 'string #'code-char codes))

(defun bytes (&rest bs)
  (make-array (length bs) :element-type '(unsigned-byte 8) :initial-contents bs))

(defun roundtrip= (string)
  "decode(encode(STRING)) equals STRING."
  (string= string (eng:utf8->code-units (eng:code-units->utf8 string))))

(define-test strings/encode-known-answers
  ;; ASCII
  (is equalp (bytes 65 66 67) (eng:code-units->utf8 "ABC"))
  ;; U+00E9 é -> C3 A9 (2-byte)
  (is equalp (bytes #xC3 #xA9) (eng:code-units->utf8 (units #xE9)))
  ;; U+20AC € -> E2 82 AC (3-byte)
  (is equalp (bytes #xE2 #x82 #xAC) (eng:code-units->utf8 (units #x20AC)))
  ;; U+1F600 😀 as surrogate pair D83D DE00 -> F0 9F 98 80 (4-byte, combined)
  (is equalp (bytes #xF0 #x9F #x98 #x80) (eng:code-units->utf8 (units #xD83D #xDE00)))
  ;; lone high surrogate D800 -> WTF-8 3-byte ED A0 80
  (is equalp (bytes #xED #xA0 #x80) (eng:code-units->utf8 (units #xD800)))
  ;; lone low surrogate DFFF -> ED BF BF
  (is equalp (bytes #xED #xBF #xBF) (eng:code-units->utf8 (units #xDFFF))))

(define-test strings/decode-known-answers
  (is string= "ABC" (eng:utf8->code-units (bytes 65 66 67)))
  (is string= (units #xE9) (eng:utf8->code-units (bytes #xC3 #xA9)))
  ;; astral scalar decodes to a surrogate PAIR
  (is string= (units #xD83D #xDE00) (eng:utf8->code-units (bytes #xF0 #x9F #x98 #x80)))
  ;; 3-byte encoding of a surrogate decodes to the lone surrogate (WTF-8)
  (is string= (units #xD800) (eng:utf8->code-units (bytes #xED #xA0 #x80))))

(define-test strings/roundtrip
  (dolist (s (list ""
                   "hello world"
                   (units #xE9 #x20AC #x41)           ; é € A
                   (units #xD83D #xDE00)              ; astral pair 😀
                   (units #x41 #xD83D #xDE00 #x42)    ; A 😀 B
                   (units #xD800)                     ; lone high
                   (units #xDFFF)                     ; lone low
                   (units #xDC00 #xD800)              ; low then high (both lone)
                   (units #x41 #xD800 #x42)           ; embedded lone high
                   (units #xD83D #x41 #xDE00)         ; hi, non-low, lone lo (all lone)
                   (units #xFFFF #x0 #x7F #x80 #x7FF #x800)))
    (true (roundtrip= s))))

(define-test strings/lossy-invalid
  ;; WHATWG maximal-subpart replacement: one U+FFFD per error, offending byte reprocessed.
  (is string= (units #xFFFD) (eng:utf8->code-units (bytes #xC3)))            ; truncated 2-byte @EOF
  (is string= (units #xFFFD) (eng:utf8->code-units (bytes #xE2 #x82)))       ; truncated 3-byte @EOF
  (is string= (units #xFFFD) (eng:utf8->code-units (bytes #xFF)))            ; invalid lead F5-FF
  (is string= (units #xFFFD #xFFFD)                                          ; C0 invalid, AF stray
      (eng:utf8->code-units (bytes #xC0 #xAF)))
  (is string= (units #xFFFD #x41)                                            ; error then resumes
      (eng:utf8->code-units (bytes #xFF #x41)))
  (is string= (units #x2F)                                                   ; valid '/' still works
      (eng:utf8->code-units (bytes #x2F))))

(define-test strings/lossy-multibyte-boundaries
  ;; the subtle per-lead-byte second-byte range guards (E0/F0/F4) and 4-byte path
  (is string= (units #xFFFD)                                                 ; truncated 4-byte @EOF
      (eng:utf8->code-units (bytes #xF0 #x9F #x98)))
  (is string= (units #xFFFD #x28)                                            ; F0 bad 2nd byte, 0x28 reprocessed
      (eng:utf8->code-units (bytes #xF0 #x28)))
  (is string= (units #xFFFD #xFFFD #xFFFD #xFFFD)                            ; F4 caps 2nd byte at 8F
      (eng:utf8->code-units (bytes #xF4 #x90 #x80 #x80)))
  (is string= (units #xFFFD #xFFFD #xFFFD)                                   ; E0 overlong (2nd < A0)
      (eng:utf8->code-units (bytes #xE0 #x80 #x80)))
  (is string= (units #xFFFD)                                                 ; stray continuation
      (eng:utf8->code-units (bytes #x80)))
  (is string= (units #xD800 #x41)                                            ; lone surrogate then ASCII resumes
      (eng:utf8->code-units (bytes #xED #xA0 #x80 #x41))))

(define-test strings/length-is-code-units
  ;; .length semantics: astral char counts as 2 code units
  (is = 2 (length (units #xD83D #xDE00)))
  (is = 1 (length (units #xD800))))
