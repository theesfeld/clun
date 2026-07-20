;;;; tar-write.lisp — pure-CL ustar writer + archive extract helpers (Phase 74 / Issue #134).
;;;; Complements the Phase-22 read-only reader in clun.tarball. Writes portable ustar
;;;; headers (checksummed) and optional gzip wrappers via clun.compress.

(in-package :clun.archive)

(defconstant +block-size+ 512)

(defun %put-string (block off s len)
  (loop for i from 0 below (min len (length s))
        do (setf (aref block (+ off i)) (logand (char-code (char s i)) #xff))))

(defun %put-octal (block off val len)
  "Zero-padded octal of exactly (len-1) digits + NUL."
  (let* ((full (format nil "~o" (max 0 val)))
         (want (1- len))
         (s (if (>= (length full) want)
                (subseq full (- (length full) want))
                (concatenate 'string
                             (make-string (- want (length full)) :initial-element #\0)
                             full))))
    (dotimes (i want)
      (setf (aref block (+ off i)) (char-code (char s i))))))

(defun %split-name (path)
  "Split PATH into (values name prefix) so name ≤100 and prefix ≤155 (ustar)."
  (let ((path (string-left-trim "/" path)))
    (if (<= (length path) 100)
        (values path "")
        (let* ((cut (- (length path) 100))
               (slash (position #\/ path :end cut :from-end t)))
          (if (and slash (< slash 155) (<= (- (length path) (1+ slash)) 100))
              (values (subseq path (1+ slash)) (subseq path 0 slash))
              (error 'tb:tarball-error
                     :message (format nil "tar path too long for ustar: ~s" path)))))))

(defun %header-block (&key name (mode #o644) (size 0) (typeflag #\0) (linkname "")
                           (mtime 0) (uid 0) (gid 0) (prefix ""))
  (let ((b (make-array +block-size+ :element-type '(unsigned-byte 8) :initial-element 0)))
    (%put-string b 0 name 100)
    (%put-octal b 100 mode 8)
    (%put-octal b 108 uid 8)
    (%put-octal b 116 gid 8)
    (%put-octal b 124 size 12)
    (%put-octal b 136 mtime 12)
    (loop for i from 148 below 156 do (setf (aref b i) 32)) ; checksum spaces
    (setf (aref b 156) (char-code typeflag))
    (%put-string b 157 linkname 100)
    (%put-string b 257 "ustar" 6)
    (setf (aref b 263) (char-code #\0) (aref b 264) (char-code #\0)) ; version "00"
    (%put-string b 345 prefix 155)
    (let ((sum 0))
      (dotimes (i +block-size+) (incf sum (aref b i)))
      (%put-octal b 148 sum 8)
      (setf (aref b 155) 0))
    b))

(defun %pad-to-block (size)
  (let ((r (mod size +block-size+)))
    (if (zerop r) 0 (- +block-size+ r))))

(defun %emit-file (out path data mode mtime)
  (multiple-value-bind (name prefix) (%split-name path)
    (let* ((octets (or data (make-array 0 :element-type '(unsigned-byte 8))))
           (size (length octets))
           (hdr (%header-block :name name :prefix prefix :mode mode :size size
                               :typeflag #\0 :mtime mtime)))
      (write-sequence hdr out)
      (write-sequence octets out)
      (let ((pad (%pad-to-block size)))
        (when (plusp pad)
          (write-sequence (make-array pad :element-type '(unsigned-byte 8)
                                          :initial-element 0)
                          out))))))

(defun %emit-dir (out path mode mtime)
  (let* ((path (if (and (plusp (length path))
                        (char/= (char path (1- (length path))) #\/))
                   (concatenate 'string path "/")
                   path)))
    (multiple-value-bind (name prefix) (%split-name path)
      (write-sequence
       (%header-block :name name :prefix prefix :mode mode :size 0
                      :typeflag #\5 :mtime mtime)
       out))))

(defun %path-has-dotdot (path)
  (loop with start = 0
        for i = (position #\/ path :start start)
        for seg = (subseq path start (or i (length path)))
        when (string= seg "..") return t
        while i do (setf start (1+ i))
        finally (return nil)))

(defun %normalize-entry-path (path)
  (let ((p (substitute #\/ #\\ (string-trim '(#\Space #\Tab) path))))
    (when (or (zerop (length p))
              (char= (char p 0) #\/)
              (find #\Nul p)
              (%path-has-dotdot p))
      (error 'tb:tarball-error
             :message (format nil "refusing archive path ~s" path)))
    (string-left-trim "/" p)))

(defun write-tar (entries &key (mtime 0))
  "Build an uncompressed ustar archive from ENTRIES — a list of
  (path . content) where content is a byte vector, string, or :directory.
  Paths use forward slashes. Returns a simple-array of octets."
  (flexi-streams:with-output-to-sequence (out :element-type '(unsigned-byte 8))
    (dolist (entry entries)
      (destructuring-bind (path . content) entry
        (let ((path (%normalize-entry-path path)))
          (cond
            ((eq content :directory)
             (%emit-dir out path #o755 mtime))
            ((stringp content)
             (%emit-file out path
                         (sb-ext:string-to-octets content :external-format :utf-8)
                         #o644 mtime))
            ((typep content '(vector (unsigned-byte 8)))
             (%emit-file out path
                         (coerce content '(simple-array (unsigned-byte 8) (*)))
                         #o644 mtime))
            (t (error 'tb:tarball-error
                      :message (format nil "unsupported archive entry content for ~s" path)))))))
    ;; two zero blocks end the archive
    (write-sequence (make-array (* 2 +block-size+) :element-type '(unsigned-byte 8)
                                                   :initial-element 0)
                    out)))

(defun build-archive-bytes (entries &key compress (level 6) (mtime 0))
  "Write ENTRIES as tar, optionally gzip-compress when COMPRESS is :gzip or \"gzip\"."
  (let ((tar (write-tar entries :mtime mtime)))
    (cond
      ((or (eq compress :gzip) (equal compress "gzip") (eq compress t))
       (cmp:gzip-compress tar :level level))
      ((or (null compress) (eq compress :none) (equal compress "none"))
       tar)
      (t (error 'tb:tarball-error
                :message (format nil "unsupported archive compress format: ~s" compress))))))

(defun %maybe-gunzip (octets)
  (if (cmp:gzip-magic-p octets)
      (cmp:gunzip octets)
      octets))

(defun parse-archive-bytes (octets)
  "Parse tar or tar.gz OCTETS into a list of tar-entry structs."
  (tb:read-tar-entries (%maybe-gunzip octets)))

(defun %strip-components (name k)
  (if (zerop k)
      name
      (let ((start 0) (n (length name)) (left k))
        (loop while (and (plusp left) (< start n))
              for slash = (position #\/ name :start start)
              do (if slash
                     (setf start (1+ slash) left (1- left))
                     (return-from %strip-components nil)))
        (when (< start n) (subseq name start)))))

(defun %safe-join (root rel)
  (when (or (zerop (length rel)) (find #\Nul rel) (char= (char rel 0) #\/)
            (%path-has-dotdot rel))
    (error 'tb:tarball-error :message (format nil "refusing unsafe extract path ~s" rel)))
  (let ((segs (loop with start = 0
                    for i = (position #\/ rel :start start)
                    for seg = (subseq rel start (or i (length rel)))
                    unless (or (string= seg "") (string= seg "."))
                      collect seg
                    while i do (setf start (1+ i)))))
    (reduce #'sys:path-join segs :initial-value root)))

(defun %simple-glob-match (name pattern)
  (cond
    ((or (string= pattern "**") (string= pattern "*")) t)
    ((string= pattern name) t)
    ((and (>= (length pattern) 3)
          (char= (char pattern 0) #\*)
          (char= (char pattern 1) #\*)
          (char= (char pattern 2) #\/))
     (let ((rest (subseq pattern 3)))
       (or (string= rest name)
           (search rest name)
           (%simple-glob-match name rest))))
    ((and (plusp (length pattern)) (char= (char pattern (1- (length pattern))) #\*))
     (let ((prefix (subseq pattern 0 (1- (length pattern)))))
       (and (>= (length name) (length prefix))
            (string= name prefix :end1 (length prefix)))))
    ((and (plusp (length pattern)) (char= (char pattern 0) #\*))
     (let ((suffix (subseq pattern 1)))
       (and (>= (length name) (length suffix))
            (string= name suffix :start1 (- (length name) (length suffix))))))
    (t (ignore-errors
         (clun.glob:glob-match-p (clun.glob:compile-glob pattern) name)))))

(defun %glob-match (name patterns)
  (when (null patterns) (return-from %glob-match t))
  (let ((positives '()) (negatives '()))
    (dolist (p patterns)
      (let ((s (if (stringp p) p (princ-to-string p))))
        (if (and (plusp (length s)) (char= (char s 0) #\!))
            (push (subseq s 1) negatives)
            (push s positives))))
    (and (or (null positives)
             (some (lambda (pat) (%simple-glob-match name pat)) positives))
         (not (some (lambda (pat) (%simple-glob-match name pat)) negatives)))))

(defun extract-archive (octets dest &key (strip-components 0) glob)
  "Extract tar/tar.gz OCTETS into DEST. Returns entry count. Path escapes fail closed."
  (let* ((dest (string-right-trim "/" dest))
         (parent (sys:path-dirname dest))
         (staging (sys:make-temp-dir
                   (sys:path-join (if (plusp (length parent)) parent ".") ".clun-archive-")))
         (count 0))
    (handler-case
        (progn
          (dolist (e (parse-archive-bytes octets))
            (let ((rel (%strip-components (tb:te-name e) strip-components)))
              (when (and rel (%glob-match (tb:te-name e) glob))
                (let ((target (%safe-join staging rel)))
                  (case (tb:te-typeflag e)
                    ;; Regular files: POSIX '0'/NUL, contiguous '7', and historical
                    ;; space typeflag used by some BSD tar producers.
                    ((#\0 #\Nul #\7 #\Space)
                     (sys:make-directory (sys:path-dirname target) :recursive t :mode #o755)
                     (sys:write-file-octets
                      target
                      (or (tb:te-data e)
                          (make-array 0 :element-type '(unsigned-byte 8))))
                     (incf count))
                    (#\5
                     (sys:make-directory target :recursive t :mode #o755)
                     (incf count))
                    ;; Ignore AppleDouble / extended metadata entries rather than
                    ;; failing closed on a full release bundle extract.
                    ((#\1 #\2 #\3 #\4 #\6 #\L #\K #\x #\g #\X #\I) nil)
                    (t nil))))))
          (when (sys:path-exists-p dest) (sys:remove-recursive dest))
          (sys:rename-path staging dest)
          count)
      (error (c)
        (ignore-errors (sys:remove-recursive staging))
        (if (typep c '(or tb:tarball-error cmp:compress-error))
            (error c)
            (error 'tb:tarball-error :message (format nil "extract failed: ~a" c)))))))
