;;;; smoke.lisp — build/test rails (Phase 00). Real coverage lives in engine/.

(in-package :clun-test)

(define-test parachute-rails
  (is = 4 (+ 2 2))
  (true (stringp "clun"))
  (false (null '(t))))

(define-test version-loaded
  (true (fboundp 'clun:main))
  (is string= "0.1.0-dev.57" clun::*clun-version*))
