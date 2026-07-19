;;;; targets.lisp — compile target triples + template registry (Issue #181).

(in-package :clun.sfe)

(defparameter *supported-targets*
  '("clun-linux-x64" "clun-linux-arm64"
    "clun-darwin-x64" "clun-darwin-arm64"
    "bun-linux-x64" "bun-linux-arm64"
    "bun-darwin-x64" "bun-darwin-arm64"
    "linux-x64" "linux-arm64" "darwin-x64" "darwin-arm64")
  "Accepted --target spellings (Bun-compatible prefixes normalized to clun-*).")

(defparameter *template-registry* (make-hash-table :test 'equal)
  "Map normalized target → absolute host-runtime template path.")

(defun host-target ()
  "Normalized target triple for the running host."
  (format nil "clun-~A-~A" (sys:platform-name) (sys:machine-arch)))

(defun normalize-target (target)
  "Normalize TARGET string to clun-<os>-<arch>. Accepts bun-*, bare os-arch."
  (unless (stringp target)
    (%fail :invalid-target "target must be a string"))
  (let* ((raw (string-downcase (string-trim '(#\Space #\Tab) target)))
         (raw (cond
                ((zerop (length raw)) (host-target))
                ((and (>= (length raw) 5) (string= raw "bun-" :end1 4))
                 (concatenate 'string "clun-" (subseq raw 4)))
                ((and (>= (length raw) 6) (string= raw "clun-" :end1 5))
                 raw)
                ((find #\- raw) (concatenate 'string "clun-" raw))
                (t (%fail :invalid-target raw))))
         ;; drop optional -baseline / -modern / -musl suffixes for template key
         (parts (loop for start = 0 then (1+ pos)
                      for pos = (position #\- raw :start start)
                      collect (subseq raw start (or pos (length raw)))
                      while pos))
         (os (second parts))
         (arch (third parts)))
    (unless (and os arch
                 (member os '("linux" "darwin") :test #'string=)
                 (member arch '("x64" "arm64") :test #'string=))
      (%fail :invalid-target
             (format nil "unsupported target ~S (need linux|darwin × x64|arm64)" target)))
    (format nil "clun-~A-~A" os arch)))

(defun register-template (target path)
  "Register PATH as the offline runtime template for TARGET."
  (let ((norm (normalize-target target))
        (abs (or (sys:realpath path) path)))
    (unless (sys:file-p abs)
      (%fail :template-missing abs))
    (setf (gethash norm *template-registry*) abs)
    norm))

(defun clear-templates ()
  (clrhash *template-registry*)
  t)

(defun list-templates ()
  (loop for k being the hash-keys of *template-registry*
        using (hash-value v)
        collect (cons k v)))

(defun %template-env-key (norm-target)
  "CLUN_SFE_TEMPLATE_CLUN_LINUX_X64 style env key."
  (concatenate 'string "CLUN_SFE_TEMPLATE_"
               (substitute #\_ #\- (string-upcase norm-target))))

(defun %default-template-search-paths (norm-target)
  (let* ((exec (self-executable-path))
         (exec-dir (and exec (sys:path-dirname exec)))
         (cwd (sys:current-directory)))
    (remove nil
            (list
             (sys:getenv (%template-env-key norm-target))
             (sys:getenv "CLUN_SFE_TEMPLATE")
             (when exec-dir
               (sys:path-join exec-dir "sfe-templates" norm-target "clun"))
             (when exec-dir
               (sys:path-join exec-dir "share" "sfe-templates" norm-target "clun"))
             (sys:path-join cwd "sfe-templates" norm-target "clun")
             (sys:path-join cwd "share" "sfe-templates" norm-target "clun")))))

(defun resolve-template (target &key template host-path)
  "Resolve a host-runtime template path for TARGET.
   Prefer explicit TEMPLATE, then registry, env, search paths, then HOST-PATH
   when TARGET matches the running host."
  (let ((norm (normalize-target (or target (host-target)))))
    (cond
      ((and template (plusp (length template)))
       (let ((abs (or (sys:realpath template) template)))
         (unless (sys:file-p abs)
           (%fail :template-missing abs))
         (values abs norm)))
      ((gethash norm *template-registry*)
       (values (gethash norm *template-registry*) norm))
      (t
       (let ((found (loop for p in (%default-template-search-paths norm)
                          when (and p (sys:file-p p)) return (or (sys:realpath p) p))))
         (cond
           (found (values found norm))
           ((string= norm (host-target))
            (let ((self (or host-path (self-executable-path))))
              (unless (and self (sys:file-p self))
                (%fail :template-missing
                       "cannot locate host Clun runtime for native compile"))
              (values self norm)))
           (t
            (%fail :template-missing
                   (format nil "no offline template for ~A (register with Clun.compile.registerTemplate or CLUN_SFE_TEMPLATE_*)"
                           norm)))))))))

(defun self-executable-path ()
  "Absolute path of the running Clun executable when resolvable."
  (let ((a0 (or (first sb-ext:*posix-argv*) "clun")))
    (or (ignore-errors
          (sys:pathname->native (truename (sys:native->pathname a0))))
        (let ((which (sys:getenv "CLUN_COMPAT_EXECUTABLE")))
          (when (and which (sys:file-p which)) which))
        a0)))

(defun all-four-targets ()
  '("clun-linux-x64" "clun-linux-arm64" "clun-darwin-x64" "clun-darwin-arm64"))
