;;;; wire.lisp — binary buffer helpers for SQL wire protocols (Issue #183).
;;;; Pure Common Lisp; no foreign bindings. Big-endian network order used by PostgreSQL;
;;;; MySQL uses little-endian for most integer fields.

(in-package :clun.sql)

(defun make-byte-vector (n &optional (fill 0))
  (make-array n :element-type '(unsigned-byte 8) :initial-element fill))

(defun bytes (&rest values)
  (let ((v (make-byte-vector (length values))))
    (loop for i from 0 for b in values do (setf (aref v i) (logand b #xff)))
    v))

(defun concat-bytes (&rest parts)
  (let* ((total (loop for p in parts sum (length p)))
         (out (make-byte-vector total))
         (off 0))
    (dolist (p parts)
      (replace out p :start1 off)
      (incf off (length p)))
    out))

(defun u8 (n) (make-array 1 :element-type '(unsigned-byte 8)
                          :initial-element (logand n #xff)))

(defun u16be (n)
  (make-array 2 :element-type '(unsigned-byte 8)
              :initial-contents (list (logand (ash n -8) #xff)
                                      (logand n #xff))))

(defun u16le (n)
  (make-array 2 :element-type '(unsigned-byte 8)
              :initial-contents (list (logand n #xff)
                                      (logand (ash n -8) #xff))))

(defun u32be (n)
  (make-array 4 :element-type '(unsigned-byte 8)
              :initial-contents (list (logand (ash n -24) #xff)
                                      (logand (ash n -16) #xff)
                                      (logand (ash n -8) #xff)
                                      (logand n #xff))))

(defun u32le (n)
  (make-array 4 :element-type '(unsigned-byte 8)
              :initial-contents (list (logand n #xff)
                                      (logand (ash n -8) #xff)
                                      (logand (ash n -16) #xff)
                                      (logand (ash n -24) #xff))))

(defun i32be (n)
  (u32be (logand n #xffffffff)))

(defun i32le (n)
  (u32le (logand n #xffffffff)))

(defun read-u16be (buf offset)
  (logior (ash (aref buf offset) 8) (aref buf (1+ offset))))

(defun read-u16le (buf offset)
  (logior (aref buf offset) (ash (aref buf (1+ offset)) 8)))

(defun read-u32be (buf offset)
  (logior (ash (aref buf offset) 24)
          (ash (aref buf (+ offset 1)) 16)
          (ash (aref buf (+ offset 2)) 8)
          (aref buf (+ offset 3))))

(defun read-u32le (buf offset)
  (logior (aref buf offset)
          (ash (aref buf (+ offset 1)) 8)
          (ash (aref buf (+ offset 2)) 16)
          (ash (aref buf (+ offset 3)) 24)))

(defun read-i32be (buf offset)
  (let ((u (read-u32be buf offset)))
    (if (>= u #x80000000) (- u #x100000000) u)))

(defun read-i32le (buf offset)
  (let ((u (read-u32le buf offset)))
    (if (>= u #x80000000) (- u #x100000000) u)))

(defun cstring-bytes (string)
  "UTF-8 bytes of STRING terminated by a single NUL."
  (let* ((raw (sb-ext:string-to-octets string :external-format :utf-8))
         (out (make-byte-vector (1+ (length raw)))))
    (replace out raw)
    out))

(defun utf8-bytes (string)
  (sb-ext:string-to-octets (or string "") :external-format :utf-8))

(defun bytes-to-utf8 (octets &optional (start 0) end)
  (sb-ext:octets-to-string octets :external-format :utf-8
                           :start start :end (or end (length octets))))

(defun read-cstring (buf offset)
  "Return (values string next-offset) reading a NUL-terminated UTF-8 string."
  (let ((end offset))
    (loop while (and (< end (length buf)) (plusp (aref buf end)))
          do (incf end))
    (values (if (= end offset) "" (bytes-to-utf8 buf offset end))
            (1+ end))))

(defun hex-encode (octets)
  (with-output-to-string (s)
    (loop for b across octets
          do (format s "~2,'0x" b))))

(defun hex-decode (hex)
  (let* ((len (length hex))
         (out (make-byte-vector (floor len 2))))
    (loop for i from 0 below len by 2
          for j from 0
          do (setf (aref out j)
                   (parse-integer hex :start i :end (+ i 2) :radix 16)))
    out))

(defun digest-bytes (algorithm octets)
  (ironclad:digest-sequence algorithm octets))

(defun hmac-bytes (algorithm key data)
  (let ((mac (ironclad:make-hmac key algorithm)))
    (ironclad:update-hmac mac data)
    (ironclad:hmac-digest mac)))

(defun md5-hex (octets)
  (hex-encode (digest-bytes :md5 octets)))

(defun sha256 (octets)
  (digest-bytes :sha256 octets))

(defun xor-bytes (a b)
  (let* ((n (min (length a) (length b)))
         (out (make-byte-vector n)))
    (dotimes (i n)
      (setf (aref out i) (logxor (aref a i) (aref b i))))
    out))

(defun split-char (separator string &key remove-empty-subseqs)
  "Minimal pure-CL splitter (avoids a split-sequence dependency)."
  (let ((parts '())
        (start 0)
        (n (length string)))
    (loop for i from 0 to n
          do (when (or (= i n) (eql (char string i) separator))
               (let ((part (subseq string start i)))
                 (unless (and remove-empty-subseqs (zerop (length part)))
                   (push part parts)))
               (setf start (1+ i))))
    (nreverse parts)))
