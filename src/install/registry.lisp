;;;; registry.lisp — the npm registry client (PLAN.md Phase 21, §3.5). Fetches ABBREVIATED
;;;; package metadata (Accept: application/vnd.npm.install-v1+json) over the Phase-18 reactor
;;;; HTTP client, parses it with the engine-free clun.sys JSON reader into a metadata struct,
;;;; and resolves the registry base from a --registry override / a minimal .npmrc. Pure CL,
;;;; no engine dependency (the install substrate is §3.6 substrate). Transport is HTTP for the
;;;; local fixture (hermetic tests) and the real registry over the network; HTTPS reuses the
;;;; blocking pure-CL TLS client on a worker. The client prefers TLS 1.3 and retries on a fresh
;;;; connection with its experimental bounded TLS 1.2 profile only when the peer returns the exact
;;;; fatal protocol_version alert. The live, non-hermetic `make smoke-npm` gate is required in
;;;; Compatibility and Release and covers public npm metadata, tarballs, SRI, dependency-graph
;;;; execution, and transport-denied cached reinstall through the shipped CLI. Issue #234 owns the
;;;; WebPKI hardening required before release.

(in-package :clun.registry)

;;; --- conditions -------------------------------------------------------------

(define-condition registry-error (error)
  ((message :initarg :message :reader registry-error-message :initform "registry error"))
  (:report (lambda (c s) (write-string (registry-error-message c) s))))

(define-condition package-not-found (registry-error)
  ((name :initarg :name :reader package-not-found-name))
  (:report (lambda (c s) (format s "package not found: ~a" (package-not-found-name c)))))

(define-condition registry-status-error (registry-error)
  ((status :initarg :status :reader registry-status-error-status)
   (name :initarg :name :initform nil :reader registry-status-error-name))
  (:report (lambda (c s) (format s "registry returned HTTP ~a~@[ for ~a~]"
                                 (registry-status-error-status c) (registry-status-error-name c)))))

(defparameter *default-registry* "https://registry.npmjs.org/"
  "The registry base URL used when neither --registry nor .npmrc overrides it.")

