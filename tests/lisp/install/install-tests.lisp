;;;; install-tests.lisp — Phase 23 milestone 1b: the hermetic install e2e against the Phase-21 fixture
;;;; registry. A fresh install resolves the diamond, downloads + extracts into a hoisted node_modules,
;;;; and writes clun.lock; deleting node_modules and reinstalling OFFLINE from the lock (via the
;;;; content-addressed cache, fixture down) reproduces the layout + a BYTE-IDENTICAL lock;
;;;; --frozen-lockfile errors on drift. CLUN_CACHE is pointed at a temp dir per test (hermetic).

(in-package :clun-test)

(defparameter *install-deps-json*
  "{\"@scope/widget\":\"^1.0.0\",\"conflict-a\":\"1.0.0\",\"conflict-b\":\"1.0.0\"}")

(defparameter *six-node-install-graph*
  '(("node_modules/@scope/widget" . "@scope/widget@1.0.0")
    ("node_modules/conflict-a" . "conflict-a@1.0.0")
    ("node_modules/conflict-b" . "conflict-b@1.0.0")
    ("node_modules/conflict-b/node_modules/shared" . "shared@2.0.0")
    ("node_modules/left-pad" . "left-pad@1.3.0")
    ("node_modules/shared" . "shared@1.0.0")))

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

