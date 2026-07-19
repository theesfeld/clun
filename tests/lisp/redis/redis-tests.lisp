;;;; redis-tests.lisp — pure-CL Redis FULL PORT (#184)

(in-package :clun-test)

(define-test redis-embedded-roundtrip
  (let ((c (clun.redis:make-redis-client)))
    (clun.redis:redis-connect c)
    (clun.redis:redis-call c "FLUSHDB")
    (is string= "OK" (clun.redis:redis-set c "k" "v"))
    (is string= "v" (clun.redis:redis-get c "k"))
    (is = 1 (clun.redis:redis-exists c "k"))
    (is = 1 (clun.redis:redis-del c "k"))
    (is eql nil (clun.redis:redis-get c "k"))
    (clun.redis:redis-set c "n" "0")
    (is = 1 (clun.redis:redis-incr c "n"))
    (is = 2 (clun.redis:redis-incr c "n"))
    (is string= "PONG" (clun.redis:redis-call c "PING"))
    (is = 1 (clun.redis:redis-call c "HSET" "h" "f" "1"))
    (is string= "1" (clun.redis:redis-call c "HGET" "h" "f"))
    (clun.redis:redis-close c)))

(define-test redis-resp-encode-shape
  (let ((oct (clun.redis:resp-encode (list "SET" "a" "b"))))
    (of-type (simple-array (unsigned-byte 8) (*)) oct)
    (true (> (length oct) 10))))

(define-test redis-process-store-flush
  (let ((c (clun.redis:make-redis-client)))
    (clun.redis:redis-connect c)
    (clun.redis:redis-call c "FLUSHDB")
    (is = 0 (clun.redis:redis-call c "DBSIZE"))
    (clun.redis:redis-set c "only" "x")
    (is = 1 (clun.redis:redis-call c "DBSIZE"))
    (clun.redis:redis-call c "FLUSHDB")
    (is = 0 (clun.redis:redis-call c "DBSIZE"))
    (clun.redis:redis-close c)))
