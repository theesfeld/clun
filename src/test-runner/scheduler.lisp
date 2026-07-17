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
  (snapshot nil) (random-state nil)
  ;; --concurrent makes inherit-mode tests concurrent; 0 max = unlimited.
  (default-concurrent nil) (max-concurrency 20))

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

(defun %invoke-test-callback (fn args)
  "Invoke FN without driving the event loop. Returns (values kind value-or-promise)
where KIND is :fulfilled, :rejected, or :pending (VALUE is the pending Promise)."
  (handler-case
      (let ((result (if (%callback-uses-done-p fn args)
                        (%call-with-done fn args)
                        (eng:js-call fn eng:+undefined+ args))))
        (cond
          ((and (eng:js-promise-p result)
                (eq (eng:js-promise-pstate result) :pending))
           (values :pending result))
          ((eng:js-promise-p result)
           (values (if (eq (eng:js-promise-pstate result) :rejected)
                       :rejected :fulfilled)
                   (eng:js-promise-value result)))
          (t (values :fulfilled result))))
    (eng:js-condition (c) (values :rejected (eng:js-condition-value c)))
    (error (c)
      (values :rejected
              (handler-case
                  (eng:js-construct
                   (eng:js-get (eng:realm-global eng:*realm*) "Error")
                   (list (format nil "~a" c)))
                (error () (format nil "~a" c)))))))

