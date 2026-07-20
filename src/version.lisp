;;;; version.lisp — release version and build-stamped revision.

(in-package :clun)

(defparameter *clun-version* "0.2.0-dev.9"
  "The clun release version string.")

(defparameter *clun-revision* "unknown"
  "Git revision stamp filled by scripts/build.lisp at image-save time.")
