;;;; Focused Phase-28 proxy gate with exact pinned-Bun evidence validation.

(load (merge-pathnames "registry.lisp" *load-truename*))
(asdf:load-system :clun/tests)

(defparameter *proxy-baseline*
  "c1076ce95effb909bfe9f596919b5dba5567d550")

(defun proxy-tsv-fields (line)
  (uiop:split-string line :separator (list #\Tab)))

(let* ((root (asdf:system-source-directory :clun))
       (inventory
         (merge-pathnames
          "tests/compat/runtime.web-standard-apis/proxy-upstream.tsv" root))
       (tests '())
       (rows 0)
       (failed nil))
  (with-open-file (input inventory :direction :input)
    (unless (string=
             (or (read-line input nil nil) "")
             (format nil
                     "contract_id~cexact_commit~cupstream_source~cupstream_contract~clocal_test"
                     #\Tab #\Tab #\Tab #\Tab))
      (error "proxy upstream inventory has an invalid header"))
    (loop for line = (read-line input nil nil)
          while line do
            (unless (zerop (length line))
              (let ((fields (proxy-tsv-fields line)))
                (unless (= (length fields) 5)
                  (error "proxy upstream inventory row ~d has ~d fields"
                         (1+ rows) (length fields)))
                (destructuring-bind
                    (contract commit source upstream-contract local-test)
                    fields
                  (unless (and (plusp (length contract))
                               (string= commit *proxy-baseline*)
                               (plusp (length source))
                               (plusp (length upstream-contract))
                               (plusp (length local-test)))
                    (error "proxy upstream inventory row ~d is invalid" (1+ rows)))
                  (let ((symbol (find-symbol local-test :clun-test)))
                    (unless symbol
                      (error "proxy evidence references missing test ~a" local-test))
                    (pushnew symbol tests :test #'eq))
                  (incf rows))))))
  (when (zerop rows)
    (error "proxy upstream inventory is empty"))
  (setf tests (nreverse tests))
  (dolist (test tests)
    (unless (eq (parachute:status (parachute:test test)) :passed)
      (setf failed t)))
  (format t "PROXY-UPSTREAM-TESTS-~a ~d contracts / ~d suites / ~a~%"
          (if failed "FAILED" "OK") rows (length tests) *proxy-baseline*)
  (sb-ext:exit :code (if failed 1 0)))
