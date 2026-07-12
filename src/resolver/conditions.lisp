;;;; conditions.lisp — resolver error conditions. The engine maps these to JS
;;;; errors at the loader boundary (module-not-found -> a Node-style Error with
;;;; code ERR_MODULE_NOT_FOUND, etc.). Kept in clun.resolver so the library stays
;;;; engine-free (§3.6).

(in-package :clun.resolver)

(define-condition resolution-error (error)
  ((specifier :initarg :specifier :initform nil :reader resolution-error-specifier)
   (referrer  :initarg :referrer  :initform nil :reader resolution-error-referrer)
   (detail    :initarg :detail    :initform nil :reader resolution-error-detail))
  (:report (lambda (c s)
             (format s "Cannot resolve ~s from ~s~@[: ~a~]"
                     (resolution-error-specifier c)
                     (resolution-error-referrer c)
                     (resolution-error-detail c)))))

;; ERR_MODULE_NOT_FOUND / MODULE_NOT_FOUND
(define-condition module-not-found (resolution-error) ())

;; ERR_PACKAGE_PATH_NOT_EXPORTED — subpath not covered by "exports"
(define-condition package-path-not-exported (resolution-error) ())

;; ERR_INVALID_PACKAGE_TARGET — an "exports"/"imports" target is malformed or
;; escapes the package (e.g. "../x", or not starting with "./").
(define-condition invalid-package-target (resolution-error) ())

;; ERR_INVALID_MODULE_SPECIFIER — the specifier itself is malformed.
(define-condition invalid-package-specifier (resolution-error) ())

;; ERR_UNSUPPORTED_DIR_IMPORT — a directory import with no index/main under ESM.
(define-condition unsupported-directory-import (resolution-error) ())

(defun rerror (type specifier referrer &optional detail)
  (error type :specifier specifier :referrer referrer :detail detail))
