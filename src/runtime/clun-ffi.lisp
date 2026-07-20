;;;; clun-ffi.lisp — bun:ffi + Clun.ffi / Clun.native / Clun.napi JS surface
;;;; (Issue #178 FULL PORT). Pure-CL host; no machine-code loading.

(in-package :clun.runtime)

;;; --- error helpers ----------------------------------------------------------

(defun %ffi-type-error (message)
  (let ((error (eng:make-error-object :type-error-prototype "TypeError" message)))
    (eng:js-set error "code" "ERR_INVALID_ARG_TYPE" nil)
    (eng:throw-js-value error)))

(defun %ffi-error-object (condition)
  (let* ((kind (clun.ffi:ffi-error-kind condition))
         (detail (or (clun.ffi:ffi-error-detail condition) (string kind)))
         (code (or (clun.ffi:ffi-error-code condition)
                   (case kind
                     (:dlopen "ERR_DLOPEN_FAILED")
                     (:invalid-ptr "ERR_FFI_INVALID_PTR")
                     (:range "ERR_FFI_RANGE")
                     (:cc "ERR_FFI_CC")
                     (:invalid-arg "ERR_INVALID_ARG_TYPE")
                     (t "ERR_FFI"))))
         (name (if (eq kind :invalid-arg) "TypeError" "Error"))
         (proto (if (eq kind :invalid-arg)
                    :type-error-prototype
                    :error-prototype))
         (error (eng:make-error-object proto name detail)))
    (eng:js-set error "code" code nil)
    error))

(defmacro %ffi-guard (&body body)
  `(handler-case (progn ,@body)
     (clun.ffi:ffi-error (e)
       (eng:throw-js-value (%ffi-error-object e)))
     (error (e)
       (let ((err (eng:make-error-object
                   :error-prototype "Error"
                   (format nil "~A" e))))
         (eng:js-set err "code" "ERR_FFI" nil)
         (eng:throw-js-value err)))))

;;; --- type coercion ----------------------------------------------------------

(defun %ffi-type-name (v)
  (cond
    ((eng:js-undefined-p v) "void")
    ((eng:js-string-p v) v)
    ((eng:js-number-p v)
     (or (car (find (truncate v) clun.ffi::*ffi-type-table* :key #'second))
         (%ffi-type-error (format nil "unknown FFIType ~A" v))))
    (t (%ffi-type-error "FFI type must be a string or FFIType enum value"))))

(defun %ffi-ptr-number (id)
  (coerce id 'double-float))

(defun %js->cl-number (v)
  (cond
    ((eng:js-undefined-p v) 0)
    ((eng:js-null-p v) 0)
    ((eng:js-bigint-p v) v)
    ((eng:js-number-p v)
     (if (or (eng:js-nan-p v) (eng:js-infinite-p v)) 0 (truncate v)))
    ((eng:js-boolean-p v) (if (eq v eng:+true+) 1 0))
    (t (let ((n (eng:to-number v)))
         (if (or (eng:js-nan-p n) (eng:js-infinite-p n)) 0 (truncate n))))))

(defun %js->cl-float (v)
  (cond
    ((eng:js-number-p v) v)
    ((eng:js-bigint-p v) (coerce v 'double-float))
    (t (eng:to-number v))))

(defun %js->ptr-id (v)
  (cond
    ((or (eng:js-null-p v) (eng:js-undefined-p v)) 0)
    ((eng:js-number-p v) (if (zerop v) 0 (truncate v)))
    ((eng:js-bigint-p v) v)
    ((eng:js-typed-array-p v) (%ptr-from-view v 0))
    ((eng:js-array-buffer-p v) (%ptr-from-buffer v 0))
    ((and (eng:js-object-p v) (eng:js-get v "ptr"))
     (%js->ptr-id (eng:js-get v "ptr")))
    (t (%ffi-type-error "expected a pointer, TypedArray, or ArrayBuffer"))))

(defun %cl->js-return (type value)
  (let ((cat (clun.ffi:type-category type)))
    (case cat
      ((:void) eng:+undefined+)
      ((:bool) (eng:js-boolean (and value (not (eql value 0)))))
      ((:int :uint)
       (if (or (typep value 'integer)
               (and (numberp value) (> (abs value) (expt 2 53))))
           ;; i64/u64 → prefer bigint when outside safe int or type is 64-bit
           (if (member (clun.ffi:normalize-type-name type)
                       '("int64_t" "i64" "uint64_t" "u64" "i64_fast" "u64_fast"
                         "usize")
                       :test #'string=)
               (truncate value)
               (coerce value 'double-float))
           (coerce (truncate value) 'double-float)))
      ((:float) (coerce (float value 1d0) 'double-float))
      ((:ptr :buffer :function :napi-env :napi-value)
       (if (or (null value) (eql value 0))
           eng:+null+
           (%ffi-ptr-number (clun.ffi:pointer-id value))))
      ((:cstring)
       (cond
         ((stringp value) value)
         ((integerp value) (clun.ffi:read-cstring value))
         (t (eng:to-string value))))
      (t value))))

(defun %js-arg-for-type (type v)
  (let ((cat (clun.ffi:type-category type)))
    (case cat
      ((:bool) (eng:js-truthy v))
      ((:float) (%js->cl-float v))
      ((:int :uint) (%js->cl-number v))
      ((:ptr :buffer :function :napi-env :napi-value) (%js->ptr-id v))
      ((:cstring)
       (cond
         ((eng:js-string-p v) (clun.ffi:alloc-cstring v))
         (t (%js->ptr-id v))))
      (t v))))

;;; --- ptr() from TypedArray / ArrayBuffer ------------------------------------

(defun %ptr-from-buffer (ab byte-offset)
  (let* ((bytes (or (eng:js-array-buffer-bytes ab)
                    (%ffi-type-error "ArrayBuffer is detached")))
         (off (max 0 (truncate byte-offset)))
         (len (max 0 (- (length bytes) off))))
    (clun.ffi:register-view bytes off len (list :abuffer ab))))

(defun %ptr-from-view (ta byte-offset)
  (multiple-value-bind (bytes off len) (eng:ta-octets ta)
    (let* ((extra (max 0 (truncate byte-offset)))
           (start (+ off extra))
           (avail (max 0 (- len extra))))
      (clun.ffi:register-view bytes start avail (list :typed-array ta)))))

(defun %ffi-ptr (args)
  (%ffi-guard
    (let ((view (eng:arg args 0))
          (off (eng:arg args 1)))
      (when (or (eng:js-undefined-p view) (eng:js-null-p view))
        (%ffi-type-error "ptr() expects a TypedArray, ArrayBuffer, or DataView"))
      (let ((byte-offset (if (eng:js-undefined-p off) 0 (eng:to-number off))))
        (when (or (eng:js-nan-p byte-offset) (minusp byte-offset))
          (%ffi-type-error "byteOffset must be a non-negative number"))
        (%ffi-ptr-number
         (cond
           ((eng:js-typed-array-p view) (%ptr-from-view view byte-offset))
           ((eng:js-array-buffer-p view) (%ptr-from-buffer view byte-offset))
           ((and (eng:js-object-p view)
                 (eng:js-array-buffer-p (eng:js-get view "buffer")))
            ;; DataView-like
            (let* ((ab (eng:js-get view "buffer"))
                   (base (eng:to-number (eng:js-get view "byteOffset")))
                   (base-n (if (eng:js-nan-p base) 0 (truncate base))))
              (%ptr-from-buffer ab (+ base-n (truncate byte-offset)))))
           (t (%ffi-type-error
               "ptr() expects a TypedArray, ArrayBuffer, or DataView"))))))))

;;; --- read / write / toBuffer / toArrayBuffer / CString ----------------------

(defun %make-read-ns ()
  (let ((o (eng:new-object)))
    (flet ((rd (name fn)
             (eng:install-method o name 2
               (lambda (this args)
                 (declare (ignore this))
                 (%ffi-guard
                   (let* ((p (%js->ptr-id (eng:arg args 0)))
                          (off (eng:arg args 1))
                          (byte-off (if (eng:js-undefined-p off) 0
                                        (truncate (eng:to-number off))))
                          (val (funcall fn p byte-off)))
                     (if (integerp val)
                         (if (> (integer-length (abs val)) 53)
                             val
                             (coerce val 'double-float))
                         (coerce val 'double-float))))))))
      (rd "u8" #'clun.ffi:read-u8)
      (rd "i8" #'clun.ffi:read-i8)
      (rd "u16" #'clun.ffi:read-u16)
      (rd "i16" #'clun.ffi:read-i16)
      (rd "u32" #'clun.ffi:read-u32)
      (rd "i32" #'clun.ffi:read-i32)
      (rd "u64" (lambda (p o) (clun.ffi:read-u64 p o)))
      (rd "i64" (lambda (p o) (clun.ffi:read-i64 p o)))
      (rd "f32" #'clun.ffi:read-f32)
      (rd "f64" #'clun.ffi:read-f64)
      (rd "ptr" (lambda (p o) (clun.ffi:read-ptr p o)))
      (rd "intptr" (lambda (p o) (clun.ffi:read-i64 p o))))
    o))

(defun %make-write-ns ()
  (let ((o (eng:new-object)))
    (flet ((wr (name fn)
             (eng:install-method o name 3
               (lambda (this args)
                 (declare (ignore this))
                 (%ffi-guard
                   (let* ((p (%js->ptr-id (eng:arg args 0)))
                          (off (truncate (eng:to-number (eng:arg args 1))))
                          (val (eng:arg args 2)))
                     (funcall fn p off
                              (if (eng:js-bigint-p val) val
                                  (eng:to-number val)))
                     eng:+undefined+))))))
      (wr "u8" #'clun.ffi:write-u8)
      (wr "i8" #'clun.ffi:write-i8)
      (wr "u16" #'clun.ffi:write-u16)
      (wr "i16" #'clun.ffi:write-i16)
      (wr "u32" #'clun.ffi:write-u32)
      (wr "i32" #'clun.ffi:write-i32)
      (wr "u64" #'clun.ffi:write-u64)
      (wr "i64" #'clun.ffi:write-i64)
      (wr "f32" (lambda (p o v) (clun.ffi:write-f32 p o (float v 1d0))))
      (wr "f64" (lambda (p o v) (clun.ffi:write-f64 p o (float v 1d0))))
      (wr "ptr" (lambda (p o v) (clun.ffi:write-ptr p o (%js->ptr-id v)))))
    o))

(defun %to-array-buffer (args)
  (%ffi-guard
    (let* ((p (%js->ptr-id (eng:arg args 0)))
           (off (eng:arg args 1))
           (len (eng:arg args 2))
           (byte-off (if (eng:js-undefined-p off) 0 (truncate (eng:to-number off))))
           (byte-len (if (eng:js-undefined-p len) nil
                         (truncate (eng:to-number len))))
           (octets (clun.ffi:read-bytes p byte-off byte-len))
           (u8 (eng:u8-from-octets octets)))
      (eng:js-get u8 "buffer"))))

(defun %to-buffer (args)
  "Return a Uint8Array (Buffer-compatible) over a copy of the pointed-to bytes."
  (let ((ab (%to-array-buffer args)))
    (eng:u8-over-arraybuffer ab)))

(defun %make-cstring (args)
  "Bun.CString(ptr) — pure-CL host also accepts an already-decoded string."
  (%ffi-guard
    (let ((a0 (eng:arg args 0)))
      (when (eng:js-string-p a0)
        (let ((o (eng:new-object)))
          (eng:data-prop o "ptr" 0d0)
          (eng:install-method o "toString" 0
            (lambda (this a) (declare (ignore this a)) a0))
          (eng:install-method o "valueOf" 0
            (lambda (this a) (declare (ignore this a)) a0))
          (eng:data-prop o "length" (coerce (length a0) 'double-float))
          (return-from %make-cstring o)))
      (let* ((p (%js->ptr-id a0))
             (off (eng:arg args 1))
             (len (eng:arg args 2))
             (byte-off (if (eng:js-undefined-p off) 0 (truncate (eng:to-number off))))
             (byte-len (if (eng:js-undefined-p len) nil
                           (truncate (eng:to-number len))))
             (str (if (zerop p) ""
                      (clun.ffi:read-cstring p byte-off byte-len)))
             (o (eng:new-object)))
        (eng:data-prop o "ptr" (%ffi-ptr-number p))
        (eng:data-prop o "byteOffset" (coerce byte-off 'double-float))
        (when byte-len
          (eng:data-prop o "byteLength" (coerce byte-len 'double-float)))
        (eng:install-method o "toString" 0
          (lambda (this a) (declare (ignore this a)) str))
        (eng:install-method o "valueOf" 0
          (lambda (this a) (declare (ignore this a)) str))
        (eng:data-prop o "length" (coerce (length str) 'double-float))
        (eng:install-getter o "arrayBuffer"
          (lambda (this a)
            (declare (ignore this a))
            (if (zerop p)
                (eng:js-get (eng:u8-from-octets #()) "buffer")
                (%to-array-buffer
                 (list (%ffi-ptr-number p)
                       (coerce byte-off 'double-float)
                       (if byte-len (coerce byte-len 'double-float)
                           eng:+undefined+))))))
        (eng:hidden-prop o "[[CStringValue]]" str)
        o))))

;;; --- symbol call wrappers ---------------------------------------------------

(defun %make-symbol-fn (fs)
  (let* ((arity (length (clun.ffi:fs-args fs)))
         (name (clun.ffi:fs-name fs)))
    (eng:make-native-function
     name arity
     (lambda (this args)
       (declare (ignore this))
       (%ffi-guard
         (let* ((want (clun.ffi:fs-args fs))
                (vals (loop for i from 0 below (length want)
                            for ty in want
                            collect (%js-arg-for-type ty (eng:arg args i))))
                (raw (clun.ffi:call-symbol fs vals)))
           (%cl->js-return (clun.ffi:fs-returns fs) raw)))))))

(defun %make-library-object (handle)
  (let* ((bound (getf handle :bound))
         (lib (getf handle :library))
         (symbols (eng:new-object))
         (o (eng:new-object)))
    (maphash (lambda (name fs)
               (eng:data-prop symbols name (%make-symbol-fn fs)))
             bound)
    (eng:data-prop o "symbols" symbols)
    (eng:install-method o "close" 0
      (lambda (this args)
        (declare (ignore this args))
        (clun.ffi:library-close lib)
        eng:+undefined+))
    o))

(defun %parse-symbol-specs (obj)
  "JS object { name: { args, returns, ptr?, fn? } } → alist of symbol specs."
  (unless (eng:js-object-p obj)
    (%ffi-type-error "symbols must be an object"))
  (let ((keys (eng:jm-own-property-keys obj))
        (out '()))
    (dolist (k keys)
      (when (eng:js-string-p k)
        (let* ((desc (eng:js-get obj k))
               (args '())
               (returns "void")
               (ptr nil)
               (fn nil))
          (when (eng:js-object-p desc)
            (let ((a (eng:js-get desc "args"))
                  (r (eng:js-get desc "returns"))
                  (p (eng:js-get desc "ptr"))
                  (f (eng:js-get desc "fn")))
              (unless (eng:js-undefined-p a)
                (let ((n (eng:array-length a)))
                  (dotimes (i n)
                    (push (%ffi-type-name (eng:js-get a (format nil "~A" i)))
                          args))
                  (setf args (nreverse args))))
              (unless (eng:js-undefined-p r)
                (setf returns (%ffi-type-name r)))
              (unless (or (eng:js-undefined-p p) (eng:js-null-p p))
                (setf ptr (%js->ptr-id p)))
              (when (eng:js-function-p f)
                (setf fn f))))
          (push (list* k :args args :returns returns
                       (append (when ptr (list :ptr ptr))
                               (when fn (list :fn fn))))
                out))))
    (nreverse out)))

(defun %wrap-js-fn-as-cl (js-fn args-types returns-type)
  (lambda (&rest cl-args)
    (let* ((js-args
             (loop for ty in args-types
                   for v in cl-args
                   collect (%cl->js-return ty v)))
           (result (eng:js-call js-fn eng:+undefined+ js-args)))
      (%js-arg-for-type returns-type result))))

(defun %dlopen (args)
  (%ffi-guard
    (let* ((name-v (eng:arg args 0))
           (syms-v (eng:arg args 1))
           (name (cond
                   ((eng:js-string-p name-v) name-v)
                   ((eng:js-object-p name-v)
                    (let ((p (eng:js-get name-v "name")))
                      (if (eng:js-string-p p) p (eng:to-string name-v))))
                   (t (eng:to-string name-v))))
           (specs (%parse-symbol-specs syms-v))
           ;; If any symbol has a JS :fn, register a transient pure-CL library.
           (needs-reg (some (lambda (s) (getf (cdr s) :fn)) specs)))
      (when needs-reg
        (let ((rows '()))
          (dolist (s specs)
            (let* ((sym (car s))
                   (plist (cdr s))
                   (js-fn (getf plist :fn))
                   (a (getf plist :args '()))
                   (r (getf plist :returns "void")))
              (when js-fn
                (push (list sym :args a :returns r
                            :fn (%wrap-js-fn-as-cl js-fn a r))
                      rows))))
          (when rows
            (clun.ffi:register-library name (nreverse rows)
                                       :meta '(:from-dlopen-fn t)))))
      ;; path to .claddon?
      (when (and (search ".claddon" name) (clun.sys:file-p name))
        (clun.ffi:load-claddon-file name))
      (%make-library-object (clun.ffi:open-library name specs)))))

(defun %link-symbols (args)
  (%ffi-guard
    (let ((specs (%parse-symbol-specs (eng:arg args 0))))
      (%make-library-object (clun.ffi:link-symbols specs)))))

(defun %cfunction (args)
  (%ffi-guard
    (let* ((desc (eng:arg args 0))
           (specs (%parse-symbol-specs
                   (let ((o (eng:new-object)))
                     (eng:data-prop o "fn" desc)
                     o)))
           ;; Prefer object form: { args, returns, ptr }
           (plist (when (eng:js-object-p desc)
                    (list :args
                          (let ((a (eng:js-get desc "args")) (out '()))
                            (unless (eng:js-undefined-p a)
                              (dotimes (i (eng:array-length a))
                                (push (%ffi-type-name
                                       (eng:js-get a (format nil "~A" i)))
                                      out)))
                            (nreverse out))
                          :returns
                          (let ((r (eng:js-get desc "returns")))
                            (if (eng:js-undefined-p r) "void"
                                (%ffi-type-name r)))
                          :ptr
                          (let ((p (eng:js-get desc "ptr")))
                            (if (or (eng:js-undefined-p p) (eng:js-null-p p))
                                nil (%js->ptr-id p))))))
           (handle (clun.ffi:link-symbols
                    (list (list* "fn" (or plist (cdr (first specs)))))))
           (fs (gethash "fn" (getf handle :bound)))
           (callable (%make-symbol-fn fs)))
      (eng:install-method callable "close" 0
        (lambda (this a)
          (declare (ignore this a))
          (clun.ffi:library-close (getf handle :library))
          eng:+undefined+))
      callable)))

(defun %jscallback (args)
  (%ffi-guard
    (let* ((cb (eng:arg args 0))
           (def (eng:arg args 1))
           (args-t '())
           (ret "void"))
      (unless (eng:js-function-p cb)
        (%ffi-type-error "JSCallback expects a function"))
      (when (eng:js-object-p def)
        (let ((a (eng:js-get def "args"))
              (r (eng:js-get def "returns")))
          (unless (eng:js-undefined-p a)
            (dotimes (i (eng:array-length a))
              (push (%ffi-type-name (eng:js-get a (format nil "~A" i))) args-t))
            (setf args-t (nreverse args-t)))
          (unless (eng:js-undefined-p r)
            (setf ret (%ffi-type-name r)))))
      (let* ((cl-fn (%wrap-js-fn-as-cl cb args-t ret))
             (pid (clun.ffi:register-fn-ptr cl-fn
                                            (list :args args-t :returns ret)
                                            '(:jscallback t)))
             (o (eng:new-object)))
        (eng:data-prop o "ptr" (%ffi-ptr-number pid))
        (eng:install-method o "close" 0
          (lambda (this a)
            (declare (ignore this a))
            (let ((e (clun.ffi:lookup-ptr pid :require nil)))
              (when e (setf (clun.ffi:pe-closed e) t)))
            (eng:js-set o "ptr" eng:+null+ nil)
            eng:+undefined+))
        o))))

(defun %view-source (args)
  (%ffi-guard
    (let ((symbols (eng:arg args 0))
          (out (eng:new-array)))
      (cond
        ((eng:js-object-p symbols)
         (let ((i 0))
           (dolist (spec (%parse-symbol-specs symbols))
             (eng:js-set out (format nil "~A" i)
                         (clun.ffi:view-source-for-symbol
                          (car spec)
                          (getf (cdr spec) :args '())
                          (getf (cdr spec) :returns "void"))
                         nil)
             (incf i))
           (eng:js-set out "length" (coerce i 'double-float) nil)))
        (t
         (eng:js-set out "0"
                     (clun.ffi:view-source-for-symbol "callback" '() "void")
                     nil)
         (eng:js-set out "length" 1d0 nil)))
      out)))

(defun %cc (args)
  (%ffi-guard
    (let* ((opts (eng:arg args 0))
           (source (when (eng:js-object-p opts) (eng:js-get opts "source")))
           (syms (when (eng:js-object-p opts) (eng:js-get opts "symbols")))
           (specs (%parse-symbol-specs (or syms (eng:new-object))))
           (src-val
             (cond
               ((eng:js-string-p source) source)
               ((eng:js-object-p source)
                ;; map of name → expr string
                (let ((pairs '()))
                  (dolist (k (eng:jm-own-property-keys source))
                    (when (eng:js-string-p k)
                      (push (cons k (eng:to-string (eng:js-get source k)))
                            pairs)))
                  pairs))
               ((eng:js-undefined-p source) nil)
               (t (eng:to-string source)))))
      ;; Allow symbols to carry fn: implementations (exceed).
      (let ((rows-from-fn '()))
        (dolist (s specs)
          (when (getf (cdr s) :fn)
            (let* ((sym (car s))
                   (plist (cdr s))
                   (a (getf plist :args '()))
                   (r (getf plist :returns "void"))
                   (js-fn (getf plist :fn)))
              (push (list sym :args a :returns r
                          :fn (%wrap-js-fn-as-cl js-fn a r))
                    rows-from-fn))))
        (when (and (null src-val) rows-from-fn)
          (let ((lib (clun.ffi:register-library
                      (format nil "cc-fn-~A" (get-universal-time))
                      (nreverse rows-from-fn)
                      :meta '(:cc t))))
            (return-from %cc
              (%make-library-object
               (clun.ffi:open-library (clun.ffi:fl-name lib) specs))))))
      (unless src-val
        (%ffi-type-error
         "cc() requires source (C-like pure-CL subset or expr map) or symbols with fn"))
      (let ((lib (clun.ffi:compile-cc-source src-val specs)))
        (%make-library-object
         (clun.ffi:open-library (clun.ffi:fl-name lib) specs))))))

;;; --- FFIType enum object ----------------------------------------------------

(defun %make-ffi-type-enum ()
  (let ((o (eng:new-object)))
    (dolist (pair (clun.ffi:ffi-type-enum-alist))
      (eng:data-prop o (car pair) (coerce (cdr pair) 'double-float)))
    ;; aliases already in table
    o))

;;; --- bun:ffi exports --------------------------------------------------------

(defun make-bun-ffi-exports ()
  "Exports object for virtual module bun:ffi."
  (let ((exports (eng:new-object))
        (ffi-type (%make-ffi-type-enum)))
    (eng:data-prop exports "FFIType" ffi-type)
    (eng:data-prop exports "suffix" (clun.ffi:shared-library-suffix))
    (eng:data-prop exports "read" (%make-read-ns))
    (eng:data-prop exports "write" (%make-write-ns))
    (eng:install-method exports "dlopen" 2
      (lambda (this args) (declare (ignore this)) (%dlopen args)))
    (eng:install-method exports "linkSymbols" 1
      (lambda (this args) (declare (ignore this)) (%link-symbols args)))
    (eng:install-method exports "CFunction" 1
      (lambda (this args) (declare (ignore this)) (%cfunction args)))
    (eng:install-method exports "ptr" 2
      (lambda (this args) (declare (ignore this)) (%ffi-ptr args)))
    (eng:install-method exports "toBuffer" 3
      (lambda (this args) (declare (ignore this)) (%to-buffer args)))
    (eng:install-method exports "toArrayBuffer" 3
      (lambda (this args) (declare (ignore this)) (%to-array-buffer args)))
    (eng:install-method exports "viewSource" 2
      (lambda (this args) (declare (ignore this)) (%view-source args)))
    (eng:install-method exports "cc" 1
      (lambda (this args) (declare (ignore this)) (%cc args)))
    ;; CString as constructible function
    (let ((ctor (eng:make-native-function "CString" 3
                  (lambda (this args)
                    (declare (ignore this))
                    (%make-cstring args))
                  :construct
                  (lambda (args nt)
                    (declare (ignore nt))
                    (%make-cstring args)))))
      (eng:data-prop exports "CString" ctor))
    ;; JSCallback
    (let ((ctor (eng:make-native-function "JSCallback" 2
                  (lambda (this args)
                    (declare (ignore this))
                    (%jscallback args))
                  :construct
                  (lambda (args nt)
                    (declare (ignore nt))
                    (%jscallback args)))))
      (eng:data-prop exports "JSCallback" ctor))
    exports))

(defun install-bun-ffi (realm)
  "Register pure-CL bun:ffi virtual module on REALM."
  (eng:register-bun-builtin realm "ffi" (make-bun-ffi-exports)))

;;; --- Clun.ffi / Clun.native / Clun.napi -------------------------------------

(defun %register-library-js (args)
  (%ffi-guard
    (let* ((name (eng:to-string (eng:arg args 0)))
           (syms (eng:arg args 1))
           (specs (%parse-symbol-specs syms))
           (rows '()))
      (dolist (s specs)
        (let* ((sym (car s))
               (plist (cdr s))
               (a (getf plist :args '()))
               (r (getf plist :returns "void"))
               (js-fn (getf plist :fn))
               (ptr (getf plist :ptr)))
          (cond
            (js-fn
             (push (list sym :args a :returns r
                         :fn (%wrap-js-fn-as-cl js-fn a r))
                   rows))
            (ptr
             (let ((e (clun.ffi:lookup-ptr ptr)))
               (push (list sym :args a :returns r
                           :fn (or (and e (clun.ffi:pe-fn e))
                                   (lambda (&rest av)
                                     (declare (ignore av))
                                     (error 'clun.ffi:ffi-error
                                            :kind :invalid-ptr
                                            :detail "not a function ptr"
                                            :code "ERR_FFI_INVALID_PTR"))))
                     rows)))
            (t (%ffi-type-error
                (format nil "registerLibrary: symbol ~A needs fn or ptr" sym))))))
      (clun.ffi:register-library name (nreverse rows) :meta '(:from-js t))
      eng:+undefined+)))

(defun %list-libraries-js (args)
  (declare (ignore args))
  (let* ((names (clun.ffi:list-libraries))
         (arr (eng:new-array)))
    (loop for i from 0 for n in names do
      (eng:js-set arr (format nil "~A" i) n nil))
    (eng:js-set arr "length" (coerce (length names) 'double-float) nil)
    arr))

(defun %native-dlopen (args)
  "process.dlopen / Clun.native.dlopen(module, filename) — pure-CL addons."
  (%ffi-guard
    (let* ((mod (eng:arg args 0))
           (filename (eng:to-string (eng:arg args 1)))
           (exports-target
             (cond
               ((and (eng:js-object-p mod)
                     (eng:js-object-p (eng:js-get mod "exports")))
                (eng:js-get mod "exports"))
               ((eng:js-object-p mod) mod)
               (t (eng:new-object)))))
      (when (and (search ".claddon" filename) (clun.sys:file-p filename))
        (clun.ffi:load-claddon-file filename))
      (let ((table (clun.ffi:load-addon filename)))
        (maphash
         (lambda (k v)
           (eng:data-prop
            exports-target k
            (cond
              ((functionp v)
               (eng:make-native-function
                k 0
                (lambda (this args)
                  (declare (ignore this))
                  (let* ((n (length args))
                         (cl-args (loop for i below n
                                        for a = (eng:arg args i)
                                        collect
                                        (cond
                                          ((eng:js-number-p a)
                                           (if (eng:js-nan-p a) 0
                                               (if (= a (truncate a))
                                                   (truncate a) a)))
                                          ((eng:js-string-p a) a)
                                          ((eng:js-boolean-p a)
                                           (eq a eng:+true+))
                                          ((eng:js-nullish-p a) nil)
                                          (t a))))
                         (raw (apply v cl-args)))
                    (cond
                      ((stringp raw) raw)
                      ((integerp raw) (coerce raw 'double-float))
                      ((floatp raw) (coerce raw 'double-float))
                      ((eq raw t) eng:+true+)
                      ((null raw) eng:+null+)
                      (t raw))))))
              ((stringp v) v)
              ((numberp v) (coerce v 'double-float))
              (t eng:+undefined+))))
         table)
        (when (and (eng:js-object-p mod)
                   (not (eq exports-target mod)))
          (eng:js-set mod "exports" exports-target nil))
        exports-target))))

(defun %define-addon-js (args)
  (%ffi-guard
    (let* ((name (eng:to-string (eng:arg args 0)))
           (setup (eng:arg args 1)))
      (unless (eng:js-function-p setup)
        (%ffi-type-error "defineAddon expects (name, setupFn)"))
      (clun.ffi:define-addon
          name
          (lambda (env exports)
            (declare (ignore env))
            (let ((js-exports (eng:new-object)))
              (eng:js-call setup eng:+undefined+ (list js-exports))
              (dolist (k (eng:jm-own-property-keys js-exports))
                (when (eng:js-string-p k)
                  (let ((v (eng:js-get js-exports k)))
                    (setf (gethash k exports)
                          (cond
                            ((eng:js-function-p v)
                             (lambda (&rest av)
                               (eng:js-call
                                v eng:+undefined+
                                (mapcar (lambda (x)
                                          (if (numberp x)
                                              (coerce x 'double-float) x))
                                        av))))
                            ((eng:js-string-p v) v)
                            ((eng:js-number-p v) v)
                            (t v))))))
              exports)))
      eng:+undefined+)))

(defun %list-addons-js (args)
  (declare (ignore args))
  (let* ((names (clun.ffi:list-addons))
         (arr (eng:new-array)))
    (loop for i from 0 for n in names do
      (eng:js-set arr (format nil "~A" i) n nil))
    (eng:js-set arr "length" (coerce (length names) 'double-float) nil)
    arr))

(defun make-clun-ffi (global)
  (declare (ignore global))
  (let ((o (eng:new-object)))
    (eng:data-prop o "backend" "cl-host")
    (eng:data-prop o "suffix" (clun.ffi:shared-library-suffix))
    (eng:install-method o "registerLibrary" 2
      (lambda (this args) (declare (ignore this)) (%register-library-js args)))
    (eng:install-method o "listLibraries" 0
      (lambda (this args) (declare (ignore this)) (%list-libraries-js args)))
    (eng:install-method o "unregisterLibrary" 1
      (lambda (this args)
        (declare (ignore this))
        (clun.ffi:unregister-library (eng:to-string (eng:arg args 0)))
        eng:+undefined+))
    (eng:install-method o "dlopen" 2
      (lambda (this args) (declare (ignore this)) (%dlopen args)))
    (eng:install-method o "alloc" 1
      (lambda (this args)
        (declare (ignore this))
        (%ffi-guard
          (%ffi-ptr-number
           (clun.ffi:heap-alloc
            (max 0 (truncate (eng:to-number (eng:arg args 0)))))))))
    (eng:install-method o "free" 1
      (lambda (this args)
        (declare (ignore this))
        (%ffi-guard
          (clun.ffi:heap-free (%js->ptr-id (eng:arg args 0)))
          eng:+undefined+)))
    (eng:install-method o "allocCString" 1
      (lambda (this args)
        (declare (ignore this))
        (%ffi-guard
          (%ffi-ptr-number
           (clun.ffi:alloc-cstring (eng:to-string (eng:arg args 0)))))))
    o))

(defun make-clun-native (global)
  (declare (ignore global))
  (let ((o (eng:new-object)))
    (eng:data-prop o "backend" "cl-host")
    (eng:install-method o "dlopen" 2
      (lambda (this args) (declare (ignore this)) (%native-dlopen args)))
    (eng:install-method o "load" 1
      (lambda (this args)
        (declare (ignore this))
        (%native-dlopen (list (eng:new-object) (eng:arg args 0)))))
    (eng:install-method o "list" 0
      (lambda (this args) (declare (ignore this)) (%list-addons-js args)))
    (eng:install-method o "define" 2
      (lambda (this args) (declare (ignore this)) (%define-addon-js args)))
    o))

(defun make-clun-napi (global)
  (declare (ignore global))
  (let ((o (eng:new-object)))
    (eng:data-prop o "backend" "cl-host")
    (eng:install-method o "defineAddon" 2
      (lambda (this args) (declare (ignore this)) (%define-addon-js args)))
    (eng:install-method o "listAddons" 0
      (lambda (this args) (declare (ignore this)) (%list-addons-js args)))
    (eng:install-method o "loadAddon" 1
      (lambda (this args)
        (declare (ignore this))
        (%native-dlopen (list (eng:new-object) (eng:arg args 0)))))
    o))

(defun install-clun-ffi (clun global)
  "Install Clun.ffi / Clun.native / Clun.napi and bun:ffi on the active realm."
  (eng:nonconfigurable-data-prop clun "ffi" (make-clun-ffi global))
  (eng:nonconfigurable-data-prop clun "native" (make-clun-native global))
  (eng:nonconfigurable-data-prop clun "napi" (make-clun-napi global))
  (when eng:*realm*
    (install-bun-ffi eng:*realm*))
  ;; process.dlopen for pure-CL addons (Node shape)
  (let ((proc (eng:js-get global "process")))
    (when (eng:js-object-p proc)
      (eng:install-method proc "dlopen" 2
        (lambda (this args)
          (declare (ignore this))
          (%native-dlopen args)))))
  clun)
