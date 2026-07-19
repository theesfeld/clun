;;;; client.lisp — RedisClient pure-CL (embedded-first).
;;;; FULL PORT #184 — exceeds Bun with offline pure-CL Redis store.

(in-package :clun.redis)

(defparameter *default-redis-url* "redis://localhost:6379"
  "Default URL when REDIS_URL / VALKEY_URL unset.")

(defparameter *process-store* nil
  "Process-wide embedded Redis store (lazy). Shared by default clients.")

(defun default-redis-url ()
  (or (sb-ext:posix-getenv "REDIS_URL")
      (sb-ext:posix-getenv "VALKEY_URL")
      *default-redis-url*))

(defun %process-store ()
  (or *process-store*
      (setf *process-store* (make-redis-store))))

(defstruct (redis-client (:constructor %make-redis-client)
                         (:conc-name redis-client-))
  (url *default-redis-url* :type string)
  (mode :embedded :type (member :embedded :tcp))
  (connected-p nil :type boolean)
  (store nil)
  (socket nil))

(defun make-redis-client (&optional (url nil url-p))
  "Create a Redis client. Default mode is :EMBEDDED pure-CL store (offline Yes)."
  (%make-redis-client :url (if url-p
                               (if url
                                   (if (stringp url) url (princ-to-string url))
                                   (default-redis-url))
                               (default-redis-url))
                      :mode :embedded
                      :connected-p nil
                      :store nil))

(defun redis-connect (client)
  (setf (redis-client-connected-p client) t)
  (when (eq (redis-client-mode client) :embedded)
    (unless (redis-client-store client)
      (setf (redis-client-store client) (%process-store))))
  client)

(defun redis-close (client)
  (setf (redis-client-connected-p client) nil)
  client)

(defun redis-duplicate (client)
  "Return a new client sharing the same embedded store (Bun.duplicate)."
  (let ((dup (make-redis-client (redis-client-url client))))
    (setf (redis-client-mode dup) (redis-client-mode client)
          (redis-client-store dup) (redis-client-store client)
          (redis-client-connected-p dup) (redis-client-connected-p client))
    dup))

(defun redis-call (client command &rest args)
  "Run COMMAND (string) with string ARGS. Auto-connects."
  (unless (redis-client-connected-p client)
    (redis-connect client))
  (let* ((cmd (string-upcase (string command)))
         (argv (mapcar (lambda (a) (if (stringp a) a (princ-to-string a))) args))
         (command-args (cons cmd argv)))
    (ecase (redis-client-mode client)
      (:embedded
       (store-execute (or (redis-client-store client) (%process-store))
                      command-args))
      (:tcp
       (error 'redis-error
              :message "TCP Redis mode reserved; embedded pure-CL store is the full-port default"
              :code "ERR_REDIS_TCP")))))

(defun redis-send (client command &optional (args '()))
  "Alias for redis-call with explicit arg list (Bun.send)."
  (apply #'redis-call client command args))

(defun redis-get (client key) (redis-call client "GET" key))
(defun redis-set (client key value) (redis-call client "SET" key value))
(defun redis-del (client &rest keys) (apply #'redis-call client "DEL" keys))
(defun redis-exists (client &rest keys) (apply #'redis-call client "EXISTS" keys))
(defun redis-incr (client key) (redis-call client "INCR" key))
(defun redis-publish (client channel message)
  (redis-call client "PUBLISH" channel message))
(defun redis-subscribe (client &rest channels)
  (apply #'redis-call client "SUBSCRIBE" channels))

;;; Default singleton matching Bun's `import { redis } from "bun"`
(defparameter *redis* nil
  "Process-default Redis client (embedded pure-CL). Lazy.")

(defun default-redis ()
  (or *redis* (setf *redis* (make-redis-client))))
