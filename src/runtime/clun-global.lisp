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
    (eng:install-method clun "which" 1
      (lambda (this args) (declare (ignore this)) (%which (eng:to-string (eng:arg args 0)))))
    (eng:install-method clun "fileURLToPath" 1
      (lambda (this args) (declare (ignore this)) (%file-url-to-path (eng:to-string (eng:arg args 0)))))
    (eng:install-method clun "pathToFileURL" 1
      (lambda (this args) (declare (ignore this)) (%path-to-file-url (eng:to-string (eng:arg args 0)))))
    (eng:hidden-prop g "Clun" clun)
    clun))

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
