;;;; url.lisp — node:url (Phase 18 residual / Phase 47 slice).
;;;; Legacy parse/format/resolve + fileURLToPath/pathToFileURL over pure string
;;;; algorithms. Re-exports the realm's WHATWG URL + URLSearchParams (web-url.lisp).
;;;; Documented Partial gaps: IDNA/punycode (domainTo* ASCII-only), resolveObject,
;;;; urlToHttpOptions, URLPattern, and full legacy edge-case parity with Node.

(in-package :clun.runtime)

;;; --- helpers ----------------------------------------------------------------

(defun %url-null () eng:+null+)

(defun %url-set (o k v)
  "Set data property K on O; NIL V becomes JS null (Node parse fields)."
  (eng:data-prop o k (if (null v) (%url-null) v)))

(defun %url-ensure-colon (protocol)
  "Normalize a protocol to include a trailing colon, or NIL."
  (when protocol
    (if (and (plusp (length protocol))
             (char= (char protocol (1- (length protocol))) #\:))
        protocol
        (concatenate 'string protocol ":"))))

(defun %url-special-slash-p (proto)
  "Protocols that Node treats as slash-using (http-family + file + gopher)."
  (and proto
       (member (%url-ensure-colon proto)
               '("http:" "https:" "ftp:" "gopher:" "file:" "ws:" "wss:")
               :test #'string-equal)))

(defun %url-protocol-end (s)
  "Index of ':' ending a scheme, or NIL. Scheme = ALPHA (ALPHA / DIGIT / + / - / .)*"
  (when (and (plusp (length s)) (alpha-char-p (char s 0)))
    (loop for i from 1 below (length s)
          for c = (char s i)
          do (cond ((char= c #\:) (return i))
                   ((not (or (alphanumericp c) (find c "+-." :test #'char=)))
                    (return nil)))
          finally (return nil))))

(defun %url-split-hash-query (rest)
  "Split REST into (values path query-no-? hash-no-#). Query/hash are NIL if absent."
  (let* ((hash-i (position #\# rest))
         (before-hash (if hash-i (subseq rest 0 hash-i) rest))
         (hash (when hash-i (subseq rest (1+ hash-i))))
         (q-i (position #\? before-hash))
         (path (if q-i (subseq before-hash 0 q-i) before-hash))
         (query (when q-i (subseq before-hash (1+ q-i)))))
    (values path query hash)))

(defun %url-parse-host-auth (authority)
  "Parse AUTHORITY (no leading //) into (values auth hostname port host).
IPv6 hosts appear as [::1] in host and ::1 in hostname."
  (let* ((at (position #\@ authority :from-end t))
         (auth (when at (subseq authority 0 at)))
         (hostpart (if at (subseq authority (1+ at)) authority))
         (hostname nil) (port nil) (host nil))
    (cond
      ((and (plusp (length hostpart)) (char= (char hostpart 0) #\[))
       (let ((close (position #\] hostpart)))
         (if close
             (let ((rest (subseq hostpart (1+ close))))
               (setf hostname (subseq hostpart 1 close)
                     port (when (and (>= (length rest) 2) (char= (char rest 0) #\:))
                            (subseq rest 1))
                     host (if port
                              (concatenate 'string "[" hostname "]:" port)
                              (concatenate 'string "[" hostname "]"))))
             (setf hostname hostpart host hostpart))))
      (t
       (let ((colon (position #\: hostpart :from-end t)))
         (if (and colon
                  (plusp (- (length hostpart) (1+ colon)))
                  (every #'digit-char-p (subseq hostpart (1+ colon))))
             (setf hostname (subseq hostpart 0 colon)
                   port (subseq hostpart (1+ colon))
                   host hostpart)
             (setf hostname (when (plusp (length hostpart)) hostpart)
                   host (when (plusp (length hostpart)) hostpart))))))
    (values auth hostname port host)))

(defstruct (%url-parts (:conc-name %up-))
  protocol slashes auth host hostname port pathname search query hash path href)

(defun %url-format-parts (p &optional query-obj)
  "Serialize %url-parts like Node url.format."
  (with-output-to-string (out)
    (let* ((proto (%url-ensure-colon (%up-protocol p)))
           (slashes (or (%up-slashes p) (%url-special-slash-p proto)))
           (hostname (%up-hostname p))
           (port (%up-port p))
           (host (or (%up-host p)
                     (cond ((and hostname port)
                            (concatenate 'string hostname ":"
                                         (if (stringp port) port (princ-to-string port))))
                           (hostname hostname)
                           (t nil))))
           (auth (%up-auth p))
           (pathname (or (%up-pathname p) ""))
           (search (cond ((%up-search p) (%up-search p))
                         (query-obj
                          (concatenate 'string "?" (%qs-stringify query-obj "&" "=")))
                         ((and (%up-query p) (stringp (%up-query p)))
                          (let ((q (%up-query p)))
                            (if (and (plusp (length q)) (char= (char q 0) #\?))
                                q (concatenate 'string "?" q))))
                         (t nil)))
           (hash (%up-hash p)))
      (when proto (write-string proto out))
      (when slashes (write-string "//" out))
      (when (and auth host) (write-string auth out) (write-char #\@ out))
      (when host (write-string host out))
      (when (and host (plusp (length pathname)) (not (char= (char pathname 0) #\/)))
        (write-char #\/ out))
      (write-string pathname out)
      (when search
        (if (and (plusp (length search)) (char= (char search 0) #\?))
            (write-string search out)
            (progn (write-char #\? out) (write-string search out))))
      (when hash
        (if (and (plusp (length hash)) (char= (char hash 0) #\#))
            (write-string hash out)
            (progn (write-char #\# out) (write-string hash out)))))))

(defun %url-parts-from-string (s &optional slashes-denote-host)
  "Legacy url.parse core → %url-parts."
  (let ((parts (make-%url-parts :href (or s ""))))
    (when (or (null s) (string= s ""))
      (return-from %url-parts-from-string parts))
    (let* ((proto-end (%url-protocol-end s))
           (protocol (when proto-end
                       (string-downcase (subseq s 0 (1+ proto-end)))))
           (rest (if proto-end (subseq s (1+ proto-end)) s))
           (slashes nil)
           (auth nil) (host nil) (hostname nil) (port nil)
           (pathname nil) (search nil) (query nil) (hash nil) (path nil)
           (consumed nil))
      ;; //authority...
      (when (and (>= (length rest) 2)
                 (char= (char rest 0) #\/) (char= (char rest 1) #\/)
                 (or protocol slashes-denote-host (%url-special-slash-p protocol)))
        (setf slashes t)
        (let* ((after (subseq rest 2))
               (path-start (or (position-if (lambda (c) (find c "/?#")) after)
                               (length after)))
               (authority (subseq after 0 path-start))
               (tail (subseq after path-start)))
          (multiple-value-setq (auth hostname port host)
            (%url-parse-host-auth authority))
          (setf rest tail)))
      ;; non-slash schemes: mailto:user@host, data:text/plain,hi (best-effort)
      (when (and protocol (not slashes) (plusp (length rest)))
        (multiple-value-bind (path* query* hash*) (%url-split-hash-query rest)
          (let ((at (position #\@ path*)))
            (cond
              (at
               (setf auth (subseq path* 0 at)
                     host (subseq path* (1+ at))
                     hostname host
                     query query*
                     hash hash*
                     consumed t))
              (t
               ;; data:media/type,data  → host=media pathname=/type,data (Node quirk)
               (let ((slash (position #\/ path*)))
                 (if slash
                     (setf host (subseq path* 0 slash)
                           hostname host
                           pathname (concatenate 'string "/" (subseq path* (1+ slash)))
                           query query*
                           hash hash*
                           consumed t)
                     (setf pathname (when (plusp (length path*)) path*)
                           query query*
                           hash hash*
                           consumed t)))))))
        (when consumed (setf rest "")))
      (when (plusp (length rest))
        (multiple-value-bind (path* query* hash*) (%url-split-hash-query rest)
          (setf pathname (if (plusp (length path*)) path* nil)
                query query*
                hash hash*)))
      ;; path-only relative / absolute without scheme
      (when (and (null protocol) (not slashes) (null pathname)
                 (plusp (length s)))
        (multiple-value-bind (path* query* hash*) (%url-split-hash-query s)
          (setf pathname (if (plusp (length path*)) path* nil)
                query query*
                hash hash*)))
      ;; special schemes always expose a path of at least "/"
      (when (and slashes protocol (%url-special-slash-p protocol) (null pathname))
        (setf pathname "/"))
      (when query (setf search (concatenate 'string "?" query)))
      (when hash (setf hash (concatenate 'string "#" hash)))
      (setf path (cond ((and pathname search) (concatenate 'string pathname search))
                       (pathname pathname)
                       (search search)
                       (t nil)))
      (setf (%up-protocol parts) protocol
            (%up-slashes parts) slashes
            (%up-auth parts) auth
            (%up-host parts) host
            (%up-hostname parts) hostname
            (%up-port parts) port
            (%up-pathname parts) pathname
            (%up-search parts) search
            (%up-query parts) query
            (%up-hash parts) hash
            (%up-path parts) path)
      (when (and protocol slashes)
        (setf (%up-href parts) (%url-format-parts parts)))
      parts)))

(defun %url-parts->js (parts parse-qs)
  (let ((o (eng:new-object)))
    (labels ((s (k v) (%url-set o k v))
             (b (k v) (eng:data-prop o k (if v eng:+true+ eng:+false+))))
      (s "protocol" (%up-protocol parts))
      (if (%up-slashes parts) (b "slashes" t) (s "slashes" nil))
      (s "auth" (%up-auth parts))
      (s "host" (%up-host parts))
      (s "hostname" (%up-hostname parts))
      (s "port" (%up-port parts))
      (s "pathname" (%up-pathname parts))
      (s "search" (%up-search parts))
      (if (and parse-qs (%up-query parts))
          (eng:data-prop o "query" (%qs-parse (%up-query parts) "&" "="))
          (s "query" (%up-query parts)))
      (s "hash" (%up-hash parts))
      (s "path" (%up-path parts))
      (eng:data-prop o "href" (or (%up-href parts) ""))
      o)))

;;; --- resolve ----------------------------------------------------------------

(defun %url-dirname-path (pathname)
  "Directory of a URL pathname (posix-ish). Trailing-slash paths keep themselves as dir."
  (cond ((or (null pathname) (string= pathname "")) "")
        ((char= (char pathname (1- (length pathname))) #\/) pathname)
        (t
         (let ((slash (position #\/ pathname :from-end t)))
           (if slash (subseq pathname 0 (1+ slash)) "")))))

(defun %url-join-relative (base-path rel-path)
  "Join BASE-PATH (a dirname, often with trailing /) and REL-PATH; normalize . and .."
  (let* ((combined (concatenate 'string (or base-path "") (or rel-path "")))
         (abs (and (plusp (length combined)) (char= (char combined 0) #\/)))
         (segs (%split combined #\/))
         (norm (%path-normalize-string segs (not abs)))
         (joined (format nil "~{~a~^/~}" norm)))
    (cond ((and abs (string= joined "")) "/")
          ((and abs (plusp (length joined)) (not (char= (char joined 0) #\/)))
           (concatenate 'string "/" joined))
          ((string= joined "") (if abs "/" ""))
          (t joined))))

(defun %url-resolve (from to)
  (let* ((rel (%url-parts-from-string to t))
         (base (%url-parts-from-string from t)))
    ;; absolute relative URL with its own protocol
    (when (and (%up-protocol rel)
               (or (%up-slashes rel)
                   (and (%up-protocol base)
                        (not (string-equal (%up-protocol rel) (%up-protocol base))))
                   (null (%up-protocol base))))
      (return-from %url-resolve (%url-format-parts rel)))
    ;; protocol-relative //host/...
    (when (and (null (%up-protocol rel)) (%up-slashes rel) (%up-host rel))
      (setf (%up-protocol rel) (%up-protocol base))
      (return-from %url-resolve (%url-format-parts rel)))
    (let ((out (make-%url-parts
                :protocol (or (%up-protocol rel) (%up-protocol base))
                :slashes (or (%up-slashes base) (%up-slashes rel)
                             (%url-special-slash-p
                              (or (%up-protocol rel) (%up-protocol base))))
                :auth (%up-auth base)
                :host (%up-host base)
                :hostname (%up-hostname base)
                :port (%up-port base)
                :pathname (%up-pathname base)
                :search nil :query nil :hash nil :path nil :href nil)))
      (cond
        ((and (%up-pathname rel) (plusp (length (%up-pathname rel)))
              (char= (char (%up-pathname rel) 0) #\/))
         (setf (%up-pathname out) (%up-pathname rel)))
        ((%up-pathname rel)
         (setf (%up-pathname out)
               (%url-join-relative (%url-dirname-path (%up-pathname base))
                                   (%up-pathname rel)))))
      (if (%up-search rel)
          (setf (%up-search out) (%up-search rel)
                (%up-query out) (%up-query rel))
          (unless (%up-pathname rel)
            (setf (%up-search out) (%up-search base)
                  (%up-query out) (%up-query base))))
      (if (%up-hash rel)
          (setf (%up-hash out) (%up-hash rel))
          (unless (or (%up-pathname rel) (%up-search rel))
            (setf (%up-hash out) (%up-hash base))))
      (%url-format-parts out))))

;;; --- file URL helpers -------------------------------------------------------

(defun %url-path-encode (path)
  "Percent-encode a filesystem path for file:// (keep / and unreserved; encode the rest)."
  (with-output-to-string (out)
    (loop for c across path do
      (let ((code (char-code c)))
        (if (or (char= c #\/)
                (char<= #\A c #\Z) (char<= #\a c #\z) (char<= #\0 c #\9)
                (find c "-._~" :test #'char=))
            (write-char c out)
            (if (< code 128)
                (format out "%~2,'0X" code)
                (dolist (b (%utf8-bytes code)) (format out "%~2,'0X" b))))))))

(defun %node-path-to-file-url-href (path)
  (let* ((p (->str path))
         (abs (if (and (plusp (length p)) (char= (char p 0) #\/)) p
                  (clun.sys:path-join (clun.sys:pathname->native (truename ".")) p))))
    (concatenate 'string "file://" (%url-path-encode abs))))

(defun %node-file-url-to-path (v)
  (let ((s (cond
             ((eng:js-string-p v) v)
             ((eng:js-object-p v)
              (let ((href (eng:js-get v "href")))
                (if (eng:js-string-p href) href (->str v))))
             (t (->str v)))))
    (%file-url-to-path s)))

(defun %node-path-to-file-url (path)
  "Return a WHATWG URL instance for PATH (Node returns URL, not a bare string)."
  (let* ((href (%node-path-to-file-url-href path))
         (ctor (eng:js-get (eng:realm-global eng:*realm*) "URL")))
    (if (eng:callable-p ctor)
        (eng:js-construct ctor (list href))
        href)))

(defun %domain-ascii (domain)
  "ASCII-only identity lowercasing; non-ASCII → empty (IDNA unsupported)."
  (let ((s (->str domain)))
    (if (some (lambda (c) (>= (char-code c) 128)) s)
        ""
        (string-downcase s))))

;;; --- parse / format from JS values ------------------------------------------

(defun %url-parse-js (url-str parse-qs slashes-denote-host)
  (%url-parts->js
   (%url-parts-from-string (->str url-str) (eng:js-truthy slashes-denote-host))
   (eng:js-truthy parse-qs)))

(defun %url-format-js (obj)
  (cond
    ((eng:js-string-p obj) obj)
    ((not (eng:js-object-p obj)) (->str obj))
    (t
     (labels ((g (k)
                (let ((v (eng:js-get obj k)))
                  (cond ((undef-p v) nil)
                        ((eng:js-null-p v) nil)
                        ((eng:js-boolean-p v) (eng:js-truthy v))
                        ((eng:js-number-p v) (eng:to-string v))
                        ((eng:js-string-p v) v)
                        (t v)))))
       (let* ((query-val (eng:js-get obj "query"))
              (query-obj (when (and (eng:js-object-p query-val)
                                    (not (eng:js-string-p query-val)))
                           query-val))
              (parts (make-%url-parts
                      :protocol (%url-ensure-colon (g "protocol"))
                      :slashes (let ((s (eng:js-get obj "slashes")))
                                 (cond ((undef-p s)
                                        (%url-special-slash-p (g "protocol")))
                                       (t (eng:js-truthy s))))
                      :auth (g "auth")
                      :host (g "host")
                      :hostname (g "hostname")
                      :port (g "port")
                      :pathname (or (g "pathname") "")
                      :search (g "search")
                      :query (if query-obj nil (g "query"))
                      :hash (g "hash"))))
         (%url-format-parts parts query-obj))))))

;;; --- module builder ---------------------------------------------------------

(defun build-node-url ()
  (let ((o (eng:new-object))
        (g (eng:realm-global eng:*realm*)))
    (labels ((m (name arity fn) (eng:install-method o name arity fn)))
      (m "parse" 3
         (lambda (this args) (declare (ignore this))
           (%url-parse-js (a args 0) (a args 1) (a args 2))))
      (m "format" 1
         (lambda (this args) (declare (ignore this))
           (%url-format-js (a args 0))))
      (m "resolve" 2
         (lambda (this args) (declare (ignore this))
           (%url-resolve (->str (a args 0)) (->str (a args 1)))))
      (m "fileURLToPath" 1
         (lambda (this args) (declare (ignore this))
           (%node-file-url-to-path (a args 0))))
      (m "pathToFileURL" 1
         (lambda (this args) (declare (ignore this))
           (%node-path-to-file-url (a args 0))))
      (m "domainToASCII" 1
         (lambda (this args) (declare (ignore this))
           (%domain-ascii (a args 0))))
      (m "domainToUnicode" 1
         (lambda (this args) (declare (ignore this))
           ;; Without IDNA, unicode form equals the ASCII form for ASCII hosts.
           (%domain-ascii (a args 0))))
      ;; re-export WHATWG constructors from the realm global
      (let ((url (eng:js-get g "URL"))
            (usp (eng:js-get g "URLSearchParams")))
        (when (eng:callable-p url) (eng:data-prop o "URL" url))
        (when (eng:callable-p usp) (eng:data-prop o "URLSearchParams" usp)))
      o)))

(register-node-builtin "url" #'build-node-url)
