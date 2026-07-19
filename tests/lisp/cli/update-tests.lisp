;;;; update-tests.lisp — Issue #221 redirect-first release resolution and atomic updater safety.

(in-package :clun-test)

(defmacro with-update-test-env ((name value) &body body)
  `(let ((old-value (sb-ext:posix-getenv ,name)))
     (unwind-protect
          (progn
            (sb-posix:setenv ,name ,value 1)
            ,@body)
       (if old-value
           (sb-posix:setenv ,name old-value 1)
           (sb-posix:unsetenv ,name)))))

(define-test update/redirect-first-skips-api
  (let* ((calls '())
         (clun.cli::*update-fetch-function*
           (lambda (url &key &allow-other-keys)
             (push url calls)
             (values "" "https://github.com/theesfeld/clun/releases/tag/v9.0.0"))))
    (multiple-value-bind (tag error)
        (cli:resolve-latest-release-tag :current-version "0.1.0-dev.69")
      (false error)
      (is string= "v9.0.0" tag)
      (is equal (list "https://github.com/theesfeld/clun/releases/latest")
          (nreverse calls)))))

(define-test update/api-fallback-honors-token-and-channel
  (let* ((calls '()) (api-headers nil)
         (payload
           "[{\"tag_name\":\"v1.5.0-dev.2\",\"draft\":false,\"prerelease\":true},
             {\"tag_name\":\"v1.4.0\",\"draft\":false,\"prerelease\":false}]")
         (clun.cli::*update-fetch-function*
           (lambda (url &key headers &allow-other-keys)
             (push url calls)
             (if (search "/releases/latest" url)
                 (error "redirect unavailable")
                 (progn
                   (setf api-headers headers)
                   (values payload url))))))
    (with-update-test-env ("GITHUB_TOKEN" "issue-221-token")
      (multiple-value-bind (tag error)
          (cli:resolve-latest-release-tag :current-version "1.5.0-dev.1")
        (false error)
        (is string= "v1.5.0-dev.2" tag)))
    (is equal '(("Authorization" . "Bearer issue-221-token"))
        (remove-if-not (lambda (header) (string= (car header) "Authorization")) api-headers))
    (is equal (list "https://github.com/theesfeld/clun/releases/latest"
                    "https://api.github.com/repos/theesfeld/clun/releases?per_page=10")
        (nreverse calls))
    ;; Stable installs never opt into a prerelease from the fallback list.
    (is string= "v1.4.0"
        (clun.cli::%api-release-tag payload "1.3.0"))
    (with-update-test-env ("GITHUB_TOKEN" "")
      (with-update-test-env ("GH_TOKEN" "issue-221-gh-token")
        (is equal '("Authorization" . "Bearer issue-221-gh-token")
            (assoc "Authorization" (clun.cli::%github-api-headers) :test #'string=))))
    (true (clun.cli::%version< "1.0.0-dev.9" "1.0.0-dev.10"))))

(define-test update/redirect-survives-api-403
  (let* ((calls 0)
         (clun.cli::*update-fetch-function*
           (lambda (url &key &allow-other-keys)
             (incf calls)
             (if (search "/releases/latest" url)
                 (values "" "https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.21")
                 (if (search "api.github.com" url)
                     (error "HTTP 403 for unauthenticated Releases API")
                     (error "Releases feed unavailable"))))))
    (multiple-value-bind (tag error)
        (cli:resolve-latest-release-tag :current-version "0.1.0-dev.69")
      (false error)
      (is string= "v0.1.0-dev.21" tag)
      (is = 3 calls))))

(define-test update/prerelease-atom-fallback-survives-api-403
  (let* ((calls '())
         (feed
           "<?xml version=\"1.0\"?><feed>
              <entry><link href=\"https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.8\"/></entry>
              <entry><link href=\"https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.70\"/></entry>
              <entry><link href=\"https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.69\"/></entry>
              <entry><link href=\"https://github.com/theesfeld/clun/releases/tag/not-semver\"/></entry>
            </feed>")
         (clun.cli::*update-fetch-function*
           (lambda (url &key &allow-other-keys)
             (push url calls)
             (cond
               ((search "/releases/latest" url)
                (values "" "https://github.com/theesfeld/clun/releases/tag/v0.0.9"))
               ((search "api.github.com" url)
                (error "HTTP 403 for unauthenticated Releases API"))
               ((search "/releases.atom" url) (values feed url))
               (t (error "unexpected update URL ~a" url))))))
    (multiple-value-bind (tag error)
        (cli:resolve-latest-release-tag :current-version "0.1.0-dev.69")
      (false error)
      (is string= "v0.1.0-dev.70" tag))
    (is equal (list "https://github.com/theesfeld/clun/releases/latest"
                    "https://api.github.com/repos/theesfeld/clun/releases?per_page=10"
                    "https://github.com/theesfeld/clun/releases.atom")
        (nreverse calls))
    ;; Stable installs do not opt into a prerelease even when it is numerically newer.
    (is string= "v0.0.9"
        (clun.cli::%highest-suitable-release-tag
         '("v0.1.0-dev.70" "v0.0.8" "v0.0.9") "v0.0.8"))))

(defun %update-text-octets (text)
  (sb-ext:string-to-octets text :external-format :utf-8))

(defun %update-fixture-payload (remote-version &key omit-sidecar reported-version)
  (let ((base (clun.cli::%release-package-basename))
        (entries '())
        (reported (or reported-version remote-version)))
    (push (cons (format nil "~a/VERSION" base)
                (format nil "~a~%" remote-version))
          entries)
    (push (cons (format nil "~a/bin/clun" base)
                (format nil "#!/bin/sh~%printf 'clun ~a\\n'~%" reported))
          entries)
    (when (string= (sys:platform-name) "linux")
      (push (cons (format nil "~a/lib/LOADER" base) (format nil "fixture-loader~%")) entries)
      (push (cons (format nil "~a/lib/fixture-loader" base)
                  (format nil "#!/bin/sh~%exec \"$@\"~%"))
            entries)
      (unless omit-sidecar
        (push (cons (format nil "~a/libexec/clun" base)
                    (format nil "#!/bin/sh~%printf 'clun ~a\\n'~%" reported))
              entries)))
    (clun.archive:build-archive-bytes (nreverse entries) :compress :gzip)))

(defun %write-update-fixture-file (path text &key executable)
  (sys:make-directory (sys:path-dirname path) :recursive t :mode #o755)
  (sys:write-file-octets path (%update-text-octets text) :mode (if executable #o755 #o644))
  (when executable (sys:change-mode path #o755))
  path)

(defun %make-managed-update-fixture (root current-version)
  (let* ((target (clun.cli::%release-target-name))
         (bundle (sys:path-join root "releases" current-version target))
         (launcher (sys:path-join root "bin" "clun"))
         (package-launcher (sys:path-join bundle "bin" "clun"))
         (actual (if (string= (sys:platform-name) "linux")
                     (sys:path-join bundle "libexec" "clun")
                     package-launcher)))
    (%write-update-fixture-file (sys:path-join bundle "VERSION")
                                (format nil "~a~%" current-version))
    (%write-update-fixture-file package-launcher
                                (format nil "#!/bin/sh~%printf 'clun ~a\\n'~%"
                                        current-version)
                                :executable t)
    (when (string= (sys:platform-name) "linux")
      (%write-update-fixture-file (sys:path-join bundle "lib" "LOADER")
                                  (format nil "fixture-loader~%"))
      (%write-update-fixture-file (sys:path-join bundle "lib" "fixture-loader")
                                  (format nil "#!/bin/sh~%exec \"$@\"~%") :executable t)
      (%write-update-fixture-file actual
                                  (format nil "#!/bin/sh~%printf 'clun ~a\\n'~%"
                                          current-version)
                                  :executable t))
    (sys:make-directory (sys:path-dirname launcher) :recursive t :mode #o755)
    (sys:make-symlink package-launcher launcher)
    (values launcher actual bundle)))

(defun %update-fetch-fixture (remote-tag payload checksums)
  (lambda (url &key binary &allow-other-keys)
    (cond
      ((search "/releases/latest" url)
       (values "" (format nil "https://github.com/theesfeld/clun/releases/tag/~a"
                          remote-tag)))
      ((search "checksums.txt" url) (values checksums url))
      (binary (values payload url))
      (t (error "unexpected update URL ~a" url)))))

(define-test update/full-bundle-path-discovery-and-activation
  (let* ((current (clun.cli::%update-current-version))
         (remote-version "9.0.0")
         (remote-tag (format nil "v~a" remote-version))
         (payload (%update-fixture-payload remote-version))
         (asset (clun.cli::%release-asset-basename))
         (checksums (format nil "~a  ~a~%" (clun.cli::%sha256-hex payload) asset))
         (root (sys:make-temp-dir "/tmp/clun-update-test-"))
         (cwd (sys:path-join root "cwd"))
         (old-cwd (sys:current-directory)))
    (unwind-protect
         (multiple-value-bind (launcher actual old-bundle)
             (%make-managed-update-fixture root current)
           (sys:make-directory cwd :recursive t :mode #o755)
           (let ((cwd-clun (%write-update-fixture-file
                            (sys:path-join cwd "clun") (format nil "cwd sentinel~%")
                            :executable t)))
             (sys:change-directory cwd)
             (with-update-test-env ("PATH" (format nil "~a:/usr/bin:/bin"
                                                    (sys:path-dirname launcher)))
               (with-update-test-env ("CLUN_UPDATE_LAUNCHER" "")
                 (let ((clun.cli::*update-current-executable-override* actual)
                       (clun.cli::*update-argv0-override* "clun")
                       (clun.cli::*update-fetch-function*
                         (%update-fetch-fixture remote-tag payload checksums)))
                   (is = 0 (cli:perform-update :stream (make-broadcast-stream)
                                              :error-stream (make-broadcast-stream))))))
             (let* ((new-bundle (sys:path-join root "releases" remote-version
                                               (clun.cli::%release-target-name)))
                    (new-package-launcher (sys:path-join new-bundle "bin" "clun")))
               (true (sys:directory-p old-bundle))
               (true (sys:directory-p new-bundle))
               (true (clun.cli::%symlink-p launcher))
               (is string= (sys:realpath new-package-launcher) (sys:realpath launcher))
               (is equalp (%update-text-octets (format nil "cwd sentinel~%"))
                   (sys:read-file-octets cwd-clun))
               (when (string= (sys:platform-name) "linux")
                 (true (sys:file-p (sys:path-join new-bundle "lib" "LOADER")))
                 (true (sys:file-p (sys:path-join new-bundle "lib" "fixture-loader")))
                 (true (sys:file-p (sys:path-join new-bundle "libexec" "clun")))))))
      (ignore-errors (sys:change-directory old-cwd))
      (ignore-errors (sys:remove-recursive root)))))

(define-test update/failures-preserve-current-launcher-and-bundle
  (let* ((current (clun.cli::%update-current-version))
         (remote-version "9.0.0")
         (remote-tag (format nil "v~a" remote-version))
         (asset (clun.cli::%release-asset-basename))
         (valid (%update-fixture-payload remote-version))
         (malformed (%update-text-octets "not a release archive"))
         (missing-sidecar (%update-fixture-payload remote-version :omit-sidecar t))
         (wrong-version (%update-fixture-payload
                         remote-version :reported-version "8.9.9")))
    (labels ((run-failure (payload checksum &key activation-verifier max-asset-bytes)
               (let ((root (sys:make-temp-dir "/tmp/clun-update-failure-")))
                 (unwind-protect
                      (multiple-value-bind (launcher actual old-bundle)
                          (%make-managed-update-fixture root current)
                        (let ((old-target (sys:realpath launcher))
                              (clun.cli::*update-current-executable-override* actual)
                              (clun.cli::*update-launcher-override* launcher)
                              (clun.cli::*update-activation-verifier* activation-verifier)
                              (clun.cli::*update-max-asset-bytes*
                                (or max-asset-bytes clun.cli::*update-max-asset-bytes*))
                              (clun.cli::*update-fetch-function*
                                (%update-fetch-fixture
                                 remote-tag payload
                                 (format nil "~a  ~a~%" checksum asset))))
                          (is = 2 (cli:perform-update :stream (make-broadcast-stream)
                                                     :error-stream (make-broadcast-stream)))
                          (true (sys:directory-p old-bundle))
                          (true (clun.cli::%symlink-p launcher))
                          (is string= old-target (sys:realpath launcher))))
                   (ignore-errors (sys:remove-recursive root))))))
      ;; Checksum mismatch stops before extraction.
      (run-failure valid (format nil "~64,'0d" 0))
      ;; An asset over the explicit update bound fails before extraction or activation.
      (run-failure valid (clun.cli::%sha256-hex valid)
                   :max-asset-bytes (1- (length valid)))
      ;; Checksum-valid malformed and structurally incomplete archives never activate.
      (run-failure malformed (clun.cli::%sha256-hex malformed))
      (run-failure wrong-version (clun.cli::%sha256-hex wrong-version))
      (when (string= (sys:platform-name) "linux")
        (run-failure missing-sidecar (clun.cli::%sha256-hex missing-sidecar)))
      ;; A post-rename validation failure atomically rolls back to the old symlink.
      (run-failure valid (clun.cli::%sha256-hex valid)
                   :activation-verifier (lambda (launcher target)
                                           (declare (ignore launcher target)) nil)))))
