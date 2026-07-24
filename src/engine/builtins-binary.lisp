;;;; builtins-binary.lisp — ArrayBuffer, TypedArrays (11 kinds), DataView, and
;;;; TextEncoder/TextDecoder (PLAN.md Phase 11, §25). TypedArrays are integer-indexed
;;;; exotic objects over a shared ArrayBuffer byte vector; detach = the buffer's bytes
;;;; slot going NIL (all aliasing views observe it at once). Bytes are pure CL
;;;; (ldb/dpb + sb-kernel float-bit primitives — zero C shims).

(in-package :clun.engine)

;;; --- structs (reuse the :include js-object exotic idiom) --------------------

(defstruct (js-array-buffer (:include js-object (class :array-buffer))
                            (:constructor %make-js-array-buffer))
  (bytes nil))                          ; (simple-array (unsigned-byte 8) (*)) | NIL when detached

(defstruct (js-typed-array (:include js-object (class :typed-array))
                           (:constructor %make-js-typed-array))
  (abuffer nil) (kind :uint8) (byte-offset 0) (array-length 0))

(defstruct (js-data-view (:include js-object (class :data-view))
                         (:constructor %make-js-data-view))
  (abuffer nil) (byte-offset 0) (byte-length 0))

;;; --- element-kind table (single source of truth) ---------------------------

(defparameter *typed-array-kinds*
  ;; kind → (js-name element-size content signed) ; content = :number | :bigint
  '((:int8           "Int8Array"          1 :number t)
    (:uint8          "Uint8Array"         1 :number nil)
    (:uint8-clamped  "Uint8ClampedArray"  1 :number nil)
    (:int16          "Int16Array"         2 :number t)
    (:uint16         "Uint16Array"        2 :number nil)
    (:int32          "Int32Array"         4 :number t)
    (:uint32         "Uint32Array"        4 :number nil)
    (:float32        "Float32Array"       4 :number nil)
    (:float64        "Float64Array"       8 :number nil)
    (:bigint64       "BigInt64Array"      8 :bigint t)
    (:biguint64      "BigUint64Array"     8 :bigint nil)))

(defun kind-info (k) (cdr (assoc k *typed-array-kinds*)))
(defun kind-name (k) (first (kind-info k)))
(defun kind-size (k) (second (kind-info k)))
(defun kind-content (k) (third (kind-info k)))
(defun kind-signed (k) (fourth (kind-info k)))
(defun kind-bigint-p (k) (eq (kind-content k) :bigint))

;;; --- byte assembly (little-endian flag; pure SBCL) -------------------------

(defun bytes-get-uint (bytes offset size le)
  (if le (loop for i below size sum (ash (aref bytes (+ offset i)) (* 8 i)))
         (loop for i below size sum (ash (aref bytes (+ offset i)) (* 8 (- size 1 i))))))
(defun bytes-put-uint (bytes offset size le u)
  (dotimes (i size)
    (setf (aref bytes (+ offset (if le i (- size 1 i)))) (ldb (byte 8 (* 8 i)) u))))

(defun %sfold (u bits) (if (>= u (ash 1 (1- bits))) (- u (ash 1 bits)) u))
(defun %num->wrapint (d) (if (or (js-nan-p d) (js-infinite-p d)) 0 (truncate d)))
(defun %clamp-uint8 (d)
  (cond ((js-nan-p d) 0) ((<= d 0d0) 0) ((>= d 255d0) 255) (t (round d))))  ; round-half-even

