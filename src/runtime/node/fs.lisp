;;;; fs.lisp — node:fs (PLAN.md Phase 13). Sync + callback + promises over clun.sys,
;;;; wrapping every clun.sys:fs-error as a code-carrying JS Error. Buffers come from
;;;; node:buffer's %buffer-from-octets (loads before us). errno message = "CODE: syscall 'path'".

(in-package :clun.runtime)

(defun %fs-global () (eng:realm-global eng:*realm*))

(defun %fs-error-object (e)
  "Build a JS Error from a clun.sys:fs-error, tagged with code/errno/syscall/path."
  (let* ((code (clun.sys:fs-error-code e))
         (sc (clun.sys:fs-error-syscall e))
         (path (clun.sys:fs-error-path e))
         ;; Node's message: "ENOENT: no such file or directory, open '/p'".
         (msg (format nil "~a: ~a, ~a '~a'" code (clun.sys:fs-code-message code) sc path))
         ;; Node's .errno is the NEGATIVE libuv errno (-2 for ENOENT on Linux).
         (errno (- (abs (clun.sys:fs-error-errno e))))
         (err (eng:js-construct (eng:js-get (%fs-global) "Error") (list msg))))
    (eng:js-set err "code" code t)
    (eng:js-set err "errno" (coerce errno 'double-float) t)
    (eng:js-set err "syscall" sc t)
    (eng:js-set err "path" path t)
    err))

(defun %fs-throw (e) (eng:throw-js-value (%fs-error-object e)))

(defmacro %with-fs (&body body)
  `(handler-case (progn ,@body) (clun.sys:fs-error (e) (%fs-throw e))))

;;; --- options / data helpers ------------------------------------------------

(defun %fs-encoding (options)
  "The encoding string from OPTIONS: OPTIONS itself if a string, else options.encoding, else NIL."
  (cond ((eng:js-string-p options) (->str options))
        ((eng:js-object-p options)
         (let ((enc (eng:js-get options "encoding")))
           (if (or (undef-p enc) (eng:js-null-p enc)) nil (->str enc))))
        (t nil)))

(defun %fs-opt-flag (options key)
  "Truthy OPTIONS[KEY] when OPTIONS is an object, else NIL."
  (and (eng:js-object-p options)
       (eng:js-truthy (eng:js-get options key))))

(defun %fs-data->octets (data)
  "Bytes for writeFile/appendFile: a Buffer/typed-array's octets, else UTF-8 of the string."
  (if (eng:js-typed-array-p data)
      (multiple-value-bind (backing offset len) (eng:ta-octets data)
        (subseq backing offset (+ offset len)))
      (eng:code-units->utf8 (->str data))))

(defun %fs-buffer (octets) (%buffer-from-octets octets))

(defun %fs-decode (octets enc)
  "Decode OCTETS to a string via a Buffer's toString(ENC) (honours hex/base64/etc.)."
  (let ((buf (%fs-buffer octets)))
    (->str (eng:js-call (eng:js-get buf "toString") buf (list enc)))))

(defun %fs-read (path options)
  "readFileSync core: a decoded string when an encoding is present, else a Buffer."
  (let ((octets (clun.sys:read-file-octets path))
        (enc (%fs-encoding options)))
    (if enc (%fs-decode octets enc) (%fs-buffer octets))))

;;; --- Stats / Dirent --------------------------------------------------------

(defun %stat-date (global ms) (eng:js-construct (eng:js-get global "Date") (list ms)))

(defun %make-stats (st)
  (let* ((global (%fs-global)) (o (eng:new-object))
         (atime-ms (/ (clun.sys:fstat-atime-ns st) 1000000.0d0))
         (mtime-ms (/ (clun.sys:fstat-mtime-ns st) 1000000.0d0))
         (ctime-ms (/ (clun.sys:fstat-ctime-ns st) 1000000.0d0)))
    (labels ((m (name val) (eng:install-method o name 0
                             (lambda (this args) (declare (ignore this args)) (eng:js-boolean val))))
             (d (key num) (eng:data-prop o key (coerce num 'double-float))))
      (m "isFile" (clun.sys:fstat-file-p st))
      (m "isDirectory" (clun.sys:fstat-dir-p st))
      (m "isSymbolicLink" (clun.sys:fstat-symlink-p st))
      (m "isBlockDevice" nil) (m "isCharacterDevice" nil)
      (m "isFIFO" nil) (m "isSocket" nil)
      (d "size" (clun.sys:fstat-size st)) (d "mode" (clun.sys:fstat-mode st))
      (d "ino" (clun.sys:fstat-ino st)) (d "nlink" (clun.sys:fstat-nlink st))
      (d "uid" (clun.sys:fstat-uid st)) (d "gid" (clun.sys:fstat-gid st))
      (d "dev" (clun.sys:fstat-dev st)) (d "rdev" (clun.sys:fstat-rdev st))
      (d "atimeMs" atime-ms) (d "mtimeMs" mtime-ms)
      (d "ctimeMs" ctime-ms) (d "birthtimeMs" ctime-ms)
      (eng:data-prop o "atime" (%stat-date global atime-ms))
      (eng:data-prop o "mtime" (%stat-date global mtime-ms))
      (eng:data-prop o "ctime" (%stat-date global ctime-ms))
      (eng:data-prop o "birthtime" (%stat-date global ctime-ms))
      o)))

(defun %make-dirent (name parent)
  (let ((o (eng:new-object))
        (st (ignore-errors (clun.sys:stat* (clun.sys:path-join parent name) :lstat t))))
    (labels ((m (nm val) (eng:install-method o nm 0
                           (lambda (this args) (declare (ignore this args)) (eng:js-boolean val)))))
      (eng:data-prop o "name" name)
      (m "isFile" (and st (clun.sys:fstat-file-p st)))
      (m "isDirectory" (and st (clun.sys:fstat-dir-p st)))
      (m "isSymbolicLink" (and st (clun.sys:fstat-symlink-p st))))
    o))

;;; --- sync ops (shared by callback/promise wrappers) ------------------------

(defun %op-read (args) (%fs-read (->str (a args 0)) (a args 1)))

(defun %op-write (args &key append)
  (clun.sys:write-file-octets (->str (a args 0)) (%fs-data->octets (a args 1)) :append append)
  (undef))

(defun %op-stat (args &key lstat) (%make-stats (clun.sys:stat* (->str (a args 0)) :lstat lstat)))

(defun %op-mkdir (args)
  (let* ((path (->str (a args 0))) (opts (a args 1))
         (recursive (%fs-opt-flag opts "recursive"))
         (created (clun.sys:make-directory path :recursive recursive)))
    ;; recursive -> the topmost newly-created dir (or undefined if none); else undefined.
    (if (and recursive created) created (undef))))

(defun %op-readdir (args)
  (let* ((path (->str (a args 0))) (opts (a args 1))
         (names (sort (copy-list (clun.sys:read-directory path)) #'string<)))
    (if (%fs-opt-flag opts "withFileTypes")
        (eng:new-array (mapcar (lambda (n) (%make-dirent n path)) names))
        (eng:new-array names))))

(defun %op-unlink (args) (clun.sys:remove-file (->str (a args 0))) (undef))

(defun %op-rename (args)
  (clun.sys:rename-path (->str (a args 0)) (->str (a args 1))) (undef))

(defun %op-access (args)
  (let ((mode (a args 1)))
    (clun.sys:check-access (->str (a args 0)) (if (undef-p mode) 0 (truncate (->num mode)))))
  (undef))

(defun %op-copy (args)
  (clun.sys:copy-file* (->str (a args 0)) (->str (a args 1))) (undef))

(defun %op-realpath (args) (or (clun.sys:realpath (->str (a args 0))) (->str (a args 0))))

(defun %op-mkdtemp (args) (clun.sys:make-temp-dir (->str (a args 0))))

(defun %op-rm (args)
  (let* ((path (->str (a args 0))) (opts (a args 1))
         (recursive (%fs-opt-flag opts "recursive")) (force (%fs-opt-flag opts "force")))
    (handler-case
        (if recursive (clun.sys:remove-recursive path) (clun.sys:remove-file path))
      (clun.sys:fs-error (e)
        (if (and force (string= (clun.sys:fs-error-code e) "ENOENT")) nil (%fs-throw e))))
    (undef)))

;;; --- callback wrapper ------------------------------------------------------

(defun %callbackify (op)
  "A method fn that runs OP (a fn of args) synchronously, then invokes the trailing
callback as cb(null,result) or cb(errorObject)."
  (lambda (this args)
    (declare (ignore this))
    (let* ((n (length args)) (cb (and (plusp n) (a args (1- n))))
           (rest (if (plusp n) (subseq args 0 (1- n)) '())))
      (handler-case
          (let ((res (funcall op rest)))
            (when (eng:callable-p cb) (eng:js-call cb (undef) (list eng:+null+ res))))
        (clun.sys:fs-error (e)
          (when (eng:callable-p cb) (eng:js-call cb (undef) (list (%fs-error-object e))))))
      (undef))))

;;; --- promise wrapper -------------------------------------------------------

(defun %promisify (op)
  "A method fn returning a Promise that resolves with OP's result or rejects with the error."
  (lambda (this args)
    (declare (ignore this))
    (let* ((global (%fs-global))
           (executor
             (eng:make-native-function
              "" 2
              (lambda (ethis eargs)
                (declare (ignore ethis))
                (let ((resolve (a eargs 0)) (reject (a eargs 1)))
                  (handler-case
                      (eng:js-call resolve (undef) (list (funcall op args)))
                    (clun.sys:fs-error (e)
                      (eng:js-call reject (undef) (list (%fs-error-object e)))))
                  (undef))))))
      (eng:js-construct (eng:js-get global "Promise") (list executor)))))

;;; --- constants -------------------------------------------------------------

(defun %fs-constants ()
  (let ((o (eng:new-object)))
    (flet ((c (k v) (eng:data-prop o k (coerce v 'double-float))))
      (c "F_OK" 0) (c "R_OK" 4) (c "W_OK" 2) (c "X_OK" 1)
      (c "O_RDONLY" 0) (c "O_WRONLY" 1) (c "O_RDWR" 2) (c "O_CREAT" 64)
      (c "O_EXCL" 128) (c "O_TRUNC" 512) (c "O_APPEND" 1024)
      (c "S_IFMT" #o170000) (c "S_IFREG" #o100000)
      (c "S_IFDIR" #o040000) (c "S_IFLNK" #o120000))
    o))

;;; --- promises namespace ----------------------------------------------------

(defun %fs-promises ()
  (let ((o (eng:new-object)))
    (labels ((p (name arity op) (eng:install-method o name arity (%promisify op))))
      (p "readFile" 2 #'%op-read)
      (p "writeFile" 3 (lambda (args) (%op-write args)))
      (p "appendFile" 3 (lambda (args) (%op-write args :append t)))
      (p "stat" 2 (lambda (args) (%op-stat args)))
      (p "lstat" 2 (lambda (args) (%op-stat args :lstat t)))
      (p "mkdir" 2 #'%op-mkdir)
      (p "readdir" 2 #'%op-readdir)
      (p "unlink" 1 #'%op-unlink)
      (p "rename" 2 #'%op-rename)
      (p "access" 2 #'%op-access)
      (p "copyFile" 3 #'%op-copy)
      (p "rm" 2 #'%op-rm)
      (p "mkdtemp" 2 #'%op-mkdtemp)
      (p "realpath" 2 #'%op-realpath))
    o))

;;; --- module ----------------------------------------------------------------

(defun build-node-fs ()
  (let ((o (eng:new-object)))
    (labels ((m (name arity fn) (eng:install-method o name arity fn))
             (mo (name arity op) (m name arity (lambda (this args) (declare (ignore this))
                                                 (%with-fs (funcall op args))))))
      ;; sync
      (mo "readFileSync" 2 #'%op-read)
      (mo "writeFileSync" 3 (lambda (args) (%op-write args)))
      (mo "appendFileSync" 3 (lambda (args) (%op-write args :append t)))
      (mo "statSync" 2 (lambda (args) (%op-stat args)))
      (mo "lstatSync" 2 (lambda (args) (%op-stat args :lstat t)))
      (mo "mkdirSync" 2 #'%op-mkdir)
      (mo "rmdirSync" 1 (lambda (args) (clun.sys:remove-directory (->str (a args 0))) (undef)))
      (mo "rmSync" 2 #'%op-rm)
      (mo "readdirSync" 2 #'%op-readdir)
      (mo "unlinkSync" 1 #'%op-unlink)
      (mo "renameSync" 2 #'%op-rename)
      (mo "realpathSync" 1 #'%op-realpath)
      (mo "copyFileSync" 3 #'%op-copy)
      (mo "readlinkSync" 1 (lambda (args) (clun.sys:read-symlink (->str (a args 0)))))
      (mo "symlinkSync" 2 (lambda (args)
                            (clun.sys:make-symlink (->str (a args 0)) (->str (a args 1))) (undef)))
      (mo "chmodSync" 2 (lambda (args)
                          (clun.sys:change-mode (->str (a args 0)) (truncate (->num (a args 1)))) (undef)))
      (mo "truncateSync" 2 (lambda (args)
                             (let ((len (a args 1)))
                               (clun.sys:truncate-file (->str (a args 0))
                                                       (if (undef-p len) 0 (truncate (->num len)))))
                             (undef)))
      (mo "mkdtempSync" 1 #'%op-mkdtemp)
      (mo "accessSync" 2 #'%op-access)
      (m "existsSync" 1 (lambda (this args) (declare (ignore this))
                          (eng:js-boolean (clun.sys:path-exists-p (->str (a args 0))))))
      ;; callback forms
      (m "readFile" 3 (%callbackify #'%op-read))
      (m "writeFile" 4 (%callbackify (lambda (args) (%op-write args))))
      (m "appendFile" 4 (%callbackify (lambda (args) (%op-write args :append t))))
      (m "stat" 3 (%callbackify (lambda (args) (%op-stat args))))
      (m "mkdir" 3 (%callbackify #'%op-mkdir))
      (m "readdir" 3 (%callbackify #'%op-readdir))
      (m "unlink" 2 (%callbackify #'%op-unlink))
      (m "rename" 3 (%callbackify #'%op-rename))
      (m "access" 3 (%callbackify #'%op-access))
      (m "exists" 2 (lambda (this args)
                      (declare (ignore this))
                      (let* ((n (length args)) (cb (and (plusp n) (a args (1- n)))))
                        (when (eng:callable-p cb)
                          (eng:js-call cb (undef)
                                       (list (eng:js-boolean
                                              (clun.sys:path-exists-p (->str (a args 0)))))))
                        (undef))))
      ;; data props
      (eng:data-prop o "constants" (%fs-constants))
      (eng:data-prop o "promises" (%fs-promises))
      o)))

(register-node-builtin "fs" #'build-node-fs)
