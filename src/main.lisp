;;;; main.lisp — the CLI toplevel (PLAN.md §3.6, Phase 08). Parses flags, installs
;;;; the runtime globals onto a fresh realm, autoloads .env, runs the entry, renders
;;;; uncaught errors (JS stack; Lisp backtrace only with --backtrace), maps to an
;;;; exit code (0 ok / 1 error / 2 usage).

(in-package :clun)

(defun print-version (&optional (stream *standard-output*))
  (format stream "clun ~a~%" *clun-version*))

(defun print-help (&optional (stream *standard-output*))
  (format stream "clun ~a — Bun, rewritten in pure Common Lisp~%~
                  ~%~
                  Usage: clun <file>              run a .js/.mjs/.cjs/.json file~%~
                  ~8@Tclun run <file>          run a file (package scripts: Phase 24)~%~
                  ~8@Tclun -e '<code>'         evaluate code~%~
                  ~8@Tclun -p '<code>'         evaluate and print the (awaited) result~%~
                  ~8@Tclun exec '<script>'      execute a Clun shell script~%~
                  ~8@Tclun install            install package.json deps into node_modules~%~
                  ~8@Tclun add <pkg>          add a dependency (-d dev, -E exact) + install~%~
                  ~8@Tclun remove <pkg>       remove a dependency + reinstall~%~
                  ~8@Tclun build <entry…>     production bundle (Clun.build / Bun.build)~%~
                  ~8@Tclun fmt [paths…]       format JS/TS/JSON/YAML/CSS (check/write/stdin)~%~
                  ~8@Tclun lint [paths…]      lint JS/TS with recommended ruleset~%~
                  ~8@Tclun build --compile <entry> --outfile <bin>   single-file executable~%~
                  ~8@Tclun compile <entry> …  alias of build --compile~%~
                  ~8@Tclun tsc <file…>        structural TypeScript typecheck (exceeds Bun strip)~%~
                  ~8@Tclun run [--filter <p>] <script>  run package.json scripts (filtered monorepo)~%~
                  ~%~
                  Flags: --cwd <dir>   set the working directory~%~
                  ~8@T--hot            soft-reload modules; preserve server connections~%~
                  ~8@T--watch          hard-restart on change (stops retained servers)~%~
                  ~8@T--no-clear-screen  keep terminal output across watch reloads~%~
                  ~8@T--filter/-F <p>   monorepo package name or ./path filter (repeatable)~%~
                  ~8@T--workspaces     run a script across every workspace package~%~
                  ~8@T--parallel       concurrent filtered scripts (topo waves)~%~
                  ~8@T--sequential     sequential filtered scripts~%~
                  ~8@T--concurrency N  max concurrent workspace scripts (default 4)~%~
                  ~8@T--silent          suppress console.log/info/debug~%~
                  ~8@T--backtrace       show the Lisp backtrace on an internal error~%~
                  ~8@T-v, --version     print the version~%~
                  ~8@T--revision        print the build revision~%~
                  ~8@T-h, --help        print this help~%"
          *clun-version*))

;;; --- uncaught-error rendering ----------------------------------------------

(defun error-object-p (v)
  (and (eng:js-object-p v) (eq (eng:js-object-class v) :error)))

(defun render-uncaught (value)
  "Print an uncaught JS VALUE to stderr, Bun-style."
  (if (error-object-p value)
      (let ((stack (eng:js-get value "stack")))
        (if (stringp stack)
            (format *error-output* "~a~%" stack)
            (format *error-output* "Uncaught ~a: ~a~%"
                    (eng:to-string (eng:js-get value "name"))
                    (eng:to-string (eng:js-get value "message")))))
      (format *error-output* "Uncaught ~a~%" (eng:inspect-value value))))

;;; --- run helpers ------------------------------------------------------------