(defun read-element (bytes offset kind le)
  "Return the JS value (double for :number kinds, CL integer for :bigint) at OFFSET.
Float reads are trap-masked: coercing a signaling-NaN bit pattern would otherwise raise a
host FLOATING-POINT-INVALID-OPERATION (JS has no observable quiet/signaling NaN)."
  (let ((size (kind-size kind)) (u (bytes-get-uint bytes offset (kind-size kind) le)))
    (if (kind-bigint-p kind)
        (if (kind-signed kind) (%sfold u (* 8 size)) u)
        (case kind
          (:float32 (with-js-floats (coerce (sb-kernel:make-single-float (%sfold u 32)) 'double-float)))
          (:float64 (with-js-floats
                      (sb-kernel:make-double-float (%sfold (ldb (byte 32 32) u) 32) (ldb (byte 32 0) u))))
          (t (coerce (if (kind-signed kind) (%sfold u (* 8 size)) u) 'double-float))))))

(defun write-element (bytes offset kind value le)
  "Store already-coerced VALUE (double for :number kinds, integer for :bigint)."
  (let* ((size (kind-size kind))
         (u (if (kind-bigint-p kind)
                (ldb (byte (* 8 size) 0) value)
                (case kind
                  (:float32 (ldb (byte 32 0) (sb-kernel:single-float-bits
                                              (%double->single value))))
                  (:float64 (logior (ash (ldb (byte 32 0) (sb-kernel:double-float-high-bits value)) 32)
                                    (sb-kernel:double-float-low-bits value)))
                  (:uint8-clamped (%clamp-uint8 value))
                  (t (ldb (byte (* 8 size) 0) (%num->wrapint value)))))))
    (bytes-put-uint bytes offset size le u)))

(defun %double->single (d)
  (with-js-floats (coerce d 'single-float)))     ; over/underflow → single ±Inf/0 (fine)

;;; --- ArrayBuffer ------------------------------------------------------------

(defconstant +max-byte-length+ (expt 2 31)
  "Cap on a Data Block size (§6.2.9): a larger request throws RangeError rather than
exhausting the heap (test262 ArrayBuffer/allocation-limit allocates PiB-scale).")

(defun crypto-fill-random (ta)
  "crypto.getRandomValues(TA): fill TA's bytes with CSPRNG bytes. Non-integer TA (Float*)
→ TypeError; byteLength > 65536 → RangeError (the WebCrypto quota)."
  (unless (js-typed-array-p ta) (throw-type-error "argument is not an integer TypedArray"))
  (when (member (js-typed-array-kind ta) '(:float32 :float64))
    (throw-type-error "argument is not an integer TypedArray"))
  (when (ta-detached-p ta) (throw-type-error "TypedArray is detached"))
  (let ((n (* (ta-length ta) (kind-size (js-typed-array-kind ta)))))
    (when (> n 65536) (throw-range-error "getRandomValues quota (65536 bytes) exceeded"))
    (let ((rnd (clun.sys:os-random-bytes n)) (bytes (ta-bytes ta)) (off (js-typed-array-byte-offset ta)))
      (dotimes (i n) (setf (aref bytes (+ off i)) (aref rnd i)))))
  ta)

(defun make-array-buffer (length &optional proto)
  ;; Reject before allocating: SBCL's heap-exhaustion on a single too-large make-array is a raw
  ;; abort (NOT a catchable storage-condition), so cap against the real runtime heap (half of it)
  ;; — a bigger request is a clean catchable RangeError, never a Lisp backtrace (§6).
  (when (or (> length +max-byte-length+) (> length (floor (sb-ext:dynamic-space-size) 2)))
    (throw-range-error "ArrayBuffer allocation failed: requested length exceeds the maximum"))
  (let ((b (%make-js-array-buffer :proto (or proto (intrinsic :array-buffer-prototype))
                                  :class :array-buffer)))
    (setf (js-array-buffer-bytes b)
          (handler-case (make-array length :element-type '(unsigned-byte 8) :initial-element 0)
            (storage-condition () (throw-range-error "ArrayBuffer allocation failed"))))
    b))
(defun array-buffer-detached-p (b) (null (js-array-buffer-bytes b)))
(defun detach-array-buffer (b) (setf (js-array-buffer-bytes b) nil))

;;; --- TypedArray element access + validity ----------------------------------

(defun ta-detached-p (ta) (array-buffer-detached-p (js-typed-array-abuffer ta)))
(defun ta-bytes (ta) (js-array-buffer-bytes (js-typed-array-abuffer ta)))
(defun ta-length (ta) (if (ta-detached-p ta) 0 (js-typed-array-array-length ta)))
(defun ta-elt-offset (ta i) (+ (js-typed-array-byte-offset ta) (* i (kind-size (js-typed-array-kind ta)))))

(defun ta-get (ta i)                    ; i a CL integer already known in range
  (read-element (ta-bytes ta) (ta-elt-offset ta i) (js-typed-array-kind ta) t))
(defun ta-set-raw (ta i value)          ; value already coerced to the element domain
  (write-element (ta-bytes ta) (ta-elt-offset ta i) (js-typed-array-kind ta) value t))
(defun ta-coerce (ta value)
  (if (kind-bigint-p (js-typed-array-kind ta)) (to-bigint value) (to-number value)))

(defun canonical-numeric-index (key)
  "§7.1.21: if KEY is a CanonicalNumericIndexString return its double (2nd val T)."
  (when (and (stringp key) (plusp (length key)))
    (if (string= key "-0")
        (values -0d0 t)
        (let ((n (with-js-floats (js-string->number key))))
          (if (string= (number->js-string n) key) (values n t) (values nil nil))))))

(defun valid-integer-index-p (ta n)
  "N is a double from canonical-numeric-index; T iff a live in-range non-neg integer index."
  (and (not (ta-detached-p ta)) (not (js-nan-p n)) (js-finite-p n)
       (not (js-neg-zero-p n)) (= n (ftruncate n))
       (<= 0 n) (< n (js-typed-array-array-length ta))))

;;; --- TypedArray exotic internal methods (§10.4.5) --------------------------

(defmethod jm-get-own-property ((ta js-typed-array) key)
  (multiple-value-bind (n canon) (canonical-numeric-index key)
    (if canon
        (when (valid-integer-index-p ta n)
          (data-pd (ta-get ta (truncate n)) :writable t :enumerable t :configurable t))
        (call-next-method))))

(defmethod jm-has-property ((ta js-typed-array) key)
  (multiple-value-bind (n canon) (canonical-numeric-index key)
    (if canon (and (valid-integer-index-p ta n) t) (call-next-method))))

(defmethod jm-get ((ta js-typed-array) key receiver)
  (multiple-value-bind (n canon) (canonical-numeric-index key)
    (if canon
        (if (valid-integer-index-p ta n) (ta-get ta (truncate n)) +undefined+)
        (call-next-method))))

(defmethod jm-set ((ta js-typed-array) key value receiver)
  (multiple-value-bind (n canon) (canonical-numeric-index key)
    (if canon
        (progn                          ; §10.4.5.15: coerce first (may throw), then store iff valid
          (let ((v (ta-coerce ta value)))
            (when (valid-integer-index-p ta n) (ta-set-raw ta (truncate n) v)))
          t)
        (call-next-method))))

(defmethod jm-define-own-property ((ta js-typed-array) key desc)
  (multiple-value-bind (n canon) (canonical-numeric-index key)
    (if canon
        (cond
          ((not (valid-integer-index-p ta n)) nil)
          ((accessor-descriptor-p desc) nil)
          ((eq (pd-configurable desc) nil) nil)
          ((eq (pd-enumerable desc) nil) nil)
          ((eq (pd-writable desc) nil) nil)
          (t (when (pd-set-p (pd-value desc))
               (ta-set-raw ta (truncate n) (ta-coerce ta (pd-value desc))))
             t))
        (call-next-method))))

(defmethod jm-own-property-keys ((ta js-typed-array))
  ;; §10.4.5.6: integer indices FIRST (ascending), then ordinary string keys, then symbols.
  (let ((indices (loop for i below (ta-length ta) collect (princ-to-string i)))
        (rest (remove-if (lambda (k) (and (stringp k) (canonical-numeric-index k)))
                         (ordinary-own-property-keys ta))))
    (append indices rest)))

;;; --- TypedArray construction -----------------------------------------------

(defun %alloc-typed-array (kind length &optional proto)
  (let* ((buf (make-array-buffer (* length (kind-size kind))))
         (ta (%make-js-typed-array :proto (or proto (intrinsic (ta-proto-key kind)))
                                   :class :typed-array
                                   :abuffer buf :kind kind :byte-offset 0 :array-length length)))
    ta))

(defun ta-proto-key (kind) (intern (format nil "~a-PROTOTYPE" (symbol-name kind)) :keyword))

(defun %typed-array-from-buffer (kind buf args proto)
  (let* ((size (kind-size kind))
         (offset (to-index (arg args 1)))
         (bytes (if (fboundp 'data-buffer-bytes)
                    (data-buffer-bytes buf)
                    (js-array-buffer-bytes buf)))
         (buflen (length bytes)))
    (when (plusp (mod offset size)) (throw-range-error "start offset must be aligned"))
    (let* ((len-arg (arg args 2))
           (length (if (js-undefined-p len-arg)
                       (progn (when (plusp (mod buflen size))
                                (throw-range-error "byte length must be aligned"))
                              (when (> offset buflen) (throw-range-error "start offset out of bounds"))
                              (floor (- buflen offset) size))
                       (to-index len-arg))))
      (when (> (+ offset (* length size)) buflen) (throw-range-error "invalid typed array length"))
      (%make-js-typed-array :proto proto :class :typed-array
                            :abuffer buf :kind kind :byte-offset offset :array-length length))))

(defun %typed-array-from-list (kind elements proto)
  (let* ((length (length elements))
         (ta (%alloc-typed-array kind length proto)) (i 0))
    (dolist (e elements) (ta-set-raw ta i (ta-coerce ta e)) (incf i))
    ta))

(defun typed-array-construct (kind args nt)
  (let* ((proto (nt-prototype nt (intrinsic (ta-proto-key kind))))
         (a0 (arg args 0)))
    (cond
      ((or (js-array-buffer-p a0)
           (and (fboundp 'js-shared-array-buffer-p) (js-shared-array-buffer-p a0)))
       (%typed-array-from-buffer kind a0 args proto))
      ((js-typed-array-p a0)
       (when (not (eq (kind-bigint-p kind) (kind-bigint-p (js-typed-array-kind a0))))
         (throw-type-error "cannot mix BigInt and non-BigInt typed arrays"))
       (let* ((len (ta-length a0)) (ta (%alloc-typed-array kind len proto)))
         (dotimes (i len) (ta-set-raw ta i (ta-coerce ta (ta-get a0 i)))) ta))
      ((js-object-p a0)
       (let ((iter (and (not (js-nullish-p a0)) (get-method a0 (well-known :iterator)))))
         (if (callable-p iter)
             (%typed-array-from-list kind (iterable->list a0) proto)
             ;; array-like: enforce the allocation cap BEFORE materializing `length` elements
             ;; (else a huge {length} exhausts the heap in array-like->list).
             (let ((len (length-of-array-like a0)))
               (when (> (* len (kind-size kind)) +max-byte-length+)
                 (throw-range-error "Invalid typed array length"))
               (%typed-array-from-list kind (array-like->list a0) proto)))))
      (t (%alloc-typed-array kind (if (js-undefined-p a0) 0 (to-index a0)) proto)))))

;;; --- prototype method helpers ----------------------------------------------

(defun this-typed-array (this)
  (if (js-typed-array-p this) this (throw-type-error "not a TypedArray")))
(defun %ta-require-live (ta) (when (ta-detached-p ta) (throw-type-error "TypedArray is detached")) ta)

(defun ta-clamp-index (v len default)
  (let ((n (%int v)))
    (cond ((minusp n) (max (+ len n) 0)) (t (min n len)))))

(defun new-typed-array-same (ta length)
  "§SpeciesCreate — we return the SAME kind (the @@species subclass hook is a gap)."
  (%alloc-typed-array (js-typed-array-kind ta) length))

;;; --- bootstrap --------------------------------------------------------------

(defun %bootstrap-binary ()
  (%bootstrap-array-buffer)
  (%bootstrap-typed-arrays)
  (%bootstrap-data-view)
  (%bootstrap-text-codec)
  (when (fboundp '%bootstrap-shared-memory)
    (%bootstrap-shared-memory)))

(defun %bootstrap-array-buffer ()
  (let ((abp (js-make-object (intrinsic :object-prototype) :object)))
    (setf (realm-intrinsic *realm* :array-buffer-prototype) abp)
    (install-getter abp "byteLength"
      (lambda (this args) (declare (ignore args))
        (if (js-array-buffer-p this)
            (coerce (if (array-buffer-detached-p this) 0 (length (js-array-buffer-bytes this))) 'double-float)
            (throw-type-error "not an ArrayBuffer"))))
    (install-method abp "slice" 2
      (lambda (this args)
        (unless (js-array-buffer-p this) (throw-type-error "not an ArrayBuffer"))
        (when (array-buffer-detached-p this) (throw-type-error "ArrayBuffer is detached"))
        (let* ((bytes (js-array-buffer-bytes this)) (len (length bytes))
               (start (ta-clamp-index (arg args 0) len 0))
               (end (if (js-undefined-p (arg args 1)) len (ta-clamp-index (arg args 1) len len)))
               (new-len (max 0 (- end start)))
               (nb (make-array-buffer new-len)))
          (dotimes (i new-len) (setf (aref (js-array-buffer-bytes nb) i) (aref bytes (+ start i))))
          nb)))
    (install-method abp "transfer" 1
      (lambda (this args) (%array-buffer-transfer this (arg args 0))))
    (install-method abp "transferToFixedLength" 1
      (lambda (this args) (%array-buffer-transfer this (arg args 0))))
    (obj-set-desc abp (well-known :to-string-tag)
                  (data-pd "ArrayBuffer" :writable nil :enumerable nil :configurable t))
    (let ((ctor (make-constructor "ArrayBuffer" 1
                  (lambda (this args) (declare (ignore this args))
                    (throw-type-error "Constructor ArrayBuffer requires 'new'"))
                  :prototype abp
                  :construct-fn (lambda (args nt)
                                  (make-array-buffer (to-index (arg args 0))
                                                     (nt-prototype nt (intrinsic :array-buffer-prototype)))))))
      (install-method ctor "isView" 1
        (lambda (this args) (declare (ignore this))
          (js-boolean (let ((v (arg args 0))) (or (js-typed-array-p v) (js-data-view-p v))))))
      (setf (realm-intrinsic *realm* :array-buffer-constructor) ctor))
    abp))

(defun %array-buffer-transfer (this new-len-arg)
  (unless (js-array-buffer-p this) (throw-type-error "not an ArrayBuffer"))
  (when (array-buffer-detached-p this) (throw-type-error "ArrayBuffer is detached"))
  (let* ((old (js-array-buffer-bytes this)) (oldlen (length old))
         (new-len (if (js-undefined-p new-len-arg) oldlen (to-index new-len-arg)))
         (nb (make-array-buffer new-len)))
    (dotimes (i (min oldlen new-len)) (setf (aref (js-array-buffer-bytes nb) i) (aref old i)))
    (detach-array-buffer this)
    nb))

(defun %bootstrap-typed-arrays ()
  (let ((tap (%bootstrap-typed-array-prototype)))
    ;; the abstract %TypedArray% constructor
    (let ((super (make-constructor "TypedArray" 0
                   (lambda (this args) (declare (ignore this args))
                     (throw-type-error "Abstract class TypedArray not directly constructable"))
                   :prototype tap)))
      ;; of/from use `this` (the concrete ctor) as the constructor — SpeciesCreate via
      ;; js-construct, then element-set through the exotic (coerces per kind).
      (install-method super "of" 0
        (lambda (this args)
          (let ((obj (js-construct this (list (coerce (length args) 'double-float)) this)) (i 0))
            (dolist (v args obj) (js-set obj (princ-to-string i) v t) (incf i)))))
      (install-method super "from" 1
        (lambda (this args)
          (let* ((src (arg args 0)) (mapfn (arg args 1))
                 (items (let ((iter (and (js-object-p src) (get-method src (well-known :iterator)))))
                          (if (callable-p iter) (iterable->list src) (array-like->list src))))
                 (obj (js-construct this (list (coerce (length items) 'double-float)) this)) (i 0))
            (dolist (v items obj)
              (js-set obj (princ-to-string i)
                      (if (callable-p mapfn) (js-call mapfn (arg args 2) (list v (coerce i 'double-float))) v) t)
              (incf i)))))
      (setf (realm-intrinsic *realm* :typed-array-constructor) super)
      ;; the 11 concrete constructors, chained by prototype to %TypedArray%
      (dolist (entry *typed-array-kinds*)
        (let* ((kind (car entry)) (name (kind-name kind)) (size (kind-size kind))
               (proto (js-make-object tap :object)))
          (setf (realm-intrinsic *realm* (ta-proto-key kind)) proto)
          (obj-set-desc proto "BYTES_PER_ELEMENT"
                        (data-pd (coerce size 'double-float) :writable nil :enumerable nil :configurable nil))
          (let ((ctor (make-native-function name 3
                        (lambda (this args) (declare (ignore this args))
                          (throw-type-error (format nil "Constructor ~a requires 'new'" name)))
                        :construct (let ((k kind)) (lambda (args nt) (typed-array-construct k args nt))))))
            (setf (js-object-proto ctor) super)      ; ctor's [[Prototype]] = %TypedArray%
            (obj-set-desc ctor "prototype" (data-pd proto :writable nil :enumerable nil :configurable nil))
            (obj-set-desc proto "constructor" (data-pd ctor :writable t :enumerable nil :configurable t))
            (obj-set-desc ctor "BYTES_PER_ELEMENT"
                          (data-pd (coerce size 'double-float) :writable nil :enumerable nil :configurable nil))
            (setf (realm-intrinsic *realm* (intern (format nil "~a-CONSTRUCTOR" (symbol-name kind)) :keyword))
                  ctor)))))
    tap))

(defun %bootstrap-typed-array-prototype ()
  (let ((tap (js-make-object (intrinsic :object-prototype) :object)))
    (setf (realm-intrinsic *realm* :typed-array-prototype) tap)
    (macrolet ((m (name arity &body body) `(install-method tap ,name ,arity (lambda (this args) ,@body))))
      (install-getter tap "length"
        (lambda (this args) (declare (ignore args)) (coerce (ta-length (this-typed-array this)) 'double-float)))
      (install-getter tap "byteLength"
        (lambda (this args) (declare (ignore args))
          (let ((ta (this-typed-array this)))
            (coerce (* (ta-length ta) (kind-size (js-typed-array-kind ta))) 'double-float))))
      (install-getter tap "byteOffset"
        (lambda (this args) (declare (ignore args))
          (let ((ta (this-typed-array this)))
            (coerce (if (ta-detached-p ta) 0 (js-typed-array-byte-offset ta)) 'double-float))))
      (install-getter tap "buffer"
        (lambda (this args) (declare (ignore args)) (js-typed-array-abuffer (this-typed-array this))))
      (obj-set-desc tap (well-known :to-string-tag)
                    (accessor-pd (make-native-function "get [Symbol.toStringTag]" 0
                                   (lambda (this args) (declare (ignore args))
                                     (if (js-typed-array-p this) (kind-name (js-typed-array-kind this)) +undefined+)))
                                 +undefined+ :enumerable nil :configurable t))
      (m "at" 1 (let* ((ta (this-typed-array this)) (len (ta-length ta)) (i (%int (arg args 0))))
                  (when (minusp i) (setf i (+ len i)))
                  (if (and (<= 0 i) (< i len)) (ta-get ta i) +undefined+)))
      (m "fill" 3 (let* ((ta (%ta-require-live (this-typed-array this))) (len (ta-length ta))
                         (v (ta-coerce ta (arg args 0)))       ; may run user code that detaches
                         (start (ta-clamp-index (arg args 1) len 0))
                         (end (if (js-undefined-p (arg args 2)) len (ta-clamp-index (arg args 2) len len))))
                    ;; re-check after coercion: a detach must no-op, not crash on a NIL buffer.
                    (unless (ta-detached-p ta)
                      (loop for i from start below (min end (ta-length ta)) do (ta-set-raw ta i v)))
                    ta))
      (m "set" 2 (%typed-array-set (this-typed-array this) (arg args 0) (arg args 1)))
      (m "subarray" 2
         (let* ((ta (this-typed-array this)) (len (ta-length ta))
                (start (ta-clamp-index (arg args 0) len 0))
                (end (if (js-undefined-p (arg args 1)) len (ta-clamp-index (arg args 1) len len)))
                (kind (js-typed-array-kind ta)))
           (%make-js-typed-array :proto (intrinsic (ta-proto-key kind)) :class :typed-array
                                 :abuffer (js-typed-array-abuffer ta) :kind kind
                                 :byte-offset (+ (js-typed-array-byte-offset ta) (* start (kind-size kind)))
                                 :array-length (max 0 (- end start)))))
      (m "slice" 2
         (let* ((ta (this-typed-array this)) (len (ta-length ta))
                (start (ta-clamp-index (arg args 0) len 0))
                (end (if (js-undefined-p (arg args 1)) len (ta-clamp-index (arg args 1) len len)))
                (n (max 0 (- end start))) (out (new-typed-array-same ta n)))
           (dotimes (i n) (ta-set-raw out i (ta-coerce out (ta-get ta (+ start i))))) out))
      (m "copyWithin" 3 (%typed-array-copy-within (this-typed-array this) args))
      (m "reverse" 0 (let* ((ta (this-typed-array this)) (len (ta-length ta)))
                       (dotimes (i (floor len 2))
                         (let ((a (ta-get ta i)) (b (ta-get ta (- len 1 i))))
                           (ta-set-raw ta i (ta-coerce ta b)) (ta-set-raw ta (- len 1 i) (ta-coerce ta a))))
                       ta))
      (m "join" 1 (let* ((ta (this-typed-array this)) (len (ta-length ta))
                         (sep (if (js-undefined-p (arg args 0)) "," (to-string (arg args 0)))))
                    (with-output-to-string (o)
                      (dotimes (i len) (when (plusp i) (write-string sep o))
                        (write-string (to-string (ta-get ta i)) o)))))
      (m "indexOf" 2 (%typed-array-index-of (this-typed-array this) args nil))
      (m "lastIndexOf" 2 (%typed-array-index-of (this-typed-array this) args :last))
      (m "includes" 2 (%typed-array-index-of (this-typed-array this) args :includes))
      (m "keys" 0 (make-array-iterator (this-typed-array this) :key))
      (m "entries" 0 (make-array-iterator (this-typed-array this) :entry))
      (m "forEach" 1 (%typed-array-iterate (this-typed-array this) args :for-each))
      (m "map" 1 (%typed-array-iterate (this-typed-array this) args :map))
      (m "filter" 1 (%typed-array-iterate (this-typed-array this) args :filter))
      (m "some" 1 (%typed-array-iterate (this-typed-array this) args :some))
      (m "every" 1 (%typed-array-iterate (this-typed-array this) args :every))
      (m "find" 1 (%typed-array-iterate (this-typed-array this) args :find))
      (m "findIndex" 1 (%typed-array-iterate (this-typed-array this) args :find-index))
      (m "reduce" 2 (%typed-array-reduce (this-typed-array this) args nil))
      (m "reduceRight" 2 (%typed-array-reduce (this-typed-array this) args :right))
      (m "sort" 1 (%typed-array-sort (this-typed-array this) (arg args 0)))
      (m "toString" 0 (let* ((ta (this-typed-array this)) (len (ta-length ta)))
                        (with-output-to-string (o)
                          (dotimes (i len) (when (plusp i) (write-char #\, o))
                            (write-string (to-string (ta-get ta i)) o)))))
      (let ((values-fn (make-native-function "values" 0
                         (lambda (this args) (declare (ignore args))
                           (make-array-iterator (this-typed-array this) :value)))))
        (obj-set-desc tap "values" (data-pd values-fn :writable t :enumerable nil :configurable t))
        (obj-set-desc tap (well-known :iterator) (data-pd values-fn :writable t :enumerable nil :configurable t))))
    tap))

(defun %typed-array-set (ta src offset-arg)
  (%ta-require-live ta)
  (let ((offset (%int offset-arg)) (len (ta-length ta)))
    (when (minusp offset) (throw-range-error "offset is negative"))
    (cond
      ((js-typed-array-p src)
       (let ((slen (ta-length src)))
         (when (> (+ offset slen) len) (throw-range-error "source is too large"))
         ;; snapshot the source first — src may alias ta's buffer (overlapping copy).
         (let ((tmp (make-array slen)))
           (dotimes (i slen) (setf (aref tmp i) (ta-get src i)))
           (dotimes (i slen) (ta-set-raw ta (+ offset i) (ta-coerce ta (aref tmp i)))))))
      (t (let* ((o (to-object src)) (slen (length-of-array-like o)))
           (when (> (+ offset slen) len) (throw-range-error "source is too large"))
           (dotimes (i slen)
             (let ((v (ta-coerce ta (js-getv o (princ-to-string i)))))  ; coerce (may detach)
               (unless (ta-detached-p ta) (ta-set-raw ta (+ offset i) v))))))))
  +undefined+)

(defun %typed-array-copy-within (ta args)
  (let* ((len (ta-length ta))
         (target (ta-clamp-index (arg args 0) len 0))
         (start (ta-clamp-index (arg args 1) len 0))
         (end (if (js-undefined-p (arg args 2)) len (ta-clamp-index (arg args 2) len len)))
         (count (min (- end start) (- len target))))
    (when (plusp count)
      (let ((tmp (make-array count)))
        (dotimes (i count) (setf (aref tmp i) (ta-get ta (+ start i))))
        (dotimes (i count) (ta-set-raw ta (+ target i) (ta-coerce ta (aref tmp i))))))
    ta))

(defun %typed-array-index-of (ta args mode)
  (let* ((len (ta-length ta)) (target (arg args 0)))
    (if (eq mode :includes)
        (loop for i below len when (%same-value-zero-ta (ta-get ta i) target) do (return-from %typed-array-index-of +true+))
        (let ((from (if (js-undefined-p (arg args 1)) (if (eq mode :last) (1- len) 0) (%int (arg args 1)))))
          (when (minusp from) (incf from len))
          (if (eq mode :last)
              (loop for i from (min from (1- len)) downto 0
                    when (js-strict-eq (ta-get ta i) target) do (return-from %typed-array-index-of (coerce i 'double-float)))
              (loop for i from (max from 0) below len
                    when (js-strict-eq (ta-get ta i) target) do (return-from %typed-array-index-of (coerce i 'double-float))))))
    (if (eq mode :includes) +false+ -1d0)))

(defun %same-value-zero-ta (a b)
  (or (js-strict-eq a b)
      (and (js-number-p a) (js-number-p b) (js-nan-p a) (js-nan-p b))))

(defun %typed-array-iterate (ta args mode)
  (let ((fn (arg args 0)) (this-arg (arg args 1)) (len (ta-length ta)))
    (unless (callable-p fn) (throw-type-error "callback is not a function"))
    (let ((mapped '()) (kept '()))         ; each callback runs exactly once, in order
      (dotimes (i len)
        (let* ((v (ta-get ta i))
               (r (js-call fn this-arg (list v (coerce i 'double-float) ta))))
          (case mode
            (:for-each)
            (:map (push r mapped))
            (:filter (when (js-truthy r) (push v kept)))
            (:some (when (js-truthy r) (return-from %typed-array-iterate +true+)))
            (:every (unless (js-truthy r) (return-from %typed-array-iterate +false+)))
            (:find (when (js-truthy r) (return-from %typed-array-iterate v)))
            (:find-index (when (js-truthy r) (return-from %typed-array-iterate (coerce i 'double-float)))))))
      (case mode
        (:for-each +undefined+)
        (:map (let* ((vals (nreverse mapped)) (res (new-typed-array-same ta len)) (i 0))
                (dolist (v vals res) (ta-set-raw res i (ta-coerce res v)) (incf i))))
        (:filter (let* ((vals (nreverse kept)) (res (new-typed-array-same ta (length vals))) (i 0))
                   (dolist (v vals res) (ta-set-raw res i (ta-coerce res v)) (incf i))))
        (:some +false+) (:every +true+) (:find +undefined+) (:find-index -1d0)))))

(defun %typed-array-reduce (ta args right)
  (let ((fn (arg args 0)) (len (ta-length ta)))
    (unless (callable-p fn) (throw-type-error "callback is not a function"))
    (let ((acc (arg args 1)) (have (>= (length args) 2)))
      (flet ((visit (i)
               (if have
                   (setf acc (js-call fn +undefined+
                                      (list acc (ta-get ta i) (coerce i 'double-float) ta)))
                   (setf acc (ta-get ta i) have t))))
        (if right
            (loop for i = (1- len) then (1- i)
                  while (>= i 0) do (visit i))
            (loop for i below len do (visit i))))
      (unless have (throw-type-error "reduce of empty array with no initial value"))
      acc)))

(defun %ta-default-less (a b)
  "CompareTypedArrayElements default order: NaN sorts AFTER every value; both-NaN equal."
  (let ((anan (and (floatp a) (js-nan-p a))) (bnan (and (floatp b) (js-nan-p b))))
    (cond (anan nil)              ; NaN is never before anything
          (bnan t)                ; a (non-NaN) before NaN
          (t (eq (%numeric-lt a b) t)))))

(defun %typed-array-sort (ta cmp)
  (let* ((len (ta-length ta)) (vec (make-array len)))
    (dotimes (i len) (setf (aref vec i) (ta-get ta i)))
    ;; stable-sort (ES2019 requires a stable sort); comparator returning NaN → equal (+0).
    (stable-sort vec (if (callable-p cmp)
                         (lambda (a b) (let ((r (to-number (js-call cmp +undefined+ (list a b)))))
                                         (and (not (js-nan-p r)) (minusp r))))
                         #'%ta-default-less))
    (dotimes (i len) (ta-set-raw ta i (ta-coerce ta (aref vec i))))
    ta))

;;; --- DataView ---------------------------------------------------------------

(defun %bootstrap-data-view ()
  (let ((dvp (js-make-object (intrinsic :object-prototype) :object)))
    (setf (realm-intrinsic *realm* :data-view-prototype) dvp)
    (install-getter dvp "buffer"
      (lambda (this args) (declare (ignore args)) (js-data-view-abuffer (%this-dv this))))
    (install-getter dvp "byteLength"
      (lambda (this args) (declare (ignore args))
        (let ((dv (%this-dv this))) (%dv-require-live dv) (coerce (js-data-view-byte-length dv) 'double-float))))
    (install-getter dvp "byteOffset"
      (lambda (this args) (declare (ignore args))
        (let ((dv (%this-dv this))) (%dv-require-live dv) (coerce (js-data-view-byte-offset dv) 'double-float))))
    (obj-set-desc dvp (well-known :to-string-tag)
                  (data-pd "DataView" :writable nil :enumerable nil :configurable t))
    (dolist (kind '(:int8 :uint8 :int16 :uint16 :int32 :uint32 :float32 :float64 :bigint64 :biguint64))
      (let ((gname (format nil "get~a" (%dv-suffix kind))) (sname (format nil "set~a" (%dv-suffix kind))) (k kind))
        (install-method dvp gname 2 (lambda (this args) (%dv-get (%this-dv this) k args)))
        (install-method dvp sname 2 (lambda (this args) (%dv-set (%this-dv this) k args)))))
    (let ((ctor (make-constructor "DataView" 3
                  (lambda (this args) (declare (ignore this args)) (throw-type-error "Constructor DataView requires 'new'"))
                  :prototype dvp
                  :construct-fn (lambda (args nt)
                                  (let* ((buf (arg args 0)))
                                    (unless (or (js-array-buffer-p buf)
                                                (and (fboundp 'js-shared-array-buffer-p)
                                                     (js-shared-array-buffer-p buf)))
                                      (throw-type-error "First argument to DataView must be an ArrayBuffer or SharedArrayBuffer"))
                                    (when (array-buffer-detached-p buf) (throw-type-error "ArrayBuffer is detached"))
                                    (let* ((buflen (if (fboundp 'data-buffer-byte-length)
                                                       (data-buffer-byte-length buf)
                                                       (length (js-array-buffer-bytes buf))))
                                           (offset (to-index (arg args 1))))
                                      (when (> offset buflen) (throw-range-error "Start offset out of bounds"))
                                      (let ((bytelen (if (js-undefined-p (arg args 2)) (- buflen offset) (to-index (arg args 2)))))
                                        (when (> (+ offset bytelen) buflen) (throw-range-error "Invalid DataView length"))
                                        (%make-js-data-view :proto (nt-prototype nt (intrinsic :data-view-prototype))
                                                            :class :data-view :abuffer buf
                                                            :byte-offset offset :byte-length bytelen))))))))
      (setf (realm-intrinsic *realm* :data-view-constructor) ctor))
    dvp))

(defun %this-dv (this) (if (js-data-view-p this) this (throw-type-error "not a DataView")))
(defun %dv-require-live (dv) (when (array-buffer-detached-p (js-data-view-abuffer dv)) (throw-type-error "ArrayBuffer is detached")))
(defun %dv-suffix (kind) (ecase kind (:int8 "Int8") (:uint8 "Uint8") (:int16 "Int16") (:uint16 "Uint16")
                           (:int32 "Int32") (:uint32 "Uint32") (:float32 "Float32") (:float64 "Float64")
                           (:bigint64 "BigInt64") (:biguint64 "BigUint64")))

(defun %dv-get (dv kind args)
  ;; §25.3.1.5: ToIndex(offset) runs BEFORE the detach re-check — a detaching valueOf must
  ;; yield a catchable TypeError, not a raw NIL-aref crash.
  (let* ((size (kind-size kind)) (offset (to-index (arg args 0)))
         (le (js-truthy (arg args 1))))
    (%dv-require-live dv)
    (when (> (+ offset size) (js-data-view-byte-length dv)) (throw-range-error "Offset is outside the bounds of the DataView"))
    (read-element (if (fboundp 'data-buffer-bytes)
                      (data-buffer-bytes (js-data-view-abuffer dv))
                      (js-array-buffer-bytes (js-data-view-abuffer dv)))
                  (+ (js-data-view-byte-offset dv) offset) kind le)))

(defun %dv-set (dv kind args)
  (let* ((size (kind-size kind)) (offset (to-index (arg args 0)))
         (value (if (kind-bigint-p kind) (to-bigint (arg args 1)) (to-number (arg args 1))))
         (le (js-truthy (arg args 2))))
    (%dv-require-live dv)
    (when (> (+ offset size) (js-data-view-byte-length dv)) (throw-range-error "Offset is outside the bounds of the DataView"))
    (write-element (if (fboundp 'data-buffer-bytes)
                       (data-buffer-bytes (js-data-view-abuffer dv))
                       (js-array-buffer-bytes (js-data-view-abuffer dv)))
                   (+ (js-data-view-byte-offset dv) offset) kind value le)
    +undefined+))

;;; --- TextEncoder / TextDecoder ---------------------------------------------

(defun %bytes->uint8array (bytes)
  (let* ((len (length bytes)) (buf (make-array-buffer len)))
    (replace (js-array-buffer-bytes buf) bytes)
    (%make-js-typed-array :proto (intrinsic :uint8-prototype) :class :typed-array
                          :abuffer buf :kind :uint8 :byte-offset 0 :array-length len)))

;;; --- Buffer support (Phase 13): a Uint8Array over a fresh buffer with a chosen proto,
;;; and direct octet access — so node:buffer builds Buffers as Uint8Array subclass instances.

(defun make-u8-array (length &optional proto)
  "A fresh zero-filled Uint8Array-kind typed array of LENGTH, with [[Prototype]] PROTO
(default Uint8Array.prototype). node:buffer passes Buffer.prototype."
  (%make-js-typed-array :proto (or proto (intrinsic :uint8-prototype)) :class :typed-array
                        :abuffer (make-array-buffer length) :kind :uint8
                        :byte-offset 0 :array-length length))

(defun u8-from-octets (octets &optional proto)
  "A Uint8Array (proto PROTO) holding a COPY of OCTETS (a byte vector or list)."
  (let* ((v (coerce octets '(simple-array (unsigned-byte 8) (*))))
         (ta (make-u8-array (length v) proto)))
    (replace (ta-bytes ta) v)
    ta))

(defun ta-octets (ta)
  "For a (Uint8Array) typed array: (values BACKING-BYTE-VECTOR BYTE-OFFSET LENGTH). node:buffer
reads/writes the backing vector directly for its byte and numeric accessors."
  (values (ta-bytes ta) (js-typed-array-byte-offset ta) (ta-length ta)))

(defun u8-over-arraybuffer (ab &optional (byte-offset 0) length proto)
  "A Uint8Array over the EXISTING ArrayBuffer AB (SHARES its memory) — Buffer.from(ArrayBuffer)."
  (let ((blen (length (or (js-array-buffer-bytes ab) #()))))
    (%make-js-typed-array :proto (or proto (intrinsic :uint8-prototype)) :class :typed-array
                          :abuffer ab :kind :uint8 :byte-offset byte-offset
                          :array-length (or length (max 0 (- blen byte-offset))))))

(defun ta-subview (ta start end &optional proto)
  "A Uint8Array over the SAME backing buffer as TA spanning [START,END) — SHARES memory
(Buffer.slice/subarray). PROTO defaults to Uint8Array.prototype; node:buffer passes Buffer.prototype."
  (%make-js-typed-array :proto (or proto (intrinsic :uint8-prototype)) :class :typed-array
                        :abuffer (js-typed-array-abuffer ta) :kind :uint8
                        :byte-offset (+ (js-typed-array-byte-offset ta) (max 0 start))
                        :array-length (max 0 (- end start))))

(defun %source-bytes (v)
  "Extract the underlying (unsigned-byte 8) bytes from a TypedArray/DataView/ArrayBuffer."
  (cond
    ((or (js-array-buffer-p v)
         (and (fboundp 'js-shared-array-buffer-p) (js-shared-array-buffer-p v)))
     (or (if (fboundp 'data-buffer-bytes) (data-buffer-bytes v) (js-array-buffer-bytes v))
         (throw-type-error "ArrayBuffer is detached")))
    ((js-typed-array-p v) (let ((b (ta-bytes v)))
                            (subseq b (js-typed-array-byte-offset v)
                                    (+ (js-typed-array-byte-offset v)
                                       (* (ta-length v) (kind-size (js-typed-array-kind v)))))))
    ((js-data-view-p v) (let ((b (js-array-buffer-bytes (js-data-view-abuffer v))))
                          (subseq b (js-data-view-byte-offset v)
                                  (+ (js-data-view-byte-offset v) (js-data-view-byte-length v)))))
    (t (throw-type-error "argument is not a BufferSource"))))

(defun buffer-source-octets (value)
  "Return the exact byte range represented by a BufferSource.
ArrayBuffer may return its backing vector; views return a bounded copy."
  (%source-bytes value))

(defun %to-usv-string (s)
  "Replace every LONE surrogate (unpaired D800..DFFF) with U+FFFD — the WHATWG
JS-string→USV-string step. Valid surrogate PAIRS (astral chars) are preserved."
  (let ((out (make-string-output-stream)) (i 0) (n (length s)))
    (loop while (< i n) do
      (let* ((c (char s i)) (cc (char-code c)))
        (cond
          ((<= #xD800 cc #xDBFF)
           (if (and (< (1+ i) n) (<= #xDC00 (char-code (char s (1+ i))) #xDFFF))
               (progn (write-char c out) (write-char (char s (1+ i)) out) (incf i 2))
               (progn (write-char (code-char #xFFFD) out) (incf i))))
          ((<= #xDC00 cc #xDFFF) (write-char (code-char #xFFFD) out) (incf i))
          (t (write-char c out) (incf i)))))
    (get-output-stream-string out)))

(defun %bootstrap-text-codec ()
  ;; TextEncoder
  (let ((tep (js-make-object (intrinsic :object-prototype) :object)))
    (install-getter tep "encoding" (lambda (this args) (declare (ignore this args)) "utf-8"))
    (install-method tep "encode" 1
      (lambda (this args) (declare (ignore this))
        ;; WHATWG encode operates on scalar values: lone surrogates → U+FFFD first.
        (%bytes->uint8array (code-units->utf8
                             (%to-usv-string (if (js-undefined-p (arg args 0)) "" (to-string (arg args 0))))))))
    (obj-set-desc tep (well-known :to-string-tag) (data-pd "TextEncoder" :writable nil :enumerable nil :configurable t))
    (let ((ctor (make-constructor "TextEncoder" 0
                  (lambda (this args) (declare (ignore this args)) (throw-type-error "Constructor TextEncoder requires 'new'"))
                  :prototype tep
                  :construct-fn (lambda (args nt) (declare (ignore args))
                                  (js-make-object (nt-prototype nt (intrinsic :text-encoder-prototype)) :object)))))
      (setf (realm-intrinsic *realm* :text-encoder-prototype) tep)
      (setf (realm-intrinsic *realm* :text-encoder-constructor) ctor)))
  ;; TextDecoder
  (let ((tdp (js-make-object (intrinsic :object-prototype) :object)))
    (install-getter tdp "encoding" (lambda (this args) (declare (ignore this args)) "utf-8"))
    (install-method tdp "decode" 2
      (lambda (this args) (declare (ignore this))
        (let ((v (arg args 0)))
          (if (js-undefined-p v) ""
              ;; strip a leading BOM (default ignoreBOM=false); WTF-8 lone surrogates → U+FFFD.
              (let ((s (%to-usv-string (utf8->code-units (%source-bytes v)))))
                (if (and (plusp (length s)) (= (char-code (char s 0)) #xFEFF))
                    (subseq s 1) s))))))
    (obj-set-desc tdp (well-known :to-string-tag) (data-pd "TextDecoder" :writable nil :enumerable nil :configurable t))
    (let ((ctor (make-constructor "TextDecoder" 0
                  (lambda (this args) (declare (ignore this args)) (throw-type-error "Constructor TextDecoder requires 'new'"))
                  :prototype tdp
                  :construct-fn (lambda (args nt)
                                  (let ((label (if (js-undefined-p (arg args 0)) "utf-8" (to-string (arg args 0)))))
                                    (unless (member (string-downcase label) '("utf-8" "utf8" "unicode-1-1-utf-8") :test #'string=)
                                      (throw-range-error (format nil "The encoding label provided ('~a') is invalid" label)))
                                    (js-make-object (nt-prototype nt (intrinsic :text-decoder-prototype)) :object))))))
      (setf (realm-intrinsic *realm* :text-decoder-prototype) tdp)
      (setf (realm-intrinsic *realm* :text-decoder-constructor) ctor))))
