;;;; runner.lisp — `clun test` entry (PLAN.md Phase 15). Parse test flags, discover
;;;; files, run each in its OWN runtime+test realm (load builds the tree, the scheduler
;;;; runs it, teardown), aggregate, print the summary, return the exit code.

(in-package :clun.test-runner)

(defstruct (test-opts (:conc-name to-))
  (positionals '()) (name-pattern nil) (timeout 5000) (retry 0)
  (bail nil) (todo nil) (ci nil) (update-snapshots nil)
  (randomize nil) (seed nil) (reporter :console) (reporter-outfile nil)
  (shard-index nil) (shard-count nil) (preloads '())
  (coverage nil) (coverage-reporters '()) (coverage-dir "coverage")
  (coverage-reporters-explicit-p nil) (coverage-dir-explicit-p nil)
  (coverage-include-test-files nil) (coverage-files-explicit-p nil)
  (coverage-ignore-patterns '())
  (coverage-threshold-lines nil) (coverage-threshold-functions nil)
  (coverage-threshold-statements nil)
  (concurrent nil) (max-concurrency 20)
  (error-message nil))

(defun %test-seed (value)
  (when (and value (plusp (length value)) (<= (length value) 10)
             (every #'digit-char-p value))
    (let ((seed (parse-integer value)))
      (and (<= seed #xffffffff) seed))))

(defun %set-test-reporter (opts value)
  (cond
    ((string= value "junit") (setf (to-reporter opts) :junit))
    ((member value '("dot" "dots") :test #'string=)
     (setf (to-reporter opts) :dots))
    (t
     (setf (to-error-message opts)
           (format nil
                   "unsupported reporter format '~a'. Available options: 'junit', 'dots'"
                   value)))))

(defun %add-coverage-reporter (opts value)
  (let ((reporter (cond ((string= value "text") :text)
                        ((string= value "lcov") :lcov))))
    (if reporter
        (progn
          (setf (to-coverage opts) t)
          (setf (to-coverage-reporters-explicit-p opts) t)
          (unless (member reporter (to-coverage-reporters opts))
            (setf (to-coverage-reporters opts)
                  (append (to-coverage-reporters opts) (list reporter)))))
        (setf (to-error-message opts)
              (format nil
                      "unsupported coverage reporter '~a'. Available options: 'text', 'lcov'"
                      value)))))

(defun %test-positive-u32 (value)
  (let ((number (%test-seed value)))
    (and number (plusp number) number)))

(defun %test-shard-spec (value)
  (when value
    (let ((slash (position #\/ value)))
      (when (and slash (plusp slash) (< slash (1- (length value)))
                 (null (position #\/ value :start (1+ slash))))
        (let ((index (%test-positive-u32 (subseq value 0 slash)))
              (count (%test-positive-u32 (subseq value (1+ slash)))))
          (when (and index count (<= index count))
            (values index count t)))))))

(defun %set-test-shard (opts value)
  (multiple-value-bind (index count valid-p) (%test-shard-spec value)
    (if valid-p
        (setf (to-shard-index opts) index (to-shard-count opts) count)
        (setf (to-error-message opts)
              (format nil "Invalid shard value: ~a (expected INDEX/COUNT)" (or value ""))))))

(defun %parse-test-args (argv)
  "ARGV = the tokens after `clun test`. Returns a test-opts."
  (let ((o (make-test-opts)) (toks argv))
    (labels ((next () (pop toks)))
      (loop for tok = (next) while tok do
        (cond
          ((or (string= tok "-t") (string= tok "--test-name-pattern"))
           (setf (to-name-pattern o) (next)))
          ((string= tok "--timeout")
           (let ((v (next))) (when v (setf (to-timeout o) (max 0 (or (parse-integer v :junk-allowed t) 5000))))))
          ((string= tok "--retry")
           (let ((v (next)))
             (when v (setf (to-retry o) (max 0 (or (parse-integer v :junk-allowed t) 0))))))
          ((string= tok "--todo") (setf (to-todo o) t))
          ((string= tok "--ci") (setf (to-ci o) t))
          ((string= tok "--randomize") (setf (to-randomize o) t))
          ((string= tok "--coverage") (setf (to-coverage o) t))
          ((string= tok "--coverage-reporter")
           (let ((value (next)))
             (if value
                 (%add-coverage-reporter o value)
                 (setf (to-error-message o) "--coverage-reporter requires a value"))))
          ((and (>= (length tok) 20)
                (string= (subseq tok 0 20) "--coverage-reporter="))
           (%add-coverage-reporter o (subseq tok 20)))
          ((string= tok "--coverage-dir")
           (let ((value (next)))
             (if (and value (plusp (length value)))
                 (setf (to-coverage-dir o) value
                       (to-coverage-dir-explicit-p o) t)
                 (setf (to-error-message o) "--coverage-dir requires a value"))))
          ((and (>= (length tok) 15)
                (string= (subseq tok 0 15) "--coverage-dir="))
           (let ((value (subseq tok 15)))
             (if (plusp (length value))
                 (setf (to-coverage-dir o) value
                       (to-coverage-dir-explicit-p o) t)
                 (setf (to-error-message o) "--coverage-dir requires a value"))))
          ((string= tok "--coverage-skip-test-files")
           (setf (to-coverage-include-test-files o) nil
                 (to-coverage-files-explicit-p o) t))
          ((string= tok "--no-coverage-skip-test-files")
           (setf (to-coverage-include-test-files o) t
                 (to-coverage-files-explicit-p o) t))
          ((member tok '("--preload" "--require" "-r") :test #'string=)
           (let ((value (next)))
             (if (and value (plusp (length value)))
                 (push value (to-preloads o))
                 (setf (to-error-message o)
                       (format nil "~a requires a module path" tok)))))
          ((or (and (>= (length tok) 10)
                    (string= (subseq tok 0 10) "--preload="))
               (and (>= (length tok) 10)
                    (string= (subseq tok 0 10) "--require=")))
           (let ((value (subseq tok 10)))
             (if (plusp (length value))
                 (push value (to-preloads o))
                 (setf (to-error-message o) "--preload requires a module path"))))
          ((and (>= (length tok) 3) (string= (subseq tok 0 3) "-r="))
           (let ((value (subseq tok 3)))
             (if (plusp (length value))
                 (push value (to-preloads o))
                 (setf (to-error-message o) "-r requires a module path"))))
          ((string= tok "--dots") (setf (to-reporter o) :dots))
          ((string= tok "--reporter")
           (let ((value (next)))
             (if value
                 (%set-test-reporter o value)
                 (setf (to-error-message o) "--reporter requires a value"))))
          ((and (>= (length tok) 11) (string= (subseq tok 0 11) "--reporter="))
           (%set-test-reporter o (subseq tok 11)))
          ((string= tok "--reporter-outfile")
           (let ((value (next)))
             (if (and value (plusp (length value)))
                 (setf (to-reporter-outfile o) value)
                 (setf (to-error-message o) "--reporter-outfile requires a value"))))
          ((and (>= (length tok) 19)
                (string= (subseq tok 0 19) "--reporter-outfile="))
           (let ((value (subseq tok 19)))
             (if (plusp (length value))
                 (setf (to-reporter-outfile o) value)
                 (setf (to-error-message o) "--reporter-outfile requires a value"))))
          ((string= tok "--shard") (%set-test-shard o (next)))
          ((and (>= (length tok) 8) (string= (subseq tok 0 8) "--shard="))
           (%set-test-shard o (subseq tok 8)))
          ((string= tok "--seed")
           (let* ((value (next)) (seed (%test-seed value)))
             (if seed
                 (setf (to-seed o) seed (to-randomize o) t)
                 (setf (to-error-message o)
                       (format nil "Invalid seed value: ~a" (or value ""))))))
          ((and (>= (length tok) 7) (string= (subseq tok 0 7) "--seed="))
           (let* ((value (subseq tok 7)) (seed (%test-seed value)))
             (if seed
                 (setf (to-seed o) seed (to-randomize o) t)
                 (setf (to-error-message o)
                       (format nil "Invalid seed value: ~a" value)))))
          ((or (string= tok "-u") (string= tok "--update-snapshots"))
           (setf (to-update-snapshots o) t))
          ((string= tok "--concurrent") (setf (to-concurrent o) t))
          ((string= tok "--max-concurrency")
           (let ((v (next)))
             (if v
                 (let ((n (parse-integer v :junk-allowed t)))
                   (if n
                       (setf (to-max-concurrency o) (max 0 n))
                       (setf (to-error-message o)
                             (format nil "Invalid max-concurrency: ~a" v))))
                 (setf (to-error-message o) "--max-concurrency requires a value"))))
          ((and (>= (length tok) 18)
                (string= (subseq tok 0 18) "--max-concurrency="))
           (let* ((value (subseq tok 18))
                  (n (parse-integer value :junk-allowed t)))
             (if n
                 (setf (to-max-concurrency o) (max 0 n))
                 (setf (to-error-message o)
                       (format nil "Invalid max-concurrency: ~a" value)))))
          ((string= tok "--bail") (setf (to-bail o) 1))
          ((and (>= (length tok) 7) (string= (subseq tok 0 7) "--bail="))
           (setf (to-bail o) (max 1 (or (parse-integer (subseq tok 7) :junk-allowed t) 1))))
          ((and (>= (length tok) 10) (string= (subseq tok 0 10) "--timeout="))
           (setf (to-timeout o) (max 0 (or (parse-integer (subseq tok 10) :junk-allowed t) 5000))))
          ((and (>= (length tok) 8) (string= (subseq tok 0 8) "--retry="))
           (setf (to-retry o) (max 0 (or (parse-integer (subseq tok 8) :junk-allowed t) 0))))
          ((and (plusp (length tok)) (char= (char tok 0) #\-)) nil) ; ignore unknown flags
          (t (push tok (to-positionals o))))))
    (setf (to-positionals o) (nreverse (to-positionals o)))
    (setf (to-preloads o) (nreverse (to-preloads o)))
    (when (and (eq (to-reporter o) :junit) (null (to-reporter-outfile o)))
      (setf (to-error-message o)
            "--reporter=junit requires --reporter-outfile [file] to specify where to save the XML report"))
    o))

(defun %apply-test-bunfig (opts config)
  (when (and (tbc-coverage-present-p config) (tbc-coverage config))
    (setf (to-coverage opts) t))
  (when (and (not (to-coverage-reporters-explicit-p opts))
             (tbc-coverage-reporters config))
    (setf (to-coverage-reporters opts) (tbc-coverage-reporters config)))
  (when (and (not (to-coverage-dir-explicit-p opts)) (tbc-coverage-dir config))
    (setf (to-coverage-dir opts) (tbc-coverage-dir config)))
  (when (and (not (to-coverage-files-explicit-p opts))
             (tbc-coverage-skip-test-files-present-p config))
    (setf (to-coverage-include-test-files opts)
          (not (tbc-coverage-skip-test-files config))))
  (setf (to-coverage-ignore-patterns opts) (tbc-coverage-ignore-patterns config)
        (to-coverage-threshold-lines opts) (tbc-coverage-threshold-lines config)
        (to-coverage-threshold-functions opts) (tbc-coverage-threshold-functions config)
        (to-coverage-threshold-statements opts) (tbc-coverage-threshold-statements config))
  (when (or (to-coverage-threshold-lines opts)
            (to-coverage-threshold-functions opts)
            (to-coverage-threshold-statements opts))
    (setf (to-coverage opts) t))
  (when (and (to-coverage opts) (null (to-coverage-reporters opts)))
    (setf (to-coverage-reporters opts) '(:text)))
  opts)

(defun %fresh-test-seed ()
  (handler-case
      (ironclad:random-bits 32)
    (error ()
      (logand #xffffffff
              (logxor (get-universal-time) (get-internal-real-time) (sys:getpid))))))

(defun %test-file-prng (path seed)
  (let* ((basename (sys:path-basename path))
         (octets (babel:string-to-octets basename :encoding :utf-8))
         (hash (clun.hash:wyhash octets)))
    (make-test-prng (%test-u64 (+ hash seed)))))

(defun %select-test-shard (files index count)
  (if (null index)
      files
      (loop for file in files
            for ordinal from 0
            when (= (mod ordinal count) (1- index))
              collect file)))

(defun %ci-active-p (opts)
  (or (to-ci opts)
      (let ((v (sys:getenv "CI")))
        (and v (not (member v '("" "0" "false") :test #'string=))))))

(defun %build-regexp (realm pattern)
  (and pattern
       (ignore-errors
        (eng:js-construct (eng:js-get (eng:realm-global realm) "RegExp") (list pattern)))))

(defun %merge-snapshot-stats (snapshot stats)
  (when snapshot
    (incf (st-snapshots stats) (ss-total snapshot))
    (incf (st-snapshot-added stats) (ss-added snapshot))
    (incf (st-snapshot-matched stats) (ss-matched snapshot))
    (incf (st-snapshot-updated stats) (ss-updated snapshot))
    (incf (st-snapshot-failed stats) (ss-failed snapshot))))

(defstruct (preload-hook-set (:conc-name ph-))
  (before-all '()) (before-each '()) (after-all '()) (after-each '()))

(defstruct (preload-suite-state (:conc-name ps-))
  (before-all-ran nil) (before-all-ok t) (after-all-ran nil))

(defun %test-preload-path (specifier cwd)
  (sys:normalize-path
   (if (sys:absolute-path-p specifier)
       specifier
       (sys:path-join cwd specifier))))

(defun %load-test-preloads (realm ctx preloads cwd)
  "Evaluate PRELOADS in order, then detach their hooks from the file-local root."
  (setf (ctx-preloading ctx) t)
  (unwind-protect
       (dolist (specifier preloads)
         (eng:run-module-file (%test-preload-path specifier cwd)
                              :realm realm :teardown nil))
    (setf (ctx-preloading ctx) nil))
  (let* ((root (ctx-root ctx))
         (hooks (make-preload-hook-set
                 :before-all (td-before-all root)
                 :before-each (td-before-each root)
                 :after-all (td-after-all root)
                 :after-each (td-after-each root))))
    (setf (td-before-all root) '()
          (td-before-each root) '()
          (td-after-all root) '()
          (td-after-each root) '())
    hooks))

(defun %merge-preload-per-test-hooks (root hooks)
  ;; Hook lists are stored in reverse registration order and %run-hooks reverses
  ;; them. Preload beforeEach runs before file hooks; preload afterEach runs after.
  (setf (td-before-each root)
        (append (td-before-each root) (ph-before-each hooks))
        (td-after-each root)
        (append (ph-after-each hooks) (td-after-each root))))

(defun %run-preload-before-all (hooks realm cfg stats report)
  (let ((failure (%run-hooks (ph-before-all hooks) realm (cfg-default-timeout cfg))))
    (if failure
        (progn
          (funcall report :fail "beforeAll" (%err-detail failure))
          (incf (st-fail stats))
          (%maybe-bail stats cfg)
          nil)
        t)))

(defun %run-preload-after-all (hooks realm cfg stats report)
  (let ((failure (%run-hooks (ph-after-all hooks) realm (cfg-default-timeout cfg))))
    (when failure
      (funcall report :fail "afterAll" (%err-detail failure))
      (incf (st-fail stats))
      (%maybe-bail stats cfg))))

(defun %run-one-file (path opts stats report cwd suite-state last-file-p
                      &optional coverage-session)
  "Load + run one test file in a fresh realm. Returns the file's expect() count. A load
error (syntax / top-level throw) is reported as a fail. Always tears the realm down."
  (let ((realm (eng:make-realm)) (ctx nil) (snapshot nil))
    (setf (eng:realm-coverage-session realm) coverage-session)
    (unwind-protect
         (progn
           (rt:install-runtime realm :argv (list :script path :rest nil)
                                     :cwd cwd :silent nil)
           (handler-case
               (progn
                 (setf snapshot
                       (make-file-snapshot-state path (to-update-snapshots opts)
                                                (%ci-active-p opts)))
                 (let ((root (make-t-describe :name nil :parent nil)))
                   (setf ctx (make-test-context :root root :current root :path path
                                                :default-timeout (to-timeout opts)
                                                :snapshot snapshot))
                   (install-test-globals realm ctx))
                 (let ((preload-hooks
                         (%load-test-preloads realm ctx (to-preloads opts) cwd)))
                   (eng:run-module-file path :realm realm :teardown nil)
                   (%merge-preload-per-test-hooks (ctx-root ctx) preload-hooks)
                 ;; bind *realm* around regexp build + the scheduler: %build-regexp and
                 ;; %name-matches do js-construct/js-call, which need the intrinsics realm
                 ;; (run-module-file only binds it internally, then returns).
                   (let ((eng:*realm* realm))
                     (let ((cfg (make-run-cfg :default-timeout (ctx-default-timeout ctx)
                                              :retry (to-retry opts)
                                              :todo (to-todo opts) :ci (%ci-active-p opts)
                                              :name-re (%build-regexp realm (to-name-pattern opts))
                                              :bail (to-bail opts)
                                              :snapshot snapshot
                                              :default-concurrent (to-concurrent opts)
                                              :max-concurrency (to-max-concurrency opts)
                                              :random-state
                                              (and (to-randomize opts)
                                                   (%test-file-prng path (to-seed opts))))))
                       (let ((setup-ok (ps-before-all-ok suite-state)))
                         (unless (ps-before-all-ran suite-state)
                           (setf (ps-before-all-ran suite-state) t)
                           (setf setup-ok
                                 (%run-preload-before-all
                                  preload-hooks realm cfg stats report)
                                 (ps-before-all-ok suite-state) setup-ok))
                         (if setup-ok
                             (run-file-tree ctx realm cfg stats report)
                             (%skip-subtree (ctx-root ctx) cfg stats report)))
                       (when (and (not (ps-after-all-ran suite-state))
                                  (or last-file-p (st-bailed stats)))
                         (setf (ps-after-all-ran suite-state) t)
                         (%run-preload-after-all preload-hooks realm cfg stats report)))
                     (snapshot-finalize snapshot))))
             (eng:js-condition (c)
               (funcall report :fail (format nil "~a (failed to load)" path)
                        (%err-detail (eng:js-condition-value c)))
               (incf (st-fail stats)))
             (snapshot-error (c)
               (funcall report :fail (format nil "~a (snapshot update failed)" path)
                        (snapshot-error-message c))
               (incf (st-fail stats)))
             (error (c)
               (funcall report :fail (format nil "~a (test runner failed)" path)
                        (princ-to-string c))
               (incf (st-fail stats))))
           (%merge-snapshot-stats snapshot stats)
           (if ctx (ctx-expect-calls ctx) 0))
      ;; Spies may have replaced properties in the realm. Restore them and release the
      ;; host-side mock registry before tearing the realm down so no file can retain
      ;; mock history or implementation state from an earlier file.
      (when ctx (restore-test-mocks ctx))
      (eng:teardown-realm realm))))

(defun run-test-command (argv cwd)
  "`clun test` — discover + run test files under CWD; print the summary; return the
process exit code (1 on any failure, on zero tests, or on a 0-match -t filter)."
  ;; CWD is the caller-resolved working directory (honouring --cwd); discovery roots there.
  (let* ((opts (%parse-test-args argv))
         (cwd* (or cwd (sys:pathname->native (truename ".")))))
    (when (to-error-message opts)
      (format *error-output* "clun test: ~a~%" (to-error-message opts))
      (return-from run-test-command 1))
    (handler-case
        (let ((config (read-test-config-from-bunfig cwd*)))
          (setf (to-preloads opts)
                (append (tbc-preloads config) (to-preloads opts)))
          (%apply-test-bunfig opts config))
      (test-config-error (condition)
        (format *error-output* "clun test: ~a~%" condition)
        (return-from run-test-command 1)))
    (when (and (to-randomize opts) (null (to-seed opts)))
      (setf (to-seed opts) (%fresh-test-seed)))
    (let* ((discovered (discover-files (to-positionals opts) cwd*))
           (selected (%select-test-shard discovered (to-shard-index opts)
                                         (to-shard-count opts)))
           (files (if (to-randomize opts)
                      (%shuffle-test-files selected (make-test-prng (to-seed opts)))
                      selected))
           (stats (make-run-stats))
           (current-file nil)
           (records '())
           (report
             (make-reporter
              *standard-output* :mode (to-reporter opts)
              :on-result
              (lambda (status name detail assertions)
                (push (make-test-report-record current-file status name detail assertions)
                      records))))
           (expect-total 0)
           (suite-state (make-preload-suite-state))
           (coverage-session (and (to-coverage opts) (eng:make-coverage-session)))
           (report-error nil))
      (when (null files)
        (format *standard-output* "No test files found.~%")
        (return-from run-test-command 1))
      (labels ((run-files ()
                 (loop for remaining on files
                       for f = (car remaining)
                       for last-file-p = (null (cdr remaining))
                       do (when (st-bailed stats) (return))
                          (setf current-file f)
                          (incf expect-total
                                (%run-one-file f opts stats report cwd* suite-state
                                               last-file-p coverage-session)))))
        (if coverage-session
            (eng:call-with-coverage-session coverage-session #'run-files)
            (run-files)))
      (print-summary *standard-output* stats (length files) expect-total
                     (and (to-randomize opts) (to-seed opts)))
      (when coverage-session
        (handler-case
            (let ((coverage-records
                    (write-test-coverage
                     coverage-session cwd* (to-coverage-reporters opts)
                     (to-coverage-dir opts)
                     (to-coverage-include-test-files opts)
                     (to-coverage-ignore-patterns opts) *standard-output*)))
              (dolist (failure
                       (coverage-threshold-failures
                        coverage-records
                        (to-coverage-threshold-lines opts)
                        (to-coverage-threshold-functions opts)
                        (to-coverage-threshold-statements opts)))
                (setf report-error t)
                (format *error-output* "clun test: ~a~%" failure)))
          (error (condition)
            (setf report-error t)
            (format *error-output* "clun test: failed to write coverage report: ~a~%"
                    condition))))
      (when (eq (to-reporter opts) :junit)
        (let ((outfile (to-reporter-outfile opts)))
          (unless (sys:absolute-path-p outfile)
            (setf outfile (sys:path-join cwd* outfile)))
          (handler-case
              (write-junit-report outfile (nreverse records))
            (error (condition)
              (setf report-error t)
              (format *error-output* "clun test: failed to write JUnit report to ~a: ~a~%"
                      outfile condition)))))
      (let ((total (+ (st-pass stats) (st-fail stats) (st-skip stats) (st-todo stats))))
        (if (or report-error
                (plusp (st-fail stats))
                (zerop total)
                (and (to-name-pattern opts) (zerop (st-matched stats))))
            1 0)))))
