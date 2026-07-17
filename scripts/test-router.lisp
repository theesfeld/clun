;;;; test-router.lisp -- focused Phase 50 immutable router-core assertions.

(load (merge-pathnames "registry.lisp" *load-truename*))
(asdf:load-system :clun/tests)

(let ((passed t))
  (dolist (name
           '(clun-test::net/router-precedence-params-and-query
             clun-test::net/router-method-fallthrough-and-head
             clun-test::net/router-percent-decoding-and-absolute-form
             clun-test::net/router-validation
             clun-test::net/router-installs-decoded-params
             clun-test::net/router-file-range-parser
             clun-test::net/router-http-conditional-parsers
             clun-test::net/router-file-responses-defer-open-until-write-turn))
    (unless (eq (parachute:status (parachute:test name)) :passed)
      (setf passed nil)))
  (sb-ext:exit :code (if passed 0 1)))