(defun %six-node-layout-snapshot (dir plan)
  "Return PLAN's exact physical-path/installed-name@version graph for manifests that really exist.
Parsing the extracted package.json bytes proves the complete layout contains valid package
manifests and does not merely borrow package identity from the resolver's plan."
  (sort (loop for placement in plan
              for physical = (car placement)
              for manifest = (sys:path-join dir physical "package.json")
              when (sys:file-p manifest)
                collect (let* ((pkg (sys:parse-json (sys:read-file-string manifest)))
                               (name (sys:jget pkg "name"))
                               (version (sys:jget pkg "version")))
                          (unless (and (stringp name) (stringp version))
                            (error "installed package manifest lacks string name/version: ~a"
                                   manifest))
                          (cons physical (format nil "~a@~a" name version))))
        #'string< :key #'car))

(defun %direct-link-one (root bytes integrity &key defer-completion)
  "Synchronously link one registry-style fixture node and return OK/ERR/error/download counts.
The downloader hook makes callback timing deterministic while exercising LINK-PLAN's real payload
cache/spool and extraction paths. When DEFER-COMPLETION is true, invoke the captured success
callback only after LINK-PLAN has returned so tests cover the asynchronous settled path."
  (let ((loop (lp:make-event-loop :workers 0))
        (nodes (make-hash-table :test 'equal))
        (ok-count 0) (err-count 0) (caught nil) (downloads 0)
        (deferred-ok nil) (pre-ok-count nil) (pre-err-count nil))
    (setf (gethash "shared@2.0.0" nodes)
          (inst::make-inst-node :name "shared" :version "2.0.0" :deps '()
                                :tarball "https://fixture.invalid/shared-2.0.0.tgz"
                                :integrity integrity :kind :registry))
    (unwind-protect
         (let ((inst::*tarball-download-function*
                 (lambda (ignored-loop ignored-url &key on-ok on-err)
                   (declare (ignore ignored-loop ignored-url on-err))
                   (incf downloads)
                   (if defer-completion
                       (setf deferred-ok on-ok)
                       (funcall on-ok bytes)))))
           (inst:link-plan loop root
                           '(("node_modules/shared" . "shared@2.0.0")) nodes
                           :on-ok (lambda () (incf ok-count))
                           :on-err (lambda (e) (incf err-count) (setf caught e)))
           (setf pre-ok-count ok-count pre-err-count err-count)
           (when defer-completion
             (unless deferred-ok (error "deferred downloader did not capture ON-OK"))
             (funcall deferred-ok bytes)))
      (lp:destroy-event-loop loop))
    (values ok-count err-count caught downloads pre-ok-count pre-err-count)))

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

(define-test install/forced-download-order-matches-lockfile-layout
  ;; Pre-cache ONLY nested shared@2 so it is ready synchronously while its conflict-b parent still
  ;; requires an async download. Extracting immediately on readiness loses the nested package when
  ;; the parent extractor later replaces node_modules/conflict-b. Fresh and lockfile paths must
  ;; instead materialise the same complete graph in plan order.
  (with-temp-cache (cache)
    (let* ((proj (sys:make-temp-dir "/tmp/clun-proj-forced-order-"))
           (fixture (load-fixture-registry "http://127.0.0.1:1"))
           (child-bytes (gethash "shared-2.0.0.tgz" (fixture-registry-tarballs fixture)))
           (child-integrity (tarball-integrity child-bytes))
           (real-downloader inst::*tarball-download-function*)
           (downloaded '())
           (fresh-plan nil))
      (labels ((recording-downloader (loop url &key on-ok on-err)
                 (push url downloaded)
                 (funcall real-downloader loop url :on-ok on-ok :on-err on-err)))
        (unwind-protect
             (progn
               (true child-bytes "shared@2 fixture tarball exists")
               (tb:cache-store child-integrity child-bytes)
               (true (tb:cache-fetch child-integrity) "only nested shared@2 is pre-cached")
               (%write-package-json proj *install-deps-json*)
               (multiple-value-bind (fresh-result fresh-error)
                   (let ((inst::*tarball-download-function* #'recording-downloader))
                     (%fresh-install proj))
                 (false fresh-error)
                 (is eq :resolved (inst:ir-source fresh-result))
                 (is = 6 (inst:ir-node-count fresh-result) "fresh path resolved six nodes")
                 (setf fresh-plan (inst:ir-plan fresh-result))
                 (is = 6 (length fresh-plan) "fresh path planned six placements"))
               (false (find-if (lambda (url) (search "/shared-2.0.0.tgz" url)) downloaded)
                      "nested shared@2 was ready from cache, without a download")
               (true (find-if (lambda (url) (search "/conflict-b-1.0.0.tgz" url)) downloaded)
                     "conflict-b parent required an async download")
               (let ((fresh-layout (%six-node-layout-snapshot proj fresh-plan))
                     (lock-before (sys:read-file-string (sys:path-join proj "clun.lock"))))
                 (is equal *six-node-install-graph* fresh-layout
                     "cache-first child install materialises the complete conflict-preserving graph")
                 (sys:remove-recursive (sys:path-join proj "node_modules"))
                 ;; JSON object order is not semantic. Reverse every package member so the nested
                 ;; child is presented before conflict-b, then prove the linker projects that
                 ;; arbitrary lock plan to ancestor-before-descendant commit order.
                 (let* ((lock-path (sys:path-join proj "clun.lock"))
                        (lock-value (sys:parse-json lock-before))
                        (packages-pair (assoc "packages" lock-value :test #'string=)))
                   (true packages-pair "lockfile contains a packages object")
                   (setf (cdr packages-pair) (reverse (cdr packages-pair)))
                   (let ((reordered-lock
                           (concatenate 'string
                                        (sys:write-json lock-value :indent 2 :sort-keys nil)
                                        (string #\Newline))))
                     (isnt equal lock-before reordered-lock
                           "reversed lockfile is byte-distinct but semantically equivalent")
                     (sys:write-file-octets
                      lock-path
                      (sb-ext:string-to-octets reordered-lock :external-format :utf-8))
                     (let ((lock-result (inst:install proj)))
                       (is eq :from-lock (inst:ir-source lock-result))
                       (is = 6 (inst:ir-node-count lock-result) "lockfile path reconstructs six nodes")
                       (is = 6 (length (inst:ir-plan lock-result)) "lockfile path plans six placements")
                       (true (< (position "node_modules/conflict-b/node_modules/shared"
                                          (inst:ir-plan lock-result) :test #'string= :key #'car)
                                (position "node_modules/conflict-b"
                                          (inst:ir-plan lock-result) :test #'string= :key #'car))
                             "input lock plan really presents the nested child before its parent")
                       (let ((lock-layout (%six-node-layout-snapshot proj (inst:ir-plan lock-result))))
                         (is equal *six-node-install-graph* lock-layout
                             "reverse-order lock replay materialises the exact complete six-node graph")
                         (is equal fresh-layout lock-layout
                             "fresh and lockfile paths materialise identical six-node layouts")))
                     (is equal reordered-lock (sys:read-file-string lock-path)
                         "lockfile reuse preserves the caller's byte order")))))
          (ignore-errors (sys:remove-recursive proj)))))))

(define-test install/ready-payload-spool-is-lazy-clean-and-callback-safe
  (with-temp-cache (cache)
    (let* ((fixture (load-fixture-registry "http://127.0.0.1:1"))
           (bytes (gethash "shared-2.0.0.tgz" (fixture-registry-tarballs fixture)))
           (integrity (tarball-integrity bytes))
           (scratch (sys:make-temp-dir "/tmp/clun-link-spool-test-"))
           (spool-root (sys:path-join scratch "spool"))
           (invalid-tmp (sys:path-join scratch "not-a-directory"))
           (old-tmpdir (sb-ext:posix-getenv "TMPDIR")))
      (unwind-protect
           (progn
             (sys:make-directory spool-root :recursive t :mode #o755)
             (sys:write-file-octets invalid-tmp
                                    (sb-ext:string-to-octets "file" :external-format :utf-8))
             ;; No integrity means no content-addressed cache path. A synchronous completion must
             ;; spool, read/extract, clean its private directory, and report success exactly once.
             (sb-posix:setenv "TMPDIR" spool-root 1)
             (let ((root (sys:path-join scratch "uncached")))
               (sys:make-directory root :recursive t :mode #o755)
               (multiple-value-bind (ok errors caught downloads)
                   (%direct-link-one root bytes "")
                 (is = 1 ok)
                 (is = 0 errors)
                 (false caught)
                 (is = 1 downloads)
                 (is equal "2.0.0"
                     (sys:jget (sys:parse-json
                                (sys:read-file-string
                                 (sys:path-join root "node_modules/shared/package.json")))
                               "version"))
                 (is = 0 (length (sys:read-directory spool-root))
                     "private ready-payload spool is removed after success")))
             ;; A verified cache-only install must not touch TMPDIR at all.
             (tb:cache-store integrity bytes)
             (sb-posix:setenv "TMPDIR" invalid-tmp 1)
             (let ((root (sys:path-join scratch "cached")))
               (sys:make-directory root :recursive t :mode #o755)
               (multiple-value-bind (ok errors caught downloads)
                   (%direct-link-one root bytes integrity)
                 (is = 1 ok)
                 (is = 0 errors)
                 (false caught)
                 (is = 0 downloads "cache-only materialisation does not acquire TMPDIR")))
             ;; If a no-integrity spool cannot be created, a deferred callback after LINK-PLAN
             ;; returns still settles through ON-ERR exactly once; it must not hang or falsely succeed.
             (let ((root (sys:path-join scratch "spool-failure")))
               (sys:make-directory root :recursive t :mode #o755)
               (multiple-value-bind (ok errors caught downloads pre-ok pre-errors)
                   (%direct-link-one root bytes "" :defer-completion t)
                 (is = 0 pre-ok "deferred response does not report early success")
                 (is = 0 pre-errors "deferred response does not report an error before completion")
                 (is = 0 ok)
                 (is = 1 errors)
                 (true caught)
                 (is = 1 downloads)
                 (false (sys:path-exists-p
                         (sys:path-join root "node_modules/shared/package.json"))))))
        (if old-tmpdir
            (sb-posix:setenv "TMPDIR" old-tmpdir 1)
            (ignore-errors (sb-posix:unsetenv "TMPDIR")))
        (ignore-errors (sys:remove-recursive scratch))))))

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

(define-test install/file-and-alias-e2e
  "file: local package + npm: alias install through the full link path and are require()-able."
  (with-temp-cache (cache)
    (let ((proj (clun.sys:make-temp-dir "/tmp/clun-spec-")))
      (unwind-protect
           (progn
             (clun.sys:make-directory (clun.sys:path-join proj "vendor" "local-pkg")
                                      :recursive t :mode #o755)
             (clun.sys:write-file-octets
              (clun.sys:path-join proj "vendor" "local-pkg" "package.json")
              (sb-ext:string-to-octets
               "{\"name\":\"local-pkg\",\"version\":\"9.9.9\"}"
               :external-format :utf-8))
             (clun.sys:write-file-octets
              (clun.sys:path-join proj "vendor" "local-pkg" "index.js")
              (map '(simple-array (unsigned-byte 8) (*)) #'char-code
                   "module.exports='local-pkg@9.9.9';"))
             (%write-package-json
              proj
              (format nil "{\"pad\":\"npm:left-pad@1.3.0\",\"local-pkg\":\"file:./vendor/local-pkg\"}"))
             (multiple-value-bind (result err) (%fresh-install proj)
               (false err)
               (true (inst:install-result-p result))
               (true (%has-pkg proj "pad") "alias pad installed")
               (true (%has-pkg proj "local-pkg") "file: local-pkg installed")
               (is equal "1.3.0"
                   (clun.sys:jget (clun.sys:parse-json
                                   (clun.sys:read-file-string (%nm proj "pad" "package.json")))
                                  "version"))
               (is equal "9.9.9"
                   (clun.sys:jget (clun.sys:parse-json
                                   (clun.sys:read-file-string (%nm proj "local-pkg" "package.json")))
                                  "version"))
               (true (clun.sys:path-exists-p (clun.sys:path-join proj "clun.lock")))))
        (ignore-errors (clun.sys:remove-recursive proj))))))

(define-test install/optional-missing-does-not-fail
  (with-temp-cache (cache)
    (let ((proj (clun.sys:make-temp-dir "/tmp/clun-opt-")))
      (unwind-protect
           (progn
             (clun.sys:write-file-octets
              (clun.sys:path-join proj "package.json")
              (sb-ext:string-to-octets
               (format nil "{\"name\":\"root\",\"version\":\"1.0.0\",~
\"dependencies\":{\"left-pad\":\"1.3.0\"},~
\"optionalDependencies\":{\"does-not-exist-xyz\":\"1.0.0\"}}~%")
               :external-format :utf-8))
             (multiple-value-bind (result err) (%fresh-install proj)
               (false err "optional miss soft-fails")
               (true (inst:install-result-p result))
               (true (%has-pkg proj "left-pad"))
               (false (%has-pkg proj "does-not-exist-xyz"))))
        (ignore-errors (clun.sys:remove-recursive proj))))))
