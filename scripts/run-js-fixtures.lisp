;;;; run-js-fixtures.lisp — the tests/js end-to-end harness (PLAN.md §3.6, Phase 08).
;;;; Convention (file-based, easy to author with a shell redirect):
;;;;   tests/js/<group>/<case>.<ext>   the source (.js/.mjs/.cjs/.json)
;;;;   tests/js/<group>/<case>.out     expected stdout (exact) — REQUIRED per case
;;;;   tests/js/<group>/<case>.exit    expected exit code (integer)   — optional (0)
;;;;   tests/js/<group>/<case>.err     expected stderr (exact)        — optional
;;;;   tests/js/<group>/<case>.argv    argv, one token per line       — optional
;;;; If no .argv, argv = (<case>.<ext>) (file-run). cwd = the case's directory.
;;;; Prints a summary; exits nonzero on any mismatch.

(load (merge-pathnames "registry.lisp" *load-truename*))

(defparameter *clun-bin* (namestring (merge-pathnames "build/clun" *clun-root*)))
(defparameter *source-exts* '("js" "mjs" "cjs" "ts" "mts" "cts" "json"))

(defun slurp (path) (with-open-file (in path :external-format :utf-8)
                      (let ((s (make-string (file-length in))))
                        (subseq s 0 (read-sequence s in)))))

(defun case-name (out-path) (pathname-name out-path))

(defun sibling (out-path type) (make-pathname :type type :defaults out-path))

(defun fixture-environment ()
  "A deterministic child environment. GitHub injects CI=true, which would change
the semantics of fixtures that intentionally exercise test.only. CI-specific
behavior remains available to a fixture through Clun's explicit --ci flag."
  (cons "CI=0"
        (remove-if (lambda (entry)
                     (and (>= (length entry) 3)
                          (string= "CI=" entry :end2 3)))
                   (sb-ext:posix-environ))))

(defun case-argv (out-path)
  "The argv for a case: its .argv file (one token/line) or (<case>.<ext>)."
  (let ((argv-file (sibling out-path "argv")))
    (if (probe-file argv-file)
        (with-open-file (in argv-file)
          (loop for line = (read-line in nil nil) while line
                unless (zerop (length line)) collect line))
        (let ((src (loop for e in *source-exts*
                         for p = (sibling out-path e)
                         when (probe-file p) return p)))
          (unless src (error "no source or .argv for ~a" out-path))
          (list (file-namestring src))))))

(defun run-case (out-path)
  (let* ((dir (make-pathname :directory (pathname-directory out-path)))
         (argv (case-argv out-path))
         (want-exit (if (probe-file (sibling out-path "exit"))
                        (parse-integer (slurp (sibling out-path "exit")) :junk-allowed t) 0))
         (want-out (slurp out-path))
         (err-file (sibling out-path "err"))
         (want-err (and (probe-file err-file) (slurp err-file)))
         (out (make-string-output-stream)) (err (make-string-output-stream)))
    (let* ((proc (sb-ext:run-program *clun-bin* argv :output out :error err :wait t
                                     :directory dir :environment (fixture-environment)))
           (code (sb-ext:process-exit-code proc))
           (got-out (get-output-stream-string out))
           (got-err (get-output-stream-string err))
           (fails '()))
      (unless (eql code want-exit) (push (format nil "exit want ~a got ~a" want-exit code) fails))
      (unless (string= got-out want-out)
        (push (format nil "stdout:~%  want ~s~%  got  ~s" want-out got-out) fails))
      (when (and want-err (not (string= got-err want-err)))
        (push (format nil "stderr:~%  want ~s~%  got  ~s" want-err got-err) fails))
      (values (null fails) (format nil "~{    ~a~%~}" (nreverse fails))))))

(let ((cases (sort (append (directory (merge-pathnames "tests/js/**/*.out" *clun-root*))
                           (directory (merge-pathnames "tests/ts/runtime/*.out" *clun-root*)))
                   #'string< :key #'namestring))
      (pass 0) (fail 0))
  (unless (probe-file *clun-bin*)
    (format t "run-js-fixtures: build/clun missing — run `make build` first~%")
    (sb-ext:exit :code 1))
  (dolist (c cases)
    (multiple-value-bind (ok report) (run-case c)
      (if ok (progn (incf pass) (format t "  (pass) ~a~%" (enough-namestring c *clun-root*)))
          (progn (incf fail) (format t "  (FAIL) ~a~%~a" (enough-namestring c *clun-root*) report)))))
  (format t "~%tests/js: ~a passed, ~a failed (~a total)~%" pass fail (+ pass fail))
  (sb-ext:exit :code (if (zerop fail) 0 1)))
