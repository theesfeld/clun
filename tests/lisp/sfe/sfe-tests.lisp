;;;; sfe-tests.lisp — pure-CL single-file executables (Issue #181 FULL PORT).

(in-package :clun-test)

(defun %sfe-temp-dir ()
  (clun.sys:make-temp-dir
   (clun.sys:path-join (clun.sys:tmpdir) "clun-sfe-test-")))

(defun %sfe-write (dir name contents)
  (let ((path (clun.sys:path-join dir name)))
    (clun.sys:write-file-octets
     path
     (sb-ext:string-to-octets contents :external-format :utf-8))
    path))

(defun %sfe-host-template ()
  "Prefer the shipped build/clun; fall back to the running image path."
  (let* ((root (or (ignore-errors
                     (namestring
                      (truename
                       (merge-pathnames
                        "../../"
                        (or *load-truename* *default-pathname-defaults*)))))
                   (clun.sys:current-directory)))
         (build (clun.sys:path-join root "build" "clun"))
         (self (clun.sfe:self-executable-path)))
    (cond
      ((clun.sys:file-p build) build)
      ((and self (clun.sys:file-p self)) self)
      (t nil))))

(define-test sfe/target-normalize
  (is string= "clun-linux-x64" (clun.sfe:normalize-target "bun-linux-x64"))
  (is string= "clun-darwin-arm64" (clun.sfe:normalize-target "darwin-arm64"))
  (is string= "clun-linux-arm64" (clun.sfe:normalize-target "clun-linux-arm64"))
  (true (member (clun.sfe:host-target)
                (clun.sfe:all-four-targets) :test #'string=)))

(define-test sfe/payload-roundtrip
  (let* ((manifest '(("entry" . "/app/main.js")
                     ("target" . "clun-linux-x64")
                     ("format" . "CLUNSEA")))
         (modules '(("/app/main.js" . "console.log(1);")
                    ("/app/lib.js" . "export const x = 2;")))
         (assets (list (cons "icon.bin"
                             (make-array 4 :element-type '(unsigned-byte 8)
                                         :initial-contents #(1 2 3 4)))))
         (payload (clun.sfe:encode-payload manifest modules assets)))
    (multiple-value-bind (m mods ass) (clun.sfe:decode-payload payload)
      (is string= "/app/main.js" (cdr (assoc "entry" m :test #'string=)))
      (is eql 2 (length mods))
      (is string= "console.log(1);" (cdr (assoc "/app/main.js" mods :test #'string=)))
      (is eql 1 (length ass))
      (is equalp #(1 2 3 4) (cdr (assoc "icon.bin" ass :test #'string=))))))

(define-test sfe/sign-verify-ed25519
  (multiple-value-bind (priv pub algo) (clun.sfe:generate-signing-key :ed25519)
    (declare (ignore algo))
    (let* ((payload (sb-ext:string-to-octets "payload-bytes" :external-format :utf-8)))
      (multiple-value-bind (sig code) (clun.sfe:sign-payload payload priv :algo :ed25519)
        (is = clun.sfe::+sig-algo-ed25519+ code)
        (true (clun.sfe:verify-payload payload sig pub :algo :ed25519))
        (false (clun.sfe:verify-payload
                (sb-ext:string-to-octets "tampered" :external-format :utf-8)
                sig pub :algo :ed25519))))))

(define-test sfe/sign-verify-hmac
  (multiple-value-bind (key _ algo) (clun.sfe:generate-signing-key :hmac-sha256)
    (declare (ignore _ algo))
    (let ((payload (sb-ext:string-to-octets "hmac-payload" :external-format :utf-8)))
      (multiple-value-bind (sig code)
          (clun.sfe:sign-payload payload key :algo :hmac-sha256)
        (is = clun.sfe::+sig-algo-hmac-sha256+ code)
        (true (clun.sfe:verify-payload payload sig key :algo :hmac-sha256))))))

(define-test sfe/module-graph-and-compile
  (let ((host (%sfe-host-template)))
    (true host)
    (when host
      (let* ((dir (%sfe-temp-dir))
             (entry (%sfe-write dir "hello.js"
                                (format nil "console.log(~S);~%" "sfe-hello")))
             (asset (%sfe-write dir "note.txt" "embedded-note"))
             (outfile (clun.sys:path-join dir "hello-bin")))
        (unwind-protect
             (progn
               (multiple-value-bind (mods resolved)
                   (clun.sfe:collect-module-graph entry :cwd dir)
                 (true (plusp (length mods)))
                 (true (stringp resolved)))
               (let ((res (clun.sfe:compile-executable
                           entry
                           :outfile outfile
                           :target (clun.sfe:host-target)
                           :template host
                           :assets (list asset)
                           :defines '(("BUILD_TAG" . "\"fixture\""))
                           :cwd dir)))
                 (true (getf res :outfile))
                 (true (clun.sys:file-p (getf res :outfile)))
                 (is string= "image" (getf res :packaging))
                 (is eql 1 (getf res :modules))
                 (is eql 1 (getf res :assets))
                 (true (stringp (getf res :build-id)))
                 (true (search "GPL" clun.sfe:+gpl-source-notice+))
                 (let* ((out (make-string-output-stream))
                        (proc (sb-ext:run-program (getf res :outfile)
                                                  '("--sfe-info")
                                                  :wait t :output out :error nil))
                        (text (get-output-stream-string out)))
                   (is eql 0 (sb-ext:process-exit-code proc))
                   (true (search "format=CLUNSEA" text))
                   (true (search "packaging=image" text)))
                 (let ((v (clun.sfe:verify-path (getf res :outfile))))
                   (true (getf v :ok)))
                 (multiple-value-bind (priv pub)
                     (clun.sfe:generate-signing-key :ed25519)
                   (let* ((signed-out (clun.sys:path-join dir "hello-signed"))
                          (sres (clun.sfe:compile-executable
                                 entry
                                 :outfile signed-out
                                 :template host
                                 :sign t
                                 :private-key priv
                                 :public-key pub
                                 :cwd dir)))
                     (true (getf sres :signed))
                     (let ((v (clun.sfe:verify-path signed-out)))
                       (true (getf v :ok))))
                   (let* ((port (clun.sys:path-join dir "hello.clunsea"))
                          (pres (clun.sfe:compile-executable
                                 entry :outfile port :portable t
                                 :cwd dir)))
                     (true (clun.sfe:sea-file-p (getf pres :outfile)))
                     (let ((sea (clun.sfe:open-sea (getf pres :outfile))))
                       (is string= "CLUNSEA"
                           (cdr (assoc "format" (getf sea :manifest)
                                       :test #'string=))))))))
          (ignore-errors (clun.sys:remove-recursive dir)))))))

(define-test sfe/template-registry
  (clun.sfe:clear-templates)
  (let ((host (%sfe-host-template)))
    (when host
      (clun.sfe:register-template "linux-x64" host)
      (let ((pairs (clun.sfe:list-templates)))
        (true (assoc "clun-linux-x64" pairs :test #'string=)))
      (clun.sfe:clear-templates)
      (is eql 0 (length (clun.sfe:list-templates))))))
