;;;; yaml.lisp -- engine adapter for the shared YAML graph parser.

(in-package :clun.engine)

(defun yaml-valid-utf8-p (bytes)
  (let ((index 0) (length (length bytes)))
    (labels ((continuation-p (position low high)
               (and (< position length) (<= low (aref bytes position) high))))
      (loop while (< index length) do
        (let ((lead (aref bytes index)))
          (cond
            ((< lead #x80) (incf index))
            ((<= #xc2 lead #xdf)
             (unless (continuation-p (1+ index) #x80 #xbf)
               (return-from yaml-valid-utf8-p nil))
             (incf index 2))
            ((<= #xe0 lead #xef)
             (unless (and (continuation-p (1+ index)
                                          (if (= lead #xe0) #xa0 #x80)
                                          (if (= lead #xed) #x9f #xbf))
                          (continuation-p (+ index 2) #x80 #xbf))
               (return-from yaml-valid-utf8-p nil))
             (incf index 3))
            ((<= #xf0 lead #xf4)
             (unless (and (continuation-p (1+ index)
                                          (if (= lead #xf0) #x90 #x80)
                                          (if (= lead #xf4) #x8f #xbf))
                          (continuation-p (+ index 2) #x80 #xbf)
                          (continuation-p (+ index 3) #x80 #xbf))
               (return-from yaml-valid-utf8-p nil))
             (incf index 4))
            (t (return-from yaml-valid-utf8-p nil)))))
      t)))

(defun yaml-octets->source (bytes &optional path)
  (unless (yaml-valid-utf8-p bytes)
    (throw-syntax-error
     (format nil "YAML Parse error: invalid UTF-8 input~@[ in ~a~]" path)))
  (utf8->code-units bytes))

(defun yaml-number->js (value)
  (case value
    (:nan *js-nan*)
    (:positive-infinity +js-infinity+)
    (:negative-infinity +js-neg-infinity+)
    (otherwise
     (with-js-floats
       (handler-case (coerce value 'double-float)
         (floating-point-overflow ()
           (if (minusp value) +js-neg-infinity+ +js-infinity+)))))))

(defun yaml-key->string (node &optional (seen (make-hash-table :test 'eq)) sequence-element-p)
  (case (clun.yaml:yaml-node-kind node)
    (:string (clun.yaml:yaml-node-value node))
    (:null (if sequence-element-p "" "null"))
    (:boolean (if (clun.yaml:yaml-node-value node) "true" "false"))
    (:number
     (let ((value (yaml-number->js (clun.yaml:yaml-node-value node))))
       (number->js-string value)))
    (:sequence
     (if (gethash node seen)
         ""
         (unwind-protect
              (progn
                (setf (gethash node seen) t)
                (with-output-to-string (output)
                  (loop for child across (clun.yaml:yaml-node-value node)
                        for first = t then nil
                        unless first do (write-char #\, output)
                        do (write-string (yaml-key->string child seen t) output))))
           (remhash node seen))))
    (:mapping "[object Object]")
    (otherwise "")))

(defun yaml-node->js (node seen)
  (case (clun.yaml:yaml-node-kind node)
    (:null +null+)
    (:boolean (js-boolean (clun.yaml:yaml-node-value node)))
    (:number (yaml-number->js (clun.yaml:yaml-node-value node)))
    (:string (clun.yaml:yaml-node-value node))
    (:sequence
     (or (gethash node seen)
         (let ((array (js-make-array (intrinsic :array-prototype))))
           (setf (gethash node seen) array)
           (loop for child across (clun.yaml:yaml-node-value node)
                 for index from 0
                 do (create-data-property array (princ-to-string index)
                                          (yaml-node->js child seen)))
           array)))
    (:mapping
     (or (gethash node seen)
         (let ((object (new-object)))
           (setf (gethash node seen) object)
           (loop for pair across (clun.yaml:yaml-node-value node)
                 do (create-data-property
                     object
                     (yaml-key->string (clun.yaml:yaml-pair-key pair))
                     (yaml-node->js (clun.yaml:yaml-pair-value pair) seen)))
           object)))
    (otherwise +undefined+)))

(defun yaml-stream->js (stream)
  (let* ((documents (clun.yaml:yaml-stream-documents stream))
         (seen (make-hash-table :test 'eq)))
    (if (= (length documents) 1)
        (yaml-node->js (aref documents 0) seen)
        (new-array (loop for document across documents
                         collect (yaml-node->js document seen))))))

(defun yaml-parse-error-message (condition &optional path)
  (format nil "YAML Parse error: ~a~@[ in ~a~] at ~d:~d"
          (clun.yaml:yaml-error-reason condition)
          path
          (clun.yaml:yaml-error-line condition)
          (clun.yaml:yaml-error-column condition)))

(defun yaml-source->js (source &optional path)
  (handler-case
      (let* ((stream (clun.yaml:parse-yaml source))
             (documents (clun.yaml:yaml-stream-documents stream)))
        (values (yaml-stream->js stream)
                (and (= (length documents) 1)
                     (eq (clun.yaml:yaml-node-kind (aref documents 0)) :mapping))))
    (clun.yaml:yaml-error (condition)
      (throw-syntax-error (yaml-parse-error-message condition path)))))
