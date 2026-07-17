;;;; cookies-tests.lisp -- Phase 32 engine-independent cookie core coverage.

(in-package :clun-test)

(defun cookie-pairs-as-lists (pairs)
  (mapcar (lambda (pair)
            (list (cookies:cookie-pair-name pair)
                  (cookies:cookie-pair-value pair)))
          pairs))

(defun cookie-error-text (thunk)
  (handler-case (progn (funcall thunk) nil)
    (cookies:cookie-error (condition)
      (cookies:cookie-error-message condition))))

(defun cookie-codepoints (string)
  (map 'list #'char-code string))

(defun cookie-codepoint-units (codepoint)
  (if (<= codepoint #xffff)
      (list codepoint)
      (let ((value (- codepoint #x10000)))
        (list (+ #xd800 (ash value -10))
              (+ #xdc00 (logand value #x3ff))))))

(defun cookie-string-from-codepoints (&rest codepoints)
  (map 'string #'code-char codepoints))

(defun cookie-double-from-bits (high low)
  (sb-kernel:make-double-float
   (if (>= high #x80000000) (- high #x100000000) high)
   low))

(defun cookie-call-succeeds-p (thunk)
  (handler-case (progn (funcall thunk) t)
    (cookies:cookie-error () nil)))

(defun cookie-map-resource-header (count)
  (with-output-to-string (output)
    (dotimes (index count)
      (when (plusp index) (write-string "; " output))
      (format output "k~d=v~d" index index))))

(defun cookie-map-measured-bytes (thunk &key (iterations 8))
  (sb-ext:gc :full t)
  (let ((before (sys:bytes-consed))
        (result nil))
    ;; Aggregate several constructions so allocator-region granularity cannot
    ;; dominate one sample on arm64 SBCL builds.
    (loop repeat iterations
          do (setf result (funcall thunk)))
    (values (floor (- (sys:bytes-consed) before) iterations) result)))

(defun cookie-map-median-parse-nanoseconds (header &key (samples 7) (iterations 16))
  (let ((measurements '()))
    (loop repeat samples
          do (let ((start (sys:monotonic-nanoseconds)))
               (loop repeat iterations
                     do (cookies:make-cookie-map-state-from-header header))
               (push (- (sys:monotonic-nanoseconds) start) measurements)))
    (nth (floor samples 2) (sort measurements #'<))))

(define-test cookie-core)

(define-test cookie-core-validator-boundaries
  :parent cookie-core
  (is string= "!" (cookies:validate-cookie-name "!"))
  (is string= "<" (cookies:validate-cookie-name "<"))
  (is string= "~" (cookies:validate-cookie-name "~"))
  (fail (cookies:validate-cookie-name "") cookies:invalid-cookie-name)
  (fail (cookies:validate-cookie-name "has space") cookies:invalid-cookie-name)
  (fail (cookies:validate-cookie-name "a;b") cookies:invalid-cookie-name)
  (fail (cookies:validate-cookie-name "a=b") cookies:invalid-cookie-name)
  (fail (cookies:validate-cookie-name (string (code-char #x80)))
        cookies:invalid-cookie-name)
  (is string= "" (cookies:validate-cookie-path ""))
  (is string= " /:=~" (cookies:validate-cookie-path " /:=~"))
  (fail (cookies:validate-cookie-path "/semi;colon") cookies:invalid-cookie-path)
  (fail (cookies:validate-cookie-path "/less<than") cookies:invalid-cookie-path)
  (fail (cookies:validate-cookie-path (format nil "/x~cy" #\Newline))
        cookies:invalid-cookie-path)
  (is string= "sub.example-2.com"
      (cookies:validate-cookie-domain "sub.example-2.com"))
  (is string= "" (cookies:validate-cookie-domain ""))
  (fail (cookies:validate-cookie-domain "Example.com") cookies:invalid-cookie-domain)
  (fail (cookies:validate-cookie-domain "bad_domain") cookies:invalid-cookie-domain)
  (is string= "a=b" (cookies:validate-cookie-field-value "a=b"))
  (fail (cookies:validate-cookie-field-value " a=b") cookies:invalid-cookie-string)
  (fail (cookies:validate-cookie-field-value "a=b ") cookies:invalid-cookie-string)
  (fail (cookies:validate-cookie-field-value (format nil "a=b~cInjected: yes" #\Return))
        cookies:invalid-cookie-string)
  (fail (cookies:validate-cookie-field-value
         (concatenate 'string "a=" (string (code-char #x100))))
        cookies:invalid-cookie-string))

(define-test cookie-core-validator-exhaustive-bytes
  :parent cookie-core
  (loop for code from 0 to #xff
        for character = (code-char code)
        for expected-name = (or (<= #x21 code #x3a)
                                (= code #x3c)
                                (<= #x3e code #x7e))
        for expected-path = (or (<= #x20 code #x3a)
                                (<= #x3d code #x7e))
        for expected-field = (or (= code #x09)
                                 (<= #x20 code #x7e)
                                 (<= #x80 code #xff))
        do (is eql expected-name
               (cookie-call-succeeds-p
                (lambda () (cookies:validate-cookie-name (string character))))
               (format nil "name byte ~2,'0x" code))
           (is eql expected-path
               (cookie-call-succeeds-p
                (lambda () (cookies:validate-cookie-path (string character))))
               (format nil "path byte ~2,'0x" code))
           (is eql expected-field
               (cookie-call-succeeds-p
                (lambda ()
                  (cookies:validate-cookie-field-value
                   (concatenate 'string "x" (string character) "y"))))
               (format nil "field byte ~2,'0x" code)))
  (false (cookie-call-succeeds-p
          (lambda () (cookies:validate-cookie-name ""))))
  (true (cookie-call-succeeds-p
         (lambda () (cookies:validate-cookie-path ""))))
  (true (cookie-call-succeeds-p
         (lambda () (cookies:validate-cookie-field-value ""))))
  (dolist (edge (list " value" "value "
                      (format nil "~cvalue" #\Tab)
                      (format nil "value~c" #\Tab)
                      (string (code-char #x100))))
    (false (cookie-call-succeeds-p
            (lambda () (cookies:validate-cookie-field-value edge))))))

(define-test cookie-core-state-and-expiry
  :parent cookie-core
  (let ((cookie (cookies:make-cookie "sid" "one")))
    (is string= "sid" (cookies:cookie-name cookie))
    (is string= "one" (cookies:cookie-value cookie))
    (false (cookies:cookie-domain-present-p cookie))
    (is string= "/" (cookies:cookie-path cookie))
    (false (cookies:cookie-expires-present-p cookie))
    (false (cookies:cookie-max-age-present-p cookie))
    (false (cookies:cookie-secure-p cookie))
    (false (cookies:cookie-http-only-p cookie))
    (is eq :lax (cookies:cookie-same-site cookie))
    (false (cookies:cookie-partitioned-p cookie))
    (false (cookies:cookie-expired-p cookie 0))
    (cookies:update-cookie-domain cookie "example.com")
    (cookies:update-cookie-path cookie "/account")
    (cookies:update-cookie-expires cookie 1000)
    (cookies:update-cookie-secure cookie t)
    (cookies:update-cookie-http-only cookie t)
    (cookies:update-cookie-same-site cookie "NONE")
    (cookies:update-cookie-partitioned cookie t)
    (is string= "example.com" (cookies:cookie-domain cookie))
    (true (cookies:cookie-domain-present-p cookie))
    (false (cookies:cookie-expired-p cookie 999))
    (false (cookies:cookie-expired-p cookie 1000)
           "Expires equality is not expired")
    (true (cookies:cookie-expired-p cookie 1001))
    (cookies:update-cookie-max-age cookie 10)
    (false (cookies:cookie-expired-p cookie 2000)
           "positive Max-Age overrides past Expires")
    (cookies:update-cookie-max-age cookie 0)
    (true (cookies:cookie-expired-p cookie 0))
    (cookies:update-cookie-max-age cookie :positive-infinity)
    (false (cookies:cookie-expired-p cookie most-positive-fixnum))
    (cookies:clear-cookie-max-age cookie)
    (cookies:clear-cookie-expires cookie)
    (cookies:clear-cookie-domain cookie)
    (false (cookies:cookie-domain-present-p cookie))
    (false (cookies:cookie-expired-p cookie most-positive-fixnum))
    (let ((copy (cookies:clone-cookie cookie)))
      (cookies:update-cookie-value copy "two")
      (is string= "one" (cookies:cookie-value cookie))
      (is string= "two" (cookies:cookie-value copy)))))

(define-test cookie-core-canonical-max-age
  :parent cookie-core
  (dolist (case '((1d-7 "1e-7")
                  (1d-6 "0.000001")
                  (1d20 "100000000000000000000")
                  (1d21 "1e+21")))
    (let ((cookie (cookies:make-cookie "n" "v" :max-age (first case)
                                      :max-age-text "000.000")))
      (is string= (second case) (cookies:cookie-max-age-text cookie))
      (true (search (concatenate 'string "Max-Age=" (second case))
                    (cookies:serialize-cookie cookie)))))
  (let ((cookie (cookies:make-cookie "n" "v")))
    (cookies:update-cookie-max-age cookie 1d-7 "not-canonical")
    (is string= "1e-7" (cookies:cookie-max-age-text cookie)))
  (let* ((nan (cookie-double-from-bits #x7ff80000 0))
         (positive-infinity (cookie-double-from-bits #x7ff00000 0))
         (negative-infinity (cookie-double-from-bits #xfff00000 0))
         (cookie (cookies:make-cookie "n" "v" :max-age nan)))
    (false (cookies:cookie-max-age-present-p cookie))
    (cookies:update-cookie-max-age cookie 1)
    (cookies:update-cookie-max-age cookie nan)
    (false (cookies:cookie-max-age-present-p cookie))
    (cookies:update-cookie-max-age cookie positive-infinity)
    (is string= "Infinity" (cookies:cookie-max-age-text cookie))
    (cookies:update-cookie-max-age cookie negative-infinity)
    (is string= "-Infinity" (cookies:cookie-max-age-text cookie))
    (fail (cookies:update-cookie-expires cookie nan) cookies:cookie-error)
    (fail (cookies:update-cookie-expires cookie positive-infinity)
          cookies:cookie-error)
    (fail (cookies:update-cookie-expires cookie negative-infinity)
          cookies:cookie-error)))

(define-test cookie-core-http-dates
  :parent cookie-core
  (dolist (input '("Sun, 06 Nov 1994 08:49:37 GMT"
                   "Sunday, 06-Nov-94 08:49:37 GMT"
                   "Sun Nov  6 08:49:37 1994"))
    (multiple-value-bind (milliseconds valid-p) (cookies:parse-http-date input)
      (true valid-p input)
      (is = 784111777000 milliseconds input)))
  (is string= "Thu, 01 Jan 1970 00:00:00 GMT"
      (cookies:format-http-date 0))
  (is string= "Wed, 31 Dec 1969 23:59:59 GMT"
      (cookies:format-http-date -1))
  (multiple-value-bind (milliseconds valid-p)
      (cookies:parse-http-date "Tue, 29 Feb 2000 12:34:56 GMT")
    (true valid-p)
    (is string= "Tue, 29 Feb 2000 12:34:56 GMT"
        (cookies:format-http-date milliseconds)))
  (multiple-value-bind (milliseconds valid-p)
      (cookies:parse-http-date "Sun, 6 Nov 94 08:49:37 EST")
    (true valid-p)
    (is = 784129777000 milliseconds))
  (multiple-value-bind (milliseconds valid-p)
      (cookies:parse-http-date "Nov 6 1994 08:49:37 PST")
    (true valid-p)
    (is = 784140577000 milliseconds))
  (multiple-value-bind (milliseconds valid-p)
      (cookies:parse-http-date "11/06/1994 08:49:37 +05:30")
    (true valid-p)
    (is = 784091977000 milliseconds))
  (dolist (case '(("GMT" 0) ("UTC" 0) ("UT" 0) ("Z" 0)
                  ("EST" -18000) ("EDT" -14400)
                  ("CST" -21600) ("CDT" -18000)
                  ("MST" -25200) ("MDT" -21600)
                  ("PST" -28800) ("PDT" -25200)))
    (multiple-value-bind (milliseconds valid-p)
        (cookies:parse-http-date
         (format nil "6 Nov 1994 08:49:37 ~a" (first case)))
      (true valid-p (first case))
      (is = (- 784111777000 (* 1000 (second case))) milliseconds
          (first case))))
  (dolist (case '(("6 Nov 49 08:49:37 GMT" "2049")
                  ("6 Nov 50 08:49:37 GMT" "1950")))
    (multiple-value-bind (milliseconds valid-p)
        (cookies:parse-http-date (first case))
      (true valid-p)
      (true (search (second case) (cookies:format-http-date milliseconds)))))
  (dolist (zone '("+2359" "-2359" "+23:59" "-23:59"))
    (multiple-value-bind (milliseconds valid-p)
        (cookies:parse-http-date (format nil "6 Nov 1994 08:49:37 ~a" zone))
      (declare (ignore milliseconds))
      (true valid-p zone)))
  (dolist (input (list "sUn, 6-nOv 94 08:49:37 utc"
                       "6 Nov-94 08:49:37 UT"
                       (format nil "Sun~cNov~c6~c1994~c08:49:37~cZ"
                               #\Tab #\Tab #\Tab #\Tab #\Tab)))
    (multiple-value-bind (milliseconds valid-p) (cookies:parse-http-date input)
      (true valid-p input)
      (is = 784111777000 milliseconds input)))
  (multiple-value-bind (milliseconds valid-p)
      (cookies:parse-http-date "13 Sep 275760 00:00:00 GMT")
    (true valid-p)
    (is = 8640000000000000 milliseconds))
  (multiple-value-bind (milliseconds valid-p)
      (cookies:parse-http-date "20 Apr -271821 00:00:00 GMT")
    (true valid-p)
    (is = -8640000000000000 milliseconds))
  (is string= "Sat, 13 Sep 275760 00:00:00 GMT"
      (cookies:format-http-date 8640000000000000))
  (is string= "Tue, 20 Apr -271821 00:00:00 GMT"
      (cookies:format-http-date -8640000000000000))
  (multiple-value-bind (milliseconds valid-p)
      (cookies:parse-http-date "1 Jan 10000 00:00:00 GMT")
    (true valid-p)
    (is string= "Sat, 01 Jan 10000 00:00:00 GMT"
        (cookies:format-http-date milliseconds)))
  (multiple-value-bind (milliseconds valid-p)
      (cookies:parse-http-date "1 Jan -0001 00:00:00 GMT")
    (true valid-p)
    (is string= "Fri, 01 Jan -0001 00:00:00 GMT"
        (cookies:format-http-date milliseconds)))
  (dolist (input '("Mon, 29 Feb 2100 00:00:00 GMT"
                   "Sun, 00 Nov 1994 08:49:37 GMT"
                   "Sun, 06 Nov 1994 24:00:00 GMT"
                   "Sun, 06 Nov 1994 08:49:60 GMT"
                   "06 Nov 1994 08:49:37"
                   "06 Nov 1994 08:49:37 LOCAL"
                   "06 Nov 123 08:49:37 GMT"
                   "06 Nov +1994 08:49:37 GMT"
                   "06 Nov 1994 08:49:37.1 GMT"
                   "06 Nov 1994 08:49:37 +2400"
                   "06 Nov 1994 08:49:37 +2360"
                   "06 Nov 1994 08:49:37 -24:00"
                   "06 Nov 1994 08:49:37 GMT junk"
                   "14 Sep 275760 00:00:00 GMT"
                   "not a date"))
    (multiple-value-bind (milliseconds valid-p) (cookies:parse-http-date input)
      (declare (ignore milliseconds))
      (false valid-p input))))

(define-test cookie-core-percent-codecs
  :parent cookie-core
  (is string= "AZaz09-_.!~*'()"
      (cookies:percent-encode-value "AZaz09-_.!~*'()"))
  (is string= "%20a%3B%2B%25%2F%3D"
      (cookies:percent-encode-value " a;+%/="))
  (is string= "%E2%82%AC" (cookies:percent-encode-value (string (code-char #x20ac))))
  (is string= "%F0%9F%98%80"
      (cookies:percent-encode-value (string (code-char #x1f600))))
  (is string= "%F0%9F%98%80"
      (cookies:percent-encode-value
       (cookie-string-from-codepoints #xd83d #xde00)))
  (is string= "%EF%BF%BD"
      (cookies:percent-encode-value
       (cookie-string-from-codepoints #xd83d)))
  (is string= "%EF%BF%BD"
      (cookies:percent-encode-value
       (cookie-string-from-codepoints #xde00)))
  (is string= "hello+world" (cookies:forgiving-percent-decode "hello+world"))
  (loop for code from 0 below #x80
        for character = (code-char code)
        for pass-p = (or (<= (char-code #\A) code (char-code #\Z))
                         (<= (char-code #\a) code (char-code #\z))
                         (<= (char-code #\0) code (char-code #\9))
                         (find character "-_.!~*'()" :test #'char=))
        for expected = (if pass-p (string character)
                           (format nil "%~2,'0X" code))
        do (is string= expected
               (cookies:percent-encode-value (string character))
               (format nil "encode ASCII ~2,'0x" code)))
  (loop for octet from 0 to #xff
        for encoded = (format nil "%~2,'0X" octet)
        for expected = (if (< octet #x80) (list octet) '(#xfffd))
        do (is equal expected
               (cookie-codepoints (cookies:forgiving-percent-decode encoded))
               encoded))
  (dolist
      (case
       (list
        (list "%C0%80" '(#xfffd))
        (list "%C1%BF" '(#xfffd))
        (list "%C2" '(#xfffd))
        (list "%C2%7F" '(#xfffd #x7f))
        (list "%C2%80" (cookie-codepoint-units #x80))
        (list "%DF%BF" (cookie-codepoint-units #x7ff))
        (list "%DF%C0" '(#xfffd #xfffd))
        (list "%E0" '(#xfffd))
        (list "%E0%80" '(#xfffd))
        (list "%E0%9F%BF" '(#xfffd))
        (list "%E0%A0%80" (cookie-codepoint-units #x800))
        (list "%E0%BF%BF" (cookie-codepoint-units #xfff))
        (list "%E1%80" '(#xfffd))
        (list "%E1%80%80" (cookie-codepoint-units #x1000))
        (list "%EC%BF%BF" (cookie-codepoint-units #xcfff))
        (list "%ED%9F%BF" (cookie-codepoint-units #xd7ff))
        (list "%ED%A0%80" '(#xfffd))
        (list "%ED%BF%BF" '(#xfffd))
        (list "%EE%80%80" (cookie-codepoint-units #xe000))
        (list "%EF%BF%BF" (cookie-codepoint-units #xffff))
        (list "%E1%7F%80" '(#xfffd #x7f #xfffd))
        (list "%E1%C0%80" '(#xfffd #xfffd))
        (list "%E1%80%7F" '(#xfffd #x7f))
        (list "%E1%80%C0" '(#xfffd #xfffd))
        (list "%F0" '(#xfffd))
        (list "%F0%80" '(#xfffd))
        (list "%F0%80%80" '(#xfffd))
        (list "%F0%8F%BF%BF" '(#xfffd))
        (list "%F0%90%80%80" (cookie-codepoint-units #x10000))
        (list "%F1%80" '(#xfffd))
        (list "%F1%80%80" '(#xfffd))
        (list "%F1%80%80%80" (cookie-codepoint-units #x40000))
        (list "%F3%BF%BF%BF" (cookie-codepoint-units #xfffff))
        (list "%F4%80%80%80" (cookie-codepoint-units #x100000))
        (list "%F4%8F%BF%BF" (cookie-codepoint-units #x10ffff))
        (list "%F4%90%80%80" '(#xfffd))
        (list "%F5%80%80%80" '(#xfffd))
        (list "%F7%BF%BF%BF" '(#xfffd))
        (list "%F1%7F%80%80" '(#xfffd #x7f #xfffd #xfffd))
        (list "%F1%80%7F%80" '(#xfffd #x7f #xfffd))
        (list "%F1%80%80%7F" '(#xfffd #x7f))
        (list "%F1%C0%80%80" '(#xfffd #xfffd #xfffd))
        (list "%F1%80%C0%80" '(#xfffd #xfffd))
        (list "%F1%80%80%C0" '(#xfffd #xfffd))))
    (is equal (second case)
        (cookie-codepoints (cookies:forgiving-percent-decode (first case)))
        (first case)))
  (dolist (case '(("%41" (#x41))
                  ("%20" (#x20))
                  ("+" (#x2b))
                  ("%" (#xfffd))
                  ("%1" (#xfffd #x31))
                  ("%ZZ" (#xfffd))
                  ("%G1" (#xfffd))
                  ("%Z1" (#xfffd))
                  ("%C2%A2" (#xa2))
                  ("%E2%82%AC" (#x20ac))
                  ("%f0%9f%98%80" (#xd83d #xde00))
                  ("%80" (#xfffd))
                  ("%C0%AF" (#xfffd))
                  ("%E0%80%AF" (#xfffd))
                  ("%ED%A0%80" (#xfffd))
                  ("%F4%90%80%80" (#xfffd))
                  ("%F8%80%80%80%80" (#xfffd #xfffd #xfffd #xfffd #xfffd))
                  ("%C2x" (#xfffd #x78))
                  ("%C2%41" (#xfffd #x41))
                  ("%C2%ZZ" (#xfffd #xfffd))
                  ("%E2%82" (#xfffd))
                  ("%E2%82x" (#xfffd #x78))
                  ("%E2%28%A1" (#xfffd #x28 #xfffd))
                  ("%F0%9F%92" (#xfffd))
                  ("%41x%E2%82%AC" (#x41 #x78 #x20ac))))
    (is equal (second case)
        (cookie-codepoints (cookies:forgiving-percent-decode (first case)))
        (first case)))
  (let ((eacute (string (code-char #xe9)))
        (smile (string (code-char #x1f600))))
    (dolist (case (list
                   (list (concatenate 'string "%" eacute) '(#xfffd))
                   (list (concatenate 'string "%" eacute "x") '(#xfffd #x78))
                   (list (concatenate 'string "x%" eacute) '(#x78 #xfffd))
                   (list (concatenate 'string "%" smile) '(#xfffd #x98 #x80))
                   (list (concatenate 'string "%%" eacute) '(#xfffd #xa9))
                   (list (concatenate 'string "%" eacute "%41") '(#xfffd #x41))
                   (list (concatenate 'string smile "%41")
                         '(#xf0 #x9f #x98 #x80 #x41))))
      (is equal (second case)
          (cookie-codepoints (cookies:forgiving-percent-decode (first case))))))
  (dolist (surrogate '(#xd800 #xdbff #xdc00 #xdfff))
    (let ((raw (string (code-char surrogate))))
      (is equal (list surrogate)
          (cookie-codepoints (cookies:forgiving-percent-decode raw)))
      (is equal '(#xef #xbf #xbd #x41)
          (cookie-codepoints
           (cookies:forgiving-percent-decode
            (concatenate 'string raw "%41"))))))
  (is string= (string (code-char #xe9))
      (cookies:forgiving-percent-decode (string (code-char #xe9))))
  (is string= (format nil "~c~c~c" (code-char #xc3) (code-char #xa9)
                     (code-char #xfffd))
      (cookies:forgiving-percent-decode
       (concatenate 'string (string (code-char #xe9)) "%80"))))

(define-test cookie-core-set-cookie-parsing-and-serialization
  :parent cookie-core
  (let ((cookie (cookies:parse-set-cookie
                 "sid=a%20b; Domain=EXAMPLE.COM; Path=/app; Expires=Sun, 06 Nov 1994 08:49:37 GMT; Max-Age=10junk; Secure; HttpOnly; Partitioned; SameSite=Strict")))
    (is string= "sid" (cookies:cookie-name cookie))
    (is string= "a%20b" (cookies:cookie-value cookie)
        "Set-Cookie parsing retains its value literally")
    (is string= "example.com" (cookies:cookie-domain cookie))
    (is string= "/app" (cookies:cookie-path cookie))
    (is = 784111777000 (cookies:cookie-expires-ms cookie))
    (is = 10 (cookies:cookie-max-age cookie))
    (true (cookies:cookie-secure-p cookie))
    (true (cookies:cookie-http-only-p cookie))
    (true (cookies:cookie-partitioned-p cookie))
    (is eq :strict (cookies:cookie-same-site cookie))
    (is string=
        "sid=a%2520b; Domain=example.com; Path=/app; Expires=Sun, 06 Nov 1994 08:49:37 GMT; Max-Age=10; Secure; HttpOnly; Partitioned; SameSite=Strict"
        (cookies:serialize-cookie cookie)))
  (let ((cookie (cookies:parse-set-cookie
                 "x=y; Domain=bad_domain; Domain=last.example; Path=/one; Path=relative; Max-Age=5; Max-Age=x; SameSite=None; SameSite=bogus")))
    (is string= "last.example" (cookies:cookie-domain cookie))
    (is string= "/one" (cookies:cookie-path cookie))
    (is = 5 (cookies:cookie-max-age cookie))
    (is eq :none (cookies:cookie-same-site cookie)))
  (fail (cookies:parse-set-cookie
         "x=y; Domain=first.example; Domain=bad_domain")
        cookies:invalid-cookie-domain)
  (let ((cookie (cookies:make-cookie "empty-domain" "v" :domain "")))
    (true (cookies:cookie-domain-present-p cookie))
    (is string= "" (cookies:cookie-domain cookie))
    (is string= "empty-domain=v; Path=/; SameSite=Lax"
        (cookies:serialize-cookie cookie)))
  (let ((cookie (cookies:parse-set-cookie
                 "max=v; Max-Age=9223372036854775807")))
    (is = 9.223372036854776d18 (cookies:cookie-max-age cookie))
    (is string= "max=v; Path=/; Max-Age=9223372036854776000; SameSite=Lax"
        (cookies:serialize-cookie cookie)))
  (let ((cookie (cookies:parse-set-cookie
                 "max=v; Max-Age=7; Max-Age=9223372036854775808")))
    (is = 7d0 (cookies:cookie-max-age cookie))
    (is string= "7" (cookies:cookie-max-age-text cookie)))
  (dolist (case '(("+0012junk" "12")
                  ("0" "0")
                  ("-0" "0")
                  ("+0" "0")
                  ("12 34" "12")
                  ("1.9" "1")
                  ("9007199254740991" "9007199254740991")
                  ("9007199254740992" "9007199254740992")
                  ("9007199254740993" "9007199254740992")
                  ("9007199254740994" "9007199254740994")
                  ("-9007199254740991" "-9007199254740991")
                  ("-9007199254740992" "-9007199254740992")
                  ("-9007199254740993" "-9007199254740992")
                  ("9223372036854775806" "9223372036854776000")
                  ("9223372036854775807" "9223372036854776000")
                  ("-9223372036854775808" "-9223372036854776000")))
    (let ((cookie (cookies:parse-set-cookie
                   (format nil "max=v; Max-Age=~a; Path=/" (first case)))))
      (is string= (second case) (cookies:cookie-max-age-text cookie)
          (first case))))
  (let ((cookie (cookies:parse-set-cookie
                 "max=v; Max-Age=7; Max-Age=+; Max-Age=-; Max-Age=; Max-Age=x1; Max-Age=-9223372036854775809")))
    (is string= "7" (cookies:cookie-max-age-text cookie)))
  (let ((cookie (cookies:make-cookie "fraction" "a b" :path ""
                                     :max-age 1.5d0 :max-age-text "1.5"
                                     :same-site :none)))
    (is string= "fraction=a%20b; Max-Age=1.5; SameSite=None"
        (cookies:serialize-cookie cookie)))
  (is string= "Invalid cookie name: contains invalid characters"
      (cookie-error-text (lambda () (cookies:parse-set-cookie ""))))
  (is string= "Invalid cookie string: empty"
      (cookie-error-text (lambda () (cookies:parse-set-cookie "a"))))
  (is string= "Invalid cookie string: no '=' found"
      (cookie-error-text (lambda () (cookies:parse-set-cookie "missing-equals"))))
  (is string= "Invalid cookie string: no '=' found"
      (cookie-error-text (lambda () (cookies:parse-set-cookie "missing; Path=/"))))
  (is string= "Invalid cookie string: empty"
      (cookie-error-text (lambda () (cookies:parse-set-cookie ";"))))
  (is string= "Invalid cookie string: name cannot be empty"
      (cookie-error-text (lambda () (cookies:parse-set-cookie "=value"))))
  (is string= "cookie string is not a valid HTTP header value"
      (cookie-error-text (lambda () (cookies:parse-set-cookie " a=b"))))
  (fail (cookies:parse-set-cookie (format nil "x=y~cInjected: yes" #\Newline))
        cookies:invalid-cookie-string))

(define-test cookie-core-request-header-order-and-malformed-values
  :parent cookie-core
  (is equal
      `(("a" "1")
        ("b" ,(string (code-char #x20ac)))
        ("a" "2")
        ("empty" "")
        ("%5F%5FHost-name" "literal+plus"))
      (cookie-pairs-as-lists
       (cookies:parse-cookie-header
        "a=1; b=%E2%82%AC; ignored; =skip; a=2; empty=; %5F%5FHost-name=literal+plus")))
  (is equal '(("a" "1") ("b" "2") ("a" "3"))
      (cookie-pairs-as-lists
       (cookies:parse-cookie-header-fields '("a=1; b=2" "a=3"))))
  (is equal `(("bad" ,(string (code-char #xfffd))))
      (cookie-pairs-as-lists (cookies:parse-cookie-header "bad=%ZZ")))
  (is equal `(("raw" ,(string (code-char #xe9))))
      (cookie-pairs-as-lists
       (cookies:parse-cookie-header
        (concatenate 'string "raw=" (string (code-char #xe9))))))
  (is equal `(("raw" ,(format nil "~c~c" (code-char #xc3) (code-char #xa9)))
              ("encoded" "A"))
      (cookie-pairs-as-lists
       (cookies:parse-cookie-header
        (concatenate 'string "raw=" (string (code-char #xe9)) "; encoded=%41"))))
  (is equal `(("raw" ,(format nil "~c~c" (code-char #xc3) (code-char #xa9)))
              ("encoded" "A"))
      (cookie-pairs-as-lists
       (cookies:parse-cookie-header-fields
        (list (concatenate 'string "raw=" (string (code-char #xe9)))
              "encoded=%41")))))

(define-test cookie-core-tombstones
  :parent cookie-core
  (let ((plain (cookies:make-cookie-tombstone "sid" :path ""))
        (secure (cookies:make-cookie-tombstone "__HOST-session"
                                               :domain "example.com")))
    (is string= "sid=; Expires=Thu, 01 Jan 1970 00:00:00 GMT; SameSite=Lax"
        (cookies:serialize-cookie plain))
    (is string=
        "__HOST-session=; Domain=example.com; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure; SameSite=Lax"
        (cookies:serialize-cookie secure))))

(define-test cookie-core-map-state
  :parent cookie-core
  (let* ((pairs (list (cookies:make-cookie-pair "a" "1")
                      (cookies:make-cookie-pair "a" "2")
                      (cookies:make-cookie-pair "empty" "")))
         (state (cookies:make-cookie-map-state pairs)))
    (is = 3 (cookies:cookie-map-size state))
    (multiple-value-bind (value found-p) (cookies:cookie-map-get state "a")
      (true found-p)
      (is string= "1" value))
    (true (cookies:cookie-map-has state "empty"))
    (multiple-value-bind (name value found-p) (cookies:cookie-map-entry-at state 1)
      (true found-p)
      (is string= "a" name)
      (is string= "2" value))
    (let ((cookie-c (cookies:make-cookie "c" "3")))
      (cookies:cookie-map-set-cookie state cookie-c)
      (multiple-value-bind (name value found-p) (cookies:cookie-map-entry-at state 0)
        (true found-p)
        (is string= "c" name)
        (is string= "3" value))
      (cookies:update-cookie-value cookie-c "changed")
      (multiple-value-bind (value found-p) (cookies:cookie-map-get state "c")
        (true found-p)
        (is string= "changed" value)))
    (cookies:cookie-map-set-cookie state (cookies:make-cookie "a" "new"))
    (is = 3 (cookies:cookie-map-size state))
    (multiple-value-bind (value found-p) (cookies:cookie-map-get state "a")
      (true found-p)
      (is string= "new" value))
    (cookies:cookie-map-set-cookie state (cookies:make-cookie "a" ""))
    (false (cookies:cookie-map-has state "a"))
    (is = 2 (cookies:cookie-map-size state))
    (cookies:cookie-map-delete state "c")
    (false (cookies:cookie-map-has state "c"))
    (is = 1 (cookies:cookie-map-size state))
    (is = 2 (cookies:cookie-map-modification-count state))
    (is equal
        '("a=; Path=/; SameSite=Lax"
          "c=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; SameSite=Lax")
        (cookies:cookie-map-response-fields state)))
  (let ((state (cookies:make-cookie-map-state
                (list (cookies:make-cookie-pair "a" "1")
                      (cookies:make-cookie-pair "b" "2")))))
    (multiple-value-bind (name value found-p) (cookies:cookie-map-entry-at state 0)
      (declare (ignore value))
      (true found-p)
      (is string= "a" name))
    (cookies:cookie-map-set-cookie state (cookies:make-cookie "c" "3"))
    ;; A live iterator with cursor 1 now sees original a again after c moved to front.
    (multiple-value-bind (name value found-p) (cookies:cookie-map-entry-at state 1)
      (true found-p)
      (is string= "a" name)
      (is string= "1" value))))

(define-test cookie-core-map-direct-construction
  :parent cookie-core
  (let ((state (cookies:make-cookie-map-state-from-header
                "a=1; a=2; empty=; ignored")))
    (is = 3 (cookies:cookie-map-size state))
    (multiple-value-bind (name value found-p)
        (cookies:cookie-map-entry-at state 1)
      (true found-p)
      (is string= "a" name)
      (is string= "2" value)))
  (let* ((eacute (string (code-char #xe9)))
         (state
           (cookies:make-cookie-map-state-from-header-fields
            (list (concatenate 'string "raw=" eacute) "encoded=%41"))))
    (multiple-value-bind (value found-p) (cookies:cookie-map-get state "raw")
      (true found-p)
      (is equal '(#xc3 #xa9) (cookie-codepoints value)))
    (multiple-value-bind (value found-p) (cookies:cookie-map-get state "encoded")
      (true found-p)
      (is string= "A" value)))
  (let* ((name (copy-seq "name"))
         (value (copy-seq "value"))
         (state (cookies:make-cookie-map-state)))
    (cookies:cookie-map-add-original state name value)
    (setf (char name 0) #\X
          (char value 0) #\X)
    (multiple-value-bind (stored found-p) (cookies:cookie-map-get state "name")
      (true found-p)
      (is string= "value" stored))))

(define-test cookie-core-map-direct-construction-resources
  :parent cookie-core
  (let* ((header-n (cookie-map-resource-header 1024))
         (header-2n (cookie-map-resource-header 2048))
         (header-4n (cookie-map-resource-header 4096)))
    ;; Warm every checked size before taking aggregate allocation samples.
    (cookies:make-cookie-map-state-from-header header-n)
    (cookies:make-cookie-map-state-from-header header-2n)
    (cookies:make-cookie-map-state-from-header header-4n)
    (multiple-value-bind (direct-bytes direct-state)
        (cookie-map-measured-bytes
         (lambda () (cookies:make-cookie-map-state-from-header header-n)))
      (is = 1024 (cookies:cookie-map-size direct-state))
      (is = 1024
          (array-total-size
           (cookies::cookie-map-state-originals direct-state)))
      (multiple-value-bind (legacy-bytes legacy-state)
          (cookie-map-measured-bytes
           (lambda ()
             (cookies:make-cookie-map-state
              (cookies:parse-cookie-header header-n))))
        (is = 1024 (cookies:cookie-map-size legacy-state))
        (true (< direct-bytes legacy-bytes)
              "direct parsing must allocate less than the pair-list/copy path"))
      (multiple-value-bind (twice-bytes twice-state)
          (cookie-map-measured-bytes
           (lambda () (cookies:make-cookie-map-state-from-header header-2n)))
        (is = 2048 (cookies:cookie-map-size twice-state))
        (is = 2048
            (array-total-size
             (cookies::cookie-map-state-originals twice-state)))
        (true (< twice-bytes (* 2.75d0 direct-bytes))
              "N to 2N direct allocation remains linear")
        (multiple-value-bind (four-times-bytes four-times-state)
            (cookie-map-measured-bytes
             (lambda () (cookies:make-cookie-map-state-from-header header-4n)))
          (is = 4096 (cookies:cookie-map-size four-times-state))
          (is = 4096
              (array-total-size
               (cookies::cookie-map-state-originals four-times-state)))
          (true (< four-times-bytes (* 2.75d0 twice-bytes))
                "2N to 4N direct allocation remains linear"))))
    (cookies:make-cookie-map-state-from-header header-n)
    (cookies:make-cookie-map-state-from-header header-2n)
    (cookies:make-cookie-map-state-from-header header-4n)
    (let ((time-n (cookie-map-median-parse-nanoseconds header-n))
          (time-2n (cookie-map-median-parse-nanoseconds header-2n))
          (time-4n (cookie-map-median-parse-nanoseconds header-4n)))
      (format t "~&CookieMap median timing (ns): N=~d 2N=~d 4N=~d~%"
              time-n time-2n time-4n)
      (true (plusp time-n))
      (true (< time-2n (* 3.25d0 time-n))
            "N to 2N median warmed elapsed time remains linear")
      (true (< time-4n (* 3.25d0 time-2n))
            "2N to 4N median warmed elapsed time remains linear"))))
