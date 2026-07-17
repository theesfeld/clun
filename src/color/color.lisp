;;;; color.lisp -- bounded CSS Color parsing, conversion, formatting, and ANSI palettes.

(in-package :clun.color)

(defconstant +max-color-input-units+ 1048576)
(defconstant +epsilon+ 1d-12)

(defstruct (color (:constructor %make-color (space c1 c2 c3 alpha)))
  (space :srgb :type keyword)
  (c1 0d0)
  (c2 0d0)
  (c3 0d0)
  (alpha 1d0))

(defstruct (color-token (:constructor %make-token (kind &optional value unit)))
  kind value unit)

(define-condition color-parse-error (error) ())

(declaim (inline %invalid %clamp %unit-clamp %component))
(defun %invalid () (error 'color-parse-error))
(defun %clamp (value low high) (max low (min high value)))
(defun %unit-clamp (value) (%clamp value 0d0 1d0))
(defun %component (value) (if (eq value :none) 0d0 value))

(defun %finitep (number)
  (and (floatp number)
       (= number number)
       (<= most-negative-double-float number most-positive-double-float)))

(defun make-rgba-color (red green blue &optional (alpha 255))
  (%make-color :srgb (/ (coerce red 'double-float) 255d0)
               (/ (coerce green 'double-float) 255d0)
               (/ (coerce blue 'double-float) 255d0)
               (/ (coerce alpha 'double-float) 255d0)))

(defun %quantized-unit-component (value)
  (let ((scaled (* 255f0 (coerce (%unit-clamp value) 'single-float))))
    (/ (coerce (floor (+ scaled 0.5f0)) 'double-float) 255d0)))

(defun %concrete-srgb-color (red green blue alpha)
  (%make-color :srgb (%quantized-unit-component red) (%quantized-unit-component green)
               (%quantized-unit-component blue) (%quantized-unit-component alpha)))

(defun %ascii-space-p (char)
  (or (char= char #\Space) (char= char #\Tab) (char= char #\Newline)
      (char= char #\Return) (char= char #\Page)))

(defun %trim-css-space (string)
  (string-trim '(#\Space #\Tab #\Newline #\Return #\Page) string))

(defun %bounded-utf16-length-p (string limit)
  (loop with units = 0
        for char across string
        do (incf units (if (> (char-code char) #xffff) 2 1))
           (when (> units limit) (return nil))
        finally (return t)))

(defun %ascii-lower (string)
  (map 'string (lambda (char)
                 (if (and (char>= char #\A) (char<= char #\Z))
                     (code-char (+ (char-code char) 32))
                     char))
       string))

(defun %digit-p (char)
  (and char (char>= char #\0) (char<= char #\9)))

(defun %ident-char-p (char)
  (and char (or (and (char>= char #\a) (char<= char #\z))
                (and (char>= char #\A) (char<= char #\Z))
                (char= char #\-))))

(defun %ident-continue-char-p (char)
  (or (%ident-char-p char) (%digit-p char)))

(defun %number-start-p (string index)
  (let* ((length (length string))
         (char (and (< index length) (char string index)))
         (next (and (< (1+ index) length) (char string (1+ index)))))
    (or (%digit-p char)
        (and char (char= char #\.) (%digit-p next))
        (and char (or (char= char #\+) (char= char #\-))
             (or (%digit-p next)
                 (and next (char= next #\.)
                      (< (+ index 2) length) (%digit-p (char string (+ index 2)))))))))

(defun %scan-number-token (string start)
  (let* ((length (length string))
         (index start))
    (when (and (< index length) (find (char string index) "+-")) (incf index))
    (let ((digits 0))
      (loop while (and (< index length) (%digit-p (char string index)))
            do (incf index) (incf digits))
      (when (and (< (1+ index) length) (char= (char string index) #\.)
                 (%digit-p (char string (1+ index))))
        (incf index)
        (loop while (and (< index length) (%digit-p (char string index)))
              do (incf index) (incf digits)))
      (when (zerop digits) (%invalid))
      (when (and (< index length) (find (char string index) "eE"))
        (incf index)
        (when (and (< index length) (find (char string index) "+-")) (incf index))
        (let ((exponent-digits 0))
          (loop while (and (< index length) (%digit-p (char string index)))
                do (incf index) (incf exponent-digits))
          (when (zerop exponent-digits) (%invalid))))
    (when (> (- index start) 128) (%invalid))
    (let* ((*read-eval* nil)
           (*read-default-float-format* 'double-float)
           (spelling (subseq string start index))
           (number (handler-case
                       (let ((value (read-from-string spelling nil nil)))
                         (coerce value 'double-float))
                     (error () (%invalid))))
           (unit-start index))
      (unless (%finitep number) (%invalid))
      (loop while (and (< index length) (%ident-continue-char-p (char string index)))
            do (incf index))
      (when (and (< index length) (char= (char string index) #\%)) (incf index))
      (values (%make-token :number number (%ascii-lower (subseq string unit-start index))) index)))))

(defun %tokenize-components (string)
  (let ((index 0) (length (length string)) (tokens '()) (need-separator nil))
    (loop
      (let ((had-space nil))
        (loop while (and (< index length) (%ascii-space-p (char string index)))
              do (setf had-space t) (incf index))
        (when (= index length) (return (nreverse tokens)))
        (let ((char (char string index)))
          (cond
            ((char= char #\,)
             (when (or (null tokens) (member (color-token-kind (car tokens)) '(:comma :slash)))
               (%invalid))
             (push (%make-token :comma) tokens) (incf index) (setf need-separator nil))
            ((char= char #\/)
             (when (or (null tokens) (member (color-token-kind (car tokens)) '(:comma :slash)))
               (%invalid))
             (push (%make-token :slash) tokens) (incf index) (setf need-separator nil))
            ((%number-start-p string index)
             (when (and need-separator (not had-space)) (%invalid))
             (multiple-value-bind (token next) (%scan-number-token string index)
               (push token tokens) (setf index next need-separator t)))
            ((%ident-char-p char)
             (when (and need-separator (not had-space)) (%invalid))
             (let ((start index))
               (loop while (and (< index length) (%ident-continue-char-p (char string index)))
                     do (incf index))
               (push (%make-token :ident (%ascii-lower (subseq string start index))) tokens)
               (setf need-separator t)))
            (t (%invalid))))))))

(defun %number-token-p (token) (eq (color-token-kind token) :number))
(defun %none-token-p (token)
  (and (eq (color-token-kind token) :ident) (string= (color-token-value token) "none")))

(defun %numeric-component (token &key percentage-scale (number-scale 1d0)
                                      (allow-none nil) (clamp nil))
  (cond
    ((and allow-none (%none-token-p token)) :none)
    ((not (%number-token-p token)) (%invalid))
    (t
     (let* ((unit (color-token-unit token))
            (value (color-token-value token))
            (result (cond
                      ((string= unit "") (* value number-scale))
                      ((and percentage-scale (string= unit "%")) (* value percentage-scale))
                      (t (%invalid)))))
       (if clamp (%clamp result (car clamp) (cdr clamp)) result)))))

(defun %alpha-component (token)
  (let ((value (%numeric-component token :percentage-scale 0.01d0 :allow-none t
                                   :clamp '(0d0 . 1d0))))
    value))

(defun %percentage-component (token &key (scale 0.01d0) (allow-none nil) clamp)
  (when (and allow-none (%none-token-p token))
    (return-from %percentage-component :none))
  (unless (and (%number-token-p token) (string= (color-token-unit token) "%"))
    (%invalid))
  (let ((value (* (color-token-value token) scale)))
    (if clamp (%clamp value (car clamp) (cdr clamp)) value)))

(defun %number-component (token &key (allow-none nil) minimum)
  (when (and allow-none (%none-token-p token))
    (return-from %number-component :none))
  (unless (and (%number-token-p token) (string= (color-token-unit token) ""))
    (%invalid))
  (let ((value (color-token-value token)))
    (if minimum (max minimum value) value)))

(defun %angle-component (token &key (allow-none nil))
  (when (and allow-none (%none-token-p token)) (return-from %angle-component :none))
  (unless (%number-token-p token) (%invalid))
  (let ((value (color-token-value token)) (unit (color-token-unit token)))
    (mod (cond ((or (string= unit "") (string= unit "deg")) value)
               ((string= unit "grad") (* value 0.9d0))
               ((string= unit "rad") (* value (/ 180d0 pi)))
               ((string= unit "turn") (* value 360d0))
               (t (%invalid)))
         360d0)))

(defun %split-functional-components (tokens &key allow-legacy-four)
  (let ((slash-count (count :slash tokens :key #'color-token-kind))
        (comma-count (count :comma tokens :key #'color-token-kind)))
    (when (> slash-count 1) (%invalid))
    (cond
      ((plusp comma-count)
       (when (plusp slash-count) (%invalid))
       (let ((groups '()) (current '()))
         (dolist (token tokens)
           (if (eq (color-token-kind token) :comma)
               (progn
                 (unless (= (length current) 1) (%invalid))
                 (push (car current) groups) (setf current '()))
               (push token current)))
         (unless (= (length current) 1) (%invalid))
         (push (car current) groups)
         (setf groups (nreverse groups))
         (unless (or (= (length groups) 3)
                     (and allow-legacy-four (= (length groups) 4)))
           (%invalid))
         (values (subseq groups 0 3) (and (= (length groups) 4) (nth 3 groups)) :legacy)))
      (t
       (let ((slash (position :slash tokens :key #'color-token-kind)))
         (if slash
             (progn
               (unless (and (= slash 3) (= (length tokens) 5)) (%invalid))
               (values (subseq tokens 0 3) (nth 4 tokens) :modern))
             (progn
               (unless (= (length tokens) 3) (%invalid))
               (values tokens nil :modern))))))))

(defun %parse-rgb-function (name tokens)
  (multiple-value-bind (components alpha syntax)
      (%split-functional-components tokens :allow-legacy-four t)
    (declare (ignore name))
    (when (eq syntax :legacy)
      (when (some #'%none-token-p components) (%invalid))
      (let ((unit (color-token-unit (first components))))
        (unless (and (member unit '("" "%") :test #'string=)
                     (every (lambda (token)
                              (and (%number-token-p token)
                                   (string= (color-token-unit token) unit)))
                            (rest components)))
          (%invalid))))
    (labels ((channel (token)
               (cond ((%none-token-p token) :none)
                     ((not (%number-token-p token)) (%invalid))
                     (t
                     (let ((value (color-token-value token))
                            (unit (color-token-unit token)))
                        (cond ((string= unit "%") (%unit-clamp (/ value 100d0)))
                              ((string= unit "")
                               (/ (coerce (floor (+ (%clamp value 0d0 255d0) 0.5d0))
                                          'double-float)
                                  255d0))
                              (t (%invalid))))))))
      (let* ((channels (mapcar #'channel components))
             (alpha-value (if alpha (%alpha-component alpha) 1d0)))
        (if (and (every (lambda (value) (not (eq value :none))) channels)
                 (not (eq alpha-value :none)))
            (%concrete-srgb-color (first channels) (second channels) (third channels) alpha-value)
            (%make-color :srgb (first channels) (second channels) (third channels)
                         alpha-value))))))

(defun %hsl->srgb-components (hue saturation lightness)
  ;; Bun's CSS converter intentionally uses f32 here. Preserve that arithmetic
  ;; through byte normalization while keeping Clun's stored channels as doubles.
  (let* ((hue (coerce hue 'single-float))
         (s (coerce (%unit-clamp saturation) 'single-float))
         (l (coerce (%unit-clamp lightness) 'single-float))
         (h (/ (- hue (* 360f0 (floor (/ hue 360f0)))) 360f0))
         (m2 (if (<= l 0.5f0) (* l (+ s 1f0)) (- (+ l s) (* l s))))
         (m1 (- (* l 2f0) m2))
         (h3 (* h 3f0)))
    (labels ((channel (value)
               (when (< value 0f0) (incf value 3f0))
               (when (> value 3f0) (decf value 3f0))
               (coerce (cond ((< (* value 2f0) 1f0)
                              (+ m1 (* (- m2 m1) value 2f0)))
                             ((< (* value 2f0) 3f0) m2)
                             ((< value 2f0)
                              (+ m1 (* (- m2 m1) (- 2f0 value) 2f0)))
                             (t m1))
                       'double-float)))
      (values (channel (+ h3 1f0)) (channel h3) (channel (- h3 1f0))))))

(defun %hwb->srgb-components (hue whiteness blackness)
  (let ((white (coerce (%component whiteness) 'single-float))
        (black (coerce (%component blackness) 'single-float)))
    (if (>= (+ white black) 1f0)
        (let ((grey (/ white (+ white black))))
          (values (coerce grey 'double-float) (coerce grey 'double-float)
                  (coerce grey 'double-float)))
        (multiple-value-bind (r g b) (%hsl->srgb-components (%component hue) 1d0 0.5d0)
          (let ((factor (- 1f0 white black)))
            (values (coerce (+ (* (coerce r 'single-float) factor) white) 'double-float)
                    (coerce (+ (* (coerce g 'single-float) factor) white) 'double-float)
                    (coerce (+ (* (coerce b 'single-float) factor) white) 'double-float)))))))

(defun %parse-hsl-function (name tokens)
  (multiple-value-bind (components alpha syntax)
      (%split-functional-components tokens :allow-legacy-four t)
    (declare (ignore name))
    (when (and (eq syntax :legacy) (some #'%none-token-p components)) (%invalid))
    (let ((h (%angle-component (first components) :allow-none t))
          (s (%percentage-component (second components) :allow-none t
                                    :clamp '(0d0 . 1d0)))
          (l (%percentage-component (third components) :allow-none t
                                    :clamp '(0d0 . 1d0)))
          (a (if alpha (%alpha-component alpha) 1d0)))
      (if (and (not (eq h :none)) (not (eq s :none)) (not (eq l :none))
               (not (eq a :none)))
          (multiple-value-bind (r g b) (%hsl->srgb-components h s l)
            (%concrete-srgb-color r g b a))
          (%make-color :hsl h s l a)))))

(defun %parse-hwb-function (tokens)
  (multiple-value-bind (components alpha syntax)
      (%split-functional-components tokens)
    (when (eq syntax :legacy) (%invalid))
    (let* ((h (%angle-component (first components) :allow-none t))
           (w (%percentage-component (second components) :allow-none t
                                     :clamp '(0d0 . 1d0)))
           (b (%percentage-component (third components) :allow-none t
                                     :clamp '(0d0 . 1d0)))
           (a (if alpha (%alpha-component alpha) 1d0)))
      (if (and (not (eq h :none)) (not (eq w :none)) (not (eq b :none))
               (not (eq a :none)))
          (multiple-value-bind (r g blue) (%hwb->srgb-components h w b)
            (%concrete-srgb-color r g blue a))
          (%make-color :hwb h w b a)))))

(defun %split-space-components (tokens)
  (when (plusp (count :comma tokens :key #'color-token-kind)) (%invalid))
  (let ((slash (position :slash tokens :key #'color-token-kind)))
    (cond
      (slash
       (unless (and (= slash 3) (= (length tokens) 5)) (%invalid))
       (values (subseq tokens 0 3) (nth 4 tokens)))
      (t
       (unless (= (length tokens) 3) (%invalid))
       (values tokens nil)))))

(defun %parse-lab-like-function (name tokens)
  (multiple-value-bind (components alpha) (%split-space-components tokens)
    (let ((a (if alpha (%alpha-component alpha) 1d0)))
      (cond
        ((string= name "lab")
         (%make-color :lab
                      (%percentage-component (first components) :scale 1d0 :allow-none t
                                             :clamp '(0d0 . #.most-positive-double-float))
                      (%number-component (second components) :allow-none t)
                      (%number-component (third components) :allow-none t)
                      a))
        ((string= name "lch")
         (%make-color :lch
                      (%percentage-component (first components) :scale 1d0 :allow-none t
                                             :clamp '(0d0 . #.most-positive-double-float))
                      (%number-component (second components) :allow-none t :minimum 0d0)
                      (%angle-component (third components) :allow-none t) a))
        ((string= name "oklab")
         (%make-color :oklab
                      (%percentage-component (first components) :allow-none t
                                             :clamp '(0d0 . #.most-positive-double-float))
                      (%number-component (second components) :allow-none t)
                      (%number-component (third components) :allow-none t)
                      a))
        ((string= name "oklch")
         (%make-color :oklch
                      (%percentage-component (first components) :allow-none t
                                             :clamp '(0d0 . #.most-positive-double-float))
                      (%number-component (second components) :allow-none t :minimum 0d0)
                      (%angle-component (third components) :allow-none t) a))
        (t (%invalid))))))

(defparameter +predefined-color-spaces+
  '("srgb" "srgb-linear" "display-p3" "a98-rgb" "prophoto-rgb" "rec2020"
    "xyz" "xyz-d50" "xyz-d65"))

(defun %predefined-space-keyword (name)
  (cond ((string= name "srgb") :srgb-float)
        ((string= name "srgb-linear") :srgb-linear)
        ((string= name "display-p3") :display-p3)
        ((string= name "a98-rgb") :a98-rgb)
        ((string= name "prophoto-rgb") :prophoto-rgb)
        ((string= name "rec2020") :rec2020)
        ((or (string= name "xyz") (string= name "xyz-d65")) :xyz-d65)
        ((string= name "xyz-d50") :xyz-d50)
        (t (%invalid))))

(defun %parse-color-function (tokens)
  (when (or (null tokens) (not (eq (color-token-kind (first tokens)) :ident))) (%invalid))
  (let ((space-name (color-token-value (first tokens))))
    (unless (member space-name +predefined-color-spaces+ :test #'string=) (%invalid))
    (multiple-value-bind (components alpha) (%split-space-components (rest tokens))
      (%make-color (%predefined-space-keyword space-name)
                   (%numeric-component (first components) :percentage-scale 0.01d0
                                       :allow-none t)
                   (%numeric-component (second components) :percentage-scale 0.01d0
                                       :allow-none t)
                   (%numeric-component (third components) :percentage-scale 0.01d0
                                       :allow-none t)
                   (if alpha (%alpha-component alpha) 1d0)))))

(defun %parse-hex-color (string)
  (let* ((digits (subseq string 1)) (length (length digits)))
    (unless (and (member length '(3 4 6 8))
                 (every (lambda (char) (digit-char-p char 16)) digits))
      (%invalid))
    (labels ((hex (start count) (parse-integer digits :start start :end (+ start count) :radix 16))
             (nibble (index) (* 17 (hex index 1))))
      (case length
        (3 (make-rgba-color (nibble 0) (nibble 1) (nibble 2)))
        (4 (make-rgba-color (nibble 0) (nibble 1) (nibble 2) (nibble 3)))
        (6 (make-rgba-color (hex 0 2) (hex 2 2) (hex 4 2)))
        (8 (make-rgba-color (hex 0 2) (hex 2 2) (hex 4 2) (hex 6 2)))))))

(defun %parse-named-color (string)
  (if (string= string "transparent")
      (make-rgba-color 0 0 0 0)
      (multiple-value-bind (packed found) (gethash string *named-color-table*)
        (when found
          (make-rgba-color (ldb (byte 8 16) packed) (ldb (byte 8 8) packed)
                           (ldb (byte 8 0) packed))))))

(defun parse-color (input)
  "Parse one concrete CSS color string. Invalid input returns NIL."
  (handler-case
      (progn
        (unless (and (stringp input) (%bounded-utf16-length-p input +max-color-input-units+))
          (%invalid))
        (let* ((trimmed (%trim-css-space input))
               (length (length trimmed)))
          (when (zerop length) (%invalid))
          (cond
            ((char= (char trimmed 0) #\#) (%parse-hex-color trimmed))
            ((and (%ident-char-p (char trimmed 0))
                  (not (find #\( trimmed)))
             (or (%parse-named-color (%ascii-lower trimmed)) (%invalid)))
            (t
             (let ((open (position #\( trimmed)) (close (position #\) trimmed :from-end t)))
               (unless (and open close (= close (1- length)) (< open close)
                            (not (find #\( trimmed :start (1+ open)))
                            (not (find #\) trimmed :start (1+ open) :end close)))
                 (%invalid))
               (let* ((name (%ascii-lower (subseq trimmed 0 open)))
                      (body (subseq trimmed (1+ open) close))
                      (tokens (%tokenize-components body)))
                 (cond ((or (string= name "rgb") (string= name "rgba"))
                        (%parse-rgb-function name tokens))
                       ((or (string= name "hsl") (string= name "hsla"))
                        (%parse-hsl-function name tokens))
                       ((string= name "hwb") (%parse-hwb-function tokens))
                       ((member name '("lab" "lch" "oklab" "oklch") :test #'string=)
                        (%parse-lab-like-function name tokens))
                       ((string= name "color") (%parse-color-function tokens))
                       (t (%invalid)))))))))
    (color-parse-error () nil)
    (arithmetic-error () nil)
    (reader-error () nil)))

;;; Color-space conversion ----------------------------------------------------

(declaim (inline %signed-power %signed-cuberoot))
(defun %signed-power (value exponent)
  (* (if (minusp value) -1d0 1d0) (expt (abs value) exponent)))

(defun %signed-cuberoot (value)
  (%signed-power value (/ 1d0 3d0)))

(defun %matrix3 (matrix x y z)
  (values (+ (* (aref matrix 0) x) (* (aref matrix 1) y) (* (aref matrix 2) z))
          (+ (* (aref matrix 3) x) (* (aref matrix 4) y) (* (aref matrix 5) z))
          (+ (* (aref matrix 6) x) (* (aref matrix 7) y) (* (aref matrix 8) z))))

(defparameter +srgb-to-xyz-d65+
  #(0.41239079926595934d0 0.35758433938387796d0 0.1804807884018343d0
    0.21263900587151027d0 0.7151686787677559d0 0.07219231536073371d0
    0.01933081871559185d0 0.11919477979462599d0 0.9505321522496607d0))
(defparameter +xyz-d65-to-srgb+
  #(3.2409699419045226d0 -1.537383177570094d0 -0.4986107602930034d0
    -0.9692436362808796d0 1.8759675015077202d0 0.04155505740717559d0
    0.05563007969699366d0 -0.20397695888897652d0 1.0569715142428786d0))
(defparameter +p3-to-xyz-d65+
  #(0.4865709486482162d0 0.26566769316909306d0 0.1982172852343625d0
    0.2289745640697488d0 0.6917385218365064d0 0.079286914093745d0
    0d0 0.04511338185890264d0 1.043944368900976d0))
(defparameter +a98-to-xyz-d65+
  #(0.5766690429101305d0 0.1855582379065463d0 0.1882286462349947d0
    0.29734497525053605d0 0.6273635662554661d0 0.0752914584939979d0
    0.02703136138641234d0 0.07068885253582723d0 0.9913375368376388d0))
(defparameter +prophoto-to-xyz-d50+
  #(0.7977666449006423d0 0.13518129740053308d0 0.0313477341283922d0
    0.2880748288194013d0 0.711835234241873d0 0.00008993693872564d0
    0d0 0d0 0.8251046025104601d0))
(defparameter +rec2020-to-xyz-d65+
  #(0.6369580483012914d0 0.14461690358620832d0 0.1688809751641721d0
    0.2627002120112671d0 0.6779980715188708d0 0.05930171646986196d0
    0d0 0.028072693049087428d0 1.060985057710791d0))
(defparameter +xyz-d50-to-d65+
  #(0.9554734527042182d0 -0.023098536874261423d0 0.0632593086610217d0
    -0.028369706963208136d0 1.0099954580058226d0 0.021041398966943008d0
    0.012314001688319899d0 -0.020507696433477912d0 1.3303659366080753d0))
(defparameter +xyz-d65-to-d50+
  #(1.0479298208405488d0 0.022946793341019088d0 -0.05019222954313557d0
    0.029627815688159344d0 0.990434484573249d0 -0.01707382502938514d0
    -0.009243058152591178d0 0.015055144896577895d0 0.7518742899580008d0))

(defun %lin-srgb-component (component)
  (let ((absolute (abs component)))
    (if (< absolute 0.04045d0)
        (/ component 12.92d0)
        (* (if (minusp component) -1d0 1d0)
           (expt (/ (+ absolute 0.055d0) 1.055d0) 2.4d0)))))

(defun %gam-srgb-component (component)
  (let ((absolute (abs component)))
    (if (> absolute 0.0031308d0)
        (* (if (minusp component) -1d0 1d0)
           (- (* 1.055d0 (expt absolute (/ 1d0 2.4d0))) 0.055d0))
        (* 12.92d0 component))))

(defun %lin-a98-component (component) (%signed-power component (/ 563d0 256d0)))
(defun %lin-prophoto-component (component)
  (if (<= (abs component) (/ 16d0 512d0))
      (/ component 16d0)
      (%signed-power component 1.8d0)))
(defun %lin-rec2020-component (component)
  (let ((absolute (abs component)) (alpha 1.09929682680944d0)
        (beta 0.018053968510807d0))
    (if (< absolute (* beta 4.5d0))
        (/ component 4.5d0)
        (* (if (minusp component) -1d0 1d0)
           (expt (/ (+ absolute (- alpha 1d0)) alpha) (/ 1d0 0.45d0))))))

(defun %lch->lab (lightness chroma hue)
  (let ((radians (* (%component hue) (/ pi 180d0))))
    (values (%component lightness) (* (%component chroma) (cos radians))
            (* (%component chroma) (sin radians)))))

(defun %lab->xyz-d50 (lightness a b)
  (let* ((l (%component lightness)) (aa (%component a)) (bb (%component b))
         (k (/ 24389d0 27d0)) (e (/ 216d0 24389d0))
         (f1 (/ (+ l 16d0) 116d0))
         (f0 (+ (/ aa 500d0) f1))
         (f2 (- f1 (/ bb 200d0)))
         (f0-cube (expt f0 3)) (f2-cube (expt f2 3))
         (x (if (> f0-cube e) f0-cube (/ (- (* 116d0 f0) 16d0) k)))
         (y (if (> l (* k e)) (expt (/ (+ l 16d0) 116d0) 3) (/ l k)))
         (z (if (> f2-cube e) f2-cube (/ (- (* 116d0 f2) 16d0) k))))
    (values (* x (/ 0.3457d0 0.3585d0)) y
            (* z (/ (- 1d0 0.3457d0 0.3585d0) 0.3585d0)))))

(defun %oklab->xyz-d65 (lightness a b)
  (let* ((l (%component lightness)) (aa (%component a)) (bb (%component b))
         (l-root (+ l (* 0.3963377774d0 aa) (* 0.2158037573d0 bb)))
         (m-root (- l (* 0.1055613458d0 aa) (* 0.0638541728d0 bb)))
         (s-root (- l (* 0.0894841775d0 aa) (* 1.291485548d0 bb)))
         (ll (expt l-root 3)) (mm (expt m-root 3)) (ss (expt s-root 3)))
    (values (+ (* 1.2268798733741557d0 ll) (* -0.5578149965554813d0 mm)
               (* 0.28139105017721583d0 ss))
            (+ (* -0.04057576262431372d0 ll) (* 1.1122868293970594d0 mm)
               (* -0.07171106666151701d0 ss))
            (+ (* -0.07637294974672142d0 ll) (* -0.4214933239627914d0 mm)
               (* 1.5869240244272418d0 ss)))))

(defun %color->xyz-d65 (color)
  (let ((a (%component (color-c1 color))) (b (%component (color-c2 color)))
        (c (%component (color-c3 color))))
    (case (color-space color)
      ((:srgb :srgb-float)
       (%matrix3 +srgb-to-xyz-d65+ (%lin-srgb-component a) (%lin-srgb-component b)
                 (%lin-srgb-component c)))
      (:srgb-linear (%matrix3 +srgb-to-xyz-d65+ a b c))
      (:display-p3
       (%matrix3 +p3-to-xyz-d65+ (%lin-srgb-component a) (%lin-srgb-component b)
                 (%lin-srgb-component c)))
      (:a98-rgb
       (%matrix3 +a98-to-xyz-d65+ (%lin-a98-component a) (%lin-a98-component b)
                 (%lin-a98-component c)))
      (:prophoto-rgb
       (multiple-value-bind (x y z)
           (%matrix3 +prophoto-to-xyz-d50+ (%lin-prophoto-component a)
                     (%lin-prophoto-component b) (%lin-prophoto-component c))
         (%matrix3 +xyz-d50-to-d65+ x y z)))
      (:rec2020
       (%matrix3 +rec2020-to-xyz-d65+ (%lin-rec2020-component a)
                 (%lin-rec2020-component b) (%lin-rec2020-component c)))
      (:hsl
       (multiple-value-bind (r g blue) (%hsl->srgb-components a b c)
         (%matrix3 +srgb-to-xyz-d65+ (%lin-srgb-component r) (%lin-srgb-component g)
                   (%lin-srgb-component blue))))
      (:hwb
       (multiple-value-bind (r g blue) (%hwb->srgb-components a b c)
         (%matrix3 +srgb-to-xyz-d65+ (%lin-srgb-component r) (%lin-srgb-component g)
                   (%lin-srgb-component blue))))
      (:xyz-d65 (values a b c))
      (:xyz-d50 (%matrix3 +xyz-d50-to-d65+ a b c))
      (:lab
       (multiple-value-bind (x y z) (%lab->xyz-d50 a b c)
         (%matrix3 +xyz-d50-to-d65+ x y z)))
      (:lch
       (multiple-value-bind (l aa bb) (%lch->lab a b c)
         (multiple-value-bind (x y z) (%lab->xyz-d50 l aa bb)
           (%matrix3 +xyz-d50-to-d65+ x y z))))
      (:oklab (%oklab->xyz-d65 a b c))
      (:oklch
       (multiple-value-bind (l aa bb) (%lch->lab a b c)
         (%oklab->xyz-d65 l aa bb)))
      (otherwise (%invalid)))))

(defun %xyz-d65->oklab (x y z)
  (multiple-value-bind (ll mm ss)
      (%matrix3 #(0.8190224432164319d0 0.3619062562801221d0 -0.12887378261216414d0
                  0.0329836671980271d0 0.9292868468965546d0 0.03614466816999844d0
                  0.048177199566046255d0 0.26423952494422764d0 0.6335478258136937d0)
                x y z)
    (%matrix3 #(0.2104542553d0 0.793617785d0 -0.0040720468d0
                1.9779984951d0 -2.428592205d0 0.4505937099d0
                0.0259040371d0 0.7827717662d0 -0.808675766d0)
              (%signed-cuberoot ll) (%signed-cuberoot mm) (%signed-cuberoot ss))))

(defun %srgb->oklab (red green blue)
  (multiple-value-bind (x y z)
      (%matrix3 +srgb-to-xyz-d65+ (%lin-srgb-component red) (%lin-srgb-component green)
                (%lin-srgb-component blue))
    (%xyz-d65->oklab x y z)))

(defun %oklch->srgb (lightness chroma hue)
  (let ((radians (* hue (/ pi 180d0))))
    (multiple-value-bind (x y z)
        (%oklab->xyz-d65 lightness (* chroma (cos radians)) (* chroma (sin radians)))
      (multiple-value-bind (red green blue) (%matrix3 +xyz-d65-to-srgb+ x y z)
        (values (%gam-srgb-component red) (%gam-srgb-component green)
                (%gam-srgb-component blue))))))

(defun %srgb-in-gamut-p (red green blue)
  (and (<= 0d0 red 1d0) (<= 0d0 green 1d0) (<= 0d0 blue 1d0)))

(defun %clip-srgb (red green blue)
  (values (%unit-clamp red) (%unit-clamp green) (%unit-clamp blue)))

(defun %delta-eok (red green blue lightness chroma hue)
  (multiple-value-bind (l a b) (%srgb->oklab red green blue)
    (let ((radians (* hue (/ pi 180d0))))
      (sqrt (+ (expt (- l lightness) 2)
               (expt (- a (* chroma (cos radians))) 2)
               (expt (- b (* chroma (sin radians))) 2))))))

(defun %gamut-map-srgb (red green blue)
  "Map an out-of-gamut sRGB triple with the CSS Color 4 OKLCH algorithm."
  (when (%srgb-in-gamut-p red green blue)
    (return-from %gamut-map-srgb (values red green blue)))
  (multiple-value-bind (lightness aa bb) (%srgb->oklab red green blue)
    (let* ((chroma (sqrt (+ (* aa aa) (* bb bb))))
           (hue (mod (* (atan bb aa) (/ 180d0 pi)) 360d0))
           (jnd 0.02d0)
           (epsilon 0.00001d0))
      (when (or (> lightness 1d0) (< (abs (- lightness 1d0)) epsilon))
        (return-from %gamut-map-srgb (values 1d0 1d0 1d0)))
      (when (< lightness epsilon)
        (return-from %gamut-map-srgb (values 0d0 0d0 0d0)))
      (multiple-value-bind (cr cg cb) (%clip-srgb red green blue)
        (when (< (%delta-eok cr cg cb lightness chroma hue) jnd)
          (return-from %gamut-map-srgb (values cr cg cb))))
      (let ((minimum 0d0) (maximum chroma) (current chroma))
        (loop while (> (- maximum minimum) epsilon)
              do (setf current (/ (+ minimum maximum) 2d0))
                 (multiple-value-bind (rr gg bb) (%oklch->srgb lightness current hue)
                   (if (%srgb-in-gamut-p rr gg bb)
                       (setf minimum current)
                       (multiple-value-bind (cr cg cb) (%clip-srgb rr gg bb)
                         (if (< (%delta-eok cr cg cb lightness current hue) jnd)
                             (return-from %gamut-map-srgb (values cr cg cb))
                             (setf maximum current)))))
              finally
                 (multiple-value-bind (rr gg bb) (%oklch->srgb lightness current hue)
                   (return-from %gamut-map-srgb (%clip-srgb rr gg bb))))))))

(defun color->srgb (color)
  "Return nonlinear sRGB and alpha as four values. RGB is not clipped."
  (case (color-space color)
    ((:srgb :srgb-float)
     (values (%component (color-c1 color)) (%component (color-c2 color))
             (%component (color-c3 color)) (%unit-clamp (%component (color-alpha color)))))
    (:hsl
     (multiple-value-bind (r g b)
         (%hsl->srgb-components (%component (color-c1 color)) (%component (color-c2 color))
                                (%component (color-c3 color)))
       (values r g b (%unit-clamp (%component (color-alpha color))))))
    (:hwb
     (multiple-value-bind (r g b)
         (%hwb->srgb-components (color-c1 color) (color-c2 color) (color-c3 color))
       (values r g b (%unit-clamp (%component (color-alpha color))))))
    (otherwise
     (multiple-value-bind (x y z) (%color->xyz-d65 color)
       (multiple-value-bind (r g b) (%matrix3 +xyz-d65-to-srgb+ x y z)
         (let ((red (%gam-srgb-component r)) (green (%gam-srgb-component g))
               (blue (%gam-srgb-component b)))
           (if (member (color-space color) '(:lab :lch :oklab :oklch))
               (multiple-value-bind (mapped-red mapped-green mapped-blue)
                   (%gamut-map-srgb red green blue)
                 (values mapped-red mapped-green mapped-blue
                         (%unit-clamp (%component (color-alpha color)))))
               (values red green blue
                       (%unit-clamp (%component (color-alpha color)))))))))))

(defun %byte-channel (component)
  (floor (+ (* 255d0 (%unit-clamp component)) 0.5d0)))

(defun color->rgba-bytes (color)
  (multiple-value-bind (r g b alpha) (color->srgb color)
    (values (%byte-channel r) (%byte-channel g) (%byte-channel b) (%byte-channel alpha))))

(defun color->hsl (color)
  "Return hue degrees, saturation/lightness in [0,1], and alpha."
  (when (eq (color-space color) :hsl)
    (return-from color->hsl
      (values (%component (color-c1 color)) (%unit-clamp (%component (color-c2 color)))
              (%unit-clamp (%component (color-c3 color)))
              (%unit-clamp (%component (color-alpha color))))))
  (multiple-value-bind (raw-r raw-g raw-b alpha) (color->srgb color)
    (let* ((r (%unit-clamp raw-r)) (g (%unit-clamp raw-g)) (b (%unit-clamp raw-b))
           (max (max r g b)) (min (min r g b)) (delta (- max min))
           (lightness (/ (+ max min) 2d0)))
      (if (< (abs delta) +epsilon+)
          (values 0d0 0d0 lightness alpha)
          (let ((saturation (/ delta (- 1d0 (abs (- (* 2d0 lightness) 1d0)))))
                (hue (cond ((= max r) (* 60d0 (mod (/ (- g b) delta) 6d0)))
                           ((= max g) (* 60d0 (+ (/ (- b r) delta) 2d0)))
                           (t (* 60d0 (+ (/ (- r g) delta) 4d0))))))
            (values (mod hue 360d0) (%unit-clamp saturation)
                    (%unit-clamp lightness) alpha))))))

(defun %xyz-d50->lab (x y z)
  (let* ((e (/ 216d0 24389d0)) (k (/ 24389d0 27d0))
         (xr (/ x (/ 0.3457d0 0.3585d0)))
         (yr y)
         (zr (/ z (/ (- 1d0 0.3457d0 0.3585d0) 0.3585d0))))
    (flet ((f (value) (if (> value e) (%signed-cuberoot value) (/ (+ (* k value) 16d0) 116d0))))
      (let ((fx (f xr)) (fy (f yr)) (fz (f zr)))
        (values (- (* 116d0 fy) 16d0) (* 500d0 (- fx fy)) (* 200d0 (- fy fz)))))))

(defun color->lab (color)
  "Return CIE Lab D50 L in [nominally 0,100], a, b, and alpha."
  (when (eq (color-space color) :lab)
    (return-from color->lab
      (values (%component (color-c1 color)) (%component (color-c2 color))
              (%component (color-c3 color)) (%unit-clamp (%component (color-alpha color))))))
  (when (eq (color-space color) :lch)
    (multiple-value-bind (l a b)
        (%lch->lab (color-c1 color) (color-c2 color) (color-c3 color))
      (return-from color->lab
        (values l a b (%unit-clamp (%component (color-alpha color)))))))
  (multiple-value-bind (x y z) (%color->xyz-d65 color)
    (multiple-value-bind (xd yd zd) (%matrix3 +xyz-d65-to-d50+ x y z)
      (multiple-value-bind (l a b) (%xyz-d50->lab xd yd zd)
        (values l a b (%unit-clamp (%component (color-alpha color))))))))

;;; Formatting and terminal palettes -----------------------------------------

(defun format-color-number (number &optional (digits 7))
  "Format the shortest decimal that round-trips as the same double float."
  (declare (ignore digits))
  (unless (%finitep number) (%invalid))
  (when (zerop number) (return-from format-color-number "0"))
  (let* ((raw (%ascii-lower (write-to-string (coerce number 'double-float))))
         (marker (position #\d raw))
         (mantissa (if marker (subseq raw 0 marker) raw))
         (exponent (and marker (subseq raw (1+ marker))))
         (length (length mantissa)))
    (when (and (>= length 2) (string= mantissa ".0" :start1 (- length 2)))
      (setf mantissa (subseq mantissa 0 (- length 2))))
    (if (or (null exponent) (string= exponent "0"))
        mantissa
        (concatenate 'string mantissa "e" exponent))))

(defun %packed-rgb (r g b) (logior (ash r 16) (ash g 8) b))

(defun %compressible-byte-p (byte) (= (ldb (byte 4 4) byte) (ldb (byte 4 0) byte)))

(defun format-css-color (color)
  (case (color-space color)
    ((:srgb :hsl :hwb)
     (multiple-value-bind (r g b a) (color->rgba-bytes color)
       (if (= a 255)
           (let* ((packed (%packed-rgb r g b)) (named (cdr (assoc packed +short-color-names+))))
             (cond (named named)
                   ((and (%compressible-byte-p r) (%compressible-byte-p g) (%compressible-byte-p b))
                    (string-downcase
                     (format nil "#~1,'0x~1,'0x~1,'0x" (ldb (byte 4 4) r)
                             (ldb (byte 4 4) g) (ldb (byte 4 4) b))))
                   (t (string-downcase (format nil "#~2,'0x~2,'0x~2,'0x" r g b)))))
           (if (and (%compressible-byte-p r) (%compressible-byte-p g)
                    (%compressible-byte-p b) (%compressible-byte-p a))
               (string-downcase
                (format nil "#~1,'0x~1,'0x~1,'0x~1,'0x" (ldb (byte 4 4) r)
                        (ldb (byte 4 4) g) (ldb (byte 4 4) b) (ldb (byte 4 4) a)))
               (string-downcase (format nil "#~2,'0x~2,'0x~2,'0x~2,'0x" r g b a))))))
    ((:lab :lch :oklab :oklch)
     (let* ((name (string-downcase (symbol-name (color-space color))))
            (l (color-c1 color)) (a (color-c2 color)) (b (color-c3 color))
            (alpha (color-alpha color)))
       (format nil "~a(~a~a ~a ~a~a)" name
               (if (eq l :none) "none"
                   (format-color-number
                    (if (member (color-space color) '(:oklab :oklch)) (* l 100d0) l)))
               (if (eq l :none) "" "%")
               (if (eq a :none) "none" (format-color-number a))
               (if (eq b :none) "none" (format-color-number b))
               (if (and (not (eq alpha :none)) (< (abs (- alpha 1d0)) +epsilon+)) ""
                   (format nil " / ~a" (if (eq alpha :none) "none"
                                           (format-color-number alpha)))))))
    (otherwise
     (let ((name (case (color-space color)
                   (:srgb-float "srgb") (:srgb-linear "srgb-linear")
                   (:display-p3 "display-p3")
                   (:a98-rgb "a98-rgb") (:prophoto-rgb "prophoto-rgb")
                   (:rec2020 "rec2020") (:xyz-d50 "xyz-d50") (:xyz-d65 "xyz")
                   (otherwise (string-downcase (symbol-name (color-space color)))))))
       (format nil "color(~a ~a ~a ~a~a)" name
               (if (eq (color-c1 color) :none) "none" (format-color-number (color-c1 color)))
               (if (eq (color-c2 color) :none) "none" (format-color-number (color-c2 color)))
               (if (eq (color-c3 color) :none) "none" (format-color-number (color-c3 color)))
               (if (and (not (eq (color-alpha color) :none))
                        (< (abs (- (color-alpha color) 1d0)) +epsilon+))
                   ""
                   (format nil " / ~a"
                           (if (eq (color-alpha color) :none) "none"
                               (format-color-number (color-alpha color))))))))))

(defun %ansi6 (value)
  (cond ((< value 48) 0) ((< value 114) 1) (t (floor (- value 35) 40))))

(defun %square-distance (r1 g1 b1 r2 g2 b2)
  (+ (expt (- r1 r2) 2) (expt (- g1 g2) 2) (expt (- b1 b2) 2)))

(defun ansi256-index (red green blue)
  (let* ((levels #(0 95 135 175 215 255))
         (qr (%ansi6 red)) (qg (%ansi6 green)) (qb (%ansi6 blue))
         (cr (aref levels qr)) (cg (aref levels qg)) (cb (aref levels qb)))
    (when (and (= cr red) (= cg green) (= cb blue))
      (return-from ansi256-index (+ 16 (* 36 qr) (* 6 qg) qb)))
    (let* ((average (floor (+ red green blue) 3))
           (grey-index (if (> average 238) 23 (floor (max 0 (- average 3)) 10)))
           (grey (+ 8 (* 10 grey-index))))
      (if (< (%square-distance grey grey grey red green blue)
             (%square-distance cr cg cb red green blue))
          (+ 232 grey-index)
          (+ 16 (* 36 qr) (* 6 qg) qb)))))

(defparameter +ansi256-to-16+
  #(0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 0 4 4 4 12 12 2 6 4 4 12 12 2 2 6 4
    12 12 2 2 2 6 12 12 10 10 10 10 14 12 10 10 10 10 10 14 1 5 4 4 12 12 3 8 4 4
    12 12 2 2 6 4 12 12 2 2 2 6 12 12 10 10 10 10 14 12 10 10 10 10 10 14 1 1 5 4
    12 12 1 1 5 4 12 12 3 3 8 4 12 12 2 2 2 6 12 12 10 10 10 10 14 12 10 10 10 10
    10 14 1 1 1 5 12 12 1 1 1 5 12 12 1 1 1 5 12 12 3 3 3 7 12 12 10 10 10 10 14
    12 10 10 10 10 10 14 9 9 9 9 13 12 9 9 9 9 13 12 9 9 9 9 13 12 9 9 9 9 13 12
    11 11 11 11 7 12 10 10 10 10 10 14 9 9 9 9 9 13 9 9 9 9 9 13 9 9 9 9 9 13 9
    9 9 9 9 13 9 9 9 9 9 13 11 11 11 11 11 15 0 0 0 0 0 0 8 8 8 8 8 8 7 7 7 7 7
    7 15 15 15 15 15 15))

(defun ansi16-index (red green blue)
  (aref +ansi256-to-16+ (ansi256-index red green blue)))
