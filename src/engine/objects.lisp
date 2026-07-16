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

;; Inlined: these run on nearly every property read/write (Phase 25 profile: pd-set-p ~2.9% +
;; data-descriptor-p ~2.3% self, un-inlined). Bodies are trivial, so inlining is a free win.
(declaim (inline pd-set-p data-descriptor-p accessor-descriptor-p generic-descriptor-p))
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
  "If KEY is a canonical array-index string (the plain decimal form of an integer in [0, 2^32-2], no
leading zeros — \"0\", \"1\", … \"4294967294\"), return that integer, else NIL. Hot on every enumeration
+ array write (Phase 25 profile: 26% of splay); a direct digit scan + integer parse fails fast on a
non-numeric key (the common case) and avoids the old float parse + `princ-to-string` round-trip."
  (when (stringp key)
    (let ((len (length key)))
      (declare (type fixnum len))
      (when (<= 1 len 10)                                  ; 2^32-2 = 4294967294 has 10 digits
        (let ((c0 (char key 0)))
          (cond
            ((char= c0 #\0) (and (= len 1) 0))             ; only "0" (no leading zeros)
            ((char<= #\1 c0 #\9)
             (let ((n 0))
               (declare (type (integer 0 99999999999) n))
               (dotimes (i len)
                 (let ((c (char key i)))
                   (if (char<= #\0 c #\9)
                       (setf n (+ (* n 10) (- (char-code c) 48)))
                       (return-from array-index-key-p nil))))
               (and (<= n #xFFFFFFFE) n)))
            (t nil)))))))

;;; --- shapes / hidden classes (Phase 25) ------------------------------------
;;; A pshape is a node in a transition tree keyed by the property-ADD sequence: two ptables that
;;; added the same string keys in the same order share ONE pshape, and each key sits at the same
;;; slot in both. That shared identity is what an inline cache keys on (%ic-read): a cache validated
;;; for "shape S ⟹ key K is the own data property at slot N" stays valid for every object of shape
;;; S, because S uniquely determines the key layout. The pshape holds ONLY the add-transition edges;
;;; the keys + descriptors still live in the ptable, so descriptor identity/mutation, enumeration
;;; order, and attribute handling are all unchanged. A ptable whose layout leaves the append-only
;;; regime (a delete) drops to shape = NIL and simply stops hitting caches — never wrong, just slow.

(defstruct (pshape (:constructor %make-pshape) (:copier nil))
  (transitions nil))            ; nil | equal hash-table: added-key -> child pshape

(defparameter *root-pshape* (%make-pshape)
  "The shape of an empty (freshly created) shaped object.")

(defparameter *pshape-cap* 200000
  "Hard bound on the global shape transition tree. The tree is process-global and monotonic (never
freed), so a long-lived process — a `Clun.serve` server, or the 40k-file conformance runner sharing
ONE image — must not be allowed to grow it without limit (dynamic-key / dictionary objects mint a
pshape per distinct key layout; unbounded, that exhausts the heap). Once the cap is reached,
`pshape-transition` returns NIL and the object simply runs dict-mode (shape = NIL): correct, just
uncached. Real programs use orders of magnitude fewer shapes (the benchmarks < 20), so this never
costs IC benefit in practice; it is purely a memory backstop.")
(defvar *pshape-count* 0 "Total pshapes minted (monotonic); bounded by *pshape-cap*.")

(defun pshape-transition (sh key)
  "The (interned, hence shared) child shape reached by ADDING KEY at shape SH, or NIL if the global
cap is reached (caller then drops the object to dict-mode)."
  (let ((tr (pshape-transitions sh)))
    (cond
      ((and tr (gethash key tr)))                          ; existing edge (shared)
      ((>= *pshape-count* *pshape-cap*) nil)               ; capped: drop to dict-mode
      (t (unless tr (setf tr (make-hash-table :test 'equal) (pshape-transitions sh) tr))
         (incf *pshape-count*)
         (setf (gethash key tr) (%make-pshape))))))

;;; --- property table: order-preserving, lazy hash index (§3.1) --------------
;;; Kept out of a hash-table-per-object for small objects (Appendix C.12); an equal
;;; hash index is built lazily once an object accumulates many keys.

(defconstant +ptable-index-threshold+ 16)

(defstruct (ptable (:constructor %make-ptable) (:copier nil))
  ;; keys+descs are parallel SIMPLE-VECTORs (fast svref on the read-IC hit path + the scan), grown by
  ;; doubling; COUNT is the live prefix length. Phase 25 m6 replaced adjustable/fill-pointer vectors,
  ;; whose "hairy" bounds-checked aref was ~15% of the post-m5 profile.
  (keys (make-array 4 :initial-element nil) :type simple-vector)
  (descs (make-array 4 :initial-element nil) :type simple-vector)
  (count 0 :type fixnum)       ; number of live entries in keys/descs (a prefix)
  (index nil)                  ; equal hash-table key -> position, or nil
  (shape *root-pshape*))       ; pshape (append-only key layout) or nil (dropped out; ICs miss)

(defun ptable-pos (pt key)
  ;; Small objects linear-scan (no equal hash yet). A hand-written scan with a direct STRING= (string
  ;; keys) / EQ (symbol keys) over a SIMPLE-VECTOR avoids POSITION, the generic EQUAL dispatch, and the
  ;; adjustable-array hairy aref. Semantically identical: a property key is a string or a js-symbol;
  ;; equal on two strings is string=, on two structs is eq, and a string never equals a symbol.
  (let ((idx (ptable-index pt)))
    (if idx
        (gethash key idx)
        (let ((keys (ptable-keys pt)) (n (ptable-count pt)))
          (declare (type simple-vector keys) (type fixnum n))
          (if (stringp key)
              (dotimes (i n nil)
                (let ((k (svref keys i)))
                  (when (and (stringp k) (string= (the string key) (the string k))) (return i))))
              (dotimes (i n nil)
                (when (eq key (svref keys i)) (return i))))))))

(defun ptable-lookup (pt key)
  (let ((pos (ptable-pos pt key)))
    (and pos (svref (ptable-descs pt) pos))))

(defun ptable-put (pt key desc)
  (let ((pos (ptable-pos pt key)))
    (cond
      (pos (setf (svref (ptable-descs pt) pos) desc))
      (t (let ((n (ptable-count pt)) (cap (length (ptable-keys pt))))
           (when (= n cap)                                    ; grow both vectors by doubling
             (let ((nk (make-array (* 2 cap) :initial-element nil))
                   (nd (make-array (* 2 cap) :initial-element nil)))
               (replace nk (ptable-keys pt))
               (replace nd (ptable-descs pt))
               (setf (ptable-keys pt) nk (ptable-descs pt) nd)))
           (setf (svref (ptable-keys pt) n) key
                 (svref (ptable-descs pt) n) desc
                 (ptable-count pt) (1+ n))
           (let ((sh (ptable-shape pt)))                      ; a new own key transitions the shape
             (when sh (setf (ptable-shape pt) (pshape-transition sh key))))
           (let ((idx (ptable-index pt)))
             (cond (idx (setf (gethash key idx) n))
                   ((>= (1+ n) +ptable-index-threshold+) (ptable-build-index pt)))))))))

(defun ptable-build-index (pt)
  (let ((idx (make-hash-table :test 'equal)) (keys (ptable-keys pt)) (n (ptable-count pt)))
    (dotimes (i n) (setf (gethash (svref keys i) idx) i))
    (setf (ptable-index pt) idx)))

(defun ptable-remove (pt key)
  "Remove KEY, shifting later entries down (preserves order)."
  (let ((pos (ptable-pos pt key)))
    (when pos
      (let ((k (ptable-keys pt)) (d (ptable-descs pt)) (n (ptable-count pt)))
        (loop for i from pos below (1- n)
              do (setf (svref k i) (svref k (1+ i)) (svref d i) (svref d (1+ i))))
        (setf (svref k (1- n)) nil (svref d (1- n)) nil            ; clear the vacated slot (don't retain)
              (ptable-count pt) (1- n)
              (ptable-shape pt) nil)                               ; layout left the tree: ICs miss
        (when (ptable-index pt) (ptable-build-index pt))))))       ; reindex

(defun ptable-key-list (pt)
  (let ((keys (ptable-keys pt)) (acc '()))
    (dotimes (i (ptable-count pt)) (push (svref keys i) acc))
    (nreverse acc)))

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
            (t (let ((idx (array-index-key-p k)))       ; parse index once; sort by the parsed value
                 (if idx (push (cons idx k) indices) (push k strings))))))
    (append (mapcar #'cdr (sort indices #'< :key #'car))   ; indices ascending
            (nreverse strings)                              ; then strings in insertion order
            (nreverse symbols))))                           ; then symbols in insertion order

;;; --- object creation --------------------------------------------------------

(defstruct (js-immutable-prototype-object
             (:include js-object)
             (:constructor %make-js-immutable-prototype-object))
  "An Immutable Prototype Exotic Object (§10.4.7). All internal methods except
[[SetPrototypeOf]] remain ordinary.")

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
(defmethod jm-set-prototype-of ((o js-immutable-prototype-object) v)
  ;; SameValue with the current prototype succeeds; every actual mutation is
  ;; rejected without changing ordinary extensibility or property semantics.
  (eq v (js-object-proto o)))
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
  (cond
    ((data-descriptor-p own)
     (cond ((eq (pd-writable own) nil) nil)         ; non-writable data -> fail
           ((not (js-object-p receiver)) nil)
           (t (let ((existing (jm-get-own-property receiver key)))
                (cond
                  (existing
                   (cond ((accessor-descriptor-p existing) nil)
                         ((eq (pd-writable existing) nil) nil)
                         ;; Fast path (Phase 25): a plain assignment (o EQ receiver) to an existing own
                         ;; writable DATA property — mutate the live stored descriptor's value in
                         ;; place, skipping validate-and-apply + a fresh descriptor (the bulk of the
                         ;; write profile). Guards: (eq o receiver) confines this to a direct set, so a
                         ;; Reflect.set(plain, i, v, exoticReceiver) with a distinct receiver (e.g. a
                         ;; typed array, whose [[GetOwnProperty]] SYNTHESIZES a throwaway descriptor)
                         ;; always takes the full path; js-array is excluded because its
                         ;; [[DefineOwnProperty]] maintains the length/index invariants. A typed array
                         ;; can never BE receiver here when o EQ receiver (it overrides [[Set]], so
                         ;; ordinary-set-with-own-desc is never entered with o = a typed array).
                         ((and (eq o receiver) (not (js-array-p receiver)))
                          (setf (pd-value existing) value) t)
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
         ;; NaN guard first: never feed a NaN to `=` (traps outside the float mask).
         (cond ((or (js-nan-p x) (js-nan-p y)) (and (js-nan-p x) (js-nan-p y)))
               ((and (js-neg-zero-p x) (not (js-neg-zero-p y))) nil)
               ((and (js-neg-zero-p y) (not (js-neg-zero-p x))) nil)
               (t (= x y))))
        ((and (stringp x) (stringp y)) (string= x y))
        (t (eq x y))))

(defun js-same-value-zero (x y)
  (cond ((and (js-number-p x) (js-number-p y))
         (cond ((or (js-nan-p x) (js-nan-p y)) (and (js-nan-p x) (js-nan-p y)))
               (t (= x y))))
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
(defun js-delete (o key throw)
  (let ((ok (jm-delete o key)))
    (when (and (not ok) throw)
      (throw-type-error (format nil "cannot delete property ~a" key)))
    ok))
(defun has-property (o key) (jm-has-property o key))
(defun has-own-property (o key) (and (jm-get-own-property o key) t))
(defun create-data-property (o key value)
  ;; Fast path (Phase 25 m7): a brand-NEW property on an extensible ORDINARY object (class :object ⟹
  ;; the ordinary [[DefineOwnProperty]], not the js-array / js-typed-array exotic) is just a store of a
  ;; default data descriptor — skip validate-and-apply, which for a new key merely re-defaults the
  ;; already-complete descriptor into a SECOND one. Only genuinely-new keys qualify (an existing key
  ;; may be non-configurable / an accessor, so it must take the full spec path).
  (if (and (eq (js-object-class o) :object)
           (js-object-extensible o)
           (not (obj-own-desc o key)))
      (progn (obj-set-desc o key (data-pd value)) t)
      (jm-define-own-property o key (data-pd value))))
(defun create-data-property-or-throw (o key value)
  (unless (create-data-property o key value)
    (throw-type-error (format nil "cannot create property ~a" key))))
(defun define-property-or-throw (o key desc)
  (unless (jm-define-own-property o key desc)
    (throw-type-error (format nil "cannot define property ~a" key))))

(defun set-integrity-level (o level)
  "Set O's integrity LEVEL through its internal methods. LEVEL is :SEALED or :FROZEN."
  (unless (jm-prevent-extensions o)
    (return-from set-integrity-level nil))
  (let ((keys (jm-own-property-keys o)))
    (ecase level
      (:sealed
       (dolist (key keys)
         (define-property-or-throw o key (make-prop-desc :configurable nil))))
      (:frozen
       (dolist (key keys)
         (let ((current (jm-get-own-property o key)))
           (when current
             (define-property-or-throw
              o key
              (if (accessor-descriptor-p current)
                  (make-prop-desc :configurable nil)
                  (make-prop-desc :writable nil :configurable nil)))))))))
  t)

(defun test-integrity-level (o level)
  "Return true when O has the requested :SEALED or :FROZEN integrity level."
  (when (jm-is-extensible o)
    (return-from test-integrity-level nil))
  (every (lambda (key)
           (let ((current (jm-get-own-property o key)))
             (or (null current)
                 (and (not (eq (pd-configurable current) t))
                      (or (eq level :sealed)
                          (accessor-descriptor-p current)
                          (not (eq (pd-writable current) t)))))))
         (jm-own-property-keys o)))

(defun get-method (v key)
  (let ((f (js-getv v key)))
    (cond ((js-nullish-p f) +undefined+)
          ((not (callable-p f)) (throw-type-error "value is not callable"))
          (t f))))

;;; --- inline cache: monomorphic data-property read, own + depth-1 proto (Phase 25) ---
;;; IC is a per-site cache cell. A hit reads the descriptor at a cached slot directly, skipping the
;;; key scan AND the [[Get]] generic dispatch. Two cached forms, both keyed on the receiver's ptable
;;; shape (EQ):
;;;   • OWN   (holder = NIL): KEY is the receiver's own data property at SLOT.
;;;   • PROTO (holder = P, depth 1): the receiver has no own KEY; its DIRECT [[Prototype]] P holds
;;;     KEY as an own data property at SLOT. Extra hit guards: receiver's direct proto is still EQ P,
;;;     and P's shape is still EQ the cached HSHAPE.
;;; Soundness. EQ receiver-shape ⟹ identical own-key layout ⟹ (own) KEY at SLOT, or (proto) the
;;; receiver still has NO own KEY. Depth 1 ⟹ no intermediate prototype can shadow. The direct-proto
;;; EQ check catches setPrototypeOf on the receiver (which does NOT change the ptable shape); the
;;; HSHAPE check catches an add/delete on P. Value changes, data↔accessor redefines, and freeze are
;;; all caught by RE-READING the live descriptor every hit and guarding on DATA-DESCRIPTOR-P. Any
;;; other case (own/proto accessor, deeper chain, absent, dict-mode receiver, primitive) falls back
;;; to the full [[Get]] and is not cached.
(defstruct (ic (:constructor %make-ic) (:copier nil))
  (shape nil) (slot 0 :type fixnum) (holder nil) (hshape nil))

(defun %ic-read (obj key ic)
  (if (js-object-p obj)
      (let* ((pt (js-object-props obj))
             (sh (and pt (ptable-shape pt))))
        (if (and sh (eq sh (ic-shape ic)))
            (let ((holder (ic-holder ic)))
              (if holder
                  ;; proto entry: revalidate the direct-proto link + holder layout
                  (let ((hp (js-object-props holder)))
                    (if (and (eq (js-object-proto obj) holder) hp (eq (ptable-shape hp) (ic-hshape ic)))
                        (let ((d (svref (ptable-descs hp) (ic-slot ic))))
                          (if (data-descriptor-p d) (pd-value d) (jm-get obj key obj)))
                        (%ic-refill obj key ic pt sh)))
                  ;; own entry
                  (let ((d (svref (ptable-descs pt) (ic-slot ic))))
                    (if (data-descriptor-p d) (pd-value d) (jm-get obj key obj)))))
            (%ic-refill obj key ic pt sh)))
      (js-getv obj key)))

(defun %ic-refill (obj key ic pt sh)
  "IC miss: resolve KEY and, for an own or depth-1-proto own-data hit on a shaped receiver, refill IC.
Always returns the correct [[Get]] value."
  (let ((own-pos (and sh (ptable-pos pt key))))
    (cond
      (own-pos
       (let ((d (svref (ptable-descs pt) own-pos)))
         (cond ((data-descriptor-p d)
                (setf (ic-shape ic) sh (ic-slot ic) own-pos (ic-holder ic) nil)
                (pd-value d))
               (t (jm-get obj key obj)))))                 ; own accessor: slow, do not cache
      (sh                                                   ; shaped receiver, no own KEY: try depth-1 proto
       (let ((proto (js-object-proto obj)))
         (if (js-object-p proto)
             (let* ((pp (js-object-props proto))
                    (psh (and pp (ptable-shape pp)))
                    (ppos (and psh (ptable-pos pp key))))
               (if ppos
                   (let ((d (svref (ptable-descs pp) ppos)))
                     (cond ((data-descriptor-p d)
                            (setf (ic-shape ic) sh (ic-slot ic) ppos
                                  (ic-holder ic) proto (ic-hshape ic) psh)
                            (pd-value d))
                           (t (jm-get obj key obj))))       ; proto accessor: slow, do not cache
                   (jm-get obj key obj)))                   ; not own-data on the direct proto: slow
             (jm-get obj key obj))))                        ; null proto
      (t (jm-get obj key obj)))))                           ; dict-mode receiver: slow

;;; --- inline cache: monomorphic own-data-property write, UPDATE-only (Phase 25 m7) ---
;;; For `obj.key = value` (a static assignment target — always o == receiver). A hit stores VALUE into
;;; the cached slot's descriptor IN PLACE, skipping ordinary-set's key scan + generic dispatch. The IC
;;; caches ONLY on an UPDATE to an existing own writable data property (the write left the shape
;;; UNCHANGED); it NEVER caches a CREATE (the write transitioned the shape) and does no extra work on
;;; that miss — this is what avoids the create-heavy regression that killed the first (m4) write IC.
;;; Sound: EQ shape ⟹ KEY is the own property at SLOT; the hit RE-CHECKS data + writable=t on the live
;;; descriptor (the shape encodes layout, not attributes); a plain assignment target is o == receiver.
(defun %ic-write (obj key value ic strict)
  (if (js-object-p obj)
      (let* ((pt (js-object-props obj))
             (sh (and pt (ptable-shape pt))))
        (if (and sh (eq sh (ic-shape ic)))
            (let ((d (svref (ptable-descs pt) (ic-slot ic))))
              (if (and (data-descriptor-p d) (eq (pd-writable d) t))
                  (progn (setf (pd-value d) value) t)
                  (js-set obj key value strict)))               ; became non-writable/accessor: slow
            (let ((ok (js-set obj key value strict)))
              ;; refill ONLY for an update: the shape is unchanged ⟹ KEY already existed (a create
              ;; transitions the shape, and gets NO refill scan — no create penalty).
              (when (and sh (eq (ptable-shape pt) sh))
                (let ((pos (ptable-pos pt key)))
                  (when pos
                    (let ((d (svref (ptable-descs pt) pos)))
                      (when (and (data-descriptor-p d) (eq (pd-writable d) t))
                        (setf (ic-shape ic) sh (ic-slot ic) pos (ic-holder ic) nil))))))
              ok)))
      (js-set (to-object obj) key value strict)))

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
  (function-kind :ordinary)    ; :ordinary :method :arrow :generator :async :async-generator or class kind
  (constructable t)
  source-text                  ; exact source slice for Function.prototype.toString
  (fname "")
  (param-count 0))

(defstruct (js-native-function (:include js-object (class :function)) (:constructor %make-native-function))
  fn                           ; (lambda (this args) -> js-value)
  construct-fn                 ; (lambda (args new-target) -> js-object) or NIL
  (function-kind :ordinary)
  (fname "")
  (param-count 0))

;; Bound functions are their own callable kind. Keeping the target and bound
;; state explicit is required for [[Construct]], OrdinaryHasInstance, and the
;; absence of an own `prototype` property; a native closure cannot model those
;; observables without leaking special cases throughout the engine.
(defstruct (js-bound-function (:include js-object (class :function))
                              (:constructor %make-bound-function))
  target
  (bound-this +undefined+)
  (bound-args '())
  (fname "")
  (param-count 0))

(declaim (inline callable-p))
(defun callable-p (v)
  (or (js-function-p v) (js-native-function-p v) (js-bound-function-p v)))
(defun constructor-p (v)
  (cond ((js-function-p v) (js-function-constructable v))
        ((js-native-function-p v) (and (js-native-function-construct-fn v) t))
        ((js-bound-function-p v) (constructor-p (js-bound-function-target v)))
        (t nil)))

(defgeneric jm-call (f this args)
  (:documentation "[[Call]] — behavior installed in functions.lisp for each kind."))
(defgeneric jm-construct (f args new-target))

(defvar +uninitialized-this+ (make-symbol "UNINITIALIZED-THIS"))

(defstruct (derived-this-binding (:constructor make-derived-this-binding ()))
  (value +uninitialized-this+))

(defun get-this-binding (binding)
  "Return an ordinary this value or read a derived constructor's mutable binding."
  (if (derived-this-binding-p binding)
      (let ((value (derived-this-binding-value binding)))
        (if (eq value +uninitialized-this+)
            (throw-reference-error "must call super constructor before using 'this'")
            value))
      binding))

(defun bind-derived-this (binding value)
  "Initialize a derived constructor's this binding exactly once."
  (unless (derived-this-binding-p binding)
    (throw-reference-error "super() is only valid in a derived constructor"))
  (unless (eq (derived-this-binding-value binding) +uninitialized-this+)
    (throw-reference-error "super constructor may only be called once"))
  (setf (derived-this-binding-value binding) value))

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
    ;; Arrays are dict-mode: their integer-index keys would churn the shape tree (one node per
    ;; length) for no benefit — element access is computed (`a[i]`), which bypasses the read IC.
    (let ((pt (js-object-props a))) (when pt (setf (ptable-shape pt) nil)))
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
         ;; Fast path (Phase 25 m8): a NEW index (>= old-len, so — by the "every own index < length"
         ;; invariant — not already own) with a COMPLETE data descriptor (what create-data-property /
         ;; an array literal produces) on an extensible array. Store it directly + bump length, skipping
         ;; validate-and-apply: there is no current descriptor to reconcile and a complete data desc
         ;; needs no defaulting. Array-literal construction is splay's hot path (~33%: ten new-index
         ;; writes per [0..9]).
         ((and (>= index old-len)
               (js-object-extensible a)
               (data-descriptor-p desc)
               (pd-set-p (pd-value desc)) (pd-set-p (pd-writable desc))
               (pd-set-p (pd-enumerable desc)) (pd-set-p (pd-configurable desc)))
          (obj-set-desc a key desc)
          (setf (pd-value len-desc) (coerce (1+ index) 'double-float))
          t)
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
             (new-len (double->uint32 num)))
        ;; ToUint32(value) must equal ToNumber(value); NaN (e.g. undefined) fails.
        ;; NaN-safe: never feed NaN to `=` (it would trap outside the float mask).
        (unless (and (not (js-nan-p num)) (= (coerce new-len 'double-float) num))
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
                   for k = (int->string i)
                   when (obj-own-desc a k)
                   do (unless (jm-delete a k)
                        (setf (pd-value new-desc) (coerce (1+ i) 'double-float))
                        (ordinary-define-own-property a "length" new-desc)
                        (return-from array-set-length nil)))
             (ordinary-define-own-property a "length" new-desc)))))))

(defun array-of (proto elements)
  "Build a dense array from a CL list of js-values."
  (let ((a (js-make-array proto (length elements))) (i 0))
    (dolist (e elements) (create-data-property a (int->string i) e) (incf i))  ; cached index keys (m9)
    a))
