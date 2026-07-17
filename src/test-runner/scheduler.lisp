;;;; scheduler.lisp — execute a file's test tree in Bun's exact hook order (PLAN.md
;;;; Phase 15, §3.6). Each hook/test body runs through eng:run-callback-to-settlement
;;;; (async-aware, timeout-enforced). Depth-first: beforeAll (outer→inner, lazily
;;;; before the first runnable test), per-test beforeEach outer→inner / afterEach
;;;; inner→outer, afterAll inner→outer. Streams results to the reporter.

(in-package :clun.test-runner)

(defconstant +test-u64-mask+ #xffffffffffffffff)

(defstruct (test-prng (:constructor %make-test-prng (state)))
  state)

(defun %test-u64 (value)
  (logand value +test-u64-mask+))

(defun %test-rotl64 (value count)
  (let ((word (%test-u64 value)))
    (%test-u64 (logior (ash word count) (ash word (- count 64))))))

(defun make-test-prng (seed)
  "Construct Bun's pinned splitmix64-seeded xoshiro256++ state."
  (let ((splitmix (%test-u64 seed))
        (state (make-array 4)))
    (dotimes (index 4)
      (setf splitmix (%test-u64 (+ splitmix #x9e3779b97f4a7c15)))
      (let ((value splitmix))
        (setf value (%test-u64 (* (logxor value (ash value -30))
                                   #xbf58476d1ce4e5b9))
              value (%test-u64 (* (logxor value (ash value -27))
                                   #x94d049bb133111eb))
              (aref state index) (%test-u64 (logxor value (ash value -31))))))
    (%make-test-prng state)))

(defun %test-prng-next (prng)
  (let* ((state (test-prng-state prng))
         (s0 (aref state 0))
         (s1 (aref state 1))
         (s2 (aref state 2))
         (s3 (aref state 3))
         (result (%test-u64 (+ (%test-rotl64 (+ s0 s3) 23) s0)))
         (shifted (%test-u64 (ash s1 17))))
    (setf s2 (%test-u64 (logxor s2 s0))
          s3 (%test-u64 (logxor s3 s1))
          s1 (%test-u64 (logxor s1 s2))
          s0 (%test-u64 (logxor s0 s3))
          s2 (%test-u64 (logxor s2 shifted))
          s3 (%test-rotl64 s3 45)
          (aref state 0) s0
          (aref state 1) s1
          (aref state 2) s2
          (aref state 3) s3)
    result))

(defun %test-prng-less-than (prng limit)
  "Bun's pinned Lemire reduction for a uniform integer below LIMIT."
  (let* ((value (%test-prng-next prng))
         (product (* value limit))
         (low (%test-u64 product))
         (threshold (mod (1+ +test-u64-mask+) limit)))
    (loop while (< low threshold)
          do (setf value (%test-prng-next prng)
                   product (* value limit)
                   low (%test-u64 product)))
    (ash product -64)))

(defun %shuffle-test-entries (entries prng)
  "Forward Fisher-Yates used by Bun inside each describe scope."
  (let* ((items (coerce entries 'vector))
         (length (length items)))
    (dotimes (index (max 0 (1- length)))
      (let ((other (+ index (%test-prng-less-than prng (- length index)))))
        (rotatef (aref items index) (aref items other))))
    (coerce items 'list)))

(defun %shuffle-test-files (files prng)
  "Descending Fisher-Yates used by Bun for the discovered file list."
  (let* ((items (coerce files 'vector))
         (length (length items)))
    (loop for index downfrom (1- length) above 0
          for other = (ash (* (%test-prng-next prng) (1+ index)) -64)
          do (rotatef (aref items index) (aref items other)))
    (coerce items 'list)))

(defstruct (run-cfg (:conc-name cfg-))
  (default-timeout 5000) (retry 0) (todo nil) (ci nil) (name-re nil) (bail nil)
  (snapshot nil) (random-state nil))

(defstruct (run-stats (:conc-name st-))
  (pass 0) (fail 0) (skip 0) (todo 0) (matched 0) (bailed nil)
  (snapshots 0) (snapshot-added 0) (snapshot-matched 0)
  (snapshot-updated 0) (snapshot-failed 0))

(defun %node-parent (n) (if (td-p n) (td-parent n) (tt-parent n)))
(defun %node-name (n) (if (td-p n) (td-name n) (tt-name n)))

(defun %describe-path (node)
  "Names from just-below-root down to and including NODE, ' > '-joined. The file root
(parent = nil) contributes nothing, so a NODE that IS the root yields \"\"."
  (let ((names '()) (n node))
    (loop while (and n (%node-parent n)) do
          (push (%node-name n) names)
          (setf n (%node-parent n)))
    (format nil "~{~a~^ > ~}" names)))

(defun %name-matches (cfg full-name)
  (let ((re (cfg-name-re cfg)))
    (or (null re)
        (eng:js-truthy (eng:js-call (eng:js-get re "test") re (list full-name))))))

(defun %callback-uses-done-p (fn args)
  (let ((arity (eng:js-get fn "length")))
    (and (eng:js-number-p arity) (> (truncate arity) (length args)))))

(defun %call-with-done (fn args)
  "Invoke FN with ARGS and a trailing done callback, returning a completion Promise.
When FN also returns a Promise, both that Promise and done() must complete."
  (multiple-value-bind (promise resolve reject) (eng:promise-and-caps)
    (let ((settled nil) (returned-known nil) (returned-promise-p nil)
          (returned-state :pending) (returned-value eng:+undefined+)
          (done-called nil) (done-error-p nil) (done-value eng:+undefined+))
      (labels ((settle (reject-p value)
                 (unless settled
                   (setf settled t)
                   (eng:js-call (if reject-p reject resolve) eng:+undefined+ (list value))))
               (maybe-settle ()
                 (when returned-known
                   (cond
                     (done-error-p (settle t done-value))
                     ((eq returned-state :rejected) (settle t returned-value))
                     ((and done-called
                           (or (not returned-promise-p)
                               (eq returned-state :fulfilled)))
                      (settle nil eng:+undefined+))))))
        (let* ((done
                 (eng:make-native-function "done" 1
                   (lambda (this done-args)
                     (declare (ignore this))
                     (unless done-called
                       (setf done-called t
                             done-value (eng:arg done-args 0)
                             done-error-p (not (eng:js-nullish-p done-value)))
                       (maybe-settle))
                     eng:+undefined+)))
               (returned (eng:js-call fn eng:+undefined+ (append args (list done)))))
          (setf returned-known t
                returned-promise-p (eng:js-promise-p returned))
          ;; Bun waits for both an async callback's Promise and done(). Attach both
          ;; reactions before deciding whether a synchronous done() completed the test.
          (if returned-promise-p
            (let ((on-fulfilled
                    (eng:make-native-function "" 1
                      (lambda (this values)
                        (declare (ignore this))
                        (setf returned-state :fulfilled
                              returned-value (eng:arg values 0))
                        (maybe-settle)
                        eng:+undefined+)))
                  (on-rejected
                    (eng:make-native-function "" 1
                      (lambda (this values)
                        (declare (ignore this))
                        (setf returned-state :rejected
                              returned-value (eng:arg values 0))
                        (maybe-settle)
                        eng:+undefined+))))
              (eng:js-call (eng:js-get returned "then") returned
                           (list on-fulfilled on-rejected)))
            (setf returned-state :fulfilled))
          (maybe-settle)
          promise)))))

(defun %run-test-callback (fn args realm timeout)
  (eng:run-callback-to-settlement
   (lambda ()
     (if (%callback-uses-done-p fn args)
         (%call-with-done fn args)
         (eng:js-call fn eng:+undefined+ args)))
   realm :timeout-ms timeout))

(defun %run-hooks (hooks realm timeout)
  "Run HOOKS (in registration order) to settlement; return NIL on success or the JS
  error value of the first that threw/rejected/timed-out."
  (dolist (fn (reverse hooks) nil)
    (multiple-value-bind (kind val)
        (%run-test-callback fn '() realm timeout)
      (case kind
        (:rejected (return val))
        (:timeout (return (%assertion-error (format nil "hook timed out after ~ams" timeout))))))))

(defun %chain (node)
  "The describe chain root→NODE's parent (for beforeEach/afterEach accumulation)."
  (let ((chain '()))
    (loop for d = (tt-parent node) then (td-parent d) while d do (push d chain))
    chain))

;;; --- test selection ---------------------------------------------------------

(defun %subtree-has-only (node)
  "True if NODE (describe) or any descendant is :only."
  (or (eq (td-mode node) :only)
      (some (lambda (c) (cond ((tt-p c) (eq (tt-mode c) :only))
                              ((td-p c) (%subtree-has-only c))))
            (td-children node))))

(defun %selected-p (test under-only has-only cfg)
  "Whether TEST should EXECUTE (vs be skipped), ignoring the -t filter."
  (and (not (eq (tt-mode test) :skip))
       (or (not has-only) under-only (eq (tt-mode test) :only))
       (or (not (eq (tt-mode test) :todo)) (cfg-todo cfg))))

;;; --- execution --------------------------------------------------------------

(defun %tree-active-only (node under-skip)
  "True if NODE's subtree has a .only test/describe that is NOT inside a .skip — so a
.only buried in a describe.skip does NOT activate only-mode (which would wrongly skip
every sibling)."
  (some (lambda (c)
          (cond ((tt-p c) (and (not under-skip) (eq (tt-mode c) :only)))
                ((td-p c) (let ((skip (or under-skip (eq (td-mode c) :skip))))
                            (or (and (not skip) (eq (td-mode c) :only))
                                (%tree-active-only c skip))))))
        (td-children node)))

(defun run-file-tree (ctx realm cfg stats report)
  "Execute CTX's tree under REALM. REPORT is (status full-name detail) -> prints a line.
Returns STATS (mutated). Honours .only (per-file), .skip/.todo, -t, timeouts, --bail."
  (let ((has-only (%tree-active-only (ctx-root ctx) nil)))
    (when (and has-only (cfg-ci cfg))
      (funcall report :fail "" "test.only is not allowed when CI=true")
      (incf (st-fail stats))
      (return-from run-file-tree stats))
    (%run-describe (ctx-root ctx) realm cfg stats report has-only nil nil)
    stats))

(defun %runnable-in-subtree (node has-only under-only cfg)
  "Does NODE (describe) contain any test that will actually EXECUTE?"
  (some (lambda (c)
          (cond ((tt-p c) (%selected-p c under-only has-only cfg))
                ((td-p c) (%runnable-in-subtree c has-only (or under-only (eq (td-mode c) :only)) cfg))))
        (td-children node)))

(defun %run-describe (node realm cfg stats report has-only under-only under-todo)
  "Run describe NODE. UNDER-ONLY and UNDER-TODO carry inherited suite modifiers."
  (let* ((uo (or under-only (eq (td-mode node) :only)))
         (skip-all (eq (td-mode node) :skip))
         (todo-all (or under-todo (eq (td-mode node) :todo)))
         (runs (and (not skip-all)
                    (or (cfg-todo cfg) (not todo-all))
                    (%runnable-in-subtree node has-only uo cfg))))
    (when skip-all                        ; describe.skip: every descendant test → (skip)
      (%skip-subtree node cfg stats report)
      (return-from %run-describe))
    (when (and todo-all (not (cfg-todo cfg)))
      (%todo-subtree node cfg stats report)
      (return-from %run-describe))
    (when (and runs (td-before-all node))
      (let ((err (%run-hooks (td-before-all node) realm (cfg-default-timeout cfg))))
        (when err
          ;; a beforeAll failure: report it + skip the subtree's tests, still run afterAll
          (funcall report :fail (format nil "~abeforeAll" (%prefix node)) (%err-detail err))
          (incf (st-fail stats))
          (%skip-subtree node cfg stats report)
          (%run-afterall node realm cfg stats report)
          (return-from %run-describe))))
    (dolist (child (%run-ordered-children node cfg))
      (when (st-bailed stats) (return))
      (cond
        ((td-p child)
         (%run-describe child realm cfg stats report has-only uo todo-all))
        ((tt-p child)
         (%run-test child realm cfg stats report has-only uo todo-all))))
    (when runs (%run-afterall node realm cfg stats report))))

(defun %run-afterall (node realm cfg stats report)
  "Run NODE's afterAll hooks; a throw/reject/timeout is a reported failure (symmetric
with beforeAll/afterEach — Bun counts a failing afterAll)."
  (when (td-after-all node)
    (let ((err (%run-hooks (td-after-all node) realm (cfg-default-timeout cfg))))
      (when err
        (funcall report :fail (format nil "~aafterAll" (%prefix node)) (%err-detail err))
        (incf (st-fail stats))
        (%maybe-bail stats cfg)))))

(defun %prefix (node)
  (let ((p (%describe-path node))) (if (string= p "") "" (concatenate 'string p " > "))))

(defun %run-ordered-children (node cfg)
  (let ((children (td-ordered-children node)))
    (if (cfg-random-state cfg)
        (%shuffle-test-entries children (cfg-random-state cfg))
        children)))

(defun %skip-subtree (node cfg stats report)
  (dolist (child (%run-ordered-children node cfg))
    (cond ((tt-p child) (funcall report :skip (%full-name child) nil) (incf (st-skip stats)))
          ((td-p child) (%skip-subtree child cfg stats report)))))

(defun %todo-subtree (node cfg stats report)
  "Report every descendant test as todo without running suite hooks or test bodies."
  (dolist (child (%run-ordered-children node cfg))
    (cond
      ((tt-p child)
       (if (eq (tt-mode child) :skip)
           (progn (funcall report :skip (%full-name child) nil) (incf (st-skip stats)))
           (progn (funcall report :todo (%full-name child) nil) (incf (st-todo stats)))))
      ((td-p child)
       (if (eq (td-mode child) :skip)
           (%skip-subtree child cfg stats report)
           (%todo-subtree child cfg stats report))))))

(defun %full-name (test)
  (let ((p (%describe-path (tt-parent test))))
    (if (string= p "") (tt-name test) (concatenate 'string p " > " (tt-name test)))))

(defun %err-detail (v)
  "A one-line-plus detail string for a thrown/rejected JS value."
  (if (and (eng:js-object-p v) (not (eng:js-undefined-p (eng:js-get v "message"))))
      (let ((name (eng:to-string (eng:js-get v "name"))) (msg (eng:to-string (eng:js-get v "message"))))
        (if (string= msg "") name (format nil "~a: ~a" name msg)))
      (eng:inspect-value v)))

(defun %run-test (test realm cfg stats report has-only under-only under-todo)
  (let* ((full (%full-name test))
         (mode (tt-mode test))
         (todo-mode (or under-todo (eq mode :todo))))
    ;; -t filter: a non-matching test is simply not counted/run (Bun) — but skip/only
    ;; still apply first.
    (cond
      ((eq mode :skip) (funcall report :skip full nil) (incf (st-skip stats)))
      ((and has-only (not under-only) (not (eq mode :only)))
       (funcall report :skip full nil) (incf (st-skip stats)))
      ((and todo-mode (not (cfg-todo cfg)))
       (funcall report :todo full nil) (incf (st-todo stats)))
      ((null (tt-fn test))                 ; test('name') with no body → todo
       (funcall report :todo full nil) (incf (st-todo stats)))
      ((not (%name-matches cfg full)) nil) ; filtered out by -t: no line, not counted
      (t
       (incf (st-matched stats))
       (multiple-value-bind (ok detail failure-kind assertions)
           (%execute-with-attempts test realm cfg todo-mode)
         (cond
           (todo-mode                     ; ran under --todo
            (if ok
                (progn (funcall report :fail full "this test is marked as todo but passed"
                                assertions)
                       (incf (st-fail stats)) (%maybe-bail stats cfg))
                (progn (funcall report :todo full nil assertions) (incf (st-todo stats)))))
           ((tt-failing test)
            (cond
              (ok
               (funcall report :fail full
                        "^ this test is marked as failing but it passed. Remove `.failing` if tested behavior now works"
                        assertions)
               (incf (st-fail stats))
               (%maybe-bail stats cfg))
              ((eq failure-kind :body)
               (funcall report :pass full nil assertions)
               (incf (st-pass stats)))
              (t
               (funcall report :fail full detail assertions)
               (incf (st-fail stats))
               (%maybe-bail stats cfg))))
           (ok (funcall report :pass full nil assertions) (incf (st-pass stats)))
           (t (funcall report :fail full detail assertions) (incf (st-fail stats))
              (%maybe-bail stats cfg))))))))

(defun %maybe-bail (stats cfg)
  (when (and (cfg-bail cfg) (>= (st-fail stats) (cfg-bail cfg)))
    (setf (st-bailed stats) t)))

(defun %attempt-passes-p (test todo-mode ok failure-kind)
  (if (and (tt-failing test) (not todo-mode))
      (and (not ok) (eq failure-kind :body))
      ok))

(defun %execute-with-attempts (test realm cfg todo-mode)
  "Execute TEST with its repeat or retry policy and return the representative result.
Retries stop on the first semantic pass. Repeats always run N+1 attempts and retain
the first semantic failure while still completing later attempts."
  (let ((repeats (and (not todo-mode) (tt-repeats test)))
        (retry (if todo-mode 0 (or (tt-retry test) (cfg-retry cfg)))))
    (if repeats
        (let ((failed nil) (failed-ok nil) (failed-detail nil) (failed-kind nil)
              (failed-assertions 0)
              (last-ok t) (last-detail nil) (last-kind nil) (last-assertions 0))
          (dotimes (attempt (1+ repeats))
            (declare (ignore attempt))
            (multiple-value-bind (ok detail failure-kind assertions) (%execute test realm cfg)
              (setf last-ok ok last-detail detail last-kind failure-kind
                    last-assertions assertions)
              (when (and (not failed)
                         (not (%attempt-passes-p test todo-mode ok failure-kind)))
                (setf failed t failed-ok ok
                      failed-detail detail failed-kind failure-kind
                      failed-assertions assertions))))
          (if failed
              (values failed-ok failed-detail failed-kind failed-assertions)
              (values last-ok last-detail last-kind last-assertions)))
        (let ((last-ok nil) (last-detail nil) (last-kind nil) (last-assertions 0))
          (dotimes (attempt (1+ retry)
                           (values last-ok last-detail last-kind last-assertions))
            (declare (ignore attempt))
            (multiple-value-bind (ok detail failure-kind assertions) (%execute test realm cfg)
              (setf last-ok ok last-detail detail last-kind failure-kind
                    last-assertions assertions)
              (when (%attempt-passes-p test todo-mode ok failure-kind)
                (return (values ok detail failure-kind assertions)))))))))

(defun %execute (test realm cfg)
  "Run beforeEach chain → the body → afterEach chain.
Returns (values ok detail failure-kind); FAILURE-KIND distinguishes an expected body
failure from framework failures that `test.failing` must not invert."
  (snapshot-reset-attempt (cfg-snapshot cfg) test)
  (let ((*test-assertions* 0) (*expected-assertions* nil) (*has-assertions* nil)
        (*active-test* test) (*test-finished-callbacks* '())
        (timeout (or (tt-timeout test) (cfg-default-timeout cfg)))
        (chain (%chain test)) (ok t) (detail nil) (failure-kind nil))
    ;; beforeEach outer→inner
    (block body
      (dolist (d chain)
        (let ((err (%run-hooks (td-before-each d) realm timeout)))
          (when err
            (setf ok nil detail (%err-detail err) failure-kind :hook)
            (return-from body))))
      ;; the test body
      (multiple-value-bind (kind val)
          (%run-test-callback (tt-fn test) (tt-args test) realm timeout)
        (case kind
          (:timeout
           (setf ok nil
                 detail (format nil "this test timed out after ~ams" timeout)
                 failure-kind :timeout))
          (:rejected
           (setf ok nil detail (%err-detail val) failure-kind :body))
          (:fulfilled
           ;; assertion-count expectations
           (cond
             ((and *expected-assertions* (/= *test-assertions* *expected-assertions*))
              (setf ok nil
                    detail (format nil "expect.assertions(~a) — but ~a assertion(s) ran"
                                   *expected-assertions* *test-assertions*)
                    failure-kind :assertion-contract))
             ((and *has-assertions* (zerop *test-assertions*))
              (setf ok nil
                    detail "expect.hasAssertions() — but no assertions ran"
                    failure-kind :assertion-contract)))))))
    ;; afterEach inner→outer (always runs)
    (dolist (d (reverse chain))
      (let ((err (%run-hooks (td-after-each d) realm timeout)))
        (when (and err ok)
          (setf ok nil detail (%err-detail err) failure-kind :hook))))
    ;; Per-test cleanup runs in registration order after every afterEach hook, even
    ;; when the body or an earlier hook failed.
    (let ((err (%run-hooks *test-finished-callbacks* realm timeout)))
      (when (and err ok)
        (setf ok nil detail (%err-detail err) failure-kind :hook)))
    (values ok detail failure-kind *test-assertions*)))
