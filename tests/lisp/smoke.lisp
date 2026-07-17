;;;; smoke.lisp — build/test rails (Phase 00). Real coverage lives in engine/.

(in-package :clun-test)

(define-test parachute-rails
  (is = 4 (+ 2 2))
  (true (stringp "clun"))
  (false (null '(t))))

(define-test version-loaded
  (is string= "0.1.0-dev.15" clun::*clun-version*)
  (true (fboundp 'clun:main)))
