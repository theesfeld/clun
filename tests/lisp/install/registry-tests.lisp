;;;; registry-tests.lisp — Phase 21 gate: the registry client against the in-process fixture
;;;; (registry-fixture.lisp). Hermetic (loopback only): metadata round-trips for a plain and a
;;;; scoped package, a gzip response decodes, an ETag yields 304 + reuse, a 404 is a clean
;;;; package-not-found, and every served tarball's bytes verify against its advertised
;;;; dist.integrity (sha512). The client's transport is the Phase-18 reactor HTTP client.

(in-package :clun-test)

(defmacro with-registry-fixture ((loop reg base &key gzip) &body setup)
  "Create a :workers-0 loop, start the fixture registry, run SETUP (which issues async requests
and calls (lp:loop-stop LOOP) on settlement), drive the loop to quiescence, then tear down.
Assertions go AFTER this form, on variables SETUP closed over."
  (let ((lst (gensym "LISTENER")))
    `(let ((,loop (lp:make-event-loop :workers 0)))
       (unwind-protect
            (multiple-value-bind (,lst ,reg ,base) (start-fixture-registry ,loop :gzip ,gzip)
              (declare (ignorable ,reg))
              (unwind-protect (progn ,@setup (lp:run-loop ,loop))
                (net:listener-close ,lst)))
         (lp:destroy-event-loop ,loop)))))

;;; --- (1) plain metadata round-trip ------------------------------------------

(define-test registry/metadata-round-trip
  (let (md err)
    (with-registry-fixture (loop reg base)
      (reg:fetch-metadata-async loop "left-pad" :override base :retries 0
        :on-ok  (lambda (v) (setf md v) (lp:loop-stop loop))
        :on-err (lambda (c) (setf err c) (lp:loop-stop loop))))
    (false err)
    (true (reg:pkg-metadata-p md))
    (is string= "left-pad" (reg:md-name md))
    (is string= "1.3.0" (reg:metadata-latest md))
    (is = 3 (length (reg:metadata-version-strings md)))
    (let ((vm (reg:metadata-version md "1.3.0")))
      (true vm)
      (true (search "sha512-" (or (reg:vm-dist-integrity vm) "")))
      (true (search "/tarballs/left-pad-1.3.0.tgz" (or (reg:vm-dist-tarball vm) ""))))))

;;; --- (2) scoped package (exercises %2F end-to-end) --------------------------

(define-test registry/scoped-metadata
  (let (md err)
    (with-registry-fixture (loop reg base)
      (reg:fetch-metadata-async loop "@scope/widget" :override base :retries 0
        :on-ok  (lambda (v) (setf md v) (lp:loop-stop loop))
        :on-err (lambda (c) (setf err c) (lp:loop-stop loop))))
    (false err)
    (is string= "@scope/widget" (reg:md-name md))
    (let ((vm (reg:metadata-version md "1.0.0")))
      (true vm)
      (is string= "^1.1.0" (cdr (assoc "left-pad" (reg:vm-dependencies vm) :test #'string=))))))

;;; --- (3) gzip response decodes (server gzips; client chipz-decodes) ---------

(define-test registry/gzip-encoder-round-trips
  ;; the stored-block gzip encoder ⟷ chipz, across an empty, a small, and a >64KiB payload
  (dolist (n (list 0 5 100000))
    (let* ((data (let ((v (make-array n :element-type '(unsigned-byte 8))))
                   (dotimes (i n v) (setf (aref v i) (mod (* i 7) 256)))))
           (round-trip (chipz:decompress nil :gzip (gzip-stored data))))
      (is = n (length round-trip) "gzip round-trip length for n=~d" n)
      (is equalp data (coerce round-trip '(simple-array (unsigned-byte 8) (*)))
          "gzip round-trip bytes for n=~d" n))))

(define-test registry/gzip-response-decodes
  ;; a RAW request to the gzip fixture: the response is Content-Encoding: gzip, and the HTTP
  ;; client transparently gunzips it, so the (already-decoded) body parses to real metadata.
  (let (enc md err)
    (with-registry-fixture (loop reg base :gzip t)
      (multiple-value-bind (h p) (reg:parse-registry-base base)
        (net:http-request-async loop :host h :port p :method "GET" :path "/left-pad"
          :headers (list (cons "Accept" reg:*abbreviated-accept*))
          :on-response (lambda (resp)
                         (setf enc (net:%header (net:hres-headers resp) "content-encoding"))
                         (handler-case
                             (setf md (reg:parse-metadata (sb-ext:octets-to-string (net:hres-body resp)
                                                                                   :external-format :utf-8)))
                           (error (c) (setf err c)))
                         (lp:loop-stop loop))
          :on-error (lambda (c) (setf err c) (lp:loop-stop loop)))))
    (false err)
    (is string= "gzip" enc)                       ; the server really gzipped
    (true (reg:pkg-metadata-p md))                ; and the client decoded valid JSON
    (is string= "left-pad" (reg:md-name md))))

;;; --- (4) ETag → 304 + reuse -------------------------------------------------

(define-test registry/etag-304-not-modified
  (let (first-md etag second err)
    (with-registry-fixture (loop reg base)
      ;; first fetch gets metadata + an ETag; capture the fixture's ETag for the package.
      (setf etag (gethash "left-pad" (fixture-registry-etags reg)))
      (reg:fetch-metadata-async loop "left-pad" :override base :retries 0
        :on-ok (lambda (v)
                 (setf first-md v)
                 ;; second fetch WITH the ETag → the server answers 304, the client reports
                 ;; :not-modified (the caller then reuses its cached copy).
                 (reg:fetch-metadata-async loop "left-pad" :override base :retries 0 :etag etag
                   :on-ok  (lambda (w) (setf second w) (lp:loop-stop loop))
                   :on-err (lambda (c) (setf err c) (lp:loop-stop loop))))
        :on-err (lambda (c) (setf err c) (lp:loop-stop loop))))
    (false err)
    (true (reg:pkg-metadata-p first-md))
    (is eq :not-modified second)))

;;; --- (5) 404 → package-not-found --------------------------------------------

(define-test registry/not-found-is-clean-error
  (let (md err)
    (with-registry-fixture (loop reg base)
      (reg:fetch-metadata-async loop "does-not-exist" :override base :retries 0
        :on-ok  (lambda (v) (setf md v) (lp:loop-stop loop))
        :on-err (lambda (c) (setf err c) (lp:loop-stop loop))))
    (false md)
    (true (typep err 'reg:package-not-found))
    (is string= "does-not-exist" (reg:package-not-found-name err))))

;;; --- (6) tarball integrity ---------------------------------------------------

(define-test registry/tarball-bytes-verify-integrity
  ;; every served tarball's bytes hash to its advertised dist.integrity (the fixture computed
  ;; integrity from the SAME bytes it serves; this re-derives independently from the parsed doc).
  (let ((reg (load-fixture-registry "http://127.0.0.1:1")) (checked 0))
    (maphash (lambda (name json)
               (let ((md (reg:parse-metadata json)))
                 (dolist (ver (reg:metadata-version-strings md))
                   (let* ((vm (reg:metadata-version md ver))
                          (bytes (gethash (%tgz-filename name ver) (fixture-registry-tarballs reg))))
                     (true bytes "tarball bytes present for ~a@~a" name ver)
                     (is string= (reg:vm-dist-integrity vm) (tarball-integrity bytes)
                         "~a@~a integrity matches bytes" name ver)
                     (incf checked)))))
             (fixture-registry-metadata reg))
    (is = 10 checked "all fixture tarballs verified")))

;;; --- (7) robustness: a malformed request must not wedge/crash the fixture loop -----

(define-test registry/url-decode-tolerates-malformed
  ;; %url-decode emits a bad escape literally (never signals) and still decodes valid ones
  (is string= "@scope/widget" (%url-decode "@scope%2Fwidget"))
  (is string= "%GG" (%url-decode "%GG"))          ; non-hex → literal
  (is string= "a%" (%url-decode "a%"))            ; trailing % → literal
  (is string= "%2" (%url-decode "%2"))            ; truncated → literal
  (is string= "/" (%url-decode "%2F")))

(define-test registry/fixture-survives-malformed-request
  ;; a request whose target holds an invalid percent-escape (`/%GG`) used to throw a raw
  ;; parse-error out of the on-data handler and unwind run-loop (§6 failure). Now %url-decode
  ;; leaves the bad escape literal, so `/%GG` is just an unknown package → a clean 404, and the
  ;; loop survives. If it had crashed, the run-loop inside with-registry-fixture would signal
  ;; and this test would ERROR rather than reach the assertions.
  (let ((resp (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (with-registry-fixture (loop reg base)
      (multiple-value-bind (h p) (reg:parse-registry-base base)
        (net:tcp-connect loop h p
          :on-connect (lambda (c)
                        (net:tcp-write c (sb-ext:string-to-octets
                                          (format nil "GET /%GG HTTP/1.1~c~cHost: x~c~cConnection: close~c~c~c~c"
                                                  #\Return #\Newline #\Return #\Newline
                                                  #\Return #\Newline #\Return #\Newline)
                                          :external-format :latin-1)))
          :on-data (lambda (c data) (declare (ignore c))
                     (loop for b across data do (vector-push-extend b resp)))
          :on-close (lambda (c code) (declare (ignore c code)) (lp:loop-stop loop))
          :on-error (lambda (c code) (declare (ignore c code)) (lp:loop-stop loop)))))
    ;; reaching here at all means run-loop returned without the loop crashing
    (let ((text (map 'string #'code-char resp)))
      (true (search "HTTP/1.1" text) "got a well-formed HTTP response (loop survived the bad escape)")
      (true (search "404" text) "the literal %GG is an unknown package → 404"))))

(define-test registry/tarball-fetch-verifies-over-the-wire
  ;; end-to-end: fetch metadata, then GET the advertised dist.tarball and verify the downloaded
  ;; bytes hash to the advertised integrity — the full "resolve → download → verify" path.
  (let (integrity downloaded err)
    (with-registry-fixture (loop reg base)
      (reg:fetch-metadata-async loop "hasbin" :override base :retries 0
        :on-ok (lambda (md)
                 (let* ((vm (reg:metadata-version md "2.0.0"))
                        (url (reg:vm-dist-tarball vm))
                        (path (subseq url (length base))))  ; base has no trailing slash
                   (setf integrity (reg:vm-dist-integrity vm))
                   (multiple-value-bind (h p) (reg:parse-registry-base base)
                     (net:http-request-async loop :host h :port p :method "GET" :path path
                       :on-response (lambda (resp)
                                      (setf downloaded (net:hres-body resp)) (lp:loop-stop loop))
                       :on-error (lambda (c) (setf err c) (lp:loop-stop loop))))))
        :on-err (lambda (c) (setf err c) (lp:loop-stop loop))))
    (false err)
    (true integrity)
    (true downloaded)
    (is string= integrity (tarball-integrity downloaded))))

;;; --- (8) https transport fails closed on an untrusted certificate -------------

(define-test registry/https-fetch-fails-closed
  ;; the client's https path reuses net:https-request (verification ON; trust = the system CA
  ;; bundle / $SSL_CERT_FILE). An in-process pure-tls server presenting a cert signed by the
  ;; TEST CA — which is NOT in the system store and is NOT injected — MUST be rejected. The
  ;; client never accepts an unverifiable certificate, whichever way pure-tls's self-interop
  ;; races (recorded → UNKNOWN-CA, or nil → NO-PEER-CERTIFICATE); both fail closed. (%https-
  ;; fixture-server / %cert / %http-response-bytes are the Phase-20 helpers in net/https-tests.)
  (multiple-value-bind (fport thread)
      (%https-fixture-server (%cert "localhost-leaf.crt") (%cert "localhost-leaf.key")
                             (%http-response-bytes 200 "{\"name\":\"secret\"}"))
    (unwind-protect
         (let ((loop (lp:make-event-loop :workers 0)) (md :none) (err nil))
           (unwind-protect
                (progn
                  (reg:fetch-metadata-async loop "secret" :retries 0 :timeout 15000
                    :override (format nil "https://localhost:~d/" fport)
                    :on-ok  (lambda (v) (setf md v) (lp:loop-stop loop))
                    :on-err (lambda (c) (setf err c) (lp:loop-stop loop)))
                  (lp:run-loop loop))
             (lp:destroy-event-loop loop))
           (is eq :none md)                              ; the fetch NEVER fulfilled
           (true (typep err 'reg:registry-error)))       ; it rejected — fail closed
      (ignore-errors (sb-thread:join-thread thread :timeout 5)))))
