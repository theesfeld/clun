;;;; resolver.lisp — dependency resolution + hoisted-layout placement (PLAN.md Phase 23, §3.5).
;;;; Breadth-first, highest-satisfying, cycle-safe resolution over the Phase-21 async registry
;;;; client; then a placement pass that hoists the first-seen version of each name to the root
;;;; node_modules and nests genuine version conflicts. Pure CL, no engine.
;;;;
;;;; Dependency-spec residual (#131): registry semver/dist-tags/scoped names, optionalDependencies
;;;; (soft-fail), and local `file:` directory packages. Git/workspace/catalog remain Phase 59–60.

(in-package :clun.installer)

(define-condition install-error (error)
  ((message :initarg :message :reader install-error-message :initform "install error"))
  (:report (lambda (c s) (write-string (install-error-message c) s))))

(define-condition lock-drift-error (install-error) ()
  (:documentation "Signalled under --frozen-lockfile when resolution would change the lockfile."))

;;; A resolved package: a concrete (name, version) with the metadata install needs.
(defstruct (inst-node (:conc-name in-))
  name version
  (deps '())                            ; alist (dep-name . range) from the version metadata
  tarball integrity bin)                ; dist.tarball / file: path, dist.integrity, bin

(defun pick-version (md range)
  "The version string of MD (a pkg-metadata) to install for RANGE: a matching dist-tag name resolves
directly (e.g. \"latest\"), else the HIGHEST semver version satisfying RANGE. NIL if none match."
  (let ((tag (cdr (assoc range (reg:md-dist-tags md) :test #'string=))))
    (or tag
        (let ((best nil))
          (dolist (v (reg:metadata-version-strings md) best)
            (when (and (sv:version-satisfies v range)
                       (or (null best) (plusp (sv:version-compare v best))))
              (setf best v)))))))

;;; --- dependency-spec helpers ------------------------------------------------

(defun file-spec-p (range)
  "T iff RANGE is a local `file:` dependency specification."
  (and (stringp range) (>= (length range) 5) (string= "file:" range :end2 5)))

(defun file-spec-path (range)
  "The path component of a `file:` RANGE (may be relative)."
  (subseq range 5))

(defun resolve-file-path (root range)
  "Absolute path for a `file:` RANGE relative to project ROOT."
  (let ((p (file-spec-path range)))
    (if (sys:absolute-path-p p)
        (sys:normalize-path p)
        (sys:normalize-path (sys:path-join root p)))))

(defun %read-local-package (abs-path)
  "Read ABS-PATH/package.json → (values name version deps bin) or signal install-error."
  (let ((pj (sys:path-join abs-path "package.json")))
    (unless (sys:path-exists-p pj)
      (error 'install-error :message (format nil "file: package missing package.json: ~a" abs-path)))
    (unless (sys:directory-p abs-path)
      (error 'install-error :message (format nil "file: target is not a directory: ~a" abs-path)))
    (let* ((pkg (handler-case (sys:parse-json (sys:read-file-string pj))
                  (sys:json-error (e)
                    (error 'install-error
                           :message (format nil "malformed package.json in ~a: ~a" abs-path e)))))
           (name (and (sys:jobject-p pkg) (sys:jget pkg "name")))
           (version (and (sys:jobject-p pkg) (sys:jget pkg "version")))
           (deps (and (sys:jobject-p pkg)
                      (let ((d (sys:jget pkg "dependencies")))
                        (cond ((eq d :empty-object) '())
                              ((and (consp d) (consp (car d)))
                               (loop for (k . v) in d collect (cons k (if (stringp v) v ""))))
                              (t '())))))
           (bin (and (sys:jobject-p pkg) (sys:jget pkg "bin"))))
      (unless (stringp name)
        (error 'install-error :message (format nil "file: package.json missing name: ~a" abs-path)))
      (values name
              (if (stringp version) version "0.0.0")
              (or deps '())
              (cond ((stringp bin) bin)
                    ((eq bin :empty-object) nil)
                    ((and (consp bin) (consp (car bin))) bin)
                    (t nil))))))

;;; --- resolution (async, breadth-first) --------------------------------------

(defun %edge-key (parent-key dep-name)
  (concatenate 'string parent-key "|" dep-name))

(defun resolve-install (loop root-deps &key registry root (retries 1) optional-names on-ok on-err)
  "Resolve ROOT-DEPS (an alist of (name . range)) transitively. Supports registry ranges/dist-tags
and local `file:` directory packages (ROOT required for relative file: paths). OPTIONAL-NAMES is a
list of root dep names whose failure is soft (skipped). Fetches each package's abbreviated metadata
ONCE (cached per name) via the async registry client, picks the highest satisfying version per edge,
and records the graph. Cycle-safe. Calls ON-OK with (values NODES EDGE-VERSION) or ON-ERR."
  (let ((meta (make-hash-table :test 'equal))     ; name → pkg-metadata
        (nodes (make-hash-table :test 'equal))     ; "name@version" → inst-node
        (edge-version (make-hash-table :test 'equal))  ; "<parent>|<dep>" → version
        (optional (make-hash-table :test 'equal))
        (pending 0) (err nil) (finished nil))
    (dolist (n optional-names) (setf (gethash n optional) t))
    (labels
        ((finish ()
           (when (and (not finished) (zerop pending))
             (setf finished t)
             (if err
                 (when on-err (funcall on-err err))
                 (when on-ok (funcall on-ok nodes edge-version)))))
         (fail (e) (unless err (setf err (if (typep e 'condition) e
                                             (make-condition 'install-error :message (princ-to-string e))))))
         (soft-or-fail (optional-p e)
           (unless optional-p (fail e)))
         (need-meta (name k &key optional-p)
           (unless err
             (let ((m (gethash name meta)))
               (if m
                   (funcall k m)
                   (progn
                     (incf pending)
                     (reg:fetch-metadata-async loop name :override registry :retries retries
                       :on-ok (lambda (md)
                                (setf (gethash name meta) md)
                                (decf pending)
                                (unless err (funcall k md))
                                (finish))
                       :on-err (lambda (e)
                                 (decf pending)
                                 (soft-or-fail optional-p e)
                                 (finish))))))))
         (record-node (parent-key name ver deps tarball integrity bin)
           (let ((key (format nil "~a@~a" name ver)))
             (setf (gethash (%edge-key parent-key name) edge-version) ver)
             (unless (gethash key nodes)
               (setf (gethash key nodes)
                     (make-inst-node :name name :version ver :deps deps
                                     :tarball tarball :integrity integrity :bin bin))
               (dolist (d deps)
                 (resolve-edge key (car d) (cdr d) :optional-p nil)))))
         (resolve-file (parent-key name range &key optional-p)
           (handler-case
               (progn
                 (unless root
                   (error 'install-error :message "file: dependency requires project root"))
                 (let ((abs (resolve-file-path root range)))
                   (unless (sys:path-exists-p abs)
                     (error 'install-error
                            :message (format nil "file: path does not exist: ~a" abs)))
                   (multiple-value-bind (pkg-name ver deps bin) (%read-local-package abs)
                     (declare (ignore pkg-name))
                     ;; Place under the dependency name (npm/Bun file: behaviour for named deps).
                     (record-node parent-key name ver deps
                                  (concatenate 'string "file:" abs) "" bin))))
             (error (e) (soft-or-fail optional-p e))))
         (resolve-edge (parent-key name range &key optional-p)
           (cond
             (err nil)
             ((file-spec-p range)
              (resolve-file parent-key name range :optional-p optional-p))
             (t
              (need-meta name
                (lambda (md)
                  (let ((ver (pick-version md range)))
                    (if (null ver)
                        (soft-or-fail optional-p
                                      (make-condition 'install-error
                                        :message (format nil "no version of ~a satisfies ~a" name range)))
                        (let ((vm (reg:metadata-version md ver)))
                          (if (null vm)
                              (soft-or-fail optional-p
                                            (make-condition 'install-error
                                              :message (format nil "~a has no version ~a" name ver)))
                              (let* ((key (format nil "~a@~a" name ver))
                                     (hard-deps (reg:vm-dependencies vm))
                                     (opt-deps (reg:vm-optional-dependencies vm)))
                                (setf (gethash (%edge-key parent-key name) edge-version) ver)
                                (unless (gethash key nodes)
                                  (setf (gethash key nodes)
                                        (make-inst-node :name name :version ver
                                                        :deps hard-deps
                                                        :tarball (reg:vm-dist-tarball vm)
                                                        :integrity (reg:vm-dist-integrity vm)
                                                        :bin (reg:vm-bin vm)))
                                  (dolist (d hard-deps)
                                    (resolve-edge key (car d) (cdr d) :optional-p nil))
                                  (dolist (d opt-deps)
                                    (resolve-edge key (car d) (cdr d) :optional-p t)))))))))
                :optional-p optional-p)))))
      (if (null root-deps)
          (when on-ok (funcall on-ok nodes edge-version))
          (progn
            (dolist (d root-deps)
              (resolve-edge ":root" (car d) (cdr d)
                            :optional-p (gethash (car d) optional)))
            (finish))))))

;;; --- placement / hoist ------------------------------------------------------

(defun plan-layout (nodes edge-version root-deps)
  "Deterministically place the resolved graph. Returns a list of (physical-dir . node-key) — where
each package is installed, relative to the project root — walking the tree in a FIXED order (ROOT-DEPS
order, then each node's metadata dependency order), independent of fetch-completion order. Hoists the
first-seen version of a name to the root node_modules; nests a conflicting different version under its
requiring parent. Signals install-error if a resolved edge is missing (an internal inconsistency)."
  (let ((at-root (make-hash-table :test 'equal))   ; name → version hoisted at the root node_modules
        (placed (make-hash-table :test 'equal))      ; physical-dir already emitted (cycle / dedup guard)
        (result '())
        (queue '()))
    (labels ((dep-version (parent-key dep-name)
               (or (gethash (%edge-key parent-key dep-name) edge-version)
                   (error 'install-error
                          :message (format nil "unresolved edge ~a → ~a" parent-key dep-name))))
             (enqueue (parent-key deps parent-dir)
               (dolist (d deps)
                 (setf queue (nconc queue (list (list (car d) (dep-version parent-key (car d)) parent-dir)))))))
      (enqueue ":root" root-deps "")
      (loop while queue do
        (destructuring-bind (name version parent-dir) (pop queue)
          (let* ((key (format nil "~a@~a" name version))
                 (rootv (gethash name at-root))
                 (physical
                   (cond ((null rootv)
                          (setf (gethash name at-root) version)
                          (format nil "node_modules/~a" name))
                         ((string= rootv version)
                          (format nil "node_modules/~a" name))
                         (t
                          (format nil "~anode_modules/~a"
                                  (if (plusp (length parent-dir)) (concatenate 'string parent-dir "/") "")
                                  name)))))
            (unless (gethash physical placed)
              (setf (gethash physical placed) t)
              (push (cons physical key) result)
              (let ((node (gethash key nodes)))
                (when node (enqueue key (in-deps node) physical))))))))
    (nreverse result)))
