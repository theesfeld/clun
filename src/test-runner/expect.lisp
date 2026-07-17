;;;; expect.lisp — expect() + the ~22 matchers (PLAN.md Phase 15, §3.6), on the shared
;;;; eng:js-deep-equal + eng:inspect-value. A failing matcher throws an AssertionError
;;;; (an Error with name patched) which the scheduler records as the test's failure.
;;;; .resolves/.rejects return real Promises (actual.then(...)) so the loop — already
;;;; driven by the scheduler for async tests — runs the assertion as a microtask (no
;;;; nested run-loop). Assertion counting backs expect.assertions/hasAssertions.

(in-package :clun.test-runner)

(defvar *test-assertions* 0 "expect() calls in the CURRENT test (reset per test).")
(defvar *expected-assertions* nil "expect.assertions(n): the required count, or NIL.")
(defvar *has-assertions* nil "expect.hasAssertions(): at least one assertion required.")
(defvar *expect-ctx* nil "the active test-context (for the cumulative expect() count).")

(defun %assertion-error (msg)
  (let ((e (eng:js-construct (eng:js-get (eng:realm-global eng:*realm*) "Error") (list msg))))
    (eng:js-set e "name" "AssertionError" nil)
    e))

(defun %fail (fmt &rest args)
  (eng:throw-js-value (%assertion-error (apply #'format nil fmt args))))

(defun %insp (v) (eng:inspect-value v))

(defun %svz (a b)
  "SameValueZero: strict-eq, plus NaN=NaN (and +0=-0, which strict-eq already gives)."
  (or (eng:js-strict-eq a b)
      (and (eng:js-number-p a) (eng:js-number-p b) (eng:js-nan-p a) (eng:js-nan-p b))))

(defun %num (v) (eng:to-number v))
(defun %nan (v) (or (eng:js-nan-p v) (not (eng:js-number-p v))))

(defun %length-of (v)
  "The .length of V as a CL integer (strings by code-unit length, objects/arrays via
the length property), or NIL when V has no numeric length."
  (cond ((eng:js-string-p v) (length (eng:to-string v)))
        ((eng:js-object-p v)
         (let ((l (eng:js-get v "length")))
           (and (eng:js-number-p l) (not (eng:js-nan-p l)) (truncate (%num l)))))
        (t nil)))

;;; --- toEqual (loose, undefined-insensitive) deep equality -------------------

(defun %own-string-keys (o)
  (remove-if-not #'stringp (eng:jm-own-property-keys o)))

(defun %loose-equal (a b) (%le a b (make-hash-table :test 'eq)))

(defun %le (a b seen)
  (cond
    ((%svz a b) t)
    ((not (and (eng:js-object-p a) (eng:js-object-p b))) nil)
    ((gethash a seen) (eq (gethash a seen) b))
    (t
     (setf (gethash a seen) b)
     (let ((ca (eng:js-object-class a)) (cb (eng:js-object-class b)))
       (cond
         ((and (eq ca :date) (eq cb :date))
          (= (%num (eng:js-call (eng:js-get a "getTime") a '()))
             (%num (eng:js-call (eng:js-get b "getTime") b '()))))
         ((and (eq ca :regexp) (eq cb :regexp))
          (and (string= (eng:to-string (eng:js-get a "source")) (eng:to-string (eng:js-get b "source")))
               (string= (eng:to-string (eng:js-get a "flags")) (eng:to-string (eng:js-get b "flags")))))
         ((and (eng:js-array-p a) (eng:js-array-p b))
          (let ((la (eng:array-length a)) (lb (eng:array-length b)))
            (and (= la lb)
                 (loop for i below la always
                       (%le (eng:js-getv a (princ-to-string i)) (eng:js-getv b (princ-to-string i)) seen)))))
         ((or (eng:js-array-p a) (eng:js-array-p b)) nil)
         (t
          ;; own enumerable string keys, ignoring keys whose value is undefined on both
          (let* ((ka (%own-string-keys a)) (kb (%own-string-keys b))
                 (keys (remove-duplicates (append ka kb) :test #'string=)))
            (loop for k in keys
                  for va = (eng:js-getv a k) for vb = (eng:js-getv b k)
                  always (or (and (eng:js-undefined-p va) (eng:js-undefined-p vb))
                             (%le va vb seen))))))))))

(defun %match-object (actual expected)
  "Recursive subset: every own key of EXPECTED matches (loose) in ACTUAL."
  (and (eng:js-object-p actual) (eng:js-object-p expected)
       (loop for k in (%own-string-keys expected)
             for ve = (eng:js-getv expected k) for va = (eng:js-getv actual k)
             always (cond ((and (eng:js-object-p ve) (eng:js-object-p va)
                                (not (eng:callable-p ve)))
                           (if (or (eng:js-array-p ve) (%plain-object-p ve))
                               (%match-object va ve)
                               (%le va ve (make-hash-table :test 'eq))))
                          (t (%le va ve (make-hash-table :test 'eq)))))))

(defun %plain-object-p (v) (and (eng:js-object-p v) (not (eng:js-array-p v)) (not (eng:callable-p v))))

;;; --- toThrow ---------------------------------------------------------------

(defun %call-catching (fn)
  "Call FN with no args; return (values threw-p thrown-value)."
  (handler-case (progn (eng:js-call fn eng:+undefined+ '()) (values nil nil))
    (eng:js-condition (c) (values t (eng:js-condition-value c)))))

(defun %thrown-message (v)
  (if (and (eng:js-object-p v) (not (eng:js-undefined-p (eng:js-get v "message"))))
      (eng:to-string (eng:js-get v "message"))
      (eng:to-string v)))

(defun %throw-matches (thrown expected)
  (cond
    ((eng:js-undefined-p expected) t)                       ; any throw
    ((eng:js-string-p expected)                             ; substring of message
     (search (eng:to-string expected) (%thrown-message thrown)))
    ((and (eng:js-object-p expected) (eq (eng:js-object-class expected) :regexp))
     (eng:js-truthy (eng:js-call (eng:js-get expected "test") expected (list (%thrown-message thrown)))))
    ((eng:callable-p expected)                              ; class: instanceof
     (eng:js-instanceof thrown expected))
    ((eng:js-object-p expected)                             ; { message } / Error instance
     (search (%thrown-message expected) (%thrown-message thrown)))
    (t t)))

;;; --- the matcher dispatch ---------------------------------------------------

(defparameter *matcher-names*
  '("toBe" "toEqual" "toStrictEqual" "toBeTruthy" "toBeFalsy" "toBeNull" "toBeUndefined"
    "toBeDefined" "toBeNaN" "toBeInstanceOf" "toBeGreaterThan" "toBeGreaterThanOrEqual"
    "toBeLessThan" "toBeLessThanOrEqual" "toBeCloseTo" "toMatch" "toContain" "toContainEqual"
    "toHaveLength" "toHaveProperty" "toMatchObject" "toThrow"
    "toHaveBeenCalled" "toHaveBeenCalledOnce" "toHaveBeenCalledTimes"
    "toHaveBeenCalledWith" "toHaveBeenLastCalledWith" "toHaveBeenNthCalledWith"
    "toHaveReturned" "toHaveReturnedTimes" "toHaveReturnedWith"
    "toHaveLastReturnedWith" "toHaveNthReturnedWith"
    "toBeCalled" "toBeCalledTimes" "toBeCalledWith" "lastCalledWith" "nthCalledWith"
    "toReturn" "toReturnTimes" "toReturnWith" "lastReturnedWith" "nthReturnedWith"))

(defun %canonical-mock-matcher (name)
  (or (cdr (assoc name
                  '(("toBeCalled" . "toHaveBeenCalled")
                    ("toBeCalledTimes" . "toHaveBeenCalledTimes")
                    ("toBeCalledWith" . "toHaveBeenCalledWith")
                    ("lastCalledWith" . "toHaveBeenLastCalledWith")
                    ("nthCalledWith" . "toHaveBeenNthCalledWith")
                    ("toReturn" . "toHaveReturned")
                    ("toReturnTimes" . "toHaveReturnedTimes")
                    ("toReturnWith" . "toHaveReturnedWith")
                    ("lastReturnedWith" . "toHaveLastReturnedWith")
                    ("nthReturnedWith" . "toHaveNthReturnedWith"))
                  :test #'string=))
      name))

(defun %mock-args-equal-p (actual expected)
  (and (= (length actual) (length expected))
       (loop for a in actual for e in expected
             always (%loose-equal a e))))

(defun %mock-required-count (name value &key positive)
  (unless (and (eng:js-number-p value) (not (eng:js-nan-p value))
               (= value (truncate value))
               (if positive (> value 0) (>= value 0)))
    (%fail "~a() requires a ~:[non-negative~;positive~] integer" name positive))
  (truncate value))

(defun %apply-mock-matcher (name actual negated args)
  (let* ((canonical (%canonical-mock-matcher name))
         (record (mock-record-for actual)))
    (unless record (%fail "expect(received).~a(...) requires a mock function" name))
    (let* ((calls (reverse (mock-calls record)))
           (results (reverse (mock-results record)))
           (returns (remove-if-not (lambda (entry) (eq (result-kind entry) :return)) results))
           (pass
             (cond
               ((string= canonical "toHaveBeenCalled") (plusp (length calls)))
               ((string= canonical "toHaveBeenCalledOnce") (= (length calls) 1))
               ((string= canonical "toHaveBeenCalledTimes")
                (= (length calls) (%mock-required-count canonical (eng:arg args 0))))
               ((string= canonical "toHaveBeenCalledWith")
                (some (lambda (call) (%mock-args-equal-p call args)) calls))
               ((string= canonical "toHaveBeenLastCalledWith")
                (and calls (%mock-args-equal-p (car (last calls)) args)))
               ((string= canonical "toHaveBeenNthCalledWith")
                (let ((n (%mock-required-count canonical (eng:arg args 0) :positive t)))
                  (and (<= n (length calls))
                       (%mock-args-equal-p (nth (1- n) calls) (rest args)))))
               ((string= canonical "toHaveReturned") (plusp (length returns)))
               ((string= canonical "toHaveReturnedTimes")
                (= (length returns) (%mock-required-count canonical (eng:arg args 0))))
               ((string= canonical "toHaveReturnedWith")
                (some (lambda (entry) (%loose-equal (result-value entry) (eng:arg args 0))) returns))
               ((string= canonical "toHaveLastReturnedWith")
                (and results
                     (let ((entry (car (last results))))
                       (and (eq (result-kind entry) :return)
                            (%loose-equal (result-value entry) (eng:arg args 0))))))
               ((string= canonical "toHaveNthReturnedWith")
                (let ((n (%mock-required-count canonical (eng:arg args 0) :positive t)))
                  (and (<= n (length results))
                       (let ((entry (nth (1- n) results)))
                         (and (eq (result-kind entry) :return)
                              (%loose-equal (result-value entry) (eng:arg args 1))))))))))
      (unless (if negated (not pass) pass)
        (%fail "expect(received).~:[~;not.~]~a(...)~%  calls: ~a, returns: ~a"
               negated name (length calls) (length returns)))
      eng:+undefined+)))

(defun %deep-fail (name actual expected)
  (%fail "expect(received).~a(expected)~%~%~a" name (line-diff (%insp expected) (%insp actual))))

(defun %apply-matcher (name actual negated args)
  "Run matcher NAME on ACTUAL with ARGS (a list of JS values). Throws an AssertionError
on the wrong outcome (honouring NEGATED). Returns undefined on success."
  (let ((e0 (eng:arg args 0)) (e1 (eng:arg args 1)))
    (labels ((chk (pass &optional msg)
               (let ((ok (if negated (not pass) pass)))
                 (unless ok
                   (if msg (%fail "~a" msg)
                       (%fail "expect(received).~:[~;not.~]~a(...)~%  received: ~a"
                              negated name (%insp actual))))))
             (num-cmp (op)
               (let ((na (%num actual)) (ne (%num e0)))
                 (chk (and (not (%nan na)) (not (%nan ne)) (funcall op na ne))
                      (format nil "expect(~a).~:[~;not.~]~a(~a)" (%insp actual) negated name (%insp e0))))))
      (cond
        ((member name '("toHaveBeenCalled" "toHaveBeenCalledOnce" "toHaveBeenCalledTimes"
                        "toHaveBeenCalledWith" "toHaveBeenLastCalledWith" "toHaveBeenNthCalledWith"
                        "toHaveReturned" "toHaveReturnedTimes" "toHaveReturnedWith"
                        "toHaveLastReturnedWith" "toHaveNthReturnedWith"
                        "toBeCalled" "toBeCalledTimes" "toBeCalledWith" "lastCalledWith"
                        "nthCalledWith" "toReturn" "toReturnTimes" "toReturnWith"
                        "lastReturnedWith" "nthReturnedWith") :test #'string=)
         (%apply-mock-matcher name actual negated args))
        ((string= name "toBe")
         (chk (eng:js-same-value actual e0)
              (unless negated (format nil "expect(received).toBe(expected)~%~%~a"
                                      (line-diff (%insp e0) (%insp actual))))))
        ((string= name "toEqual")
         (chk (%loose-equal actual e0) (unless negated (%deep-msg "toEqual" actual e0))))
        ((string= name "toStrictEqual")
         (chk (eng:js-deep-equal actual e0) (unless negated (%deep-msg "toStrictEqual" actual e0))))
        ((string= name "toBeTruthy") (chk (eng:js-truthy actual)))
        ((string= name "toBeFalsy") (chk (not (eng:js-truthy actual))))
        ((string= name "toBeNull") (chk (eng:js-null-p actual)))
        ((string= name "toBeUndefined") (chk (eng:js-undefined-p actual)))
        ((string= name "toBeDefined") (chk (not (eng:js-undefined-p actual))))
        ((string= name "toBeNaN") (chk (and (eng:js-number-p actual) (eng:js-nan-p actual))))
        ((string= name "toBeInstanceOf") (chk (and (eng:callable-p e0) (eng:js-instanceof actual e0))))
        ((string= name "toBeGreaterThan") (num-cmp #'>))
        ((string= name "toBeGreaterThanOrEqual") (num-cmp #'>=))
        ((string= name "toBeLessThan") (num-cmp #'<))
        ((string= name "toBeLessThanOrEqual") (num-cmp #'<=))
        ((string= name "toBeCloseTo")
         (let* ((na (%num actual)) (ne (%num e0))
                (p (if (eng:js-number-p e1) (truncate (%num e1)) 2))
                (tol (/ (expt 10d0 (- p)) 2)))
           (chk (cond ((or (%nan na) (%nan ne)) nil)
                      ;; equal infinities are "close" (Jest); Inf vs finite is not. Guard
                      ;; the subtraction — (- Inf Inf) traps FLOATING-POINT-INVALID.
                      ((or (eng:js-infinite-p na) (eng:js-infinite-p ne)) (= na ne))
                      (t (< (abs (- na ne)) tol)))
                (format nil "expect(~a).~:[~;not.~]toBeCloseTo(~a, ~a)" (%insp actual) negated (%insp e0) p))))
        ((string= name "toMatch")
         (let ((s (eng:to-string actual)))
           (chk (if (and (eng:js-object-p e0) (eq (eng:js-object-class e0) :regexp))
                    (eng:js-truthy (eng:js-call (eng:js-get e0 "test") e0 (list s)))
                    (and (search (eng:to-string e0) s) t)))))
        ((string= name "toContain")
         (chk (if (eng:js-string-p actual)
                  (and (search (eng:to-string e0) (eng:to-string actual)) t)
                  (and (eng:js-array-p actual)
                       (loop for i below (eng:array-length actual)
                             thereis (%svz (eng:js-getv actual (princ-to-string i)) e0))))))
        ((string= name "toContainEqual")
         (chk (and (eng:js-array-p actual)
                   (loop for i below (eng:array-length actual)
                         thereis (%loose-equal (eng:js-getv actual (princ-to-string i)) e0)))))
        ((string= name "toHaveLength")
         (let ((len (%length-of actual)))
           (chk (and len (= len (truncate (%num e0)))))))
        ((string= name "toHaveProperty") (%match-has-property actual e0 e1 args negated #'chk))
        ((string= name "toMatchObject") (chk (%match-object actual e0) (unless negated (%deep-msg "toMatchObject" actual e0))))
        ((string= name "toThrow")
         (unless (eng:callable-p actual)
           (%fail "expect(received).toThrow() — received value must be a function"))
         (multiple-value-bind (threw val) (%call-catching actual)
           (chk (and threw (%throw-matches val e0))
                (format nil "expect(received).~:[~;not.~]toThrow(~a)~%  ~:[did not throw~;threw: ~a~]"
                        negated (if (eng:js-undefined-p e0) "" (%insp e0)) threw (and threw (%thrown-message val))))))
        (t (%fail "unknown matcher ~a" name)))
      eng:+undefined+)))

(defun %deep-msg (name actual expected)
  (format nil "expect(received).~a(expected)~%~%~a" name (line-diff (%insp expected) (%insp actual))))

(defun %match-has-property (actual path value args negated chk)
  "toHaveProperty(path[, value]): PATH is a dotted string or an array of keys."
  (let* ((keys (if (eng:js-array-p path)
                   (mapcar #'eng:to-string (eng:array-like->list path))
                   (%split-dots (eng:to-string path))))
         (cur actual) (present t))
    (dolist (k keys)
      (if (and (eng:js-object-p cur) (eng:has-property cur k))
          (setf cur (eng:js-getv cur k))
          (progn (setf present nil) (return))))
    (funcall chk (if (>= (length args) 2)
                     (and present (%loose-equal cur value))
                     present)
             (unless negated (format nil "expect(received).toHaveProperty(~a~:[~;, ...~])"
                                     (%insp path) (>= (length args) 2))))))

(defun %split-dots (s)
  (let ((parts '()) (start 0))
    (dotimes (i (length s))
      (when (char= (char s i) #\.) (push (subseq s start i) parts) (setf start (1+ i))))
    (push (subseq s start) parts)
    (nreverse parts)))

;;; --- building the matcher object --------------------------------------------

(defun %make-matcher (actual negated)
  (let ((o (eng:new-object)))
    (dolist (nm *matcher-names*)
      (let ((name nm))
        (eng:install-method o name 3
          (lambda (this args) (declare (ignore this))
            (incf *test-assertions*)
            (%apply-matcher name actual negated args)))))
    (eng:install-getter o "not" (lambda (this args) (declare (ignore this args)) (%make-matcher actual (not negated))))
    (eng:install-getter o "resolves" (lambda (this args) (declare (ignore this args)) (%make-async-matcher actual negated nil)))
    (eng:install-getter o "rejects" (lambda (this args) (declare (ignore this args)) (%make-async-matcher actual negated t)))
    o))

(defun %make-async-matcher (actual negated reject-p)
  "expect(promise).resolves|rejects.MATCHER(...) -> a Promise (actual.then(...)) that
applies MATCHER to the fulfilled value (resolves) or rejection reason (rejects)."
  (let ((o (eng:new-object)))
    (dolist (nm *matcher-names*)
      (let ((name nm))
        (eng:install-method o name 3
          (lambda (this args) (declare (ignore this))
            (incf *test-assertions*)
            (let ((then (and (eng:js-object-p actual) (eng:js-get actual "then")))
                  (on-value (lambda (v)
                              ;; .resolves/.rejects.toThrow: the settled value IS the error
                              ;; to match (not a function to call); other matchers apply normally.
                              (if (string= name "toThrow")
                                  (let ((pass (%throw-matches v (eng:arg args 0))))
                                    (unless (if negated (not pass) pass)
                                      (%fail "expect(received).~:[~;not.~]toThrow(...) — ~a"
                                             negated (%thrown-message v))))
                                  (%apply-matcher name v negated args))
                              eng:+undefined+)))
              (unless (eng:callable-p then)
                (%fail "expect(received).~:[resolves~;rejects~] — received is not a Promise" reject-p))
              (eng:js-call then actual
                (if reject-p
                    (list (%fn "" 1 (lambda (th a) (declare (ignore th a))
                                      (%fail "expect(received).rejects.~a() — promise resolved" name)))
                          (%fn "" 1 (lambda (th a) (declare (ignore th)) (funcall on-value (eng:arg a 0)))))
                    (list (%fn "" 1 (lambda (th a) (declare (ignore th)) (funcall on-value (eng:arg a 0))))
                          (%fn "" 1 (lambda (th a) (declare (ignore th a))
                                      (%fail "expect(received).resolves.~a() — promise rejected" name)))))))))))
    o))

(defun install-expect (realm ctx)
  (let ((eng:*realm* realm) (g (eng:realm-global realm)))
    (let ((expect (eng:make-native-function "expect" 1
                    (lambda (this args) (declare (ignore this))
                      (incf (ctx-expect-calls ctx))
                      (%make-matcher (eng:arg args 0) nil)))))
      (eng:install-method expect "assertions" 1
        (lambda (this args) (declare (ignore this))
          (setf *expected-assertions* (truncate (%num (eng:arg args 0)))) eng:+undefined+))
      (eng:install-method expect "hasAssertions" 0
        (lambda (this args) (declare (ignore this args))
          (setf *has-assertions* t) eng:+undefined+))
      (eng:hidden-prop g "expect" expect))))
