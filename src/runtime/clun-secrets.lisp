;;;; clun-secrets.lisp -- Clun.secrets JavaScript boundary (Phase 58).
;;;;
;;;; Fail-closed OS-secrets surface: Bun-shaped argument validation, then
;;;; ERR_SECRETS_NOT_AVAILABLE. Never stores credentials and never opens a
;;;; keychain, D-Bus session, or file vault under this API.

(in-package :clun.runtime)

(defun %secrets-type-error (message)
  (let ((error (eng:make-error-object :type-error-prototype "TypeError" message)))
    (eng:js-set error "code" "ERR_INVALID_ARG_TYPE" nil)
    (eng:throw-js-value error)))

(defun %secrets-not-available-error ()
  (let ((error (eng:make-error-object
                :error-prototype "Error"
                clun.secrets:+not-available-message+)))
    (eng:js-set error "code" clun.secrets:+not-available-code+ nil)
    error))

(defun %secrets-throw-not-available ()
  (eng:throw-js-value (%secrets-not-available-error)))

(defun %secrets-rejected-promise (global)
  "Promise that rejects with ERR_SECRETS_NOT_AVAILABLE (async path)."
  (let ((error (%secrets-not-available-error)))
    (eng:js-construct
     (eng:js-get global "Promise")
     (list
      (eng:make-native-function
       "" 2
       (lambda (this args)
         (declare (ignore this))
         (eng:js-call (eng:arg args 1) eng:+undefined+ (list error))
         eng:+undefined+))))))

(defun %secrets-js-string (value)
  (and (eng:js-string-p value) value))

(defun %secrets-parse-options (args operation)
  "Parse object or positional secrets arguments.
   Returns (values service name value value-present-p allow-unrestricted-p).
   VALUE is meaningful only for :set."
  (let ((n (length args))
        (first (eng:arg args 0))
        (second (eng:arg args 1))
        (third (eng:arg args 2)))
    (when (and (>= n (if (eq operation :set) 3 2))
               (eng:js-string-p first)
               (eng:js-string-p second)
               (or (not (eq operation :set)) (eng:js-string-p third)))
      (return-from %secrets-parse-options
        (values first second
                (if (eq operation :set) third nil)
                (eq operation :set)
                nil)))
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
            (cond
              ((not has-value)
               (%secrets-type-error
                "Expected 'value' to be a string. To delete the secret, call secrets.delete instead."))
              ((or (eng:js-undefined-p value) (eng:js-null-p value))
               (%secrets-type-error
                "Expected 'value' to be a string. To delete the secret, call secrets.delete instead."))
              ((not (eng:js-string-p value))
               (%secrets-type-error "Expected 'value' to be a string"))
              (t
               (let ((allow (eng:js-get first "allowUnrestrictedAccess")))
                 (values service-s name-s value t
                         (and (not (eng:js-undefined-p allow))
                              (eng:js-truthy allow)))))))
          (values service-s name-s nil nil nil)))))

(defun %secrets-dispatch (global args operation)
  "Validate ARGS then reject with the constitutional not-available error."
  (%secrets-parse-options args operation)
  ;; Validation succeeded; purity contract forbids any OS store access.
  (%secrets-rejected-promise global))

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
    object))

(defun install-clun-secrets (clun global)
  (eng:nonconfigurable-data-prop clun "secrets" (make-clun-secrets global)))
