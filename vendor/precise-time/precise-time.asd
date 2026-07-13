;; clun purity patch (Phase 19): upstream pulls a foreign-lib dep + its posix/darwin/
;; windows/nx files make a C clock_gettime foreign call. We drop that dependency, replace
;; posix.lisp with a pure sb-unix:clock-gettime implementation, and delete the darwin/
;; windows/nx foreign files (§1.1 purity; §3.4). See DECISIONS.md.
(asdf:defsystem precise-time
  :version "1.0.0"
  :license "zlib"
  :author "Yukari Hafner <shinmera@tymoon.eu>"
  :maintainer "Yukari Hafner <shinmera@tymoon.eu>"
  :description "Precise time measurements"
  :homepage "https://shinmera.com/docs/precise-time/"
  :serial T
  :components ((:file "package")
               (:file "protocol")
               (:file "posix" :if-feature :unix)
               (:file "mezzano" :if-feature :mezzano)
               (:file "documentation"))
  :defsystem-depends-on (:trivial-features)
  :depends-on (:documentation-utils)
  :in-order-to ((asdf:test-op (asdf:test-op :precise-time/test))))

(asdf:defsystem precise-time/test
  :version "1.0.0"
  :license "zlib"
  :serial T
  :components ((:file "test"))
  :depends-on (:precise-time :parachute)
  :perform (asdf:test-op (op c) (uiop:symbol-call :parachute :test :org.shirakumo.precise-time.test)))
