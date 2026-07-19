;;;; clun-redis.lisp — Clun.redis JavaScript boundary (FULL PORT #184).
;;;;
;;;; Bun.redis-compatible Promise API over pure-CL embedded Redis store.
;;;; Exceeds Bun: offline hermetic store without an external Redis process.

(in-package :clun.runtime)

(defun %redis-js-string (value)
  (cond
    ((null value) nil)
    ((eng:js-undefined-p value) nil)
    ((eq value eng:+null+) nil)
    ((eng:js-string-p value) value)
    ((stringp value) value)
    (t (eng:to-string value))))

(defun %redis-args-to-strings (args)
  (loop for a in args
        for s = (%redis-js-string a)
        when s collect s))

(defun %redis-resolved-promise (global value)
  (eng:js-construct
   (eng:js-get global "Promise")
   (list
    (eng:make-native-function
     "" 2
     (lambda (this args)
       (declare (ignore this))
       (eng:js-call (eng:arg args 0) eng:+undefined+ (list value))
       eng:+undefined+)))))

(defun %redis-rejected-promise (global condition)
  (let* ((err (eng:make-error-object
               :error-prototype "Error"
               (if (typep condition 'clun.redis:redis-error)
                   (clun.redis:redis-error-message condition)
                   (princ-to-string condition)))))
    (eng:js-set err "code"
                (if (typep condition 'clun.redis:redis-error)
                    (or (clun.redis:redis-error-code condition) "ERR_REDIS")
                    "ERR_REDIS")
                nil)
    (eng:js-construct
     (eng:js-get global "Promise")
     (list
      (eng:make-native-function
       "" 2
       (lambda (this args)
         (declare (ignore this))
         (eng:js-call (eng:arg args 1) eng:+undefined+ (list err))
         eng:+undefined+))))))

(defun %redis-result->js (value)
  (cond
    ((null value) eng:+null+)
    ((eq value t) eng:+true+)
    ((stringp value) value)
    ((integerp value) (coerce value 'double-float))
    ((floatp value) (coerce value 'double-float))
    ((and (consp value) (consp (car value)))
     ;; alist (HGETALL-shaped) → object
     (let ((obj (eng:new-object)))
       (dolist (pair value obj)
         (eng:data-prop obj (car pair) (%redis-result->js (cdr pair))))))
    ((listp value)
     (eng:new-array (mapcar #'%redis-result->js value)))
    (t (princ-to-string value))))

(defmacro %redis-async ((global) &body body)
  (let ((g (gensym)) (e (gensym)))
    `(let ((,g ,global))
       (handler-case (%redis-resolved-promise ,g (progn ,@body))
         (error (,e)
           (%redis-rejected-promise ,g ,e))))))

(defun %redis-run (global client op args)
  (%redis-async (global)
    (%redis-result->js
     (ecase op
       (:get (clun.redis:redis-get client (%redis-js-string (first args))))
       (:set (clun.redis:redis-set client
                                   (%redis-js-string (first args))
                                   (%redis-js-string (second args))))
       (:del (apply #'clun.redis:redis-del client
                    (%redis-args-to-strings args)))
       (:exists (apply #'clun.redis:redis-exists client
                       (%redis-args-to-strings args)))
       (:incr (clun.redis:redis-incr client (%redis-js-string (first args))))
       (:ping (clun.redis:redis-call client "PING"))
       (:publish (clun.redis:redis-publish client
                                            (%redis-js-string (first args))
                                            (%redis-js-string (second args))))
       (:send (apply #'clun.redis:redis-call client
                     (%redis-js-string (first args))
                     (%redis-args-to-strings (rest args))))))))

(defun make-clun-redis-client (global &optional url)
  (let* ((client (if url
                     (clun.redis:make-redis-client (%redis-js-string url))
                     (clun.redis:make-redis-client)))
         (object (eng:new-object)))
    (flet ((method (name arity op)
             (eng:data-prop
              object name
              (eng:make-native-function
               name arity
               (lambda (this args)
                 (declare (ignore this))
                 (%redis-run global client op args))))))
      (method "get" 1 :get)
      (method "set" 2 :set)
      (method "del" 1 :del)
      (method "exists" 1 :exists)
      (method "incr" 1 :incr)
      (method "ping" 0 :ping)
      (method "publish" 2 :publish)
      (method "send" 1 :send)
      (eng:data-prop
       object "connect"
       (eng:make-native-function
        "connect" 0
        (lambda (this args)
          (declare (ignore this args))
          (clun.redis:redis-connect client)
          (%redis-resolved-promise global eng:+undefined+))))
      (eng:data-prop
       object "close"
       (eng:make-native-function
        "close" 0
        (lambda (this args)
          (declare (ignore this args))
          (clun.redis:redis-close client)
          eng:+undefined+)))
      object)))

(defun make-clun-redis (global)
  "Bun-shaped Clun.redis default client + RedisClient constructor."
  (let ((object (make-clun-redis-client global)))
    (eng:data-prop
     object "RedisClient"
     (eng:make-native-function
      "RedisClient" 1
      (lambda (this args)
        (declare (ignore this))
        (make-clun-redis-client global (when args (first args))))))
    object))

(defun install-clun-redis (clun global)
  (eng:nonconfigurable-data-prop clun "redis" (make-clun-redis global)))
