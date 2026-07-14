;;;; resolver.lisp — dependency resolution + hoisted-layout placement (PLAN.md Phase 23, §3.5).
;;;; Breadth-first, highest-satisfying, cycle-safe resolution over the Phase-21 async registry
;;;; client; then a placement pass that hoists the first-seen version of each name to the root
;;;; node_modules and nests genuine version conflicts. Pure CL, no engine.

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
  tarball integrity bin)                ; dist.tarball, dist.integrity, bin (a string or alist)

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

;;; --- resolution (async, breadth-first) --------------------------------------

(defun %edge-key (parent-key dep-name)
  (concatenate 'string parent-key "|" dep-name))

(defun resolve-install (loop root-deps &key registry (retries 1) on-ok on-err)
  "Resolve ROOT-DEPS (an alist of (name . range)) transitively. Fetches each package's abbreviated
metadata ONCE (cached per name) via the async registry client, picks the highest satisfying version
per edge, and records the graph. Cycle-safe (an already-resolved name@version is reused). Calls ON-OK
with (values NODES EDGE-VERSION) — NODES: hash \"name@version\" → inst-node; EDGE-VERSION: hash
\"<parent-key>|<dep-name>\" → resolved-version, parent-key = \":root\" or a \"name@version\". Placement
walks these deterministically (independent of fetch-completion order) — or ON-ERR with a condition."
  (let ((meta (make-hash-table :test 'equal))     ; name → pkg-metadata
        (nodes (make-hash-table :test 'equal))     ; "name@version" → inst-node
        (edge-version (make-hash-table :test 'equal))  ; "<parent>|<dep>" → version
        (pending 0) (err nil) (finished nil))
    (labels
        ((finish ()
           (when (and (not finished) (zerop pending))
             (setf finished t)
             (if err
                 (when on-err (funcall on-err err))
                 (when on-ok (funcall on-ok nodes edge-version)))))
         (fail (e) (unless err (setf err (if (typep e 'condition) e
                                             (make-condition 'install-error :message (princ-to-string e))))))
         (need-meta (name k)
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
                       :on-err (lambda (e) (decf pending) (fail e) (finish))))))))
         (resolve-edge (parent-key name range)
           (need-meta name
             (lambda (md)
               (let ((ver (pick-version md range)))
                 (if (null ver)
                     (fail (make-condition 'install-error
                             :message (format nil "no version of ~a satisfies ~a" name range)))
                     (let ((key (format nil "~a@~a" name ver)))
                       (setf (gethash (%edge-key parent-key name) edge-version) ver)
                       (unless (gethash key nodes)
                         (let ((vm (reg:metadata-version md ver)))
                           (if (null vm)
                               (fail (make-condition 'install-error
                                       :message (format nil "~a has no version ~a" name ver)))
                               (progn
                                 (setf (gethash key nodes)
                                       (make-inst-node :name name :version ver
                                                       :deps (reg:vm-dependencies vm)
                                                       :tarball (reg:vm-dist-tarball vm)
                                                       :integrity (reg:vm-dist-integrity vm)
                                                       :bin (reg:vm-bin vm)))
                                 (dolist (d (reg:vm-dependencies vm))
                                   (resolve-edge key (car d) (cdr d))))))))))))))
      (if (null root-deps)
          (when on-ok (funcall on-ok nodes edge-version))
          (progn
            (dolist (d root-deps) (resolve-edge ":root" (car d) (cdr d)))
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
