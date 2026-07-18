;;;; clun-cron.lisp — Clun.cron pure-CL scheduling (Phase 76 / Issue #50).
;;;;
;;;; Surface (Bun-shaped, Clun-named):
;;;;   Clun.cron(schedule, handler)        → CronJob (in-process)
;;;;   Clun.cron(path, schedule, title)    → Promise (OS-level: fail-closed)
;;;;   Clun.cron.parse(expression, from?)  → Date | null (UTC next occurrence)
;;;;   Clun.cron.remove(title)             → Promise (OS-level: fail-closed)
;;;;
;;;; Cron expressions are standard 5-field (minute hour day month weekday) with
;;;; lists/ranges/steps, named months/weekdays, Sunday-as-7, nicknames, and POSIX
;;;; DOM/DOW OR semantics. In-process jobs schedule via the realm's setTimeout so
;;;; jest/vi fake timers control fire times. OS crontab/launchd/schtasks is not
;;;; pure-CL (shell-out / host scheduler); that overload validates then rejects.

(in-package :clun.runtime)

;;; --- bitset expression -------------------------------------------------------

(defstruct (cron-expression (:conc-name cronx-))
  (minutes 0 :type integer)            ; bits 0-59
  (hours 0 :type integer)              ; bits 0-23
  (days 0 :type integer)               ; bits 1-31
  (months 0 :type integer)             ; bits 1-12
  (weekdays 0 :type integer)           ; bits 0-6
  (days-wildcard nil)
  (weekdays-wildcard nil))

(defconstant +cron-all-hours+ #xFFFFFF)           ; 24 bits
(defconstant +cron-all-days+ #xFFFFFFFE)          ; bits 1-31
(defconstant +cron-all-months+ #x1FFE)            ; bits 1-12
(defconstant +cron-all-weekdays+ #x7F)            ; bits 0-6

(defparameter *cron-error-messages*
  '((:too-few-fields . "Invalid cron expression: expected 5 space-separated fields (minute hour day month weekday)")
    (:too-many-fields . "Invalid cron expression: too many fields. Clun.cron uses 5 fields (minute hour day month weekday) — seconds are not supported")
    (:invalid-step . "Invalid cron expression: step value must be a positive integer")
    (:invalid-range . "Invalid cron expression: range must be ascending (use 'a,b' or 'a-max,0-b' for wrap-around)")
    (:invalid-number . "Invalid cron expression: value out of range for field")
    (:invalid-field . "Invalid cron expression: unrecognized field syntax")))

(defun %cron-error-message (kind)
  (or (cdr (assoc kind *cron-error-messages*))
      "Invalid cron expression"))

(define-condition cron-parse-error (error)
  ((kind :initarg :kind :reader cron-parse-error-kind))
  (:report (lambda (c s)
             (write-string (%cron-error-message (cron-parse-error-kind c)) s))))

(defun %cron-fail (kind)
  (error 'cron-parse-error :kind kind))

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

(defun %cron-downcase (s)
  (string-downcase s))

(defun %cron-lookup-name (s kind)
  (let ((key (%cron-downcase s))
        (table (ecase kind
                 (:weekday *cron-weekday-names*)
                 (:month *cron-month-names*))))
    (cdr (assoc key table :test #'string=))))

;;; --- field parsing -----------------------------------------------------------

(defun %cron-bit-set-p (bits pos)
  (plusp (logand bits (ash 1 pos))))

(defun %cron-set-bit (bits pos)
  (logior bits (ash 1 pos)))

(defun %cron-parse-decimal (s)
  "Parse unsigned decimal; NIL if empty or non-digit."
  (when (and (plusp (length s))
             (every #'digit-char-p s))
    (parse-integer s)))

(defun %cron-parse-value (s min max kind)
  (when (member kind '(:weekday :month))
    (let ((named (%cron-lookup-name s kind)))
      (when named (return-from %cron-parse-value named))))
  (let ((val (%cron-parse-decimal s)))
    (unless val (%cron-fail :invalid-number))
    (unless (<= min val max) (%cron-fail :invalid-number))
    val))

(defun %cron-split-range (base)
  "Return (values lo-string hi-string) for a-b, or NIL if not a range."
  (let ((idx (position #\- base)))
    (when (and idx (plusp idx) (< idx (1- (length base)))
               (not (position #\- base :start (1+ idx))))
      (values (subseq base 0 idx) (subseq base (1+ idx))))))

(defun %cron-parse-field (field min max kind)
  (when (zerop (length field)) (%cron-fail :invalid-field))
  (let ((result 0)
        (parts (uiop:split-string field :separator '(#\,))))
    (dolist (part parts)
      (when (zerop (length part)) (%cron-fail :invalid-field))
      (let* ((slash (position #\/ part))
             (base (if slash (subseq part 0 slash) part))
             (step-str (when slash (subseq part (1+ slash))))
             (step 1))
        (when slash
          (when (or (zerop (length step-str))
                    (position #\/ step-str))
            (%cron-fail :invalid-step))
          (let ((sv (%cron-parse-decimal step-str)))
            (unless (and sv (<= 0 sv 127)) (%cron-fail :invalid-step))
            (when (zerop sv) (%cron-fail :invalid-step))
            (setf step sv)))
        (multiple-value-bind (range-min range-max)
            (cond
              ((string= base "*")
               (values min max))
              (t
               (multiple-value-bind (lo-s hi-s) (%cron-split-range base)
                 (if lo-s
                     (let ((lo (%cron-parse-value lo-s min max kind))
                           (hi (%cron-parse-value hi-s min max kind)))
                       (when (> lo hi) (%cron-fail :invalid-range))
                       (values lo hi))
                     (let ((lo (%cron-parse-value base min max kind)))
                       (values lo (if step-str max lo)))))))
          (loop for i = range-min then (+ i step)
                while (<= i range-max)
                do (setf result (%cron-set-bit result i))
                until (> (+ i step) range-max)))))
    ;; Weekday: fold bit 7 (Sunday alias) into bit 0 after expansion.
    (when (eq kind :weekday)
      (setf result (logand #x7F (logior result (ash result -7)))))
    result))

(defun %cron-nickname (expr)
  (let ((key (%cron-downcase expr)))
    (cond
      ((or (string= key "@yearly") (string= key "@annually"))
       (make-cron-expression
        :minutes 1 :hours 1 :days (ash 1 1) :months (ash 1 1)
        :weekdays +cron-all-weekdays+
        :days-wildcard nil :weekdays-wildcard t))
      ((string= key "@monthly")
       (make-cron-expression
        :minutes 1 :hours 1 :days (ash 1 1) :months +cron-all-months+
        :weekdays +cron-all-weekdays+
        :days-wildcard nil :weekdays-wildcard t))
      ((string= key "@weekly")
       (make-cron-expression
        :minutes 1 :hours 1 :days +cron-all-days+ :months +cron-all-months+
        :weekdays 1
        :days-wildcard t :weekdays-wildcard nil))
      ((or (string= key "@daily") (string= key "@midnight"))
       (make-cron-expression
        :minutes 1 :hours 1 :days +cron-all-days+ :months +cron-all-months+
        :weekdays +cron-all-weekdays+
        :days-wildcard t :weekdays-wildcard t))
      ((string= key "@hourly")
       (make-cron-expression
        :minutes 1 :hours +cron-all-hours+ :days +cron-all-days+
        :months +cron-all-months+ :weekdays +cron-all-weekdays+
        :days-wildcard t :weekdays-wildcard t))
      (t nil))))

(defun %cron-trim (s)
  (string-trim '(#\Space #\Tab #\Newline #\Return) s))

(defun parse-cron-expression (input)
  "Parse a 5-field cron expression or nickname. Signals CRON-PARSE-ERROR."
  (let ((expr (%cron-trim input)))
    (when (and (plusp (length expr)) (char= (char expr 0) #\@))
      (return-from parse-cron-expression
        (or (%cron-nickname expr) (%cron-fail :invalid-field))))
    (let* ((raw-fields (uiop:split-string expr :separator '(#\Space #\Tab)))
           (fields (remove-if (lambda (f) (zerop (length f))) raw-fields)))
      (when (< (length fields) 5) (%cron-fail :too-few-fields))
      (when (> (length fields) 5) (%cron-fail :too-many-fields))
      (make-cron-expression
       :minutes (%cron-parse-field (nth 0 fields) 0 59 nil)
       :hours (%cron-parse-field (nth 1 fields) 0 23 nil)
       :days (%cron-parse-field (nth 2 fields) 1 31 nil)
       :months (%cron-parse-field (nth 3 fields) 1 12 :month)
       :weekdays (%cron-parse-field (nth 4 fields) 0 7 :weekday)
       :days-wildcard (string= (nth 2 fields) "*")
       :weekdays-wildcard (string= (nth 4 fields) "*")))))


;;; --- next occurrence (UTC) ---------------------------------------------------

(defun %cron-wall-now-ms ()
  "Wall-clock ms since epoch, honoring realm fake-timer clock when set."
  (eng::%date-now))

(defun %cron-ms-to-fields (ms)
  "Return (values year month[1-12] day hour minute weekday[0-6])."
  (multiple-value-bind (year month0 day hour minute sec ms0 weekday)
      (eng::%decompose (floor ms))
    (declare (ignore sec ms0))
    (values year (1+ month0) day hour minute weekday)))

(defun %cron-fields-to-ms (year month day hour minute)
  "Month is 1-12. Returns double-float ms."
  (eng::%compose-tv year (1- month) day hour minute 0 0))

(defun %cron-normalize-fields (year month day hour minute)
  "Normalize overflow via ms round-trip; return same values as %cron-ms-to-fields."
  (%cron-ms-to-fields (%cron-fields-to-ms year month day hour minute)))

(defun cron-next-ms (expr from-ms)
  "Next matching UTC instant strictly after FROM-MS, or NIL within 8 years."
  (multiple-value-bind (year month day hour minute weekday)
      (%cron-ms-to-fields from-ms)
    (declare (ignore weekday))
    (incf minute)
    (let ((start-year year))
      (loop
        while (<= (- year start-year) 8)
        do (multiple-value-setq (year month day hour minute weekday)
             (%cron-normalize-fields year month day hour minute))
           (cond
             ((not (%cron-bit-set-p (cronx-months expr) month))
              (incf month)
              (setf day 1 hour 0 minute 0))
             (t
              (let* ((day-ok (%cron-bit-set-p (cronx-days expr) day))
                     (weekday-ok (%cron-bit-set-p (cronx-weekdays expr) weekday))
                     (day-match
                       (if (and (not (cronx-days-wildcard expr))
                                (not (cronx-weekdays-wildcard expr)))
                           (or day-ok weekday-ok)
                           (and day-ok weekday-ok))))
                (cond
                  ((not day-match)
                   (incf day)
                   (setf hour 0 minute 0))
                  ((not (%cron-bit-set-p (cronx-hours expr) hour))
                   (incf hour)
                   (setf minute 0))
                  ((not (%cron-bit-set-p (cronx-minutes expr) minute))
                   (incf minute))
                  (t
                   (return-from cron-next-ms
                     (%cron-fields-to-ms year month day hour minute))))))))))
  nil)

;;; --- JS errors ---------------------------------------------------------------

(defun %cron-type-error (message)
  (eng:throw-type-error message))

(defun %cron-os-not-available-error ()
  (eng:make-error-object
   :error-prototype "Error"
   "Clun.cron OS-level scheduling is not available: pure Common Lisp cannot register crontab, launchd, or Task Scheduler jobs without a purity exception (Phase 76). Use Clun.cron(schedule, handler) for in-process jobs."))

(defun %cron-rejected-promise (global reason)
  (eng:js-construct
   (eng:js-get global "Promise")
   (list
    (eng:make-native-function
     "" 2
     (lambda (this args)
       (declare (ignore this))
       (eng:js-call (eng:arg args 1) eng:+undefined+ (list reason))
       eng:+undefined+)))))

(defun %cron-require-string (value message)
  (unless (eng:js-string-p value)
    (%cron-type-error message))
  value)

;;; --- CronJob handle + scheduling --------------------------------------------

(defstruct (cron-job-state (:conc-name cjs-))
  expression
  (schedule "" :type string)
  handler
  global
  job-object
  (stopped nil)
  (refd t)
  timer-id
  (in-fire nil))

(defun %cron-clear-timer (state)
  (let ((id (cjs-timer-id state)))
    (when id
      (let ((clear (eng:js-get (cjs-global state) "clearTimeout")))
        (when (eng:callable-p clear)
          (ignore-errors (eng:js-call clear eng:+undefined+ (list id)))))
      (setf (cjs-timer-id state) nil))))

(defun %cron-arm (state &optional (from-ms nil))
  "Schedule the next fire strictly after FROM-MS (default: wall now)."
  (when (cjs-stopped state)
    (return-from %cron-arm nil))
  (%cron-clear-timer state)
  (let* ((g (cjs-global state))
         (now (or from-ms (%cron-wall-now-ms)))
         (next (cron-next-ms (cjs-expression state) now)))
    (unless next
      ;; Expression became impossible mid-flight — stop quietly.
      (setf (cjs-stopped state) t)
      (return-from %cron-arm nil))
    (let* ((delay (max 0d0 (- next now)))
           (setto (eng:js-get g "setTimeout")))
      (unless (eng:callable-p setto)
        (%cron-type-error "Clun.cron requires setTimeout"))
      (let ((cb (eng:make-native-function
                 "" 0
                 (lambda (this args)
                   (declare (ignore this args))
                   (%cron-fire state)))))
        (setf (cjs-timer-id state)
              (eng:js-call setto eng:+undefined+ (list cb delay)))
        ;; Honor ref/unref: if unref'd, unref the underlying timeout when possible.
        (unless (cjs-refd state)
          (let ((id (cjs-timer-id state)))
            (when (and (eng:js-object-p id) (eng:callable-p (eng:js-get id "unref")))
              (eng:js-call (eng:js-get id "unref") id '())))))
      t)))

(defun %cron-reschedule-after (state)
  (unless (cjs-stopped state)
    (%cron-arm state (%cron-wall-now-ms))))

(defun %cron-fire (state)
  (when (cjs-stopped state)
    (return-from %cron-fire eng:+undefined+))
  (setf (cjs-timer-id state) nil
        (cjs-in-fire state) t)
  (let ((handler (cjs-handler state))
        (job (cjs-job-object state))
        (result eng:+undefined+)
        (sync-error nil))
    (handler-case
        (setf result (eng:js-call handler job '()))
      (eng:js-condition (c)
        (setf sync-error (eng:js-condition-value c)))
      (error (c)
        (setf sync-error
              (eng:make-error-object
               :error-prototype "Error"
               (princ-to-string c)))))
    (setf (cjs-in-fire state) nil)
    (cond
      (sync-error
       ;; Match setTimeout semantics: surface as uncaught, but always re-arm first
       ;; so a throwing handler does not stop the schedule (Bun.cron guarantee).
       (%cron-reschedule-after state)
       (eng:throw-js-value sync-error))
      ((eng:js-promise-p result)
       ;; Attach then handlers so the next fire waits for settlement (no-overlap).
       (let ((on-done
               (eng:make-native-function
                "" 1
                (lambda (this args)
                  (declare (ignore this args))
                  (%cron-reschedule-after state)
                  eng:+undefined+)))
             (on-rej
               (eng:make-native-function
                "" 1
                (lambda (this args)
                  (declare (ignore this args))
                  ;; Rejection tracked by promise machinery; still reschedule.
                  (%cron-reschedule-after state)
                  eng:+undefined+)))
             (then (eng:js-get result "then")))
         (if (eng:callable-p then)
             (eng:js-call then result (list on-done on-rej))
             (%cron-reschedule-after state))))
      (t
       (%cron-reschedule-after state))))
  eng:+undefined+)

(defun %make-cron-job (global schedule-string expr handler)
  (let* ((state (make-cron-job-state
                 :expression expr
                 :schedule schedule-string
                 :handler handler
                 :global global))
         (job (eng:new-object)))
    (setf (cjs-job-object state) job)
    (eng:hidden-prop job "%cron-job%" state)
    (eng:install-getter job "cron"
      (lambda (this args)
        (declare (ignore this args))
        (cjs-schedule state)))
    (eng:install-method job "stop" 0
      (lambda (this args)
        (declare (ignore args))
        (unless (cjs-stopped state)
          (setf (cjs-stopped state) t)
          (%cron-clear-timer state))
        this))
    (eng:install-method job "ref" 0
      (lambda (this args)
        (declare (ignore args))
        (setf (cjs-refd state) t)
        (let ((id (cjs-timer-id state)))
          (when (and (eng:js-object-p id) (eng:callable-p (eng:js-get id "ref")))
            (eng:js-call (eng:js-get id "ref") id '())))
        this))
    (eng:install-method job "unref" 0
      (lambda (this args)
        (declare (ignore args))
        (setf (cjs-refd state) nil)
        (let ((id (cjs-timer-id state)))
          (when (and (eng:js-object-p id) (eng:callable-p (eng:js-get id "unref")))
            (eng:js-call (eng:js-get id "unref") id '())))
        this))
    ;; Eager-validate: must have a future occurrence.
    (unless (cron-next-ms expr (%cron-wall-now-ms))
      (%cron-type-error
       (format nil "Cron expression '~a' has no future occurrences" schedule-string)))
    (%cron-arm state)
    job))

;;; --- public API --------------------------------------------------------------

(defun %cron-parse-js (global args)
  (declare (ignore global))
  (let ((expr-arg (eng:arg args 0))
        (from-arg (eng:arg args 1)))
    (%cron-require-string expr-arg
                          "Clun.cron.parse() expects a string cron expression as the first argument")
    (let ((expr
            (handler-case (parse-cron-expression expr-arg)
              (cron-parse-error (c)
                (%cron-type-error (%cron-error-message (cron-parse-error-kind c)))))))
      (let ((from-ms
              (cond
                ((or (eng:js-undefined-p from-arg) (eng:js-null-p from-arg))
                 (%cron-wall-now-ms))
                ((eng:js-number-p from-arg)
                 (let ((n (eng:to-number from-arg)))
                   (when (or (eng:js-nan-p n) (eng:js-infinite-p n))
                     (%cron-type-error "Invalid date value"))
                   n))
                ((and (eng:js-object-p from-arg)
                      (eq (eng:js-object-class from-arg) :date))
                 (eng:to-number (eng:js-call (eng:js-get from-arg "getTime") from-arg '())))
                (t
                 (%cron-type-error
                  "Clun.cron.parse() expects the second argument to be a Date or number (ms since epoch)")))))
        (when (or (eng:js-nan-p from-ms) (eng:js-infinite-p from-ms))
          (%cron-type-error "Invalid date value"))
        (let ((next (cron-next-ms expr from-ms)))
          (if next
              (eng:js-construct (eng:js-get (eng:realm-global eng:*realm*) "Date")
                                (list next))
              eng:+null+))))))

(defun %cron-validate-title (title)
  (unless (and (plusp (length title))
               (every (lambda (c)
                        (or (alphanumericp c) (char= c #\-) (char= c #\_)))
                      title))
    (%cron-type-error
     "Cron title must contain only alphanumeric characters, hyphens, and underscores")))

(defun %cron-os-register (global args)
  "Fail-closed OS-level register after Bun-shaped validation."
  (let ((path (eng:arg args 0))
        (schedule (eng:arg args 1))
        (title (eng:arg args 2)))
    (%cron-require-string path "Clun.cron() expects a string path as the first argument")
    (%cron-require-string schedule "Clun.cron() expects a string schedule as the second argument")
    (%cron-require-string title "Clun.cron() expects a string title as the third argument")
    (%cron-validate-title title)
    (handler-case (parse-cron-expression schedule)
      (cron-parse-error (c)
        (%cron-type-error (%cron-error-message (cron-parse-error-kind c)))))
    (%cron-rejected-promise global (%cron-os-not-available-error))))

(defun %cron-os-remove (global args)
  (let ((title (eng:arg args 0)))
    (%cron-require-string title "Clun.cron.remove() expects a string title")
    (%cron-validate-title title)
    (%cron-rejected-promise global (%cron-os-not-available-error))))

(defun %cron-register (global args)
  "Dispatch Clun.cron(...): in-process (2 args, handler fn) or OS-level (3 strings)."
  (let ((n (length args))
        (a0 (eng:arg args 0))
        (a1 (eng:arg args 1))
        (a2 (eng:arg args 2)))
    (cond
      ;; In-process: schedule + callable handler
      ((and (>= n 2) (eng:callable-p a1))
       (%cron-require-string a0 "Clun.cron() expects a string cron expression")
       (let ((expr
               (handler-case (parse-cron-expression a0)
                 (cron-parse-error (c)
                   (%cron-type-error (%cron-error-message (cron-parse-error-kind c)))))))
         (%make-cron-job global a0 expr a1)))
      ;; OS-level: path, schedule, title
      ((>= n 3)
       (%cron-os-register global args))
      ((and (>= n 2) (eng:js-string-p a0) (eng:js-string-p a1) (eng:js-undefined-p a2))
       (%cron-type-error "Clun.cron() OS-level overload expects a title as the third argument"))
      ((zerop n)
       (%cron-type-error "Clun.cron() expects a string cron expression"))
      (t
       (%cron-type-error "Clun.cron() expects a string cron expression")))))

(defun make-clun-cron (global)
  "Build the callable Clun.cron function object with .parse and .remove."
  (let ((cron
          (eng:make-native-function
           "cron" 3
           (lambda (this args)
             (declare (ignore this))
             (%cron-register global args)))))
    (eng:data-prop
     cron "parse"
     (eng:make-native-function
      "parse" 1
      (lambda (this args)
        (declare (ignore this))
        (%cron-parse-js global args))))
    (eng:data-prop
     cron "remove"
     (eng:make-native-function
      "remove" 1
      (lambda (this args)
        (declare (ignore this))
        (%cron-os-remove global args))))
    cron))

(defun install-clun-cron (clun global)
  (eng:nonconfigurable-data-prop clun "cron" (make-clun-cron global))
  clun)
