;;;; clun-secrets.lisp -- Clun.secrets JavaScript boundary (Issue #179 FULL PORT).
;;;;
;;;; Bun-compatible get/set/delete (service/name, empty-value delete,
;;;; allowUnrestrictedAccess) backed by the pure-CL AES-256-GCM vault.
;;;; Exceed surface: has, list, clear.

(in-package :clun.runtime)

(defun %secrets-type-error (message)
  (let ((error (eng:make-error-object :type-error-prototype "TypeError" message)))
    (eng:js-set error "code" "ERR_INVALID_ARG_TYPE" nil)
    (eng:throw-js-value error)))

(defun %secrets-error-object (condition)
  (let* ((kind (clun.secrets:secrets-error-kind condition))
         (detail (or (clun.secrets:secrets-error-detail condition)
                     (string kind)))
         (code (or (clun.secrets:secrets-error-code condition)
                   (case kind
                     (:access-denied clun.secrets:+access-denied-code+)
                     (:platform-error clun.secrets:+platform-error-code+)
                     (:not-available clun.secrets:+not-available-code+)
                     (t clun.secrets:+platform-error-code+))))
         (name (if (eq kind :invalid-arg) "TypeError" "Error"))
         (proto (if (eq kind :invalid-arg)
                    :type-error-prototype
                    :error-prototype))
         (error (eng:make-error-object proto name detail)))
    (eng:js-set error "code"
                (if (eq kind :invalid-arg) "ERR_INVALID_ARG_TYPE" code)
                nil)
    error))

(defun %secrets-resolved-promise (global value)
  (eng:js-construct
   (eng:js-get global "Promise")
   (list
    (eng:make-native-function
     "" 2
     (lambda (this args)
       (declare (ignore this))
       (eng:js-call (eng:arg args 0) eng:+undefined+ (list value))
       eng:+undefined+)))))

(defun %secrets-rejected-promise (global error)
  (eng:js-construct
   (eng:js-get global "Promise")
   (list
    (eng:make-native-function
     "" 2
     (lambda (this args)
       (declare (ignore this))
       (eng:js-call (eng:arg args 1) eng:+undefined+ (list error))
       eng:+undefined+)))))

(defmacro %secrets-async ((global) &body body)
  (let ((g (gensym)) (e (gensym)))
    `(let ((,g ,global))
       (handler-case (%secrets-resolved-promise ,g (progn ,@body))
         (clun.secrets:secrets-error (,e)
           (if (eq (clun.secrets:secrets-error-kind ,e) :invalid-arg)
               (eng:throw-js-value (%secrets-error-object ,e))
               (%secrets-rejected-promise ,g (%secrets-error-object ,e))))
         (error (,e)
           (%secrets-rejected-promise
            ,g
            (let ((err (eng:make-error-object
                        :error-prototype "Error"
                        (format nil "~A" ,e))))
              (eng:js-set err "code" clun.secrets:+platform-error-code+ nil)
              err)))))))

(defun %secrets-js-string (value)
  (and (eng:js-string-p value) value))

(defun %secrets-require-set-value (value has-value-p)
  "Bun-shaped TypeError for missing / non-string set value."
  (cond
    ((or (not has-value-p)
         (eng:js-undefined-p value)
         (eng:js-null-p value))
     (%secrets-type-error
      "Expected 'value' to be a string. To delete the secret, call secrets.delete instead."))
    ((not (eng:js-string-p value))
     (%secrets-type-error "Expected 'value' to be a string"))
    (t value)))

(defun %secrets-parse-options (args operation)
  "Parse object or positional secrets arguments.
   Returns (values service name value value-present-p allow-unrestricted-p).
   VALUE is meaningful only for :set.

   Positional forms:
     get/delete/has: (service name)
     set:            (service name value)
     list/clear:     (service?) optional
   When the first two arguments are strings, the call is treated as positional
   even if `value` is missing or the wrong type (so set reports a value error,
   not \"Expected options to be an object\")."
  (let ((n (length args))
        (first (eng:arg args 0))
        (second (eng:arg args 1))
        (third (eng:arg args 2)))
    (when (member operation '(:list :clear))
      (cond
        ((zerop n) (return-from %secrets-parse-options (values nil nil nil nil nil)))
        ((eng:js-string-p first)
         (when (zerop (length first))
           (%secrets-type-error "Expected service to not be empty"))
         (return-from %secrets-parse-options (values first nil nil nil nil)))
        ((eng:js-object-p first)
         (let* ((service (eng:js-get first "service"))
                (service-s (%secrets-js-string service)))
           (unless service-s
             (%secrets-type-error "Expected service to be a string"))
           (when (zerop (length service-s))
             (%secrets-type-error "Expected service to not be empty"))
           (return-from %secrets-parse-options
             (values service-s nil nil nil nil))))
        (t (%secrets-type-error "Expected service to be a string or options object"))))
    (when (and (>= n 2)
               (eng:js-string-p first)
               (eng:js-string-p second))
      (return-from %secrets-parse-options
        (if (eq operation :set)
            (let ((has-value (>= n 3))
                  (value (if (>= n 3) third eng:+undefined+)))
              (%secrets-require-set-value value has-value)
              (values first second value t nil))
            (values first second nil nil nil))))
    (when (zerop n)
      (%secrets-type-error "Expected options to be an object"))
    (unless (eng:js-object-p first)
      (%secrets-type-error "Expected options to be an object"))
    (let* ((service (eng:js-get first "service"))
           (name (eng:js-get first "name"))
           (service-s (%secrets-js-string service))
           (name-s (%secrets-js-string name)))
      (unless (and service-s name-s)
        (%secrets-type-error "Expected service and name to be strings"))
      (when (or (zerop (length service-s)) (zerop (length name-s)))
        (%secrets-type-error "Expected service and name to not be empty"))
      (if (eq operation :set)
          (let ((has-value (eng:has-property first "value"))
                (value (eng:js-get first "value")))
            (%secrets-require-set-value value has-value)
            (let ((allow (eng:js-get first "allowUnrestrictedAccess")))
              (values service-s name-s value t
                      (and (not (eng:js-undefined-p allow))
                           (eng:js-truthy allow)))))
          (values service-s name-s nil nil nil)))))

(defun %secrets-list-to-js (pairs)
  "PAIRS is a list of (service . name) conses → JS array of {service,name}."
  (eng:new-array
   (mapcar (lambda (pair)
             (let ((obj (eng:new-object)))
               (eng:data-prop obj "service" (car pair))
               (eng:data-prop obj "name" (cdr pair))
               obj))
           pairs)))

(defun %secrets-dispatch (global args operation)
  "Validate ARGS and perform the vault operation as a Promise."
  (multiple-value-bind (service name value value-p allow)
      (%secrets-parse-options args operation)
    (declare (ignore value-p))
    (%secrets-async (global)
      (ecase operation
        (:get
         (let ((v (clun.secrets:secrets-get service name)))
           (if v v eng:+null+)))
        (:set
         (clun.secrets:secrets-set service name value
                                   :allow-unrestricted allow)
         eng:+undefined+)
        (:delete
         (if (clun.secrets:secrets-delete service name)
             eng:+true+
             eng:+false+))
        (:has
         (if (clun.secrets:secrets-has service name)
             eng:+true+
             eng:+false+))
        (:list
         (%secrets-list-to-js (clun.secrets:secrets-list service)))
        (:clear
         (let ((n (clun.secrets:secrets-clear service)))
           (coerce (float n 1d0) 'double-float)))))))

(defun make-clun-secrets (global)
  (let ((object (eng:new-object)))
    (eng:data-prop object "get"
                   (eng:make-native-function
                    "get" 1
                    (lambda (this args)
                      (declare (ignore this))
                      (%secrets-dispatch global args :get))))
    (eng:data-prop object "set"
                   (eng:make-native-function
                    "set" 1
                    (lambda (this args)
                      (declare (ignore this))
                      (%secrets-dispatch global args :set))))
    (eng:data-prop object "delete"
                   (eng:make-native-function
                    "delete" 1
                    (lambda (this args)
                      (declare (ignore this))
                      (%secrets-dispatch global args :delete))))
    (eng:data-prop object "has"
                   (eng:make-native-function
                    "has" 1
                    (lambda (this args)
                      (declare (ignore this))
                      (%secrets-dispatch global args :has))))
    (eng:data-prop object "list"
                   (eng:make-native-function
                    "list" 0
                    (lambda (this args)
                      (declare (ignore this))
                      (%secrets-dispatch global args :list))))
    (eng:data-prop object "clear"
                   (eng:make-native-function
                    "clear" 0
                    (lambda (this args)
                      (declare (ignore this))
                      (%secrets-dispatch global args :clear))))
    (eng:data-prop object "backend" "vault")
    object))

(defun install-clun-secrets (clun global)
  (eng:nonconfigurable-data-prop clun "secrets" (make-clun-secrets global)))
