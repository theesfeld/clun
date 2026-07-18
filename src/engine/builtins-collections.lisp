;;;; builtins-collections.lisp — Map / Set / WeakMap / WeakSet (Phase 04, §24).
;;;; Keys use SameValueZero (−0 stored as +0, NaN matches NaN) — canonicalized into
;;;; an EQUAL hash index that keeps insertion order via a parallel entry vector.
;;;; Weak variants use SBCL weak-key hash-tables. Iteration is live (§24.1.5).

(in-package :clun.engine)

(defstruct (js-map (:include js-object (class :map)) (:constructor %make-js-map)) data)
(defstruct (js-set (:include js-object (class :set)) (:constructor %make-js-set)) data)
(defstruct (js-weakmap (:include js-object (class :weakmap)) (:constructor %make-js-weakmap)) table)
(defstruct (js-weakset (:include js-object (class :weakset)) (:constructor %make-js-weakset)) table)

(defstruct (mentry (:conc-name me-)) key value (deleted nil))
(defstruct (map-data (:conc-name md-))
  (index (make-hash-table :test 'equal))
  (order (make-array 8 :adjustable t :fill-pointer 0))
  (live 0))

(defun %svz-key (v)
  "Canonicalize V to an EQUAL-hashable SameValueZero key."
  (cond ((js-nan-p v) :%map-nan%)
        ((and (js-number-p v) (zerop v)) 0d0)
        (t v)))

(defun %svz-store (v) (if (and (js-number-p v) (js-neg-zero-p v)) 0d0 v))

(defun md-get-entry (md key)
  (let ((e (gethash (%svz-key key) (md-index md))))
    (and e (not (me-deleted e)) e)))

(defun md-set (md key value)
  (let ((e (md-get-entry md key)))
    (if e (setf (me-value e) value)
        (let ((ne (make-mentry :key (%svz-store key) :value value)))
          (setf (gethash (%svz-key key) (md-index md)) ne)
          (vector-push-extend ne (md-order md))
          (incf (md-live md))))))

(defun md-delete (md key)
  (let ((e (md-get-entry md key)))
    (when e (setf (me-deleted e) t) (remhash (%svz-key key) (md-index md)) (decf (md-live md)) t)))

(defun md-clear (md)
  (clrhash (md-index md))
  (loop for e across (md-order md) do (setf (me-deleted e) t))
  (setf (fill-pointer (md-order md)) 0 (md-live md) 0))

(defun md-foreach (md cb this-arg map-obj value-only)
  (let ((i 0))
    (loop while (< i (fill-pointer (md-order md)))
          do (let ((e (aref (md-order md) i)))
               (unless (me-deleted e)
                 (js-call cb this-arg (if value-only
                                          (list (me-value e) (me-value e) map-obj)
                                          (list (me-value e) (me-key e) map-obj))))
               (incf i)))))

(defun make-map-iterator (md kind proto-key)
  (let ((i 0))
    (make-iterator proto-key
      (lambda ()
        (loop
          (if (>= i (fill-pointer (md-order md))) (return (values +undefined+ t))
              (let ((e (aref (md-order md) i)))
                (incf i)
                (unless (me-deleted e)
                  (return (values (ecase kind
                                    (:key (me-key e)) (:value (me-value e))
                                    (:entry (new-array (list (me-key e) (me-value e)))))
                                  nil))))))))))

(defun proto-from-newtarget (nt default-key)
  (let ((p (and (js-object-p nt) (js-get nt "prototype"))))
    (if (js-object-p p) p (intrinsic default-key))))

(defun this-map-data (this)
  (if (js-map-p this) (js-map-data this) (throw-type-error "Method called on incompatible receiver")))
(defun this-set-data (this)
  (if (js-set-p this) (js-set-data this) (throw-type-error "Method called on incompatible receiver")))

(defun collection-add-all (obj iterable adder-name entries-p)
  "Drive ITERABLE through OBJ's named adder (used by collection constructors)."
  (unless (js-nullish-p iterable)
    (let ((adder (js-get obj adder-name)))
      (unless (callable-p adder)
        (throw-type-error (format nil "~a is not callable" adder-name)))
      (let ((record (get-iterator-record iterable)))
        (loop
          (multiple-value-bind (item done) (iterator-step-value record)
            (when done (return))
            (call-with-iterator-close-on-abrupt
             record
             (lambda ()
               (if entries-p
                   (progn
                     (unless (js-object-p item)
                       (throw-type-error "iterator value is not an entry object"))
                     (let ((key (js-getv item "0"))
                           (value (js-getv item "1")))
                       (js-call adder obj (list key value))))
                   (js-call adder obj (list item)))))))))))

;;; --- Map --------------------------------------------------------------------

(defun %bootstrap-map ()
  (let ((mp (js-make-object (intrinsic :object-prototype))))
    (setf (realm-intrinsic *realm* :map-prototype) mp)
    (obj-set-desc mp (well-known :to-string-tag) (data-pd "Map" :writable nil :enumerable nil :configurable t))
    (macrolet ((m (name arity &body body) `(install-method mp ,name ,arity ,@body)))
      (m "get" 1 (lambda (this args) (let ((e (md-get-entry (this-map-data this) (arg args 0)))) (if e (me-value e) +undefined+))))
      (m "set" 2 (lambda (this args) (md-set (this-map-data this) (arg args 0) (arg args 1)) this))
      (m "has" 1 (lambda (this args) (js-boolean (md-get-entry (this-map-data this) (arg args 0)))))
      (m "delete" 1 (lambda (this args) (js-boolean (md-delete (this-map-data this) (arg args 0)))))
      (m "clear" 0 (lambda (this args) (declare (ignore args)) (md-clear (this-map-data this)) +undefined+))
      (m "forEach" 1 (lambda (this args) (md-foreach (this-map-data this) (arg args 0) (arg args 1) this nil) +undefined+))
      (m "keys" 0 (lambda (this args) (declare (ignore args)) (make-map-iterator (this-map-data this) :key :map-iterator-prototype)))
      (m "values" 0 (lambda (this args) (declare (ignore args)) (make-map-iterator (this-map-data this) :value :map-iterator-prototype)))
      (m "entries" 0 (lambda (this args) (declare (ignore args)) (make-map-iterator (this-map-data this) :entry :map-iterator-prototype))))
    (obj-set-desc mp (well-known :iterator) (obj-own-desc mp "entries"))
    (install-getter mp "size" (lambda (this args) (declare (ignore args)) (coerce (md-live (this-map-data this)) 'double-float)))
    (let ((ctor (make-constructor "Map" 0
                  (lambda (this args) (declare (ignore this args)) (throw-type-error "Constructor Map requires 'new'"))
                  :prototype mp
                  :construct-fn (lambda (args nt)
                                  (let ((o (%make-js-map :proto (proto-from-newtarget nt :map-prototype) :data (make-map-data))))
                                    (collection-add-all o (arg args 0) "set" t)
                                    o)))))
      (setf (realm-intrinsic *realm* :map-constructor) ctor))))

;;; --- Set --------------------------------------------------------------------

;;; Set methods (ES2025 / Phase 37 m3): GetSetRecord + union/intersection/
;;; difference/symmetricDifference/isSubsetOf/isSupersetOf/isDisjointFrom.
;;; Results always use %Set.prototype% (never Symbol.species / subclass).
;;; Elements are written into [[SetData]] directly — Set.prototype.add is never
;;; invoked for construction of the result.

(defstruct (set-record (:conc-name sr-) (:constructor %make-set-record (object size has keys)))
  object size has keys)

(defun get-set-record (obj)
  "GetSetRecord (obj) — §24.2.1.2."
  (unless (js-object-p obj)
    (throw-type-error "Set method argument is not an object"))
  (let* ((raw-size (js-get obj "size"))
         (number-size (to-number raw-size)))
    (when (js-nan-p number-size)
      (throw-type-error "Set-like size is NaN"))
    (let ((int-size (to-integer-or-infinity number-size)))
      (when (< int-size 0d0)
        (throw-range-error "Set-like size is negative"))
      (let ((has (js-get obj "has")))
        (unless (callable-p has)
          (throw-type-error "Set-like has is not callable"))
        (let ((keys (js-get obj "keys")))
          (unless (callable-p keys)
            (throw-type-error "Set-like keys is not callable"))
          (%make-set-record obj int-size has keys))))))

(defun md-copy (md)
  "Shallow-copy map/set data: new index + order of non-deleted entries (compact)."
  (let ((out (make-map-data)))
    (loop for e across (md-order md)
          do (unless (me-deleted e)
               (md-set out (me-key e) (me-value e))))
    out))

(defun md-copy-with-empties (md)
  "Copy map/set data preserving deleted holes and order indices (for difference)."
  (let* ((n (fill-pointer (md-order md)))
         (out (make-map-data))
         (order (make-array n :adjustable t :fill-pointer n)))
    (setf (md-order out) order
          (md-live out) (md-live md))
    (dotimes (i n)
      (let* ((e (aref (md-order md) i))
             (ne (make-mentry :key (me-key e) :value (me-value e)
                              :deleted (me-deleted e))))
        (setf (aref order i) ne)
        (unless (me-deleted e)
          (setf (gethash (%svz-key (me-key e)) (md-index out)) ne))))
    out))

(defun md-mark-empty (md key)
  "Mark KEY empty in MD if present (difference / symmetricDifference)."
  (md-delete md key))

(defun md-setdata-size (md)
  "SetDataSize — count of non-empty entries."
  (md-live md))

(defun md-setdata-length (md)
  "Number of elements in [[SetData]] including empties."
  (fill-pointer (md-order md)))

(defun md-append-value (md value)
  "Append VALUE to set data without going through Set.prototype.add."
  (let ((k (%svz-store value)))
    (md-set md k k)))

(defun %set-from-data (md)
  "Ordinary Set instance with %Set.prototype% and the given [[SetData]]."
  (%make-js-set :proto (intrinsic :set-prototype) :data md))

(defun %set-call-has (record entry)
  "ToBoolean(Call(other.has, other, « entry »))."
  (js-truthy (js-call (sr-has record) (sr-object record) (list entry))))

(defun %set-keys-iterator (record)
  "GetIteratorFromMethod(other, other.keys)."
  (get-iterator-record (sr-object record) (sr-keys record)))

(defun %set-union (this other)
  (let* ((md (this-set-data this))
         (record (get-set-record other))
         (result (md-copy md))
         (keys-it (%set-keys-iterator record)))
    (loop
      (multiple-value-bind (value done) (iterator-step-value keys-it)
        (when done (return (%set-from-data result)))
        (let ((v (%svz-store value)))
          (unless (md-get-entry result v)
            (md-append-value result v)))))))

(defun %set-intersection (this other)
  (let* ((md (this-set-data this))
         (record (get-set-record other))
         (result (make-map-data)))
    (if (<= (md-setdata-size md) (sr-size record))
        (let ((this-size (md-setdata-length md))
              (index 0))
          (loop while (< index this-size)
                do (let ((e (aref (md-order md) index)))
                     (incf index)
                     (unless (me-deleted e)
                       (when (%set-call-has record (me-key e))
                         (unless (md-get-entry result (me-key e))
                           (md-append-value result (me-key e))))
                       (setf this-size (md-setdata-length md))))))
        (let ((keys-it (%set-keys-iterator record)))
          (loop
            (multiple-value-bind (value done) (iterator-step-value keys-it)
              (when done (return))
              (let ((v (%svz-store value)))
                (when (and (md-get-entry md v)
                           (not (md-get-entry result v)))
                  (md-append-value result v)))))))
    (%set-from-data result)))

(defun %set-difference (this other)
  (let* ((md (this-set-data this))
         (record (get-set-record other))
         ;; Copy after GetSetRecord so side effects on `this` are included.
         (result (md-copy-with-empties md)))
    (if (<= (md-setdata-size md) (sr-size record))
        (let ((this-size (md-setdata-length md))
              (index 0))
          (loop while (< index this-size)
                do (let ((e (aref (md-order result) index)))
                     (when (and e (not (me-deleted e)))
                       (when (%set-call-has record (me-key e))
                         (md-mark-empty result (me-key e))))
                     (incf index))))
        (let ((keys-it (%set-keys-iterator record)))
          (loop
            (multiple-value-bind (value done) (iterator-step-value keys-it)
              (when done (return))
              (let ((v (%svz-store value)))
                (when (md-get-entry result v)
                  (md-mark-empty result v)))))))
    (%set-from-data result)))

(defun %set-symmetric-difference (this other)
  (let* ((md (this-set-data this))
         (record (get-set-record other))
         (keys-it (%set-keys-iterator record))
         (result (md-copy md)))
    (loop
      (multiple-value-bind (value done) (iterator-step-value keys-it)
        (when done (return (%set-from-data result)))
        (let* ((v (%svz-store value))
               (already (and (md-get-entry result v) t))
               (in-this (and (md-get-entry md v) t)))
          (if in-this
              (when already (md-mark-empty result v))
              (unless already (md-append-value result v))))))))

(defun %set-is-subset-of (this other)
  (let* ((md (this-set-data this))
         (record (get-set-record other)))
    (when (> (md-setdata-size md) (sr-size record))
      (return-from %set-is-subset-of +false+))
    (let ((this-size (md-setdata-length md))
          (index 0))
      (loop while (< index this-size)
            do (let ((e (aref (md-order md) index)))
                 (incf index)
                 (unless (me-deleted e)
                   (unless (%set-call-has record (me-key e))
                     (return-from %set-is-subset-of +false+))
                   (setf this-size (md-setdata-length md)))))
      +true+)))

(defun %set-is-superset-of (this other)
  (let* ((md (this-set-data this))
         (record (get-set-record other)))
    (when (< (md-setdata-size md) (sr-size record))
      (return-from %set-is-superset-of +false+))
    (let ((keys-it (%set-keys-iterator record)))
      (loop
        (multiple-value-bind (value done) (iterator-step-value keys-it)
          (when done (return +true+))
          (unless (md-get-entry md value)
            (iterator-close keys-it)
            (return +false+)))))))

(defun %set-is-disjoint-from (this other)
  (let* ((md (this-set-data this))
         (record (get-set-record other)))
    (if (<= (md-setdata-size md) (sr-size record))
        (let ((this-size (md-setdata-length md))
              (index 0))
          (loop while (< index this-size)
                do (let ((e (aref (md-order md) index)))
                     (incf index)
                     (unless (me-deleted e)
                       (when (%set-call-has record (me-key e))
                         (return-from %set-is-disjoint-from +false+))
                       (setf this-size (md-setdata-length md)))))
          +true+)
        (let ((keys-it (%set-keys-iterator record)))
          (loop
            (multiple-value-bind (value done) (iterator-step-value keys-it)
              (when done (return +true+))
              (when (md-get-entry md value)
                (iterator-close keys-it)
                (return +false+))))))))

(defun %bootstrap-set ()
  (let ((sp (js-make-object (intrinsic :object-prototype))))
    (setf (realm-intrinsic *realm* :set-prototype) sp)
    (obj-set-desc sp (well-known :to-string-tag) (data-pd "Set" :writable nil :enumerable nil :configurable t))
    (macrolet ((m (name arity &body body) `(install-method sp ,name ,arity ,@body)))
      ;; A Set element is stored as both key and value; canonicalize -0 -> +0 in
      ;; BOTH slots so values()/entries()/forEach return +0 (SameValueZero, §24.2.3.1).
      (m "add" 1 (lambda (this args) (let ((k (%svz-store (arg args 0)))) (md-set (this-set-data this) k k)) this))
      (m "has" 1 (lambda (this args) (js-boolean (md-get-entry (this-set-data this) (arg args 0)))))
      (m "delete" 1 (lambda (this args) (js-boolean (md-delete (this-set-data this) (arg args 0)))))
      (m "clear" 0 (lambda (this args) (declare (ignore args)) (md-clear (this-set-data this)) +undefined+))
      (m "forEach" 1 (lambda (this args) (md-foreach (this-set-data this) (arg args 0) (arg args 1) this t) +undefined+))
      (m "values" 0 (lambda (this args) (declare (ignore args)) (make-map-iterator (this-set-data this) :value :set-iterator-prototype)))
      (m "entries" 0 (lambda (this args) (declare (ignore args)) (make-map-iterator (this-set-data this) :entry :set-iterator-prototype)))
      (m "union" 1 (lambda (this args) (%set-union this (arg args 0))))
      (m "intersection" 1 (lambda (this args) (%set-intersection this (arg args 0))))
      (m "difference" 1 (lambda (this args) (%set-difference this (arg args 0))))
      (m "symmetricDifference" 1 (lambda (this args) (%set-symmetric-difference this (arg args 0))))
      (m "isSubsetOf" 1 (lambda (this args) (%set-is-subset-of this (arg args 0))))
      (m "isSupersetOf" 1 (lambda (this args) (%set-is-superset-of this (arg args 0))))
      (m "isDisjointFrom" 1 (lambda (this args) (%set-is-disjoint-from this (arg args 0)))))
    (obj-set-desc sp "keys" (obj-own-desc sp "values"))
    (obj-set-desc sp (well-known :iterator) (obj-own-desc sp "values"))
    (install-getter sp "size" (lambda (this args) (declare (ignore args)) (coerce (md-live (this-set-data this)) 'double-float)))
    (let ((ctor (make-constructor "Set" 0
                  (lambda (this args) (declare (ignore this args)) (throw-type-error "Constructor Set requires 'new'"))
                  :prototype sp
                  :construct-fn (lambda (args nt)
                                  (let ((o (%make-js-set :proto (proto-from-newtarget nt :set-prototype) :data (make-map-data))))
                                    (collection-add-all o (arg args 0) "add" nil)
                                    o)))))
      (setf (realm-intrinsic *realm* :set-constructor) ctor))))

;;; --- WeakMap / WeakSet ------------------------------------------------------

(defun %weak-key (v)
  (if (js-object-p v) v (throw-type-error "Invalid value used as weak collection key")))

(defun %bootstrap-weakmap ()
  (let ((wp (js-make-object (intrinsic :object-prototype))))
    (setf (realm-intrinsic *realm* :weakmap-prototype) wp)
    (obj-set-desc wp (well-known :to-string-tag) (data-pd "WeakMap" :writable nil :enumerable nil :configurable t))
    (flet ((tbl (this) (if (js-weakmap-p this) (js-weakmap-table this) (throw-type-error "not a WeakMap"))))
      (install-method wp "get" 1 (lambda (this args) (let ((k (arg args 0))) (if (js-object-p k) (gethash k (tbl this) +undefined+) +undefined+))))
      (install-method wp "set" 2 (lambda (this args) (setf (gethash (%weak-key (arg args 0)) (tbl this)) (arg args 1)) this))
      (install-method wp "has" 1 (lambda (this args) (let ((k (arg args 0))) (js-boolean (and (js-object-p k) (nth-value 1 (gethash k (tbl this))))))))
      (install-method wp "delete" 1 (lambda (this args) (let ((k (arg args 0))) (js-boolean (and (js-object-p k) (remhash k (tbl this))))))))
    (let ((ctor (make-constructor "WeakMap" 0
                  (lambda (this args) (declare (ignore this args)) (throw-type-error "Constructor WeakMap requires 'new'"))
                  :prototype wp
                  :construct-fn (lambda (args nt)
                                  (let ((o (%make-js-weakmap :proto (proto-from-newtarget nt :weakmap-prototype)
                                                             :table (make-hash-table :test 'eq :weakness :key))))
                                    (collection-add-all o (arg args 0) "set" t)
                                    o)))))
      (setf (realm-intrinsic *realm* :weakmap-constructor) ctor))))

(defun %bootstrap-weakset ()
  (let ((wp (js-make-object (intrinsic :object-prototype))))
    (setf (realm-intrinsic *realm* :weakset-prototype) wp)
    (obj-set-desc wp (well-known :to-string-tag) (data-pd "WeakSet" :writable nil :enumerable nil :configurable t))
    (flet ((tbl (this) (if (js-weakset-p this) (js-weakset-table this) (throw-type-error "not a WeakSet"))))
      (install-method wp "add" 1 (lambda (this args) (setf (gethash (%weak-key (arg args 0)) (tbl this)) t) this))
      (install-method wp "has" 1 (lambda (this args) (let ((k (arg args 0))) (js-boolean (and (js-object-p k) (nth-value 1 (gethash k (tbl this))))))))
      (install-method wp "delete" 1 (lambda (this args) (let ((k (arg args 0))) (js-boolean (and (js-object-p k) (remhash k (tbl this))))))))
    (let ((ctor (make-constructor "WeakSet" 0
                  (lambda (this args) (declare (ignore this args)) (throw-type-error "Constructor WeakSet requires 'new'"))
                  :prototype wp
                  :construct-fn (lambda (args nt)
                                  (let ((o (%make-js-weakset :proto (proto-from-newtarget nt :weakset-prototype)
                                                             :table (make-hash-table :test 'eq :weakness :key))))
                                    (collection-add-all o (arg args 0) "add" nil)
                                    o)))))
      (setf (realm-intrinsic *realm* :weakset-constructor) ctor))))
