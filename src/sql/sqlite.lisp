;;;; sqlite.lisp — pure-CL SQLite-compatible embedded engine (Issue #183).
;;;; No foreign libraries / no libsqlite. Implements a practical SQL dialect sufficient for
;;;; Bun.SQL SQLite adapter parity plus Clun exceed features (inspect, export).

(in-package :clun.sql)

(defstruct (sqlite-column
            (:conc-name scol-)
            (:constructor make-sqlite-column (name &optional (type "ANY") (not-null nil) (pk nil) (default nil))))
  (name "" :type string)
  (type "ANY" :type string)
  (not-null nil)
  (pk nil)
  default)

(defstruct (sqlite-table
            (:conc-name stab-)
            (:constructor make-sqlite-table (name columns)))
  (name "" :type string)
  columns
  (rows nil)                           ; list of vectors
  (autoincrement 0 :type integer)
  (indexes nil))                       ; alist name -> column list

(defstruct (sqlite-db
            (:conc-name sdb-)
            (:constructor %make-sqlite-db))
  (filename ":memory:" :type string)
  (tables (make-hash-table :test #'equal))
  (in-transaction nil)
  (savepoints nil)
  (txn-snapshot nil)
  (readonly nil)
  (closed nil)
  (changes 0 :type integer)
  (last-insert-rowid 0 :type integer)
  (stats-queries 0 :type integer))

(defun %sqlite-error (message &key (code "SQLITE_ERROR") (errno 1) byte-offset)
  (raise-sql-error 'sqlite-error
                   :message message
                   :code code
                   :errno errno
                   :adapter :sqlite
                   :byte-offset byte-offset))

(defun open-sqlite (&key (filename ":memory:") readonly create)
  (declare (ignore create))
  (let ((db (%make-sqlite-db :filename filename :readonly readonly)))
    (unless (or (string= filename ":memory:")
                (zerop (length filename))
                readonly
                (not (probe-file filename)))
      (when (probe-file filename)
        (%sqlite-load db filename)))
    (when (and (not (string= filename ":memory:"))
               (probe-file filename)
               readonly)
      (%sqlite-load db filename))
    db))

(defun close-sqlite (db)
  (unless (sdb-closed db)
    (unless (or (sdb-readonly db)
                (string= (sdb-filename db) ":memory:"))
      (%sqlite-save db (sdb-filename db)))
    (setf (sdb-closed db) t))
  (values))

(defun %sqlite-save (db path)
  (let* ((payload
          (with-output-to-string (s)
            (format s "CLUN-SQLITE 1~%")
            (maphash
             (lambda (name table)
               (format s "TABLE ~A~%" name)
               (format s "COLUMNS ~A~%"
                       (format nil "~{~A~^,~}"
                               (mapcar (lambda (c)
                                         (format nil "~A:~A:~A:~A"
                                                 (scol-name c)
                                                 (scol-type c)
                                                 (if (scol-not-null c) "1" "0")
                                                 (if (scol-pk c) "1" "0")))
                                       (stab-columns table))))
               (format s "AUTO ~D~%" (stab-autoincrement table))
               (dolist (row (reverse (stab-rows table)))
                 (format s "ROW ~A~%"
                         (with-output-to-string (o)
                           (loop for i from 0 below (length row) do
                             (when (plusp i) (write-char #\Tab o))
                             (let ((v (aref row i)))
                               (cond
                                 ((null v) (write-string "\\N" o))
                                 ((integerp v) (format o "i:~D" v))
                                 ((floatp v) (format o "f:~F" v))
                                 ((typep v '(vector (unsigned-byte 8)))
                                  (format o "b:~A" (hex-encode v)))
                                 (t (format o "s:~A"
                                            (%sqlite-escape-cell
                                             (princ-to-string v)))))))))))
             (sdb-tables db))))
         (octets (utf8-bytes payload))
         (dir (clun.sys:path-dirname path)))
    (when (and dir (plusp (length dir)))
      (ensure-directories-exist
       (if (eql (char dir (1- (length dir))) #\/)
           dir
           (concatenate 'string dir "/"))))
    (clun.sys:write-file-octets path octets)))

(defun %sqlite-load (db path)
  (let* ((octets (clun.sys:read-file-octets path))
         (text (bytes-to-utf8 octets))
         (lines (split-char #\Newline text :remove-empty-subseqs t))
         (current nil))
    (unless (and lines (eql (search "CLUN-SQLITE" (first lines)) 0))
      (%sqlite-error "Not a Clun SQLite database file" :code "SQLITE_CORRUPT" :errno 11))
    (dolist (line (rest lines))
      (cond
        ((eql (search "TABLE " line) 0)
         (let ((name (subseq line 6)))
           (setf current (make-sqlite-table name '()))
           (setf (gethash (string-downcase name) (sdb-tables db)) current)))
        ((eql (search "COLUMNS " line) 0)
         (when current
           (setf (stab-columns current)
                 (mapcar
                  (lambda (spec)
                    (let ((parts (split-char #\: spec)))
                      (make-sqlite-column
                       (first parts)
                       (or (second parts) "ANY")
                       (equal (third parts) "1")
                       (equal (fourth parts) "1"))))
                  (split-char #\, (subseq line 8))))))
        ((eql (search "AUTO " line) 0)
         (when current
           (setf (stab-autoincrement current) (parse-integer (subseq line 5)))))
        ((eql (search "ROW " line) 0)
         (when current
           (let* ((cells (split-char #\Tab (subseq line 4)))
                  (row (make-array (length (stab-columns current))
                                   :initial-element nil)))
             (loop for cell in cells
                   for i from 0
                   while (< i (length row))
                   do (setf (aref row i)
                            (cond
                              ((string= cell "\\N") nil)
                              ((eql (search "i:" cell) 0)
                               (parse-integer cell :start 2))
                              ((eql (search "f:" cell) 0)
                               (read-from-string cell t nil :start 2))
                              ((eql (search "b:" cell) 0)
                               (hex-decode (subseq cell 2)))
                              ((eql (search "s:" cell) 0)
                               (%sqlite-unescape-cell (subseq cell 2)))
                              (t cell))))
             (push row (stab-rows current)))))))))

(defun %sqlite-escape-cell (s)
  (with-output-to-string (o)
    (loop for c across s
          do (case c
               ((#\Tab) (write-string "\\t" o))
               ((#\Newline) (write-string "\\n" o))
               ((#\\) (write-string "\\\\" o))
               (t (write-char c o))))))

(defun %sqlite-unescape-cell (s)
  (with-output-to-string (o)
    (loop with i = 0
          with n = (length s)
          while (< i n)
          do (let ((c (char s i)))
               (if (and (char= c #\\) (< (1+ i) n))
                   (let ((n2 (char s (1+ i))))
                     (write-char (case n2
                                   (#\t #\Tab)
                                   (#\n #\Newline)
                                   (t n2))
                                 o)
                     (incf i 2))
                   (progn (write-char c o) (incf i)))))))

;;; --- tokenizer / parser -----------------------------------------------------

(defun %sql-skip-ws (s i)
  (loop while (and (< i (length s))
                   (member (char s i) '(#\Space #\Tab #\Newline #\Return)))
        do (incf i))
  i)

(defun %sql-token (s i)
  (setf i (%sql-skip-ws s i))
  (when (>= i (length s))
    (return-from %sql-token (values :eof nil i)))
  (let ((c (char s i)))
    (cond
      ((char= c #\;) (values :semi nil (1+ i)))
      ((char= c #\,) (values :comma nil (1+ i)))
      ((char= c #\() (values :lparen nil (1+ i)))
      ((char= c #\)) (values :rparen nil (1+ i)))
      ((char= c #\*) (values :star nil (1+ i)))
      ((char= c #\=) (values :eq nil (1+ i)))
      ((char= c #\<)
       (if (and (< (1+ i) (length s)) (char= (char s (1+ i)) #\>))
           (values :ne nil (+ i 2))
           (if (and (< (1+ i) (length s)) (char= (char s (1+ i)) #\=))
               (values :le nil (+ i 2))
               (values :lt nil (1+ i)))))
      ((char= c #\>)
       (if (and (< (1+ i) (length s)) (char= (char s (1+ i)) #\=))
           (values :ge nil (+ i 2))
           (values :gt nil (1+ i))))
      ((char= c #\!)
       (if (and (< (1+ i) (length s)) (char= (char s (1+ i)) #\=))
           (values :ne nil (+ i 2))
           (%sqlite-error (format nil "Unexpected character ! at ~D" i)
                          :byte-offset i)))
      ((char= c #\?) (values :param nil (1+ i)))
      ((char= c #\$)
       (let ((j (1+ i)))
         (loop while (and (< j (length s)) (digit-char-p (char s j))) do (incf j))
         (values :param (parse-integer s :start (1+ i) :end j) j)))
      ((or (char= c #\') (char= c #\"))
       (let ((q c) (j (1+ i)) (chars '()))
         (loop while (< j (length s))
               do (let ((ch (char s j)))
                    (cond
                      ((char= ch q)
                       (if (and (< (1+ j) (length s)) (char= (char s (1+ j)) q))
                           (progn (push q chars) (incf j 2))
                           (return)))
                      (t (push ch chars) (incf j)))))
         (unless (< j (length s))
           (%sqlite-error "Unterminated string" :byte-offset i))
         (values (if (char= q #\") :ident :string)
                 (coerce (nreverse chars) 'string)
                 (1+ j))))
      ((or (digit-char-p c) (and (char= c #\-) (< (1+ i) (length s))
                                 (digit-char-p (char s (1+ i)))))
       (let ((j i))
         (when (char= (char s j) #\-) (incf j))
         (loop while (and (< j (length s)) (or (digit-char-p (char s j))
                                               (char= (char s j) #\.)))
               do (incf j))
         (let ((num (read-from-string s t nil :start i :end j)))
           (values :number num j))))
      ((alpha-char-p c)
       (let ((j i))
         (loop while (and (< j (length s))
                          (or (alphanumericp (char s j))
                              (member (char s j) '(#\_ #\.))))
               do (incf j))
         (let ((word (subseq s i j)))
           (values :ident word j))))
      (t (%sqlite-error (format nil "Unexpected character ~A at ~D" c i)
                        :byte-offset i)))))

(defun %sql-tokenize (s)
  (let ((tokens '()) (i 0))
    (loop
      (multiple-value-bind (kind value next) (%sql-token s i)
        (when (eq kind :eof)
          (return (nreverse tokens)))
        (push (cons kind value) tokens)
        (setf i next)))))

(defun %tok-kind (tok) (car tok))
(defun %tok-val (tok) (cdr tok))

(defun %expect (tokens kinds)
  (let ((tok (first tokens)))
    (unless (and tok (member (%tok-kind tok) kinds))
      (%sqlite-error (format nil "Expected ~A, got ~A" kinds (or tok :eof))))
    (values tok (rest tokens))))

(defun %ident-name (tok)
  (string-downcase (string (%tok-val tok))))

;;; --- execution --------------------------------------------------------------

(defun %table (db name)
  (or (gethash (string-downcase name) (sdb-tables db))
      (%sqlite-error (format nil "no such table: ~A" name)
                     :code "SQLITE_ERROR" :errno 1)))

(defun %col-index (table name)
  (let ((n (string-downcase name)))
    (or (position n (stab-columns table)
                  :key (lambda (c) (string-downcase (scol-name c)))
                  :test #'string=)
        (%sqlite-error (format nil "no such column: ~A" name)))))

(defun %row-object (table row)
  (let ((ht (make-hash-table :test #'equal)))
    (loop for col in (stab-columns table)
          for i from 0
          do (setf (gethash (scol-name col) ht) (aref row i)))
    ht))

(defun %eval-expr (table row expr params)
  "EXPR is a simplified tree: (:lit v) (:col name) (:param n) (:binop op a b)."
  (cond
    ((null expr) nil)
    ((eq (first expr) :lit) (second expr))
    ((eq (first expr) :col)
     (aref row (%col-index table (second expr))))
    ((eq (first expr) :param)
     (let ((n (second expr)))
       (if (integerp n)
           (nth (1- n) params)
           (pop params))))              ; positional ? consumes left-to-right — handled by caller
    ((eq (first expr) :binop)
     (let* ((op (second expr))
            (a (%eval-expr table row (third expr) params))
            (b (%eval-expr table row (fourth expr) params)))
       (ecase op
         (= (equal a b))
         ((/= !=) (not (equal a b)))
         (< (and a b (< a b)))
         (<= (and a b (<= a b)))
         (> (and a b (> a b)))
         (>= (and a b (>= a b)))
         (and (and a b))
         (or (or a b)))))
    (t nil)))

(defun %parse-value (tokens params param-idx)
  (declare (ignore params))
  (let ((tok (first tokens)))
    (case (%tok-kind tok)
      (:string (values (list :lit (%tok-val tok)) (rest tokens) param-idx))
      (:number (values (list :lit (%tok-val tok)) (rest tokens) param-idx))
      (:param
       (if (%tok-val tok)
           (values (list :param (%tok-val tok)) (rest tokens) param-idx)
           (progn
             (incf param-idx)
             (values (list :param param-idx) (rest tokens) param-idx))))
      (:ident
       (let ((name (%tok-val tok)))
         (cond
           ((equalp name "null")
            (values (list :lit nil) (rest tokens) param-idx))
           ((equalp name "true")
            (values (list :lit 1) (rest tokens) param-idx))
           ((equalp name "false")
            (values (list :lit 0) (rest tokens) param-idx))
           (t (values (list :col name) (rest tokens) param-idx)))))
      (t (%sqlite-error "Expected value")))))

(defun %parse-condition (tokens params &key (start-param 0))
  "Parse simple WHERE: col OP value [AND/OR ...].
   START-PARAM is the number of ? placeholders already consumed (e.g. by SET)."
  (declare (ignore params))
  (let ((param-idx start-param)
        (left nil)
        (rest tokens))
    (labels ((parse-cmp ()
               (multiple-value-bind (lhs r1 p1) (%parse-value rest nil param-idx)
                 (setf param-idx p1)
                 (let ((op-tok (first r1)))
                   (unless (member (%tok-kind op-tok) '(:eq :ne :lt :le :gt :ge))
                     (%sqlite-error "Expected comparison operator"))
                   (let ((op (case (%tok-kind op-tok)
                               (:eq '=) (:ne '/=) (:lt '<) (:le '<=) (:gt '>) (:ge '>=))))
                     (multiple-value-bind (rhs r2 p2)
                         (%parse-value (rest r1) nil param-idx)
                       (setf param-idx p2 rest r2)
                       (list :binop op lhs rhs)))))))
      (setf left (parse-cmp))
      (loop while (and rest (eq (%tok-kind (first rest)) :ident)
                       (member (%tok-val (first rest)) '("and" "or") :test #'equalp))
            do (let ((lop (if (equalp (%tok-val (first rest)) "and") 'and 'or)))
                 (setf rest (rest rest)
                       left (list :binop lop left (parse-cmp)))))
      (values left rest))))

(defun %bind-params (params)
  "Normalize params list (may contain sql-array-parameter)."
  (mapcar (lambda (p)
            (if (sql-array-parameter-p p)
                (arr-values p)
                p))
          params))

(defun sqlite-exec (db sql &optional params)
  "Execute SQL against DB. Returns a result plist:
   (:columns names :rows list-of-hash-tables :values list-of-vectors
    :changes n :last-insert-rowid id)"
  (when (sdb-closed db)
    (%sqlite-error "database is closed" :code "SQLITE_MISUSE" :errno 21))
  (incf (sdb-stats-queries db))
  (let* ((params (%bind-params params))
         (tokens (%sql-tokenize sql))
         (cmd (first tokens)))
    (unless cmd
      (return-from sqlite-exec
        (list :columns '() :rows '() :values '() :changes 0
              :last-insert-rowid (sdb-last-insert-rowid db))))
    (unless (eq (%tok-kind cmd) :ident)
      (%sqlite-error "Expected SQL statement"))
    (let ((op (string-upcase (%tok-val cmd)))
          (rest (rest tokens)))
      (cond
        ((string= op "BEGIN")
         (when (sdb-in-transaction db)
           (%sqlite-error "cannot start a transaction within a transaction"))
         (setf (sdb-in-transaction db) t
               (sdb-txn-snapshot db) (%sqlite-snapshot db)
               (sdb-savepoints db) '())
         (list :columns '() :rows '() :values '() :changes 0
               :last-insert-rowid (sdb-last-insert-rowid db)))

        ((string= op "COMMIT")
         (unless (sdb-in-transaction db)
           (%sqlite-error "cannot commit - no transaction is active"))
         (setf (sdb-in-transaction db) nil
               (sdb-txn-snapshot db) nil
               (sdb-savepoints db) '())
         (unless (or (sdb-readonly db)
                     (string= (sdb-filename db) ":memory:"))
           (%sqlite-save db (sdb-filename db)))
         (list :columns '() :rows '() :values '() :changes 0
               :last-insert-rowid (sdb-last-insert-rowid db)))

        ((string= op "ROLLBACK")
         (cond
           ((and rest (eq (%tok-kind (first rest)) :ident)
                 (equalp (%tok-val (first rest)) "TO"))
            (let* ((sp-tok (third rest))
                   (name (string-downcase (%tok-val sp-tok)))
                   (snap (cdr (assoc name (sdb-savepoints db) :test #'string=))))
              (unless snap
                (%sqlite-error (format nil "no such savepoint: ~A" name)))
              (%sqlite-restore db snap)
              (setf (sdb-savepoints db)
                    (member name (sdb-savepoints db) :key #'car :test #'string=))))
           (t
            (unless (sdb-in-transaction db)
              (%sqlite-error "cannot rollback - no transaction is active"))
            (%sqlite-restore db (sdb-txn-snapshot db))
            (setf (sdb-in-transaction db) nil
                  (sdb-txn-snapshot db) nil
                  (sdb-savepoints db) '())))
         (list :columns '() :rows '() :values '() :changes 0
               :last-insert-rowid (sdb-last-insert-rowid db)))

        ((string= op "SAVEPOINT")
         (let ((name (string-downcase (%tok-val (first rest)))))
           (push (cons name (%sqlite-snapshot db)) (sdb-savepoints db))
           (list :columns '() :rows '() :values '() :changes 0
                 :last-insert-rowid (sdb-last-insert-rowid db))))

        ((string= op "RELEASE")
         (let* ((toks rest)
                (name-tok (if (and toks (equalp (%tok-val (first toks)) "SAVEPOINT"))
                              (second toks)
                              (first toks)))
                (name (string-downcase (%tok-val name-tok))))
           (setf (sdb-savepoints db)
                 (remove name (sdb-savepoints db) :key #'car :test #'string=))
           (list :columns '() :rows '() :values '() :changes 0
                 :last-insert-rowid (sdb-last-insert-rowid db))))

        ((string= op "CREATE")
         (%sqlite-create db rest))

        ((string= op "DROP")
         (%sqlite-drop db rest))

        ((string= op "INSERT")
         (%sqlite-insert db rest params))

        ((string= op "UPDATE")
         (%sqlite-update db rest params))

        ((string= op "DELETE")
         (%sqlite-delete db rest params))

        ((string= op "SELECT")
         (%sqlite-select db tokens params))

        ((string= op "PRAGMA")
         (%sqlite-pragma db rest))

        ((string= op "EXPLAIN")
         (list :columns '("detail")
               :rows (list (let ((ht (make-hash-table :test #'equal)))
                             (setf (gethash "detail" ht)
                                   (format nil "clun-sqlite plan for: ~A" sql))
                             ht))
               :values (list (vector (format nil "clun-sqlite plan for: ~A" sql)))
               :changes 0
               :last-insert-rowid (sdb-last-insert-rowid db)))

        (t (%sqlite-error (format nil "unsupported statement: ~A" op)))))))

(defun %sqlite-snapshot (db)
  (let ((snap (make-hash-table :test #'equal)))
    (maphash
     (lambda (k table)
       (setf (gethash k snap)
             (list :columns (mapcar #'copy-structure (stab-columns table))
                   :rows (mapcar #'copy-seq (stab-rows table))
                   :auto (stab-autoincrement table))))
     (sdb-tables db))
    snap))

(defun %sqlite-restore (db snap)
  (clrhash (sdb-tables db))
  (maphash
   (lambda (k data)
     (let ((table (make-sqlite-table k (getf data :columns))))
       (setf (stab-rows table) (mapcar #'copy-seq (getf data :rows))
             (stab-autoincrement table) (getf data :auto)
             (gethash k (sdb-tables db)) table)))
   snap))

(defun %sqlite-create (db tokens)
  (let* ((tok (first tokens))
         (if-not-exists nil))
    (when (and tok (eq (%tok-kind tok) :ident) (equalp (%tok-val tok) "TABLE"))
      (setf tokens (rest tokens)))
    (when (and tokens (eq (%tok-kind (first tokens)) :ident)
               (equalp (%tok-val (first tokens)) "IF"))
      (setf tokens (cdddr tokens)       ; IF NOT EXISTS
            if-not-exists t))
    (let* ((name-tok (first tokens))
           (name (string-downcase (%tok-val name-tok)))
           (rest (rest tokens)))
      (when (and if-not-exists (gethash name (sdb-tables db)))
        (return-from %sqlite-create
          (list :columns '() :rows '() :values '() :changes 0
                :last-insert-rowid (sdb-last-insert-rowid db))))
      (when (gethash name (sdb-tables db))
        (%sqlite-error (format nil "table ~A already exists" name)))
      (multiple-value-bind (_ rest2) (%expect rest '(:lparen))
        (declare (ignore _))
        (let ((cols '()))
          (loop
            (let* ((c-tok (first rest2))
                   (cname (%tok-val c-tok))
                   (rest3 (rest rest2))
                   (ctype "ANY")
                   (not-null nil)
                   (pk nil))
              (when (and rest3 (eq (%tok-kind (first rest3)) :ident)
                         (not (member (%tok-val (first rest3))
                                      '("PRIMARY" "NOT" "NULL" "UNIQUE" "DEFAULT")
                                      :test #'equalp)))
                (setf ctype (%tok-val (first rest3))
                      rest3 (rest rest3)))
              (loop while (and rest3 (eq (%tok-kind (first rest3)) :ident))
                    do (let ((w (string-upcase (%tok-val (first rest3)))))
                         (cond
                           ((string= w "PRIMARY")
                            (setf rest3 (rest rest3))
                            (when (and rest3 (equalp (%tok-val (first rest3)) "KEY"))
                              (setf rest3 (rest rest3) pk t)))
                           ((string= w "NOT")
                            (setf rest3 (rest rest3))
                            (when (and rest3 (equalp (%tok-val (first rest3)) "NULL"))
                              (setf rest3 (rest rest3) not-null t)))
                           ((string= w "NULL") (setf rest3 (rest rest3)))
                           ((string= w "UNIQUE") (setf rest3 (rest rest3)))
                           ((string= w "DEFAULT")
                            (setf rest3 (cddr rest3)))
                           (t (return)))))
              (push (make-sqlite-column cname ctype not-null pk) cols)
              (cond
                ((and rest3 (eq (%tok-kind (first rest3)) :comma))
                 (setf rest2 (rest rest3)))
                ((and rest3 (eq (%tok-kind (first rest3)) :rparen))
                 (setf rest2 (rest rest3))
                 (return))
                (t (%sqlite-error "Expected , or ) in CREATE TABLE")))))
          (setf (gethash name (sdb-tables db))
                (make-sqlite-table name (nreverse cols)))
          (list :columns '() :rows '() :values '() :changes 0
                :last-insert-rowid (sdb-last-insert-rowid db)))))))

(defun %sqlite-drop (db tokens)
  (when (and tokens (equalp (%tok-val (first tokens)) "TABLE"))
    (setf tokens (rest tokens)))
  (let ((if-exists nil))
    (when (and tokens (equalp (%tok-val (first tokens)) "IF"))
      (setf tokens (cddr tokens) if-exists t)) ; IF EXISTS
    (let ((name (string-downcase (%tok-val (first tokens)))))
      (if (gethash name (sdb-tables db))
          (remhash name (sdb-tables db))
          (unless if-exists
            (%sqlite-error (format nil "no such table: ~A" name))))
      (list :columns '() :rows '() :values '() :changes 0
            :last-insert-rowid (sdb-last-insert-rowid db)))))

(defun %sqlite-insert (db tokens params)
  (when (sdb-readonly db)
    (%sqlite-error "attempt to write a readonly database" :code "SQLITE_READONLY" :errno 8))
  (when (and tokens (equalp (%tok-val (first tokens)) "INTO"))
    (setf tokens (rest tokens)))
  (let* ((name (string-downcase (%tok-val (first tokens))))
         (table (%table db name))
         (rest (rest tokens))
         (col-names nil)
         (param-i 0))
    (when (and rest (eq (%tok-kind (first rest)) :lparen))
      (setf rest (rest rest) col-names '())
      (loop
        (push (%tok-val (first rest)) col-names)
        (setf rest (rest rest))
        (if (eq (%tok-kind (first rest)) :comma)
            (setf rest (rest rest))
            (progn
              (setf rest (rest rest))   ; )
              (return))))
      (setf col-names (nreverse col-names)))
    (unless (and rest (equalp (%tok-val (first rest)) "VALUES"))
      (%sqlite-error "Expected VALUES"))
    (setf rest (rest rest))
    (let ((changes 0) (last-id (sdb-last-insert-rowid db)))
      (loop while (and rest (eq (%tok-kind (first rest)) :lparen))
            do (setf rest (rest rest))
               (let ((vals '())
                     (row (make-array (length (stab-columns table)) :initial-element nil)))
                 (loop
                   (let ((tok (first rest)))
                     (case (%tok-kind tok)
                       (:string (push (%tok-val tok) vals) (setf rest (rest rest)))
                       (:number (push (%tok-val tok) vals) (setf rest (rest rest)))
                       (:param
                        (let ((n (or (%tok-val tok) (progn (incf param-i) param-i))))
                          (push (nth (1- n) params) vals)
                          (setf rest (rest rest))))
                       (:ident
                        (if (equalp (%tok-val tok) "null")
                            (push nil vals)
                            (push (%tok-val tok) vals))
                        (setf rest (rest rest)))
                       (t (%sqlite-error "Expected value in INSERT"))))
                   (if (eq (%tok-kind (first rest)) :comma)
                       (setf rest (rest rest))
                       (progn (setf rest (rest rest)) (return)))) ; )
                 (setf vals (nreverse vals))
                 (if col-names
                     (loop for c in col-names for v in vals
                           do (setf (aref row (%col-index table c)) v))
                     (loop for i from 0 for v in vals
                           while (< i (length row))
                           do (setf (aref row i) v)))
                 ;; INTEGER PRIMARY KEY autoincrement
                 (loop for col in (stab-columns table)
                       for i from 0
                       when (and (scol-pk col)
                                 (null (aref row i))
                                 (search "INT" (string-upcase (scol-type col))))
                         do (incf (stab-autoincrement table))
                            (setf (aref row i) (stab-autoincrement table)
                                  last-id (stab-autoincrement table)))
                 (push row (stab-rows table))
                 (incf changes))
               (when (and rest (eq (%tok-kind (first rest)) :comma))
                 (setf rest (rest rest))))
      (setf (sdb-changes db) changes
            (sdb-last-insert-rowid db) last-id)
      (list :columns '() :rows '() :values '() :changes changes
            :last-insert-rowid last-id))))

(defun %sqlite-update (db tokens params)
  (when (sdb-readonly db)
    (%sqlite-error "attempt to write a readonly database" :code "SQLITE_READONLY" :errno 8))
  (let* ((name (string-downcase (%tok-val (first tokens))))
         (table (%table db name))
         (rest (rest tokens))
         (param-i 0)
         (sets '()))
    (unless (and rest (equalp (%tok-val (first rest)) "SET"))
      (%sqlite-error "Expected SET"))
    (setf rest (rest rest))
    (loop
      (let ((col (%tok-val (first rest))))
        (setf rest (rest rest))
        (unless (eq (%tok-kind (first rest)) :eq)
          (%sqlite-error "Expected = in SET"))
        (setf rest (rest rest))
        (let ((tok (first rest)))
          (let ((val (case (%tok-kind tok)
                       (:string (%tok-val tok))
                       (:number (%tok-val tok))
                       (:param
                        (let ((n (or (%tok-val tok) (progn (incf param-i) param-i))))
                          (nth (1- n) params)))
                       (:ident (if (equalp (%tok-val tok) "null") nil (%tok-val tok)))
                       (t (%sqlite-error "Expected value in SET")))))
            (push (cons col val) sets)
            (setf rest (rest rest)))))
      (if (and rest (eq (%tok-kind (first rest)) :comma))
          (setf rest (rest rest))
          (return)))
    (let ((where nil))
      (when (and rest (equalp (%tok-val (first rest)) "WHERE"))
        (multiple-value-bind (expr r2)
            (%parse-condition (rest rest) params :start-param param-i)
          (setf where expr rest r2)))
      (let ((changes 0))
        (dolist (row (stab-rows table))
          (when (or (null where) (%eval-expr table row where params))
            (dolist (pair sets)
              (setf (aref row (%col-index table (car pair))) (cdr pair)))
            (incf changes)))
        (setf (sdb-changes db) changes)
        (list :columns '() :rows '() :values '() :changes changes
              :last-insert-rowid (sdb-last-insert-rowid db))))))

(defun %sqlite-delete (db tokens params)
  (when (sdb-readonly db)
    (%sqlite-error "attempt to write a readonly database" :code "SQLITE_READONLY" :errno 8))
  (when (and tokens (equalp (%tok-val (first tokens)) "FROM"))
    (setf tokens (rest tokens)))
  (let* ((name (string-downcase (%tok-val (first tokens))))
         (table (%table db name))
         (rest (rest tokens))
         (where nil))
    (when (and rest (equalp (%tok-val (first rest)) "WHERE"))
      (multiple-value-bind (expr r2) (%parse-condition (rest rest) params)
        (setf where expr rest r2)))
    (let* ((kept '())
           (changes 0))
      (dolist (row (stab-rows table))
        (if (and where (%eval-expr table row where params))
            (incf changes)
            (push row kept)))
      (setf (stab-rows table) (nreverse kept)
            (sdb-changes db) changes)
      (list :columns '() :rows '() :values '() :changes changes
            :last-insert-rowid (sdb-last-insert-rowid db)))))

(defun %sqlite-select (db tokens params)
  ;; tokens start with SELECT
  (let* ((rest (rest tokens))
         (star nil)
         (select-cols '())
         (from nil)
         (where nil)
         (limit nil)
         (offset 0)
         (param-i 0))
    (if (eq (%tok-kind (first rest)) :star)
        (setf star t rest (rest rest))
        (loop
          (push (%tok-val (first rest)) select-cols)
          (setf rest (rest rest))
          (if (and rest (eq (%tok-kind (first rest)) :comma))
              (setf rest (rest rest))
              (return))))
    (setf select-cols (nreverse select-cols))
    (unless (and rest (equalp (%tok-val (first rest)) "FROM"))
      (%sqlite-error "Expected FROM"))
    (setf rest (rest rest)
          from (string-downcase (%tok-val (first rest)))
          rest (rest rest))
    (when (and rest (equalp (%tok-val (first rest)) "WHERE"))
      (multiple-value-bind (expr r2) (%parse-condition (rest rest) params)
        (setf where expr rest r2)))
    (when (and rest (equalp (%tok-val (first rest)) "LIMIT"))
      (setf rest (rest rest))
      (let ((tok (first rest)))
        (setf limit (if (eq (%tok-kind tok) :param)
                        (nth (1- (or (%tok-val tok) (progn (incf param-i) param-i))) params)
                        (%tok-val tok))
              rest (rest rest))))
    (when (and rest (equalp (%tok-val (first rest)) "OFFSET"))
      (setf rest (rest rest))
      (let ((tok (first rest)))
        (setf offset (if (eq (%tok-kind tok) :param)
                         (nth (1- (or (%tok-val tok) (progn (incf param-i) param-i))) params)
                         (%tok-val tok)))))
    (let* ((table (%table db from))
           (cols (if star
                     (mapcar #'scol-name (stab-columns table))
                     select-cols))
           (matched '())
           (skipped 0))
      (dolist (row (reverse (stab-rows table)))
        (when (or (null where) (%eval-expr table row where params))
          (if (< skipped offset)
              (incf skipped)
              (progn
                (push row matched)
                (when (and limit (>= (length matched) limit))
                  (return))))))
      (setf matched (nreverse matched))
      (let ((objects '())
            (values '()))
        (dolist (row matched)
          (let ((ht (make-hash-table :test #'equal))
                (vec (make-array (length cols))))
            (loop for c in cols for i from 0
                  for idx = (%col-index table c)
                  do (setf (gethash c ht) (aref row idx)
                           (aref vec i) (aref row idx)))
            (push ht objects)
            (push vec values)))
        (list :columns cols
              :rows (nreverse objects)
              :values (nreverse values)
              :changes 0
              :last-insert-rowid (sdb-last-insert-rowid db))))))

(defun %sqlite-pragma (db tokens)
  (let ((name (string-downcase (%tok-val (first tokens)))))
    (cond
      ((string= name "table_list")
       (let ((cols '("schema" "name" "type" "ncol" "wr" "strict"))
             (rows '()))
         (maphash
          (lambda (k table)
            (let ((ht (make-hash-table :test #'equal)))
              (setf (gethash "schema" ht) "main"
                    (gethash "name" ht) k
                    (gethash "type" ht) "table"
                    (gethash "ncol" ht) (length (stab-columns table))
                    (gethash "wr" ht) 0
                    (gethash "strict" ht) 0)
              (push ht rows)))
          (sdb-tables db))
         (list :columns cols :rows (nreverse rows)
               :values (mapcar (lambda (ht)
                                 (map 'vector (lambda (c) (gethash c ht)) cols))
                               (nreverse rows))
               :changes 0 :last-insert-rowid 0)))
      ((string= name "table_info")
       ;; PRAGMA table_info(name)
       (let* ((rest (rest tokens))
              (tname (string-downcase
                      (if (eq (%tok-kind (first rest)) :lparen)
                          (%tok-val (second rest))
                          (%tok-val (first rest)))))
              (table (%table db tname))
              (cols '("cid" "name" "type" "notnull" "dflt_value" "pk"))
              (rows '()))
         (loop for col in (stab-columns table) for i from 0
               do (let ((ht (make-hash-table :test #'equal)))
                    (setf (gethash "cid" ht) i
                          (gethash "name" ht) (scol-name col)
                          (gethash "type" ht) (scol-type col)
                          (gethash "notnull" ht) (if (scol-not-null col) 1 0)
                          (gethash "dflt_value" ht) (scol-default col)
                          (gethash "pk" ht) (if (scol-pk col) 1 0))
                    (push ht rows)))
         (list :columns cols :rows (nreverse rows)
               :values (mapcar (lambda (ht)
                                 (map 'vector (lambda (c) (gethash c ht)) cols))
                               (reverse rows))
               :changes 0 :last-insert-rowid 0)))
      (t
       (list :columns '("pragma")
             :rows (list (let ((ht (make-hash-table :test #'equal)))
                           (setf (gethash "pragma" ht) name) ht))
             :values (list (vector name))
             :changes 0 :last-insert-rowid 0)))))

(defun sqlite-inspect (db)
  "Exceed Bun: structured schema inspection."
  (let ((tables '()))
    (maphash
     (lambda (name table)
       (push (list :name name
                   :columns (mapcar (lambda (c)
                                      (list :name (scol-name c)
                                            :type (scol-type c)
                                            :not-null (scol-not-null c)
                                            :pk (scol-pk c)))
                                    (stab-columns table))
                   :row-count (length (stab-rows table)))
             tables))
     (sdb-tables db))
    (list :adapter :sqlite
          :filename (sdb-filename db)
          :tables (sort tables #'string< :key (lambda (tbl) (getf tbl :name)))
          :queries (sdb-stats-queries db))))

(defun sqlite-export-json (db)
  "Exceed Bun: dump entire database as a JSON-friendly alist tree."
  (let ((tables '()))
    (maphash
     (lambda (name table)
       (push
        (list :name name
              :columns (mapcar #'scol-name (stab-columns table))
              :rows (mapcar (lambda (row)
                              (loop for col in (stab-columns table)
                                    for i from 0
                                    collect (cons (scol-name col) (aref row i))))
                            (reverse (stab-rows table))))
        tables))
     (sdb-tables db))
    tables))
