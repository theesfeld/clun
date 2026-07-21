;;;; update.lisp — built-in self-update from GitHub Releases (user standard §8.3).
;;;; Uses the direct pure-CL HTTP/TLS transport so update does not depend on a
;;;; JavaScript realm (or evaluate synthesized JavaScript).
;;;; Resolves a channel-suitable release through the browser redirect first,
;;;; downloads the same archive assets as site/install, verifies SHA-256, and
;;;; stages a complete versioned release bundle and atomically switches the
;;;; stable installer-managed launcher, retaining the prior bundle for rollback.

(in-package :clun.cli)

(defparameter *update-repo* "theesfeld/clun"
  "owner/repo for GitHub Releases.")

(defparameter *update-user-agent* "clun-update/0.1"
  "GitHub requires a User-Agent on unauthenticated downloads.")

(defparameter *update-max-asset-bytes* (* 300 1024 1024)
  "Hard upper bound for a downloaded release asset (300 MiB).
Sized for full SBCL release bundles plus licenses. The transport rejects larger
bodies before returning, and activation starts only after the complete bounded
payload has been checksum-verified.")

(defvar *update-fetch-function* nil
  "Optional test seam. When non-NIL, called instead of the pure-CL fetch transport.")

(defvar *update-current-executable-override* nil
  "Optional test seam for the actual running executable.")

(defvar *update-argv0-override* nil
  "Optional test seam for the original argv[0] used to discover a launcher.")

(defvar *update-launcher-override* nil
  "Optional test seam for an installer-managed stable launcher.")

(defvar *update-activation-verifier* nil
  "Optional test seam run after launcher activation; NIL uses realpath equality.")

(defun %update-current-version ()
  clun::*clun-version*)

(defun %split-https-url (url)
  "Return HOST, PORT, and request target for a simple absolute HTTPS URL."
  (unless (and (stringp url) (>= (length url) 9)
               (string-equal "https://" url :end2 8))
    (error "update refuses non-HTTPS URL ~s" url))
  (let* ((rest (subseq url 8))
         (slash (position #\/ rest))
         (authority (if slash (subseq rest 0 slash) rest))
         (path (if slash (subseq rest slash) "/"))
         (colon (position #\: authority :from-end t))
         (host authority)
         (port 443))
    (when (or (zerop (length authority)) (find #\@ authority)
              (find #\Newline authority) (find #\Return authority))
      (error "invalid HTTPS authority in ~s" url))
    (when colon
      (setf host (subseq authority 0 colon)
            port (or (ignore-errors (parse-integer authority :start (1+ colon)))
                     (error "invalid HTTPS port in ~s" url))))
    (values host port path)))

(defun %redirect-url (base location)
  (cond
    ((and (>= (length location) 8)
          (string-equal "https://" location :end2 8))
     location)
    ((and (plusp (length location)) (char= (char location 0) #\/))
     (multiple-value-bind (host port path) (%split-https-url base)
       (declare (ignore path))
       (format nil "https://~a~a~a" host
               (if (= port 443) "" (format nil ":~d" port))
               location)))
    (t (error "unsupported relative redirect location ~s" location))))

(defun %without-authorization (headers)
  (remove-if (lambda (header) (string-equal (car header) "Authorization")) headers))

(defun %fetch-response (url &key (headers '()) (timeout-ms 120000) (binary nil)
                                  (metadata-only nil))
  "GET URL with the direct pure-CL TLS client and follow bounded HTTPS redirects.
Returns BODY and the final URL; authorization is never forwarded cross-origin.
Clears the pure-tls session-ticket cache for each host so multi-asset update
downloads always full-handshake (avoids PSK resume Certificate-missing failures
on older pure-tls verify paths)."
  (loop with current = url
        with request-headers = (acons "User-Agent" *update-user-agent* headers)
        for redirects from 0 to 5
        do (multiple-value-bind (host port path) (%split-https-url current)
             ;; Full handshake every request — safer for sequential asset downloads.
             (ignore-errors (ptls:session-ticket-cache-clear host))
             (let* ((response (net:https-request :host host :port port :method "GET"
                                                :path path :headers request-headers
                                                :connect-timeout-ms
                                                (min timeout-ms 30000)))
                    (status (net:hres-status response)))               (cond
                 ((and (>= status 200) (< status 300))
                  (let ((octets (net:hres-body response)))
                    (return
                      (values (cond (metadata-only current)
                                    (binary octets)
                                    (t (sb-ext:octets-to-string
                                        octets :external-format :utf-8)))
                              current))))
                 ((member status '(301 302 303 307 308))
                  (when (= redirects 5)
                    (error "too many redirects for ~a" url))
                  (let ((location (net:%header (net:hres-headers response) "location")))
                    (unless location (error "HTTP ~d redirect without Location for ~a"
                                            status current))
                    (multiple-value-bind (old-host old-port old-path)
                        (%split-https-url current)
                      (declare (ignore old-path))
                      (let ((next (%redirect-url current location)))
                        (multiple-value-bind (new-host new-port new-path)
                            (%split-https-url next)
                          (declare (ignore new-path))
                          (unless (and (string-equal old-host new-host)
                                       (= old-port new-port))
                            (setf request-headers
                                  (%without-authorization request-headers))))
                        (setf current next)))))
                 (t (error "HTTP ~d for ~a" status current)))))))

(defun %call-update-fetch (url &rest args &key &allow-other-keys)
  (if *update-fetch-function*
      (apply *update-fetch-function* url args)
      (apply #'%fetch-response url args)))

(defun %fetch-text (url &key (headers '()) (timeout-ms 120000) (binary nil))
  "GET URL via the pure-CL update transport and return its body."
  (%call-update-fetch url :headers headers :timeout-ms timeout-ms :binary binary))

(defun %release-tag-p (tag)
  (and (stringp tag)
       (> (length tag) 1)
       (char= (char tag 0) #\v)
       (clun.install:version-valid-p tag)))

(defun %prerelease-version-p (version)
  (handler-case
      (not (null (clun.install:semver-prerelease
                  (clun.install:parse-version version))))
    (clun.install:invalid-version () nil)))

(defun %tag-from-release-url (url)
  (let* ((prefix (format nil "https://github.com/~a/releases/tag/" *update-repo*))
         (start (and (stringp url) (search prefix url))))
    (when (and start (zerop start))
      (let* ((raw (subseq url (length prefix)))
             (end (position-if (lambda (c) (member c '(#\? #\# #\/))) raw))
             (tag (subseq raw 0 (or end (length raw)))))
        (and (%release-tag-p tag) tag)))))

(defun %prerelease-maturity-rank (version)
  "Clun maturity order for same-core prereleases (higher = newer channel).
Strict SemVer compares prerelease *identifiers* lexicographically, so
`dev` would rank above `beta` — wrong for our train (dev → alpha → beta → rc).
Return: 0=dev, 1=alpha, 2=beta, 3=rc, 4=stable/unknown-prefix, NIL=unparseable."
  (handler-case
      (let* ((v (clun.install:parse-version version))
             (pre (clun.install:semver-prerelease v)))
        (if (null pre)
            4
            (let ((head (first pre)))
              (cond
                ((or (equal head "dev") (equal head "DEV")) 0)
                ((or (equal head "alpha") (equal head "ALPHA")) 1)
                ((or (equal head "beta") (equal head "BETA")) 2)
                ((or (equal head "rc") (equal head "RC")) 3)
                (t 4)))))
    (clun.install:invalid-version () nil)))

(defun %version-prefer (a b)
  "Return T when A is a better update target than B for Clun channel policy.
Compare SemVer core first, then maturity rank (dev < alpha < beta < rc < stable),
then full SemVer (numeric sequence within the same prefix)."
  (handler-case
      (let* ((va (clun.install:parse-version a))
             (vb (clun.install:parse-version b))
             (core (clun.install::compare-main va vb)))
        (cond
          ((plusp core) t)
          ((minusp core) nil)
          (t
           (let ((ra (%prerelease-maturity-rank a))
                 (rb (%prerelease-maturity-rank b)))
             (cond
               ((and ra rb (> ra rb)) t)
               ((and ra rb (< ra rb)) nil)
               (t (plusp (clun.install:version-compare a b))))))))
    (clun.install:invalid-version ()
      (plusp (clun.install:version-compare a b)))))

(defun %api-release-tag (text current-version)
  "Select the highest suitable non-draft tag from a Releases API payload.
Stable installs stay on the stable channel; prerelease installs may advance to
a newer prerelease or a stable release. Preference uses Clun maturity rank so
`0.2.0-beta.1` wins over a higher-looking `0.2.0-dev.N` on the same core."
  (let* ((parsed (sys:parse-json text))
         (entries (cond ((vectorp parsed) (coerce parsed 'list))
                        ((listp parsed) parsed)
                        (t (error "GitHub Releases API did not return an array"))))
         (current-prerelease (%prerelease-version-p current-version))
         (best nil))
    (dolist (entry entries best)
      (let ((tag (sys:jget entry "tag_name"))
            (draft (sys:jget entry "draft" sys:json-false)))
        (when (and (%release-tag-p tag)
                   (not (eq draft sys:json-true))
                   (or current-prerelease (not (%prerelease-version-p tag)))
                   (or (null best) (%version-prefer tag best)))
          (setf best tag))))))

(defun %highest-suitable-release-tag (tags current-version)
  "Return the highest valid TAG suitable for CURRENT-VERSION's channel."
  (let ((current-prerelease (%prerelease-version-p current-version))
        (best nil))
    (dolist (tag tags best)
      (when (and (%release-tag-p tag)
                 (or current-prerelease (not (%prerelease-version-p tag)))
                 (or (null best) (%version-prefer tag best)))
        (setf best tag)))))
(defun %atom-release-tags (text)
  "Extract published release tags from GitHub's Releases Atom feed."
  (let ((prefix (format nil "https://github.com/~a/releases/tag/" *update-repo*))
        (start 0)
        (tags '()))
    (loop
      (let ((href (search "href=\"" text :start2 start)))
        (unless href (return (nreverse (remove-duplicates tags :test #'string=))))
        (let* ((value-start (+ href 6))
               (value-end (position #\" text :start value-start)))
          (unless value-end (return (nreverse (remove-duplicates tags :test #'string=))))
          (let ((url (subseq text value-start value-end)))
            (when (and (<= (length prefix) (length url))
                       (string= prefix url :end2 (length prefix)))
              (let* ((raw (subseq url (length prefix)))
                     (end (position-if (lambda (c) (member c '(#\? #\# #\/))) raw))
                     (tag (subseq raw 0 (or end (length raw)))))
                (when (%release-tag-p tag) (push tag tags)))))
          (setf start (1+ value-end)))))))

(defun %github-api-headers ()
  (flet ((nonempty-env (name)
           (let ((value (sys:getenv name)))
             (and value (plusp (length value)) value))))
    (let ((token (or (nonempty-env "GITHUB_TOKEN") (nonempty-env "GH_TOKEN"))))
      (append (list (cons "Accept" "application/vnd.github+json")
                    (cons "X-GitHub-Api-Version" "2022-11-28"))
              (when token
                (list (cons "Authorization" (format nil "Bearer ~a" token))))))))

(defun %resolve-redirect-tag ()
  (let ((url (format nil "https://github.com/~a/releases/latest" *update-repo*)))
    (multiple-value-bind (body final-url)
        (%call-update-fetch url :metadata-only t :timeout-ms 120000)
      (declare (ignore body))
      (or (%tag-from-release-url final-url)
          (error "latest redirect did not end at a release tag: ~a" final-url)))))

(defun %resolve-api-tag (current-version)
  (let* ((url (format nil "https://api.github.com/repos/~a/releases?per_page=10"
                      *update-repo*))
         (text (%fetch-text url :headers (%github-api-headers)))
         (tag (%api-release-tag text current-version)))
    (or tag (error "no suitable release tag in GitHub API response"))))

(defun %resolve-atom-tag (current-version)
  (let* ((url (format nil "https://github.com/~a/releases.atom" *update-repo*))
         (text (%fetch-text url))
         (tag (%highest-suitable-release-tag
               (%atom-release-tags text) current-version)))
    (or tag (error "no suitable release tag in GitHub Releases feed"))))

(defun resolve-latest-release-tag (&key (current-version (%update-current-version)))
  "Resolve a suitable Release through github.com/releases/latest first.
The API is fallback-only (including when a prerelease install is newer than
the latest stable redirect). GITHUB_TOKEN/GH_TOKEN authenticate that fallback.
If the API is unavailable or rate-limited, GitHub's public Releases Atom feed
provides a non-API fallback. A usable redirect is retained if both fail."
  (let ((redirect-tag nil)
        (redirect-error nil)
        (api-error nil))
    (handler-case
        (setf redirect-tag (%resolve-redirect-tag))
      (error (e) (setf redirect-error (format nil "~a" e))))
    (when (and redirect-tag
               (or (not (%prerelease-version-p current-version))
                   (not (%version< redirect-tag current-version))))
      (return-from resolve-latest-release-tag (values redirect-tag nil)))
    (handler-case
        (return-from resolve-latest-release-tag
          (values (%resolve-api-tag current-version) nil))
      (error (e) (setf api-error (format nil "~a" e))))
    (handler-case
        (values (%resolve-atom-tag current-version) nil)
      (error (atom-error)
        (if redirect-tag
            (values redirect-tag nil)
            (values nil
                    (format nil
                            "latest redirect failed (~a); API fallback failed (~a); Releases feed fallback failed (~a)"
                            (or redirect-error "no release tag")
                            (or api-error "no release tag") atom-error)))))))

(defun %release-package-basename ()
  (format nil "clun-~a-~a" (sys:platform-name) (sys:machine-arch)))

(defun %release-asset-basename ()
  (format nil "~a.tar.gz" (%release-package-basename)))

(defun %download-release-bytes (tag relative-name)
  (let ((url (format nil "https://github.com/~a/releases/download/~a/~a"
                     *update-repo* tag relative-name)))
    (let ((payload (%fetch-text url :binary t :timeout-ms 600000)))
      (unless (typep payload '(vector (unsigned-byte 8)))
        (error "release asset transport did not return octets"))
      (when (> (length payload) *update-max-asset-bytes*)
        (error "release asset exceeds the ~d-byte update limit"
               *update-max-asset-bytes*))
      payload)))

(defun %checksums-map (checksums-text)
  (let ((table (make-hash-table :test #'equal)))
    (with-input-from-string (in checksums-text)
      (loop for line = (read-line in nil nil)
            while line
            do (let* ((line (string-trim '(#\Space #\Tab #\Return) line))
                      (sp (position-if (lambda (c) (member c '(#\Space #\Tab))) line)))
                 (when (and sp (> sp 0))
                   (let ((hex (subseq line 0 sp))
                         (name (string-trim '(#\Space #\Tab #\*) (subseq line (1+ sp)))))
                     (when (and (plusp (length hex)) (plusp (length name)))
                       (setf (gethash name table) (string-downcase hex))))))))
    table))

(defun %sha256-hex (octets)
  (string-downcase
   (ironclad:byte-array-to-hex-string
    (ironclad:digest-sequence :sha256 octets))))

(defstruct (update-install-context
            (:constructor %make-update-install-context
                (&key launcher bundle releases-root target)))
  launcher bundle releases-root target)

(defun %split-search-path (value)
  (loop with start = 0
        for colon = (position #\: value :start start)
        for part = (subseq value start (or colon (length value)))
        collect part
        while colon do (setf start (1+ colon))))

(defun %executable-file-p (path)
  (and path (sys:file-p path) (ignore-errors (sys:check-access path 1))))

(defun %absolute-reference (reference)
  "Resolve REFERENCE to an absolute path while retaining its final symlink."
  (when (and (stringp reference) (plusp (length reference)))
    (cond
      ((sys:absolute-path-p reference) (sys:normalize-path reference))
      ((find #\/ reference)
       (sys:normalize-path (sys:path-join (sys:current-directory) reference)))
      (t
       ;; Empty PATH fields traditionally mean cwd. Deliberately ignore them:
       ;; only an explicit `.` opts into cwd lookup for updater safety.
       (loop for directory in (%split-search-path (or (sys:getenv "PATH") ""))
             when (plusp (length directory))
               do (let* ((base (if (sys:absolute-path-p directory)
                                   directory
                                   (sys:path-join (sys:current-directory) directory)))
                         (candidate
                           (sys:normalize-path (sys:path-join base reference))))
                    (when (%executable-file-p candidate) (return candidate))))))))

(defun %resolved-executable (reference)
  (let ((candidate (%absolute-reference reference)))
    (and (%executable-file-p candidate) (sys:realpath candidate))))

(defun %symlink-p (path)
  (let ((stat (and path (ignore-errors (sys:stat* path :lstat t)))))
    (and stat (sys:fstat-symlink-p stat))))

(defun %single-line-file (path description)
  (unless (sys:file-p path) (error "release bundle is missing ~a" description))
  (let* ((raw (sys:read-file-string path))
         (value (string-right-trim '(#\Newline #\Return) raw))
         (suffix (subseq raw (length value))))
    (when (or (zerop (length value)) (find #\Newline value) (find #\Return value)
              (not (member suffix
                           (list "" (string #\Newline)
                                 (coerce (list #\Return #\Newline) 'string))
                           :test #'string=)))
      (error "release bundle has an invalid ~a" description))
    value))

(defun %run-version-probe (launcher)
  "Run LAUNCHER --version directly and return its complete stdout."
  (let ((process nil)
        (stdout nil)
        (stderr nil))
    (unwind-protect
         (progn
           (setf process (sb-ext:run-program launcher '("--version")
                                             :search nil :wait t
                                             :input nil :output :stream :error :stream)
                 stdout (sb-ext:process-output process)
                 stderr (sb-ext:process-error process))
           (let ((output (with-output-to-string (stream)
                           (loop for line = (read-line stdout nil nil)
                                 while line
                                 for first = t then nil
                                 do (unless first (terpri stream))
                                    (write-string line stream))))
                 (error-output (with-output-to-string (stream)
                                 (loop for line = (read-line stderr nil nil)
                                       while line
                                       for first = t then nil
                                       do (unless first (terpri stream))
                                          (write-string line stream)))))
             (unless (and (eq (sb-ext:process-status process) :exited)
                          (zerop (sb-ext:process-exit-code process)))
               (error "release launcher version probe failed~@[ (~a)~]"
                      (and (plusp (length error-output)) error-output)))
             output))
      (when stdout (ignore-errors (close stdout)))
      (when stderr (ignore-errors (close stderr))))))

(defun %release-target-name ()
  (format nil "~a-~a" (sys:platform-name) (sys:machine-arch)))

(defun %validate-release-bundle (bundle expected-version)
  "Validate the complete host release layout and exact VERSION. Signal on failure."
  (unless (and (sys:directory-p bundle)
               (member (sys:path-basename bundle)
                       (list (%release-target-name) (%release-package-basename))
                       :test #'string=))
    (error "release bundle does not target ~a" (%release-target-name)))
  (let ((version (%single-line-file (sys:path-join bundle "VERSION") "VERSION"))
        (launcher (sys:path-join bundle "bin" "clun")))
    (unless (and (clun.install:version-valid-p version)
                 (string= version expected-version))
      (error "release bundle VERSION ~s does not match ~s" version expected-version))
    (unless (%executable-file-p launcher)
      (error "release bundle is missing executable bin/clun"))
    (when (string= (sys:platform-name) "linux")
      (let* ((loader-name (%single-line-file (sys:path-join bundle "lib" "LOADER")
                                             "lib/LOADER"))
             (loader (sys:path-join bundle "lib" loader-name))
             (core (sys:path-join bundle "libexec" "clun")))
        (when (or (find #\/ loader-name) (member loader-name '("." "..") :test #'string=))
          (error "release bundle has an unsafe lib/LOADER entry"))
        (unless (%executable-file-p loader)
          (error "release bundle is missing executable lib/~a" loader-name))
        (unless (%executable-file-p core)
          (error "release bundle is missing executable libexec/clun"))))
    (let ((reported (%run-version-probe launcher)))
      (unless (string= reported (format nil "clun ~a" expected-version))
        (error "release launcher reported ~s; expected clun ~a"
               reported expected-version)))
    bundle))

(defun %prepare-release-modes (bundle)
  ;; The hardened archive extractor intentionally ignores archive modes. Restore
  ;; only the known executable release surfaces after structural extraction.
  (let ((launcher (sys:path-join bundle "bin" "clun")))
    (unless (sys:file-p launcher)
      (error "release bundle extract is missing bin/clun under ~a (entries: ~{~a~^, ~})"
             bundle
             (ignore-errors
               (loop for e in (sys:read-directory bundle)
                     collect e))))
    (sys:change-mode launcher #o755))
  (when (string= (sys:platform-name) "linux")
    (sys:change-mode (sys:path-join bundle "libexec" "clun") #o755)
    (let ((lib (sys:path-join bundle "lib")))
      (when (sys:directory-p lib)
        (dolist (entry (sys:read-directory lib))
          (let ((path (sys:path-join lib entry)))
            (when (sys:file-p path) (sys:change-mode path #o755)))))))
  bundle)

(defun %actual-executable ()
  (or (%resolved-executable *update-current-executable-override*)
      (%resolved-executable (ignore-errors (clun.sfe:self-executable-path)))
      (%resolved-executable (or *update-argv0-override* (first sb-ext:*posix-argv*)))
      (error "could not resolve the running Clun executable")))

(defun %bundle-from-actual-executable (actual)
  (let* ((parent (sys:path-dirname actual))
         (expected-leaf (if (string= (sys:platform-name) "linux") "libexec" "bin")))
    (unless (and (string= (sys:path-basename actual) "clun")
                 (string= (sys:path-basename parent) expected-leaf))
      (error "running executable ~a is not inside a packaged ~a/clun layout"
             actual expected-leaf))
    (sys:path-dirname parent)))

(defun %launcher-candidates ()
  (remove-duplicates
   (remove-if-not
    #'identity
    (list (%absolute-reference *update-launcher-override*)
          (%absolute-reference (sys:getenv "CLUN_UPDATE_LAUNCHER"))
          (%absolute-reference (or *update-argv0-override* (first sb-ext:*posix-argv*)))))
   :test #'string=))

(defun %managed-install-context ()
  "Discover and validate the installer-managed bundle and stable symlink."
  (let* ((actual (%actual-executable))
         (bundle (%bundle-from-actual-executable actual))
         (current (%update-current-version))
         (target (%release-target-name))
         (bundle-launcher (sys:path-join bundle "bin" "clun"))
         (bundle-real (sys:realpath bundle-launcher))
         (version-dir (sys:path-dirname bundle))
         (releases-root (sys:path-dirname version-dir)))
    (%validate-release-bundle bundle current)
    (unless (and (string= (sys:path-basename version-dir) current)
                 (string= (sys:path-basename releases-root) "releases"))
      (error "running bundle is not in releases/<version>/<target>"))
    (let ((launcher
            (find-if
             (lambda (candidate)
               (and (%symlink-p candidate)
                    (let ((resolved (sys:realpath candidate)))
                      (and resolved bundle-real (string= resolved bundle-real)))))
             (%launcher-candidates))))
      (unless launcher
        (error "could not find an installer-managed Clun launcher on PATH; rerun the installer"))
      (%make-update-install-context :launcher launcher :bundle bundle
                                    :releases-root releases-root :target target))))

(defun %unique-symlink (directory prefix target)
  (let ((path (sys:make-temp-dir (sys:path-join directory prefix))))
    (sys:remove-directory path)
    (handler-case
        (progn (sys:make-symlink target path) path)
      (error (condition)
        (ignore-errors (sys:remove-recursive path))
        (error condition)))))

(defun %launcher-points-to-p (launcher target)
  (if *update-activation-verifier*
      (funcall *update-activation-verifier* launcher target)
      (let ((launcher-real (sys:realpath launcher))
            (target-real (sys:realpath target)))
        (and launcher-real target-real (string= launcher-real target-real)))))

(defun %activate-launcher (launcher new-target)
  "Atomically switch LAUNCHER and restore its prior target on any failed validation."
  (unless (%symlink-p launcher)
    (error "refusing to replace non-symlink launcher ~a" launcher))
  (let* ((directory (sys:path-dirname launcher))
         (old-target (sys:read-symlink launcher))
         (staged (%unique-symlink directory ".clun-link-" new-target))
         (activated nil))
    (unwind-protect
         (handler-case
             (progn
               (sys:rename-path staged launcher)
               (setf staged nil activated t)
               (unless (%launcher-points-to-p launcher new-target)
                 (error "activated launcher did not resolve to the staged release"))
               launcher)
           (error (condition)
             (when activated
               (let ((rollback (%unique-symlink directory ".clun-rollback-" old-target)))
                 (unwind-protect
                      (progn (sys:rename-path rollback launcher) (setf rollback nil))
                   (when rollback (ignore-errors (sys:remove-recursive rollback))))))
             (error condition)))
      (when staged (ignore-errors (sys:remove-recursive staged))))))


(defun %user-man1-dir ()
  "User man1 directory matching site/install (XDG data home)."
  (let* ((xdg (sys:getenv "XDG_DATA_HOME"))
         (base (if (and xdg (plusp (length xdg)))
                   xdg
                   (sys:path-join (sys:homedir) ".local" "share"))))
    (sys:path-join base "man" "man1")))

(defun %install-man-page (bundle)
  "Install packaged share/man/man1/clun.1 next to the live CLI (hard rule).
Returns T when installed, NIL when the archive predates man packaging.
Never fails the update for a missing man page (same policy as site/install)."
  (let* ((source (sys:path-join bundle "share" "man" "man1" "clun.1"))
         (dest-dir (%user-man1-dir))
         (dest (sys:path-join dest-dir "clun.1")))
    (cond
      ((not (sys:file-p source)) nil)
      (t
       (sys:make-directory dest-dir :recursive t :mode #o755)
       (sys:copy-file* source dest)
       t))))

(defun %install-payload-octets (payload remote-version context)
  "Stage and validate a full release archive, then atomically activate its launcher."
  (let* ((releases-root (update-install-context-releases-root context))
         (target (update-install-context-target context))
         (release-parent (sys:path-join releases-root remote-version))
         (final (sys:path-join release-parent target))
         (new-launcher (sys:path-join final "bin" "clun"))
         (stage-root nil))
    (sys:make-directory release-parent :recursive t :mode #o755)
    (cond
      ((sys:path-exists-p final)
       (%validate-release-bundle final remote-version))
      (t
       (setf stage-root
             (sys:make-temp-dir (sys:path-join release-parent ".clun-stage-")))
       (unwind-protect
            (let* ((unpacked (sys:path-join stage-root "unpacked"))
                   (found (sys:path-join unpacked (%release-package-basename))))
              (clun.archive:extract-archive payload unpacked :strip-components 0)
              (unless (sys:directory-p found)
                (error "release archive did not contain ~a" (%release-package-basename)))
              (%prepare-release-modes found)
              (%validate-release-bundle found remote-version)
              (sys:rename-path found final))
         (when stage-root
           (ignore-errors (sys:remove-recursive stage-root))
           (setf stage-root nil)))))
    (%validate-release-bundle final remote-version)
    (%activate-launcher (update-install-context-launcher context) new-launcher)
    ;; Hard rule: man page always matches live CLI. site/install does this;
    ;; --update must too (man lives under the versioned bundle, not on PATH).
    (%install-man-page final)
    final))

(defun %version< (a b)
  "True when A is older than B under Clun channel policy (maturity-aware)."
  (%version-prefer b a))

(defun %tls-update-failure-p (message)
  "True when MESSAGE looks like the known pure-tls Certificate-missing / decode class."
  (let ((s (string-downcase (princ-to-string message))))
    (or (search "decode_error" s)
        (search "decode error" s)
        (search "certificate was missing" s)
        (search "no-peer-certificate" s)
        (search "no peer certificate" s)
        (search "tls" s))))

(defun %update-recovery-hint ()
  "curl|sh reinstall — works when the running binary's TLS cannot fetch assets."
  "If update fails repeatedly (especially TLS errors on older builds), reinstall with:
  curl -fsSL https://clun.sh/install | sh")

(defun %format-update-error (condition)
  (let ((msg (princ-to-string condition)))
    (if (%tls-update-failure-p msg)
        (format nil "~a~%~a" msg (%update-recovery-hint))
        msg)))

(defparameter *update-notice-ttl-seconds* (* 12 60 60)
  "How long to cache a silent update-availability probe (12 hours).")

(defun %update-notice-cache-path ()
  (let* ((xdg (sys:getenv "XDG_CACHE_HOME"))
         (home (sys:homedir))
         (base (if (and xdg (plusp (length xdg)))
                   xdg
                   (sys:path-join home ".cache"))))
    (sys:path-join base "clun" "update-notice.cache")))

(defun %read-update-notice-cache ()
  "Return (values remote-tag checked-universal-time) or NIL."
  (let ((path (%update-notice-cache-path)))
    (when (sys:file-p path)
      (handler-case
          (with-open-file (in path :direction :input :if-does-not-exist nil)
            (when in
              (let* ((line (read-line in nil nil))
                     (sp (and line (position #\Space line))))
                (when (and line sp)
                  (values (subseq line 0 sp)
                          (parse-integer line :start (1+ sp) :junk-allowed t))))))
        (error () nil)))))

(defun %write-update-notice-cache (tag)
  (let* ((path (%update-notice-cache-path))
         (dir (sys:path-dirname path)))
    (ignore-errors
      (sys:make-directory dir :recursive t :mode #o755)
      (with-open-file (out path :direction :output :if-exists :supersede
                           :if-does-not-exist :create)
        (format out "~a ~d~%" tag (get-universal-time))))))

(defun %tty-stream-p (stream)
  "True when STREAM is attached to a terminal (best-effort)."
  (and (streamp stream)
       (ignore-errors
         (and (sb-sys:fd-stream-p stream)
              (= 1 (sb-unix:unix-isatty (sb-sys:fd-stream-fd stream)))))))

(defun maybe-emit-update-notice (&key (stream *error-output*) force)
  "If a newer release is available, print a one-line TTY hint (cached probe).
Never fails the calling command — network/TLS errors are silent here."
  (unless (or force (%tty-stream-p stream))
    (return-from maybe-emit-update-notice nil))
  (let ((now (get-universal-time)))
    (multiple-value-bind (cached-tag cached-at) (%read-update-notice-cache)
      (when (and (not force) cached-at
                 (< (- now cached-at) *update-notice-ttl-seconds*))
        (when (and cached-tag (plusp (length cached-tag)))
          (let* ((current (%update-current-version))
                 (remote (string-left-trim '(#\v #\V) cached-tag)))
            (when (and (not (string= current remote))
                       (%version< current remote))
              (format stream "~a update available: ~a ~a ~a  (clun --update)~%"
                      (style-warn (glyph-up) stream)
                      (style-dim current stream)
                      (style-info (glyph-step) stream)
                      (style-ok cached-tag stream))
              (force-output stream)
              (return-from maybe-emit-update-notice t))))
        (return-from maybe-emit-update-notice nil)))
    (handler-case
        (multiple-value-bind (tag err) (resolve-latest-release-tag)
          (when (and (null err) tag)
            (%write-update-notice-cache tag)
            (let* ((current (%update-current-version))
                   (remote (string-left-trim '(#\v #\V) tag)))
              (when (and (not (string= current remote))
                         (%version< current remote))
                (format stream "~a update available: ~a ~a ~a  (clun --update)~%"
                        (style-warn (glyph-up) stream)
                        (style-dim current stream)
                        (style-info (glyph-step) stream)
                        (style-ok tag stream))
                (force-output stream)
                t))))
      (error () nil))))
(defun check-update (&key (stream *standard-output*) (error-stream *error-output*))
  "Print update availability. 0 = up to date (or local ahead of published);
   1 = newer published release available; 2 = error."
  (multiple-value-bind (tag err) (resolve-latest-release-tag)
    (cond
      (err
       (fail err :command "check-update" :exit 2 :stream error-stream))
      ((null tag)
       (fail "could not resolve latest release"
             :command "check-update" :exit 2 :stream error-stream))
      (t
       (let* ((current (%update-current-version))
              (remote (string-left-trim '(#\v #\V) tag)))
         (ignore-errors (%write-update-notice-cache tag))
         (cond
           ((string= current remote)
            (emit-ok (format nil "~a is up to date (~a)"
                             (style-brand *cli-brand* stream) tag)
                     :stream stream)
            0)
           ((%version< current remote)
            (format stream "~a update available: ~a ~a ~a~%"
                    (style-warn (glyph-up) stream)
                    (style-dim current stream)
                    (style-info (glyph-step) stream)
                    (style-ok tag stream))
            (format stream "  run: ~a --update~%"
                    (style-brand *cli-brand* stream))
            (force-output stream)
            1)
           (t
            (emit-info (format nil "~a is newer than published ~a (no update)"
                               (style-brand *cli-brand* stream) tag)
                       :stream stream)
            0)))))))

(defun perform-update (&key (stream *standard-output*) (error-stream *error-output*))
  "Download latest release, verify it, and atomically activate its full bundle."
  (multiple-value-bind (tag err) (resolve-latest-release-tag)
    (when err
      (return-from perform-update
        (fail err :command "update" :exit 2 :stream error-stream)))
    (unless tag
      (return-from perform-update
        (fail "could not resolve latest release"
              :command "update" :exit 2 :stream error-stream)))
    (let* ((old (%update-current-version))
           (remote (string-left-trim '(#\v #\V) tag))
           (asset (%release-asset-basename)))
      (when (or (string= old remote) (not (%version< old remote)))
        (emit-ok (format nil "~a needs no update (latest ~a)"
                         (style-brand *cli-brand* stream) tag)
                 :stream stream)
        (return-from perform-update 0))
      (emit-step (format nil "updating ~a ~a ~a"
                         (style-dim old stream)
                         (style-info (glyph-step) stream)
                         (style-ok tag stream))
                 :stream stream)
      (handler-case
          (progn
            (call-with-progress
             (format nil "fetching ~a" asset)
             (lambda ()
               (let* ((context (%managed-install-context))
                      (sum-text (%fetch-text
                                 (format nil "https://github.com/~a/releases/download/~a/checksums.txt"
                                         *update-repo* tag)))
                      (sums (%checksums-map sum-text))
                      (want (gethash asset sums))
                      (payload (%download-release-bytes tag asset))
                      (got (%sha256-hex payload)))
                 (unless want
                   (error "no checksum entry for ~a" asset))
                 (unless (string= want got)
                   (error "SHA-256 mismatch for ~a (expected ~a got ~a)" asset want got))
                 (%install-payload-octets payload remote context)))
             :done-message (lambda (final)
                             (format nil "activated ~a ~a ~a  ~a"
                                     (style-dim old stream)
                                     (style-info (glyph-step) stream)
                                     (style-ok remote stream)
                                     (style-dim final stream)))
             :stream stream)
            0)
        (error (e)
          (fail (%format-update-error e)
                :command "update" :exit 2 :stream error-stream))))))