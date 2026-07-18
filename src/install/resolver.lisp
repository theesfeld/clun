;;;; resolver.lisp — dependency resolution + hoisted-layout placement (PLAN.md Phase 23/59, §3.5).
;;;; Breadth-first, highest-satisfying, cycle-safe resolution over the Phase-21 async registry
;;;; client; then a placement pass that hoists the first-seen version of each name to the root
;;;; node_modules and nests genuine version conflicts. Dependency-spec breadth covers registry
;;;; ranges/dist-tags, npm: aliases, file:/link: local packages, and optionalDependencies with
;;;; soft-fail. Pure CL, no engine.

(in-package :clun.installer)

(define-condition install-error (error)
  ((message :initarg :message :reader install-error-message :initform "install error"))
  (:report (lambda (c s) (write-string (install-error-message c) s))))

(define-condition lock-drift-error (install-error) ()
  (:documentation "Signalled under --frozen-lockfile when resolution would change the lockfile."))

;;; A resolved package: a concrete (name, version) with the metadata install needs.
(defstruct (inst-node (:conc-name in-))
  name version
  (deps '())                            ; alist (dep-name . range)
  tarball integrity bin
  (kind :registry)                      ; :registry | :file | :url
  (local-path nil)
  (optional nil)
  (real-name nil))                      ; registry name for npm: aliases

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

;;; --- dependency-spec classification -----------------------------------------

(defun classify-dep-spec (spec)
  "Classify a package.json dependency value. Returns one of:
  (:range STRING)          — ordinary semver range or dist-tag
  (:file PATH)             — file: or link: local path
  (:npm-alias NAME RANGE)  — npm:NAME@RANGE alias (NAME may be scoped)
  (:url URL)               — direct http(s) tarball URL"
  (cond
    ((or (null spec) (not (stringp spec)))
     (list :range "*"))
    ((or (and (>= (length spec) 5) (string= "file:" spec :end2 5))
         (and (>= (length spec) 5) (string= "link:" spec :end2 5)))
     (list :file (subseq spec 5)))
    ((and (>= (length spec) 4) (string= "npm:" spec :end2 4))
     (let ((body (subseq spec 4)))
       (multiple-value-bind (name range) (%parse-name-spec body)
         (unless (and name (plusp (length name)))
           (error 'install-error :message (format nil "malformed npm: alias ~s" spec)))
         (list :npm-alias name (or range "*")))))
    ((or (and (>= (length spec) 8) (string-equal "https://" spec :end2 8))
         (and (>= (length spec) 7) (string-equal "http://" spec :end2 7)))
     (list :url spec))
    (t (list :range spec))))

(defun %resolve-local-path (root rel)
  "Absolute path for a file:/link: REL relative to ROOT (or absolute REL)."
  (let ((p (if (sys:absolute-path-p rel)
               (sys:normalize-path rel)
               (sys:normalize-path (sys:path-join root rel)))))
    (handler-case (sys:realpath p)
      (error () p))))

(defun %read-local-package (abs-path)
  "Read ABS-PATH/package.json → (values version deps-alist bin)."
  (let ((pj (sys:path-join abs-path "package.json")))
    (unless (sys:file-p pj)
      (error 'install-error
             :message (format nil "file: dependency has no package.json at ~a" abs-path)))
    (let* ((pkg (handler-case (sys:parse-json (sys:read-file-string pj))
                  (sys:json-error (e)
                    (error 'install-error
                           :message (format nil "malformed package.json at ~a: ~a" abs-path e)))))
           (ver (let ((v (sys:jget pkg "version"))) (if (stringp v) v "0.0.0")))
           (deps (%obj->alist (sys:jget pkg "dependencies")))
           (opt (%obj->alist (sys:jget pkg "optionalDependencies")))
           (bin (let ((b (sys:jget pkg "bin"))) (if (eq b :empty-object) nil b))))
      (values ver (append deps opt) bin))))

(defun %platform-matches-p (os-list cpu-list)
  "T when the current host is allowed by optional package os/cpu metadata (empty = unrestricted)."
  (flet ((match-list (wanted host)
           (or (null wanted)
               (let ((items (loop for x in wanted
                                  when (stringp x) collect (string-downcase x))))
                 (or (null items)
                     (let* ((host (string-downcase host))
                            (neg (remove-if-not
                                  (lambda (s) (and (plusp (length s)) (char= (char s 0) #\!)))
                                  items))
                            (pos (remove-if
                                  (lambda (s) (and (plusp (length s)) (char= (char s 0) #\!)))
                                  items)))
                       (and (or (null pos) (member host pos :test #'string=))
                            (notany (lambda (s) (string= host (subseq s 1))) neg))))))))
    (and (match-list os-list (sys:platform-name))
         (match-list cpu-list (sys:machine-arch)))))

(defun %dep-name (d)
  (if (consp d) (car d) d))

(defun %dep-range (d)
  "Range string from a root-dep entry: (name . range) or (name range &key optional)."
  (cond ((and (consp d) (stringp (cdr d))) (cdr d))
        ((and (consp d) (consp (cdr d))) (second d))
        (t "*")))

(defun %dep-optional-p (d)
  (cond ((and (consp d) (stringp (cdr d))) nil)
        ((and (consp d) (consp (cdr d)))
         (or (eq (third d) :optional)
             (eq (getf (cddr d) :optional) t)
             (member :optional (cddr d))))
        (t nil)))

;;; --- resolution (async, breadth-first) --------------------------------------

(defun %edge-key (parent-key dep-name)
  (concatenate 'string parent-key "|" dep-name))

(defun resolve-install (loop root-deps &key registry (retries 1) (project-root ".")
                                      on-ok on-err)
  "Resolve ROOT-DEPS transitively. ROOT-DEPS entries are either classic alists (name . range)
or lists (name range &optional :optional). Supports registry ranges/dist-tags, npm: aliases,
file:/link: local packages, and direct http(s) tarball URLs. Optional edges soft-fail."
  (let ((meta (make-hash-table :test 'equal))
        (nodes (make-hash-table :test 'equal))
        (edge-version (make-hash-table :test 'equal))
        (pending 0) (err nil) (finished nil))
    (labels
        ((finish ()
           (when (and (not finished) (zerop pending))
             (setf finished t)
             (if err
                 (when on-err (funcall on-err err))
                 (when on-ok (funcall on-ok nodes edge-version)))))
         (fail (e &key optional)
           (unless optional
             (unless err
               (setf err (if (typep e 'condition) e
                             (make-condition 'install-error
                                             :message (princ-to-string e)))))))
         (need-meta (fetch-name k &key optional)
           (unless err
             (let ((m (gethash fetch-name meta)))
               (if m
                   (funcall k m)
                   (progn
                     (incf pending)
                     (reg:fetch-metadata-async loop fetch-name :override registry :retries retries
                       :on-ok (lambda (md)
                                (setf (gethash fetch-name meta) md)
                                (decf pending)
                                (unless err (funcall k md))
                                (finish))
                       :on-err (lambda (e)
                                 (decf pending)
                                 (fail e :optional optional)
                                 (finish))))))))
         (record-edge (parent-key name ver)
           (setf (gethash (%edge-key parent-key name) edge-version) ver))
         (resolve-children (parent-key vm)
           (dolist (d (reg:vm-dependencies vm))
             (resolve-edge parent-key (car d) (cdr d)))
           (dolist (d (reg:vm-optional-dependencies vm))
             (resolve-edge parent-key (car d) (cdr d) :optional t)))
         (resolve-registry (parent-key install-name fetch-name range &key optional)
           (need-meta fetch-name
             (lambda (md)
               (let ((ver (pick-version md range)))
                 (cond
                   ((null ver)
                    (fail (make-condition 'install-error
                            :message (format nil "no version of ~a satisfies ~a"
                                             fetch-name range))
                          :optional optional))
                   (t
                    (let ((vm (reg:metadata-version md ver)))
                      (cond
                        ((null vm)
                         (fail (make-condition 'install-error
                                 :message (format nil "~a has no version ~a" fetch-name ver))
                               :optional optional))
                        ((and optional
                              (not (%platform-matches-p (reg:vm-os vm) (reg:vm-cpu vm))))
                         nil)
                        (t
                         (let ((key (format nil "~a@~a" install-name ver)))
                           (record-edge parent-key install-name ver)
                           (unless (gethash key nodes)
                             (setf (gethash key nodes)
                                   (make-inst-node
                                    :name install-name :version ver
                                    :real-name fetch-name
                                    :deps (append (reg:vm-dependencies vm)
                                                  (reg:vm-optional-dependencies vm))
                                    :tarball (reg:vm-dist-tarball vm)
                                    :integrity (reg:vm-dist-integrity vm)
                                    :bin (reg:vm-bin vm)
                                    :kind :registry
                                    :optional optional))
                             (resolve-children key vm))))))))))
             :optional optional))
         (resolve-file (parent-key name rel &key optional)
           (handler-case
               (let* ((abs (%resolve-local-path project-root rel)))
                 (multiple-value-bind (ver deps bin) (%read-local-package abs)
                   (let ((key (format nil "~a@~a" name ver)))
                     (record-edge parent-key name ver)
                     (unless (gethash key nodes)
                       (setf (gethash key nodes)
                             (make-inst-node :name name :version ver
                                             :real-name name
                                             :deps deps
                                             :tarball (concatenate 'string "file:" abs)
                                             :integrity ""
                                             :bin bin
                                             :kind :file
                                             :local-path abs
                                             :optional optional))
                       (dolist (d deps)
                         (resolve-edge key (car d) (cdr d)))))))
             (error (e) (fail e :optional optional))))
         (resolve-url (parent-key name url &key optional)
           (let* ((ver "0.0.0")
                  (key (format nil "~a@~a" name ver)))
             (record-edge parent-key name ver)
             (unless (gethash key nodes)
               (setf (gethash key nodes)
                     (make-inst-node :name name :version ver
                                     :real-name name
                                     :deps '()
                                     :tarball url
                                     :integrity ""
                                     :bin nil
                                     :kind :url
                                     :optional optional)))))
         (resolve-edge (parent-key name range &key optional)
           (unless err
             (handler-case
                 (let ((class (classify-dep-spec range)))
                   (ecase (first class)
                     (:range
                      (resolve-registry parent-key name name (second class)
                                        :optional optional))
                     (:file
                      (resolve-file parent-key name (second class) :optional optional))
                     (:npm-alias
                      (resolve-registry parent-key name (second class) (third class)
                                        :optional optional))
                     (:url
                      (resolve-url parent-key name (second class) :optional optional))))
               (error (e) (fail e :optional optional))))))
      (if (null root-deps)
          (when on-ok (funcall on-ok nodes edge-version))
          (progn
            (dolist (d root-deps)
              (resolve-edge ":root" (%dep-name d) (%dep-range d)
                            :optional (%dep-optional-p d)))
            (finish))))))

;;; --- placement / hoist ------------------------------------------------------

(defun plan-layout (nodes edge-version root-deps)
  "Deterministically place the resolved graph. Returns a list of (physical-dir . node-key).
Optional root edges that failed resolution are skipped; required missing edges signal."
  (let ((at-root (make-hash-table :test 'equal))
        (placed (make-hash-table :test 'equal))
        (result '())
        (queue '()))
    (labels ((enqueue (parent-key deps parent-dir)
               (dolist (d deps)
                 (let* ((dep-name (%dep-name d))
                        (ver (gethash (%edge-key parent-key dep-name) edge-version)))
                   (when ver
                     (setf queue (nconc queue
                                       (list (list dep-name ver parent-dir))))))))
             (place (name version parent-dir)
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
                                       (if (plusp (length parent-dir))
                                           (concatenate 'string parent-dir "/")
                                           "")
                                       name)))))
                 (unless (gethash physical placed)
                   (setf (gethash physical placed) t)
                   (push (cons physical key) result)
                   (let ((node (gethash key nodes)))
                     (when node (enqueue key (in-deps node) physical)))))))
      (dolist (d root-deps)
        (let* ((name (%dep-name d))
               (optional (%dep-optional-p d))
               (ver (gethash (%edge-key ":root" name) edge-version)))
          (cond (ver (place name ver ""))
                (optional nil)
                (t (error 'install-error
                          :message (format nil "unresolved root dependency ~a" name))))))
      (loop while queue do
        (destructuring-bind (name version parent-dir) (pop queue)
          (place name version parent-dir))))
    (nreverse result)))
