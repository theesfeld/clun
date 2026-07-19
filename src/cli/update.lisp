;;;; update.lisp — built-in self-update from GitHub Releases (user standard §8.3).
;;;; Uses the pure-CL fetch stack (same TLS path as runtime fetch) so GitHub works.
;;;; Resolves newest release (including prereleases), downloads the same archive
;;;; assets as site/install, verifies SHA-256, replaces the running binary.

(in-package :clun.cli)

(defparameter *update-repo* "theesfeld/clun"
  "owner/repo for GitHub Releases.")

(defparameter *update-user-agent* "clun-update/0.1"
  "GitHub requires a User-Agent on unauthenticated downloads.")

(defun %update-current-version ()
  clun::*clun-version*)

(defun %js-string (value)
  (cond
    ((stringp value) value)
    ((eng:js-string-p value) (eng:to-string value))
    (t (eng:to-string value))))

(defun %fetch-text (url &key (headers '()) (timeout-ms 120000) (binary nil))
  "GET URL via pure-CL fetch; return body as a Lisp string (or octet vector if BINARY).
   Signals a CL error on network/HTTP failure."
  (let* ((realm (eng:make-realm))
         (hdr-entries
           (with-output-to-string (o)
             (format o "{")
             (format o "\"User-Agent\":~s" *update-user-agent*)
             (dolist (h headers)
               (format o ",~s:~s" (car h) (cdr h)))
             (format o "}")))
         (source
           (format nil
                   "(async () => {
  const r = await fetch(~s, { headers: ~a });
  if (!r.ok) {
    const err = new Error(\"HTTP \" + r.status + \" for \" + ~s);
    err.name = \"UpdateError\";
    throw err;
  }
  ~a
})()"
                   url hdr-entries url
                   (if binary
                       "const buf = await r.arrayBuffer();
  const u8 = new Uint8Array(buf);
  // stash on globalThis for host extraction
  globalThis.__clunUpdateBytes = u8;
  return u8.length;"
                       "return await r.text();"))))
    (clun.runtime:install-runtime realm :argv (list :script "[clun-update]" :rest '()) :cwd (sys:current-directory))
    (multiple-value-bind (kind value)
        (eng:run-callback-to-settlement
         (lambda () (eng:eval-source source :realm realm))
         realm
         :timeout-ms timeout-ms)
      (ecase kind
        (:fulfilled
         (if binary
             (let ((u8 (eng:js-get (eng:realm-global realm) "__clunUpdateBytes")))
               (unless (eng:js-typed-array-p u8)
                 (error "fetch binary body missing"))
               (multiple-value-bind (backing offset len) (eng:ta-octets u8)
                 (subseq backing offset (+ offset len))))
             (%js-string value)))
        (:rejected
         (error "fetch failed: ~a" (%js-string (eng:js-get value "message"))))
        (:timeout
         (error "fetch timed out for ~a" url))))))

(defun %first-tag-name-in-json (text)
  "First \"tag_name\":\"…\" occurrence in a GitHub Releases JSON payload."
  (let ((tag-pos (search "\"tag_name\":\"" text)))
    (when tag-pos
      (let* ((start (+ tag-pos (length "\"tag_name\":\"")))
             (end (position #\" text :start start)))
        (when end (subseq text start end))))))

(defun resolve-latest-release-tag ()
  "Resolve newest GitHub Release tag including prereleases (Clun's train is prerelease).
   Uses /releases?per_page=5 (not /releases/latest, which ignores prereleases).
   Honours GITHUB_TOKEN / GH_TOKEN when set."
  (handler-case
      (let* ((token (or (sys:getenv "GITHUB_TOKEN") (sys:getenv "GH_TOKEN")))
             (headers (list* (cons "Accept" "application/vnd.github+json")
                             (when token
                               (list (cons "Authorization" (format nil "Bearer ~a" token))))))
             (url (format nil "https://api.github.com/repos/~a/releases?per_page=5" *update-repo*))
             (text (%fetch-text url :headers headers))
             (tag (%first-tag-name-in-json text)))
        (if tag
            (values tag nil)
            (values nil "tag_name missing from releases list")))
    (error (e)
      (values nil (format nil "~a" e)))))

(defun %release-asset-basename ()
  (format nil "clun-~a-~a.tar.gz" (sys:platform-name) (sys:machine-arch)))

(defun %download-release-bytes (tag relative-name)
  (let ((url (format nil "https://github.com/~a/releases/download/~a/~a"
                     *update-repo* tag relative-name)))
    (%fetch-text url :binary t :timeout-ms 600000)))

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

(defun %current-executable ()
  (or (ignore-errors (clun.sfe:self-executable-path))
      (first sb-ext:*posix-argv*)
      "clun"))

(defun %find-named-file (root name)
  (labels ((walk (dir)
             (dolist (entry (or (ignore-errors (sys:read-directory dir)) '()))
               (let ((full (sys:path-join dir entry)))
                 (cond
                   ((sys:file-p full)
                    (when (string= (sys:path-basename full) name)
                      (return-from %find-named-file full)))
                   ((sys:directory-p full)
                    (let ((hit (walk full)))
                      (when hit (return-from %find-named-file hit)))))))))
    (walk root)
    nil))

(defun %install-payload-octets (payload dest-path)
  (let ((staging (sys:make-temp-dir
                  (sys:path-join (or (sys:getenv "TMPDIR") "/tmp") "clun-update-"))))
    (unwind-protect
         (progn
           (handler-case
               (progn
                 (clun.archive:extract-archive payload staging :strip-components 0)
                 (let ((found (or (%find-named-file staging "clun")
                                  (sys:path-join staging "clun"))))
                   (unless (sys:file-p found)
                     (error "archive did not contain a clun binary"))
                   (sys:copy-file* found dest-path)))
             (error ()
               (sys:write-file-octets dest-path payload)))
           (ignore-errors (sb-posix:chmod dest-path #o755))
           dest-path)
      (ignore-errors
        (when (sys:directory-p staging)
          (labels ((rm (p)
                     (cond
                       ((sys:file-p p) (ignore-errors (delete-file p)))
                       ((sys:directory-p p)
                        (dolist (e (or (ignore-errors (sys:read-directory p)) '()))
                          (rm (sys:path-join p e)))
                        (ignore-errors (sys:remove-directory p))))))
            (rm staging)))))))

(defun %prerelease-parts (version)
  "Split VERSION into (core major minor patch pre-id pre-num) for 0.1.0-dev.N style."
  (let* ((v (string-left-trim '(#\v #\V) version))
         (dash (position #\- v))
         (core (if dash (subseq v 0 dash) v))
         (pre (if dash (subseq v (1+ dash)) nil))
         (dots (loop for start = 0 then (1+ p)
                     for p = (position #\. core :start start)
                     collect (subseq core start (or p (length core)))
                     while p))
         (maj (ignore-errors (parse-integer (or (first dots) "0") :junk-allowed t)))
         (min (ignore-errors (parse-integer (or (second dots) "0") :junk-allowed t)))
         (pat (ignore-errors (parse-integer (or (third dots) "0") :junk-allowed t)))
         (pre-dot (and pre (position #\. pre)))
         (pre-id (if (and pre pre-dot) (subseq pre 0 pre-dot) pre))
         (pre-num (when (and pre pre-dot)
                    (ignore-errors (parse-integer (subseq pre (1+ pre-dot)) :junk-allowed t)))))
    (list core (or maj 0) (or min 0) (or pat 0) pre-id pre-num)))

(defun %version< (a b)
  "True when A is strictly older than B for 0.x.y-dev.N prerelease trains."
  (destructuring-bind (ca ma mia pa ia na) (%prerelease-parts a)
    (declare (ignore ca))
    (destructuring-bind (cb mb mib pb ib nb) (%prerelease-parts b)
      (declare (ignore cb))
      (cond
        ((< ma mb) t)
        ((> ma mb) nil)
        ((< mia mib) t)
        ((> mia mib) nil)
        ((< pa pb) t)
        ((> pa pb) nil)
        ;; same core: no prerelease > prerelease; compare pre-id then number
        ((and (null ia) ib) nil)
        ((and ia (null ib)) t)
        ((and ia ib)
         (cond
           ((string< ia ib) t)
           ((string> ia ib) nil)
           (t (< (or na -1) (or nb -1)))))
        (t nil)))))

(defun check-update (&key (stream *standard-output*) (error-stream *error-output*))
  "Print update availability. 0 = up to date (or local ahead of published);
   1 = newer published release available; 2 = error."
  (multiple-value-bind (tag err) (resolve-latest-release-tag)
    (cond
      (err
       (format error-stream "clun check-update: ~a~%" err)
       2)
      ((null tag)
       (format error-stream "clun check-update: could not resolve latest release~%")
       2)
      (t
       (let* ((current (%update-current-version))
              (remote (string-left-trim '(#\v #\V) tag)))
         (cond
           ((string= current remote)
            (format stream "clun ~a is up to date (latest ~a)~%" current tag)
            0)
           ((%version< current remote)
            (format stream "update available: ~a → ~a~%" current tag)
            1)
           (t
            (format stream "clun ~a is newer than published ~a (no update)~%" current tag)
            0)))))))

(defun perform-update (&key (stream *standard-output*) (error-stream *error-output*))
  "Download latest release asset, verify SHA-256, replace running binary. Print old → new."
  (multiple-value-bind (tag err) (resolve-latest-release-tag)
    (when err
      (format error-stream "clun update: ~a~%" err)
      (return-from perform-update 2))
    (unless tag
      (format error-stream "clun update: could not resolve latest release~%")
      (return-from perform-update 2))
    (let* ((old (%update-current-version))
           (remote (string-left-trim '(#\v #\V) tag))
           (asset (%release-asset-basename))
           (exe (%current-executable)))
      (when (or (string= old remote) (not (%version< old remote)))
        (format stream "clun ~a needs no update (published latest ~a)~%" old tag)
        (return-from perform-update 0))
      (format stream "updating clun ~a → ~a …~%" old tag)
      (handler-case
          (let* ((sum-text (%fetch-text
                            (format nil "https://github.com/~a/releases/download/~a/checksums.txt"
                                    *update-repo* tag)))
                 (sums (%checksums-map sum-text))
                 (want (gethash asset sums))
                 (payload (%download-release-bytes tag asset))
                 (got (%sha256-hex payload)))
            (unless want
              (format error-stream "clun update: no checksum entry for ~a~%" asset)
              (return-from perform-update 2))
            (unless (string= want got)
              (format error-stream "clun update: SHA-256 mismatch for ~a~%  expected ~a~%  got      ~a~%"
                      asset want got)
              (return-from perform-update 2))
            (let* ((dir (sys:path-dirname exe))
                   (tmp (sys:path-join dir (format nil ".clun-update-~d" (get-universal-time))))
                   (final (or (ignore-errors (sys:realpath exe)) exe)))
              (%install-payload-octets payload tmp)
              (rename-file tmp final)
              (format stream "clun ~a → ~a (installed ~a)~%" old remote final)
              0))
        (error (e)
          (format error-stream "clun update: ~a~%" e)
          2)))))
