;;;; sql-tests.lisp — pure-CL SQL drivers full port (Issue #183).

(in-package :clun-test)

(defun %sql-err (thunk)
  (handler-case (progn (funcall thunk) nil)
    (clun.sql:sql-error (c) c)))

(define-test sql/url-parse-sqlite
  (let ((o (clun.sql:parse-sql-url "sqlite://:memory:")))
    (is eq :sqlite (clun.sql:so-adapter o))
    (is string= ":memory:" (clun.sql:so-filename o)))
  (let ((o (clun.sql:parse-sql-url ":memory:")))
    (is eq :sqlite (clun.sql:so-adapter o)))
  (let ((o (clun.sql:parse-sql-url "postgres://alice:s3cret@db.example:5433/app?max=5")))
    (is eq :postgres (clun.sql:so-adapter o))
    (is string= "alice" (clun.sql:so-username o))
    (is string= "s3cret" (clun.sql:so-password o))
    (is string= "db.example" (clun.sql:so-hostname o))
    (is = 5433 (clun.sql:so-port o))
    (is string= "app" (clun.sql:so-database o))
    (is = 5 (clun.sql:so-max o)))
  (let ((o (clun.sql:parse-sql-url "mysql://root@localhost/test")))
    (is eq :mysql (clun.sql:so-adapter o))
    (is = 3306 (clun.sql:so-port o))
    (is string= "test" (clun.sql:so-database o))))

(define-test sql/sqlite-crud-transactions
  (let ((sql (clun.sql:make-sql-client "sqlite://:memory:")))
    (clun.sql:sql-execute sql
     "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER)")
    (clun.sql:sql-execute sql "INSERT INTO users (name, age) VALUES (?, ?)"
                          (list "Ada" 36))
    (clun.sql:sql-execute sql "INSERT INTO users (name, age) VALUES (?, ?)"
                          (list "Grace" 45))
    (let ((rows (clun.sql:result-rows
                 (clun.sql:sql-execute sql "SELECT * FROM users WHERE age > ?" (list 40)))))
      (is = 1 (length rows))
      (is string= "Grace" (gethash "name" (first rows))))
    (clun.sql:sql-execute sql "UPDATE users SET age = ? WHERE name = ?"
                          (list 37 "Ada"))
    (let ((row (clun.sql:result-first
                (clun.sql:sql-execute sql "SELECT age FROM users WHERE name = ?"
                                      (list "Ada")))))
      (is = 37 (gethash "age" row)))
    (clun.sql:sql-begin sql
                        (lambda (tx)
                          (clun.sql:sql-execute tx
                           "INSERT INTO users (name, age) VALUES (?, ?)"
                           (list "TxUser" 1))
                          (clun.sql:sql-execute tx "DELETE FROM users WHERE name = ?"
                                                (list "Grace"))))
    (let ((all (clun.sql:result-rows
                (clun.sql:sql-execute sql "SELECT name FROM users"))))
      (is = 2 (length all))
      (true (find "TxUser" all :key (lambda (r) (gethash "name" r)) :test #'string=))
      (false (find "Grace" all :key (lambda (r) (gethash "name" r)) :test #'string=)))
    ;; rollback path
    (handler-case
        (clun.sql:sql-begin sql
                            (lambda (tx)
                              (clun.sql:sql-execute tx
                               "INSERT INTO users (name, age) VALUES (?, ?)"
                               (list "RollbackMe" 9))
                              (error "boom")))
      (error ()))
    (let ((all (clun.sql:result-rows
                (clun.sql:sql-execute sql "SELECT name FROM users WHERE name = ?"
                                      (list "RollbackMe")))))
      (is = 0 (length all)))
    (let ((vals (clun.sql:result-rows
                 (clun.sql:sql-execute sql "SELECT name, age FROM users" nil :values)
                 :values)))
      (true (plusp (length vals)))
      (true (vectorp (first vals))))
    (clun.sql:sql-close sql)))

(define-test sql/sqlite-template-helpers
  (let ((sql (clun.sql:make-sql-client "sqlite://:memory:")))
    (clun.sql:sql-execute sql
     "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT, qty INTEGER)")
    (multiple-value-bind (q params)
        (clun.sql:compile-template :sqlite
                                   (list "INSERT INTO items (title, qty) VALUES (" ", " ")")
                                   (list "widget" 3))
      (is string= "INSERT INTO items (title, qty) VALUES (?, ?)" q)
      (is equal (list "widget" 3) params)
      (clun.sql:sql-execute sql q params))
    (let ((rows (clun.sql:result-rows
                 (clun.sql:sql-query sql
                                     (list "SELECT * FROM items WHERE title = " "")
                                     (list "widget")))))
      (is = 1 (length rows))
      (is = 3 (gethash "qty" (first rows))))
    (clun.sql:sql-close sql)))

(define-test sql/sqlite-file-persist
  (let* ((dir (clun.sys:make-temp-dir
               (clun.sys:path-join (clun.sys:tmpdir) "clun-sql-")))
         (path (clun.sys:path-join dir "app.db")))
    (unwind-protect
         (progn
           (let ((sql (clun.sql:make-sql-client
                       (format nil "sqlite://~A" path))))
             (clun.sql:sql-execute sql
              "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
             (clun.sql:sql-execute sql "INSERT INTO t (v) VALUES (?)" (list "persist"))
             (clun.sql:sql-close sql))
           (let* ((sql2 (clun.sql:make-sql-client
                         (format nil "sqlite://~A" path)))
                  (rows (clun.sql:result-rows
                         (clun.sql:sql-execute sql2 "SELECT v FROM t"))))
             (is = 1 (length rows))
             (is string= "persist" (gethash "v" (first rows)))
             (clun.sql:sql-close sql2)))
      (ignore-errors (clun.sys:remove-recursive dir)))))

(define-test sql/sqlite-inspect-export-stats
  (let ((sql (clun.sql:make-sql-client "sqlite://:memory:")))
    (clun.sql:sql-enable-query-log sql t)
    (clun.sql:sql-execute sql "CREATE TABLE a (x INTEGER)")
    (clun.sql:sql-execute sql "INSERT INTO a (x) VALUES (1)")
    (let ((ins (clun.sql:sql-inspect sql)))
      (is eq :sqlite (getf ins :adapter))
      (true (getf ins :tables)))
    (let ((exp (clun.sql:sql-export sql)))
      (true (listp exp)))
    (let ((st (clun.sql:sql-stats sql)))
      (is eq :sqlite (getf st :adapter))
      (true (plusp (getf st :queries))))
    (true (plusp (length (clun.sql:sql-query-log sql))))
    (clun.sql:sql-close sql)))

(define-test sql/postgres-mock-pool-reserve
  (let* ((calls '())
         (clun.sql:*sql-mock-postgres*
          (lambda (q params)
            (push (list q params) calls)
            (cond
              ((search "SELECT 1" q :test #'char-equal)
               (list :columns '("?column?")
                     :rows (list (let ((ht (make-hash-table :test #'equal)))
                                   (setf (gethash "?column?" ht) "1") ht))
                     :values (list (vector "1"))
                     :changes 0 :last-insert-rowid 0))
              ((or (eql (search "BEGIN" q) 0)
                   (eql (search "COMMIT" q) 0)
                   (eql (search "ROLLBACK" q) 0))
               (list :columns '() :rows '() :values '() :changes 0 :last-insert-rowid 0))
              (t (list :columns '("ok")
                       :rows (list (let ((ht (make-hash-table :test #'equal)))
                                     (setf (gethash "ok" ht) "yes") ht))
                       :values (list (vector "yes"))
                       :changes 0 :last-insert-rowid 0)))))
         (sql (clun.sql:make-sql-client "postgres://u:p@localhost:5432/db")))
    (clun.sql:sql-connect sql)
    (let ((rows (clun.sql:result-rows
                 (clun.sql:sql-execute sql "SELECT 1"))))
      (is = 1 (length rows)))
    (clun.sql:sql-begin sql
                        (lambda (tx)
                          (clun.sql:sql-execute tx "SELECT 1")))
    (let ((reserved (clun.sql:sql-reserve sql)))
      (clun.sql:sql-execute reserved "SELECT 1")
      (clun.sql:sql-release reserved))
    (true (plusp (length calls)))
    (let ((st (clun.sql:sql-stats sql)))
      (is eq :postgres (getf st :adapter))
      (true (getf st :pool)))
    (clun.sql:sql-close sql)))

(define-test sql/mysql-mock-exec
  (let* ((clun.sql:*sql-mock-mysql*
          (lambda (q params)
            (declare (ignore params))
            (if (search "SELECT" q :test #'char-equal)
                (list :columns '("v")
                      :rows (list (let ((ht (make-hash-table :test #'equal)))
                                    (setf (gethash "v" ht) "mysql") ht))
                      :values (list (vector "mysql"))
                      :changes 0 :last-insert-rowid 0)
                (list :columns '() :rows '() :values '() :changes 1
                      :last-insert-rowid 7))))
         (sql (clun.sql:make-sql-client "mysql://root@127.0.0.1:3306/app")))
    (let ((rows (clun.sql:result-rows
                 (clun.sql:sql-execute sql "SELECT * FROM t WHERE id = ?" (list 1)))))
      (is string= "mysql" (gethash "v" (first rows))))
    (is eq :mysql (getf (clun.sql:sql-inspect sql) :adapter))
    (clun.sql:sql-close sql)))

(define-test sql/wire-helpers
  (is equalp #(1 2) (clun.sql::u16be #x0102))
  (is = #x0102 (clun.sql::read-u16be (clun.sql::u16be #x0102) 0))
  (is = #x04030201 (clun.sql::read-u32le (clun.sql::u32le #x04030201) 0))
  (is string= "hi" (clun.sql::bytes-to-utf8 (clun.sql::utf8-bytes "hi")))
  (let ((md (clun.sql::md5-hex (clun.sql::utf8-bytes "abc"))))
    (is = 32 (length md))))

(define-test sql/errors-typed
  (let ((c (%sql-err
            (lambda ()
              (clun.sql::raise-sql-error 'clun.sql:sqlite-error
                                         :message "boom"
                                         :code "SQLITE_ERROR"
                                         :errno 1
                                         :adapter :sqlite)))))
    (true (typep c 'clun.sql:sqlite-error))
    (is string= "boom" (clun.sql:sql-error-message c))
    (is string= "SQLITE_ERROR" (clun.sql:sql-error-code c))))

(define-test sql/exceed-array-helper
  (let ((arr (clun.sql:sql-array '(1 2 3) "INT")))
    (true (clun.sql::sql-array-parameter-p arr))
    (true (plusp (length (clun.sql::arr-serialized-values arr)))))
  (multiple-value-bind (sql params)
      (clun.sql:compile-template :postgres
                                 (list "SELECT * FROM t WHERE id IN " "")
                                 (list (clun.sql:sql-helper '(1 2 3))))
    (true (search "$1" sql))
    (is equal '(1 2 3) params)))
