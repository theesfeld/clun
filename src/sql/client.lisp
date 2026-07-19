;;;; client.lisp — unified Clun.SQL client exceeding Bun.SQL (Issue #183).

(in-package :clun.sql)

(defstruct (sql-client
            (:conc-name client-)
            (:constructor %make-sql-client))
  options
  (adapter :postgres :type keyword)
  pool
  ;; sqlite single connection
  sqlite
  ;; reserved single connection (pg/mysql)
  reserved
  (in-transaction nil)
  (closed nil)
  (mock nil)
  ;; exceed Bun
  (query-log nil)
  (stats-queries 0 :type integer)
  (stats-transactions 0 :type integer)
  (created-at (get-universal-time) :type integer))

(defvar *sql-mock-postgres* nil
  "When non-nil, a function (sql params) -> result used for all new postgres clients.")
(defvar *sql-mock-mysql* nil
  "When non-nil, a function (sql params) -> result used for all new mysql clients.")

(defun %open-backend (options &key mock)
  (ecase (so-adapter options)
    (:sqlite
     (open-sqlite :filename (or (so-filename options) (so-database options) ":memory:")
                  :readonly (so-readonly options)
                  :create (so-create options)))
    (:postgres
     (connect-postgres options :mock (or mock *sql-mock-postgres*)))
    (:mysql
     (connect-mysql options :mock (or mock *sql-mock-mysql*)))))

(defun %close-backend (adapter conn)
  (ecase adapter
    (:sqlite (close-sqlite conn))
    (:postgres (close-postgres conn))
    (:mysql (close-mysql conn))))

(defun %exec-backend (adapter conn sql params)
  (ecase adapter
    (:sqlite (sqlite-exec conn sql params))
    (:postgres (postgres-exec conn sql params))
    (:mysql (mysql-exec conn sql params))))

(defun make-sql-client (&rest args)
  "Create a unified SQL client.
   (make-sql-client \"sqlite://:memory:\")
   (make-sql-client \"postgres://...\")
   (make-sql-client :adapter :sqlite :filename \":memory:\")
   (make-sql-client options-plist)"
  (let* ((options
          (cond
            ((null args) (merge-sql-options))
            ((and (= (length args) 1) (stringp (first args)))
             (merge-sql-options (first args)))
            ((and (= (length args) 1) (sql-options-p (first args)))
             (merge-sql-options (first args)))
            ((and (= (length args) 1) (listp (first args)))
             (merge-sql-options (first args)))
            ((keywordp (first args))
             (merge-sql-options (copy-list args)))
            (t (apply #'merge-sql-options args))))
         (adapter (so-adapter options))
         (client (%make-sql-client :options options :adapter adapter)))
    (ecase adapter
      (:sqlite
       (setf (client-sqlite client) (%open-backend options)))
      ((:postgres :mysql)
       (let ((mock (if (eq adapter :postgres) *sql-mock-postgres* *sql-mock-mysql*)))
         (setf (client-pool client)
               (make-sql-pool
                options
                :factory (lambda () (%open-backend options :mock mock))
                :closer (lambda (c) (%close-backend adapter c))))
         ;; Eager first connection (Bun connects lazily on first query; we connect on connect())
         )))
    client))

(defun sql-connect (client)
  "Ensure the client is connected (pool warm for network adapters)."
  (when (client-closed client)
    (raise-sql-error 'sql-connection-error :message "SQL client is closed"
                     :code "ERR_CLOSED" :adapter (client-adapter client)))
  (ecase (client-adapter client)
    (:sqlite client)
    ((:postgres :mysql)
     (let ((c (pool-acquire (client-pool client))))
       (pool-release (client-pool client) c)
       client))))

(defun sql-close (client &key (timeout 0))
  (declare (ignore timeout))
  (unless (client-closed client)
    (setf (client-closed client) t)
    (ecase (client-adapter client)
      (:sqlite (when (client-sqlite client) (close-sqlite (client-sqlite client))))
      ((:postgres :mysql)
       (when (client-reserved client)
         (%close-backend (client-adapter client) (client-reserved client))
         (setf (client-reserved client) nil))
       (when (client-pool client) (pool-close (client-pool client))))))
  (values))

(defun sql-end (client &key (timeout 0))
  (sql-close client :timeout timeout))

(defun sql-flush (client)
  (when (eq (client-adapter client) :sqlite)
    (raise-sql-error 'sql-error
                     :message "SQLite adapter does not support flush"
                     :code "ERR_NOT_SUPPORTED"
                     :adapter :sqlite))
  (values))

(defun %with-connection (client thunk)
  (ecase (client-adapter client)
    (:sqlite (funcall thunk (client-sqlite client)))
    ((:postgres :mysql)
     (if (client-reserved client)
         (funcall thunk (client-reserved client))
         (let ((c (pool-acquire (client-pool client))))
           (unwind-protect (funcall thunk c)
             (pool-release (client-pool client) c)))))))

(defun sql-execute (client sql &optional params mode simple)
  "Run SQL and return a result structure:
   (:columns :rows :values :changes :last-insert-rowid :mode)"
  (declare (ignore simple))
  (let ((mode (or mode :objects)))
    (when (client-closed client)
      (raise-sql-error 'sql-connection-error :message "SQL client is closed"
                       :code "ERR_CLOSED" :adapter (client-adapter client)))
    (incf (client-stats-queries client))
    (when (client-query-log client)
      (let ((entry (list :sql sql :params params :at (get-universal-time)))
            (log (client-query-log client)))
        (setf (client-query-log client)
              (if (eq (first log) :enabled)
                  (list* :enabled entry (rest log))
                  (cons entry log)))))
    (let ((result (%with-connection client
                    (lambda (conn)
                      (%exec-backend (client-adapter client) conn sql params)))))
      (setf (getf result :mode) mode)
      result)))

(defun sql-query (client strings &optional values mode simple)
  "Tagged-template entry: STRINGS list + VALUES list."
  (multiple-value-bind (sql params)
      (if (and (null values) (stringp strings))
          (values strings nil)
          (compile-template (client-adapter client)
                            (if (stringp strings) (list strings) strings)
                            (or values '())))
    (sql-execute client sql params mode simple)))

(defun sql-unsafe (client string &optional values)
  (multiple-value-bind (sql params) (compile-unsafe string values)
    (sql-execute client sql params)))

(defun sql-file (client filename &optional values)
  (let* ((octets (clun.sys:read-file-octets filename))
         (text (bytes-to-utf8 octets)))
    (sql-unsafe client text values)))

(defun sql-array (values &optional type)
  (serialize-array-parameter
   (make-sql-array-parameter (coerce values 'list) (or type "JSON"))
   (or type "JSON")))

(defun sql-helper (value &rest columns)
  (make-sql-helper value (when columns (mapcar #'string columns))))

(defun sql-fragment (sql &optional params)
  (make-sql-fragment sql params))

(defun sql-reserve (client)
  "Reserve a dedicated connection from the pool (network adapters)."
  (when (eq (client-adapter client) :sqlite)
    (raise-sql-error 'sql-error
                     :message "SQLite adapter does not support connection pooling / reserve"
                     :code "ERR_NOT_SUPPORTED"
                     :adapter :sqlite))
  (let ((reserved (%make-sql-client
                   :options (client-options client)
                   :adapter (client-adapter client)
                   :reserved (pool-acquire (client-pool client))
                   :pool (client-pool client))))
    reserved))

(defun sql-release (reserved-client)
  (when (client-reserved reserved-client)
    (pool-release (client-pool reserved-client)
                  (client-reserved reserved-client))
    (setf (client-reserved reserved-client) nil
          (client-closed reserved-client) t))
  (values))

(defun sql-begin (client fn &optional options-string)
  "Begin a transaction; call FN with a transactional client; commit or rollback."
  (incf (client-stats-transactions client))
  (let* ((tx (ecase (client-adapter client)
               (:sqlite client)
               ((:postgres :mysql)
                (if (client-reserved client)
                    client
                    (sql-reserve client)))))
         (begin-sql (if (and options-string (plusp (length options-string)))
                        (format nil "BEGIN ~A" options-string)
                        "BEGIN")))
    (unwind-protect
         (progn
           (sql-execute tx begin-sql)
           (setf (client-in-transaction tx) t)
           (let ((result (funcall fn tx)))
             (sql-execute tx "COMMIT")
             (setf (client-in-transaction tx) nil)
             result))
      (when (client-in-transaction tx)
        (ignore-errors (sql-execute tx "ROLLBACK"))
        (setf (client-in-transaction tx) nil))
      (when (and (not (eq tx client))
                 (client-reserved tx)
                 (not (eq (client-adapter client) :sqlite)))
        (sql-release tx)))))

(defun sql-transaction (client fn &optional options-string)
  (sql-begin client fn options-string))

(defun sql-savepoint (tx name fn)
  (let ((sp (format nil "sp_~A" (or name (hex-encode (crypto:random-data 4))))))
    (sql-execute tx (format nil "SAVEPOINT ~A" sp))
    (handler-case
        (prog1 (funcall fn tx)
          (sql-execute tx (format nil "RELEASE SAVEPOINT ~A" sp)))
      (error (e)
        (ignore-errors (sql-execute tx (format nil "ROLLBACK TO SAVEPOINT ~A" sp)))
        (error e)))))

(defun sql-begin-distributed (client name fn)
  "Two-phase commit: PostgreSQL PREPARE TRANSACTION / MySQL XA."
  (ecase (client-adapter client)
    (:sqlite
     (raise-sql-error 'sql-error
                      :message "SQLite does not support distributed transactions"
                      :code "ERR_NOT_SUPPORTED" :adapter :sqlite))
    (:postgres
     (sql-begin client
                (lambda (tx)
                  (prog1 (funcall fn tx)
                    (sql-execute tx (format nil "PREPARE TRANSACTION '~A'" name))))))
    (:mysql
     (sql-begin client
                (lambda (tx)
                  (sql-execute tx (format nil "XA START '~A'" name))
                  (prog1 (funcall fn tx)
                    (sql-execute tx (format nil "XA END '~A'" name))
                    (sql-execute tx (format nil "XA PREPARE '~A'" name))))))))

(defun sql-commit-distributed (client name)
  (ecase (client-adapter client)
    (:sqlite (raise-sql-error 'sql-error :message "SQLite does not support distributed transactions"
                              :code "ERR_NOT_SUPPORTED" :adapter :sqlite))
    (:postgres (sql-execute client (format nil "COMMIT PREPARED '~A'" name)))
    (:mysql (sql-execute client (format nil "XA COMMIT '~A'" name)))))

(defun sql-rollback-distributed (client name)
  (ecase (client-adapter client)
    (:sqlite (raise-sql-error 'sql-error :message "SQLite does not support distributed transactions"
                              :code "ERR_NOT_SUPPORTED" :adapter :sqlite))
    (:postgres (sql-execute client (format nil "ROLLBACK PREPARED '~A'" name)))
    (:mysql (sql-execute client (format nil "XA ROLLBACK '~A'" name)))))

;;; --- exceed Bun surface -----------------------------------------------------

(defun sql-inspect (client)
  "Schema / connection inspection (Clun exceed)."
  (ecase (client-adapter client)
    (:sqlite (sqlite-inspect (client-sqlite client)))
    (:postgres
     (%with-connection client #'postgres-inspect))
    (:mysql
     (%with-connection client #'mysql-inspect))))

(defun sql-stats (client)
  (list :adapter (client-adapter client)
        :queries (client-stats-queries client)
        :transactions (client-stats-transactions client)
        :created-at (client-created-at client)
        :closed (client-closed client)
        :pool (when (client-pool client) (pool-stats (client-pool client)))
        :sqlite (when (and (eq (client-adapter client) :sqlite)
                           (client-sqlite client))
                  (list :filename (sdb-filename (client-sqlite client))
                        :queries (sdb-stats-queries (client-sqlite client))))))

(defun sql-export (client)
  "Export SQLite database (Clun exceed)."
  (unless (eq (client-adapter client) :sqlite)
    (raise-sql-error 'sql-error
                     :message "export is only supported for the SQLite adapter"
                     :code "ERR_NOT_SUPPORTED"
                     :adapter (client-adapter client)))
  (sqlite-export-json (client-sqlite client)))

(defun sql-enable-query-log (client &optional (enabled t))
  ;; Use a non-nil empty vector as the "enabled, no entries yet" sentinel so
  ;; LISTP empty NIL is not confused with disabled logging.
  (setf (client-query-log client) (if enabled (list :enabled) nil))
  enabled)

(defun sql-query-log (client)
  (let ((log (client-query-log client)))
    (if (and log (eq (first log) :enabled))
        (reverse (rest log))
        (reverse (or log '())))))

(defun result-rows (result &optional (mode (getf result :mode :objects)))
  (ecase mode
    (:objects (getf result :rows))
    (:values (getf result :values))
    (:raw (mapcar (lambda (vec)
                    (map 'vector (lambda (v)
                                   (if (stringp v) (utf8-bytes v) v))
                         vec))
                  (getf result :values)))))

(defun result-first (result)
  (first (result-rows result :objects)))
