;;;; linker.lisp — materialise a resolved plan on disk (PLAN.md Phase 23, §3.5). For each placement,
;;;; obtain the tarball (content-addressed cache by integrity, else download dist.tarball over the
;;;; Phase-18 http client / Phase-20 https worker path), verify + extract with the Phase-22 hardened
;;;; extractor, then create `bin` symlinks + chmod into the nearest node_modules/.bin. Lifecycle
;;;; scripts are NEVER executed — collected + logged (stricter than Bun, PLAN §3.5). Pure CL.

(in-package :clun.installer)

;;; --- tarball download (http + https) ----------------------------------------

(defun %split-url (url)
  "Split URL into (values scheme host port path). Defaults: https→443, http→80."
  (let* ((secure t) (rest url))
    (cond ((and (>= (length url) 8) (string-equal "https://" url :end2 8)) (setf secure t rest (subseq url 8)))
          ((and (>= (length url) 7) (string-equal "http://" url :end2 7)) (setf secure nil rest (subseq url 7))))
    (let* ((slash (position #\/ rest))
           (authority (if slash (subseq rest 0 slash) rest))
           (path (if slash (subseq rest slash) "/"))
           (colon (position #\: authority))
           (host (if colon (subseq authority 0 colon) authority))
           (port (if colon (or (ignore-errors (parse-integer authority :start (1+ colon))) (if secure 443 80))
                     (if secure 443 80))))
      (values (if secure "https" "http") host port (if (plusp (length path)) path "/")))))

(defun %download-tarball (loop url &key on-ok on-err)
  "GET the tarball at URL; ON-OK with the body octets, ON-ERR with a code string. Dispatches http →
the Phase-18 reactor client, https → net:https-request on the worker pool (verification fail-closed)."
  (multiple-value-bind (scheme host port path) (%split-url url)
    (flet ((handle (resp) (let ((s (net:hres-status resp)))
                            (if (and (>= s 200) (< s 300))
                                (funcall on-ok (net:hres-body resp))
                                (funcall on-err (format nil "HTTP ~d for ~a" s url))))))
      (if (string= scheme "https")
          (let ((box (list nil)) (done nil))
            (flet ((settle (thunk) (unless done (setf done t) (funcall thunk))))
              (lp:worker-submit loop
                (lambda () (net:https-request :host host :port port :method "GET" :path path :socket-box box))
                (lambda (result)
                  (settle (lambda ()
                            (if (eq (car result) :ok) (handle (second result))
                                (funcall on-err (net:tls-error-message (second result))))))))))
          (net:http-request-async loop :host host :port port :method "GET" :path path :timeout 60000
            :on-response #'handle
            :on-error (lambda (code) (funcall on-err code)))))))

;;; --- bin symlinks -----------------------------------------------------------

(defun %bin-entries (bin pkg-name)
  "Normalise a version's `bin` (a string or a name→path object/alist) to a list of (bin-name . rel-path)."
  (cond ((null bin) '())
        ((stringp bin) (list (cons (sys:path-basename pkg-name) bin)))
        ((eq bin :empty-object) '())
        ((consp bin) (loop for (k . v) in bin when (stringp v) collect (cons k v)))
        (t '())))

(defun %nearest-node-modules (physical)
  "The node_modules dir that DIRECTLY holds the package at PHYSICAL, honouring a scope segment:
node_modules/left-pad → node_modules ; node_modules/@scope/widget → node_modules (NOT
node_modules/@scope) ; node_modules/a/node_modules/b → node_modules/a/node_modules."
  (let ((pos (search "node_modules/" physical :from-end t)))
    (if pos (subseq physical 0 (+ pos (length "node_modules"))) "node_modules")))

(defun %link-bins (root plan nodes)
  "Create node_modules/.bin symlinks (relative) + chmod +x the targets, for every placed package with
a `bin`. Bins go in the NEAREST node_modules/.bin — for a scoped package too (node_modules/.bin, not
node_modules/@scope/.bin), matching npm/Bun so the bin is on PATH."
  (dolist (p plan)
    (destructuring-bind (physical . key) p
      (let ((node (gethash key nodes)))
        (when (and node (in-bin node))
          (let* ((nm-dir (%nearest-node-modules physical))     ; the node_modules holding the package
                 (pkg-subpath (subseq physical (min (length physical) (1+ (length nm-dir)))))  ; e.g. @scope/widget
                 (bindir-abs (sys:path-join root (concatenate 'string nm-dir "/.bin"))))
            (dolist (b (%bin-entries (in-bin node) (in-name node)))
              (destructuring-bind (bin-name . rel-path) b
                (unless (sys:path-exists-p bindir-abs) (sys:make-directory bindir-abs :recursive t :mode #o755))
                (let ((linkpath (sys:path-join bindir-abs bin-name))
                      ;; from <nm>/.bin/<bin> to <nm>/<pkg-subpath>/<rel-path>
                      (target (concatenate 'string "../" pkg-subpath "/" rel-path))
                      (target-abs (sys:path-join root physical rel-path)))
                  (ignore-errors (when (sys:path-exists-p linkpath) (sys:remove-recursive linkpath)))
                  (ignore-errors (sys:make-symlink target linkpath))
                  (ignore-errors (sys:change-mode target-abs #o755)))))))))))

;;; --- lifecycle scripts (collected, never run) -------------------------------

(defun %collect-lifecycle-scripts (plan nodes)
  "Return a list of (package . script-names) for any placed package declaring install lifecycle
scripts. clun NEVER runs them (stricter than Bun) — the caller logs this list."
  (declare (ignore plan nodes))
  ;; abbreviated metadata exposes only hasInstallScript, not the script bodies; the resolver records
  ;; the flag on the node's version-meta when present. For v1 we report nothing to run (the flag path
  ;; is surfaced by the CLI in milestone 2 from the installed package.json); this stays a no-op hook.
  '())

;;; --- link a whole plan ------------------------------------------------------

(defun link-plan (loop root plan nodes &key on-ok on-err)
  "Materialise PLAN (list of (physical-dir . node-key)) under ROOT: obtain each tarball (cache by
integrity, else download), verify + extract (Phase-22) into ROOT/physical, then create bin symlinks.
Async (downloads in flight on the loop); ON-OK () when everything is extracted + linked, ON-ERR
(condition)."
  (let ((pending 0) (err nil) (finished nil))
    (labels ((fail (e) (unless err
                         (setf err (if (typep e 'condition) e
                                       (make-condition 'install-error :message (princ-to-string e))))))
             (finish ()
               (when (and (not finished) (zerop pending))
                 (setf finished t)
                 (if err
                     (when on-err (funcall on-err err))
                     (progn (handler-case (%link-bins root plan nodes) (error (e) (fail e)))
                            (if err (when on-err (funcall on-err err))
                                (when on-ok (funcall on-ok)))))))
             (extract (node dest bytes)
               (handler-case
                   (let ((parent (sys:path-dirname dest)))
                     ;; the extractor renames a staging dir INTO dest, so dest's parent must exist
                     ;; (recursively — a nested node_modules/<pkg>/node_modules/<dep>).
                     (unless (sys:path-exists-p parent)
                       (sys:make-directory parent :recursive t :mode #o755))
                     (tb:extract-package bytes dest :integrity (in-integrity node) :strip-components 1))
                 (error (e) (fail e))))
             (do-one (physical key)
               (let* ((node (gethash key nodes))
                      (dest (sys:path-join root physical))
                      (integrity (in-integrity node))
                      (cached (and integrity (ignore-errors (tb:cache-fetch integrity)))))
                 (cond
                   (cached (extract node dest cached))
                   ((null (in-tarball node))
                    (fail (make-condition 'install-error
                            :message (format nil "no tarball for ~a" key))))
                   (t
                    (incf pending)
                    (%download-tarball loop (in-tarball node)
                      :on-ok (lambda (bytes)
                               (when integrity (ignore-errors (tb:cache-store integrity bytes)))
                               (extract node dest bytes)
                               (decf pending) (finish))
                      :on-err (lambda (code)
                                (fail (make-condition 'install-error
                                        :message (format nil "download failed for ~a: ~a" key code)))
                                (decf pending) (finish))))))))
      (dolist (p plan) (unless err (do-one (car p) (cdr p))))
      (finish))))
