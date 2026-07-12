;;;; package-json.lisp — reading + caching package.json, nearest-package lookup,
;;;; and "type" detection. Pure over clun.sys fs primitives (engine-free).

(in-package :clun.resolver)

;;; A per-resolve cache avoids re-reading + re-parsing the same package.json many
;;; times during one resolution. Bound by `resolve` (below); NIL => no caching.
(defvar *pjson-cache* nil)

(defun read-package-json (dir)
  "Read + parse DIR/package.json, returning the parsed JSON object (an alist) or
NIL if it doesn't exist / can't be parsed. Cached under *pjson-cache* by DIR."
  (let ((path (sys:path-join dir "package.json")))
    (flet ((load-it ()
             (when (sys:file-p path)
               (handler-case (sys:parse-json (sys:read-file-string path))
                 (error () nil)))))
      (if *pjson-cache*
          (multiple-value-bind (cached present) (gethash dir *pjson-cache*)
            (if present cached (setf (gethash dir *pjson-cache*) (load-it))))
          (load-it)))))

(defun nearest-package-json (start-dir)
  "Walk up from START-DIR looking for a package.json. Returns (values pjson dir)
of the nearest one, or (values NIL NIL). Stops at the filesystem root. A
node_modules boundary does NOT stop the search (Node walks through it for `type`)."
  (loop for dir = start-dir then (sys:path-dirname dir)
        for pj = (read-package-json dir)
        when pj do (return (values pj dir))
        when (or (string= dir "/") (string= dir ".") (string= dir ""))
          do (return (values nil nil))))

(defun package-type (start-dir)
  "The effective module type for a `.js` file under START-DIR: :module iff the
nearest package.json has \"type\":\"module\", else :commonjs (Node's default)."
  (let ((pj (nearest-package-json start-dir)))
    (if (and pj (equal (jstr (jget* pj "type")) "module"))
        :module
        :commonjs)))

;;; --- small helpers over the clun.sys JSON representation --------------------

(defun jget* (object key &optional default)
  "clun.sys:jget, tolerant of the :empty-object sentinel and non-objects."
  (if (sys:jobject-p object) (sys:jget object key default) default))

(defun jstr (v)
  "V as a Lisp string if it is a JSON string, else NIL."
  (and (stringp v) v))

(defun jobj-p (v) (sys:jobject-p v))

(defun jarray-p (v) (and (vectorp v) (not (stringp v))))
