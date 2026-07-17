;;;; test-cookie-resources.lisp -- run the architecture-sensitive CookieMap gate.

(load (merge-pathnames "registry.lisp" *load-truename*))
(asdf:load-system :clun/tests)

(let ((report
        (parachute:test
         'clun-test::cookie-core-map-direct-construction-resources)))
  (sb-ext:exit :code (if (eq (parachute:status report) :passed) 0 1)))
