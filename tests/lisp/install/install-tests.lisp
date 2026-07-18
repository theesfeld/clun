;;;; install-tests.lisp — Phase 23 milestone 1b: the hermetic install e2e against the Phase-21 fixture
;;;; registry. A fresh install resolves the diamond, downloads + extracts into a hoisted node_modules,
;;;; and writes clun.lock; deleting node_modules and reinstalling OFFLINE from the lock (via the
;;;; content-addressed cache, fixture down) reproduces the layout + a BYTE-IDENTICAL lock;
;;;; --frozen-lockfile errors on drift. CLUN_CACHE is pointed at a temp dir per test (hermetic).

(in-package :clun-test)

(defparameter *install-deps-json*
  "{\"@scope/widget\":\"^1.0.0\",\"conflict-a\":\"1.0.0\",\"conflict-b\":\"1.0.0\"}")

(defun %write-package-json (dir deps-json)
  (sys:write-file-octets
   (sys:path-join dir "package.json")
   (sb-ext:string-to-octets
    (format nil "{\"name\":\"root\",\"version\":\"1.0.0\",\"dependencies\":~a}~%" deps-json)
    :external-format :utf-8)))

(defun %fresh-install (dir &key production)
  "Start the fixture on a loop, install-async DIR against it (shared loop — no second loop), and
return (values install-result error)."
  (let ((loop (lp:make-event-loop :workers 0)) (result nil) (err nil))
    (unwind-protect
         (multiple-value-bind (listener reg base) (start-fixture-registry loop)
           (declare (ignore reg))
           (unwind-protect
                (progn
                  (handler-case
                      (inst:install-async loop dir :registry base :production production
                        :on-ok  (lambda (r) (setf result r) (lp:loop-stop loop))
                        :on-err (lambda (e) (setf err e) (lp:loop-stop loop)))
                    (error (e) (setf err e)))
                  (unless (or result err) (lp:run-loop loop)))
             (net:listener-close listener)))
      (lp:destroy-event-loop loop))
    (values result err)))

