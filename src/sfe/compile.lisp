;;;; compile.lisp — pure-CL single-file executable compile path (Issue #181 / epic #177).
;;;;
;;;; Native packaging uses an SBCL image dump (save-lisp-and-die) performed in a
;;;; child process: SBCL locates its core at EOF, so Bun-style binary trailers
;;;; break the runtime. Cross-target offline templates still emit portable
;;;; CLUNSEA payload packages that finalize on the matching host.

(in-package :clun.sfe)

(defparameter +gpl-source-notice+
  (format nil "~
Clun single-file executable — GPL-3.0-or-later.
Source for the Clun runtime is available from the Clun project distribution
matching the embedded clunVersion. Application modules and assets embedded
in this binary are subject to their own licenses as declared by the author.
")
  "Embedded legal notice (Phase 52 GPL obligation).")

;;; --- image-embedded state (saved into dumped executables) -------------------

(defparameter *sfe-image-mode* nil
  "T when this process is a dumped SFE application image.")

(defparameter *sfe-entry* nil)
(defparameter *sfe-modules* nil
  "Alist of (abs-path . source-string).")
(defparameter *sfe-assets* nil
  "Alist of (name . octets).")
(defparameter *sfe-manifest* nil)
(defparameter *sfe-payload* nil
  "Encoded payload octets used for signing/verify.")
(defparameter *sfe-signature* nil)
(defparameter *sfe-sig-algo* 0)
(defparameter *sfe-exec-argv* nil)
(defparameter *sfe-public-key* nil)

(defparameter *embedded-sea* nil
  "When non-NIL, plist of a portable SEA package opened for this process.")

(defparameter *embedded-assets* (make-hash-table :test 'equal)
  "Virtual asset name → octet vector for the running SFE.")

(defun %manifest-get (manifest key &optional default)
  (let ((cell (assoc key manifest :test #'string=)))
    (if cell (cdr cell) default)))

(defun %source-date-epoch ()
  (let ((e (sys:getenv "SOURCE_DATE_EPOCH")))
    (if (and e (plusp (length e)))
        (parse-integer e :junk-allowed t)
        (floor (sys:unix-milliseconds) 1000))))

(defun %build-id (entry target modules assets)
  "Stable hex id from entry/target/module+asset digests (reproducible)."
  (let ((h (crypto:make-digest :sha256)))
    (crypto:update-digest h (%utf8 entry))
    (crypto:update-digest h (%utf8 target))
    (dolist (m (sort (copy-list modules) #'string< :key #'car))
      (crypto:update-digest h (%utf8 (car m)))
      (crypto:update-digest h (%utf8 (cdr m))))
    (dolist (a (sort (copy-list assets) #'string< :key #'car))
      (crypto:update-digest h (%utf8 (car a)))
      (crypto:update-digest h (cdr a)))
    (%hex (crypto:produce-digest h))))

(defun make-manifest (&key entry target modules assets outfile
                        exec-argv defines minify bytecode
                        public-key-hex clun-version build-id packaging)
  (let ((mod-list (map 'vector #'identity
                       (mapcar #'car modules)))
        (asset-list (map 'vector #'identity
                         (mapcar (lambda (a)
                                   (list (cons "name" (car a))
                                         (cons "sha256" (%hex (%sha256 (cdr a))))
                                         (cons "size" (length (cdr a)))))
                                 assets))))
    `(("format" . "CLUNSEA")
      ("version" . ,+sea-version+)
      ("entry" . ,entry)
      ("target" . ,target)
      ("outfile" . ,(or outfile ""))
      ("packaging" . ,(or packaging "image"))
      ("clunVersion" . ,(or clun-version clun::*clun-version*))
      ("buildId" . ,build-id)
      ("sourceDateEpoch" . ,(%source-date-epoch))
      ("minify" . ,(if minify sys:json-true sys:json-false))
      ("bytecode" . ,(if bytecode sys:json-true sys:json-false))
      ("modules" . ,mod-list)
      ("assets" . ,asset-list)
      ("execArgv" . ,(map 'vector #'identity (or exec-argv '())))
      ("defines" . ,(if defines
                        (loop for (k . v) in defines collect (cons k v))
                        :empty-object))
      ("sourceNotice" . ,+gpl-source-notice+)
      ,@(when public-key-hex
          `(("publicKeyHex" . ,public-key-hex)
            ("signed" . ,sys:json-true))))))

;;; --- job file (parent → dump child) ----------------------------------------

(defun %write-job (path plist)
  "Write a binary job: payload + signature + JSON sidecar header as our payload format."
  (let* ((manifest (getf plist :manifest))
         (modules (getf plist :modules))
         (assets (getf plist :assets))
         (payload (encode-payload manifest modules assets))
         (sig (or (getf plist :signature)
                  (make-array 0 :element-type '(unsigned-byte 8))))
         (meta `(("outfile" . ,(getf plist :outfile))
                 ("sigAlgo" . ,(getf plist :sig-algo))
                 ("publicKeyHex" . ,(or (getf plist :public-key-hex) ""))
                 ("execArgv" . ,(map 'vector #'identity
                                     (or (getf plist :exec-argv) '())))))
         (meta-bytes (%utf8 (sys:write-json meta :indent 0))))
    (sys:write-file-octets
     path
     (%cat (%lp-octets meta-bytes)
           (%lp-octets payload)
           (%lp-octets sig)))))

(defun %read-job (path)
  (let* ((octets (sys:read-file-octets path))
         (pos 0))
    (multiple-value-bind (meta-bytes p1) (%read-lp octets 0)
      (multiple-value-bind (payload p2) (%read-lp octets p1)
        (multiple-value-bind (sig p3) (%read-lp octets p2)
          (declare (ignore p3))
          (let* ((meta (sys:parse-json (%utf8-string meta-bytes)))
                 (manifest-modules-assets (multiple-value-list
                                           (decode-payload payload))))
            (list :outfile (sys:jget meta "outfile")
                  :sig-algo (let ((v (sys:jget meta "sigAlgo")))
                              (if (numberp v) (truncate v) 0))
                  :public-key-hex (sys:jget meta "publicKeyHex" "")
                  :exec-argv (let ((v (sys:jget meta "execArgv")))
                               (when (vectorp v) (map 'list #'identity v)))
                  :payload payload
                  :signature sig
                  :manifest (first manifest-modules-assets)
                  :modules (second manifest-modules-assets)
                  :assets (third manifest-modules-assets))))))))

(defun perform-image-dump (job-path)
  "Child entry: load JOB-PATH into image specials and save-lisp-and-die."
  (let* ((job (%read-job job-path))
         (outfile (getf job :outfile)))
    (setf *sfe-image-mode* t
          *sfe-entry* (%manifest-get (getf job :manifest) "entry")
          *sfe-modules* (getf job :modules)
          *sfe-assets* (getf job :assets)
          *sfe-manifest* (getf job :manifest)
          *sfe-payload* (getf job :payload)
          *sfe-signature* (getf job :signature)
          *sfe-sig-algo* (getf job :sig-algo)
          *sfe-exec-argv* (getf job :exec-argv)
          *sfe-public-key*
          (let ((hex (getf job :public-key-hex)))
            (when (and hex (plusp (length hex)))
              (crypto:hex-string-to-byte-array hex))))
    (install-embedded-assets *sfe-assets*)
    (ensure-directories-exist
     (sys:native->pathname (sys:path-dirname outfile)))
    (sb-ext:save-lisp-and-die
     outfile
     :executable t
     :save-runtime-options t
     :toplevel #'dumped-sfe-toplevel)))

(defun dumped-sfe-toplevel ()
  "Toplevel for a dumped SFE image."
  (let* ((argv (rest sb-ext:*posix-argv*))
         (backtrace (member "--backtrace" argv :test #'string=)))
    (handler-case
        (cond
          ;; Force full Clun CLI (exceeds Bun BUN_BE_BUN).
          ((be-clun-mode-p)
           (clun::main))
          ;; Metadata / verify without running the app entry.
          ((equal (first argv) "--sfe-info")
           (format t "format=CLUNSEA packaging=image entry=~A target=~A buildId=~A signed=~A~%"
                   *sfe-entry*
                   (%manifest-get *sfe-manifest* "target")
                   (%manifest-get *sfe-manifest* "buildId")
                   (plusp *sfe-sig-algo*))
           (sb-ext:exit :code 0))
          ((equal (first argv) "--sfe-verify")
           (let ((v (verify-image-sfe)))
             (format t "ok=~A algo=~A signed=~A digest=~A~@[ error=~A~]~%"
                     (getf v :ok) (getf v :algo) (getf v :signed)
                     (getf v :digest) (getf v :error))
             (sb-ext:exit :code (if (getf v :ok) 0 1))))
          (t
           (sb-ext:exit :code (run-image-embedded argv))))
      (error (c)
        (format *error-output* "clun: ~a~%" c)
        (when backtrace (sb-debug:print-backtrace :stream *error-output* :count 30))
        (sb-ext:exit :code 1)))))

(defun verify-image-sfe ()
  (let ((digest (payload-digest-hex *sfe-payload*)))
    (cond
      ((zerop *sfe-sig-algo*)
       (list :ok t :algo :none :digest digest :signed nil))
      ((null *sfe-public-key*)
       (list :ok nil :algo (algo-keyword *sfe-sig-algo*) :digest digest
             :signed t :error "missing public key"))
      ((verify-payload *sfe-payload* *sfe-signature* *sfe-public-key*
                       :algo (algo-keyword *sfe-sig-algo*))
       (list :ok t :algo (algo-keyword *sfe-sig-algo*) :digest digest :signed t))
      (t
       (list :ok nil :algo (algo-keyword *sfe-sig-algo*) :digest digest
             :signed t :error "signature mismatch")))))

(defun run-image-embedded (argv)
  (install-embedded-assets *sfe-assets*)
  (let* ((entry *sfe-entry*)
         (modules *sfe-modules*)
         (exec-argv *sfe-exec-argv*))
    (multiple-value-bind (tmpdir path-map)
        (materialize-modules modules)
      (unwind-protect
           (let* ((entry-path (or (gethash entry path-map) entry))
                  (full-argv (append exec-argv argv))
                  (r (list :action :run :file entry-path :args full-argv
                           :cwd (sys:current-directory) :silent nil :backtrace nil))
                  (cwd (sys:current-directory))
                  (realm (clun::make-runtime-realm r cwd
                                                   :script entry-path
                                                   :rest full-argv)))
             (let ((clun-g (eng:js-get (eng:realm-global realm) "Clun")))
               (when (eng:js-object-p clun-g)
                 (eng:data-prop clun-g "main" entry-path)))
             (eng:run-module-file entry-path :realm realm)
             (clun::finish-exit realm))
        (ignore-errors (sys:remove-recursive tmpdir))))))

;;; --- public compile API ----------------------------------------------------

(defun %native-target-p (target)
  (string= (normalize-target target) (host-target)))

(defun %spawn-image-dump (self job-path)
  (let* ((err (make-string-output-stream))
         (out (make-string-output-stream))
         (proc (sb-ext:run-program
                self
                (list "--internal-sfe-dump" job-path)
                :wait t
                :output out
                :error err
                :environment
                (cons "CLUN_SFE_DUMPING=1"
                      (remove-if (lambda (e)
                                   (or (and (>= (length e) 15)
                                            (string= "CLUN_SFE_DUMPING=" e :end2 15))
                                       (and (>= (length e) 12)
                                            (string= "CLUN_BE_CLUN=" e :end2 12))))
                                 (sb-ext:posix-environ))))))
    (let ((code (sb-ext:process-exit-code proc)))
      ;; save-lisp-and-die exits 0 on success
      (unless (eql code 0)
        (%fail :dump-failed
               (format nil "image dump exit ~A~%~A~%~A"
                       code (get-output-stream-string out)
                       (get-output-stream-string err))))
      code)))

(defun compile-executable (entry &key
                                   (outfile nil)
                                   (target nil)
                                   (template nil)
                                   (assets nil)
                                   (defines nil)
                                   (minify nil)
                                   (bytecode nil)
                                   (exec-argv nil)
                                   (sign nil)
                                   (private-key nil)
                                   (public-key nil)
                                   (sign-algo :ed25519)
                                   (cwd nil)
                                   (host-path nil)
                                   (portable nil))
  "Compile ENTRY into a single-file executable at OUTFILE.
   Native targets use pure-CL image dump (working standalone binary).
   Cross-targets emit a portable CLUNSEA package (finalize on target host).
   Returns plist :outfile :target :modules :assets :build-id :signed :digest :packaging."
  (let* ((cwd (or cwd (sys:current-directory)))
         (target (normalize-target (or target (host-target))))
         (outfile (or outfile
                      (let ((base (sys:path-basename entry)))
                        (sys:path-join
                         cwd
                         (if (find #\. base)
                             (subseq base 0 (position #\. base :from-end t))
                             base)))))
         (native (and (%native-target-p target) (not portable)))
         (dump-bin
          (cond
            ((and template (sys:file-p template)) template)
            ((and host-path (sys:file-p host-path)) host-path)
            (t
             (handler-case
                 (resolve-template target :template template :host-path host-path)
               (sfe-error ()
                 (self-executable-path)))))))
    (multiple-value-bind (modules entry-abs)
        (collect-module-graph entry :cwd cwd)
      (let* ((modules (prepare-modules modules :defines defines :minify minify))
             (asset-list (load-assets (or assets '()) :cwd cwd))
             (build-id (%build-id entry-abs target modules asset-list))
             (pub-hex (when (and sign public-key)
                        (%hex public-key)))
             (manifest (make-manifest
                        :entry entry-abs :target target :modules modules
                        :assets asset-list :outfile outfile
                        :exec-argv exec-argv :defines defines
                        :minify minify :bytecode bytecode
                        :public-key-hex pub-hex
                        :build-id build-id
                        :packaging (if native "image" "portable")))
             (payload (encode-payload manifest modules asset-list))
             (sig-algo-code +sig-algo-none+)
             (signature (make-array 0 :element-type '(unsigned-byte 8))))
        (when sign
          (unless private-key
            (%fail :missing-key "sign requested without private-key"))
          (multiple-value-bind (sig code)
              (sign-payload payload private-key :algo sign-algo)
            (setf signature sig sig-algo-code code)))
        (ensure-directories-exist
         (sys:native->pathname (sys:path-dirname outfile)))
        (cond
          (native
           (unless (and dump-bin (sys:file-p dump-bin))
             (%fail :template-missing
                    "native image dump needs a Clun executable template (build/clun)"))
           (let* ((job-dir (sys:make-temp-dir
                            (sys:path-join (sys:tmpdir) "clun-sfe-job-")))
                  (job-path (sys:path-join job-dir "job.bin")))
             (unwind-protect
                  (progn
                    (%write-job job-path
                                (list :outfile outfile
                                      :manifest manifest
                                      :modules modules
                                      :assets asset-list
                                      :signature signature
                                      :sig-algo sig-algo-code
                                      :public-key-hex pub-hex
                                      :exec-argv exec-argv))
                    (%spawn-image-dump dump-bin job-path)
                    (unless (sys:file-p outfile)
                      (%fail :dump-failed "outfile missing after image dump")))
               (ignore-errors (sys:remove-recursive job-dir)))))
          (t
           ;; Portable CLUNSEA package (payload + footer without host).
           (let* ((footer (encode-footer 0 (length payload) 0
                                         sig-algo-code (length signature)))
                  (bytes (%cat payload signature footer)))
             (sys:write-file-octets outfile bytes))))
        (list :outfile (or (sys:realpath outfile) outfile)
              :target target
              :entry entry-abs
              :modules (length modules)
              :assets (length asset-list)
              :build-id build-id
              :signed (and sign t)
              :digest (payload-digest-hex payload)
              :packaging (if native "image" "portable")
              :template (when native dump-bin))))))

(defun compile-all-targets (entry &key
                                    (outdir nil)
                                    (basename nil)
                                    (assets nil)
                                    (defines nil)
                                    (minify nil)
                                    (bytecode nil)
                                    (exec-argv nil)
                                    (sign nil)
                                    (private-key nil)
                                    (public-key nil)
                                    (sign-algo :ed25519)
                                    (cwd nil)
                                    (targets nil))
  "Compile ENTRY for every listed target. Native → image dump; others → portable."
  (let* ((cwd (or cwd (sys:current-directory)))
         (outdir (or outdir cwd))
         (base (or basename
                   (let ((b (sys:path-basename entry)))
                     (if (find #\. b)
                         (subseq b 0 (position #\. b :from-end t))
                         b))))
         (targets (or targets (all-four-targets)))
         (results '()))
    (dolist (tgt targets)
      (handler-case
          (let* ((norm (normalize-target tgt))
                 (out (sys:path-join outdir (concatenate 'string base "-" norm)))
                 (res (compile-executable
                       entry
                       :outfile out :target norm
                       :assets assets :defines defines
                       :minify minify :bytecode bytecode
                       :exec-argv exec-argv
                       :sign sign :private-key private-key
                       :public-key public-key :sign-algo sign-algo
                       :cwd cwd)))
            (push res results))
        (sfe-error (e)
          (push (list :outfile nil :target (ignore-errors (normalize-target tgt))
                      :error (format nil "~A" e)
                      :skipped t)
                results))))
    (nreverse results)))

;;; --- boot helpers ----------------------------------------------------------

(defun install-embedded-assets (assets)
  (clrhash *embedded-assets*)
  (dolist (a assets)
    (setf (gethash (car a) *embedded-assets*) (cdr a)))
  *embedded-assets*)

(defun embedded-asset (name)
  (gethash name *embedded-assets*))

(defun embedded-asset-text (name)
  (let ((oct (embedded-asset name)))
    (when oct (%utf8-string oct))))

(defun sea-boot-info (self-path)
  "Open SELF-PATH when it is a portable SEA package. Image SFEs use *sfe-image-mode*."
  (unless (and self-path (sys:file-p self-path) (sea-file-p self-path))
    (return-from sea-boot-info nil))
  (let* ((sea (open-sea self-path))
         (manifest (getf sea :manifest))
         (entry (%manifest-get manifest "entry"))
         (exec-argv (%manifest-get manifest "execArgv")))
    (list :sea sea
          :entry entry
          :modules (getf sea :modules)
          :assets (getf sea :assets)
          :exec-argv (when (and exec-argv (vectorp exec-argv))
                       (map 'list #'identity exec-argv))
          :footer (getf sea :footer)
          :manifest manifest)))

(defun materialize-modules (modules &optional (dir nil))
  "Write MODULES alist to DIR (temp when NIL). Return (values dir path-map)."
  (let* ((dir (or dir
                  (sys:make-temp-dir
                   (sys:path-join (sys:tmpdir) "clun-sfe-"))))
         (map (make-hash-table :test 'equal)))
    (dolist (m modules)
      (let* ((abs (car m))
             (src (cdr m))
             (base (sys:path-basename abs))
             (digest (subseq (%hex (%sha256 (%utf8 abs))) 0 8))
             (name (concatenate 'string digest "-" base))
             (out (sys:path-join dir name)))
        (sys:write-file-octets out (%utf8 src))
        (setf (gethash abs map) out)))
    (values dir map)))

(defun be-clun-mode-p ()
  "T when CLUN_BE_CLUN forces normal CLI (exceeds Bun BUN_BE_BUN)."
  (let ((v (sys:getenv "CLUN_BE_CLUN")))
    (and v (plusp (length v)) (not (string= v "0")))))

(defun image-sfe-p ()
  "T if this Lisp image is a dumped SFE application."
  (and *sfe-image-mode* *sfe-entry* t))

(defun verify-path (path &key public-key)
  "Verify either a portable SEA package or a dumped image SFE."
  (cond
    ((and path (sea-file-p path))
     (verify-sea path :public-key public-key))
    ((and path (sys:file-p path))
     ;; Ask the binary itself (image SFE).
     (let* ((out (make-string-output-stream))
            (err (make-string-output-stream))
            (proc (sb-ext:run-program path '("--sfe-verify")
                                      :wait t :output out :error err))
            (text (get-output-stream-string out))
            (code (sb-ext:process-exit-code proc)))
       (list :ok (eql code 0)
             :algo (if (search "algo=ED25519" text) :ed25519
                       (if (search "algo=NONE" text) :none :unknown))
             :signed (and (search "signed=T" text) t)
             :digest (let ((p (search "digest=" text)))
                       (when p
                         (let* ((s (+ p 7))
                                (e (or (position #\Space text :start s)
                                       (position #\Newline text :start s)
                                       (length text))))
                           (subseq text s e))))
             :error (when (not (eql code 0))
                      (get-output-stream-string err)))))
    (t (list :ok nil :error "not found"))))
