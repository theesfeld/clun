;;;; clun-yaml.lisp -- Clun.YAML parse/stringify JavaScript boundary.

(in-package :clun.runtime)

(defconstant +yaml-max-output-length+ (* 32 1024 1024))

(defstruct (yaml-writer (:conc-name yw-))
  (gap "")
  (counts (make-hash-table :test 'eq))
  (origins (make-hash-table :test 'eq))
  (anchors (make-hash-table :test 'eq))
  (used-names (make-hash-table :test 'equal))
  (emitted (make-hash-table :test 'eq))
  (discover-edges 0)
  (emit-edges 0)
  (output-length 0)
  (item-counter 0)
  (value-counter 0))

(defun %yaml-check-edge (writer phase)
  (let ((count (ecase phase
                 (:discover (yw-discover-edges writer))
                 (:emit (yw-emit-edges writer)))))
    (when (>= count clun.yaml:+max-edges+)
      (eng:throw-range-error "YAML.stringify edge limit exceeded"))
    (ecase phase
      (:discover (incf (yw-discover-edges writer)))
      (:emit (incf (yw-emit-edges writer))))))

(defun %yaml-check-output (writer amount)
  (when (> amount (- +yaml-max-output-length+ (yw-output-length writer)))
    (eng:throw-range-error "YAML.stringify output limit exceeded"))
  (incf (yw-output-length writer) amount))

(defun %yaml-input-string (value)
  (if (or (eng:js-array-buffer-p value)
          (eng:js-typed-array-p value)
          (eng::js-data-view-p value))
      (let ((bytes (eng::%source-bytes value)))
        (eng::yaml-octets->source bytes))
      (eng:to-string value)))

(defun %yaml-unwrap (value)
  (if (eng:js-object-p value)
      (case (eng:js-object-class value)
        (:number (eng:to-number value))
        (:string (eng:to-string value))
        ((:boolean :bigint) (eng::wrapper-primitive value))
        (otherwise value))
      value))

(defun %yaml-serializable-collection-p (value)
  (and (eng:js-object-p value) (not (eng:callable-p value))))

(defun %yaml-own-keys (object)
  (loop for key in (eng::jm-own-property-keys object)
        for descriptor = (and (stringp key) (eng::jm-get-own-property object key))
        when (and descriptor (eq (eng::pd-enumerable descriptor) t))
          collect key))

(defun %yaml-discover (writer value origin depth)
  (when (> depth clun.yaml:+max-depth+)
    (eng:throw-range-error "YAML.stringify nesting depth limit exceeded"))
  (setf value (%yaml-unwrap value))
  (when (%yaml-serializable-collection-p value)
    (let ((count (gethash value (yw-counts writer) 0)))
      (setf (gethash value (yw-counts writer)) (1+ count))
      (when (zerop count)
        (setf (gethash value (yw-origins writer)) origin)
        (if (eng:js-array-p value)
            (dotimes (index (eng:length-of-array-like value))
              (%yaml-check-edge writer :discover)
              (%yaml-discover writer
                              (eng:js-getv value (princ-to-string index))
                              :item (1+ depth)))
            (dolist (key (%yaml-own-keys value))
              (%yaml-check-edge writer :discover)
              (%yaml-discover writer (eng:js-getv value key)
                              (list :property key) (1+ depth))))))))

(defun %yaml-safe-anchor-name-p (name)
  (and (plusp (length name))
       (loop for character across name
             always (or (alphanumericp character)
                        (member character '(#\- #\. #\_))))
       (not (and (or (string= name "root")
                     (and (>= (length name) 4) (string= name "item" :end1 4))
                     (and (>= (length name) 5) (string= name "value" :end1 5)))
                 (let ((start (cond ((string= name "root") 4)
                                    ((string= name "item" :end1 4) 4)
                                    (t 5))))
                   (and (< start (length name))
                        (every #'digit-char-p (subseq name start))))))))

(defun %yaml-generated-anchor (writer prefix counter-kind)
  (loop
    for counter = (ecase counter-kind
                    (:item (yw-item-counter writer))
                    (:value (yw-value-counter writer)))
    for name = (format nil "~a~d" prefix counter)
    do (ecase counter-kind
         (:item (setf (yw-item-counter writer) (1+ counter)))
         (:value (setf (yw-value-counter writer) (1+ counter))))
    unless (gethash name (yw-used-names writer))
      do (setf (gethash name (yw-used-names writer)) t)
         (return name)))

(defun %yaml-anchor-name (writer value)
  (when (> (gethash value (yw-counts writer) 0) 1)
    (or (gethash value (yw-anchors writer))
        (progn
          (when (>= (hash-table-count (yw-anchors writer)) clun.yaml:+max-anchors+)
            (eng:throw-range-error "YAML.stringify anchor limit exceeded"))
          (setf (gethash value (yw-anchors writer))
                (let ((origin (gethash value (yw-origins writer))))
                  (cond
                    ((eq origin :root)
                     (if (gethash "root" (yw-used-names writer))
                         (%yaml-generated-anchor writer "value" :value)
                         (progn (setf (gethash "root" (yw-used-names writer)) t) "root")))
                    ((eq origin :item)
                     (%yaml-generated-anchor writer "item" :item))
                    ((and (consp origin)
                          (%yaml-safe-anchor-name-p (second origin))
                          (not (gethash (second origin) (yw-used-names writer))))
                     (setf (gethash (second origin) (yw-used-names writer)) t)
                     (second origin))
                    (t (%yaml-generated-anchor writer "value" :value)))))))))

(defun %yaml-number-string (number)
  (cond
    ((eng:js-nan-p number) ".nan")
    ((eng:js-infinite-p number) (if (minusp number) "-.inf" ".inf"))
    ((eng:js-neg-zero-p number) "-0")
    (t (eng::number->js-string number))))

(defparameter +yaml-quoted-keywords+
  '("true" "True" "TRUE" "false" "False" "FALSE"
    "yes" "Yes" "YES" "no" "No" "NO" "on" "On" "ON" "off" "Off" "OFF"
    "n" "N" "y" "Y" "null" "Null" "NULL" "~"
    ".inf" ".Inf" ".INF" ".nan" ".NaN" ".NAN"))

(defun %yaml-signed-infinity-prefix-p (string index)
  (and (<= (+ index 4) (length string))
       (member (subseq string index (+ index 4))
               '(".inf" ".Inf" ".INF") :test #'string=)))

(defun %yaml-number-like-string-p (string)
  (let* ((length (length string))
         (index 0)
         (base :decimal)
         (saw-dot nil)
         (saw-exponent nil)
         (saw-inner-minus nil))
    (when (zerop length) (return-from %yaml-number-like-string-p nil))
    (unless (or (digit-char-p (char string 0) 10)
                (member (char string 0) '(#\+ #\- #\.)))
      (return-from %yaml-number-like-string-p nil))
    (when (member (char string 0) '(#\+ #\-))
      (incf index)
      (when (= index length) (return-from %yaml-number-like-string-p nil))
      (when (and (char= (char string index) #\.)
                 (%yaml-signed-infinity-prefix-p string index))
        (return-from %yaml-number-like-string-p t)))
    (when (and (< (1+ index) length) (char= (char string index) #\0))
      (case (char string (1+ index))
        ((#\x #\X) (setf base :hexadecimal) (incf index 2))
        ((#\o #\O) (setf base :octal) (incf index 2)))
      (when (= index length) (return-from %yaml-number-like-string-p nil)))
    (loop while (< index length) do
      (let ((character (char string index)))
        (cond
          ((digit-char-p character 10))
          ((or (find character "abcdfABCDF"))
           (unless (eq base :hexadecimal)
             (return-from %yaml-number-like-string-p nil)))
          ((member character '(#\e #\E))
           (when (eq base :decimal)
             (when saw-exponent (return-from %yaml-number-like-string-p nil))
             (setf saw-exponent t)))
          ((char= character #\.)
           (when (or saw-dot (not (eq base :decimal)))
             (return-from %yaml-number-like-string-p nil))
           (setf saw-dot t))
          ((char= character #\+)
           (when (eq base :hexadecimal)
             (return-from %yaml-number-like-string-p nil)))
          ((char= character #\-)
           (when saw-inner-minus (return-from %yaml-number-like-string-p nil))
           (setf saw-inner-minus t))
          (t (return-from %yaml-number-like-string-p nil))))
      (incf index))
    t))

(defun %yaml-document-marker-like-p (string)
  (loop for index from 0 to (- (length string) 3)
        when (and (or (string= string "---" :start1 index :end1 (+ index 3))
                      (string= string "..." :start1 index :end1 (+ index 3)))
                  (or (= (+ index 3) (length string))
                      (member (char string (+ index 3))
                              '(#\Space #\Tab #\Newline #\Return
                                #\[ #\] #\{ #\} #\,))))
          return t))

(defun %yaml-string-needs-quotes-p (string)
  (or (zerop (length string))
      (%yaml-document-marker-like-p string)
      (member string +yaml-quoted-keywords+ :test #'string=)
      (%yaml-number-like-string-p string)
      (member (char string 0)
              '(#\& #\* #\? #\| #\- #\< #\> #\! #\% #\@ #\: #\, #\[ #\]
                #\{ #\} #\# #\' #\" #\` #\Space #\Tab #\Newline #\Return))
      (member (char string (1- (length string)))
              '(#\Space #\Tab #\Newline #\Return #\:))
      (loop for index below (length string)
            for character = (char string index)
            for code = (char-code character)
            thereis
            (or (< code #x20)
                (<= #x7f code #x9f)
                (member code '(#xa0 #xfeff #xfffe #xffff #x2028 #x2029))
                (member character '(#\{ #\} #\[ #\] #\, #\` #\' #\" #\#))
                (and (char= character #\:)
                     (< (1+ index) (length string))
                     (clun.yaml::ascii-space-p (char string (1+ index))))))))

(defun %yaml-quoted-string (string)
  (with-output-to-string (output)
    (write-char #\" output)
    (loop for character across string
          for code = (char-code character) do
      (case code
        (0 (write-string "\\0" output))
        (7 (write-string "\\a" output))
        (8 (write-string "\\b" output))
        (9 (write-string "\\t" output))
        (10 (write-string "\\n" output))
        (11 (write-string "\\v" output))
        (12 (write-string "\\f" output))
        (13 (write-string "\\r" output))
        (27 (write-string "\\e" output))
        (34 (write-string "\\\"" output))
        (92 (write-string "\\\\" output))
        (#x85 (write-string "\\N" output))
        (#xa0 (write-string "\\_" output))
        (#x2028 (write-string "\\L" output))
        (#x2029 (write-string "\\P" output))
        (otherwise
         (cond ((or (< code #x20) (<= #x7f code #x9f))
                (format output "\\x~(~2,'0x~)" code))
               ((member code '(#xfffe #xffff))
                (format output "\\u~(~4,'0x~)" code))
               (t (write-char character output))))))
    (write-char #\" output)))

(defun %yaml-quoted-string-length (string)
  (+ 2
     (loop for character across string
           for code = (char-code character)
           sum (cond
                 ((member code '(0 7 8 9 10 11 12 13 27 34 92 #x85 #xa0 #x2028 #x2029)) 2)
                 ((or (< code #x20) (<= #x7f code #x9f)) 4)
                 ((member code '(#xfffe #xffff)) 6)
                 (t 1)))))

(defun %yaml-render-string (writer string)
  (if (%yaml-string-needs-quotes-p string)
      (progn
        (%yaml-check-output writer (%yaml-quoted-string-length string))
        (%yaml-quoted-string string))
      (progn
        (%yaml-check-output writer (length string))
        string)))

(defun %yaml-scalar-string (writer value)
  (let ((rendered
          (cond
            ((eng:js-null-p value) "null")
            ((eq value eng:+true+) "true")
            ((eq value eng:+false+) "false")
            ((stringp value) (return-from %yaml-scalar-string
                               (%yaml-render-string writer value)))
            ((eng:js-number-p value) (%yaml-number-string value))
            ((eng:js-bigint-p value)
             (eng:throw-type-error "YAML.stringify cannot serialize BigInt"))
            (t nil))))
    (when rendered
      (%yaml-check-output writer (length rendered)))
    rendered))

(defun %yaml-emit (writer value depth)
  (when (> depth clun.yaml:+max-depth+)
    (eng:throw-range-error "YAML.stringify nesting depth limit exceeded"))
  (setf value (%yaml-unwrap value))
  (or (%yaml-scalar-string writer value)
      (cond
        ((or (eng:js-undefined-p value) (eng:js-symbol-p value) (eng:callable-p value)) nil)
        ((%yaml-serializable-collection-p value)
         (let ((anchor (%yaml-anchor-name writer value)))
           (when (gethash value (yw-emitted writer))
             (unless anchor
               (eng:throw-type-error "YAML.stringify graph changed during serialization"))
             (%yaml-check-output writer (1+ (length anchor)))
             (return-from %yaml-emit (format nil "*~a" anchor)))
           (setf (gethash value (yw-emitted writer)) t)
           (let ((body (if (string= (yw-gap writer) "")
                           (%yaml-emit-flow writer value depth)
                           (%yaml-emit-block writer value depth))))
             (if anchor
                 (progn
                   (%yaml-check-output writer (+ 2 (length anchor)))
                   (if (string= (yw-gap writer) "")
                       (format nil "&~a ~a" anchor body)
                       (format nil "&~a~%~a" anchor body)))
                 body))))
        (t nil))))

(defun %yaml-emit-flow (writer value depth)
  (if (eng:js-array-p value)
      (let ((parts '()))
        (%yaml-check-output writer 2)
        (dotimes (index (eng:length-of-array-like value))
          (%yaml-check-edge writer :emit)
          (when (plusp index) (%yaml-check-output writer 1))
          (let ((rendered
                  (%yaml-emit writer (eng:js-getv value (princ-to-string index)) (1+ depth))))
            (unless rendered (%yaml-check-output writer 4))
            (push (or rendered "null") parts)))
        (format nil "[~{~a~^,~}]" (nreverse parts)))
      (let ((parts '()) (count 0))
        (%yaml-check-output writer 2)
        (dolist (key (%yaml-own-keys value))
          (%yaml-check-edge writer :emit)
          (let ((rendered (%yaml-emit writer (eng:js-getv value key) (1+ depth))))
            (when rendered
              (when (plusp count) (%yaml-check-output writer 1))
              (%yaml-check-output writer 2)
              (push (format nil "~a: ~a"
                            (%yaml-render-string writer key)
                            rendered)
                    parts)
              (incf count))))
        (format nil "{~{~a~^,~}}" (nreverse parts)))))

(defun %yaml-multiline-value-p (value)
  (and (%yaml-serializable-collection-p value)
       (if (eng:js-array-p value)
           (plusp (eng:length-of-array-like value))
           (plusp (length (%yaml-own-keys value))))))

(defun %yaml-prefix-lines (text prefix &key (start 0))
  (with-output-to-string (output)
    (loop for newline = (position #\Newline text :start start)
          do (write-string prefix output)
             (write-string text output :start start :end (or newline (length text)))
          while newline
          do (write-char #\Newline output)
             (setf start (1+ newline)))))

(defun %yaml-prefix-continuation-lines (text prefix)
  (let ((first-newline (position #\Newline text)))
    (if first-newline
        (concatenate 'string
                     (subseq text 0 (1+ first-newline))
                     (%yaml-prefix-lines text prefix :start (1+ first-newline)))
        text)))

(defun %yaml-emit-block (writer value depth)
  (let ((gap (yw-gap writer)))
    (if (eng:js-array-p value)
        (let ((parts '()))
          (dotimes (index (eng:length-of-array-like value))
            (%yaml-check-edge writer :emit)
            (%yaml-check-output writer (+ 2 (if (plusp index) 1 0)))
            (let* ((child (eng:js-getv value (princ-to-string index)))
                   (rendered (%yaml-emit writer child (1+ depth))))
              (unless rendered (%yaml-check-output writer 4))
              (setf rendered (or rendered "null"))
              (when (%yaml-multiline-value-p (%yaml-unwrap child))
                (%yaml-check-output
                 writer (* (length gap) (count #\Newline rendered))))
              (push (if (%yaml-multiline-value-p (%yaml-unwrap child))
                        (format nil "- ~a" (%yaml-prefix-continuation-lines rendered gap))
                        (format nil "- ~a" rendered))
                    parts)))
          (if parts
              (format nil "~{~a~^~%~}" (nreverse parts))
              (progn (%yaml-check-output writer 2) "[]")))
        (let ((parts '()) (count 0))
          (dolist (key (%yaml-own-keys value))
            (%yaml-check-edge writer :emit)
            (let* ((child (eng:js-getv value key))
                   (rendered (%yaml-emit writer child (1+ depth))))
              (when rendered
                (when (plusp count) (%yaml-check-output writer 1))
                (let* ((multiline-p (%yaml-multiline-value-p (%yaml-unwrap child)))
                       (rendered-key nil))
                  (%yaml-check-output writer (if multiline-p 3 2))
                  (setf rendered-key (%yaml-render-string writer key))
                  (when multiline-p
                    (%yaml-check-output
                     writer (* (length gap) (1+ (count #\Newline rendered)))))
                  (push (if multiline-p
                            (format nil "~a: ~%~a"
                                    rendered-key (%yaml-prefix-lines rendered gap))
                            (format nil "~a: ~a" rendered-key rendered))
                        parts))
                (incf count))))
          (if parts
              (format nil "~{~a~^~%~}" (nreverse parts))
              (progn (%yaml-check-output writer 2) "{}"))))))

(defun %yaml-gap (space)
  (setf space (%yaml-unwrap space))
  (cond
    ((eng:js-number-p space)
     (if (or (eng:js-nan-p space) (eng:js-infinite-p space) (< space 1d0))
         (if (and (eng:js-infinite-p space) (plusp space))
             (make-string 10 :initial-element #\Space)
             "")
         (make-string (min 10 (truncate space)) :initial-element #\Space)))
    ((stringp space) (subseq space 0 (min 10 (length space))))
    (t "")))

(defun %yaml-stringify (value replacer space)
  (unless (eng:js-nullish-p replacer)
    (eng:throw-native-error :error "YAML.stringify does not support the replacer argument"))
  (setf value (%yaml-unwrap value))
  (when (or (eng:js-undefined-p value) (eng:js-symbol-p value) (eng:callable-p value))
    (return-from %yaml-stringify eng:+undefined+))
  (let ((writer (make-yaml-writer :gap (%yaml-gap space))))
    (%yaml-discover writer value :root 0)
    (let ((result (%yaml-emit writer value 0)))
      (when (> (length result) +yaml-max-output-length+)
        (eng:throw-range-error "YAML.stringify output limit exceeded"))
      result)))

(defun make-clun-yaml ()
  (let ((namespace (eng:new-object)))
    (eng:data-prop
     namespace "parse"
     (eng:make-native-function
      "parse" 1
      (lambda (this args)
        (declare (ignore this))
        (eng::yaml-source->js (%yaml-input-string (eng:arg args 0))))))
    (eng:data-prop
     namespace "stringify"
     (eng:make-native-function
      "stringify" 3
      (lambda (this args)
        (declare (ignore this))
        (%yaml-stringify (eng:arg args 0) (eng:arg args 1) (eng:arg args 2)))))
    namespace))

(defun install-clun-yaml (clun)
  (eng:nonconfigurable-data-prop clun "YAML" (make-clun-yaml))
  clun)
