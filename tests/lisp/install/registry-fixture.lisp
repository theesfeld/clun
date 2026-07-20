;;;; registry-fixture.lisp — an in-process npm registry for hermetic install tests (Phase 21,
;;;; §3.5). Reuses the Phase-16 tcp-listen + Phase-17 request parser to serve a hand-built
;;;; registry described by tests/fixtures/registry/packages.json against the checked-in
;;;; tarballs/. dist.integrity is computed from the REAL tarball bytes at startup (ironclad
;;;; sha512 + cl-base64) and dist.tarball is templated to the server's own base URL, so nothing
;;;; is hardcoded to a port. Metadata carries an ETag (→ 304 on If-None-Match) and, when the
;;;; server is started :gzip t, is gzip-encoded for Accept-Encoding: gzip.
;;;;
;;;; No deflate encoder is vendored (chipz decompresses only), so gzip here emits DEFLATE
;;;; STORED blocks (zero compression) wrapped in a valid gzip envelope — chipz round-trips it
;;;; and Content-Encoding: gzip is honest. This is test-only (the registry CLIENT never encodes).

(in-package :clun-test)

;;; --- fixture file locations -------------------------------------------------

(defun %registry-fixture-dir ()
  (namestring (merge-pathnames "tests/fixtures/registry/" (asdf:system-source-directory :clun))))

