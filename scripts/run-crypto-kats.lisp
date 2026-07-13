;;;; run-crypto-kats.lisp — Phase-19 crypto known-answer-test gate step.
;;;;
;;;; Runs tests/lisp/crypto/kat-tests.lisp (RFC/FIPS KATs over the vendored ironclad)
;;;; in its OWN image.  ironclad is deliberately NOT a clun/tests dependency: loading it
;;;; opens /dev/urandom + starts a bordeaux-threads lock and shifts fd numbering, which
;;;; adds fd pressure to the socket suites' shared serve-event reactor image.  Keeping the
;;;; KATs here (like the pure-tls suites in run-pure-tls-suites.lisp) isolates them.

(load (merge-pathnames "registry.lisp" *load-truename*))

(asdf:load-system :ironclad)
(asdf:load-system :parachute)

(let ((kat (merge-pathnames "../tests/lisp/crypto/kat-tests.lisp" *load-truename*)))
  (handler-bind ((warning #'muffle-warning))
    (load (compile-file kat))))

(let ((report (parachute:test :clun.crypto-test)))
  (sb-ext:exit :code (if (eq (parachute:status report) :passed) 0 1)))
