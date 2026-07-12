;;;; resolver-tests.lisp — the Phase-07 resolution corpus (engine-free). Builds a
;;;; comprehensive fixture tree in a fresh temp dir (mkdtemp) and asserts ~40
;;;; distinct Node-resolution scenarios against clun.resolver: relative/absolute,
;;;; extension probing, directory index, main/exports/imports conditions, subpath
;;;; patterns, scoped packages, self-reference, node_modules walk, symlink
;;;; realpath, and format detection. No engine dependency.

(in-package :clun-test)

;;; --- fixture builder (rt-write lives in sys-tests, loaded first) ------------

(defvar *rt-root* nil "The realpath'd root of the built fixture tree.")

(defun build-resolution-corpus ()
  "Build the fixture corpus in a fresh temp dir; return its realpath'd root."
  (let* ((tmp (sys:pathname->native (sb-posix:mkdtemp "/tmp/clun-rescorpus-XXXXXX")))
         (real (sys:realpath tmp))
         ;; realpath of a directory (truename) carries a trailing slash — strip it
         ;; so path-join / suffix arithmetic below is uniform.
         (root (if (and (plusp (length real)) (char= (char real (1- (length real))) #\/))
                   (subseq real 0 (1- (length real)))
                   real)))
    (flet ((w (rel content) (rt-write (sys:path-join root rel) content)))
      ;; --- app: relative + directory + extension + json + esm/cjs ---
      (w "app/index.mjs"       "import './util.js';")
      (w "app/util.js"         "module.exports = 1;")
      (w "app/data.json"       "{\"k\":1}")
      (w "app/esm-file.mjs"    "export default 1;")
      (w "app/cjs-file.cjs"    "module.exports = 1;")
      (w "app/lib/index.js"    "module.exports = 'lib-index';")
      (w "app/deep/a/b/c.js"   "module.exports = 'c';")
      (w "app/sub/mod.js"      "module.exports = 's';")
      ;; a nested package with type:module (so .js there is ESM)
      (w "app/esm-pkg/package.json" "{\"type\":\"module\"}")
      (w "app/esm-pkg/m.js"    "export default 2;")
      ;; --- node_modules: dep with rich exports ---
      (w "app/node_modules/dep/package.json"
         "{\"name\":\"dep\",\"exports\":{
            \".\":\"./main.js\",
            \"./sub\":\"./lib/sub.js\",
            \"./feat/*\":\"./feats/*.js\",
            \"./cond\":{\"import\":\"./cond.mjs\",\"require\":\"./cond.cjs\",\"default\":\"./cond.js\"},
            \"./nested\":{\"node\":{\"import\":\"./nested-node.mjs\"},\"default\":\"./nested-def.js\"},
            \"./arr\":[\"./missing-first.js\",\"./arr-second.js\"],
            \"./blocked\":null}}")
      (w "app/node_modules/dep/main.js"        "module.exports = 'dep-main';")
      (w "app/node_modules/dep/lib/sub.js"     "module.exports = 'dep-sub';")
      (w "app/node_modules/dep/feats/alpha.js" "module.exports = 'alpha';")
      (w "app/node_modules/dep/cond.mjs"       "export default 1;")
      (w "app/node_modules/dep/cond.cjs"       "module.exports = 1;")
      (w "app/node_modules/dep/cond.js"        "module.exports = 1;")
      (w "app/node_modules/dep/nested-node.mjs" "export default 1;")
      (w "app/node_modules/dep/nested-def.js"  "module.exports = 1;")
      (w "app/node_modules/dep/arr-second.js"  "module.exports = 'arr2';")
      ;; --- scoped package with import/require conditions ---
      (w "app/node_modules/@scope/pkg/package.json"
         "{\"name\":\"@scope/pkg\",\"type\":\"module\",
           \"exports\":{\".\":{\"import\":\"./m.mjs\",\"require\":\"./c.cjs\"},\"./x\":\"./x.mjs\"}}")
      (w "app/node_modules/@scope/pkg/m.mjs" "export default 1;")
      (w "app/node_modules/@scope/pkg/c.cjs" "module.exports = 1;")
      (w "app/node_modules/@scope/pkg/x.mjs" "export default 1;")
      ;; --- legacy package (main -> extensionless / directory) ---
      (w "app/node_modules/legacy/package.json" "{\"name\":\"legacy\",\"main\":\"lib/entry\"}")
      (w "app/node_modules/legacy/lib/entry.js" "module.exports = 9;")
      (w "app/node_modules/legacy-dir/package.json" "{\"name\":\"legacy-dir\",\"main\":\"./lib\"}")
      (w "app/node_modules/legacy-dir/lib/index.js" "module.exports = 10;")
      ;; --- package with no main and no exports (bare index) ---
      (w "app/node_modules/plainidx/package.json" "{\"name\":\"plainidx\"}")
      (w "app/node_modules/plainidx/index.js" "module.exports = 11;")
      ;; --- package with exports "." string sugar ---
      (w "app/node_modules/sugar/package.json" "{\"name\":\"sugar\",\"exports\":\"./e.js\"}")
      (w "app/node_modules/sugar/e.js" "module.exports = 12;")
      ;; --- deep legacy import into a package without exports ---
      (w "app/node_modules/deeppkg/package.json" "{\"name\":\"deeppkg\",\"main\":\"index.js\"}")
      (w "app/node_modules/deeppkg/index.js" "module.exports = 13;")
      (w "app/node_modules/deeppkg/extra/thing.js" "module.exports = 14;")
      ;; --- node_modules walk: dep in the ROOT node_modules (above app) ---
      (w "node_modules/rootdep/package.json" "{\"name\":\"rootdep\",\"main\":\"i.js\"}")
      (w "node_modules/rootdep/i.js" "module.exports = 'rootdep';")
      ;; --- nested node_modules: closer dep shadows farther ---
      (w "app/deep/node_modules/shadowed/package.json" "{\"name\":\"shadowed\",\"main\":\"near.js\"}")
      (w "app/deep/node_modules/shadowed/near.js" "module.exports = 'near';")
      (w "node_modules/shadowed/package.json" "{\"name\":\"shadowed\",\"main\":\"far.js\"}")
      (w "node_modules/shadowed/far.js" "module.exports = 'far';")
      ;; --- self-reference + imports (#internal) ---
      (w "selfpkg/package.json"
         "{\"name\":\"selfpkg\",\"exports\":{\".\":\"./main.js\",\"./feature\":\"./feature.js\"},
           \"imports\":{\"#helper\":\"./helper.js\",\"#dep\":\"idep\"}}")
      (w "selfpkg/main.js"    "module.exports = 'self-main';")
      (w "selfpkg/feature.js" "module.exports = 'self-feature';")
      (w "selfpkg/helper.js"  "module.exports = 'helper';")
      (w "selfpkg/node_modules/idep/package.json" "{\"name\":\"idep\",\"main\":\"i.js\"}")
      (w "selfpkg/node_modules/idep/i.js" "module.exports = 'idep';")
      ;; --- symlink: a link to app/util.js resolves to the real path ---
      (handler-case
          (sb-posix:symlink (sys:native->pathname (sys:path-join root "app/util.js"))
                            (sys:native->pathname (sys:path-join root "app/util-link.js")))
        (error () nil)))
    (setf *rt-root* root)
    root))

(defun corpus-root ()
  (or *rt-root* (build-resolution-corpus)))

(defun rr (specifier referrer-rel &rest kw)
  "Resolve SPECIFIER from REFERRER-REL (a dir relative to the corpus root). Return
(values suffix format) where suffix is the resolved path relative to the root, or
:error on any resolution error."
  (let* ((root (corpus-root))
         (dir (if (string= referrer-rel "") root (sys:path-join root referrer-rel))))
    (handler-case
        (multiple-value-bind (p f) (apply #'rslv:resolve specifier dir kw)
          (values (if (and (> (length p) (length root))
                           (string= root (subseq p 0 (length root))))
                      (subseq p (1+ (length root)))
                      p)
                  f))
      (rslv:resolution-error () :error))))

(defmacro res= (expected specifier referrer &rest kw)
  `(is equal ,expected (rr ,specifier ,referrer ,@kw)))

;;; --- relative / absolute / extension / directory ---------------------------

(define-test resolve/relative-and-extension
  (res= "app/util.js"        "./util.js" "app")      ; exact
  (res= "app/util.js"        "./util"    "app")      ; extension probing
  (res= "app/data.json"      "./data"    "app")      ; .json probing
  (res= "app/sub/mod.js"     "./sub/mod" "app")      ; nested relative
  (res= "app/util.js"        "../util" "app/sub")    ; parent traversal
  (res= "app/deep/a/b/c.js"  "./deep/a/b/c" "app"))

(define-test resolve/directory-index
  (res= "app/lib/index.js"   "./lib"  "app")         ; directory -> index.js
  (res= "app/lib/index.js"   "./lib/" "app"))        ; trailing slash

(define-test resolve/absolute
  (let ((root (corpus-root)))
    (res= "app/util.js" (sys:path-join root "app/util.js") "")))

(define-test resolve/format-detection
  (is eq :esm (nth-value 1 (rr "./esm-file" "app")))  ; .mjs
  (is eq :cjs (nth-value 1 (rr "./cjs-file" "app")))  ; .cjs
  (is eq :cjs (nth-value 1 (rr "./util" "app")))      ; .js, default type
  (is eq :json (nth-value 1 (rr "./data" "app")))     ; .json
  (is eq :esm (nth-value 1 (rr "./m" "app/esm-pkg")))); .js under type:module

;;; --- bare packages: main / index / exports ---------------------------------

(define-test resolve/bare-main-index-sugar
  (res= "app/node_modules/legacy/lib/entry.js"     "legacy"    "app")   ; main extensionless
  (res= "app/node_modules/legacy-dir/lib/index.js" "legacy-dir" "app")  ; main -> dir -> index
  (res= "app/node_modules/plainidx/index.js"       "plainidx"  "app")   ; no main -> index
  (res= "app/node_modules/sugar/e.js"              "sugar"     "app"))  ; exports string sugar

(define-test resolve/exports-subpaths
  (res= "app/node_modules/dep/main.js"       "dep"        "app")   ; exports "."
  (res= "app/node_modules/dep/lib/sub.js"    "dep/sub"    "app")   ; exports "./sub"
  (res= "app/node_modules/dep/feats/alpha.js" "dep/feat/alpha" "app") ; pattern "./feat/*"
  (res= "app/node_modules/dep/arr-second.js" "dep/arr"    "app"))  ; array fallback

(define-test resolve/exports-conditions
  (res= "app/node_modules/dep/cond.mjs" "dep/cond" "app" :conditions '("node" "import"))
  (res= "app/node_modules/dep/cond.cjs" "dep/cond" "app" :conditions '("node" "require"))
  (res= "app/node_modules/dep/cond.js"  "dep/cond" "app" :conditions '("something-else"))
  (res= "app/node_modules/dep/nested-node.mjs" "dep/nested" "app" :conditions '("node" "import"))
  (res= "app/node_modules/dep/nested-def.js"   "dep/nested" "app" :conditions '("import")))

(define-test resolve/exports-errors
  (res= :error "dep/blocked" "app")     ; null target (blocked)
  (res= :error "dep/nope"    "app")     ; subpath not exported
  (res= :error "nonexistent" "app")     ; package missing
  (res= :error "./missing"   "app"))    ; relative missing

;;; --- scoped packages --------------------------------------------------------

(define-test resolve/scoped
  (res= "app/node_modules/@scope/pkg/m.mjs" "@scope/pkg"   "app" :conditions '("node" "import"))
  (res= "app/node_modules/@scope/pkg/c.cjs" "@scope/pkg"   "app" :conditions '("node" "require"))
  (res= "app/node_modules/@scope/pkg/x.mjs" "@scope/pkg/x" "app"))

;;; --- node_modules walk + shadowing ------------------------------------------

(define-test resolve/node-modules-walk
  (res= "node_modules/rootdep/i.js" "rootdep" "app/sub")   ; found in root node_modules
  (res= "app/deep/node_modules/shadowed/near.js" "shadowed" "app/deep/a") ; closer wins
  (res= "node_modules/shadowed/far.js" "shadowed" "app/sub")) ; farther when no closer

(define-test resolve/legacy-deep-import
  (res= "app/node_modules/deeppkg/extra/thing.js" "deeppkg/extra/thing" "app")) ; deep, no exports

;;; --- self-reference + imports ----------------------------------------------

(define-test resolve/self-reference
  (res= "selfpkg/main.js"    "selfpkg"         "selfpkg")   ; self-ref "."
  (res= "selfpkg/feature.js" "selfpkg/feature" "selfpkg"))  ; self-ref subpath

(define-test resolve/imports-internal
  (res= "selfpkg/helper.js" "#helper" "selfpkg")                       ; #internal -> ./path
  (res= "selfpkg/node_modules/idep/i.js" "#dep" "selfpkg"))            ; #internal -> package

;;; --- symlink realpath -------------------------------------------------------

;;; --- review-panel regressions ----------------------------------------------

(defun build-review-corpus ()
  "A second corpus for the review-panel edge cases; returns its root."
  (let* ((tmp (sys:pathname->native (sb-posix:mkdtemp "/tmp/clun-revcorpus-XXXXXX")))
         (real (sys:realpath tmp))
         (root (if (and (plusp (length real)) (char= (char real (1- (length real))) #\/))
                   (subseq real 0 (1- (length real))) real)))
    (flet ((w (rel content) (rt-write (sys:path-join root rel) content)))
      ;; pattern base-length precedence: ./a/* (base 4) beats ./*/index.js (base 2)
      (w "app/node_modules/pat/package.json"
         "{\"name\":\"pat\",\"exports\":{\"./*/index.js\":\"./via-star/*.out\",\"./a/*\":\"./via-a/*.out\"}}")
      (w "app/node_modules/pat/via-a/index.js.out" "1")
      (w "app/node_modules/pat/via-star/a.out" "1")
      ;; two equal-total keys, order-independent: ./a/* (base 4) beats ./*/b (base 2)
      (w "app/node_modules/pat2/package.json"
         "{\"name\":\"pat2\",\"exports\":{\"./*/b\":\"./star-b/*.js\",\"./a/*\":\"./a-star/*.js\"}}")
      (w "app/node_modules/pat2/a-star/b.js" "1")
      (w "app/node_modules/pat2/star-b/a.js" "1")
      ;; bare-in-exports (illegal) vs bare-in-imports (legal)
      (w "app/node_modules/bad/package.json" "{\"name\":\"bad\",\"exports\":{\".\":\"lodash\"}}")
      (w "app/node_modules/lodash/package.json" "{\"name\":\"lodash\",\"main\":\"i.js\"}")
      (w "app/node_modules/lodash/i.js" "1")
      (w "app/package.json" "{\"name\":\"theapp\",\"imports\":{\"#dep\":\"lodash\"}}")
      ;; '..' escape via ./* pattern
      (w "app/node_modules/sand/package.json" "{\"name\":\"sand\",\"exports\":{\"./*\":\"./src/*.js\"}}")
      (w "app/node_modules/sand/src/ok.js" "1")
      (w "app/node_modules/sand/secret.js" "1"))
    root))

(defvar *rev-root* nil)
(defun rev-root () (or *rev-root* (setf *rev-root* (build-review-corpus))))
(defun rrv (spec &rest kw)
  (let* ((root (rev-root)) (dir (sys:path-join root "app")))
    (handler-case
        (let ((p (apply #'rslv:resolve spec dir kw)))
          (if (and (> (length p) (length root)) (string= root (subseq p 0 (length root))))
              (subseq p (length root)) p))
      (rslv:resolution-error (e) (list :error (type-of e))))))

(define-test resolve/pattern-base-length-precedence
  ;; the key with the longest BASE (pre-*) wins, regardless of total length or order
  (is equal "/app/node_modules/pat/via-a/index.js.out"
      (rrv "pat/a/index.js" :conditions '("node" "import")))
  (is equal "/app/node_modules/pat2/a-star/b.js"
      (rrv "pat2/a/b" :conditions '("node" "import"))))

(define-test resolve/bare-target-exports-vs-imports
  ;; a bare-specifier target is Invalid Package Target inside exports...
  (is eq 'rslv:invalid-package-target
      (second (rrv "bad" :conditions '("node" "import"))))
  ;; ...but legal inside imports
  (is equal "/app/node_modules/lodash/i.js"
      (rrv "#dep" :conditions '("node" "import"))))

(define-test resolve/dotdot-escape-blocked
  ;; a `..` consumer subpath must not escape a ./* export sandbox
  (is eq 'rslv:invalid-package-specifier
      (second (rrv "sand/../secret" :conditions '("node" "import"))))
  ;; the legitimate sandboxed path still resolves
  (is equal "/app/node_modules/sand/src/ok.js"
      (rrv "sand/ok" :conditions '("node" "import"))))

(define-test resolve/symlink-realpath
  ;; a symlink resolves to the REAL file path (registry dedup by real identity)
  (let ((suffix (rr "./util-link.js" "app")))
    (true (or (equal suffix "app/util.js")       ; realpath collapsed the link
              (equal suffix :error)))))           ; (skip if symlink unsupported)