(defun resolve-cwd (r)
  (let ((cwd (cli:cli-get r :cwd)))
    (when cwd
      (handler-case (sys:change-directory cwd)
        (error () (error 'bad-cwd :dir cwd))))
    (sys:current-directory)))

(define-condition bad-cwd (error)
  ((dir :initarg :dir :reader bad-cwd-dir)))

(defun make-runtime-realm (r cwd &key script rest)
  "A fresh realm with the runtime globals installed + .env autoloaded."
  (let ((realm (eng:make-realm)))
    (rt:install-runtime realm
                        :argv (list :script script :rest rest)
                        :cwd cwd
                        :silent (cli:cli-get r :silent))
    (let ((proc (eng:js-get (eng:realm-global realm) "process")))
      (when (eng:js-object-p proc)
        (cli:load-dotenv (eng:js-get proc "env") cwd)))
    realm))

(defun bun-shell-file-p (path)
  (let ((suffix ".bun.sh"))
    (and (>= (length path) (length suffix))
         (string= suffix path :start2 (- (length path) (length suffix))))))

(defun run-shell-file (path rest cwd)
  (multiple-value-bind (stdout stderr status)
      (rt:execute-shell-script
       (eng:utf8->code-units (sys:read-file-octets path))
       :cwd cwd
       :env (sys:environ-alist)
       :positionals (cons path rest))
    (when (plusp (length stdout))
      (sys:write-fd-octets 1 stdout))
    (when (plusp (length stderr))
      (sys:write-fd-octets 2 stderr))
    status))

(defun run-file (r file &key (rest (cli:cli-get r :args)))
  "Execute FILE (a path). Returns an exit code. REST is process.argv after the script (defaults to
the CLI's trailing args). .ts/.mts/.cts are stripped by *ts-strip-hook*; .jsx/.tsx are lowered by
*jsx-transform-hook* then (for .tsx) type-stripped.
With --hot / --watch, state-preserving (or hard) reload is armed for the process lifetime."
  (cond
    ((null file)
     (format *error-output* "clun: no file to run~%") 2)
    (t
     (let* ((cwd (resolve-cwd r))
            (abs (if (sys:absolute-path-p file) file (sys:path-join cwd file)))
            (hot (cli:cli-get r :hot))
            (watch (cli:cli-get r :watch))
            (no-clear (cli:cli-get r :no-clear-screen)))
       (if (not (sys:file-p abs))
           (progn (format *error-output* "clun: cannot find module '~a'~%" file) 1)
           (if (bun-shell-file-p abs)
               (run-shell-file abs rest cwd)
               (let ((realm (make-runtime-realm r cwd :script abs :rest rest)))
                 (let ((clun-g (eng:js-get (eng:realm-global realm) "Clun")))
                   (when (eng:js-object-p clun-g) (eng:data-prop clun-g "main" abs)))
                 (cond
                   (hot
                    (rt::run-file-with-hot realm abs :hot :no-clear no-clear))
                   (watch
                    (rt::run-file-with-hot realm abs :watch :no-clear no-clear))
                   (t
                    (eng:run-module-file abs :realm realm)
                    (finish-exit realm))))))))))

(defun run-test (r)
  "`clun test` — resolve cwd (honouring --cwd), then hand the test-subcommand argv
(file + trailing args, verbatim) to the test runner."
  (let ((cwd (resolve-cwd r))
        (argv (remove nil (cons (cli:cli-get r :file) (cli:cli-get r :args)))))
    (clun.test-runner:run-test-command argv cwd)))

(defun print-exec-help (&optional (stream *standard-output*))
  (format stream "Usage: clun exec <script>~%~
                  ~%~
                  Execute a shell script directly from Clun.~%~
                  ~%~
                  Note: If executing this from a shell, make sure to escape the string!~%~
                  ~%~
                  Examples:~%~
                  ~2@Tclun exec \"echo hi\"~%~
                  ~2@Tclun exec \"echo \\\"hey friends\\\"!\"~%"))

(defun run-exec (r)
  "Execute the `clun exec` source through Clun's in-process shell engine."
  (let ((parts (remove nil (cons (cli:cli-get r :file) (cli:cli-get r :args)))))
    (when (null parts)
      (print-exec-help)
      (return-from run-exec 0))
    (multiple-value-bind (stdout stderr status)
        (rt:execute-shell-script
         (format nil "~{~a~^ ~}" parts)
         :cwd (resolve-cwd r)
         :env (sys:environ-alist))
      (when (plusp (length stdout))
        (sys:write-fd-octets 1 stdout))
      (when (plusp (length stderr))
        (sys:write-fd-octets 2 stderr))
      (if (= status 127) 1 status))))

;;; --- install / add / remove -------------------------------------------------

(defun %flag-p (tok) (and (plusp (length tok)) (char= (char tok 0) #\-)))

(defun run-install-command (r)
  "Handle `clun install` / `add <pkg…>` / `remove <pkg…>`: edit package.json for add/remove, then
install. Flags: -d/-D/--dev, -E/--exact, --frozen-lockfile, --production, --dry-run, --registry,
--filter/-F (monorepo package selection)."
  (let ((sub (cli:cli-get r :subcommand))
        (cwd (resolve-cwd r))
        (names '()) (registry nil) (filters '())
        (dev nil) (exact nil) (frozen nil) (production nil) (dry-run nil))
    ;; walk the tokens: --registry/--filter consume values; other flags set booleans;
    ;; everything else is a package name.
    (loop with rest = (remove nil (cons (cli:cli-get r :file) (cli:cli-get r :args)))
          while rest
          for tok = (pop rest) do
            (cond
              ((member tok '("-d" "-D" "--dev" "--development") :test #'string=) (setf dev t))
              ((member tok '("-E" "--exact") :test #'string=) (setf exact t))
              ((string= tok "--frozen-lockfile") (setf frozen t))
              ((string= tok "--production") (setf production t))
              ((string= tok "--dry-run") (setf dry-run t))
              ((string= tok "--no-save") nil)                 ; accepted; no-op here
              ((member tok '("--filter" "-F") :test #'string=)
               (if (and rest (not (%flag-p (car rest))))
                   (push (pop rest) filters)
                   (error 'clun.installer:install-error :message "--filter requires a value")))
              ((and (> (length tok) 9) (string= "--filter=" tok :end2 9))
               (push (subseq tok 9) filters))
              ((string= tok "--registry")
               (if (and rest (not (%flag-p (car rest))))
                   (setf registry (pop rest))
                   (error 'clun.installer:install-error :message "--registry requires a value")))
              ((and (> (length tok) 11) (string= "--registry=" tok :end2 11)) (setf registry (subseq tok 11)))
              ((%flag-p tok) nil)                             ; ignore any other flag
              (t (push tok names))))
    (setf names (nreverse names) filters (nreverse filters))
    (handler-case
        (progn
          (cond
            ((string= sub "add")
             (when (null names) (error 'clun.installer:install-error :message "add: no packages given"))
             (if dry-run
                 (format t "clun add (dry-run): ~{~a~^, ~}~%" names)
                 (progn (clun.installer:add-dependencies cwd names :dev dev :exact exact :registry registry)
                        (clun.installer:install cwd :registry registry :production production
                                                :filters filters)
                        (format t "installed ~{~a~^, ~}~%" names))))
            ((string= sub "remove")
             (when (null names) (error 'clun.installer:install-error :message "remove: no packages given"))
             (if dry-run
                 (format t "clun remove (dry-run): ~{~a~^, ~}~%" names)
                 (progn (clun.installer:remove-dependencies cwd names)
                        (clun.installer:install cwd :registry registry :production production
                                                :filters filters)
                        (format t "removed ~{~a~^, ~}~%" names))))
            (t
             (if dry-run
                 (format t "clun install (dry-run)~%")
                 (let ((res (clun.installer:install cwd :registry registry :frozen frozen
                                                        :production production :filters filters)))
                   (format t "clun install: ~(~a~), ~d package~:p~%"
                           (clun.installer:ir-source res) (clun.installer:ir-node-count res))
                   (dolist (s (clun.installer:ir-lifecycle-skipped res))
                     (format t "  note: lifecycle scripts skipped for ~a (clun never runs them)~%" s))))))
          0)
      (clun.installer:install-error (e)
        (format *error-output* "clun: ~a~%" (clun.installer:install-error-message e)) 1)
      (clun.registry:registry-error (e)
        (format *error-output* "clun: ~a~%" (clun.registry:registry-error-message e)) 1)
      (clun.integrity:integrity-error (e)
        (format *error-output* "clun: integrity error: ~a~%" (clun.integrity:integrity-error-message e)) 1)
      (clun.tarball:tarball-error (e)
        (format *error-output* "clun: tarball error: ~a~%" (clun.tarball:tarball-error-message e)) 1))))

;;; --- clun run <script> (package.json scripts, §3.6) ------------------------

(defun %nearest-package-json (dir)
  "Walk up from DIR to the nearest package.json → (values parsed-json pkg-dir pkg-json-path) or NILs."
  (loop for d = dir then (sys:path-dirname d)
        for pj = (sys:path-join d "package.json")
        when (sys:file-p pj)
          return (values (ignore-errors (sys:parse-json (sys:read-file-string pj))) d pj)
        when (string= d (sys:path-dirname d)) return (values nil nil nil)))

(defun %script-path (cwd)
  "PATH with node_modules/.bin for CWD + every ancestor (nearest first) prepended to the real PATH."
  (let ((bins '()))
    (loop for d = cwd then (sys:path-dirname d)
          do (push (sys:path-join d "node_modules" ".bin") bins)
          until (string= d (sys:path-dirname d)))
    (format nil "~{~a:~}~a" (nreverse bins) (or (sys:getenv "PATH") ""))))

(defun %script-env (pkg pkg-json cwd event)
  "The env for a script: the current environment + npm_* vars + the .bin-augmented PATH, as K=V."
  (let ((env (sys:environ-alist)))
    (flet ((setv (k v) (let ((c (assoc k env :test #'string=)))
                         (if c (setf (cdr c) v) (setf env (cons (cons k v) env))))))
      (setv "PATH" (%script-path cwd))
      (setv "npm_lifecycle_event" event)
      (setv "npm_config_user_agent" (format nil "clun/~a" *clun-version*))
      (setv "npm_execpath" (or (first sb-ext:*posix-argv*) "clun"))
      (when pkg-json (setv "npm_package_json" pkg-json))
      (when (and pkg (sys:jobject-p pkg))
        (let ((n (sys:jget pkg "name")) (v (sys:jget pkg "version")))
          (when (stringp n) (setv "npm_package_name" n))
          (when (stringp v) (setv "npm_package_version" v)))))
    (loop for (k . v) in env collect (format nil "~a=~a" k v))))

(defun %sh-quote (s)
  "Single-quote S for /bin/sh (each ' becomes '\\'')."
  (with-output-to-string (o)
    (write-char #\' o)
    (loop for c across s do (if (char= c #\') (write-string "'\\''" o) (write-char c o)))
    (write-char #\' o)))

(defun %run-sh (command cwd env)
  "Run `/bin/sh -c COMMAND` inheriting stdio, in CWD with ENV. Returns the exit code (128+sig on a
signal). A missing/unexecutable /bin/sh is reported as a clean message + exit 127."
  (let ((proc (handler-case
                  (sb-ext:run-program "/bin/sh" (list "-c" command)
                                      :wait t :input t :output t :error t :directory cwd :environment env)
                (error (e)
                  (format *error-output* "clun: cannot exec /bin/sh: ~a~%" e)
                  (return-from %run-sh 127)))))
    (let ((status (sb-ext:process-status proc))
          (code (sb-ext:process-exit-code proc)))
      (if (eq status :signaled) (+ 128 (or code 0)) (or code 1)))))

(defun %run-package-script (pkg pkg-json cwd name pre-cmd cmd post-cmd passthrough)
  "Run pre<name> (a failing pre aborts) → <name> (+ passthrough args) → post<name>. Exit code
propagates; the first nonzero stage's code is returned."
  (when (stringp pre-cmd)
    (let ((code (%run-sh pre-cmd cwd (%script-env pkg pkg-json cwd (concatenate 'string "pre" name)))))
      (unless (zerop code) (return-from %run-package-script code))))
  (let* ((full (if passthrough (format nil "~a~{ ~a~}" cmd (mapcar #'%sh-quote passthrough)) cmd))
         (code (%run-sh full cwd (%script-env pkg pkg-json cwd name))))
    (unless (zerop code) (return-from %run-package-script code))
    (when (stringp post-cmd)
      (let ((pcode (%run-sh post-cmd cwd (%script-env pkg pkg-json cwd (concatenate 'string "post" name)))))
        (unless (zerop pcode) (return-from %run-package-script pcode))))
    0))

(defun run-script (r)
  "`clun run <name> [args]`: run a package.json script (`/bin/sh -c`, ancestor .bin PATH, pre/post,
npm_* env, arg passthrough); if <name> is not a script, fall through to running it as a FILE
(script-first, file-fallback). `--if-present` on a missing script exits 0.
With `--filter` / `--workspaces`, run the script across monorepo packages (topological concurrent
waves with `--parallel`, sequential with `--sequential`; exceeds Bun with `--concurrency`)."
  (let* ((cwd (resolve-cwd r))
         (toks (remove nil (cons (cli:cli-get r :file) (cli:cli-get r :args))))
         (if-present nil) (name nil) (passthrough '())
         (filters '()) (workspaces nil) (parallel t) (concurrency 4)
         (exit-on-error t))
    (loop with rest = toks while rest for tok = (pop rest) do
      (cond ((string= tok "--if-present") (setf if-present t))
            ((string= tok "--workspaces") (setf workspaces t))
            ((string= tok "--parallel") (setf parallel t))
            ((string= tok "--sequential") (setf parallel nil))
            ((string= tok "--no-exit-on-error") (setf exit-on-error nil))
            ((member tok '("--filter" "-F") :test #'string=)
             (if (and rest (not (%flag-p (car rest))))
                 (push (pop rest) filters)
                 (progn (format *error-output* "clun run: --filter requires a value~%")
                        (return-from run-script 2))))
            ((and (> (length tok) 9) (string= "--filter=" tok :end2 9))
             (push (subseq tok 9) filters))
            ((string= tok "--concurrency")
             (if (and rest (not (%flag-p (car rest))))
                 (setf concurrency (max 1 (or (parse-integer (pop rest) :junk-allowed t) 4)))
                 (progn (format *error-output* "clun run: --concurrency requires a value~%")
                        (return-from run-script 2))))
            ((and (> (length tok) 14) (string= "--concurrency=" tok :end2 14))
             (setf concurrency (max 1 (or (parse-integer (subseq tok 14) :junk-allowed t) 4))))
            ((%flag-p tok) nil)                    ; ignore other leading flags before the name
            (t (setf name tok passthrough rest) (return))))
    (setf filters (nreverse filters))
    (when (null name)
      (format *error-output* "clun run: no script or file specified~%")
      (return-from run-script 2))
    ;; Filtered / workspaces monorepo script execution.
    (when (or filters workspaces)
      (return-from run-script
        (handler-case
            (let* ((graph (clun.installer:discover-workspaces cwd))
                   (pkgs (if workspaces
                             (clun.installer:filter-workspaces graph filters :include-root t)
                             (clun.installer:filter-workspaces graph filters :include-root t))))
              (when (null pkgs)
                (format *error-output* "clun run: no packages matched filters~%")
                (return-from run-script 1))
              (clun.installer:run-workspace-scripts
               graph pkgs name
               :parallel parallel :concurrency concurrency
               :exit-on-error exit-on-error :if-present if-present
               :passthrough passthrough))
          (clun.installer:install-error (e)
            (format *error-output* "clun: ~a~%" (clun.installer:install-error-message e))
            1))))
    (multiple-value-bind (pkg pkg-dir pkg-json) (%nearest-package-json cwd)
      (declare (ignore pkg-dir))
      (let* ((scripts (and pkg (sys:jobject-p pkg) (sys:jget pkg "scripts")))
             (cmd (and scripts (sys:jobject-p scripts) (sys:jget scripts name))))
        (cond
          ((stringp cmd)
           (%run-package-script pkg pkg-json cwd name
                                (and (sys:jobject-p scripts) (sys:jget scripts (concatenate 'string "pre" name)))
                                cmd
                                (and (sys:jobject-p scripts) (sys:jget scripts (concatenate 'string "post" name)))
                                passthrough))
          (if-present 0)                            ; --if-present + no such script → nothing, success
          ;; not a script → run it as a file, with the post-name tokens as its argv (a leading flag
          ;; before the name would otherwise leave the name itself in the CLI's trailing args)
          (t (run-file r name :rest passthrough)))))))

(defun run-eval (r code print)
  "Evaluate CODE (script semantics; drives the loop). If PRINT, print the completion."
  (let* ((cwd (resolve-cwd r))
         (realm (make-runtime-realm r cwd :script "[eval]" :rest (cli:cli-get r :args)))
         (value (eng:eval-source code :realm realm)))
    (when print
      (let ((v (if (and (eng:js-promise-p value)
                        (not (eq (eng:js-promise-pstate value) :pending)))
                   (eng:js-promise-value value)   ; -p awaits the promise
                   value)))
        ;; a top-level string prints RAW (Node/Bun `-p '"x"'` → x); else inspected
        (%write-out (if (stringp v) v (eng:inspect-value v)))))
    (finish-exit realm)))

(defun %write-out (text)
  (write-string text *standard-output*) (write-char #\Newline *standard-output*)
  (finish-output *standard-output*))

(defun finish-exit (realm)
  "Normal completion: fire process 'exit' handlers with process.exitCode, return it."
  (let* ((proc (eng:js-get (eng:realm-global realm) "process"))
         (code (if (eng:js-object-p proc) (rt:safe-integer (eng:js-get proc "exitCode")) 0)))
    (rt:run-exit-handlers code)
    code))

;;; --- fmt (tooling.formatter-linter #190) ------------------------------------

(defun run-fmt-command (r)
  "Handle `clun fmt|format [paths…]` — first-party pure-CL formatter.
Flags: --check (exit 1 if would change), --write (rewrite files), --stdin,
--indent N, --print-width N, --no-semi, --single-quote."
  (let ((cwd (resolve-cwd r))
        (paths '())
        (check nil) (write nil) (stdin nil)
        (indent 2) (print-width 80) (semicolons t) (single-quote nil))
    (loop with rest = (remove nil (cons (cli:cli-get r :file) (cli:cli-get r :args)))
          while rest
          for tok = (pop rest) do
            (cond
              ((string= tok "--check") (setf check t))
              ((string= tok "--write") (setf write t))
              ((member tok '("--stdin" "-") :test #'string=) (setf stdin t))
              ((member tok '("--indent" "-i") :test #'string=)
               (if (and rest (not (%flag-p (car rest))))
                   (setf indent (max 0 (or (parse-integer (pop rest) :junk-allowed t) 2)))
                   (progn (format *error-output* "clun fmt: --indent needs a value~%")
                          (return-from run-fmt-command 2))))
              ((string= tok "--print-width")
               (if (and rest (not (%flag-p (car rest))))
                   (setf print-width (max 1 (or (parse-integer (pop rest) :junk-allowed t) 80)))
                   (progn (format *error-output* "clun fmt: --print-width needs a value~%")
                          (return-from run-fmt-command 2))))
              ((string= tok "--no-semi") (setf semicolons nil))
              ((string= tok "--single-quote") (setf single-quote t))
              ((member tok '("-h" "--help") :test #'string=)
               (format t "Usage: clun fmt [paths…] [--check] [--write] [--stdin]~%")
               (return-from run-fmt-command 0))
              ((%flag-p tok)
               (format *error-output* "clun fmt: unknown flag ~a~%" tok)
               (return-from run-fmt-command 2))
              (t (push tok paths))))
    (setf paths (nreverse paths))
    (let ((opts (clun.fmt:default-fmt-options
                 :indent indent :print-width print-width
                 :semicolons semicolons :single-quote single-quote)))
      (handler-case
          (cond
            (stdin
             (let* ((src (with-output-to-string (o)
                           (loop for line = (read-line *standard-input* nil nil)
                                 while line do (write-line line o))))
                    (out (clun.fmt:format-source src :options opts)))
               (if check
                   (if (string= src out) 0
                       (progn (format *error-output* "clun fmt: stdin would be reformatted~%") 1))
                   (progn (write-string out) (finish-output) 0))))
            ((null paths)
             (format *error-output* "clun fmt: no paths (pass files/dirs or --stdin)~%")
             2)
            (t
             (let* ((results (clun.fmt:format-paths paths :cwd cwd
                                                    :write write :check check
                                                    :options opts))
                    (changed 0) (errors 0))
               (dolist (r results)
                 (cond
                   ((clun.fmt:fr-error r)
                    (incf errors)
                    (format *error-output* "clun fmt: ~a: ~a~%"
                            (clun.fmt:fr-path r) (clun.fmt:fr-error r)))
                   ((clun.fmt:fr-changed r)
                    (incf changed)
                    (cond
                      (write
                       (format t "formatted ~a~%" (clun.fmt:fr-path r)))
                      (check
                       (format *error-output* "would reformat ~a~%" (clun.fmt:fr-path r)))
                      (t
                       ;; default: print formatted content for single file, else list
                       (if (= (length results) 1)
                           (progn (write-string (clun.fmt:fr-formatted r))
                                  (finish-output))
                           (format t "~a~%" (clun.fmt:fr-path r))))))))
               (cond ((plusp errors) 1)
                     ((and check (plusp changed)) 1)
                     (t 0)))))
        (clun.fmt:fmt-error (e)
          (format *error-output* "clun fmt: ~a~%" (clun.fmt:fmt-error-message e))
          1)
        (error (e)
          (format *error-output* "clun fmt: ~a~%" e)
          1)))))

;;; --- lint (tooling.formatter-linter #190) -----------------------------------

(defun run-lint-command (r)
  "Handle `clun lint [paths…]` — first-party pure-CL linter.
Flags: --format stylish|json, --fix, --config PATH, --rule name=severity."
  (let ((cwd (resolve-cwd r))
        (paths '())
        (fmt :stylish) (fix nil) (config-path nil)
        (rule-overrides '()))
    (loop with rest = (remove nil (cons (cli:cli-get r :file) (cli:cli-get r :args)))
          while rest
          for tok = (pop rest) do
            (cond
              ((string= tok "--fix") (setf fix t))
              ((member tok '("--format" "-f") :test #'string=)
               (if (and rest (not (%flag-p (car rest))))
                   (let ((v (string-downcase (pop rest))))
                     (setf fmt (cond ((string= v "json") :json)
                                     ((string= v "stylish") :stylish)
                                     (t :stylish))))
                   (progn (format *error-output* "clun lint: --format needs a value~%")
                          (return-from run-lint-command 2))))
              ((string= tok "--config")
               (if (and rest (not (%flag-p (car rest))))
                   (setf config-path (pop rest))
                   (progn (format *error-output* "clun lint: --config needs a value~%")
                          (return-from run-lint-command 2))))
              ((string= tok "--rule")
               (if (and rest (not (%flag-p (car rest))))
                   (let* ((spec (pop rest))
                          (eqpos (position #\= spec)))
                     (if eqpos
                         (push (cons (subseq spec 0 eqpos)
                                     (subseq spec (1+ eqpos)))
                               rule-overrides)
                         (progn (format *error-output* "clun lint: --rule needs name=severity~%")
                                (return-from run-lint-command 2))))
                   (progn (format *error-output* "clun lint: --rule needs a value~%")
                          (return-from run-lint-command 2))))
              ((member tok '("-h" "--help") :test #'string=)
               (format t "Usage: clun lint [paths…] [--format stylish|json] [--fix] [--config f]~%")
               (return-from run-lint-command 0))
              ((%flag-p tok)
               (format *error-output* "clun lint: unknown flag ~a~%" tok)
               (return-from run-lint-command 2))
              (t (push tok paths))))
    (setf paths (nreverse paths) rule-overrides (nreverse rule-overrides))
    (when (null paths)
      (format *error-output* "clun lint: no paths~%")
      (return-from run-lint-command 2))
    (handler-case
        (let ((config (if config-path
                          (clun.lint:load-lint-config
                           (if (sys:absolute-path-p config-path)
                               config-path
                               (sys:path-join cwd config-path)))
                          (clun.lint:default-lint-config))))
          (dolist (pair rule-overrides)
            (clun.lint:set-rule config (car pair)
                                (clun.lint::parse-severity (cdr pair))))
          (multiple-value-bind (diags code)
              (clun.lint:lint-paths paths :cwd cwd :config config :fix fix)
            (ecase fmt
              (:json (clun.lint:report-json diags *standard-output*))
              (:stylish (when diags (clun.lint:report-stylish diags *error-output*))))
            code))
      (clun.lint:lint-error (e)
        (format *error-output* "clun lint: ~a~%" (clun.lint:lint-error-message e))
        1)
      (error (e)
        (format *error-output* "clun lint: ~a~%" e)
        1))))

;;; --- build (tooling.bundler #180) -------------------------------------------

;;; --- single-file executable compile (Issue #181) ---------------------------

(defun run-sfe-compile-command (r)
  "`clun build --compile` / `clun compile` pure-CL SFE path."
  (let* ((sub (cli:cli-get r :subcommand))
         (trailing (remove nil (cons (cli:cli-get r :file) (cli:cli-get r :args))))
         ;; `clun compile …` implies --compile; `clun build` needs the flag (Bun shape).
         (argv (if (equal sub "compile")
                   (cons "--compile" trailing)
                   trailing))
         (opts (cli:parse-build-args argv))
         (cwd (resolve-cwd r)))
    (when (getf opts :error)
      (format *error-output* "clun: ~a~%" (getf opts :error))
      (return-from run-sfe-compile-command 2))
    (when (getf opts :verify)
      (let ((v (clun.sfe:verify-path (getf opts :verify))))
        (format t "ok=~A algo=~A digest=~A signed=~A~@[ error=~A~]~%"
                (getf v :ok) (getf v :algo) (getf v :digest)
                (getf v :signed) (getf v :error))
        (return-from run-sfe-compile-command (if (getf v :ok) 0 1))))
    (unless (or (getf opts :compile) (equal sub "compile"))
      (format *error-output*
              "clun: internal error — SFE path without --compile~%")
      (return-from run-sfe-compile-command 2))
    (handler-case
        (if (getf opts :all-targets)
            (let ((results (clun.sfe:compile-all-targets
                            (getf opts :entry)
                            :outfile (getf opts :outfile)
                            :assets (getf opts :assets)
                            :defines (getf opts :defines)
                            :minify (getf opts :minify)
                            :bytecode (getf opts :bytecode)
                            :sign (getf opts :sign)
                            :cwd cwd)))
              (dolist (res results)
                (if (getf res :skipped)
                    (format t "skip ~A: ~A~%" (getf res :target) (getf res :error))
                    (format t "compiled ~A -> ~A (modules=~A assets=~A buildId=~A)~%"
                            (getf res :target) (getf res :outfile)
                            (getf res :modules) (getf res :assets)
                            (getf res :build-id))))
              0)
            (let ((res (clun.sfe:compile-executable
                        (getf opts :entry)
                        :outfile (getf opts :outfile)
                        :target (getf opts :target)
                        :template (getf opts :template)
                        :assets (getf opts :assets)
                        :defines (getf opts :defines)
                        :minify (getf opts :minify)
                        :bytecode (getf opts :bytecode)
                        :sign (getf opts :sign)
                        :cwd cwd
                        :host-path (clun.sfe:self-executable-path))))
              (format t "compiled ~A -> ~A (modules=~A assets=~A buildId=~A~@[ signed~])~%"
                      (getf res :target) (getf res :outfile)
                      (getf res :modules) (getf res :assets)
                      (getf res :build-id) (getf res :signed))
              0))
      (clun.sfe:sfe-error (e)
        (format *error-output* "clun: ~a~%" e)
        1))))

(defun run-sfe-image-if-any (argv)
  "If this process is a dumped SFE image (and not CLUN_BE_CLUN), run the app.
   Returns exit code or NIL."
  (when (clun.sfe:be-clun-mode-p)
    (return-from run-sfe-image-if-any nil))
  (when (clun.sfe:image-sfe-p)
    (return-from run-sfe-image-if-any
      (clun.sfe::run-image-embedded argv)))
  nil)

;;; --- build (tooling.bundler #180 + SFE #181) --------------------------------

(defun %build-has-compile-p (rest)
  "True when trailing build argv requests the SFE compile path."
  (or (member "--compile" rest :test #'string=)
      (member "--verify" rest :test #'string=)
      (member "--targets" rest :test #'string=)
      (member "--asset" rest :test #'string=)
      (member "--template" rest :test #'string=)
      (member "--sign" rest :test #'string=)
      (member "--bytecode" rest :test #'string=)))

(defun run-build-command (r)
  "Handle `clun build [entry…]` — bundler by default; SFE when --compile."
  (let* ((sub (cli:cli-get r :subcommand))
         (rest (remove nil (cons (cli:cli-get r :file) (cli:cli-get r :args)))))
    (when (or (equal sub "compile") (%build-has-compile-p rest))
      (return-from run-build-command (run-sfe-compile-command r)))
    (let ((cwd (resolve-cwd r))
          (entries '())
          (outdir nil) (outfile nil) (format "esm") (target "browser")
          (minify nil) (splitting nil) (sourcemap nil) (metafile nil)
          (external '()) (define '()) (banner nil) (footer nil)
          (packages nil) (public-path nil))
      (loop with toks = rest
            while toks
            for tok = (pop toks) do
              (cond
                ((or (string= tok "--outdir") (string= tok "-d"))
                 (if (and toks (not (%flag-p (car toks))))
                     (setf outdir (pop toks))
                     (progn (format *error-output* "clun build: ~a needs a value~%" tok)
                            (return-from run-build-command 2))))
                ((or (string= tok "--outfile") (string= tok "-o"))
                 (if (and toks (not (%flag-p (car toks))))
                     (setf outfile (pop toks))
                     (progn (format *error-output* "clun build: ~a needs a value~%" tok)
                            (return-from run-build-command 2))))
                ((string= tok "--format")
                 (if (and toks (not (%flag-p (car toks))))
                     (setf format (pop toks))
                     (progn (format *error-output* "clun build: --format needs a value~%")
                            (return-from run-build-command 2))))
                ((string= tok "--target")
                 (if (and toks (not (%flag-p (car toks))))
                     (setf target (pop toks))
                     (progn (format *error-output* "clun build: --target needs a value~%")
                            (return-from run-build-command 2))))
                ((string= tok "--minify") (setf minify t))
                ((string= tok "--splitting") (setf splitting t))
                ((string= tok "--sourcemap") (setf sourcemap t))
                ((string= tok "--metafile") (setf metafile t))
                ((string= tok "--external")
                 (if (and toks (not (%flag-p (car toks))))
                     (push (pop toks) external)
                     (progn (format *error-output* "clun build: --external needs a value~%")
                            (return-from run-build-command 2))))
                ((string= tok "--define")
                 (if (and toks (not (%flag-p (car toks))))
                     (let* ((d (pop toks))
                            (eq (position #\= d)))
                       (if eq
                           (push (cons (subseq d 0 eq) (subseq d (1+ eq))) define)
                           (progn
                             (format *error-output* "clun build: --define needs name=value~%")
                             (return-from run-build-command 2))))
                     (progn (format *error-output* "clun build: --define needs a value~%")
                            (return-from run-build-command 2))))
                ((string= tok "--banner")
                 (when (and toks (not (%flag-p (car toks)))) (setf banner (pop toks))))
                ((string= tok "--footer")
                 (when (and toks (not (%flag-p (car toks)))) (setf footer (pop toks))))
                ((string= tok "--packages")
                 (when (and toks (not (%flag-p (car toks)))) (setf packages (pop toks))))
                ((string= tok "--public-path")
                 (when (and toks (not (%flag-p (car toks)))) (setf public-path (pop toks))))
                ((and (> (length tok) 0) (char= (char tok 0) #\-))
                 (format *error-output* "clun build: unknown flag ~a~%" tok)
                 (return-from run-build-command 2))
                (t (push tok entries))))
      (setf entries (nreverse entries)
            external (nreverse external)
            define (nreverse define))
      (unless entries
        (format *error-output* "clun build: no entrypoints~%")
        (return-from run-build-command 2))
      (handler-case
          (let* ((plist (list :entrypoints entries
                              :outdir outdir
                              :outfile outfile
                              :root cwd
                              :target target
                              :format format
                              :splitting splitting
                              :minify minify
                              :external external
                              :define define
                              :banner banner
                              :footer footer
                              :packages packages
                              :public-path public-path
                              :sourcemap sourcemap
                              :metafile metafile
                              :throw t))
                 (result (clun.bundler:build plist)))
            (if (clun.bundler:br-success result)
                (progn
                  (dolist (out (clun.bundler:br-outputs result))
                    (when (clun.bundler:ba-path out)
                      (format t "~a  ~a bytes~%"
                              (clun.bundler:ba-path out)
                              (length (clun.bundler:ba-text out)))))
                  0)
                (progn
                  (dolist (log (clun.bundler:br-logs result))
                    (format *error-output* "clun build: ~a~%" (getf log :message)))
                  1)))
        (clun.bundler:build-error (e)
          (format *error-output* "clun build: ~a~%" (clun.bundler:build-error-message e))
          1)
        (error (e)
          (format *error-output* "clun build: ~a~%" e)
          1)))))

(defun run-tsc-command (r)
  "Structural TypeScript typecheck (`clun tsc` / `clun typecheck`). Paths are the
remaining argv tokens; exit 1 when any diagnostic is reported."
  (resolve-cwd r)
  (let ((paths (cli:cli-get r :args)))
    (unless paths
      (format *error-output* "clun tsc: missing file path(s)~%")
      (return-from run-tsc-command 2))
    (clun.transpiler:typecheck-paths paths)))

;;; --- dispatch ---------------------------------------------------------------

(defun dispatch (argv)
  "Return a process exit code for ARGV (executable name already dropped)."
  (let ((r (cli:parse-cli-args argv)))
    (ecase (cli:cli-action r)
      (:version (print-version) 0)
      (:revision (format t "~a~%" *clun-revision*) 0)
      (:help (print-help) 0)
      (:error (format *error-output* "clun: ~a~%note: run `clun --help` for usage~%"
                      (cli:cli-get r :error-msg))
              2)
      (:eval (run-eval r (cli:cli-get r :code) nil))
      (:print (run-eval r (cli:cli-get r :code) t))
      (:run (let ((sub (cli:cli-get r :subcommand)))
              (cond
                ((equal sub "test") (run-test r))
                ((member sub '("install" "add" "remove") :test #'equal) (run-install-command r))
                ((member sub '("build" "compile") :test #'equal) (run-build-command r))
                ((member sub '("fmt" "format") :test #'equal) (run-fmt-command r))
                ((equal sub "lint") (run-lint-command r))
                ((member sub '("tsc" "typecheck") :test #'equal) (run-tsc-command r))
                ((equal sub "exec") (run-exec r))
                ((equal sub "run") (run-script r))
                (t (run-file r (cli:cli-get r :file)))))))))

(defun main ()
  "Toplevel for the saved executable. Never lets a Lisp backtrace reach the user
unless --backtrace was passed; JS throws render as the value + stack."
  (let* ((argv (rest sb-ext:*posix-argv*))
         (backtrace (and (member "--backtrace" argv :test #'string=) t))
         (code
           (handler-case
               (progn
                 (when (equal (first argv) "--internal-sfe-dump")
                   (clun.sfe:perform-image-dump (second argv))
                   (return-from main 0))
                 (eng::cs-reset-telemetry)
                 (setf eng::*compile-tier-mode* (eng::compile-tier-mode-from-environment)
                       eng::*cs-trace-executions* (eng::compile-tier-trace-enabled-p))
                 (or (run-sfe-image-if-any argv)
                     (dispatch argv)))
             (rt:process-exit (c) (rt:process-exit-code c))
             (eng:js-condition (c)
               (render-uncaught (eng:js-condition-value c))
               (ignore-errors (rt:run-exit-handlers 1))
               1)
             (bad-cwd (c)
               (format *error-output* "clun: cannot change directory to '~a'~%" (bad-cwd-dir c))
               2)
             (storage-condition ()
               (format *error-output* "RangeError: Maximum call stack size exceeded~%")
               (when backtrace (sb-debug:print-backtrace :stream *error-output* :count 30))
               1)
             (error (c)
               (format *error-output* "clun: ~a~%" c)
               (when backtrace (sb-debug:print-backtrace :stream *error-output* :count 30))
               1))))
    (when (eng::compile-tier-report-enabled-p) (eng::write-compile-tier-report))
    (when (eng::compile-tier-details-enabled-p) (eng::write-compile-tier-details))
    (sb-ext:exit :code code)))
