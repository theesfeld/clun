;;;; resolve.lisp — the Node module resolution algorithm (CommonJS + ESM merged),
;;;; pure over clun.sys (engine-free, §3.6). Entry point: RESOLVE. Returns
;;;; (values absolute-path format), format in {:esm :cjs :json}. Mirrors Node's
;;;; ESM_RESOLVE / CJS LOAD_* with `exports`/`imports` conditions + subpath
;;;; patterns + scoped packages + self-reference + symlink realpath.

(in-package :clun.resolver)

(defparameter *default-conditions* '("node" "import")
  "Default `exports`/`imports` conditions for an ESM importer. The engine passes
'(\"node\" \"require\") for a CJS require(). \"default\" always matches implicitly.")

(defparameter *extensions* '(".js" ".json" ".mjs" ".cjs" ".ts" ".tsx" ".jsx")
  "Extension-probing order for a file specifier (Bun-leniency: probes even for ESM
imports, and includes TS extensions the Phase-09 transpiler will load). The exact
path is tried before any of these.")

(defparameter *index-bases* '("index")
  "Directory-index basenames, tried with each of *extensions*.")

;;; --- format detection -------------------------------------------------------

(defun detect-format (path)
  "The module format of the resolved file PATH."
  (let ((ext (sys:path-extension path)))
    (cond ((string= ext ".mjs") :esm)
          ((string= ext ".cjs") :cjs)
          ((string= ext ".json") :json)
          ((member ext '(".js" ".jsx" ".ts" ".tsx") :test #'string=)
           (if (eq (package-type (sys:path-dirname path)) :module) :esm :cjs))
          (t ;; extensionless (e.g. a "main" with no suffix): fall back to type.
           (if (eq (package-type (sys:path-dirname path)) :module) :esm :cjs)))))

;;; --- file / directory probing (LOAD_AS_FILE / LOAD_AS_DIRECTORY) ------------

(defun try-file (path)
  "PATH if it names an existing regular file, else NIL."
  (and (sys:file-p path) path))

(defun resolve-as-file (path)
  "Node LOAD_AS_FILE: exact PATH, then PATH+each extension. Returns a file or NIL."
  (or (try-file path)
      (loop for ext in *extensions*
            thereis (try-file (concatenate 'string path ext)))))

(defun resolve-index (dir)
  "Node LOAD_INDEX: DIR/index.<ext> for each extension. Returns a file or NIL."
  (loop for base in *index-bases*
        thereis (loop for ext in *extensions*
                      thereis (try-file (sys:path-join dir (concatenate 'string base ext))))))

(defun resolve-as-directory (dir conditions specifier referrer)
  "Node LOAD_AS_DIRECTORY: package.json main/exports, else index. NIL if none."
  (let ((pj (read-package-json dir)))
    (or
     ;; "exports" takes precedence over "main" (Node ≥12 with exports).
     (let ((exports (and pj (jget* pj "exports"))))
       (when exports
         (package-exports-resolve dir "." exports conditions specifier referrer)))
     ;; "main" (legacy): resolve as file, else as its own index.
     (let ((main (and pj (jstr (jget* pj "main")))))
       (when (and main (plusp (length main)))
         (let ((mp (sys:path-join dir main)))
           (or (resolve-as-file mp)
               (resolve-index mp)))))
     ;; bare index.
     (resolve-index dir))))

(defun resolve-file-or-dir (path conditions specifier referrer)
  "Resolve an absolute PATH that may be a file or a directory."
  (or (resolve-as-file path)
      (and (sys:directory-p path)
           (resolve-as-directory path conditions specifier referrer))))

;;; --- exports / imports target resolution ------------------------------------

(defun sugar-exports-p (exports)
  "True iff EXPORTS is the `.`-shorthand form: a string, an array, or an object
NONE of whose keys start with `.` (a bare conditions object)."
  (or (stringp exports)
      (jarray-p exports)
      (and (jobj-p exports)
           (not (eq exports :empty-object))
           (every (lambda (kv) (not (and (plusp (length (car kv)))
                                         (char= (char (car kv) 0) #\.))))
                  exports))))

(defun subst-star (target star)
  "Replace every `*` in TARGET with STAR (the captured pattern segment)."
  (if (and star (find #\* target))
      (with-output-to-string (s)
        (loop for ch across target
              if (char= ch #\*) do (write-string star s)
              else do (write-char ch s)))
      target))

(defun package-target-resolve (pkg-dir target star conditions specifier referrer
                               &optional is-imports)
  "Resolve a single `exports`/`imports` TARGET (string / array / conditions object
/ null) relative to PKG-DIR. STAR is the captured `*` segment (or NIL). A bare
specifier target is only legal under `imports` (IS-IMPORTS t) — under `exports` it
is Invalid Package Target (Node PACKAGE_TARGET_RESOLVE). Returns an absolute file
path, or NIL for 'no applicable condition' (caller continues)."
  (cond
    ;; null target -> explicitly blocked.
    ((eq target sys:json-null)
     (rerror 'package-path-not-exported specifier referrer
             "target is null (blocked)"))
    ;; string target.
    ((stringp target)
     ;; a `*`-captured segment must not smuggle in a `..`/`.` path segment.
     (when (and star (segments-invalid-p star))
       (rerror 'invalid-package-specifier specifier referrer
               (format nil "pattern match ~s contains an invalid segment" star)))
     (let ((tgt (subst-star target star)))
       (cond
         ;; internal package-relative target ("./x").
         ((and (>= (length tgt) 2) (char= (char tgt 0) #\.) (char= (char tgt 1) #\/))
          (let* ((rel (subseq tgt 2))
                 (abs (sys:normalize-path (sys:path-join pkg-dir rel))))
            ;; must not escape the package root.
            (unless (path-within-p pkg-dir abs)
              (rerror 'invalid-package-target specifier referrer
                      (format nil "target ~s escapes the package" tgt)))
            abs))
         ;; a bare specifier target — legal ONLY inside `imports` (e.g. "#dep"->"pkg").
         ((and is-imports (not (or (char= (char tgt 0) #\.) (char= (char tgt 0) #\/))))
          (resolve-bare tgt pkg-dir conditions specifier referrer))
         (t (rerror 'invalid-package-target specifier referrer
                    (format nil "invalid target ~s (exports targets must start with ./)" tgt))))))
    ;; conditions object: first matching key wins ("default" always matches).
    ((jobj-p target)
     (loop for (key . val) in (if (eq target :empty-object) '() target)
           when (or (string= key "default") (member key conditions :test #'string=))
             do (let ((r (package-target-resolve pkg-dir val star conditions
                                                 specifier referrer is-imports)))
                  (when r (return r)))
           finally (return nil)))
    ;; array: first element that resolves (existing file / valid package). Node
    ;; continues past Invalid Package Target errors within an array (spec).
    ((jarray-p target)
     (loop for elt across target
           do (let ((r (ignore-errors
                        (package-target-resolve pkg-dir elt star conditions
                                                specifier referrer is-imports))))
                (when (and r (or (sys:file-p r) (resolve-as-file r))) (return r)))
           finally (return nil)))
    (t nil)))

(defun exports-match (exports subpath)
  "Match SUBPATH (e.g. \".\" or \"./sub\") against an EXPORTS subpath map. Returns
(values target star) — target is the matched value, star the captured `*` segment
(or NIL for an exact match) — or NIL if no key matches. Longest pattern prefix wins."
  ;; exact key.
  (let ((exact (jget* exports subpath :missing)))
    (unless (eq exact :missing)
      (return-from exports-match (values exact nil))))
  ;; pattern keys ("./*", "./foo/*"): Node PATTERN_KEY_COMPARE picks the key with the
  ;; longest BASE (substring before `*`); ties broken by longest TOTAL key length.
  (let ((best-key nil) (best-base -1) (best-target nil) (best-star nil))
    (loop for (key . val) in (if (eq exports :empty-object) '() exports)
          for star = (position #\* key)
          when (and star
                    (let ((prefix (subseq key 0 star))
                          (suffix (subseq key (1+ star))))
                      (and (<= (+ (length prefix) (length suffix)) (length subpath))
                           (string= prefix (subseq subpath 0 (length prefix)))
                           (or (zerop (length suffix))
                               (string= suffix (subseq subpath (- (length subpath)
                                                                   (length suffix)))))
                           (not (find #\* suffix)))))
            do (when (or (null best-key)
                         (> star best-base)
                         (and (= star best-base) (> (length key) (length best-key))))
                 (setf best-key key
                       best-base star
                       best-target val
                       best-star (subseq subpath star
                                         (- (length subpath)
                                            (- (length key) (1+ star)))))))
    (when best-key (values best-target best-star))))

(defun package-exports-resolve (pkg-dir subpath exports conditions specifier referrer)
  "Resolve SUBPATH (\".\" or \"./x\") through a package's EXPORTS. Returns an
absolute file path, or signals package-path-not-exported."
  (cond
    ((sugar-exports-p exports)
     (if (string= subpath ".")
         (or (package-target-resolve pkg-dir exports nil conditions specifier referrer)
             (rerror 'package-path-not-exported specifier referrer
                     "no matching condition for \".\""))
         (rerror 'package-path-not-exported specifier referrer
                 (format nil "subpath ~s not exported (exports has no subpaths)" subpath))))
    ((jobj-p exports)
     (multiple-value-bind (target star) (exports-match exports subpath)
       (if target
           (or (package-target-resolve pkg-dir target star conditions specifier referrer)
               (rerror 'package-path-not-exported specifier referrer
                       (format nil "no matching condition for ~s" subpath)))
           (rerror 'package-path-not-exported specifier referrer
                   (format nil "subpath ~s not exported" subpath)))))
    (t (rerror 'package-path-not-exported specifier referrer "malformed exports"))))

;;; --- bare specifier + node_modules walk + self-reference --------------------

(defun segments-invalid-p (rest)
  "True iff any `/`-separated segment of REST is `.` or `..` (Node invalidSegmentRegEx
— such a bare-specifier subpath / captured `*` may escape the package sandbox)."
  (loop with start = 0
        for i from 0 to (length rest)
        when (or (= i (length rest)) (char= (char rest i) #\/))
          do (let ((seg (subseq rest start i)))
               (when (or (string= seg ".") (string= seg "..")) (return t))
               (setf start (1+ i)))))

(defun split-package-specifier (specifier)
  "Split a bare SPECIFIER into (values package-name subpath). subpath is \".\" or
\"./rest\". Handles @scope/pkg. Signals invalid-package-specifier on garbage or on a
subpath bearing a `.`/`..` segment (which could escape the package)."
  (when (or (zerop (length specifier)) (char= (char specifier 0) #\.))
    (rerror 'invalid-package-specifier specifier nil "not a bare specifier"))
  (multiple-value-bind (name subpath)
      (if (char= (char specifier 0) #\@)
          ;; @scope/name[/sub...]
          (let ((slash1 (position #\/ specifier)))
            (unless slash1
              (rerror 'invalid-package-specifier specifier nil "scoped name needs a `/`"))
            (let ((slash2 (position #\/ specifier :start (1+ slash1))))
              (if slash2
                  (values (subseq specifier 0 slash2)
                          (concatenate 'string "." (subseq specifier slash2)))
                  (values specifier "."))))
          ;; name[/sub...]
          (let ((slash (position #\/ specifier)))
            (if slash
                (values (subseq specifier 0 slash)
                        (concatenate 'string "." (subseq specifier slash)))
                (values specifier "."))))
    (when (and (not (string= subpath ".")) (segments-invalid-p (subseq subpath 2)))
      (rerror 'invalid-package-specifier specifier nil
              (format nil "subpath of ~s has a `.`/`..` segment" specifier)))
    (values name subpath)))

(defun resolve-in-package (pkg-dir subpath conditions specifier referrer)
  "Resolve SUBPATH inside an already-located package directory PKG-DIR."
  (let* ((pj (read-package-json pkg-dir))
         (exports (and pj (jget* pj "exports"))))
    (cond
      (exports
       (package-exports-resolve pkg-dir subpath exports conditions specifier referrer))
      ((string= subpath ".")
       (or (resolve-as-directory pkg-dir conditions specifier referrer)
           (rerror 'module-not-found specifier referrer
                   (format nil "no main/index in ~s" pkg-dir))))
      (t ;; legacy deep import: PKG_DIR/subpath as file or dir.
       (let ((p (sys:path-join pkg-dir (subseq subpath 2)))) ; drop "./"
         (or (resolve-file-or-dir p conditions specifier referrer)
             (rerror 'module-not-found specifier referrer
                     (format nil "~s not found in ~s" subpath pkg-dir))))))))

(defun self-reference-resolve (specifier referrer-dir conditions)
  "If SPECIFIER's package name matches the nearest package.json `name` (and it has
`exports`), resolve via self-reference. Returns a path or NIL (not a self-ref)."
  (multiple-value-bind (pkg-name subpath) (split-package-specifier specifier)
    (multiple-value-bind (pj pkg-dir) (nearest-package-json referrer-dir)
      (when (and pj pkg-dir
                 (equal (jstr (jget* pj "name")) pkg-name)
                 (jget* pj "exports"))
        (package-exports-resolve pkg-dir subpath (jget* pj "exports")
                                 conditions specifier referrer-dir)))))

(defun resolve-bare (specifier referrer-dir conditions orig-specifier referrer)
  "Resolve a bare SPECIFIER: self-reference, then walk node_modules up from
REFERRER-DIR."
  (or
   (self-reference-resolve specifier referrer-dir conditions)
   (multiple-value-bind (pkg-name subpath) (split-package-specifier specifier)
     (loop for dir = referrer-dir then (sys:path-dirname dir)
           for nm = (sys:path-join dir "node_modules")
           for candidate = (sys:path-join nm pkg-name)
           when (sys:directory-p candidate)
             do (return (resolve-in-package candidate subpath conditions
                                            orig-specifier referrer))
           when (or (string= dir "/") (string= dir ".") (string= dir ""))
             do (return (rerror 'module-not-found (or orig-specifier specifier) referrer
                                (format nil "~s not found in any node_modules" pkg-name)))))))

(defun package-imports-resolve (specifier referrer-dir conditions)
  "Resolve a `#`-prefixed internal SPECIFIER via the nearest package.json `imports`."
  (multiple-value-bind (pj pkg-dir) (nearest-package-json referrer-dir)
    (unless (and pj pkg-dir (jget* pj "imports"))
      (rerror 'package-path-not-exported specifier referrer-dir
              "no `imports` in scope"))
    (let ((imports (jget* pj "imports")))
      (multiple-value-bind (target star) (exports-match imports specifier)
        (if target
            (or (package-target-resolve pkg-dir target star conditions
                                        specifier referrer-dir t) ; t = is-imports
                (rerror 'package-path-not-exported specifier referrer-dir
                        "no matching condition"))
            (rerror 'package-path-not-exported specifier referrer-dir
                    (format nil "~s not defined in imports" specifier)))))))

;;; --- helpers ----------------------------------------------------------------

(defun path-within-p (root path)
  "True iff PATH is ROOT or lexically nested under ROOT (no `..` escape)."
  (let ((r (sys:normalize-path root))
        (p (sys:normalize-path path)))
    (and (<= (length r) (length p))
         (string= r (subseq p 0 (length r)))
         (or (= (length r) (length p))
             (char= (char p (length r)) #\/)
             (and (plusp (length r)) (char= (char r (1- (length r))) #\/))))))

(defun strip-file-url (specifier)
  "Turn a `file:` URL specifier into a plain path; pass others through."
  (cond ((and (>= (length specifier) 7) (string= (subseq specifier 0 7) "file://"))
         (subseq specifier 7))
        ((and (>= (length specifier) 5) (string= (subseq specifier 0 5) "file:"))
         (subseq specifier 5))
        (t specifier)))

;;; --- entry point ------------------------------------------------------------

(defun resolve (specifier referrer-dir &key (conditions *default-conditions*))
  "Resolve SPECIFIER as imported from a module whose directory is REFERRER-DIR.
Returns (values absolute-realpath format). Signals a RESOLUTION-ERROR subtype on
failure. CONDITIONS drives `exports`/`imports` matching."
  (let* ((*pjson-cache* (make-hash-table :test 'equal))
         (spec (strip-file-url specifier))
         (resolved
           (cond
             ;; internal imports (#foo)
             ((and (plusp (length spec)) (char= (char spec 0) #\#))
              (package-imports-resolve spec referrer-dir conditions))
             ;; absolute path
             ((sys:absolute-path-p spec)
              (or (resolve-file-or-dir (sys:normalize-path spec) conditions spec referrer-dir)
                  (rerror 'module-not-found spec referrer-dir "absolute path not found")))
             ;; relative path
             ((and (>= (length spec) 2)
                   (char= (char spec 0) #\.)
                   (or (char= (char spec 1) #\/)
                       (and (>= (length spec) 3) (char= (char spec 1) #\.)
                            (char= (char spec 2) #\/))))
              (let ((abs (sys:normalize-path (sys:path-join referrer-dir spec))))
                (or (resolve-file-or-dir abs conditions spec referrer-dir)
                    (rerror 'module-not-found spec referrer-dir "relative path not found"))))
             ;; bare specifier (package)
             (t (resolve-bare spec referrer-dir conditions spec referrer-dir)))))
    ;; symlink realpath so the loader's registry dedups by real identity (§3.2).
    (let ((real (or (sys:realpath resolved) resolved)))
      (unless (sys:file-p real)
        (rerror 'module-not-found specifier referrer-dir
                (format nil "resolved to ~s which is not a file" real)))
      (values real (detect-format real)))))
