;;;; clun-global.lisp — a minimal `Clun` global (PLAN.md §1.2, Phase 08 stub). The
;;;; full 14-member surface (file/write/spawn/serve/…) lands in later phases; here we
;;;; wire the cheap members that depend only on what exists: version/revision/env/
;;;; argv/main/inspect/deepEquals/sleep.

(in-package :clun.runtime)

(defun install-clun-global (realm rt)
  (declare (ignore rt))
  (let* ((eng:*realm* realm)
         (g (eng:realm-global realm))
         (clun (eng:new-object))
         (proc (eng:js-get g "process")))
    (eng:data-prop clun "version" clun::*clun-version*)
    (eng:data-prop clun "revision" clun::*clun-revision*)
    (eng:fixed-data-prop clun "semver" (make-clun-semver))
    (eng:nonconfigurable-data-prop clun "CSRF" (make-clun-csrf g))
    (install-shell clun g)
    (install-clun-glob clun g realm)
    (install-clun-file-system-router clun g realm)
    (eng:nonconfigurable-data-prop clun "password" (make-clun-password g))
    (eng:nonconfigurable-data-prop clun "hash" (make-clun-hash))
    (install-clun-secrets clun g)
    (install-clun-string-width clun)
    (install-clun-color clun)
    (install-clun-yaml clun)
    (install-clun-markdown clun)
    (install-clun-cron clun g)                               ; Clun.cron (Phase 76)
    (install-clun-archive clun g)           ; gzip/deflate/zip + Archive (Phase 74)
    ;; env / argv mirror process (same objects)
    (when (eng:js-object-p proc)
      (eng:data-prop clun "env" (eng:js-get proc "env"))
      (eng:data-prop clun "argv" (eng:js-get proc "argv")))
    (eng:data-prop clun "main" eng:+undefined+)        ; set to the entry path by the CLI
    (eng:install-method clun "inspect" 1
      (lambda (this args) (declare (ignore this)) (eng:inspect-value (eng:arg args 0))))
    (eng:install-method clun "deepEquals" 2                ; the ONE shared deepEquals
      (lambda (this args) (declare (ignore this))
        (eng:js-boolean (eng:js-deep-equal (eng:arg args 0) (eng:arg args 1)))))
    (eng:install-method clun "sleepSync" 1
      (lambda (this args) (declare (ignore this))
        (let ((ms (eng:to-number (eng:arg args 0))))
          (when (and (not (eng:js-nan-p ms)) (plusp ms)) (sleep (/ ms 1000d0))))
        eng:+undefined+))
    (eng:install-method clun "sleep" 1                     ; -> a Promise resolving after ms
      (lambda (this args) (declare (ignore this))
        (%clun-sleep g (eng:to-number (eng:arg args 0)))))
    (eng:install-method clun "nanoseconds" 0
      (lambda (this args) (declare (ignore this args))
        (coerce (clun.sys:monotonic-nanoseconds) 'double-float)))
    (eng:install-method clun "gc" 1
      (lambda (this args)
        (declare (ignore this))
        (sb-ext:gc :full (eq (eng:to-boolean (eng:arg args 0)) eng:+true+))
        eng:+undefined+))
    (eng:install-method clun "which" 1
      (lambda (this args) (declare (ignore this)) (%which (eng:to-string (eng:arg args 0)))))
    (eng:install-method clun "fileURLToPath" 1
      (lambda (this args) (declare (ignore this)) (%file-url-to-path (eng:to-string (eng:arg args 0)))))
    (eng:install-method clun "pathToFileURL" 1
      (lambda (this args) (declare (ignore this)) (%path-to-file-url (eng:to-string (eng:arg args 0)))))
    (eng:install-method clun "file" 1
      (lambda (this args) (declare (ignore this)) (%clun-file g (eng:to-string (eng:arg args 0)))))
    (eng:install-method clun "write" 2
      (lambda (this args) (declare (ignore this)) (%clun-write g (eng:arg args 0) (eng:arg args 1))))
    (eng:install-method clun "serve" 1
      (lambda (this args) (declare (ignore this)) (%clun-serve g (eng:arg args 0))))
    (install-spawn clun g)                                 ; Clun.spawnSync (Phase 24)
    (eng:hidden-prop g "Clun" clun)
    clun))

;;; --- Clun.file / Clun.write (lazy file I/O; Bun-shaped, buffered) ------------

(defstruct (js-clun-file
            (:include eng:js-object (class :clun-file))
            (:constructor %make-js-clun-file))
  (path "" :type string)
  (start 0 :type (integer 0 *))
  end
  (sliced-p nil))

(defun %resolved-promise (g value)
  (eng:js-construct (eng:js-get g "Promise")
    (list (eng:make-native-function "" 2
            (lambda (this a) (declare (ignore this)) (eng:js-call (eng:arg a 0) eng:+undefined+ (list value)) eng:+undefined+)))))
(defun %rejected-promise (g err)
  (eng:js-construct (eng:js-get g "Promise")
    (list (eng:make-native-function "" 2
            (lambda (this a) (declare (ignore this)) (eng:js-call (eng:arg a 1) eng:+undefined+ (list err)) eng:+undefined+)))))

(defmacro %async ((g) &body body)
  "Run BODY; a fs-error -> a rejected Promise (JS Error w/ .code), else a Promise of the value."
  (let ((gg (gensym)) (e (gensym)))
    `(let ((,gg ,g))
       (handler-case (%resolved-promise ,gg (progn ,@body))
         (clun.sys:fs-error (,e) (%rejected-promise ,gg (%fs-error->js ,gg ,e)))))))

(defun %fs-error->js (g e)
  (let* ((code (clun.sys:fs-error-code e))
         (err (eng:js-construct (eng:js-get g "Error")
                                (list (format nil "~a: ~a, ~a '~a'" code (clun.sys:fs-code-message code)
                                              (clun.sys:fs-error-syscall e) (clun.sys:fs-error-path e))))))
    (eng:js-set err "code" code nil)
    (eng:js-set err "errno" (coerce (- (abs (clun.sys:fs-error-errno e))) 'double-float) nil)
    (eng:js-set err "syscall" (clun.sys:fs-error-syscall e) nil)
    (eng:js-set err "path" (clun.sys:fs-error-path e) nil)
    err))

(defun %clun-file-size (file)
  (let* ((stat (ignore-errors (clun.sys:stat* (js-clun-file-path file))))
         (total (if (and stat (clun.sys:fstat-file-p stat))
                    (clun.sys:fstat-size stat)
                    0))
         (start (min total (js-clun-file-start file)))
         (end (min total (or (js-clun-file-end file) total))))
    (max 0 (- end start))))

(defun %clun-file-octets (file)
  (let* ((octets (clun.sys:read-file-octets (js-clun-file-path file)))
         (start (min (length octets) (js-clun-file-start file)))
         (end (min (length octets)
                   (or (js-clun-file-end file) (length octets)))))
    (subseq octets start (max start end))))

(defun %clun-file-slice-index (value size default)
  (if (eng:js-undefined-p value)
      default
      (let ((number (eng:to-number value)))
        (cond
          ((eng:js-nan-p number) 0)
          ((>= number size) size)
          ((<= number (- size)) 0)
          ((minusp number) (max 0 (+ size (truncate number))))
          (t (truncate number))))))

(defun %make-clun-file-object (g path &key (start 0) end sliced-p)
  (let ((o (%make-js-clun-file :proto (eng:intrinsic :object-prototype)
                               :path path :start start :end end
                               :sliced-p sliced-p)))
    (eng:data-prop o "name" path)
    (eng:install-getter o "size"
      (lambda (this args) (declare (ignore this args))
        (coerce (%clun-file-size o) 'double-float)))
    (eng:install-method o "exists" 0
      (lambda (this args) (declare (ignore this args)) (%resolved-promise g (eng:js-boolean (clun.sys:file-p path)))))
    (eng:install-method o "text" 0
      (lambda (this args) (declare (ignore this args))
        (%async (g) (eng:utf8->code-units (%clun-file-octets o)))))
    (eng:install-method o "bytes" 0
      (lambda (this args) (declare (ignore this args))
        (%async (g) (%buffer-uint8 (%clun-file-octets o)))))
    (eng:install-method o "arrayBuffer" 0
      (lambda (this args) (declare (ignore this args))
        (%async (g) (eng:js-get (%buffer-uint8 (%clun-file-octets o)) "buffer"))))
    (eng:install-method o "json" 0
      (lambda (this args) (declare (ignore this args))
        (%async (g) (let ((json (eng:js-get g "JSON")))
                      (eng:js-call (eng:js-get json "parse") json
                                   (list (eng:utf8->code-units
                                          (%clun-file-octets o))))))))
    (eng:install-method o "slice" 2
      (lambda (this args)
        (declare (ignore this))
        (let* ((size (%clun-file-size o))
               (relative-start
                 (%clun-file-slice-index (eng:arg args 0) size 0))
               (relative-end
                 (%clun-file-slice-index (eng:arg args 1) size size))
               (base (js-clun-file-start o)))
          (%make-clun-file-object
           g path :start (+ base relative-start)
           :end (+ base (max relative-start relative-end))
           :sliced-p t))))
    o))

(defun %clun-file (g path)
  "A lazy BunFile: text()/json()/arrayBuffer()/bytes()/exists()/slice(), name, and size."
  (%make-clun-file-object g path))

(defun %buffer-uint8 (octets)
  "A Uint8Array over a COPY of OCTETS (Clun.file returns Uint8Array, not Buffer)."
  (eng:u8-from-octets octets))

(defun %clun-write (g dest data)
  "Write DATA (string / Buffer / Uint8Array / ArrayBuffer) to DEST (a path or a Clun.file)."
  (%async (g)
    (let* ((path (if (js-clun-file-p dest)
                     (js-clun-file-path dest)
                     (eng:to-string dest)))
           (octets (cond ((eng:js-typed-array-p data)
                          (multiple-value-bind (v o l) (eng:ta-octets data) (subseq v o (+ o l))))
                         ((eng:js-array-buffer-p data)
                          (copy-seq (eng:js-array-buffer-bytes data)))
                         (t (eng:code-units->utf8 (eng:to-string data))))))
      (coerce (clun.sys:write-file-octets path octets) 'double-float))))

(defun %clun-sleep (g ms)
  "A Promise that resolves (undefined) after MS via the global setTimeout."
  (let ((promise-ctor (eng:js-get g "Promise")) (set-timeout (eng:js-get g "setTimeout")))
    (eng:js-construct promise-ctor
      (list (eng:make-native-function "" 2
              (lambda (this a) (declare (ignore this))
                (let ((resolve (eng:arg a 0)))
                  (eng:js-call set-timeout eng:+undefined+
                               (list resolve (if (and (not (eng:js-nan-p ms)) (plusp ms)) ms 0d0)))
                  eng:+undefined+)))))))

(defun %which (cmd)
  "First executable named CMD on PATH (existence check), or null. A '/'-containing CMD
is checked directly."
  (flet ((ok (p) (and (clun.sys:file-p p) p)))
    (or (if (find #\/ cmd) (ok cmd)
            (loop for dir in (%split-path (clun.sys:getenv "PATH" ""))
                  for cand = (clun.sys:path-join dir cmd)
                  when (ok cand) return cand))
        eng:+null+)))

(defun %split-path (s)
  (loop with start = 0 for i = (position #\: s :start start)
        for part = (subseq s start (or i (length s)))
        unless (string= part "") collect part
        while i do (setf start (1+ i))))

(defun %file-url-to-path (url)
  "file:// URL -> a filesystem path (percent-decoded). Non-file URLs pass through best-effort."
  (let ((p (cond ((and (>= (length url) 7) (string= "file://" url :end2 7)) (subseq url 7))
                 (t url))))
    ;; drop an empty authority (file:///a -> /a)
    (%percent-decode p)))

(defun %path-to-file-url (path)
  "A path -> a file:// URL string (URL objects arrive in Phase 18 — documented 🟡)."
  (let ((abs (if (clun.sys:absolute-path-p path) path
                 (clun.sys:path-join (clun.sys:pathname->native (truename ".")) path))))
    (concatenate 'string "file://" abs)))

(defun %percent-decode (s)
  (with-output-to-string (o)
    (let ((i 0) (n (length s)))
      (loop while (< i n) do
        (let ((c (char s i)))
          (if (and (char= c #\%) (< (+ i 2) n))
              (progn (write-char (code-char (parse-integer s :start (1+ i) :end (+ i 3) :radix 16)) o)
                     (incf i 3))
              (progn (write-char c o) (incf i))))))))
