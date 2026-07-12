;;;; paths.lisp — path discipline (PLAN.md §3.2, line 204). Every user-supplied
;;;; path crosses `sb-ext:parse-native-namestring` / `native-namestring` HERE and
;;;; only here: raw strings bearing `[` crash SBCL pathname parsing (Appendix C.9,
;;;; verified). The rest of the tree passes plain POSIX path STRINGS around and
;;;; calls into clun.sys at the boundaries. These ops are lexical (no fs access).

(in-package :clun.sys)

(defun native->pathname (path)
  "A user path STRING -> a CL pathname, safely (handles `[`, `~`, etc.)."
  (sb-ext:parse-native-namestring path))

(defun pathname->native (pathname)
  "A CL pathname -> a user path STRING."
  (sb-ext:native-namestring pathname))

(defun absolute-path-p (path)
  "True iff PATH (a POSIX string) is absolute (starts with `/`)."
  (and (plusp (length path)) (char= (char path 0) #\/)))

(defun %split (path)
  "Split a POSIX path STRING into its `/`-separated segments (no empties)."
  (loop with start = 0
        for i from 0 to (length path)
        when (or (= i (length path)) (char= (char path i) #\/))
          when (> i start) collect (subseq path start i) end
          and do (setf start (1+ i))))

(defun path-join (&rest parts)
  "Join POSIX path segments with `/`. An absolute PART resets the accumulation
(Node's path.join keeps concatenating, but our callers only join a base dir with
relative pieces; an absolute piece should win — matching path.resolve semantics
for the cases the resolver needs). Empty parts are ignored."
  (let ((acc nil))
    (dolist (p parts)
      (when (and p (plusp (length p)))
        (if (absolute-path-p p)
            (setf acc p)
            (setf acc (if (or (null acc) (zerop (length acc)))
                          p
                          (concatenate 'string acc
                                       (if (char= (char acc (1- (length acc))) #\/) "" "/")
                                       p))))))
    (or acc "")))

(defun path-dirname (path)
  "The directory portion of PATH (POSIX). `/a/b`->`/a`, `/a`->`/`, `a`->`.`."
  (let ((slash (position #\/ path :from-end t)))
    (cond ((null slash) ".")
          ((zerop slash) "/")
          (t (subseq path 0 slash)))))

(defun path-basename (path)
  "The final segment of PATH (POSIX), sans trailing slash."
  (let* ((end (if (and (> (length path) 1) (char= (char path (1- (length path))) #\/))
                  (1- (length path)) (length path)))
         (slash (position #\/ path :from-end t :end end)))
    (subseq path (if slash (1+ slash) 0) end)))

(defun path-extension (path)
  "The extension of PATH including the dot (e.g. `.js`), or \"\" if none. A leading
dot on the basename (a dotfile) is not an extension."
  (let* ((base (path-basename path))
         (dot (position #\. base :from-end t)))
    (if (and dot (plusp dot)) (subseq base dot) "")))

(defun normalize-path (path)
  "Lexically collapse `.` and `..` segments (no fs access). Preserves leading `/`.
A `..` above an absolute root is dropped; above a relative root it is kept."
  (let ((abs (absolute-path-p path))
        (out '()))
    (dolist (seg (%split path))
      (cond ((string= seg ".") nil)
            ((string= seg "..")
             (cond ((and out (not (string= (first out) "..")))
                    (pop out))
                   ((not abs) (push seg out))
                   (t nil)))
            (t (push seg out))))
    (let ((body (format nil "~{~a~^/~}" (nreverse out))))
      (cond (abs (concatenate 'string "/" body))
            ((zerop (length body)) ".")
            (t body)))))
