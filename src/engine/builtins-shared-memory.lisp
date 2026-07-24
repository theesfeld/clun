;;;; builtins-shared-memory.lisp — SharedArrayBuffer + Atomics (Issue #338).
;;;; Shared mutable state is a shared-data-block (byte vector + locks). Each realm
;;;; holds its own js-shared-array-buffer wrapper; workers share the block only.
;;;; Ordinary JS heaps stay single-owner-per-thread.

(in-package :clun.engine)

;;; --- shared data block (the only cross-thread mutable JS memory) ------------

(defstruct (sab-waiter (:constructor %make-sab-waiter))
  (lock (sb-thread:make-mutex :name "clun-sab-waiter"))
  (cvar (sb-thread:make-waitqueue :name "clun-sab-waiter"))
  (status :waiting))                    ; :waiting | :ok | :not-equal | :timed-out

(defstruct (shared-data-block (:constructor %make-shared-data-block)
                              (:conc-name sdb-))
  (bytes nil)                           ; (simple-array (unsigned-byte 8) (*))
  (lock (sb-thread:make-mutex :name "clun-sab-data"))
  (waiters-lock (sb-thread:make-mutex :name "clun-sab-waiters"))
  (waiters (make-hash-table :test 'eql))) ; index → list of sab-waiter

(defstruct (js-shared-array-buffer (:include js-object (class :shared-array-buffer))
                                   (:constructor %make-js-shared-array-buffer))
  (block nil))                          ; shared-data-block

;;; --- buffer protocol (ArrayBuffer | SharedArrayBuffer) ----------------------

(defun data-buffer-p (b)
  (or (js-array-buffer-p b) (js-shared-array-buffer-p b)))

(defun data-buffer-shared-p (b)
  (js-shared-array-buffer-p b))

(defun data-buffer-bytes (b)
  (cond ((js-array-buffer-p b) (js-array-buffer-bytes b))
        ((js-shared-array-buffer-p b)
         (let ((blk (js-shared-array-buffer-block b)))
           (and blk (sdb-bytes blk))))
        (t nil)))

(defun data-buffer-byte-length (b)
  (let ((bytes (data-buffer-bytes b)))
    (if bytes (length bytes) 0)))

(defun data-buffer-detached-p (b)
  "SharedArrayBuffer is never detached; ArrayBuffer detaches when bytes → NIL."
  (cond ((js-array-buffer-p b) (null (js-array-buffer-bytes b)))
        ((js-shared-array-buffer-p b) nil)
        (t t)))

(defun data-buffer-block (b)
  "Shared data block for a SAB, else NIL."
  (when (js-shared-array-buffer-p b)
    (js-shared-array-buffer-block b)))

;;; Rebind TypedArray/DataView helpers to the shared buffer protocol.
(defun array-buffer-detached-p (b)
  (data-buffer-detached-p b))

(defun ta-bytes (ta)
  (data-buffer-bytes (js-typed-array-abuffer ta)))

;;; --- SharedArrayBuffer construction -----------------------------------------

(defun make-shared-data-block (length)
  (when (or (> length +max-byte-length+) (> length (floor (sb-ext:dynamic-space-size) 2)))
    (throw-range-error "SharedArrayBuffer allocation failed: requested length exceeds the maximum"))
  (let ((bytes (handler-case
                   (make-array length :element-type '(unsigned-byte 8) :initial-element 0)
                 (storage-condition ()
                   (throw-range-error "SharedArrayBuffer allocation failed")))))
    (%make-shared-data-block :bytes bytes)))

(defun make-shared-array-buffer (length &optional proto)
  (let ((b (%make-js-shared-array-buffer
            :proto (or proto (intrinsic :shared-array-buffer-prototype))
            :class :shared-array-buffer
            :block (make-shared-data-block length))))
    b))

(defun wrap-shared-array-buffer (block &optional proto)
  "Realm-local SAB wrapper for an existing shared data block (postMessage share)."
  (%make-js-shared-array-buffer
   :proto (or proto (intrinsic :shared-array-buffer-prototype))
   :class :shared-array-buffer
   :block block))

(defun %bootstrap-shared-array-buffer ()
  (let ((sabp (js-make-object (intrinsic :object-prototype) :object)))
    (setf (realm-intrinsic *realm* :shared-array-buffer-prototype) sabp)
    (install-getter sabp "byteLength"
      (lambda (this args) (declare (ignore args))
        (unless (js-shared-array-buffer-p this)
          (throw-type-error "not a SharedArrayBuffer"))
        (coerce (data-buffer-byte-length this) 'double-float)))
    (install-method sabp "slice" 2
      (lambda (this args)
        (unless (js-shared-array-buffer-p this)
          (throw-type-error "not a SharedArrayBuffer"))
        (let* ((bytes (data-buffer-bytes this))
               (len (length bytes))
               (start (ta-clamp-index (arg args 0) len 0))
               (end (if (js-undefined-p (arg args 1)) len (ta-clamp-index (arg args 1) len len)))
               (new-len (max 0 (- end start)))
               (nb (make-shared-array-buffer new-len)))
          (replace (data-buffer-bytes nb) bytes :start2 start :end2 (+ start new-len))
          nb)))
    (obj-set-desc sabp (well-known :to-string-tag)
                  (data-pd "SharedArrayBuffer" :writable nil :enumerable nil :configurable t))
    (let ((ctor (make-constructor "SharedArrayBuffer" 1
                  (lambda (this args) (declare (ignore this args))
                    (throw-type-error "Constructor SharedArrayBuffer requires 'new'"))
                  :prototype sabp
                  :construct-fn
                  (lambda (args nt)
                    (make-shared-array-buffer
                     (to-index (arg args 0))
                     (nt-prototype nt (intrinsic :shared-array-buffer-prototype)))))))
      (setf (realm-intrinsic *realm* :shared-array-buffer-constructor) ctor))
    sabp))

;;; --- Atomics ----------------------------------------------------------------

(defun %atomics-validate-integer-ta (ta)
  (unless (js-typed-array-p ta)
    (throw-type-error "Atomics requires an integer TypedArray"))
  (when (member (js-typed-array-kind ta) '(:float32 :float64 :uint8-clamped))
    (throw-type-error "Atomics does not support this TypedArray kind"))
  (when (ta-detached-p ta)
    (throw-type-error "Atomics on detached buffer"))
  ta)

(defun %atomics-index (ta index-arg)
  (let* ((i (to-index index-arg))
         (len (ta-length ta)))
    (when (>= i len)
      (throw-range-error "Atomics index out of bounds"))
    i))

(defun %atomics-with-block (ta thunk)
  "Run THUNK under the SAB data lock when the view is shared; else run unlocked.
THUNK receives (bytes byte-offset kind)."
  (let* ((buf (js-typed-array-abuffer ta))
         (bytes (data-buffer-bytes buf))
         (off (js-typed-array-byte-offset ta))
         (kind (js-typed-array-kind ta))
         (block (data-buffer-block buf)))
    (if block
        (sb-thread:with-mutex ((sdb-lock block))
          (sb-thread:barrier (:memory)
            (funcall thunk bytes off kind)))
        (funcall thunk bytes off kind))))

(defun %atomics-load (bytes base kind index)
  (read-element bytes (+ base (ta-elt-offset-raw kind index)) kind t))

(defun ta-elt-offset-raw (kind i)
  (* i (kind-size kind)))

(defun %atomics-store (bytes base kind index value)
  (write-element bytes (+ base (ta-elt-offset-raw kind index)) kind value t)
  value)

(defun %atomics-binop (ta index-arg value-arg op)
  (%atomics-validate-integer-ta ta)
  (let* ((i (%atomics-index ta index-arg))
         (bigintp (kind-bigint-p (js-typed-array-kind ta)))
         (val (if bigintp (to-bigint value-arg) (to-number value-arg))))
    (%atomics-with-block
     ta
     (lambda (bytes base kind)
       (let* ((old (%atomics-load bytes base kind i))
              (new (ecase op
                     (:add (if bigintp (+ old val) (coerce (+ old val) 'double-float)))
                     (:sub (if bigintp (- old val) (coerce (- old val) 'double-float)))
                     (:and (if bigintp (logand old val)
                               (coerce (logand (%num->wrapint old) (%num->wrapint val)) 'double-float)))
                     (:or (if bigintp (logior old val)
                              (coerce (logior (%num->wrapint old) (%num->wrapint val)) 'double-float)))
                     (:xor (if bigintp (logxor old val)
                               (coerce (logxor (%num->wrapint old) (%num->wrapint val)) 'double-float))))))
         ;; Store through write-element so wrapping/signedness matches the kind.
         (%atomics-store bytes base kind i new)
         old)))))

(defun %atomics-store-op (ta index-arg value-arg)
  (%atomics-validate-integer-ta ta)
  (let* ((i (%atomics-index ta index-arg))
         (bigintp (kind-bigint-p (js-typed-array-kind ta)))
         (val (if bigintp (to-bigint value-arg) (to-number value-arg))))
    (%atomics-with-block
     ta
     (lambda (bytes base kind)
       (%atomics-store bytes base kind i val)
       val))))

(defun %atomics-load-op (ta index-arg)
  (%atomics-validate-integer-ta ta)
  (let ((i (%atomics-index ta index-arg)))
    (%atomics-with-block
     ta
     (lambda (bytes base kind)
       (%atomics-load bytes base kind i)))))

(defun %atomics-exchange (ta index-arg value-arg)
  (%atomics-validate-integer-ta ta)
  (let* ((i (%atomics-index ta index-arg))
         (bigintp (kind-bigint-p (js-typed-array-kind ta)))
         (val (if bigintp (to-bigint value-arg) (to-number value-arg))))
    (%atomics-with-block
     ta
     (lambda (bytes base kind)
       (let ((old (%atomics-load bytes base kind i)))
         (%atomics-store bytes base kind i val)
         old)))))

(defun %atomics-compare-exchange (ta index-arg expected-arg replacement-arg)
  (%atomics-validate-integer-ta ta)
  (let* ((i (%atomics-index ta index-arg))
         (bigintp (kind-bigint-p (js-typed-array-kind ta)))
         (expected (if bigintp (to-bigint expected-arg) (to-number expected-arg)))
         (replacement (if bigintp (to-bigint replacement-arg) (to-number replacement-arg))))
    (%atomics-with-block
     ta
     (lambda (bytes base kind)
       (let ((old (%atomics-load bytes base kind i)))
         (when (if bigintp (= old expected)
                   (and (not (js-nan-p old)) (not (js-nan-p expected)) (= old expected)))
           (%atomics-store bytes base kind i replacement))
         old)))))

(defun %atomics-is-lock-free (size-arg)
  (let ((n (to-number size-arg)))
    (js-boolean (and (not (js-nan-p n))
                     (member (truncate n) '(1 2 4 8) :test #'=)))))

;;; --- wait / notify ----------------------------------------------------------

(defun %atomics-register-waiter (block index waiter)
  (sb-thread:with-mutex ((sdb-waiters-lock block))
    (push waiter (gethash index (sdb-waiters block)))))

(defun %atomics-unregister-waiter (block index waiter)
  (sb-thread:with-mutex ((sdb-waiters-lock block))
    (setf (gethash index (sdb-waiters block))
          (remove waiter (gethash index (sdb-waiters block)) :count 1))
    (unless (gethash index (sdb-waiters block))
      (remhash index (sdb-waiters block)))))

(defun %atomics-wait (ta index-arg value-arg timeout-arg)
  "Atomics.wait — only on SharedArrayBuffer-backed Int32/BigInt64 views."
  (%atomics-validate-integer-ta ta)
  (unless (member (js-typed-array-kind ta) '(:int32 :bigint64))
    (throw-type-error "Atomics.wait requires Int32Array or BigInt64Array"))
  (let ((buf (js-typed-array-abuffer ta)))
    (unless (js-shared-array-buffer-p buf)
      (throw-type-error "Atomics.wait requires a SharedArrayBuffer")))
  (let* ((i (%atomics-index ta index-arg))
         (bigintp (kind-bigint-p (js-typed-array-kind ta)))
         (expected (if bigintp (to-bigint value-arg) (to-number value-arg)))
         (timeout-ms
           (if (js-undefined-p timeout-arg)
               nil
               (let ((t0 (to-number timeout-arg)))
                 (cond ((js-nan-p t0) nil)
                       ((js-infinite-p t0) (if (minusp t0) 0 nil))
                       ((minusp t0) 0)
                       (t t0)))))
         (block (data-buffer-block (js-typed-array-abuffer ta)))
         (waiter (%make-sab-waiter)))
    ;; Check expected under the data lock; if match, register waiter before unlock.
    (let ((matched
            (sb-thread:with-mutex ((sdb-lock block))
              (sb-thread:barrier (:memory)
                (let* ((bytes (sdb-bytes block))
                       (base (js-typed-array-byte-offset ta))
                       (kind (js-typed-array-kind ta))
                       (old (%atomics-load bytes base kind i)))
                  (if (if bigintp (= old expected)
                          (and (not (js-nan-p old)) (not (js-nan-p expected)) (= old expected)))
                      (progn (%atomics-register-waiter block i waiter) t)
                      nil))))))
      (unless matched
        (return-from %atomics-wait "not-equal"))
      (when (and timeout-ms (zerop timeout-ms))
        (%atomics-unregister-waiter block i waiter)
        (return-from %atomics-wait "timed-out"))
      ;; Optional timeout notifier.
      (let ((timer-thread nil))
        (when timeout-ms
          (setf timer-thread
                (sb-thread:make-thread
                 (lambda ()
                   (sleep (/ timeout-ms 1000d0))
                   (sb-thread:with-mutex ((sab-waiter-lock waiter))
                     (when (eq (sab-waiter-status waiter) :waiting)
                       (setf (sab-waiter-status waiter) :timed-out)
                       (sb-thread:condition-notify (sab-waiter-cvar waiter)))))
                 :name "clun-atomics-wait-timeout")))
        (unwind-protect
             (progn
               (sb-thread:with-mutex ((sab-waiter-lock waiter))
                 (loop while (eq (sab-waiter-status waiter) :waiting)
                       do (sb-thread:condition-wait (sab-waiter-cvar waiter)
                                                    (sab-waiter-lock waiter))))
               (%atomics-unregister-waiter block i waiter)
               (ecase (sab-waiter-status waiter)
                 (:ok "ok")
                 (:timed-out "timed-out")
                 (:not-equal "not-equal")
                 (:waiting "ok")))      ; should not happen
          (when timer-thread
            (ignore-errors (sb-thread:terminate-thread timer-thread))
            (ignore-errors (sb-thread:join-thread timer-thread :default nil))))))))

(defun %atomics-notify (ta index-arg count-arg)
  (%atomics-validate-integer-ta ta)
  (unless (js-shared-array-buffer-p (js-typed-array-abuffer ta))
    (throw-type-error "Atomics.notify requires a SharedArrayBuffer"))
  (let* ((i (%atomics-index ta index-arg))
         (count (if (js-undefined-p count-arg)
                    most-positive-fixnum
                    (let ((n (to-integer-or-infinity count-arg)))
                      (cond ((js-infinite-p n) most-positive-fixnum)
                            ((minusp n) 0)
                            (t (truncate n))))))
         (block (data-buffer-block (js-typed-array-abuffer ta)))
         (woken 0)
         (to-wake '()))
    (sb-thread:with-mutex ((sdb-waiters-lock block))
      (let ((list (gethash i (sdb-waiters block))))
        (loop while (and list (< woken count))
              do (let ((w (pop list)))
                   (push w to-wake)
                   (incf woken)))
        (setf (gethash i (sdb-waiters block)) list)
        (unless list (remhash i (sdb-waiters block)))))
    (dolist (w to-wake)
      (sb-thread:with-mutex ((sab-waiter-lock w))
        (when (eq (sab-waiter-status w) :waiting)
          (setf (sab-waiter-status w) :ok)
          (sb-thread:condition-notify (sab-waiter-cvar w)))))
    (coerce woken 'double-float)))

(defun %bootstrap-atomics ()
  (let ((a (new-object)))
    (flet ((m (name arity fn)
             (install-method a name arity fn)))
      (m "add" 3 (lambda (this args) (declare (ignore this))
                   (%atomics-binop (arg args 0) (arg args 1) (arg args 2) :add)))
      (m "sub" 3 (lambda (this args) (declare (ignore this))
                   (%atomics-binop (arg args 0) (arg args 1) (arg args 2) :sub)))
      (m "and" 3 (lambda (this args) (declare (ignore this))
                   (%atomics-binop (arg args 0) (arg args 1) (arg args 2) :and)))
      (m "or" 3 (lambda (this args) (declare (ignore this))
                  (%atomics-binop (arg args 0) (arg args 1) (arg args 2) :or)))
      (m "xor" 3 (lambda (this args) (declare (ignore this))
                   (%atomics-binop (arg args 0) (arg args 1) (arg args 2) :xor)))
      (m "load" 2 (lambda (this args) (declare (ignore this))
                    (%atomics-load-op (arg args 0) (arg args 1))))
      (m "store" 3 (lambda (this args) (declare (ignore this))
                     (%atomics-store-op (arg args 0) (arg args 1) (arg args 2))))
      (m "exchange" 3 (lambda (this args) (declare (ignore this))
                        (%atomics-exchange (arg args 0) (arg args 1) (arg args 2))))
      (m "compareExchange" 4
         (lambda (this args) (declare (ignore this))
           (%atomics-compare-exchange (arg args 0) (arg args 1) (arg args 2) (arg args 3))))
      (m "isLockFree" 1 (lambda (this args) (declare (ignore this))
                          (%atomics-is-lock-free (arg args 0))))
      (m "wait" 4 (lambda (this args) (declare (ignore this))
                    (%atomics-wait (arg args 0) (arg args 1) (arg args 2) (arg args 3))))
      (m "notify" 3 (lambda (this args) (declare (ignore this))
                      (%atomics-notify (arg args 0) (arg args 1) (arg args 2))))
      (m "pause" 0 (lambda (this args) (declare (ignore this args))
                     (sb-thread:thread-yield)
                     +undefined+)))
    (obj-set-desc a (well-known :to-string-tag)
                  (data-pd "Atomics" :writable nil :enumerable nil :configurable t))
    (setf (realm-intrinsic *realm* :atomics) a)
    a))

(defun %bootstrap-shared-memory ()
  (%bootstrap-shared-array-buffer)
  (%bootstrap-atomics))
