;;;; builtins-date.lisp — Date, UTC core (PLAN.md Phase 04, §21.4). Time value is a
;;;; double (ms since the epoch) or NaN. All gregorian<->ms math is pure integer CL
;;;; (exact: |tv| <= 8.64e15 < 2^53). Local time == UTC (getTimezoneOffset() = 0);
;;;; TZif local zones are deferred to Phase 26 (PLAN.md §3.1).

(in-package :clun.engine)

(defstruct (js-date (:include js-object (class :date)) (:constructor %make-js-date)) (tv 0d0))

(defconstant +ms-per-day+ 86400000)
(defconstant +ms-per-hour+ 3600000)
(defconstant +ms-per-minute+ 60000)
(defparameter +month-days+ #(31 28 31 30 31 30 31 31 30 31 30 31))
(defparameter +day-names+ #("Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat"))
(defparameter +month-names+ #("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))

(defun %leap-year-p (y) (and (zerop (mod y 4)) (or (not (zerop (mod y 100))) (zerop (mod y 400)))))
(defun %day-from-year (y)
  (+ (* 365 (- y 1970)) (floor (- y 1969) 4) (- (floor (- y 1901) 100)) (floor (- y 1601) 400)))
(defun %year-from-day (day)
  (let ((y (+ 1970 (floor (* day 10000) 3652425))))
    (loop while (> (%day-from-year y) day) do (decf y))
    (loop while (<= (%day-from-year (1+ y)) day) do (incf y))
    y))

(defun %decompose (tv)
  "Integer ms TV -> (values year month[0-11] date hours min sec ms weekday[0-6])."
  (let* ((day (floor tv +ms-per-day+))
         (twd (mod tv +ms-per-day+))
         (year (%year-from-day day))
         (doy (- day (%day-from-year year)))
         (leap (%leap-year-p year))
         (month 0))
    (loop for m below 12
          for dim = (+ (aref +month-days+ m) (if (and (= m 1) leap) 1 0))
          do (if (< doy dim) (progn (setf month m) (return)) (decf doy dim)))
    (values year month (1+ doy)
            (floor twd +ms-per-hour+)
            (mod (floor twd +ms-per-minute+) 60)
            (mod (floor twd 1000) 60)
            (mod tv 1000)
            (mod (+ day 4) 7))))

(defun %make-day (year month date)
  (let* ((y (+ year (floor month 12))) (m (mod month 12)))
    (+ (%day-from-year y)
       (loop for i below m sum (+ (aref +month-days+ i) (if (and (= i 1) (%leap-year-p y)) 1 0)))
       (1- date))))

(defun %make-time-ms (h mi s ms) (+ (* h +ms-per-hour+) (* mi +ms-per-minute+) (* s 1000) ms))

(defun %time-clip (tv)
  (cond ((not (js-finite-p tv)) *js-nan*)
        ((> (abs tv) 8.64d15) *js-nan*)
        (t (+ 0d0 (ftruncate tv)))))

(defun %compose-tv (y mo d h mi s ms)
  "Integer components -> clipped double time value."
  (%time-clip (coerce (+ (* (%make-day y mo d) +ms-per-day+) (%make-time-ms h mi s ms)) 'double-float)))

(defun %date-now ()
  (or (and *realm* (realm-clock-now-ms *realm*))
      (coerce (* 1000 (- (get-universal-time) 2208988800)) 'double-float)))

(defun this-date (this)
  (if (js-date-p this) this (throw-type-error "this is not a Date object")))
(defun this-date-tv (this) (js-date-tv (this-date this)))

(defun %date-get (this idx)
  (let ((tv (this-date-tv this)))
    (if (js-nan-p tv) *js-nan*
        (coerce (nth idx (multiple-value-list (%decompose (floor tv)))) 'double-float))))

(defun %date-from-fields (year month date hours min sec ms)
  "All args doubles (defaulted); returns clipped double time value or NaN."
  (if (some (lambda (x) (or (js-nan-p x) (js-infinite-p x))) (list year month date hours min sec ms))
      *js-nan*
      (let ((y (truncate year)))
        (when (<= 0 y 99) (setf y (+ 1900 y)))
        (%compose-tv y (truncate month) (truncate date)
                     (truncate hours) (truncate min) (truncate sec) (truncate ms)))))

(defun %date-set (this first-idx args &key nan-to-zero)
  "Recompute TV overriding fields [FIRST-IDX..] from ARGS (ToNumber'd)."
  (let* ((tv (js-date-tv this))
         (base (cond ((js-finite-p tv) (subseq (multiple-value-list (%decompose (floor tv))) 0 7))
                     (nan-to-zero (list 1970 0 1 0 0 0 0))
                     (t nil))))
    (if (null base)
        (setf (js-date-tv this) *js-nan*)
        (progn
          (loop for a in args for i from first-idx below 7
                do (let ((n (to-number a)))
                     (setf (nth i base) (if (or (js-nan-p n) (js-infinite-p n)) :nan (truncate n)))))
          (setf (js-date-tv this)
                (if (member :nan base) *js-nan*
                    (destructuring-bind (y mo d h mi s ms) base (%compose-tv y mo d h mi s ms))))))
    (js-date-tv this)))

;;; --- ISO 8601 parsing (§21.4.1.18) -----------------------------------------

(defun %parse-date (string)
  (let ((s (%trim-js-whitespace string)))
    (or (%parse-iso s) *js-nan*)))

(defun %digits-run (s i count)
  "Read exactly COUNT decimal digits at I -> (values int next) or (values nil nil)."
  (if (and (<= (+ i count) (length s))
           (loop for j from i below (+ i count) always (char<= #\0 (char s j) #\9)))
      (values (parse-integer s :start i :end (+ i count)) (+ i count))
      (values nil nil)))

(defun %parse-iso (s)
  (let ((n (length s)) (i 0) (year 0) (month 1) (date 1) (h 0) (mi 0) (sec 0) (ms 0)
        (tz-offset nil) (ysign 1))
    (macrolet ((need (form) `(multiple-value-bind (v ni) ,form
                               (if v (progn (setf i ni) v) (return-from %parse-iso nil)))))
      ;; year: [+-]YYYYYY or YYYY
      (cond ((and (< i n) (member (char s i) '(#\+ #\-)))
             (when (char= (char s i) #\-) (setf ysign -1))
             (incf i) (setf year (* ysign (need (%digits-run s i 6)))))
            (t (setf year (need (%digits-run s i 4)))))
      (when (and (< i n) (char= (char s i) #\-))
        (incf i) (setf month (need (%digits-run s i 2)))
        (when (and (< i n) (char= (char s i) #\-))
          (incf i) (setf date (need (%digits-run s i 2)))))
      (when (and (< i n) (char= (char s i) #\T))
        (incf i)
        (setf h (need (%digits-run s i 2)))
        (unless (and (< i n) (char= (char s i) #\:)) (return-from %parse-iso nil))
        (incf i) (setf mi (need (%digits-run s i 2)))
        (when (and (< i n) (char= (char s i) #\:))
          (incf i) (setf sec (need (%digits-run s i 2)))
          (when (and (< i n) (char= (char s i) #\.))
            (incf i)
            (multiple-value-bind (v ni) (%digits-run s i 3)
              (unless v (return-from %parse-iso nil))
              (setf ms v i ni)))))
      ;; timezone
      (when (< i n)
        (cond ((char= (char s i) #\Z) (setf tz-offset 0) (incf i))
              ((member (char s i) '(#\+ #\-))
               (let ((sgn (if (char= (char s i) #\-) -1 1)))
                 (incf i)
                 (let ((oh (need (%digits-run s i 2))))
                   (unless (and (< i n) (char= (char s i) #\:)) (return-from %parse-iso nil))
                   (incf i)
                   (let ((om (need (%digits-run s i 2))))
                     (setf tz-offset (* sgn (+ (* oh 60) om)))))))
              (t (return-from %parse-iso nil))))
      (unless (= i n) (return-from %parse-iso nil))
      ;; Field-range validation (§21.4.1.18): month 1-12; day within the month's
      ;; actual length (leap-aware); hour 0-24 but 24 only when min=sec=ms=0.
      (unless (and (<= 1 month 12)
                   (<= 1 date (+ (aref +month-days+ (1- month))
                                 (if (and (= month 2) (%leap-year-p year)) 1 0)))
                   (<= 0 h 24) (<= 0 mi 59) (<= 0 sec 59)
                   (or (< h 24) (and (zerop mi) (zerop sec) (zerop ms))))
        (return-from %parse-iso nil))
      (let ((tv (%compose-tv year (1- month) date h mi sec ms)))
        (when (and tz-offset (js-finite-p tv)) (setf tv (%time-clip (+ tv (* tz-offset +ms-per-minute+)))))
        tv))))

;;; --- string output ----------------------------------------------------------

(defun %date-iso-string (tv)
  (multiple-value-bind (y mo d h mi s ms) (%decompose (floor tv))
    (let ((ystr (if (<= 0 y 9999) (format nil "~4,'0d" y)
                    (format nil "~:[+~;-~]~6,'0d" (minusp y) (abs y)))))
      (format nil "~a-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0d.~3,'0dZ" ystr (1+ mo) d h mi s ms))))

(defun %date-utc-string (tv)
  (multiple-value-bind (y mo d h mi s ms wd) (%decompose (floor tv))
    (declare (ignore ms))
    (format nil "~a, ~2,'0d ~a ~4,'0d ~2,'0d:~2,'0d:~2,'0d GMT"
            (aref +day-names+ wd) d (aref +month-names+ mo) y h mi s)))

(defun %date-string (tv)
  (if (js-nan-p tv) "Invalid Date"
      (multiple-value-bind (y mo d h mi s ms wd) (%decompose (floor tv))
        (declare (ignore ms))
        (format nil "~a ~a ~2,'0d ~4,'0d ~2,'0d:~2,'0d:~2,'0d GMT+0000 (Coordinated Universal Time)"
                (aref +day-names+ wd) (aref +month-names+ mo) d y h mi s))))

;;; --- bootstrap --------------------------------------------------------------

(defun %date-value-arg (v)
  "new Date(value): a Date copies its tv; else ToPrimitive then string-parse/number."
  (if (js-date-p v) (js-date-tv v)
      (let ((prim (to-primitive v)))
        (if (stringp prim) (%time-clip (%parse-date prim)) (%time-clip (to-number prim))))))

(defun %bootstrap-date ()
  (let ((dp (js-make-object (intrinsic :object-prototype))))
    (setf (realm-intrinsic *realm* :date-prototype) dp)
    (macrolet ((m (name arity &body body) `(install-method dp ,name ,arity ,@body)))
      (m "getTime" 0 (lambda (this args) (declare (ignore args)) (this-date-tv this)))
      (m "valueOf" 0 (lambda (this args) (declare (ignore args)) (this-date-tv this)))
      (m "setTime" 1 (lambda (this args) (setf (js-date-tv (this-date this)) (%time-clip (to-number (arg args 0))))))
      (m "getTimezoneOffset" 0 (lambda (this args) (declare (ignore args)) (if (js-nan-p (this-date-tv this)) *js-nan* 0d0)))
      (macrolet ((getter (name idx) `(progn (m ,name 0 (lambda (this args) (declare (ignore args)) (%date-get this ,idx)))
                                            (m ,(concatenate 'string "getUTC" (subseq name 3)) 0
                                               (lambda (this args) (declare (ignore args)) (%date-get this ,idx))))))
        (getter "getFullYear" 0) (getter "getMonth" 1) (getter "getDate" 2)
        (getter "getHours" 3) (getter "getMinutes" 4) (getter "getSeconds" 5)
        (getter "getMilliseconds" 6) (getter "getDay" 7))
      (macrolet ((setter (name first &key nz)
                   `(progn (m ,name 4 (lambda (this args) (%date-set (this-date this) ,first args :nan-to-zero ,nz)))
                           (m ,(concatenate 'string "setUTC" (subseq name 3)) 4
                              (lambda (this args) (%date-set (this-date this) ,first args :nan-to-zero ,nz))))))
        (setter "setFullYear" 0 :nz t) (setter "setMonth" 1) (setter "setDate" 2)
        (setter "setHours" 3) (setter "setMinutes" 4) (setter "setSeconds" 5) (setter "setMilliseconds" 6))
      (m "toISOString" 0 (lambda (this args) (declare (ignore args))
                           (let ((tv (this-date-tv this)))
                             (unless (js-finite-p tv) (throw-range-error "Invalid time value"))
                             (%date-iso-string tv))))
      (m "toJSON" 1 (lambda (this args) (declare (ignore args))
                      (let* ((o (to-object this)) (tv (to-primitive o :number)))
                        (if (and (js-number-p tv) (not (js-finite-p tv))) +null+
                            (js-call (js-get o "toISOString") o '())))))
      (m "toString" 0 (lambda (this args) (declare (ignore args)) (%date-string (this-date-tv this))))
      (m "toDateString" 0 (lambda (this args) (declare (ignore args)) (%date-string (this-date-tv this))))
      (m "toTimeString" 0 (lambda (this args) (declare (ignore args)) (%date-string (this-date-tv this))))
      (m "toUTCString" 0 (lambda (this args) (declare (ignore args))
                           (let ((tv (this-date-tv this))) (if (js-nan-p tv) "Invalid Date" (%date-utc-string tv)))))
      (m "toGMTString" 0 (lambda (this args) (declare (ignore args))
                           (let ((tv (this-date-tv this))) (if (js-nan-p tv) "Invalid Date" (%date-utc-string tv)))))
      (m "toLocaleString" 0 (lambda (this args) (declare (ignore args)) (%date-string (this-date-tv this))))
      (m "toLocaleDateString" 0 (lambda (this args) (declare (ignore args)) (%date-string (this-date-tv this))))
      (m "toLocaleTimeString" 0 (lambda (this args) (declare (ignore args)) (%date-string (this-date-tv this))))
      (obj-set-desc dp (well-known :to-primitive)
                    (data-pd (make-native-function "[Symbol.toPrimitive]" 1
                               (lambda (this args)
                                 (unless (js-object-p this) (throw-type-error "not an object"))
                                 (let ((hint (arg args 0)))
                                   (ordinary-to-primitive this (if (or (equal hint "string") (equal hint "default")) :string :number)))))
                             :writable nil :enumerable nil :configurable t)))
    (let ((ctor (make-constructor "Date" 7
                  (lambda (this args) (declare (ignore this args)) (%date-string (%date-now)))
                  :prototype dp
                  :construct-fn
                  (lambda (args nt)
                    (let ((tv (cond ((null args) (%date-now))
                                    ((= 1 (length args)) (%date-value-arg (arg args 0)))
                                    (t (%date-from-fields
                                        (to-number (arg args 0)) (to-number (arg args 1))
                                        (if (> (length args) 2) (to-number (arg args 2)) 1d0)
                                        (if (> (length args) 3) (to-number (arg args 3)) 0d0)
                                        (if (> (length args) 4) (to-number (arg args 4)) 0d0)
                                        (if (> (length args) 5) (to-number (arg args 5)) 0d0)
                                        (if (> (length args) 6) (to-number (arg args 6)) 0d0))))))
                      (%make-js-date :proto (proto-from-newtarget nt :date-prototype) :tv tv))))))
      (install-method ctor "now" 0 (lambda (this args) (declare (ignore this args)) (%date-now)))
      (install-method ctor "parse" 1 (lambda (this args) (declare (ignore this)) (%time-clip (%parse-date (to-string (arg args 0))))))
      (install-method ctor "UTC" 7
        (lambda (this args) (declare (ignore this))
          (%date-from-fields (if args (to-number (arg args 0)) *js-nan*)
                             (if (> (length args) 1) (to-number (arg args 1)) 0d0)
                             (if (> (length args) 2) (to-number (arg args 2)) 1d0)
                             (if (> (length args) 3) (to-number (arg args 3)) 0d0)
                             (if (> (length args) 4) (to-number (arg args 4)) 0d0)
                             (if (> (length args) 5) (to-number (arg args 5)) 0d0)
                             (if (> (length args) 6) (to-number (arg args 6)) 0d0))))
      (setf (realm-intrinsic *realm* :date-constructor) ctor))))
