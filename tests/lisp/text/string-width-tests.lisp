;;;; string-width-tests.lisp -- focused Phase 33 terminal-width coverage.

(in-package :clun-test)

(defun sw-string (&rest codepoints)
  (coerce (mapcar #'code-char codepoints) 'string))

(defun sw-units (&rest code-units)
  (make-array (length code-units)
              :element-type '(unsigned-byte 32)
              :initial-contents code-units))

(defun sw-ansi (&rest pieces)
  (apply #'concatenate 'string
         (mapcar (lambda (piece)
                   (etypecase piece
                     (string piece)
                     (integer (string (code-char piece)))))
                 pieces)))

(defparameter *sw-ucd-root*
  (merge-pathnames "vendor-data/ucd/17.0.0/"
                   (asdf:system-source-directory :clun)))

(defun sw-sha256 (relative-path)
  (string-downcase
   (ironclad:byte-array-to-hex-string
    (ironclad:digest-file :sha256
                          (merge-pathnames relative-path *sw-ucd-root*)))))

(defun sw-split-whitespace (string)
  (let ((tokens '())
        (start nil))
    (loop for index from 0 to (length string)
          for whitespace-p = (or (= index (length string))
                                 (member (char string index)
                                         '(#\Space #\Tab #\Return #\Newline)))
          do (cond ((and whitespace-p start)
                    (push (subseq string start index) tokens)
                    (setf start nil))
                   ((and (not whitespace-p) (null start))
                    (setf start index))))
    (nreverse tokens)))

(defun sw-data-body (line)
  (string-trim '(#\Space #\Tab #\Return #\Newline)
               (subseq line 0 (position #\# line))))

(defun sw-grapheme-row (line)
  (let ((body (sw-data-body line)))
    (when (plusp (length body))
      (let ((codepoints '())
            (boundaries '()))
        (dolist (token (sw-split-whitespace body))
          (let ((marker (and (= (length token) 1)
                             (char-code (char token 0)))))
            (cond ((eql marker #xF7) (push t boundaries))
                  ((eql marker #xD7) (push nil boundaries))
                  (t (push (parse-integer token :radix 16) codepoints)))))
        (values (nreverse codepoints) (nreverse boundaries))))))

(defun sw-grapheme-boundaries (codepoints)
  (if (null codepoints)
      '(t)
      (let ((boundaries (list t))
            (state clun.text::+break-default+)
            (previous (clun.text::%grapheme-class (first codepoints))))
        (dolist (codepoint (rest codepoints))
          (let ((class (clun.text::%grapheme-class codepoint)))
            (multiple-value-bind (break-p next-state)
                (clun.text::%grapheme-break previous class state)
              (push break-p boundaries)
              (setf state next-state
                    previous class))))
        (nreverse (cons t boundaries)))))

(defun sw-emoji-row (line)
  (let* ((body (sw-data-body line))
         (semicolon (position #\; body)))
    (when (and semicolon (plusp (length body)))
      (values (mapcar (lambda (token) (parse-integer token :radix 16))
                      (sw-split-whitespace (subseq body 0 semicolon)))
              (string-trim '(#\Space #\Tab)
                           (subseq body (1+ semicolon)))))))

(defun sw-repeat-units (units count)
  (let* ((unit-count (length units))
         (result (make-array (* unit-count count)
                             :element-type '(unsigned-byte 32))))
    (loop for start from 0 below (length result) by unit-count
          do (replace result units :start1 start))
    result))

(define-test string-width-unicode-pin
  (is string= "17.0.0" clun.text:+unicode-width-version+)
  (is = 1 (clun.text:codepoint-width #x41))
  (is = 2 (clun.text:codepoint-width #x4E2D))
  (is = 2 (clun.text:codepoint-width #xFF21))
  (is = 1 (clun.text:codepoint-width #xFF71))
  ;; Unicode 17 EAW default-wide planes are represented explicitly.
  (is = 2 (clun.text:codepoint-width #x3FFFD))
  (is = 1 (clun.text:codepoint-width #x40000)))

(define-test string-width-unicode-corpus-hashes
  (is string= "24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08"
      (sw-sha256 "DerivedCoreProperties.txt"))
  (is string= "ea7ce50f3444a050333448dffef1cadd9325af55cbb764b4a2280faf52170a33"
      (sw-sha256 "EastAsianWidth.txt"))
  (is string= "e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96"
      (sw-sha256 "LICENSE.txt"))
  (is string= "d6b51d1d2ae5c33b451b7ed994b48f1f4dc62b2272a5831e7fd418514a6bae89"
      (sw-sha256 "auxiliary/GraphemeBreakProperty.txt"))
  (is string= "e2d134d2c52919bace503ebb6a551c1855fe1a1faec18478c78fff254a1793ec"
      (sw-sha256 "auxiliary/GraphemeBreakTest.txt"))
  (is string= "2cb2bb9455cda83e8481541ecf5b6dfda66a3bb89efa3fa7c5297eccf607b72b"
      (sw-sha256 "emoji/emoji-data.txt"))
  (is string= "1d8a944f88d7952f7ef7c5167fef3c67995bcae24543949710231b03a201acda"
      (sw-sha256 "emoji/emoji-test.txt")))

(define-test string-width-uax29-grapheme-break-corpus
  (let ((rows 0)
        (failures '()))
    (with-open-file (input (merge-pathnames "auxiliary/GraphemeBreakTest.txt"
                                            *sw-ucd-root*)
                           :direction :input :external-format :utf-8)
      (loop for line = (read-line input nil)
            for line-number from 1
            while line
            do (multiple-value-bind (codepoints expected) (sw-grapheme-row line)
                 (when codepoints
                   (incf rows)
                   (let ((actual (sw-grapheme-boundaries codepoints)))
                     (unless (equal expected actual)
                       (push (list line-number codepoints expected actual)
                             failures)))))))
    (is = 766 rows "all Unicode 17 grapheme rows executed")
    (false failures "UAX #29 failures: ~s" (nreverse failures))))

(define-test string-width-unicode-rgi-emoji-corpus
  (let ((fully-qualified 0)
        (components 0)
        (failures '())
        (component-widths '((#x1F3FB . 2) (#x1F3FC . 2) (#x1F3FD . 2)
                            (#x1F3FE . 2) (#x1F3FF . 2) (#x1F9B0 . 2)
                            (#x1F9B1 . 2) (#x1F9B2 . 2) (#x1F9B3 . 2))))
    (with-open-file (input (merge-pathnames "emoji/emoji-test.txt" *sw-ucd-root*)
                           :direction :input :external-format :utf-8)
      (loop for line = (read-line input nil)
            for line-number from 1
            while line
            do (multiple-value-bind (codepoints status) (sw-emoji-row line)
                 (when codepoints
                   (cond
                     ((string= status "fully-qualified")
                      (incf fully-qualified)
                      (let ((width (clun.text:string-width
                                    (apply #'sw-string codepoints))))
                        (unless (= width 2)
                          (push (list line-number codepoints 2 width) failures))))
                     ((string= status "component")
                      (incf components)
                      (let* ((expected (and (= (length codepoints) 1)
                                            (cdr (assoc (first codepoints)
                                                        component-widths))))
                             (width (clun.text:string-width
                                     (apply #'sw-string codepoints))))
                        (unless (and expected (= width expected))
                          (push (list line-number codepoints expected width)
                                failures)))))))))
    (is = 3944 fully-qualified "all fully-qualified RGI emoji rows executed")
    (is = 9 components "all explicit emoji component rows executed")
    (false failures "RGI emoji width failures: ~s" (nreverse failures))))

(define-test string-width-ascii-controls-and-invisibles
  (is = 0 (clun.text:string-width ""))
  (is = 11 (clun.text:string-width "hello world"))
  (is = 4 (clun.text:string-width (sw-ansi "a" 9 "b" 10 "c" 13 "d")))
  (dolist (codepoint '(#x00 #x1F #x7F #x80 #x9F #xAD #x61C
                       #x180B #x180F #x200B #x200C #x200D #x200E #x200F
                       #x202A #x202E #x2060 #x2069 #x206F #xFEFF
                       #xE0001 #xE007F #xE0100 #xE01EF))
    (is = 0 (clun.text:string-width (sw-string codepoint))
        "U+~4,'0X is invisible" codepoint))
  (is = 2 (clun.text:string-width (sw-string #x61 #x2060 #x62))))

(define-test string-width-east-asian-and-ambiguous
  (is = 4 (clun.text:string-width (sw-string #x4E2D #x6587)))
  (is = 10 (clun.text:string-width
            (sw-string #x3053 #x3093 #x306B #x3061 #x306F)))
  (is = 3 (clun.text:string-width (sw-string #xFF71 #xFF72 #xFF73)))
  (is = 1 (clun.text:string-width (sw-string #x2605)))
  (is = 2 (clun.text:string-width (sw-string #x2605)
                                  :ambiguous-is-narrow nil))
  ;; Clun applies the option uniformly, including Latin-1-backed JS strings.
  (is = 1 (clun.text:string-width (sw-string #xB1)))
  (is = 2 (clun.text:string-width (sw-string #xB1)
                                  :ambiguous-is-narrow nil))
  (is = 5 (clun.text:string-width (sw-string #x3B1 #x3B2 #x3B3 #x3B4 #x3B5)))
  (is = 10 (clun.text:string-width (sw-string #x3B1 #x3B2 #x3B3 #x3B4 #x3B5)
                                   :ambiguous-is-narrow nil)))

(define-test string-width-combining-and-indic
  (is = 0 (clun.text:string-width (sw-string #x300)))
  (is = 1 (clun.text:string-width (sw-string #x65 #x301)))
  (is = 2 (clun.text:string-width (sw-string #x304B)))
  ;; Bun deliberately counts the wide combining kana mark in the cluster.
  (is = 4 (clun.text:string-width (sw-string #x304B #x3099)))
  (is = 1 (clun.text:string-width (sw-string #x915)))
  (is = 1 (clun.text:string-width (sw-string #x915 #x94D)))
  (is = 1 (clun.text:string-width (sw-string #x915 #x93F)))
  (is = 3 (clun.text:string-width (sw-string #xE1B #xE0F #xE31 #xE01)))
  (is = 1 (clun.text:string-width (sw-string #x93D)))
  (is = 1 (clun.text:string-width (sw-string #xD4F))))

(define-test string-width-emoji-clusters
  (is = 2 (clun.text:string-width (sw-string #x1F600)))
  (is = 2 (clun.text:string-width (sw-string #x1F1FA #x1F1F8)))
  (is = 1 (clun.text:string-width (sw-string #x1F1E6)))
  (is = 3 (clun.text:string-width (sw-string #x1F1E6 #x1F3FB)))
  (is = 4 (clun.text:string-width (sw-string #x1F1E6 #x1F1E7 #x1F3FB)))
  (is = 2 (clun.text:string-width (sw-string #x1F44B #x1F3FD)))
  (is = 4 (clun.text:string-width (sw-string #x1F469 #x1F3FB #x1F3FC)))
  (is = 4 (clun.text:string-width (sw-string #x1F469 #x300 #x1F3FB)))
  (is = 4 (clun.text:string-width (sw-string #x1F469 #xFE0F #x1F3FB)))
  (is = 4 (clun.text:string-width (sw-string #x1F4BB #x1F3FB)))
  (is = 4 (clun.text:string-width (sw-string #x1F3FB #x1F3FC)))
  ;; Woman technologist.
  (is = 2 (clun.text:string-width (sw-string #x1F469 #x200D #x1F4BB)))
  (is = 4 (clun.text:string-width
           (sw-string #x1F469 #x200D #x1F4BB #x1F3FB)))
  (is = 2 (clun.text:string-width
           (sw-string #x1F4BB #x200D #x1F469 #x1F3FB)))
  ;; Family: man, woman, girl, boy.
  (is = 2 (clun.text:string-width
           (sw-string #x1F468 #x200D #x1F469 #x200D #x1F467 #x200D #x1F466)))
  ;; Rainbow flag, with VS16 inside the ZWJ sequence.
  (is = 2 (clun.text:string-width
           (sw-string #x1F3F3 #xFE0F #x200D #x1F308)))
  (is = 2 (clun.text:string-width (sw-string #x31 #xFE0F #x20E3)))
  (is = 2 (clun.text:string-width (sw-string #x20E3)))
  (is = 4 (clun.text:string-width (sw-string #x20E3 #x1F3FB)))
  (is = 6 (clun.text:string-width
           (sw-string #x20E3 #x1F3FB #x20E3 #x1F3FC)))
  (is = 1 (clun.text:string-width (sw-string #x31 #xFE0F)))
  (is = 2 (clun.text:string-width (sw-string #x2764 #xFE0F)))
  (is = 1 (clun.text:string-width (sw-string #x2764 #xFE0E)))
  (is = 1 (clun.text:string-width (sw-string #x61 #xFE0F)))
  (is = 0 (clun.text:string-width (sw-string #xFE0E)))
  (is = 1 (clun.text:string-width (sw-string #xFE0E #x300 #x41)))
  (is = 1 (clun.text:string-width (sw-string #xFE0E #x200D #x41)))
  (is = 1 (clun.text:string-width (sw-string #x300 #xFE0E)))
  (is = 1 (clun.text:string-width (sw-string #x600 #xFE0E)))
  (is = 1 (clun.text:string-width (sw-string #x600 #x41 #xFE0F)))
  (is = 1 (clun.text:string-width (sw-string #x600 #x31 #xFE0F)))
  (is = 1 (clun.text:string-width
           (sw-string #x600 #x600 #x41 #xFE0F)))
  (is = 1 (clun.text:string-width (sw-string #x600 #x1F3FB #xFE0E)))
  (is = 2 (clun.text:string-width (sw-string #x890 #x41 #xFE0E)))
  (is = 2 (clun.text:string-width (sw-string #x890 #x41 #xFE0F)))
  (is = 1 (clun.text:string-width (sw-string #x890 #x4E2D #xFE0E)))
  (is = 2 (clun.text:string-width (sw-string #x890 #x4E2D #xFE0F)))
  (is = 3 (clun.text:string-width (sw-string #x890 #x1F3FB)))
  (is = 1 (clun.text:string-width (sw-string #x890 #x1F3FB #xFE0E)))
  (is = 2 (clun.text:string-width (sw-string #x890 #x1F3FB #xFE0F)))
  (is = 2 (clun.text:string-width (sw-string #x890 #x1F3FB #x20E3)))
  ;; Bun's ASCII component flush is width-only: the UAX Prepend boundary
  ;; remains joined, but the ASCII base starts a separately measured unit.
  (is = 3 (clun.text:string-width (sw-string #x890 #x31 #xFE0F #x20E3)))
  (is = 3 (clun.text:string-width (sw-string #x890 #x41 #x20E3)))
  (is = 2 (clun.text:string-width (sw-string #x600 #x31 #xFE0F #x20E3)))
  (is = 2 (clun.text:string-width (sw-string #x600 #x41 #x20E3)))
  ;; Unicode 17 gives LANGUAGE TAG GCB Control, so it terminates the
  ;; nonzero Prepend component before the keycap mark.
  (is = 3 (clun.text:string-width (sw-string #x890 #xE0001 #x20E3)))
  (is = 5 (clun.text:string-width (sw-string #x890 #x1F469 #x1F3FB)))
  (is = 4 (clun.text:string-width (sw-string #x600 #x1F469 #x1F3FB)))
  (is = 0 (clun.text:string-width (sw-string #xFE00 #xFE0E #xFE0F)))
  (is = 0 (clun.text:string-width (sw-string #xFE0E #xFE0F)))
  (is = 0 (clun.text:string-width (sw-string #x300 #xFE0F)))
  (is = 0 (clun.text:string-width (sw-string #x200B #xFE0F)))
  (is = 0 (clun.text:string-width (sw-string #x200D #xFE0F)))
  (is = 2 (clun.text:string-width (sw-string #xA9 #xFE0F #xFE0E)))
  (is = 2 (clun.text:string-width (sw-string #x2600 #xFE0F #xFE0E))))

(define-test string-width-utf16-decoding
  ;; U+1F600 as a JS UTF-16 pair and as a host scalar have identical width.
  (is = 2 (clun.text:string-width (sw-units #xD83D #xDE00)))
  (is = 2 (clun.text:string-width (sw-string #x1F600)))
  (is = 2 (clun.text:string-width
           (sw-units #xD800 #x61 #xDC00 #x62)))
  (dolist (surrogate '(#xD800 #xDBFF #xDC00 #xDFFF))
    (is = 0 (clun.text:string-width (sw-units surrogate)))))

(define-test string-width-csi
  (let ((escape #x1B))
    (dolist (final '(#x40 #x41 #x48 #x4A #x4B #x53 #x6D #x7E))
      (is = 2 (clun.text:string-width
               (sw-ansi "a" escape "[12;3" final "b"))
          "CSI final U+~2,'0X" final))
    (is = 5 (clun.text:string-width
             (sw-ansi escape "[31mhello" escape "[0m")))
    (is = 12 (clun.text:string-width
              (sw-ansi escape "[31mhello" escape "[0m")
              :count-ansi-escape-codes t))
    (is = 100 (clun.text:string-width
               (sw-ansi (make-string 100 :initial-element #\a)
                        escape "[31;38;2;1;2;3")))
    ;; '[' is itself a legal final byte for the first malformed CSI.
    (is = 3 (clun.text:string-width
             (sw-ansi escape "[31;" escape "[32m")))
    (is = 1 (clun.text:string-width (sw-ansi escape "A")))
    (is = 1 (clun.text:string-width
             (sw-ansi escape escape "[1mx" escape "[0m")))))

(define-test string-width-ansi-lone-surrogate-state
  (let ((inside-csi (sw-units #x61 #x1B #x5B #x31 #x32 #xD800 #x6D #x58))
        (after-escape (sw-units #x61 #x1B #xD800 #x5B #x33 #x31 #x6D #x58)))
    (is = 2 (clun.text:string-width inside-csi)
        "lone surrogate does not terminate CSI")
    (is = 2 (clun.text:string-width after-escape)
        "lone surrogate does not consume pending bare ESC state")
    (is = 2 (clun.text:string-width
             (sw-units #x61 #x1B #xDC00 #x5B #x33 #x31 #x6D #x58)))
    (is = 2 (clun.text:string-width
             (sw-units #x61 #x1B #x5B #x31 #xDBFF #xD800 #x6D #x58)))
    ;; Exercise the same state transitions over 800,000 UTF-16 units.
    (is = 200000
        (clun.text:string-width (sw-repeat-units inside-csi 100000)))))

(define-test string-width-osc
  (let ((escape #x1B))
    (is = 4 (clun.text:string-width
             (sw-ansi escape "]8;;https://example.com" 7
                      "link" escape "]8;;" 7)))
    (is = 4 (clun.text:string-width
             (sw-ansi escape "]8;;https://example.com" escape "\\"
                      "link" escape "]8;;" escape "\\")))
    (is = 4 (clun.text:string-width
             (sw-ansi escape "]8;;https://example.com" #x9C "link")))
    (is = 2 (clun.text:string-width
             (concatenate 'string
                          (sw-ansi "a" escape "]8;;https://")
                          (sw-string #x1F389)
                          (sw-ansi 7 "b"))))
    (is = 2 (clun.text:string-width
             (concatenate 'string (sw-string #x4E2D)
                          (sw-ansi escape "]0;unterminated title"))))))

(define-test string-width-ansi-is-grapheme-transparent
  (let ((escape #x1B))
    (is = 1 (clun.text:string-width
             (concatenate 'string
                          (sw-ansi escape "[31me" escape "[39m")
                          (sw-string #x301))))
    (is = 2 (clun.text:string-width
             (concatenate 'string
                          (sw-ansi escape "[1m")
                          (sw-string #x1F469)
                          (sw-ansi escape "[22m")
                          (sw-string #x200D #x1F4BB))))
    (is = 2 (clun.text:string-width
             (concatenate 'string
                          (sw-string #x1F1FA)
                          (sw-ansi escape "[31m")
                          (sw-string #x1F1F8))))))

(define-test string-width-linear-stress
  (is = 1000000
      (clun.text:string-width (make-string 1000000 :initial-element #\x)))
  (let ((input (sw-ansi "a" #x1B "[" (make-string 100000 :initial-element #\9))))
    (is = 1 (clun.text:string-width input))))
