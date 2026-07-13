;;;; buffer.lisp — node:buffer (PLAN.md Phase 13). Buffer is a Uint8Array subclass:
;;;; an instance is a Uint8Array over its own bytes with [[Prototype]]=Buffer.prototype,
;;;; so indexing/.length/typed-array methods inherit. Byte access goes through
;;;; (eng:ta-octets this) -> (values BACKING BYTE-OFFSET LENGTH); index i is BACKING[offset+i].
;;;; Encodings (utf8/ascii/latin1/hex/base64/base64url/ucs2) are hand-rolled below.

(in-package :clun.runtime)

(defvar *buffer-proto* nil
  "Buffer.prototype, shared by %buffer-from-octets and all statics; set in build-node-buffer.")

;;; --- interop point: node:fs wraps a byte vector as a Buffer via this ---------

(defun %buffer-from-octets (octets)
  "Wrap OCTETS (a byte vector or list) as a Buffer instance (Uint8Array over a COPY,
proto=*buffer-proto*). Required node:fs interop point."
  (eng:u8-from-octets octets *buffer-proto*))

;;; --- octet-vector view of a Buffer/Uint8Array `this` ------------------------

(defun %buf-view (this)
  "For a Buffer/Uint8Array THIS return (values BACKING BYTE-OFFSET LENGTH)."
  (unless (eng:js-typed-array-p this) (eng:throw-type-error "not a Buffer"))
  (eng:ta-octets this))

(defun %buf-len (this)
  (multiple-value-bind (b off len) (%buf-view this) (declare (ignore b off)) len))

(defun %clamp (v lo hi) (max lo (min hi v)))

(defun %to-idx (v default lo hi)
  "Coerce arg V to an integer index, defaulting when undefined, then clamp to [lo,hi]."
  (if (undef-p v) default
      (let ((n (eng:to-integer-or-infinity v)))
        (cond ((eng:js-infinite-p n) (if (plusp n) hi lo))
              (t (%clamp (truncate n) lo hi))))))

;;; --- encodings --------------------------------------------------------------

(defun %norm-enc (v &optional (default "utf8"))
  "Normalize an encoding name to a canonical keyword, or NIL if unrecognized."
  (let ((s (string-downcase (if (undef-p v) default (->str v)))))
    (cond ((or (string= s "utf8") (string= s "utf-8")) :utf8)
          ((string= s "ascii") :ascii)
          ((or (string= s "latin1") (string= s "binary")) :latin1)
          ((string= s "hex") :hex)
          ((string= s "base64") :base64)
          ((string= s "base64url") :base64url)
          ((or (string= s "ucs2") (string= s "ucs-2")
               (string= s "utf16le") (string= s "utf-16le")) :ucs2)
          (t nil))))

