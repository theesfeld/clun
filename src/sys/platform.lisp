;;;; platform.lisp — the pure-SBCL platform primitives the runtime layer needs for
;;;; `process` and `console` (PLAN.md §3.6, Phase 08). All sb-posix/sb-unix/sb-ext/
;;;; sb-kernel (allowed contribs — no foreign code). Quarantined here so the runtime
;;;; and CLI never touch internal SBCL APIs directly.

(in-package :clun.sys)

;;; --- TTY -------------------------------------------------------------------

(defun stream-fd (stream)
  "The underlying file descriptor of STREAM, or NIL if it isn't an fd-stream."
  (ignore-errors (sb-sys:fd-stream-fd stream)))

(defun tty-p (stream)
  "True iff STREAM is connected to a terminal (sb-posix has no isatty; sb-unix does)."
  (let ((fd (stream-fd stream)))
    (and fd (not (zerop (sb-unix:unix-isatty fd))))))

;;; --- environment -----------------------------------------------------------

(defun environ-alist ()
  "The process environment as a list of (NAME . VALUE) string conses (split on the
first `=`), preserving order."
  (loop for entry in (sb-ext:posix-environ)
        for eq = (position #\= entry)
        when eq collect (cons (subseq entry 0 eq) (subseq entry (1+ eq)))))

(defun getenv (name &optional default)
  (or (sb-ext:posix-getenv name) default))

;;; --- process identity + working directory ----------------------------------

(defun getpid () (sb-posix:getpid))

(defun current-directory ()
  "The process cwd as a POSIX string (no trailing slash except at root)."
  (let ((d (sb-posix:getcwd)))
    (if (and (> (length d) 1) (char= (char d (1- (length d))) #\/))
        (subseq d 0 (1- (length d)))
        d)))

(defun change-directory (path)
  "chdir to PATH (a POSIX string), through path discipline. Signals on failure."
  (sb-posix:chdir (native->pathname path))
  (current-directory))

(defun machine-arch ()
  "Node-style arch string for this host."
  (let ((m (machine-type)))
    (cond ((search "X86-64" m) "x64")
          ((search "X86" m) "ia32")
          ((or (search "ARM64" m) (search "AARCH64" m)) "arm64")
          ((search "ARM" m) "arm")
          (t (string-downcase m)))))

(defun platform-name () "linux")

;;; --- high-resolution time --------------------------------------------------

(defun monotonic-nanoseconds ()
  "Wall-clock time in nanoseconds. NOTE: sb-ext:get-time-of-day is microsecond
resolution, so the low 3 digits are always 000 — a documented divergence from a true
nanosecond clock (Phase 08)."
  (multiple-value-bind (sec usec) (sb-ext:get-time-of-day)
    (+ (* sec 1000000000) (* usec 1000))))

;;; --- memory ----------------------------------------------------------------

(defun heap-bytes-used ()
  "Approximate live dynamic-space bytes (SBCL). Used for process.memoryUsage()."
  (sb-kernel:dynamic-usage))

(defun bytes-consed ()
  (sb-ext:get-bytes-consed))
