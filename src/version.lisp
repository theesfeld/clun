;;;; version.lisp — release version and build-stamped revision.

(in-package :clun)

(defparameter *clun-version* "0.1.0-dev.32"
  "The clun release version string.")

(defparameter *clun-revision* "unknown"
  "Git revision stamp filled by scripts/build.lisp at image-save time.")