(defun %utf8-encode (str)
  "JS string -> UTF-8 octet vector, encoding surrogate PAIRS as astral code points."
  (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
        (i 0) (n (length str)))
    (flet ((emit (b) (vector-push-extend b out)))
      (loop while (< i n) do
        (let ((cc (char-code (char str i))))
          (when (and (<= #xD800 cc #xDBFF) (< (1+ i) n)
                     (<= #xDC00 (char-code (char str (1+ i))) #xDFFF))
            (setf cc (+ #x10000 (ash (- cc #xD800) 10) (- (char-code (char str (1+ i))) #xDC00)))
            (incf i))
          (cond ((< cc #x80) (emit cc))
                ((< cc #x800) (emit (logior #xC0 (ash cc -6))) (emit (logior #x80 (logand cc #x3F))))
                ((< cc #x10000)
                 (emit (logior #xE0 (ash cc -12)))
                 (emit (logior #x80 (logand (ash cc -6) #x3F)))
                 (emit (logior #x80 (logand cc #x3F))))
                (t (emit (logior #xF0 (ash cc -18)))
                   (emit (logior #x80 (logand (ash cc -12) #x3F)))
                   (emit (logior #x80 (logand (ash cc -6) #x3F)))
                   (emit (logior #x80 (logand cc #x3F)))))
          (incf i))))
    out))

(defun %buf-utf8-decode (bytes off len)
  "UTF-8 octets -> JS string; malformed sequences become U+FFFD. Astral code points
are emitted as surrogate pairs (JS strings are UTF-16 code-unit sequences)."
  (let ((out (make-string-output-stream)) (i off) (end (+ off len)))
    (flet ((put (cp)
             (if (> cp #xFFFF)
                 (let ((v (- cp #x10000)))
                   (write-char (code-char (+ #xD800 (ash v -10))) out)
                   (write-char (code-char (+ #xDC00 (logand v #x3FF))) out))
                 (write-char (code-char cp) out)))
           (cont (k) (and (< k end) (= (logand (aref bytes k) #xC0) #x80))))
      (loop while (< i end) do
        (let ((b (aref bytes i)))
          (cond
            ((< b #x80) (put b) (incf i))
            ((and (= (logand b #xE0) #xC0) (cont (+ i 1)))
             (put (logior (ash (logand b #x1F) 6) (logand (aref bytes (+ i 1)) #x3F))) (incf i 2))
            ((and (= (logand b #xF0) #xE0) (cont (+ i 1)) (cont (+ i 2)))
             (put (logior (ash (logand b #x0F) 12) (ash (logand (aref bytes (+ i 1)) #x3F) 6)
                          (logand (aref bytes (+ i 2)) #x3F))) (incf i 3))
            ((and (= (logand b #xF8) #xF0) (cont (+ i 1)) (cont (+ i 2)) (cont (+ i 3)))
             (put (logior (ash (logand b #x07) 18) (ash (logand (aref bytes (+ i 1)) #x3F) 12)
                          (ash (logand (aref bytes (+ i 2)) #x3F) 6) (logand (aref bytes (+ i 3)) #x3F)))
             (incf i 4))
            (t (put #xFFFD) (incf i))))))
    (get-output-stream-string out)))

(defparameter +b64+ "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
(defparameter +b64url+ "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

(defun %b64-decval (c)
  (cond ((char<= #\A c #\Z) (- (char-code c) 65))
        ((char<= #\a c #\z) (+ 26 (- (char-code c) 97)))
        ((char<= #\0 c #\9) (+ 52 (- (char-code c) 48)))
        ((or (char= c #\+) (char= c #\-)) 62)
        ((or (char= c #\/) (char= c #\_)) 63)
        (t nil)))

(defun %base64-encode (bytes off len url)
  (let ((alpha (if url +b64url+ +b64+)) (out (make-string-output-stream)) (i off) (end (+ off len)))
    (loop while (< i end) do
      (let* ((b0 (aref bytes i))
             (b1 (if (< (+ i 1) end) (aref bytes (+ i 1)) 0))
             (b2 (if (< (+ i 2) end) (aref bytes (+ i 2)) 0))
             (n (logior (ash b0 16) (ash b1 8) b2))
             (rem (- end i)))
        (write-char (char alpha (logand (ash n -18) #x3F)) out)
        (write-char (char alpha (logand (ash n -12) #x3F)) out)
        (if (>= rem 2) (write-char (char alpha (logand (ash n -6) #x3F)) out)
            (unless url (write-char #\= out)))
        (if (>= rem 3) (write-char (char alpha (logand n #x3F)) out)
            (unless url (write-char #\= out)))
        (incf i 3)))
    (get-output-stream-string out)))

(defun %base64-decode (str)
  "Decode base64/base64url; ignores whitespace and padding, accepts either alphabet."
  (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
        (acc 0) (bits 0))
    (loop for c across str
          for v = (%b64-decval c)
          when v do
            (setf acc (logior (ash acc 6) v) bits (+ bits 6))
            (when (>= bits 8)
              (decf bits 8)
              (vector-push-extend (logand (ash acc (- bits)) #xFF) out)))
    out))

(defun %hex-decode (str)
  (let* ((s (string-trim '(#\Space #\Tab #\Newline #\Return) str))
         (pairs (truncate (length s) 2))
         (out (make-array pairs :element-type '(unsigned-byte 8))))
    (dotimes (i pairs out)
      (let ((hi (digit-char-p (char s (* 2 i)) 16))
            (lo (digit-char-p (char s (1+ (* 2 i))) 16)))
        (unless (and hi lo) (return (subseq out 0 i)))
        (setf (aref out i) (logior (ash hi 4) lo))))))

(defun %hex-encode (bytes off len)
  (let ((out (make-string (* 2 len))))
    (dotimes (i len out)
      (let ((b (aref bytes (+ off i))))
        (setf (char out (* 2 i)) (char-downcase (digit-char (ash b -4) 16))
              (char out (1+ (* 2 i))) (char-downcase (digit-char (logand b #xF) 16)))))))

(defun %ucs2-encode (str)
  (let* ((n (length str)) (out (make-array (* 2 n) :element-type '(unsigned-byte 8))))
    (dotimes (i n out)
      (let ((cc (char-code (char str i))))
        (setf (aref out (* 2 i)) (logand cc #xFF)
              (aref out (1+ (* 2 i))) (logand (ash cc -8) #xFF))))))

(defun %ucs2-decode (bytes off len)
  (let* ((units (truncate len 2)) (out (make-string units)))
    (dotimes (i units out)
      (setf (char out i)
            (code-char (logior (aref bytes (+ off (* 2 i)))
                               (ash (aref bytes (+ off (1+ (* 2 i)))) 8)))))))

(defun %encode-string (str enc)
  "JS string STR -> octet vector, per encoding keyword ENC."
  (ecase enc
    (:utf8 (%utf8-encode str))
    (:ascii (map '(vector (unsigned-byte 8)) (lambda (c) (logand (char-code c) #x7F)) str))
    (:latin1 (map '(vector (unsigned-byte 8)) (lambda (c) (logand (char-code c) #xFF)) str))
    (:hex (%hex-decode str))
    (:base64 (%base64-decode str))
    (:base64url (%base64-decode str))
    (:ucs2 (%ucs2-encode str))))

(defun %decode-bytes (bytes off len enc)
  "Octets BYTES[off,off+len) -> JS string, per encoding keyword ENC."
  (ecase enc
    (:utf8 (%buf-utf8-decode bytes off len))
    ((:ascii :latin1)
     (let ((s (make-string len)))
       (dotimes (i len s)
         (setf (char s i) (code-char (if (eq enc :ascii)
                                         (logand (aref bytes (+ off i)) #x7F)
                                         (aref bytes (+ off i))))))))
    (:hex (%hex-encode bytes off len))
    (:base64 (%base64-encode bytes off len nil))
    (:base64url (%base64-encode bytes off len t))
    (:ucs2 (%ucs2-decode bytes off len))))

;;; --- byte-source coercion for Buffer.from / concat --------------------------

(defun %value->octets (value arg2 arg3)
  "Turn a Buffer.from VALUE into a fresh octet vector (a copy). ArrayBuffer views over
offset/len are still copied here; the ArrayBuffer branch is handled by the caller."
  (cond
    ((eng:js-string-p value)
     (let ((enc (or (%norm-enc arg2) (eng:throw-type-error "unknown encoding"))))
       (%encode-string value enc)))
    ((eng:js-typed-array-p value)
     (multiple-value-bind (b off len) (eng:ta-octets value)
       (subseq b off (+ off len))))
    (t ;; Array / array-like: bytes mod 256
     (let* ((n (eng:length-of-array-like value))
            (out (make-array n :element-type '(unsigned-byte 8))))
       (dotimes (i n out)
         (let ((x (eng:to-integer-or-infinity (eng:js-getv value (number->key i)))))
           (setf (aref out i) (logand (if (eng:js-infinite-p x) 0 (truncate x)) #xFF))))))))

(defun number->key (i) (eng:to-string (coerce i 'double-float)))

(defun %array-buffer-view (ab arg2 arg3)
  "Buffer.from(ArrayBuffer, byteOffset?, length?) -> a Buffer VIEW SHARING AB's memory."
  (let* ((bytes (eng:js-getv ab "byteLength"))
         (total (if (eng:js-number-p bytes) (truncate bytes) 0))
         (off (%to-idx arg2 0 0 total))
         (len (if (undef-p arg3) (- total off) (%to-idx arg3 (- total off) 0 (- total off)))))
    (eng:u8-over-arraybuffer ab off len *buffer-proto*)))

;;; --- Buffer.from dispatch ---------------------------------------------------

(defun %buffer-from (value arg2 arg3)
  (cond
    ((eng:js-array-buffer-p value) (%array-buffer-view value arg2 arg3))
    (t (%buffer-from-octets (%value->octets value arg2 arg3)))))

;;; --- fill helper ------------------------------------------------------------

(defun %fill-octets (bytes off start end value enc)
  "Fill BACKING[off+start, off+end) with VALUE (a number, or a string per ENC)."
  (cond
    ((eng:js-string-p value)
     (let ((pat (%encode-string value (or (%norm-enc enc) :utf8))))
       (if (zerop (length pat))
           nil
           (loop for i from start below end
                 do (setf (aref bytes (+ off i)) (aref pat (mod (- i start) (length pat))))))))
    (t (let ((b (logand (let ((n (eng:to-integer-or-infinity value)))
                          (if (eng:js-infinite-p n) 0 (truncate n))) #xFF)))
         (loop for i from start below end do (setf (aref bytes (+ off i)) b))))))

;;; --- numeric read/write helpers (LE/BE, guarded float reads) ----------------

(defun %num-bounds (bytes off n)
  "RangeError [ERR_OUT_OF_RANGE] instead of a raw Lisp abort on an OOB numeric access."
  (when (or (< off 0) (> (+ off n) (length bytes)))
    (eng:throw-range-error
     (format nil "The value of \"offset\" is out of range. It must be >= 0 and <= ~a. Received ~a"
             (max 0 (- (length bytes) n)) off))))

(defun %read-uint (bytes off n le)
  (%num-bounds bytes off n)
  (let ((v 0))
    (if le (dotimes (i n) (setf v (logior v (ash (aref bytes (+ off i)) (* 8 i)))))
        (dotimes (i n) (setf v (logior (ash v 8) (aref bytes (+ off i))))))
    v))

(defun %read-int (bytes off n le)
  (let ((v (%read-uint bytes off n le)) (bits (* 8 n)))
    (if (>= v (ash 1 (1- bits))) (- v (ash 1 bits)) v)))

(defun %write-uint (bytes off n v le)
  (%num-bounds bytes off n)
  (let ((u (logand v (1- (ash 1 (* 8 n))))))
    (if le (dotimes (i n) (setf (aref bytes (+ off i)) (logand (ash u (* -8 i)) #xFF)))
        (dotimes (i n) (setf (aref bytes (+ off i)) (logand (ash u (* -8 (- n 1 i))) #xFF)))))
  (+ off n))

(defun %read-f32 (bytes off le)
  (let ((bits (%read-uint bytes off 4 le)))
    (sb-int:with-float-traps-masked (:overflow :invalid :divide-by-zero)
      (coerce (sb-kernel:make-single-float
               (if (>= bits #x80000000) (- bits #x100000000) bits))
              'double-float))))

(defun %write-f32 (bytes off value le)
  (let ((bits (logand (sb-kernel:single-float-bits (coerce value 'single-float)) #xFFFFFFFF)))
    (%write-uint bytes off 4 bits le)))

(defun %read-f64 (bytes off le)
  (let* ((lo (%read-uint bytes off 4 le))
         (hi (%read-uint bytes (+ off 4) 4 le)))
    (when (not le) (rotatef lo hi))
    (sb-int:with-float-traps-masked (:overflow :invalid :divide-by-zero)
      (sb-kernel:make-double-float
       (if (>= hi #x80000000) (- hi #x100000000) hi) lo))))

(defun %write-f64 (bytes off value le)
  (%num-bounds bytes off 8)                  ; guard the full width so a boundary offset can't partial-write
  (let* ((d (coerce value 'double-float))
         (hi (logand (sb-kernel:double-float-high-bits d) #xFFFFFFFF))
         (lo (sb-kernel:double-float-low-bits d)))
    (if le (progn (%write-uint bytes off 4 lo t) (%write-uint bytes (+ off 4) 4 hi t))
        (progn (%write-uint bytes off 4 hi nil) (%write-uint bytes (+ off 4) 4 lo nil)))
    (+ off 8)))

;;; --- prototype method installers --------------------------------------------

(defun %install-numeric (proto)
  "Install read*/write* numeric accessors on the Buffer prototype."
  (labels ((m (name arity fn) (eng:install-method proto name arity fn))
           (rd-u (name n le)
             (m name 1 (lambda (this args)
                         (multiple-value-bind (b off) (%buf-view this)
                           (coerce (%read-uint b (+ off (%to-idx (a args 0) 0 0 most-positive-fixnum))
                                              n le) 'double-float)))))
           (rd-i (name n le)
             (m name 1 (lambda (this args)
                         (multiple-value-bind (b off) (%buf-view this)
                           (coerce (%read-int b (+ off (%to-idx (a args 0) 0 0 most-positive-fixnum))
                                             n le) 'double-float)))))
           (wr (name n le signed)
             (declare (ignore signed))
             (m name 2 (lambda (this args)
                         (multiple-value-bind (b off) (%buf-view this)
                           (let ((v (eng:to-integer-or-infinity (a args 0)))
                                 (o (%to-idx (a args 1) 0 0 most-positive-fixnum)))
                             (coerce (%write-uint b (+ off o) n
                                                  (if (eng:js-infinite-p v) 0 (truncate v)) le)
                                     'double-float))))))
           (rd-big (name n le signed)
             (m name 1 (lambda (this args)
                         (multiple-value-bind (b off) (%buf-view this)
                           (let ((o (+ off (%to-idx (a args 0) 0 0 most-positive-fixnum))))
                             (if signed (%read-int b o n le) (%read-uint b o n le)))))))
           (wr-big (name n le)
             (m name 2 (lambda (this args)
                         (multiple-value-bind (b off) (%buf-view this)
                           (let ((v (a args 0)) (o (%to-idx (a args 1) 0 0 most-positive-fixnum)))
                             (coerce (%write-uint b (+ off o) n
                                                  (if (integerp v) v (truncate (->num v))) le)
                                     'double-float)))))))
    ;; 8-bit
    (rd-u "readUInt8" 1 t) (rd-i "readInt8" 1 t)
    (wr "writeUInt8" 1 t nil) (wr "writeInt8" 1 t t)
    ;; 16-bit
    (rd-u "readUInt16LE" 2 t) (rd-u "readUInt16BE" 2 nil)
    (rd-i "readInt16LE" 2 t) (rd-i "readInt16BE" 2 nil)
    (wr "writeUInt16LE" 2 t nil) (wr "writeUInt16BE" 2 nil nil)
    (wr "writeInt16LE" 2 t t) (wr "writeInt16BE" 2 nil t)
    ;; 32-bit
    (rd-u "readUInt32LE" 4 t) (rd-u "readUInt32BE" 4 nil)
    (rd-i "readInt32LE" 4 t) (rd-i "readInt32BE" 4 nil)
    (wr "writeUInt32LE" 4 t nil) (wr "writeUInt32BE" 4 nil nil)
    (wr "writeInt32LE" 4 t t) (wr "writeInt32BE" 4 nil t)
    ;; BigInt 64-bit
    (rd-big "readBigUInt64LE" 8 t nil) (rd-big "readBigUInt64BE" 8 nil nil)
    (rd-big "readBigInt64LE" 8 t t) (rd-big "readBigInt64BE" 8 nil t)
    (wr-big "writeBigUInt64LE" 8 t) (wr-big "writeBigUInt64BE" 8 nil)
    (wr-big "writeBigInt64LE" 8 t) (wr-big "writeBigInt64BE" 8 nil)
    ;; floats
    (m "readFloatLE" 1 (lambda (this args) (multiple-value-bind (b off) (%buf-view this)
                         (%read-f32 b (+ off (%to-idx (a args 0) 0 0 most-positive-fixnum)) t))))
    (m "readFloatBE" 1 (lambda (this args) (multiple-value-bind (b off) (%buf-view this)
                         (%read-f32 b (+ off (%to-idx (a args 0) 0 0 most-positive-fixnum)) nil))))
    (m "readDoubleLE" 1 (lambda (this args) (multiple-value-bind (b off) (%buf-view this)
                          (%read-f64 b (+ off (%to-idx (a args 0) 0 0 most-positive-fixnum)) t))))
    (m "readDoubleBE" 1 (lambda (this args) (multiple-value-bind (b off) (%buf-view this)
                          (%read-f64 b (+ off (%to-idx (a args 0) 0 0 most-positive-fixnum)) nil))))
    (m "writeFloatLE" 2 (lambda (this args) (multiple-value-bind (b off) (%buf-view this)
                          (coerce (%write-f32 b (+ off (%to-idx (a args 1) 0 0 most-positive-fixnum))
                                              (->num (a args 0)) t) 'double-float))))
    (m "writeFloatBE" 2 (lambda (this args) (multiple-value-bind (b off) (%buf-view this)
                          (coerce (%write-f32 b (+ off (%to-idx (a args 1) 0 0 most-positive-fixnum))
                                              (->num (a args 0)) nil) 'double-float))))
    (m "writeDoubleLE" 2 (lambda (this args) (multiple-value-bind (b off) (%buf-view this)
                           (coerce (%write-f64 b (+ off (%to-idx (a args 1) 0 0 most-positive-fixnum))
                                               (->num (a args 0)) t) 'double-float))))
    (m "writeDoubleBE" 2 (lambda (this args) (multiple-value-bind (b off) (%buf-view this)
                           (coerce (%write-f64 b (+ off (%to-idx (a args 1) 0 0 most-positive-fixnum))
                                               (->num (a args 0)) nil) 'double-float))))
    ;; variable byteLength 1..6
    (m "readUIntLE" 2 (lambda (this args) (multiple-value-bind (b off) (%buf-view this)
                        (coerce (%read-uint b (+ off (%to-idx (a args 0) 0 0 most-positive-fixnum))
                                           (truncate (->num (a args 1))) t) 'double-float))))
    (m "readUIntBE" 2 (lambda (this args) (multiple-value-bind (b off) (%buf-view this)
                        (coerce (%read-uint b (+ off (%to-idx (a args 0) 0 0 most-positive-fixnum))
                                           (truncate (->num (a args 1))) nil) 'double-float))))
    (m "readIntLE" 2 (lambda (this args) (multiple-value-bind (b off) (%buf-view this)
                       (coerce (%read-int b (+ off (%to-idx (a args 0) 0 0 most-positive-fixnum))
                                         (truncate (->num (a args 1))) t) 'double-float))))
    (m "readIntBE" 2 (lambda (this args) (multiple-value-bind (b off) (%buf-view this)
                       (coerce (%read-int b (+ off (%to-idx (a args 0) 0 0 most-positive-fixnum))
                                         (truncate (->num (a args 1))) nil) 'double-float))))
    (m "writeUIntLE" 3 (lambda (this args) (multiple-value-bind (b off) (%buf-view this)
                         (let ((v (eng:to-integer-or-infinity (a args 0))))
                           (coerce (%write-uint b (+ off (%to-idx (a args 1) 0 0 most-positive-fixnum))
                                                (truncate (->num (a args 2)))
                                                (if (eng:js-infinite-p v) 0 (truncate v)) t)
                                   'double-float)))))
    (m "writeUIntBE" 3 (lambda (this args) (multiple-value-bind (b off) (%buf-view this)
                         (let ((v (eng:to-integer-or-infinity (a args 0))))
                           (coerce (%write-uint b (+ off (%to-idx (a args 1) 0 0 most-positive-fixnum))
                                                (truncate (->num (a args 2)))
                                                (if (eng:js-infinite-p v) 0 (truncate v)) nil)
                                   'double-float)))))
    (m "writeIntLE" 3 (lambda (this args) (multiple-value-bind (b off) (%buf-view this)
                        (let ((v (eng:to-integer-or-infinity (a args 0))))
                          (coerce (%write-uint b (+ off (%to-idx (a args 1) 0 0 most-positive-fixnum))
                                               (truncate (->num (a args 2)))
                                               (if (eng:js-infinite-p v) 0 (truncate v)) t)
                                  'double-float)))))
    (m "writeIntBE" 3 (lambda (this args) (multiple-value-bind (b off) (%buf-view this)
                        (let ((v (eng:to-integer-or-infinity (a args 0))))
                          (coerce (%write-uint b (+ off (%to-idx (a args 1) 0 0 most-positive-fixnum))
                                               (truncate (->num (a args 2)))
                                               (if (eng:js-infinite-p v) 0 (truncate v)) nil)
                                  'double-float)))))))

;;; --- indexOf / lastIndexOf / includes ---------------------------------------

(defun %needle->octets (value enc)
  "Coerce an indexOf/fill/etc VALUE to a search needle octet vector."
  (cond
    ((eng:js-string-p value) (%encode-string value (or (%norm-enc enc) :utf8)))
    ((eng:js-typed-array-p value)
     (multiple-value-bind (b off len) (eng:ta-octets value) (subseq b off (+ off len))))
    (t (let ((n (logand (let ((x (eng:to-integer-or-infinity value)))
                          (if (eng:js-infinite-p x) 0 (truncate x))) #xFF)))
         (make-array 1 :element-type '(unsigned-byte 8) :initial-element n)))))

(defun %buf-index-of (this value byte-offset enc last)
  (multiple-value-bind (b off len) (%buf-view this)
    (let* ((needle (%needle->octets value enc))
           (nl (length needle))
           (start (%to-idx byte-offset (if last (1- len) 0)
                           (if last (- 1) 0) len)))
      (when (< start 0) (setf start (max 0 (+ len start))))
      (cond
        ((zerop nl) (if last (min start len) 0))
        (t (flet ((match-at (p)
                    (and (<= (+ p nl) len)
                         (loop for k below nl always (= (aref b (+ off p k)) (aref needle k))))))
             (if last
                 (loop for p from (min start (- len nl)) downto 0
                       when (match-at p) do (return p) finally (return -1))
                 (loop for p from start to (- len nl)
                       when (match-at p) do (return p) finally (return -1)))))))))

;;; --- prototype (non-numeric) methods ----------------------------------------

(defun %install-proto-methods (proto)
  (labels ((m (name arity fn) (eng:install-method proto name arity fn)))
    (m "toString" 3
       (lambda (this args)
         (multiple-value-bind (b off len) (%buf-view this)
           (let* ((enc (or (%norm-enc (a args 0)) (eng:throw-type-error "unknown encoding")))
                  (start (%to-idx (a args 1) 0 0 len))
                  (end (%to-idx (a args 2) len 0 len)))
             (if (<= end start) "" (%decode-bytes b (+ off start) (- end start) enc))))))
    (m "toJSON" 0
       (lambda (this args) (declare (ignore args))
         (multiple-value-bind (b off len) (%buf-view this)
           (let ((o (eng:new-object)))
             (eng:data-prop o "type" "Buffer")
             (eng:data-prop o "data"
                            (eng:new-array (loop for i below len
                                                 collect (coerce (aref b (+ off i)) 'double-float))))
             o))))
    (m "write" 4
       (lambda (this args)
         ;; write(string[, offset[, length]][, encoding]); the 2-arg form write(string, encoding)
         ;; has a STRING second arg standing in for the encoding, with offset defaulting to 0.
         (multiple-value-bind (b off len) (%buf-view this)
           (let* ((str (->str (a args 0)))
                  (a1 (a args 1)) (a2 (a args 2)) (a3 (a args 3))
                  (enc-in-a1 (and (eng:js-string-p a1) (undef-p a2)))
                  (start (if (or (undef-p a1) enc-in-a1) 0 (%to-idx a1 0 0 len)))
                  (has-len (eng:js-number-p a2))
                  (maxlen (- len start))
                  (wlen (if has-len (min maxlen (%to-idx a2 maxlen 0 maxlen)) maxlen))
                  (enc (or (%norm-enc (cond (enc-in-a1 a1)
                                            ((and (not (undef-p a2)) (not has-len)) a2)
                                            (t a3)))
                           :utf8))
                  (src (%encode-string str enc))
                  (n (min wlen (length src))))
             (dotimes (i n) (setf (aref b (+ off start i)) (aref src i)))
             (coerce n 'double-float)))))
    (m "slice" 2 (lambda (this args) (%buf-slice this (a args 0) (a args 1))))
    (m "subarray" 2 (lambda (this args) (%buf-slice this (a args 0) (a args 1))))
    (m "copy" 4
       (lambda (this args)
         (multiple-value-bind (sb soff slen) (%buf-view this)
           (multiple-value-bind (tb toff tlen) (%buf-view (a args 0))
             (let* ((tstart (%to-idx (a args 1) 0 0 tlen))
                    (sstart (%to-idx (a args 2) 0 0 slen))
                    (send (%to-idx (a args 3) slen 0 slen))
                    (n (min (- send sstart) (- tlen tstart))))
               (when (plusp n)
                 (let ((tp (+ toff tstart)) (sp (+ soff sstart)))
                   ;; memmove: same backing + forward overlap -> copy backward, else forward.
                   (if (and (eq tb sb) (> tp sp))
                       (loop for i from (1- n) downto 0 do (setf (aref tb (+ tp i)) (aref sb (+ sp i))))
                       (dotimes (i n) (setf (aref tb (+ tp i)) (aref sb (+ sp i)))))))
               (coerce (max 0 n) 'double-float))))))
    (m "fill" 4
       (lambda (this args)
         (multiple-value-bind (b off len) (%buf-view this)
           (let ((start (%to-idx (a args 1) 0 0 len))
                 (end (%to-idx (a args 2) len 0 len)))
             (%fill-octets b off start end (a args 0) (a args 3))
             this))))
    (m "equals" 1
       (lambda (this args)
         (eng:js-boolean (zerop (%buf-compare this (a args 0))))))
    (m "compare" 1
       (lambda (this args) (coerce (%buf-compare this (a args 0)) 'double-float)))
    (m "indexOf" 3
       (lambda (this args)
         (coerce (%buf-index-of this (a args 0) (a args 1) (a args 2) nil) 'double-float)))
    (m "lastIndexOf" 3
       (lambda (this args)
         (coerce (%buf-index-of this (a args 0) (a args 1) (a args 2) t) 'double-float)))
    (m "includes" 3
       (lambda (this args)
         (eng:js-boolean (>= (%buf-index-of this (a args 0) (a args 1) (a args 2) nil) 0))))))

(defun %buf-slice (this astart aend)
  "slice/subarray -> a Buffer VIEW over the SAME backing memory (Node semantics: writes to
the view propagate to the parent), via eng:ta-subview with Buffer.prototype."
  (multiple-value-bind (b off len) (%buf-view this)
    (declare (ignore b off))
    (let* ((s (%to-idx astart 0 (- len) len))
           (e (%to-idx aend len (- len) len))
           (start (if (< s 0) (max 0 (+ len s)) s))
           (end (if (< e 0) (max 0 (+ len e)) e)))
      (eng:ta-subview this start (max start end) *buffer-proto*))))

(defun %buf-compare (this other)
  "Byte-lexicographic comparison: -1/0/1."
  (multiple-value-bind (ab aoff alen) (%buf-view this)
    (multiple-value-bind (bb boff blen) (%buf-view other)
      (let ((n (min alen blen)))
        (dotimes (i n)
          (let ((x (aref ab (+ aoff i))) (y (aref bb (+ boff i))))
            (cond ((< x y) (return-from %buf-compare -1))
                  ((> x y) (return-from %buf-compare 1)))))
        (cond ((< alen blen) -1) ((> alen blen) 1) (t 0))))))

;;; --- static byteLength ------------------------------------------------------

(defun %byte-length (value enc)
  (cond
    ((eng:js-string-p value) (length (%encode-string value (or (%norm-enc enc) :utf8))))
    ((eng:js-typed-array-p value) (multiple-value-bind (b off len) (eng:ta-octets value)
                                    (declare (ignore b off)) len))
    ((eng:js-array-buffer-p value)
     (let ((bl (eng:js-getv value "byteLength"))) (if (eng:js-number-p bl) (truncate bl) 0)))
    (t (length (%encode-string (->str value) :utf8)))))

;;; --- isBuffer: typed-array whose proto chain includes *buffer-proto* ---------

(defun %is-buffer (v)
  (and (eng:js-object-p v)
       (eq (eng:js-object-class v) :typed-array)
       (loop for p = (clun.engine::js-object-proto v) then (clun.engine::js-object-proto p)
             while (eng:js-object-p p)
             thereis (eq p *buffer-proto*))))

;;; --- build the module -------------------------------------------------------

(defun build-node-buffer ()
  (let* ((global (eng:realm-global eng:*realm*))
         (u8 (eng:js-get global "Uint8Array"))
         (u8proto (eng:js-get u8 "prototype"))
         (proto (eng:new-object u8proto))
         (exports (eng:new-object)))
    (setf *buffer-proto* proto)
    (%install-proto-methods proto)
    (%install-numeric proto)
    (labels ((ctor-body (args)
               (let ((a0 (a args 0)))
                 (cond
                   ((eng:js-number-p a0)
                    (let ((n (max 0 (let ((x (eng:to-integer-or-infinity a0)))
                                      (if (eng:js-infinite-p x) 0 (truncate x))))))
                      (eng:u8-from-octets (make-array n :element-type '(unsigned-byte 8)
                                                        :initial-element 0)
                                          *buffer-proto*)))
                   ((eng:js-string-p a0) (%buffer-from a0 (a args 1) (undef)))
                   (t (%buffer-from a0 (a args 1) (a args 2))))))
             (alloc (args)
               (let* ((n (max 0 (let ((x (eng:to-integer-or-infinity (a args 0))))
                                  (if (eng:js-infinite-p x) 0 (truncate x)))))
                      (buf (eng:u8-from-octets (make-array n :element-type '(unsigned-byte 8)
                                                             :initial-element 0)
                                               *buffer-proto*)))
                 (unless (undef-p (a args 1))
                   (multiple-value-bind (b off len) (%buf-view buf)
                     (%fill-octets b off 0 len (a args 1) (a args 2))))
                 buf)))
      (let ((ctor (eng:make-native-function
                   "Buffer" 3
                   (lambda (this args) (declare (ignore this)) (ctor-body args))
                   :construct (lambda (args new-target) (declare (ignore new-target))
                                (ctor-body args)))))
        (eng:data-prop ctor "prototype" proto)
        (eng:data-prop proto "constructor" ctor)
        (eng:data-prop ctor "poolSize" (coerce 8192 'double-float))
        ;; statics
        (eng:install-method ctor "alloc" 3 (lambda (this args) (declare (ignore this)) (alloc args)))
        (eng:install-method ctor "allocUnsafe" 1 (lambda (this args) (declare (ignore this)) (alloc args)))
        (eng:install-method ctor "allocUnsafeSlow" 1 (lambda (this args) (declare (ignore this)) (alloc args)))
        (eng:install-method ctor "from" 3
          (lambda (this args) (declare (ignore this))
            (%buffer-from (a args 0) (a args 1) (a args 2))))
        (eng:install-method ctor "isBuffer" 1
          (lambda (this args) (declare (ignore this)) (eng:js-boolean (%is-buffer (a args 0)))))
        (eng:install-method ctor "isEncoding" 1
          (lambda (this args) (declare (ignore this))
            (eng:js-boolean (and (eng:js-string-p (a args 0)) (%norm-enc (a args 0)) t))))
        (eng:install-method ctor "byteLength" 2
          (lambda (this args) (declare (ignore this))
            (coerce (%byte-length (a args 0) (a args 1)) 'double-float)))
        (eng:install-method ctor "compare" 2
          (lambda (this args) (declare (ignore this))
            (coerce (%buf-compare (a args 0) (a args 1)) 'double-float)))
        (eng:install-method ctor "concat" 2
          (lambda (this args) (declare (ignore this)) (%buf-concat (a args 0) (a args 1))))
        (eng:data-prop exports "Buffer" ctor)
        ;; constants module member (minimal)
        (let ((consts (eng:new-object)))
          (eng:data-prop consts "MAX_LENGTH" (coerce (ash 1 31) 'double-float))
          (eng:data-prop consts "MAX_STRING_LENGTH" (coerce (ash 1 29) 'double-float))
          (eng:data-prop exports "constants" consts))
        (eng:data-prop exports "kMaxLength" (coerce (ash 1 31) 'double-float))
        exports))))

(defun %buf-concat (list total)
  "Buffer.concat(list[, totalLength]) -> a new Buffer of the joined bytes."
  (let* ((items (eng:array-like->list list))
         (parts (mapcar (lambda (it)
                          (multiple-value-bind (b off len) (%buf-view it)
                            (subseq b off (+ off len))))
                        items))
         (sum (reduce #'+ parts :key #'length :initial-value 0))
         ;; totalLength larger than the sum -> the tail stays zero-filled (Node fills it);
         ;; smaller -> truncate. The copy loop caps each take at (- n pos).
         (n (if (undef-p total) sum
                (max 0 (let ((x (eng:to-integer-or-infinity total)))
                         (if (eng:js-infinite-p x) 0 (truncate x))))))
         (out (make-array n :element-type '(unsigned-byte 8) :initial-element 0))
         (pos 0))
    (dolist (p parts)
      (let ((take (min (length p) (- n pos))))
        (when (plusp take) (replace out p :start1 pos :end2 take) (incf pos take))))
    (%buffer-from-octets out)))

(register-node-builtin "buffer" #'build-node-buffer)
