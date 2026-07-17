;;;; Focused deterministic Phase-28 DNS resolver tests.

(load (merge-pathnames "registry.lisp" *load-truename*))
(asdf:load-system :clun/tests)

(let ((failed nil)
      (tests '(clun-test::net/dns-query-encoding
               clun-test::net/dns-parse-compressed-cname-a
               clun-test::net/dns-parse-compressed-aaaa
               clun-test::net/dns-truncated-response-is-explicit
               clun-test::net/dns-malformed-packets-fail-boundedly
               clun-test::net/dns-rcode-errors-are-exact
               clun-test::net/dns-family-interleave
               clun-test::net/dns-literals-and-localhost-avoid-network
               clun-test::net/dns-resolver-udp-fixture
               clun-test::net/dns-cancel-interrupts-silent-resolver
               clun-test::net/happy-eyeballs-falls-back-to-ipv4)))
  (dolist (test tests)
    (unless (eq (parachute:status (parachute:test test)) :passed)
      (setf failed t)))
  (format t "DNS-TESTS-~a ~d suites~%"
          (if failed "FAILED" "OK") (length tests))
  (sb-ext:exit :code (if failed 1 0)))
