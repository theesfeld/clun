;;;; builtins-symbol.lisp — Symbol breadth (Phase 04, §20.4): the global symbol
;;;; registry (for / keyFor), the description getter, valueOf, @@toPrimitive and
;;;; @@toStringTag. Extends the Phase 03 Symbol set.

(in-package :clun.engine)

(defun %bootstrap-symbol-extra ()
  (let ((sp (intrinsic :symbol-prototype)) (sc (intrinsic :symbol-constructor))
        (registry (make-hash-table :test 'equal)))
    (setf (realm-intrinsic *realm* :symbol-registry) registry)
    (install-method sp "valueOf" 0 (lambda (this args) (declare (ignore args)) (this-symbol this)))
    (install-getter sp "description"
      (lambda (this args) (declare (ignore args))
        (let ((d (js-symbol-description (this-symbol this)))) (if (js-undefined-p d) +undefined+ d))))
    (obj-set-desc sp (well-known :to-string-tag)
                  (data-pd "Symbol" :writable nil :enumerable nil :configurable t))
    (obj-set-desc sp (well-known :to-primitive)
                  (data-pd (make-native-function "[Symbol.toPrimitive]" 1
                             (lambda (this args) (declare (ignore args)) (this-symbol this)))
                           :writable nil :enumerable nil :configurable t))
    (install-method sc "for" 1
      (lambda (this args) (declare (ignore this))
        (let ((key (to-string (arg args 0))))
          (or (gethash key registry)
              (setf (gethash key registry) (%make-js-symbol :description key))))))
    (install-method sc "keyFor" 1
      (lambda (this args) (declare (ignore this))
        (let ((sym (arg args 0)))
          (unless (js-symbol-p sym) (throw-type-error "Symbol.keyFor requires a symbol"))
          (block found
            (maphash (lambda (k v) (when (eq v sym) (return-from found k))) registry)
            +undefined+))))))
