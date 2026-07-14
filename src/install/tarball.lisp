;;;; tarball.lisp — a read-only ustar/pax tar reader + a hardened, verify-then-commit extractor
;;;; for npm package tarballs (PLAN.md Phase 22, §3.5). cl-tar's extractor pulls in a foreign
;;;; filesystem binding (disqualified by the purity contract), so this is hand-rolled. The
;;;; extractor's single invariant: every directory in a write path under
;;;; the staging dir is a REAL directory we created; absolute / `..` / NUL names are refused before
;;;; use; symlink & hardlink TARGETS that escape are refused — so the archive can never cause a
;;;; write outside its destination. SRI sha512 is verified BEFORE anything is extracted; extraction
;;;; lands in a temp dir and is atomically renamed in, so a failure commits nothing. Pure CL
;;;; (chipz inflate + sb-posix via clun.sys), no engine.

(in-package :clun.tarball)

(define-condition tarball-error (error)
  ((message :initarg :message :reader tarball-error-message :initform "tarball error"))
  (:report (lambda (c s) (write-string (tarball-error-message c) s))))

(defparameter *max-inflated-bytes* (* 512 1024 1024)
  "Hard cap on a single tarball's inflated size — a zip bomb hits this and signals rather than
exhausting the heap (§6: bound every size from the wire).")
(defparameter *max-entry-size* (* 512 1024 1024)
  "Hard cap on one entry's declared size before it is used to slice the buffer.")
(defconstant +block-size+ 512)

;;; --- bounded gzip inflate ---------------------------------------------------

(defun inflate-gzip (octets &key (max-bytes *max-inflated-bytes*))
  "Gunzip OCTETS through a decompressing stream with a hard output cap. Returns the tar bytes as a
(simple-array (unsigned-byte 8)). A malformed/truncated/corrupt gzip stream, or the cap being
exceeded, signals tarball-error — never a raw chipz condition (the reader must never emit a raw
Lisp error on a hostile input)."
  (handler-case
      (flexi-streams:with-input-from-sequence (in octets)
        (let ((ds (chipz:make-decompressing-stream 'chipz:gzip in))
              (out (make-array (* 256 1024) :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
              (buf (make-array (* 64 1024) :element-type '(unsigned-byte 8))))
          (loop for n = (read-sequence buf ds)
                while (plusp n) do
                  (when (> (+ (fill-pointer out) n) max-bytes)
                    (error 'tarball-error :message "gzip inflate exceeded the size cap (zip bomb?)"))
                  (let ((old (fill-pointer out)))
                    (adjust-array out (max (array-total-size out) (+ old n)) :fill-pointer (+ old n))
                    (replace out buf :start1 old :end2 n)))
          (coerce out '(simple-array (unsigned-byte 8) (*)))))
    (chipz:decompression-error (c)
      (error 'tarball-error :message (format nil "tar: gzip decode failed: ~a" c)))))

;;; --- tar field parsing ------------------------------------------------------

(defun %octets->latin1 (bytes start end)
  (let ((s (make-string (- end start))))
    (dotimes (i (- end start) s) (setf (char s i) (code-char (aref bytes (+ start i)))))))

(defun %field-string (bytes start len)
  "The NUL-terminated latin-1 string in the fixed field bytes[start,start+len)."
  (let ((end start) (limit (+ start len)))
    (loop while (and (< end limit) (/= (aref bytes end) 0)) do (incf end))
    (%octets->latin1 bytes start end)))

(defun %string-until-nul (bytes start size)
  "A GNU longname/longlink payload: up to SIZE bytes from START, stopping at the first NUL."
  (let ((end start) (limit (+ start size)))
    (loop while (and (< end limit) (/= (aref bytes end) 0)) do (incf end))
    (%octets->latin1 bytes start end)))

(defun %numeric-field (bytes start end)
  "Parse a tar numeric field bytes[start,end): octal (default) or GNU base-256 (high bit of byte 0
set → big-endian). Returns a non-negative integer (0 for an all-space/NUL field)."
  (cond
    ((>= start end) 0)
    ((logbitp 7 (aref bytes start))
     (let ((v (logand (aref bytes start) #x7f)))
       (loop for i from (1+ start) below end do (setf v (+ (* v 256) (aref bytes i))))
       v))
    (t
     (let ((i start))
       (loop while (and (< i end) (member (aref bytes i) '(0 32))) do (incf i))
       (let ((v 0))
         (loop while (< i end) for c = (aref bytes i)
               while (<= 48 c 55) do (setf v (+ (* v 8) (- c 48))) (incf i))
         v)))))

(defun %block-all-zero (bytes start)
  (loop for i from start below (+ start +block-size+) always (zerop (aref bytes i))))

(defun %checksum-ok (bytes start)
  "The stored header checksum matches the (unsigned or signed) sum of the header block with the
checksum field read as spaces."
  (let ((stored (%numeric-field bytes (+ start 148) (+ start 156)))
        (usum 0) (ssum 0))
    (loop for i from start below (+ start +block-size+)
          for off = (- i start)
          for b = (if (<= 148 off 155) 32 (aref bytes i))
          do (incf usum b) (incf ssum (if (> b 127) (- b 256) b)))
    (and stored (or (= usum stored) (= ssum stored)))))

;;; --- pax extended header ----------------------------------------------------

(defun %parse-pax (bytes start size)
  "Parse pax extended-header records in bytes[start,start+size). Returns (values path linkpath
size-int) for the recognised keys (nil for absent). Malformed records terminate parsing."
  (let ((end (+ start size)) (i start) (path nil) (linkpath nil) (sz nil))
    (loop while (< i end) do
      (let ((sp (position 32 bytes :start i :end end)))     ; the space after the decimal LEN
        (unless sp (return))
        (let ((len 0) (any nil))
          (loop for k from i below sp for c = (aref bytes k)
                while (<= 48 c 57) do (setf len (+ (* len 10) (- c 48)) any t))
          (unless (and any (> len 0) (<= (+ i len) end)) (return))
          (let* ((rec-end (+ i len))
                 (kv-start (1+ sp)))
            ;; only slice a WELL-FORMED record: `key=value\n` must fit between kv-start and rec-end.
            ;; (A malformed LEN — e.g. non-digits before the space — can leave kv-start >= rec-end;
            ;; without this guard `position :start kv-start :end rec-end` would raise a raw
            ;; BOUNDING-INDICES error rather than a clean tarball-error.)
            (when (< kv-start rec-end)
              (let ((eq (position (char-code #\=) bytes :start kv-start :end (1- rec-end))))
                (when eq
                  (let ((key (%octets->latin1 bytes kv-start eq))
                        (val (%octets->latin1 bytes (1+ eq) (1- rec-end))))  ; drop the trailing newline
                    (cond ((string= key "path") (setf path val))
                          ((string= key "linkpath") (setf linkpath val))
                          ((string= key "size") (setf sz (ignore-errors (parse-integer val)))))))))
            (setf i rec-end)))))
    (values path linkpath sz)))

;;; --- the reader -------------------------------------------------------------

(defstruct (tar-entry (:conc-name te-))
  name                                  ; effective path (pax/gnu/prefix applied)
  (mode 0) (size 0) typeflag linkname data)   ; data = regular-file contents, else NIL

(defun read-tar-entries (tar)
  "Parse the tar octet vector TAR into a list of resolved tar-entry structs (pax `path`/`linkpath`/
`size` + GNU `L`/`K` longname overrides applied to the following entry). Signals tarball-error on a
malformed archive. Every size is bounds-checked before the data is sliced (§6)."
  (let ((entries '()) (pos 0) (n (length tar))
        (pending-path nil) (pending-linkpath nil) (pending-size nil))
    (loop
      (when (> (+ pos +block-size+) n) (return))
      (when (%block-all-zero tar pos) (return))             ; end-of-archive marker
      (unless (%checksum-ok tar pos)
        (error 'tarball-error :message "tar: bad header checksum"))
      (let* ((raw-name (%field-string tar pos 100))
             (mode (%numeric-field tar (+ pos 100) (+ pos 108)))
             (hsize (%numeric-field tar (+ pos 124) (+ pos 136)))
             (typeflag (code-char (aref tar (+ pos 156))))
             (linkname (%field-string tar (+ pos 157) 100))
             (prefix (%field-string tar (+ pos 345) 155))
             (name (if (plusp (length prefix)) (concatenate 'string prefix "/" raw-name) raw-name))
             (data-start (+ pos +block-size+)))
        ;; the block count for THIS header's payload uses its own size field
        (when (or (> hsize *max-entry-size*) (> (+ data-start hsize) n))
          (error 'tarball-error :message (format nil "tar: header size ~a out of range" hsize)))
        (flet ((advance (payload) (setf pos (+ data-start (* +block-size+ (ceiling payload +block-size+))))))
          (case typeflag
            (#\x (multiple-value-bind (p lp sz) (%parse-pax tar data-start hsize)
                   (when p (setf pending-path p))
                   (when lp (setf pending-linkpath lp))
                   (when sz (setf pending-size sz)))
                 (advance hsize))
            (#\g (advance hsize))                           ; global pax — ignored
            (#\L (setf pending-path (%string-until-nul tar data-start hsize)) (advance hsize))
            (#\K (setf pending-linkpath (%string-until-nul tar data-start hsize)) (advance hsize))
            (t
             (let* ((eff-name (or pending-path name))
                    (eff-link (or pending-linkpath linkname))
                    (eff-size (or pending-size hsize)))
               (when (or (< eff-size 0) (> eff-size *max-entry-size*) (> (+ data-start eff-size) n))
                 (error 'tarball-error :message (format nil "tar: entry size ~a out of range" eff-size)))
               (let ((data (when (member typeflag '(#\0 #\Nul #\7))
                             (subseq tar data-start (+ data-start eff-size)))))
                 (push (make-tar-entry :name eff-name :mode (logand mode #o7777) :size eff-size
                                       :typeflag typeflag :linkname eff-link :data data)
                       entries))
               (setf pending-path nil pending-linkpath nil pending-size nil)
               (advance eff-size)))))))
    (nreverse entries)))

;;; --- path hardening ---------------------------------------------------------

(defun %split-slash (s)
  (let ((out '()) (start 0))
    (dotimes (i (length s))
      (when (char= (char s i) #\/) (push (subseq s start i) out) (setf start (1+ i))))
    (push (subseq s start) out)
    (nreverse out)))

(defun %strip-components (name k)
  "Strip K leading path segments (npm's `package/` wrapper). NIL if nothing meaningful remains."
  (let ((segs (%split-slash name)))
    (if (<= (length segs) k) nil
        (let ((rest (remove "" (nthcdr k segs) :test #'string=)))
          (when rest (format nil "~{~a~^/~}" rest))))))

(defun %lexical-resolve (segs)
  "Resolve `.`/`..` in SEGS lexically against a virtual root. Returns the normalised segment list,
or :escape if a `..` would rise above the root."
  (let ((stack '()))
    (dolist (s segs (nreverse stack))
      (cond ((or (string= s "") (string= s ".")) nil)
            ((string= s "..") (if stack (pop stack) (return :escape)))
            (t (push s stack))))))

(defun %safe-descend (staging rel)
  "Walk REL's parent components from STAGING: each existing component must be a REAL directory (a
symlink component → refuse; that is the write-through defense), a missing one is created, a non-dir
→ refuse; a `..` segment → refuse. Returns the absolute path for REL's final component."
  (let ((segs (remove-if (lambda (s) (or (string= s "") (string= s "."))) (%split-slash rel))))
    (when (null segs) (error 'tarball-error :message (format nil "tar: empty name ~s" rel)))
    (dolist (s segs)
      (when (string= s "..") (error 'tarball-error :message (format nil "tar: '..' segment in ~s" rel))))
    (let ((cur staging))
      (loop for (s . rest) on segs do
        (setf cur (sys:path-join cur s))
        (when rest
          (let ((st (ignore-errors (sys:stat* cur :lstat t))))
            (cond ((null st) (sys:make-directory cur :mode #o755))
                  ((sys:fstat-symlink-p st)
                   (error 'tarball-error :message (format nil "tar: path component ~s is a symlink (escape attempt)" s)))
                  ((not (sys:fstat-dir-p st))
                   (error 'tarball-error :message (format nil "tar: path component ~s is not a directory" s)))))))
      cur)))

(defun %validate-name (name)
  "Reject a NUL-bearing, absolute, empty, or `.`-only effective name before it is stripped/used."
  (when (zerop (length name)) (error 'tarball-error :message "tar: empty entry name"))
  (when (find #\Nul name) (error 'tarball-error :message "tar: NUL in entry name"))
  (when (char= (char name 0) #\/) (error 'tarball-error :message (format nil "tar: absolute name ~s" name)))
  name)

(defun %prepare-leaf (target)
  "Before creating a leaf at TARGET, remove any existing SYMLINK there so we never write THROUGH it
(the duplicate symlink-then-file attack), and clear a directory being replaced by a file/symlink."
  (let ((st (ignore-errors (sys:stat* target :lstat t))))
    (when st
      (cond ((sys:fstat-symlink-p st) (ignore-errors (sys:remove-recursive target)))
            ((sys:fstat-dir-p st) (ignore-errors (sys:remove-recursive target)))))))

(defun %write-regular (target data mode)
  (%prepare-leaf target)
  ;; defense in depth: write-file-octets follows a symlink, so if %prepare-leaf's removal ever
  ;; silently failed (a partial-removal edge on an unusual filesystem) we must NOT write through a
  ;; surviving symlink — re-lstat and refuse. (A surviving symlink can only point in-dest, since
  ;; %extract-symlink refuses escaping targets, but refusing here is unconditional and cheap.)
  (let ((st (ignore-errors (sys:stat* target :lstat t))))
    (when (and st (sys:fstat-symlink-p st))
      (error 'tarball-error :message (format nil "tar: refusing to write through a symlink at ~a" target))))
  (sys:write-file-octets target (or data (make-array 0 :element-type '(unsigned-byte 8))))
  ;; strip setuid/setgid/sticky; keep the ordinary rwx (so a bin script stays executable)
  (ignore-errors (sys:change-mode target (logand mode #o777))))

(defun %ensure-dir (target mode)
  (let ((st (ignore-errors (sys:stat* target :lstat t))))
    (cond ((null st) (sys:make-directory target :mode (logand (logior mode #o700) #o777)))
          ((sys:fstat-dir-p st) nil)                        ; already a real dir
          (t (ignore-errors (sys:remove-recursive target))
             (sys:make-directory target :mode (logand (logior mode #o700) #o777))))))

(defun %extract-symlink (target rel linkname)
  "Create a symlink at TARGET → LINKNAME, but only if LINKNAME (relative to the symlink's own dir)
stays within the archive root. An absolute or escaping target is refused (covers pax-linkpath escape)."
  (when (or (zerop (length linkname)) (char= (char linkname 0) #\/))
    (error 'tarball-error :message (format nil "tar: refusing symlink ~s → absolute/empty target ~s" rel linkname)))
  (let ((resolved (%lexical-resolve (append (butlast (%split-slash rel)) (%split-slash linkname)))))
    (when (eq resolved :escape)
      (error 'tarball-error :message (format nil "tar: refusing symlink ~s → escaping target ~s" rel linkname))))
  (%prepare-leaf target)
  (sys:make-symlink linkname target))

(defun %extract-hardlink (target linkname staging)
  "Materialise a hardlink entry as a COPY of its (archive-root-relative) target, but only if the
target resolves WITHIN staging and exists. An escaping/missing target is refused."
  (let ((resolved (%lexical-resolve (%split-slash linkname))))
    (when (eq resolved :escape)
      (error 'tarball-error :message (format nil "tar: refusing hardlink → escaping target ~s" linkname)))
    (let ((src (apply #'sys:path-join staging resolved)))
      (let ((st (ignore-errors (sys:stat* src :lstat t))))
        (unless (and st (sys:fstat-file-p st))
          (error 'tarball-error :message (format nil "tar: hardlink target ~s missing/not a regular file" linkname)))
        (%prepare-leaf target)
        (sys:write-file-octets target (sys:read-file-octets src))))))

;;; --- the extractor ----------------------------------------------------------

(defun %extract-entry (e staging strip-components)
  (let ((name (%validate-name (te-name e))))
    (let ((rel (%strip-components name strip-components)))
      (when (null rel) (return-from %extract-entry))        ; the `package/` dir itself, or empty
      (let ((target (%safe-descend staging rel)))
        (case (te-typeflag e)
          ((#\0 #\Nul #\7) (%write-regular target (te-data e) (te-mode e)))
          (#\5 (%ensure-dir target (te-mode e)))
          (#\2 (%extract-symlink target rel (te-linkname e)))
          (#\1 (%extract-hardlink target (te-linkname e) staging))
          ((#\3 #\4 #\6)
           (error 'tarball-error :message (format nil "tar: refusing device/FIFO entry ~s" rel)))
          (t (error 'tarball-error :message (format nil "tar: unsupported typeflag ~s for ~s" (te-typeflag e) rel))))))))

(defun %strip-trailing-slash (s)
  (if (and (> (length s) 1) (char= (char s (1- (length s))) #\/)) (subseq s 0 (1- (length s))) s))

(defun extract-package (tgz-octets dest &key integrity (strip-components 1))
  "Verify TGZ-OCTETS against INTEGRITY (an SRI string, if given), inflate + parse, and safely
extract into DEST — replacing it atomically. Nothing is written outside DEST; a failure commits
nothing (extraction lands in a sibling temp dir and is renamed in only on success). Signals
integrity-error / tarball-error. Returns DEST."
  (when integrity (integ:verify-integrity tgz-octets integrity))
  (let* ((dest (%strip-trailing-slash dest))
         (parent (sys:path-dirname dest))
         (staging (sys:make-temp-dir (sys:path-join (if (plusp (length parent)) parent ".") ".clun-extract-"))))
    (handler-case
        (progn
          (dolist (e (read-tar-entries (inflate-gzip tgz-octets)))
            (%extract-entry e staging strip-components))
          (when (sys:path-exists-p dest) (sys:remove-recursive dest))
          (sys:rename-path staging dest)
          dest)
      (error (c)
        (ignore-errors (sys:remove-recursive staging))
        (if (typep c '(or tarball-error integ:integrity-error))
            (error c)
            (error 'tarball-error :message (format nil "extract failed: ~a" c)))))))

;;; --- content-addressed cache ------------------------------------------------

(defun cache-root ()
  "~/.clun/cache, or $CLUN_CACHE."
  (or (sb-ext:posix-getenv "CLUN_CACHE")
      (sys:path-join (or (sb-ext:posix-getenv "HOME") "/tmp") ".clun" "cache")))

(defun cache-path (integrity)
  "The content-addressed path for INTEGRITY: <cache>/<algo>/<hexdigest>.tgz."
  (let ((sri (integ:parse-sri integrity)))
    (sys:path-join (cache-root)
                   (string-downcase (symbol-name (integ:sri-algorithm sri)))
                   (concatenate 'string (ironclad:byte-array-to-hex-string (integ:sri-digest sri)) ".tgz"))))

(defun cache-store (integrity octets)
  "Verify OCTETS against INTEGRITY, then write to the cache atomically (temp + rename). Returns the
cache path."
  (integ:verify-integrity octets integrity)
  (let* ((path (cache-path integrity)) (dir (sys:path-dirname path)))
    (unless (sys:path-exists-p dir) (sys:make-directory dir :recursive t :mode #o755))
    (let ((tmp (concatenate 'string path ".tmp")))
      (sys:write-file-octets tmp octets)
      (sys:rename-path tmp path))
    path))

(defun cache-fetch (integrity)
  "The cached tarball bytes for INTEGRITY iff present AND they still verify; else NIL. A corrupted
cache entry is ignored, never trusted."
  (let ((path (cache-path integrity)))
    (when (sys:path-exists-p path)
      (let ((bytes (ignore-errors (sys:read-file-octets path))))
        (when (and bytes (ignore-errors (integ:verify-integrity bytes integrity))) bytes)))))
