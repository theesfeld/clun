;;;; Run every top-level NET/ suite and return a gate status.

(load (merge-pathnames "registry.lisp" *load-truename*))
(asdf:load-system :clun/tests)

(let* ((tests
         (remove-if-not
          (lambda (test)
            (and (null (parachute:parent test))
                 (let ((name (string (parachute:name test))))
                   (and (>= (length name) 4)
                        (string= "NET/" name :end2 4)))))
          (parachute:package-tests :clun-test)))
       (report (parachute:test tests)))
  (format t "NET-TESTS-~a ~d suites~%"
          (if (eq (parachute:status report) :passed) "OK" "FAILED")
          (length tests))
  (sb-ext:exit :code (if (eq (parachute:status report) :passed) 0 1)))
