;;;; Focused deterministic Phase-28 transport security tests.

(load (merge-pathnames "registry.lisp" *load-truename*))
(asdf:load-system :clun/tests)

(let ((failed nil)
      (tests '(clun-test::net/tls12-prf-sha256
               clun-test::net/tls12-record-authentication
               clun-test::net/tls12-client-hello-contract
               clun-test::net/tls-fallback-alert-is-exact
               clun-test::net/tls13-abrupt-eof-is-not-clean-eof
               clun-test::net/tls12-server-hello-rejects-downgrade
               clun-test::net/tls12-rejects-oversized-authenticated-plaintext
               clun-test::net/tls12-eof-framing-requires-close-notify
               clun-test::net/https-connect-proxy-split-envelope-is-not-origin-response
               clun-test::net/https-connect-proxy-non-2xx-is-a-response
               clun-test::net/https-connect-proxy-101-is-rejected
               clun-test::net/fetch-https-connect-redirect-is-not-followed
               clun-test::net/https-transport-streams-request-body
               clun-test::net/https-async-stream-bridge-pulls-request-body
               clun-test::net/http-content-decoding-is-bounded-and-fail-closed)))
  (dolist (test tests)
    (unless (eq (parachute:status (parachute:test test)) :passed)
      (setf failed t)))
  (format t "TLS-TRANSPORT-TESTS-~a ~d suites~%"
          (if failed "FAILED" "OK") (length tests))
  (sb-ext:exit :code (if failed 1 0)))
