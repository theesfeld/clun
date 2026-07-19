;;;; Fail-closed Test262 gate for Phase 37 milestone 4 keyed Promise combinators.

(in-package :cl-user)
(defparameter *clun-test262-library* t)
(defparameter *clun-test262-distinguish-timeout* t)
(load (merge-pathnames "test262.lisp" *load-truename*))
(in-package :clun.engine)

(defparameter +phase-37-m4-topics+
  '(("built-ins/Promise/allKeyed" . 38)
    ("built-ins/Promise/allSettledKeyed" . 36)))

(defconstant +phase-37-m4-path-sha256+
  "29621a93d20294a4347afe2fea77eecce08df71d79a1072ad713e0a7d869582b")

(defun phase-37-m4-read-paths (path)
  (with-open-file (input path)
    (let ((paths '()))
      (loop for line = (read-line input nil nil)
            for line-number from 1
            while line do
        (unless (or (zerop (length line))
                    (char= (char line 0) #\#))
          (when (find #\Return line)
            (error "Malformed Phase 37 m4 manifest line ~d" line-number))
          (push line paths)))
      (nreverse paths))))

(defun phase-37-m4-topic-for-path (path)
  (or (car (find-if (lambda (topic)
                      (let ((prefix (concatenate 'string (car topic) "/")))
                        (and (<= (length prefix) (length path))
                             (string= prefix path :end2 (length prefix)))))
                    +phase-37-m4-topics+))
      (error "Phase 37 m4 path has no selected topic: ~a" path)))

(defun phase-37-m4-ascii-octets (string)
  (let ((bytes (make-array (length string) :element-type '(unsigned-byte 8))))
    (dotimes (index (length string) bytes)
      (let ((code (char-code (char string index))))
        (unless (< code 128)
          (error "Non-ASCII character in frozen Phase 37 m4 path digest"))
        (setf (aref bytes index) code)))))

(defun phase-37-m4-path-digest (paths)
  (let ((text (with-output-to-string (output)
                (dolist (path paths) (write-line path output)))))
    (ironclad:byte-array-to-hex-string
     (ironclad:digest-sequence :sha256 (phase-37-m4-ascii-octets text)))))

(defun phase-37-m4-validate (paths)
  (unless (= 74 (length paths))
    (error "Phase 37 m4 selected ~d paths, expected 74" (length paths)))
  (let ((previous nil))
    (dolist (path paths)
      (when (and previous (not (string< previous path)))
        (error "Phase 37 m4 paths are not strictly sorted at ~a" path))
      (setf previous path)))
  (dolist (expected +phase-37-m4-topics+)
    (let ((actual (count (car expected) paths :test #'string=
                         :key #'phase-37-m4-topic-for-path)))
      (unless (= actual (cdr expected))
        (error "Phase 37 m4 topic ~a has ~d rows, expected ~d"
               (car expected) actual (cdr expected)))))
  (let ((digest (phase-37-m4-path-digest paths)))
    (unless (string-equal digest +phase-37-m4-path-sha256+)
      (error "Phase 37 m4 path digest ~a does not match frozen ~a"
             digest +phase-37-m4-path-sha256+)))
  paths)

(defun phase-37-m4-pathname (path)
  (let ((prefix "built-ins/"))
    (unless (and (<= (length prefix) (length path))
                 (string= prefix path :end2 (length prefix)))
      (error "Phase 37 m4 path is outside built-ins: ~a" path))
    (merge-pathnames (subseq path (length prefix)) *builtins-root*)))

(let* ((manifest (merge-pathnames "tests/conformance/phase-37-m4-paths.txt"
                                   cl-user::*clun-root*))
       (paths (phase-37-m4-validate (phase-37-m4-read-paths manifest)))
       (counts (make-hash-table :test #'equal))
       (mismatches '()))
  (format t "=== Phase 37 milestone 4 Test262 slice -- ~d frozen failures ===~%"
          (length paths))
  (dolist (path paths)
    (let* ((topic (phase-37-m4-topic-for-path path))
           (classification (classify-exec (phase-37-m4-pathname path))))
      (incf (gethash (list topic classification) counts 0))
      (unless (eq classification :pass)
        (push (list path classification) mismatches))))
  (dolist (topic +phase-37-m4-topics+)
    (format t "~a: pass=~d fail=~d skip=~d tmo=~d crash=~d~%"
            (car topic)
            (gethash (list (car topic) :pass) counts 0)
            (gethash (list (car topic) :fail) counts 0)
            (gethash (list (car topic) :skip) counts 0)
            (gethash (list (car topic) :tmo) counts 0)
            (gethash (list (car topic) :crash) counts 0)))
  (if mismatches
      (progn
        (format t "~%MISMATCHES (~d):~%" (length mismatches))
        (dolist (mismatch (nreverse mismatches))
          (format t "  ~a: expected pass, got ~(~a~)~%"
                  (first mismatch) (second mismatch)))
        (format t "phase-37-m4: FAILED~%")
        (sb-ext:exit :code 1))
      (progn
        (format t "phase-37-m4: OK (74 entry failures converted; 0 fail/skip/tmo/crash)~%")
        (sb-ext:exit :code 0))))
