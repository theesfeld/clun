;;;; fs.lisp — the minimal filesystem primitives the resolver + module loader
;;;; need (PLAN.md §3.2: sb-posix + CL streams; realpath via `truename`). Engine-
;;;; free. All paths are POSIX strings; every crossing into a pathname goes through
;;;; native->pathname (paths.lisp) so `[`-bearing names don't crash SBCL.

(in-package :clun.sys)

(defun %stat (path)
  "sb-posix:stat PATH, or NIL if it doesn't exist / can't be stat'd. A stat on a
symlink follows it (S_IFLNK never appears)."
  (handler-case (sb-posix:stat (native->pathname path))
    (sb-posix:syscall-error () nil)
    (file-error () nil)))

(defun path-exists-p (path)
  "True iff PATH names an existing filesystem entry (following symlinks)."
  (and (%stat path) t))

(defconstant +s-ifmt+  #o170000)
(defconstant +s-ifreg+ #o100000)
(defconstant +s-ifdir+ #o040000)

(defun file-p (path)
  "True iff PATH is (or points, via symlink, at) a regular file."
  (let ((s (%stat path)))
    (and s (= (logand (sb-posix:stat-mode s) +s-ifmt+) +s-ifreg+))))

(defun directory-p (path)
  "True iff PATH is (or points, via symlink, at) a directory."
  (let ((s (%stat path)))
    (and s (= (logand (sb-posix:stat-mode s) +s-ifmt+) +s-ifdir+))))

(defun realpath (path)
  "Canonical absolute path of PATH with all symlinks resolved — via `truename`
(Appendix C.8: sb-posix has no realpath; truename resolves symlink chains). Returns
a POSIX string, or NIL for a nonexistent / dangling-symlink target (truename
signals FILE-ERROR there — we swallow it rather than crash the loader)."
  (handler-case
      (pathname->native (truename (native->pathname path)))
    (file-error () nil)
    (sb-posix:syscall-error () nil)))

(defun read-file-string (path &key (external-format :utf-8))
  "Read PATH fully into a string. Signals FILE-ERROR if it can't be opened."
  (with-open-file (in (native->pathname path)
                      :direction :input
                      :external-format external-format
                      :element-type 'character)
    (let ((buf (make-string (file-length in))))
      ;; file-length is byte count; UTF-8 may shrink it — use the fill pointer.
      (let ((n (read-sequence buf in)))
        (subseq buf 0 n)))))

(defun read-directory (path)
  "The entry names in directory PATH (files + subdirs, no `.`/`..`), as strings;
NIL if not a dir. Uses uiop's pure-CL directory walk (sb-posix:readdir yields a raw
dirent whose low-level accessors are unsafe here and barred by the purity gate)."
  (when (directory-p path)
    (let ((dir (native->pathname
                (if (and (plusp (length path))
                         (char= (char path (1- (length path))) #\/))
                    path
                    (concatenate 'string path "/")))))
      (flet ((leaf (native) ; the final path segment of a native namestring
               (let* ((s (if (and (plusp (length native))
                                  (char= (char native (1- (length native))) #\/))
                             (subseq native 0 (1- (length native)))
                             native))
                      (slash (position #\/ s :from-end t)))
                 (if slash (subseq s (1+ slash)) s))))
        ;; Use native namestrings (not file-namestring, which ESCAPES wildcard chars
        ;; like `[` — breaking round-trip) so names come back verbatim.
        (nconc
         (mapcar (lambda (f) (leaf (pathname->native f))) (uiop:directory-files dir))
         (mapcar (lambda (d) (leaf (pathname->native d))) (uiop:subdirectories dir)))))))
