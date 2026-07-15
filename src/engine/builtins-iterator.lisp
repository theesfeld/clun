;;;; builtins-iterator.lisp — the iterator protocol (PLAN.md Phase 04, §27).
;;;; %IteratorPrototype% and the concrete Array/String/Map/Set iterator prototypes.
;;;; A concrete iterator is a js-iterator struct carrying a CL step closure; the
;;;; shared `next` on its prototype drives it. Array.prototype and String.prototype
;;;; get their @@iterator / keys / values / entries here (their base methods live in
;;;; realm-builtins.lisp; this file adds the iteration surface).

(in-package :clun.engine)

(defstruct (js-iterator (:include js-object (class :object)) (:constructor %make-js-iterator))
  (step nil)                     ; CL closure: () -> (values value done-p)
  (done nil))

(defun make-iter-result (value done)
  (let ((o (new-object)))
    (create-data-property o "value" value)
    (create-data-property o "done" (js-boolean done))
    o))

(defun make-iterator (proto-key step)
  "A concrete iterator over the CL STEP closure, prototype = intrinsic PROTO-KEY."
  (%make-js-iterator :proto (intrinsic proto-key) :step step))

(defun %iterator-next (this)
  (unless (js-iterator-p this) (throw-type-error "next called on a non-iterator"))
  (if (js-iterator-done this)
      (make-iter-result +undefined+ t)
      (multiple-value-bind (value done) (funcall (js-iterator-step this))
        (when done (setf (js-iterator-done this) t))
        (make-iter-result (if done +undefined+ value) done))))

(defun make-list-iterator (proto-key items)
  "An iterator yielding each of the CL list ITEMS in turn."
  (let ((cell items))
    (make-iterator proto-key
                   (lambda () (if cell (values (pop cell) nil) (values +undefined+ t))))))

(defun %array-iterator-step (o index-box kind)
  "One step over array-like O, observing its current length on every step."
  (let ((i (aref index-box 0)) (len (length-of-array-like o)))
    (if (>= i len) (values +undefined+ t)
        (progn (setf (aref index-box 0) (1+ i))
               (values (ecase kind
                         (:key (coerce i 'double-float))
                         (:value (js-getv o (princ-to-string i)))
                         (:entry (new-array (list (coerce i 'double-float)
                                                  (js-getv o (princ-to-string i))))))
                       nil)))))

(defun make-array-iterator (o kind)
  (let ((index-box (make-array 1 :initial-element 0)))
    (make-iterator :array-iterator-prototype
                   (lambda () (%array-iterator-step o index-box kind)))))

(defun string->code-points (s)
  "List of one-code-point strings (surrogate pairs kept whole)."
  (let ((out '()) (i 0) (n (length s)))
    (loop while (< i n) do
      (let ((c (char-code (char s i))))
        (if (and (high-surrogate-p c) (< (1+ i) n) (low-surrogate-p (char-code (char s (1+ i)))))
            (progn (push (subseq s i (+ i 2)) out) (incf i 2))
            (progn (push (string (char s i)) out) (incf i)))))
    (nreverse out)))

(defun %bootstrap-iterator ()
  ;; %IteratorPrototype%: @@iterator returns this.
  (let ((itp (js-make-object (intrinsic :object-prototype))))
    (setf (realm-intrinsic *realm* :iterator-prototype) itp)
    (obj-set-desc itp (well-known :iterator)
                  (data-pd (make-native-function "[Symbol.iterator]" 0
                             (lambda (this args) (declare (ignore args)) this))
                           :writable t :enumerable nil :configurable t))
    ;; concrete iterator prototypes: next + @@toStringTag
    (flet ((mk (key tag)
             (let ((p (js-make-object itp)))
               (setf (realm-intrinsic *realm* key) p)
               (install-method p "next" 0 (lambda (this args) (declare (ignore args)) (%iterator-next this)))
               (obj-set-desc p (well-known :to-string-tag)
                             (data-pd tag :writable nil :enumerable nil :configurable t))
               p)))
      (mk :array-iterator-prototype "Array Iterator")
      (mk :string-iterator-prototype "String Iterator")
      (mk :map-iterator-prototype "Map Iterator")
      (mk :set-iterator-prototype "Set Iterator")))
  ;; Array.prototype iteration surface
  (let ((ap (intrinsic :array-prototype)))
    (install-method ap "keys" 0 (lambda (this args) (declare (ignore args)) (make-array-iterator (to-object this) :key)))
    (install-method ap "entries" 0 (lambda (this args) (declare (ignore args)) (make-array-iterator (to-object this) :entry)))
    (let ((values-fn (make-native-function "values" 0
                       (lambda (this args) (declare (ignore args)) (make-array-iterator (to-object this) :value)))))
      (obj-set-desc ap "values" (data-pd values-fn :writable t :enumerable nil :configurable t))
      (obj-set-desc ap (well-known :iterator) (data-pd values-fn :writable t :enumerable nil :configurable t))))
  ;; String.prototype[@@iterator] over code points
  (let ((sp (intrinsic :string-prototype)))
    (obj-set-desc sp (well-known :iterator)
                  (data-pd (make-native-function "[Symbol.iterator]" 0
                             (lambda (this args) (declare (ignore args))
                               (make-list-iterator :string-iterator-prototype
                                                   (string->code-points
                                                    (to-string (require-object-coercible this))))))
                           :writable t :enumerable nil :configurable t))))
