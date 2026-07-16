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

(defun platform-name ()
  "Node-style platform string for this host."
  #+linux "linux"
  #+darwin "darwin"
  #-(or linux darwin) (string-downcase (or (software-type) "unknown")))

;;; --- high-resolution time --------------------------------------------------

(defun monotonic-nanoseconds ()
  "Wall-clock time in nanoseconds. NOTE: sb-ext:get-time-of-day is microsecond
resolution, so the low 3 digits are always 000 — a documented divergence from a true
nanosecond clock (Phase 08)."
  (multiple-value-bind (sec usec) (sb-ext:get-time-of-day)
    (+ (* sec 1000000000) (* usec 1000))))

(defun unix-milliseconds ()
  "Current Unix epoch time in integer milliseconds."
  (multiple-value-bind (sec usec) (sb-ext:get-time-of-day)
    (+ (* sec 1000) (floor usec 1000))))

;;; --- memory ----------------------------------------------------------------

(defun heap-bytes-used ()
  "Approximate live dynamic-space bytes (SBCL). Used for process.memoryUsage()."
  (sb-kernel:dynamic-usage))

(defun bytes-consed ()
  (sb-ext:get-bytes-consed))

;;; --- OS info + CSPRNG (Phase 12: node:os, crypto) --------------------------

(defun os-random-bytes (n)
  "N cryptographically-strong random bytes as a (simple-array (unsigned-byte 8) (N)),
read from /dev/urandom via a plain CL binary stream (pure — no foreign code)."
  (let ((buf (make-array n :element-type '(unsigned-byte 8))))
    (with-open-file (in #P"/dev/urandom" :element-type '(unsigned-byte 8))
      (let ((got (read-sequence buf in)))
        (when (< got n) (error "short read from /dev/urandom"))))
    buf))

(defun hostname () (machine-instance))          ; CL: the host name
(defun os-type ()
  (or (software-type)
      #+darwin "Darwin"
      #-darwin "Linux"))
(defun os-release ()
  (or #+linux (%first-line "/proc/sys/kernel/osrelease")
      (software-version)
      ""))
(defun tmpdir () (or (getenv "TMPDIR") (getenv "TMP") (getenv "TEMP") "/tmp"))
(defun homedir () (or (getenv "HOME") ""))

(defun %first-line (path)
  (ignore-errors (with-open-file (in path :if-does-not-exist nil)
                   (and in (read-line in nil nil)))))

(defun %meminfo-kb (key)
  "Bytes for a /proc/meminfo KEY (e.g. \"MemTotal\"), or 0."
  (ignore-errors
   (with-open-file (in "/proc/meminfo" :if-does-not-exist nil)
     (when in
       (loop for line = (read-line in nil nil) while line
             when (and (>= (length line) (length key))
                       (string= key line :end2 (length key)))
               do (let* ((colon (position #\: line))
                         (rest (string-trim " kB" (subseq line (1+ colon)))))
                    (return (* 1024 (or (parse-integer rest :junk-allowed t) 0)))))))))

(defun total-memory ()
  "Total physical memory where the pure substrate can read it; 0 when unavailable."
  #+linux (or (%meminfo-kb "MemTotal") 0)
  #-linux 0)

(defun free-memory ()
  "Available physical memory where the pure substrate can read it; 0 when unavailable."
  #+linux (or (%meminfo-kb "MemAvailable") (%meminfo-kb "MemFree") 0)
  #-linux 0)

(defun uptime-seconds ()
  #+linux
  (let ((line (%first-line "/proc/uptime")))
    (if line (or (ignore-errors (read-from-string line)) 0) 0))
  #-linux 0)

(defun cpu-count ()
  "Number of logical CPUs (count `processor` lines in /proc/cpuinfo); ≥1."
  #+linux
  (max 1 (or (ignore-errors
              (with-open-file (in "/proc/cpuinfo" :if-does-not-exist nil)
                (when in
                  (loop for line = (read-line in nil nil) while line
                        count (and (>= (length line) 9) (string= "processor" line :end2 9))))))
             1))
  #-linux 1)
