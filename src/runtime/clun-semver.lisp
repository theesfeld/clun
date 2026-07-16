;;;; clun-semver.lisp — the public Clun.semver bridge over the Phase-21 engine.

(in-package :clun.runtime)

(defun %semver-ascii-p (string)
  (loop for character across string
        always (< (char-code character) 128)))

(defun %semver-require-two (args)
  (when (< (length args) 2)
    (eng:throw-native-error :error "Expected two arguments")))

(defun %semver-order-version (text)
  (handler-case
      (clun.install:parse-version text :allow-equals-prefix t)
    (clun.install:invalid-version ()
      (eng:throw-native-error :error (format nil "Invalid SemVer: ~a~%" text)))))

(defun %semver-satisfies (version range)
  (handler-case
      (clun.install:version-satisfies
       (clun.install:parse-version version :allow-equals-prefix t)
       range)
    (clun.install:invalid-version () nil)))

(defun make-clun-semver ()
  (let ((object (eng:new-object)))
    (eng:data-prop
     object "satisfies"
     (eng:make-native-function
      "satisfies" 2
      (lambda (this args)
        (declare (ignore this))
        (%semver-require-two args)
        (let* ((version (eng:to-string (first args)))
               (range (eng:to-string (second args))))
          (eng:js-boolean
           (and (%semver-ascii-p version)
                (%semver-ascii-p range)
                (%semver-satisfies version range)))))))
    (eng:data-prop
     object "order"
     (eng:make-native-function
      "order" 2
      (lambda (this args)
        (declare (ignore this))
        (%semver-require-two args)
        (let* ((left-text (eng:to-string (first args)))
               (right-text (eng:to-string (second args))))
          (if (or (not (%semver-ascii-p left-text))
                  (not (%semver-ascii-p right-text)))
              0d0
              (let* ((left (%semver-order-version left-text))
                     (right (%semver-order-version right-text)))
                (coerce (clun.install:version-compare left right)
                        'double-float)))))))
    object))
