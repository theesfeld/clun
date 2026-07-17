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

;;; --- fs error mapping (Phase 13): sb-posix errno -> a code-carrying condition -----
;;; Defined before the first with-fs use (read-file-string) so the macro is available
;;; at compile time; the %raise-* functions it names are forward references (fine).

(define-condition fs-error (error)
  ((code :initarg :code :reader fs-error-code)         ; "ENOENT" etc.
   (errno :initarg :errno :reader fs-error-errno)      ; integer
   (syscall :initarg :syscall :reader fs-error-syscall)
   (path :initarg :path :reader fs-error-path))
  (:report (lambda (c s) (format s "~a: ~a, ~a '~a'"
                                 (fs-error-code c) (fs-code-message (fs-error-code c))
                                 (fs-error-syscall c) (fs-error-path c)))))

(defparameter *errno-names*
  ;; errno integer -> POSIX name, built from the sb-posix constants present on this host.
  (let ((tbl (make-hash-table)))
    (dolist (name '("EPERM" "ENOENT" "ESRCH" "EINTR" "EIO" "EBADF" "EAGAIN" "ENOMEM"
                    "EACCES" "EFAULT" "EBUSY" "EEXIST" "EXDEV" "ENODEV" "ENOTDIR"
                    "EISDIR" "EINVAL" "ENFILE" "EMFILE" "ENOTTY" "EFBIG" "ENOSPC"
                    "ESPIPE" "EROFS" "EMLINK" "EPIPE" "ENAMETOOLONG" "ENOTEMPTY"
                    "ELOOP" "EOVERFLOW"))
      (let ((sym (find-symbol name :sb-posix)))
        (when (and sym (boundp sym)) (setf (gethash (symbol-value sym) tbl) name))))
    tbl))

(defun %errno-name (n) (or (gethash n *errno-names*) (format nil "E~a" n)))
(defun %errno-of-name (code)
  "The POSIX errno integer for a code name (\"ENOENT\" -> 2), or 0 if unknown on this host."
  (let ((sym (find-symbol code :sb-posix)))
    (if (and sym (boundp sym)) (symbol-value sym) 0)))
