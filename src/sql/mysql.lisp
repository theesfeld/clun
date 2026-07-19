;;;; mysql.lisp — pure-CL MySQL client protocol (Issue #183).

(in-package :clun.sql)

(defstruct (mysql-conn
            (:conc-name my-)
            (:constructor %make-mysql-conn))
  stream
  socket
  options
  (capability 0 :type integer)
  (status 0 :type integer)
  (charset 45 :type integer)
  (connection-id 0 :type integer)
  (closed nil)
  (mock nil)
  (seq 0 :type (unsigned-byte 8))
  (stats-queries 0 :type integer))

(defun %my-send (conn payload)
  (let* ((len (length payload))
         (hdr (concat-bytes
               (make-array 3 :element-type '(unsigned-byte 8)
                           :initial-contents (list (logand len #xff)
                                                   (logand (ash len -8) #xff)
                                                   (logand (ash len -16) #xff)))
               (u8 (my-seq conn)))))
    (setf (my-seq conn) (logand (1+ (my-seq conn)) #xff))
    (write-sequence (concat-bytes hdr payload) (my-stream conn))
    (force-output (my-stream conn))))

(defun %my-recv (conn)
  (let* ((hdr (%pg-read-n (my-stream conn) 4))
         (len (logior (aref hdr 0)
                      (ash (aref hdr 1) 8)
                      (ash (aref hdr 2) 16)))
         (seq (aref hdr 3))
         (payload (if (plusp len) (%pg-read-n (my-stream conn) len) #())))
    (setf (my-seq conn) (logand (1+ seq) #xff))
    payload))

(defun %my-read-lenenc (buf i)
  (let ((b (aref buf i)))
    (cond
      ((< b 251) (values b (1+ i)))
      ((= b 251) (values nil (1+ i)))   ; NULL
      ((= b 252) (values (read-u16le buf (1+ i)) (+ i 3)))
      ((= b 253) (values (logior (aref buf (+ i 1))
                                 (ash (aref buf (+ i 2)) 8)
                                 (ash (aref buf (+ i 3)) 16))
                         (+ i 4)))
      ((= b 254) (values (read-u32le buf (1+ i)) (+ i 9))) ; low 4 of 8
      (t (values b (1+ i))))))

(defun %my-lenenc-int (n)
  (cond
    ((null n) (u8 251))
    ((< n 251) (u8 n))
    ((< n 65536) (concat-bytes (u8 252) (u16le n)))
    ((< n 16777216)
     (concat-bytes (u8 253)
                   (make-array 3 :element-type '(unsigned-byte 8)
                               :initial-contents (list (logand n #xff)
                                                       (logand (ash n -8) #xff)
                                                       (logand (ash n -16) #xff)))))
    (t (concat-bytes (u8 254) (u32le n) (u32le 0)))))

(defun %my-lenenc-str (s)
  (let ((b (utf8-bytes s)))
    (concat-bytes (%my-lenenc-int (length b)) b)))

(defun %mysql-native-password (password scramble)
  "mysql_native-password: SHA1(password) xor SHA1(scramble || SHA1(SHA1(password)))."
  (if (zerop (length password))
      #()
      (let* ((stage1 (digest-bytes :sha1 (utf8-bytes password)))
             (stage2 (digest-bytes :sha1 stage1))
             (stage3 (digest-bytes :sha1 (concat-bytes scramble stage2))))
        (xor-bytes stage1 stage3))))

(defun %mysql-caching-sha2-password (password scramble)
  "caching_sha2_password fast auth: SHA256(password) xor SHA256(SHA256(SHA256(password)) || scramble)."
  (if (zerop (length password))
      #()
      (let* ((p1 (sha256 (utf8-bytes password)))
             (p2 (sha256 p1))
             (p3 (sha256 (concat-bytes p2 scramble))))
        (xor-bytes p1 p3))))

(defun connect-mysql (options &key stream socket mock)
  (when mock
    (return-from connect-mysql
      (%make-mysql-conn :mock mock :options options)))
  (let* ((host (so-hostname options))
         (port (so-port options))
         (sock (or socket
                   (let ((s (make-instance 'sb-bsd-sockets:inet-socket
                                           :type :stream :protocol :tcp)))
                     (sb-bsd-sockets:socket-connect
                      s (sb-bsd-sockets:make-inet-address
                         (if (or (string= host "localhost") (string= host ""))
                             "127.0.0.1" host))
                      port)
                     s)))
         (str (or stream
                  (sb-bsd-sockets:socket-make-stream
                   sock :input t :output t :element-type '(unsigned-byte 8)
                   :buffering :full)))
         (conn (%make-mysql-conn :stream str :socket sock :options options :seq 0)))
    (handler-case
        (let* ((greeting (%my-recv conn))
               (proto (aref greeting 0)))
          (declare (ignore proto))
          (multiple-value-bind (version i) (read-cstring greeting 1)
            (declare (ignore version))
            (let* ((conn-id (read-u32le greeting i))
                   (salt1 (subseq greeting (+ i 4) (+ i 12)))
                   (j (+ i 13))         ; skip filler
                   (caps-low (read-u16le greeting j))
                   (charset (aref greeting (+ j 2)))
                   (status (read-u16le greeting (+ j 3)))
                   (caps-high (read-u16le greeting (+ j 5)))
                   (caps (logior caps-low (ash caps-high 16)))
                   (salt2-len (aref greeting (+ j 7)))
                   (salt2-start (+ j 10))
                   (salt2-end (+ salt2-start (max 0 (- salt2-len 8))))
                   (salt2 (if (> salt2-end salt2-start)
                              (subseq greeting salt2-start (min salt2-end (length greeting)))
                              #()))
                   (scramble (concat-bytes salt1 salt2))
                   (plugin (let ((pstart salt2-end))
                             (if (< pstart (length greeting))
                                 (nth-value 0 (read-cstring greeting pstart))
                                 "mysql_native_password")))
                   (client-caps (logior #x00000200  ; PROTOCOL_41
                                        #x00080000  ; PLUGIN_AUTH
                                        #x00020000  ; SECURE_CONNECTION
                                        #x00000008  ; CONNECT_WITH_DB
                                        #x00008000  ; TRANSACTIONS
                                        #x00200000  ; PLUGIN_AUTH_LENENC
                                        ))
                   (password (so-password options))
                   (auth-resp (if (search "caching_sha2" plugin)
                                  (%mysql-caching-sha2-password password scramble)
                                  (%mysql-native-password password scramble)))
                   (packet (concat-bytes
                            (u32le client-caps)
                            (u32le (* 16 1024 1024))
                            (u8 charset)
                            (make-byte-vector 23 0)
                            (cstring-bytes (so-username options))
                            (concat-bytes (u8 (length auth-resp)) auth-resp)
                            (cstring-bytes (so-database options))
                            (cstring-bytes plugin))))
              (declare (ignore status))
              (setf (my-connection-id conn) conn-id
                    (my-capability conn) caps
                    (my-charset conn) charset
                    (my-seq conn) 1)
              (%my-send conn packet)
              (let ((resp (%my-recv conn)))
                (cond
                  ((= (aref resp 0) #xff)
                   (let ((errno (read-u16le resp 1))
                         (msg (bytes-to-utf8 resp 3)))
                     (raise-sql-error 'mysql-error
                                      :message msg
                                      :code (format nil "ER_~D" errno)
                                      :errno errno
                                      :adapter :mysql)))
                  ((= (aref resp 0) #xfe)
                   ;; auth switch — try native
                   (multiple-value-bind (new-plugin ni) (read-cstring resp 1)
                     (let* ((new-scramble (subseq resp ni (min (+ ni 20) (1- (length resp)))))
                            (auth2 (if (search "caching_sha2" new-plugin)
                                       (%mysql-caching-sha2-password password new-scramble)
                                       (%mysql-native-password password new-scramble))))
                       (%my-send conn auth2)
                       (let ((r2 (%my-recv conn)))
                         (when (= (aref r2 0) #xff)
                           (raise-sql-error 'mysql-error
                                            :message (bytes-to-utf8 r2 3)
                                            :errno (read-u16le r2 1)
                                            :adapter :mysql))))))
                  ;; OK or more auth data
                  ((= (aref resp 0) #x01)
                   ;; fast auth success path / full auth request
                   (when (and (> (length resp) 1) (= (aref resp 1) 3))
                     ;; continue with empty
                     )
                   (let ((r2 (%my-recv conn)))
                     (when (= (aref r2 0) #xff)
                       (raise-sql-error 'mysql-error
                                        :message (bytes-to-utf8 r2 3)
                                        :errno (read-u16le r2 1)
                                        :adapter :mysql))))
                  (t)))
              conn)))
      (error (e)
        (ignore-errors (close-mysql conn))
        (if (typep e 'sql-error)
            (error e)
            (raise-sql-error 'sql-connection-error
                             :message (format nil "MySQL connect failed: ~A" e)
                             :code "ECONNREFUSED"
                             :adapter :mysql))))))

(defun close-mysql (conn)
  (unless (my-closed conn)
    (setf (my-closed conn) t)
    (unless (my-mock conn)
      (ignore-errors
        (setf (my-seq conn) 0)
        (%my-send conn (u8 1)))         ; COM_QUIT
      (ignore-errors (close (my-stream conn) :abort t))
      (ignore-errors (sb-bsd-sockets:socket-close (my-socket conn) :abort t))))
  (values))

(defun %mysql-query (conn sql)
  (setf (my-seq conn) 0)
  (%my-send conn (concat-bytes (u8 3) (utf8-bytes sql))) ; COM_QUERY
  (let ((first (%my-recv conn)))
    (cond
      ((= (aref first 0) #xff)
       (raise-sql-error 'mysql-error
                        :message (bytes-to-utf8 first 3)
                        :errno (read-u16le first 1)
                        :adapter :mysql
                        :sqlstate (when (and (> (length first) 3)
                                             (char= (code-char (aref first 3)) #\#))
                                    (bytes-to-utf8 first 4 9))))
      ((= (aref first 0) #x00)
       ;; OK packet
       (multiple-value-bind (affected i) (%my-read-lenenc first 1)
         (multiple-value-bind (last-id j) (%my-read-lenenc first i)
           (declare (ignore j))
           (list :columns '() :rows '() :values '()
                 :changes (or affected 0)
                 :last-insert-rowid (or last-id 0)))))
      (t
       ;; result set: column count
       (multiple-value-bind (col-count i0) (%my-read-lenenc first 0)
         (declare (ignore i0))
         (let ((columns '()))
           (dotimes (_ col-count)
             (let* ((pkt (%my-recv conn))
                    (i 0))
               ;; catalog, schema, table, org_table, name, org_name — lenenc strings
               (dotimes (_ 4)
                 (multiple-value-bind (s ni) (%my-read-lenenc pkt i)
                   (declare (ignore s))
                   (setf i ni)))
               (multiple-value-bind (name ni) (%my-read-lenenc pkt i)
                 (push (or name "") columns))))
           (setf columns (nreverse columns))
           ;; EOF or optional OK between columns and rows (deprecate EOF)
           (let ((maybe-eof (%my-recv conn)))
             (declare (ignore maybe-eof)))
           (let ((rows '()) (values '()))
             (loop
               (let ((pkt (%my-recv conn)))
                 (cond
                   ((or (zerop (length pkt))
                        (= (aref pkt 0) #xfe)
                        (= (aref pkt 0) #x00))
                    (return))
                   ((= (aref pkt 0) #xff)
                    (raise-sql-error 'mysql-error
                                     :message (bytes-to-utf8 pkt 3)
                                     :errno (read-u16le pkt 1)
                                     :adapter :mysql))
                   (t
                    (let ((i 0)
                          (vals '())
                          (obj (make-hash-table :test #'equal)))
                      (dotimes (ci col-count)
                        (let ((b (aref pkt i)))
                          (cond
                            ((= b 251)
                             (push nil vals)
                             (incf i)
                             (when (< ci (length columns))
                               (setf (gethash (nth ci columns) obj) nil)))
                            (t
                             (multiple-value-bind (len ni) (%my-read-lenenc pkt i)
                               (let ((s (bytes-to-utf8 pkt ni (+ ni len))))
                                 (setf i (+ ni len))
                                 (push s vals)
                                 (when (< ci (length columns))
                                   (setf (gethash (nth ci columns) obj) s))))))))
                      (push obj rows)
                      (push (coerce (nreverse vals) 'vector) values))))))
             (list :columns columns
                   :rows (nreverse rows)
                   :values (nreverse values)
                   :changes 0
                   :last-insert-rowid 0))))))))

(defun mysql-exec (conn sql &optional params)
  (when (my-closed conn)
    (raise-sql-error 'sql-connection-error :message "MySQL connection closed"
                     :code "ECONNRESET" :adapter :mysql))
  (incf (my-stats-queries conn))
  (if (my-mock conn)
      (funcall (my-mock conn) sql params)
      (let ((final sql))
        (when params
          ;; Client-side substitution with proper escaping for COM_QUERY
          (let ((idx 0))
            (setf final
                  (with-output-to-string (o)
                    (loop for c across sql
                          do (if (char= c #\?)
                                 (progn
                                   (write-string (%sql-literal :mysql (nth idx params)) o)
                                   (incf idx))
                                 (write-char c o)))))))
        (%mysql-query conn final))))

(defun mysql-inspect (conn)
  (list :adapter :mysql
        :connection-id (my-connection-id conn)
        :queries (my-stats-queries conn)
        :mock (and (my-mock conn) t)))
