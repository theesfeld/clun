;;;; secrets-tests.lisp -- Phase 58 OS-secrets constitutional checkpoint.

(in-package :clun-test)

(defun secrets-error-kind (thunk)
  (handler-case (progn (funcall thunk) nil)
    (clun.secrets:secrets-error (condition)
      (clun.secrets:secrets-error-kind condition))))

(define-test security/secrets-os-unavailable
  (false (clun.secrets:os-secrets-available-p))
  (is eq :not-available (secrets-error-kind #'clun.secrets:reject-os-secrets))
  (is string= "ERR_SECRETS_NOT_AVAILABLE" clun.secrets:+not-available-code+)
  (true (search "purity" clun.secrets:+not-available-message+ :test #'char-equal))
  (true (search "Phase 58" clun.secrets:+not-available-message+)))

(define-test security/secrets-arg-validation
  (is eq :invalid-arg
      (secrets-error-kind
       (lambda () (clun.secrets:validate-service-name nil "n"))))
  (is eq :invalid-arg
      (secrets-error-kind
       (lambda () (clun.secrets:validate-service-name "s" 1))))
  (is eq :invalid-arg
      (secrets-error-kind
       (lambda () (clun.secrets:validate-service-name "" "n"))))
  (is eq :invalid-arg
      (secrets-error-kind
       (lambda () (clun.secrets:validate-service-name "s" ""))))
  (true (clun.secrets:validate-service-name "svc" "acct"))
  (is eq :invalid-arg
      (secrets-error-kind
       (lambda () (clun.secrets:validate-set-value nil nil))))
  (is eq :invalid-arg
      (secrets-error-kind
       (lambda () (clun.secrets:validate-set-value 12 t))))
  (true (clun.secrets:validate-set-value "token" t))
  (true (clun.secrets:validate-set-value "" t)))

(define-test runtime/clun-secrets-surface
  (let ((realm (eng:make-realm)))
    (unwind-protect
         (progn
           (rt:install-runtime realm :argv '(:script "[secrets-test]" :rest nil)
                                       :cwd "/tmp" :colors nil)
           (eng:run-source
            "globalThis.keys = Object.keys(Clun.secrets).join(',');
             globalThis.getName = Clun.secrets.get.name;
             globalThis.setName = Clun.secrets.set.name;
             globalThis.deleteName = Clun.secrets.delete.name;
             globalThis.syncInvalid = null;
             try {
               Clun.secrets.get({ name: 'only-name' });
               globalThis.syncInvalid = 'NO_THROW';
             } catch (error) {
               globalThis.syncInvalid = error.name + '|' + error.code + '|' + error.message;
             }
             globalThis.emptyInvalid = null;
             try {
               Clun.secrets.get({ service: '', name: 'x' });
               globalThis.emptyInvalid = 'NO_THROW';
             } catch (error) {
               globalThis.emptyInvalid = error.name + '|' + error.code + '|' + error.message;
             }
             globalThis.missingValue = null;
             try {
               Clun.secrets.set({ service: 's', name: 'n' });
               globalThis.missingValue = 'NO_THROW';
             } catch (error) {
               globalThis.missingValue = error.name + '|' + error.code + '|' + error.message;
             }
             globalThis.tick = 0;
             setTimeout(() => { globalThis.tick++; }, 0);
             Clun.secrets.get({ service: 'clun-phase-58', name: 'probe' })
               .then(() => { globalThis.gotResolved = true; })
               .catch((error) => {
                 globalThis.gotCode = error.code;
                 globalThis.gotName = error.name;
                 globalThis.gotMsg = error.message;
               });
             Clun.secrets.set({ service: 'clun-phase-58', name: 'probe', value: 'v' })
               .then(() => { globalThis.setResolved = true; })
               .catch((error) => { globalThis.setCode = error.code; });
             Clun.secrets.delete({ service: 'clun-phase-58', name: 'probe' })
               .then(() => { globalThis.delResolved = true; })
               .catch((error) => { globalThis.delCode = error.code; });
             Clun.secrets.get('clun-phase-58', 'positional')
               .then(() => { globalThis.posResolved = true; })
               .catch((error) => { globalThis.posCode = error.code; });"
            :realm realm)
           (let ((eng::*realm* realm)
                 (global (eng:realm-global realm)))
             (is string= "get,set,delete" (eng:js-get global "keys"))
             (is string= "get" (eng:js-get global "getName"))
             (is string= "set" (eng:js-get global "setName"))
             (is string= "delete" (eng:js-get global "deleteName"))
             (is string= "TypeError|ERR_INVALID_ARG_TYPE|Expected service and name to be strings"
                 (eng:js-get global "syncInvalid"))
             (is string= "TypeError|ERR_INVALID_ARG_TYPE|Expected service and name to not be empty"
                 (eng:js-get global "emptyInvalid"))
             (true (search "Expected 'value' to be a string"
                           (eng:js-get global "missingValue")))
             (is string= "ERR_SECRETS_NOT_AVAILABLE" (eng:js-get global "gotCode"))
             (is string= "Error" (eng:js-get global "gotName"))
             (true (search "purity" (eng:js-get global "gotMsg") :test #'char-equal))
             (is string= "ERR_SECRETS_NOT_AVAILABLE" (eng:js-get global "setCode"))
             (is string= "ERR_SECRETS_NOT_AVAILABLE" (eng:js-get global "delCode"))
             (is string= "ERR_SECRETS_NOT_AVAILABLE" (eng:js-get global "posCode"))
             (is eq eng:+undefined+ (eng:js-get global "gotResolved"))
             (is eq eng:+undefined+ (eng:js-get global "setResolved"))
             (is eq eng:+undefined+ (eng:js-get global "delResolved"))
             (is eql 1d0 (eng:js-get global "tick"))))
      (eng:teardown-realm realm))))
