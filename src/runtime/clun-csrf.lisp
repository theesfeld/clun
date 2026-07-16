;;;; clun-csrf.lisp -- Clun.CSRF JavaScript boundary over the engine-free core.

(in-package :clun.runtime)

(defconstant +csrf-max-string-units+ 1048576)
(defconstant +csrf-max-string-bytes+ 1048576)
(defconstant +csrf-max-safe-integer+ 9007199254740991d0)
(defconstant +csrf-u64-max+ #xffffffffffffffff)
(defconstant +csrf-default-age+ 86400000)

(defun %csrf-throw (kind message code)
  (let ((error (eng:make-error-object
                (ecase kind
                  (:type-error :type-error-prototype)
                  (:range-error :range-error-prototype))
                (ecase kind
                  (:type-error "TypeError")
                  (:range-error "RangeError"))
                message)))
    (eng:js-set error "code" code nil)
    (eng:throw-js-value error)))

(defun %csrf-type-error (message)
  (%csrf-throw :type-error message "ERR_INVALID_ARG_TYPE"))

(defun %csrf-range-error (message)
  (%csrf-throw :range-error message "ERR_OUT_OF_RANGE"))

(defun %csrf-received (value)
  ;; Error rendering must not inspect properties or invoke user code.
  (if (eng:js-object-p value)
      (format nil "an instance of ~a"
              (case (eng:js-object-class value)
                (:object "Object")
                (:array "Array")
                (:function "Function")
                (:arguments "Arguments")
                (:promise "Promise")
                (:generator "Generator")
                (:async-generator "AsyncGenerator")
                (:array-buffer "ArrayBuffer")
                (:data-view "DataView")
                (:typed-array "TypedArray")
                (:regexp "RegExp")
                (:map "Map")
                (:set "Set")
                (:weakmap "WeakMap")
                (:weakset "WeakSet")
                (:date "Date")
                (:error "Error")
                (otherwise "Object")))
      (eng:inspect-value value)))

(defun %csrf-property-type-error (name value)
  (%csrf-type-error
   (format nil "The \"~a\" property must be of type string, got ~a"
           name (eng:js-typeof value))))

(defun %csrf-argument-type-error (name expected value)
  (%csrf-type-error
   (format nil "The \"~a\" argument must be of type ~a. Received ~a"
           name expected (%csrf-received value))))

(defun %csrf-string-octets (value name)
  (when (> (length value) +csrf-max-string-units+)
    (%csrf-range-error
     (format nil "~a exceeds the 1048576 code-unit or byte limit" name)))
  (let ((octets (eng:code-units->utf8-replacing value)))
    (when (> (length octets) +csrf-max-string-bytes+)
      (%csrf-range-error
       (format nil "~a exceeds the 1048576 code-unit or byte limit" name)))
    octets))

(defun %csrf-required-generate-secret (args)
  (if (null args)
      nil
      (let ((value (first args)))
        (when (eng:js-nullish-p value)
          (%csrf-type-error "Secret is required"))
        (unless (and (eng:js-string-p value) (plusp (length value)))
          (%csrf-type-error "Secret must be a non-empty string"))
        (%csrf-string-octets value "secret"))))

(defun %csrf-required-token (args)
  (when (null args)
    (%csrf-type-error "Missing required token parameter"))
  (let ((value (first args)))
    (when (eng:js-nullish-p value)
      (%csrf-type-error "Token is required"))
    (unless (and (eng:js-string-p value) (plusp (length value)))
      (%csrf-type-error "Token must be a non-empty string"))
    value))

(defun %csrf-numeric-option (options name default)
  (let ((value (eng:js-get options name)))
    (when (eng:js-undefined-p value)
      (return-from %csrf-numeric-option default))
    (unless (eng:js-number-p value)
      (%csrf-argument-type-error name "number" value))
    (when (or (eng:js-nan-p value)
              (eng:js-infinite-p value)
              (< value 0d0)
              (> value +csrf-max-safe-integer+)
              (/= value (truncate value)))
      (%csrf-type-error
       (format nil "~a must be an integer between 0 and 9007199254740991" name)))
    (truncate value)))

(defun %csrf-optional-string (options name)
  (let ((value (eng:js-get options name)))
    (when (eng:js-nullish-p value)
      (return-from %csrf-optional-string nil))
    (unless (eng:js-string-p value)
      (%csrf-property-type-error name value))
    (when (zerop (length value))
      (%csrf-type-error
       (if (string= name "secret")
           "Secret must be a non-empty string"
           "sessionId must be a non-empty string")))
    (%csrf-string-octets value name)))

(defun %csrf-encoding-option (options)
  (let ((value (eng:js-get options "encoding")))
    (when (eng:js-undefined-p value)
      (return-from %csrf-encoding-option :base64url))
    (let ((name (eng:to-string value)))
      (cond
        ((zerop (length name)) :base64url)
        ((string-equal name "base64") :base64)
        ((string-equal name "base64url") :base64url)
        ((string-equal name "hex") :hex)
        (t (%csrf-type-error
            "Invalid format: must be 'base64', 'base64url', or 'hex'"))))))

(defun %csrf-algorithm-option (options)
  (let ((value (eng:js-get options "algorithm")))
    (when (eng:js-undefined-p value)
      (return-from %csrf-algorithm-option :sha256))
    (unless (eng:js-string-p value)
      (%csrf-argument-type-error "algorithm" "string" value))
    (cond
      ((or (string-equal value "sha256") (string-equal value "sha-256")) :sha256)
      ((or (string-equal value "sha384") (string-equal value "sha-384")) :sha384)
      ((or (string-equal value "sha512") (string-equal value "sha-512")) :sha512)
      ((member value '("sha512-256" "sha-512/256" "sha-512_256" "sha-512256")
               :test #'string-equal)
       :sha512/256)
      ((string-equal value "blake2b256") :blake2b256)
      ((string-equal value "blake2b512") :blake2b512)
      (t (%csrf-type-error "Algorithm not supported")))))

(defun %csrf-generate-options (value)
  (if (not (eng:js-object-p value))
      (values +csrf-default-age+ nil :base64url :sha256)
      ;; Keep these separate bindings: the left-to-right LET* is the observable getter order.
      (let* ((expires-in (%csrf-numeric-option value "expiresIn" +csrf-default-age+))
             (session-id (%csrf-optional-string value "sessionId"))
             (encoding (%csrf-encoding-option value))
             (algorithm (%csrf-algorithm-option value)))
        (values expires-in session-id encoding algorithm))))

(defun %csrf-verify-options (value)
  (if (not (eng:js-object-p value))
      (values nil nil +csrf-default-age+ :base64url :sha256)
      (let* ((secret (%csrf-optional-string value "secret"))
             (session-id (%csrf-optional-string value "sessionId"))
             (max-age (%csrf-numeric-option value "maxAge" +csrf-default-age+))
             (encoding (%csrf-encoding-option value))
             (algorithm (%csrf-algorithm-option value)))
        (values secret session-id max-age encoding algorithm))))

(defun %csrf-now ()
  (let ((now (sys:unix-milliseconds)))
    (unless (and (integerp now) (<= 0 now +csrf-u64-max+))
      (%csrf-range-error "timestamp is outside the unsigned 64-bit range"))
    now))

(defun make-clun-csrf (global)
  (declare (ignore global))
  (let ((default-secret nil)
        (object (eng:new-object)))
    (labels ((runtime-secret ()
               (or default-secret
                   (setf default-secret (sys:os-random-bytes 16))))
             (generate (this args)
               (declare (ignore this))
               (let ((explicit-secret (%csrf-required-generate-secret args)))
                 (multiple-value-bind (expires-in session-id encoding algorithm)
                     (%csrf-generate-options (eng:arg args 1))
                   (let ((secret (or explicit-secret (runtime-secret)))
                         (now (%csrf-now))
                         (nonce (sys:os-random-bytes 16)))
                     (clun.csrf:core-generate
                      secret :session-id session-id :expires-in expires-in
                      :encoding encoding :algorithm algorithm :timestamp-ms now :nonce nonce)))))
             (verify (this args)
               (declare (ignore this))
               (let ((token (%csrf-required-token args)))
                 (multiple-value-bind (explicit-secret session-id max-age encoding algorithm)
                     (%csrf-verify-options (eng:arg args 1))
                   (eng:js-boolean
                    (clun.csrf:core-verify
                     token (or explicit-secret (runtime-secret))
                     :session-id session-id :max-age max-age :encoding encoding
                     :algorithm algorithm :now-ms (%csrf-now)))))))
      ;; Bun's methods are enumerable data properties; INSTALL-METHOD is intentionally unsuitable.
      (eng:data-prop object "generate" (eng:make-native-function "generate" 1 #'generate))
      (eng:data-prop object "verify" (eng:make-native-function "verify" 1 #'verify))
      object)))
