;;;; installer.lisp — the top-level `install` orchestration (PLAN.md Phase 23, §3.5): read the root
;;;; package.json's deps, resolve → plan-layout → link → write-lock, OR (when the lock is fresh, or
;;;; under --frozen-lockfile) reinstall from the lock via the content-addressed cache (offline). One
;;;; event loop drives resolution + downloads. Pure CL.

(in-package :clun.installer)

(defun %obj->alist (v)
  "A parsed-JSON object → a plain (name . value) alist; NIL for the empty object / a non-object."
  (cond ((eq v :empty-object) '())
        ((and (consp v) (consp (car v))) (loop for (k . val) in v collect (cons k val)))
        (t '())))

(defun read-package-json (root)
  (let ((path (sys:path-join root "package.json")))
    (unless (sys:path-exists-p path)
      (error 'install-error :message (format nil "no package.json in ~a" root)))
    (let ((v (handler-case (sys:parse-json (sys:read-file-string path))
               (sys:json-error (e)
                 (error 'install-error :message (format nil "malformed package.json in ~a: ~a" root e))))))
      ;; the top level must be a JSON OBJECT — a scalar/array is valid JSON but not a package.json,
      ;; and would otherwise crash the editor (add) or silently no-op (remove/install). §6.
      (unless (or (eq v :empty-object) (and (consp v) (consp (car v))))
        (error 'install-error :message (format nil "package.json in ~a must be a JSON object" root)))
      v)))

(defun root-deps (pkg &key production)
  "The root dependency set: `dependencies` plus (unless PRODUCTION) `devDependencies`, as an alist of
(name . range). A name in both prefers `dependencies`."
  (let* ((deps (%obj->alist (sys:jget pkg "dependencies")))
         (dev (unless production (%obj->alist (sys:jget pkg "devDependencies")))))
    (append deps (remove-if (lambda (d) (assoc (car d) deps :test #'string=)) dev))))

(defstruct (install-result (:conc-name ir-))
  (source :resolved)                    ; :resolved (fresh) | :from-lock (reused)
  (plan '()) (node-count 0) (lifecycle-skipped '()))

;;; --- package.json editing (add / remove) ------------------------------------

(defun %parse-name-spec (spec)
  "Split a dep spec into (values name range-or-nil): `pkg`, `pkg@range`, `@scope/pkg`,
`@scope/pkg@range`. The leading `@` of a scope is not a range separator."
  (let ((start (if (and (plusp (length spec)) (char= (char spec 0) #\@)) 1 0)))
    (let ((at (position #\@ spec :start start)))
      (if at (values (subseq spec 0 at) (subseq spec (1+ at))) (values spec nil)))))

(defun %set-pkg-field (pkg field value)
  "Return PKG (a parsed-JSON object alist) with FIELD set to VALUE — replacing in place (order-
preserving) or appending; :empty-object PKG becomes a fresh alist."
  (let ((pkg (if (eq pkg :empty-object) '() pkg)))
    (if (assoc field pkg :test #'string=)
        (mapcar (lambda (c) (if (string= (car c) field) (cons field value) c)) pkg)
        (append pkg (list (cons field value))))))

(defun %write-package-json-file (root pkg)
  "Write PKG back to ROOT/package.json (2-space indent, key order preserved, trailing newline)."
  (sys:write-file-octets
   (sys:path-join root "package.json")
   (sb-ext:string-to-octets (concatenate 'string (sys:write-json pkg :indent 2) (string #\Newline))
                            :external-format :utf-8)))

(defun resolve-latest-async (loop name &key registry (retries 1) on-ok on-err)
  "Fetch NAME's `latest` dist-tag version (or the highest) over LOOP. ON-OK with the version string."
  (reg:fetch-metadata-async loop name :override registry :retries retries
    :on-ok (lambda (md)
             (let ((v (or (reg:metadata-latest md) (pick-version md "*"))))
               (if v (when on-ok (funcall on-ok v))
                   (when on-err (funcall on-err (make-condition 'install-error
                                 :message (format nil "no versions of ~a" name)))))))
    :on-err (lambda (e) (when on-err (funcall on-err e)))))

(defun resolve-latest (name &key registry)
  "Blocking: NAME's latest version via the registry (own loop — CLI use, no concurrent loop)."
  (let ((loop (lp:make-event-loop :workers 0)) (ver nil) (err nil))
    (unwind-protect
         (progn
           (resolve-latest-async loop name :registry registry
             :on-ok (lambda (v) (setf ver v) (lp:loop-stop loop))
             :on-err (lambda (e) (setf err e) (lp:loop-stop loop)))
           (lp:run-loop loop))
      (lp:destroy-event-loop loop))
    (if err (error err) ver)))

(defun add-dependencies (root names &key dev exact registry)
  "Add NAMES (each `pkg` or `pkg@range`) to ROOT/package.json's dependencies (or devDependencies if
DEV) and rewrite the file. A bare name resolves to the registry's latest as `^version` (or exact
`version`). Returns the (name . range) list added."
  (let* ((pkg (read-package-json root))
         (field (if dev "devDependencies" "dependencies"))
         (added (loop for spec in names collect
                      (multiple-value-bind (name range) (%parse-name-spec spec)
                        (cons name (cond (range range)
                                         (t (let ((v (resolve-latest name :registry registry)))
                                              (if exact v (concatenate 'string "^" v))))))))))
    (let ((merged (%obj->alist (sys:jget pkg field))))
      (dolist (nd added)
        (let ((cell (assoc (car nd) merged :test #'string=)))
          (if cell (setf (cdr cell) (cdr nd)) (setf merged (append merged (list nd))))))
      (%write-package-json-file root (%set-pkg-field pkg field (or merged :empty-object))))
    added))

(defun remove-dependencies (root names)
  "Remove NAMES from every dependency field of ROOT/package.json and rewrite it. Returns the names
that were present."
  (let ((pkg (read-package-json root)) (removed '()))
    (dolist (field '("dependencies" "devDependencies" "optionalDependencies" "peerDependencies"))
      (let ((existing (sys:jget pkg field)))
        (when (and (consp existing) (consp (car existing)))
          (dolist (n names) (when (assoc n existing :test #'string=) (pushnew n removed :test #'string=)))
          (let ((filtered (remove-if (lambda (c) (member (car c) names :test #'string=)) existing)))
            (setf pkg (%set-pkg-field pkg field (or filtered :empty-object)))))))
    (%write-package-json-file root pkg)
    (nreverse removed)))

(defun install-async (loop root &key registry frozen production on-ok on-err)
  "Async core of `install`, driving the CALLER's LOOP (so a hermetic test can share the fixture
registry's loop — a second concurrent event loop is avoided). Reads ROOT/package.json + clun.lock
synchronously (may signal for a missing package.json), then either reinstalls from a fresh lock / under
--frozen (offline-capable via the cache) or resolves fresh over REGISTRY and writes the lock. Calls
ON-OK with an install-result, or ON-ERR with a condition. The synchronous prelude (reading + shape-
checking package.json / clun.lock) is wrapped so a malformed input reaches ON-ERR as an install-error
rather than a raw condition escaping onto the caller's loop (§6)."
  (handler-case
   (let* ((pkg (read-package-json root))
          (deps (root-deps pkg :production production))
          (lock (read-lock root)))
    (labels ((from-lock ()
               (multiple-value-bind (plan nodes) (lock->plan lock)
                 (link-plan loop root plan nodes
                   :on-ok (lambda () (when on-ok
                                       (funcall on-ok (make-install-result :source :from-lock :plan plan
                                                                           :node-count (hash-table-count nodes)))))
                   :on-err (lambda (e) (when on-err (funcall on-err e))))))
             (resolve-fresh ()
               (resolve-install loop deps :registry registry
                 :on-ok (lambda (nodes ev)
                          (handler-case
                              (let ((plan (plan-layout nodes ev deps)))
                                (link-plan loop root plan nodes
                                  :on-ok (lambda ()
                                           (write-lock root plan nodes)
                                           (when on-ok
                                             (funcall on-ok (make-install-result
                                                             :source :resolved :plan plan
                                                             :node-count (hash-table-count nodes)
                                                             :lifecycle-skipped (%collect-lifecycle-scripts plan nodes)))))
                                  :on-err (lambda (e) (when on-err (funcall on-err e)))))
                            (error (e) (when on-err (funcall on-err e)))))
                 :on-err (lambda (e) (when on-err (funcall on-err e))))))
      (cond
        (frozen
         (cond ((null lock)
                (when on-err (funcall on-err (make-condition 'lock-drift-error
                              :message "no clun.lock; --frozen-lockfile requires an up-to-date lock"))))
               ((not (lock-satisfies-p lock deps))
                (when on-err (funcall on-err (make-condition 'lock-drift-error
                              :message "clun.lock is out of date with package.json (--frozen-lockfile)"))))
               (t (from-lock))))
        ((and lock (lock-satisfies-p lock deps)) (from-lock))
        (t (resolve-fresh)))))
   (install-error (e) (when on-err (funcall on-err e)))
   (error (e) (when on-err (funcall on-err (make-condition 'install-error
                            :message (format nil "install setup failed: ~a" e)))))))

(defun install (root &key registry frozen production)
  "Blocking install: create a private event loop, run install-async to settlement, and RETURN the
install-result — or SIGNAL install-error / lock-drift-error / a transport error. Use install-async on
a shared loop when the registry runs in-process (a hermetic test)."
  (let ((loop (lp:make-event-loop :workers 0)) (result nil) (err nil) (settled nil))
    (unwind-protect
         (progn
           (handler-case
               (install-async loop root :registry registry :frozen frozen :production production
                 :on-ok (lambda (r) (setf result r settled t) (lp:loop-stop loop))
                 :on-err (lambda (e) (setf err e settled t) (lp:loop-stop loop)))
             (error (e) (setf err e settled t)))
           (unless settled (lp:run-loop loop)))
      (lp:destroy-event-loop loop))
    (if err (error err) result)))
