;;;; objects.lisp — the object kernel (PLAN.md Phase 03, §3.1). Property descriptors,
;;;; order-preserving property storage, the spec internal methods as CLOS generic
;;;; functions dispatching on the js-object struct type (Proxy-shaped), the Ordinary*
;;;; defaults, the user-facing abstract operations, and the Array exotic.

(in-package :clun.engine)

;;; --- property descriptors (§6.2.6) -----------------------------------------
;;; :unset distinguishes an ABSENT field from a present false — needed by
;;; ValidateAndApplyPropertyDescriptor (§10.1.6.3).

(defstruct (prop-desc (:constructor make-prop-desc) (:conc-name pd-) (:copier copy-pd))
  (value :unset) (get :unset) (set :unset)
  (writable :unset) (enumerable :unset) (configurable :unset))

(defun pd-set-p (x) (not (eq x :unset)))
(defun data-descriptor-p (d) (or (pd-set-p (pd-value d)) (pd-set-p (pd-writable d))))
(defun accessor-descriptor-p (d) (or (pd-set-p (pd-get d)) (pd-set-p (pd-set d))))
(defun generic-descriptor-p (d) (and (not (data-descriptor-p d)) (not (accessor-descriptor-p d))))

(defun data-pd (value &key (writable t) (enumerable t) (configurable t))
  (make-prop-desc :value value :writable writable :enumerable enumerable :configurable configurable))
(defun accessor-pd (getter setter &key (enumerable t) (configurable t))
  (make-prop-desc :get getter :set setter :enumerable enumerable :configurable configurable))

;;; --- property keys ----------------------------------------------------------
;;; A property key is a CL string (string key) or a js-symbol. Array-index keys are
;;; the canonical decimal strings of integers in [0, 2^32-2].

