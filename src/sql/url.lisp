;;;; url.lisp — connection URL / options parsing for Clun.SQL.

(in-package :clun.sql)

(defstruct (sql-options
            (:conc-name so-)
            (:constructor %make-sql-options))
  (adapter :postgres :type keyword)
  (hostname "localhost" :type string)
  (port 5432 :type integer)
  (username "postgres" :type string)
  (password "" :type string)
  (database "postgres" :type string)
  (filename nil)                       ; sqlite only
  (tls nil)
  (max 10 :type integer)
  (idle-timeout 0 :type integer)
  (connection-timeout 30 :type integer)
  (max-lifetime 0 :type integer)
  (bigint nil)
  (prepare t)
  (path nil)                           ; unix socket
  (connection-params nil)              ; alist
  (readonly nil)
  (create t)
  (readwrite t)
  (onconnect nil)
  (onclose nil)
  (allow-public-key-retrieval nil)
  ;; Clun exceed surface
  (query-timeout 0 :type integer)
  (application-name "clun" :type string)
  (debug nil)
  (named-params t))

(defun %url-decode (s)
  (with-output-to-string (out)
    (loop with i = 0
          with n = (length s)
          while (< i n)
          do (let ((c (char s i)))
               (cond
                 ((char= c #\%)
                  (when (< (+ i 2) n)
                    (write-char (code-char (parse-integer s :start (1+ i)
                                                          :end (+ i 3) :radix 16))
                                out)
                    (incf i 3)))
                 ((char= c #\+)
                  (write-char #\Space out)
                  (incf i))
                 (t (write-char c out) (incf i)))))))

(defun %split-once (string separator)
  (let ((pos (position separator string)))
    (if pos
        (values (subseq string 0 pos) (subseq string (1+ pos)))
        (values string nil))))

(defun %parse-query (q)
  (when (and q (plusp (length q)))
    (loop for part in (split-char #\& q)
          for (k v) = (multiple-value-list (%split-once part #\=))
          when (and k (plusp (length k)))
            collect (cons (string-downcase (%url-decode k))
                          (%url-decode (or v ""))))))

(defun %detect-adapter (url-or-adapter)
  (cond
    ((null url-or-adapter) :postgres)
    ((keywordp url-or-adapter) url-or-adapter)
    ((stringp url-or-adapter)
     (let ((s (string-downcase url-or-adapter)))
       (cond
         ((or (string= s "postgres") (string= s "postgresql") (string= s "pg"))
          :postgres)
         ((or (string= s "mysql") (string= s "mysql2") (string= s "mariadb"))
          :mysql)
         ((or (string= s "sqlite") (string= s "sqlite3"))
          :sqlite)
         (t nil))))
    (t nil)))

(defun %default-port (adapter)
  (ecase adapter
    (:postgres 5432)
    (:mysql 3306)
    (:sqlite 0)))

(defun %default-user (adapter)
  (ecase adapter
    (:postgres "postgres")
    (:mysql "root")
    (:sqlite "")))

(defun parse-sql-url (url)
  "Parse a connection URL into an sql-options struct.
   Supports postgres://, postgresql://, mysql://, mysql2://, mariadb://,
   sqlite://, file://, :memory:, and bare sqlite filenames with adapter."
  (let ((s (if (pathnamep url) (namestring url) (string url))))
    (cond
      ((or (string= s ":memory:")
           (string= s "sqlite://:memory:")
           (string= s "sqlite::memory:")
           (string= s "file::memory:")
           (string= s "file://:memory:"))
       (%make-sql-options :adapter :sqlite :filename ":memory:"
                          :hostname "" :port 0 :username "" :database ":memory:"))
      ((or (eql (search "sqlite://" s :test #'char-equal) 0)
           (eql (search "sqlite:" s :test #'char-equal) 0)
           (eql (search "file://" s :test #'char-equal) 0)
           (eql (search "file:" s :test #'char-equal) 0))
       (multiple-value-bind (scheme rest)
           (let ((idx (position #\: s)))
             (values (subseq s 0 idx) (subseq s (1+ idx))))
         (declare (ignore scheme))
         (let* ((path (string-left-trim "/" rest))
                (qpos (position #\? path))
                (file (if qpos (subseq path 0 qpos) path))
                (qs (when qpos (subseq path (1+ qpos))))
                (params (%parse-query qs))
                (mode (cdr (assoc "mode" params :test #'string=)))
                (ro (equalp mode "ro"))
                (rwc (or (null mode) (equalp mode "rwc") (equalp mode "rw"))))
           (%make-sql-options
            :adapter :sqlite
            :filename (if (zerop (length file)) ":memory:" file)
            :hostname ""
            :port 0
            :username ""
            :database (if (zerop (length file)) ":memory:" file)
            :readonly ro
            :create (or (null mode) (equalp mode "rwc"))
            :readwrite (not ro)
            :connection-params params))))
      (t
       ;; scheme://[user[:pass]@]host[:port][/db][?k=v]
       (let* ((scheme-end (search "://" s))
              (scheme (if scheme-end (string-downcase (subseq s 0 scheme-end)) "postgres"))
              (adapter (or (%detect-adapter scheme) :postgres))
              (rest (if scheme-end (subseq s (+ scheme-end 3)) s))
              (qpos (position #\? rest))
              (main (if qpos (subseq rest 0 qpos) rest))
              (params (%parse-query (when qpos (subseq rest (1+ qpos)))))
              (at (position #\@ main :from-end t))
              (auth (when at (subseq main 0 at)))
              (hostpart (if at (subseq main (1+ at)) main))
              (slash (position #\/ hostpart))
              (hostport (if slash (subseq hostpart 0 slash) hostpart))
              (db (if slash (subseq hostpart (1+ slash)) nil))
              (user nil)
              (pass "")
              (host "localhost")
              (port (%default-port adapter)))
         (when auth
           (multiple-value-bind (u p) (%split-once auth #\:)
             (setf user (%url-decode u)
                   pass (if p (%url-decode p) ""))))
         (cond
           ((and (plusp (length hostport)) (char= (char hostport 0) #\/))
            ;; unix socket path form: mysql://user:pass@/db?socket=/path
            (setf host ""))
           ((and (plusp (length hostport)) (char= (char hostport 0) #\[))
            ;; IPv6 [addr]:port
            (let ((rb (position #\] hostport)))
              (setf host (subseq hostport 1 rb))
              (when (and rb (< (1+ rb) (length hostport))
                         (char= (char hostport (1+ rb)) #\:))
                (setf port (parse-integer hostport :start (+ rb 2))))))
           (t
            (multiple-value-bind (h p) (%split-once hostport #\:)
              (setf host (if (zerop (length h)) "localhost" h))
              (when p (setf port (parse-integer p))))))
         (let ((socket (cdr (assoc "socket" params :test #'string=)))
               (ssl (cdr (assoc "ssl" params :test #'string=))))
           (%make-sql-options
            :adapter adapter
            :hostname host
            :port port
            :username (or user (%default-user adapter))
            :password pass
            :database (or db (or user (%default-user adapter)))
            :path socket
            :tls (or (equalp ssl "true") (equalp ssl "1") (equalp ssl "require"))
            :connection-params params
            :max (let ((m (cdr (assoc "max" params :test #'string=))))
                   (if m (parse-integer m) 10)))))))))

(defun merge-sql-options (&rest option-plists-or-structs)
  "Left-to-right merge of sql-options / plists / alists into one sql-options.
   Also accepts a single keyword plist when called as (merge-sql-options '(:adapter :sqlite ...))."
  (let ((base (%make-sql-options))
        (items option-plists-or-structs))
    ;; If the only argument is itself a keyword plist, unwrap it.
    (when (and (= (length items) 1)
               (consp (first items))
               (keywordp (first (first items))))
      (setf items (list (first items))))
    (dolist (item items base)
      (cond
        ((null item))
        ((sql-options-p item)
         (setf base item))
        ((stringp item)
         (setf base (parse-sql-url item)))
        ((and (listp item) (keywordp (first item)))
         (labels ((getk (k &optional default)
                    (or (getf item k)
                        (when (and (consp item) (consp (first item)))
                          (cdr (assoc k item :test #'equal)))
                        (when (stringp k)
                          (getf item (intern (string-upcase k) :keyword)))
                        default)))
           (let ((adapter (or (%detect-adapter (getk :adapter (getk "adapter")))
                              (so-adapter base)))
                 (url (or (getk :url (getk "url"))
                          (getk :hostname nil))))
             (when (and (stringp url)
                        (or (search "://" url) (search "sqlite" url :test #'char-equal)
                            (string= url ":memory:")))
               (setf base (parse-sql-url url)))
             (when (getk :adapter (getk "adapter"))
               (setf (so-adapter base) adapter))
             (when (getk :hostname (getk "hostname" (getk :host (getk "host"))))
               (setf (so-hostname base)
                     (string (getk :hostname (getk "hostname" (getk :host (getk "host")))))))
             (when (getk :port (getk "port"))
               (setf (so-port base)
                     (let ((p (getk :port (getk "port"))))
                       (if (integerp p) p (parse-integer (string p))))))
             (when (getk :username (getk "username" (getk :user (getk "user"))))
               (setf (so-username base)
                     (string (getk :username (getk "username" (getk :user (getk "user")))))))
             (when (getk :password (getk "password" (getk :pass (getk "pass"))))
               (setf (so-password base)
                     (string (getk :password (getk "password" (getk :pass (getk "pass")))))))
             (when (getk :database (getk "database" (getk :db (getk "db"))))
               (setf (so-database base)
                     (string (getk :database (getk "database" (getk :db (getk "db")))))))
             (when (getk :filename (getk "filename"))
               (setf (so-filename base) (string (getk :filename (getk "filename")))
                     (so-adapter base) :sqlite))
             (when (getk :max (getk "max"))
               (setf (so-max base) (getk :max (getk "max"))))
             (when (getk :idle-timeout (getk "idleTimeout" (getk :idle_timeout)))
               (setf (so-idle-timeout base)
                     (getk :idle-timeout (getk "idleTimeout" (getk :idle_timeout)))))
             (when (getk :connection-timeout
                         (getk "connectionTimeout"
                               (getk :connect-timeout (getk "connectTimeout"))))
               (setf (so-connection-timeout base)
                     (getk :connection-timeout
                           (getk "connectionTimeout"
                                 (getk :connect-timeout (getk "connectTimeout"))))))
             (when (getk :tls (getk "tls" (getk :ssl (getk "ssl"))))
               (setf (so-tls base) (getk :tls (getk "tls" (getk :ssl (getk "ssl"))))))
             (when (getk :path (getk "path"))
               (setf (so-path base) (getk :path (getk "path"))))
             (when (getk :bigint (getk "bigint"))
               (setf (so-bigint base) (getk :bigint (getk "bigint"))))
             (when (member :prepare item)
               (setf (so-prepare base) (getf item :prepare)))
             (when (getk :query-timeout (getk "queryTimeout"))
               (setf (so-query-timeout base)
                     (getk :query-timeout (getk "queryTimeout"))))
             (when (getk :application-name (getk "application_name"))
               (setf (so-application-name base)
                     (string (getk :application-name (getk "application_name"))))))))
        (t (error 'sql-error :message "Invalid SQL options" :code "ERR_INVALID_ARG"))))))
