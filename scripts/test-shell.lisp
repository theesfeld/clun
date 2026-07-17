;;;; test-shell.lisp -- run the Phase 65 CL-side shell tests and return gate status.

(load (merge-pathnames "registry.lisp" *load-truename*))
(asdf:load-system :clun/tests)

(let* ((tests
         (remove-if-not
          (lambda (test)
            (and (null (parachute:parent test))
                 (let ((name (string (parachute:name test))))
                   (and (>= (length name) 6)
                        (string= "SHELL/" name :end2 6)))))
          (parachute:package-tests :clun-test)))
       (report (parachute:test tests)))
  (sb-ext:exit :code (if (eq (parachute:status report) :passed) 0 1)))
