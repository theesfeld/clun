;;;; workspace-tests.lisp — Phase 60 monorepo workspaces: discovery, filters, catalogs,
;;;; workspace: protocol linking, topological concurrent script runs. Pure CL hermetic suite.

(in-package :clun-test)

(defun %write-file (path text)
  (let ((parent (clun.sys:path-dirname path)))
    (unless (clun.sys:path-exists-p parent)
      (clun.sys:make-directory parent :recursive t :mode #o755)))
  (clun.sys:write-file-octets
   path
   (sb-ext:string-to-octets text :external-format :utf-8)))

(defun %mk-monorepo ()
  "Create a temp monorepo:
  root workspaces packages/*
  packages/pkg-a depends on pkg-b via workspace:*
  packages/pkg-b leaf
  packages/pkg-c excluded by some filters
  catalog: react in root"
  (let ((root (clun.sys:make-temp-dir "/tmp/clun-ws-")))
    (%write-file
     (clun.sys:path-join root "package.json")
     (format nil "~
{\"name\":\"mono\",\"version\":\"1.0.0\",~
\"workspaces\":{\"packages\":[\"packages/*\"],~
\"catalog\":{\"left-pad\":\"^1.0.0\"},~
\"catalogs\":{\"testing\":{\"shared\":\"2.0.0\"}}},~
\"scripts\":{\"hello\":\"echo root-hello\"}}~%"))
    (%write-file
     (clun.sys:path-join root "packages" "pkg-a" "package.json")
     (format nil "~
{\"name\":\"pkg-a\",\"version\":\"1.0.0\",~
\"dependencies\":{\"pkg-b\":\"workspace:*\",\"left-pad\":\"catalog:\"},~
\"scripts\":{\"build\":\"echo build-a\",\"hello\":\"echo hello-a\"}}~%"))
    (%write-file
     (clun.sys:path-join root "packages" "pkg-a" "index.js")
     "module.exports = 'pkg-a';\n")
    (%write-file
     (clun.sys:path-join root "packages" "pkg-b" "package.json")
     (format nil "~
{\"name\":\"pkg-b\",\"version\":\"2.0.0\",~
\"scripts\":{\"build\":\"echo build-b\",\"hello\":\"echo hello-b\"}}~%"))
    (%write-file
     (clun.sys:path-join root "packages" "pkg-b" "index.js")
     "module.exports = 'pkg-b';\n")
    (%write-file
     (clun.sys:path-join root "packages" "pkg-c" "package.json")
     (format nil "~
{\"name\":\"pkg-c\",\"version\":\"3.0.0\",~
\"dependencies\":{\"shared\":\"catalog:testing\"},~
\"scripts\":{\"hello\":\"echo hello-c\"}}~%"))
    root))

(define-test workspace/discover-globs
  (let ((root (%mk-monorepo)))
    (unwind-protect
         (let* ((g (inst:discover-workspaces root))
                (names (mapcar #'inst:ws-name (inst:workspace-packages g :include-root nil))))
           (true (inst:workspace-graph-p g))
           (is equal "mono" (inst:ws-name (first (inst:wg-packages g))))
           (true (member "pkg-a" names :test #'string=) "pkg-a discovered")
           (true (member "pkg-b" names :test #'string=) "pkg-b discovered")
           (true (member "pkg-c" names :test #'string=) "pkg-c discovered")
           (is = 4 (length (inst:wg-packages g)) "root + 3 packages")
           (true (inst:ws-name (gethash "pkg-a" (inst:wg-by-name g)))))
      (ignore-errors (clun.sys:remove-recursive root)))))

(define-test workspace/filter-name-and-path
  (let ((root (%mk-monorepo)))
    (unwind-protect
         (let* ((g (inst:discover-workspaces root))
                (by-name (inst:filter-workspaces g '("pkg-*") :include-root nil))
                (excl (inst:filter-workspaces g '("pkg-*" "!pkg-c") :include-root nil))
                (by-path (inst:filter-workspaces g '("./packages/pkg-a") :include-root nil))
                (root-only (inst:filter-workspaces g '("./") :include-root t)))
           (is = 3 (length by-name) "pkg-* matches three")
           (is = 2 (length excl) "negation drops pkg-c")
           (false (find "pkg-c" excl :key #'inst:ws-name :test #'string=))
           (is = 1 (length by-path))
           (is equal "pkg-a" (inst:ws-name (first by-path)))
           (is = 1 (length root-only))
           (is equal "" (inst:ws-relative (first root-only))))
      (ignore-errors (clun.sys:remove-recursive root)))))

(define-test workspace/catalog-and-workspace-expand
  (let ((root (%mk-monorepo)))
    (unwind-protect
         (let* ((g (inst:discover-workspaces root))
                (ws-range (inst:expand-dep-spec "pkg-b" "workspace:*" g))
                (cat-range (inst:expand-dep-spec "left-pad" "catalog:" g))
                (named (inst:expand-dep-spec "shared" "catalog:testing" g)))
           (true (inst:workspace-spec-p ws-range) "workspace:* expands to workspace:path")
           (true (search "pkg-b" ws-range) "expanded path names pkg-b")
           (is equal "^1.0.0" cat-range "default catalog")
           (is equal "2.0.0" named "named catalog testing"))
      (ignore-errors (clun.sys:remove-recursive root)))))

(define-test workspace/topo-waves-dependency-order
  (let ((root (%mk-monorepo)))
    (unwind-protect
         (let* ((g (inst:discover-workspaces root))
                (pkgs (inst:filter-workspaces g '("pkg-a" "pkg-b") :include-root nil))
                (waves (inst:workspace-topo-waves pkgs g))
                (flat (apply #'append waves))
                (names (mapcar #'inst:ws-name flat)))
           ;; pkg-b has no workspace deps; pkg-a depends on pkg-b → b before a
           (true (< (position "pkg-b" names :test #'string=)
                    (position "pkg-a" names :test #'string=))
                 "pkg-b builds before pkg-a"))
      (ignore-errors (clun.sys:remove-recursive root)))))

(defun %ws-install (dir &key filters)
  "Hermetic monorepo install against the fixture registry. Returns (values result err).
   Uses a worker pool so HTTPS catalog fetches (left-pad) can complete on Darwin."
  (let ((loop (lp:make-event-loop :workers 2)) (result nil) (err nil))
    (unwind-protect
         (multiple-value-bind (listener reg base) (start-fixture-registry loop)
           (declare (ignore reg))
           (unwind-protect
                (progn
                  (handler-case
                      (inst:install-async loop dir :registry base :filters filters
                        :on-ok  (lambda (r) (setf result r) (lp:loop-stop loop))
                        :on-err (lambda (e) (setf err e) (lp:loop-stop loop)))
                    (error (e) (setf err e)))
                  (unless (or result err) (lp:run-loop loop))
                  ;; One cooperative tick so symlink finalization is visible to path-exists.
                  (when (and result (not err))
                    (lp:drain-microtasks loop)))
             (net:listener-close listener)))
      (lp:destroy-event-loop loop))
    (values result err)))

(define-test workspace/install-links-workspace-packages
  "Install monorepo: workspace packages become live symlinks under node_modules;
  catalog: expands for left-pad from the fixture registry."
  (with-temp-cache (cache)
    (let ((root (%mk-monorepo)))
      (unwind-protect
           (progn
             ;; Ensure root depends on pkg-a via workspace: so the full graph installs.
             (let* ((pkg (inst:read-package-json root))
                    (deps (list (cons "pkg-a" "workspace:*"))))
               (inst::%write-package-json-file
                root
                (inst::%set-pkg-field pkg "dependencies" deps)))
             (multiple-value-bind (res err) (%ws-install root)
               (false err (format nil "install error: ~a" err))
               (true res)
               (true (clun.sys:path-exists-p
                      (clun.sys:path-join root "node_modules" "pkg-a")))
               (true (clun.sys:path-exists-p
                      (clun.sys:path-join root "node_modules" "pkg-b")))
               (let* ((pa (clun.sys:path-join root "node_modules" "pkg-a"))
                      (st (clun.sys:stat* pa :lstat t)))
                 (true (clun.sys:fstat-symlink-p st) "pkg-a is a live workspace symlink"))
               (true (clun.sys:path-exists-p
                      (clun.sys:path-join root "node_modules" "left-pad"))
                     "catalog: left-pad installed from registry")))
        (ignore-errors (clun.sys:remove-recursive root))))))

(define-test workspace/filtered-install
  (with-temp-cache (cache)
    (let ((root (%mk-monorepo)))
      (unwind-protect
           (multiple-value-bind (res err) (%ws-install root :filters '("pkg-b"))
             (false err (format nil "filtered install error: ~a" err))
             (true res)
             (true (clun.sys:path-exists-p
                    (clun.sys:path-join root "node_modules" "pkg-b"))
                   "filtered install links pkg-b"))
        (ignore-errors (clun.sys:remove-recursive root))))))

(define-test workspace/concurrent-script-run
  (let ((root (%mk-monorepo)))
    (unwind-protect
         (let* ((g (inst:discover-workspaces root))
                (pkgs (inst:filter-workspaces g '("pkg-*") :include-root nil))
                (code (inst:run-workspace-scripts g pkgs "hello"
                                                  :parallel t :concurrency 3
                                                  :exit-on-error t)))
           (is = 0 code "all hello scripts exit 0"))
      (ignore-errors (clun.sys:remove-recursive root)))))

(define-test workspace/classify-workspace-catalog-specs
  (let ((c (inst:classify-dep-spec "workspace:/tmp/pkg"))
        (cat (inst:classify-dep-spec "catalog:"))
        (catn (inst:classify-dep-spec "catalog:testing")))
    (is eq :workspace (first c))
    (is equal "/tmp/pkg" (second c))
    (is eq :catalog (first cat))
    (is eq :catalog (first catn))
    (is equal "testing" (second catn))))
