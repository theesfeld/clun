;;;; runner.lisp — `clun test` entry (PLAN.md Phase 15). Parse test flags, discover
;;;; files, run each in its OWN runtime+test realm (load builds the tree, the scheduler
;;;; runs it, teardown), aggregate, print the summary, return the exit code.

(in-package :clun.test-runner)

(defstruct (test-opts (:conc-name to-))
  (positionals '()) (name-pattern nil) (timeout 5000) (retry 0)
  (bail nil) (todo nil) (ci nil) (update-snapshots nil))

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
          ((or (string= tok "-u") (string= tok "--update-snapshots"))
           (setf (to-update-snapshots o) t))
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
    o))

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

(defun %run-one-file (path opts stats report cwd)
  "Load + run one test file in a fresh realm. Returns the file's expect() count. A load
error (syntax / top-level throw) is reported as a fail. Always tears the realm down."
  (let ((realm (eng:make-realm)) (ctx nil) (snapshot nil))
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
                   (setf ctx (make-test-context :root root :current root
                                                :default-timeout (to-timeout opts)
                                                :snapshot snapshot))
                   (install-test-globals realm ctx))
                 (eng:run-module-file path :realm realm :teardown nil)
                 ;; bind *realm* around regexp build + the scheduler: %build-regexp and
                 ;; %name-matches do js-construct/js-call, which need the intrinsics realm
                 ;; (run-module-file only binds it internally, then returns).
                 (let ((eng:*realm* realm))
                   (let ((cfg (make-run-cfg :default-timeout (ctx-default-timeout ctx)
                                            :retry (to-retry opts)
                                            :todo (to-todo opts) :ci (%ci-active-p opts)
                                            :name-re (%build-regexp realm (to-name-pattern opts))
                                            :bail (to-bail opts)
                                            :snapshot snapshot)))
                     (run-file-tree ctx realm cfg stats report))
                   (snapshot-finalize snapshot)))
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
         (cwd* (or cwd (sys:pathname->native (truename "."))))
         (files (discover-files (to-positionals opts) cwd*))
         (stats (make-run-stats))
         (report (make-reporter *standard-output*))
         (expect-total 0))
    (when (null files)
      (format *standard-output* "No test files found.~%")
      (return-from run-test-command 1))
    (dolist (f files)
      (when (st-bailed stats) (return))
      (incf expect-total (%run-one-file f opts stats report cwd*)))
    (print-summary *standard-output* stats (length files) expect-total)
    (let ((total (+ (st-pass stats) (st-fail stats) (st-skip stats) (st-todo stats))))
      (if (or (plusp (st-fail stats))
              (zerop total)
              (and (to-name-pattern opts) (zerop (st-matched stats))))
          1 0))))
