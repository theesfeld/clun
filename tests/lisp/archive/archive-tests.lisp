;;;; archive-tests.lisp — ustar write/extract + zip (Issue #134).

(in-package :clun-test)

(define-test write-tar-roundtrip
  (let* ((entries (list (cons "hello.txt" "hi")
                        (cons "nested/x.txt" "nested")))
         (tar (clun.archive:write-tar entries))
         (parsed (clun.archive:parse-archive-bytes tar))
         (names (mapcar #'clun.tarball:te-name parsed)))
    (true (>= (length tar) 1024))
    (true (member "hello.txt" names :test #'string=))
    (true (member "nested/x.txt" names :test #'string=))
    (let ((e (find "hello.txt" parsed :key #'clun.tarball:te-name :test #'string=)))
      (is string= "hi"
          (sb-ext:octets-to-string (clun.tarball:te-data e) :external-format :utf-8)))))

(define-test tar-gzip-roundtrip
  (let* ((bytes (clun.archive:build-archive-bytes
                 (list (cons "a.txt" "alpha"))
                 :compress :gzip))
         (parsed (clun.archive:parse-archive-bytes bytes)))
    (true (clun.compress:gzip-magic-p bytes))
    (is = 1 (length parsed))
    (is string= "a.txt" (clun.tarball:te-name (first parsed)))))

(define-test extract-archive-safe
  (let* ((dir (namestring
               (uiop:ensure-directory-pathname
                (merge-pathnames
                 (format nil "clun-archive-test-~a/" (get-universal-time))
                 (uiop:temporary-directory)))))
         (bytes (clun.archive:build-archive-bytes
                 (list (cons "ok.txt" "payload"))))
         (n (clun.archive:extract-archive bytes dir)))
    (unwind-protect
         (progn
           (true (plusp n))
           (is string= "payload"
               (uiop:read-file-string (merge-pathnames "ok.txt" (pathname dir)))))
      (uiop:delete-directory-tree (pathname dir) :validate t :if-does-not-exist :ignore))))

(define-test extract-refuses-absolute
  (let ((r (handler-case
               (progn
                 (clun.archive:write-tar (list (cons "/etc/passwd" "x")))
                 :ok)
             (clun.tarball:tarball-error () :refused))))
    (is eq :refused r)))

(define-test zip-store-and-deflate-roundtrip
  (let* ((entries (list (cons "z.txt" "zipped")))
         (store (clun.archive:build-zip entries :method 0))
         (defl (clun.archive:build-zip entries :method 8))
         (a (clun.archive:read-zip-entries store))
         (b (clun.archive:read-zip-entries defl)))
    (is string= "z.txt" (first (first a)))
    (is string= "zipped"
        (sb-ext:octets-to-string (second (first a)) :external-format :utf-8))
    (is string= "zipped"
        (sb-ext:octets-to-string (second (first b)) :external-format :utf-8))))
