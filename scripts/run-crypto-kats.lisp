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

;; Execute the registered Ironclad SHA-512/256 vector file through Ironclad's
;; own generated-vector reader without loading/running the unrelated full
;; ironclad/tests system (whose optional RT dependency is not vendored here).
(let* ((testfuns (merge-pathnames
                  "../vendor/ironclad/testing/testfuns.lisp"
                  *load-truename*)))
  (unless (find-package :crypto-tests)
    (error "Ironclad test package was not defined while loading ironclad.asd"))
  (let ((*compile-file-pathname* testfuns))
    (load testfuns))
  (let* ((package (find-package :crypto-tests))
         (runner (symbol-function (find-symbol "RUN-TEST-VECTOR-FILE" package)))
         (maps (mapcar (lambda (name)
                         (symbol-value (find-symbol name package)))
                       '("*DIGEST-TESTS*"
                         "*DIGEST-INCREMENTAL-TESTS*"
                         "*DIGEST-REINITIALIZE-INSTANCE-TESTS*"))))
    (dolist (test-map maps)
      (unless (funcall runner :sha512/256 test-map)
        (error "Ironclad SHA-512/256 generated vector suite failed"))))
  (format t "Ironclad SHA-512/256 generated vectors: base/incremental/reset pass~%"))

(let ((kat (merge-pathnames "../tests/lisp/crypto/kat-tests.lisp" *load-truename*)))
  (handler-bind ((warning #'muffle-warning))
    (load (compile-file kat))))

(let ((report (parachute:test :clun.crypto-test)))
  (sb-ext:exit :code (if (eq (parachute:status report) :passed) 0 1)))
