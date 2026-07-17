;;;; test-glob.lisp -- run only Phase 30 CL-side tests and return gate status.

(load (merge-pathnames "registry.lisp" *load-truename*))
(asdf:load-system :clun/tests)

(let* ((tests
         (remove-if-not
          (lambda (test)
            (and (null (parachute:parent test))
                 (let ((name (string (parachute:name test))))
                   (and (>= (length name) 5)
                        (string= "GLOB-" name :end2 5)))))
          (parachute:package-tests :clun-test)))
       (report (parachute:test tests)))
  (sb-ext:exit :code (if (eq (parachute:status report) :passed) 0 1)))
