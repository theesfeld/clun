;;;; query.lisp — tagged-template helpers, fragments, array params, unsafe.

(in-package :clun.sql)

(defstruct (sql-fragment
            (:conc-name frag-)
            (:constructor make-sql-fragment (sql &optional (params nil))))
  (sql "" :type string)
  (params nil :type list))

(defstruct (sql-helper
            (:conc-name helper-)
            (:constructor make-sql-helper (value &optional columns)))
  value
  columns)

(defstruct (sql-array-parameter
            (:conc-name arr-)
            (:constructor make-sql-array-parameter (values &optional (array-type "JSON"))))
  values
  (array-type "JSON" :type string)
  (serialized-values "" :type string))

(defstruct (sql-query
            (:conc-name query-)
            (:constructor %make-sql-query))
  client
  sql
  params
  (mode :objects)                      ; :objects | :values | :raw
  (simple nil)
  (active nil)
  (cancelled nil)
  (result nil)
  (error nil))

(defun %ident-quote (adapter name)
  (let ((s (string name)))
    (ecase adapter
      ((:postgres :sqlite)
       (format nil "\"~A\""
               (with-output-to-string (o)
                 (loop for c across s
                       do (write-char c o)
                          (when (char= c #\") (write-char #\" o))))))
      (:mysql
       (format nil "`~A`"
               (with-output-to-string (o)
                 (loop for c across s
                       do (write-char c o)
                          (when (char= c #\`) (write-char #\` o)))))))))

(defun %sql-literal (adapter value)
  "Serialize VALUE as a SQL literal for ADAPTER (used by helpers / unsafe paths)."
  (cond
    ((null value) "NULL")
    ((eq value t)
     (ecase adapter (:mysql "1") ((:postgres :sqlite) "TRUE")))
    ((eq value :false)
     (ecase adapter (:mysql "0") ((:postgres :sqlite) "FALSE")))
    ((stringp value)
     (format nil "'~A'"
             (with-output-to-string (o)
               (loop for c across value
                     do (if (char= c #\')
                            (write-string "''" o)
                            (write-char c o))))))
    ((integerp value) (princ-to-string value))
    ((floatp value) (format nil "~F" value))
    ((typep value '(vector (unsigned-byte 8)))
     (ecase adapter
       (:postgres (format nil "'\\x~A'" (hex-encode value)))
       (:mysql (format nil "X'~A'" (hex-encode value)))
       (:sqlite (format nil "X'~A'" (hex-encode value)))))
    ((sql-array-parameter-p value)
     (let ((inner (mapcar (lambda (v) (%sql-literal adapter v)) (arr-values value))))
       (ecase adapter
         (:postgres (format nil "ARRAY[~{~A~^,~}]::~A[]"
                            inner (arr-array-type value)))
         ((:mysql :sqlite) (format nil "(~{~A~^,~})" inner)))))
    ((listp value)
     (format nil "(~{~A~^,~})" (mapcar (lambda (v) (%sql-literal adapter v)) value)))
    (t (%sql-literal adapter (princ-to-string value)))))

(defun serialize-array-parameter (param &optional (array-type "JSON"))
  (let ((p (if (sql-array-parameter-p param)
               param
               (make-sql-array-parameter (coerce param 'list) array-type))))
    (setf (arr-serialized-values p)
          (format nil "{~{~A~^,~}}"
                  (mapcar (lambda (v)
                            (cond
                              ((null v) "NULL")
                              ((stringp v) (format nil "\"~A\"" v))
                              (t (princ-to-string v))))
                          (arr-values p))))
    p))

(defun build-helper-sql (adapter helper context)
  "CONTEXT is :insert | :update | :in | :ident."
  (let* ((value (helper-value helper))
         (columns (helper-columns helper)))
    (cond
      ((stringp value)
       (make-sql-fragment (%ident-quote adapter value)))
      ((and (listp value) (every #'atom value) (not (and value (keywordp (car value)))))
       ;; scalar list → IN (...)
       (make-sql-fragment
        (format nil "(~{~A~^,~})"
                (loop for i from 1 to (length value) collect
                      (ecase adapter
                        (:postgres (format nil "$~D" i))
                        ((:mysql :sqlite) "?"))))
        (copy-list value)))
      ((or (hash-table-p value)
           (and (listp value) (or (null value) (keywordp (car value)) (consp (car value)))))
       (let* ((rows (if (and (listp value) (consp (car value)) (not (keywordp (car value))))
                        value
                        (list value)))
              (cols (or columns
                        (mapcar (lambda (k) (if (keywordp k) (string-downcase (symbol-name k)) (string k)))
                                (if (hash-table-p (first rows))
                                    (loop for k being the hash-keys of (first rows) collect k)
                                    (loop for (k) on (first rows) by #'cddr collect k)))))
              (col-names (mapcar (lambda (c) (%ident-quote adapter c)) cols)))
         (ecase context
           (:insert
            (let ((params '())
                  (value-groups '()))
              (dolist (row rows)
                (let ((vals '()))
                  (dolist (c cols)
                    (let ((v (if (hash-table-p row)
                                 (or (gethash c row)
                                     (gethash (intern (string-upcase c) :keyword) row))
                                 (getf row (intern (string-upcase c) :keyword)
                                       (getf row (intern (string c) :keyword))))))
                      (push v params)
                      (push (ecase adapter
                              (:postgres (format nil "$~D" (length params)))
                              ((:mysql :sqlite) "?"))
                            vals)))
                  (push (format nil "(~{~A~^,~})" (nreverse vals)) value-groups)))
              (make-sql-fragment
               (format nil "(~{~A~^,~}) VALUES ~{~A~^,~}"
                       col-names (nreverse value-groups))
               (nreverse params))))
           (:update
            (let ((params '())
                  (sets '()))
              (let ((row (first rows)))
                (dolist (c cols)
                  (let ((v (if (hash-table-p row)
                               (or (gethash c row)
                                   (gethash (intern (string-upcase c) :keyword) row))
                               (getf row (intern (string-upcase c) :keyword)
                                     (getf row (intern (string c) :keyword))))))
                    (push v params)
                    (push (format nil "~A = ~A"
                                  (%ident-quote adapter c)
                                  (ecase adapter
                                    (:postgres (format nil "$~D" (length params)))
                                    ((:mysql :sqlite) "?")))
                          sets))))
              (make-sql-fragment (format nil "~{~A~^, ~}" (nreverse sets))
                                 (nreverse params))))
           (t (make-sql-fragment (%sql-literal adapter value))))))
      (t (make-sql-fragment (%sql-literal adapter value))))))

(defun %replace-all (string old new)
  (let ((out (make-array (length string) :element-type 'character
                         :adjustable t :fill-pointer 0))
        (i 0)
        (n (length string))
        (olen (length old)))
    (loop while (< i n)
          do (if (and (<= (+ i olen) n)
                      (string= string old :start1 i :end1 (+ i olen)))
                 (progn
                   (loop for c across new do (vector-push-extend c out))
                   (incf i olen))
                 (progn
                   (vector-push-extend (char string i) out)
                   (incf i))))
    (coerce out 'string)))

(defun compile-template (adapter strings values)
  "Compile tagged-template STRINGS + VALUES into (values sql params).
   STRINGS is a list of string parts (like TemplateStringsArray).
   VALUES may include fragments, helpers, arrays, or scalars."
  (let ((sql-parts '())
        (params '())
        (param-n 0))
    (labels ((ph ()
               (incf param-n)
               (ecase adapter
                 (:postgres (format nil "$~D" param-n))
                 ((:mysql :sqlite) "?")))
             (emit-value (v)
               (cond
                 ((sql-fragment-p v)
                  (let ((inner (frag-sql v))
                        (ip (frag-params v)))
                    ;; renumber $n for postgres when embedding fragment params
                    (if (and (eq adapter :postgres) ip)
                        (let ((rewritten inner)
                              (base param-n))
                          (loop for i from (length ip) downto 1
                                do (setf rewritten
                                         (%replace-all
                                          rewritten
                                          (format nil "$~D" i)
                                          (format nil "$~D" (+ base i)))))
                          (incf param-n (length ip))
                          (setf params (append params ip))
                          (push rewritten sql-parts))
                        (progn
                          (setf params (append params ip))
                          (incf param-n (length ip))
                          (push inner sql-parts)))))
                 ((sql-helper-p v)
                  (let* ((ctx (cond
                                ((and (stringp (helper-value v))) :ident)
                                ((and (listp (helper-value v))
                                      (every #'atom (helper-value v))
                                      (not (keywordp (car (helper-value v)))))
                                 :in)
                                (t :insert)))
                         (frag (build-helper-sql adapter v ctx)))
                    (emit-value frag)))
                 ((sql-array-parameter-p v)
                  (push (ph) sql-parts)
                  (setf params (append params (list v))))
                 (t
                  (push (ph) sql-parts)
                  (setf params (append params (list v)))))))
      (loop for i from 0
            for part in strings
            do (push part sql-parts)
               (when (< i (length values))
                 (emit-value (nth i values))))
      (values (apply #'concatenate 'string (nreverse sql-parts))
              params))))

(defun compile-unsafe (sql &optional values)
  (values sql (or values '())))