(defun fs-code-message (code)
  "The human description Node embeds in an fs error message, keyed by CODE — so both
the condition :report and the runtime's JS Error share one table."
  (or (cdr (assoc code '(("ENOENT" . "no such file or directory") ("EEXIST" . "file already exists")
                         ("EACCES" . "permission denied") ("ENOTDIR" . "not a directory")
                         ("EISDIR" . "illegal operation on a directory") ("ENOTEMPTY" . "directory not empty")
                         ("EPERM" . "operation not permitted") ("ELOOP" . "too many symbolic links encountered")
                         ("EINVAL" . "invalid argument"))
                 :test #'string=))
      "I/O error"))
(defun %errno-message (n) (fs-code-message (%errno-name n)))

(defun %raise-fs (syscall path sb-err)
  (let ((errno (ignore-errors (sb-posix:syscall-errno sb-err))))
    (error 'fs-error :code (%errno-name (or errno 0)) :errno (or errno 0)
                     :syscall syscall :path path)))

(defun %raise-fs-file (syscall path)
  "Map a CL file-error (open on a missing/dir/unreadable path) to an errno code by probing.
Fill errno from the code so callers can report Node's negative libuv errno (-errno)."
  (let ((code (cond ((not (path-exists-p path)) "ENOENT")
                    ((directory-p path) "EISDIR")
                    (t "EACCES"))))
    (error 'fs-error :errno (%errno-of-name code) :syscall syscall :path path :code code)))

(defmacro with-fs ((syscall path) &body body)
  "Run BODY; map sb-posix:syscall-error (errno) or a CL file-error to an fs-error."
  (let ((sc (gensym)) (p (gensym)) (e (gensym)))
    `(let ((,sc ,syscall) (,p ,path))
       (handler-case (progn ,@body)
         (sb-posix:syscall-error (,e) (%raise-fs ,sc ,p ,e))
         (file-error (,e) (declare (ignore ,e)) (%raise-fs-file ,sc ,p))))))

(defun read-file-string (path &key (external-format :utf-8))
  "Read PATH fully into a string. Signals fs-error (ENOENT/EISDIR/EACCES) if it
can't be opened, so callers above the engine boundary get a catchable JS error
rather than a raw Lisp backtrace (§6)."
  (when (directory-p path)
    (error 'fs-error :code "EISDIR" :errno (%errno-of-name "EISDIR") :syscall "read" :path path))
  (with-fs ("open" path)
    (with-open-file (in (native->pathname path)
                        :direction :input
                        :external-format external-format
                        :element-type 'character)
      (let ((buf (make-string (file-length in))))
        ;; file-length is byte count; UTF-8 may shrink it — use the fill pointer.
        (let ((n (read-sequence buf in)))
          (subseq buf 0 n))))))

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

(defun map-directory-entries (path function)
  "Call FUNCTION once for each immediate entry name in PATH.

Unlike READ-DIRECTORY, this preserves dangling symbolic links and does not
classify links by following them. FUNCTION runs while SBCL owns the directory
stream, so callers can cooperatively cancel without retaining a directory-sized
pathname list. Filesystem failures remain FS-ERROR conditions."
  (labels ((leaf-name (pathname)
             (let* ((native (pathname->native pathname))
                    (end (if (and (> (length native) 1)
                                  (char= (char native (1- (length native))) #\/))
                             (1- (length native))
                             (length native)))
                    (slash (position #\/ native :from-end t :end end)))
               (subseq native (if slash (1+ slash) 0) end))))
    (with-fs ("scandir" path)
      (let ((fd nil))
        (unwind-protect
             (progn
               ;; Mapping through the open descriptor keeps SBCL's callback
               ;; pathname short. Mapping PATH directly can silently omit an
               ;; immediate child when PATH/NAME crosses PATH_MAX, even though
               ;; PATH itself is openable and readdir returned the name.
               (setf fd (sb-posix:open (native->pathname path) sb-posix:o-rdonly))
               (let ((directory-path
                       (native->pathname
                        (format nil "~a/~d/"
                                (if (string= (platform-name) "darwin")
                                    "/dev/fd" "/proc/self/fd")
                                fd))))
                 (sb-ext:map-directory
                  (lambda (entry) (funcall function (leaf-name entry)))
                  directory-path
                  :files t
                  :directories :as-files
                  :classify-symlinks nil
                  :errorp t)))
          (when fd (ignore-errors (sb-posix:close fd)))))))
  nil)

;;; --- stat ------------------------------------------------------------------

(defstruct (fstat (:conc-name fstat-))
  dev ino mode nlink uid gid rdev size
  atime-ns mtime-ns ctime-ns)          ; nanosecond-scaled ints (seconds*1e9; §3.2 sec granularity)

(defun %stat->fstat (s)
  (flet ((acc (name) (let ((sym (find-symbol name :sb-posix)))
                       (if (and sym (fboundp sym)) (funcall sym s) 0)))
         (sec-ns (v) (* (truncate v) 1000000000)))
    (make-fstat :dev (acc "STAT-DEV") :ino (acc "STAT-INO") :mode (acc "STAT-MODE")
                :nlink (acc "STAT-NLINK") :uid (acc "STAT-UID") :gid (acc "STAT-GID")
                :rdev (acc "STAT-RDEV") :size (acc "STAT-SIZE")
                :atime-ns (sec-ns (acc "STAT-ATIME")) :mtime-ns (sec-ns (acc "STAT-MTIME"))
                :ctime-ns (sec-ns (acc "STAT-CTIME")))))

(defun stat* (path &key lstat)
  "stat (or lstat) PATH -> an fstat; signals fs-error on failure."
  (with-fs ((if lstat "lstat" "stat") path)
    (%stat->fstat (funcall (if lstat #'sb-posix:lstat #'sb-posix:stat) (native->pathname path)))))

(defun stat-at* (directory name &key lstat)
  "Classify immediate NAME relative to DIRECTORY without an OS-sized path join.

The logical result path may exceed PATH_MAX while DIRECTORY is still openable.
Linux and macOS expose an open descriptor through a short filesystem path, which
lets the existing SB-POSIX boundary classify that final entry without a native
extension or a process-global chdir. Errors retain the logical joined path."
  (let ((logical-path (path-join directory name))
        (fd nil))
    (with-fs ((if lstat "lstat" "stat") logical-path)
      (unwind-protect
           (progn
             (setf fd (sb-posix:open (native->pathname directory) sb-posix:o-rdonly))
             (let ((entry-path
                     (format nil "~a/~d/~a"
                             (if (string= (platform-name) "darwin")
                                 "/dev/fd" "/proc/self/fd")
                             fd name)))
               (%stat->fstat
                (funcall (if lstat #'sb-posix:lstat #'sb-posix:stat)
                         (native->pathname entry-path)))))
        (when fd (ignore-errors (sb-posix:close fd)))))))

(defun fstat-file-p (st) (= (logand (fstat-mode st) +s-ifmt+) +s-ifreg+))
(defun fstat-dir-p (st) (= (logand (fstat-mode st) +s-ifmt+) +s-ifdir+))
(defconstant +s-iflnk+ #o120000)
(defun fstat-symlink-p (st) (= (logand (fstat-mode st) +s-ifmt+) +s-iflnk+))

;;; --- mutating ops ----------------------------------------------------------

(defun make-directory (path &key recursive (mode #o777))
  "Create PATH. With :recursive, create missing ancestors too and return the TOPMOST
newly-created directory (Node's mkdirSync recursive return), or NIL if nothing was
created. Non-recursive returns NIL (Node returns undefined there)."
  (if recursive
      (let ((parent (path-dirname path)))
        (cond
          ((path-exists-p path) nil)
          (t (let ((ancestor
                     (when (and (plusp (length parent)) (not (string= parent path))
                                (not (path-exists-p parent)))
                       (make-directory parent :recursive t :mode mode))))
               (with-fs ("mkdir" path) (sb-posix:mkdir (native->pathname path) mode))
               (or ancestor path)))))
      (progn (with-fs ("mkdir" path) (sb-posix:mkdir (native->pathname path) mode)) nil)))

(defun remove-directory (path) (with-fs ("rmdir" path) (sb-posix:rmdir (native->pathname path))))
(defun remove-file (path) (with-fs ("unlink" path) (sb-posix:unlink (native->pathname path))))
(defun rename-path (old new)
  (with-fs ("rename" old) (sb-posix:rename (native->pathname old) (native->pathname new))))
(defun make-symlink (target linkpath)
  (with-fs ("symlink" linkpath) (sb-posix:symlink (native->pathname target) (native->pathname linkpath))))
(defun read-symlink (path) (with-fs ("readlink" path) (sb-posix:readlink (native->pathname path))))
(defun change-mode (path mode) (with-fs ("chmod" path) (sb-posix:chmod (native->pathname path) mode)))
(defun truncate-file (path len) (with-fs ("truncate" path) (sb-posix:truncate (native->pathname path) len)))
(defun make-temp-dir (prefix)
  "mkdtemp: PREFIX + 'XXXXXX' -> a created unique dir path (POSIX string)."
  (with-fs ("mkdtemp" prefix)
    (pathname->native (sb-posix:mkdtemp (concatenate 'string prefix "XXXXXX")))))

(defun check-access (path &optional (mode 0))
  (with-fs ("access" path) (sb-posix:access (native->pathname path) mode)) t)

(defun remove-recursive (path)
  "rm -rf PATH (best-effort, follows the tree via lstat so symlinks aren't descended)."
  (let ((st (ignore-errors (stat* path :lstat t))))
    (cond ((null st) nil)
          ((fstat-dir-p st)
           (dolist (e (read-directory path)) (remove-recursive (path-join path e)))
           (remove-directory path))
          (t (remove-file path)))))

;;; --- octet I/O (Buffer/fs bodies) ------------------------------------------

(defun read-file-octets (path)
  "Read PATH fully into a fresh (unsigned-byte 8) vector; signals fs-error on failure.
Reading a directory is EISDIR (opening a dir stream signals a non-file-error otherwise)."
  (when (directory-p path)
    (error 'fs-error :code "EISDIR" :errno (%errno-of-name "EISDIR") :syscall "read" :path path))
  (with-fs ("open" path)
    (with-open-file (in (native->pathname path) :element-type '(unsigned-byte 8))
      (let ((buf (make-array (file-length in) :element-type '(unsigned-byte 8))))
        (subseq buf 0 (read-sequence buf in))))))

(defun write-file-octets (path octets &key append (mode #o666))
  "Write OCTETS (a byte vector) to PATH (truncate or :append)."
  (declare (ignore mode))
  (with-fs ("open" path)
    (with-open-file (out (native->pathname path) :direction :output :element-type '(unsigned-byte 8)
                         :if-exists (if append :append :supersede) :if-does-not-exist :create)
      (write-sequence octets out)))
  (length octets))

(defun copy-file* (src dst) (write-file-octets dst (read-file-octets src)))
