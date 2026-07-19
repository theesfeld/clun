;;;; bundle.lisp — pure-CL entry/module/asset graph for SFE compile (Issue #181).

(in-package :clun.sfe)

(defparameter *bundle-builtin-prefixes*
  '("node:" "bun:" "clun:" "fs" "path" "os" "util" "events" "assert"
    "buffer" "url" "querystring" "timers" "module" "process" "crypto"
    "stream" "http" "https" "net" "tls" "zlib" "worker_threads")
  "Specifiers that stay external (runtime-provided); not embedded.")

(defun %builtin-specifier-p (spec)
  (or (find #\: spec :test #'char=)
      (member spec *bundle-builtin-prefixes* :test #'string=)
      (and (plusp (length spec))
           (char/= (char spec 0) #\.)
           (char/= (char spec 0) #\/)
           ;; bare package name — leave for runtime resolution unless file: path
           (not (sys:file-p spec)))))

(defun %scan-string-literals-after (source needles)
  "Find quoted string literals that immediately follow any of NEEDLES in SOURCE.
   NEEDLES are substrings like \"from\" \"require(\" \"import \"."
  (let ((hits '())
        (n (length source)))
    (labels ((skip-ws (i)
               (loop while (and (< i n)
                                (member (char source i)
                                        '(#\Space #\Tab #\Newline #\Return)))
                     do (incf i))
               i)
             (read-string (i)
               (when (>= i n) (return-from read-string (values nil i)))
               (let ((q (char source i)))
                 (unless (or (char= q #\') (char= q #\") (char= q #\`))
                   (return-from read-string (values nil i)))
                 (incf i)
                 (let ((start i))
                   (loop while (< i n)
                         do (let ((c (char source i)))
                              (cond
                                ((char= c #\\) (incf i 2))
                                ((char= c q)
                                 (return-from read-string
                                   (values (subseq source start i) (1+ i))))
                                (t (incf i))))
                   (values nil i)))))
             (try-at (pos needle)
               (let ((i (skip-ws (+ pos (length needle)))))
                 ;; allow optional type-only / side-effect forms
                 (when (and (< i n) (char= (char source i) #\())
                   (setf i (skip-ws (1+ i))))
                 (multiple-value-bind (str next) (read-string i)
                   (declare (ignore next))
                   (when (and str (plusp (length str)))
                     (push str hits))))))
      (dolist (needle needles)
        (loop for pos = (search needle source :test #'char=)
                then (search needle source :start2 (1+ pos) :test #'char=)
              while pos
              do (try-at pos needle)))
      (nreverse (delete-duplicates hits :test #'string=)))))

(defun collect-import-specifiers (source)
  "Heuristic static import/require/export-from specifier collection."
  (append
   (%scan-string-literals-after source '("from " "from\t" "from\n" "from\r"))
   (%scan-string-literals-after source '("import " "import\t" "import\n"))
   (%scan-string-literals-after source '("require(" "require ("))
   (%scan-string-literals-after source '("export "))))

(defun %conditions-for (path)
  (if (member (sys:path-extension path) '(".cjs" ".cts") :test #'string=)
      '("node" "require")
      clun.resolver:*default-conditions*))

(defun %entry-specifier (entry cwd)
  "Turn ENTRY into a resolver specifier relative to CWD."
  (cond
    ((sys:absolute-path-p entry) entry)
    ((and (plusp (length entry))
          (or (char= (char entry 0) #\.)
              (char= (char entry 0) #\/)))
     entry)
    (t (concatenate 'string "./" entry))))

(defun collect-module-graph (entry &key (cwd nil))
  "Resolve ENTRY and transitive local imports into an alist of (abs-path . source).
   ENTRY may be absolute or relative to CWD."
  (let* ((cwd (or cwd (sys:current-directory)))
         (spec (%entry-specifier entry cwd))
         (resolved
          (handler-case
              (multiple-value-bind (path fmt)
                  (clun.resolver:resolve spec cwd
                                         :conditions (%conditions-for spec))
                (declare (ignore fmt))
                path)
            (clun.resolver:resolution-error ()
              (let ((abs (if (sys:absolute-path-p entry)
                             entry
                             (sys:path-join cwd entry))))
                (or (sys:realpath abs)
                    (and (sys:file-p abs) abs)
                    (%fail :entry-not-found entry))))))
         (seen (make-hash-table :test 'equal))
         (modules '()))
    (labels ((visit (path)
               (let ((abs (or (sys:realpath path) path)))
                 (when (gethash abs seen)
                   (return-from visit))
                 (unless (sys:file-p abs)
                   (%fail :module-not-found abs))
                 (setf (gethash abs seen) t)
                 (let* ((src (sys:read-file-string abs))
                        (dir (sys:path-dirname abs)))
                   (push (cons abs src) modules)
                   (dolist (ispec (collect-import-specifiers src))
                     (unless (%builtin-specifier-p ispec)
                       (handler-case
                           (multiple-value-bind (dep fmt)
                               (clun.resolver:resolve ispec dir
                                                      :conditions (%conditions-for abs))
                             (declare (ignore fmt))
                             (when dep (visit dep)))
                         (clun.resolver:resolution-error ()
                           ;; leave unresolved bare packages external
                           nil))))))))
      (visit resolved)
      (values (nreverse modules) resolved))))
(defun load-assets (asset-specs &key (cwd nil))
  "ASSET-SPECS is a list of path strings or (virtual-name . path) conses.
   Returns ((virtual-name . octets)*)."
  (let ((cwd (or cwd (sys:current-directory)))
        (out '()))
    (dolist (spec asset-specs out)
      (multiple-value-bind (name path)
          (if (consp spec)
              (values (car spec) (cdr spec))
              (values (sys:path-basename spec) spec))
        (let* ((abs (if (sys:absolute-path-p path)
                        path
                        (sys:path-join cwd path)))
               (real (or (sys:realpath abs) abs)))
          (unless (sys:file-p real)
            (%fail :asset-not-found real))
          (push (cons name (sys:read-file-octets real)) out))))
    (nreverse out)))

(defun apply-defines (source defines)
  "Replace free identifiers listed in DEFINES ((name . json-literal-string)*) .
   Conservative: whole-word textual replacement for build-time constants."
  (if (null defines)
      source
      (let ((out source))
        (dolist (pair defines out)
          (let* ((name (car pair))
                 (value (cdr pair))
                 (pattern name))
            ;; Simple global replace of exact token occurrences bounded by non-ident chars.
            (setf out
                  (with-output-to-string (s)
                    (let ((i 0) (n (length out)))
                      (loop while (< i n)
                            do (if (and (<= (+ i (length pattern)) n)
                                        (string= out pattern :start1 i
                                                             :end1 (+ i (length pattern)))
                                        (or (zerop i)
                                            (not (alphanumericp (char out (1- i)))))
                                        (let ((j (+ i (length pattern))))
                                          (or (>= j n)
                                              (not (or (alphanumericp (char out j))
                                                       (char= (char out j) #\_)
                                                       (char= (char out j) #\$))))))
                                   (progn (write-string value s)
                                          (incf i (length pattern)))
                                   (progn (write-char (char out i) s)
                                          (incf i))))))))))))

(defun minify-source (source)
  "Whitespace-light minify (pure CL). Not a full JS minifier — strips // comments
   and compresses runs of horizontal whitespace outside strings."
  (with-output-to-string (out)
    (let ((i 0) (n (length source)) (in-str nil) (q nil) (prev-space nil))
      (loop while (< i n)
            do (let ((c (char source i)))
                 (cond
                   (in-str
                    (write-char c out)
                    (cond
                      ((char= c #\\)
                       (when (< (1+ i) n)
                         (write-char (char source (1+ i)) out)
                         (incf i 2)
                         (decf i))) ; loop will +1
                      ((char= c q) (setf in-str nil)))
                    (incf i))
                   ((and (char= c #\/) (< (1+ i) n) (char= (char source (1+ i)) #\/))
                    (loop while (and (< i n) (char/= (char source i) #\Newline))
                          do (incf i)))
                   ((and (char= c #\/) (< (1+ i) n) (char= (char source (1+ i)) #\*))
                    (incf i 2)
                    (loop until (or (>= i n)
                                    (and (< (1+ i) n)
                                         (char= (char source i) #\*)
                                         (char= (char source (1+ i)) #\/)))
                          do (incf i))
                    (when (< (1+ i) n) (incf i 2)))
                   ((or (char= c #\') (char= c #\") (char= c #\`))
                    (setf in-str t q c prev-space nil)
                    (write-char c out)
                    (incf i))
                   ((member c '(#\Space #\Tab) :test #'char=)
                    (unless prev-space
                      (write-char #\Space out)
                      (setf prev-space t))
                    (incf i))
                   ((member c '(#\Newline #\Return) :test #'char=)
                    (unless prev-space
                      (write-char #\Newline out)
                      (setf prev-space t))
                    (incf i))
                   (t
                    (setf prev-space nil)
                    (write-char c out)
                    (incf i))))))))

(defun prepare-modules (modules &key defines minify)
  (mapcar (lambda (pair)
            (let ((src (cdr pair)))
              (setf src (apply-defines src defines))
              (when minify (setf src (minify-source src)))
              (cons (car pair) src)))
          modules))
