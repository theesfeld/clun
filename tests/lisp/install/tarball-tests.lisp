;;;; tarball-tests.lisp — Phase 22 gate: the ustar/pax reader + hardened extractor + integrity +
;;;; cache. A CL tar-writer helper builds byte-exact archives (stock `tar` cannot emit the malicious
;;;; shapes); each is gzipped with the Phase-21 stored-block encoder (gzip-stored, chipz inflates it).
;;;; The suite covers the real-package corpus (a lodash-scale archive, a bin exec-bit, the Phase-21
;;;; pax-longname tarball) and the MANDATED traversal suite — every escape refused, nothing written
;;;; outside the destination.

(in-package :clun-test)

;;; --- a byte-exact tar writer -------------------------------------------------

(defun %tw-put-string (block off s len)
  (loop for i from 0 below (min len (length s)) do (setf (aref block (+ off i)) (logand (char-code (char s i)) #xff))))

(defun %tw-put-octal* (block off val len)
  "Zero-padded octal of exactly (len-1) low digits + NUL (truncates high digits — used only where
the value fits)."
  (let* ((full (format nil "~o" val))
         (want (1- len))
         (s (if (>= (length full) want) (subseq full (- (length full) want))
                (concatenate 'string (make-string (- want (length full)) :initial-element #\0) full))))
    (dotimes (i want) (setf (aref block (+ off i)) (char-code (char s i))))))

(defun %tw-put-base256 (block off val len)
  (let ((v val))
    (loop for i from (1- len) downto 1 do (setf (aref block (+ off i)) (logand v #xff)) (setf v (ash v -8)))
    (setf (aref block off) (logior #x80 (logand v #x7f)))))

(defun %tw-header (&key name (mode #o644) (size 0) (typeflag #\0) (linkname "") (prefix "")
                        (uid 0) (gid 0) (mtime 0) (ustar t) size-base256)
  "A 512-byte ustar header with a correct checksum."
  (let ((b (make-array 512 :element-type '(unsigned-byte 8) :initial-element 0)))
    (%tw-put-string b 0 name 100)
    (%tw-put-octal* b 100 mode 8)
    (%tw-put-octal* b 108 uid 8)
    (%tw-put-octal* b 116 gid 8)
    (if size-base256 (%tw-put-base256 b 124 size 12) (%tw-put-octal* b 124 size 12))
    (%tw-put-octal* b 136 mtime 12)
    (loop for i from 148 below 156 do (setf (aref b i) 32))   ; checksum field = spaces for summing
    (setf (aref b 156) (char-code typeflag))
    (%tw-put-string b 157 linkname 100)
    (when ustar
      (%tw-put-string b 257 "ustar" 6)                        ; "ustar\0"
      (setf (aref b 263) (char-code #\0) (aref b 264) (char-code #\0)))  ; version "00"
    (%tw-put-string b 345 prefix 155)
    (let ((sum (loop for x across b sum x)))                  ; checksum over the block (field=spaces)
      (let ((s (format nil "~6,'0o" (logand sum #o777777))))
        (dotimes (i 6) (setf (aref b (+ 148 i)) (char-code (char s i))))
        (setf (aref b 154) 0 (aref b 155) 32)))               ; 6 octal digits + NUL + space
    b))

(defun %tw-octets (x)
  (etypecase x
    (string (map '(simple-array (unsigned-byte 8) (*)) (lambda (c) (logand (char-code c) #xff)) x))
    (vector (coerce x '(simple-array (unsigned-byte 8) (*))))
    (null (make-array 0 :element-type '(unsigned-byte 8)))))

(defun %tw-entry (name data &key (typeflag #\0) (mode #o644) (linkname "") (prefix "")
                                 header-size size-base256)
  "A header + DATA padded to a 512 multiple. HEADER-SIZE overrides the size FIELD (for the
size-overflow / base-256 tests) independently of the actual payload length."
  (let* ((d (%tw-octets data))
         (hdr (%tw-header :name name :mode mode :size (or header-size (length d)) :typeflag typeflag
                          :linkname linkname :prefix prefix :size-base256 size-base256))
         (pad (mod (- (length d)) 512)))
    (concatenate '(simple-array (unsigned-byte 8) (*)) hdr d
                 (make-array pad :element-type '(unsigned-byte 8)))))

(defun %tw-pax-record (key value)
  "A pax record `LEN KEY=VALUE\\n`, LEN counting the whole (self-referential) record."
  (let ((tail (format nil "~a=~a~c" key value #\Newline)))
    (loop for total from (+ 2 (length tail)) do
      (when (= total (+ (length (princ-to-string total)) 1 (length tail)))
        (return (format nil "~d ~a" total tail))))))

(defun %tw-pax-entry (records &key (name "paxheader"))
  "An 'x' pax extended-header entry carrying the concatenated RECORDS string."
  (%tw-entry name records :typeflag #\x))

(defun %tw-gnu-longname (longname)
  "A GNU 'L' longname entry (its data is LONGNAME, NUL-terminated)."
  (%tw-entry "././@LongLink" (concatenate 'string longname (string #\Nul)) :typeflag #\L))

(defun %tw-archive (&rest entries)
  "Concatenate ENTRIES + two zero blocks and gzip (via the Phase-21 stored-block encoder)."
  (let ((tar (apply #'concatenate '(simple-array (unsigned-byte 8) (*))
                    (append entries (list (make-array 1024 :element-type '(unsigned-byte 8)))))))
    (gzip-stored tar)))

;;; --- extraction harness ------------------------------------------------------

(defun %fresh-dest ()
  "A unique, NON-existent destination path under /tmp (extract-package renames staging → dest)."
  (let ((d (clun.sys:make-temp-dir "/tmp/clun-tb-")))
    (clun.sys:remove-recursive d) d))

(defun %extract (tgz &key (strip 0) integrity)
  "Extract TGZ to a fresh dest; return (values dest error-or-nil)."
  (let ((dest (%fresh-dest)))
    (values dest
            (handler-case (progn (tb:extract-package tgz dest :strip-components strip :integrity integrity)
                                 nil)
              (error (c) c)))))

(defun %rejected-p (err)
  (typep err 'tb:tarball-error))

;;; ============================ real-package corpus ============================

(define-test tarball/extracts-nested-package
  ;; a normal package/ archive (strip-components 1) round-trips every file with contents intact
  (let ((tgz (%tw-archive
              (%tw-entry "package/" "" :typeflag #\5 :mode #o755)
              (%tw-entry "package/package.json" "{\"name\":\"p\"}" :mode #o644)
              (%tw-entry "package/lib/" "" :typeflag #\5 :mode #o755)
              (%tw-entry "package/lib/util.js" "module.exports=1" :mode #o644))))
    (multiple-value-bind (dest err) (%extract tgz :strip 1)
      (false err)
      (true (clun.sys:path-exists-p (clun.sys:path-join dest "package.json")))
      (true (clun.sys:path-exists-p (clun.sys:path-join dest "lib/util.js")))
      (is string= "module.exports=1"
          (clun.sys:read-file-string (clun.sys:path-join dest "lib/util.js")))
      (clun.sys:remove-recursive dest))))

(define-test tarball/lodash-scale
  ;; ~200 nested files extract correctly (a realistic package size)
  (let* ((entries (list (%tw-entry "package/" "" :typeflag #\5 :mode #o755)))
         (expected 0))
    (dotimes (d 10)
      (push (%tw-entry (format nil "package/mod~2,'0d/" d) "" :typeflag #\5 :mode #o755) entries)
      (dotimes (f 20)
        (push (%tw-entry (format nil "package/mod~2,'0d/f~2,'0d.js" d f)
                         (format nil "export const id=~d" (+ (* d 100) f)) :mode #o644)
              entries)
        (incf expected)))
    (let ((tgz (apply #'%tw-archive (nreverse entries))))
      (multiple-value-bind (dest err) (%extract tgz :strip 1)
        (false err)
        (let ((count 0))
          (dotimes (d 10) (dotimes (f 20)
            (when (clun.sys:path-exists-p (clun.sys:path-join dest (format nil "mod~2,'0d/f~2,'0d.js" d f)))
              (incf count))))
          (is = expected count "all lodash-scale files extracted"))
        (clun.sys:remove-recursive dest)))))

(define-test tarball/bin-executable-bit-preserved
  ;; a 0755 file keeps its executable bit (bin package); setuid is stripped
  (let ((tgz (%tw-archive
              (%tw-entry "package/" "" :typeflag #\5 :mode #o755)
              (%tw-entry "package/cli.js" "#!/usr/bin/env node" :mode #o4755))))  ; setuid + rwxr-xr-x
    (multiple-value-bind (dest err) (%extract tgz :strip 1)
      (false err)
      (let ((mode (logand (clun.sys:fstat-mode (clun.sys:stat* (clun.sys:path-join dest "cli.js"))) #o7777)))
        (is = #o755 mode "executable bit kept, setuid stripped"))
      (clun.sys:remove-recursive dest))))

(define-test tarball/real-pax-longname
  ;; the Phase-21 pax/gnu longname tarball (a 156-char internal path) extracts to that path
  (let* ((path (namestring (merge-pathnames "tests/fixtures/registry/tarballs/longname-pkg-1.0.0.tgz"
                                            (asdf:system-source-directory :clun))))
         (tgz (clun.sys:read-file-octets path)))
    (multiple-value-bind (dest err) (%extract tgz :strip 1)
      (false err)
      (true (clun.sys:path-exists-p
             (clun.sys:path-join dest "lib/this-is-a-deliberately-long-file-name-that-exceeds-the-ustar-one-hundred-byte-name-field-limit-to-force-a-pax-or-gnu-longname-extended-header.js"))
            "the 156-char longname path extracted")
      (clun.sys:remove-recursive dest))))

;;; --- base-256 size (valid, small) parses + extracts --------------------------

(define-test tarball/base256-size-parses
  (let ((tgz (%tw-archive (%tw-entry "x.txt" "hello" :size-base256 t))))
    (multiple-value-bind (dest err) (%extract tgz :strip 0)
      (false err)
      (is string= "hello" (clun.sys:read-file-string (clun.sys:path-join dest "x.txt")))
      (clun.sys:remove-recursive dest))))

;;; --- reader robustness: malformed input → tarball-error, never a raw condition ----

(define-test tarball/malformed-pax-len-no-raw-error
  ;; a pax record whose LEN field holds a non-digit before the space used to raise a raw
  ;; BOUNDING-INDICES error (position :start > :end); it must now be skipped cleanly.
  (let* ((tgz (%tw-archive (%tw-pax-entry (format nil "1x =y~c" #\Newline))
                           (%tw-entry "ok.txt" "data")))
         (result (handler-case (progn (tb:read-tar-entries (tb:inflate-gzip tgz)) :ok)
                   (tb:tarball-error () :tarball-error)
                   (error (e) (cons :raw (type-of e))))))
    (true (member result '(:ok :tarball-error)) (format nil "no raw error from a bad pax LEN (got ~s)" result))))

(define-test tarball/non-gzip-input-is-tarball-error
  ;; inflate-gzip must convert a raw chipz decode error into a tarball-error
  (let* ((junk (map '(simple-array (unsigned-byte 8) (*)) #'char-code "not a gzip stream at all"))
         (r (handler-case (progn (tb:inflate-gzip junk) :ok)
              (tb:tarball-error () :tarball-error)
              (error (e) (cons :raw (type-of e))))))
    (is eq :tarball-error r "inflate-gzip wraps chipz errors")
    (true (typep (nth-value 1 (%extract junk)) 'tb:tarball-error) "extract-package on non-gzip → tarball-error")))

;;; --- header-before-pax ordering: a pax `path` overrides the next entry -------

(define-test tarball/pax-path-override-applies-to-next
  (let ((tgz (%tw-archive
              (%tw-pax-entry (%tw-pax-record "path" "renamed/deep/actual.js"))
              (%tw-entry "shortname" "PAYLOAD" :mode #o644))))
    (multiple-value-bind (dest err) (%extract tgz :strip 0)
      (false err)
      (true (clun.sys:path-exists-p (clun.sys:path-join dest "renamed/deep/actual.js")))
      (false (clun.sys:path-exists-p (clun.sys:path-join dest "shortname")))
      (clun.sys:remove-recursive dest))))

;;; --- duplicate entries: last wins --------------------------------------------

(define-test tarball/duplicate-last-wins
  (let ((tgz (%tw-archive
              (%tw-entry "dup.txt" "FIRST" :mode #o644)
              (%tw-entry "dup.txt" "SECOND" :mode #o644))))
    (multiple-value-bind (dest err) (%extract tgz :strip 0)
      (false err)
      (is string= "SECOND" (clun.sys:read-file-string (clun.sys:path-join dest "dup.txt")))
      (clun.sys:remove-recursive dest))))

;;; ============================ traversal suite ================================
;;; every case must be REFUSED (a tarball-error) and write nothing outside dest

(defmacro define-reject-test (name archive-form &optional (why ""))
  `(define-test ,name
     (multiple-value-bind (dest err) (%extract ,archive-form :strip 0)
       (true (%rejected-p err) ,(format nil "must reject: ~a" why))
       (ignore-errors (clun.sys:remove-recursive dest)))))

(define-reject-test tarball/reject-absolute-name
  (%tw-archive (%tw-entry "/etc/evil" "x")) "absolute name")

(define-reject-test tarball/reject-dotdot-plain
  (%tw-archive (%tw-entry "../escape.txt" "x")) "leading ..")

(define-reject-test tarball/reject-dotdot-embedded
  (%tw-archive (%tw-entry "a/b/../../../escape.txt" "x")) "embedded ..")

(define-reject-test tarball/reject-dotdot-via-pax-path
  (%tw-archive (%tw-pax-entry (%tw-pax-record "path" "../../escape.txt"))
               (%tw-entry "innocent.txt" "x")) ".. via pax path")

(define-reject-test tarball/reject-dotdot-via-longname
  (%tw-archive (%tw-gnu-longname "../../escape-long.txt")
               (%tw-entry "innocent.txt" "x")) ".. via gnu longname")

(define-reject-test tarball/reject-symlink-absolute
  (%tw-archive (%tw-entry "s" "" :typeflag #\2 :linkname "/tmp")) "symlink → absolute")

(define-reject-test tarball/reject-symlink-escape
  (%tw-archive (%tw-entry "s" "" :typeflag #\2 :linkname "../../../../etc")) "symlink → escaping ..")

(define-test tarball/reject-symlink-write-through
  ;; an in-dest symlink dir, then a write THROUGH it — descend must refuse the symlink component
  (let ((tgz (%tw-archive
              (%tw-entry "realdir/" "" :typeflag #\5 :mode #o755)
              (%tw-entry "link" "" :typeflag #\2 :linkname "realdir")   ; in-dest, allowed to create
              (%tw-entry "link/pwned.txt" "x" :mode #o644))))           ; write through → refused
    (multiple-value-bind (dest err) (%extract tgz :strip 0)
      (true (%rejected-p err) "writing through a symlink component is refused")
      (ignore-errors (clun.sys:remove-recursive dest)))))

(define-reject-test tarball/reject-hardlink-escape
  (%tw-archive (%tw-entry "h" "" :typeflag #\1 :linkname "../../../../etc/passwd")) "hardlink → escaping target")

(define-reject-test tarball/reject-pax-linkpath-escape
  (%tw-archive (%tw-pax-entry (%tw-pax-record "linkpath" "../../../../etc/passwd"))
               (%tw-entry "s" "" :typeflag #\2 :linkname "innocent")) "pax linkpath escape")

(define-reject-test tarball/reject-nul-in-name
  (%tw-archive (%tw-pax-entry (%tw-pax-record "path" (format nil "a~cb.txt" #\Nul)))
               (%tw-entry "innocent.txt" "x")) "NUL in name")

(define-reject-test tarball/reject-char-device
  (%tw-archive (%tw-entry "dev" "" :typeflag #\3)) "char device")

(define-reject-test tarball/reject-fifo
  (%tw-archive (%tw-entry "pipe" "" :typeflag #\6)) "FIFO")

(define-reject-test tarball/reject-size-overflow
  ;; a base-256 size field claiming 1 TB (fits base-256, dwarfs the buffer + *max-entry-size*)
  (%tw-archive (%tw-entry "big.txt" "tiny" :header-size (* 1024 1024 1024 1024) :size-base256 t))
  "base-256 size field beyond the buffer")

;;; --- extraction commits NOTHING outside dest on a rejected archive -----------

(define-test tarball/rejected-archive-writes-nothing-outside
  ;; craft an archive whose FIRST entry is fine and SECOND escapes; assert the escape target and
  ;; the (removed) dest are both absent — verify-then-commit means the staging dir is torn down.
  (let* ((sentinel "/tmp/clun-tb-sentinel-must-not-appear.txt")
         (tgz (%tw-archive
               (%tw-entry "ok.txt" "fine" :mode #o644)
               (%tw-entry "s" "" :typeflag #\2 :linkname "/tmp")
               (%tw-entry "s/clun-tb-sentinel-must-not-appear.txt" "PWNED" :mode #o644))))
    (ignore-errors (clun.sys:remove-recursive sentinel))
    (multiple-value-bind (dest err) (%extract tgz :strip 0)
      (true (%rejected-p err) "escape refused")
      (false (clun.sys:path-exists-p sentinel) "nothing written outside dest")
      (false (clun.sys:path-exists-p dest) "nothing committed to dest")
      (ignore-errors (clun.sys:remove-recursive dest)))))

;;; ============================ integrity + cache ==============================

(define-test tarball/integrity-gates-extraction
  ;; a Phase-21 fixture tarball extracts under its correct integrity; a wrong one fails BEFORE
  ;; anything is written.
  (let* ((path (namestring (merge-pathnames "tests/fixtures/registry/tarballs/left-pad-1.0.0.tgz"
                                            (asdf:system-source-directory :clun))))
         (tgz (clun.sys:read-file-octets path))
         (good (integ:sri-string :sha512 tgz)))
    (multiple-value-bind (dest err) (%extract tgz :strip 1 :integrity good)
      (false err)
      (true (clun.sys:path-exists-p (clun.sys:path-join dest "package.json")))
      (clun.sys:remove-recursive dest))
    (multiple-value-bind (dest err) (%extract tgz :strip 1 :integrity "sha512-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==")
      (true (typep err 'integ:integrity-error) "wrong integrity fails closed")
      (false (clun.sys:path-exists-p dest) "nothing extracted under a bad integrity")
      (ignore-errors (clun.sys:remove-recursive dest)))))

(define-test tarball/cache-store-fetch-roundtrip
  (let ((tmp (clun.sys:make-temp-dir "/tmp/clun-cache-")))
    (unwind-protect
         (progn
           (sb-posix:setenv "CLUN_CACHE" tmp 1)
           (let* ((bytes (map '(simple-array (unsigned-byte 8) (*)) #'char-code "the tarball bytes"))
                  (sri (integ:sri-string :sha512 bytes)))
             (tb:cache-store sri bytes)
             (let ((got (tb:cache-fetch sri)))
               (true got "cache-fetch returns the stored bytes")
               (is equalp bytes got "round-trip bytes match"))
             ;; corrupt the cached entry → cache-fetch must ignore it (never trust)
             (let ((p (tb:cache-path sri)))
               (clun.sys:write-file-octets p (map '(simple-array (unsigned-byte 8) (*)) #'char-code "corrupted"))
               (false (tb:cache-fetch sri) "a corrupted cache entry is ignored"))))
      (ignore-errors (sb-posix:unsetenv "CLUN_CACHE"))
      (ignore-errors (clun.sys:remove-recursive tmp)))))
