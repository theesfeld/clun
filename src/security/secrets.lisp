;;;; secrets.lisp -- Phase 58 OS-secrets constitutional disposition (engine-free).
;;;;
;;;; Bun.secrets backs credentials with OS keychains (macOS Security.framework,
;;;; Linux libsecret, Windows Credential Manager). Those backends require native
;;;; foreign calls forbidden by Clun's purity contract. This package records that
;;;; disposition and provides pure argument validation so the runtime can fail
;;;; closed with Bun-shaped codes without ever touching a store.

(in-package :clun.secrets)

;; String codes use DEFPARAMETER: SBCL treats reloaded string DEFCONSTANTs as
;; DEFCONSTANT-UNEQL even when the characters match.
(defparameter +not-available-code+ "ERR_SECRETS_NOT_AVAILABLE")

(defparameter +not-available-message+
  "Operating-system secrets storage is not available in Clun: pure Common Lisp cannot use macOS Keychain, libsecret, or Windows Credential Manager without a constitutional purity amendment (Phase 58)."
  "User-visible Error.message for every store operation under the constitutional checkpoint.")

(define-condition secrets-error (error)
  ((kind :initarg :kind :reader secrets-error-kind)
   (detail :initarg :detail :initform nil :reader secrets-error-detail))
  (:report (lambda (condition stream)
             (if (secrets-error-detail condition)
                 (format stream "~A: ~A"
                         (secrets-error-kind condition)
                         (secrets-error-detail condition))
                 (format stream "~A" (secrets-error-kind condition))))))

(defun os-secrets-available-p ()
  "Always NIL: OS keychain parity is excluded by the purity contract."
  nil)

(defun reject-os-secrets (&optional operation)
  "Signal the constitutional not-available error for OPERATION (:get/:set/:delete)."
  (declare (ignore operation))
  (error 'secrets-error
         :kind :not-available
         :detail +not-available-message+))

(defun validate-service-name (service name)
  "Validate SERVICE and NAME as non-empty strings.
   Returns T on success; signals secrets-error :invalid-arg otherwise.
   Messages match Bun's ERR_INVALID_ARG_TYPE spellings."
  (unless (and (stringp service) (stringp name))
    (error 'secrets-error
           :kind :invalid-arg
           :detail "Expected service and name to be strings"))
  (when (or (zerop (length service)) (zerop (length name)))
    (error 'secrets-error
           :kind :invalid-arg
           :detail "Expected service and name to not be empty"))
  t)

(defun validate-set-value (value present-p)
  "Validate SET's value string. PRESENT-P is false when the property was absent
   or null/undefined in the options object form."
  (cond
    ((not present-p)
     (error 'secrets-error
            :kind :invalid-arg
            :detail "Expected 'value' to be a string. To delete the secret, call secrets.delete instead."))
    ((not (stringp value))
     (error 'secrets-error
            :kind :invalid-arg
            :detail "Expected 'value' to be a string"))
    (t t)))
