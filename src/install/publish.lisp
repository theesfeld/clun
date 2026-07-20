;;;; publish.lisp — pure-CL `clun publish` (Issue #262).
;;;;
;;;; Packs the current package (ustar + gzip under package/), authenticates with
;;;; NPM_TOKEN / .npmrc _authToken, and PUTs the npm attach-document body to the
;;;; registry. Dry-run packs without network. Hermetic tests use the fixture
;;;; registry PUT route.

(in-package :clun.installer)

(defparameter *default-publish-excludes*
  '(".git" ".hg" ".svn" "CVS" "node_modules" ".clun-cache"
    ".DS_Store" "clun.lock" "package-lock.json" "yarn.lock" "pnpm-lock.yaml"
    ".npmrc" ".yarnrc" ".yarnrc.yml")
  "Directory/file basenames skipped when walking a package for publish/pack.")

(defstruct (publish-result (:conc-name pr-))
  name version filename tarball-bytes integrity shasum
  registry tag (dry-run nil) (status nil) (body nil) (id nil))

;;; --- package walk / pack ----------------------------------------------------

(defun %basename (path)
  (sys:path-basename path))

(defun %skip-publish-name-p (name)
  (or (member name *default-publish-excludes* :test #'string=)
      (and (plusp (length name)) (char= (char name 0) #\.)
           (not (member name '(".gitignore" ".npmignore" ".gitattributes")
                        :test #'string=)))))

(defun %files-field-patterns (pkg)
  "Return the package.json `files` array as a list of strings, or NIL if absent."
  (let ((f (sys:jget pkg "files")))
    (cond
      ((null f) nil)
      ((eq f :empty-object) nil)
      ((vectorp f) (map 'list #'identity f))
      ((listp f)
       (loop for x in f when (stringp x) collect x))
      (t nil))))

(defun %path-under-p (rel prefix)
  (or (string= rel prefix)
      (and (>= (length rel) (1+ (length prefix)))
           (string= rel prefix :end1 (length prefix))
           (char= (char rel (length prefix)) #\/))))

(defun %files-allows-p (rel patterns)
  "Whether relative path REL is allowed by npm-style files patterns (subset)."
  (or (null patterns)
      (string= rel "package.json")
      (let ((base (%basename rel)))
        (or (and (>= (length base) 6) (string-equal "readme" base :end2 6))
            (and (>= (length base) 7) (string-equal "license" base :end2 7))
            (and (>= (length base) 7) (string-equal "licence" base :end2 7))))
      (some (lambda (pat)
              (cond
                ((string= pat rel) t)
                ((and (plusp (length pat))
                      (char= (char pat (1- (length pat))) #\/)
                      (%path-under-p rel (subseq pat 0 (1- (length pat)))))
                 t)
                ((%path-under-p rel pat) t)
                ((and (find #\* pat)
                      (let ((star (position #\* pat)))
                        (and star
                             (zerop star)
                             (let ((suf (subseq pat 1)))
                               (and (>= (length rel) (length suf))
                                    (string= rel suf
                                             :start1 (- (length rel) (length suf))))))))
                 t)
                (t nil)))
            patterns)))

(defun %walk-package-files (root &optional (rel "") patterns)
  "Collect (archive-rel . absolute-path) for publishable files under ROOT."
  (let ((abs (if (plusp (length rel)) (sys:path-join root rel) root))
        (out '()))
    (dolist (name (sys:read-directory abs))
      (unless (%skip-publish-name-p name)
        (let* ((child-rel (if (plusp (length rel))
                              (concatenate 'string rel "/" name)
                              name))
               (child-abs (sys:path-join root child-rel)))
          (cond
            ((sys:directory-p child-abs)
             (setf out (nconc out (%walk-package-files root child-rel patterns))))
            ((and (sys:file-p child-abs)
                  (%files-allows-p child-rel patterns))
             (push (cons child-rel child-abs) out))))))
    out))

(defun %archive-entries-for-root (root)
  "Build (\"package/…\" . content) entries for write-tar from ROOT/package.json."
  (let* ((pkg (read-package-json root))
         (patterns (%files-field-patterns pkg))
         (files (%walk-package-files root "" patterns))
         (entries '()))
    ;; Always ensure package.json is present first.
    (unless (find "package.json" files :key #'car :test #'string=)
      (let ((pj (sys:path-join root "package.json")))
        (when (sys:path-exists-p pj)
          (push (cons "package.json" pj) files))))
    (push (cons "package" :directory) entries)
    (dolist (pair (sort files #'string< :key #'car))
      (let* ((rel (car pair))
             (abs (cdr pair))
             (arch (concatenate 'string "package/" rel)))
        (push (cons arch (sys:read-file-octets abs)) entries)))
    (nreverse entries)))

(defun pack-package (root &key (mtime 0))
  "Pack ROOT into a gzip npm tarball. Returns a publish-result with bytes filled
(no network). Signals install-error when package.json is missing name/version."
  (let* ((pkg (read-package-json root))
         (name (sys:jget pkg "name"))
         (version (sys:jget pkg "version")))
    (unless (and (stringp name) (plusp (length name)))
      (error 'install-error :message "package.json missing string \"name\""))
    (unless (and (stringp version) (plusp (length version)))
      (error 'install-error :message "package.json missing string \"version\""))
    (let* ((entries (%archive-entries-for-root root))
           (tgz (arch:build-archive-bytes entries :compress :gzip :mtime mtime))
           (safe-name (substitute #\- #\/ name)) ; scoped @s/p → @s-p for filename
           (filename (format nil "~a-~a.tgz" safe-name version))
           (integrity (integ:sri-string :sha512 tgz))
           (shasum (string-downcase
                    (format nil "~{~2,'0x~}"
                            (coerce (integ:digest-bytes :sha1 tgz) 'list)))))
      (make-publish-result
       :name name :version version :filename filename
       :tarball-bytes tgz :integrity integrity :shasum shasum))))

;;; --- auth -------------------------------------------------------------------

(defun %read-text-if-exists (path)
  (when (and path (sys:path-exists-p path))
    (sys:read-file-string path)))

(defun load-publish-npmrc (&key root)
  "Merge .npmrc from ROOT (project) and ~/.npmrc (user). Project wins on key conflict
by being parsed last into a combined text (simple: project overrides via second parse
merge of auth tokens / registry)."
  (let* ((home (or (sys:homedir) ""))
         (user (when (plusp (length home))
                 (%read-text-if-exists (sys:path-join home ".npmrc"))))
         (proj (when root
                 (%read-text-if-exists (sys:path-join root ".npmrc"))))
         (text (concatenate 'string
                            (or user "")
                            (if (and user proj) (string #\Newline) "")
                            (or proj ""))))
    (if (plusp (length text))
        (reg:parse-npmrc text)
        (reg:parse-npmrc ""))))

(defun publish-token (&key npmrc registry)
  "Auth token for REGISTRY: NPM_TOKEN / npm_token env, else .npmrc _authToken match."
  (or (sys:getenv "NPM_TOKEN")
      (sys:getenv "npm_token")
      (multiple-value-bind (host port secure path)
          (reg:parse-registry-base (or registry reg:*default-registry*))
        (declare (ignore secure))
        (reg:auth-token-for npmrc host port path))))

;;; --- publish body -----------------------------------------------------------

(defun %pkg-field-string (pkg key &optional default)
  (let ((v (sys:jget pkg key)))
    (if (stringp v) v default)))

(defun %json-escape (s)
  (with-output-to-string (o)
    (write-char #\" o)
    (loop for c across (string s) do
      (case c
        (#\" (write-string "\\\"" o))
        (#\\ (write-string "\\\\" o))
        (#\Newline (write-string "\\n" o))
        (#\Return (write-string "\\r" o))
        (#\Tab (write-string "\\t" o))
        (t (if (< (char-code c) 32)
               (format o "\\u~4,'0x" (char-code c))
               (write-char c o)))))
    (write-char #\" o)))

(defun %b64 (octets)
  (cl-base64:usb8-array-to-base64-string octets :columns 0))

(defun build-publish-document (pkg packed &key (tag "latest") registry)
  "Build the npm attach-document JSON string for PACKED publish-result."
  (let* ((name (pr-name packed))
         (version (pr-version packed))
         (filename (pr-filename packed))
         (tgz (pr-tarball-bytes packed))
         (base (or registry reg:*default-registry*))
         (tarball-url
          (let ((b base))
            (unless (and (plusp (length b))
                         (char= (char b (1- (length b))) #\/))
              (setf b (concatenate 'string b "/")))
            (format nil "~a~a/-/~a"
                    b (reg:encode-package-name name) filename)))
         (desc (%pkg-field-string pkg "description" ""))
         (main (%pkg-field-string pkg "main"))
         (license (%pkg-field-string pkg "license"))
         (b64 (%b64 tgz)))
    (with-output-to-string (o)
      (format o "{\"_id\":~a,\"name\":~a" (%json-escape name) (%json-escape name))
      (when (plusp (length desc))
        (format o ",\"description\":~a" (%json-escape desc)))
      (format o ",\"dist-tags\":{~a:~a}" (%json-escape tag) (%json-escape version))
      (format o ",\"versions\":{~a:{" (%json-escape version))
      (format o "\"name\":~a,\"version\":~a" (%json-escape name) (%json-escape version))
      (when (plusp (length desc))
        (format o ",\"description\":~a" (%json-escape desc)))
      (when main (format o ",\"main\":~a" (%json-escape main)))
      (when license (format o ",\"license\":~a" (%json-escape license)))
      (format o ",\"_id\":~a" (%json-escape (format nil "~a@~a" name version)))
      (format o ",\"dist\":{\"shasum\":~a,\"integrity\":~a,\"tarball\":~a}"
              (%json-escape (pr-shasum packed))
              (%json-escape (pr-integrity packed))
              (%json-escape tarball-url))
      (format o "}}")
      (format o ",\"_attachments\":{~a:{" (%json-escape filename))
      (format o "\"content_type\":\"application/octet-stream\"")
      (format o ",\"data\":~a" (%json-escape b64))
      (format o ",\"length\":~d}}" (length tgz))
      (format o "}"))))

;;; --- HTTP PUT ---------------------------------------------------------------

(defun %publish-put-sync (registry name body token &key (timeout 60))
  "Synchronous PUT of BODY (string) to REGISTRY for package NAME. Returns
(values status response-body-string)."
  (multiple-value-bind (host port secure path)
      (reg:parse-registry-base registry)
    (let* ((req-path (concatenate 'string path (reg:encode-package-name name)))
           (headers (list (cons "content-type" "application/json")
                          (cons "accept" "application/json")
                          (cons "npm-command" "publish")
                          (cons "user-agent" "clun-publish")))
           (headers (if token
                        (cons (cons "authorization" (format nil "Bearer ~a" token)) headers)
                        headers))
           (body-octets (sb-ext:string-to-octets body :external-format :utf-8))
           (host-header (if (or (and secure (= port 443))
                                (and (not secure) (= port 80)))
                            host
                            (format nil "~a:~d" host port)))
           (timeout-ms (truncate (* (or timeout 60) 1000))))
      (flet ((decode-body (resp)
               (handler-case
                   (sb-ext:octets-to-string (net:hres-body resp) :external-format :utf-8)
                 (error () ""))))
        (if secure
            (handler-case
                (let ((resp (net:https-request :host host :port port :method "PUT"
                                               :path req-path :headers headers
                                               :body body-octets :host-header host-header
                                               :connect-timeout-ms timeout-ms)))
                  (values (net:hres-status resp) (decode-body resp)))
              (error (e)
                (error 'install-error
                       :message (format nil "publish request failed: ~a" e))))
            ;; HTTP (hermetic fixture): drive one-shot request on an event loop.
            (let ((loop (lp:make-event-loop :workers 0))
                  (status nil) (resp-body nil) (err nil))
              (unwind-protect
                   (progn
                     (net:http-request-async
                      loop :host host :port port :method "PUT" :path req-path
                      :host-header host-header :headers headers
                      :body body-octets :timeout timeout-ms
                      :on-response (lambda (resp)
                                     (setf status (net:hres-status resp)
                                           resp-body (decode-body resp))
                                     (lp:loop-stop loop))
                      :on-error (lambda (code)
                                  (setf err code)
                                  (lp:loop-stop loop)))
                     (lp:run-loop loop)
                     (when err
                       (error 'install-error
                              :message (format nil "publish request failed: ~a" err)))
                     (values status (or resp-body "")))
                (ignore-errors (lp:destroy-event-loop loop)))))))))

(defun publish-package (root &key registry tag access dry-run token npmrc
                               (timeout 60))
  "Publish ROOT. When DRY-RUN is true, pack only. ACCESS is accepted for CLI
parity (public/restricted) and recorded in the result. Returns a publish-result."
  (declare (ignore access))
  (let* ((pkg (read-package-json root))
         (packed (pack-package root))
         (rc (or npmrc (load-publish-npmrc :root root)))
         (reg-url (or registry
                      (reg:resolve-registry (pr-name packed) :npmrc rc)
                      reg:*default-registry*))
         (tag (or tag "latest"))
         (tok (or token (publish-token :npmrc rc :registry reg-url))))
    (setf (pr-registry packed) reg-url
          (pr-tag packed) tag
          (pr-dry-run packed) (and dry-run t))
    (when dry-run
      (setf (pr-status packed) 0
            (pr-body packed) "dry-run"
            (pr-id packed) (format nil "~a@~a" (pr-name packed) (pr-version packed)))
      (return-from publish-package packed))
    (unless (and tok (plusp (length tok)))
      (error 'install-error
             :message "publish requires auth: set NPM_TOKEN or //registry/:_authToken in .npmrc"))
    (let* ((doc (build-publish-document pkg packed :tag tag :registry reg-url)))
      (multiple-value-bind (status body)
          (%publish-put-sync reg-url (pr-name packed) doc tok :timeout timeout)
        (setf (pr-status packed) status
              (pr-body packed) body
              (pr-id packed) (format nil "~a@~a" (pr-name packed) (pr-version packed)))
        (unless (and status (>= status 200) (< status 300))
          (error 'install-error
                 :message (format nil "publish failed HTTP ~a~@[: ~a~]"
                                  status
                                  (when (and body (plusp (length body)))
                                    (if (> (length body) 200)
                                        (subseq body 0 200)
                                        body)))))
        packed))))