(defparameter *abbreviated-accept* "application/vnd.npm.install-v1+json"
  "The Accept media type that asks the registry for the ABBREVIATED metadata document
(a much smaller payload than the full document — only the fields install needs).")

;;; --- metadata structs -------------------------------------------------------

(defstruct (version-meta (:conc-name vm-))
  version dependencies optional-dependencies peer-dependencies
  bin engines os cpu (has-install-script nil) (deprecated nil)
  dist-tarball dist-shasum dist-integrity)

(defstruct (pkg-metadata (:conc-name md-))
  name
  (dist-tags '())                       ; alist tag -> version string
  (versions (make-hash-table :test 'equal))  ; version string -> version-meta
  modified etag)

(defun metadata-version (md version)
  "The version-meta for VERSION in MD, or NIL."
  (gethash version (md-versions md)))

(defun metadata-latest (md)
  "The version string of MD's `latest` dist-tag, or NIL."
  (cdr (assoc "latest" (md-dist-tags md) :test #'string=)))

(defun metadata-version-strings (md)
  "All version strings present in MD (unordered)."
  (loop for v being the hash-key of (md-versions md) collect v))

;;; --- URL + name encoding ----------------------------------------------------

(defun parse-registry-base (url)
  "Split a registry base URL into (values host port secure-p base-path). BASE-PATH keeps its
trailing slash so a package segment can be appended directly. Defaults: port 443 (https) /
80 (http); a bare host is treated as https."
  (let* ((secure t) (rest url))
    (cond ((and (>= (length url) 8) (string-equal "https://" url :end2 8))
           (setf secure t rest (subseq url 8)))
          ((and (>= (length url) 7) (string-equal "http://" url :end2 7))
           (setf secure nil rest (subseq url 7))))
    (let* ((slash (position #\/ rest))
           (authority0 (if slash (subseq rest 0 slash) rest))
           (path (if slash (subseq rest slash) "/"))
           (default-port (if secure 443 80))
           ;; strip userinfo (user[:pass]@) — the credentials are NOT the host
           (at (position #\@ authority0 :from-end t))
           (authority (if at (subseq authority0 (1+ at)) authority0)))
      (multiple-value-bind (host port)
          (if (and (plusp (length authority)) (char= (char authority 0) #\[))
              ;; [ipv6]:port — the colons inside the brackets are the address, not a port sep
              (let ((rb (position #\] authority)))
                (if rb
                    (values (subseq authority 1 rb)
                            (let ((c (position #\: authority :start rb)))
                              (if c (or (ignore-errors (parse-integer authority :start (1+ c))) default-port)
                                  default-port)))
                    (values authority default-port)))         ; unterminated — best effort
              (let ((colon (position #\: authority)))
                (values (if colon (subseq authority 0 colon) authority)
                        (if colon (or (ignore-errors (parse-integer authority :start (1+ colon))) default-port)
                            default-port))))
        (unless (and (plusp (length path)) (char= (char path (1- (length path))) #\/))
          (setf path (concatenate 'string path "/")))
        (values host port secure (if (plusp (length host)) path "/"))))))

(defun encode-package-name (name)
  "URL-encode a package name for a metadata path. A scoped name `@scope/pkg` becomes
`@scope%2Fpkg` (the ONLY character npm percent-encodes in a package path is the `/` of a
scope); an unscoped name is unchanged."
  (if (and (plusp (length name)) (char= (char name 0) #\@))
      (let ((slash (position #\/ name)))
        (if slash
            (concatenate 'string (subseq name 0 slash) "%2F" (subseq name (1+ slash)))
            name))
      name))

(defun metadata-path (base-path name)
  "The request path for NAME's metadata under BASE-PATH (which ends in `/`)."
  (concatenate 'string base-path (encode-package-name name)))

;;; --- minimal .npmrc ---------------------------------------------------------

(defstruct (npmrc (:conc-name npmrc-))
  (default-registry nil)
  (scope-registries '())                ; alist "@scope" -> registry URL
  (auth-tokens '()))                    ; alist "//host/[path]" -> token

(defun %npmrc-trim (s) (string-trim '(#\Space #\Tab #\Return #\Newline) s))

(defun parse-npmrc (text)
  "Parse a MINIMAL subset of .npmrc from TEXT (not full npm config): `registry=URL`,
`@scope:registry=URL`, and `//host/[path]:_authToken=TOKEN`. Blank lines and `;`/`#`
comments are ignored; unknown keys are ignored. Returns an NPMRC struct."
  (let ((rc (make-npmrc)))
    (with-input-from-string (in text)
      (loop for raw = (read-line in nil nil) while raw do
        (let ((line (%npmrc-trim raw)))
          (when (and (plusp (length line))
                     (not (member (char line 0) '(#\; #\#))))
            (let ((eq (position #\= line)))
              (when eq
                (let ((key (%npmrc-trim (subseq line 0 eq)))
                      (val (%npmrc-trim (subseq line (1+ eq)))))
                  (cond
                    ((string= key "registry") (setf (npmrc-default-registry rc) val))
                    ((and (plusp (length key)) (char= (char key 0) #\@)
                          (let ((c (search ":registry" key)))
                            (and c (= (+ c (length ":registry")) (length key)))))
                     (push (cons (subseq key 0 (search ":registry" key)) val)
                           (npmrc-scope-registries rc)))
                    ((let ((c (search ":_authToken" key)))
                       (and c (= (+ c (length ":_authToken")) (length key))))
                     (push (cons (subseq key 0 (search ":_authToken" key)) val)
                           (npmrc-auth-tokens rc)))))))))))
    rc))

(defun package-scope (name)
  "The `@scope` of a scoped NAME, or NIL for an unscoped package."
  (when (and (plusp (length name)) (char= (char name 0) #\@))
    (let ((slash (position #\/ name)))
      (when slash (subseq name 0 slash)))))

(defun resolve-registry (name &key override npmrc)
  "The registry base URL for NAME: an explicit OVERRIDE (--registry) wins; else a
scope-specific `@scope:registry` from NPMRC; else NPMRC's default `registry`; else the
built-in *default-registry*."
  (or override
      (let ((scope (package-scope name)))
        (and scope npmrc (cdr (assoc scope (npmrc-scope-registries npmrc) :test #'string=))))
      (and npmrc (npmrc-default-registry npmrc))
      *default-registry*))

(defun %parse-authtoken-key (k)
  "Parse a .npmrc auth key `//host[:port]/pathprefix` → (values host port-or-nil pathprefix),
or NIL if it is not a `//authority/path` key."
  (when (and (>= (length k) 2) (string= "//" k :end2 2))
    (let* ((rest (subseq k 2))
           (slash (position #\/ rest))
           (authority (if slash (subseq rest 0 slash) rest))
           (pathprefix (if slash (subseq rest slash) "/"))
           (colon (position #\: authority)))
      (values (if colon (subseq authority 0 colon) authority)
              (and colon (ignore-errors (parse-integer authority :start (1+ colon))))
              pathprefix))))

(defun auth-token-for (npmrc host port path)
  "The _authToken scoped to (HOST, PORT, PATH), or NIL. A key `//host[:port]/prefix` matches
only when the host matches, the port matches (if the key names one), AND PATH is under the
key's path PREFIX — so a token scoped to `//host/private/` is NOT leaked to `/other`."
  (when npmrc
    (loop for (k . tok) in (npmrc-auth-tokens npmrc)
          do (multiple-value-bind (kh kp kpath) (%parse-authtoken-key k)
               (when (and kh (string-equal kh host)
                          (or (null kp) (= kp port))
                          (>= (length path) (length kpath))
                          (string= kpath path :end2 (length kpath)))
                 (return tok))))))

;;; --- metadata parsing -------------------------------------------------------

(defun %jstr (v &optional default)
  "V as a string if it is one, else DEFAULT (JSON strings parse to CL strings)."
  (if (stringp v) v default))

(defun %alist-of (v)
  "A parsed JSON object V as a plain alist of (string . value); NIL for the empty object or
a non-object (dependencies/bin are objects, missing → empty)."
  (cond ((eq v :empty-object) '())
        ((sys:jobject-p v) v)
        (t '())))

(defun %string-alist (v)
  "V (a JSON object) as an alist of (string . string) — deps: name -> range string."
  (loop for (k . val) in (%alist-of v)
        collect (cons k (%jstr val ""))))

(defun %string-vector (v)
  "A JSON array of strings V as a list of strings (os/cpu); NIL if absent."
  (when (vectorp v)
    (loop for x across v when (stringp x) collect x)))

(defun %parse-version-meta (vobj)
  "Build a version-meta from one abbreviated version object VOBJ."
  (let ((dist (sys:jget vobj "dist")))
    (make-version-meta
     :version (%jstr (sys:jget vobj "version"))
     :dependencies (%string-alist (sys:jget vobj "dependencies"))
     :optional-dependencies (%string-alist (sys:jget vobj "optionalDependencies"))
     :peer-dependencies (%string-alist (sys:jget vobj "peerDependencies"))
     :bin (let ((b (sys:jget vobj "bin")))
            (if (stringp b) b (%string-alist b)))   ; bin may be a string or an object
     :engines (%string-alist (sys:jget vobj "engines"))
     :os (%string-vector (sys:jget vobj "os"))
     :cpu (%string-vector (sys:jget vobj "cpu"))
     :has-install-script (eq (sys:jget vobj "hasInstallScript") sys:json-true)
     :deprecated (%jstr (sys:jget vobj "deprecated"))
     :dist-tarball (%jstr (sys:jget dist "tarball"))
     :dist-shasum (%jstr (sys:jget dist "shasum"))
     :dist-integrity (%jstr (sys:jget dist "integrity")))))

(defun parse-metadata (json-text &optional etag)
  "Parse an abbreviated-metadata JSON document into a pkg-metadata struct."
  (let* ((root (sys:parse-json json-text))
         (md (make-pkg-metadata :name (%jstr (sys:jget root "name"))
                                :modified (%jstr (sys:jget root "modified"))
                                :etag etag)))
    (setf (md-dist-tags md)
          (loop for (tag . ver) in (%alist-of (sys:jget root "dist-tags"))
                collect (cons tag (%jstr ver))))
    (loop for (ver . vobj) in (%alist-of (sys:jget root "versions"))
          do (setf (gethash ver (md-versions md)) (%parse-version-meta vobj)))
    md))

;;; --- transport --------------------------------------------------------------
;;; (a metadata response body is bounded by the HTTP parser's *max-body-bytes*, 100 MB.)

(defun %transient-status-p (status)
  "A 5xx, 429 (Too Many Requests), or 408 (Request Timeout) is retryable; other 4xx are hard
client errors (matching what npm/pacote retry)."
  (or (= status 408) (= status 429) (>= status 500)))

(defun %https-request-async (loop &key host port method path headers body host-header
                                       timeout on-response on-error)
  "HTTPS transport, same worker-pool path fetch uses: net:https-request runs BLOCKING on the
worker pool; its completion runs on the loop thread → ON-RESPONSE (a parsed http-response) /
ON-ERROR (a code string). CA trust = $SSL_CERT_FILE / the system bundle; certificates fail
closed. Returns a cancel thunk that closes the worker's socket to unblock its read."
  (let ((box (list nil))                 ; (car box) ← a socket-close thunk, set by the worker
        (done nil))
    (flet ((settle (thunk) (unless done (setf done t) (funcall thunk)))
           (abort-socket () (when (car box) (funcall (car box)))))
      (lp:worker-submit loop
        (lambda () (net:https-request :host host :port port :method method :path path
                                      :headers headers :body body :host-header host-header
                                      :socket-box box))
        (lambda (result)               ; loop thread
          (settle (lambda ()
                    (if (eq (car result) :ok)
                        (funcall on-response (second result))
                        (funcall on-error (net:tls-error-message (second result))))))))
      (when (and timeout (plusp timeout))
        (lp:set-timer loop timeout
          (lambda () (unless done (abort-socket) (settle (lambda () (funcall on-error "timeout")))))))
      (lambda () (unless done (abort-socket) (settle (lambda () (funcall on-error "abort"))))))))

(defun fetch-metadata-async (loop name
                             &key override npmrc etag (retries 2) (timeout 30000)
                                  extra-headers on-ok on-err)
  "Fetch NAME's abbreviated metadata. Resolves the registry base (OVERRIDE / NPMRC / default),
issues the request with Accept: application/vnd.npm.install-v1+json (and If-None-Match if ETAG
is given), and on success calls ON-OK with a pkg-metadata (or the keyword :not-modified on a
304). ON-ERR receives a condition. Retries transient failures (connection error / timeout /
5xx / 429) up to RETRIES times with a linear backoff. Returns a cancel thunk."
  (let* ((base (resolve-registry name :override override :npmrc npmrc))
         (settled nil) (current-cancel nil) (retry-timer nil))
    (multiple-value-bind (host port secure base-path) (parse-registry-base base)
      (let* ((path (metadata-path base-path name))
             (token (auth-token-for npmrc host port path))
             (headers (append
                       (list (cons "Accept" *abbreviated-accept*))
                       (when etag (list (cons "If-None-Match" etag)))
                       (when token (list (cons "Authorization" (concatenate 'string "Bearer " token))))
                       extra-headers)))
        (labels ((clear-retry () (when retry-timer (lp:clear-timer retry-timer) (setf retry-timer nil)))
                 (settle-ok (v) (unless settled (setf settled t) (clear-retry) (when on-ok (funcall on-ok v))))
                 (settle-err (c) (unless settled (setf settled t) (clear-retry) (when on-err (funcall on-err c))))
                 (on-resp (resp n)
                   (let ((status (net:hres-status resp)))
                     (cond
                       ((= status 304) (settle-ok :not-modified))
                       ((= status 404) (settle-err (make-condition 'package-not-found :name name)))
                       ((and (>= status 200) (< status 300))
                        (handler-case
                            (let ((et (net:%header (net:hres-headers resp) "etag"))
                                  (text (%body->string (net:hres-body resp))))
                              (settle-ok (parse-metadata text et)))
                          (error (e)
                            (settle-err (make-condition 'registry-error
                              :message (format nil "bad metadata for ~a: ~a" name e))))))
                       ((and (%transient-status-p status) (< n retries)) (%retry n))
                       (t (settle-err (make-condition 'registry-status-error
                            :status status :name name))))))
                 (on-err-code (code n)
                   (if (and (< n retries) (not (string= code "abort")))
                       (%retry n)
                       (settle-err (make-condition 'registry-error
                         :message (format nil "request failed for ~a: ~a" name code)))))
                 (attempt (n)
                   ;; dispatch by scheme: http over the Phase-18 reactor client; https over the
                   ;; Phase-20 pure-tls worker path. Both deliver a parsed http-response.
                   (let ((host-header (if (or (and secure (= port 443)) (and (not secure) (= port 80)))
                                          host (format nil "~a:~d" host port))))
                     (setf current-cancel
                           (funcall (if secure #'%https-request-async #'net:http-request-async)
                                    loop :host host :port port :method "GET" :path path
                                    :host-header host-header :headers headers :timeout timeout
                                    :on-response (lambda (resp) (on-resp resp n))
                                    :on-error (lambda (code) (on-err-code code n))))))
                 (%retry (n)
                   ;; linear backoff: 100ms, 200ms, … keeps the fixture tests fast while still
                   ;; exercising the retry path. The timer is tracked so a settle/abort clears
                   ;; it (an orphaned ref'd timer would otherwise keep the loop alive to fire).
                   (setf retry-timer
                         (lp:set-timer loop (* 100 (1+ n)) (lambda () (setf retry-timer nil)
                                                             (unless settled (attempt (1+ n))))))))
          (attempt 0)
          (lambda () (unless settled (when current-cancel (funcall current-cancel))
                            (settle-err (make-condition 'registry-error :message "aborted")))))))))

(defun %body->string (octets)
  "Decode a response body (already gunzipped by the HTTP client) as UTF-8, leniently."
  (handler-case (sb-ext:octets-to-string octets :external-format :utf-8)
    (error () (map 'string #'code-char octets))))
