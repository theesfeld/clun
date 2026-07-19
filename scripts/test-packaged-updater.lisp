;;;; Exercise updater staging/activation against a real scripts/release/package.sh archive.

(load (merge-pathnames "registry.lisp" *load-truename*))
(asdf:load-system :clun)

(flet ((required-env (name)
         (let ((value (sb-ext:posix-getenv name)))
           (unless (and value (plusp (length value)))
             (error "~a is required" name))
           value)))
  (let* ((archive (required-env "CLUN_PACKAGED_UPDATE_ARCHIVE"))
         (version (required-env "CLUN_PACKAGED_UPDATE_VERSION"))
         (expected-target (required-env "CLUN_PACKAGED_UPDATE_TARGET"))
         (root (required-env "CLUN_PACKAGED_UPDATE_ROOT"))
         (target (clun.cli::%release-target-name))
         (launcher (clun.sys:path-join root "bin" "clun"))
         (old-target (clun.sys:path-join root "old" "bin" "clun"))
         (releases-root (clun.sys:path-join root "releases")))
    (unless (string= target expected-target)
      (error "test host target ~a does not match packaged target ~a" target expected-target))
    (clun.sys:make-directory (clun.sys:path-dirname old-target) :recursive t :mode #o755)
    (clun.sys:write-file-octets
     old-target
     (sb-ext:string-to-octets "old packaged updater sentinel" :external-format :utf-8)
     :mode #o755)
    (clun.sys:change-mode old-target #o755)
    (clun.sys:make-directory (clun.sys:path-dirname launcher) :recursive t :mode #o755)
    (clun.sys:make-symlink old-target launcher)
    (let* ((context
             (clun.cli::%make-update-install-context
              :launcher launcher :bundle nil :releases-root releases-root :target target))
           (final
             (clun.cli::%install-payload-octets
              (clun.sys:read-file-octets archive) version context)))
      (unless (and (clun.sys:directory-p final)
                   (string= (clun.sys:realpath launcher)
                            (clun.sys:realpath
                             (clun.sys:path-join final "bin" "clun"))))
        (error "real packaged updater fixture did not activate its full bundle"))
      (format t "packaged updater activated ~a via ~a~%" final launcher))))
