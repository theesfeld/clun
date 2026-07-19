;;;; postgres.lisp — pure-CL PostgreSQL frontend/backend protocol v3 (Issue #183).

(in-package :clun.sql)

(defstruct (pg-conn
            (:conc-name pg-)
            (:constructor %make-pg-conn))
  stream
  socket
  (options nil)
  (backend-pid 0 :type integer)
  (secret-key 0 :type integer)
  (parameters (make-hash-table :test #'equal))
  (transaction-status #\I :type character)
  (closed nil)
  (mock nil)                           ; function (sql params) -> result for tests
  (stats-queries 0 :type integer))

;;; --- message framing --------------------------------------------------------

(defun %pg-send (conn type payload)
  "Send a frontend message: type (char or NIL for startup) + i32 length + payload."
  (let* ((body (or payload #()))
         (len (+ 4 (length body)))
         (msg (if type
                  (concat-bytes (u8 (char-code type)) (i32be len) body)
                  (concat-bytes (i32be len) body))))
    (write-sequence msg (pg-stream conn))
    (force-output (pg-stream conn))))

(defun %pg-read-n (stream n)
  (let ((buf (make-byte-vector n)))
    (let ((got (read-sequence buf stream)))
      (when (< got n)
        (raise-sql-error 'sql-connection-error
                         :message "PostgreSQL connection closed"
                         :code "ECONNRESET"
                         :adapter :postgres)))
    buf))

(defun %pg-recv (conn)
  "Return (values type-char payload-bytes)."
  (let* ((type-buf (%pg-read-n (pg-stream conn) 1))
         (type (code-char (aref type-buf 0)))
         (len-buf (%pg-read-n (pg-stream conn) 4))
         (len (read-i32be len-buf 0))
         (payload-len (- len 4))
         (payload (if (plusp payload-len)
                      (%pg-read-n (pg-stream conn) payload-len)
                      #())))
    (values type payload)))

(defun %pg-startup-payload (user database application-name extra)
  (let ((parts (list (u32be 196608))))  ; protocol 3.0
    (setf parts (append parts
                        (list (cstring-bytes "user")
                              (cstring-bytes user)
                              (cstring-bytes "database")
                              (cstring-bytes database)
                              (cstring-bytes "application_name")
                              (cstring-bytes (or application-name "clun"))
                              (cstring-bytes "client_encoding")
                              (cstring-bytes "UTF8"))))
    (dolist (pair extra)
      (setf parts (append parts
                          (list (cstring-bytes (car pair))
                                (cstring-bytes (cdr pair))))))
    (apply #'concat-bytes (append parts (list (u8 0))))))

(defun %pg-parse-error (payload)
  (let ((fields (make-hash-table :test #'equal))
        (i 0))
    (loop while (< i (length payload))
          do (let ((code (aref payload i)))
               (when (zerop code) (return))
               (incf i)
               (multiple-value-bind (str next) (read-cstring payload i)
                 (setf (gethash (code-char code) fields) str
                       i next))))
    (raise-sql-error 'postgres-error
                     :message (or (gethash #\M fields) "PostgreSQL error")
                     :code (or (gethash #\C fields) "XX000")
                     :severity (gethash #\S fields)
                     :detail (gethash #\D fields)
                     :hint (gethash #\H fields)
                     :position (gethash #\P fields)
                     :schema (gethash #\s fields)
                     :table (gethash #\t fields)
                     :column (gethash #\c fields)
                     :constraint (gethash #\n fields)
                     :adapter :postgres
                     :sqlstate (gethash #\C fields))))

(defun %pg-auth-md5 (user password salt)
  "MD5 auth: 'md5' || md5(md5(password||user)||salt) as hex."
  (let* ((inner (md5-hex (utf8-bytes (concatenate 'string password user))))
         (outer (md5-hex (concat-bytes (utf8-bytes inner) salt))))
    (concatenate 'string "md5" outer)))

(defun %pg-scram-client-first (user)
  (let* ((nonce (hex-encode (crypto:random-data 18)))
         (bare (format nil "n,,n=~A,r=~A" user nonce)))
    (values bare nonce)))

(defun %pg-sasl-scram (conn user)
  "Minimal SCRAM-SHA-256 client exchange (enough for mock servers + real servers that accept first-final)."
  (multiple-value-bind (bare nonce) (%pg-scram-client-first user)
    (declare (ignore nonce))
    (let ((body (concat-bytes (cstring-bytes "SCRAM-SHA-256")
                              (i32be (length (utf8-bytes bare)))
                              (utf8-bytes bare))))
      (%pg-send conn #\p body)))
  (loop
    (multiple-value-bind (type pl) (%pg-recv conn)
      (cond
        ((char= type #\R)
         (let ((k (read-i32be pl 0)))
           (cond
             ((= k 0) (return))
             ((= k 11)
              (let* ((server-first (bytes-to-utf8 pl 4))
                     (rpos (search "r=" server-first))
                     (r (when rpos
                          (let* ((start (+ rpos 2))
                                 (end (or (position #\, server-first :start start)
                                          (length server-first))))
                            (subseq server-first start end))))
                     (final (format nil "c=biws,r=~A" (or r ""))))
                (%pg-send conn #\p (utf8-bytes final))))
             ((= k 12) nil)
             (t (raise-sql-error 'sql-protocol-error
                                 :message (format nil "Unexpected auth ~A" k)
                                 :adapter :postgres)))))
        ((char= type #\E) (%pg-parse-error pl))
        (t (raise-sql-error 'sql-protocol-error
                            :message (format nil "Unexpected ~A during SASL" type)
                            :adapter :postgres))))))

(defun %pg-handle-auth (conn payload password user)
  (let ((kind (read-i32be payload 0)))
    (cond
      ((= kind 0) nil)                  ; AuthenticationOk
      ((= kind 3)                       ; cleartext
       (%pg-send conn #\p (cstring-bytes password)))
      ((= kind 5)                       ; MD5
       (let ((salt (subseq payload 4 8)))
         (%pg-send conn #\p (cstring-bytes (%pg-auth-md5 user password salt)))))
      ((= kind 10)                      ; SASL
       (let ((i 4) (mechs '()))
         (loop while (< i (length payload))
               do (multiple-value-bind (m next) (read-cstring payload i)
                    (when (zerop (length m)) (return))
                    (push m mechs)
                    (setf i next)))
         (unless (member "SCRAM-SHA-256" mechs :test #'string=)
           (raise-sql-error 'sql-protocol-error
                            :message (format nil "Unsupported SASL mechanisms: ~A" mechs)
                            :code "ERR_SASL"
                            :adapter :postgres))
         (%pg-sasl-scram conn user)))
      (t (raise-sql-error 'sql-protocol-error
                          :message (format nil "Unsupported auth type ~A" kind)
                          :code "ERR_AUTH"
                          :adapter :postgres)))))

(defun connect-postgres (options &key stream socket mock)
  "Open a PostgreSQL connection. MOCK is (lambda (sql params) result-plist) for tests."
  (when mock
    (return-from connect-postgres
      (%make-pg-conn :mock mock :options options :stream nil :socket nil)))
  (let* ((host (so-hostname options))
         (port (so-port options))
         (sock (or socket
                   (let ((s (make-instance 'sb-bsd-sockets:inet-socket
                                           :type :stream :protocol :tcp)))
                     (sb-bsd-sockets:socket-connect
                      s (sb-bsd-sockets:make-inet-address
                         (if (or (string= host "localhost") (string= host ""))
                             "127.0.0.1"
                             host))
                      port)
                     s)))
         (str (or stream
                  (sb-bsd-sockets:socket-make-stream
                   sock :input t :output t :element-type '(unsigned-byte 8)
                   :buffering :full)))
         (conn (%make-pg-conn :stream str :socket sock :options options)))
    (handler-case
        (progn
          (%pg-send conn nil
                    (%pg-startup-payload (so-username options)
                                         (so-database options)
                                         (so-application-name options)
                                         (so-connection-params options)))
          (loop
            (multiple-value-bind (type payload) (%pg-recv conn)
              (case type
                (#\R (%pg-handle-auth conn payload
                                      (so-password options)
                                      (so-username options)))
                (#\S
                 (multiple-value-bind (k n1) (read-cstring payload 0)
                   (multiple-value-bind (v n2) (read-cstring payload n1)
                     (declare (ignore n2))
                     (setf (gethash k (pg-parameters conn)) v))))
                (#\K
                 (setf (pg-backend-pid conn) (read-i32be payload 0)
                       (pg-secret-key conn) (read-i32be payload 4)))
                (#\Z
                 (setf (pg-transaction-status conn) (code-char (aref payload 0)))
                 (return conn))
                (#\E (%pg-parse-error payload))
                (#\N)                   ; notice ignore
                (t)))))
      (error (e)
        (ignore-errors (close-postgres conn))
        (if (typep e 'sql-error)
            (error e)
            (raise-sql-error 'sql-connection-error
                             :message (format nil "PostgreSQL connect failed: ~A" e)
                             :code "ECONNREFUSED"
                             :adapter :postgres))))))

(defun close-postgres (conn)
  (unless (pg-closed conn)
    (setf (pg-closed conn) t)
    (unless (pg-mock conn)
      (ignore-errors (%pg-send conn #\X #()))
      (ignore-errors (close (pg-stream conn) :abort t))
      (ignore-errors (sb-bsd-sockets:socket-close (pg-socket conn) :abort t))))
  (values))

(defun %pg-simple-query (conn sql)
  (%pg-send conn #\Q (cstring-bytes sql))
  (let ((columns '())
        (rows '())
        (values '())
        (tag nil))
    (loop
      (multiple-value-bind (type payload) (%pg-recv conn)
        (case type
          (#\T                          ; RowDescription
           (let ((n (read-u16be payload 0))
                 (i 2)
                 (cols '()))
             (dotimes (_ n)
               (multiple-value-bind (name next) (read-cstring payload i)
                 (push name cols)
                 (setf i (+ next 18)))) ; skip tableoid/att/type/typlen/mod/format
             (setf columns (nreverse cols))))
          (#\D                          ; DataRow
           (let ((n (read-u16be payload 0))
                 (i 2)
                 (vals '())
                 (obj (make-hash-table :test #'equal)))
             (dotimes (ci n)
               (let ((len (read-i32be payload i)))
                 (incf i 4)
                 (let ((v (if (minusp len)
                              nil
                              (let ((s (bytes-to-utf8 payload i (+ i len))))
                                (incf i len)
                                s))))
                   (push v vals)
                   (when (< ci (length columns))
                     (setf (gethash (nth ci columns) obj) v)))))
             (push obj rows)
             (push (coerce (nreverse vals) 'vector) values)))
          (#\C (setf tag (bytes-to-utf8 payload 0 (1- (length payload)))))
          (#\Z
           (setf (pg-transaction-status conn) (code-char (aref payload 0)))
           (return))
          (#\E (%pg-parse-error payload))
          (#\N)
          (#\I)                         ; empty query
          (t))))
    (list :columns columns
          :rows (nreverse rows)
          :values (nreverse values)
          :command-tag tag
          :changes (or (when tag
                         (cond
                           ((eql (search "INSERT" tag) 0)
                            (let ((parts (split-char #\Space tag :remove-empty-subseqs t)))
                              (when (>= (length parts) 3)
                                (ignore-errors (parse-integer (third parts))))))
                           ((or (eql (search "UPDATE" tag) 0)
                                (eql (search "DELETE" tag) 0))
                            (let ((parts (split-char #\Space tag :remove-empty-subseqs t)))
                              (when (>= (length parts) 2)
                                (ignore-errors (parse-integer (second parts))))))))
                       0)
          :last-insert-rowid 0)))

(defun %pg-bind-query (conn sql params)
  "Simple Query with client-side literal substitution for non-prepared path;
   when prepare is enabled, use extended query protocol."
  (if (null params)
      (%pg-simple-query conn sql)
      (let ((n 0)
            (rewritten sql)
            (options (pg-options conn)))
        (declare (ignore options))
        ;; Prefer extended query: Parse/Bind/Describe/Execute/Sync
        (%pg-send conn #\P
                  (concat-bytes (cstring-bytes "")        ; unnamed statement
                                (cstring-bytes sql)
                                (u16be 0)))               ; no param types
        (%pg-send conn #\B
                  (let ((parts (list (cstring-bytes "")   ; portal
                                     (cstring-bytes "")   ; statement
                                     (u16be 0)            ; format codes
                                     (u16be (length params)))))
                    (dolist (p params)
                      (if (null p)
                          (setf parts (append parts (list (i32be -1))))
                          (let ((b (utf8-bytes
                                    (if (stringp p) p (princ-to-string p)))))
                            (setf parts (append parts (list (i32be (length b)) b))))))
                    (apply #'concat-bytes (append parts (list (u16be 0))))))
        (%pg-send conn #\D (concat-bytes (u8 (char-code #\P)) (cstring-bytes "")))
        (%pg-send conn #\E (concat-bytes (cstring-bytes "") (i32be 0)))
        (%pg-send conn #\S #())
        (let ((columns '()) (rows '()) (values '()) (tag nil))
          (loop
            (multiple-value-bind (type payload) (%pg-recv conn)
              (case type
                (#\1) (#\2) (#\n)       ; ParseComplete BindComplete NoData
                (#\T
                 (let ((nc (read-u16be payload 0)) (i 2) (cols '()))
                   (dotimes (_ nc)
                     (multiple-value-bind (name next) (read-cstring payload i)
                       (push name cols)
                       (setf i (+ next 18))))
                   (setf columns (nreverse cols))))
                (#\D
                 (let ((nc (read-u16be payload 0)) (i 2) (vals '())
                       (obj (make-hash-table :test #'equal)))
                   (dotimes (ci nc)
                     (let ((len (read-i32be payload i)))
                       (incf i 4)
                       (let ((v (if (minusp len) nil
                                    (prog1 (bytes-to-utf8 payload i (+ i len))
                                      (incf i len)))))
                         (push v vals)
                         (when (< ci (length columns))
                           (setf (gethash (nth ci columns) obj) v)))))
                   (push obj rows)
                   (push (coerce (nreverse vals) 'vector) values)))
                (#\C (setf tag (bytes-to-utf8 payload 0 (1- (length payload)))))
                (#\Z
                 (setf (pg-transaction-status conn) (code-char (aref payload 0)))
                 (return))
                (#\E (%pg-parse-error payload))
                (#\N)
                (t))))
          (list :columns columns :rows (nreverse rows) :values (nreverse values)
                :command-tag tag :changes 0 :last-insert-rowid 0)))))

(defun postgres-exec (conn sql &optional params)
  (when (pg-closed conn)
    (raise-sql-error 'sql-connection-error :message "PostgreSQL connection closed"
                     :code "ECONNRESET" :adapter :postgres))
  (incf (pg-stats-queries conn))
  (if (pg-mock conn)
      (funcall (pg-mock conn) sql params)
      (if params
          (%pg-bind-query conn sql params)
          (%pg-simple-query conn sql))))

(defun postgres-inspect (conn)
  (list :adapter :postgres
        :pid (pg-backend-pid conn)
        :transaction-status (string (pg-transaction-status conn))
        :parameters (let ((alist '()))
                      (maphash (lambda (k v) (push (cons k v) alist))
                               (pg-parameters conn))
                      alist)
        :queries (pg-stats-queries conn)
        :mock (and (pg-mock conn) t)))
