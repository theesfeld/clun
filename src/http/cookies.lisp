;;;; cookies.lisp -- engine-independent Cookie parsing and serialization.

(in-package :clun.cookies)

(define-condition cookie-error (error)
  ((message :initarg :message :reader cookie-error-message))
  (:report (lambda (condition stream)
             (write-string (cookie-error-message condition) stream))))

(define-condition invalid-cookie-name (cookie-error) ())
(define-condition invalid-cookie-path (cookie-error) ())
(define-condition invalid-cookie-domain (cookie-error) ())
(define-condition invalid-cookie-string (cookie-error) ())

(defun %cookie-error (condition-type control &rest arguments)
  (error condition-type :message (apply #'format nil control arguments)))

(defstruct (cookie (:constructor %make-cookie) (:copier nil) (:conc-name cookie-))
  (name "")
  (value "")
  domain
  (domain-present-p nil)
  (path "/")
  expires-ms
  (expires-present-p nil)
  max-age
  max-age-text
  (max-age-present-p nil)
  (secure-p nil)
  (http-only-p nil)
  (same-site :lax)
  (partitioned-p nil))

(defstruct (cookie-pair
            (:constructor make-cookie-pair (name value))
            (:copier nil)
            (:conc-name cookie-pair-))
  (name "")
  (value ""))

(defstruct (cookie-map-state
            (:constructor %make-cookie-map-state (originals modifications))
            (:copier nil)
            (:conc-name cookie-map-state-))
  originals
  modifications)

(defun %copy-string (value)
  (check-type value string)
  (copy-seq value))

(defun %ascii-digit-p (character)
  (char<= #\0 character #\9))

(defun %ascii-space-p (character)
  (or (char= character #\Space) (char= character #\Tab)))

(defun %ascii-trim-bounds (string start end)
  (check-type string string)
  (check-type start (integer 0 *))
  (check-type end (integer 0 *))
  (unless (<= start end (length string))
    (error 'type-error :datum (list start end)
                       :expected-type `(cons (integer 0 ,(length string))
                                             (integer ,start ,(length string)))))
  (let ((start start)
        (end end))
    (loop while (and (< start end) (%ascii-space-p (char string start)))
          do (incf start))
    (loop while (and (< start end) (%ascii-space-p (char string (1- end))))
          do (decf end))
    (values start end)))

(defun validate-cookie-name (name)
  (check-type name string)
  (unless (and (plusp (length name))
               (every (lambda (character)
                        (let ((code (char-code character)))
                          (or (<= #x21 code #x3a)
                              (= code #x3c)
                              (<= #x3e code #x7e))))
                      name))
    (%cookie-error 'invalid-cookie-name
                   "Invalid cookie name: contains invalid characters"))
  name)

(defun validate-cookie-path (path)
  (check-type path string)
  (unless (every (lambda (character)
                   (let ((code (char-code character)))
                     (or (<= #x20 code #x3a)
                         (<= #x3d code #x7e))))
                 path)
    (%cookie-error 'invalid-cookie-path
                   "Invalid cookie path: contains invalid characters"))
  path)

(defun validate-cookie-domain (domain)
  (check-type domain string)
  ;; An explicit empty string is observable state, but is omitted on the wire.
  (unless (every (lambda (character)
                   (or (char<= #\a character #\z)
                       (char<= #\0 character #\9)
                       (char= character #\.)
                       (char= character #\-)))
                 domain)
    (%cookie-error 'invalid-cookie-domain
                   "Invalid cookie domain: contains invalid characters"))
  domain)

(defun validate-cookie-field-value (value)
  "Validate the pinned HTTP field-value domain used by Cookie.parse.

An empty value is allowed through this boundary so cookie-name validation owns
the observable empty-input error."
  (check-type value string)
  (when (plusp (length value))
    (when (or (%ascii-space-p (char value 0))
              (%ascii-space-p (char value (1- (length value)))))
      (%cookie-error 'invalid-cookie-string
                     "cookie string is not a valid HTTP header value")))
  (unless (every (lambda (character)
                   (let ((code (char-code character)))
                     (or (= code #x09)
                         (<= #x20 code #x7e)
                         (<= #x80 code #xff))))
                 value)
    (%cookie-error 'invalid-cookie-string
                   "cookie string is not a valid HTTP header value"))
  value)

(defun normalize-same-site (value &key case-sensitive)
  (let ((text (etypecase value
                (string value)
                (symbol (symbol-name value)))))
    (flet ((matches (expected)
             (if case-sensitive
                 (string= text expected)
                 (string-equal text expected))))
      (cond ((matches "strict") :strict)
            ((matches "lax") :lax)
            ((matches "none") :none)
            (t (%cookie-error 'cookie-error
                              "Invalid sameSite value. Must be 'strict', 'lax', or 'none'"))))))

(defun %normalize-number-marker (text)
  (let ((copy (string-downcase text)))
    (dotimes (index (length copy))
      (when (find (char copy index) "dfs" :test #'char=)
        (setf (char copy index) #\e)))
    (let ((exponent (position #\e copy)))
      (if (and exponent (string= (subseq copy exponent) "e0"))
          (subseq copy 0 exponent)
          copy))))

(declaim (inline %float-nan-p %float-infinity-p))
(declaim (ftype (function (double-float) string) %cookie-double-text))

(defun %float-nan-p (value)
  (and (floatp value) (sb-ext:float-nan-p value)))

(defun %float-infinity-p (value)
  (and (floatp value) (sb-ext:float-infinity-p value)))

(defun %default-number-text (value)
  (cond ((%float-nan-p value) "NaN")
        ((%float-infinity-p value) (if (minusp value) "-Infinity" "Infinity"))
        ((and (realp value) (zerop value)) "0")
        ((integerp value) (write-to-string value))
        ((eq value :positive-infinity) "Infinity")
        ((eq value :negative-infinity) "-Infinity")
        ((floatp value) (%cookie-double-text (coerce value 'double-float)))
        ((rationalp value) (%cookie-double-text (coerce value 'double-float)))
        (t (write-to-string value))))

(defun %max-age-text-p (text)
  (or (string= text "Infinity")
      (string= text "-Infinity")
      (let ((index 0)
            (length (length text)))
        (when (and (< index length) (char= (char text index) #\-))
          (incf index))
        (let ((integer-start index))
          (loop while (and (< index length) (%ascii-digit-p (char text index)))
                do (incf index))
          (when (= integer-start index) (return-from %max-age-text-p nil)))
        (when (and (< index length) (char= (char text index) #\.))
          (incf index)
          (loop while (and (< index length) (%ascii-digit-p (char text index)))
                do (incf index)))
        (when (and (< index length) (member (char text index) '(#\e #\E)))
          (incf index)
          (when (and (< index length) (member (char text index) '(#\+ #\-)))
            (incf index))
          (let ((exponent-start index))
            (loop while (and (< index length) (%ascii-digit-p (char text index)))
                  do (incf index))
            (when (= exponent-start index) (return-from %max-age-text-p nil))))
        (= index length))))

(defun %timeclip-milliseconds (milliseconds)
  (unless (and (realp milliseconds)
               (not (%float-nan-p milliseconds))
               (not (%float-infinity-p milliseconds))
               (<= -8640000000000000 milliseconds 8640000000000000))
    (%cookie-error 'cookie-error "Invalid cookie expiration date"))
  (truncate milliseconds))

(defun make-cookie (name value
                    &key domain (path "/")
                      (expires-ms nil expires-supplied-p)
                      (max-age nil max-age-supplied-p) max-age-text
                      secure http-only (same-site :lax) partitioned)
  (declare (ignore max-age-text))
  (validate-cookie-name name)
  (check-type value string)
  (validate-cookie-path path)
  (when domain (validate-cookie-domain domain))
  (let* ((expires-present-p (and expires-supplied-p (not (null expires-ms))))
         (stored-expires (and expires-present-p (%timeclip-milliseconds expires-ms)))
         (max-age-present-p
           (and max-age-supplied-p (not (null max-age))
                (not (%float-nan-p max-age))))
         (stored-max-age-text
           (and max-age-present-p
                (%default-number-text max-age))))
    (when (and stored-max-age-text (not (%max-age-text-p stored-max-age-text)))
      (%cookie-error 'cookie-error "Invalid Max-Age serialization"))
    (%make-cookie :name (%copy-string name)
                  :value (%copy-string value)
                  :domain (and domain (%copy-string domain))
                  :domain-present-p (not (null domain))
                  :path (%copy-string path)
                  :expires-ms stored-expires
                  :expires-present-p expires-present-p
                  :max-age max-age
                  :max-age-text stored-max-age-text
                  :max-age-present-p max-age-present-p
                  :secure-p (not (null secure))
                  :http-only-p (not (null http-only))
                  :same-site (normalize-same-site same-site)
                  :partitioned-p (not (null partitioned)))))

(defun clone-cookie (cookie)
  (check-type cookie cookie)
  (%make-cookie :name (%copy-string (cookie-name cookie))
                :value (%copy-string (cookie-value cookie))
                :domain (and (cookie-domain-present-p cookie)
                             (%copy-string (cookie-domain cookie)))
                :domain-present-p (cookie-domain-present-p cookie)
                :path (%copy-string (cookie-path cookie))
                :expires-ms (cookie-expires-ms cookie)
                :expires-present-p (cookie-expires-present-p cookie)
                :max-age (cookie-max-age cookie)
                :max-age-text (and (cookie-max-age-present-p cookie)
                                   (%copy-string (cookie-max-age-text cookie)))
                :max-age-present-p (cookie-max-age-present-p cookie)
                :secure-p (cookie-secure-p cookie)
                :http-only-p (cookie-http-only-p cookie)
                :same-site (cookie-same-site cookie)
                :partitioned-p (cookie-partitioned-p cookie)))

(defun update-cookie-value (cookie value)
  (check-type cookie cookie)
  (setf (cookie-value cookie) (%copy-string value))
  cookie)

(defun update-cookie-domain (cookie domain)
  (check-type cookie cookie)
  (validate-cookie-domain domain)
  (setf (cookie-domain cookie) (%copy-string domain)
        (cookie-domain-present-p cookie) t)
  cookie)

(defun clear-cookie-domain (cookie)
  (check-type cookie cookie)
  (setf (cookie-domain cookie) nil
        (cookie-domain-present-p cookie) nil)
  cookie)

(defun update-cookie-path (cookie path)
  (check-type cookie cookie)
  (validate-cookie-path path)
  (setf (cookie-path cookie) (%copy-string path))
  cookie)

(defun update-cookie-expires (cookie milliseconds)
  (check-type cookie cookie)
  (setf (cookie-expires-ms cookie) (%timeclip-milliseconds milliseconds)
        (cookie-expires-present-p cookie) t)
  cookie)

(defun clear-cookie-expires (cookie)
  (check-type cookie cookie)
  (setf (cookie-expires-ms cookie) nil
        (cookie-expires-present-p cookie) nil)
  cookie)

(defun update-cookie-max-age (cookie value &optional text)
  (declare (ignore text))
  (check-type cookie cookie)
  (unless (or (realp value)
              (member value '(:positive-infinity :negative-infinity)))
    (error 'type-error :datum value
                       :expected-type '(or real (member :positive-infinity
                                                       :negative-infinity))))
  (when (%float-nan-p value)
    (setf (cookie-max-age cookie) nil
          (cookie-max-age-text cookie) nil
          (cookie-max-age-present-p cookie) nil)
    (return-from update-cookie-max-age cookie))
  (let ((text (%default-number-text value)))
    (unless (%max-age-text-p text)
      (%cookie-error 'cookie-error "Invalid Max-Age serialization"))
    (setf (cookie-max-age cookie) value
          (cookie-max-age-text cookie) text
          (cookie-max-age-present-p cookie) t))
  cookie)

(defun clear-cookie-max-age (cookie)
  (check-type cookie cookie)
  (setf (cookie-max-age cookie) nil
        (cookie-max-age-text cookie) nil
        (cookie-max-age-present-p cookie) nil)
  cookie)

(defun update-cookie-secure (cookie value)
  (setf (cookie-secure-p cookie) (not (null value)))
  cookie)

(defun update-cookie-http-only (cookie value)
  (setf (cookie-http-only-p cookie) (not (null value)))
  cookie)

(defun update-cookie-same-site (cookie value &key case-sensitive)
  (setf (cookie-same-site cookie)
        (normalize-same-site value :case-sensitive case-sensitive))
  cookie)

(defun update-cookie-partitioned (cookie value)
  (setf (cookie-partitioned-p cookie) (not (null value)))
  cookie)

(defun cookie-expired-p (cookie now-ms)
  "Return expiration state using NOW-MS supplied by the caller."
  (check-type cookie cookie)
  (cond ((cookie-max-age-present-p cookie)
         (let ((value (cookie-max-age cookie)))
           (cond ((eq value :positive-infinity) nil)
                 ((eq value :negative-infinity) t)
                 (t (<= value 0)))))
        ((cookie-expires-present-p cookie)
         (> now-ms (cookie-expires-ms cookie)))
        (t nil)))

(defun %prefix-equal-p (prefix string)
  (and (<= (length prefix) (length string))
       (string-equal prefix string :end2 (length prefix))))

(defun make-cookie-tombstone (name &key domain (path "/"))
  (make-cookie name "" :domain domain :path path :expires-ms 0
               :secure (or (%prefix-equal-p "__secure-" name)
                           (%prefix-equal-p "__host-" name))))

;;; HTTP dates

(defconstant +timeclip-limit+ 8640000000000000)
(defparameter +month-names+
  #("Jan" "Feb" "Mar" "Apr" "May" "Jun"
    "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))
(defparameter +weekday-names+ #("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun"))
(defparameter +weekday-full-names+
  #("Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday" "Sunday"))
(defparameter +date-zone-offsets+
  '(("GMT" . 0) ("UTC" . 0) ("UT" . 0) ("Z" . 0)
    ("EST" . -18000) ("EDT" . -14400)
    ("CST" . -21600) ("CDT" . -18000)
    ("MST" . -25200) ("MDT" . -21600)
    ("PST" . -28800) ("PDT" . -25200)))

(defun %date-whitespace-p (character)
  (or (char= character #\Space) (char= character #\Tab)))

(defun %date-ascii-range-p (string start end)
  (loop for index from start below end
        for character = (char string index)
        always (and (< (char-code character) #x80)
                    (not (member character '(#\Return #\Newline #\Nul))))))

(defun %date-tokenize (string start end starts ends)
  "Tokenize into fixed caller-owned storage; date grammar needs at most six."
  (let ((index start)
        (count 0))
    (loop while (< index end)
          do (loop while (and (< index end)
                              (%date-whitespace-p (char string index)))
                   do (incf index))
             (when (< index end)
               (when (= count (length starts))
                 (return-from %date-tokenize (values nil nil)))
               (setf (aref starts count) index)
               (loop while (and (< index end)
                                (not (%date-whitespace-p (char string index))))
                     do (incf index))
               (setf (aref ends count) index)
               (incf count)))
    (values count t)))

(defun %range-digits-p (string start end)
  (and (< start end)
       (loop for index from start below end
             always (%ascii-digit-p (char string index)))))

(defun %parse-fixed-digits-range (string start end minimum maximum)
  (when (and (<= minimum (- end start) maximum)
             (%range-digits-p string start end))
    (let ((value 0))
      (loop for index from start below end
            do (setf value (+ (* value 10)
                              (- (char-code (char string index))
                                 (char-code #\0)))))
      value)))

(defun %range-member-p (string start end choices)
  (find-if (lambda (choice) (%range-string-equal string start end choice))
           choices))

(defun %short-weekday-range-p (string start end
                               &key comma-required comma-forbidden)
  (let* ((comma-p (and (< start end) (char= (char string (1- end)) #\,)))
         (name-end (if comma-p (1- end) end)))
    (and (or (not comma-required) comma-p)
         (or (not comma-forbidden) (not comma-p))
         (= (- name-end start) 3)
         (%range-member-p string start name-end +weekday-names+))))

(defun %full-weekday-range-p (string start end)
  (and (< start end)
       (char= (char string (1- end)) #\,)
       (%range-member-p string start (1- end) +weekday-full-names+)))

(defun %month-number-range (string start end)
  (when (= (- end start) 3)
    (let ((position
            (position-if (lambda (month)
                           (%range-string-equal string start end month))
                         +month-names+)))
      (and position (1+ position)))))

(defun %parse-clock-range (string start end)
  (when (and (= (- end start) 8)
             (char= (char string (+ start 2)) #\:)
             (char= (char string (+ start 5)) #\:))
    (let ((hours (%parse-fixed-digits-range string start (+ start 2) 2 2))
          (minutes (%parse-fixed-digits-range string (+ start 3) (+ start 5) 2 2))
          (seconds (%parse-fixed-digits-range string (+ start 6) end 2 2)))
      (when (and hours minutes seconds
                 (<= hours 23) (<= minutes 59) (<= seconds 59))
        (values hours minutes seconds t)))))

(defun %parse-cookie-year-range (string start end &key allow-short exact-four)
  (let ((negative-p (and (< start end) (char= (char string start) #\-))))
    (when (and (< start end) (char= (char string start) #\+))
      (return-from %parse-cookie-year-range (values nil nil)))
    (let* ((digits-start (if negative-p (1+ start) start))
           (length (- end digits-start)))
      (unless (and (%range-digits-p string digits-start end)
                   (if exact-four
                       (and (not negative-p) (= length 4))
                       (or (and allow-short (not negative-p) (= length 2))
                           (<= 4 length 6))))
        (return-from %parse-cookie-year-range (values nil nil)))
      (let ((year (%parse-fixed-digits-range string digits-start end length length)))
        (values (cond (negative-p (- year))
                      ((= length 2)
                       (if (< year 50) (+ year 2000) (+ year 1900)))
                      (t year))
                t)))))

(defun %parse-zone-range (string start end)
  (dolist (entry +date-zone-offsets+)
    (when (%range-string-equal string start end (car entry))
      (return-from %parse-zone-range (values (cdr entry) t))))
  (let ((length (- end start)))
    (when (and (member length '(5 6))
               (member (char string start) '(#\+ #\-)))
      (let* ((colon-p (= length 6))
             (hours (%parse-fixed-digits-range string (1+ start) (+ start 3) 2 2))
             (minutes-start (if colon-p (+ start 4) (+ start 3)))
             (minutes (%parse-fixed-digits-range string minutes-start end 2 2)))
        (when (and (or (not colon-p) (char= (char string (+ start 3)) #\:))
                   hours minutes (<= hours 23) (<= minutes 59))
          (let ((offset (+ (* hours 3600) (* minutes 60))))
            (return-from %parse-zone-range
              (values (if (char= (char string start) #\-) (- offset) offset)
                      t)))))))
  (values nil nil))

(defun %leap-year-p (year)
  (and (zerop (mod year 4))
       (or (not (zerop (mod year 100)))
           (zerop (mod year 400)))))

(defun %days-in-month (month year)
  (case month
    ((1 3 5 7 8 10 12) 31)
    ((4 6 9 11) 30)
    (2 (if (%leap-year-p year) 29 28))))

(defun %civil-to-days (year month day)
  "Proleptic Gregorian days relative to 1970-01-01."
  (let* ((adjusted-year (- year (if (<= month 2) 1 0)))
         (era (floor adjusted-year 400))
         (year-of-era (- adjusted-year (* era 400)))
         (month-position (+ month (if (> month 2) -3 9)))
         (day-of-year (+ (floor (+ (* 153 month-position) 2) 5) day -1))
         (day-of-era (+ (* year-of-era 365)
                        (floor year-of-era 4)
                        (- (floor year-of-era 100))
                        day-of-year)))
    (- (+ (* era 146097) day-of-era) 719468)))

(defun %days-to-civil (days)
  "Inverse of %CIVIL-TO-DAYS for the complete TimeClip range."
  (let* ((shifted (+ days 719468))
         (era (floor shifted 146097))
         (day-of-era (- shifted (* era 146097)))
         (year-of-era
           (floor (- day-of-era
                     (floor day-of-era 1460)
                     (- (floor day-of-era 36524))
                     (floor day-of-era 146096))
                  365))
         (year (+ year-of-era (* era 400)))
         (day-of-year (- day-of-era
                         (+ (* 365 year-of-era)
                            (floor year-of-era 4)
                            (- (floor year-of-era 100)))))
         (month-position (floor (+ (* 5 day-of-year) 2) 153))
         (day (1+ (- day-of-year (floor (+ (* 153 month-position) 2) 5))))
         (month (+ month-position (if (< month-position 10) 3 -9))))
    (values (+ year (if (<= month 2) 1 0)) month day)))

(defun %date-components-ms (year month day hours minutes seconds offset)
  (when (and (<= 1 month 12)
             (<= 1 day (%days-in-month month year))
             (<= 0 hours 23) (<= 0 minutes 59) (<= 0 seconds 59))
    (let ((milliseconds
            (* 1000 (- (+ (* (%civil-to-days year month day) 86400)
                            (* hours 3600) (* minutes 60) seconds)
                         offset))))
      (when (<= (- +timeclip-limit+) milliseconds +timeclip-limit+)
        milliseconds))))

(defun %date-separator-end-range (string index end)
  (cond ((>= index end) nil)
        ((char= (char string index) #\-) (1+ index))
        ((%date-whitespace-p (char string index))
         (loop while (and (< index end)
                          (%date-whitespace-p (char string index)))
               do (incf index))
         index)))

(defun %digit-run-end-range (string index end maximum)
  (let ((start index))
    (loop while (and (< index end)
                     (< (- index start) maximum)
                     (%ascii-digit-p (char string index)))
          do (incf index))
    (and (> index start) index)))

(defun %parse-dmy-range (string start end)
  (let ((day-end (%digit-run-end-range string start end 2)))
    (when day-end
      (let ((first-separator (%date-separator-end-range string day-end end)))
        (when (and first-separator (<= (+ first-separator 3) end))
          (let* ((month-end (+ first-separator 3))
                 (month (%month-number-range string first-separator month-end))
                 (second-separator
                   (%date-separator-end-range string month-end end)))
            (when (and month second-separator (< second-separator end))
              (let ((day (%parse-fixed-digits-range string start day-end 1 2)))
                (multiple-value-bind (year year-p)
                    (%parse-cookie-year-range string second-separator end
                                              :allow-short t)
                  (when (and day year-p)
                    (return-from %parse-dmy-range
                      (values year month day t)))))))))))
  (values nil nil nil nil))

(defun %parse-mdy-tokens (string starts ends first count)
  (when (= count 3)
    (let ((month (%month-number-range string (aref starts first)
                                      (aref ends first)))
          (day (%parse-fixed-digits-range string (aref starts (1+ first))
                                           (aref ends (1+ first)) 1 2)))
      (multiple-value-bind (year year-p)
          (%parse-cookie-year-range string (aref starts (+ first 2))
                                    (aref ends (+ first 2)))
        (when (and month day year-p)
          (return-from %parse-mdy-tokens (values year month day t))))))
  (values nil nil nil nil))

(defun %parse-numeric-range (string start end)
  (let ((first-slash (position #\/ string :start start :end end)))
    (when first-slash
      (let ((second-slash (position #\/ string :start (1+ first-slash) :end end)))
        (when (and second-slash
                   (null (position #\/ string :start (1+ second-slash) :end end)))
          (let ((month (%parse-fixed-digits-range string start first-slash 2 2))
                (day (%parse-fixed-digits-range string (1+ first-slash)
                                                 second-slash 2 2)))
            (multiple-value-bind (year year-p)
                (%parse-cookie-year-range string (1+ second-slash) end)
              (when (and month day year-p)
                (return-from %parse-numeric-range
                  (values year month day t)))))))))
  (values nil nil nil nil))

(defun %date-result (year month day hours minutes seconds offset)
  (let ((milliseconds
          (%date-components-ms year month day hours minutes seconds offset)))
    (if milliseconds (values milliseconds t) (values nil nil))))

(defun %parse-imf-ranges (string starts ends count)
  (when (and (= count 6)
             (%short-weekday-range-p string (aref starts 0) (aref ends 0)
                                             :comma-required t)
             (%range-string-equal string (aref starts 5) (aref ends 5) "GMT"))
    (let ((day (%parse-fixed-digits-range string (aref starts 1) (aref ends 1)
                                           2 2))
          (month (%month-number-range string (aref starts 2) (aref ends 2))))
      (multiple-value-bind (year year-p)
          (%parse-cookie-year-range string (aref starts 3) (aref ends 3)
                                    :exact-four t)
        (multiple-value-bind (hours minutes seconds clock-p)
            (%parse-clock-range string (aref starts 4) (aref ends 4))
          (when (and day month year-p clock-p)
            (%date-result year month day hours minutes seconds 0)))))))

(defun %parse-rfc850-ranges (string starts ends count)
  (when (and (= count 4)
             (%full-weekday-range-p string (aref starts 0) (aref ends 0))
             (%range-string-equal string (aref starts 3) (aref ends 3) "GMT"))
    (let* ((date-start (aref starts 1))
           (date-end (aref ends 1))
           (first-hyphen (position #\- string :start date-start :end date-end))
           (second-hyphen (and first-hyphen
                                (position #\- string :start (1+ first-hyphen)
                                                        :end date-end))))
      (when (and first-hyphen second-hyphen
                 (null (position #\- string :start (1+ second-hyphen)
                                                 :end date-end)))
        (let ((day (%parse-fixed-digits-range string date-start first-hyphen 2 2))
              (month (%month-number-range string (1+ first-hyphen) second-hyphen)))
          (multiple-value-bind (year year-p)
              (%parse-cookie-year-range string (1+ second-hyphen) date-end
                                        :allow-short t)
            (multiple-value-bind (hours minutes seconds clock-p)
                (%parse-clock-range string (aref starts 2) (aref ends 2))
              (when (and day month year-p
                         (= (- date-end (1+ second-hyphen)) 2) clock-p)
                (%date-result year month day hours minutes seconds 0)))))))))

(defun %parse-asctime-ranges (string starts ends count)
  (when (and (= count 5)
             (%short-weekday-range-p string (aref starts 0) (aref ends 0)
                                             :comma-forbidden t))
    (let ((month (%month-number-range string (aref starts 1) (aref ends 1)))
          (day (%parse-fixed-digits-range string (aref starts 2) (aref ends 2)
                                           1 2)))
      (multiple-value-bind (hours minutes seconds clock-p)
          (%parse-clock-range string (aref starts 3) (aref ends 3))
        (multiple-value-bind (year year-p)
            (%parse-cookie-year-range string (aref starts 4) (aref ends 4)
                                      :exact-four t)
          (when (and month day clock-p year-p)
            (%date-result year month day hours minutes seconds 0)))))))

(defun %parse-explicit-zone-ranges (string starts ends count)
  (when (>= count 3)
    (multiple-value-bind (offset zone-p)
        (%parse-zone-range string (aref starts (1- count)) (aref ends (1- count)))
      (multiple-value-bind (hours minutes seconds clock-p)
          (%parse-clock-range string (aref starts (- count 2))
                              (aref ends (- count 2)))
        (when (and zone-p clock-p)
          (let ((date-count (- count 2)))
            (labels ((finish (year month day valid-p)
                       (when valid-p
                         (return-from %parse-explicit-zone-ranges
                           (%date-result year month day hours minutes seconds
                                         offset)))))
              (when (= date-count 1)
                (multiple-value-call #'finish
                  (%parse-numeric-range string (aref starts 0) (aref ends 0))))
              (let ((first (if (%short-weekday-range-p
                                string (aref starts 0) (aref ends 0))
                               1 0)))
                (when (< first date-count)
                  (multiple-value-call #'finish
                    (%parse-dmy-range string (aref starts first)
                                      (aref ends (1- date-count))))))
              (let ((first (if (%short-weekday-range-p
                                string (aref starts 0) (aref ends 0)
                                :comma-forbidden t)
                               1 0)))
                (multiple-value-call #'finish
                  (%parse-mdy-tokens string starts ends first (- date-count first)))))))))))

(defun %parse-http-date-range (string start end)
  (unless (%date-ascii-range-p string start end)
    (return-from %parse-http-date-range (values nil nil)))
  (let ((starts (make-array 6 :element-type 'fixnum :initial-element 0))
        (ends (make-array 6 :element-type 'fixnum :initial-element 0)))
    (multiple-value-bind (count tokenized-p)
        (%date-tokenize string start end starts ends)
      (unless tokenized-p
        (return-from %parse-http-date-range (values nil nil)))
      (multiple-value-bind (milliseconds valid-p)
          (%parse-imf-ranges string starts ends count)
        (when valid-p
          (return-from %parse-http-date-range (values milliseconds t))))
      (multiple-value-bind (milliseconds valid-p)
          (%parse-rfc850-ranges string starts ends count)
        (when valid-p
          (return-from %parse-http-date-range (values milliseconds t))))
      (multiple-value-bind (milliseconds valid-p)
          (%parse-asctime-ranges string starts ends count)
        (when valid-p
          (return-from %parse-http-date-range (values milliseconds t))))
      (%parse-explicit-zone-ranges string starts ends count))))

(defun parse-http-date (string)
  "Parse the deterministic Phase 32 HTTP-date families."
  (check-type string string)
  (%parse-http-date-range string 0 (length string)))

(defun %format-cookie-year (year)
  (cond ((<= 0 year 9999) (format nil "~4,'0d" year))
        ((minusp year) (format nil "-~4,'0d" (abs year)))
        (t (write-to-string year))))

(defun format-http-date (unix-ms)
  (let* ((milliseconds (%timeclip-milliseconds unix-ms))
         (unix-seconds (floor milliseconds 1000)))
    (multiple-value-bind (days seconds-in-day) (floor unix-seconds 86400)
      (multiple-value-bind (year month day) (%days-to-civil days)
        (multiple-value-bind (hours after-hours) (floor seconds-in-day 3600)
          (multiple-value-bind (minutes seconds) (floor after-hours 60)
            (format nil "~a, ~2,'0d ~a ~a ~2,'0d:~2,'0d:~2,'0d GMT"
                    (aref +weekday-names+ (mod (+ days 3) 7)) day
                    (aref +month-names+ (1- month)) (%format-cookie-year year)
                    hours minutes seconds)))))))

;;; UTF-8 percent codecs

(defparameter +hex-digits+ "0123456789ABCDEF")

(defun %unicode-scalar (codepoint)
  (if (or (> codepoint #x10ffff) (<= #xd800 codepoint #xdfff))
      #xfffd
      codepoint))

(defun %replacement-scalar-at (value index end)
  "Read one UTF-16 scalar from VALUE, replacing lone surrogates with U+FFFD.

Clun strings normally contain UTF-16 code units, while host-side callers may
also supply a Lisp character above U+FFFF.  Supporting both representations
keeps the core useful without changing JavaScript string semantics."
  (let ((codepoint (char-code (char value index))))
    (cond
      ((<= #xd800 codepoint #xdbff)
       (if (< (1+ index) end)
           (let ((low (char-code (char value (1+ index)))))
             (if (<= #xdc00 low #xdfff)
                 (values (+ #x10000
                            (ash (- codepoint #xd800) 10)
                            (- low #xdc00))
                         (+ index 2))
                 (values #xfffd (1+ index))))
           (values #xfffd (1+ index))))
      ((or (<= #xdc00 codepoint #xdfff) (> codepoint #x10ffff))
       (values #xfffd (1+ index)))
      (t
       (values codepoint (1+ index))))))

(defun %uri-unescaped-p (codepoint)
  (or (<= (char-code #\A) codepoint (char-code #\Z))
      (<= (char-code #\a) codepoint (char-code #\z))
      (<= (char-code #\0) codepoint (char-code #\9))
      (and (< codepoint #x80)
           (find (code-char codepoint) "-_.!~*'()" :test #'char=))))

(defun %utf8-octet-count (codepoint)
  (cond ((< codepoint #x80) 1)
        ((< codepoint #x800) 2)
        ((< codepoint #x10000) 3)
        (t 4)))

(defun %write-percent-octet (octet output)
  (write-char #\% output)
  (write-char (char +hex-digits+ (ash octet -4)) output)
  (write-char (char +hex-digits+ (logand octet #x0f)) output))

(defun %write-percent-encoded-codepoint (codepoint output)
  (let ((codepoint (%unicode-scalar codepoint)))
    (if (%uri-unescaped-p codepoint)
        (write-char (code-char codepoint) output)
        (flet ((emit (octet) (%write-percent-octet octet output)))
          (cond ((< codepoint #x80)
                 (emit codepoint))
                ((< codepoint #x800)
                 (emit (logior #xc0 (ash codepoint -6)))
                 (emit (logior #x80 (logand codepoint #x3f))))
                ((< codepoint #x10000)
                 (emit (logior #xe0 (ash codepoint -12)))
                 (emit (logior #x80 (logand (ash codepoint -6) #x3f)))
                 (emit (logior #x80 (logand codepoint #x3f))))
                (t
                 (emit (logior #xf0 (ash codepoint -18)))
                 (emit (logior #x80 (logand (ash codepoint -12) #x3f)))
                 (emit (logior #x80 (logand (ash codepoint -6) #x3f)))
                 (emit (logior #x80 (logand codepoint #x3f)))))))))

(defun %encoded-value-length (value)
  (let ((output-length 0)
        (index 0)
        (end (length value)))
    (loop while (< index end)
          do (multiple-value-bind (codepoint next-index)
                 (%replacement-scalar-at value index end)
               (setf index next-index)
               (incf output-length
                     (if (%uri-unescaped-p codepoint)
                         1
                         (* 3 (%utf8-octet-count codepoint))))))
    (when (> output-length array-total-size-limit)
      (%cookie-error 'cookie-error "Encoded cookie value is too large"))
    output-length))

(defun %write-percent-encoded-value (value output)
  (let ((index 0)
        (end (length value)))
    (loop while (< index end)
          do (multiple-value-bind (codepoint next-index)
                 (%replacement-scalar-at value index end)
               (%write-percent-encoded-codepoint codepoint output)
               (setf index next-index)))))

(defun percent-encode-value (value)
  "encodeURIComponent-compatible UTF-8 encoding with uppercase hex digits."
  (check-type value string)
  (%encoded-value-length value)
  (with-output-to-string (output)
    (%write-percent-encoded-value value output)))

(defun %hex-value (character)
  (cond ((char<= #\0 character #\9)
         (- (char-code character) (char-code #\0)))
        ((char<= #\a character #\f)
         (+ 10 (- (char-code character) (char-code #\a))))
        ((char<= #\A character #\F)
         (+ 10 (- (char-code character) (char-code #\A))))))

(defun %write-js-codepoint (codepoint stream)
  "Append CODEPOINT using Clun's UTF-16 code-unit string representation."
  (let ((codepoint (%unicode-scalar codepoint)))
    (if (<= codepoint #xffff)
        (write-char (code-char codepoint) stream)
        (let ((value (- codepoint #x10000)))
          (write-char (code-char (+ #xd800 (ash value -10))) stream)
          (write-char (code-char (+ #xdc00 (logand value #x3ff))) stream)))))

(defun %utf8-octet (codepoint index)
  "Return byte INDEX from CODEPOINT's replacement-mode UTF-8 encoding."
  (let ((codepoint (%unicode-scalar codepoint)))
    (case (%utf8-octet-count codepoint)
      (1 codepoint)
      (2 (if (zerop index)
             (logior #xc0 (ash codepoint -6))
             (logior #x80 (logand codepoint #x3f))))
      (3 (case index
           (0 (logior #xe0 (ash codepoint -12)))
           (1 (logior #x80 (logand (ash codepoint -6) #x3f)))
           (otherwise (logior #x80 (logand codepoint #x3f)))))
      (4 (case index
           (0 (logior #xf0 (ash codepoint -18)))
           (1 (logior #x80 (logand (ash codepoint -12) #x3f)))
           (2 (logior #x80 (logand (ash codepoint -6) #x3f)))
           (otherwise (logior #x80 (logand codepoint #x3f))))))))

(defun %hex-octet-value (octet)
  (cond ((<= (char-code #\0) octet (char-code #\9))
         (- octet (char-code #\0)))
        ((<= (char-code #\a) octet (char-code #\f))
         (+ 10 (- octet (char-code #\a))))
        ((<= (char-code #\A) octet (char-code #\F))
         (+ 10 (- octet (char-code #\A))))))

(defun %forgiving-percent-decode-range (value start end force)
  (unless (or force (find #\% value :start start :end end))
    (return-from %forgiving-percent-decode-range (subseq value start end)))
  (with-output-to-string (output)
    ;; Stable Bun scans replacement-mode UTF-8 bytes, not host characters.  A
    ;; three-byte lookahead is enough to recognize one %XX token; the scalar
    ;; and lookahead state remain constant-size for arbitrarily large input.
    (let ((source-index start)
          (scalar 0)
          (scalar-byte-index 0)
          (scalar-byte-count 0)
          (lookahead (make-array 3 :element-type '(unsigned-byte 8)))
          (lookahead-count 0))
      (labels ((next-virtual-octet ()
                 (when (= scalar-byte-index scalar-byte-count)
                   (when (>= source-index end)
                     (return-from next-virtual-octet nil))
                   (multiple-value-bind (next-scalar next-index)
                       (%replacement-scalar-at value source-index end)
                     (setf scalar next-scalar
                           source-index next-index
                           scalar-byte-index 0
                           scalar-byte-count (%utf8-octet-count next-scalar))))
                 (prog1 (%utf8-octet scalar scalar-byte-index)
                   (incf scalar-byte-index)))
               (peek-octet (offset)
                 (loop while (<= lookahead-count offset)
                       for octet = (next-virtual-octet)
                       do (if octet
                              (setf (aref lookahead lookahead-count) octet)
                              (return-from peek-octet nil))
                          (incf lookahead-count))
                 (aref lookahead offset))
               (consume-octets (count)
                 (replace lookahead lookahead :start1 0 :start2 count
                            :end2 lookahead-count)
                 (decf lookahead-count count))
               (percent-octet ()
                 (let ((marker (peek-octet 0))
                       (high-octet (peek-octet 1))
                       (low-octet (peek-octet 2)))
                   (when (and marker high-octet low-octet
                              (= marker (char-code #\%)))
                     (let ((high (%hex-octet-value high-octet))
                           (low (%hex-octet-value low-octet)))
                       (when (and high low)
                         (values (+ (* high 16) low) t)))))))
        (loop for current = (peek-octet 0)
              while current
              do (cond
                   ((/= current (char-code #\%))
                    (%write-js-codepoint current output)
                    (consume-octets 1))
                   ((or (null (peek-octet 1)) (null (peek-octet 2)))
                    ;; An incomplete escape consumes only the percent byte.
                    (%write-js-codepoint #xfffd output)
                    (consume-octets 1))
                   (t
                    (multiple-value-bind (first valid-p) (percent-octet)
                      (cond
                        ((not valid-p)
                         ;; A complete malformed escape consumes three bytes.
                         (%write-js-codepoint #xfffd output)
                         (consume-octets 3))
                        ((< first #x80)
                         (%write-js-codepoint first output)
                         (consume-octets 3))
                        (t
                         (consume-octets 3)
                         (multiple-value-bind (count minimum codepoint)
                             (cond ((<= #xc0 first #xdf)
                                    (values 2 #x80 (logand first #x1f)))
                                   ((<= #xe0 first #xef)
                                    (values 3 #x800 (logand first #x0f)))
                                   ((<= #xf0 first #xf7)
                                    (values 4 #x10000 (logand first #x07)))
                                   (t (values nil nil nil)))
                           (if (null count)
                               (%write-js-codepoint #xfffd output)
                               (let ((complete-p t))
                                 (loop repeat (1- count)
                                       do (multiple-value-bind (next next-p)
                                              (percent-octet)
                                            (unless (and next-p
                                                         (= (logand next #xc0) #x80))
                                              (setf complete-p nil)
                                              (return))
                                            (setf codepoint
                                                  (logior (ash codepoint 6)
                                                          (logand next #x3f)))
                                            (consume-octets 3)))
                                 (%write-js-codepoint
                                  (if (and complete-p
                                           (>= codepoint minimum)
                                           (<= codepoint #x10ffff)
                                           (not (<= #xd800 codepoint #xdfff)))
                                      codepoint
                                      #xfffd)
                                  output))))))))))))))

(defun forgiving-percent-decode (value &key force)
  "Decode percent octets as forgiving UTF-8; plus remains a literal plus."
  (check-type value string)
  (%forgiving-percent-decode-range value 0 (length value) force))

;;; Cookie wire parsing and serialization

(defun %range-string-equal (source start end target)
  (and (= (- end start) (length target))
       (loop for source-index from start below end
             for target-index from 0
             always (char-equal (char source source-index)
                                (char target target-index)))))

(defun %lowercase-ascii-range (source start end)
  (let ((result (make-string (- end start))))
    (loop for source-index from start below end
          for target-index from 0
          for character = (char source source-index)
          do (setf (char result target-index)
                   (if (char<= #\A character #\Z)
                       (code-char (+ (char-code character) 32))
                       character)))
    result))

(defun %cookie-path-range-valid-p (source start end)
  (loop for index from start below end
        for code = (char-code (char source index))
        always (or (<= #x20 code #x3a)
                   (<= #x3d code #x7e))))

(defun %cookie-floor-log10 (rational)
  (let ((estimate (floor (log (coerce rational 'double-float) 10d0))))
    (loop while (>= rational (expt 10 (1+ estimate))) do (incf estimate))
    (loop while (< rational (expt 10 estimate)) do (decf estimate))
    estimate))

(defun %cookie-shortest-double (number)
  "Return shortest round-trip decimal digits, their length, and decimal position."
  (multiple-value-bind (significand exponent sign) (integer-decode-float number)
    (declare (ignore sign))
    (let* ((boundary-p (and (= significand (expt 2 52)) (/= exponent -1074)))
           (even-p (evenp significand))
           (half (expt 2 (1- exponent)))
           (high (* (+ (* 2 significand) 1) half))
           (low (if boundary-p
                    (* (- (* 4 significand) 1) (expt 2 (- exponent 2)))
                    (* (- (* 2 significand) 1) half)))
           (exact (* significand (expt 2 exponent)))
           (power (+ 2 (%cookie-floor-log10 exact))))
      (loop
        (let* ((scale (expt 10 power))
               (minimum (let ((candidate (ceiling low scale)))
                          (if (and (not even-p) (= (* candidate scale) low))
                              (1+ candidate) candidate)))
               (maximum (let ((candidate (floor high scale)))
                          (if (and (not even-p) (= (* candidate scale) high))
                              (1- candidate) candidate))))
          (when (<= minimum maximum)
            (let ((digits (min (max (round (/ exact scale)) minimum) maximum)))
              (loop while (and (plusp digits) (zerop (mod digits 10)))
                    do (setf digits (truncate digits 10)) (incf power))
              (let* ((text (write-to-string digits))
                     (length (length text)))
                (return-from %cookie-shortest-double
                  (values text length (+ length power)))))))
        (decf power)))))

(defun %cookie-format-shortest-double (digits length decimal-position)
  (cond
    ((<= length decimal-position 21)
     (concatenate 'string digits
                  (make-string (- decimal-position length) :initial-element #\0)))
    ((< 0 decimal-position 22)
     (concatenate 'string (subseq digits 0 decimal-position) "."
                  (subseq digits decimal-position)))
    ((< -6 decimal-position 1)
     (concatenate 'string "0."
                  (make-string (- decimal-position) :initial-element #\0) digits))
    (t
     (let ((mantissa (if (= length 1) digits
                         (concatenate 'string (subseq digits 0 1) "."
                                      (subseq digits 1))))
           (exponent (1- decimal-position)))
       (format nil "~ae~a~d" mantissa (if (>= exponent 0) "+" "-")
               (abs exponent))))))

(defun %cookie-double-text (number)
  (cond ((zerop number) "0")
        ((minusp number) (concatenate 'string "-" (%cookie-double-text (- number))))
        ((<= number 9007199254740992d0)
         (let ((integer (floor number)))
           (if (= number integer)
               (write-to-string integer)
               (multiple-value-bind (digits length position)
                   (%cookie-shortest-double number)
                 (%cookie-format-shortest-double digits length position)))))
        (t
         (multiple-value-bind (digits length position)
             (%cookie-shortest-double number)
           (%cookie-format-shortest-double digits length position)))))

(defun %parse-signed-integer-prefix-range (string start end)
  (multiple-value-setq (start end) (%ascii-trim-bounds string start end))
  (let ((index start)
        (negative-p nil))
    (when (< index end)
      (case (char string index)
        (#\+ (incf index))
        (#\- (setf negative-p t) (incf index)))
      (let ((digit-start index))
        (let ((magnitude 0)
              (limit (if negative-p 9223372036854775808 9223372036854775807)))
          (loop while (and (< index end)
                           (%ascii-digit-p (char string index)))
                for digit = (- (char-code (char string index)) (char-code #\0))
                do (when (> magnitude (floor (- limit digit) 10))
                     (return-from %parse-signed-integer-prefix-range
                       (values nil nil nil)))
                   (setf magnitude (+ (* magnitude 10) digit))
                   (incf index))
          (when (> index digit-start)
            (let ((number (coerce (if negative-p (- magnitude) magnitude)
                                  'double-float)))
              (values number (%cookie-double-text number) t))))))))

(defun %parse-signed-integer-prefix (string)
  (%parse-signed-integer-prefix-range string 0 (length string)))

(defun parse-set-cookie (value)
  (validate-cookie-field-value value)
  (when (zerop (length value))
    (validate-cookie-name ""))
  (let* ((semicolon (position #\; value))
         (pair-end (or semicolon (length value)))
         (equals (position #\= value :end pair-end)))
    (unless equals
      (%cookie-error 'invalid-cookie-string
                     (if (if semicolon
                             (zerop pair-end)
                             (<= pair-end 1))
                         "Invalid cookie string: empty"
                         "Invalid cookie string: no '=' found")))
    (when (zerop equals)
      (%cookie-error 'invalid-cookie-string
                     (if (= (length value) 1)
                         "Invalid cookie string: empty"
                         "Invalid cookie string: name cannot be empty")))
    (multiple-value-bind (name-start name-end)
        (%ascii-trim-bounds value 0 equals)
      (multiple-value-bind (cookie-value-start cookie-value-end)
          (%ascii-trim-bounds value (1+ equals) pair-end)
        (let* ((name (subseq value name-start name-end))
               (cookie-value (subseq value cookie-value-start cookie-value-end))
               (cookie (progn
                         (validate-cookie-name name)
                         (%make-cookie :name name :value cookie-value
                                       :path "/" :same-site :lax)))
              (domain-start nil)
              (domain-end nil)
              (path-start nil)
              (path-end nil))
          (when semicolon
            (let ((index (1+ semicolon))
                  (end (length value)))
              (loop
                (let ((attribute-end (or (position #\; value :start index) end)))
                  (multiple-value-bind (attribute-start trimmed-end)
                      (%ascii-trim-bounds value index attribute-end)
                    (let ((separator (position #\= value :start attribute-start
                                                    :end trimmed-end)))
                      (multiple-value-bind (name-start name-end)
                          (%ascii-trim-bounds value attribute-start
                                              (or separator trimmed-end))
                        (multiple-value-bind (attribute-value-start
                                              attribute-value-end)
                            (if separator
                                (%ascii-trim-bounds value (1+ separator) trimmed-end)
                                (values nil nil))
                          (cond
                            ((%range-string-equal value name-start name-end "domain")
                             (when (and separator
                                        (< attribute-value-start attribute-value-end))
                               (setf domain-start attribute-value-start
                                     domain-end attribute-value-end)))
                            ((%range-string-equal value name-start name-end "path")
                             (when (and separator
                                        (< attribute-value-start attribute-value-end)
                                        (char= (char value attribute-value-start) #\/)
                                        (%cookie-path-range-valid-p
                                         value attribute-value-start
                                         attribute-value-end))
                               (setf path-start attribute-value-start
                                     path-end attribute-value-end)))
                            ((%range-string-equal value name-start name-end "expires")
                             (when separator
                               (multiple-value-bind (milliseconds valid-p)
                                   (%parse-http-date-range
                                    value attribute-value-start attribute-value-end)
                                 (when valid-p
                                   (update-cookie-expires cookie milliseconds)))))
                            ((%range-string-equal value name-start name-end "max-age")
                             (when separator
                               (multiple-value-bind (number text valid-p)
                                   (%parse-signed-integer-prefix-range
                                    value attribute-value-start attribute-value-end)
                                 (when valid-p
                                   (update-cookie-max-age cookie number text)))))
                            ((%range-string-equal value name-start name-end "secure")
                             (update-cookie-secure cookie t))
                            ((%range-string-equal value name-start name-end "httponly")
                             (update-cookie-http-only cookie t))
                            ((%range-string-equal value name-start name-end "partitioned")
                             (update-cookie-partitioned cookie t))
                            ((%range-string-equal value name-start name-end "samesite")
                             (when separator
                               (cond
                                 ((%range-string-equal value attribute-value-start
                                                       attribute-value-end "strict")
                                  (update-cookie-same-site cookie :strict))
                                 ((%range-string-equal value attribute-value-start
                                                       attribute-value-end "lax")
                                  (update-cookie-same-site cookie :lax))
                                 ((%range-string-equal value attribute-value-start
                                                       attribute-value-end "none")
                                  (update-cookie-same-site cookie :none))))))))))
                  (when (= attribute-end end) (return))
                  (setf index (1+ attribute-end))))))
          (when domain-start
            (let ((domain (%lowercase-ascii-range value domain-start domain-end)))
              (validate-cookie-domain domain)
              (setf (cookie-domain cookie) domain
                    (cookie-domain-present-p cookie) t)))
          (when path-start
            (setf (cookie-path cookie) (subseq value path-start path-end)))
          cookie)))))

(defun %same-site-text (same-site)
  (ecase same-site (:strict "Strict") (:lax "Lax") (:none "None")))

(defun serialize-cookie (cookie)
  (check-type cookie cookie)
  ;; Revalidate output-bearing fields so even internal callers cannot turn a
  ;; mutated CL record into response splitting.
  (validate-cookie-name (cookie-name cookie))
  (validate-cookie-path (cookie-path cookie))
  (when (cookie-domain-present-p cookie)
    (validate-cookie-domain (cookie-domain cookie)))
  (when (and (cookie-max-age-present-p cookie)
             (not (%max-age-text-p (cookie-max-age-text cookie))))
    (%cookie-error 'cookie-error "Invalid Max-Age serialization"))
  (%encoded-value-length (cookie-value cookie))
  (with-output-to-string (output)
    (labels ((attribute (name value)
               (write-string "; " output)
               (write-string name output)
               (when value
                 (write-char #\= output)
                 (write-string value output))))
      (write-string (cookie-name cookie) output)
      (write-char #\= output)
      (%write-percent-encoded-value (cookie-value cookie) output)
      (when (and (cookie-domain-present-p cookie)
                 (plusp (length (cookie-domain cookie))))
        (attribute "Domain" (cookie-domain cookie)))
      (when (plusp (length (cookie-path cookie)))
        (attribute "Path" (cookie-path cookie)))
      (when (cookie-expires-present-p cookie)
        (attribute "Expires" (format-http-date (cookie-expires-ms cookie))))
      (when (cookie-max-age-present-p cookie)
        (attribute "Max-Age" (cookie-max-age-text cookie)))
      (when (cookie-secure-p cookie) (attribute "Secure" nil))
      (when (cookie-http-only-p cookie) (attribute "HttpOnly" nil))
      (when (cookie-partitioned-p cookie) (attribute "Partitioned" nil))
      (attribute "SameSite" (%same-site-text (cookie-same-site cookie))))))

(defun %scan-cookie-header (value percent-mode-p consumer)
  "Call CONSUMER for each retained pair without allocating token substrings."
  (check-type value string)
  (let ((index 0)
        (end (length value)))
    (loop
      (let* ((segment-end (or (position #\; value :start index) end))
             (equals (position #\= value :start index :end segment-end)))
        (when equals
          (multiple-value-bind (name-start name-end)
              (%ascii-trim-bounds value index equals)
            (when (< name-start name-end)
              (multiple-value-bind (value-start value-end)
                  (%ascii-trim-bounds value (1+ equals) segment-end)
                (funcall consumer
                         (make-cookie-pair
                          (subseq value name-start name-end)
                          (%forgiving-percent-decode-range
                           value value-start value-end percent-mode-p)))))))
        (when (= segment-end end) (return))
        (setf index (1+ segment-end))))))

(defun parse-cookie-header (value)
  "Parse one Cookie field into ordered, duplicate-preserving pairs."
  (let ((pairs '()))
    (%scan-cookie-header value (not (null (find #\% value)))
                         (lambda (pair) (push pair pairs)))
    (nreverse pairs)))

(defun parse-cookie-header-fields (values)
  "Parse duplicate Cookie fields without comma-merging or losing order."
  (let ((pairs '())
        (percent-mode-p
          (not (null (find-if (lambda (value) (find #\% value)) values)))))
    (map nil (lambda (value)
               (%scan-cookie-header value percent-mode-p
                                    (lambda (pair) (push pair pairs))))
         values)
    (nreverse pairs)))

;;; Ordered CookieMap state

(defun %cookie-header-layout (value)
  "Return the segment capacity and whether VALUE contains a percent escape."
  (check-type value string)
  (let ((capacity (if (plusp (length value)) 1 0))
        (percent-mode-p nil))
    (dotimes (index (length value))
      (case (char value index)
        (#\; (incf capacity))
        (#\% (setf percent-mode-p t))))
    (values capacity percent-mode-p)))

(defun %make-cookie-map-state-with-capacity (original-capacity)
  (check-type original-capacity (integer 0 *))
  (%make-cookie-map-state
   (make-array (max 4 original-capacity) :adjustable t :fill-pointer 0)
   (make-array 4 :adjustable t :fill-pointer 0)))

(defun make-cookie-map-state (&optional (pairs '()))
  (let* ((state (%make-cookie-map-state-with-capacity (length pairs)))
         (originals (cookie-map-state-originals state)))
    (map nil (lambda (pair)
               (check-type pair cookie-pair)
               (vector-push-extend
                (make-cookie-pair (%copy-string (cookie-pair-name pair))
                                  (%copy-string (cookie-pair-value pair)))
                originals))
         pairs)
    state))

(defun %cookie-map-check (state)
  (check-type state cookie-map-state)
  state)

(defun %cookie-map-push-original-pair (state pair)
  (%cookie-map-check state)
  (check-type pair cookie-pair)
  (vector-push-extend pair (cookie-map-state-originals state))
  state)

(defun cookie-map-add-original (state name value)
  "Append one original request-cookie entry without building an intermediate list."
  (%cookie-map-check state)
  (check-type name string)
  (check-type value string)
  (%cookie-map-push-original-pair
   state
   (make-cookie-pair (%copy-string name) (%copy-string value))))

(defun make-cookie-map-state-from-header (value)
  "Parse one Cookie header directly into map state without a proportional pair list."
  (multiple-value-bind (original-capacity percent-mode-p)
      (%cookie-header-layout value)
    (let ((state (%make-cookie-map-state-with-capacity original-capacity)))
      (%scan-cookie-header
       value percent-mode-p
       (lambda (pair) (%cookie-map-push-original-pair state pair)))
      state)))

(defun make-cookie-map-state-from-header-fields (values)
  "Parse ordered duplicate Cookie fields directly with one global percent prepass."
  (check-type values list)
  (let ((original-capacity 0)
        (percent-mode-p nil))
    (dolist (value values)
      (multiple-value-bind (field-capacity field-percent-mode-p)
          (%cookie-header-layout value)
        (incf original-capacity field-capacity)
        (when field-percent-mode-p
          (setf percent-mode-p t))))
    (let ((state (%make-cookie-map-state-with-capacity original-capacity)))
      (dolist (value values state)
        (%scan-cookie-header
         value percent-mode-p
         (lambda (pair) (%cookie-map-push-original-pair state pair)))))))

(defun %cookie-map-visible-modification-p (cookie)
  (plusp (length (cookie-value cookie))))

(defun cookie-map-entry-at (state index)
  "Return (values name value found-p) for the current live effective view."
  (%cookie-map-check state)
  (check-type index (integer 0 *))
  (let ((visible-index 0)
        (modifications (cookie-map-state-modifications state))
        (originals (cookie-map-state-originals state)))
    (dotimes (position (fill-pointer modifications))
      (let ((cookie (aref modifications position)))
        (when (%cookie-map-visible-modification-p cookie)
          (when (= visible-index index)
            (return-from cookie-map-entry-at
              (values (cookie-name cookie) (cookie-value cookie) t)))
          (incf visible-index))))
    (dotimes (position (fill-pointer originals))
      (let ((pair (aref originals position)))
        (when pair
          (when (= visible-index index)
            (return-from cookie-map-entry-at
              (values (cookie-pair-name pair) (cookie-pair-value pair) t)))
          (incf visible-index))))
    (values nil nil nil)))

(defun cookie-map-size (state)
  (%cookie-map-check state)
  (let ((count 0))
    (dotimes (position (fill-pointer (cookie-map-state-modifications state)))
      (when (%cookie-map-visible-modification-p
             (aref (cookie-map-state-modifications state) position))
        (incf count)))
    (dotimes (position (fill-pointer (cookie-map-state-originals state)))
      (when (aref (cookie-map-state-originals state) position)
        (incf count)))
    count))

(defun cookie-map-get (state name)
  "Return (values first-effective-value found-p)."
  (%cookie-map-check state)
  (check-type name string)
  (let ((modifications (cookie-map-state-modifications state))
        (originals (cookie-map-state-originals state)))
    (dotimes (position (fill-pointer modifications))
      (let ((cookie (aref modifications position)))
        (when (and (%cookie-map-visible-modification-p cookie)
                   (string= name (cookie-name cookie)))
          (return-from cookie-map-get (values (cookie-value cookie) t)))))
    (dotimes (position (fill-pointer originals))
      (let ((pair (aref originals position)))
        (when (and pair (string= name (cookie-pair-name pair)))
          (return-from cookie-map-get (values (cookie-pair-value pair) t))))))
  (values nil nil))

(defun cookie-map-has (state name)
  (nth-value 1 (cookie-map-get state name)))

(defun %cookie-map-remove-originals (state name)
  (let ((originals (cookie-map-state-originals state)))
    (dotimes (position (fill-pointer originals))
      (let ((pair (aref originals position)))
        (when (and pair (string= name (cookie-pair-name pair)))
          (setf (aref originals position) nil))))))

(defun %cookie-map-remove-modification (state name)
  (let* ((modifications (cookie-map-state-modifications state))
         (write-index 0))
    (dotimes (read-index (fill-pointer modifications))
      (let ((cookie (aref modifications read-index)))
        (unless (string= name (cookie-name cookie))
          (setf (aref modifications write-index) cookie)
          (incf write-index))))
    (loop for index from write-index below (fill-pointer modifications)
          do (setf (aref modifications index) nil))
    (setf (fill-pointer modifications) write-index)))

(defun cookie-map-set-cookie (state cookie)
  "Retain COOKIE by reference, replacing every effective entry with its name."
  (%cookie-map-check state)
  (check-type cookie cookie)
  (let ((name (cookie-name cookie)))
    (%cookie-map-remove-originals state name)
    (%cookie-map-remove-modification state name)
    (vector-push-extend cookie (cookie-map-state-modifications state)))
  state)

(defun cookie-map-delete (state name &key domain (path "/"))
  (%cookie-map-check state)
  (cookie-map-set-cookie state
                         (make-cookie-tombstone name :domain domain :path path)))

(defun cookie-map-modification-count (state)
  (%cookie-map-check state)
  (fill-pointer (cookie-map-state-modifications state)))

(defun cookie-map-response-fields (state)
  "Return a fresh list containing only ordered, coalesced mutation fields."
  (%cookie-map-check state)
  (let ((fields '())
        (modifications (cookie-map-state-modifications state)))
    (dotimes (position (fill-pointer modifications))
      (push (serialize-cookie (aref modifications position)) fields))
    (nreverse fields)))