(defmacro with-temp-cache ((cache-dir) &body body)
  "Point $CLUN_CACHE at a fresh temp dir for the duration of BODY (hermetic; restored/removed after)."
  (let ((old (gensym)))
    `(let ((,cache-dir (clun.sys:make-temp-dir "/tmp/clun-icache-"))
           (,old (sb-ext:posix-getenv "CLUN_CACHE")))
       (declare (ignorable ,cache-dir))
       (unwind-protect
            (progn (sb-posix:setenv "CLUN_CACHE" ,cache-dir 1) ,@body)
         (if ,old (sb-posix:setenv "CLUN_CACHE" ,old 1) (ignore-errors (sb-posix:unsetenv "CLUN_CACHE")))
         (ignore-errors (clun.sys:remove-recursive ,cache-dir))))))

(defun %nm (dir &rest segs) (apply #'clun.sys:path-join dir "node_modules" segs))
(defun %has-pkg (dir &rest segs) (clun.sys:path-exists-p (apply #'clun.sys:path-join (%nm dir) (append segs (list "package.json")))))

(define-test install/fresh-hoisted-layout
  (with-temp-cache (cache)
    (let ((proj (clun.sys:make-temp-dir "/tmp/clun-proj-")))
      (unwind-protect
           (progn
             (%write-package-json proj *install-deps-json*)
             (multiple-value-bind (result err) (%fresh-install proj)
               (false err)
               (true (inst:install-result-p result))
               (is eq :resolved (inst:ir-source result))
               (is = 6 (inst:ir-node-count result) "6 packages resolved")
               ;; hoisted to the root node_modules
               (true (%has-pkg proj "left-pad") "left-pad hoisted")
               (true (%has-pkg proj "@scope" "widget") "@scope/widget hoisted")
               (true (%has-pkg proj "conflict-a") "conflict-a hoisted")
               (true (%has-pkg proj "conflict-b") "conflict-b hoisted")
               ;; the diamond: shared@1 hoisted, shared@2 nested under conflict-b
               (true (%has-pkg proj "shared") "shared (one version) hoisted")
               (true (%has-pkg proj "conflict-b" "node_modules" "shared") "the conflicting shared is nested")
               ;; the hoisted shared is 1.0.0 (conflict-a's), the nested is 2.0.0
               (is equal "1.0.0" (clun.sys:jget (clun.sys:parse-json
                                                 (clun.sys:read-file-string (%nm proj "shared" "package.json"))) "version"))
               (is equal "2.0.0" (clun.sys:jget (clun.sys:parse-json
                                                 (clun.sys:read-file-string (%nm proj "conflict-b" "node_modules" "shared" "package.json"))) "version"))
               ;; left-pad ^1.1.0 (transitive via @scope/widget) resolved to 1.3.0
               (is equal "1.3.0" (clun.sys:jget (clun.sys:parse-json
                                                 (clun.sys:read-file-string (%nm proj "left-pad" "package.json"))) "version"))
               ;; the lock was written
               (true (clun.sys:path-exists-p (clun.sys:path-join proj "clun.lock")) "clun.lock written")))
        (ignore-errors (clun.sys:remove-recursive proj))))))

(define-test install/offline-reinstall-byte-identical-lock
  (with-temp-cache (cache)
    (let ((proj (clun.sys:make-temp-dir "/tmp/clun-proj-")))
      (unwind-protect
           (progn
             (%write-package-json proj *install-deps-json*)
             ;; 1. fresh install (populates the temp cache + writes the lock)
             (multiple-value-bind (r1 e1) (%fresh-install proj)
               (declare (ignore r1))
               (false e1))
             (let ((lock1 (clun.sys:read-file-string (clun.sys:path-join proj "clun.lock"))))
               ;; 2. delete node_modules, reinstall OFFLINE (no fixture running) from the lock via cache
               (clun.sys:remove-recursive (clun.sys:path-join proj "node_modules"))
               (let ((result (inst:install proj)))   ; blocking, own loop, NO network
                 (is eq :from-lock (inst:ir-source result) "reused the lock (offline)"))
               (true (%has-pkg proj "left-pad") "layout reproduced offline")
               (true (%has-pkg proj "conflict-b" "node_modules" "shared") "nested dep reproduced offline")
               ;; 3. the lock is byte-identical after the offline reinstall
               (let ((lock2 (clun.sys:read-file-string (clun.sys:path-join proj "clun.lock"))))
                 (is equal lock1 lock2 "clun.lock is byte-identical after offline reinstall"))))
        (ignore-errors (clun.sys:remove-recursive proj))))))

(define-test install/frozen-lockfile-drift-errors
  (with-temp-cache (cache)
    (let ((proj (clun.sys:make-temp-dir "/tmp/clun-proj-")))
      (unwind-protect
           (progn
             (%write-package-json proj *install-deps-json*)
             (multiple-value-bind (r e) (%fresh-install proj) (declare (ignore r)) (false e))
             ;; bump a dep to a range the locked tree cannot satisfy, then --frozen-lockfile must error
             (%write-package-json proj (concatenate 'string
                                        "{\"@scope/widget\":\"^1.0.0\",\"conflict-a\":\"1.0.0\",\"conflict-b\":\"1.0.0\",\"left-pad\":\"^9.0.0\"}"))
             (let ((err (handler-case (progn (inst:install proj :frozen t) nil)
                          (inst:lock-drift-error (c) c)
                          (error (c) c))))
               (true (typep err 'inst:lock-drift-error) "frozen install on a drifted lock errors")))
        (ignore-errors (clun.sys:remove-recursive proj))))))

;;; --- review fixes: dist-tag lock pinning, malformed-input catchability, scoped bins ----

(define-test install/dist-tag-pinned-offline
  ;; a dist-tag dependency ("latest") must reinstall from the lock OFFLINE (pinned once locked),
  ;; not re-resolve/re-hit the network.
  (with-temp-cache (cache)
    (let ((proj (clun.sys:make-temp-dir "/tmp/clun-proj-")))
      (unwind-protect
           (progn
             (%write-package-json proj "{\"left-pad\":\"latest\"}")
             (multiple-value-bind (r e) (%fresh-install proj) (declare (ignore r)) (false e))
             (is equal "1.3.0" (clun.sys:jget (clun.sys:parse-json
                                               (clun.sys:read-file-string (%nm proj "left-pad" "package.json"))) "version")
                 "latest → 1.3.0")
             (clun.sys:remove-recursive (clun.sys:path-join proj "node_modules"))
             (is eq :from-lock (inst:ir-source (inst:install proj)) "dist-tag dep reuses the lock offline"))
        (ignore-errors (clun.sys:remove-recursive proj))))))

(define-test install/malformed-inputs-are-catchable
  ;; §6: a malformed package.json / clun.lock must be a catchable install-error, never a raw json-error.
  (let ((proj (clun.sys:make-temp-dir "/tmp/clun-proj-")))
    (unwind-protect
         (flet ((bytes (s) (map '(simple-array (unsigned-byte 8) (*)) #'char-code s)))
           ;; (a) malformed package.json
           (clun.sys:write-file-octets (clun.sys:path-join proj "package.json") (bytes "{ this is not json ]]"))
           (is eq :install-error
               (handler-case (progn (inst:install proj) :ok)
                 (inst:install-error () :install-error) (error () :raw))
               "malformed package.json → install-error")
           ;; (b) valid package.json + malformed clun.lock (errors in the synchronous prelude, no network)
           (%write-package-json proj "{\"left-pad\":\"^1.0.0\"}")
           (clun.sys:write-file-octets (clun.sys:path-join proj "clun.lock") (bytes "{ broken lock ]["))
           (is eq :install-error
               (handler-case (progn (inst:install proj) :ok)
                 (inst:install-error () :install-error) (error () :raw))
               "malformed clun.lock → install-error")
           ;; (c) a valid-JSON lock whose `packages` is the wrong shape → lock->plan signals install-error
           (is eq :install-error
               (handler-case (progn (inst:lock->plan (clun.sys:parse-json "{\"packages\":\"junk\"}")) :ok)
                 (inst:install-error () :install-error) (error () :raw))
               "malformed lock packages shape → install-error")
           ;; (d) a valid-JSON but NON-OBJECT package.json (array) → catchable install-error on both add
           ;; and install (never a raw TYPE-ERROR out of the editor, never a silent false success). §6.
           (ignore-errors (clun.sys:remove-recursive (clun.sys:path-join proj "clun.lock")))
           (clun.sys:write-file-octets (clun.sys:path-join proj "package.json") (bytes "[1,2,3]"))
           (is eq :install-error
               (handler-case (progn (inst:add-dependencies proj '("left-pad@^1.0.0")) :ok)
                 (inst:install-error () :install-error) (error () :raw))
               "non-object package.json (add) → install-error")
           (is eq :install-error
               (handler-case (progn (inst:install proj) :ok)
                 (inst:install-error () :install-error) (error () :raw))
               "non-object package.json (install) → install-error"))
      (ignore-errors (clun.sys:remove-recursive proj)))))

(define-test install/scoped-bin-in-root-bindir
  ;; a scoped package's bin belongs in node_modules/.bin (on PATH), NOT node_modules/@scope/.bin.
  (let ((root (clun.sys:make-temp-dir "/tmp/clun-bin-")))
    (unwind-protect
         (progn
           (clun.sys:make-directory (clun.sys:path-join root "node_modules/@scope/widget/bin") :recursive t)
           (clun.sys:write-file-octets (clun.sys:path-join root "node_modules/@scope/widget/bin/wdg.js")
                                       (map '(simple-array (unsigned-byte 8) (*)) #'char-code "x"))
           (let ((nodes (make-hash-table :test 'equal)))
             (setf (gethash "@scope/widget@1.0.0" nodes)
                   (inst::make-inst-node :name "@scope/widget" :version "1.0.0" :bin "bin/wdg.js"))
             (inst::%link-bins root (list (cons "node_modules/@scope/widget" "@scope/widget@1.0.0")) nodes))
           (true (clun.sys:path-exists-p (clun.sys:path-join root "node_modules/.bin/widget"))
                 "scoped bin lives in node_modules/.bin")
           (false (clun.sys:path-exists-p (clun.sys:path-join root "node_modules/@scope/.bin/widget"))
                  "not under node_modules/@scope/.bin"))
      (ignore-errors (clun.sys:remove-recursive root)))))

;;; --- dependency-spec residual (#131): optionalDependencies + file: ---------

(define-test install/optional-dep-soft-fail
  "A missing optionalDependency does not fail the install; required deps still land."
  (with-temp-cache (cache)
    (let ((proj (clun.sys:make-temp-dir "/tmp/clun-opt-")))
      (unwind-protect
           (progn
             (clun.sys:write-file-octets
              (clun.sys:path-join proj "package.json")
              (sb-ext:string-to-octets
               (format nil "{\"name\":\"app\",\"version\":\"1.0.0\",\"dependencies\":{\"left-pad\":\"^1.0.0\"},\"optionalDependencies\":{\"no-such-optional-pkg-zzzz\":\"^9.9.9\"}}~%")
               :external-format :utf-8))
             (multiple-value-bind (result err) (%fresh-install proj)
               (false err "optional miss is soft")
               (true (inst:install-result-p result))
               (true (%has-pkg proj "left-pad") "required dep installed")
               (false (%has-pkg proj "no-such-optional-pkg-zzzz") "optional miss skipped")))
        (ignore-errors (clun.sys:remove-recursive proj))))))

(define-test install/file-spec-local-package
  "file: directory packages install by pure-CL recursive copy and reinstall offline."
  (with-temp-cache (cache)
    (let* ((base (clun.sys:make-temp-dir "/tmp/clun-file-"))
           (local (clun.sys:path-join base "local-pkg"))
           (proj (clun.sys:path-join base "app")))
      (unwind-protect
           (progn
             (clun.sys:make-directory local :recursive t :mode #o755)
             (clun.sys:make-directory proj :recursive t :mode #o755)
             (clun.sys:write-file-octets
              (clun.sys:path-join local "package.json")
              (sb-ext:string-to-octets
               (format nil "{\"name\":\"local-pkg\",\"version\":\"1.2.3\",\"main\":\"index.js\"}~%")
               :external-format :utf-8))
             (clun.sys:write-file-octets
              (clun.sys:path-join local "index.js")
              (sb-ext:string-to-octets "module.exports = 'from-file';
" :external-format :utf-8))
             (clun.sys:write-file-octets
              (clun.sys:path-join proj "package.json")
              (sb-ext:string-to-octets
               (format nil "{\"name\":\"app\",\"version\":\"1.0.0\",\"dependencies\":{\"local-pkg\":\"file:../local-pkg\",\"left-pad\":\"1.3.0\"}}~%")
               :external-format :utf-8))
             (multiple-value-bind (result err) (%fresh-install proj)
               (false err)
               (true (inst:install-result-p result))
               (true (%has-pkg proj "local-pkg") "file: package copied")
               (true (%has-pkg proj "left-pad") "registry dep still works")
               (is equal "1.2.3"
                   (clun.sys:jget (clun.sys:parse-json
                                   (clun.sys:read-file-string
                                    (%nm proj "local-pkg" "package.json")))
                                  "version"))
               (true (search "from-file"
                             (clun.sys:read-file-string (%nm proj "local-pkg" "index.js")))
                     "file: package body copied")
               ;; offline reinstall from lock
               (let ((lock1 (clun.sys:read-file-string (clun.sys:path-join proj "clun.lock"))))
                 (clun.sys:remove-recursive (clun.sys:path-join proj "node_modules"))
                 (is eq :from-lock (inst:ir-source (inst:install proj)))
                 (true (%has-pkg proj "local-pkg") "file: package restored offline")
                 (is equal lock1 (clun.sys:read-file-string (clun.sys:path-join proj "clun.lock"))))))
        (ignore-errors (clun.sys:remove-recursive base))))))