(defun %run-hooks (hooks realm timeout)
  "Run HOOKS (in registration order) to settlement; return NIL on success or the JS
  error value of the first that threw/rejected/timed-out."
  (dolist (fn (reverse hooks) nil)
    (multiple-value-bind (kind val)
        (%run-test-callback fn '() realm timeout)
      (case kind
        (:rejected (return val))
        (:timeout (return (%assertion-error (format nil "hook timed out after ~ams" timeout))))))))

(defun %test-runs-concurrent-p (test cfg)
  "Resolved concurrent flag for TEST: explicit yes/no, else nearest describe, else
`--concurrent` file default."
  (let ((mode (tt-concurrent test)))
    (ecase mode
      (:yes t)
      (:no nil)
      (:inherit
       (let ((parent (tt-parent test)))
         (loop while parent do
           (let ((dm (td-concurrent parent)))
             (ecase dm
               (:yes (return-from %test-runs-concurrent-p t))
               (:no (return-from %test-runs-concurrent-p nil))
               (:inherit (setf parent (td-parent parent)))))
           finally (return (and (cfg-default-concurrent cfg) t))))))))

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
Returns STATS (mutated). Honours .only (per-file), .skip/.todo, -t, timeouts, --bail,
test.concurrent / describe.concurrent / test.serial, and --max-concurrency."
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

;;; Plan entries are either:
;;;   (:barrier node hooks)  — beforeAll / afterAll run serially as a group break
;;;   (:test test under-only under-todo concurrent-p)
;;; Consecutive concurrent :test entries form one concurrent group (Bun Order.rs).

(defun %push-plan (acc kind &rest data)
  (vector-push-extend (cons kind data) acc)
  acc)

(defun %collect-plan (node has-only under-only under-todo cfg acc)
  "Depth-first plan mirroring Bun's Order generation: beforeAll/afterAll are serial
barriers; consecutive concurrent tests merge across nested describes."
  (let* ((uo (or under-only (eq (td-mode node) :only)))
         (skip-all (eq (td-mode node) :skip))
         (todo-all (or under-todo (eq (td-mode node) :todo)))
         (runs (and (not skip-all)
                    (or (cfg-todo cfg) (not todo-all))
                    (%runnable-in-subtree node has-only uo cfg))))
    (cond
      (skip-all
       (%plan-skip-subtree node cfg acc))
      ((and todo-all (not (cfg-todo cfg)))
       (%plan-todo-subtree node cfg acc))
      (t
       (when (and runs (td-before-all node))
         (%push-plan acc :before-all node (td-before-all node)))
       (dolist (child (%run-ordered-children node cfg))
         (cond
           ((td-p child)
            (%collect-plan child has-only uo todo-all cfg acc))
           ((tt-p child)
            (%push-plan acc :test child uo todo-all
                        (%test-runs-concurrent-p child cfg)))))
       (when (and runs (td-after-all node))
         (%push-plan acc :after-all node (td-after-all node)))))
    acc))

(defun %plan-skip-subtree (node cfg acc)
  (dolist (child (%run-ordered-children node cfg))
    (cond ((tt-p child) (%push-plan acc :skip-test child))
          ((td-p child) (%plan-skip-subtree child cfg acc)))))

(defun %plan-todo-subtree (node cfg acc)
  (dolist (child (%run-ordered-children node cfg))
    (cond
      ((tt-p child)
       (if (eq (tt-mode child) :skip)
           (%push-plan acc :skip-test child)
           (%push-plan acc :todo-test child)))
      ((td-p child)
       (if (eq (td-mode child) :skip)
           (%plan-skip-subtree child cfg acc)
           (%plan-todo-subtree child cfg acc))))))

(defun %group-plan (plan)
  "Partition PLAN into serial barriers and concurrent test groups.
Each group is either a single non-concurrent entry or a list of consecutive concurrent
:test entries."
  (let ((groups '()) (batch '()))
    (labels ((flush ()
               (when batch
                 (push (cons :concurrent (nreverse batch)) groups)
                 (setf batch '()))))
      (dotimes (i (length plan))
        (let ((entry (aref plan i)))
          (case (car entry)
            (:test
             (if (fifth entry)          ; concurrent-p
                 (push entry batch)
                 (progn (flush) (push (cons :serial (list entry)) groups))))
            (otherwise
             (flush)
             (push (cons :serial (list entry)) groups)))))
      (flush)
      (nreverse groups))))

(defvar *before-all-failed-nodes* nil
  "Describe nodes whose beforeAll failed; descendant tests are skipped until afterAll.")

(defun %under-failed-before-all-p (node)
  (let ((n node))
    (loop while n do
      (when (member n *before-all-failed-nodes* :test #'eq)
        (return t))
      (setf n (%node-parent n)))))

(defun %run-describe (node realm cfg stats report has-only under-only under-todo)
  "Run describe NODE via a Bun-shaped concurrent plan (file root and nested suites)."
  (declare (ignore under-only under-todo))
  (let* ((*before-all-failed-nodes* '())
         (acc (make-array 32 :adjustable t :fill-pointer 0))
         (plan (%collect-plan node has-only nil nil cfg acc))
         (groups (%group-plan plan)))
    (dolist (group groups)
      (when (eq (st-bailed stats) t) (return))
      (destructuring-bind (kind . entries) group
        (ecase kind
          (:serial
           (dolist (entry entries)
             (when (eq (st-bailed stats) t) (return))
             (%run-plan-entry entry realm cfg stats report has-only)))
          (:concurrent
           (%run-concurrent-group entries realm cfg stats report has-only)))))))

(defun %run-plan-entry (entry realm cfg stats report has-only)
  (case (car entry)
    (:before-all
     (destructuring-bind (node hooks) (cdr entry)
       (if (%under-failed-before-all-p node)
           nil
           (let ((err (%run-hooks hooks realm (cfg-default-timeout cfg))))
             (when err
               (funcall report :fail (format nil "~abeforeAll" (%prefix node))
                        (%err-detail err))
               (incf (st-fail stats))
               (push node *before-all-failed-nodes*)
               (%maybe-bail stats cfg))))))
    (:after-all
     (destructuring-bind (node hooks) (cdr entry)
       (setf *before-all-failed-nodes*
             (remove node *before-all-failed-nodes* :test #'eq))
       (unless (and (eq (st-bailed stats) t)
                    (not (%under-failed-before-all-p node)))
         (let ((err (%run-hooks hooks realm (cfg-default-timeout cfg))))
           (when err
             (funcall report :fail (format nil "~aafterAll" (%prefix node))
                      (%err-detail err))
             (incf (st-fail stats))
             (%maybe-bail stats cfg))))))
    (:skip-test
     (let ((test (second entry)))
       (funcall report :skip (%full-name test) nil)
       (incf (st-skip stats))))
    (:todo-test
     (let ((test (second entry)))
       (funcall report :todo (%full-name test) nil)
       (incf (st-todo stats))))
    (:test
     (destructuring-bind (test under-only under-todo concurrent-p) (cdr entry)
       (declare (ignore concurrent-p))
       (if (%under-failed-before-all-p test)
           (progn (funcall report :skip (%full-name test) nil)
                  (incf (st-skip stats)))
           (%run-test test realm cfg stats report has-only under-only under-todo))))
    (otherwise nil)))

;;; --- concurrent group execution ---------------------------------------------

;;; --- concurrent group execution ---------------------------------------------

(defstruct (cslot (:conc-name cslot-))
  test under-only under-todo
  (phase :start)
  (ok t) detail failure-kind
  (assertions 0) (expected-assertions nil) (has-assertions nil)
  (finished-callbacks '())
  (timeout nil)
  (pending-promise nil)
  (chain nil)
  (index 0)
  (started nil)
  (reported nil)
  (deadline-ms nil))

(defun %slot-bind (slot thunk)
  "Run THUNK with dynamic test-runner state rebound for SLOT."
  (let ((*active-test* (cslot-test slot))
        (*test-assertions* (cslot-assertions slot))
        (*expected-assertions* (cslot-expected-assertions slot))
        (*has-assertions* (cslot-has-assertions slot))
        (*test-finished-callbacks* (cslot-finished-callbacks slot)))
    (unwind-protect (funcall thunk)
      (setf (cslot-assertions slot) *test-assertions*
            (cslot-expected-assertions slot) *expected-assertions*
            (cslot-has-assertions slot) *has-assertions*
            (cslot-finished-callbacks slot) *test-finished-callbacks*))))

(defun %slot-fail (slot detail kind)
  (setf (cslot-ok slot) nil
        (cslot-detail slot) detail
        (cslot-failure-kind slot) kind))

(defun %now-ms ()
  (values (floor (get-internal-real-time)
                 (floor internal-time-units-per-second 1000))))

(defun %run-concurrent-group (entries realm cfg stats report has-only)
  "Run consecutive concurrent :test plan entries with overlapping async settlement."
  (let ((runnable '())
        (maxc (cfg-max-concurrency cfg)))
    (dolist (entry entries)
      (destructuring-bind (test under-only under-todo concurrent-p) (cdr entry)
        (declare (ignore concurrent-p))
        (cond
          ((%under-failed-before-all-p test)
           (funcall report :skip (%full-name test) nil)
           (incf (st-skip stats)))
          (t
           (let ((full (%full-name test))
                 (mode (tt-mode test))
                 (todo-mode (or under-todo (eq (tt-mode test) :todo))))
             (cond
               ((eq mode :skip)
                (funcall report :skip full nil) (incf (st-skip stats)))
               ((and has-only (not under-only) (not (eq mode :only)))
                (funcall report :skip full nil) (incf (st-skip stats)))
               ((and todo-mode (not (cfg-todo cfg)))
                (funcall report :todo full nil) (incf (st-todo stats)))
               ((null (tt-fn test))
                (funcall report :todo full nil) (incf (st-todo stats)))
               ((not (%name-matches cfg full)) nil)
               (t
                (incf (st-matched stats))
                (push (make-cslot :test test
                                  :under-only under-only
                                  :under-todo under-todo
                                  :timeout (or (tt-timeout test)
                                               (cfg-default-timeout cfg))
                                  :chain (%chain test)
                                  :index (length runnable))
                      runnable))))))))
    (setf runnable (nreverse runnable))
    (when (null runnable)
      (return-from %run-concurrent-group))
    ;; Retries/repeats/todo/failing fall back to the serial multi-attempt path.
    (when (or (= (length runnable) 1)
              (some (lambda (s)
                      (or (tt-repeats (cslot-test s))
                          (tt-retry (cslot-test s))
                          (plusp (cfg-retry cfg))
                          (cslot-under-todo s)
                          (tt-failing (cslot-test s))))
                    runnable))
      (dolist (s runnable)
        (when (eq (st-bailed stats) t) (return))
        (%run-test (cslot-test s) realm cfg stats report has-only
                   (cslot-under-only s) (cslot-under-todo s)))
      (return-from %run-concurrent-group))
    (%execute-concurrent-slots runnable realm cfg stats report maxc)))

(defun %report-concurrent-slot (slot cfg stats report)
  (when (cslot-reported slot)
    (return-from %report-concurrent-slot))
  (setf (cslot-reported slot) t)
  (let ((full (%full-name (cslot-test slot)))
        (ok (cslot-ok slot))
        (detail (cslot-detail slot))
        (assertions (cslot-assertions slot)))
    (if ok
        (progn (funcall report :pass full nil assertions) (incf (st-pass stats)))
        (progn (funcall report :fail full detail assertions)
               (incf (st-fail stats))
               (%maybe-bail stats cfg)))))

(defun %attach-promise-continue (promise slot cont)
  "When PROMISE settles, rebind SLOT state and call CONT with (ok value)."
  (let ((settled nil))
    (flet ((make-reaction (ok-p)
             (eng:make-native-function
              "" 1
              (lambda (this args)
                (declare (ignore this))
                (unless settled
                  (setf settled t)
                  (%slot-bind slot
                              (lambda ()
                                (funcall cont ok-p (eng:arg args 0)))))
                eng:+undefined+))))
      (eng:js-call (eng:js-get promise "then") promise
                   (list (make-reaction t) (make-reaction nil))))))

(defun %run-hooks-async (hooks slot cont)
  "Run HOOKS in registration order; CONT receives NIL or an error value."
  (let ((remaining (copy-list hooks)))
    (labels ((advance ()
               (if (null remaining)
                   (funcall cont nil)
                   (let ((fn (pop remaining)))
                     (%slot-bind
                      slot
                      (lambda ()
                        (multiple-value-bind (kind val)
                            (%invoke-test-callback fn '())
                          (ecase kind
                            (:fulfilled (advance))
                            (:rejected (funcall cont val))
                            (:pending
                             (setf (cslot-pending-promise slot) val)
                             (%attach-promise-continue
                              val slot
                              (lambda (ok value)
                                (setf (cslot-pending-promise slot) nil)
                                (if ok
                                    (advance)
                                    (funcall cont value)))))))))))))
      (advance))))

(defun %advance-slot (slot realm on-progress)
  "Advance SLOT through beforeEach → body → afterEach → onTestFinished."
  (let ((eng:*realm* realm))
    (labels
        ((done ()
           (when (and (cslot-ok slot)
                      (cslot-expected-assertions slot)
                      (/= (cslot-assertions slot)
                          (cslot-expected-assertions slot)))
             (%slot-fail slot
                         (format nil "expect.assertions(~a) — but ~a assertion(s) ran"
                                 (cslot-expected-assertions slot)
                                 (cslot-assertions slot))
                         :assertion-contract))
           (when (and (cslot-ok slot)
                      (cslot-has-assertions slot)
                      (zerop (cslot-assertions slot)))
             (%slot-fail slot
                         "expect.hasAssertions() — but no assertions ran"
                         :assertion-contract))
           (setf (cslot-phase slot) :done)
           (funcall on-progress slot))
         (after-hooks ()
           (let ((cbs (reverse (cslot-finished-callbacks slot))))
             (setf (cslot-finished-callbacks slot) '())
             (if cbs
                 (%run-hooks-async cbs slot
                                   (lambda (err)
                                     (when err
                                       (%slot-fail slot (%err-detail err) :hook))
                                     (done)))
                 (done))))
         (after-body ()
           (let ((after
                   (mapcan (lambda (d) (reverse (td-after-each d)))
                           (reverse (cslot-chain slot)))))
             (if after
                 (%run-hooks-async after slot
                                   (lambda (err)
                                     (when err
                                       (%slot-fail slot (%err-detail err) :hook))
                                     (after-hooks)))
                 (after-hooks))))
         (run-body ()
           (%slot-bind
            slot
            (lambda ()
              (multiple-value-bind (kind val)
                  (%invoke-test-callback (tt-fn (cslot-test slot))
                                         (tt-args (cslot-test slot)))
                (ecase kind
                  (:fulfilled (after-body))
                  (:rejected
                   (%slot-fail slot (%err-detail val) :body)
                   (after-body))
                  (:pending
                   (setf (cslot-pending-promise slot) val)
                   (%attach-promise-continue
                    val slot
                    (lambda (ok value)
                      (setf (cslot-pending-promise slot) nil)
                      (unless ok
                        (%slot-fail slot (%err-detail value) :body))
                      (after-body))))))))))
      (let ((before
              (mapcan (lambda (d) (reverse (td-before-each d)))
                      (cslot-chain slot))))
        (if before
            (%run-hooks-async before slot
                              (lambda (err)
                                (when err
                                  (%slot-fail slot (%err-detail err) :hook))
                                (if (cslot-ok slot)
                                    (run-body)
                                    (after-body))))
            (run-body))))))

(defun %execute-concurrent-slots (slots realm cfg stats report maxc)
  "Start concurrent SLOTS (up to MAXC, 0 = unlimited) and drive the realm loop."
  (let* ((eng:*realm* realm)
         (n (length slots))
         (next 0)
         (active 0)
         (eloop (eng:current-loop)))
    (labels
        ((can-start-p ()
           (and (< next n)
                (or (zerop maxc) (< active maxc))))
         (start-more ()
           (loop while (can-start-p) do
             (let ((slot (nth next slots)))
               (incf next)
               (incf active)
               (setf (cslot-started slot) t
                     (cslot-deadline-ms slot)
                     (+ (%now-ms) (cslot-timeout slot)))
               (snapshot-reset-attempt (cfg-snapshot cfg) (cslot-test slot))
               (%advance-slot slot realm #'on-slot-progress))))
         (on-slot-progress (slot)
           (when (eq (cslot-phase slot) :done)
             (decf active)
             (%report-concurrent-slot slot cfg stats report)
             (start-more)
             (when (and (zerop active) (>= next n) eloop)
               (lp:loop-stop eloop))))
         (check-timeouts ()
           (let ((now (%now-ms)))
             (dolist (slot slots)
               (when (and (cslot-started slot)
                          (not (eq (cslot-phase slot) :done))
                          (cslot-deadline-ms slot)
                          (>= now (cslot-deadline-ms slot)))
                 (setf (cslot-pending-promise slot) nil)
                 (%slot-fail slot
                             (format nil "this test timed out after ~ams"
                                     (cslot-timeout slot))
                             :timeout)
                 (setf (cslot-phase slot) :done)
                 (on-slot-progress slot))))))
      (start-more)
      (when (every (lambda (s) (eq (cslot-phase s) :done)) slots)
        (return-from %execute-concurrent-slots))
      (let ((timer
              (and eloop
                   (lp:set-timer
                    eloop 5
                    (lambda ()
                      (check-timeouts)
                      (when (and (zerop active) (>= next n))
                        (lp:loop-stop eloop)))
                    :repeat 5))))
        (unwind-protect
             (when eloop (lp:run-loop eloop))
          (when timer (lp:clear-timer timer))))
      (dolist (slot slots)
        (unless (eq (cslot-phase slot) :done)
          (%slot-fail slot
                      (format nil "this test timed out after ~ams"
                              (cslot-timeout slot))
                      :timeout)
          (setf (cslot-phase slot) :done)
          (%report-concurrent-slot slot cfg stats report))))))

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
