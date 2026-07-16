;;;; web-cookies.lisp -- Clun.Cookie / Clun.CookieMap JavaScript bridge.

(in-package :clun.runtime)

(defstruct (js-cookie
            (:include eng:js-object (class :cookie))
            (:constructor %make-js-cookie))
  record
  date-cache)

(defstruct (js-cookie-map
            (:include eng:js-object (class :cookie-map))
            (:constructor %make-js-cookie-map))
  state)

(defstruct (js-cookie-map-iterator
            (:include eng:js-object (class :cookie-map-iterator))
            (:constructor %make-js-cookie-map-iterator))
  map
  (kind :entries)
  (cursor 0 :type (integer 0 *))
  (done-p nil))

(defstruct (web-cookie-realm-state
            (:constructor %make-web-cookie-realm-state))
  cookie-constructor
  cookie-prototype
  cookie-map-constructor
  cookie-map-prototype
  iterator-prototype)

(defvar *web-cookie-realm-states*
  (make-hash-table :test #'eq :weakness :key))

(defun %cookie-runtime-state (&optional (realm eng:*realm*))
  (or (gethash realm *web-cookie-realm-states*)
      (error "The cookie runtime is not installed in this realm")))

(defmacro %with-cookie-core-errors (&body body)
  `(handler-case (progn ,@body)
     (clun.cookies:cookie-error (condition)
       (eng:throw-type-error
        (clun.cookies:cookie-error-message condition)))))

(defun %validate-cookie-name-runtime (name)
  (%with-cookie-core-errors (clun.cookies:validate-cookie-name name)))

(defun %validate-cookie-domain-runtime (domain)
  (%with-cookie-core-errors (clun.cookies:validate-cookie-domain domain)))

(defun %validate-cookie-path-runtime (path)
  (%with-cookie-core-errors (clun.cookies:validate-cookie-path path)))

(defun %cookie-illegal-this (class member)
  (%error-with-code
   :type-error
   (format nil "Can only call ~a.~a on instances of ~a" class member class)
   "ERR_INVALID_THIS"))

(defun %require-cookie (value member)
  (if (js-cookie-p value)
      value
      (%cookie-illegal-this "Cookie" member)))

(defun %require-cookie-map (value member)
  (if (js-cookie-map-p value)
      value
      (%cookie-illegal-this "CookieMap" member)))

(defun %to-usv-string (value)
  (eng:utf8->code-units
   (eng:code-units->utf8-replacing (eng:to-string value))))

(defun %same-site-js-string (same-site)
  (ecase same-site (:strict "strict") (:lax "lax") (:none "none")))

(defun %runtime-normalize-same-site (value &key case-sensitive)
  (%with-cookie-core-errors
    (clun.cookies:normalize-same-site value :case-sensitive case-sensitive)))

(defun %js-number->cookie-number (number)
  (cond ((eql number eng:+js-infinity+) :positive-infinity)
        ((eql number eng:+js-neg-infinity+) :negative-infinity)
        (t number)))

(defun %cookie-number->js-number (number)
  (case number
    (:positive-infinity eng:+js-infinity+)
    (:negative-infinity eng:+js-neg-infinity+)
    (otherwise number)))

(defun %fresh-date (milliseconds)
  (eng:js-construct (eng:intrinsic :date-constructor)
                    (list (coerce milliseconds 'double-float))))

(defun %expires-milliseconds (value)
  (cond
    ((eng:js-nullish-p value) nil)
    ((eng::js-date-p value)
     (let ((milliseconds (eng::js-date-tv value)))
       (unless (eng:js-finite-p milliseconds)
         (eng:throw-range-error "expires must be a valid Date (or Number)"))
       (truncate milliseconds)))
    ((eng:js-number-p value)
     (unless (eng:js-finite-p value)
       (eng:throw-range-error "expires must be a valid Number (or Date)"))
     (let ((milliseconds (* value 1000d0)))
       (unless (and (eng:js-finite-p milliseconds)
                    (<= -8640000000000000d0 milliseconds
                        8640000000000000d0))
         (eng:throw-range-error "expires must be a valid Number (or Date)"))
       (truncate milliseconds)))
    ((eng:js-string-p value)
     (multiple-value-bind (milliseconds valid-p)
         (clun.cookies:parse-http-date (%to-usv-string value))
       (unless valid-p
         (eng:throw-type-error "Invalid cookie expiration date"))
       milliseconds))
    (t
     (%error-with-code :type-error
                       (format nil
                               "The argument 'expires' Invalid expires value. Must be a Date or a number. Received ~a"
                               (eng:inspect-value value))
                       "ERR_INVALID_ARG_VALUE"))))

(defun %cookie-options-values (options &key ignore-invalid-options)
  "Return the converted option values in the contract's observable lookup order."
  (cond
    ((or (eng:js-nullish-p options) (null options))
     (values nil nil "/" nil nil nil nil nil :lax))
    ((not (eng:js-object-p options))
     (if ignore-invalid-options
         (values nil nil "/" nil nil nil nil nil :lax)
         (eng:throw-type-error "Options must be an object")))
    (t
     (let* ((domain-value (eng:js-get options "domain"))
            (domain-present-p (not (eng:js-nullish-p domain-value)))
            (domain
              (and domain-present-p
                   (%validate-cookie-domain-runtime
                    (%to-usv-string domain-value))))
            (path-value (eng:js-get options "path"))
            (path (if (eng:js-nullish-p path-value)
                      "/"
                      (%validate-cookie-path-runtime
                       (%to-usv-string path-value))))
            (expires-value (eng:js-get options "expires"))
            (expires (and (not (eng:js-nullish-p expires-value))
                          (%expires-milliseconds expires-value)))
            (max-age-value (eng:js-get options "maxAge"))
            (max-age
              (and (eng:js-number-p max-age-value)
                   (not (eng:js-nan-p max-age-value))
                   (%js-number->cookie-number max-age-value)))
            (secure (eng:js-truthy (eng:js-get options "secure")))
            (http-only (eng:js-truthy (eng:js-get options "httpOnly")))
            (partitioned (eng:js-truthy (eng:js-get options "partitioned")))
            (same-site-value (eng:js-get options "sameSite"))
            (same-site
              (if (eng:js-nullish-p same-site-value)
                  :lax
                  (%runtime-normalize-same-site
                   (%to-usv-string same-site-value) :case-sensitive t))))
       (values domain-present-p domain path expires max-age
               secure http-only partitioned same-site)))))

(defun %make-cookie-record-positional (name-value value-value options
                                       &key ignore-invalid-options)
  ;; Positional conversion happens before any option getter.
  (let ((name (%to-usv-string name-value))
        (value (%to-usv-string value-value)))
    (%validate-cookie-name-runtime name)
    (multiple-value-bind
          (domain-present-p domain path expires max-age
           secure http-only partitioned same-site)
        (%cookie-options-values options
                                :ignore-invalid-options ignore-invalid-options)
      (%with-cookie-core-errors
        (apply #'clun.cookies:make-cookie name value
               (append
                (when domain-present-p (list :domain domain))
                (list :path path)
                (when expires (list :expires-ms expires))
                (when max-age
                  (list :max-age max-age
                        :max-age-text
                        (eng:number->js-string
                         (%cookie-number->js-number max-age))))
                (list :secure secure :http-only http-only
                      :partitioned partitioned :same-site same-site)))))))

(defun %make-cookie-record-init (init)
  (let* ((name-value (eng:js-get init "name"))
         (name (if (eng:js-undefined-p name-value)
                   "" (%to-usv-string name-value))))
    (when (zerop (length name))
      (eng:throw-type-error "name is required"))
    (%validate-cookie-name-runtime name)
    ;; Each member is read once and converted before the next lookup.
    (let* ((value (if (eng:has-property init "value")
                      (%to-usv-string (eng:js-get init "value"))
                      ""))
           (domain-value (eng:js-get init "domain"))
           (domain-present-p (not (eng:js-nullish-p domain-value)))
           (domain
             (and domain-present-p
                  (%validate-cookie-domain-runtime
                   (%to-usv-string domain-value))))
           (path-value (eng:js-get init "path"))
           (path (if (eng:js-nullish-p path-value)
                     "/"
                     (%validate-cookie-path-runtime
                      (%to-usv-string path-value))))
           (expires-value (eng:js-get init "expires"))
           (expires (and (not (eng:js-nullish-p expires-value))
                         (%expires-milliseconds expires-value)))
           (max-age-value (eng:js-get init "maxAge"))
           (max-age
             (and (eng:js-number-p max-age-value)
                  (not (eng:js-nan-p max-age-value))
                  (%js-number->cookie-number max-age-value)))
           (secure (eng:js-truthy (eng:js-get init "secure")))
           (http-only (eng:js-truthy (eng:js-get init "httpOnly")))
           (partitioned (eng:js-truthy (eng:js-get init "partitioned")))
           (same-site-value (eng:js-get init "sameSite"))
           (same-site
             (if (eng:js-nullish-p same-site-value)
                 :lax
                 (%runtime-normalize-same-site
                  (%to-usv-string same-site-value) :case-sensitive t))))
      (%with-cookie-core-errors
        (apply #'clun.cookies:make-cookie name value
               (append
                (when domain-present-p (list :domain domain))
                (list :path path)
                (when expires (list :expires-ms expires))
                (when max-age
                  (list :max-age max-age
                        :max-age-text
                        (eng:number->js-string
                         (%cookie-number->js-number max-age))))
                (list :secure secure :http-only http-only
                      :partitioned partitioned :same-site same-site)))))))

(defun %allocate-cookie (record)
  (%make-js-cookie
   :proto (web-cookie-realm-state-cookie-prototype
           (%cookie-runtime-state))
   :record record))

(defun %cookie-record-from-constructor-args (args)
  (when (null args)
    (%error-with-code :type-error "Not enough arguments" "ERR_MISSING_ARGS"))
  (let ((first (first args)))
    (cond
      ((and (= (length args) 1) (eng:js-string-p first))
       (when (zerop (length first))
         (eng:throw-type-error "Invalid cookie string: empty"))
       (%with-cookie-core-errors
         (clun.cookies:parse-set-cookie first)))
      ((and (= (length args) 1) (eng:js-object-p first))
       (%make-cookie-record-init first))
      ((= (length args) 1)
       (%error-with-code :type-error "Not enough arguments" "ERR_MISSING_ARGS"))
      (t
       (%make-cookie-record-positional
        first (eng:arg args 1) (eng:arg args 2))))))

(defun %cookie-get-expires (object)
  (let* ((cookie (js-cookie-record object))
         (milliseconds (clun.cookies:cookie-expires-ms cookie)))
    (if (not (clun.cookies:cookie-expires-present-p cookie))
        eng:+undefined+
        (let ((cache (js-cookie-date-cache object)))
          (if (and (eng::js-date-p cache)
                   (eng:js-finite-p (eng::js-date-tv cache))
                   (= (eng::js-date-tv cache) milliseconds))
              cache
              (setf (js-cookie-date-cache object)
                    (%fresh-date milliseconds)))))))

(defun %cookie-set-expires (object value)
  (let ((milliseconds (%expires-milliseconds value)))
    (%with-cookie-core-errors
      (if milliseconds
          (clun.cookies:update-cookie-expires
           (js-cookie-record object) milliseconds)
          (clun.cookies:clear-cookie-expires (js-cookie-record object))))
    (setf (js-cookie-date-cache object) nil)
    eng:+undefined+))

(defun %cookie-get-max-age (cookie)
  (if (clun.cookies:cookie-max-age-present-p cookie)
      (%cookie-number->js-number (clun.cookies:cookie-max-age cookie))
      eng:+undefined+))

(defun %cookie-set-max-age (cookie value)
  (if (eng:js-nullish-p value)
      (clun.cookies:clear-cookie-max-age cookie)
      (let ((number (eng:to-number value)))
        (unless (eng:js-finite-p number)
          (eng:throw-type-error "The provided value is non-finite"))
        (clun.cookies:update-cookie-max-age
         cookie number (eng:number->js-string number))))
  eng:+undefined+)

(defun %cookie-json (object)
  (let* ((cookie (js-cookie-record object))
         (json (eng:new-object eng:+null+)))
    (eng:create-data-property json "name" (clun.cookies:cookie-name cookie))
    (eng:create-data-property json "value" (clun.cookies:cookie-value cookie))
    (when (and (clun.cookies:cookie-domain-present-p cookie)
               (plusp (length (clun.cookies:cookie-domain cookie))))
      (eng:create-data-property json "domain"
                                (clun.cookies:cookie-domain cookie)))
    (eng:create-data-property json "path" (clun.cookies:cookie-path cookie))
    (when (clun.cookies:cookie-expires-present-p cookie)
      (eng:create-data-property
       json "expires" (%fresh-date (clun.cookies:cookie-expires-ms cookie))))
    (when (clun.cookies:cookie-max-age-present-p cookie)
      (eng:create-data-property json "maxAge" (%cookie-get-max-age cookie)))
    (eng:create-data-property json "secure"
                              (eng:js-boolean
                               (clun.cookies:cookie-secure-p cookie)))
    (eng:create-data-property json "sameSite"
                              (%same-site-js-string
                               (clun.cookies:cookie-same-site cookie)))
    (eng:create-data-property json "httpOnly"
                              (eng:js-boolean
                               (clun.cookies:cookie-http-only-p cookie)))
    (eng:create-data-property json "partitioned"
                              (eng:js-boolean
                               (clun.cookies:cookie-partitioned-p cookie)))
    json))

(defun %install-cookie-prototype (prototype)
  (flet ((getter (member function)
           (lambda (this args)
             (declare (ignore args))
             (let ((object (%require-cookie this member)))
               (funcall function object))))
         (setter (member function)
           (lambda (this args)
             (let ((object (%require-cookie this member)))
               (funcall function object (eng:arg args 0))))))
    (%define-accessor prototype "name"
                      (getter "name"
                              (lambda (object)
                                (clun.cookies:cookie-name
                                 (js-cookie-record object))))
                      nil :enumerable t :configurable t)
    (%define-accessor prototype "value"
                      (getter "value"
                              (lambda (object)
                                (clun.cookies:cookie-value
                                 (js-cookie-record object))))
                      (setter "value"
                              (lambda (object value)
                                (clun.cookies:update-cookie-value
                                 (js-cookie-record object)
                                 (%to-usv-string value))
                                eng:+undefined+))
                      :enumerable t :configurable t)
    (%define-accessor prototype "domain"
                      (getter "domain"
                              (lambda (object)
                                (let ((cookie (js-cookie-record object)))
                                  (if (clun.cookies:cookie-domain-present-p cookie)
                                      (clun.cookies:cookie-domain cookie)
                                      eng:+null+))))
                      (setter "domain"
                              (lambda (object value)
                                (%with-cookie-core-errors
                                  (clun.cookies:update-cookie-domain
                                   (js-cookie-record object)
                                   (%to-usv-string value)))
                                eng:+undefined+))
                      :enumerable t :configurable t)
    (%define-accessor prototype "path"
                      (getter "path"
                              (lambda (object)
                                (clun.cookies:cookie-path
                                 (js-cookie-record object))))
                      (setter "path"
                              (lambda (object value)
                                (%with-cookie-core-errors
                                  (clun.cookies:update-cookie-path
                                   (js-cookie-record object)
                                   (%to-usv-string value)))
                                eng:+undefined+))
                      :enumerable t :configurable t)
    (%define-accessor prototype "expires"
                      (getter "expires" #'%cookie-get-expires)
                      (setter "expires" #'%cookie-set-expires)
                      :enumerable t :configurable t)
    (%define-accessor prototype "maxAge"
                      (getter "maxAge"
                              (lambda (object)
                                (%cookie-get-max-age
                                 (js-cookie-record object))))
                      (setter "maxAge"
                              (lambda (object value)
                                (%cookie-set-max-age
                                 (js-cookie-record object) value)))
                      :enumerable t :configurable t)
    (%define-accessor prototype "secure"
                      (getter "secure"
                              (lambda (object)
                                (eng:js-boolean
                                 (clun.cookies:cookie-secure-p
                                  (js-cookie-record object)))))
                      (setter "secure"
                              (lambda (object value)
                                (clun.cookies:update-cookie-secure
                                 (js-cookie-record object)
                                 (eng:js-truthy value))
                                eng:+undefined+))
                      :enumerable t :configurable t)
    (%define-accessor prototype "httpOnly"
                      (getter "httpOnly"
                              (lambda (object)
                                (eng:js-boolean
                                 (clun.cookies:cookie-http-only-p
                                  (js-cookie-record object)))))
                      (setter "httpOnly"
                              (lambda (object value)
                                (clun.cookies:update-cookie-http-only
                                 (js-cookie-record object)
                                 (eng:js-truthy value))
                                eng:+undefined+))
                      :enumerable t :configurable t)
    (%define-accessor prototype "sameSite"
                      (getter "sameSite"
                              (lambda (object)
                                (%same-site-js-string
                                 (clun.cookies:cookie-same-site
                                  (js-cookie-record object)))))
                      (setter "sameSite"
                              (lambda (object value)
                                (%with-cookie-core-errors
                                  (clun.cookies:update-cookie-same-site
                                   (js-cookie-record object)
                                   (%to-usv-string value)))
                                eng:+undefined+))
                      :enumerable t :configurable t)
    (%define-accessor prototype "partitioned"
                      (getter "partitioned"
                              (lambda (object)
                                (eng:js-boolean
                                 (clun.cookies:cookie-partitioned-p
                                  (js-cookie-record object)))))
                      (setter "partitioned"
                              (lambda (object value)
                                (clun.cookies:update-cookie-partitioned
                                 (js-cookie-record object)
                                 (eng:js-truthy value))
                                eng:+undefined+))
                      :enumerable t :configurable t))
  (%install-prototype-method
   prototype "isExpired" 0
   (lambda (this args) (declare (ignore args))
     (let ((cookie (js-cookie-record (%require-cookie this "isExpired")))
           (now (clun.sys:unix-milliseconds)))
       (eng:js-boolean (clun.cookies:cookie-expired-p cookie now))))
   :enumerable t)
  (%install-prototype-method
   prototype "toString" 0
   (lambda (this args) (declare (ignore args))
     (%with-cookie-core-errors
       (clun.cookies:serialize-cookie
        (js-cookie-record (%require-cookie this "toString")))))
   :enumerable t)
  (%install-prototype-method
   prototype "toJSON" 0
   (lambda (this args) (declare (ignore args))
     (%cookie-json (%require-cookie this "toJSON")))
   :enumerable t)
  (%install-prototype-method
   prototype "serialize" 0
   (lambda (this args) (declare (ignore args))
     (%with-cookie-core-errors
       (clun.cookies:serialize-cookie
        (js-cookie-record (%require-cookie this "serialize")))))
   :enumerable t)
  (%define-data prototype (eng:well-known :to-string-tag) "Cookie"
                :writable nil :enumerable nil :configurable t)
  prototype)

(defun %make-cookie-constructor (prototype)
  (let ((constructor
          (eng:make-native-function
           "Cookie" 2
           (lambda (this args)
             (declare (ignore this args))
             (%error-with-code
              :type-error "Use `new Cookie(...)` instead of `Cookie(...)`"
              "ERR_ILLEGAL_CONSTRUCTOR"))
           :construct
           (lambda (args new-target)
             (declare (ignore new-target))
             (%allocate-cookie (%cookie-record-from-constructor-args args))))))
    (%set-constructor-prototype constructor prototype)
    (%install-prototype-method
     constructor "parse" 1
     (lambda (this args) (declare (ignore this))
       (when (null args)
         (%error-with-code :type-error "Not enough arguments" "ERR_MISSING_ARGS"))
       (%allocate-cookie
        (%with-cookie-core-errors
          (clun.cookies:parse-set-cookie
           (%to-usv-string (eng:arg args 0))))))
     :enumerable t :configurable nil)
    (%install-prototype-method
     constructor "from" 3
     (lambda (this args)
       (declare (ignore this))
       (when (< (length args) 2)
         (%error-with-code :type-error "Not enough arguments" "ERR_MISSING_ARGS"))
       (%allocate-cookie
        (%make-cookie-record-positional
         (eng:arg args 0) (eng:arg args 1) (eng:arg args 2)
         :ignore-invalid-options t)))
     :enumerable t :configurable nil)
    constructor))

;;; --- CookieMap --------------------------------------------------------------

(defun %cookie-map-state-from-init (init)
  (cond
    ((or (null init) (eng:js-nullish-p init))
     (clun.cookies:make-cookie-map-state))
    ((eng:js-string-p init)
     (clun.cookies:make-cookie-map-state-from-header init))
    ;; Bun's CookieMap initializer deliberately does not unwrap or enumerate a
    ;; Proxy. Proxy(array), Proxy(record), and even a revoked Proxy are all
    ;; accepted as empty initializers without invoking any trap.
    ((eng::js-proxy-p init)
     (clun.cookies:make-cookie-map-state))
    ((eng:js-array-p init)
     (let ((state (clun.cookies:make-cookie-map-state)))
       (dotimes (index (eng:array-length init) state)
         (let ((pair (eng:js-getv init (princ-to-string index))))
           (unless (eng:js-array-p pair)
             (eng:throw-type-error
              "Expected each element to be an array of two strings"))
           (unless (= (eng:array-length pair) 2)
             (eng:throw-type-error "Expected arrays of exactly two strings"))
           ;; The first conversion must complete before the second begins.
           (let ((name (eng:to-string (eng:js-getv pair "0")))
                 (value (eng:to-string (eng:js-getv pair "1"))))
             (clun.cookies:cookie-map-add-original state name value))))))
    ((eng:js-object-p init)
     (let ((state (clun.cookies:make-cookie-map-state)))
       (dolist (key (eng:jm-own-property-keys init) state)
         (when (stringp key)
           (clun.cookies:cookie-map-add-original
            state key (eng:to-string (eng:js-getv init key)))))))
    (t (eng:throw-type-error "Invalid initializer type"))))

(defun %allocate-cookie-map (state)
  (%make-js-cookie-map
   :proto (web-cookie-realm-state-cookie-map-prototype
           (%cookie-runtime-state))
   :state state))

(defun %new-cookie-map (&optional (init eng:+undefined+))
  (%allocate-cookie-map (%cookie-map-state-from-init init)))

(defun %cookie-map-iterator-result (iterator)
  (let ((result (eng:new-object)))
    (if (js-cookie-map-iterator-done-p iterator)
        (progn
          (eng:create-data-property result "value" eng:+undefined+)
          (eng:create-data-property result "done" eng:+true+))
        (let* ((map (js-cookie-map-iterator-map iterator))
               (state (js-cookie-map-state map))
               (index (js-cookie-map-iterator-cursor iterator)))
          (multiple-value-bind (name value found-p)
              (clun.cookies:cookie-map-entry-at state index)
            (if found-p
                (progn
                  (incf (js-cookie-map-iterator-cursor iterator))
                  (eng:create-data-property
                   result "value"
                   (ecase (js-cookie-map-iterator-kind iterator)
                     (:entries (eng:new-array (list name value)))
                     (:keys name)
                     (:values value)))
                  (eng:create-data-property result "done" eng:+false+))
                (progn
                  (setf (js-cookie-map-iterator-done-p iterator) t)
                  (eng:create-data-property result "value" eng:+undefined+)
                  (eng:create-data-property result "done" eng:+true+))))))
    result))

(defun %new-cookie-map-iterator (map kind)
  (%make-js-cookie-map-iterator
   :proto (web-cookie-realm-state-iterator-prototype
           (%cookie-runtime-state))
   :map map :kind kind :cursor 0))

(defun %install-cookie-map-iterator-prototype (prototype)
  (%install-prototype-method
   prototype "next" 0
   (lambda (this args) (declare (ignore args))
     (unless (js-cookie-map-iterator-p this)
       (%error-with-code :type-error
                         "Cannot call next() on a non-Iterator object"
                         "ERR_INVALID_THIS"))
     (%cookie-map-iterator-result this))
   :enumerable t)
  (%define-data prototype (eng:well-known :to-string-tag) "CookieMap Iterator"
                :writable nil :enumerable nil :configurable t)
  prototype)

(defun %cookie-map-delete-options (args)
  (let ((first (eng:arg args 0)))
    (if (eng:js-object-p first)
        (let ((name-value (eng:js-get first "name")))
          (unless (eng:js-string-p name-value)
            (eng:throw-type-error "Cookie name is required"))
          (let* ((name (%validate-cookie-name-runtime name-value))
                 (domain-value (eng:js-get first "domain"))
                 (domain
                   (and (not (eng:js-nullish-p domain-value))
                        (%validate-cookie-domain-runtime
                         (%to-usv-string domain-value))))
                 (path-value (eng:js-get first "path"))
                 (path (if (eng:js-nullish-p path-value)
                           "/"
                           (%validate-cookie-path-runtime
                            (%to-usv-string path-value)))))
            (values name domain path)))
        (progn
          (unless (eng:js-string-p first)
            (eng:throw-type-error "Cookie name is required"))
          (let ((name (%validate-cookie-name-runtime first)))
            (if (= (length args) 1)
                (values name nil "/")
                (let ((options (eng:arg args 1)))
                  (unless (eng:js-object-p options)
                    (eng:throw-type-error "Options must be an object"))
                  (let* ((domain-value (eng:js-get options "domain"))
                         (domain
                           (and (not (eng:js-nullish-p domain-value))
                                (%validate-cookie-domain-runtime
                                 (%to-usv-string domain-value))))
                         (path-value (eng:js-get options "path"))
                         (path
                           (if (eng:js-nullish-p path-value)
                               "/"
                               (%validate-cookie-path-runtime
                                (%to-usv-string path-value)))))
                    (values name domain path)))))))))

(defun %cookie-map-json (map)
  (let* ((state (js-cookie-map-state map))
         (json (eng:new-object))
         (index 0))
    (loop
      (multiple-value-bind (name value found-p)
          (clun.cookies:cookie-map-entry-at state index)
        (unless found-p (return))
        (unless (eng:has-own-property json name)
          (eng:create-data-property json name value))
        (incf index)))
    json))

(defun %install-cookie-map-prototype (prototype)
  (%install-prototype-method
   prototype "get" 1
   (lambda (this args)
     (let ((map (%require-cookie-map this "get")))
       (if (null args)
           eng:+null+
           (multiple-value-bind (value found-p)
               (clun.cookies:cookie-map-get
                (js-cookie-map-state map)
                (%to-usv-string (eng:arg args 0)))
             (if found-p value eng:+null+)))))
   :enumerable t)
  (%install-prototype-method
   prototype "toSetCookieHeaders" 0
   (lambda (this args) (declare (ignore args))
     (eng:new-array
      (clun.cookies:cookie-map-response-fields
       (js-cookie-map-state
        (%require-cookie-map this "toSetCookieHeaders")))))
   :enumerable t)
  (%install-prototype-method
   prototype "has" 1
   (lambda (this args)
     (let ((map (%require-cookie-map this "has")))
       (eng:js-boolean
        (and args
             (clun.cookies:cookie-map-has
              (js-cookie-map-state map)
              (%to-usv-string (eng:arg args 0)))))))
   :enumerable t)
  (%install-prototype-method
   prototype "set" 2
   (lambda (this args)
     (let ((map (%require-cookie-map this "set")))
       (unless (null args)
         (let* ((first (first args))
                (record
                  (cond
                    ((js-cookie-p first) (js-cookie-record first))
                    ((eng:js-object-p first) (%make-cookie-record-init first))
                    ((= (length args) 1)
                     (%error-with-code :type-error "Not enough arguments"
                                       "ERR_MISSING_ARGS"))
                    (t
                     (%make-cookie-record-positional
                      first (eng:arg args 1) (eng:arg args 2))))))
           (clun.cookies:cookie-map-set-cookie
            (js-cookie-map-state map) record))))
     eng:+undefined+)
   :enumerable t)
  (%install-prototype-method
   prototype "delete" 1
   (lambda (this args)
     (let ((map (%require-cookie-map this "delete")))
       (unless (null args)
         (multiple-value-bind (name domain path)
             (%cookie-map-delete-options args)
           (%with-cookie-core-errors
             (clun.cookies:cookie-map-delete
              (js-cookie-map-state map) name :domain domain :path path)))))
     eng:+undefined+)
   :enumerable t)
  (let ((entries
          (%install-prototype-method
           prototype "entries" 0
           (lambda (this args) (declare (ignore args))
             (%new-cookie-map-iterator
              (%require-cookie-map this "entries") :entries))
           :enumerable t)))
    (%install-prototype-method
     prototype "keys" 0
     (lambda (this args) (declare (ignore args))
       (%new-cookie-map-iterator
        (%require-cookie-map this "keys") :keys))
     :enumerable t)
    (%install-prototype-method
     prototype "values" 0
     (lambda (this args) (declare (ignore args))
       (%new-cookie-map-iterator
        (%require-cookie-map this "values") :values))
     :enumerable t)
    (%install-prototype-method
     prototype "forEach" 1
     (lambda (this args)
       (let* ((map (%require-cookie-map this "forEach"))
              (callback (eng:arg args 0))
              (this-arg (eng:arg args 1))
              (state (js-cookie-map-state map))
              (index 0))
         (unless (eng:callable-p callback)
           (eng:throw-type-error "Cannot call callback on a non-function"))
         (loop
           (multiple-value-bind (name value found-p)
               (clun.cookies:cookie-map-entry-at state index)
             (unless found-p (return))
             (eng:js-call callback this-arg (list value name map))
             (incf index))))
       eng:+undefined+)
     :enumerable t)
    (%install-prototype-method
     prototype "toJSON" 0
     (lambda (this args) (declare (ignore args))
       (%cookie-map-json (%require-cookie-map this "toJSON")))
     :enumerable t)
    (%define-accessor
     prototype "size"
     (lambda (this args) (declare (ignore args))
       (coerce
        (clun.cookies:cookie-map-size
         (js-cookie-map-state (%require-cookie-map this "size")))
        'double-float))
     nil :enumerable t :configurable nil)
    (%define-data prototype (eng:well-known :iterator) entries
                  :writable t :enumerable nil :configurable t))
  (%define-data prototype (eng:well-known :to-string-tag) "CookieMap"
                :writable nil :enumerable nil :configurable t)
  prototype)

(defun %make-cookie-map-constructor (prototype)
  (let ((constructor
          (eng:make-native-function
           "CookieMap" 1
           (lambda (this args)
             (declare (ignore this args))
             (%error-with-code
              :type-error
              "Use `new CookieMap(...)` instead of `CookieMap(...)`"
              "ERR_ILLEGAL_CONSTRUCTOR"))
           :construct
           (lambda (args new-target)
             (declare (ignore new-target))
             (%new-cookie-map (eng:arg args 0))))))
    (%set-constructor-prototype constructor prototype)
    constructor))

;;; --- server Request cookies -------------------------------------------------

(defun %server-request-cookies (request)
  (unless (js-server-request-p request)
    (%error-with-code :type-error
                      "Can only get cookies on a Clun.serve Request"
                      "ERR_INVALID_THIS"))
  (if (js-server-request-cookie-cache-initialized-p request)
      (js-server-request-cookie-cache request)
      (let* ((headers (%request-headers-object request))
             (values (%header-values headers "cookie"))
             (header (and values (%join-header-values "cookie" values)))
             (map (%new-cookie-map
                   (if header header eng:+undefined+))))
        (setf (js-server-request-cookie-cache request) map
              (js-server-request-cookie-cache-initialized-p request) t)
        map)))

(defun %install-server-request-cookies-accessor ()
  (%define-accessor
   (%server-request-prototype) "cookies"
   (lambda (this args) (declare (ignore args))
     (%server-request-cookies this))
   nil :enumerable t :configurable nil))

;;; --- installation -----------------------------------------------------------

(defun install-web-cookies (realm)
  "Install realm-local Clun.Cookie, Clun.CookieMap, and server Request cookies."
  (let ((eng:*realm* realm))
    ;; web-http must already have installed the canonical Request prototype.
    (%http-state realm)
    (or (gethash realm *web-cookie-realm-states*)
        (let* ((cookie-prototype (eng:new-object))
               (cookie-map-prototype (eng:new-object))
               (iterator-prototype
                 (eng:js-make-object (eng:intrinsic :iterator-prototype)))
               (state
                 (%make-web-cookie-realm-state
                  :cookie-prototype cookie-prototype
                  :cookie-map-prototype cookie-map-prototype
                  :iterator-prototype iterator-prototype)))
          (setf (gethash realm *web-cookie-realm-states*) state)
          ;; Wire constructors first so "constructor" is the first own key on
          ;; each public prototype, then append the frozen method/accessor order.
          (setf (web-cookie-realm-state-cookie-constructor state)
                (%make-cookie-constructor cookie-prototype)
                (web-cookie-realm-state-cookie-map-constructor state)
                (%make-cookie-map-constructor cookie-map-prototype))
          (%install-cookie-prototype cookie-prototype)
          (%install-cookie-map-iterator-prototype iterator-prototype)
          (%install-cookie-map-prototype cookie-map-prototype)
          (%install-server-request-cookies-accessor)
          state))
    (let* ((global (eng:realm-global realm))
           (clun (eng:js-get global "Clun"))
           (state (%cookie-runtime-state realm)))
      (unless (eng:js-object-p clun)
        (error "Clun must be installed before web cookies"))
      (%define-data clun "Cookie"
                    (web-cookie-realm-state-cookie-constructor state)
                    :writable nil :enumerable t :configurable nil)
      (%define-data clun "CookieMap"
                    (web-cookie-realm-state-cookie-map-constructor state)
                    :writable nil :enumerable t :configurable nil))
    realm))
