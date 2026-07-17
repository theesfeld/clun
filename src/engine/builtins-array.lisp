;;;; builtins-array.lisp — Array.prototype breadth (ES2017) + Array statics
;;;; (PLAN.md Phase 04, §23.1). Generic over array-likes via the object API; a
;;;; stable merge sort for Array.prototype.sort. Extends the Phase 03 Array set.

(in-package :clun.engine)

(declaim (inline %aidx))
(defun %aidx (i) (princ-to-string i))
(defun %alen (o) (length-of-array-like o))
(defun %aget (o i) (js-getv o (%aidx i)))
(defun %aset (o i v) (js-set o (%aidx i) v t))
(defun %ahas (o i) (has-property o (%aidx i)))
(defun %adel (o i) (jm-delete o (%aidx i)))
(defun %aset-len (o n) (js-set o "length" (coerce n 'double-float) t))

(defun %array-species-new (n) (js-make-array (intrinsic :array-prototype) n))

(defconstant +max-array-length+ #xffffffff)

(defun %array-copy-new (length)
  "ArrayCreate for the copy-by-change methods."
  (when (> length +max-array-length+)
    (throw-range-error "invalid array length"))
  (js-make-array (intrinsic :array-prototype) length))

(defun %array-to-reversed (this)
  (let* ((object (to-object this))
         (length (%alen object))
         (result (%array-copy-new length)))
    (dotimes (index length result)
      (create-data-property-or-throw
       result (%aidx index) (%aget object (- length index 1))))))

(defun %array-to-sorted (this comparefn)
  (unless (or (js-undefined-p comparefn) (callable-p comparefn))
    (throw-type-error "comparator is not a function"))
  (let* ((object (to-object this))
         (length (%alen object)))
    ;; ArrayCreate precedes source element access for the copy-by-change API.
    (let* ((result (%array-copy-new length))
           (values (loop for index below length collect (%aget object index)))
           (sorted (%stable-sort-list values
                                      (unless (js-undefined-p comparefn) comparefn))))
      (loop for value in sorted
            for index from 0
            do (create-data-property-or-throw result (%aidx index) value))
      result)))

(defun %array-to-spliced (this args)
  (let* ((object (to-object this))
         (length (%alen object))
         (start (%rel-index (arg args 0) length))
         (argument-count (length args))
         (inserted (if (> argument-count 2) (cddr args) '()))
         (insert-count (length inserted))
         (delete-count
           (cond
             ((zerop argument-count) 0)
             ((= argument-count 1) (- length start))
             (t
              (let ((count (to-integer-or-infinity (arg args 1))))
                (cond
                  ((<= count 0d0) 0)
                  ((js-infinite-p count) (- length start))
                  (t (min (truncate count) (- length start))))))))
         (new-length (+ (- length delete-count) insert-count)))
    (when (> new-length +max-safe-length+)
      (throw-type-error "result exceeds maximum safe length"))
    (let ((result (%array-copy-new new-length))
          (to 0))
      (loop for from below start do
        (create-data-property-or-throw result (%aidx to) (%aget object from))
        (incf to))
      (dolist (value inserted)
        (create-data-property-or-throw result (%aidx to) value)
        (incf to))
      (loop for from from (+ start delete-count) below length do
        (create-data-property-or-throw result (%aidx to) (%aget object from))
        (incf to))
      result)))

(defun %array-with (this index value)
  (let* ((object (to-object this))
         (length (%alen object))
         (relative (to-integer-or-infinity index))
         (actual (if (minusp relative) (+ length relative) relative)))
    (when (or (js-infinite-p relative) (< actual 0) (>= actual length))
      (throw-range-error "index out of range"))
    (let ((result (%array-copy-new length))
          (actual (truncate actual)))
      (dotimes (at length result)
        (create-data-property-or-throw
         result (%aidx at) (if (= at actual) value (%aget object at)))))))

(defun %to-array-list (o len)
  (loop for i below len collect (%aget o i)))

(defun %array-sort-less (a b comparefn)
  (cond ((js-undefined-p a) nil)
        ((js-undefined-p b) t)
        (comparefn (let ((r (to-number (js-call comparefn +undefined+ (list a b)))))
                     (and (not (js-nan-p r)) (< r 0))))   ; NaN -> treat as +0 (not less)
        (t (string< (to-string a) (to-string b)))))

(defun %stable-sort-list (items comparefn)
  (stable-sort (copy-list items) (lambda (a b) (%array-sort-less a b comparefn))))

(defun %array-flatten (target source depth)
  "Append SOURCE's elements to TARGET list (reversed accumulator returned)."
  (let ((len (%alen source)) (acc target))
    (dotimes (i len acc)
      (when (%ahas source i)
        (let ((e (%aget source i)))
          (if (and (> depth 0) (is-array e))
              (setf acc (%array-flatten acc e (1- depth)))
              (push e acc)))))))

(defun %array-from (items mapfn this-arg)
  (when (and mapfn (not (callable-p mapfn)))
    (throw-type-error "Array.from mapper is not a function"))
  (let ((iter-fn (get-method items (well-known :iterator))))
    (if (not (js-undefined-p iter-fn))
        (let ((record (get-iterator-record items iter-fn))
              (vals '())
              (i 0))
          (loop
            (multiple-value-bind (value done) (iterator-step-value record)
              (when done
                (return (new-array (nreverse vals))))
              (let ((mapped
                      (call-with-iterator-close-on-abrupt
                       record
                       (lambda ()
                         (if mapfn
                             (js-call mapfn this-arg
                                      (list value (coerce i 'double-float)))
                             value)))))
                (push mapped vals)
                (incf i)))))
        (let* ((o (to-object items)) (len (%alen o)))
          (new-array (loop for i below len
                           collect (let ((v (%aget o i))) (if mapfn (js-call mapfn this-arg (list v (coerce i 'double-float))) v))))))))

;;; --- Array.fromAsync (Phase 37 m2; TC39 Array.fromAsync / ES sec-array.fromasync) ---

(defun %array-from-async-make-async-record (async-items method)
  "GetIteratorFromMethod for an async iterator method."
  (let ((iterator (js-call method async-items '())))
    (unless (js-object-p iterator)
      (throw-type-error "iterator is not an object"))
    (%make-async-iterator-record iterator (js-get iterator "next"))))

(defun %array-from-async-make-sync-adapted-record (async-items method)
  "CreateAsyncFromSyncIterator(GetIteratorFromMethod(...))."
  (let* ((sync-record (get-iterator-record async-items method))
         (adapter (%make-async-from-sync-iterator-record
                   (iterator-record-iterator sync-record)
                   (iterator-record-next-method sync-record))))
    (%make-async-iterator-record
     (async-from-sync-iterator-record-iterator adapter)
     (async-from-sync-iterator-record-next-method adapter)
     adapter)))

(defun %array-from-async-construct (c &optional (length nil length-p))
  (if (constructor-p c)
      (if length-p
          (js-construct c (list (coerce length 'double-float)))
          (js-construct c '()))
      (if length-p
          (%array-copy-new length)
          (js-make-array (intrinsic :array-prototype) 0))))

(defun %array-from-async-body (co c async-items mapfn this-arg)
  "Async body of Array.fromAsync. Runs on a coroutine; uses AWAIT-VALUE for Await."
  (let* ((mapping (cond ((js-undefined-p mapfn) nil)
                        ((callable-p mapfn) t)
                        (t (throw-type-error "Array.fromAsync mapper is not a function"))))
         (using-async (get-method async-items (well-known :async-iterator)))
         (using-sync (if (js-undefined-p using-async)
                         (get-method async-items (well-known :iterator))
                         +undefined+))
         (iterator-record
           (cond ((not (js-undefined-p using-async))
                  (%array-from-async-make-async-record async-items using-async))
                 ((not (js-undefined-p using-sync))
                  (%array-from-async-make-sync-adapted-record async-items using-sync))
                 (t nil))))
    (if iterator-record
        (let ((a (%array-from-async-construct c))
              (k 0))
          (loop
            (when (>= k +max-safe-length+)
              (async-iterator-close co iterator-record :throw-completion-p t)
              (throw-type-error "Array.fromAsync produced too many values"))
            (let* ((next-result (async-iterator-next iterator-record))
                   (awaited (await-value co next-result)))
              (unless (js-object-p awaited)
                (throw-type-error "iterator result is not an object"))
              (when (js-truthy (js-get awaited "done"))
                (setf (async-iterator-record-done iterator-record) t)
                (js-set a "length" (coerce k 'double-float) t)
                (return a))
              (let ((next-value (js-get awaited "value"))
                    (pk (%aidx k)))
                (call-with-async-iterator-close-on-abrupt
                 co iterator-record
                 (lambda ()
                   (let ((mapped-value
                           (if mapping
                               (await-value
                                co
                                (js-call mapfn this-arg
                                         (list next-value
                                               (coerce k 'double-float))))
                               next-value)))
                     (create-data-property-or-throw a pk mapped-value)
                     +undefined+)))
                (incf k)))))
        (let* ((array-like (to-object async-items))
               (len (%alen array-like))
               (a (%array-from-async-construct c len)))
          (loop for k below len do
            (let* ((pk (%aidx k))
                   (k-value (await-value co (js-get array-like pk)))
                   (mapped-value
                     (if mapping
                         (await-value
                          co
                          (js-call mapfn this-arg
                                   (list k-value (coerce k 'double-float))))
                         k-value)))
              (create-data-property-or-throw a pk mapped-value)))
          (js-set a "length" (coerce len 'double-float) t)
          a))))

(defun %array-from-async (c async-items mapfn this-arg)
  "Array.fromAsync: always returns a Promise (built-in async method)."
  (start-async-function
   (lambda ()
     (let ((box (cons nil nil)))
       (let ((co (make-coroutine
                  (lambda ()
                    (%array-from-async-body (car box) c async-items mapfn this-arg)))))
         (setf (car box) co)
         co)))))

(defun %bootstrap-array-extra ()
  (let ((ap (intrinsic :array-prototype)) (ac (intrinsic :array-constructor)))
    (macrolet ((m (name arity &body body) `(install-method ap ,name ,arity ,@body)))
      (m "at" 1 (lambda (this args)
                  (let* ((o (to-object this)) (len (%alen o)) (n (%int (arg args 0)))
                         (i (if (minusp n) (+ len n) n)))
                    (if (and (<= 0 i) (< i len)) (%aget o i) +undefined+))))
      (m "toReversed" 0
        (lambda (this args) (declare (ignore args)) (%array-to-reversed this)))
      (m "toSorted" 1
        (lambda (this args) (%array-to-sorted this (arg args 0))))
      (m "toSpliced" 2
        (lambda (this args) (%array-to-spliced this args)))
      (m "with" 2
        (lambda (this args) (%array-with this (arg args 0) (arg args 1))))
      (m "shift" 0 (lambda (this args) (declare (ignore args))
                     (let* ((o (to-object this)) (len (%alen o)))
                       (if (zerop len) (progn (%aset-len o 0) +undefined+)
                           (let ((first (%aget o 0)))
                             (loop for i from 1 below len do (if (%ahas o i) (%aset o (1- i) (%aget o i)) (%adel o (1- i))))
                             (%adel o (1- len)) (%aset-len o (1- len)) first)))))
      (m "unshift" 1 (lambda (this args)
                       (let* ((o (to-object this)) (len (%alen o)) (k (length args)))
                         (loop for i from (1- len) downto 0 do (if (%ahas o i) (%aset o (+ i k) (%aget o i)) (%adel o (+ i k))))
                         (loop for v in args for i from 0 do (%aset o i v))
                         (%aset-len o (+ len k)) (coerce (+ len k) 'double-float))))
      (m "reverse" 0 (lambda (this args) (declare (ignore args))
                       (let* ((o (to-object this)) (len (%alen o)))
                         (dotimes (i (floor len 2))
                           (let ((j (- len 1 i)) (hi (%ahas o i)) (hj (%ahas o (- len 1 i))))
                             (let ((vi (and hi (%aget o i))) (vj (and hj (%aget o j))))
                               (if hj (%aset o i vj) (%adel o i))
                               (if hi (%aset o j vi) (%adel o j)))))
                         o)))
      (m "fill" 1 (lambda (this args)
                    (let* ((o (to-object this)) (len (%alen o)) (v (arg args 0))
                           (start (%rel-index (arg args 1) len))
                           (end (if (js-undefined-p (arg args 2)) len (%rel-index (arg args 2) len))))
                      (loop for i from start below end do (%aset o i v)) o)))
      (m "copyWithin" 2 (lambda (this args)
                          (let* ((o (to-object this)) (len (%alen o))
                                 (target (%rel-index (arg args 0) len))
                                 (start (%rel-index (arg args 1) len))
                                 (end (if (js-undefined-p (arg args 2)) len (%rel-index (arg args 2) len)))
                                 (count (min (- end start) (- len target)))
                                 (vals (loop for i from start below (+ start (max 0 count)) collect (cons (%ahas o i) (%aget o i)))))
                            (loop for pair in vals for i from target
                                  do (if (car pair) (%aset o i (cdr pair)) (%adel o i)))
                            o)))
      (m "lastIndexOf" 1 (lambda (this args)
                           (let* ((o (to-object this)) (len (%alen o)) (target (arg args 0)))
                             (coerce (or (loop for i from (1- len) downto 0
                                               when (and (%ahas o i) (js-strict-eq (%aget o i) target)) do (return i)) -1) 'double-float))))
      (m "find" 1 (lambda (this args) (%array-find this args :value nil)))
      (m "findIndex" 1 (lambda (this args) (%array-find this args :index nil)))
      (m "findLast" 1 (lambda (this args) (%array-find this args :value t)))
      (m "findLastIndex" 1 (lambda (this args) (%array-find this args :index t)))
      (m "every" 1 (lambda (this args)
                     (let* ((o (to-object this)) (len (%alen o)) (f (arg args 0)) (that (arg args 1)))
                       (dotimes (i len +true+)
                         (when (and (%ahas o i) (not (js-truthy (js-call f that (list (%aget o i) (coerce i 'double-float) o)))))
                           (return +false+))))))
      (m "some" 1 (lambda (this args)
                    (let* ((o (to-object this)) (len (%alen o)) (f (arg args 0)) (that (arg args 1)))
                      (dotimes (i len +false+)
                        (when (and (%ahas o i) (js-truthy (js-call f that (list (%aget o i) (coerce i 'double-float) o))))
                          (return +true+))))))
      (m "filter" 1 (lambda (this args)
                      (let* ((o (to-object this)) (len (%alen o)) (f (arg args 0)) (that (arg args 1)) (out '()))
                        (dotimes (i len) (when (%ahas o i)
                                           (let ((v (%aget o i)))
                                             (when (js-truthy (js-call f that (list v (coerce i 'double-float) o))) (push v out)))))
                        (new-array (nreverse out)))))
      (m "reduce" 1 (lambda (this args) (%array-reduce this args nil)))
      (m "reduceRight" 1 (lambda (this args) (%array-reduce this args t)))
      (m "sort" 1 (lambda (this args)
                    (let* ((o (to-object this)) (len (%alen o)) (comparefn (arg args 0)))
                      (unless (or (js-undefined-p comparefn) (callable-p comparefn)) (throw-type-error "comparator is not a function"))
                      (let* ((present (loop for i below len when (%ahas o i) collect (%aget o i)))
                             (npresent (length present))
                             (sorted (%stable-sort-list present (if (js-undefined-p comparefn) nil comparefn))))
                        (loop for v in sorted for i from 0 do (%aset o i v))
                        (loop for i from npresent below len do (%adel o i))
                        o))))
      (m "splice" 2 (lambda (this args) (%array-splice this args)))
      (m "flat" 0 (lambda (this args)
                    (let* ((o (to-object this))
                           (depth (if (js-undefined-p (arg args 0)) 1 (%int (arg args 0)))))
                      (new-array (nreverse (%array-flatten '() o depth))))))
      (m "flatMap" 1 (lambda (this args)
                       (let* ((o (to-object this)) (len (%alen o)) (f (arg args 0)) (that (arg args 1)) (acc '()))
                         (dotimes (i len)
                           (when (%ahas o i)
                             (let ((v (js-call f that (list (%aget o i) (coerce i 'double-float) o))))
                               (if (is-array v) (setf acc (%array-flatten acc v 0)) (push v acc)))))
                         (new-array (nreverse acc))))))
    (install-method ac "from" 1
      (lambda (this args) (declare (ignore this))
        (%array-from (arg args 0) (let ((mf (arg args 1))) (if (js-undefined-p mf) nil mf)) (arg args 2))))
    (install-method ac "fromAsync" 1
      (lambda (this args)
        (%array-from-async this (arg args 0) (arg args 1) (arg args 2))))))

(defun %array-find (this args mode from-end)
  (let* ((o (to-object this)) (len (%alen o)) (f (arg args 0)) (that (arg args 1)))
    (flet ((check (i) (js-truthy (js-call f that (list (%aget o i) (coerce i 'double-float) o)))))
      (if from-end
          (loop for i from (1- len) downto 0 when (check i)
                do (return-from %array-find (if (eq mode :value) (%aget o i) (coerce i 'double-float))))
          (dotimes (i len) (when (check i)
                             (return-from %array-find (if (eq mode :value) (%aget o i) (coerce i 'double-float)))))))
    (if (eq mode :value) +undefined+ -1d0)))

(defun %array-splice (this args)
  (let* ((o (to-object this)) (len (%alen o))
         (start (%rel-index (arg args 0) len))
         (insert (if (>= (length args) 2) (cddr args) '()))
         (del (cond ((< (length args) 1) 0)
                    ((< (length args) 2) (- len start))
                    (t (max 0 (min (%int (arg args 1)) (- len start))))))
         (removed (loop for i below del when (%ahas o (+ start i)) collect (cons i (%aget o (+ start i)))))
         (result (%array-species-new del))
         (ins (length insert)))
    (dolist (pair removed) (create-data-property result (%aidx (car pair)) (cdr pair)))
    (%aset-len result del)
    (cond
      ((< ins del)                              ; shrink: shift tail left
       (loop for i from start below (- len del)
             do (if (%ahas o (+ i del)) (%aset o (+ i ins) (%aget o (+ i del))) (%adel o (+ i ins))))
       (loop for i from (- len (- del ins)) below len do (%adel o i)))
      ((> ins del)                              ; grow: shift tail right
       (loop for i from (- len del) above start
             do (let ((from (+ i del -1)) (to (+ i ins -1)))
                  (if (%ahas o from) (%aset o to (%aget o from)) (%adel o to))))))
    (loop for v in insert for i from start do (%aset o i v))
    (%aset-len o (+ (- len del) ins))
    result))

(defun %array-reduce (this args right)
  (let* ((o (to-object this)) (len (%alen o)) (f (arg args 0)))
    (unless (callable-p f) (throw-type-error "reduce callback is not a function"))
    (let ((acc +undefined+) (have (>= (length args) 2)))
      (when have (setf acc (arg args 1)))
      (flet ((visit (i)
               (when (%ahas o i)
                 (if have
                     (setf acc (js-call f +undefined+
                                        (list acc (%aget o i) (coerce i 'double-float) o)))
                     (setf acc (%aget o i) have t)))))
        (if right
            (loop for i = (1- len) then (1- i)
                  while (>= i 0) do (visit i))
            (loop for i below len do (visit i))))
      (unless have (throw-type-error "Reduce of empty array with no initial value"))
      acc)))
