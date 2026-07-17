;;;; Fail-closed focused Test262 gate for the Phase 65 tagged-template prerequisite.

(in-package :cl-user)
(defparameter *clun-test262-library* t)
(defparameter *clun-test262-distinguish-timeout* t)
(load (merge-pathnames "test262.lisp" *load-truename*))
(in-package :clun.engine)

(defparameter +phase-65-tagged-template-exceptions+
  '(("cache-eval-inner-function.js" . :fail)
    ("cache-realm.js" . :skip)
    ("tco-call.js" . :skip)
    ("tco-member.js" . :skip)))

(defun phase-65-tagged-template-expected (path)
  (or (cdr (assoc (file-namestring path)
                  +phase-65-tagged-template-exceptions+
                  :test #'string=))
      :pass))

(let* ((root (merge-pathnames "expressions/tagged-template/" *lang-root*))
       (paths (sort (directory (merge-pathnames "*.js" root))
                    #'string< :key #'namestring))
       (counts (make-hash-table))
       (mismatches '()))
  (unless (= 27 (length paths))
    (error "Phase 65 tagged-template corpus has ~d files, expected 27"
           (length paths)))
  (dolist (path paths)
    (let ((expected (phase-65-tagged-template-expected path))
          (actual (classify-exec path)))
      (incf (gethash actual counts 0))
      (unless (eq expected actual)
        (push (list (file-namestring path) expected actual) mismatches))))
  (format t "Phase 65 tagged-template Test262: pass=~d fail=~d skip=~d tmo=~d crash=~d~%"
          (gethash :pass counts 0) (gethash :fail counts 0)
          (gethash :skip counts 0) (gethash :tmo counts 0)
          (gethash :crash counts 0))
  (when mismatches
    (dolist (mismatch (nreverse mismatches))
      (destructuring-bind (path expected actual) mismatch
        (format t "  ~a: expected ~(~a~), got ~(~a~)~%" path expected actual)))
    (sb-ext:exit :code 1))
  (unless (and (= 23 (gethash :pass counts 0))
               (= 1 (gethash :fail counts 0))
               (= 3 (gethash :skip counts 0))
               (zerop (gethash :tmo counts 0))
               (zerop (gethash :crash counts 0)))
    (error "Phase 65 tagged-template classification totals changed"))
  (format t "phase-65-tagged-templates: OK (one direct-eval residual; three policy skips)~%")
  (sb-ext:exit :code 0))
