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

(defparameter *tarball-download-function* #'%download-tarball
  "Internal tarball downloader indirection. Tests may bind this to exercise callback timing;
production uses the fail-closed HTTP/TLS downloader above.")

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

;;; --- local package materialisation (file:) ----------------------------------

(defun %copy-tree (src dst)
  "Recursively copy directory SRC to DST (DST must not exist). Regular files, directories, and
symlinks are preserved; device nodes are skipped. Used for file: dependencies."
  (let ((st (sys:stat* src :lstat t)))
    (cond
      ((sys:fstat-dir-p st)
       (sys:make-directory dst :recursive t :mode #o755)
       (dolist (e (sys:read-directory src))
         (%copy-tree (sys:path-join src e) (sys:path-join dst e))))
      ((sys:fstat-symlink-p st)
       (sys:make-symlink (sys:read-symlink src) dst))
      ((sys:fstat-file-p st)
       (let ((parent (sys:path-dirname dst)))
         (unless (sys:path-exists-p parent)
           (sys:make-directory parent :recursive t :mode #o755)))
       (sys:copy-file-stream src dst :mode (logand (sys:fstat-mode st) #o777)))
      (t nil))))

(defun %materialise-file-node (node dest)
  "Copy a file: package from NODE's local-path into DEST."
  (let ((src (or (in-local-path node)
                 (let ((tb (in-tarball node)))
                   (when (and (stringp tb) (>= (length tb) 5) (string= "file:" tb :end2 5))
                     (subseq tb 5))))))
    (unless (and src (sys:directory-p src))
      (error 'install-error :message (format nil "file: package missing at ~a" src)))
    (let ((parent (sys:path-dirname dest)))
      (unless (sys:path-exists-p parent)
        (sys:make-directory parent :recursive t :mode #o755)))
    (when (sys:path-exists-p dest) (sys:remove-recursive dest))
    (%copy-tree src dest)))

(defun %split-path-parts (path)
  "Split a normalized absolute/relative path into non-empty segments."
  (loop for start = 0 then (1+ pos)
        for pos = (position #\/ path :start start)
        for part = (subseq path start (or pos (length path)))
        unless (zerop (length part)) collect part
        while pos))

(defun %relative-symlink-target (from-path to-path)
  "Compute a relative symlink path from FROM-PATH (the link location) to TO-PATH (the target dir)."
  (let* ((from-dir (sys:path-dirname from-path))
         ;; Resolve existing endpoints before comparing path components.  A
         ;; lexical relative path is wrong when an ancestor is a symlink whose
         ;; canonical target has a different depth -- notably Darwin's
         ;; /tmp -> /private/tmp.  The link parent and workspace source both
         ;; exist at materialisation time; retain lexical fallbacks for callers
         ;; that use this helper independently.
         (canonical-from
           (or (ignore-errors (sys:realpath from-dir))
               (sys:normalize-path from-dir)))
         (canonical-to
           (or (ignore-errors (sys:realpath to-path))
               (sys:normalize-path to-path)))
         (from-parts (%split-path-parts canonical-from))
         (to-parts (%split-path-parts canonical-to))
         (i 0)
         (n (min (length from-parts) (length to-parts))))
    (loop while (and (< i n) (string= (nth i from-parts) (nth i to-parts))) do (incf i))
    (let ((ups (make-list (- (length from-parts) i) :initial-element ".."))
          (down (subseq to-parts i)))
      (if (and (null ups) (null down))
          "."
          (format nil "~{~a~^/~}" (append ups down))))))

(defun %materialise-workspace-node (node dest)
  "Symlink a workspace package from NODE's local-path into DEST (live link, exceeds file: copy)."
  (let ((src (or (in-local-path node)
                 (let ((tb (in-tarball node)))
                   (when (and (stringp tb) (>= (length tb) 10)
                              (string= "workspace:" tb :end2 10))
                     (subseq tb 10))))))
    (unless (and src (sys:directory-p src))
      (error 'install-error :message (format nil "workspace package missing at ~a" src)))
    (let ((parent (sys:path-dirname dest)))
      (unless (sys:path-exists-p parent)
        (sys:make-directory parent :recursive t :mode #o755)))
    (when (sys:path-exists-p dest) (sys:remove-recursive dest))
    (let ((target (handler-case (%relative-symlink-target dest src)
                    (error () src))))
      (sys:make-symlink target dest))))

;;; --- link a whole plan ------------------------------------------------------

(defun %ordered-materialisation-plan (plan)
  "Return a fresh PLAN whose shallower physical paths precede deeper paths.
Every package ancestor therefore commits before a nested dependency even when a hand-edited or
reformatted lockfile presents object entries in another order. STABLE-SORT preserves the resolver's
order among placements at the same depth."
  (stable-sort (copy-list plan) #'<
               :key (lambda (entry)
                      (length (%split-path-parts (car entry))))))

(defun link-plan (loop root plan nodes &key on-ok on-err)
  "Materialise PLAN (list of (physical-dir . node-key)) under ROOT: obtain each tarball (cache by
integrity, else download), verify + extract (Phase-22) into ROOT/physical, copy file: packages, then
create bin symlinks. Downloads remain concurrent and may complete in any order; ready entries are
committed only as a deterministic ancestor-before-descendant prefix, so extracting a parent can
never erase an already-extracted child even when lockfile entries are reordered. ON-OK () when
everything is extracted + linked, ON-ERR (condition)."
  (let* ((ordered-plan (%ordered-materialisation-plan plan))
         ;; Created lazily only for URL/no-integrity or cache-write fallback. All-cache, file,
         ;; workspace, and empty installs must not acquire a new TMPDIR dependency.
         (spool-dir nil)
         (spool-counter 0)
         (pending 0) (err nil) (finished nil) (preparation-complete nil)
         (remaining ordered-plan)
         (ready (make-hash-table :test 'equal)))
    (labels ((cleanup-ready ()
               (clrhash ready)
               (when spool-dir
                 (ignore-errors (sys:remove-recursive spool-dir))
                 (setf spool-dir nil)))
             (fail (e) (unless err
                         (setf err (if (typep e 'condition) e
                                       (make-condition 'install-error :message (princ-to-string e))))
                         ;; Completed responses must not accumulate after terminal failure. Late
                         ;; callbacks see ERR and discard their bodies without recreating the spool.
                         (cleanup-ready)))
             (finish-if-ready ()
               ;; A test downloader may invoke its callback synchronously from PREPARE-ONE. Do not
               ;; report success until every plan entry has at least been prepared/scheduled.
               (when (and preparation-complete (not finished) (zerop pending)
                          (or err (null remaining)))
                 (setf finished t)
                 (unless err
                   ;; Preserve the resolver/lock plan's same-level .bin collision order. Only
                   ;; package materialisation needs the ancestor-first projection.
                   (handler-case (%link-bins root plan nodes) (error (e) (fail e))))
                 (cleanup-ready)
                 (if err (when on-err (funcall on-err err))
                     (when on-ok (funcall on-ok)))))
             (spool-payload (bytes)
               (handler-case
                   (let* ((dir (or spool-dir
                                   (setf spool-dir
                                         (sys:make-temp-dir
                                          (sys:path-join (sys:tmpdir)
                                                         "clun-link-ready-")))))
                          (path (sys:path-join dir
                                              (format nil "~d.tgz" (incf spool-counter)))))
                     (sys:write-file-octets path bytes)
                     (cons :spool path))
                 (error (e) (fail e) nil)))
             (ready-payload (integrity bytes)
               ;; Queue only disk-backed tokens. Registry tarballs normally enter the verified
               ;; content-addressed cache; URL/no-integrity or cache-write failures use this
               ;; link-plan's private spool. A slow parent therefore cannot retain every completed
               ;; descendant response in the Lisp heap.
               (let ((cache-path
                       (and integrity (plusp (length integrity))
                            (ignore-errors (tb:cache-store integrity bytes)))))
                 (if cache-path (cons :cache cache-path)
                     (spool-payload bytes))))
             (payload-octets (payload)
               (cond
                 ((and (consp payload) (member (car payload) '(:cache :spool))
                       (stringp (cdr payload)))
                  (handler-case
                      (let ((bytes (sys:read-file-octets (cdr payload))))
                        (when (eq (car payload) :spool)
                          (ignore-errors (sys:remove-recursive (cdr payload))))
                        bytes)
                    (error (e) (fail e) nil)))
                 ((typep payload '(vector (unsigned-byte 8))) payload)
                 (t nil)))
             (extract (node dest bytes)
               (handler-case
                   (let ((parent (sys:path-dirname dest)))
                     ;; the extractor renames a staging dir INTO dest, so dest's parent must exist
                     ;; (recursively — a nested node_modules/<pkg>/node_modules/<dep>).
                     (unless (sys:path-exists-p parent)
                       (sys:make-directory parent :recursive t :mode #o755))
                     (let ((integrity (in-integrity node)))
                       (tb:extract-package bytes dest
                                           :integrity (if (and integrity (plusp (length integrity)))
                                                          integrity
                                                          nil)
                                           :strip-components 1)))
                 (error (e) (fail e))))
             (materialise-one (physical key payload)
               (let* ((node (gethash key nodes))
                      (dest (sys:path-join root physical)))
                 (cond
                   ((null node)
                    (fail (make-condition 'install-error
                            :message (format nil "missing node for ~a" key))))
                   ((eq (in-kind node) :file)
                    (handler-case (%materialise-file-node node dest)
                      (error (e) (fail e))))
                   ((eq (in-kind node) :workspace)
                    (handler-case (%materialise-workspace-node node dest)
                      (error (e) (fail e))))
                   (t
                    (let ((bytes (payload-octets payload)))
                      (if bytes
                        (extract node dest bytes)
                        (fail (make-condition 'install-error
                                :message (format nil "missing downloaded payload for ~a" key)))))))))
             (drain-ready-prefix ()
               ;; Remove each payload immediately after commit so a slow later download does not
               ;; retain every earlier tarball in memory.
               (loop while (and remaining (not err))
                     for physical = (caar remaining)
                     for key = (cdar remaining)
                     do (multiple-value-bind (payload presentp) (gethash physical ready)
                          (unless presentp (return))
                          (materialise-one physical key payload)
                          (unless err
                            (remhash physical ready)
                            (pop remaining))))
               (finish-if-ready))
             (mark-ready (physical payload)
               (if err
                   (finish-if-ready)
                   (progn
                     (setf (gethash physical ready) payload)
                     (drain-ready-prefix))))
             (prepare-one (physical key)
               (let ((node (gethash key nodes)))
                 (cond
                   ((null node)
                    (fail (make-condition 'install-error
                            :message (format nil "missing node for ~a" key))))
                   ((member (in-kind node) '(:file :workspace))
                    (mark-ready physical (in-kind node)))
                   (t
                    (let* ((integrity (in-integrity node))
                           (cached (and integrity (plusp (length integrity))
                                        (ignore-errors (tb:cache-fetch integrity)))))
                      (cond
                        (cached
                         ;; CACHE-FETCH verified the bytes; queue the path and release the vector.
                         ;; EXTRACT-PACKAGE verifies integrity again after the just-in-time read.
                         (mark-ready physical (cons :cache (tb:cache-path integrity))))
                        ((null (in-tarball node))
                         (fail (make-condition 'install-error
                                 :message (format nil "no tarball for ~a" key))))
                        (t
                         (let ((settled nil))
                           (incf pending)
                           (funcall *tarball-download-function* loop (in-tarball node)
                             :on-ok (lambda (bytes)
                                      (unless settled
                                        (setf settled t)
                                        (decf pending)
                                        (if err
                                            (finish-if-ready)
                                            (let ((payload (ready-payload integrity bytes)))
                                              (if payload
                                                  (mark-ready physical payload)
                                                  (finish-if-ready))))))
                             :on-err (lambda (code)
                                       (unless settled
                                         (setf settled t)
                                         (fail (make-condition 'install-error
                                                 :message (format nil "download failed for ~a: ~a"
                                                                  key code)))
                                         (decf pending)
                                         (finish-if-ready)))))))))))))
      (dolist (p ordered-plan) (unless err (prepare-one (car p) (cdr p))))
      (setf preparation-complete t)
      (drain-ready-prefix))))
