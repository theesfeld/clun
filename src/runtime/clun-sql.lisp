;;;; clun-sql.lisp — Clun.SQL JavaScript boundary (Issue #183 FULL PORT).
;;;; Bun.SQL-compatible unified client over pure-CL PostgreSQL / MySQL / SQLite.
;;;; Exceed: inspect, stats, export, queryLog, adapters list.

(in-package :clun.runtime)

(defstruct (js-sql-client
            (:include eng:js-object (class :sql-client))
            (:constructor %make-js-sql-client))
  backend)

(defstruct (js-sql-query
            (:include eng:js-object (class :sql-query))
            (:constructor %make-js-sql-query))
  client
  sql
  params
  (mode :objects)
  (simple nil)
  (active nil)
  (cancelled nil))

(defun %sql-js-error (global condition)
  (let* ((name (typecase condition
                 (clun.sql:postgres-error "PostgresError")
                 (clun.sql:mysql-error "MySQLError")
                 (clun.sql:sqlite-error "SQLiteError")
                 (t "SQLError")))
         (msg (if (typep condition 'clun.sql:sql-error)
                  (clun.sql:sql-error-message condition)
                  (princ-to-string condition)))
         (err (eng:make-error-object :error-prototype name msg)))
    (when (typep condition 'clun.sql:sql-error)
      (eng:js-set err "code" (or (clun.sql:sql-error-code condition) "SQL_ERROR") nil)
      (when (clun.sql:sql-error-errno condition)
        (eng:js-set err "errno" (clun.sql:sql-error-errno condition) nil))
      (when (clun.sql:sql-error-sqlstate condition)
        (eng:js-set err "sqlState" (clun.sql:sql-error-sqlstate condition) nil))
      (when (clun.sql:sql-error-detail condition)
        (eng:js-set err "detail" (clun.sql:sql-error-detail condition) nil))
      (when (clun.sql:sql-error-adapter condition)
        (eng:js-set err "adapter"
                    (string-downcase (symbol-name (clun.sql:sql-error-adapter condition)))
                    nil)))
    err))

(defun %sql-resolved (global value)
  (eng:js-construct
   (eng:js-get global "Promise")
   (list
    (eng:make-native-function
     "" 2
     (lambda (this args)
       (declare (ignore this))
       (eng:js-call (eng:arg args 0) eng:+undefined+ (list value))
       eng:+undefined+)))))

(defun %sql-rejected (global error)
  (eng:js-construct
   (eng:js-get global "Promise")
   (list
    (eng:make-native-function
     "" 2
     (lambda (this args)
       (declare (ignore this))
       (eng:js-call (eng:arg args 1) eng:+undefined+ (list error))
       eng:+undefined+)))))

(defun %sql-value->js (global value)
  (cond
    ((null value) eng:+null+)
    ((eq value t) eng:+true+)
    ((stringp value) value)
    ((integerp value)
     (if (and (<= value #x1fffffffffffff) (>= value #x-1fffffffffffff))
         (coerce value 'double-float)
         value))
    ((floatp value) (coerce value 'double-float))
    ((hash-table-p value)
     (let ((obj (eng:new-object)))
       (maphash (lambda (k v)
                  (eng:data-prop obj (string k) (%sql-value->js global v)))
                value)
       obj))
    ((typep value 'vector)
     (eng:new-array
      (loop for i from 0 below (length value)
            collect (%sql-value->js global (aref value i)))))
    ((and (listp value) (keywordp (first value)))
     ;; property list / inspect export alists rendered as objects
     (let ((obj (eng:new-object)))
       (loop for (k v) on value by #'cddr
             do (eng:data-prop obj
                               (string-downcase (string k))
                               (%sql-value->js global v)))
       obj))
    ((listp value)
     (eng:new-array (mapcar (lambda (v) (%sql-value->js global v)) value)))
    (t (princ-to-string value))))

(defun %sql-result->js (global result mode)
  (let* ((rows (clun.sql:result-rows result mode))
         (arr (eng:new-array
               (mapcar (lambda (row) (%sql-value->js global row)) rows))))
    ;; attach metadata like Bun (count, command tag via non-enumerable-ish props)
    (eng:data-prop arr "count" (coerce (length rows) 'double-float))
    (when (getf result :changes)
      (eng:data-prop arr "changes" (coerce (getf result :changes) 'double-float)))
    (when (getf result :last-insert-rowid)
      (eng:data-prop arr "lastInsertRowid"
                     (coerce (getf result :last-insert-rowid) 'double-float)))
    arr))

(defun %sql-js->cl (value)
  (cond
    ((eng:js-nullish-p value) nil)
    ((eng:js-boolean-p value) (eq value eng:+true+))
    ((eng:js-string-p value) value)
    ((eng:js-number-p value)
     (let ((n value))
       (if (= n (floor n)) (floor n) n)))
    ((eng:js-typed-array-p value) (eng:ta-octets value))
    ((eng:js-array-p value)
     (loop for i from 0 below (eng:array-length value)
           collect (%sql-js->cl (eng:js-getv value (princ-to-string i)))))
    ((eng:js-object-p value)
     (let ((plist '()))
       (dolist (k (eng::obj-own-keys value))
         (setf plist (list* (intern (string-upcase (string k)) :keyword)
                            (%sql-js->cl (eng:js-getv value k))
                            plist)))
       (nreverse plist)))
    (t value)))

(defun %sql-params-list (value)
  "Normalize a JS params argument into a CL list for SQL binding."
  (cond
    ((eng:js-undefined-p value) nil)
    ((eng:js-null-p value) nil)
    ((eng:js-array-p value)
     (loop for i from 0 below (eng:array-length value)
           collect (%sql-js->cl (eng:js-getv value (princ-to-string i)))))
    ((eng:js-object-p value)
     ;; Accept array-likes with numeric length.
     (let ((len (eng:js-get value "length")))
       (if (eng:js-number-p len)
           (loop for i from 0 below (floor len)
                 collect (%sql-js->cl (eng:js-getv value (princ-to-string i))))
           (list (%sql-js->cl value)))))
    (t (list (%sql-js->cl value)))))

(defun %sql-parse-options (args)
  (let ((a0 (eng:arg args 0))
        (a1 (eng:arg args 1)))
    (cond
      ((or (null args) (eng:js-undefined-p a0) (eng:js-null-p a0))
       (clun.sql:merge-sql-options
        (list :adapter :sqlite :filename ":memory:")))
      ((eng:js-string-p a0)
       (if (and (eng:js-object-p a1) (not (eng:js-nullish-p a1)))
           (clun.sql:merge-sql-options
            a0
            (%sql-options-from-object a1))
           (clun.sql:merge-sql-options a0)))
      ((eng:js-object-p a0)
       (clun.sql:merge-sql-options (%sql-options-from-object a0)))
      (t (eng:throw-type-error "SQL: expected connection string or options object")))))

(defun %sql-options-from-object (obj)
  (let ((plist '()))
    (labels ((put (k js-key)
               (let ((v (eng:js-get obj js-key)))
                 (unless (eng:js-undefined-p v)
                   (setf plist (list* k (%sql-js->cl v) plist))))))
      (put :adapter "adapter")
      (put :url "url")
      (put :hostname "hostname")
      (put :host "host")
      (put :port "port")
      (put :username "username")
      (put :user "user")
      (put :password "password")
      (put :pass "pass")
      (put :database "database")
      (put :db "db")
      (put :filename "filename")
      (put :max "max")
      (put :idle-timeout "idleTimeout")
      (put :connection-timeout "connectionTimeout")
      (put :tls "tls")
      (put :ssl "ssl")
      (put :path "path")
      (put :bigint "bigint")
      (put :query-timeout "queryTimeout")
      (put :application-name "application_name")
      plist)))

(defun %sql-run-query (global client sql params mode)
  (handler-case
      (let ((result (clun.sql:sql-execute (js-sql-client-backend client) sql params mode)))
        (%sql-resolved global (%sql-result->js global result mode)))
    (clun.sql:sql-error (c)
      (%sql-rejected global (%sql-js-error global c)))
    (error (c)
      (%sql-rejected global (%sql-js-error global c)))))

(defun %make-sql-query-object (global client sql params &optional (mode :objects))
  (let ((q (%make-js-sql-query :client client :sql sql :params params :mode mode)))
    (eng:install-method q "then" 2
      (lambda (this args)
        (declare (ignore this))
        (let ((p (%sql-run-query global client sql params (js-sql-query-mode q))))
          (eng:js-call (eng:js-get p "then") p (list (eng:arg args 0) (eng:arg args 1))))))
    (eng:install-method q "values" 0
      (lambda (this args)
        (declare (ignore args))
        (setf (js-sql-query-mode this) :values)
        this))
    (eng:install-method q "raw" 0
      (lambda (this args)
        (declare (ignore args))
        (setf (js-sql-query-mode this) :raw)
        this))
    (eng:install-method q "simple" 0
      (lambda (this args)
        (declare (ignore args))
        (setf (js-sql-query-simple this) t)
        this))
    (eng:install-method q "execute" 0
      (lambda (this args)
        (declare (ignore args))
        (%sql-run-query global client sql params (js-sql-query-mode this))))
    (eng:install-method q "cancel" 0
      (lambda (this args)
        (declare (ignore args))
        (setf (js-sql-query-cancelled this) t)
        this))
    (eng:data-prop q "active" eng:+false+)
    (eng:data-prop q "cancelled" eng:+false+)
    q))

(defun %sql-call (global client this args)
  (declare (ignore this))
  (let ((a0 (eng:arg args 0)))
    (cond
      ;; tagged template: first arg is TemplateStringsArray-like with .raw or array of strings
      ((and (eng:js-object-p a0)
            (or (eng:js-array-p a0)
                (not (eng:js-undefined-p (eng:js-get a0 "raw")))))
       (let* ((len (eng:array-length a0))
              (strings (loop for i from 0 below len
                             collect (eng:to-string
                                      (eng:js-getv a0 (princ-to-string i)))))
              (values (loop for i from 1 below (length args)
                            collect (%sql-js->cl (nth i args)))))
         (multiple-value-bind (sql params)
             (clun.sql:compile-template
              (clun.sql:client-adapter (js-sql-client-backend client))
              strings values)
           (%make-sql-query-object global client sql params))))
      ((eng:js-string-p a0)
       (%make-sql-query-object global client a0 nil))
      ((eng:js-object-p a0)
       ;; helper form sql(obj) / sql(obj, cols...)
       (let* ((value (%sql-js->cl a0))
              (cols (loop for i from 1 below (length args)
                          collect (eng:to-string (nth i args))))
              (helper (apply #'clun.sql:sql-helper value cols)))
         (%sql-value->js global
                         (list "helper" (clun.sql:helper-value helper)
                               (clun.sql:helper-columns helper)))))
      (t (eng:throw-type-error "SQL: invalid call")))))

(defun %wrap-sql-client (global backend)
  (let ((client (%make-js-sql-client :backend backend))
        (adapter (string-downcase (symbol-name (clun.sql:client-adapter backend)))))
    ;; Make the client callable like Bun.SQL tagged template
    (setf (eng:js-object-class client) :sql-client)
    (eng:data-prop client "options"
                   (let ((o (eng:new-object)))
                     (eng:data-prop o "adapter" adapter)
                     o))
    (eng:install-method client "connect" 0
      (lambda (this args)
        (declare (ignore args))
        (handler-case
            (progn
              (clun.sql:sql-connect (js-sql-client-backend this))
              (%sql-resolved global this))
          (error (c) (%sql-rejected global (%sql-js-error global c))))))
    (eng:install-method client "close" 1
      (lambda (this args)
        (declare (ignore args))
        (clun.sql:sql-close (js-sql-client-backend this))
        (%sql-resolved global eng:+undefined+)))
    (eng:install-method client "end" 1
      (lambda (this args)
        (declare (ignore args))
        (clun.sql:sql-end (js-sql-client-backend this))
        (%sql-resolved global eng:+undefined+)))
    (eng:install-method client "flush" 0
      (lambda (this args)
        (declare (ignore args))
        (handler-case
            (progn (clun.sql:sql-flush (js-sql-client-backend this)) eng:+undefined+)
          (error (c) (eng:throw-js-value (%sql-js-error global c))))))
    (eng:install-method client "unsafe" 2
      (lambda (this args)
        (let ((sql (eng:to-string (eng:arg args 0)))
              (vals (when (> (length args) 1)
                      (%sql-js->cl (eng:arg args 1)))))
          (multiple-value-bind (s p) (values sql (if (listp vals) vals nil))
            (%make-sql-query-object global this s p)))))
    (eng:install-method client "array" 2
      (lambda (this args)
        (declare (ignore this))
        (let ((vals (%sql-js->cl (eng:arg args 0)))
              (type (unless (eng:js-undefined-p (eng:arg args 1))
                      (eng:to-string (eng:arg args 1)))))
          (let ((arr (clun.sql:sql-array (if (listp vals) vals (list vals)) type))
                (obj (eng:new-object)))
            (eng:data-prop obj "serializedValues" (clun.sql::arr-serialized-values arr))
            (eng:data-prop obj "arrayType" (clun.sql::arr-array-type arr))
            obj))))
    (eng:install-method client "begin" 2
      (lambda (this args)
        (let* ((fn (if (eng:js-function-p (eng:arg args 0))
                       (eng:arg args 0)
                       (eng:arg args 1)))
               (opts (when (eng:js-string-p (eng:arg args 0))
                       (eng:to-string (eng:arg args 0)))))
          (handler-case
              (let ((result
                     (clun.sql:sql-begin
                      (js-sql-client-backend this)
                      (lambda (tx)
                        (let ((jstx (%wrap-sql-client global tx)))
                          ;; synchronous callback path for pure-CL engine simplicity:
                          ;; if fn returns a Promise we cannot easily wait without the loop;
                          ;; for SQLite paths callbacks that use await need the query thenables.
                          (eng:js-call fn eng:+undefined+ (list jstx))))
                      opts)))
                (%sql-resolved global (%sql-value->js global result)))
            (error (c) (%sql-rejected global (%sql-js-error global c)))))))
    (eng:install-method client "transaction" 2
      (lambda (this args)
        (eng:js-call (eng:js-get this "begin") this args)))
    (eng:install-method client "reserve" 0
      (lambda (this args)
        (declare (ignore args))
        (handler-case
            (let ((r (clun.sql:sql-reserve (js-sql-client-backend this))))
              (let ((jr (%wrap-sql-client global r)))
                (eng:install-method jr "release" 0
                  (lambda (self a)
                    (declare (ignore a))
                    (clun.sql:sql-release (js-sql-client-backend self))
                    (%sql-resolved global eng:+undefined+)))
                (%sql-resolved global jr)))
          (error (c) (%sql-rejected global (%sql-js-error global c))))))
    (eng:install-method client "inspect" 0
      (lambda (this args)
        (declare (ignore args))
        (handler-case
            (%sql-resolved global
                           (%sql-value->js global
                                           (clun.sql:sql-inspect
                                            (js-sql-client-backend this))))
          (error (c) (%sql-rejected global (%sql-js-error global c))))))
    (eng:install-method client "stats" 0
      (lambda (this args)
        (declare (ignore args))
        (%sql-value->js global (clun.sql:sql-stats (js-sql-client-backend this)))))
    (eng:install-method client "export" 0
      (lambda (this args)
        (declare (ignore args))
        (handler-case
            (%sql-resolved global
                           (%sql-value->js global
                                           (clun.sql:sql-export
                                            (js-sql-client-backend this))))
          (error (c) (%sql-rejected global (%sql-js-error global c))))))
    (eng:install-method client "enableQueryLog" 1
      (lambda (this args)
        (clun.sql:sql-enable-query-log
         (js-sql-client-backend this)
         (not (eq (eng:arg args 0) eng:+false+)))
        eng:+undefined+))
    (eng:install-method client "queryLog" 0
      (lambda (this args)
        (declare (ignore args))
        (%sql-value->js global (clun.sql:sql-query-log (js-sql-client-backend this)))))
    ;; Callable client: use apply trap via hidden call helper
    (eng:install-method client "query" 1
      (lambda (this args)
        (%sql-call global this this args)))
    (eng:install-method client "run" 2
      (lambda (this args)
        (let* ((sql (eng:to-string (eng:arg args 0)))
               (raw (eng:arg args 1))
               (params (when (and (> (length args) 1)
                                  (not (eng:js-undefined-p raw)))
                         (%sql-params-list raw))))
          (%sql-run-query global this sql params :objects))))
    client))

(defun %sql-construct (global args)
  (handler-case
      (let* ((opts (%sql-parse-options args))
             (backend (clun.sql:make-sql-client opts)))
        (%wrap-sql-client global backend))
    (clun.sql:sql-error (c)
      (eng:throw-js-value (%sql-js-error global c)))
    (error (c)
      (eng:throw-js-value (%sql-js-error global c)))))

(defun make-clun-sql-constructor (global)
  (let ((ctor
         (eng:make-native-function
          "SQL" 1
          (lambda (this args)
            (declare (ignore this))
            ;; Allow call without new (Bun also permits factory-style use).
            (%sql-construct global args))
          :construct
          (lambda (args new-target)
            (declare (ignore new-target))
            (%sql-construct global args)))))
    (eng:data-prop ctor "adapters"
                   (eng:new-array (list "postgres" "mysql" "sqlite")))
    (eng:data-prop ctor "version" "clun-sql-1")
    ctor))

(defun install-clun-sql (clun global)
  "Install Clun.SQL constructor and default memory SQLite helper."
  (let ((ctor (make-clun-sql-constructor global)))
    (eng:nonconfigurable-data-prop clun "SQL" ctor)
    ;; Convenience: Clun.sql default in-memory client factory (lazy)
    (eng:install-method clun "sql" 1
      (lambda (this args)
        (declare (ignore this))
        (eng:js-construct ctor args)))
    ctor))
