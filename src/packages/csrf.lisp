;;;; packages/csrf.lisp — clun.csrf package (first packages.lisp split; Elon P3 / #318).
(defpackage :clun.csrf
  (:use :cl)
  (:local-nicknames (:crypto :ironclad))
  (:documentation "Engine-free bounded CSRF token encoding, authentication, and expiry.")
  (:export #:core-generate #:core-verify))
