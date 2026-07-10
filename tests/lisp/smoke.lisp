;;;; smoke.lisp — Phase 00 parachute smoke suite: proves the build/test rails
;;;; work end to end. Real coverage begins in Phase 01.

(defpackage :clun-test
  (:use :cl)
  (:import-from :parachute #:define-test #:is #:true #:false))

(in-package :clun-test)

(define-test parachute-rails
  (is = 4 (+ 2 2))
  (true (stringp "clun"))
  (false (null '(t))))

(define-test version-loaded
  (is string= "0.0.1-dev" clun::*clun-version*)
  (true (fboundp 'clun:main)))
