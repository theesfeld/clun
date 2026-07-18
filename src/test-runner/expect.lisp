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

(defun %boxed-class-p (value class)
  (and (eng:js-object-p value) (eq (eng:js-object-class value) class)))

(defun %string-value-p (value)
  (or (eng:js-string-p value) (%boxed-class-p value :string)))

(defun %date-value-p (value)
  (%boxed-class-p value :date))

(defun %integer-number-p (value)
  (and (eng:js-number-p value) (eng:js-finite-p value)
       (= value (ftruncate value))))

(defun %integer-numeric-p (value)
  (or (eng:js-bigint-p value) (%integer-number-p value)))

(defun %round-away-from-zero (value)
  (if (minusp value)
      (ceiling (- value 0.5d0))
      (floor (+ value 0.5d0))))

(defun %bun-whitespace-p (character)
  "The ASCII whitespace set used by Bun's toEqualIgnoringWhitespace matcher."
  (and (member (char-code character) '(#x09 #x0a #x0b #x0c #x0d #x20)) t))

(defun %without-bun-whitespace (string)
  (remove-if #'%bun-whitespace-p string))

(defun %string-starts-with-p (string prefix)
  (let ((position (search prefix string)))
    (and position (zerop position))))

(defun %string-ends-with-p (string suffix)
  (let ((position (search suffix string :from-end t)))
    (and position (= position (- (length string) (length suffix))))))

(defun %non-overlapping-count (string substring)
  (loop with start = 0
        with count = 0
        for position = (search substring string :start2 start)
        while position
        do (incf count)
           (setf start (+ position (length substring)))
        finally (return count)))

(defun %asymmetric-matcher-p (value)
  (and (eng:js-object-p value)
       (eng:callable-p (eng:js-get value "asymmetricMatch"))))

(defun %asymmetric-match (matcher received)
  (let ((result
          (eng:js-call (eng:js-get matcher "asymmetricMatch") matcher (list received))))
    (if (eng:js-promise-p result) result (eng:js-truthy result))))

(defun %promise-map (promise function)
  (eng:js-call
   (eng:js-get promise "then") promise
   (list (%fn "" 1
           (lambda (this args)
             (declare (ignore this))
             (funcall function (eng:arg args 0)))))))

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
    ((%asymmetric-matcher-p b)
     (let ((result (%asymmetric-match b a)))
       (and (not (eng:js-promise-p result)) result)))
    ((%asymmetric-matcher-p a)
     (let ((result (%asymmetric-match a b)))
       (and (not (eng:js-promise-p result)) result)))
    ((not (and (eng:js-object-p a) (eng:js-object-p b))) nil)
    ((gethash a seen) (eq (gethash a seen) b))
    (t
     (setf (gethash a seen) b)
     (unwind-protect
          (let ((ca (eng:js-object-class a)) (cb (eng:js-object-class b)))
            (cond
              ((and (eq ca :date) (eq cb :date))
               (= (%num (eng:js-call (eng:js-get a "getTime") a '()))
                  (%num (eng:js-call (eng:js-get b "getTime") b '()))))
              ((and (eq ca :regexp) (eq cb :regexp))
               (and (string= (eng:to-string (eng:js-get a "source"))
                             (eng:to-string (eng:js-get b "source")))
                    (string= (eng:to-string (eng:js-get a "flags"))
                             (eng:to-string (eng:js-get b "flags")))))
              ((and (eng:js-array-p a) (eng:js-array-p b))
               (let ((la (eng:array-length a)) (lb (eng:array-length b)))
                 (and (= la lb)
                      (loop for i below la always
                            (%le (eng:js-getv a (princ-to-string i))
                                 (eng:js-getv b (princ-to-string i)) seen)))))
              ((or (eng:js-array-p a) (eng:js-array-p b)) nil)
              (t
               ;; own enumerable string keys, ignoring keys whose value is undefined on both
               (let* ((ka (%own-string-keys a)) (kb (%own-string-keys b))
                      (keys (remove-duplicates (append ka kb) :test #'string=)))
                 (loop for k in keys
                       for va = (eng:js-getv a k) for vb = (eng:js-getv b k)
                       always (or (and (eng:js-undefined-p va)
                                       (eng:js-undefined-p vb))
                                  (%le va vb seen)))))))
       (remhash a seen)))))

(defun %match-items-and (items function)
  "Evaluate match items in order, stopping before later async matchers on failure."
  (labels ((next-match (remaining)
             (if (null remaining)
                 t
                 (let ((result (funcall function (car remaining))))
                   (if (eng:js-promise-p result)
                       (%promise-map
                        result
                        (lambda (value)
                          (if (eng:js-truthy value)
                              (let ((next (next-match (cdr remaining))))
                                (if (eng:js-promise-p next)
                                    next
                                    (eng:js-boolean next)))
                              eng:+false+)))
                       (and result (next-match (cdr remaining))))))))
    (next-match items)))

(defun %loose-equal-result (a b)
  "%loose-equal with asynchronous asymmetricMatch results propagated as a Promise."
  (%ler a b (make-hash-table :test 'eq)))

(defun %ler-node (a b seen)
  (let ((ca (eng:js-object-class a)) (cb (eng:js-object-class b)))
    (cond
      ((and (eq ca :date) (eq cb :date))
       (= (%num (eng:js-call (eng:js-get a "getTime") a '()))
          (%num (eng:js-call (eng:js-get b "getTime") b '()))))
      ((and (eq ca :regexp) (eq cb :regexp))
       (and (string= (eng:to-string (eng:js-get a "source"))
                     (eng:to-string (eng:js-get b "source")))
            (string= (eng:to-string (eng:js-get a "flags"))
                     (eng:to-string (eng:js-get b "flags")))))
      ((and (eng:js-array-p a) (eng:js-array-p b))
       (let ((la (eng:array-length a)) (lb (eng:array-length b)))
         (and (= la lb)
              (%match-items-and
               (loop for i below la collect i)
               (lambda (i)
                 (%ler (eng:js-getv a (princ-to-string i))
                       (eng:js-getv b (princ-to-string i)) seen))))))
      ((or (eng:js-array-p a) (eng:js-array-p b)) nil)
      (t
       (let* ((ka (%own-string-keys a)) (kb (%own-string-keys b))
              (keys (remove-duplicates (append ka kb) :test #'string=)))
         (%match-items-and
          keys
          (lambda (key)
            (let ((va (eng:js-getv a key)) (vb (eng:js-getv b key)))
              (or (and (eng:js-undefined-p va)
                       (eng:js-undefined-p vb))
                  (%ler va vb seen))))))))))

(defun %ler (a b seen)
  (cond
    ((%svz a b) t)
    ((%asymmetric-matcher-p b) (%asymmetric-match b a))
    ((%asymmetric-matcher-p a) (%asymmetric-match a b))
    ((not (and (eng:js-object-p a) (eng:js-object-p b))) nil)
    ((gethash a seen) (eq (gethash a seen) b))
    (t
     (setf (gethash a seen) b)
     (let ((async-cleanup-p nil))
       (unwind-protect
            (let ((result (%ler-node a b seen)))
              (if (eng:js-promise-p result)
                  (let ((chained
                          (eng:js-call
                           (eng:js-get result "finally") result
                           (list (%fn "" 0
                                   (lambda (this args)
                                     (declare (ignore this args))
                                     (remhash a seen)
                                     eng:+undefined+))))))
                    (setf async-cleanup-p t)
                    chained)
                  result))
         (unless async-cleanup-p (remhash a seen)))))))

(defun %match-object (actual expected)
  "Recursive subset: every own key of EXPECTED matches (loose) in ACTUAL."
  (and (eng:js-object-p actual) (eng:js-object-p expected)
       (loop for k in (eng:jm-own-property-keys expected)
             for ve = (eng:js-getv expected k) for va = (eng:js-getv actual k)
             always (and (eng:has-property actual k)
                         (cond ((%asymmetric-matcher-p ve)
                                (%loose-equal va ve))
                               ((and (eng:js-object-p ve) (eng:js-object-p va)
                                     (not (eng:callable-p ve)))
                                (if (or (eng:js-array-p ve) (%plain-object-p ve))
                                    (%match-object va ve)
                                    (%le va ve (make-hash-table :test 'eq))))
                               (t (%le va ve (make-hash-table :test 'eq))))))))

(defun %plain-object-p (v) (and (eng:js-object-p v) (not (eng:js-array-p v)) (not (eng:callable-p v))))

;;; --- built-in asymmetric matchers ------------------------------------------

(defun %make-asymmetric (label negated predicate)
  (let ((matcher (eng:new-object)))
    (eng:install-method matcher "asymmetricMatch" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((matched (funcall predicate (eng:arg args 0))))
          (if (eng:js-promise-p matched)
              (%promise-map
               matched
               (lambda (value)
                 (eng:js-boolean
                  (if negated (not (eng:js-truthy value)) (eng:js-truthy value)))))
              (eng:js-boolean (if negated (not matched) matched))))))
    (eng:install-method matcher "toString" 0
      (lambda (this args) (declare (ignore this args))
        (if negated (concatenate 'string "Not" label) label)))
    (eng:install-method matcher "toAsymmetricMatcher" 0
      (lambda (this args) (declare (ignore this args))
        (if negated (concatenate 'string "Not" label) label)))
    matcher))

(defun %global-constructor (name)
  (eng:js-get (eng:realm-global eng:*realm*) name))

(defun %wrapper-kind-p (value kind)
  (and (eng:js-object-p value) (eq (eng:js-object-class value) kind)))

(defun %any-match-p (value constructor)
  (cond
    ((eq constructor (%global-constructor "String"))
     (or (eng:js-string-p value) (%wrapper-kind-p value :string)))
    ((eq constructor (%global-constructor "Number"))
     (or (eng:js-number-p value) (%wrapper-kind-p value :number)))
    ((eq constructor (%global-constructor "Function")) (eng:callable-p value))
    ((eq constructor (%global-constructor "Boolean"))
     (or (eng:js-boolean-p value) (%wrapper-kind-p value :boolean)))
    ((eq constructor (%global-constructor "BigInt"))
     (or (eng:js-bigint-p value) (%wrapper-kind-p value :bigint)))
    ((eq constructor (%global-constructor "Symbol"))
     (or (eng:js-symbol-p value) (%wrapper-kind-p value :symbol)))
    ((eq constructor (%global-constructor "Object"))
     (string= (eng:js-typeof value) "object"))
    ((eq constructor (%global-constructor "Array")) (eng:js-array-p value))
    ((eng:js-object-p value) (eng:js-instanceof value constructor))
    (t nil)))

(defun %asymmetric-any (constructor negated)
  (unless (eng:callable-p constructor)
    (eng:throw-type-error
     "any() expects to be passed a constructor function. Please pass one or use anything() to match any object."))
  (%make-asymmetric (format nil "Any<~a>" (eng:to-string (eng:js-get constructor "name")))
                    negated
                    (lambda (received) (%any-match-p received constructor))))

(defun %asymmetric-anything (negated)
  (%make-asymmetric "Anything" negated
                    (lambda (received) (not (eng:js-nullish-p received)))))

(defun %asymmetric-array-containing (sample negated)
  (unless (eng:js-array-p sample)
    (eng:throw-type-error "arrayContaining() expects an array"))
  (let ((expected (eng:array-like->list sample)))
    (%make-asymmetric
     "ArrayContaining" negated
     (lambda (received)
       (and (eng:js-array-p received)
            (let ((actual (eng:array-like->list received)))
              (every (lambda (wanted)
                       (some (lambda (value) (%loose-equal value wanted)) actual))
                     expected)))))))

(defun %object-containing-match-p (received sample)
  (and (eng:js-object-p received)
       (loop for key in (eng:jm-own-property-keys sample)
             always (and (eng:has-property received key)
                         (%loose-equal (eng:js-getv received key)
                                       (eng:js-getv sample key))))))

(defun %asymmetric-object-containing (sample negated)
  (unless (eng:js-object-p sample)
    (eng:throw-type-error "objectContaining() expects an object"))
  (%make-asymmetric "ObjectContaining" negated
                    (lambda (received) (%object-containing-match-p received sample))))

(defun %string-like-p (value)
  (or (eng:js-string-p value) (%wrapper-kind-p value :string)))

(defun %asymmetric-string-containing (sample negated)
  (unless (%string-like-p sample)
    (eng:throw-type-error "stringContaining() expects a string"))
  (let ((needle (eng:to-string sample)))
    (%make-asymmetric
     "StringContaining" negated
     (lambda (received)
       (and (eng:js-string-p received)
            (not (null (search needle (eng:to-string received)))))))))

(defun %regexp-p (value)
  (and (eng:js-object-p value) (eq (eng:js-object-class value) :regexp)))

(defun %asymmetric-string-matching (sample negated)
  (unless (or (%string-like-p sample) (%regexp-p sample))
    (eng:throw-type-error "stringMatching() expects a string or RegExp"))
  (let ((regexp (if (%regexp-p sample)
                    sample
                    (eng:js-construct (%global-constructor "RegExp")
                                      (list (eng:to-string sample))))))
    (%make-asymmetric
     "StringMatching" negated
     (lambda (received)
       (and (eng:js-string-p received)
            (progn
              (eng:js-set regexp "lastIndex" 0 nil)
              (eng:js-truthy
               (eng:js-call (eng:js-get regexp "test") regexp (list received)))))))))

(defun %close-to-match-p (received expected precision)
  (and (eng:js-number-p received)
       (cond
         ((or (eng:js-nan-p received) (eng:js-nan-p expected)) nil)
         ((or (eng:js-infinite-p received) (eng:js-infinite-p expected))
          (= received expected))
         (t (< (abs (- received expected))
               (/ (expt 10d0 (- precision)) 2))))))

(defun %asymmetric-close-to (sample precision-arg negated)
  (unless (eng:js-number-p sample)
    (eng:throw-type-error "closeTo() expects a number"))
  (unless (or (eng:js-undefined-p precision-arg) (eng:js-number-p precision-arg))
    (eng:throw-type-error "closeTo() precision expects a number"))
  (let ((precision (if (eng:js-undefined-p precision-arg)
                       2
                       (truncate (eng:to-number precision-arg)))))
    ;; Bun intentionally treats a non-number receiver as no match for both closeTo
    ;; and not.closeTo; negation applies only after the receiver type is valid.
    (%make-asymmetric (if negated "NotCloseTo" "CloseTo") nil
      (lambda (received)
        (and (eng:js-number-p received)
             (let ((matched (%close-to-match-p received sample precision)))
               (if negated (not matched) matched)))))))

;;; --- custom matcher protocol ------------------------------------------------

(defun %custom-print-function ()
  (%fn "" 1
    (lambda (this args)
      (declare (ignore this))
      (%insp (eng:arg args 0)))))

(defun %custom-identity-function ()
  (%fn "" 1
    (lambda (this args)
      (declare (ignore this))
      (eng:arg args 0))))

(defun %custom-matcher-context (negated &optional (promise ""))
  (let ((context (eng:new-object)) (utils (eng:new-object)))
    (eng:data-prop context "isNot" (eng:js-boolean negated))
    (eng:data-prop context "promise" promise)
    (eng:data-prop context "equals"
      (%fn "equals" 2
        (lambda (this args)
          (declare (ignore this))
          (eng:js-boolean (%loose-equal (eng:arg args 0) (eng:arg args 1))))))
    (eng:data-prop utils "printReceived" (%custom-print-function))
    (eng:data-prop utils "printExpected" (%custom-print-function))
    (eng:data-prop utils "stringify" (%custom-print-function))
    (eng:data-prop utils "RECEIVED_COLOR" (%custom-identity-function))
    (eng:data-prop utils "EXPECTED_COLOR" (%custom-identity-function))
    (eng:data-prop context "utils" utils)
    context))

(defun %invalid-custom-result (name result)
  (eng:throw-type-error
   (format nil
           "Unexpected return from matcher function `~a`. Matcher functions must return { message?: string | function, pass: boolean }; received ~a"
           name (%insp result))))

(defun %custom-result-pass (name result)
  (unless (and (eng:js-object-p result) (eng:has-property result "pass"))
    (%invalid-custom-result name result))
  (eng:js-truthy (eng:js-get result "pass")))

(defun %custom-failure-message (result)
  (let ((message (eng:js-get result "message")))
    (cond
      ((eng:callable-p message)
       (eng:to-string (eng:js-call message result '())))
      ((eng:js-string-p message) (eng:to-string message))
      ((eng:js-undefined-p message) "No message was specified for this matcher.")
      (t (eng:to-string message)))))

(defun %custom-pass-result (name function actual args negated)
  (let* ((context (%custom-matcher-context negated))
         (result (eng:js-call function context (cons actual args))))
    (if (eng:js-promise-p result)
        (%promise-map result (lambda (settled) (eng:js-boolean (%custom-result-pass name settled))))
        (%custom-result-pass name result))))

(defun %apply-custom-matcher (name function actual negated args &optional (promise ""))
  (let ((context (%custom-matcher-context negated promise)))
    (labels ((finish (result)
               (let* ((pass (%custom-result-pass name result))
                      (ok (if negated (not pass) pass)))
                 (unless ok (%fail "~a" (%custom-failure-message result)))
                 eng:+undefined+)))
      (let ((result (eng:js-call function context (cons actual args))))
        (if (eng:js-promise-p result)
            (%promise-map result #'finish)
            (finish result))))))

(defun %custom-asymmetric (name function args matcher-negated context-negated)
  (%make-asymmetric name matcher-negated
    (lambda (received)
      (%custom-pass-result name function received args context-negated))))

(defun %custom-definition-layers (object)
  "OBJECT and its non-Object prototype layers, farthest first for later override."
  (let* ((global-object (%global-constructor "Object"))
         (object-prototype (eng:js-get global-object "prototype"))
         (get-prototype (eng:js-get global-object "getPrototypeOf"))
         (layers '())
         (current object))
    (loop while (and (eng:js-object-p current) (not (eq current object-prototype))) do
      (push current layers)
      (setf current (eng:js-call get-prototype global-object (list current))))
    layers))

;;; --- toThrow ---------------------------------------------------------------

(defun %call-catching (fn &optional (args '()))
  "Call FN with ARGS; return (values threw-p result-or-thrown-value)."
  (handler-case (values nil (eng:js-call fn eng:+undefined+ args))
    (eng:js-condition (c) (values t (eng:js-condition-value c)))))

(defun %thrown-message (v)
  (if (and (eng:js-object-p v) (not (eng:js-undefined-p (eng:js-get v "message"))))
      (eng:to-string (eng:js-get v "message"))
      (eng:to-string v)))

(defun %throw-matches (thrown expected)
  (cond
    ((eng:js-undefined-p expected) t)                       ; any throw
    ((%asymmetric-matcher-p expected) (%asymmetric-match expected thrown))
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
    "toBeDefined" "toBeNaN" "toBeNil" "toBeTypeOf" "toBeBoolean" "toBeTrue" "toBeFalse"
    "toBeNumber" "toBeInteger" "toBeObject" "toBeFinite" "toBePositive" "toBeNegative"
    "toBeSymbol" "toBeFunction" "toBeDate" "toBeValidDate" "toBeString"
    "toBeArray" "toBeArrayOfSize" "toBeEven" "toBeOdd" "toSatisfy"
    "toBeInstanceOf" "toBeGreaterThan" "toBeGreaterThanOrEqual"
    "toBeLessThan" "toBeLessThanOrEqual" "toBeCloseTo" "toMatch" "toContain" "toContainEqual"
    "toBeWithin" "toEqualIgnoringWhitespace" "toInclude" "toIncludeRepeated"
    "toStartWith" "toEndWith"
    "toHaveLength" "toHaveProperty" "toMatchObject" "toMatchSnapshot"
    "toMatchInlineSnapshot" "toThrow"
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
    (unless record (%fail "Expected value must be a mock function"))
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

(defun %snapshot-property-object-p (value)
  (and (eng:js-object-p value) (not (eng:js-array-p value))
       (not (eng:callable-p value))))

(defun %snapshot-external-args (args)
  (case (length args)
    (0 (values nil ""))
    (1 (let ((first (first args)))
         (cond ((eng:js-string-p first) (values nil first))
               ((%snapshot-property-object-p first) (values first ""))
               (t (%fail "toMatchSnapshot() expects a hint string or property matcher object")))))
    (2 (let ((properties (first args)) (hint (second args)))
         (unless (%snapshot-property-object-p properties)
           (%fail "toMatchSnapshot() property matchers must be an object"))
         (unless (eng:js-string-p hint)
           (%fail "toMatchSnapshot() hint must be a string"))
         (values properties hint)))
    (t (%fail "toMatchSnapshot() accepts at most two arguments"))))

(defun %snapshot-inline-args (args)
  (case (length args)
    (0 (values nil nil))
    (1 (let ((first (first args)))
         (cond ((eng:js-string-p first) (values nil first))
               ((%snapshot-property-object-p first) (values first nil))
               (t (%fail "toMatchInlineSnapshot() expects a snapshot string or property matcher object")))))
    (2 (let ((properties (first args)) (expected (second args)))
         (unless (%snapshot-property-object-p properties)
           (%fail "toMatchInlineSnapshot() property matchers must be an object"))
         (unless (eng:js-string-p expected)
           (%fail "toMatchInlineSnapshot() snapshot must be a string"))
         (values properties expected)))
    (t (%fail "toMatchInlineSnapshot() accepts at most two arguments"))))

(defun %snapshot-check-properties (actual properties matcher-name)
  (when properties
    (unless (eng:js-object-p actual)
      (%fail "~a() property matchers require an object received value" matcher-name))
    (unless (%match-object actual properties)
      (%fail "expect(received).~a(propertyMatchers)~%~%~a"
             matcher-name (%deep-msg matcher-name actual properties)))))

(defun %snapshot-matcher-label (value)
  (when (%asymmetric-matcher-p value)
    (let ((to-asymmetric (eng:js-get value "toAsymmetricMatcher"))
          (to-string (eng:js-get value "toString")))
      (cond ((eng:callable-p to-asymmetric)
             (eng:to-string (eng:js-call to-asymmetric value '())))
            ((eng:callable-p to-string)
             (eng:to-string (eng:js-call to-string value '())))
            (t "AsymmetricMatcher")))))

(defun %apply-snapshot-matcher (name actual negated args ctx call-span)
  (when negated (%fail "Snapshot matchers cannot be used with .not"))
  (let ((state (ctx-snapshot ctx)))
    (handler-case
        (if (string= name "toMatchSnapshot")
            (multiple-value-bind (properties hint) (%snapshot-external-args args)
              (%snapshot-check-properties actual properties name)
              (let ((serialized
                      (snapshot-format-value actual properties #'%snapshot-matcher-label)))
                (multiple-value-bind (status expected key)
                    (snapshot-match-external state *active-test* hint serialized)
                  (case status
                    ((:matched :added :updated) eng:+undefined+)
                    (:mismatch
                     (%fail "Snapshot ~s did not match~%~%~a"
                            key (line-diff expected serialized)))
                    (:ci-denied
                     (%fail "Snapshot ~s is missing; new snapshots are disabled in CI" key))))))
            (multiple-value-bind (properties expected) (%snapshot-inline-args args)
              (%snapshot-check-properties actual properties name)
              (let ((serialized
                      (snapshot-format-value actual properties #'%snapshot-matcher-label)))
                (multiple-value-bind (status old)
                    (snapshot-match-inline state serialized expected (not (null properties))
                                           call-span)
                  (case status
                    ((:matched :added :updated) eng:+undefined+)
                    (:mismatch
                     (%fail "Inline snapshot did not match~%~%~a"
                            (line-diff old serialized)))
                    (:ci-denied
                     (%fail "Inline snapshot is missing; new snapshots are disabled in CI")))))))
      (snapshot-error (condition)
        (%fail "~a" (snapshot-error-message condition))))))

(defun %apply-matcher (name actual negated args ctx &optional call-span)
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
        ((member name '("toMatchSnapshot" "toMatchInlineSnapshot") :test #'string=)
         (%apply-snapshot-matcher name actual negated args ctx call-span))
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
         (let ((result (%loose-equal-result actual e0)))
           (if (eng:js-promise-p result)
               (return-from %apply-matcher
                 (%promise-map
                  result
                  (lambda (value)
                    (chk (eng:js-truthy value)
                         (unless negated (%deep-msg "toEqual" actual e0)))
                    eng:+undefined+)))
               (chk result (unless negated (%deep-msg "toEqual" actual e0))))))
        ((string= name "toStrictEqual")
         (chk (eng:js-deep-equal actual e0) (unless negated (%deep-msg "toStrictEqual" actual e0))))
        ((string= name "toBeTruthy") (chk (eng:js-truthy actual)))
        ((string= name "toBeFalsy") (chk (not (eng:js-truthy actual))))
        ((string= name "toBeNull") (chk (eng:js-null-p actual)))
        ((string= name "toBeUndefined") (chk (eng:js-undefined-p actual)))
        ((string= name "toBeDefined") (chk (not (eng:js-undefined-p actual))))
        ((string= name "toBeNaN") (chk (and (eng:js-number-p actual) (eng:js-nan-p actual))))
        ((string= name "toBeNil") (chk (eng:js-nullish-p actual)))
        ((string= name "toBeTypeOf")
         (unless (eng:js-string-p e0)
           (%fail "toBeTypeOf() requires a string argument"))
         (unless (member e0 '("function" "object" "bigint" "boolean" "number"
                              "string" "symbol" "undefined") :test #'string=)
           (%fail "toBeTypeOf() requires a valid type string argument ('function', 'object', 'bigint', 'boolean', 'number', 'string', 'symbol', 'undefined')"))
         (chk (string= (eng:js-typeof actual) e0)))
        ((string= name "toBeBoolean") (chk (eng:js-boolean-p actual)))
        ((string= name "toBeTrue") (chk (eq actual eng:+true+)))
        ((string= name "toBeFalse") (chk (eq actual eng:+false+)))
        ((string= name "toBeNumber") (chk (eng:js-number-p actual)))
        ((string= name "toBeInteger") (chk (%integer-number-p actual)))
        ((string= name "toBeObject") (chk (eng:js-object-p actual)))
        ((string= name "toBeFinite")
         (chk (and (eng:js-number-p actual) (eng:js-finite-p actual))))
        ((string= name "toBePositive")
         (chk (and (eng:js-number-p actual) (eng:js-finite-p actual)
                   (plusp (%round-away-from-zero actual)))))
        ((string= name "toBeNegative")
         (chk (and (eng:js-number-p actual) (eng:js-finite-p actual)
                   (minusp (%round-away-from-zero actual)))))
        ((string= name "toBeSymbol") (chk (eng:js-symbol-p actual)))
        ((string= name "toBeFunction") (chk (eng:callable-p actual)))
        ((string= name "toBeDate") (chk (%date-value-p actual)))
        ((string= name "toBeValidDate")
         (chk (and (%date-value-p actual)
                   (let ((time (eng:js-call (eng:js-get actual "getTime") actual '())))
                     (and (eng:js-number-p time) (not (eng:js-nan-p time)))))))
        ((string= name "toBeString") (chk (%string-value-p actual)))
        ((string= name "toBeArray") (chk (eng:js-array-p actual)))
        ((string= name "toBeArrayOfSize")
         (unless (%integer-number-p e0)
           (%fail "toBeArrayOfSize() requires the first argument to be a number"))
         (chk (and (eng:js-array-p actual) (= (eng:array-length actual) (truncate e0)))))
        ((string= name "toBeEven")
         (chk (and (%integer-numeric-p actual) (zerop (mod actual 2)))))
        ((string= name "toBeOdd")
         (chk (and (%integer-numeric-p actual) (= (mod actual 2) 1))))
        ((string= name "toSatisfy")
         (unless (eng:callable-p e0) (%fail "toSatisfy() argument must be a function"))
         (multiple-value-bind (threw result) (%call-catching e0 (list actual))
           (when threw (%fail "toSatisfy() predicate threw an exception"))
           (chk (eq result eng:+true+))))
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
        ((string= name "toBeWithin")
         (unless (eng:js-number-p e0)
           (%fail "toBeWithin() requires the first argument to be a number"))
         (unless (eng:js-number-p e1)
           (%fail "toBeWithin() requires the second argument to be a number"))
         (chk (and (eng:js-number-p actual) (>= actual e0) (< actual e1))))
        ((string= name "toEqualIgnoringWhitespace")
         (unless (eng:js-string-p e0)
           (%fail "toEqualIgnoringWhitespace() requires argument to be a string"))
         (chk (and (eng:js-string-p actual)
                   (string= (%without-bun-whitespace actual)
                            (%without-bun-whitespace e0)))))
        ((member name '("toInclude" "toStartWith" "toEndWith") :test #'string=)
         (unless (eng:js-string-p e0)
           (%fail "~a() requires the first argument to be a string" name))
         (chk (and (eng:js-string-p actual)
                   (cond ((string= name "toInclude") (and (search e0 actual) t))
                         ((string= name "toStartWith") (%string-starts-with-p actual e0))
                         (t (%string-ends-with-p actual e0))))))
        ((string= name "toIncludeRepeated")
         (unless (eng:js-string-p e0)
           (%fail "toIncludeRepeated() requires the first argument to be a string"))
         (unless (and (%integer-number-p e1) (not (eng:js-neg-zero-p e1)) (>= e1 0))
           (%fail "toIncludeRepeated() requires the second argument to be a number"))
         (when (zerop (length e0))
           (%fail "toIncludeRepeated() requires the first argument to be a non-empty string"))
         (unless (eng:js-string-p actual)
           (%fail "toIncludeRepeated() requires the expect(value) to be a string"))
         (chk (= (%non-overlapping-count actual e0) (truncate e1))))
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

(defun %make-matcher (actual negated ctx)
  (let ((o (eng:new-object)))
    (dolist (nm *matcher-names*)
      (let ((name nm))
        (eng:install-method o name 3
          (lambda (this args) (declare (ignore this))
            (incf *test-assertions*)
            (multiple-value-bind (start end) (eng:current-call-source-span)
              (%apply-matcher name actual negated args ctx
                              (and start end (list start end))))))))
    (maphash
     (lambda (name function)
       (eng:install-method o name 3
         (lambda (this args)
           (declare (ignore this))
           (incf *test-assertions*)
           (%apply-custom-matcher name function actual negated args))))
     (ctx-custom-matchers ctx))
    (eng:install-getter o "not"
      (lambda (this args)
        (declare (ignore this args))
        (%make-matcher actual (not negated) ctx)))
    (eng:install-getter o "resolves"
      (lambda (this args)
        (declare (ignore this args))
        (%make-async-matcher actual negated nil ctx)))
    (eng:install-getter o "rejects"
      (lambda (this args)
        (declare (ignore this args))
        (%make-async-matcher actual negated t ctx)))
    o))

(defun %make-async-matcher (actual negated reject-p ctx)
  "expect(promise).resolves|rejects.MATCHER(...) -> a Promise (actual.then(...)) that
applies MATCHER to the fulfilled value (resolves) or rejection reason (rejects)."
  (let ((o (eng:new-object)))
    (dolist (nm *matcher-names*)
      (let ((name nm))
        (eng:install-method o name 3
          (lambda (this args) (declare (ignore this))
            (incf *test-assertions*)
            (multiple-value-bind (call-start call-end) (eng:current-call-source-span)
              (let ((then (and (eng:js-object-p actual) (eng:js-get actual "then")))
                  (on-value (lambda (v)
                              ;; .resolves/.rejects.toThrow: the settled value IS the error
                              ;; to match (not a function to call); other matchers apply normally.
                              (if (string= name "toThrow")
                                  (let ((pass (%throw-matches v (eng:arg args 0))))
                                    (unless (if negated (not pass) pass)
                                      (%fail "expect(received).~:[~;not.~]toThrow(...) — ~a"
                                             negated (%thrown-message v))))
                                  (%apply-matcher name v negated args ctx
                                                  (and call-start call-end
                                                       (list call-start call-end))))
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
                                      (%fail "expect(received).resolves.~a() — promise rejected" name))))))))))))
    (maphash
     (lambda (name function)
       (eng:install-method o name 3
         (lambda (this args)
           (declare (ignore this))
           (incf *test-assertions*)
           (let ((then (and (eng:js-object-p actual) (eng:js-get actual "then"))))
             (unless (eng:callable-p then)
               (%fail "expect(received).~:[resolves~;rejects~] — received is not a Promise"
                      reject-p))
             (eng:js-call
              then actual
              (if reject-p
                  (list
                   (%fn "" 1
                     (lambda (th values)
                       (declare (ignore th values))
                       (%fail "expect(received).rejects.~a() — promise resolved" name)))
                   (%fn "" 1
                     (lambda (th values)
                       (declare (ignore th))
                       (%apply-custom-matcher name function (eng:arg values 0)
                                              negated args "rejects"))))
                  (list
                   (%fn "" 1
                     (lambda (th values)
                       (declare (ignore th))
                       (%apply-custom-matcher name function (eng:arg values 0)
                                              negated args "resolves")))
                   (%fn "" 1
                     (lambda (th values)
                       (declare (ignore th values))
                       (%fail "expect(received).resolves.~a() — promise rejected" name))))))))))
     (ctx-custom-matchers ctx))
    o))

(defun %settlement-asymmetric (matcher settlement negated)
  (%make-asymmetric
   (if (eq settlement :resolve) "ResolvesTo" "RejectsTo") negated
   (lambda (received)
     (if (eng:js-promise-p received)
         (let ((on-match
                 (%fn "" 1
                   (lambda (this args)
                     (declare (ignore this))
                     (let ((result (%asymmetric-match matcher (eng:arg args 0))))
                       (if (eng:js-promise-p result)
                           result
                           (eng:js-boolean result))))))
               (on-mismatch
                 (%fn "" 1
                   (lambda (this args)
                     (declare (ignore this args))
                     eng:+false+))))
           (eng:js-call
            (eng:js-get received "then") received
            (if (eq settlement :resolve)
                (list on-match on-mismatch)
                (list on-mismatch on-match))))
         nil))))

(defun %asymmetric-output (matcher settlement negated)
  (if settlement
      (%settlement-asymmetric matcher settlement negated)
      matcher))

(defun %install-asymmetric-family (target negated &key include-any ctx settlement)
  (let ((inner-negated (and negated (null settlement))))
    (labels ((output (matcher) (%asymmetric-output matcher settlement negated)))
      (when include-any
        (eng:install-method target "any" 1
          (lambda (this args) (declare (ignore this))
            (output (%asymmetric-any (eng:arg args 0) inner-negated))))
        (eng:install-method target "anything" 0
          (lambda (this args) (declare (ignore this args))
            (output (%asymmetric-anything inner-negated)))))
      (eng:install-method target "arrayContaining" 1
        (lambda (this args) (declare (ignore this))
          (output (%asymmetric-array-containing (eng:arg args 0) inner-negated))))
      (eng:install-method target "objectContaining" 1
        (lambda (this args) (declare (ignore this))
          (output (%asymmetric-object-containing (eng:arg args 0) inner-negated))))
      (eng:install-method target "stringContaining" 1
        (lambda (this args) (declare (ignore this))
          (output (%asymmetric-string-containing (eng:arg args 0) inner-negated))))
      (eng:install-method target "stringMatching" 1
        (lambda (this args) (declare (ignore this))
          (output (%asymmetric-string-matching (eng:arg args 0) inner-negated))))
      (eng:install-method target "closeTo" 2
        (lambda (this args) (declare (ignore this))
          (output (%asymmetric-close-to (eng:arg args 0) (eng:arg args 1)
                                        inner-negated))))
      (when ctx
        (maphash
         (lambda (name function)
           (eng:install-method target name 3
             (lambda (this args)
               (declare (ignore this))
               (output (%custom-asymmetric name function args inner-negated negated)))))
         (ctx-custom-matchers ctx)))
      target)))

(defun %install-settlement-getters (target negated ctx)
  (eng:install-getter target "resolvesTo"
    (lambda (this args)
      (declare (ignore this args))
      (%install-asymmetric-family (eng:new-object) negated
                                  :include-any (not negated) :ctx ctx
                                  :settlement :resolve)))
  (eng:install-getter target "rejectsTo"
    (lambda (this args)
      (declare (ignore this args))
      (%install-asymmetric-family (eng:new-object) negated
                                  :include-any (not negated) :ctx ctx
                                  :settlement :reject)))
  target)

(defun %custom-value-kind (value)
  (cond ((eng:js-undefined-p value) "undefined")
        ((eng:js-null-p value) "null")
        (t (eng:js-typeof value))))

(defun %install-custom-static (expect ctx name function)
  (eng:install-method expect name 3
    (lambda (this args)
      (declare (ignore this))
      (%custom-asymmetric name function args nil nil)))
  (setf (gethash name (ctx-custom-matchers ctx)) function))

(defun %extend-expect (expect ctx definitions)
  (unless (eng:js-object-p definitions)
    (eng:throw-type-error "expect.extend expects an object"))
  (let ((pending '()))
    (dolist (layer (%custom-definition-layers definitions))
      (dolist (key (eng:jm-own-property-keys layer))
        (when (and (stringp key) (not (string= key "constructor")))
          (let ((function (eng:js-getv layer key)))
            (unless (eng:callable-p function)
              (eng:throw-type-error
               (format nil
                       "expect.extend: `~a` is not a valid matcher. Must be a function, is ~s"
                       key (%custom-value-kind function))))
            (push (cons key function) pending)))))
    (dolist (entry (nreverse pending))
      (%install-custom-static expect ctx (car entry) (cdr entry))))
  eng:+undefined+)

(defun %expect-unreachable (this args)
  "Bun `expect.unreachable([message|Error])` — always fails the current test."
  (declare (ignore this))
  (let ((argument (eng:arg args 0)))
    (cond
      ((eng:js-undefined-p argument)
       (%fail "reached unreachable code"))
      ((and (eng:js-object-p argument)
            (eq (eng:js-object-class argument) :error))
       (eng:throw-js-value argument))
      (t (%fail "~a" (eng:to-string argument))))))

(defun %make-expect-type-of ()
  "Runtime no-op surface for Bun's type-level `expectTypeOf` chain.
Type assertions are compile-time only; Clun exposes a chainable object so files
that import `expectTypeOf` load and run without engine TypeScript types."
  (let ((chain (eng:new-object)))
    (labels ((install-noop (name)
               (eng:install-method chain name 1
                 (lambda (this args)
                   (declare (ignore this args))
                   chain)))
             (install-getter-noop (name)
               (eng:install-getter chain name
                 (lambda (this args)
                   (declare (ignore this args))
                   chain))))
      (dolist (name '("toEqualTypeOf" "toMatchTypeOf" "toMatchObjectType"
                      "toBeAny" "toBeUnknown" "toBeNever" "toBeFunction"
                      "toBeObject" "toBeArray" "toBeString" "toBeNumber"
                      "toBeBoolean" "toBeVoid" "toBeUndefined" "toBeNull"
                      "toBeNullable" "toBeOptional" "brands" "toHaveProperty"
                      "toBeCallableWith" "extract" "exclude" "parameter"))
        (install-noop name))
      ;; Chain properties used as `expectTypeOf(fn).parameters.toEqualTypeOf(...)`.
      (dolist (name '("not" "resolves" "rejects" "parameters" "returns"
                      "constructorParameters" "instance" "items" "flags"
                      "value" "thisParameter"))
        (install-getter-noop name))
      chain)))

(defun install-expect (realm ctx)
  (let ((eng:*realm* realm) (g (eng:realm-global realm)))
    (let ((expect (eng:make-native-function "expect" 1
                    (lambda (this args) (declare (ignore this))
                      (incf (ctx-expect-calls ctx))
                      (%make-matcher (eng:arg args 0) nil ctx)))))
      (eng:install-method expect "assertions" 1
        (lambda (this args) (declare (ignore this))
          (setf *expected-assertions* (truncate (%num (eng:arg args 0)))) eng:+undefined+))
      (eng:install-method expect "hasAssertions" 0
        (lambda (this args) (declare (ignore this args))
          (setf *has-assertions* t) eng:+undefined+))
      (eng:install-method expect "extend" 1
        (lambda (this args)
          (declare (ignore this))
          (%extend-expect expect ctx (eng:arg args 0))))
      (eng:install-method expect "unreachable" 1 #'%expect-unreachable)
      (%install-asymmetric-family expect nil :include-any t :ctx ctx)
      (%install-settlement-getters expect nil ctx)
      (eng:install-getter expect "not"
        (lambda (this args)
          (declare (ignore this args))
          (let ((namespace
                  (%install-asymmetric-family (eng:new-object) t :ctx ctx)))
            (%install-settlement-getters namespace t ctx))))
      (eng:hidden-prop g "expect" expect)
      (let ((expect-type-of
              (eng:make-native-function "expectTypeOf" 1
                (lambda (this args)
                  (declare (ignore this args))
                  (%make-expect-type-of)))))
        (eng:hidden-prop g "expectTypeOf" expect-type-of)
        (eng:data-prop expect "typeOf" expect-type-of))
      expect)))
