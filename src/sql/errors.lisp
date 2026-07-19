;;;; errors.lisp — SQL error conditions exceeding Bun.SQL error classes.

(in-package :clun.sql)

(define-condition sql-error (error)
  ((message :initarg :message :reader sql-error-message
            :initform "SQL error")
   (code :initarg :code :reader sql-error-code :initform "SQL_ERROR")
   (adapter :initarg :adapter :reader sql-error-adapter :initform nil)
   (sqlstate :initarg :sqlstate :reader sql-error-sqlstate :initform nil)
   (detail :initarg :detail :reader sql-error-detail :initform nil)
   (hint :initarg :hint :reader sql-error-hint :initform nil)
   (query :initarg :query :reader sql-error-query :initform nil)
   (position :initarg :position :reader sql-error-position :initform nil)
   (errno :initarg :errno :reader sql-error-errno :initform nil)
   (severity :initarg :severity :reader sql-error-severity :initform nil)
   (schema :initarg :schema :reader sql-error-schema :initform nil)
   (table :initarg :table :reader sql-error-table :initform nil)
   (column :initarg :column :reader sql-error-column :initform nil)
   (constraint :initarg :constraint :reader sql-error-constraint :initform nil)
   (byte-offset :initarg :byte-offset :reader sql-error-byte-offset :initform nil))
  (:report (lambda (c s)
             (format s "~A~@[: ~A~]" (sql-error-code c) (sql-error-message c)))))

(define-condition postgres-error (sql-error) ())
(define-condition mysql-error (sql-error) ())
(define-condition sqlite-error (sql-error) ())
(define-condition sql-protocol-error (sql-error) ())
(define-condition sql-connection-error (sql-error) ())
(define-condition sql-timeout-error (sql-error) ())
(define-condition sql-cancel-error (sql-error) ())

(defun raise-sql-error (class &key message code adapter sqlstate detail hint
                         query position errno severity schema table column
                         constraint byte-offset)
  (error class
         :message (or message "SQL error")
         :code (or code "SQL_ERROR")
         :adapter adapter
         :sqlstate sqlstate
         :detail detail
         :hint hint
         :query query
         :position position
         :errno errno
         :severity severity
         :schema schema
         :table table
         :column column
         :constraint constraint
         :byte-offset byte-offset))
