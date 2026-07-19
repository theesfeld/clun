;;;; secrets-tests.lisp -- Pure-CL secrets vault + Clun.secrets (Issue #179).

(in-package :clun-test)

(defun secrets-error-kind (thunk)
  (handler-case (progn (funcall thunk) nil)
    (clun.secrets:secrets-error (condition)
      (clun.secrets:secrets-error-kind condition))))

(defun %with-temp-vault (thunk)
  (let* ((dir (clun.sys:make-temp-dir
               (clun.sys:path-join (clun.sys:tmpdir) "clun-secrets-test-")))
         (vault (clun.sys:path-join dir "secrets.vault"))
         (key (clun.sys:os-random-bytes 32)))
    (unwind-protect
         (let ((clun.secrets:*vault-path-override* vault)
               (clun.secrets:*master-key-override* key))
           (funcall thunk dir vault))
      (ignore-errors (clun.sys:remove-recursive dir)))))

(define-test security/secrets-available
  (true (clun.secrets:secrets-available-p))
  (true (clun.secrets:os-secrets-available-p))
  (true (search "ERR_SECRETS" clun.secrets:+platform-error-code+)))

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

(define-test security/secrets-vault-roundtrip
  (%with-temp-vault
   (lambda (dir vault)
     (declare (ignore dir vault))
     (is eq nil (clun.secrets:secrets-get "svc" "acct"))
     (false (clun.secrets:secrets-has "svc" "acct"))
     (false (clun.secrets:secrets-delete "svc" "acct"))
     (clun.secrets:secrets-set "svc" "acct" "s3cret")
     (is string= "s3cret" (clun.secrets:secrets-get "svc" "acct"))
     (true (clun.secrets:secrets-has "svc" "acct"))
     (clun.secrets:secrets-set "svc" "acct" "rotated")
     (is string= "rotated" (clun.secrets:secrets-get "svc" "acct"))
     (clun.secrets:secrets-set "svc" "other" "v2")
     (clun.secrets:secrets-set "other-svc" "acct" "v3")
     (let ((all (clun.secrets:secrets-list))
           (svc (clun.secrets:secrets-list "svc")))
       (is eql 3 (length all))
       (is eql 2 (length svc))
       (true (every (lambda (p) (string= (car p) "svc")) svc)))
     (true (clun.secrets:secrets-delete "svc" "acct"))
     (is eq nil (clun.secrets:secrets-get "svc" "acct"))
     (false (clun.secrets:secrets-has "svc" "acct"))
     ;; Bun empty-string delete parity
     (clun.secrets:secrets-set "svc" "other" "")
     (false (clun.secrets:secrets-has "svc" "other"))
     (is eql 1 (clun.secrets:secrets-clear "other-svc"))
     (is eql 0 (length (clun.secrets:secrets-list)))
     ;; unicode + multi-byte
     (clun.secrets:secrets-set "svc" "ユニコード" "パスワード🔐")
     (is string= "パスワード🔐" (clun.secrets:secrets-get "svc" "ユニコード"))
     (is eql 1 (clun.secrets:secrets-clear))
     (is eql 0 (length (clun.secrets:secrets-list))))))

(define-test security/secrets-vault-persistence
  (%with-temp-vault
   (lambda (dir vault)
     (declare (ignore dir))
     (clun.secrets:secrets-set "persist" "k" "value-1")
     (true (clun.sys:file-p vault))
     ;; Reload via fresh get using same overrides
     (is string= "value-1" (clun.secrets:secrets-get "persist" "k"))
     ;; Wrong key → access denied
     (let ((clun.secrets:*master-key-override*
             (clun.sys:os-random-bytes 32)))
       (is eq :access-denied
           (secrets-error-kind
            (lambda () (clun.secrets:secrets-get "persist" "k"))))))))

(define-test runtime/clun-secrets-surface
  (%with-temp-vault
   (lambda (dir vault)
     (declare (ignore dir vault))
     (let ((realm (eng:make-realm)))
       (unwind-protect
            (progn
              (rt:install-runtime realm :argv '(:script "[secrets-test]" :rest nil)
                                          :cwd "/tmp" :colors nil)
              (eng:run-source
               "globalThis.keys = Object.keys(Clun.secrets).sort().join(',');
                globalThis.backend = Clun.secrets.backend;
                globalThis.getName = Clun.secrets.get.name;
                globalThis.setName = Clun.secrets.set.name;
                globalThis.deleteName = Clun.secrets.delete.name;
                globalThis.hasName = Clun.secrets.has.name;
                globalThis.listName = Clun.secrets.list.name;
                globalThis.clearName = Clun.secrets.clear.name;
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
                Promise.all([
                  Clun.secrets.set({ service: 'clun-179', name: 'probe', value: 'token-1',
                                    allowUnrestrictedAccess: true }),
                  Clun.secrets.get({ service: 'clun-179', name: 'probe' }),
                  Clun.secrets.has({ service: 'clun-179', name: 'probe' }),
                  Clun.secrets.get('clun-179', 'missing'),
                  Clun.secrets.set('clun-179', 'positional', 'pos-val'),
                  Clun.secrets.get('clun-179', 'positional'),
                  Clun.secrets.list({ service: 'clun-179' }),
                  Clun.secrets.delete({ service: 'clun-179', name: 'probe' }),
                  Clun.secrets.delete({ service: 'clun-179', name: 'probe' }),
                  Clun.secrets.set({ service: 'clun-179', name: 'positional', value: '' }),
                  Clun.secrets.has('clun-179', 'positional'),
                  Clun.secrets.clear('clun-179')
                ]).then((results) => {
                  globalThis.setOk = results[0] === undefined;
                  globalThis.gotVal = results[1];
                  globalThis.hasTrue = results[2] === true;
                  globalThis.missingNull = results[3] === null;
                  globalThis.posVal = results[5];
                  globalThis.listLen = results[6].length;
                  globalThis.delTrue = results[7] === true;
                  globalThis.delFalse = results[8] === false;
                  globalThis.hasAfterEmpty = results[10] === false;
                  globalThis.clearCount = results[11];
                }).catch((error) => {
                  globalThis.asyncErr = error.name + '|' + error.code + '|' + error.message;
                });
                try {
                  Clun.secrets.set('svc', 'name');
                  globalThis.posMissingValue = 'NO_THROW';
                } catch (error) {
                  globalThis.posMissingValue = error.name + '|' + error.code + '|' + error.message;
                }
                try {
                  Clun.secrets.set('svc', 'name', 1);
                  globalThis.posBadValue = 'NO_THROW';
                } catch (error) {
                  globalThis.posBadValue = error.name + '|' + error.code + '|' + error.message;
                }"
               :realm realm)
              (let ((eng::*realm* realm)
                    (global (eng:realm-global realm)))
                (is string= "backend,clear,delete,get,has,list,set"
                    (eng:js-get global "keys"))
                (is string= "vault" (eng:js-get global "backend"))
                (is string= "get" (eng:js-get global "getName"))
                (is string= "set" (eng:js-get global "setName"))
                (is string= "delete" (eng:js-get global "deleteName"))
                (is string= "has" (eng:js-get global "hasName"))
                (is string= "list" (eng:js-get global "listName"))
                (is string= "clear" (eng:js-get global "clearName"))
                (is string= "TypeError|ERR_INVALID_ARG_TYPE|Expected service and name to be strings"
                    (eng:js-get global "syncInvalid"))
                (is string= "TypeError|ERR_INVALID_ARG_TYPE|Expected service and name to not be empty"
                    (eng:js-get global "emptyInvalid"))
                (true (search "Expected 'value' to be a string"
                              (eng:js-get global "missingValue")))
                (true (search "Expected 'value' to be a string"
                              (eng:js-get global "posMissingValue")))
                (is string= "TypeError|ERR_INVALID_ARG_TYPE|Expected 'value' to be a string"
                    (eng:js-get global "posBadValue"))
                (is eq eng:+undefined+ (eng:js-get global "asyncErr"))
                (true (eng:js-get global "setOk"))
                (is string= "token-1" (eng:js-get global "gotVal"))
                (true (eng:js-get global "hasTrue"))
                (true (eng:js-get global "missingNull"))
                (is string= "pos-val" (eng:js-get global "posVal"))
                (is eql 2d0 (eng:js-get global "listLen"))
                (true (eng:js-get global "delTrue"))
                (true (eng:js-get global "delFalse"))
                (true (eng:js-get global "hasAfterEmpty"))
                (is eql 0d0 (eng:js-get global "clearCount"))
                (is eql 1d0 (eng:js-get global "tick"))))
         (eng:teardown-realm realm))))))
