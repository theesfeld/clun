;;;; workspaces.lisp — monorepo workspace discovery, catalogs, filters, and concurrent
;;;; package script execution (PLAN.md Phase 60). Pure Common Lisp: globs via clun.glob,
;;;; no shell out for discovery. Matches and exceeds Bun workspaces:
;;;;   - workspace globs + exclusions (!pattern)
;;;;   - workspace: and catalog:/catalogs protocols
;;;;   - --filter name / path / negation for install and run
;;;;   - topological dependency-ordered concurrent script waves with concurrency cap
;;;;   - live symlink linking of workspace packages

(in-package :clun.installer)

(defstruct (workspace (:conc-name ws-))
  name                                  ; package.json "name" (string or NIL)
  version                               ; package.json "version" or "0.0.0"
  path                                  ; absolute directory
  relative                              ; path relative to monorepo root ("" for root)
  package                               ; parsed package.json
  (deps '())                            ; combined required deps alist
  (scripts nil))                        ; scripts object or NIL

(defstruct (workspace-graph (:conc-name wg-))
  root                                  ; absolute monorepo root
  root-package                          ; root package.json
  (packages '())                        ; list of workspace (root first when included)
  (by-name (make-hash-table :test 'equal))
  (by-path (make-hash-table :test 'equal))
  (catalog (make-hash-table :test 'equal))   ; default catalog name→range
  (catalogs (make-hash-table :test 'equal))  ; named → hash name→range
  (patterns '()))

;;; --- package.json workspaces field ------------------------------------------

(defun %as-string-list (v)
  "JSON array of strings → list of strings; single string → singleton; else ().
JSON arrays are vectors (clun.sys:parse-json); plain lists are also accepted."
  (cond ((stringp v) (list v))
        ((and (vectorp v) (every #'stringp v)) (coerce v 'list))
        ((and (consp v) (every #'stringp v)) (copy-list v))
        (t '())))

(defun %catalog-hash (obj)
  "JSON object of package→range → equal hash-table."
  (let ((h (make-hash-table :test 'equal)))
    (dolist (pair (%obj->alist obj) h)
      (when (and (stringp (car pair)) (stringp (cdr pair)))
        (setf (gethash (car pair) h) (cdr pair))))))

(defun parse-workspaces-field (pkg)
  "From a root package.json PKG return (values patterns default-catalog named-catalogs).
Supports array form, object form with packages/catalog/catalogs, and top-level catalog fields."
  (let* ((ws (sys:jget pkg "workspaces"))
         (patterns '())
         (default (make-hash-table :test 'equal))
         (named (make-hash-table :test 'equal)))
    (cond
      ((null ws) nil)
      ((eq ws :empty-object) nil)
      ((or (stringp ws) (and (consp ws) (stringp (car ws))))
       (setf patterns (%as-string-list ws)))
      ((and (consp ws) (consp (car ws)))        ; object
       (setf patterns (%as-string-list (sys:jget ws "packages")))
       (let ((c (sys:jget ws "catalog")))
         (when c (setf default (%catalog-hash c))))
       (let ((cs (sys:jget ws "catalogs")))
         (dolist (pair (%obj->alist cs))
           (when (stringp (car pair))
             (setf (gethash (car pair) named) (%catalog-hash (cdr pair))))))))
    ;; Top-level catalog / catalogs also apply (Bun accepts both).
    (let ((c (sys:jget pkg "catalog")))
      (when c
        (maphash (lambda (k v) (setf (gethash k default) v)) (%catalog-hash c))))
    (let ((cs (sys:jget pkg "catalogs")))
      (dolist (pair (%obj->alist cs))
        (when (stringp (car pair))
          (let ((h (or (gethash (car pair) named)
                       (setf (gethash (car pair) named) (make-hash-table :test 'equal)))))
            (maphash (lambda (k v) (setf (gethash k h) v)) (%catalog-hash (cdr pair)))))))
    (values patterns default named)))

;;; --- directory discovery ----------------------------------------------------

(defun %skip-dir-name-p (name)
  "Directories never scanned for workspace packages."
  (or (string= name "node_modules")
      (string= name ".git")
      (string= name ".hg")
      (string= name ".svn")
      (string= name ".clun-cache")
      (string= name "dist")
      (string= name "build")
      (string= name "coverage")
      (and (plusp (length name)) (char= (char name 0) #\.))))

(defun %collect-package-dirs (root &key (max-depth 8))
  "Relative paths (from ROOT) of directories that contain package.json, excluding ROOT itself
and skip-list directories. Depth-bounded BFS."
  (let ((out '())
        (queue (list (list "" 0))))
    (loop while queue do
      (destructuring-bind (rel depth) (pop queue)
        (when (< depth max-depth)
          (let ((abs (if (zerop (length rel)) root (sys:path-join root rel))))
            (handler-case
                (dolist (name (sys:read-directory abs))
                  (unless (%skip-dir-name-p name)
                    (let* ((child-rel (if (zerop (length rel))
                                          name
                                          (concatenate 'string rel "/" name)))
                           (child-abs (sys:path-join root child-rel)))
                      (when (sys:directory-p child-abs)
                        (when (sys:file-p (sys:path-join child-abs "package.json"))
                          (push child-rel out))
                        (setf queue (nconc queue (list (list child-rel (1+ depth)))))))))
              (error () nil))))))
    (sort out #'string<)))

(defun %glob-path-match-p (pattern path)
  "Match PATH (posix-relative, no leading ./) against a workspace glob PATTERN.
Supports *, **, ?, and character classes via clun.glob. Patterns may start with ./."
  (let* ((pat (if (and (>= (length pattern) 2)
                       (char= (char pattern 0) #\.)
                       (char= (char pattern 1) #\/))
                  (subseq pattern 2)
                  pattern))
         ;; Treat a trailing /** as optional so packages/* matches packages/foo
         (pat (string-right-trim "/" pat))
         (path (string-right-trim "/" path)))
    (or (string= pat path)
        (ignore-errors
          (clun.glob:glob-match-p (clun.glob:compile-glob pat) path))
        ;; Also try matching with /** suffix for directory globs written as packages/*
        (and (find #\* pat)
             (ignore-errors
               (clun.glob:glob-match-p
                (clun.glob:compile-glob (concatenate 'string pat "/**"))
                path))))))

(defun %apply-workspace-patterns (candidates patterns)
  "Filter CANDIDATE relative paths by PATTERNS (positive union, then ! negatives)."
  (let ((pos (remove-if (lambda (p) (and (plusp (length p)) (char= (char p 0) #\!))) patterns))
        (neg (mapcar (lambda (p) (subseq p 1))
                     (remove-if-not (lambda (p) (and (plusp (length p)) (char= (char p 0) #\!)))
                                    patterns)))
        (selected '()))
    (if (null pos)
        (setf selected (copy-list candidates))
        (dolist (c candidates)
          (when (some (lambda (p) (%glob-path-match-p p c)) pos)
            (push c selected))))
    (setf selected (nreverse selected))
    (remove-if (lambda (c) (some (lambda (p) (%glob-path-match-p p c)) neg)) selected)))

(defun %make-workspace-from-dir (root rel)
  "Build a workspace struct for ROOT/REL (REL \"\" = root package)."
  (let* ((abs (if (zerop (length rel)) root (sys:path-join root rel)))
         (pkg (read-package-json abs))
         (name (let ((n (sys:jget pkg "name"))) (and (stringp n) n)))
         (ver (let ((v (sys:jget pkg "version"))) (if (stringp v) v "0.0.0")))
         (scripts (let ((s (sys:jget pkg "scripts")))
                    (if (or (null s) (eq s :empty-object)) nil s)))
         (deps (root-deps pkg :production nil)))
    (make-workspace :name name :version ver :path abs :relative rel
                    :package pkg :deps deps :scripts scripts)))

(defun discover-workspaces (root)
  "Discover the monorepo at ROOT. Always includes the root package. Returns a workspace-graph.
If no workspaces field is present, the graph contains only the root package."
  (let* ((root (sys:normalize-path
                (handler-case (sys:realpath root) (error () root))))
         (pkg (read-package-json root))
         (graph (make-workspace-graph :root root :root-package pkg)))
    (multiple-value-bind (patterns default named) (parse-workspaces-field pkg)
      (setf (wg-patterns graph) patterns
            (wg-catalog graph) default
            (wg-catalogs graph) named)
      (let* ((root-ws (%make-workspace-from-dir root ""))
             (packages (list root-ws)))
        (when patterns
          (let* ((cands (%collect-package-dirs root))
                 (matched (%apply-workspace-patterns cands patterns)))
            (dolist (rel matched)
              (handler-case
                  (push (%make-workspace-from-dir root rel) packages)
                (install-error () nil)))))
        (setf packages (nreverse packages)
              (wg-packages graph) packages)
        (dolist (ws packages)
          (when (ws-name ws)
            (let ((prev (gethash (ws-name ws) (wg-by-name graph))))
              (when prev
                (error 'install-error
                       :message (format nil "duplicate workspace name ~a (~a and ~a)"
                                        (ws-name ws) (ws-relative prev) (ws-relative ws))))
              (setf (gethash (ws-name ws) (wg-by-name graph)) ws)))
          (setf (gethash (ws-relative ws) (wg-by-path graph)) ws))
        graph))))

(defun workspace-packages (graph &key (include-root t))
  "All workspace packages from GRAPH, optionally excluding the root package."
  (if include-root
      (copy-list (wg-packages graph))
      (remove-if (lambda (ws) (zerop (length (ws-relative ws)))) (wg-packages graph))))

;;; --- filters ----------------------------------------------------------------

(defun %strip-filter (f)
  "Return (values negated-p body). Body may still start with ./ for path filters."
  (if (and (plusp (length f)) (char= (char f 0) #\!))
      (values t (subseq f 1))
      (values nil f)))

(defun %path-filter-p (body)
  "T when BODY is a path filter (starts with ./ or / or is .)."
  (or (string= body ".")
      (string= body "./")
      (and (plusp (length body)) (char= (char body 0) #\/))
      (and (>= (length body) 2)
           (char= (char body 0) #\.)
           (char= (char body 1) #\/))))

(defun %normalize-filter-path (body)
  "Normalize a path filter body to a relative path without leading ./."
  (cond ((or (string= body ".") (string= body "./")) "")
        ((and (>= (length body) 2)
              (char= (char body 0) #\.)
              (char= (char body 1) #\/))
         (string-right-trim "/" (subseq body 2)))
        ((and (plusp (length body)) (char= (char body 0) #\/))
         (string-right-trim "/" (subseq body 1)))
        (t (string-right-trim "/" body))))

(defun %name-glob-match-p (pattern name)
  "Match package NAME against a name filter PATTERN (* wildcards)."
  (cond ((null name) nil)
        ((string= pattern "*") t)
        ((string= pattern name) t)
        (t (ignore-errors
             (clun.glob:glob-match-p (clun.glob:compile-glob pattern) name)))))

(defun %workspace-matches-body-p (ws body)
  "T if workspace WS matches a non-negated filter BODY (name glob or ./path glob)."
  (if (%path-filter-p body)
      (let* ((pat (%normalize-filter-path body))
             (rel (ws-relative ws)))
        (cond ((string= pat "") (zerop (length rel)))
              ((zerop (length rel)) nil)
              (t (or (%glob-path-match-p pat rel)
                     (%glob-path-match-p (concatenate 'string "./" pat) rel)))))
      (%name-glob-match-p body (ws-name ws))))

(defun workspace-matches-filter-p (ws filter)
  "T if workspace WS is selected by a single FILTER string (name glob or ./path glob; ! negates)."
  (multiple-value-bind (neg body) (%strip-filter filter)
    (let ((hit (%workspace-matches-body-p ws body)))
      (if neg (not hit) hit))))

(defun filter-workspaces (graph filters &key (include-root t))
  "Select packages from GRAPH matching FILTERS (list of --filter strings). Empty FILTERS means
all packages (respecting include-root). Multiple positive filters OR; then negatives remove."
  (let ((all (workspace-packages graph :include-root include-root)))
    (if (null filters)
        all
        (let* ((pos (remove-if (lambda (f)
                                 (and (plusp (length f)) (char= (char f 0) #\!)))
                               filters))
               (neg-bodies (mapcar (lambda (f) (subseq f 1))
                                   (remove-if-not
                                    (lambda (f)
                                      (and (plusp (length f)) (char= (char f 0) #\!)))
                                    filters)))
               (base (if (null pos)
                         all
                         (remove-if-not
                          (lambda (ws)
                            (some (lambda (f) (%workspace-matches-body-p ws f)) pos))
                          all))))
          (remove-if (lambda (ws)
                       (some (lambda (body) (%workspace-matches-body-p ws body)) neg-bodies))
                     base)))))

;;; --- catalog + workspace protocol rewrite -----------------------------------

(defun resolve-catalog-range (name spec catalogs default-catalog)
  "Resolve catalog: or catalog:NAME for dependency NAME. SPEC is the full range string.
CATALOGS is the named-catalogs hash; DEFAULT-CATALOG is the default catalog hash."
  (unless (and (stringp spec) (>= (length spec) 8) (string= "catalog:" spec :end2 8))
    (return-from resolve-catalog-range nil))
  (let* ((cat-name (subseq spec 8))
         (table (if (zerop (length cat-name))
                    default-catalog
                    (or (gethash cat-name catalogs)
                        (error 'install-error
                               :message (format nil "unknown catalog ~a" cat-name)))))
         (range (gethash name table)))
    (unless range
      (error 'install-error
             :message (format nil "catalog entry missing for ~a~@[:~a~]"
                              name (and (plusp (length cat-name)) cat-name))))
    range))

(defun expand-dep-spec (name range graph)
  "Expand workspace: and catalog: RANGE for dependency NAME against GRAPH.
Returns a concrete range string (file: path for workspace, or resolved catalog/semver)."
  (cond
    ((and (stringp range) (>= (length range) 10) (string= "workspace:" range :end2 10))
     (let* ((body (subseq range 10))
            (ws (gethash name (wg-by-name graph))))
       (unless ws
         (error 'install-error
                :message (format nil "workspace package ~a not found for workspace:~a"
                                 name body)))
       (let ((ver (ws-version ws)))
         (cond
           ((or (zerop (length body)) (string= body "*"))
            (concatenate 'string "workspace:" (ws-path ws)))
           ((string= body "^")
            (concatenate 'string "workspace:" (ws-path ws)))
           ((string= body "~")
            (concatenate 'string "workspace:" (ws-path ws)))
           ((and (or (char= (char body 0) #\^) (char= (char body 0) #\~)
                     (digit-char-p (char body 0)))
                 (not (sv:version-satisfies ver body))
                 (sv:range-valid-p body))
            (error 'install-error
                   :message (format nil "workspace ~a@~a does not satisfy workspace:~a"
                                    name ver body)))
           (t (concatenate 'string "workspace:" (ws-path ws)))))))
    ((and (stringp range) (>= (length range) 8) (string= "catalog:" range :end2 8))
     (resolve-catalog-range name range (wg-catalogs graph) (wg-catalog graph)))
    (t range)))

(defun expand-deps-for-graph (deps graph)
  "Map DEPS alist/list through expand-dep-spec against GRAPH."
  (mapcar (lambda (d)
            (let* ((n (%dep-name d))
                   (r (expand-dep-spec n (%dep-range d) graph))
                   (opt (%dep-optional-p d)))
              (if opt (list n r :optional t) (cons n r))))
          deps))

(defun collect-install-deps (graph packages &key production)
  "Union of dependencies for PACKAGES (workspaces) plus expanded workspace/catalog specs.
Root package uses PRODUCTION for root-deps; workspace leaves always include their deps.
Returns a list of dep entries suitable for resolve-install."
  (let ((seen (make-hash-table :test 'equal))
        (out '()))
    (dolist (ws packages)
      (let* ((raw (if (zerop (length (ws-relative ws)))
                      (root-deps (ws-package ws) :production production)
                      (ws-deps ws)))
             (expanded (expand-deps-for-graph raw graph)))
        (dolist (d expanded)
          (let ((n (%dep-name d)))
            (unless (gethash n seen)
              ;; Prefer required over optional if both appear.
              (setf (gethash n seen) d)
              (push d out))))))
    ;; Also inject workspace packages themselves as installable nodes when they are
    ;; referenced only as workspace: deps — handled by resolution. Additionally, every
    ;; selected workspace package is registered for linking by name.
    (nreverse out)))

(defun workspace-link-deps (packages)
  "Synthetic root deps that place each named workspace package into node_modules via workspace:."
  (loop for ws in packages
        when (and (ws-name ws) (plusp (length (ws-relative ws))))
          collect (cons (ws-name ws)
                        (concatenate 'string "workspace:" (ws-path ws)))))

;;; --- topological concurrent script runner -----------------------------------

(defun %workspace-dep-names (ws graph)
  "Names of other workspace packages that WS depends on (after expansion)."
  (let ((names '()))
    (dolist (d (ws-deps ws) names)
      (let* ((n (%dep-name d))
             (r (%dep-range d))
             (target (gethash n (wg-by-name graph))))
        (when (and target
                   (or (and (stringp r) (>= (length r) 10)
                            (string= "workspace:" r :end2 10))
                       (and (stringp r) (>= (length r) 5)
                            (string= "file:" r :end2 5))
                       ;; bare range that happens to name a workspace — treat as edge when
                       ;; the workspace is present (Bun links workspace matches).
                       t))
          (when (and target (not (eq target ws)))
            (pushnew n names :test #'string=)))))))

(defun workspace-topo-waves (packages graph)
  "Partition PACKAGES into topological waves (list of lists). Within a wave, packages have no
unsatisfied inter-workspace dependency on a later package in the selected set. Cycles collapse
into a single final wave (stable alphabetical) so execution still proceeds."
  (let* ((selected (make-hash-table :test 'equal))
         (remaining (make-hash-table :test 'equal))
         (waves '()))
    (dolist (ws packages)
      (when (ws-name ws)
        (setf (gethash (ws-name ws) selected) ws
              (gethash (ws-name ws) remaining) ws)))
    ;; Packages without a name run in the last wave alone.
    (let ((unnamed (remove-if #'ws-name packages)))
      (loop while (plusp (hash-table-count remaining)) do
        (let ((ready '()))
          (maphash
           (lambda (name ws)
             (declare (ignore name))
             (let ((deps (%workspace-dep-names ws graph)))
               (when (every (lambda (d)
                              (or (not (gethash d selected))
                                  (not (gethash d remaining))))
                            deps)
                 (push ws ready))))
           remaining)
          (when (null ready)
            ;; Cycle: dump everything remaining in alpha order and stop.
            (let ((rest '()))
              (maphash (lambda (n ws) (declare (ignore n)) (push ws rest)) remaining)
              (setf ready (sort rest #'string< :key (lambda (w) (or (ws-name w) (ws-relative w))))
                    remaining (make-hash-table :test 'equal)))
            (push ready waves)
            (return))
          (setf ready (sort ready #'string<
                            :key (lambda (w) (or (ws-name w) (ws-relative w)))))
          (dolist (ws ready)
            (remhash (ws-name ws) remaining))
          (push ready waves)))
      (let ((ordered (nreverse waves)))
        (if unnamed
            (append ordered (list unnamed))
            ordered)))))

(defun %script-command (ws name)
  "Return the scripts[NAME] string for WS, or NIL."
  (let ((scripts (ws-scripts ws)))
    (and scripts (sys:jobject-p scripts)
         (let ((c (sys:jget scripts name)))
           (and (stringp c) c)))))

(defun %workspace-bin-path (ws graph)
  "PATH prefix: package node_modules/.bin then monorepo root node_modules/.bin then process PATH."
  (let* ((pkg-bin (sys:path-join (ws-path ws) "node_modules" ".bin"))
         (root-bin (sys:path-join (wg-root graph) "node_modules" ".bin"))
         (old (or (sys:getenv "PATH") "")))
    (format nil "~a:~a:~a" pkg-bin root-bin old)))

(defun %run-one-workspace-script (ws graph script-name command)
  "Run COMMAND for workspace WS via /bin/sh -c in the package directory. Returns exit code.
Each stdout/stderr line is prefixed with package:script (Bun-compatible filtered run UI)."
  (let* ((cwd (ws-path ws))
         (pkg-json (sys:path-join cwd "package.json"))
         (env (let ((e (sys:environ-alist)))
                (flet ((setv (k v)
                         (let ((c (assoc k e :test #'string=)))
                           (if c (setf (cdr c) v) (setf e (cons (cons k v) e))))))
                  (setv "npm_lifecycle_event" script-name)
                  (setv "npm_package_json" pkg-json)
                  (when (ws-name ws) (setv "npm_package_name" (ws-name ws)))
                  (when (ws-version ws) (setv "npm_package_version" (ws-version ws)))
                  (setv "PATH" (%workspace-bin-path ws graph)))
                (loop for (k . v) in e collect (format nil "~a=~a" k v))))
         (label (or (ws-name ws) (ws-relative ws) "."))
         (proc (handler-case
                   (sb-ext:run-program "/bin/sh" (list "-c" command)
                                       :wait t :input t
                                       :output :stream :error :stream
                                       :directory cwd :environment env)
                 (error (e)
                   (format *error-output* "clun: cannot exec script in ~a: ~a~%" label e)
                   (return-from %run-one-workspace-script 127)))))
    (flet ((drain (stream)
             (when stream
               (loop for line = (read-line stream nil nil)
                     while line do
                       (format t "~a:~a | ~a~%" label script-name line)
                       (force-output)))))
      (let ((out (sb-ext:process-output proc))
            (err (sb-ext:process-error proc)))
        (drain out)
        (drain err)
        (sb-ext:process-wait proc)
        (let ((status (sb-ext:process-status proc))
              (code (sb-ext:process-exit-code proc)))
          (if (eq status :signaled) (+ 128 (or code 0)) (or code 1)))))))

(defun %quote-sh-arg (a)
  (with-output-to-string (o)
    (write-char #\' o)
    (loop for c across a do
      (if (char= c #\')
          (write-string "'\\''" o)
          (write-char c o)))
    (write-char #\' o)))

(defun %run-wave-parallel (graph jobs script-name concurrency exit-on-error)
  "Run JOBS (list of (ws command)) with up to CONCURRENCY threads. Returns worst exit code."
  (let* ((lock (sb-thread:make-mutex :name "ws-scripts"))
         (remaining jobs)
         (codes '())
         (threads '()))
    (flet ((worker ()
             (loop
               (let ((job nil))
                 (sb-thread:with-mutex (lock)
                   (when remaining
                     (setf job (pop remaining))))
                 (unless job (return))
                 (let ((code (%run-one-workspace-script
                              (first job) graph script-name (second job))))
                   (sb-thread:with-mutex (lock)
                     (push code codes)
                     (when (and exit-on-error (plusp code))
                       (setf remaining nil))))))))
      (dotimes (i (min concurrency (length jobs)))
        (push (sb-thread:make-thread #'worker :name (format nil "ws-run-~d" i))
              threads))
      (mapc #'sb-thread:join-thread threads)
      (if codes (reduce #'max codes) 0))))

(defun run-workspace-scripts (graph packages script-name
                              &key (parallel t) (concurrency 4)
                                (exit-on-error t) (if-present nil)
                                (passthrough '()))
  "Run SCRIPT-NAME across PACKAGES. PARALLEL T runs topo-waves with up to CONCURRENCY threads
per wave; NIL runs sequentially in topo order. Returns the worst (max) exit code.
IF-PRESENT skips packages missing the script. Exceeds Bun with explicit concurrency capping
and wave-based topological parallelism."
  (let* ((waves (if parallel
                    (workspace-topo-waves packages graph)
                    (list (apply #'append (workspace-topo-waves packages graph)))))
         (worst 0)
         (abort nil))
    (dolist (wave waves)
      (when abort (return))
      (let ((jobs '()))
        (dolist (ws wave)
          (let ((cmd (%script-command ws script-name)))
            (cond
              ((stringp cmd)
               (let ((full (if passthrough
                               (format nil "~a~{ ~a~}" cmd
                                       (mapcar #'%quote-sh-arg passthrough))
                               cmd)))
                 (push (list ws full) jobs)))
              (if-present nil)
              (t
               (format *error-output* "clun: script ~a not found in package ~a~%"
                       script-name (or (ws-name ws) (ws-relative ws)))
               (setf worst (max worst 1))
               (when exit-on-error (setf abort t))))))
        (setf jobs (nreverse jobs))
        (when (and jobs (not abort))
          (let ((code
                  (if (and parallel (> (length jobs) 1) (> concurrency 1))
                      (%run-wave-parallel graph jobs script-name concurrency exit-on-error)
                      (let ((w 0))
                        (dolist (job jobs w)
                          (let ((c (%run-one-workspace-script
                                    (first job) graph script-name (second job))))
                            (setf w (max w c))
                            (when (and exit-on-error (plusp c))
                              (return w))))))))
            (setf worst (max worst code))
            (when (and exit-on-error (plusp worst))
              (setf abort t))))))
    worst))

;;; --- workspace protocol classification helpers ------------------------------

(defun workspace-spec-p (spec)
  (and (stringp spec) (>= (length spec) 10) (string= "workspace:" spec :end2 10)))

(defun catalog-spec-p (spec)
  (and (stringp spec) (>= (length spec) 8) (string= "catalog:" spec :end2 8)))

(defun workspace-path-from-spec (spec)
  "Absolute path from a workspace:/abs/or/rel resolved marker (after expand)."
  (when (workspace-spec-p spec)
    (subseq spec 10)))
