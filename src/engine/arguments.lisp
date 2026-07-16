;;;; arguments.lisp -- mapped and unmapped arguments exotic objects.

(in-package :clun.engine)

(defstruct (js-arguments-object
             (:include js-object (class :arguments))
             (:constructor %make-js-arguments-object))
  ;; NIL identifies an unmapped object. A vector identifies a mapped object,
  ;; including the empty vector for a sloppy function with no parameters.
  ;; Each live entry is (FRAME-SLOT . BINDING-NAME); NIL means detached.
  parameter-map
  parameter-environment)

(defun mapped-argument-cell (arguments key)
  (let ((map (js-arguments-object-parameter-map arguments))
        (index (array-index-key-p key)))
    (and map index (< index (length map)) (aref map index))))

(defun mapped-argument-value (arguments cell)
  (frame-ref (js-arguments-object-parameter-environment arguments)
             0 (car cell) (cdr cell)))

(defun set-mapped-argument-value (arguments cell value)
  (frame-set (js-arguments-object-parameter-environment arguments)
             0 (car cell) value (cdr cell)))

(defun detach-mapped-argument (arguments key)
  (let* ((map (js-arguments-object-parameter-map arguments))
         (index (and map (array-index-key-p key))))
    (when (and index (< index (length map)))
      (setf (aref map index) nil))))

(defmethod jm-get-own-property ((arguments js-arguments-object) key)
  (let ((descriptor (call-next-method))
        (cell (mapped-argument-cell arguments key)))
    (if (and descriptor cell)
        (let ((result (copy-pd descriptor)))
          (setf (pd-value result) (mapped-argument-value arguments cell))
          result)
        descriptor)))

(defmethod jm-define-own-property ((arguments js-arguments-object) key descriptor)
  ;; ArgumentsDefineOwnProperty first applies the ordinary descriptor. Only a
  ;; successful definition can update or detach the parameter mapping.
  (let ((cell (mapped-argument-cell arguments key))
        (allowed (ordinary-define-own-property arguments key descriptor)))
    (when (and allowed cell)
      (cond
        ((accessor-descriptor-p descriptor)
         (detach-mapped-argument arguments key))
        (t
         (when (pd-set-p (pd-value descriptor))
           (set-mapped-argument-value arguments cell (pd-value descriptor)))
         (when (eq (pd-writable descriptor) nil)
           (detach-mapped-argument arguments key)))))
    allowed))

(defmethod jm-set ((arguments js-arguments-object) key value receiver)
  ;; The ordinary-object fast path mutates a stored descriptor directly. A
  ;; mapped own index must instead pass through ArgumentsDefineOwnProperty so
  ;; the frame cell is synchronized. Distinct receivers retain ordinary Set.
  (if (and (eq receiver arguments) (mapped-argument-cell arguments key))
      (jm-define-own-property arguments key (make-prop-desc :value value))
      (call-next-method)))

(defmethod jm-delete ((arguments js-arguments-object) key)
  (let ((deleted (call-next-method)))
    (when deleted (detach-mapped-argument arguments key))
    deleted))

(defun arguments-throw-type-error ()
  (or (intrinsic :throw-type-error)
      ;; Early-bootstrap fallback. Normal realms install one shared immutable
      ;; %ThrowTypeError% intrinsic before user code can create arguments.
      (make-native-function "" 0
        (lambda (this args)
          (declare (ignore this args))
          (throw-type-error "restricted arguments property")))))

(defun make-arguments-object (args function frame &key mapped-parameters)
  "Create an arguments object. MAPPED-PARAMETERS is NIL for strict/non-simple
functions, or a vector of compile-time parameter-cell entries for a sloppy
simple parameter list. Only supplied argument indices retain live mappings."
  (let* ((mapped-p (not (null mapped-parameters)))
         (map (and mapped-p
                   (subseq mapped-parameters
                           0 (min (length args) (length mapped-parameters)))))
         (arguments (%make-js-arguments-object
                     :proto (intrinsic :object-prototype)
                     :parameter-map map
                     :parameter-environment (and mapped-p frame))))
    (loop for value in args
          for index from 0
          do (obj-set-desc arguments (int->string index)
                           (data-pd value :writable t :enumerable t :configurable t)))
    (obj-set-desc arguments "length"
                  (data-pd (coerce (length args) 'double-float)
                           :writable t :enumerable nil :configurable t))
    (obj-set-desc arguments (well-known :iterator)
                  (data-pd (js-get (intrinsic :array-prototype) "values")
                           :writable t :enumerable nil :configurable t))
    (if mapped-p
        (obj-set-desc arguments "callee"
                      (data-pd function :writable t :enumerable nil :configurable t))
        (let ((thrower (arguments-throw-type-error)))
          (obj-set-desc arguments "callee"
                        (accessor-pd thrower thrower
                                     :enumerable nil :configurable nil))))
    arguments))
