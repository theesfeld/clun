;;;; coverage.lisp -- source-aligned execution probes shared by the test runner.
;;;; Probes are registered while the original JS/TS AST is compiled and captured by
;;;; the emitted closures, so runtime hits do not depend on dynamic loader state.

(in-package :clun.engine)

(declaim (special *current-source-text*))

(defstruct (coverage-session (:constructor make-coverage-session ()))
  (files (make-hash-table :test #'equal))
  (lock (sb-thread:make-mutex :name "clun-coverage-session"))
  (next-id 0))

(defstruct (coverage-file (:constructor %make-coverage-file (path source)))
  path source
  (points (make-hash-table :test #'equal)))

(defstruct (coverage-point
             (:constructor %make-coverage-point
                 (session id kind start end line name)))
  session id kind start end line name
  (hits 0))

(defvar *coverage-session* nil)
(defvar *coverage-source-path* nil)

(defun call-with-coverage-session (session thunk)
  "Call THUNK while module compilation registers probes in SESSION."
  (let ((*coverage-session* session))
    (funcall thunk)))

(defun %coverage-line-at-offset (source offset)
  (1+ (count #\Newline source :end (min (max 0 offset) (length source)))))

(defun %coverage-file-for-source (session path source)
  (or (gethash path (coverage-session-files session))
      (setf (gethash path (coverage-session-files session))
            (%make-coverage-file path source))))

(defun coverage-register-point (kind start end &optional name)
  "Register a source probe for the active module compilation, or return NIL."
  (let ((session (or (and *realm* (realm-coverage-session *realm*))
                     *coverage-session*))
        (path *coverage-source-path*)
        (source *current-source-text*))
    (when (and session path source start end
               (<= 0 start end (length source)))
      (sb-thread:with-mutex ((coverage-session-lock session))
        (let* ((file (%coverage-file-for-source session path source))
               (key (list kind start end name))
               (existing (gethash key (coverage-file-points file))))
          (or existing
              (let* ((id (incf (coverage-session-next-id session)))
                     (point
                       (%make-coverage-point
                        session id kind start end
                        (%coverage-line-at-offset source start)
                        (or name ""))))
                (setf (gethash key (coverage-file-points file)) point)
                point)))))))

(defun coverage-hit (point)
  (when point
    (let ((session (coverage-point-session point)))
      (sb-thread:with-mutex ((coverage-session-lock session))
        (incf (coverage-point-hits point)))))
  nil)

(defun %coverage-point-plist (point)
  (list :id (coverage-point-id point)
        :kind (coverage-point-kind point)
        :start (coverage-point-start point)
        :end (coverage-point-end point)
        :line (coverage-point-line point)
        :name (coverage-point-name point)
        :hits (coverage-point-hits point)))

(defun coverage-results (session)
  "Return immutable path-sorted coverage records for SESSION."
  (sb-thread:with-mutex ((coverage-session-lock session))
    (sort
     (loop for file being the hash-values of (coverage-session-files session)
           collect
           (list :path (coverage-file-path file)
                 :source (coverage-file-source file)
                 :points
                 (sort
                  (loop for point being the hash-values of (coverage-file-points file)
                        collect (%coverage-point-plist point))
                  (lambda (left right)
                    (or (< (getf left :start) (getf right :start))
                        (and (= (getf left :start) (getf right :start))
                             (< (getf left :id) (getf right :id))))))))
     #'string< :key (lambda (record) (getf record :path)))))
