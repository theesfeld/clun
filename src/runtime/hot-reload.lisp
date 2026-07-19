;;;; hot-reload.lisp — tooling.hot-reload full port (#188 / Phase 67 / epic #177).
;;;;
;;;; Pure Common Lisp state-preserving hot reload that meets and exceeds `bun --hot`:
;;;;   * --hot  soft reload: re-evaluate the module graph without killing the process;
;;;;             Clun.serve sockets and live TCP connections are retained via identity
;;;;             registry + server.reload; globalThis / process persist.
;;;;   * --watch hard restart: stop retained servers, clear user modules, re-run entry.
;;;;   * portable stat-poll watcher (mtime+size+ino+content fingerprint) with change
;;;;     coalescing — no native filesystem watcher bindings.
;;;;   * import.meta.hot (accept / dispose / data / decline / on / off / invalidate)
;;;;     ships for the server runtime (Bun documents this as planned for --hot).
;;;;   * failed reload recovery: keep previous handlers when the new graph throws.
;;;;   * Clun.hot introspection surface (mode, reloads, lastError, watched paths).

(in-package :clun.runtime)

;;; --- mode -------------------------------------------------------------------

(defvar *hot-reload-mode* nil
  "NIL | :hot | :watch — set by the CLI for the current process run.")

(defvar *hot-no-clear-screen* nil
  "When true, do not clear the terminal between reload cycles.")

(defvar *hot-poll-ms* 50
  "Stat-poll interval in milliseconds (pure CL; no native FS watchers).")

(defvar *hot-coalesce-ms* 40
  "Debounce window after the first detected change before firing a reload.")

(defvar *hot-session* nil
  "Active hot-session for the current CLI run, or NIL.")

(defun hot-mode-p ()
  (member *hot-reload-mode* '(:hot :watch) :test #'eq))

(defun hot-soft-p ()
  (eq *hot-reload-mode* :hot))

;;; --- server identity (connection-preserving reload) -------------------------

(defvar *hot-server-registry* (make-hash-table :test 'equal)
  "host:port → live server js-object while *hot-reload-mode* is active.")

(defvar *hot-server-cells* (make-hash-table :test 'eq)
  "server object → plist of mutable cells used by %clun-serve for reload.")

(defun %serve-identity-key (host port)
  (format nil "~a:~d" host port))

(defun hot-register-server (key server cells)
  (setf (gethash key *hot-server-registry*) server
        (gethash server *hot-server-cells*)
        (list* :key key cells))
  server)

(defun hot-unregister-server (server)
  (let ((meta (gethash server *hot-server-cells*)))
    (when meta
      (let ((key (getf meta :key)))
        (when key (remhash key *hot-server-registry*)))
      (remhash server *hot-server-cells*)))
  nil)

(defun hot-find-server (host port)
  "Locate a live hot-registered server for HOST:PORT.
When PORT is 0 under :hot and exactly one server is registered, return that server
(so re-evaluations that pass port:0 still reload the live listener)."
  (cond
    ((and (zerop port) (hot-soft-p))
     (let ((found nil) (n 0))
       (maphash (lambda (k v)
                  (declare (ignore k))
                  (incf n)
                  (setf found v))
                *hot-server-registry*)
       (when (= n 1) found)))
    (t (gethash (%serve-identity-key host port) *hot-server-registry*))))

(defun hot-server-reload (server opts)
  "Apply OPTS to an existing server via the same cells as server.reload."
  (let ((meta (gethash server *hot-server-cells*)))
    (unless meta
      (eng:throw-type-error "hot reload: server is not registered for identity reload"))
    (multiple-value-bind (new-fetch new-error new-routes new-ws)
        (%compile-serve-dispatch-options opts)
      (let ((fetch-cell (getf meta :fetch-cell))
            (err-cell (getf meta :err-handler-cell))
            (routes-cell (getf meta :routes-cell))
            (ws-cell (getf meta :websocket-cell)))
        (setf (car fetch-cell) new-fetch
              (car err-cell) new-error
              (car routes-cell) new-routes
              (car ws-cell) new-ws)))
    server))

(defun hot-stop-all-servers (&optional force)
  "Hard-watch path: stop every retained server so the next entry rebind succeeds."
  (let ((servers '()))
    (maphash (lambda (k v) (declare (ignore k)) (push v servers))
             *hot-server-registry*)
    (dolist (server servers)
      (ignore-errors
        (let ((stop (eng:js-get server "stop")))
          (when (eng:callable-p stop)
            (eng:js-call stop server (list (if force eng:+true+ eng:+false+)))))))
    (clrhash *hot-server-registry*)
    (clrhash *hot-server-cells*)))

;;; --- import.meta.hot state --------------------------------------------------

(defvar *hot-module-data* (make-hash-table :test 'equal)
  "resolved-path → persistent js-object for import.meta.hot.data across soft reloads.")

(defvar *hot-dispose-hooks* (make-hash-table :test 'equal)
  "resolved-path → list of dispose callbacks (newest first).")

(defvar *hot-accept-hooks* (make-hash-table :test 'equal)
  "resolved-path → list of accept callbacks.")

(defvar *hot-event-hooks* (make-hash-table :test 'equal)
  "resolved-path → alist of (event . callbacks).")

(defun %hot-data-for (path)
  (or (gethash path *hot-module-data*)
      (setf (gethash path *hot-module-data*) (eng:new-object))))

(defun %hot-run-dispose (path)
  (let ((hooks (gethash path *hot-dispose-hooks*)))
    (setf (gethash path *hot-dispose-hooks*) '())
    (dolist (cb (reverse hooks))
      (ignore-errors (eng:js-call cb eng:+undefined+ '())))))

(defun %hot-run-all-dispose ()
  (let ((paths '()))
    (maphash (lambda (k v) (declare (ignore v)) (push k paths))
             *hot-dispose-hooks*)
    (dolist (p paths) (%hot-run-dispose p))))

(defun make-import-meta-hot (path)
  "Bun/Vite-shaped import.meta.hot for PATH. Exceeds Bun's server --hot surface
(which documents import.meta.hot as planned)."
  (let ((hot (eng:new-object))
        (data (%hot-data-for path)))
    (eng:data-prop hot "data" data)
    (eng:install-method hot "accept" 2
      (lambda (this args)
        (declare (ignore this))
        (let ((a0 (eng:arg args 0))
              (a1 (eng:arg args 1)))
          (cond
            ((eng:callable-p a0)
             (push a0 (gethash path *hot-accept-hooks*)))
            ((or (eng:js-string-p a0) (eng:js-array-p a0))
             (when (eng:callable-p a1)
               (push a1 (gethash path *hot-accept-hooks*))))
            (t
             ;; bare accept() — mark self-accepting (no-op registry for server soft reload)
             (push (eng:make-native-function "" 0
                     (lambda (th a) (declare (ignore th a)) eng:+undefined+))
                   (gethash path *hot-accept-hooks*)))))
        eng:+undefined+))
    (eng:install-method hot "dispose" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((cb (eng:arg args 0)))
          (when (eng:callable-p cb)
            (push cb (gethash path *hot-dispose-hooks*))))
        eng:+undefined+))
    (eng:install-method hot "decline" 0
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method hot "invalidate" 0
      (lambda (this args)
        (declare (ignore this args))
        ;; Exceed Bun: request a full soft reload of the entry graph.
        (when *hot-session*
          (setf (hs-pending-reload *hot-session*) t))
        eng:+undefined+))
    (eng:install-method hot "on" 2
      (lambda (this args)
        (declare (ignore this))
        (let* ((ev (eng:to-string (eng:arg args 0)))
               (cb (eng:arg args 1))
               (alist (gethash path *hot-event-hooks*)))
          (when (eng:callable-p cb)
            (let ((entry (assoc ev alist :test #'string=)))
              (if entry
                  (push cb (cdr entry))
                  (setf (gethash path *hot-event-hooks*)
                        (acons ev (list cb) alist)))))
          eng:+undefined+)))
    (eng:install-method hot "off" 2
      (lambda (this args)
        (declare (ignore this))
        (let* ((ev (eng:to-string (eng:arg args 0)))
               (cb (eng:arg args 1))
               (alist (gethash path *hot-event-hooks*))
               (entry (assoc ev alist :test #'string=)))
          (when entry
            (setf (cdr entry) (remove cb (cdr entry) :test #'eq)))
          eng:+undefined+)))
    (eng:install-method hot "prune" 1
      (lambda (this args)
        (declare (ignore this))
        ;; Vite-compat no-op registration (Bun marks prune as WIP).
        (let ((cb (eng:arg args 0)))
          (declare (ignore cb)))
        eng:+undefined+))
    hot))

;;; --- session + watcher ------------------------------------------------------

(defstruct (hot-session (:conc-name hs-) (:constructor %make-hot-session))
  realm
  entry                                 ; absolute path
  mode                                  ; :hot | :watch
  (reloads 0)
  (last-error nil)                      ; string or NIL
  (last-reload-ms 0)
  (watched (make-hash-table :test 'equal)) ; path → (mtime size ino)
  (timer nil)
  (pending-reload nil)
  (coalesce-deadline 0)
  (coalesced-paths nil)                 ; paths accumulated during debounce window
  (reloading nil)
  (no-clear nil)
  (started-ms 0))

(defun %now-ms ()
  (truncate (/ (sys:monotonic-nanoseconds) 1000000)))

(defun %file-fingerprint (path)
  "Cheap content fingerprint (size + rolling hash) so same-second same-size
rewrites still count as changes when mtime is second-granularity."
  (handler-case
      (let* ((octets (sys:read-file-octets path))
             (n (length octets))
             (h 2166136261))            ; FNV-1a 32-bit offset basis
        (dotimes (i n)
          (setf h (logand #xffffffff
                          (* (logxor h (aref octets i)) 16777619))))
        (list n h))
    (error () nil)))

(defun %stat-signature (path)
  "Return (mtime-ns size ino content-fp) or NIL if PATH is unreadable.
Content fingerprint exceeds pure mtime watchers that miss same-second rewrites."
  (handler-case
      (let ((st (sys:stat* path))
            (fp (%file-fingerprint path)))
        (list (sys:fstat-mtime-ns st)
              (sys:fstat-size st)
              (sys:fstat-ino st)
              fp))
    (error () nil)))

(defun %node-modules-path-p (path)
  (or (search "/node_modules/" path)
      (search "\\node_modules\\" path)
      (and (>= (length path) 13)
           (string= "node_modules/" path :end2 13))))

(defun %virtual-module-key-p (key)
  "True for non-filesystem registry keys (node:/bun: builtins)."
  (or (zerop (length key))
      (char= (char key 0) #\Nul)
      (and (>= (length key) 5) (string= key "node:" :end1 5))
      (and (>= (length key) 4) (string= key "bun:" :end1 4))
      (and (>= (length key) 8) (string= key "builtin:" :end1 8))))

(defun reloadable-module-key-p (key)
  (and (not (%virtual-module-key-p key))
       (not (%node-modules-path-p key))))

(defun clear-reloadable-modules (realm)
  "Drop user source modules from REALM's registry; keep builtins and node_modules."
  (let ((tbl (eng::realm-modules realm)))
    (when tbl
      (let ((drop '()))
        (maphash (lambda (k v)
                   (declare (ignore v))
                   (when (reloadable-module-key-p k)
                     (push k drop)))
                 tbl)
        (dolist (k drop) (remhash k tbl)))))
  (values))

(defun %refresh-watch-set (session)
  "Rebuild the watch set from the realm module registry (user sources only)."
  (let ((tbl (eng::realm-modules (hs-realm session)))
        (watched (hs-watched session))
        (keep (make-hash-table :test 'equal)))
    (when tbl
      (maphash
       (lambda (path mr)
         (declare (ignore mr))
         (when (and (reloadable-module-key-p path)
                    (sys:file-p path))
           (setf (gethash path keep) t)
           (unless (gethash path watched)
             (setf (gethash path watched) (%stat-signature path)))))
       tbl))
    ;; drop paths no longer in the graph
    (let ((gone '()))
      (maphash (lambda (p sig)
                 (declare (ignore sig))
                 (unless (gethash p keep) (push p gone)))
               watched)
      (dolist (p gone) (remhash p watched)))
    ;; always watch the entry
    (let ((entry (hs-entry session)))
      (when (sys:file-p entry)
        (setf (gethash entry watched)
              (or (gethash entry watched) (%stat-signature entry)))))
    watched))

(defun %detect-changes (session)
  "Return list of changed paths (empty if none). Updates stored signatures."
  (let ((changed '())
        (watched (hs-watched session)))
    (maphash
     (lambda (path old)
       (let ((new (%stat-signature path)))
         (cond
           ((null new)
            ;; deleted — treat as change, drop from set
            (push path changed)
            (remhash path watched))
           ((or (null old)
                (not (equal old new)))
            (push path changed)
            (setf (gethash path watched) new)))))
     watched)
    changed))

(defun %maybe-clear-screen (session)
  (unless (hs-no-clear session)
    (ignore-errors
      (write-string #.(format nil "~c[2J~c[H" #\Escape #\Escape) *standard-output*)
      (finish-output *standard-output*))))

(defun %report-reload (session kind paths &optional error)
  (let ((msg (format nil "[clun ~a] ~a reload #~d~@[: ~a~]~@[ (~{~a~^, ~})~]~%"
                     (string-downcase (symbol-name (hs-mode session)))
                     kind
                     (hs-reloads session)
                     error
                     (mapcar #'sys:path-basename paths))))
    (write-string msg *error-output*)
    (finish-output *error-output*)))

(defun %soft-reload (session &optional paths)
  "Soft reload: dispose hooks → clear user modules → re-evaluate entry.
Servers keep listening; re-eval of Clun.serve hits the identity registry."
  (when (hs-reloading session)
    (return-from %soft-reload nil))
  (setf (hs-reloading session) t
        (hs-pending-reload session) nil)
  (let* ((realm (hs-realm session))
         (entry (hs-entry session))
         (t0 (%now-ms))
         (ok t)
         (err nil))
    (let ((eng:*realm* realm))
      (handler-case
          (progn
            (%hot-run-all-dispose)
            (clear-reloadable-modules realm)
            (multiple-value-bind (path format)
                (eng::resolve-specifier
                 (eng::entry->specifier entry)
                 (sys:path-dirname entry)
                 '("node" "import"))
              (let ((mr (eng::load-any path format)))
                (setf (eng::realm-entry-module realm) mr)
                (eng::evaluate-module mr)
                (let ((loop (eng:current-loop)))
                  (when loop (lp:drain-microtasks loop)))))
            (incf (hs-reloads session))
            (setf (hs-last-error session) nil
                  (hs-last-reload-ms session) (- (%now-ms) t0))
            (%refresh-watch-set session)
            (%report-reload session "soft" paths))
        (eng:js-condition (c)
          (setf ok nil
                err (%hot-error-string (eng:js-condition-value c))
                (hs-last-error session) err)
          (%report-reload session "FAILED soft" paths err))
        (error (c)
          (setf ok nil
                err (princ-to-string c)
                (hs-last-error session) err)
          (%report-reload session "FAILED soft" paths err))))
    (setf (hs-reloading session) nil)
    ok))

(defun %hot-error-string (value)
  "Safe short error text for JS error objects (avoid circular inspect)."
  (handler-case
      (if (eng:js-object-p value)
          (let ((name (eng:js-get value "name"))
                (msg (eng:js-get value "message")))
            (format nil "~a: ~a"
                    (if (eng:js-string-p name) (eng:to-string name) "Error")
                    (if (eng:js-string-p msg) (eng:to-string msg) "")))
          (princ-to-string value))
    (error () "reload error")))

(defun %hard-reload (session &optional paths)
  "Watch-mode restart: stop servers, clear modules, re-run entry from scratch."
  (when (hs-reloading session)
    (return-from %hard-reload nil))
  (setf (hs-reloading session) t
        (hs-pending-reload session) nil)
  (let* ((realm (hs-realm session))
         (entry (hs-entry session))
         (t0 (%now-ms))
         (ok t)
         (err nil))
    (let ((eng:*realm* realm))
      (handler-case
          (progn
            (%maybe-clear-screen session)
            (%hot-run-all-dispose)
            (hot-stop-all-servers t)
            (clear-reloadable-modules realm)
            ;; drop hot module data on hard restart (process-like)
            (clrhash *hot-module-data*)
            (clrhash *hot-dispose-hooks*)
            (clrhash *hot-accept-hooks*)
            (clrhash *hot-event-hooks*)
            (multiple-value-bind (path format)
                (eng::resolve-specifier
                 (eng::entry->specifier entry)
                 (sys:path-dirname entry)
                 '("node" "import"))
              (let ((mr (eng::load-any path format)))
                (setf (eng::realm-entry-module realm) mr)
                (eng::evaluate-module mr)
                (let ((loop (eng:current-loop)))
                  (when loop (lp:drain-microtasks loop)))))
            (incf (hs-reloads session))
            (setf (hs-last-error session) nil
                  (hs-last-reload-ms session) (- (%now-ms) t0))
            (%refresh-watch-set session)
            (%report-reload session "hard" paths))
        (eng:js-condition (c)
          (setf ok nil
                err (%hot-error-string (eng:js-condition-value c))
                (hs-last-error session) err)
          (%report-reload session "FAILED hard" paths err))
        (error (c)
          (setf ok nil
                err (princ-to-string c)
                (hs-last-error session) err)
          (%report-reload session "FAILED hard" paths err))))
    (setf (hs-reloading session) nil)
    ok))

(defun %poll-tick (session)
  "One watcher tick: detect changes, coalesce across ticks, fire reload."
  (when (hs-reloading session)
    (return-from %poll-tick nil))
  (let ((changed (%detect-changes session))
        (now (%now-ms)))
    (when (hs-pending-reload session)
      (pushnew (hs-entry session) changed :test #'string=)
      (setf (hs-pending-reload session) nil))
    (when changed
      (setf (hs-coalesced-paths session)
            (union (hs-coalesced-paths session) changed :test #'string=))
      (when (zerop (hs-coalesce-deadline session))
        (setf (hs-coalesce-deadline session) (+ now *hot-coalesce-ms*))))
    ;; Fire once the debounce window elapses, even if this tick saw no new diffs
    ;; (signatures were already advanced on the first detection tick).
    (when (and (plusp (hs-coalesce-deadline session))
               (>= now (hs-coalesce-deadline session))
               (hs-coalesced-paths session))
      (let ((paths (hs-coalesced-paths session)))
        (setf (hs-coalesce-deadline session) 0
              (hs-coalesced-paths session) nil)
        (if (eq (hs-mode session) :hot)
            (%soft-reload session paths)
            (%hard-reload session paths))))
    nil))

(defun %arm-poll-timer (session)
  (let* ((realm (hs-realm session))
         (loop (or (eng::realm-loop realm)
                   (and eng:*realm* (eng:current-loop)))))
    (unless loop
      (return-from %arm-poll-timer nil))
    (when (null (eng::realm-loop realm))
      (setf (eng::realm-loop realm) loop))
    (let ((timer
            (lp:set-timer
             loop *hot-poll-ms*
             (lambda ()
               (let ((eng:*realm* realm)
                     (*hot-session* session)
                     (*hot-reload-mode* (hs-mode session)))
                 (handler-case (%poll-tick session)
                   (error (c)
                     (%report-reload session "poll-error" nil
                                     (princ-to-string c))))))
             :repeat *hot-poll-ms*
             :refd t)))
      (setf (hs-timer session) timer)
      timer)))

(defun hot-poll-now ()
  "Opportunity poll: call from the serve accept path so reloads fire even when
the reactor is busy with connections (exceeds Bun's FS-watcher-only path)."
  (when (and *hot-session* (hot-mode-p) (not (hs-reloading *hot-session*)))
    (handler-case (%poll-tick *hot-session*)
      (error () nil)))
  (values))

(defun make-hot-session (realm entry mode &key no-clear)
  (%make-hot-session
   :realm realm
   :entry entry
   :mode mode
   :no-clear no-clear
   :started-ms (%now-ms)))

(defun start-hot-session (session)
  "Populate the initial watch set and arm the poll timer. Caller drives the loop."
  (setf *hot-session* session
        *hot-reload-mode* (hs-mode session)
        *hot-no-clear-screen* (hs-no-clear session))
  (%refresh-watch-set session)
  (%arm-poll-timer session)
  session)

(defun stop-hot-session (session)
  (when (hs-timer session)
    (ignore-errors (lp:clear-timer (hs-timer session)))
    (setf (hs-timer session) nil))
  (when (eq *hot-session* session)
    (setf *hot-session* nil))
  session)

;;; --- Clun.hot public surface ------------------------------------------------

(defun %install-clun-hot (clun g)
  "Attach Clun.hot introspection (exceeds Bun CLI-only --hot).
Mode/reloads are live getters so install-time mode (before --hot arms) is fine."
  (declare (ignore g))
  (let ((hot (eng:new-object)))
    (eng:install-getter hot "mode"
      (lambda (this args)
        (declare (ignore this args))
        (if *hot-reload-mode*
            (string-downcase (symbol-name *hot-reload-mode*))
            eng:+undefined+)))
    (eng:install-method hot "reloads" 0
      (lambda (this args)
        (declare (ignore this args))
        (coerce (if *hot-session* (hs-reloads *hot-session*) 0) 'double-float)))
    (eng:install-method hot "lastError" 0
      (lambda (this args)
        (declare (ignore this args))
        (if (and *hot-session* (hs-last-error *hot-session*))
            (hs-last-error *hot-session*)
            eng:+null+)))
    (eng:install-method hot "lastReloadMs" 0
      (lambda (this args)
        (declare (ignore this args))
        (coerce (if *hot-session* (hs-last-reload-ms *hot-session*) 0)
                'double-float)))
    (eng:install-method hot "watched" 0
      (lambda (this args)
        (declare (ignore this args))
        (let ((paths '()))
          (when *hot-session*
            (maphash (lambda (p sig)
                       (declare (ignore sig))
                       (push p paths))
                     (hs-watched *hot-session*)))
          (eng:new-array (sort paths #'string<)))))
    (eng:install-method hot "reload" 0
      (lambda (this args)
        (declare (ignore this args))
        (when *hot-session*
          (if (eq (hs-mode *hot-session*) :hot)
              (%soft-reload *hot-session* (list (hs-entry *hot-session*)))
              (%hard-reload *hot-session* (list (hs-entry *hot-session*)))))
        eng:+undefined+))
    (eng:data-prop clun "hot" hot)
    hot))

;;; --- CLI entry: run file under hot/watch ------------------------------------

(defun run-file-with-hot (realm entry mode &key no-clear)
  "Evaluate ENTRY in REALM under MODE (:hot or :watch), arm the watcher, drive the
event loop until idle/exit. Returns an exit code integer."
  (let* ((*hot-reload-mode* mode)
         (*hot-no-clear-screen* no-clear)
         (session (make-hot-session realm entry mode :no-clear no-clear)))
    ;; reset per-run tables
    (clrhash *hot-server-registry*)
    (clrhash *hot-server-cells*)
    (clrhash *hot-module-data*)
    (clrhash *hot-dispose-hooks*)
    (clrhash *hot-accept-hooks*)
    (clrhash *hot-event-hooks*)
    (let ((eng:*realm* realm))
      (unwind-protect
           (progn
             (multiple-value-bind (path format)
                 (eng::resolve-specifier
                  (eng::entry->specifier entry)
                  (sys:path-dirname entry)
                  '("node" "import"))
               (let ((mr (eng::load-any path format)))
                 (setf (eng::realm-entry-module realm) mr)
                 (eng::evaluate-module mr)))
             (start-hot-session session)
             (eng:drive-jobs realm)
             (eng::report-unhandled-rejections realm)
             (let* ((proc (eng:js-get (eng:realm-global realm) "process"))
                    (code (if (eng:js-object-p proc)
                              (safe-integer (eng:js-get proc "exitCode"))
                              0)))
               (run-exit-handlers code)
               code))
        (stop-hot-session session)
        (hot-stop-all-servers t)
        (setf *hot-reload-mode* nil)
        (eng:teardown-realm realm)))))

;;; --- test/programmatic helpers (exported for Lisp suite) --------------------

(defun hot-soft-reload-now (&optional session)
  "Force a soft reload (tests)."
  (let ((s (or session *hot-session*)))
    (when s (%soft-reload s (list (hs-entry s))))))

(defun hot-hard-reload-now (&optional session)
  (let ((s (or session *hot-session*)))
    (when s (%hard-reload s (list (hs-entry s))))))

(defun hot-session-reloads (&optional session)
  (let ((s (or session *hot-session*)))
    (if s (hs-reloads s) 0)))

(defun hot-session-last-error (&optional session)
  (let ((s (or session *hot-session*)))
    (and s (hs-last-error s))))
