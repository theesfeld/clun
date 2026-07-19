;;;; lockfile.lisp — clun.lock read/write + freshness + drift (PLAN.md Phase 23, §3.5). A versioned
;;;; JSON lock (deterministic key order via clun.sys:write-json :sort-keys) recording, per install
;;;; path, the resolved version + tarball URL + integrity + deps + bin — enough to reinstall OFFLINE
;;;; from the content-addressed cache. `--frozen-lockfile` errors on drift. Pure CL.

(in-package :clun.installer)

(defparameter +lockfile-version+ 1)
(defparameter +lockfile-name+ "clun.lock")

(defun %lock-path (root) (sys:path-join root +lockfile-name+))

(defun name-from-physical (physical)
  "The package name for an install dir, e.g. node_modules/@scope/widget → @scope/widget, and a
nested node_modules/a/node_modules/b → b (everything after the LAST node_modules/)."
  (let ((pos (search "node_modules/" physical :from-end t)))
    (if pos (subseq physical (+ pos (length "node_modules/"))) physical)))

(defun %lock-entry (node)
  (let ((e (list (cons "version" (in-version node))
                 (cons "resolved" (or (in-tarball node) ""))
                 (cons "integrity" (or (in-integrity node) ""))
                 (cons "dependencies" (or (in-deps node) :empty-object)))))
    (when (and (in-bin node) (not (eq (in-bin node) :empty-object)))
      (setf e (append e (list (cons "bin" (in-bin node))))))
    e))

(defun lock-value (plan nodes)
  "Build the parsed-JSON value for the lock from PLAN + NODES."
  (list (cons "lockfileVersion" +lockfile-version+)
        (cons "packages"
              (or (loop for (physical . key) in plan
                        for node = (gethash key nodes)
                        when node collect (cons physical (%lock-entry node)))
                  :empty-object))))

(defun write-lock (root plan nodes)
  "Write ROOT/clun.lock deterministically (sorted keys, 2-space indent, trailing newline)."
  (let ((text (concatenate 'string (sys:write-json (lock-value plan nodes) :indent 2 :sort-keys t)
                           (string #\Newline))))
    (sys:write-file-octets (%lock-path root)
                           (sb-ext:string-to-octets text :external-format :utf-8))
    text))

(defun read-lock (root)
  "Parse ROOT/clun.lock, or NIL if absent. A present-but-malformed lock signals install-error (never a
raw json-error — §6: a malformed lock must be catchable)."
  (let ((path (%lock-path root)))
    (when (sys:path-exists-p path)
      (handler-case (sys:parse-json (sys:read-file-string path))
        (sys:json-error (e) (error 'install-error :message (format nil "malformed clun.lock: ~a" e)))))))

(defun %packages-object (lock)
  "LOCK's `packages` as a proper (path . entry) alist, or NIL for empty / absent / a structurally
wrong shape (a string/array/number — a corrupt or foreign lock). Never signals."
  (let ((p (sys:jget lock "packages")))
    (cond ((or (null p) (eq p :empty-object)) nil)
          ((and (consp p) (consp (car p)) (stringp (caar p))) p)
          (t :malformed))))

(defun lock->plan (lock)
  "Reconstruct (values PLAN NODES) from a parsed LOCK for an OFFLINE reinstall (resolved URL +
integrity + deps + bin per install path). Signals install-error on a structurally malformed lock;
skips an entry whose value is not an object or whose version is not a string."
  (let ((plan '()) (nodes (make-hash-table :test 'equal))
        (packages (%packages-object lock)))
    (when (eq packages :malformed)
      (error 'install-error :message "malformed clun.lock: 'packages' is not an object"))
    (when packages
      (dolist (entry packages)
        (when (and (consp entry) (stringp (car entry)) (consp (cdr entry)))
          (destructuring-bind (physical . obj) entry
            (let ((version (sys:jget obj "version")))
              (when (stringp version)
                (let* ((name (name-from-physical physical))
                       (deps (let ((d (sys:jget obj "dependencies"))) (if (eq d :empty-object) '() (or d '()))))
                       (bin (let ((b (sys:jget obj "bin"))) (if (eq b :empty-object) nil b)))
                       (resolved (sys:jget obj "resolved"))
                       (file-p (and (stringp resolved) (>= (length resolved) 5)
                                    (string= "file:" resolved :end2 5)))
                       (local (when file-p (subseq resolved 5))))
                  (setf (gethash (format nil "~a@~a" name version) nodes)
                        (make-inst-node :name name :version version :deps deps
                                        :tarball resolved
                                        :integrity (or (sys:jget obj "integrity") "")
                                        :bin bin
                                        :kind (cond (file-p :file)
                                                    ((and (stringp resolved)
                                                          (or (and (>= (length resolved) 8)
                                                                   (string-equal "https://" resolved :end2 8))
                                                              (and (>= (length resolved) 7)
                                                                   (string-equal "http://" resolved :end2 7))))
                                                     :url)
                                                    (t :registry))
                                        :local-path local
                                        :real-name name))
                  (push (cons physical (format nil "~a@~a" name version)) plan))))))))
    (values (nreverse plan) nodes)))

(defun lock-satisfies-p (lock root-deps)
  "T iff LOCK is a usable object AND has a root-level (hoisted) version for every required ROOT-DEPS
name that satisfies its range — the freshness/no-drift test. Optional entries are ignored (they may
be absent after soft-fail). A non-semver range (dist-tag, file:, npm:, URL) is considered pinned once
locked. A malformed lock is simply not fresh (→ re-resolve, or drift under --frozen); it never raises
a raw error."
  (let ((packages (%packages-object lock)))
    (and packages (not (eq packages :malformed))
         (every (lambda (d)
                  (if (%dep-optional-p d)
                      t
                      (let* ((name (%dep-name d))
                             (range (%dep-range d))
                             (obj (cdr (assoc (format nil "node_modules/~a" name) packages
                                              :test #'string=))))
                        (and (consp obj)
                             (let ((v (sys:jget obj "version")))
                               (and (stringp v)
                                    (let ((class (ignore-errors (classify-dep-spec range))))
                                      (cond
                                        ((null class) nil)
                                        ((eq (first class) :range)
                                         (or (not (sv:range-valid-p range))
                                             (sv:version-satisfies v range)))
                                        (t t)))))))))  ; file:/npm:/url — pin once locked
                root-deps))))
