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
  "Approximate live dynamic-space bytes (SBCL)."
  (sb-kernel:dynamic-usage))

(defun resident-set-bytes ()
  "Current resident-set bytes on Linux, peak resident-set bytes on Darwin,
and live heap bytes only when neither operating-system measurement is available."
  (or
   #+linux
   (ignore-errors
    (let ((*read-eval* nil))
      (with-open-file (stream #P"/proc/self/statm" :if-does-not-exist nil)
        (when stream
          (read stream nil nil)
          (let ((resident-pages (read stream nil nil)))
            (and (integerp resident-pages)
                 (* resident-pages (sb-posix:getpagesize))))))))
   ;; Darwin exposes peak rather than current RSS through getrusage. It remains
   ;; a real resident-set measurement and is preferable to reporting heap bytes.
   #+darwin
   (ignore-errors
    (let ((peak-rss (nth 5 (multiple-value-list
                            (sb-unix:unix-getrusage sb-unix:rusage_self)))))
      (and (integerp peak-rss) peak-rss)))
   (heap-bytes-used)))

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

(defun loadavg ()
  "Three load averages as a list of double-floats (1/5/15 min). Reads /proc/loadavg
on Linux; zeros only when the platform provides no pure-CL source."
  #+linux
  (or (ignore-errors
        (let ((line (%first-line "/proc/loadavg")))
          (when line
            (with-input-from-string (in line)
              (list (float (read in) 1d0)
                    (float (read in) 1d0)
                    (float (read in) 1d0))))))
      (list 0d0 0d0 0d0))
  #-linux (list 0d0 0d0 0d0))

(defun %cpuinfo-blocks ()
  "Parse /proc/cpuinfo into a list of alists ((key . value) ...), one per processor."
  #+linux
  (ignore-errors
    (with-open-file (in "/proc/cpuinfo" :if-does-not-exist nil)
      (when in
        (let ((blocks '()) (cur '()))
          (loop for line = (read-line in nil nil)
                while line
                do (cond
                     ((zerop (length line))
                      (when cur (push (nreverse cur) blocks) (setf cur '())))
                     (t (let ((colon (position #\: line)))
                          (when colon
                            (push (cons (string-trim '(#\Space #\Tab)
                                                     (subseq line 0 colon))
                                        (string-trim '(#\Space #\Tab)
                                                     (subseq line (1+ colon))))
                                  cur))))))
          (when cur (push (nreverse cur) blocks))
          (nreverse blocks)))))
  #-linux nil)

(defun %cpu-times-jiffies ()
  "Per-cpu times from /proc/stat as lists of (user nice system idle iowait irq softirq).
Values are jiffies converted to milliseconds assuming USER_HZ=100."
  #+linux
  (ignore-errors
    (with-open-file (in "/proc/stat" :if-does-not-exist nil)
      (when in
        (let ((hz 100d0) (out '()))
          (loop for line = (read-line in nil nil) while line
                when (and (>= (length line) 4)
                          (char= (char line 0) #\c)
                          (char= (char line 1) #\p)
                          (char= (char line 2) #\u)
                          (digit-char-p (char line 3)))
                  do (with-input-from-string (s (subseq line (position #\Space line)))
                       (flet ((ms () (* (float (or (read s nil 0) 0) 1d0) (/ 1000d0 hz))))
                         (push (list (ms) (ms) (ms) (ms) (ms) (ms) (ms)) out))))
          (nreverse out)))))
  #-linux nil)

(defun cpu-infos ()
  "List of plists describing each logical CPU: :model :speed :user :nice :sys :idle :irq
(milliseconds). Pure /proc reads on Linux."
  (let* ((blocks (%cpuinfo-blocks))
         (times (%cpu-times-jiffies))
         (n (max 1 (or (and blocks (length blocks)) (cpu-count)))))
    (loop for i below n
          for block = (nth i blocks)
          for tms = (nth i times)
          collect (list :model (or (cdr (assoc "model name" block :test #'string-equal))
                                   (cdr (assoc "Hardware" block :test #'string-equal))
                                   "unknown")
                        :speed (let ((mhz (or (cdr (assoc "cpu MHz" block :test #'string-equal))
                                              (cdr (assoc "BogoMIPS" block :test #'string-equal)))))
                                  (if mhz
                                      (or (ignore-errors (truncate (read-from-string mhz))) 0)
                                      0))
                        :user (or (first tms) 0d0)
                        :nice (or (second tms) 0d0)
                        :sys (or (third tms) 0d0)
                        :idle (or (fourth tms) 0d0)
                        :irq (or (sixth tms) 0d0)))))

(defun getuid () (ignore-errors (sb-posix:getuid)))
(defun getgid () (ignore-errors (sb-posix:getgid)))
(defun geteuid () (ignore-errors (sb-posix:geteuid)))
(defun getegid () (ignore-errors (sb-posix:getegid)))
