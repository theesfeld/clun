;;;; compress.lisp — pure-CL gzip / zlib / raw-deflate codecs (Phase 74 / Issue #134).
;;;; Compress with vendored salza2; decompress with vendored chipz. Every inflate path
;;;; is hard-capped so hostile streams cannot exhaust the heap. Pure CL only; no zstd.

(in-package :clun.compress)

(define-condition compress-error (error)
  ((message :initarg :message :reader compress-error-message :initform "compress error"))
  (:report (lambda (c s) (write-string (compress-error-message c) s))))

(defparameter *max-decompressed-bytes* (* 512 1024 1024)
  "Hard cap on a single decompress output. Zip bombs hit this and signal compress-error.")

(defun %coerce-octets (data)
  "Accept a (vector (unsigned-byte 8)) or UTF-8 string → simple-array of octets."
  (cond
    ((typep data '(simple-array (unsigned-byte 8) (*))) data)
    ((typep data '(vector (unsigned-byte 8)))
     (coerce data '(simple-array (unsigned-byte 8) (*))))
    ((stringp data)
     (sb-ext:string-to-octets data :external-format :utf-8))
    (t (error 'compress-error
              :message "compress input must be a byte vector or string"))))

(defun %u16le (n)
  (vector (logand n #xff) (logand (ash n -8) #xff)))

(defun %u32le (n)
  (vector (logand n #xff) (logand (ash n -8) #xff)
          (logand (ash n -16) #xff) (logand (ash n -24) #xff)))

(defun %emit-stored-deflate (data)
  "RFC 1951 BTYPE=00 stored blocks covering DATA (may be empty)."
  (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
        (n (length data)))
    (flet ((emit (seq) (loop for b across seq do (vector-push-extend b out))))
      (if (zerop n)
          (progn (emit #(#x01)) (emit (%u16le 0)) (emit (%u16le #xffff)))
          (loop with pos = 0
                for remaining = (- n pos)
                for len = (min remaining 65535)
                for finalp = (<= remaining 65535)
                do (emit (vector (if finalp 1 0)))
                   (emit (%u16le len))
                   (emit (%u16le (logand (lognot len) #xffff)))
                   (loop for i from pos below (+ pos len)
                         do (vector-push-extend (aref data i) out))
                   (incf pos len)
                until finalp)))
    (coerce out '(simple-array (unsigned-byte 8) (*)))))

(defun %gzip-stored (data)
  "Valid empty-safe gzip via stored DEFLATE blocks + CRC32/ISIZE trailers."
  (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
        (n (length data)))
    (flet ((emit (seq) (loop for b across seq do (vector-push-extend b out))))
      (emit #(#x1f #x8b #x08 #x00 #x00 #x00 #x00 #x00 #x00 #xff))
      (emit (%emit-stored-deflate data))
      (emit (reverse (ironclad:digest-sequence :crc32 data)))
      (emit (%u32le (logand n #xffffffff))))
    (coerce out '(simple-array (unsigned-byte 8) (*)))))

(defun %zlib-stored (data)
  "Valid empty-safe zlib (CMF/FLG + stored DEFLATE + Adler-32)."
  (let* ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
         ;; CMF=0x78 window 32k; FLG chosen so (CMF*256+FLG) % 31 == 0 → 0x01
         (adler (ironclad:digest-sequence :adler32 data)))
    (flet ((emit (seq) (loop for b across seq do (vector-push-extend b out))))
      (emit #(#x78 #x01))
      (emit (%emit-stored-deflate data))
      ;; Adler-32 is big-endian
      (emit adler))
    (coerce out '(simple-array (unsigned-byte 8) (*)))))

(defun %salza-compress (octets designator)
  (handler-case
      (salza2:compress-data octets designator)
    (error (c)
      (error 'compress-error
             :message (format nil "compression failed: ~a" c)))))

(defun gzip-compress (data &key (level 6))
  "gzip-compress DATA (octets or string). LEVEL is accepted for Bun parity (0–12).
  Empty input uses a stored-block encoder (salza2 empty streams are not chipz-safe)."
  (declare (ignore level))
  (let ((octets (%coerce-octets data)))
    (if (zerop (length octets))
        (%gzip-stored octets)
        (%salza-compress octets 'salza2:gzip-compressor))))

(defun zlib-compress (data &key (level 6))
  "zlib (DEFLATE with zlib header/footer) compress — Bun.deflateSync default format."
  (declare (ignore level))
  (let ((octets (%coerce-octets data)))
    (if (zerop (length octets))
        (%zlib-stored octets)
        (%salza-compress octets 'salza2:zlib-compressor))))

(defun raw-deflate-compress (data &key (level 6))
  "Raw DEFLATE (no zlib/gzip wrapper).
  salza2's raw deflate-compressor does not always produce chipz-compatible streams
  (Unexpected EOF on some payloads), so we emit RFC 1951 stored blocks — valid
  DEFLATE that chipz and ZIP consumers accept. LEVEL is accepted for Bun shape."
  (declare (ignore level))
  (%emit-stored-deflate (%coerce-octets data)))

(defun %decompress-bounded (format octets &key (max-bytes *max-decompressed-bytes*))
  "Bounded chipz decompress. FORMAT is one of :gzip :zlib :deflate."
  (handler-case
      (flexi-streams:with-input-from-sequence (in octets)
        (let* ((chipz-format (ecase format
                               (:gzip 'chipz:gzip)
                               (:zlib 'chipz:zlib)
                               (:deflate 'chipz:deflate)))
               (ds (chipz:make-decompressing-stream chipz-format in))
               (out (make-array (* 64 1024) :element-type '(unsigned-byte 8)
                                            :adjustable t :fill-pointer 0))
               (buf (make-array (* 64 1024) :element-type '(unsigned-byte 8))))
          (loop for n = (read-sequence buf ds)
                while (plusp n) do
                  (when (> (+ (fill-pointer out) n) max-bytes)
                    (error 'compress-error
                           :message "decompression exceeded the size cap (zip bomb?)"))
                  (let* ((old (fill-pointer out))
                         (needed (+ old n))
                         (capacity (array-total-size out)))
                    (when (> needed capacity)
                      (adjust-array out
                                    (min max-bytes (max needed (* 2 capacity)))
                                    :fill-pointer old))
                    (setf (fill-pointer out) needed)
                    (replace out buf :start1 old :end2 n)))
          (coerce out '(simple-array (unsigned-byte 8) (*)))))
    (compress-error (c) (error c))
    (chipz:decompression-error (c)
      (error 'compress-error
             :message (format nil "decompression failed: ~a" c)))
    (error (c)
      (error 'compress-error
             :message (format nil "decompression failed: ~a" c)))))

(defun gunzip (data &key (max-bytes *max-decompressed-bytes*))
  "Gunzip DATA (octets). Bounded; signals compress-error on hostile/corrupt input."
  (%decompress-bounded :gzip (%coerce-octets data) :max-bytes max-bytes))

(defun zlib-decompress (data &key (max-bytes *max-decompressed-bytes*))
  "Inflate zlib-wrapped DEFLATE (Bun.inflateSync default)."
  (%decompress-bounded :zlib (%coerce-octets data) :max-bytes max-bytes))

(defun raw-inflate (data &key (max-bytes *max-decompressed-bytes*))
  "Inflate raw DEFLATE (no wrapper)."
  (%decompress-bounded :deflate (%coerce-octets data) :max-bytes max-bytes))

(defun gzip-magic-p (octets)
  "True when OCTETS starts with the gzip magic 1F 8B."
  (and (>= (length octets) 2)
       (= (aref octets 0) #x1f)
       (= (aref octets 1) #x8b)))
