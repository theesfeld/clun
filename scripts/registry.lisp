;;;; registry.lisp — make ASDF find clun + the vendored systems.
;;;; Loaded (not compiled) by the other build scripts. Registers the repo root
;;;; (clun.asd) and every vendor/*/ directory on asdf:*central-registry*.
;;;; No quicklisp, no source-registry :tree scan of the big vendor-data corpora.

(require :asdf)

(defparameter *clun-root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname *load-truename*))
  "Absolute pathname of the repository root (parent of scripts/).")

(pushnew *clun-root* asdf:*central-registry* :test #'equal)

(dolist (dir (directory (merge-pathnames "vendor/*/" *clun-root*)))
  (pushnew dir asdf:*central-registry* :test #'equal))
