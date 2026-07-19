;;;; format.lisp — CLUNSEA single-file executable trailer (pure CL, Issue #181).
;;;;
;;;; Layout (appended to a host Clun runtime binary):
;;;;   [ host runtime bytes ]
;;;;   [ payload: u32-BE length-prefixed sections ]
;;;;   [ signature block optional ]
;;;;   [ fixed footer 48 bytes ending in magic "CLUNSEA1" ]
;;;;
;;;; Footer (little-endian for host-native u64 friendliness on x86/arm LE):
;;;;   host-size     u64
;;;;   payload-size  u64
;;;;   flags         u32   bit0 signed, bit1 minify, bit2 bytecode-policy
;;;;   sig-algo      u16   0 none, 1 ed25519, 2 hmac-sha256
;;;;   sig-size      u16
;;;;   version       u16   = 1
;;;;   reserved      u16
;;;;   magic         8 bytes "CLUNSEA1"

(in-package :clun.sfe)

(defparameter +sea-magic+
  (make-array 8 :element-type '(unsigned-byte 8)
              :initial-contents
              (map 'list #'char-code (coerce "CLUNSEA1" 'list)))
  "Trailer magic identifying a Clun single-file executable.")

(defconstant +sea-version+ 1)
;; host u64 + payload u64 + flags u32 + sig-algo u16 + sig-size u16
;; + version u16 + reserved u16 + magic 8 = 36
(defconstant +footer-size+ 36)
(defconstant +flag-signed+ 1)
(defconstant +flag-minify+ 2)
(defconstant +flag-bytecode+ 4)

(defparameter +sig-algo-none+ 0)
(defparameter +sig-algo-ed25519+ 1)
(defparameter +sig-algo-hmac-sha256+ 2)

(define-condition sfe-error (error)
  ((kind :initarg :kind :reader sfe-error-kind)
   (detail :initarg :detail :initform nil :reader sfe-error-detail))
  (:report (lambda (c s)
             (if (sfe-error-detail c)
                 (format s "~A: ~A" (sfe-error-kind c) (sfe-error-detail c))
                 (format s "~A" (sfe-error-kind c))))))

(defun %fail (kind &optional detail)
  (error 'sfe-error :kind kind :detail detail))

;;; --- binary helpers --------------------------------------------------------

(defun %u16le (n)
  (make-array 2 :element-type '(unsigned-byte 8)
              :initial-contents (list (ldb (byte 8 0) n) (ldb (byte 8 8) n))))

(defun %u32le (n)
  (make-array 4 :element-type '(unsigned-byte 8)
              :initial-contents
              (list (ldb (byte 8 0) n) (ldb (byte 8 8) n)
                    (ldb (byte 8 16) n) (ldb (byte 8 24) n))))

(defun %u64le (n)
  (make-array 8 :element-type '(unsigned-byte 8)
              :initial-contents
              (loop for shift from 0 by 8 below 64
                    collect (ldb (byte 8 shift) n))))

(defun %read-u16le (octets start)
  (logior (aref octets start)
          (ash (aref octets (+ start 1)) 8)))

(defun %read-u32le (octets start)
  (logior (aref octets start)
          (ash (aref octets (+ start 1)) 8)
          (ash (aref octets (+ start 2)) 16)
          (ash (aref octets (+ start 3)) 24)))

(defun %read-u64le (octets start)
  (loop for i from 0 below 8
        sum (ash (aref octets (+ start i)) (* 8 i))))

(defun %cat (&rest parts)
  (let* ((total (loop for p in parts sum (length p)))
         (out (make-array total :element-type '(unsigned-byte 8)))
         (i 0))
    (dolist (p parts out)
      (replace out p :start1 i)
      (incf i (length p)))))

(defun %utf8 (string)
  (sb-ext:string-to-octets string :external-format :utf-8))

(defun %utf8-string (octets &key (start 0) end)
  (sb-ext:octets-to-string octets :external-format :utf-8
                                  :start start :end end))

(defun %lp-string (string)
  "u32 length + utf-8 bytes."
  (let ((b (%utf8 string)))
    (%cat (%u32le (length b)) b)))

(defun %lp-octets (octets)
  (%cat (%u32le (length octets)) octets))

;;; --- payload codec ---------------------------------------------------------

(defun encode-payload (manifest modules assets)
  "Encode MANIFEST (alist of string keys), MODULES ((path . source-string)*),
ASSETS ((name . octet-vector)*) into a payload octet vector."
  (let* ((manifest-json (sys:write-json
                         (if manifest manifest :empty-object)
                         :indent 0))
         (manifest-bytes (%utf8 manifest-json))
         (mod-parts
          (apply #'%cat
                 (%u32le (length modules))
                 (loop for (path . source) in modules
                       append (list (%lp-string path)
                                    (%lp-string (or source ""))))))
         (asset-parts
          (apply #'%cat
                 (%u32le (length assets))
                 (loop for (name . data) in assets
                       append (list (%lp-string name)
                                    (%lp-octets data))))))
    (%cat (%lp-octets manifest-bytes) mod-parts asset-parts)))

(defun %read-lp (octets pos)
  "Return (values bytes new-pos)."
  (when (> (+ pos 4) (length octets))
    (%fail :corrupt "truncated length prefix"))
  (let* ((n (%read-u32le octets pos))
         (start (+ pos 4))
         (end (+ start n)))
    (when (> end (length octets))
      (%fail :corrupt "truncated blob"))
    (values (subseq octets start end) end)))

(defun decode-payload (octets)
  "Return (values manifest-alist modules assets)."
  (multiple-value-bind (manifest-bytes pos) (%read-lp octets 0)
    (let* ((manifest (sys:parse-json (%utf8-string manifest-bytes)))
           (manifest-alist
            (if (sys:jobject-p manifest)
                (mapcar (lambda (kv) (cons (car kv) (cdr kv))) manifest)
                '()))
           (mod-count (%read-u32le octets pos))
           (pos2 (+ pos 4))
           (modules '())
           (assets '()))
      (dotimes (_ mod-count)
        (multiple-value-bind (pathb p1) (%read-lp octets pos2)
          (multiple-value-bind (srcb p2) (%read-lp octets p1)
            (push (cons (%utf8-string pathb) (%utf8-string srcb)) modules)
            (setf pos2 p2))))
      (when (> (+ pos2 4) (length octets))
        (%fail :corrupt "missing assets count"))
      (let ((asset-count (%read-u32le octets pos2)))
        (incf pos2 4)
        (dotimes (_ asset-count)
          (multiple-value-bind (nameb p1) (%read-lp octets pos2)
            (multiple-value-bind (data p2) (%read-lp octets p1)
              (push (cons (%utf8-string nameb) data) assets)
              (setf pos2 p2)))))
      (values manifest-alist (nreverse modules) (nreverse assets)))))

;;; --- footer / open ---------------------------------------------------------

(defun encode-footer (host-size payload-size flags sig-algo sig-size)
  (%cat (%u64le host-size)
        (%u64le payload-size)
        (%u32le flags)
        (%u16le sig-algo)
        (%u16le sig-size)
        (%u16le +sea-version+)
        (%u16le 0)
        +sea-magic+))

(defun read-footer (octets)
  "Parse footer from end of OCTETS. Returns plist or NIL if not a SEA.
   Layout offsets: host@0 payload@8 flags@16 sig-algo@20 sig-size@22
   version@24 reserved@26 magic@28 (8 bytes)."
  (when (< (length octets) +footer-size+)
    (return-from read-footer nil))
  (let* ((start (- (length octets) +footer-size+))
         (magic (subseq octets (+ start 28) (+ start 36))))
    (unless (equalp magic +sea-magic+)
      (return-from read-footer nil))
    (let ((version (%read-u16le octets (+ start 24))))
      (unless (= version +sea-version+)
        (%fail :unsupported-version (format nil "SEA version ~A" version)))
      (list :host-size (%read-u64le octets start)
            :payload-size (%read-u64le octets (+ start 8))
            :flags (%read-u32le octets (+ start 16))
            :sig-algo (%read-u16le octets (+ start 20))
            :sig-size (%read-u16le octets (+ start 22))
            :version version))))
(defun %file-size (path)
  (let ((st (sys:stat* path)))
    (and st (sys:fstat-size st))))

(defun %read-file-region (path start end)
  "Read bytes [START, END) from PATH without loading the whole file."
  (let* ((len (- end start))
         (buf (make-array len :element-type '(unsigned-byte 8))))
    (with-open-file (in (sys:native->pathname path)
                        :element-type '(unsigned-byte 8)
                        :direction :input)
      (file-position in start)
      (let ((n (read-sequence buf in)))
        (unless (= n len)
          (%fail :corrupt (format nil "short read ~A want ~A" n len)))
        buf))))

(defun %read-footer-from-file (path)
  "Read and parse the last +footer-size+ bytes of PATH. NIL if not a SEA."
  (let ((size (%file-size path)))
    (when (and size (>= size +footer-size+))
      (read-footer (%read-file-region path (- size +footer-size+) size)))))

(defun sea-file-p (path)
  "T if PATH ends with a CLUNSEA footer (O(1) disk read)."
  (and (sys:file-p path)
       (and (%read-footer-from-file path) t)))

(defun open-sea (path &key (include-host nil))
  "Open a SEA at PATH. Returns plist:
   :payload :signature :footer :manifest :modules :assets [:host]
   Host bytes are omitted unless INCLUDE-HOST is true (large)."
  (unless (sys:file-p path)
    (%fail :not-found path))
  (let* ((total (%file-size path))
         (footer (or (%read-footer-from-file path)
                     (%fail :not-sea path)))
         (host-size (getf footer :host-size))
         (payload-size (getf footer :payload-size))
         (sig-size (getf footer :sig-size))
         (expected (+ host-size payload-size sig-size +footer-size+)))
    (unless (= expected total)
      (%fail :corrupt
             (format nil "size mismatch total=~A expected=~A" total expected)))
    (let* ((payload (%read-file-region path host-size (+ host-size payload-size)))
           (signature (if (plusp sig-size)
                          (%read-file-region path
                                             (+ host-size payload-size)
                                             (+ host-size payload-size sig-size))
                          (make-array 0 :element-type '(unsigned-byte 8)))))
      (multiple-value-bind (manifest modules assets) (decode-payload payload)
        (list :host (when include-host
                      (%read-file-region path 0 host-size))
              :payload payload
              :signature signature
              :footer footer
              :manifest manifest
              :modules modules
              :assets assets
              :path path)))))

(defun host-size-of (path)
  "Bytes of runtime host in PATH (full size if not a SEA)."
  (let ((footer (%read-footer-from-file path)))
    (if footer
        (getf footer :host-size)
        (%file-size path))))

(defun %copy-file-prefix (src dst nbytes)
  "Copy the first NBYTES of SRC to DST (create/overwrite)."
  (with-open-file (in (sys:native->pathname src)
                      :element-type '(unsigned-byte 8)
                      :direction :input)
    (with-open-file (out (sys:native->pathname dst)
                         :element-type '(unsigned-byte 8)
                         :direction :output
                         :if-exists :supersede
                         :if-does-not-exist :create)
      (let ((buf (make-array (min nbytes (* 1024 1024))
                             :element-type '(unsigned-byte 8)))
            (left nbytes))
        (loop while (plusp left)
              do (let* ((want (min left (length buf)))
                        (n (read-sequence buf in :end want)))
                   (when (zerop n) (%fail :corrupt "short host copy"))
                   (write-sequence buf out :end n)
                   (decf left n)))))))

(defun write-sea (outfile host-path-or-octets payload signature flags sig-algo)
  "Write a complete SEA executable to OUTFILE.
   HOST-PATH-OR-OCTETS may be a pathname string (preferred, streams) or octets."
  (let* ((sig (or signature (make-array 0 :element-type '(unsigned-byte 8))))
         (host-size
          (if (stringp host-path-or-octets)
              (host-size-of host-path-or-octets)
              (length host-path-or-octets)))
         (footer (encode-footer host-size (length payload)
                                flags sig-algo (length sig))))
    (cond
      ((stringp host-path-or-octets)
       (%copy-file-prefix host-path-or-octets outfile host-size)
       (with-open-file (out (sys:native->pathname outfile)
                            :element-type '(unsigned-byte 8)
                            :direction :output
                            :if-exists :append
                            :if-does-not-exist :error)
         (write-sequence payload out)
         (when (plusp (length sig)) (write-sequence sig out))
         (write-sequence footer out)))
      (t
       (sys:write-file-octets outfile
                              (%cat host-path-or-octets payload sig footer))))
    (sys:change-mode outfile #o755)
    outfile))
