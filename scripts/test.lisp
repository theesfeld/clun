;;;; test.lisp — load and run the parachute suites; exit nonzero on any failure.

(load (merge-pathnames "registry.lisp" *load-truename*))

(asdf:load-system :clun/tests)

(let ((report (parachute:test :clun-test)))
  (sb-ext:exit :code (if (eq (parachute:status report) :passed) 0 1)))