(defun array-index-key-p (key)
  "If KEY is a canonical array index string, return its integer value, else NIL."
  (and (stringp key) (plusp (length key))
       (let ((n (with-js-floats (js-string->number key))))
         (and (js-finite-p n)
              (let ((i (floor n)))
                (and (= (coerce i 'double-float) n) (<= 0 i #xFFFFFFFE)
                     (string= key (princ-to-string i)) i))))))

;;; --- property table: order-preserving, lazy hash index (§3.1) --------------
;;; Kept out of a hash-table-per-object for small objects (Appendix C.12); an equal
;;; hash index is built lazily once an object accumulates many keys.

(defconstant +ptable-index-threshold+ 16)

(defstruct (ptable (:constructor %make-ptable) (:copier nil))
  (keys (make-array 4 :adjustable t :fill-pointer 0))
  (descs (make-array 4 :adjustable t :fill-pointer 0))
  (index nil))                 ; equal hash-table key -> position, or nil

(defun ptable-pos (pt key)
  (let ((idx (ptable-index pt)))
    (if idx
        (gethash key idx)
        (position key (ptable-keys pt) :test #'equal))))

(defun ptable-lookup (pt key)
  (let ((pos (ptable-pos pt key)))
    (and pos (aref (ptable-descs pt) pos))))

(defun ptable-put (pt key desc)
  (let ((pos (ptable-pos pt key)))
    (cond
      (pos (setf (aref (ptable-descs pt) pos) desc))
      (t (vector-push-extend key (ptable-keys pt))
         (vector-push-extend desc (ptable-descs pt))
         (let ((idx (ptable-index pt)))
           (cond (idx (setf (gethash key idx) (1- (fill-pointer (ptable-keys pt)))))
                 ((>= (fill-pointer (ptable-keys pt)) +ptable-index-threshold+)
                  (ptable-build-index pt))))))))

(defun ptable-build-index (pt)
  (let ((idx (make-hash-table :test 'equal)))
    (dotimes (i (fill-pointer (ptable-keys pt)))
      (setf (gethash (aref (ptable-keys pt) i) idx) i))
    (setf (ptable-index pt) idx)))

(defun ptable-remove (pt key)
  "Remove KEY, shifting later entries down (preserves order)."
  (let ((pos (ptable-pos pt key)))
    (when pos
      (let ((k (ptable-keys pt)) (d (ptable-descs pt)))
        (loop for i from pos below (1- (fill-pointer k))
              do (setf (aref k i) (aref k (1+ i)) (aref d i) (aref d (1+ i))))
        (decf (fill-pointer k)) (decf (fill-pointer d))
        (when (ptable-index pt) (ptable-build-index pt))))))       ; reindex

(defun ptable-key-list (pt)
  (coerce (subseq (ptable-keys pt) 0 (fill-pointer (ptable-keys pt))) 'list))

;;; object-level property access over the (possibly nil) props slot
(defun obj-own-desc (o key)
  (let ((pt (js-object-props o))) (and pt (ptable-lookup pt key))))

(defun obj-set-desc (o key desc)
  (let ((pt (js-object-props o)))
    (unless pt (setf pt (%make-ptable) (js-object-props o) pt))
    (ptable-put pt key desc)))

(defun obj-remove-key (o key)
  (let ((pt (js-object-props o))) (when pt (ptable-remove pt key))))

(defun obj-own-keys (o)
  (let ((pt (js-object-props o))) (if pt (ptable-key-list pt) '())))

;;; --- ordered OwnPropertyKeys (§10.1.11.1): indices asc, strings, symbols ----

(defun ordinary-own-property-keys (o)
  (let ((indices '()) (strings '()) (symbols '()))
    (dolist (k (obj-own-keys o))
      (cond ((js-symbol-p k) (push k symbols))
            ((array-index-key-p k) (push k indices))
            (t (push k strings))))
    (append (sort (nreverse indices) #'< :key #'array-index-key-p)
            (nreverse strings)
            (nreverse symbols))))

;;; --- object creation --------------------------------------------------------

(defun js-make-object (&optional (proto +null+) (class :object))
  (make-js-object :proto proto :class class))

;;; --- internal methods: generic functions dispatched on struct type ----------

(defgeneric jm-get-prototype-of (o))
(defgeneric jm-set-prototype-of (o v))
(defgeneric jm-is-extensible (o))
(defgeneric jm-prevent-extensions (o))
(defgeneric jm-get-own-property (o key))
(defgeneric jm-define-own-property (o key desc))
(defgeneric jm-has-property (o key))
(defgeneric jm-get (o key receiver))
(defgeneric jm-set (o key value receiver))
(defgeneric jm-delete (o key))
(defgeneric jm-own-property-keys (o))

;;; Ordinary implementations (§10.1) — the default on js-object.

(defmethod jm-get-prototype-of ((o js-object)) (js-object-proto o))
(defmethod jm-set-prototype-of ((o js-object) v)
  (cond ((eq v (js-object-proto o)) t)
        ((not (js-object-extensible o)) nil)
        ;; cycle check
        ((loop for p = v then (js-object-proto p)
               while (js-object-p p)
               when (eq p o) do (return t)
               finally (return nil))
         nil)
        (t (setf (js-object-proto o) v) t)))
(defmethod jm-is-extensible ((o js-object)) (js-object-extensible o))
(defmethod jm-prevent-extensions ((o js-object)) (setf (js-object-extensible o) nil) t)

(defmethod jm-get-own-property ((o js-object) key)
  (obj-own-desc o key))

(defmethod jm-has-property ((o js-object) key)
  (loop for obj = o then (jm-get-prototype-of obj)
        while (js-object-p obj)
        when (jm-get-own-property obj key) do (return t)
        finally (return nil)))

(defmethod jm-get ((o js-object) key receiver)
  (let ((desc (jm-get-own-property o key)))
    (cond
      ((null desc)
       (let ((parent (jm-get-prototype-of o)))
         (if (js-object-p parent) (jm-get parent key receiver) +undefined+)))
      ((data-descriptor-p desc) (pd-value desc))
      (t (let ((getter (pd-get desc)))
           (if (or (eq getter :unset) (js-undefined-p getter)) +undefined+
               (js-call getter receiver '())))))))

(defmethod jm-set ((o js-object) key value receiver)
  (ordinary-set o key value receiver))

(defun ordinary-set (o key value receiver)
  (let ((own (jm-get-own-property o key)))
    (cond
      ((null own)
       (let ((parent (jm-get-prototype-of o)))
         (if (js-object-p parent)
             (jm-set parent key value receiver)
             (ordinary-set-with-own-desc o key value receiver (data-pd +undefined+)))))
      (t (ordinary-set-with-own-desc o key value receiver own)))))

(defun ordinary-set-with-own-desc (o key value receiver own)
  (declare (ignore o))
  (cond
    ((data-descriptor-p own)
     (cond ((eq (pd-writable own) nil) nil)         ; non-writable data -> fail
           ((not (js-object-p receiver)) nil)
           (t (let ((existing (jm-get-own-property receiver key)))
                (cond
                  (existing
                   (cond ((accessor-descriptor-p existing) nil)
                         ((eq (pd-writable existing) nil) nil)
                         (t (jm-define-own-property receiver key (make-prop-desc :value value)))))
                  (t (create-data-property receiver key value)))))))
    (t (let ((setter (pd-set own)))                 ; accessor
         (if (or (eq setter :unset) (js-undefined-p setter)) nil
             (progn (js-call setter receiver (list value)) t))))))

(defmethod jm-delete ((o js-object) key)
  (let ((desc (jm-get-own-property o key)))
    (cond ((null desc) t)
          ((eq (pd-configurable desc) t) (obj-remove-key o key) t)
          (t nil))))

(defmethod jm-own-property-keys ((o js-object)) (ordinary-own-property-keys o))

(defmethod jm-define-own-property ((o js-object) key desc)
  (ordinary-define-own-property o key desc))

(defun ordinary-define-own-property (o key desc)
  (let ((current (jm-get-own-property o key))
        (extensible (js-object-extensible o)))
    (validate-and-apply-property-descriptor o key extensible desc current)))

(defun validate-and-apply-property-descriptor (o key extensible desc current)
  "§10.1.6.3. O may be NIL (validation only)."
  (cond
    ((null current)
     (cond
       ((not extensible) nil)
       (t (when o
            (obj-set-desc o key
                          (if (accessor-descriptor-p desc)
                              (accessor-pd (defaulted (pd-get desc) +undefined+)
                                           (defaulted (pd-set desc) +undefined+)
                                           :enumerable (defaulted (pd-enumerable desc) nil)
                                           :configurable (defaulted (pd-configurable desc) nil))
                              (data-pd (defaulted (pd-value desc) +undefined+)
                                       :writable (defaulted (pd-writable desc) nil)
                                       :enumerable (defaulted (pd-enumerable desc) nil)
                                       :configurable (defaulted (pd-configurable desc) nil)))))
          t)))
    (t
     (block validate
       ;; every field absent -> ok
       (when (and (eq (pd-value desc) :unset) (eq (pd-get desc) :unset) (eq (pd-set desc) :unset)
                  (eq (pd-writable desc) :unset) (eq (pd-enumerable desc) :unset)
                  (eq (pd-configurable desc) :unset))
         (return-from validate t))
       (when (eq (pd-configurable current) nil)
         (when (eq (pd-configurable desc) t) (return-from validate nil))
         (when (and (pd-set-p (pd-enumerable desc))
                    (not (eq (pd-enumerable desc) (pd-enumerable current))))
           (return-from validate nil)))
       (cond
         ((generic-descriptor-p desc))               ; nothing more to validate
         ((not (eq (data-descriptor-p current) (data-descriptor-p desc)))
          (when (eq (pd-configurable current) nil) (return-from validate nil)))
         ((and (data-descriptor-p current) (data-descriptor-p desc))
          (when (eq (pd-configurable current) nil)
            (when (and (eq (pd-writable current) nil) (eq (pd-writable desc) t))
              (return-from validate nil))
            (when (and (eq (pd-writable current) nil) (pd-set-p (pd-value desc))
                       (not (js-same-value (pd-value desc) (pd-value current))))
              (return-from validate nil))))
         (t                                           ; both accessor
          (when (eq (pd-configurable current) nil)
            (when (and (pd-set-p (pd-set desc)) (not (eq (pd-set desc) (pd-set current))))
              (return-from validate nil))
            (when (and (pd-set-p (pd-get desc)) (not (eq (pd-get desc) (pd-get current))))
              (return-from validate nil)))))
       (when o (apply-descriptor-fields o key current desc))
       t))))

(defun apply-descriptor-fields (o key current desc)
  "Merge DESC's set fields into CURRENT (converting data<->accessor as needed)."
  (let ((new (cond
               ((and (accessor-descriptor-p desc) (data-descriptor-p current))
                (accessor-pd +undefined+ +undefined+
                             :enumerable (pd-enumerable current) :configurable (pd-configurable current)))
               ((and (data-descriptor-p desc) (accessor-descriptor-p current))
                (data-pd +undefined+ :writable nil
                         :enumerable (pd-enumerable current) :configurable (pd-configurable current)))
               (t (copy-pd current)))))
    (when (pd-set-p (pd-value desc)) (setf (pd-value new) (pd-value desc)))
    (when (pd-set-p (pd-get desc)) (setf (pd-get new) (pd-get desc)))
    (when (pd-set-p (pd-set desc)) (setf (pd-set new) (pd-set desc)))
    (when (pd-set-p (pd-writable desc)) (setf (pd-writable new) (pd-writable desc)))
    (when (pd-set-p (pd-enumerable desc)) (setf (pd-enumerable new) (pd-enumerable desc)))
    (when (pd-set-p (pd-configurable desc)) (setf (pd-configurable new) (pd-configurable desc)))
    ;; normalize: a data descriptor loses get/set, accessor loses value/writable
    (if (accessor-descriptor-p new)
        (setf (pd-value new) :unset (pd-writable new) :unset)
        (progn (unless (pd-set-p (pd-value new)) (setf (pd-value new) +undefined+))
               (unless (pd-set-p (pd-writable new)) (setf (pd-writable new) nil))
               (setf (pd-get new) :unset (pd-set new) :unset)))
    (obj-set-desc o key new)))

(defun defaulted (x default) (if (eq x :unset) default x))

;;; --- SameValue / SameValueZero (§7.2.11/12) ---------------------------------

(defun js-same-value (x y)
  (cond ((and (js-number-p x) (js-number-p y))
         (cond ((and (js-nan-p x) (js-nan-p y)) t)
               ((and (js-neg-zero-p x) (not (js-neg-zero-p y))) nil)
               ((and (js-neg-zero-p y) (not (js-neg-zero-p x))) nil)
               (t (= x y))))
        ((and (stringp x) (stringp y)) (string= x y))
        (t (eq x y))))

(defun js-same-value-zero (x y)
  (cond ((and (js-number-p x) (js-number-p y))
         (cond ((and (js-nan-p x) (js-nan-p y)) t) (t (= x y))))
        ((and (stringp x) (stringp y)) (string= x y))
        (t (eq x y))))

;;; --- user-facing abstract operations (§7.3) --------------------------------

(defun js-get (o key) (jm-get o key o))
(defun js-getv (v key)
  (if (js-object-p v) (jm-get v key v) (jm-get (to-object v) key v)))
(defun js-set (o key value throw)
  (let ((ok (jm-set o key value o)))
    (when (and (not ok) throw) (throw-type-error (format nil "cannot set property ~a" key)))
    ok))
(defun has-property (o key) (jm-has-property o key))
(defun has-own-property (o key) (and (jm-get-own-property o key) t))
(defun create-data-property (o key value)
  (jm-define-own-property o key (data-pd value)))
(defun create-data-property-or-throw (o key value)
  (unless (create-data-property o key value)
    (throw-type-error (format nil "cannot create property ~a" key))))
(defun define-property-or-throw (o key desc)
  (unless (jm-define-own-property o key desc)
    (throw-type-error (format nil "cannot define property ~a" key))))
(defun get-method (v key)
  (let ((f (js-getv v key)))
    (cond ((js-nullish-p f) +undefined+)
          ((not (callable-p f)) (throw-type-error "value is not callable"))
          (t f))))

;;; --- callables --------------------------------------------------------------
;;; Two callable object kinds: user js-function (compiled from JS) and js-native-
;;; function (a wrapped CL lambda for built-ins). Both :include js-object.

(defstruct (js-function (:include js-object (class :function)) (:constructor %make-js-function))
  compiled-body                ; (lambda (fn this args new-target) -> js-value)
  env                          ; captured lexical environment
  params                       ; parameter binding info (from the emitter)
  (strict nil)
  (this-mode :normal)          ; :normal :strict :lexical(arrow)
  (home-object +undefined+)    ; for super
  (constructable t)
  (fname "")
  (param-count 0))

(defstruct (js-native-function (:include js-object (class :function)) (:constructor %make-native-function))
  fn                           ; (lambda (this args) -> js-value)
  construct-fn                 ; (lambda (args new-target) -> js-object) or NIL
  (fname "")
  (param-count 0))

(declaim (inline callable-p constructor-p))
(defun callable-p (v) (or (js-function-p v) (js-native-function-p v)))
(defun constructor-p (v)
  (cond ((js-function-p v) (js-function-constructable v))
        ((js-native-function-p v) (and (js-native-function-construct-fn v) t))
        (t nil)))

(defgeneric jm-call (f this args)
  (:documentation "[[Call]] — behavior installed in functions.lisp for each kind."))
(defgeneric jm-construct (f args new-target))

(defun js-call (f this args)
  (unless (callable-p f) (throw-type-error "value is not a function"))
  (jm-call f this args))
(defun js-construct (f args &optional (new-target f))
  (unless (constructor-p f) (throw-type-error "value is not a constructor"))
  (jm-construct f args new-target))

;;; --- ToObject / ToPropertyKey (need the realm; filled by realm.lisp hooks) --

(defvar *to-object-hook* nil "Installed by realm.lisp: (value) -> js-object wrapper.")
(defun to-object (v)
  (cond ((js-object-p v) v)
        ((js-nullish-p v) (throw-type-error "cannot convert undefined or null to object"))
        (*to-object-hook* (funcall *to-object-hook* v))
        (t (throw-type-error "cannot convert to object (realm not initialized)"))))

(defun to-property-key (v)
  (let ((key (to-primitive v :string)))
    (if (js-symbol-p key) key (to-string key))))

;;; --- Array exotic (§10.4.2) -------------------------------------------------
;;; Elements are stored as ordinary index properties; only [[DefineOwnProperty]] is
;;; overridden to maintain the length/index invariants. (A dense backing vector is a
;;; Phase 25 optimization behind this same protocol.)

(defstruct (js-array (:include js-object (class :array)) (:constructor %make-js-array)))

(defun js-make-array (proto &optional (length 0))
  (let ((a (%make-js-array :proto proto)))
    (obj-set-desc a "length" (data-pd (coerce length 'double-float)
                                      :writable t :enumerable nil :configurable nil))
    a))

(defun array-length (a)
  (let ((d (obj-own-desc a "length"))) (if d (floor (pd-value d)) 0)))

(defmethod jm-define-own-property ((a js-array) key desc)
  (cond
    ((and (stringp key) (string= key "length")) (array-set-length a desc))
    ((array-index-key-p key)
     (let* ((index (array-index-key-p key))
            (len-desc (obj-own-desc a "length"))
            (old-len (floor (pd-value len-desc))))
       (cond
         ((and (>= index old-len) (eq (pd-writable len-desc) nil)) nil)
         (t (let ((ok (ordinary-define-own-property a key desc)))
              (cond ((not ok) nil)
                    (t (when (>= index old-len)
                         (setf (pd-value len-desc) (coerce (1+ index) 'double-float)))
                       t)))))))
    (t (ordinary-define-own-property a key desc))))

(defun array-set-length (a desc)
  (if (not (pd-set-p (pd-value desc)))
      (ordinary-define-own-property a "length" desc)
      (let* ((num (to-number (pd-value desc)))
             (new-len (double->uint32 (pd-value desc))))
        (unless (= (coerce new-len 'double-float) num)
          (throw-range-error "invalid array length"))
        (let* ((len-desc (obj-own-desc a "length"))
               (old-len (floor (pd-value len-desc)))
               (new-desc (copy-pd desc)))
          (setf (pd-value new-desc) (coerce new-len 'double-float))
          (cond
            ((>= new-len old-len) (ordinary-define-own-property a "length" new-desc))
            ((eq (pd-writable len-desc) nil) nil)
            (t
             ;; delete indices [new-len, old-len) in descending order
             (loop for i from (1- old-len) downto new-len
                   for k = (princ-to-string i)
                   when (obj-own-desc a k)
                   do (unless (jm-delete a k)
                        (setf (pd-value new-desc) (coerce (1+ i) 'double-float))
                        (ordinary-define-own-property a "length" new-desc)
                        (return-from array-set-length nil)))
             (ordinary-define-own-property a "length" new-desc)))))))

(defun array-of (proto elements)
  "Build a dense array from a CL list of js-values."
  (let ((a (js-make-array proto (length elements))) (i 0))
    (dolist (e elements) (create-data-property a (princ-to-string i) e) (incf i))
    a))
