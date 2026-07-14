;;;; cli-tests.lisp — Phase 23 milestone 2 (closes the phase gate): the install CLI surface.
;;;; package.json editing for add/remove (hermetic, no registry), latest-version resolution against
;;;; the fixture, and THE gate headline — install a fixture graph, then run an app that require()s
;;;; the installed packages and assert its exact stdout (install → node_modules → require → run).
;;;; Reuses install-tests.lisp helpers (%fresh-install, %write-package-json, with-temp-cache, %nm).

(in-package :clun-test)

(define-test cli/add-remove-edits-package-json
  ;; add (explicit ranges — no registry) merges into dependencies / devDependencies; remove prunes.
  (let ((proj (clun.sys:make-temp-dir "/tmp/clun-cli-")))
    (unwind-protect
         (progn
           (%write-package-json proj "{\"left-pad\":\"^1.0.0\"}")
           (inst:add-dependencies proj '("conflict-a@1.0.0" "conflict-b@1.0.0"))
           (let ((deps (clun.sys:jget (inst:read-package-json proj) "dependencies")))
             (is equal "^1.0.0" (cdr (assoc "left-pad" deps :test #'string=)) "existing dep kept")
             (is equal "1.0.0" (cdr (assoc "conflict-a" deps :test #'string=)) "conflict-a added")
             (is equal "1.0.0" (cdr (assoc "conflict-b" deps :test #'string=)) "conflict-b added"))
           ;; dev dependency
           (inst:add-dependencies proj '("shared@2.0.0") :dev t)
           (is equal "2.0.0" (cdr (assoc "shared" (clun.sys:jget (inst:read-package-json proj)
                                                                 "devDependencies") :test #'string=))
               "dev dep in devDependencies")
           ;; remove from both fields
           (inst:remove-dependencies proj '("conflict-a" "shared"))
           (let* ((pkg (inst:read-package-json proj))
                  (deps (clun.sys:jget pkg "dependencies"))
                  (dev (clun.sys:jget pkg "devDependencies")))
             (false (assoc "conflict-a" deps :test #'string=) "conflict-a removed")
             (true (assoc "conflict-b" deps :test #'string=) "conflict-b kept")
             (true (or (eq dev :empty-object) (null (assoc "shared" dev :test #'string=))) "shared removed")))
      (ignore-errors (clun.sys:remove-recursive proj)))))

(define-test cli/resolve-latest-against-fixture
  ;; `clun add <bare-name>` resolves the registry's `latest` dist-tag (fixture left-pad latest = 1.3.0)
  (let ((loop (lp:make-event-loop :workers 0)) (ver nil) (err nil))
    (unwind-protect
         (multiple-value-bind (listener reg base) (start-fixture-registry loop)
           (declare (ignore reg))
           (unwind-protect
                (progn
                  (inst:resolve-latest-async loop "left-pad" :registry base
                    :on-ok  (lambda (v) (setf ver v) (lp:loop-stop loop))
                    :on-err (lambda (e) (setf err e) (lp:loop-stop loop)))
                  (unless (or ver err) (lp:run-loop loop)))
             (net:listener-close listener)))
      (lp:destroy-event-loop loop))
    (false err)
    (is equal "1.3.0" ver "left-pad latest → 1.3.0")))

(defun %run-app (proj app-rel)
  "Run PROJ/APP-REL in a fresh runtime realm (cwd = PROJ), capturing stdout. Install must have run;
require() resolves through PROJ/node_modules."
  (let ((realm (eng:make-realm)) (out (make-string-output-stream)))
    (rt:install-runtime realm :argv (list :script (clun.sys:path-join proj app-rel) :rest nil)
                              :cwd proj :colors nil)
    (let ((*standard-output* out))
      (eng:run-module-file (clun.sys:path-join proj app-rel) :realm realm))
    (get-output-stream-string out)))

(define-test cli/install-then-run-app
  ;; THE Phase-23 gate headline: install a fixture graph, then run an app that require()s the
  ;; installed packages and assert exact stdout (each fixture package's index.js exports "name@ver").
  (with-temp-cache (cache)
    (let ((proj (clun.sys:make-temp-dir "/tmp/clun-app-")))
      (unwind-protect
           (progn
             (%write-package-json proj "{\"left-pad\":\"^1.0.0\",\"@scope/widget\":\"^1.0.0\"}")
             (multiple-value-bind (r e) (%fresh-install proj) (declare (ignore r)) (false e))
             ;; left-pad@1.3.0 (hoisted) + @scope/widget@1.0.0 both installed
             (true (%has-pkg proj "left-pad"))
             (true (%has-pkg proj "@scope" "widget"))
             (clun.sys:write-file-octets
              (clun.sys:path-join proj "app.cjs")
              (map '(simple-array (unsigned-byte 8) (*)) #'char-code
                   "console.log(require('left-pad'));console.log(require('@scope/widget'));"))
             (let ((out (%run-app proj "app.cjs")))
               (is equal (format nil "left-pad@1.3.0~%@scope/widget@1.0.0~%") out
                   "the app require()s the installed packages and prints their exports")))
        (ignore-errors (clun.sys:remove-recursive proj))))))
