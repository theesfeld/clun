;;;; run-pure-tls-suites.lisp — run pure-tls's OWN self-contained fiveam suites.
;;;;
;;;; Phase-19 gate step.  Runs the crypto / record / handshake / certificate /
;;;; x509test / ml-dsa / cancel / security-regression suites that live in
;;;; package pure-tls/test.  These are self-contained: they use only pure-tls +
;;;; fiveam + pre-generated cert fixtures under vendor/pure-tls/test/certs/.
;;;;
;;;; We deliberately do NOT load the `pure-tls/test' ASDF system (it depends-on
;;;; drakma + iparse + usocket for the interop suites we exclude).  Instead we
;;;; load :pure-tls + :fiveam via ASDF, then compile+load ONLY the self-contained
;;;; test files.  The genuinely-interop files (network / openssl /
;;;; resumption-interop / cancel-integration / runner) are NOT loaded: they pull
;;;; drakma / need the external openssl binary / need a live network.
;;;; (trust-store + boringssl ARE included — see the *core-test-files* note.)
;;;;
;;;; Load order matters (see pure-tls.asd :serial component order):
;;;;   crypto-tests           defines hex-to-bytes + bytes-equal (used by the
;;;;                          record/handshake/certificate/security suites)
;;;;   certificate-tests      defines test-cert-path + *test-certs-dir* (used by
;;;;                          security-regression-tests)
;;;; so crypto must load first and certificate before security-regression.
;;;;
;;;; certificate-tests + x509test-tests resolve their fixture dirs with
;;;; (asdf:system-relative-pathname :pure-tls/test ...).  That only needs the
;;;; system to be FINDABLE (registry.lisp puts vendor/pure-tls/ on the central
;;;; registry so ASDF can parse pure-tls.asd), not loaded — so it works without
;;;; dragging in drakma.

(load (merge-pathnames "registry.lisp" *load-truename*))

(asdf:load-system :pure-tls)
(asdf:load-system :fiveam)

;;; Keep fiveam's default failure reporting (no forced backtraces) and do NOT
;;; auto-run tests as they are defined.
(setf fiveam:*run-test-when-defined* nil)

(defparameter *pure-tls-test-dir*
  (merge-pathnames "test/"
                   (asdf:system-relative-pathname :pure-tls "pure-tls.asd"))
  "Absolute pathname of vendor/pure-tls/test/.")

;;; The core, self-contained test files, in load order.  package first, then
;;; crypto (helpers), then the rest with cross-file deps satisfied.
(defparameter *core-test-files*
  '("package"
    "crypto-tests"
    "ml-dsa-tests"
    "record-tests"
    "handshake-tests"
    "certificate-tests"
    ;; trust-store + boringssl are self-contained: trust-store's only "drakma" is a
    ;; COMMENT, and boringssl reads pre-generated fixtures under test/certs/boringssl/
    ;; (not the bssl binary). Both use test-cert-path (defined in certificate-tests),
    ;; so they load after it. (Phase-19 review finding; added to strengthen the gate.)
    "trust-store-tests"
    "boringssl-tests"
    "x509test-tests"
    "cancel-tests"
    "security-regression-tests")
  "Test file base names (without .lisp) to compile+load, in dependency order.")

;;; The fiveam suite names to run, one per non-package file above.  Kept as
;;; strings because the PURE-TLS/TEST package does not exist until package.lisp
;;; is loaded below; we resolve them to symbols at run time.
(defparameter *suite-names*
  '("CRYPTO-TESTS"
    "ML-DSA-TESTS"
    "RECORD-TESTS"
    "HANDSHAKE-TESTS"
    "CERTIFICATE-TESTS"
    "TRUST-STORE-TESTS"
    "BORINGSSL-TESTS"
    "X509TEST-TESTS"
    "CANCEL-TESTS"
    "SECURITY-REGRESSION-TESTS")
  "fiveam suite symbol-names (in PURE-TLS/TEST) to run, in order.")

;;; Compile + load each core test file.  A compile-time STYLE-WARNING about an
;;; undefined function (forward reference to a helper) is fine; only a hard
;;; load ERROR should stop us.
(dolist (base *core-test-files*)
  (let ((src (merge-pathnames (concatenate 'string base ".lisp")
                              *pure-tls-test-dir*)))
    (format t "~&;;; compiling+loading ~a~%" src)
    (handler-bind ((style-warning #'muffle-warning)
                   (warning #'muffle-warning))
      (load (compile-file src)))))

;;; Three tests in SECURITY-REGRESSION-TESTS are LIVE-NETWORK interop cases:
;;; they open loopback TCP sockets (usocket:socket-listen/socket-connect) in a
;;; background thread and drive a full TLS server<->client session-resumption
;;; handshake.  They also call ALLOCATE-TEST-PORT, a helper that lives only in
;;; the EXCLUDED openssl-tests.lisp.  Per the Phase-19 constraints (exclude
;;; suites/tests needing live network or deps we deliberately lack), we remove
;;; just these three from the suite so the other 26 self-contained security
;;; regression tests still run and gate.  The excision is non-invasive: it
;;; mutates fiveam's in-memory suite bundle only, never a vendored file.
(defparameter *excluded-tests*
  '(("SECURITY-REGRESSION-TESTS" .
     ("RESUMED-PSK-CARRIES-FORWARD-VERIFICATION"
      "RESUMPTION-NIL-PROVENANCE-FAILS-CLOSED"
      "RESUMPTION-CROSS-HOSTNAME-FAILS-CLOSED")))
  "alist of (suite-name . (test-name ...)) to drop before running (live-network).")

(defun excise-network-tests ()
  "Remove the excluded live-network tests from their fiveam suite bundles."
  (let ((pkg (find-package "PURE-TLS/TEST")))
    (dolist (entry *excluded-tests*)
      (let* ((suite-sym (find-symbol (car entry) pkg))
             (suite (and suite-sym (fiveam:get-test suite-sym))))
        (when suite
          ;; The suite object holds its own test bundle in slot TESTS; bind
          ;; fiveam's *TEST* to it so REM-TEST edits the suite, not the global.
          (let ((fiveam::*test* (fiveam::tests suite)))
            (dolist (tname (cdr entry))
              (let ((tsym (find-symbol tname pkg)))
                (when (and tsym (fiveam::get-test tsym))
                  (fiveam::rem-test tsym)
                  (format t "~&;;; excluded live-network test ~a::~a~%"
                          (car entry) tname))))))))))

(excise-network-tests)

;;; Run every suite.  fiveam:run! prints a results summary and returns T iff
;;; every test in the suite passed.  Resolve suite names to symbols now that the
;;; PURE-TLS/TEST package exists.
(let ((all-ok t)
      (n 0))
  (dolist (name *suite-names*)
    (let ((suite (or (find-symbol name (find-package "PURE-TLS/TEST"))
                     (error "Suite ~a not found in PURE-TLS/TEST" name))))
      (format t "~&~%;;; ==================== running suite ~a ====================~%"
              suite)
      (let ((ok (fiveam:run! suite)))
        (incf n)
        (unless ok
          (setf all-ok nil)))))
  (finish-output)
  (if all-ok
      (progn
        (format t "~&~%PURE-TLS-SUITES-OK ~d suites~%" n)
        (finish-output)
        (sb-ext:exit :code 0))
      (progn
        (format t "~&~%PURE-TLS-SUITES-FAIL~%")
        (finish-output)
        (sb-ext:exit :code 1))))
