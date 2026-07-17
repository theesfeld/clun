;;;; walker-tests.lisp -- Phase 30 incremental scanner and resource bounds.

(in-package :clun-test)

(defun glob-test-stat (kind inode)
  (clun.sys::make-fstat
   :dev 1 :ino inode
   :mode (ecase kind (:directory #o040755) (:file #o100644) (:symlink #o120777))
   :nlink 1 :uid 0 :gid 0 :rdev 0 :size 0
   :atime-ns 0 :mtime-ns 0 :ctime-ns 0))

(define-test glob-walker/classifies-only-live-transitions
  (let ((mapped 0) (classified 0)
        (directory (glob-test-stat :directory 1))
        (file (glob-test-stat :file 2)))
    (let* ((accessor
             (glob:make-glob-accessor
              :map-directory
              (lambda (path callback)
                (is equal "/virtual" path)
                (dolist (name '("miss-a" "hit" "miss-b"))
                  (incf mapped)
                  (funcall callback name)))
              :stat (lambda (path)
                      (if (string= path "/virtual") directory file))
              :lstat (lambda (path)
                       (incf classified)
                       (is equal "/virtual/hit" path)
                       file)))
           (options (glob:make-glob-scan-options :cwd "/virtual"))
           (results (glob:scan-glob "hit" options nil accessor)))
      (is equalp #("hit") results)
      (is = 3 mapped)
      (is = 1 classified))))

(define-test glob-walker/cancellation-stops-before-next-entry
  (let ((token (glob:make-glob-scan-token))
        (visits 0)
        (classified 0)
        (directory (glob-test-stat :directory 1)))
    (let ((accessor
            (glob:make-glob-accessor
             :map-directory
             (lambda (path callback)
               (declare (ignore path))
               (loop for index from 1 to 1000 do
                 (incf visits)
                 (when (= index 128) (glob:cancel-glob-scan token))
                 (funcall callback "entry")))
             :stat (lambda (path) (declare (ignore path)) directory)
             :lstat (lambda (path)
                      (declare (ignore path))
                      (incf classified)
                      (error "cancelled scan classified an entry")))))
      (true
       (handler-case
           (progn
             (glob:scan-glob "absent" (glob:make-glob-scan-options :cwd "/virtual")
                             token accessor)
             nil)
         (glob:glob-scan-cancelled () t)))
      (is = 128 visits)
      (is = 0 classified))))

(define-test glob-walker/million-entry-zero-match-is-bounded
  (let ((visits 0)
        (directory (glob-test-stat :directory 1)))
    (let ((accessor
            (glob:make-glob-accessor
             :map-directory
             (lambda (path callback)
               (declare (ignore path))
               (dotimes (index 1000000)
                 (declare (ignore index))
                 (incf visits)
                 (funcall callback "entry")))
             :stat (lambda (path) (declare (ignore path)) directory)
             :lstat (lambda (path)
                      (declare (ignore path))
                      (error "zero-match walk classified an entry")))))
      (sb-ext:gc :full t)
      (let ((baseline (sys:heap-bytes-used)))
        (is equalp #()
            (glob:scan-glob "absent" (glob:make-glob-scan-options :cwd "/virtual")
                            nil accessor))
        (sb-ext:gc :full t)
        (true (< (max 0 (- (sys:heap-bytes-used) baseline)) (* 64 1024 1024))))
      (is = 1000000 visits))))
