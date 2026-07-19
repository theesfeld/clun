;;;; pool.lisp — connection pool for PostgreSQL / MySQL (Bun.SQL max / reserve).

(in-package :clun.sql)

(defstruct (sql-pool
            (:conc-name pool-)
            (:constructor %make-sql-pool))
  options
  (adapter :postgres :type keyword)
  (max 10 :type integer)
  (idle nil)                           ; list of connections
  (busy 0 :type integer)
  (lock (sb-thread:make-mutex :name "clun-sql-pool"))
  (closed nil)
  (factory nil)                        ; () -> conn
  (closer nil)                         ; (conn) ->
  (stats-acquires 0 :type integer)
  (stats-creates 0 :type integer))

(defun make-sql-pool (options &key factory closer)
  (%make-sql-pool
   :options options
   :adapter (so-adapter options)
   :max (max 1 (or (so-max options) 10))
   :factory factory
   :closer closer))

(defun pool-acquire (pool)
  (sb-thread:with-mutex ((pool-lock pool))
    (when (pool-closed pool)
      (raise-sql-error 'sql-connection-error
                       :message "SQL pool is closed"
                       :code "ERR_POOL_CLOSED"
                       :adapter (pool-adapter pool)))
    (incf (pool-stats-acquires pool))
    (if (pool-idle pool)
        (let ((c (pop (pool-idle pool))))
          (incf (pool-busy pool))
          c)
        (if (>= (pool-busy pool) (pool-max pool))
            (raise-sql-error 'sql-connection-error
                             :message "SQL pool exhausted"
                             :code "ERR_POOL_TIMEOUT"
                             :adapter (pool-adapter pool))
            (let ((c (funcall (pool-factory pool))))
              (incf (pool-stats-creates pool))
              (incf (pool-busy pool))
              c)))))

(defun pool-release (pool conn)
  (sb-thread:with-mutex ((pool-lock pool))
    (decf (pool-busy pool))
    (if (pool-closed pool)
        (when (pool-closer pool) (funcall (pool-closer pool) conn))
        (push conn (pool-idle pool))))
  (values))

(defun pool-close (pool)
  (sb-thread:with-mutex ((pool-lock pool))
    (setf (pool-closed pool) t)
    (dolist (c (pool-idle pool))
      (when (pool-closer pool) (funcall (pool-closer pool) c)))
    (setf (pool-idle pool) nil))
  (values))

(defun pool-stats (pool)
  (list :adapter (pool-adapter pool)
        :max (pool-max pool)
        :idle (length (pool-idle pool))
        :busy (pool-busy pool)
        :acquires (pool-stats-acquires pool)
        :creates (pool-stats-creates pool)
        :closed (pool-closed pool)))
