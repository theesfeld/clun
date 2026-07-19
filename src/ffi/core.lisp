;;;; core.lisp — Pure-CL FFI / native-addon substrate (Issue #178 / FULL PORT).
;;;;
;;;; Clun cannot load machine-code shared objects (constitutional purity: Common
;;;; Lisp only). This module is the full-port realization of runtime.native-addons:
;;;; a real ABI host with linear memory, typed symbols, dynamic pure-CL library
;;;; registration, N-API-shaped addon lifecycle, and Bun.ffi-compatible surface
;;;; implemented entirely in Common Lisp. Purity is the implementation language,
;;;; not a feature exclusion (epic #177).
;;;;
;;;; Exceeds Bun.ffi:
;;;;   - Bounds-checked pointer reads/writes (Bun can crash on bad ptrs)
;;;;   - register-library / list-libraries from CL and JS
;;;;   - Pure-CL addon packs (.claddon JSON) + N-API define-addon
;;;;   - Inspectable ABI (view-source, library metadata)
;;;;   - cc() accepts pure-CL arithmetic DSL (no TinyCC / no C toolchain)

(in-package :clun.ffi)

;;; --- conditions -------------------------------------------------------------

(define-condition ffi-error (error)
  ((kind :initarg :kind :reader ffi-error-kind)
   (detail :initarg :detail :initform nil :reader ffi-error-detail)
   (code :initarg :code :initform nil :reader ffi-error-code))
  (:report (lambda (c s)
             (if (ffi-error-detail c)
                 (format s "~A: ~A" (ffi-error-kind c) (ffi-error-detail c))
                 (format s "~A" (ffi-error-kind c))))))

(defun %fail (kind detail &optional code)
  (error 'ffi-error :kind kind :detail detail :code code))

;;; --- FFI type table (Bun.ffi FFIType parity) --------------------------------

(defparameter *ffi-type-table*
  ;; name → (id size-or-nil category)
  ;; category: :int :uint :float :ptr :void :cstring :bool :buffer :napi-env :napi-value :function
  '(("char"       0  1 :int)
    ("int8_t"     1  1 :int)
    ("i8"         1  1 :int)
    ("uint8_t"    2  1 :uint)
    ("u8"         2  1 :uint)
    ("int16_t"    3  2 :int)
    ("i16"        3  2 :int)
    ("uint16_t"   4  2 :uint)
    ("u16"        4  2 :uint)
    ("int32_t"    5  4 :int)
    ("i32"        5  4 :int)
    ("int"        5  4 :int)
    ("uint32_t"   6  4 :uint)
    ("u32"        6  4 :uint)
    ("int64_t"    7  8 :int)
    ("i64"        7  8 :int)
    ("uint64_t"   8  8 :uint)
    ("u64"        8  8 :uint)
    ("double"     9  8 :float)
    ("f64"        9  8 :float)
    ("float"     10  4 :float)
    ("f32"       10  4 :float)
    ("bool"      11  1 :bool)
    ("ptr"       12  8 :ptr)
    ("pointer"   12  8 :ptr)
    ("void"      13  0 :void)
    ("cstring"   14  8 :cstring)
    ("i64_fast"  15  8 :int)
    ("u64_fast"  16  8 :uint)
    ("function"  17  8 :function)
    ("napi_env"  18  8 :napi-env)
    ("napi_value" 19 8 :napi-value)
    ("buffer"    20  8 :buffer)
    ("usize"      8  8 :uint)
    ("callback"  12  8 :ptr)))

(defun normalize-type-name (type)
  (cond
    ((null type) "void")
    ((symbolp type) (string-downcase (symbol-name type)))
    ((stringp type) (string-downcase type))
    ((integerp type)
     (or (car (find type *ffi-type-table* :key #'second))
         (%fail :invalid-type (format nil "unknown FFI type id ~A" type))))
    (t (%fail :invalid-type (format nil "invalid FFI type ~S" type)))))

(defun type-info (type)
  (or (cdr (assoc (normalize-type-name type) *ffi-type-table* :test #'string=))
      (%fail :invalid-type (format nil "unknown FFI type ~A" type))))

(defun type-id (type) (first (type-info type)))
(defun type-size (type) (second (type-info type)))
(defun type-category (type) (third (type-info type)))

(defun ffi-type-enum-alist ()
  "All (name . id) pairs for the JS FFIType enum object (includes aliases)."
  (mapcar (lambda (row) (cons (first row) (second row)))
          *ffi-type-table*))

;;; --- pointer / heap model ---------------------------------------------------

(defstruct (ptr-entry (:conc-name pe-))
  kind                                  ; :heap | :view | :fn | :napi | :null
  (offset 0 :type integer)              ; for :heap
  (length 0 :type integer)
  bytes                                 ; shared (unsigned-byte 8) vector for :view/:heap slice
  (closed nil)
  fn                                    ; callable for :fn
  sig                                   ; (:args ... :returns ...)
  meta)                                 ; free-form

(defparameter *ptr-counter* 4096
  "Next pointer id. 0 is null; small ids reserved.")

(defparameter *ptr-table* (make-hash-table :test #'eql)
  "pointer-id → ptr-entry")

(defparameter *heap*
  (make-array 65536 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)
  "Growable pure-CL linear memory for malloc-style allocations and CString bytes.")

(defparameter *heap-brks* nil
  "List of free (offset . length) freelist segments (best-effort).")

(defun reset-ffi-state ()
  "Test helper: clear pointer table, heap, and library/addon registries."
  (clrhash *ptr-table*)
  (setf *ptr-counter* 4096
        *heap* (make-array 65536 :element-type '(unsigned-byte 8)
                           :adjustable t :fill-pointer 0)
        *heap-brks* nil)
  (clrhash *libraries*)
  (clrhash *addons*)
  (register-builtin-libraries)
  t)

(defun %next-ptr-id ()
  (incf *ptr-counter*))

(defun null-pointer-p (p)
  (or (null p) (eql p 0) (eql p 0d0)))

(defun pointer-id (p)
  "Coerce a JS/CL pointer value to a CL integer id (0 = null)."
  (cond
    ((null-pointer-p p) 0)
    ((integerp p) p)
    ((and (typep p 'double-float) (not (/= p p))) ; not NaN
     (if (zerop p) 0 (truncate p)))
    (t (%fail :invalid-ptr (format nil "not a pointer: ~S" p) "ERR_FFI_INVALID_PTR"))))

(defun lookup-ptr (p &key (require t))
  (let* ((id (pointer-id p))
         (e (gethash id *ptr-table*)))
    (cond
      ((zerop id) nil)
      ((and e (not (pe-closed e))) e)
      (require (%fail :invalid-ptr
                      (format nil "invalid or closed pointer ~A" id)
                      "ERR_FFI_INVALID_PTR"))
      (t nil))))

(defun %ensure-heap (need)
  (when (> need (array-total-size *heap*))
    (let ((new (max need (* 2 (array-total-size *heap*)))))
      (adjust-array *heap* new :element-type '(unsigned-byte 8))))
  (when (> need (fill-pointer *heap*))
    (setf (fill-pointer *heap*) need)))

(defun heap-alloc (nbytes &optional (align 8))
  "Allocate NBYTES on the pure-CL heap; return pointer id."
  (when (minusp nbytes)
    (%fail :range "negative allocation" "ERR_FFI_RANGE"))
  (when (> nbytes (* 64 1024 1024))
    (%fail :range "allocation exceeds 64 MiB cap" "ERR_FFI_RANGE"))
  (let* ((off (fill-pointer *heap*))
         (pad (mod (- align (mod off align)) align))
         (start (+ off pad))
         (end (+ start (max 1 nbytes))))
    (%ensure-heap end)
    (fill *heap* 0 :start start :end end)
    (let ((id (%next-ptr-id))
          (e (make-ptr-entry :kind :heap :offset start :length nbytes
                             :bytes *heap*)))
      (setf (gethash id *ptr-table*) e)
      id)))

(defun heap-free (p)
  (let ((e (lookup-ptr p :require nil)))
    (when e
      (setf (pe-closed e) t)
      (remhash (pointer-id p) *ptr-table*))
    t))

(defun register-view (bytes offset length &optional meta)
  "Register a view over an existing octet vector; return pointer id."
  (let ((id (%next-ptr-id))
        (e (make-ptr-entry :kind :view
                           :offset offset
                           :length length
                           :bytes bytes
                           :meta meta)))
    (setf (gethash id *ptr-table*) e)
    id))

(defun register-fn-ptr (fn sig &optional meta)
  (let ((id (%next-ptr-id))
        (e (make-ptr-entry :kind :fn :fn fn :sig sig :meta meta)))
    (setf (gethash id *ptr-table*) e)
    id))

(defun ptr-bytes-window (p &optional byte-offset byte-length)
  "Return (values bytes start end) for a live data pointer."
  (let* ((id (pointer-id p))
         (e (or (lookup-ptr id)
                (%fail :invalid-ptr "null pointer" "ERR_FFI_INVALID_PTR")))
         (off (or byte-offset 0)))
    (when (eq (pe-kind e) :fn)
      (%fail :invalid-ptr "function pointer is not readable as data" "ERR_FFI_INVALID_PTR"))
    (let* ((bytes (pe-bytes e))
           (base (pe-offset e))
           (len (pe-length e))
           (start (+ base off))
           (avail (max 0 (- len off)))
           (n (or byte-length avail)))
      (when (or (minusp off) (> n avail) (> (+ start n) (length bytes)))
        (%fail :range
               (format nil "out-of-bounds read/write at ptr=~A off=~A len=~A"
                       id off n)
               "ERR_FFI_RANGE"))
      (values bytes start (+ start n)))))

;;; --- endian helpers (little-endian, Bun host ABI on supported targets) ------

(defun %get-uint (bytes index size)
  (loop for i below size sum (ash (aref bytes (+ index i)) (* 8 i))))

(defun %put-uint (bytes index size u)
  (dotimes (i size)
    (setf (aref bytes (+ index i)) (ldb (byte 8 (* 8 i)) u))))

(defun %sfold (u bits)
  (if (>= u (ash 1 (1- bits))) (- u (ash 1 bits)) u))

(defun read-u8 (p &optional (byte-offset 0))
  (multiple-value-bind (b s e) (ptr-bytes-window p byte-offset 1)
    (declare (ignore e)) (aref b s)))

(defun read-i8 (p &optional (byte-offset 0))
  (%sfold (read-u8 p byte-offset) 8))

(defun read-u16 (p &optional (byte-offset 0))
  (multiple-value-bind (b s e) (ptr-bytes-window p byte-offset 2)
    (declare (ignore e)) (%get-uint b s 2)))

(defun read-i16 (p &optional (byte-offset 0))
  (%sfold (read-u16 p byte-offset) 16))

(defun read-u32 (p &optional (byte-offset 0))
  (multiple-value-bind (b s e) (ptr-bytes-window p byte-offset 4)
    (declare (ignore e)) (%get-uint b s 4)))

(defun read-i32 (p &optional (byte-offset 0))
  (%sfold (read-u32 p byte-offset) 32))

(defun read-u64 (p &optional (byte-offset 0))
  (multiple-value-bind (b s e) (ptr-bytes-window p byte-offset 8)
    (declare (ignore e)) (%get-uint b s 8)))

(defun read-i64 (p &optional (byte-offset 0))
  (%sfold (read-u64 p byte-offset) 64))

(defun read-f32 (p &optional (byte-offset 0))
  (let ((u (read-u32 p byte-offset)))
    (coerce (sb-kernel:make-single-float (%sfold u 32)) 'double-float)))

(defun read-f64 (p &optional (byte-offset 0))
  (let ((u (read-u64 p byte-offset)))
    (sb-kernel:make-double-float
     (%sfold (ldb (byte 32 32) u) 32)
     (ldb (byte 32 0) u))))

(defun read-ptr (p &optional (byte-offset 0))
  (read-u64 p byte-offset))

(defun write-u8 (p byte-offset value)
  (multiple-value-bind (b s e) (ptr-bytes-window p byte-offset 1)
    (declare (ignore e))
    (setf (aref b s) (ldb (byte 8 0) (truncate value)))
    value))

(defun write-i8 (p byte-offset value) (write-u8 p byte-offset value))
(defun write-u16 (p byte-offset value)
  (multiple-value-bind (b s e) (ptr-bytes-window p byte-offset 2)
    (declare (ignore e)) (%put-uint b s 2 (truncate value)) value))
(defun write-i16 (p byte-offset value) (write-u16 p byte-offset value))
(defun write-u32 (p byte-offset value)
  (multiple-value-bind (b s e) (ptr-bytes-window p byte-offset 4)
    (declare (ignore e)) (%put-uint b s 4 (truncate value)) value))
(defun write-i32 (p byte-offset value) (write-u32 p byte-offset value))
(defun write-u64 (p byte-offset value)
  (multiple-value-bind (b s e) (ptr-bytes-window p byte-offset 8)
    (declare (ignore e)) (%put-uint b s 8 (truncate value)) value))
(defun write-i64 (p byte-offset value) (write-u64 p byte-offset value))

(defun write-f32 (p byte-offset value)
  (let* ((sf (coerce (float value 1d0) 'single-float))
         (bits (sb-kernel:single-float-bits sf)))
    (write-u32 p byte-offset (ldb (byte 32 0) bits))))

(defun write-f64 (p byte-offset value)
  (let* ((d (float value 1d0))
         (hi (sb-kernel:double-float-high-bits d))
         (lo (sb-kernel:double-float-low-bits d))
         (u (logior (ash (ldb (byte 32 0) hi) 32) lo)))
    (write-u64 p byte-offset u)))

(defun write-ptr (p byte-offset value)
  (write-u64 p byte-offset (pointer-id value)))

(defun read-bytes (p &optional byte-offset byte-length)
  (multiple-value-bind (b s e)
      (if byte-length
          (ptr-bytes-window p (or byte-offset 0) byte-length)
          (let ((e (lookup-ptr p)))
            (unless e (%fail :invalid-ptr "null pointer" "ERR_FFI_INVALID_PTR"))
            (ptr-bytes-window p (or byte-offset 0) (pe-length e))))
    (subseq b s e)))

(defun read-cstring (p &optional (byte-offset 0) byte-length)
  "UTF-8 C string at pointer (null-terminated unless BYTE-LENGTH given)."
  (let* ((e (lookup-ptr p))
         (bytes (pe-bytes e))
         (base (+ (pe-offset e) byte-offset))
         (limit (if byte-length
                    (+ base byte-length)
                    (min (length bytes) (+ base (pe-length e))))))
    (when (> base (length bytes))
      (%fail :range "cstring out of bounds" "ERR_FFI_RANGE"))
    (let ((end (if byte-length
                   limit
                   (or (position 0 bytes :start base :end limit) limit))))
      (sb-ext:octets-to-string (subseq bytes base end) :external-format :utf-8))))

(defun alloc-cstring (string)
  "Allocate a null-terminated UTF-8 string on the heap; return pointer id."
  (let* ((oct (sb-ext:string-to-octets string :external-format :utf-8))
         (n (length oct))
         (id (heap-alloc (1+ n)))
         (e (lookup-ptr id)))
    (replace (pe-bytes e) oct :start1 (pe-offset e))
    (setf (aref (pe-bytes e) (+ (pe-offset e) n)) 0)
    id))

;;; --- libraries --------------------------------------------------------------

(defstruct (ffi-symbol (:conc-name fs-))
  name
  args                                  ; list of type names
  returns
  fn                                    ; (lambda (&rest args) ...) CL values
  (ptr-id 0))

(defstruct (ffi-library (:conc-name fl-))
  name
  path
  (symbols (make-hash-table :test #'equal)) ; name → ffi-symbol
  (closed nil)
  meta)

(defparameter *libraries* (make-hash-table :test #'equal)
  "library name (string) → ffi-library")

(defun library-key (name)
  (string-downcase (string name)))

(defun %basename (path)
  (let* ((s (string path))
         (slash (max (or (position #\/ s :from-end t) -1)
                     (or (position #\\ s :from-end t) -1))))
    (subseq s (1+ slash))))

(defun %strip-lib-suffix (name)
  (let ((s (library-key name)))
    (dolist (suf '(".claddon" ".so" ".dylib" ".dll" ".node" ".dylib.claddon") s)
      (let ((n (length suf)))
        (when (and (>= (length s) n)
                   (string= s suf :start1 (- (length s) n)))
          (return (subseq s 0 (- (length s) n))))))))

(defun resolve-library-name (name)
  "Match NAME against registered libraries (exact, basename, suffix-stripped)."
  (let* ((raw (library-key name))
         (base (%basename raw))
         (stripped (%strip-lib-suffix base))
         (candidates (list raw base stripped
                           (concatenate 'string "lib" stripped)
                           (%strip-lib-suffix raw))))
    (dolist (c candidates)
      (let ((lib (gethash c *libraries*)))
        (when (and lib (not (fl-closed lib)))
          (return-from resolve-library-name lib))))
    nil))

(defun register-library (name symbols &key path meta)
  "Register a pure-CL native library.
SYMBOLS is an alist or list of plists:
  (\"add\" :args (\"i32\" \"i32\") :returns \"i32\" :fn #'+)
or hash-table name → plist."
  (let* ((key (library-key name))
         (lib (make-ffi-library :name key :path path :meta meta)))
    (labels ((add-sym (sym-name args returns fn)
               (let* ((an (mapcar #'normalize-type-name args))
                      (rn (normalize-type-name (or returns "void")))
                      (fs (make-ffi-symbol :name (string sym-name)
                                           :args an :returns rn :fn fn))
                      (pid (register-fn-ptr fn (list :args an :returns rn)
                                            (list :library key :symbol (string sym-name)))))
                 (setf (fs-ptr-id fs) pid
                       (gethash (string sym-name) (fl-symbols lib)) fs))))
      (cond
        ((hash-table-p symbols)
         (maphash (lambda (k v)
                    (let ((plist (if (listp v) v '())))
                      (add-sym k
                               (or (getf plist :args) '())
                               (or (getf plist :returns) "void")
                               (or (getf plist :fn)
                                   (%fail :invalid-arg
                                          (format nil "symbol ~A missing :fn" k))))))
                  symbols))
        (t
         (dolist (row symbols)
           (cond
             ((and (consp row) (keywordp (second row)))
              (add-sym (first row)
                       (getf (cdr row) :args '())
                       (getf (cdr row) :returns "void")
                       (or (getf (cdr row) :fn)
                           (%fail :invalid-arg "symbol missing :fn"))))
             ((and (consp row) (stringp (car row)))
              (let ((plist (cdr row)))
                (add-sym (car row)
                         (getf plist :args '())
                         (getf plist :returns "void")
                         (or (getf plist :fn)
                             (%fail :invalid-arg "symbol missing :fn")))))
             (t (%fail :invalid-arg (format nil "bad symbol row ~S" row))))))))
    (setf (gethash key *libraries*) lib)
    lib))

(defun list-libraries ()
  (let ((out '()))
    (maphash (lambda (k v)
               (declare (ignore v))
               (push k out))
             *libraries*)
    (sort out #'string<)))

(defun unregister-library (name)
  (let ((lib (gethash (library-key name) *libraries*)))
    (when lib
      (setf (fl-closed lib) t)
      (remhash (library-key name) *libraries*))
    t))

(defun coerce-arg (type value)
  "Coerce VALUE (CL) to the host representation expected by a pure-CL symbol."
  (let ((cat (type-category type)))
    (case cat
      ((:void) nil)
      ((:bool) (and value (not (eql value 0)) (not (eql value 0d0))))
      ((:int :uint)
       (cond ((integerp value) value)
             ((typep value 'double-float) (truncate value))
             (t (truncate (float value 1d0)))))
      ((:float)
       (float value 1d0))
      ((:ptr :buffer :cstring :function :napi-env :napi-value)
       (pointer-id value))
      (t value))))

(defun call-symbol (fs arg-values)
  (when (null (fs-fn fs))
    (%fail :closed "symbol has no implementation" "ERR_FFI_CLOSED"))
  (let* ((args (fs-args fs))
         (n (length args))
         (got (length arg-values)))
    (unless (= n got)
      (%fail :invalid-arg
             (format nil "~A expects ~A args, got ~A" (fs-name fs) n got)
             "ERR_INVALID_ARG_TYPE"))
    (let ((coerced (mapcar #'coerce-arg args arg-values)))
      (apply (fs-fn fs) coerced))))

(defun library-close (lib)
  (setf (fl-closed lib) t)
  t)

(defun open-library (name symbol-specs)
  "Resolve pure-CL library NAME and bind SYMBOL-SPECS (alist name → type plist).
Returns a live handle plist (:library lib :bound hash name→ffi-symbol)."
  (let ((lib (resolve-library-name name)))
    (unless lib
      (%fail :dlopen
             (format nil "Cannot open pure-CL addon library '~A'. Register it with Clun.ffi.registerLibrary or load a .claddon."
                     name)
             "ERR_DLOPEN_FAILED"))
    (when (fl-closed lib)
      (%fail :dlopen "library is closed" "ERR_DLOPEN_FAILED"))
    (let ((bound (make-hash-table :test #'equal)))
      (dolist (spec symbol-specs)
        (let* ((sym-name (string (car spec)))
               (plist (cdr spec))
               (want-args (mapcar #'normalize-type-name
                                  (or (getf plist :args) '())))
               (want-ret (normalize-type-name (or (getf plist :returns) "void")))
               (existing (gethash sym-name (fl-symbols lib)))
               (ptr (getf plist :ptr)))
          (cond
            (ptr
             (let* ((e (lookup-ptr ptr))
                    (fn (and e (pe-fn e)))
                    (fs (make-ffi-symbol :name sym-name
                                         :args want-args
                                         :returns want-ret
                                         :fn (or fn
                                                 (%fail :invalid-ptr
                                                        "ptr is not a function"
                                                        "ERR_FFI_INVALID_PTR"))
                                         :ptr-id (pointer-id ptr))))
               (setf (gethash sym-name bound) fs)))
            (existing
             (setf (gethash sym-name bound) existing))
            (t
             (%fail :dlopen
                    (format nil "symbol '~A' not found in library '~A'"
                            sym-name (fl-name lib))
                    "ERR_DLOPEN_FAILED")))))
      (list :library lib :bound bound :name (fl-name lib)))))

(defun link-symbols (symbol-specs)
  "Bind symbols that already have :ptr (like Bun.linkSymbols)."
  (let ((bound (make-hash-table :test #'equal))
        (lib (make-ffi-library :name (format nil "link-~A" (%next-ptr-id))
                               :meta '(:linked t))))
    (dolist (spec symbol-specs)
      (let* ((sym-name (string (car spec)))
             (plist (cdr spec))
             (ptr (or (getf plist :ptr)
                      (%fail :invalid-arg
                             (format nil "linkSymbols: ~A requires ptr" sym-name)
                             "ERR_INVALID_ARG_TYPE")))
             (e (lookup-ptr ptr))
             (args (mapcar #'normalize-type-name (or (getf plist :args) '())))
             (ret (normalize-type-name (or (getf plist :returns) "void")))
             (fn (or (and e (pe-fn e))
                     (%fail :invalid-ptr "ptr is not a function pointer"
                            "ERR_FFI_INVALID_PTR")))
             (fs (make-ffi-symbol :name sym-name :args args :returns ret
                                  :fn fn :ptr-id (pointer-id ptr))))
        (setf (gethash sym-name bound) fs
              (gethash sym-name (fl-symbols lib)) fs)))
    (setf (gethash (fl-name lib) *libraries*) lib)
    (list :library lib :bound bound :name (fl-name lib))))

;;; --- viewSource (inspectable pure-CL ABI wrappers) --------------------------

(defun view-source-for-symbol (name args returns)
  (format nil "/* pure-CL FFI wrapper */~%~A ~A(~{~A~^, ~}) {~%  /* hosted by Clun.ffi */~%  return clun_ffi_call(~S);~%}~%"
          (normalize-type-name returns)
          name
          (loop for a in args for i from 0
                collect (format nil "~A a~A" (normalize-type-name a) i))
          name))

;;; --- pure-CL arithmetic DSL for cc() ----------------------------------------

(defun %tokenize-c-like (src)
  (let ((s (string src)) (i 0) (n (length src)) (toks '()))
    (labels ((peek () (when (< i n) (char s i)))
             (bump () (prog1 (peek) (incf i)))
             (skip-ws ()
               (loop while (and (< i n) (member (peek) '(#\Space #\Tab #\Newline #\Return)))
                     do (bump))
               (when (and (< i n) (char= (peek) #\/) (< (1+ i) n)
                          (char= (char s (1+ i)) #\/))
                 (loop while (and (< i n) (char/= (peek) #\Newline)) do (bump))
                 (skip-ws))))
      (loop
        (skip-ws)
        (when (>= i n) (return (nreverse toks)))
        (let ((c (peek)))
          (cond
            ((alpha-char-p c)
             (let ((start i))
               (loop while (and (< i n)
                                (or (alphanumericp (peek)) (char= (peek) #\_)))
                     do (bump))
               (push (list :id (subseq s start i)) toks)))
            ((digit-char-p c)
             (let ((start i))
               (loop while (and (< i n) (or (digit-char-p (peek)) (char= (peek) #\.)))
                     do (bump))
               (push (list :num (read-from-string (subseq s start i))) toks)))
            ((member c '(#\+ #\- #\* #\/ #\% #\( #\) #\{ #\} #\; #\, #\=))
             (push (list :op (string (bump))) toks))
            (t (%fail :cc (format nil "unexpected char ~S in pure-CL cc source" c)
                      "ERR_FFI_CC"))))))))

(defun %parse-c-functions (src)
  "Parse a tiny C-like subset: `T name(T a, T b) { return expr; }`."
  (let* ((toks (%tokenize-c-like src))
         (i 0)
         (fns '()))
    (labels ((peek () (nth i toks))
             (bump () (prog1 (peek) (incf i)))
             (expect (kind &optional val)
               (let ((tok (bump)))
                 (unless (and tok (eq (first tok) kind)
                              (or (null val) (equal (second tok) val)))
                   (%fail :cc (format nil "parse error near ~S" tok) "ERR_FFI_CC"))
                 tok))
             (parse-type ()
               (second (expect :id)))
             (parse-primary ()
               (let ((tok (peek)))
                 (case (first tok)
                   (:num (second (bump)))
                   (:id
                    (let ((name (second (bump))))
                      (if (and (peek) (eq (first (peek)) :op)
                               (string= (second (peek)) "("))
                          (progn
                            (bump)
                            (let ((args '()))
                              (unless (and (peek) (eq (first (peek)) :op)
                                           (string= (second (peek)) ")"))
                                (push (parse-expr) args)
                                (loop while (and (peek) (eq (first (peek)) :op)
                                                 (string= (second (peek)) ","))
                                      do (bump)
                                         (push (parse-expr) args)))
                              (expect :op ")")
                              (list* :call name (nreverse args))))
                          (list :var name))))
                   (:op
                    (cond
                      ((string= (second tok) "(")
                       (bump)
                       (prog1 (parse-expr) (expect :op ")")))
                      ((string= (second tok) "-")
                       (bump)
                       (list :neg (parse-primary)))
                      (t (%fail :cc "bad primary" "ERR_FFI_CC"))))
                   (t (%fail :cc "bad primary" "ERR_FFI_CC")))))
             (parse-mul ()
               (let ((left (parse-primary)))
                 (loop while (and (peek) (eq (first (peek)) :op)
                                  (member (second (peek)) '("*" "/" "%")
                                          :test #'string=))
                       do (let ((op (second (bump))))
                            (setf left (list :bin op left (parse-primary)))))
                 left))
             (parse-expr ()
               (let ((left (parse-mul)))
                 (loop while (and (peek) (eq (first (peek)) :op)
                                  (member (second (peek)) '("+" "-")
                                          :test #'string=))
                       do (let ((op (second (bump))))
                            (setf left (list :bin op left (parse-mul)))))
                 left)))
      (loop while (peek) do
        (let* ((ret (parse-type))
               (name (second (expect :id)))
               (params '()))
          (expect :op "(")
          (unless (and (peek) (eq (first (peek)) :op) (string= (second (peek)) ")"))
            (let ((pt (parse-type))
                  (pn (second (expect :id))))
              (push (cons pn pt) params))
            (loop while (and (peek) (eq (first (peek)) :op)
                             (string= (second (peek)) ","))
                  do (bump)
                     (let ((pt (parse-type))
                           (pn (second (expect :id))))
                       (push (cons pn pt) params))))
          (expect :op ")")
          (expect :op "{")
          (let ((id (expect :id)))
            (unless (string= (second id) "return")
              (%fail :cc "only return-body functions supported in pure-CL cc"
                     "ERR_FFI_CC")))
          (let ((body (parse-expr)))
            (expect :op ";")
            (expect :op "}")
            (push (list :name name :returns ret
                        :params (nreverse params) :body body)
                  fns))))
      (nreverse fns))))

(defun %eval-c-expr (expr env)
  (cond
    ((numberp expr) expr)
    ((and (consp expr) (eq (first expr) :var))
     (or (gethash (second expr) env)
         (%fail :cc (format nil "unbound ~A" (second expr)) "ERR_FFI_CC")))
    ((and (consp expr) (eq (first expr) :neg))
     (- (%eval-c-expr (second expr) env)))
    ((and (consp expr) (eq (first expr) :bin))
     (let ((op (second expr))
           (a (%eval-c-expr (third expr) env))
           (b (%eval-c-expr (fourth expr) env)))
       (cond ((string= op "+") (+ a b))
             ((string= op "-") (- a b))
             ((string= op "*") (* a b))
             ((string= op "/") (if (zerop b) 0 (truncate a b)))
             ((string= op "%") (if (zerop b) 0 (mod a b)))
             (t (%fail :cc "bad op" "ERR_FFI_CC")))))
    ((and (consp expr) (eq (first expr) :call))
     (%fail :cc "nested calls not supported in pure-CL cc subset" "ERR_FFI_CC"))
    (t (%fail :cc "bad expr" "ERR_FFI_CC"))))

(defun compile-cc-source (source symbol-specs &key name)
  "Compile pure-CL cc source into a registered library. SOURCE may be C-like text
or an alist of name → s-expression string like \"(+ a b)\"."
  (let* ((lib-name (or name (format nil "cc-~A" (%next-ptr-id))))
         (parsed
           (cond
             ((stringp source) (%parse-c-functions source))
             ((listp source)
              (mapcar (lambda (pair)
                        (let* ((n (string (car pair)))
                               (body-str (string (cdr pair)))
                               (body (let ((*package* (find-package :cl)))
                                       (read-from-string body-str))))
                          (list :name n :returns "i32" :params nil
                                :body-cl body :raw t)))
                      source))
             (t (%fail :cc "source must be string or alist" "ERR_FFI_CC"))))
         (by-name (make-hash-table :test #'equal))
         (rows '()))
    (dolist (fn parsed)
      (setf (gethash (getf fn :name) by-name) fn))
    (dolist (spec symbol-specs)
      (let* ((sym (string (car spec)))
             (plist (cdr spec))
             (args (or (getf plist :args) '()))
             (ret (or (getf plist :returns) "i32"))
             (fn-def (gethash sym by-name))
             (explicit-fn (getf plist :fn)))
        (cond
          (explicit-fn
           (push (list sym :args args :returns ret :fn explicit-fn) rows))
          (fn-def
           (let ((params (getf fn-def :params))
                 (body (getf fn-def :body))
                 (body-cl (getf fn-def :body-cl)))
             (push
              (list sym :args args :returns ret
                    :fn (if body-cl
                            (let ((form body-cl))
                              (lambda (&rest av)
                                (let ((env (make-hash-table :test #'equal)))
                                  ;; bind a, b, ... style from args list positions
                                  (loop for i from 0 for a in args
                                        for pname = (or (car (nth i params))
                                                        (format nil "a~A" i)
                                                        (nth i '("a" "b" "c" "d" "e" "f")))
                                        do (setf (gethash pname env) (nth i av)
                                                 (gethash (format nil "a~A" i) env)
                                                 (nth i av)))
                                  ;; evaluate CL form with a/b symbols
                                  (let ((*package* (find-package :cl)))
                                    (eval
                                     `(let ,(loop for i from 0 for a in args
                                                  for names = '("a" "b" "c" "d" "e" "f" "g" "h")
                                                  collect (list (intern (nth i names) :cl)
                                                                (nth i av)))
                                        ,form))))))
                            (lambda (&rest av)
                              (let ((env (make-hash-table :test #'equal)))
                                (loop for pair in params
                                      for v in av
                                      do (setf (gethash (car pair) env) v))
                                (%eval-c-expr body env)))))
              rows)))
          (t
           (%fail :cc (format nil "no implementation for symbol ~A" sym)
                  "ERR_FFI_CC")))))
    (register-library lib-name (nreverse rows) :meta '(:cc t))))

;;; --- platform suffix (Bun.ffi.suffix parity) --------------------------------

(defun shared-library-suffix ()
  "Platform shared-object suffix string (path-construction parity with Bun)."
  (let ((os (string-downcase (clun.sys:platform-name))))
    (cond
      ((search "darwin" os) "dylib")
      ((search "win" os) "dll")
      (t "so"))))

;;; --- N-API shaped addon registry --------------------------------------------

(defstruct (napi-addon (:conc-name na-))
  name
  version
  init                                  ; (lambda (env exports) exports)
  (exports nil)                         ; frozen export map name → value/fn
  path
  meta)

(defparameter *addons* (make-hash-table :test #'equal)
  "addon name → napi-addon")

(defun define-addon (name init-fn &key version path meta)
  "Register a pure-CL N-API-style addon. INIT-FN receives (env exports-hash) and
may populate exports-hash with string keys → CL values or functions."
  (let* ((key (library-key name))
         (addon (make-napi-addon :name key
                                 :version (or version "1.0.0")
                                 :init init-fn
                                 :path path
                                 :meta meta)))
    (setf (gethash key *addons*) addon)
    addon))

(defun list-addons ()
  (let ((out '()))
    (maphash (lambda (k v) (declare (ignore v)) (push k out)) *addons*)
    (sort out #'string<)))

(defun resolve-addon (name)
  (let* ((raw (library-key name))
         (base (%basename raw))
         (stripped (%strip-lib-suffix base)))
    (or (gethash raw *addons*)
        (gethash base *addons*)
        (gethash stripped *addons*))))

(defun load-addon (name)
  "Run addon init and return a fresh exports hash-table (string → value)."
  (let ((addon (or (resolve-addon name)
                   (%fail :dlopen
                          (format nil "Cannot load pure-CL addon '~A'" name)
                          "ERR_DLOPEN_FAILED"))))
    (let ((exports (make-hash-table :test #'equal))
          (env (list :napi-env t :addon (na-name addon))))
      (when (na-init addon)
        (funcall (na-init addon) env exports))
      (setf (na-exports addon) exports)
      exports)))

(defun %json-object-pairs (obj)
  "Return alist pairs for a clun.sys JSON object (or empty list)."
  (cond
    ((eq obj :empty-object) '())
    ((clun.sys:jobject-p obj) obj)
    (t '())))

(defun %json-array-list (arr)
  (cond
    ((null arr) '())
    ((vectorp arr) (coerce arr 'list))
    ((listp arr) arr)
    (t '())))

(defun %expr-fn (expr-string arity)
  "Compile EXPR-STRING as a CL form with bindings a,b,c… for ARITY args."
  (let ((form (let ((*package* (find-package :cl)))
                (read-from-string (string expr-string))))
        (names '("a" "b" "c" "d" "e" "f" "g" "h")))
    (lambda (&rest av)
      (eval
       `(let ,(loop for i from 0 below (max arity (length av))
                    for n in names
                    collect (list (intern n :cl) (nth i av)))
          ,form)))))

(defun load-claddon-file (path)
  "Load a .claddon JSON manifest and register its library + napi exports.
Manifest shape:
  {\"name\":\"demo\",\"version\":\"1\",
   \"symbols\":{\"add\":{\"args\":[\"i32\",\"i32\"],\"returns\":\"i32\",\"expr\":\"(+ a b)\"}},
   \"exports\":{\"hello\":{\"type\":\"function\",\"expr\":\"\\\"hi\\\"\"}}}"
  (let* ((text (clun.sys:read-file-string path))
         (json (clun.sys:parse-json text))
         (name (or (clun.sys:jget json "name")
                   (%basename path)))
         (version (or (clun.sys:jget json "version") "1.0.0"))
         (symbols (clun.sys:jget json "symbols"))
         (exports (clun.sys:jget json "exports"))
         (rows '()))
    (dolist (pair (%json-object-pairs symbols))
      (let* ((sym (car pair))
             (desc (cdr pair))
             (args (%json-array-list (clun.sys:jget desc "args")))
             (ret (or (clun.sys:jget desc "returns") "void"))
             (expr (clun.sys:jget desc "expr")))
        (push (list (string sym)
                    :args (mapcar #'string args)
                    :returns (string ret)
                    :fn (if expr
                            (%expr-fn expr (length args))
                            (lambda (&rest av)
                              (declare (ignore av))
                              (%fail :dlopen "symbol has no expr"
                                     "ERR_DLOPEN_FAILED"))))
              rows)))
    (when rows
      (register-library name (nreverse rows) :path path
                        :meta (list :claddon t :version version)))
    (define-addon
        name
        (lambda (env exp)
          (declare (ignore env))
          (dolist (pair (%json-object-pairs exports))
            (let* ((k (car pair))
                   (desc (cdr pair))
                   (type (clun.sys:jget desc "type"))
                   (expr (clun.sys:jget desc "expr"))
                   (form (when expr
                           (let ((*package* (find-package :cl)))
                             (read-from-string (string expr))))))
              (setf (gethash (string k) exp)
                    (if (equal type "function")
                        (let ((f form))
                          (lambda (&rest av)
                            (declare (ignore av))
                            (eval f)))
                        (eval form)))))
          exp)
        :version version :path path :meta '(:claddon t))
    name))

;;; --- builtin demo library (always present) ----------------------------------

(defun register-builtin-libraries ()
  "Built-in pure-CL libs available to dlopen without prior registration."
  (register-library
   "clun_demo"
   `(("add" :args ("i32" "i32") :returns "i32"
            :fn ,(lambda (a b) (+ a b)))
     ("sub" :args ("i32" "i32") :returns "i32"
            :fn ,(lambda (a b) (- a b)))
     ("mul" :args ("i32" "i32") :returns "i32"
            :fn ,(lambda (a b) (* a b)))
     ("sum3" :args ("i32" "i32" "i32") :returns "i32"
             :fn ,(lambda (a b c) (+ a b c)))
     ("identity_ptr" :args ("ptr") :returns "ptr"
                     :fn ,(lambda (p) p))
     ("write_u32" :args ("ptr" "u32") :returns "void"
                  :fn ,(lambda (p v) (write-u32 p 0 v) nil))
     ("read_u32" :args ("ptr") :returns "u32"
                 :fn ,(lambda (p) (read-u32 p 0)))
     ("version" :args () :returns "cstring"
                :fn ,(lambda () (alloc-cstring "clun-ffi-1.0.0"))))
   :meta '(:builtin t))
  ;; alias without underscore
  (let ((lib (gethash "clun_demo" *libraries*)))
    (when lib
      (setf (gethash "clun-demo" *libraries*) lib
            (gethash "libclun_demo" *libraries*) lib)))
  (define-addon
      "clun_napi_demo"
      (lambda (env exports)
        (declare (ignore env))
        (setf (gethash "hello" exports)
              (lambda (&rest args)
                (declare (ignore args))
                "hello-from-pure-cl-napi")
              (gethash "add" exports)
              (lambda (&rest args)
                (flet ((num (x)
                         (cond ((integerp x) x)
                               ((typep x 'float) (truncate x))
                               (t 0))))
                  (+ (num (first args)) (num (second args)))))
              (gethash "version" exports) "1.0.0")
        exports)
      :version "1.0.0" :meta '(:builtin t))
  t)

;; Initialize builtins at load time.
(register-builtin-libraries)
