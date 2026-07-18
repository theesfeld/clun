;;;; clun-cron.lisp — pure-CL Bun.cron surface (Phase 76 / Issue #136).
;;;;
;;;; In-process scheduling and expression parse/next-occurrence are pure Common
;;;; Lisp over the existing timer loop and UTC Date core. OS-level register and
;;;; remove (crontab / launchd / schtasks) fail closed: pure-CL forbids shell-outs
;;;; as implementation shortcuts.

(in-package :clun.runtime)

;;; --- bitset helpers ----------------------------------------------------------

(declaim (inline %bit-set-p %set-bit))
(defun %bit-set-p (bits pos)
  (plusp (logand bits (ash 1 pos))))

(defun %set-bit (bits pos)
  (logior bits (ash 1 pos)))

(defconstant +cron-all-hours+ #xFFFFFF)          ; bits 0-23
(defconstant +cron-all-days+ #xFFFFFFFE)         ; bits 1-31
(defconstant +cron-all-months+ #x1FFE)           ; bits 1-12
(defconstant +cron-all-weekdays+ #x7F)           ; bits 0-6

;;; --- expression --------------------------------------------------------------

(defstruct (cron-expr (:conc-name cron-expr-))
  (minutes 0 :type integer)
  (hours 0 :type integer)
  (days 0 :type integer)
  (months 0 :type integer)
  (weekdays 0 :type integer)
  (days-wildcard-p nil)
  (weekdays-wildcard-p nil))

(define-condition cron-parse-error (error)
  ((message :initarg :message :reader cron-parse-error-message))
  (:report (lambda (c s) (write-string (cron-parse-error-message c) s))))

(defun %cron-error (message)
  (error 'cron-parse-error :message message))

;;; --- name tables -------------------------------------------------------------

(defparameter *cron-weekday-names*
  '(("sun" . 0) ("sunday" . 0)
    ("mon" . 1) ("monday" . 1)
    ("tue" . 2) ("tuesday" . 2)
    ("wed" . 3) ("wednesday" . 3)
    ("thu" . 4) ("thursday" . 4)
    ("fri" . 5) ("friday" . 5)
    ("sat" . 6) ("saturday" . 6)))

(defparameter *cron-month-names*
  '(("jan" . 1) ("january" . 1)
    ("feb" . 2) ("february" . 2)
    ("mar" . 3) ("march" . 3)
    ("apr" . 4) ("april" . 4)
    ("may" . 5)
    ("jun" . 6) ("june" . 6)
    ("jul" . 7) ("july" . 7)
    ("aug" . 8) ("august" . 8)
    ("sep" . 9) ("september" . 9)
    ("oct" . 10) ("october" . 10)
    ("nov" . 11) ("november" . 11)
    ("dec" . 12) ("december" . 12)))

(defun %cron-lookup-name (token names)
  (let ((key (string-downcase token)))
    (cdr (assoc key names :test #'string=))))

;;; --- field parsing -----------------------------------------------------------

(defun %cron-parse-decimal (token)
  "Parse a non-empty unsigned decimal token, or NIL."
  (when (and (plusp (length token))
             (every #'digit-char-p token))
    (parse-integer token)))

(defun %cron-parse-value (token min max kind)
  (or (ecase kind
        (:none nil)
        (:weekday (%cron-lookup-name token *cron-weekday-names*))
        (:month (%cron-lookup-name token *cron-month-names*)))
      (let ((val (%cron-parse-decimal token)))
        (unless val
          (%cron-error "Invalid cron expression: value out of range for field"))
        (unless (<= min val max)
          (%cron-error "Invalid cron expression: value out of range for field"))
        val)))

(defun %cron-split-range (base)
  "Return (values lo hi) if BASE is a range a-b, else NIL."
  (let ((idx (position #\- base)))
    (when (and idx (plusp idx) (< idx (1- (length base)))
               (not (position #\- base :start (1+ idx))))
      (values (subseq base 0 idx) (subseq base (1+ idx))))))

(defun %cron-parse-field (field min max kind)
  "Parse one cron field into a bitset integer."
  (when (zerop (length field))
    (%cron-error "Invalid cron expression: unrecognized field syntax"))
  (let ((result 0))
    (dolist (part (uiop:split-string field :separator '(#\,)))
      (when (zerop (length part))
        (%cron-error "Invalid cron expression: unrecognized field syntax"))
      (let* ((slash (position #\/ part))
             (base (if slash (subseq part 0 slash) part))
             (step-str (when slash (subseq part (1+ slash))))
             (step 1))
        (when slash
          (when (or (zerop (length step-str))
                    (position #\/ step-str))
            (%cron-error "Invalid cron expression: step value must be a positive integer"))
          (let ((s (%cron-parse-decimal step-str)))
            (unless (and s (<= 1 s 127))
              (%cron-error "Invalid cron expression: step value must be a positive integer"))
            (setf step s)))
        (when (zerop (length base))
          (%cron-error "Invalid cron expression: unrecognized field syntax"))
        (multiple-value-bind (range-min range-max)
            (cond
              ((string= base "*")
               (values min max))
              (t
               (multiple-value-bind (lo-s hi-s) (%cron-split-range base)
                 (if lo-s
                     (let ((lo (%cron-parse-value lo-s min max kind))
                           (hi (%cron-parse-value hi-s min max kind)))
                       (when (> lo hi)
                         (%cron-error
                          "Invalid cron expression: range must be ascending (use 'a,b' or 'a-max,0-b' for wrap-around)"))
                       (values lo hi))
                     (let ((lo (%cron-parse-value base min max kind)))
                       (values lo (if slash max lo)))))))
          (loop for i = range-min then (+ i step)
                while (<= i range-max)
                do (setf result (%set-bit result i))
                when (> (+ i step) range-max) do (return)))))
    ;; Weekday: fold bit 7 (Sunday alias) into bit 0 after range expansion.
    (when (eq kind :weekday)
      (setf result (logand (logior result (ash result -7)) #x7F)))
    result))

(defun %cron-nickname (trimmed)
  (cond
    ((or (string-equal trimmed "@yearly") (string-equal trimmed "@annually"))
     (make-cron-expr :minutes 1 :hours 1
                     :days (ash 1 1) :months (ash 1 1)
                     :weekdays +cron-all-weekdays+
                     :days-wildcard-p nil :weekdays-wildcard-p t))
    ((string-equal trimmed "@monthly")
     (make-cron-expr :minutes 1 :hours 1
                     :days (ash 1 1) :months +cron-all-months+
                     :weekdays +cron-all-weekdays+
                     :days-wildcard-p nil :weekdays-wildcard-p t))
    ((string-equal trimmed "@weekly")
     (make-cron-expr :minutes 1 :hours 1
                     :days +cron-all-days+ :months +cron-all-months+
                     :weekdays 1
                     :days-wildcard-p t :weekdays-wildcard-p nil))
    ((or (string-equal trimmed "@daily") (string-equal trimmed "@midnight"))
     (make-cron-expr :minutes 1 :hours 1
                     :days +cron-all-days+ :months +cron-all-months+
                     :weekdays +cron-all-weekdays+
                     :days-wildcard-p t :weekdays-wildcard-p t))
    ((string-equal trimmed "@hourly")
     (make-cron-expr :minutes 1 :hours +cron-all-hours+
                     :days +cron-all-days+ :months +cron-all-months+
                     :weekdays +cron-all-weekdays+
                     :days-wildcard-p t :weekdays-wildcard-p t))
    (t nil)))

(defun parse-cron-expression (input)
  "Parse a 5-field cron expression or @nickname into a CRON-EXPR.
Signals CRON-PARSE-ERROR on invalid input."
  (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) input)))
    (when (zerop (length trimmed))
      (%cron-error
       "Invalid cron expression: expected 5 space-separated fields (minute hour day month weekday)"))
    (when (char= (char trimmed 0) #\@)
      (return-from parse-cron-expression
        (or (%cron-nickname trimmed)
            (%cron-error "Invalid cron expression: unrecognized field syntax"))))
    (let* ((parts (remove "" (uiop:split-string trimmed :separator '(#\Space #\Tab))
                          :test #'string=))
           (n (length parts)))
      (when (< n 5)
        (%cron-error
         "Invalid cron expression: expected 5 space-separated fields (minute hour day month weekday)"))
      (when (> n 5)
        (%cron-error
         "Invalid cron expression: too many fields. Bun.cron uses 5 fields (minute hour day month weekday) — seconds are not supported"))
      (make-cron-expr
       :minutes (%cron-parse-field (nth 0 parts) 0 59 :none)
       :hours (%cron-parse-field (nth 1 parts) 0 23 :none)
       :days (%cron-parse-field (nth 2 parts) 1 31 :none)
       :months (%cron-parse-field (nth 3 parts) 1 12 :month)
       :weekdays (%cron-parse-field (nth 4 parts) 0 7 :weekday)
       :days-wildcard-p (string= (nth 2 parts) "*")
       :weekdays-wildcard-p (string= (nth 4 parts) "*")))))

;;; --- next occurrence (UTC, strictly after FROM-MS) ---------------------------

(defconstant +cron-ms-day+ 86400000)
(defconstant +cron-ms-hour+ 3600000)
(defconstant +cron-ms-minute+ 60000)
(defparameter +cron-month-days+ #(31 28 31 30 31 30 31 31 30 31 30 31))

(defun %cron-leap-p (y)
  (and (zerop (mod y 4)) (or (not (zerop (mod y 100))) (zerop (mod y 400)))))

(defun %cron-day-from-year (y)
  (+ (* 365 (- y 1970))
     (floor (- y 1969) 4)
     (- (floor (- y 1901) 100))
     (floor (- y 1601) 400)))

(defun %cron-year-from-day (day)
  (let ((y (+ 1970 (floor (* day 10000) 3652425))))
    (loop while (> (%cron-day-from-year y) day) do (decf y))
    (loop while (<= (%cron-day-from-year (1+ y)) day) do (incf y))
    y))

(defun %cron-decompose (tv-ms)
  "UTC ms -> (values year month[1-12] day hour minute weekday[0-6])."
  (let* ((day (floor tv-ms +cron-ms-day+))
         (twd (mod tv-ms +cron-ms-day+))
         (year (%cron-year-from-day day))
         (doy (- day (%cron-day-from-year year)))
         (leap (%cron-leap-p year))
         (month 0))
    (loop for m below 12
          for dim = (+ (aref +cron-month-days+ m) (if (and (= m 1) leap) 1 0))
          do (if (< doy dim)
                 (progn (setf month m) (return))
                 (decf doy dim)))
    (values year (1+ month) (1+ doy)
            (floor twd +cron-ms-hour+)
            (mod (floor twd +cron-ms-minute+) 60)
            (mod (+ day 4) 7))))

(defun %cron-compose (year month day hour minute)
  "UTC components (month 1-12) -> ms since epoch."
  (let* ((y year)
         (m (1- month))
         (y2 (+ y (floor m 12)))
         (m2 (mod m 12))
         (day-num (+ (%cron-day-from-year y2)
                     (loop for i below m2
                           sum (+ (aref +cron-month-days+ i)
                                  (if (and (= i 1) (%cron-leap-p y2)) 1 0)))
                     (1- day))))
    (+ (* day-num +cron-ms-day+)
       (* hour +cron-ms-hour+)
       (* minute +cron-ms-minute+))))

(defun %cron-days-in-month (year month)
  (+ (aref +cron-month-days+ (1- month))
     (if (and (= month 2) (%cron-leap-p year)) 1 0)))

(defun %cron-normalize-components (year month day hour minute)
  "Carry overflow so components are valid; return recomposed ms."
  (loop while (> minute 59)
        do (decf minute 60) (incf hour))
  (loop while (> hour 23)
        do (decf hour 24) (incf day))
  (loop
    (let ((dim (%cron-days-in-month year month)))
      (when (<= day dim) (return))
      (decf day dim)
      (incf month)
      (when (> month 12)
        (setf month 1)
        (incf year))))
  (%cron-compose year month day hour minute))

(defun cron-next-ms (expr from-ms)
  "Next matching UTC time strictly after FROM-MS, or NIL if none within 8 years.
Mirrors Bun's bitset walk: advance minute, zero seconds, cascade on mismatch."
  (let* ((start (truncate from-ms))
         (start-year (nth-value 0 (%cron-decompose start)))
         ;; Next whole minute boundary strictly after from (Bun: minute += 1; second = 0).
         (cursor (* (1+ (floor start +cron-ms-minute+)) +cron-ms-minute+)))
    (loop
      (multiple-value-bind (year month day hour minute weekday)
          (%cron-decompose cursor)
        (when (> (- year start-year) 8)
          (return nil))
        (cond
          ((not (%bit-set-p (cron-expr-months expr) month))
           (incf month)
           (when (> month 12)
             (setf month 1)
             (incf year))
           (setf cursor (%cron-compose year month 1 0 0)))
          (t
           (let* ((day-ok (%bit-set-p (cron-expr-days expr) day))
                  (wd-ok (%bit-set-p (cron-expr-weekdays expr) weekday))
                  (day-match
                    (if (and (not (cron-expr-days-wildcard-p expr))
                             (not (cron-expr-weekdays-wildcard-p expr)))
                        (or day-ok wd-ok)
                        (and day-ok wd-ok))))
             (cond
               ((not day-match)
                (setf cursor (%cron-normalize-components year month (1+ day) 0 0)))
               ((not (%bit-set-p (cron-expr-hours expr) hour))
                (setf cursor (%cron-normalize-components year month day (1+ hour) 0)))
               ((not (%bit-set-p (cron-expr-minutes expr) minute))
                (setf cursor (%cron-normalize-components year month day hour (1+ minute))))
               (t
                (return (coerce cursor 'double-float)))))))))))

;;; --- wall clock --------------------------------------------------------------

(defun %cron-now-ms ()
  (or (and eng:*realm* (eng:realm-clock-now-ms eng:*realm*))
      (coerce (sys:unix-milliseconds) 'double-float)))

;;; --- CronJob state -----------------------------------------------------------

(defstruct (cron-job-state (:conc-name cjs-))
  expression
  schedule-text
  handler
  (stopped nil)
  (refd t)
  timer-id
  (last-next-ms 0d0)
  (in-fire nil)
  js-job)

(defun %cron-clear-timer (state)
  (let ((id (cjs-timer-id state)))
    (when id
      (let* ((g (eng:realm-global eng:*realm*))
             (clear (eng:js-get g "clearTimeout")))
        (when (eng:callable-p clear)
          (eng:js-call clear eng:+undefined+ (list id))))
      (setf (cjs-timer-id state) nil))))

(defun %cron-apply-ref (state)
  "Mirror ref/unref onto the pending Timeout handle when present."
  (let ((id (cjs-timer-id state)))
    (when (and id (eng:js-object-p id))
      (let ((method (eng:js-get id (if (cjs-refd state) "ref" "unref"))))
        (when (eng:callable-p method)
          (eng:js-call method id '()))))))

(defun %cron-schedule-next (state)
  (when (cjs-stopped state)
    (%cron-clear-timer state)
    (return-from %cron-schedule-next nil))
  (let* ((now (%cron-now-ms))
         (from (max now (cjs-last-next-ms state)))
         (next (cron-next-ms (cjs-expression state) from)))
    (unless next
      (setf (cjs-stopped state) t)
      (%cron-clear-timer state)
      (return-from %cron-schedule-next nil))
    (setf (cjs-last-next-ms state) next)
    (let* ((delay (max 1d0 (- next now)))
           (g (eng:realm-global eng:*realm*))
           (set-timeout (eng:js-get g "setTimeout"))
           (cb (eng:make-native-function
                "" 0
                (lambda (this args)
                  (declare (ignore this args))
                  (%cron-on-fire state)
                  eng:+undefined+))))
      (%cron-clear-timer state)
      (setf (cjs-timer-id state)
            (eng:js-call set-timeout eng:+undefined+ (list cb delay)))
      (%cron-apply-ref state)
      t)))

(defun %cron-on-fire (state)
  (setf (cjs-timer-id state) nil)
  (when (cjs-stopped state)
    (return-from %cron-on-fire))
  (let ((handler (cjs-handler state))
        (job (cjs-js-job state)))
    (setf (cjs-in-fire state) t)
    (let ((result
            (handler-case
                (eng:js-call handler job '())
              (eng:js-condition (c)
                ;; Sync throw → rethrow so uncaughtException / CLI surface it.
                (setf (cjs-in-fire state) nil)
                (%cron-schedule-next state)
                (error c)))))
      (setf (cjs-in-fire state) nil)
      (when (cjs-stopped state)
        (return-from %cron-on-fire))
      (if (and (eng:js-promise-p result)
               (eq (eng:js-promise-pstate result) :pending))
          (let ((on-done
                  (eng:make-native-function
                   "" 1
                   (lambda (this args)
                     (declare (ignore this args))
                     (unless (cjs-stopped state)
                       (%cron-schedule-next state))
                     eng:+undefined+))))
            ;; Fulfill and reject both re-arm (Bun: reschedule after error).
            (eng:js-call (eng:js-get result "then") result
                         (list on-done on-done)))
          (%cron-schedule-next state)))))

(defun %make-cron-job (g schedule-text expr handler)
  (let* ((state (make-cron-job-state
                 :expression expr
                 :schedule-text schedule-text
                 :handler handler
                 :refd t))
         (job (eng:new-object)))
    (setf (cjs-js-job state) job)
    (eng:hidden-prop job "%cron-job%" state)
    (eng:install-getter job "cron"
      (lambda (this args)
        (declare (ignore this args))
        (cjs-schedule-text state)))
    (eng:install-method job "stop" 0
      (lambda (this args)
        (declare (ignore this args))
        (unless (cjs-stopped state)
          (setf (cjs-stopped state) t)
          (%cron-clear-timer state))
        job))
    (eng:install-method job "ref" 0
      (lambda (this args)
        (declare (ignore this args))
        (unless (cjs-stopped state)
          (setf (cjs-refd state) t)
          (%cron-apply-ref state))
        job))
    (eng:install-method job "unref" 0
      (lambda (this args)
        (declare (ignore this args))
        (setf (cjs-refd state) nil)
        (%cron-apply-ref state)
        job))
    ;; Disposable: prefer Symbol.dispose when present; else a plain dispose method.
    (let* ((sym-ctor (eng:js-get g "Symbol"))
           (dispose-key
             (when (eng:js-object-p sym-ctor)
               (let ((for-fn (eng:js-get sym-ctor "for")))
                 (when (eng:callable-p for-fn)
                   (eng:js-call for-fn sym-ctor (list "dispose")))))))
      (let ((stop-fn
              (eng:make-native-function
               "dispose" 0
               (lambda (this args)
                 (declare (ignore this args))
                 (unless (cjs-stopped state)
                   (setf (cjs-stopped state) t)
                   (%cron-clear-timer state))
                 eng:+undefined+))))
        (if (eng:js-symbol-p dispose-key)
            (eng::obj-set-desc job dispose-key
                               (eng::data-pd stop-fn :writable t :enumerable nil :configurable t))
            (eng:data-prop job "dispose" stop-fn))))
    (unless (%cron-schedule-next state)
      (eng:throw-native-error
       :error
       (format nil "Cron expression '~a' has no future occurrences" schedule-text)))
    job))

;;; --- OS-level fail-closed ----------------------------------------------------

(defparameter *cron-os-unsupported*
  "Clun.cron OS-level registration is unavailable: pure Common Lisp cannot drive crontab, launchd, or Task Scheduler. Use the in-process overload Clun.cron(schedule, handler) instead.")

(defun %cron-rejected-promise (g message)
  (let ((promise-ctor (eng:js-get g "Promise"))
        (err (eng:js-construct (eng:js-get g "Error") (list message))))
    (eng:js-construct promise-ctor
      (list (eng:make-native-function
             "" 2
             (lambda (this a)
               (declare (ignore this))
               (eng:js-call (eng:arg a 1) eng:+undefined+ (list err))
               eng:+undefined+))))))

;;; --- public install ----------------------------------------------------------

(defun %cron-parse-relative (from)
  "Coerce optional relativeDate (Date | number | undefined) to ms, or signal."
  (cond
    ((eng:js-undefined-p from) (%cron-now-ms))
    ((eng::js-date-p from) (eng::js-date-tv from))
    (t
     (let ((n (eng:to-number from)))
       (when (or (eng:js-nan-p n) (eng:js-infinite-p n))
         (eng:throw-native-error :error "relativeDate must be a finite number or Date"))
       n))))

(defun make-clun-cron (g)
  "Callable Clun.cron with .parse and .remove (Bun-shaped)."
  (let ((cron
          (eng:make-native-function
           "cron" 2
           (lambda (this args)
             (declare (ignore this))
             (let ((a0 (eng:arg args 0))
                   (a1 (eng:arg args 1))
                   (a2 (eng:arg args 2)))
               (cond
                 ;; OS-level: (path, schedule, title) — fail closed.
                 ((and (not (eng:js-undefined-p a2))
                       (not (eng:callable-p a1)))
                  (unless (eng:js-string-p a0)
                    (eng:throw-type-error "Bun.cron() expects a string path as the first argument"))
                  (unless (eng:js-string-p a1)
                    (eng:throw-type-error "Bun.cron() expects a string schedule as the second argument"))
                  (unless (eng:js-string-p a2)
                    (eng:throw-type-error "Bun.cron() expects a string title as the third argument"))
                  ;; Validate schedule so bad expressions still throw like Bun.
                  (handler-case
                      (parse-cron-expression (eng:to-string a1))
                    (cron-parse-error (c)
                      (eng:throw-native-error :error (cron-parse-error-message c))))
                  (%cron-rejected-promise g *cron-os-unsupported*))
                 ;; In-process: (schedule, handler)
                 (t
                  (unless (eng:js-string-p a0)
                    (eng:throw-type-error "Bun.cron() expects a string cron expression"))
                  (unless (eng:callable-p a1)
                    (eng:throw-type-error "Bun.cron() expects a function handler"))
                  (let* ((schedule (eng:to-string a0))
                         (expr
                           (handler-case (parse-cron-expression schedule)
                             (cron-parse-error (c)
                               (eng:throw-native-error :error (cron-parse-error-message c))))))
                    (%make-cron-job g schedule expr a1)))))))))
    (eng:data-prop
     cron "parse"
     (eng:make-native-function
      "parse" 2
      (lambda (this args)
        (declare (ignore this))
        (let ((expr-arg (eng:arg args 0))
              (from-arg (eng:arg args 1)))
          (unless (eng:js-string-p expr-arg)
            (eng:throw-type-error "Bun.cron.parse() expects a string cron expression"))
          (let* ((text (eng:to-string expr-arg))
                 (expr
                   (handler-case (parse-cron-expression text)
                     (cron-parse-error (c)
                       (eng:throw-native-error :error (cron-parse-error-message c)))))
                 (from (%cron-parse-relative from-arg))
                 (next (cron-next-ms expr from)))
            (if next
                (eng:js-construct (eng:js-get g "Date") (list next))
                eng:+null+))))))
    (eng:data-prop
     cron "remove"
     (eng:make-native-function
      "remove" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((title (eng:arg args 0)))
          (unless (eng:js-string-p title)
            (eng:throw-type-error "Bun.cron.remove() expects a string title"))
          (%cron-rejected-promise g *cron-os-unsupported*)))))
    cron))

(defun install-clun-cron (clun g)
  "Attach Clun.cron (Bun-compatible pure-CL scheduling surface)."
  (eng:fixed-data-prop clun "cron" (make-clun-cron g))
  clun)