(defun %read-file-bytes (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((buf (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence buf s) buf)))

(defun %tgz-filename (name version)
  "name+version → the checked-in tarball basename (mirrors scripts/gen-registry-fixture.sh:
strip `@`, `/`→`-`)."
  (concatenate 'string (substitute #\- #\/ (remove #\@ name)) "-" version ".tgz"))

;;; --- integrity + shasum -----------------------------------------------------

(defun tarball-integrity (bytes)
  "SRI `sha512-<base64>` of BYTES (npm dist.integrity)."
  (concatenate 'string "sha512-"
               (cl-base64:usb8-array-to-base64-string (ironclad:digest-sequence :sha512 bytes))))

(defun tarball-shasum (bytes)
  "The sha1 hex of BYTES (npm dist.shasum)."
  (ironclad:byte-array-to-hex-string (ironclad:digest-sequence :sha1 bytes)))

;;; --- stored-block gzip encoder (test-only) ----------------------------------

(defun %u16le (n) (vector (logand n #xff) (logand (ash n -8) #xff)))
(defun %u32le (n) (vector (logand n #xff) (logand (ash n -8) #xff)
                          (logand (ash n -16) #xff) (logand (ash n -24) #xff)))

(defun gzip-stored (data)
  "Wrap DATA (a byte vector) in a gzip stream of DEFLATE stored blocks (BTYPE 00). Valid gzip:
chipz:decompress :gzip round-trips it. CRC32 (ironclad) + ISIZE are little-endian trailers."
  (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
        (n (length data)))
    (flet ((emit (seq) (loop for b across seq do (vector-push-extend b out))))
      (emit #(#x1f #x8b #x08 #x00 #x00 #x00 #x00 #x00 #x00 #xff)) ; gzip header, OS=unknown
      (if (zerop n)
          (progn (emit #(#x01)) (emit (%u16le 0)) (emit (%u16le #xffff))) ; one empty final block
          (loop with pos = 0
                for remaining = (- n pos)
                for len = (min remaining 65535)
                for finalp = (<= remaining 65535)
                do (emit (vector (if finalp 1 0)))           ; BFINAL bit, BTYPE=00, byte-aligned
                   (emit (%u16le len))
                   (emit (%u16le (logand (lognot len) #xffff)))
                   (loop for i from pos below (+ pos len) do (vector-push-extend (aref data i) out))
                   (incf pos len)
                until finalp))
      ;; CRC32 (ironclad returns 4 big-endian bytes) → little-endian; ISIZE = n mod 2^32.
      (emit (reverse (ironclad:digest-sequence :crc32 data)))
      (emit (%u32le (logand n #xffffffff))))
    (coerce out '(simple-array (unsigned-byte 8) (*)))))

;;; --- minimal JSON emit (controlled fixture data) ----------------------------

(defun %json-str (s)
  (with-output-to-string (o)
    (write-char #\" o)
    (loop for c across s do
      (case c (#\" (write-string "\\\"" o)) (#\\ (write-string "\\\\" o))
              (#\Newline (write-string "\\n" o)) (#\Return (write-string "\\r" o))
              (#\Tab (write-string "\\t" o)) (t (write-char c o))))
    (write-char #\" o)))

(defun %json-obj (pairs)
  "PAIRS = list of (key-string . value-already-rendered-string). → `{\"k\":v,...}`."
  (with-output-to-string (o)
    (write-char #\{ o)
    (loop for (k . v) in pairs for first = t then nil
          do (unless first (write-char #\, o))
             (write-string (%json-str k) o) (write-char #\: o) (write-string v o))
    (write-char #\} o)))

(defun %render-string-map (alist)
  "alist of (string . string) → JSON object of string values (dependencies/engines/bin)."
  (%json-obj (loop for (k . v) in alist collect (cons k (%json-str v)))))

;;; --- registry model (from the manifest) -------------------------------------

(defstruct fixture-registry
  base-url                              ; e.g. "http://127.0.0.1:PORT"
  (metadata (make-hash-table :test 'equal))  ; package name -> metadata JSON string
  (etags (make-hash-table :test 'equal))     ; package name -> ETag string
  (tarballs (make-hash-table :test 'equal)))  ; filename -> bytes

(defun %manifest-versions (pkg-obj)
  (let ((v (sys:jget pkg-obj "versions"))) (if (vectorp v) (coerce v 'list) '())))

(defun %alist->pairs (v)
  (cond ((eq v :empty-object) '()) ((sys:jobject-p v) v) (t '())))

(defun build-package-metadata (registry pkg-obj)
  "Render one package's abbreviated metadata JSON, computing dist from the real tarball bytes
and templating dist.tarball to REGISTRY's base URL. Registers each tarball's bytes for serving."
  (let* ((name (sys:jget pkg-obj "name"))
         (dist-tags (loop for (tag . ver) in (%alist->pairs (sys:jget pkg-obj "dist-tags"))
                          collect (cons tag (%json-str ver))))
         (versions
           (loop for vobj in (%manifest-versions pkg-obj)
                 for ver = (sys:jget vobj "version")
                 for file = (%tgz-filename name ver)
                 for bytes = (%read-file-bytes (merge-pathnames (concatenate 'string "tarballs/" file)
                                                                (%registry-fixture-dir)))
                 do (setf (gethash file (fixture-registry-tarballs registry)) bytes)
                 collect
                 (cons ver
                       (%json-obj
                        (append
                         (list (cons "name" (%json-str name))
                               (cons "version" (%json-str ver))
                               (cons "dependencies"
                                     (%render-string-map
                                      (loop for (k . val) in (%alist->pairs (sys:jget vobj "dependencies"))
                                            collect (cons k val)))))
                         (let ((bin (sys:jget vobj "bin")))
                           (when (and bin (not (eq bin :empty-object)))
                             (list (cons "bin"
                                         (%render-string-map
                                          (loop for (k . val) in (%alist->pairs bin) collect (cons k val)))))))
                         (list (cons "dist"
                                     (%json-obj
                                      (list (cons "tarball"
                                                  (%json-str (format nil "~a/tarballs/~a"
                                                                     (fixture-registry-base-url registry) file)))
                                            (cons "shasum" (%json-str (tarball-shasum bytes)))
                                            (cons "integrity" (%json-str (tarball-integrity bytes)))))))))))))
    (%json-obj
     (list (cons "name" (%json-str name))
           (cons "dist-tags" (%json-obj dist-tags))
           (cons "modified" (%json-str "2020-01-01T00:00:00.000Z"))
           (cons "versions" (%json-obj versions))))))

(defun load-fixture-registry (base-url)
  "Build a fixture-registry (metadata strings + tarball bytes + ETags) from packages.json for
the given BASE-URL (…no trailing slash)."
  (let* ((manifest (sys:parse-json (sys:read-file-string
                                    (merge-pathnames "packages.json" (%registry-fixture-dir)))))
         (packages (let ((p (sys:jget manifest "packages"))) (if (vectorp p) (coerce p 'list) '())))
         (reg (make-fixture-registry :base-url base-url)))
    (dolist (pkg packages reg)
      (let* ((name (sys:jget pkg "name"))
             (json (build-package-metadata reg pkg)))
        (setf (gethash name (fixture-registry-metadata reg)) json)
        (setf (gethash name (fixture-registry-etags reg))
              (format nil "\"~a\"" (subseq (ironclad:byte-array-to-hex-string
                                            (ironclad:digest-sequence :sha1
                                             (sb-ext:string-to-octets json :external-format :utf-8)))
                                           0 16)))))))

;;; --- request routing --------------------------------------------------------

(defun %hex-digit-p (c) (digit-char-p c 16))

(defun %url-decode (s)
  "Percent-decode S (enough for `%2F` in a scoped metadata path). A malformed escape (a `%`
not followed by two hex digits, or at the end of the string) is emitted LITERALLY rather than
signalled — a network-visible input must never throw a raw parse error into the loop thread."
  (with-output-to-string (o)
    (let ((i 0) (n (length s)))
      (loop while (< i n) do
        (let ((c (char s i)))
          (if (and (char= c #\%) (<= (+ i 3) n)
                   (%hex-digit-p (char s (+ i 1))) (%hex-digit-p (char s (+ i 2))))
              (progn (write-char (code-char (parse-integer s :start (1+ i) :end (+ i 3) :radix 16)) o)
                     (incf i 3))
              (progn (write-char c o) (incf i))))))))

(defun %http-response (status body &key (content-type "application/json") etag content-encoding)
  "Serialize an HTTP/1.1 response with an explicit Content-Length + Connection: close. BODY is a
byte vector."
  (let ((head (with-output-to-string (h)
                (format h "HTTP/1.1 ~d ~a~c~c" status
                        (case status (200 "OK") (304 "Not Modified") (404 "Not Found") (t "OK"))
                        #\Return #\Newline)
                (format h "Content-Type: ~a~c~c" content-type #\Return #\Newline)
                (when etag (format h "ETag: ~a~c~c" etag #\Return #\Newline))
                (when content-encoding (format h "Content-Encoding: ~a~c~c" content-encoding #\Return #\Newline))
                (format h "Content-Length: ~d~c~c" (length body) #\Return #\Newline)
                (format h "Connection: close~c~c" #\Return #\Newline)
                (format h "~c~c" #\Return #\Newline))))
    (concatenate '(vector (unsigned-byte 8))
                 (sb-ext:string-to-octets head :external-format :latin-1) body)))

(defun %route (reg req gzip)
  "Return the response bytes for one parsed request REQ against fixture-registry REG."
  (let* ((target (net:hr-target req))
         (qpos (position #\? target))
         (path (if qpos (subseq target 0 qpos) target))
         (headers (net:hr-headers req))
         (method (string-upcase (or (net:hr-method req) "GET"))))
    (cond
      ;; Issue #262: publish PUT /<encoded-name> with Bearer auth + attach document.
      ((and (string= method "PUT") (> (length path) 1))
       (let* ((name (%url-decode (subseq path 1)))
              (auth (or (net:%header headers "authorization") ""))
              (ok-auth (and (>= (length auth) 7)
                            (string-equal "Bearer " auth :end2 7)
                            (plusp (length (subseq auth 7)))))
              (body (or (net:hr-body req)
                        (make-array 0 :element-type '(unsigned-byte 8)))))
         (cond
           ((not ok-auth)
            (%http-response 401 (sb-ext:string-to-octets
                                 "{\"error\":\"unauthorized\"}" :external-format :utf-8)))
           ((zerop (length body))
            (%http-response 400 (sb-ext:string-to-octets
                                 "{\"error\":\"empty body\"}" :external-format :utf-8)))
           (t
            ;; Accept and remember metadata so a subsequent GET succeeds.
            (let ((text (handler-case
                            (sb-ext:octets-to-string body :external-format :utf-8)
                          (error () "{}"))))
              (setf (gethash name (fixture-registry-metadata reg)) text
                    (gethash name (fixture-registry-etags reg))
                    (format nil "\"pub-~a\"" (sxhash text)))
              (%http-response 201 (sb-ext:string-to-octets
                                   (format nil "{\"ok\":true,\"id\":~s}" name)
                                   :external-format :utf-8)))))))
      ;; tarball: GET /tarballs/<file>
      ((and (string= method "GET")
            (> (length path) 10) (string= "/tarballs/" path :end2 10))
       (let* ((file (subseq path 10)) (bytes (gethash file (fixture-registry-tarballs reg))))
         (if bytes
             (%http-response 200 bytes :content-type "application/octet-stream")
             (%http-response 404 (sb-ext:string-to-octets "not found" :external-format :latin-1)
                             :content-type "text/plain"))))
      ;; metadata: GET /<encoded-name>
      ((and (string= method "GET") (> (length path) 1))
       (let* ((name (%url-decode (subseq path 1)))
              (json (gethash name (fixture-registry-metadata reg)))
              (etag (gethash name (fixture-registry-etags reg))))
         (cond
           ((null json)
            (%http-response 404 (sb-ext:string-to-octets
                                 (format nil "{\"error\":\"Not found: ~a\"}" name) :external-format :utf-8)))
           ((let ((inm (net:%header headers "if-none-match"))) (and inm (string= inm etag)))
            (%http-response 304 (make-array 0 :element-type '(unsigned-byte 8)) :etag etag))
           (t
            (let ((raw (sb-ext:string-to-octets json :external-format :utf-8))
                  (want-gzip (let ((ae (net:%header headers "accept-encoding")))
                               (and gzip ae (search "gzip" ae)))))
              (if want-gzip
                  (%http-response 200 (gzip-stored raw) :etag etag :content-encoding "gzip")
                  (%http-response 200 raw :etag etag)))))))
      (t (%http-response 404 (sb-ext:string-to-octets "no package" :external-format :latin-1)
                         :content-type "text/plain")))))

(defun start-fixture-registry (loop &key (gzip nil))
  "Start the fixture registry on 127.0.0.1:0 (an ephemeral port) on LOOP. Returns
(values listener fixture-registry base-url). The caller drives LOOP and closes the listener."
  ;; Bind first to learn the port, then build the base URL + registry model, then serve.
  (let* ((box (list nil nil))                 ; (reg gzip) shared with the connection handler
         (listener (net:tcp-listen loop "127.0.0.1" 0
                     :on-connection
                     (lambda (tcp)
                       (let ((parser (net:make-http-parser)))
                         (setf (net::tcp-on-data tcp)
                               (lambda (c data)
                                 ;; A malformed request must produce a 400 (or a dropped
                                 ;; connection) — never a raw condition escaping onto the loop
                                 ;; thread, which would unwind run-loop (§6). Route dispatch is
                                 ;; wrapped so any surprise still yields a clean close.
                                 (handler-case
                                     (multiple-value-bind (ev req) (net:parser-feed parser data)
                                       (case ev
                                         (:request
                                          (net:tcp-write c (%route (first box) req (second box)))
                                          (net:tcp-shutdown c))
                                         (:error
                                          (net:tcp-write c (%http-response
                                                            400 (sb-ext:string-to-octets "bad request"
                                                                                         :external-format :latin-1)
                                                            :content-type "text/plain"))
                                          (net:tcp-shutdown c))
                                         (t nil)))       ; :need-more — await more bytes
                                   (error ()
                                     (ignore-errors (net:tcp-shutdown c))))))))))
         (port (net:listener-port listener))
         (base-url (format nil "http://127.0.0.1:~d" port))
         (reg (load-fixture-registry base-url)))
    (setf (first box) reg (second box) gzip)
    (values listener reg base-url)))
