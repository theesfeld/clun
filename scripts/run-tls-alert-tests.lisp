;;;; Focused deterministic TLS fatal-alert and closure wire-contract tests.

(load (merge-pathnames "registry.lisp" *load-truename*))
(asdf:load-system :clun/tests)

(let ((failed nil)
      (tests '(clun-test::net/tls12-local-fatal-alert-wire-contract
               clun-test::net/tls12-peer-alert-and-close-wire-contract
               clun-test::net/tls13-fatal-alert-wire-contract
               clun-test::net/tls13-peer-alert-and-close-wire-contract
               clun-test::net/tls13-malformed-record-alert-wire-contract)))
  (dolist (test tests)
    (unless (eq (parachute:status (parachute:test test)) :passed)
      (setf failed t)))
  (format t "TLS-ALERT-TESTS-~a ~d suites~%"
          (if failed "FAILED" "OK") (length tests))
  (sb-ext:exit :code (if failed 1 0)))
