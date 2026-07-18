;;;; compress-tests.lisp — pure-CL gzip/zlib/raw-deflate round-trips (Issue #134).

(in-package :clun-test)

(defun %cmp-bytes (s)
  (sb-ext:string-to-octets s :external-format :utf-8))

(define-test gzip-roundtrip
  (let* ((src (%cmp-bytes "hello pure-cl gzip"))
         (gz (clun.compress:gzip-compress src))
         (out (clun.compress:gunzip gz)))
    (true (clun.compress:gzip-magic-p gz))
    (is equalp src out)))

(define-test zlib-roundtrip
  (let* ((src (%cmp-bytes "zlib body"))
         (z (clun.compress:zlib-compress src))
         (out (clun.compress:zlib-decompress z)))
    (is equalp src out)))

(define-test raw-deflate-roundtrip
  (let* ((src (%cmp-bytes "raw deflate body"))
         (d (clun.compress:raw-deflate-compress src))
         (out (clun.compress:raw-inflate d)))
    (is equalp src out)))

(define-test gunzip-rejects-junk
  (let ((r (handler-case
               (progn (clun.compress:gunzip #(1 2 3 4 5 6 7 8)) :ok)
             (clun.compress:compress-error () :err))))
    (is eq :err r)))

(define-test gunzip-respects-size-cap
  (let* ((src (%cmp-bytes "tiny"))
         (gz (clun.compress:gzip-compress src))
         (r (handler-case
                (progn (clun.compress:gunzip gz :max-bytes 1) :ok)
              (clun.compress:compress-error () :cap))))
    (is eq :cap r)))
