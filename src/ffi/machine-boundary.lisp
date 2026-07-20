;;;; machine-boundary.lisp — narrow user-native load/call boundary (Issue #265).
;;;;
;;;; Constitutional split (Phase 48 / operator decision on #22):
;;;;   * Clun product features stay pure Common Lisp (no CFFI shortcuts for TLS/crypto/etc).
;;;;   * Users may load real machine-code shared libraries (.so / .dylib / .node).
;;;;   * This file is the ONLY allowlisted site of SBCL foreign load/call tokens.
;;;;     Purity scan skips it; every other source still forbids them.
;;;;
;;;; The pure-CL host in core.lisp processes/hooks libraries: typed specs, marshalling,
;;;; registry, error codes. This module only maps names → machine addresses and invokes them.

(in-package :clun.ffi)

;;; --- RTLD flags (POSIX) -----------------------------------------------------

(defconstant +rtld-lazy+ 1)
(defconstant +rtld-now+ 2)
(defconstant +rtld-global+ #x100)
(defconstant +rtld-local+ 0)

;;; --- libc dynamic loader ----------------------------------------------------

(sb-alien:define-alien-routine ("dlopen" %c-dlopen) (* t)
  (filename sb-alien:c-string)
  (flag sb-alien:int))

(sb-alien:define-alien-routine ("dlsym" %c-dlsym) (* t)
  (handle (* t))
  (symbol sb-alien:c-string))

(sb-alien:define-alien-routine ("dlerror" %c-dlerror) sb-alien:c-string)

(sb-alien:define-alien-routine ("dlclose" %c-dlclose) sb-alien:int
  (handle (* t)))

;;; --- handle table -----------------------------------------------------------

(defstruct (machine-handle (:conc-name mh-))
  path
  alien                                 ; alien (* t) from dlopen
  (closed nil)
  (symbols (make-hash-table :test #'equal))) ; name → address (integer)

(defparameter *machine-handles* (make-hash-table :test #'equal)
  "path-key → machine-handle")

(defun reset-machine-state ()
  "Close and forget all machine handles (test helper)."
  (maphash (lambda (k h)
             (declare (ignore k))
             (unless (mh-closed h)
               (ignore-errors (%c-dlclose (mh-alien h)))
               (setf (mh-closed h) t)))
           *machine-handles*)
  (clrhash *machine-handles*)
  t)

(defun %machine-path-key (path)
  (string path))

(defun %null-alien-p (a)
  (or (null a)
      (zerop (sb-sys:sap-int (sb-alien:alien-sap a)))))

(defun machine-available-p ()
  "This boundary is present on SBCL hosts that export the dynamic loader."
  t)

(defun machine-dlerror ()
  (or (%c-dlerror) "unknown dynamic-loader error"))

(defun machine-open (path &key (flags +rtld-now+))
  "dlopen PATH. Returns a machine-handle or signals ffi-error."
  (let* ((key (%machine-path-key path))
         (existing (gethash key *machine-handles*)))
    (when (and existing (not (mh-closed existing)))
      (return-from machine-open existing))
    ;; Clear sticky error state.
    (%c-dlerror)
    (let* ((alien (%c-dlopen (if (and path (plusp (length (string path))))
                                 (string path)
                                 nil)
                             flags))
           (err (when (%null-alien-p alien) (machine-dlerror))))
      (when (%null-alien-p alien)
        (%fail :dlopen
               (format nil "Cannot open machine library '~A': ~A" path (or err "null handle"))
               "ERR_DLOPEN_FAILED"))
      (let ((h (make-machine-handle :path key :alien alien)))
        (setf (gethash key *machine-handles*) h)
        h))))

(defun machine-close (handle)
  (when (and handle (not (mh-closed handle)))
    (%c-dlclose (mh-alien handle))
    (setf (mh-closed handle) t)
    (remhash (mh-path handle) *machine-handles*))
  t)

(defun machine-symbol-address (handle name)
  "Resolve NAME in HANDLE via dlsym; return integer address or signal."
  (when (or (null handle) (mh-closed handle))
    (%fail :dlopen "machine library is closed" "ERR_DLOPEN_FAILED"))
  (let* ((cached (gethash (string name) (mh-symbols handle))))
    (when cached
      (return-from machine-symbol-address cached))
    (%c-dlerror)
    (let* ((sym (%c-dlsym (mh-alien handle) (string name)))
           (err (when (%null-alien-p sym) (machine-dlerror))))
      (when (%null-alien-p sym)
        (%fail :dlopen
               (format nil "symbol '~A' not found in '~A': ~A"
                       name (mh-path handle) (or err "null"))
               "ERR_DLOPEN_FAILED"))
      (let ((addr (sb-sys:sap-int (sb-alien:alien-sap sym))))
        (setf (gethash (string name) (mh-symbols handle)) addr)
        addr))))

;;; --- typed alien call -------------------------------------------------------

(defun %alien-type-for (type-name)
  "Map Clun FFI type name → sb-alien type specifier."
  (let ((cat (type-category type-name))
        (n (normalize-type-name type-name)))
    (case cat
      ((:void) 'sb-alien:void)
      ((:bool) '(sb-alien:signed 32))
      ((:int)
       (cond
         ((member n '("int8_t" "i8" "char") :test #'string=) '(sb-alien:signed 8))
         ((member n '("int16_t" "i16") :test #'string=) '(sb-alien:signed 16))
         ((member n '("int32_t" "i32" "int") :test #'string=) '(sb-alien:signed 32))
         ((member n '("int64_t" "i64" "i64_fast") :test #'string=) '(sb-alien:signed 64))
         (t '(sb-alien:signed 32))))
      ((:uint)
       (cond
         ((member n '("uint8_t" "u8") :test #'string=) '(sb-alien:unsigned 8))
         ((member n '("uint16_t" "u16") :test #'string=) '(sb-alien:unsigned 16))
         ((member n '("uint32_t" "u32") :test #'string=) '(sb-alien:unsigned 32))
         ((member n '("uint64_t" "u64" "u64_fast" "usize") :test #'string=)
          '(sb-alien:unsigned 64))
         (t '(sb-alien:unsigned 32))))
      ((:float)
       (if (member n '("float" "f32") :test #'string=)
           'sb-alien:single-float
           'sb-alien:double-float))
      ((:cstring) 'sb-alien:c-string)
      ((:ptr :buffer :function :napi-env :napi-value)
       '(* t))
      (t
       (%fail :invalid-type
              (format nil "unsupported machine FFI type ~A" type-name)
              "ERR_INVALID_ARG_TYPE")))))

(defun %coerce-machine-arg (type-name value)
  "Coerce a pure-CL host value into something alien-funcall can take."
  (let ((cat (type-category type-name)))
    (case cat
      ((:void) nil)
      ((:bool)
       (if (and value (not (eql value 0)) (not (eql value 0d0))) 1 0))
      ((:int :uint)
       (cond
         ((integerp value) value)
         ((typep value 'double-float) (truncate value))
         ((numberp value) (truncate value))
         (t 0)))
      ((:float)
       (if (member (normalize-type-name type-name) '("float" "f32") :test #'string=)
           (float value 1.0f0)
           (float value 1d0)))
      ((:cstring)
       (cond
         ((null value) nil)
         ((stringp value) value)
         ((integerp value)
          (let ((e (lookup-ptr value :require nil)))
            (if (and e (pe-bytes e) (not (pe-closed e)))
                (let* ((bytes (pe-bytes e))
                       (off (pe-offset e))
                       (len (pe-length e))
                       (end off))
                  (loop while (and (< end (+ off len))
                                   (< end (length bytes))
                                   (plusp (aref bytes end)))
                        do (incf end))
                  (sb-ext:octets-to-string (subseq bytes off end)
                                           :external-format :utf-8))
                nil)))
         (t (princ-to-string value))))
      ((:ptr :buffer :function :napi-env :napi-value)
       (let ((id (pointer-id value)))
         (if (zerop id)
             nil
             (let ((e (lookup-ptr id :require nil)))
               (cond
                 ((and e (eq (pe-kind e) :machine-addr) (getf (pe-meta e) :addr))
                  (sb-sys:int-sap (getf (pe-meta e) :addr)))
                 (t nil))))))
      (t value))))

(defparameter *machine-call-cache* (make-hash-table :test #'equal)
  "Signature → compiled trampoline (address &rest args) → raw alien result.")

(defun %machine-trampoline (arg-types return-type)
  "Compile (or reuse) a trampoline for this alien signature."
  (let* ((key (list (normalize-type-name return-type)
                    (mapcar #'normalize-type-name arg-types)))
         (hit (gethash key *machine-call-cache*)))
    (or hit
        (let* ((rty (%alien-type-for return-type))
               (atys (mapcar #'%alien-type-for arg-types))
               (vars (loop for i from 0 below (length atys)
                           collect (intern (format nil "A~D" i) :clun.ffi)))
               (fn (compile
                    nil
                    `(lambda (address ,@vars)
                       (sb-alien:alien-funcall
                        (sb-alien:sap-alien
                         (sb-sys:int-sap address)
                         (function ,rty ,@atys))
                        ,@vars)))))
          (setf (gethash key *machine-call-cache*) fn)
          fn))))

(defun machine-call (address arg-types return-type arg-values)
  "Invoke machine code at integer ADDRESS with typed ARGS. Returns CL value."
  (let* ((args (mapcar #'normalize-type-name arg-types))
         (ret (normalize-type-name return-type))
         (coerced (mapcar #'%coerce-machine-arg args arg-values))
         (tramp (%machine-trampoline args ret))
         (raw (apply tramp address coerced))
         (cat (type-category ret)))
    (case cat
      ((:void) nil)
      ((:bool) (and raw (not (eql raw 0))))
      ((:cstring)
       (cond
         ((null raw) 0)
         ((stringp raw) (alloc-cstring raw))
         (t
          (handler-case
              (if (%null-alien-p raw)
                  0
                  (alloc-cstring (princ-to-string raw)))
            (error ()
              (alloc-cstring (princ-to-string raw)))))))
      ((:ptr :buffer :function :napi-env :napi-value)
       (cond
         ((null raw) 0)
         ((integerp raw)
          (if (zerop raw)
              0
              (let ((id (%next-ptr-id)))
                (setf (gethash id *ptr-table*)
                      (make-ptr-entry :kind :machine-addr
                                      :meta (list :addr raw)))
                id)))
         (t
          (handler-case
              (if (%null-alien-p raw)
                  0
                  (let* ((addr (sb-sys:sap-int (sb-alien:alien-sap raw)))
                         (id (%next-ptr-id)))
                    (setf (gethash id *ptr-table*)
                          (make-ptr-entry :kind :machine-addr
                                          :meta (list :addr addr)))
                    id))
            (error () 0)))))
      (t raw))))

(defun make-machine-symbol-fn (address arg-types return-type)
  "Return a CL function that calls machine code at ADDRESS."
  (let ((args (mapcar #'normalize-type-name arg-types))
        (ret (normalize-type-name return-type))
        (addr address))
    (lambda (&rest values)
      (machine-call addr args ret values))))
(defun machine-probe-path (name)
  "Return a filesystem path for NAME if it looks like a loadable shared object,
or NAME itself when the dynamic loader should search the system path."
  (let* ((raw (string name))
         (p (probe-file raw)))
    (cond
      (p (namestring p))
      ;; Absolute/relative path that does not exist → fail later at dlopen.
      ((or (and (plusp (length raw)) (char= (char raw 0) #\/))
           (search "/" raw)
           (search "\\" raw))
       raw)
      ;; Bare soname / basename — let dlopen search (libc.so.6, libm.so.6, …).
      ((or (search ".so" raw)
           (search ".dylib" raw)
           (search ".dll" raw)
           (search ".node" raw)
           (search ".bundle" raw))
       raw)
      (t nil))))

(defun system-libc-candidates ()
  "Platform libc sonames for smoke tests and default system FFI demos."
  (let ((os (string-downcase (clun.sys:platform-name))))
    (cond
      ((search "darwin" os)
       '("libSystem.B.dylib" "/usr/lib/libSystem.B.dylib" "libc.dylib"))
      ((search "linux" os)
       '("libc.so.6"
         "/lib64/libc.so.6"
         "/lib/x86_64-linux-gnu/libc.so.6"
         "/lib/aarch64-linux-gnu/libc.so.6"
         "libm.so.6"))
      (t '("libc.so.6" "libSystem.B.dylib")))))

(defun open-system-libc ()
  "Open the first loadable system C library candidate."
  (dolist (c (system-libc-candidates))
    (handler-case
        (return-from open-system-libc (machine-open c))
      (ffi-error ())))
  (%fail :dlopen "no system C library candidates could be opened" "ERR_DLOPEN_FAILED"))
