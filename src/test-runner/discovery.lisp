;;;; discovery.lisp — find test files + apply positional filters (PLAN.md Phase 15).
;;;; Patterns: <stem>.{test,spec}.<ext> and <stem>_{test,spec}.<ext> for ext ∈
;;;; js/mjs/cjs/ts/mts/cts. Walks cwd (skipping node_modules + dotdirs). A positional
;;;; that names an existing file/dir is used directly; otherwise it is a substring
;;;; filter over discovered paths.

(in-package :clun.test-runner)

(defparameter *test-exts* '("js" "mjs" "cjs" "ts" "mts" "cts"))
(defparameter *test-stems* '(".test" "_test" ".spec" "_spec"))

(defun %test-file-p (name)
  (let ((dot (position #\. name :from-end t)))
    (and dot (< (1+ dot) (length name))
         (member (subseq name (1+ dot)) *test-exts* :test #'string=)
         (let ((stem (subseq name 0 dot)))
           (some (lambda (s) (and (>= (length stem) (length s))
                                  (string= s (subseq stem (- (length stem) (length s))))))
                 *test-stems*)))))

(defun %walk-dir (dir acc)
  "Collect test-file paths under DIR (recursive), skipping node_modules + dot dirs."
  (dolist (entry (sys:read-directory dir))
    (unless (and (plusp (length entry)) (char= (char entry 0) #\.))
      (let ((full (sys:path-join dir entry)))
        (cond
          ((sys:directory-p full)
           (unless (string= entry "node_modules") (%walk-dir full acc)))
          ((and (sys:file-p full) (%test-file-p entry)) (vector-push-extend full acc))))))
  acc)

(defun %abs (path cwd) (if (sys:absolute-path-p path) path (sys:path-join cwd path)))

(defun discover-files (positionals cwd)
  "Absolute test-file paths for POSITIONALS (paths and/or substring filters) under CWD."
  (let ((explicit-files '()) (roots '()) (filters '()))
    (dolist (p positionals)
      (let ((abs (%abs p cwd)))
        (cond ((sys:file-p abs) (push abs explicit-files))
              ((sys:directory-p abs) (push abs roots))
              (t (push p filters)))))
    (when (and (null roots) (null explicit-files)) (setf roots (list cwd)))
    (let ((acc (make-array 0 :adjustable t :fill-pointer 0)))
      (dolist (f (nreverse explicit-files)) (vector-push-extend f acc))
      (dolist (r (nreverse roots)) (%walk-dir r acc))
      (let ((paths (remove-duplicates (coerce acc 'list) :test #'string=)))
        (when filters
          (setf paths (remove-if-not
                       (lambda (path) (some (lambda (f) (search f path)) filters))
                       paths)))
        (sort paths #'string<)))))
