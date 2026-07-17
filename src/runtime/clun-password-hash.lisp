;;;; clun-password-hash.lisp -- Clun.password and callable Clun.hash boundary.

(in-package :clun.runtime)

(defconstant +hash-u64-mask+ #xffffffffffffffff)

(defun %password-wipe (value)
  (when (typep value '(array (unsigned-byte 8) (*)))
    (fill value 0))
  nil)

(defun %buffer-source-p (value)
  (or (eng:js-array-buffer-p value)
      (eng:js-typed-array-p value)
      (and (eng:js-object-p value)
           (eq (eng:js-object-class value) :data-view))))

(defun %password-octets (value name)
  (cond
    ((eng:js-string-p value)
     (eng:code-units->utf8-replacing value))
    ((%buffer-source-p value)
     (copy-seq (eng:buffer-source-octets value)))
    (t
     (eng:throw-type-error
      (format nil "The ~A argument must be a string or TypedArray" name)))))

(defun %password-algorithm (value verb)
  (unless (eng:js-string-p value)
    (eng:throw-type-error
     (format nil "The ~A algorithm must be a string" verb)))
  (cond
    ((string= value "argon2id") :argon2id)
    ((string= value "argon2i") :argon2i)
    ((string= value "argon2d") :argon2d)
    ((string= value "bcrypt") :bcrypt)
    (t
     (eng:throw-type-error
      "unknown algorithm, expected one of: \"bcrypt\", \"argon2id\", \"argon2d\", \"argon2i\" (default is \"argon2id\")"))))

(defun %truthy-property (object name)
  (let ((value (eng:js-get object name)))
    (if (eng:js-truthy value) value eng:+undefined+)))

(defun %password-i32-option (object name default)
  (let ((value (%truthy-property object name)))
    (if (eng:js-undefined-p value)
        default
        (progn
          (unless (eng:js-number-p value)
            (eng:throw-type-error (format nil "The ~A option must be a number" name)))
          (eng:to-int32 value)))))

(defun %password-hash-options (value)
  (when (eng:js-nullish-p value)
    (return-from %password-hash-options
      (list :algorithm :argon2id
            :memory-cost clun.password:+default-argon-memory-cost+
            :time-cost clun.password:+default-argon-time-cost+)))
  (when (eng:js-string-p value)
    (return-from %password-hash-options
      (list :algorithm (%password-algorithm value "hash"))))
  (unless (eng:js-object-p value)
    (eng:throw-type-error "The hash algorithm must be a string or options object"))
  (let ((algorithm-value (%truthy-property value "algorithm")))
    (when (eng:js-undefined-p algorithm-value)
      (eng:throw-type-error "The options.algorithm property must be a string"))
    (let ((algorithm (%password-algorithm algorithm-value "hash")))
      (if (eq algorithm :bcrypt)
          (let ((cost (%password-i32-option value "cost" 10)))
            (unless (<= 4 cost 31)
              (eng:throw-range-error "Rounds must be between 4 and 31"))
            (list :algorithm algorithm :cost cost))
          (let* ((time-cost (%password-i32-option value "timeCost" 2))
                 (memory-cost (%password-i32-option value "memoryCost" 65536)))
            (when (< time-cost 1)
              (eng:throw-range-error "Time cost must be greater than 0"))
            (when (< memory-cost 8)
              (eng:throw-range-error "Memory cost must be at least 8"))
            (list :algorithm algorithm :memory-cost memory-cost
                  :time-cost time-cost))))))

(defun %password-verify-algorithm (value)
  (if (or (eng:js-nullish-p value)
          (and (eng:js-string-p value) (zerop (length value))))
      nil
      (%password-algorithm value "verify")))

(defun %password-error-name (condition)
  (if (typep condition 'clun.password:password-error)
      (case (clun.password:password-error-kind condition)
        (:invalid-encoding "InvalidEncoding")
        (:weak-parameters "WeakParameters")
        (:unsupported-algorithm "UnsupportedAlgorithm")
        (:invalid-argument "InvalidArguments")
        (:input-too-long "NoSpaceLeft")
        (otherwise "Unexpected"))
      "Unexpected"))

(defun %password-error-code (condition)
  (if (typep condition 'clun.password:password-error)
      (case (clun.password:password-error-kind condition)
        (:invalid-encoding "PASSWORD_INVALID_ENCODING")
        (:weak-parameters "PASSWORD_WEAK_PARAMETERS")
        (:unsupported-algorithm "PASSWORD_UNSUPPORTED_ALGORITHM")
        (:invalid-argument "PASSWORD_INVALID_ARGUMENTS")
        (:input-too-long "PASSWORD_NO_SPACE_LEFT")
        (otherwise "PASSWORD_UNEXPECTED"))
      "PASSWORD_UNEXPECTED"))

(defun %password-error-object (condition verb)
  (let* ((name (%password-error-name condition))
         (error (eng:make-error-object
                 :error-prototype "Error"
                 (format nil "Password ~A failed with error \"~A\"" verb name))))
    (eng:js-set error "code" (%password-error-code condition) nil)
    error))

(defun %password-sync (thunk verb converter)
  (handler-case (funcall converter (funcall thunk))
    (clun.password:password-error (condition)
      (eng:throw-js-value (%password-error-object condition verb)))
    (error (condition)
      (eng:throw-js-value (%password-error-object condition verb)))))

(defun %password-async (global thunk verb converter cleanup)
  (let ((promise-constructor (eng:js-get global "Promise")))
    (eng:js-construct
     promise-constructor
     (list
      (eng:make-native-function
       "" 2
       (lambda (this args)
         (declare (ignore this))
         (let ((resolve (eng:arg args 0))
               (reject (eng:arg args 1)))
           (handler-case
               (lp:worker-submit
                (eng:current-loop)
                (lambda ()
                  (unwind-protect (funcall thunk)
                    (funcall cleanup)))
                (lambda (result)
                  (if (eq (first result) :ok)
                      (eng:js-call resolve eng:+undefined+
                                   (list (funcall converter (second result))))
                      (eng:js-call reject eng:+undefined+
                                   (list (%password-error-object
                                          (second result) verb))))))
             (error (condition)
               (funcall cleanup)
               (eng:js-call reject eng:+undefined+
                            (list (%password-error-object condition verb)))))
           eng:+undefined+)))))))

(defun %password-resolved-promise (global value)
  (eng:js-construct
   (eng:js-get global "Promise")
   (list
    (eng:make-native-function
     "" 2
     (lambda (this args)
       (declare (ignore this))
       (eng:js-call (eng:arg args 0) eng:+undefined+ (list value))
       eng:+undefined+)))))

(defun %password-hash-call (global args synchronous-p)
  (when (null args)
    (eng:throw-type-error "hash requires at least 1 argument"))
  ;; Bun validates the algorithm/options before it copies the password input.
  ;; Keeping that order also avoids retaining a secret copy when options fail.
  (let* ((options (%password-hash-options (eng:arg args 1)))
         (password (%password-octets (eng:arg args 0) "password")))
    (when (zerop (length password))
      (%password-wipe password)
      (eng:throw-range-error "password must not be empty"))
    (let ((thunk (lambda ()
                   (apply #'clun.password:hash-password password options))))
      (if synchronous-p
          (unwind-protect
               (%password-sync thunk "hashing" #'identity)
            (%password-wipe password))
          (%password-async global thunk "hashing" #'identity
                           (lambda () (%password-wipe password)))))))

(defun %password-verify-call (global args synchronous-p)
  (when (< (length args) 2)
    (eng:throw-type-error "verify requires at least 2 arguments"))
  (let* ((algorithm (%password-verify-algorithm (eng:arg args 2)))
         (password (%password-octets (eng:arg args 0) "password"))
         (encoded (%password-octets (eng:arg args 1) "hash")))
    (when (or (zerop (length password)) (zerop (length encoded)))
      (%password-wipe password)
      (%password-wipe encoded)
      (return-from %password-verify-call
        (if synchronous-p
            eng:+false+
            (%password-resolved-promise global eng:+false+))))
    (let ((thunk (lambda ()
                   (clun.password:verify-password password encoded algorithm)))
          (converter #'eng:js-boolean)
          (cleanup (lambda ()
                     (%password-wipe password)
                     (%password-wipe encoded))))
      (if synchronous-p
          (unwind-protect
               (%password-sync thunk "verification" converter)
            (funcall cleanup))
          (%password-async global thunk "verification" converter cleanup)))))

(defun make-clun-password (global)
  (let ((object (eng:new-object)))
    (eng:data-prop object "hash"
                   (eng:make-native-function
                    "hash" 2
                    (lambda (this args)
                      (declare (ignore this))
                      (%password-hash-call global args nil))))
    (eng:data-prop object "hashSync"
                   (eng:make-native-function
                    "hashSync" 2
                    (lambda (this args)
                      (declare (ignore this))
                      (%password-hash-call global args t))))
    (eng:data-prop object "verify"
                   (eng:make-native-function
                    "verify" 2
                    (lambda (this args)
                      (declare (ignore this))
                      (%password-verify-call global args nil))))
    (eng:data-prop object "verifySync"
                   (eng:make-native-function
                    "verifySync" 2
                    (lambda (this args)
                      (declare (ignore this))
                      (%password-verify-call global args t))))
    object))

(defun %hash-input-octets (args)
  (if (null args)
      (make-array 0 :element-type '(unsigned-byte 8))
      (let ((value (eng:arg args 0)))
        (cond
          ((%buffer-source-p value) (eng:buffer-source-octets value))
          ((eng:js-string-p value) (eng:code-units->utf8-replacing value))
          ((eng:js-undefined-p value)
           (make-array 0 :element-type '(unsigned-byte 8)))
          (t (eng:code-units->utf8-replacing (eng:to-string value)))))))

(defun %hash-seed (value)
  (cond
    ((eng:js-bigint-p value) (logand value +hash-u64-mask+))
    ((eng:js-number-p value)
     (if (or (eng:js-nan-p value) (eng:js-infinite-p value))
         0
         (logand (truncate value) +hash-u64-mask+)))
    (t 0)))

(defun %make-hash-function (name algorithm result-bits)
  (eng:make-native-function
   name 1
   (lambda (this args)
     (declare (ignore this))
     (let ((value (clun.hash:hash-octets
                   algorithm (%hash-input-octets args)
                   (%hash-seed (eng:arg args 1)))))
       (if (= result-bits 32) (coerce value 'double-float) value)))))

(defun make-clun-hash ()
  (let ((function (%make-hash-function "hash" :wyhash 64)))
    (dolist (spec '(("wyhash" :wyhash 64)
                    ("adler32" :adler32 32)
                    ("crc32" :crc32 32)
                    ("cityHash32" :city-hash32 32)
                    ("cityHash64" :city-hash64 64)
                    ("xxHash32" :xxhash32 32)
                    ("xxHash64" :xxhash64 64)
                    ("xxHash3" :xxhash3 64)
                    ("murmur32v2" :murmur32v2 32)
                    ("murmur32v3" :murmur32v3 32)
                    ("murmur64v2" :murmur64v2 64)
                    ("rapidhash" :rapidhash 64)))
      (eng:data-prop function (first spec)
                     (%make-hash-function (first spec) (second spec) (third spec))))
    function))
