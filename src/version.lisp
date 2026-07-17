;;;; version.lisp — release version and build-stamped revision.

(in-package :clun)

(defparameter *clun-version* "0.1.0-dev.13"
  "The clun release version string.")

(defparameter *clun-revision* "unknown"
  "Short git revision; stamped at build time by scripts/build.lisp.")
