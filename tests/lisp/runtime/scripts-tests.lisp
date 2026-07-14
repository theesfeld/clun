;;;; scripts-tests.lisp — Phase 24 milestone 3: `clun run <script>` (package.json scripts). Scripts
;;;; inherit stdio (child writes to fd 1, bypassing a Lisp stream rebinding), so these assert on
;;;; SIDE-EFFECT FILES the scripts write + on the returned exit code. The full script-vs-file
;;;; dispatch (--if-present, file fallback) is smoked through the binary in examples/e2e.sh.

(in-package :clun-test)

(defun %read-str (path) (and (clun.sys:path-exists-p path) (clun.sys:read-file-string path)))

(define-test scripts/exit-code-propagates
  (let ((dir (clun.sys:make-temp-dir "/tmp/clun-scr-")))
    (unwind-protect
         (progn
           (is = 7 (clun::%run-package-script nil nil dir "fail" nil "exit 7" nil nil) "exit code propagates")
           (is = 0 (clun::%run-package-script nil nil dir "ok" nil "true" nil nil) "success is 0"))
      (clun.sys:remove-recursive dir))))

(define-test scripts/pre-and-post-run-in-order
  (let ((dir (clun.sys:make-temp-dir "/tmp/clun-scr-")))
    (unwind-protect
         (progn
           (is = 0 (clun::%run-package-script nil nil dir "build"
                                              "echo pre >> log.txt" "echo main >> log.txt" "echo post >> log.txt" nil))
           (is equal (format nil "pre~%main~%post~%") (%read-str (clun.sys:path-join dir "log.txt"))
               "prebuild → build → postbuild in order"))
      (clun.sys:remove-recursive dir))))

(define-test scripts/failing-pre-aborts
  (let ((dir (clun.sys:make-temp-dir "/tmp/clun-scr-")))
    (unwind-protect
         (progn
           ;; a failing prebuild aborts: build (which would touch ran.txt) must NOT run
           (is = 1 (clun::%run-package-script nil nil dir "build" "exit 1" "echo x > ran.txt" nil nil))
           (false (clun.sys:path-exists-p (clun.sys:path-join dir "ran.txt")) "build did not run after pre failed"))
      (clun.sys:remove-recursive dir))))

(define-test scripts/npm-env-vars
  (let* ((dir (clun.sys:make-temp-dir "/tmp/clun-scr-"))
         (pj (clun.sys:path-join dir "package.json")))
    (unwind-protect
         (progn
           (clun.sys:write-file-octets pj (map '(simple-array (unsigned-byte 8) (*)) #'char-code
                                               "{\"name\":\"pkgx\",\"version\":\"3.4.5\",\"scripts\":{}}"))
           (let ((pkg (clun.sys:parse-json (clun.sys:read-file-string pj))))
             (is = 0 (clun::%run-package-script
                      pkg pj dir "envtest" nil
                      "printf '%s %s %s %s' \"$npm_lifecycle_event\" \"$npm_package_name\" \"$npm_package_version\" \"$npm_config_user_agent\" > env.txt"
                      nil nil))
             (let ((out (%read-str (clun.sys:path-join dir "env.txt"))))
               (true (search "envtest" out) "npm_lifecycle_event")
               (true (search "pkgx" out) "npm_package_name")
               (true (search "3.4.5" out) "npm_package_version")
               (true (search "clun/" out) "npm_config_user_agent"))))
      (clun.sys:remove-recursive dir))))

(define-test scripts/node-modules-bin-on-path
  ;; a script can invoke a tool from node_modules/.bin without a path (the ancestor .bin PATH walk)
  (let* ((dir (clun.sys:make-temp-dir "/tmp/clun-scr-"))
         (bindir (clun.sys:path-join dir "node_modules" ".bin"))
         (tool (clun.sys:path-join bindir "mytool")))
    (unwind-protect
         (progn
           (clun.sys:make-directory bindir :recursive t :mode #o755)
           (clun.sys:write-file-octets tool (map '(simple-array (unsigned-byte 8) (*)) #'char-code
                                                 (format nil "#!/bin/sh~%echo TOOL-RAN~%")))
           (clun.sys:change-mode tool #o755)
           (is = 0 (clun::%run-package-script nil nil dir "use" nil "mytool > toolout.txt" nil nil))
           (is equal (format nil "TOOL-RAN~%") (%read-str (clun.sys:path-join dir "toolout.txt"))
               "the .bin tool was found on PATH and ran"))
      (clun.sys:remove-recursive dir))))

(define-test scripts/script-path-includes-bin-dirs
  ;; %script-path prepends node_modules/.bin for cwd + ancestors, then the real PATH
  (let ((p (clun::%script-path "/a/b/c")))
    (true (search "/a/b/c/node_modules/.bin:" p) "cwd .bin first")
    (true (search "/a/b/node_modules/.bin:" p) "parent .bin")
    (true (search "/a/node_modules/.bin:" p) "grandparent .bin")
    (true (search "/node_modules/.bin:" p) "root .bin")
    ;; cwd's .bin precedes the parent's
    (true (< (or (search "/a/b/c/node_modules/.bin" p) 999999)
             (or (search "/a/b/node_modules/.bin" p) 0)) "nearest .bin first")))
