;;; test/security-regression-tests.lisp --- Security regression tests
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Anthony Green <green@moxielogic.com>
;;;
;;; Regression tests for security findings surfaced by a SAST triage of the
;;; pure-Lisp verification and handshake-parsing paths.
;;;
;;; Each test asserts the SECURE behaviour for a fixed finding and guards
;;; against regression:
;;;   * CL-SEC-2026-0206 -- out-of-bounds read parsing a hostile ECHConfig
;;;   * CL-SEC-2026-0207 -- ExtendedKeyUsage not enforced during chain verify
;;;
;;; Fixtures (cert-only, no private keys) live in test/certs/ and were produced
;;; with OpenSSL; see the comments on each test for how to regenerate them.

(in-package #:pure-tls/test)

(def-suite security-regression-tests
  :description "Regression tests for SAST security findings (expected-failing until fixed)")

(in-suite security-regression-tests)

;;;; Note: hex-to-bytes is defined in crypto-tests.lisp; test-cert-path and
;;;; *test-certs-dir* are defined in certificate-tests.lisp.  Both files load
;;;; before this one (see pure-tls.asd :serial t component order).

;;;; ---------------------------------------------------------------------------
;;;; Finding: ECH config parsing crashes with a raw, non-TLS error on a
;;;; malformed length field (remote DoS from a single peer message).
;;;;
;;;; src/handshake/ech.lisp parse-ech-config-contents reads attacker-controlled
;;;; length fields (pk_len, pn_len, ext_len) and slices with AREF/SUBSEQ BEFORE
;;;; the only bounds check ((<= pos end), ech.lisp:92).  An oversized length
;;;; makes SUBSEQ raise SB-KERNEL:BOUNDING-INDICES-BAD-ERROR -- an ordinary CL
;;;; error, NOT a subtype of PURE-TLS:TLS-ERROR.  The EncryptedExtensions
;;;; parse path (extensions.lisp ~590) reaches this unconditionally, and the
;;;; handshake error handlers only catch TLS-* conditions, so a malicious peer
;;;; aborts the handshake with an uncaught Lisp error.
;;;;
;;;; Secure behaviour: malformed peer ECH bytes MUST surface as a graceful
;;;; PURE-TLS:TLS-ERROR (e.g. tls-decode-error / tls-handshake-error), never a
;;;; raw bounds error.  This test will pass once the ECH parser validates each
;;;; length against the remaining buffer (or routes through the bounds-checked
;;;; tls-buffer readers).
;;;; ---------------------------------------------------------------------------

(test ech-config-malformed-length-is-graceful
  "Malformed ECHConfigList length must raise a TLS-ERROR, not a raw Lisp crash."
  ;; ECHConfigList:
  ;;   total_len = 0x0009
  ;;   ECHConfig { version = 0xfe0d, length = 0x0005,
  ;;               contents = { config_id=0x00, kem_id=0x0020, pk_len=0xffff } }
  ;; pk_len (0xffff) runs far past the 11-byte buffer.
  (let ((bytes (hex-to-bytes "00 09 fe 0d 00 05 00 00 20 ff ff")))
    ;; Currently raises SB-KERNEL:BOUNDING-INDICES-BAD-ERROR (not a tls-error),
    ;; so this SIGNALS assertion fails until the parser is hardened.
    (signals pure-tls:tls-error
      (pure-tls::parse-ech-config-list bytes))))

;;;; ---------------------------------------------------------------------------
;;;; Finding: ExtendedKeyUsage (EKU) is recognised but never enforced.
;;;;
;;;; The pure-Lisp chain verifier accepts a leaf whose EKU does NOT include
;;;; serverAuth as a valid server certificate.  src/x509/verify.lisp
;;;; verify-certificate-chain checks dates, names, BasicConstraints, keyCertSign,
;;;; path length, and signatures, but contains no EKU enforcement; EKU is even
;;;; listed as a "known critical" extension (certificate.lisp), so a critical
;;;; clientAuth-only EKU passes silently.
;;;;
;;;; Secure behaviour: a leaf valid only for clientAuth must NOT be accepted for
;;;; TLS server authentication.
;;;;
;;;; DESIGN NOTE: verify-certificate-chain is also used for mTLS client-cert
;;;; validation, where a clientAuth leaf is correct.  The fix adds a :purpose
;;;; keyword (the TLS client path requests :server-auth, the server path
;;;; requests :client-auth); a leaf whose EKU is present but lists neither the
;;;; requested purpose nor anyExtendedKeyUsage is rejected.  This test requests
;;;; :server-auth explicitly, mirroring the client handshake path.
;;;;
;;;; Fixtures (regenerate with):
;;;;   openssl req -x509 -newkey rsa:2048 -nodes -keyout root.key \
;;;;     -out security-regression-root-ca.pem -subj "/CN=Test Root CA" \
;;;;     -days 36500 -sha256 \
;;;;     -addext "basicConstraints=critical,CA:TRUE" \
;;;;     -addext "keyUsage=critical,keyCertSign,cRLSign"
;;;;   openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr \
;;;;     -subj "/CN=victim.example" -sha256
;;;;   printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,clientAuth\nsubjectAltName=DNS:victim.example\n" > ext.cnf
;;;;   openssl x509 -req -in leaf.csr -CA security-regression-root-ca.pem \
;;;;     -CAkey root.key -CAcreateserial \
;;;;     -out security-regression-clientauth-leaf.pem -days 36500 -sha256 \
;;;;     -extfile ext.cnf
;;;; ---------------------------------------------------------------------------

(test clientauth-only-leaf-rejected-for-server-auth
  "A clientAuth-only leaf must not validate as a server certificate."
  ;; Force the pure-Lisp verification path (not the OS native verifiers).
  (let ((pure-tls:*use-windows-certificate-store* nil)
        (pure-tls:*use-macos-keychain* nil))
    (let* ((root (pure-tls:parse-certificate-from-file
                  (test-cert-path "security-regression-root-ca.pem")))
           (leaf (pure-tls:parse-certificate-from-file
                  (test-cert-path "security-regression-clientauth-leaf.pem"))))
      ;; Sanity: the fixture really is EKU clientAuth-only with a critical EKU
      ;; extension that the verifier currently treats as "known".
      (is (member :extended-key-usage
                  (pure-tls::certificate-critical-extensions leaf))
          "Fixture leaf should carry a critical ExtendedKeyUsage extension")
      ;; With :purpose :server-auth, a clientAuth-only leaf must be rejected.
      ;; (now and hostname are positional &optional args before the &key.)
      (signals pure-tls:tls-certificate-error
        (pure-tls::verify-certificate-chain (list leaf) (list root)
                                            (get-universal-time) nil
                                            :purpose :server-auth)))))

;;;; ---------------------------------------------------------------------------
;;;; Finding: resumption must carry forward the original handshake's
;;;; authentication (RFC 8446 Sections 2.2 and 4.2.11).
;;;;
;;;; On a first verify-required handshake the client verifies the certificate
;;;; chain and hostname, then caches a NewSessionTicket keyed by hostname.  A
;;;; later PSK resumption legitimately skips Certificate/CertificateVerify -- the
;;;; resumed session inherits the authentication of the handshake that minted the
;;;; ticket -- so demanding a fresh certificate breaks valid resumption.
;;;;
;;;; The fix records, on each ticket, the hostname the minting handshake
;;;; certificate-verified under verify-required, and accepts a certificate-less
;;;; resumed Finished ONLY when the accepted PSK's ticket proves verification of
;;;; the SAME host.  Otherwise it fails closed, exactly as before.
;;;;
;;;; These proofs drive a real pure-tls loopback (pure-tls server + pure-tls
;;;; client over 127.0.0.1) so the handshakes are genuine, and they keep the
;;;; process-global ticket cache WARM across connections (no per-connection
;;;; reset) so resumption exercises the real cache.
;;;;
;;;; Fixtures generated with (long-dated CA + leaf, SAN=resumption.test):
;;;;   openssl req -x509 -newkey rsa:2048 -nodes -keyout resumption-ca.key \
;;;;     -out resumption-ca.pem -subj "/CN=pure-tls Resumption Test CA" \
;;;;     -days 36500 -sha256 \
;;;;     -addext "basicConstraints=critical,CA:TRUE" \
;;;;     -addext "keyUsage=critical,keyCertSign,cRLSign"
;;;;   openssl req -newkey rsa:2048 -nodes -keyout resumption-leaf.key \
;;;;     -out resumption-leaf.csr -subj "/CN=resumption.test" -sha256
;;;;   printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:resumption.test\n" > ext.cnf
;;;;   openssl x509 -req -in resumption-leaf.csr -CA resumption-ca.pem \
;;;;     -CAkey resumption-ca.key -CAcreateserial \
;;;;     -out resumption-leaf.pem -days 36500 -sha256 -extfile ext.cnf
;;;; (resumption-ca.pem, resumption-leaf.pem, resumption-leaf.key live in
;;;; test/certs/; the transient CA key and CSR are not kept.)
;;;; ---------------------------------------------------------------------------

(defun %resumption-server-loop (port n-conns ready-flag ready-lock ready-cv server-info)
  "Accept N-CONNS sequential pure-tls connections on PORT using the resumption
   test leaf certificate.  Each accepted connection completes the handshake
   (which sends a NewSessionTicket), then a single app-data byte is pushed so
   the client's read loop consumes the post-handshake ticket, then the
   connection closes.  Each connection's server-side psk-accepted flag is pushed
   onto (car SERVER-INFO), newest first."
  (let ((listen-sock nil))
    (unwind-protect
         (handler-case
             (progn
               (setf listen-sock (usocket:socket-listen "127.0.0.1" port
                                                        :reuse-address t
                                                        :element-type '(unsigned-byte 8)))
               (bt:with-lock-held (ready-lock)
                 (setf (car ready-flag) t)
                 (bt:condition-notify ready-cv))
               (dotimes (i n-conns)
                 (let ((client-sock nil)
                       (tls nil))
                   (unwind-protect
                        (handler-case
                            (progn
                              (setf client-sock
                                    (usocket:socket-accept listen-sock
                                                           :element-type '(unsigned-byte 8)))
                              (setf tls (pure-tls:make-tls-server-stream
                                         (usocket:socket-stream client-sock)
                                         :certificate (test-cert-path "resumption-leaf.pem")
                                         :key (test-cert-path "resumption-leaf.key")))
                              (push (pure-tls::server-handshake-psk-accepted
                                     (pure-tls::tls-stream-handshake tls))
                                    (car server-info))
                              ;; App-data byte drives the client's fill-buffer so
                              ;; it consumes the post-handshake NewSessionTicket.
                              (write-byte 42 tls)
                              (force-output tls)
                              ;; Wait for the client's acknowledgement byte (or EOF
                              ;; if the client aborted, e.g. a fail-closed case).
                              (read-byte tls nil nil))
                          (error () nil))
                     (ignore-errors (when tls (close tls)))
                     (ignore-errors (when client-sock
                                      (usocket:socket-close client-sock)))))))
           (error () nil))
      (ignore-errors (when listen-sock (usocket:socket-close listen-sock))))))

(defun %spawn-resumption-server (port n-conns)
  "Spawn the resumption loopback server for N-CONNS connections on PORT.
   Blocks until the server is listening.  Returns (values thread server-info),
   where (car SERVER-INFO) accumulates each connection's server-side
   psk-accepted flag (newest first)."
  (let ((ready-lock (bt:make-lock "resumption-server-ready"))
        (ready-cv (bt:make-condition-variable :name "resumption-server-ready-cv"))
        (ready-flag (list nil))
        (server-info (list nil)))
    (let ((thread (bt:make-thread
                   (lambda ()
                     (%resumption-server-loop port n-conns ready-flag ready-lock
                                              ready-cv server-info))
                   :name "resumption-test-server")))
      (bt:with-lock-held (ready-lock)
        (loop until (car ready-flag)
              do (unless (bt:condition-wait ready-cv ready-lock :timeout 5)
                   (return))))
      ;; Small delay to ensure the listening socket is fully ready.
      (sleep 0.05)
      (values thread server-info))))

(defun %resumption-client (port hostname verify ca-file)
  "Open one pure-tls client connection to PORT for HOSTNAME under VERIFY,
   trusting only CA-FILE.  On a successful handshake, reads the app-data byte
   (consuming the server's NewSessionTicket into the process-global cache),
   sends an acknowledgement byte, and returns the client handshake object so
   callers can inspect psk-accepted / peer-certificate.  Handshake failures
   (e.g. a fail-closed resumption) propagate to the caller."
  (let ((sock nil)
        (tls nil))
    (unwind-protect
         (progn
           (setf sock (usocket:socket-connect "127.0.0.1" port
                                              :element-type '(unsigned-byte 8)))
           (let ((ctx (pure-tls:make-tls-context :verify-mode verify
                                                 :ca-file ca-file
                                                 :auto-load-system-ca nil)))
             (setf tls (pure-tls:make-tls-client-stream
                        (usocket:socket-stream sock)
                        :hostname hostname
                        :verify verify
                        :context ctx))
             (let ((hs (pure-tls::tls-stream-handshake tls)))
               ;; Consume the post-handshake NewSessionTicket, then acknowledge.
               (read-byte tls)
               (write-byte 43 tls)
               (force-output tls)
               hs)))
      (ignore-errors (when tls (close tls)))
      (ignore-errors (when sock (usocket:socket-close sock))))))

(test resumed-psk-carries-forward-verification
  "A verify-required full handshake mints a certificate-verified ticket; later
   connections to the same host resume via PSK (server skips its Certificate)
   and the client accepts them as authenticated -- with the real process-global
   ticket cache warm across all connections.  RFC 8446 Sections 2.2 / 4.2.11."
  (let ((pure-tls:*use-windows-certificate-store* nil)
        (pure-tls:*use-macos-keychain* nil)
        (port (allocate-test-port))
        (ca (test-cert-path "resumption-ca.pem"))
        (host "resumption.test"))
    ;; Start from a clean slate for this host; the cache then stays warm across
    ;; every connection below (never reset between handshakes).
    (pure-tls::session-ticket-cache-clear host)
    (multiple-value-bind (thread server-info)
        (%spawn-resumption-server port 3)
      (unwind-protect
           (let (hs1 hs2 hs3)
             ;; 1st: full handshake with real certificate verification.
             (setf hs1 (%resumption-client port host pure-tls:+verify-required+ ca))
             (is (not (pure-tls::client-handshake-psk-accepted hs1))
                 "First handshake must be a full (non-resumed) handshake")
             (is (pure-tls::client-handshake-peer-certificate hs1)
                 "First handshake must present a server certificate")
             ;; The ticket minted by connection 1 carries proven provenance.
             (let ((tk (pure-tls::session-ticket-cache-get host)))
               (is (and tk (equal (pure-tls::session-ticket-verified-hostname tk) host))
                   "Cached ticket must record the verified hostname"))
             ;; 2nd: resume via PSK; server skips Certificate; accepted as authenticated.
             (setf hs2 (%resumption-client port host pure-tls:+verify-required+ ca))
             (is (pure-tls::client-handshake-psk-accepted hs2)
                 "Second connection must resume via PSK, not full-handshake")
             (is (not (pure-tls::client-handshake-peer-certificate hs2))
                 "Resumed connection must receive no server certificate")
             ;; 3rd: carry-forward keeps repeated warm-cache resumptions working.
             (setf hs3 (%resumption-client port host pure-tls:+verify-required+ ca))
             (is (pure-tls::client-handshake-psk-accepted hs3)
                 "Third connection must also resume via PSK")
             (is (not (pure-tls::client-handshake-peer-certificate hs3))
                 "Third resumed connection must receive no server certificate")
             ;; Server side agrees: one full handshake, then two resumptions.
             (is (equal (reverse (car server-info)) '(nil t t))
                 "Server must full-handshake once then resume twice"))
        (pure-tls::session-ticket-cache-clear host)
        (ignore-errors (bt:join-thread thread))))))

(test resumption-nil-provenance-fails-closed
  "A ticket minted by a non-verified (+verify-none+) origin proves no
   authentication; offering it on a +verify-required+ resumption to that host
   must fail closed with a catchable tls-certificate-error."
  (let ((pure-tls:*use-windows-certificate-store* nil)
        (pure-tls:*use-macos-keychain* nil)
        (port (allocate-test-port))
        (ca (test-cert-path "resumption-ca.pem"))
        (host "resumption.test"))
    (pure-tls::session-ticket-cache-clear host)
    (multiple-value-bind (thread server-info)
        (%spawn-resumption-server port 2)
      (declare (ignore server-info))
      (unwind-protect
           (progn
             ;; 1st: full handshake under +verify-none+ -> NIL-provenance ticket.
             (%resumption-client port host pure-tls:+verify-none+ ca)
             (let ((tk (pure-tls::session-ticket-cache-get host)))
               (is (and tk (null (pure-tls::session-ticket-verified-hostname tk)))
                   "A verify-none origin must cache a NIL-provenance ticket"))
             ;; 2nd: resume under +verify-required+ -> must fail closed.
             (signals pure-tls:tls-certificate-error
               (%resumption-client port host pure-tls:+verify-required+ ca)))
        (pure-tls::session-ticket-cache-clear host)
        (ignore-errors (bt:join-thread thread))))))

(test resumption-cross-hostname-fails-closed
  "A ticket whose proven hostname differs from the host being connected to must
   fail closed on resumption, even though the server accepts the PSK -- exercising
   the hostname-equality guard on the resumed certificate-less Finished."
  (let ((pure-tls:*use-windows-certificate-store* nil)
        (pure-tls:*use-macos-keychain* nil)
        (port (allocate-test-port))
        (ca (test-cert-path "resumption-ca.pem"))
        (host "resumption.test"))
    (pure-tls::session-ticket-cache-clear host)
    (multiple-value-bind (thread server-info)
        (%spawn-resumption-server port 2)
      (declare (ignore server-info))
      (unwind-protect
           (progn
             ;; 1st: full verify-required handshake mints a ticket for HOST.
             (%resumption-client port host pure-tls:+verify-required+ ca)
             ;; Rewrite the cached ticket's proven hostname to a different host
             ;; while leaving it keyed under HOST, so the next resumption offers a
             ;; genuine PSK whose provenance is for the wrong identity.
             (let ((tk (pure-tls::session-ticket-cache-get host)))
               (is (and tk (equal (pure-tls::session-ticket-verified-hostname tk) host))
                   "Sanity: minted ticket is provenance-stamped for HOST")
               (setf (pure-tls::session-ticket-verified-hostname tk) "other-identity.test"))
             ;; 2nd: server resumes the PSK, but its provenance is cross-hostname.
             (signals pure-tls:tls-certificate-error
               (%resumption-client port host pure-tls:+verify-required+ ca)))
        (pure-tls::session-ticket-cache-clear host)
        (ignore-errors (bt:join-thread thread))))))

;;;; ---------------------------------------------------------------------------
;;;; Finding: an unusable explicit :ca-file crashes the image instead of
;;;; signalling a catchable condition.
;;;;
;;;; make-tls-context's explicit-CA branch loaded the trust store through
;;;; read-file-bytes, which opens with-open-file with no :if-does-not-exist,
;;;; so a missing/unreadable file raised a raw FILE-ERROR.  FILE-ERROR is not
;;;; a subtype of PURE-TLS:TLS-ERROR, so a non-interactive consumer's
;;;; fail-closed handler (which catches only the tls-error family) could not
;;;; catch it and the image died.  A garbage or empty file was worse: the
;;;; parser swallowed the decode error and returned an empty trust store, so
;;;; the context silently trusted nothing.
;;;;
;;;; Secure behaviour: an explicitly-named CA source that cannot be read or
;;;; that yields zero trust anchors is a misconfiguration -- make-tls-context
;;;; must fail closed with a catchable PURE-TLS:TLS-CERTIFICATE-ERROR and the
;;;; image must survive.  Each case passes :auto-load-system-ca nil so the bad
;;;; file is the only trust source (no accidental system-store fallback).
;;;; ---------------------------------------------------------------------------

(test explicit-ca-source-fails-closed
  "An unusable explicit :ca-file must signal a catchable tls-error-family
   condition, never crash the image with a raw file-error."
  (let* ((dir (uiop:temporary-directory))
         (empty (merge-pathnames "pure-tls-fail-closed-empty.pem" dir))
         (garbage (merge-pathnames "pure-tls-fail-closed-garbage.pem" dir))
         (missing (merge-pathnames "pure-tls-fail-closed-does-not-exist.pem" dir)))
    (unwind-protect
         (progn
           ;; Empty file: zero certificates parse -> fail closed on empty store.
           (with-open-file (s empty :direction :output :if-exists :supersede
                                    :if-does-not-exist :create
                                    :element-type '(unsigned-byte 8)))
           ;; Garbage non-PEM bytes (invalid UTF-8 lead bytes): decode/parse
           ;; failure -> resignalled as a certificate error.
           (with-open-file (s garbage :direction :output :if-exists :supersede
                                      :if-does-not-exist :create
                                      :element-type '(unsigned-byte 8))
             (write-sequence #(255 254 0 1 2 3 128 200 66 66 7 7) s))
           ;; Make sure the "missing" path really is absent.
           (ignore-errors (delete-file missing))
           ;; Missing path (guaranteed absent).
           (signals pure-tls:tls-certificate-error
             (pure-tls:make-tls-context :ca-file (namestring missing)
                                        :auto-load-system-ca nil))
           ;; Empty file (zero usable anchors).
           (signals pure-tls:tls-certificate-error
             (pure-tls:make-tls-context :ca-file (namestring empty)
                                        :auto-load-system-ca nil))
           ;; Garbage non-PEM file.
           (signals pure-tls:tls-certificate-error
             (pure-tls:make-tls-context :ca-file (namestring garbage)
                                        :auto-load-system-ca nil))
           ;; Not-a-regular-file: pass the temp directory itself.  Opening a
           ;; directory as a file signals an error, which is portable AND
           ;; root-safe -- chmod 000 is bypassed when the suite runs as root,
           ;; so we deliberately use a directory path rather than an unreadable
           ;; regular file.
           (signals pure-tls:tls-certificate-error
             (pure-tls:make-tls-context :ca-file (namestring dir)
                                        :auto-load-system-ca nil)))
      (ignore-errors (delete-file empty))
      (ignore-errors (delete-file garbage)))))

;;;; Test Runner

;;;; ---------------------------------------------------------------------------
;;;; Finding: Adversarial certificate-chain validation (Georgiev et al.).
;;;;
;;;; verify-certificate-chain must fail closed on every class of forged chain:
;;;; a non-CA issuer, a violated path-length budget, a corrupted signature, and
;;;; an out-of-window validity date.  These tests drive the real pure-Lisp
;;;; verifier (OS native store disabled, :trust-anchor-mode :replace with an
;;;; explicit root list) so the decision is made by our own code, not the OS.
;;;;
;;;; The CA / date proofs use certificates constructed in-image: those checks
;;;; fire before signature verification, so no valid signatures are needed.  The
;;;; path-length and tampered-signature proofs need a chain whose earlier checks
;;;; genuinely pass, so they load a real OpenSSL-signed leaf+intermediate chain
;;;; (goodcn2-chain.pem) anchored at root-cert.pem and corrupt exactly one input.
;;;; ---------------------------------------------------------------------------

(defun %pem-chain (path)
  "Parse every CERTIFICATE block in a PEM file, in file order (leaf first).
   parse-certificate-from-file only decodes the first block, so multi-cert
   chain fixtures need this."
  (let ((text (pure-tls::octets-to-string (pure-tls::read-file-bytes path)))
        (certs nil)
        (pos 0)
        (begin "-----BEGIN CERTIFICATE-----")
        (end "-----END CERTIFICATE-----"))
    (loop for b = (search begin text :start2 pos)
          while b
          for e = (search end text :start2 b)
          while e
          do (push (pure-tls::parse-certificate
                    (pure-tls::base64-decode
                     (remove-if (lambda (c) (member c '(#\Newline #\Return #\Space)))
                                (subseq text (+ b (length begin)) e))))
                   certs)
             (setf pos (+ e (length end))))
    (nreverse certs)))

(defun %chain-cert (subject-cn issuer-cn
                    &key (basic-constraints :ca-true) path-length
                         (key-usage '(:key-cert-sign :crl-sign))
                         (not-before 0) (not-after most-positive-fixnum))
  "Construct an in-image X.509 certificate for chain-verification proofs.
   BASIC-CONSTRAINTS is :ca-true, :ca-false, or :absent.  The default validity
   window is always-valid; NOT-BEFORE / NOT-AFTER override it for date proofs.
   Names are single-CN so certificate-issued-by-p links a leaf to its issuer by
   equal CN."
  (pure-tls::make-x509-certificate
   :subject (pure-tls::make-x509-name :rdns (list (cons :common-name subject-cn)))
   :issuer (pure-tls::make-x509-name :rdns (list (cons :common-name issuer-cn)))
   :validity-not-before not-before
   :validity-not-after not-after
   :extensions
   (append
    (ecase basic-constraints
      (:ca-true (list (pure-tls::make-x509-extension
                       :oid :basic-constraints :critical t
                       :value (if path-length
                                  (list :ca t :path-length-constraint path-length)
                                  (list :ca t)))))
      (:ca-false (list (pure-tls::make-x509-extension
                        :oid :basic-constraints :critical t
                        :value (list :ca nil))))
      (:absent nil))
    (when key-usage
      (list (pure-tls::make-x509-extension
             :oid :key-usage :critical t :value key-usage))))))

(test chain-rejects-ca-false-intermediate
  "An issuer with BasicConstraints cA=FALSE (or absent) must not be accepted as
   a signing CA."
  (let ((pure-tls:*use-windows-certificate-store* nil)
        (pure-tls:*use-macos-keychain* nil)
        (now (get-universal-time)))
    ;; Intermediate explicitly asserts cA=FALSE.
    (let ((leaf (%chain-cert "leaf.example" "Intermediate CA"
                             :basic-constraints :absent))
          (inter (%chain-cert "Intermediate CA" "Root CA"
                              :basic-constraints :ca-false)))
      (signals pure-tls:tls-certificate-error
        (pure-tls::verify-certificate-chain (list leaf inter) (list inter)
                                            now nil :trust-anchor-mode :replace)))
    ;; Intermediate carries no BasicConstraints extension at all.
    (let ((leaf (%chain-cert "leaf.example" "Intermediate CA"
                             :basic-constraints :absent))
          (inter (%chain-cert "Intermediate CA" "Root CA"
                              :basic-constraints :absent)))
      (signals pure-tls:tls-certificate-error
        (pure-tls::verify-certificate-chain (list leaf inter) (list inter)
                                            now nil :trust-anchor-mode :replace)))))

(test chain-rejects-pathlen-violation
  "A CA asserting pathLenConstraint=0 with an intermediate CA below it in the
   chain must be rejected."
  (let ((pure-tls:*use-windows-certificate-store* nil)
        (pure-tls:*use-macos-keychain* nil)
        (now (get-universal-time)))
    (let ((leaf (pure-tls:parse-certificate-from-file
                 (test-cert-path "webpki-eku-server-leaf.pem")))
          (inter (pure-tls:parse-certificate-from-file
                  (test-cert-path "webpki-eku-server.pem")))
          (root (pure-tls:parse-certificate-from-file
                 (test-cert-path "webpki-root.pem"))))
        ;; Baseline: the untampered chain verifies, so the rejection below is
        ;; attributable solely to the path-length constraint.
        (is (pure-tls::verify-certificate-chain (list leaf inter root) (list root)
                                                now nil :trust-anchor-mode :replace)
            "Untampered signed WebPKI fixture chain should verify")
        ;; Assert pathLenConstraint=0 on the trusted root: it may issue end
        ;; entities but no intermediate CA -- and the chain has exactly one.
        (let ((bc (find :basic-constraints
                        (pure-tls::x509-certificate-extensions root)
                        :key #'pure-tls::x509-extension-oid)))
          (setf (pure-tls::x509-extension-value bc)
                (list :ca t :path-length-constraint 0)))
        (signals pure-tls:tls-certificate-error
          (pure-tls::verify-certificate-chain (list leaf inter root) (list root)
                                              now nil :trust-anchor-mode :replace)))))

(test chain-rejects-tampered-signature
  "A chain that passes name / CA / pathLen / date checks but whose leaf
   signature is corrupted must be rejected at signature verification."
  (let ((pure-tls:*use-windows-certificate-store* nil)
        (pure-tls:*use-macos-keychain* nil)
        (now (get-universal-time)))
    (let ((leaf (pure-tls:parse-certificate-from-file
                 (test-cert-path "webpki-eku-server-leaf.pem")))
          (inter (pure-tls:parse-certificate-from-file
                  (test-cert-path "webpki-eku-server.pem")))
          (root (pure-tls:parse-certificate-from-file
                 (test-cert-path "webpki-root.pem"))))
        ;; Baseline: the untampered chain verifies.
        (is (pure-tls::verify-certificate-chain (list leaf inter root) (list root)
                                                now nil :trust-anchor-mode :replace)
            "Untampered signed WebPKI fixture chain should verify")
        ;; Flip one byte of the leaf signature.  Every earlier check still
        ;; passes, so a rejection can only come from signature verification.
        (let ((sig (copy-seq (pure-tls::x509-certificate-signature leaf))))
          (setf (aref sig 20) (logxor #xff (aref sig 20)))
          (setf (pure-tls::x509-certificate-signature leaf) sig))
        (signals pure-tls:tls-certificate-error
          (pure-tls::verify-certificate-chain (list leaf inter root) (list root)
                                              now nil :trust-anchor-mode :replace)))))

(test chain-rejects-expired-leaf
  "A leaf whose notAfter is in the past must be rejected."
  (let ((pure-tls:*use-windows-certificate-store* nil)
        (pure-tls:*use-macos-keychain* nil)
        (now (get-universal-time)))
    (let ((root (%chain-cert "Root CA" "Root CA" :basic-constraints :ca-true))
          (leaf (%chain-cert "leaf.example" "Root CA"
                             :basic-constraints :absent
                             :not-after (- now 100000))))
      ;; tls-certificate-expired is internal to pure-tls (double colon).
      (signals pure-tls::tls-certificate-expired
        (pure-tls::verify-certificate-chain (list leaf root) (list root)
                                            now nil :trust-anchor-mode :replace)))))

(test chain-rejects-not-yet-valid-leaf
  "A leaf whose notBefore is in the future must be rejected."
  (let ((pure-tls:*use-windows-certificate-store* nil)
        (pure-tls:*use-macos-keychain* nil)
        (now (get-universal-time)))
    (let ((root (%chain-cert "Root CA" "Root CA" :basic-constraints :ca-true))
          (leaf (%chain-cert "leaf.example" "Root CA"
                             :basic-constraints :absent
                             :not-before (+ now 100000000))))
      ;; tls-certificate-not-yet-valid is internal to pure-tls (double colon).
      (signals pure-tls::tls-certificate-not-yet-valid
        (pure-tls::verify-certificate-chain (list leaf root) (list root)
                                            now nil :trust-anchor-mode :replace)))))

;;;; ---------------------------------------------------------------------------
;;;; Finding: RFC 5280 4.2.1.3 -- an issuer whose KeyUsage extension is present
;;;; but omits keyCertSign must not be accepted as a signing CA, even when its
;;;; BasicConstraints assert cA=TRUE.  keyCertSign is the specific bit that
;;;; authorizes certificate signing; a CA scoped to (say) CRL signing only must
;;;; not be able to mint end-entity certificates.
;;;;
;;;; The fixture is arranged so that keyCertSign is the OPERATIVE rejection:
;;;; the issuer is cA=TRUE (CA check passes), the leaf's issuer name matches
;;;; (issued-by passes), and both certs are always-valid (date checks pass), so
;;;; the only failing check is the missing keyCertSign key usage.
;;;; ---------------------------------------------------------------------------

(test chain-rejects-keycertsign-absent-issuer
  "An issuer with KeyUsage present but lacking keyCertSign must be rejected as a
   signing CA, even with BasicConstraints cA=TRUE."
  (let ((pure-tls:*use-windows-certificate-store* nil)
        (pure-tls:*use-macos-keychain* nil)
        (now (get-universal-time)))
    (let ((leaf (%chain-cert "leaf.example" "Issuing CA"
                             :basic-constraints :absent))
          ;; cA=TRUE, but KeyUsage is present WITHOUT :key-cert-sign.
          (issuer (%chain-cert "Issuing CA" "Root CA"
                               :basic-constraints :ca-true
                               :key-usage '(:crl-sign))))
      (signals pure-tls:tls-certificate-error
        (pure-tls::verify-certificate-chain (list leaf issuer) (list issuer)
                                            now nil :trust-anchor-mode :replace)))))

;;;; ---------------------------------------------------------------------------
;;;; DNS name-safety in hostname verification.
;;;;
;;;; verify-hostname must reject a syntactically unsafe DNS name (embedded NUL,
;;;; non-LDH bytes) outright rather than letting it reach a silent
;;;; unequal-compare.  These drive the real validator with certificate objects
;;;; constructed in-image (no private keys / OpenSSL fixtures needed for the
;;;; identity decision).
;;;; ---------------------------------------------------------------------------

(defun %san-cert (&rest dns-names)
  "Build a certificate whose only identity is the given SAN dNSName(s)."
  (pure-tls::make-x509-certificate
   :extensions (list (pure-tls::make-x509-extension
                      :oid :subject-alt-name
                      :value (mapcar (lambda (d) (list :dns d)) dns-names)))))

(defun %cn-only-cert (common-name)
  "Build a certificate with a Subject Common Name and NO subjectAltName."
  (pure-tls::make-x509-certificate
   :subject (pure-tls::make-x509-name
             :rdns (list (cons :common-name common-name)))))

(defun %nul-name ()
  "The classic embedded-NUL truncation-confusion SAN: www.bank.com<NUL>.evil.com."
  (concatenate 'string "www.bank.com" (string (code-char 0)) ".evil.com"))

(test verify-hostname-embedded-nul-san-is-rejected
  "A SAN dNSName carrying an embedded NUL must never be the basis of a match."
  (let ((evil-name (%nul-name)))
    ;; (a) The malicious name reaching the validator as the SAN, with the
    ;;     truncated benign identity requested, must not match.
    (signals pure-tls:tls-verification-error
      (pure-tls:verify-hostname (%san-cert evil-name) "www.bank.com"))
    ;; (b) The malicious name reaching the validator as the requested identity
    ;;     is rejected outright as an invalid DNS name.
    (signals pure-tls:tls-verification-error
      (pure-tls:verify-hostname (%san-cert "www.bank.com") evil-name))))

(test verify-hostname-u-label-still-verifies
  "The DNS name-safety check runs after IDNA normalization, so a Unicode
   (U-label) requested identity still verifies against its punycode A-label
   SAN rather than being rejected as non-LDH."
  (let ((u-label (format nil "m~Cnchen.example.com" (code-char 252)))) ; münchen
    (is-true (pure-tls:verify-hostname
              (%san-cert "xn--mnchen-3ya.example.com") u-label))))

;;;; ---------------------------------------------------------------------------
;;;; Hostname-verification policy: two orthogonal RFC 6125 knobs on the TLS
;;;; context, both defaulting to the permissive value so the default profile is
;;;; byte-for-byte the general-purpose behaviour.  ALLOW-WILDCARDS gates whether
;;;; wildcard SANs match; ALLOW-CN-FALLBACK gates Common Name fallback for a
;;;; no-SAN certificate.
;;;; ---------------------------------------------------------------------------

(test verify-hostname-default-honors-wildcard-san
  "The default policy honors an RFC 6125 wildcard SAN: *.example.com must
   authenticate www.example.com when no explicit policy is supplied."
  (is (pure-tls:verify-hostname (%san-cert "*.example.com") "www.example.com")
      "A wildcard SAN must authenticate a single-label host under the default policy"))

(test verify-hostname-allow-wildcards-nil-excludes-wildcard-san
  "With ALLOW-WILDCARDS disabled, a wildcard SAN is excluded from matching even
   where the general matcher would cover it, while an exact SAN still matches."
  (let ((policy (pure-tls:make-hostname-policy :allow-wildcards nil)))
    (signals pure-tls:tls-verification-error
      (pure-tls:verify-hostname (%san-cert "*.example.com") "foo.example.com"
                                :policy policy))
    (is (pure-tls:verify-hostname (%san-cert "dns.google") "dns.google"
                                  :policy policy)
        "An exact SAN must still match when wildcards are disabled")))

(test verify-hostname-default-permits-cn-fallback
  "The default policy falls back to the Subject Common Name for a no-SAN
   certificate (deprecated but still deployed)."
  (is (pure-tls:verify-hostname (%cn-only-cert "www.example.com")
                                "www.example.com")
      "CN fallback must authenticate a matching no-SAN certificate by default"))

(test verify-hostname-allow-cn-fallback-nil-rejects-no-san
  "With ALLOW-CN-FALLBACK disabled the Common Name is never consulted, so a
   no-SAN certificate is rejected even when its CN matches exactly."
  (let ((policy (pure-tls:make-hostname-policy :allow-cn-fallback nil)))
    (signals pure-tls:tls-verification-error
      (pure-tls:verify-hostname (%cn-only-cert "www.example.com")
                                "www.example.com"
                                :policy policy))))

(test hostname-policy-general-matcher-unchanged
  "The general RFC 6125 wildcard matcher is untouched by the policy seam: a
   single-label wildcard still matches structurally, *.com does not, and a
   wildcard over a multi-label public suffix does not."
  (is (pure-tls::hostname-matches-p "*.example.com" "foo.example.com"))
  (is (not (pure-tls::hostname-matches-p "*.com" "foo.com")))
  (is (not (pure-tls::hostname-matches-p "*.co.uk" "foo.co.uk"))))

;;;; ---------------------------------------------------------------------------
;;;; Bounded WebPKI profile used by Clun HTTPS (#234).
;;;;
;;;; The webpki-*.pem fixtures are real DER certificates in PEM armor, signed
;;;; with OpenSSL 3.  The test root signs five distinct CA intermediates:
;;;; critical/noncritical nameConstraints and clientAuth/serverAuth/anyEKU.
;;;; Each intermediate signs its matching serverAuth leaf.  A separate 1024-bit
;;;; RSA leaf is signed directly by the root.  Private keys are intentionally
;;;; not retained in the repository.
;;;; ---------------------------------------------------------------------------

(defun %webpki-cert (name)
  (pure-tls:parse-certificate-from-file
   (test-cert-path (format nil "webpki-~a.pem" name))))

(defun %verify-webpki-intermediate (kind &key (maximum-chain-depth 3))
  (let* ((root (%webpki-cert "root"))
         (intermediate (%webpki-cert kind))
         (leaf (%webpki-cert (format nil "~a-leaf" kind))))
    (pure-tls::verify-certificate-chain
     (list leaf intermediate root) (list root) (get-universal-time) nil
     :purpose :server-auth :trust-anchor-mode :replace
     :maximum-chain-depth maximum-chain-depth)))

(test webpki-critical-name-constraints-real-der-rejected
  "A real signed CA with critical nameConstraints is rejected while parsing;
mapping the OID for diagnostics must never mark its semantics as enforced."
  (signals pure-tls:tls-decode-error
    (%webpki-cert "nc-critical")))

(test webpki-noncritical-name-constraints-real-der-rejected
  "Unsupported nameConstraints affect path processing even when noncritical,
so the real signed leaf/intermediate/root path must fail closed."
  (signals pure-tls:tls-certificate-error
    (%verify-webpki-intermediate "nc-noncritical")))

(test webpki-intermediate-eku-constrains-server-auth
  "A non-anchor CA restricted to clientAuth cannot issue a serverAuth path;
serverAuth and anyExtendedKeyUsage CA constraints remain acceptable."
  (signals pure-tls:tls-certificate-error
    (%verify-webpki-intermediate "eku-client"))
  (is-true (%verify-webpki-intermediate "eku-server"))
  (is-true (%verify-webpki-intermediate "eku-any")))

(test webpki-empty-and-malformed-ku-eku-rejected
  "Present-but-empty or wrongly typed KU/EKU encodings never become the NIL
value reserved for an absent, unrestricted extension."
  ;; KeyUsage BIT STRING with no content octet / no asserted bits / wrong tag.
  (signals pure-tls:tls-decode-error
    (pure-tls::parse-key-usage (hex-to-bytes "03 01 00")))
  (signals pure-tls:tls-decode-error
    (pure-tls::parse-key-usage (hex-to-bytes "03 02 00 00")))
  (signals pure-tls:tls-decode-error
    (pure-tls::parse-key-usage (hex-to-bytes "04 01 00")))
  (signals pure-tls:tls-decode-error
    (pure-tls::parse-key-usage (hex-to-bytes "03 02 00 80")))
  ;; encipherOnly and decipherOnly are undefined without keyAgreement.
  (signals pure-tls:tls-decode-error
    (pure-tls::parse-key-usage (hex-to-bytes "03 02 00 01")))
  (signals pure-tls:tls-decode-error
    (pure-tls::parse-key-usage (hex-to-bytes "03 03 07 00 80")))
  (is (equal '(:key-agreement :encipher-only)
             (pure-tls::parse-key-usage (hex-to-bytes "03 02 00 09"))))
  (is (equal '(:key-agreement :decipher-only)
             (pure-tls::parse-key-usage (hex-to-bytes "03 03 07 08 80"))))
  ;; ExtendedKeyUsage empty sequence / non-OID member / wrong top-level tag.
  (signals pure-tls:tls-decode-error
    (pure-tls::parse-extended-key-usage (hex-to-bytes "30 00")))
  (signals pure-tls:tls-decode-error
    (pure-tls::parse-extended-key-usage (hex-to-bytes "30 03 02 01 01")))
  (signals pure-tls:tls-decode-error
    (pure-tls::parse-extended-key-usage (hex-to-bytes "31 00")))
  (signals pure-tls:tls-decode-error
    (pure-tls::parse-extended-key-usage (hex-to-bytes "30 02 06 00")))
  (signals pure-tls:tls-decode-error
    (pure-tls::parse-extended-key-usage (hex-to-bytes "30 03 06 01 80")))
  ;; The combined first two OID arcs are themselves base-128 encoded.  Keep a
  ;; valid multi-octet first subidentifier working while malformed forms reject.
  (is (equal '((2 999 3))
             (pure-tls::parse-extended-key-usage
              (hex-to-bytes "30 05 06 03 88 37 03")))))

(test webpki-basic-constraints-boolean-is-canonical-der
  "BasicConstraints accepts canonical cA=TRUE but rejects malformed BOOLEANs
and the explicitly encoded DEFAULT FALSE value that DER requires omitted."
  (is (equal '(:ca t :path-length-constraint nil)
             (pure-tls::parse-basic-constraints
              (hex-to-bytes "30 03 01 01 ff"))))
  ;; BOOLEAN content must be exactly one octet and TRUE must be FF in DER.
  (signals pure-tls:tls-decode-error
    (pure-tls::parse-basic-constraints
     (hex-to-bytes "30 04 01 02 ff 00")))
  (signals pure-tls:tls-decode-error
    (pure-tls::parse-basic-constraints
     (hex-to-bytes "30 03 01 01 01")))
  ;; Even a canonical FALSE is the schema default and therefore must be absent.
  (signals pure-tls:tls-decode-error
    (pure-tls::parse-basic-constraints
     (hex-to-bytes "30 03 01 01 00")))
  ;; Long-form length for a one-octet BOOLEAN is not canonical DER.
  (signals pure-tls:tls-decode-error
    (pure-tls::parse-basic-constraints
     (hex-to-bytes "30 04 01 81 01 ff"))))

(test webpki-critical-extension-policy-is-centralized
  "OID recognition and critical-semantics enforcement are separate decisions."
  (is-true (pure-tls::enforced-critical-certificate-extension-p
            :basic-constraints))
  (is (not (pure-tls::enforced-critical-certificate-extension-p
            :name-constraints)))
  (is (not (pure-tls::enforced-critical-certificate-extension-p
            :certificate-policies)))
  (is (not (pure-tls::enforced-critical-certificate-extension-p
            :policy-constraints))))

(test webpki-rsa-server-key-must-be-at-least-2048-bits
  "A correctly signed 1024-bit RSA leaf is still too weak for TLS server auth."
  ;; Reject while parsing SubjectPublicKeyInfo, before the weak key can enter a
  ;; path object or reach any signature verifier.
  (signals pure-tls:tls-decode-error
    (%webpki-cert "weak-rsa-leaf")))

(test webpki-certificate-path-depth-is-bounded
  "The exact same valid ordered path rejects above the configured entry bound."
  (signals pure-tls:tls-certificate-error
    (%verify-webpki-intermediate "eku-server" :maximum-chain-depth 2))
  (is-true
   (%verify-webpki-intermediate "eku-server" :maximum-chain-depth 3)))

(test webpki-tls13-certificate-list-enforces-context-bound
  "TLS 1.3 rejects an oversized Certificate list before DER/path processing."
  (let* ((entries (loop repeat 3
                        collect (pure-tls::make-certificate-entry)))
         (message
          (pure-tls::make-handshake-message
            :type pure-tls::+handshake-certificate+
            :body (pure-tls::make-certificate-message
                   :certificate-list entries)))
         (handshake (pure-tls::make-client-handshake :verify-depth 2)))
    (signals pure-tls:tls-certificate-error
      (pure-tls::process-certificate handshake message))))

(test webpki-ordered-path-cannot-ignore-trailing-certificates
  "A path that reaches a configured anchor and then continues is not accepted
by scanning for a convenient earlier anchor."
  (let ((root (%webpki-cert "root"))
        (intermediate (%webpki-cert "eku-server"))
        (leaf (%webpki-cert "eku-server-leaf")))
    (signals pure-tls:tls-certificate-error
      (pure-tls::verify-certificate-chain
       (list leaf intermediate root) (list intermediate)
       (get-universal-time) nil :purpose :server-auth
       :trust-anchor-mode :replace :maximum-chain-depth 3))))

(test webpki-terminal-cross-sign-representation-matches-trust-anchor-key
  "A terminal certificate may represent a local trust anchor by the same CA
name and public key even when its DER differs, as with a cross-signed root."
  (let* ((root (%webpki-cert "root"))
         (terminal (pure-tls::copy-x509-certificate root))
         (different-der (copy-seq (pure-tls::x509-certificate-raw-der root))))
    (setf (aref different-der (1- (length different-der)))
          (logxor #xff (aref different-der (1- (length different-der)))))
    (setf (pure-tls::x509-certificate-raw-der terminal) different-der)
    (is (not (pure-tls::certificate-equal-p terminal root)))
    (is-true (pure-tls::certificate-matches-trust-anchor-p terminal root))
    ;; Matching only one half of the trust-anchor identity is never enough.
    (let* ((different-key (pure-tls::copy-x509-certificate root))
           (spki (copy-list
                  (pure-tls::x509-certificate-subject-public-key-info root)))
           (key (copy-seq (getf spki :public-key)))
           (spki-der (copy-seq (getf spki :spki-der))))
      (setf (aref key (1- (length key)))
            (logxor #x01 (aref key (1- (length key))))
            (aref spki-der (1- (length spki-der)))
            (logxor #x01 (aref spki-der (1- (length spki-der))))
            (getf spki :public-key) key
            (getf spki :spki-der) spki-der
            (pure-tls::x509-certificate-subject-public-key-info different-key)
            spki
            ;; The copy is a deliberately synthetic negative object; avoid
            ;; its original DER identity short-circuiting the field mismatch.
            (pure-tls::x509-certificate-raw-der different-key) nil)
      (is (not (pure-tls::certificate-matches-trust-anchor-p
                different-key root))))
    (let ((different-subject (pure-tls::copy-x509-certificate root)))
      (setf (pure-tls::x509-certificate-subject different-subject)
            (pure-tls::make-x509-name
             :rdns '((:common-name . "Different Root")))
            (pure-tls::x509-certificate-raw-der different-subject) nil)
      (is (not (pure-tls::certificate-matches-trust-anchor-p
                different-subject root))))))

;;;; The helpers below rebuild hostile DER from the raw fields of the real
;;;; fixtures.  That keeps every negative focused on one malformed boundary;
;;;; no private key or synthetic unsigned certificate is needed.

(defun %webpki-der-wrap (tag contents)
  (pure-tls::concat-octet-vectors
   (pure-tls::octet-vector tag)
   (pure-tls::encode-der-length (length contents))
   contents))

(defun %webpki-der-sequence (elements)
  (pure-tls::encode-der-sequence elements))

(defun %webpki-node-raw-children (node)
  (mapcar #'pure-tls::asn1-node-raw-bytes
          (pure-tls::asn1-children node)))

(defun %webpki-concat (vectors)
  (reduce #'pure-tls::concat-octet-vectors vectors
          :initial-value (pure-tls::make-octet-vector 0)))

(defun %webpki-rewrap-certificate (certificate &key tbs-raw outer-algorithm-raw
                                                   signature-raw extra-outer)
  (let* ((root (pure-tls::parse-der
                (pure-tls::x509-certificate-raw-der certificate)))
         (children (pure-tls::asn1-children root)))
    (%webpki-der-sequence
     (append (list (or tbs-raw
                       (pure-tls::asn1-node-raw-bytes (first children)))
                   (or outer-algorithm-raw
                       (pure-tls::asn1-node-raw-bytes (second children)))
                   (or signature-raw
                       (pure-tls::asn1-node-raw-bytes (third children))))
             extra-outer))))

(defun %webpki-mutated-tbs (certificate index replacement &key append insert-before-last)
  (let* ((root (pure-tls::parse-der
                (pure-tls::x509-certificate-raw-der certificate)))
         (tbs (first (pure-tls::asn1-children root)))
         (fields (%webpki-node-raw-children tbs)))
    (when replacement
      (setf (nth index fields) replacement))
    (when insert-before-last
      (setf fields
            (append (butlast fields) insert-before-last (last fields))))
    (%webpki-rewrap-certificate
     certificate :tbs-raw (%webpki-der-sequence (append fields append)))))

(defun %webpki-der-time (tag value)
  (%webpki-der-wrap tag (pure-tls::string-to-octets value)))

(defun %webpki-pss-algorithm-identifier (salt-length)
  (let* ((sha256-oid
           (hex-to-bytes "06 09 60 86 48 01 65 03 04 02 01"))
         (pss-oid
           (hex-to-bytes "06 09 2a 86 48 86 f7 0d 01 01 0a"))
         (mgf1-oid
           (hex-to-bytes "06 09 2a 86 48 86 f7 0d 01 01 08"))
         (hash-ai
           (%webpki-der-sequence (list sha256-oid (hex-to-bytes "05 00"))))
         (mgf-ai
           (%webpki-der-sequence (list mgf1-oid hash-ai)))
         (params
           (%webpki-der-sequence
            (list (%webpki-der-wrap #xa0 hash-ai)
                  (%webpki-der-wrap #xa1 mgf-ai)
                  (%webpki-der-wrap
                   #xa2 (pure-tls::encode-der-integer salt-length))))))
    (%webpki-der-sequence (list pss-oid params))))

(defun %webpki-certificate-entry-bytes (cert-data extensions-data)
  (pure-tls::concat-octet-vectors
   (pure-tls::encode-uint24 (length cert-data)) cert-data
   (pure-tls::encode-uint16 (length extensions-data)) extensions-data))

(defun %webpki-certificate-message-bytes (entries)
  (let ((list-bytes (%webpki-concat entries)))
    (pure-tls::concat-octet-vectors
     (pure-tls::octet-vector 0)
     (pure-tls::encode-uint24 (length list-bytes))
     list-bytes)))

(test webpki-der-parser-is-bounded-and-fully-consuming
  "DER rejects trailing bytes, parent overruns, excessive depth/nodes/size,
and hostile high-tag-number encodings before certificate materialization."
  (dolist (bytes (list (hex-to-bytes "02 01 01 00")
                       (hex-to-bytes "30 02 02 01 01")
                       (hex-to-bytes "1f 81")
                       (hex-to-bytes "1f 80 1f 00")
                       (hex-to-bytes "1f 1e 00")
                       (hex-to-bytes "1f 81 81 81 81 01 00")))
    (signals pure-tls:tls-error (pure-tls::parse-der bytes)))
  (let ((nested (hex-to-bytes "05 00")))
    (dotimes (i 34)
      (declare (ignore i))
      (setf nested (%webpki-der-sequence (list nested))))
    (signals pure-tls:tls-decode-error (pure-tls::parse-der nested)))
  (let ((nodes (pure-tls::make-octet-vector (* 2 4097))))
    (dotimes (i 4097)
      (setf (aref nodes (* 2 i)) #x05
            (aref nodes (1+ (* 2 i))) 0))
    (signals pure-tls:tls-decode-error
      (pure-tls::parse-der (%webpki-der-wrap #x30 nodes))))
  (signals pure-tls:tls-decode-error
    (pure-tls::parse-der
     (pure-tls::make-octet-vector
      (1+ pure-tls::+maximum-der-input-size+)))))

(test webpki-der-universal-forms-are-canonical
  "Universal containers/scalars, NULL, and empty BIT STRING forms are exact."
  (dolist (bytes (list (hex-to-bytes "10 00") ; primitive SEQUENCE
                       (hex-to-bytes "22 00") ; constructed INTEGER
                       (hex-to-bytes "05 01 00")
                       (hex-to-bytes "03 01 01")))
    (signals pure-tls:tls-decode-error (pure-tls::parse-der bytes))))

(test webpki-extension-schema-is-exact
  "Extension permits only OID, optional canonical TRUE, and OCTET STRING."
  (is (pure-tls::x509-extension-p
       (pure-tls::parse-x509-extension
        (pure-tls::parse-der
         (hex-to-bytes "30 0b 06 03 55 1d 0f 04 04 03 02 07 80")))))
  (dolist (bytes
           (list (hex-to-bytes
                  "30 0e 06 03 55 1d 0f 01 01 00 04 04 03 02 07 80")
                 (hex-to-bytes
                  "30 0d 06 03 55 1d 0f 04 04 03 02 07 80 05 00")
                 (hex-to-bytes "30 05 06 03 55 1d 0f")
                 (hex-to-bytes "30 06 02 01 0f 04 01 00")
                 (hex-to-bytes "30 08 06 03 55 1d 0f 02 01 00")))
    (signals pure-tls:tls-decode-error
      (pure-tls::parse-x509-extension (pure-tls::parse-der bytes)))))

(test webpki-certificate-and-tbs-shapes-are-exact
  "Certificate/TBSCertificate reject extra, duplicate, malformed version and
out-of-range serial fields rather than ignoring them."
  (let ((root (%webpki-cert "root")))
    (signals pure-tls:tls-decode-error
      (pure-tls:parse-certificate
       (%webpki-rewrap-certificate root :extra-outer
                                   (list (hex-to-bytes "05 00")))))
    (dolist (version (list (hex-to-bytes "a0 03 02 01 00")
                           (hex-to-bytes "a0 03 02 01 03")
                           (hex-to-bytes "80 01 02")
                           (hex-to-bytes "a0 06 02 01 02 02 01 02")))
      (signals pure-tls:tls-decode-error
        (pure-tls:parse-certificate (%webpki-mutated-tbs root 0 version))))
    (dolist (serial (list (hex-to-bytes "02 01 00")
                          (%webpki-der-wrap
                           #x02
                           (pure-tls::make-octet-vector 21 :initial-element 1))))
      (signals pure-tls:tls-decode-error
        (pure-tls:parse-certificate (%webpki-mutated-tbs root 1 serial))))
    (signals pure-tls:tls-decode-error
      (pure-tls:parse-certificate
       (%webpki-mutated-tbs root 0 nil :append (list (hex-to-bytes "05 00")))))
    (let* ((root-node (pure-tls::parse-der
                       (pure-tls::x509-certificate-raw-der root)))
           (tbs (first (pure-tls::asn1-children root-node)))
           (extensions (car (last (%webpki-node-raw-children tbs)))))
      (signals pure-tls:tls-decode-error
        (pure-tls:parse-certificate
         (%webpki-mutated-tbs root 0 nil :append (list extensions)))))))

(test webpki-validity-time-profile-is-exact
  "RFC 5280 UTC forms, calendar values, tag selection, and ordering are strict."
  (is (integerp (pure-tls::decode-utc-time "491231235959Z")))
  (is (integerp (pure-tls::decode-generalized-time "20500101000000Z")))
  (dolist (value '("2401010000Z" "240101000000+0000"
                   "240101000000Zjunk" "230229000000Z"))
    (signals pure-tls:tls-decode-error (pure-tls::decode-utc-time value)))
  (signals pure-tls:tls-decode-error
    (pure-tls::decode-generalized-time "20491231235959Z"))
  (let* ((root (%webpki-cert "root"))
         (inverted
           (%webpki-der-sequence
            (list (%webpki-der-time #x17 "300101000000Z")
                  (%webpki-der-time #x17 "290101000000Z"))))
         (wrong-tag
           (%webpki-der-sequence
            (list (%webpki-der-time #x16 "240101000000Z")
                  (%webpki-der-time #x17 "490101000000Z")))))
    (signals pure-tls:tls-decode-error
      (pure-tls:parse-certificate (%webpki-mutated-tbs root 4 inverted)))
    (signals pure-tls:tls-decode-error
      (pure-tls:parse-certificate (%webpki-mutated-tbs root 4 wrong-tag)))))

(test webpki-name-and-empty-subject-rules-are-exact
  "Issuer/RDN/ATV shapes and SET OF order are exact; empty subject needs critical SAN."
  (signals pure-tls:tls-decode-error
    (pure-tls::parse-name (pure-tls::parse-der (hex-to-bytes "30 00"))))
  (signals pure-tls:tls-decode-error
    (pure-tls::parse-name
     (pure-tls::parse-der (hex-to-bytes "30 02 31 00"))))
  (signals pure-tls:tls-decode-error
    (pure-tls::parse-name
     (pure-tls::parse-der
      (hex-to-bytes "30 10 31 0e 30 0c 06 03 55 04 03 0c 01 61 05 00"))))
  (let* ((common-name-oid (hex-to-bytes "06 03 55 04 03"))
         (attr-a (%webpki-der-sequence
                  (list common-name-oid (hex-to-bytes "0c 01 61"))))
         (attr-b (%webpki-der-sequence
                  (list common-name-oid (hex-to-bytes "0c 01 62"))))
         (ordered-rdn (%webpki-der-wrap
                       #x31 (%webpki-concat (list attr-a attr-b))))
         (reversed-rdn (%webpki-der-wrap
                        #x31 (%webpki-concat (list attr-b attr-a)))))
    (is (pure-tls::x509-name-p
         (pure-tls::parse-name
          (pure-tls::parse-der (%webpki-der-sequence (list ordered-rdn))))))
    (signals pure-tls:tls-decode-error
      (pure-tls::parse-name
       (pure-tls::parse-der (%webpki-der-sequence (list reversed-rdn))))))
  (let ((root (%webpki-cert "root"))
        (leaf (%webpki-cert "eku-server-leaf")))
    (signals pure-tls:tls-decode-error
      (pure-tls:parse-certificate
       (%webpki-mutated-tbs root 3 (hex-to-bytes "30 00"))))
    ;; The fixture SAN is deliberately noncritical, so emptying Subject must
    ;; fail even though a DNS SAN is present and non-empty.
    (signals pure-tls:tls-decode-error
      (pure-tls:parse-certificate
       (%webpki-mutated-tbs leaf 5 (hex-to-bytes "30 00"))))))

(test webpki-spki-and-rsa-key-shapes-are-exact
  "SPKI validates algorithm parameters, named curve/point, and exact RSA key."
  (let* ((root (%webpki-cert "root"))
         (rsa-der (getf (pure-tls::x509-certificate-subject-public-key-info root)
                        :public-key))
         (rsa-node (pure-tls::parse-der rsa-der))
         (rsa-fields (%webpki-node-raw-children rsa-node)))
    (signals pure-tls:tls-decode-error
      (pure-tls::parse-rsa-public-key-components
       (%webpki-der-sequence (append rsa-fields (list (hex-to-bytes "02 01 03"))))))
    (signals pure-tls:tls-decode-error
      (pure-tls::parse-rsa-public-key-components
       (%webpki-der-sequence
        (list (first rsa-fields) (hex-to-bytes "02 01 04"))))))
  (signals pure-tls:tls-decode-error
    (pure-tls::parse-rsa-public-key-components
     (%webpki-der-sequence
      (list (pure-tls::encode-der-integer
             (1+ (ash 1 pure-tls::+maximum-rsa-modulus-bits+)))
            (pure-tls::encode-der-integer 3)))))
  (let* ((ec-oid (hex-to-bytes "06 07 2a 86 48 ce 3d 02 01"))
         (p256-oid (hex-to-bytes "06 08 2a 86 48 ce 3d 03 01 07"))
         (unknown-oid (hex-to-bytes "06 03 2a 03 04"))
         (point (pure-tls::make-octet-vector 65 :initial-element 0)))
    (setf (aref point 0) #x04)
    (flet ((spki (curve point-bytes)
             (%webpki-der-sequence
              (list (%webpki-der-sequence (list ec-oid curve))
                    (%webpki-der-wrap
                     #x03 (pure-tls::concat-octet-vectors
                           (pure-tls::octet-vector 0) point-bytes))))))
      (signals pure-tls:tls-decode-error
        (pure-tls::parse-subject-public-key-info
         (pure-tls::parse-der (spki unknown-oid point))))
      (signals pure-tls:tls-decode-error
        (pure-tls::parse-subject-public-key-info
         (pure-tls::parse-der (spki p256-oid point))))
      (signals pure-tls:tls-decode-error
        (pure-tls::parse-subject-public-key-info
         (pure-tls::parse-der (spki p256-oid (subseq point 0 64))))))))

(test webpki-ec-public-point-coordinates-are-canonical-field-elements
  "A modulo-equivalent x=p encoding is rejected even when the curve equation holds."
  (let* ((prime pure-tls::+secp256r1-field-prime+)
         (curve-b
           #x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B)
         ;; P-256 has p = 3 (mod 4), so this is a square root of b and
         ;; (x=0,y) is a valid point. Ironclad also accepts x=p because its
         ;; equation check reduces coordinates modulo p; SEC 1 does not.
         (y (ironclad:expt-mod curve-b (/ (1+ prime) 4) prime))
         (canonical
           (pure-tls::concat-octet-vectors
            (pure-tls::octet-vector #x04)
            (ironclad:integer-to-octets 0 :n-bits 256)
            (ironclad:integer-to-octets y :n-bits 256)))
         (noncanonical
           (pure-tls::concat-octet-vectors
            (pure-tls::octet-vector #x04)
            (ironclad:integer-to-octets prime :n-bits 256)
            (ironclad:integer-to-octets y :n-bits 256))))
    (is (pure-tls::validate-ec-public-point :prime256v1 canonical))
    (is (ironclad:ec-decode-point :secp256r1 noncanonical))
    (signals pure-tls:tls-decode-error
      (pure-tls::validate-ec-public-point :prime256v1 noncanonical))))

(test webpki-algorithm-identifiers-and-pss-restrictions-are-exact
  "Inner/outer AlgorithmIdentifier bytes and issuer PSS key policy must match."
  (signals pure-tls:tls-decode-error
    (pure-tls::parse-algorithm-identifier-with-params
     (pure-tls::parse-der
      (%webpki-pss-algorithm-identifier
       (1+ pure-tls::+maximum-rsa-pss-salt-length+)))))
  (let* ((root (%webpki-cert "root"))
         (node (pure-tls::parse-der
                (pure-tls::x509-certificate-raw-der root)))
         (outer (second (pure-tls::asn1-children node)))
         (oid-only (%webpki-der-sequence
                    (list (pure-tls::asn1-node-raw-bytes
                           (first (pure-tls::asn1-children outer)))))))
    (signals pure-tls:tls-decode-error
      (pure-tls:parse-certificate
       (%webpki-rewrap-certificate root :outer-algorithm-raw oid-only)))
    ;; Matching OID but different RSA-PSS parameter DER is still a mismatch.
    (let* ((tbs (first (pure-tls::asn1-children node)))
           (fields (%webpki-node-raw-children tbs))
           (inner-pss (%webpki-pss-algorithm-identifier 32))
           (outer-pss (%webpki-pss-algorithm-identifier 48)))
      (setf (nth 2 fields) inner-pss)
      (signals pure-tls:tls-decode-error
        (pure-tls:parse-certificate
         (%webpki-rewrap-certificate
          root :tbs-raw (%webpki-der-sequence fields)
               :outer-algorithm-raw outer-pss)))))
  (signals pure-tls:tls-certificate-error
    (pure-tls::enforce-rsassa-pss-key-restrictions
     '(:algorithm :rsassa-pss) :sha256-with-rsa-encryption nil))
  (signals pure-tls:tls-certificate-error
    (pure-tls::enforce-rsassa-pss-key-restrictions
     '(:algorithm :rsassa-pss
       :algorithm-params (:hash :sha384 :salt-length 48))
     :rsassa-pss '(:hash :sha256 :salt-length 32)))
  (signals pure-tls:tls-certificate-error
    (pure-tls::enforce-rsassa-pss-key-restrictions
     '(:algorithm :rsassa-pss
       :algorithm-params (:hash :sha256 :salt-length 48))
     :rsassa-pss '(:hash :sha256 :salt-length 32)))
  (let* ((issuer (%webpki-cert "root"))
         (issuer-info
           (pure-tls::x509-certificate-subject-public-key-info issuer))
         (public-key
           (pure-tls::parse-rsa-public-key (getf issuer-info :public-key))))
    (is-true
     (pure-tls::validate-rsa-pss-salt-length-for-key public-key :sha256 32))
    (signals pure-tls:tls-certificate-error
      (pure-tls::validate-rsa-pss-salt-length-for-key
       public-key :sha512 pure-tls::+maximum-rsa-pss-salt-length+))))

(test webpki-subject-alt-name-profile-rejects-unsupported-forms
  "Unsupported GeneralName choices fail closed instead of bypassing critical SAN."
  (dolist (bytes (list (hex-to-bytes "30 02 a0 00")
                       (hex-to-bytes "30 03 88 01 2a")))
    (signals pure-tls:tls-decode-error
      (pure-tls::parse-subject-alt-name bytes))))

(test webpki-rsa-pss-declared-salt-length-is-enforced
  "PSS accepts a valid non-digest-length salt only when the caller declares it."
  (multiple-value-bind (private-key public-key)
      (ironclad:generate-key-pair :rsa :num-bits 2048)
    (let* ((message (pure-tls::string-to-octets
                     "bounded WebPKI PSS salt-length regression"))
           (public-key-der
             (%webpki-der-sequence
              (list (pure-tls::encode-der-integer
                     (ironclad:rsa-key-modulus public-key))
                    (pure-tls::encode-der-integer
                     (ironclad:rsa-key-exponent public-key)))))
           (short-salt-signature
             (ironclad:sign-message private-key message
                                    :pss :sha256 :salt-length 20))
           (tls-salt-signature
             (ironclad:sign-message private-key message
                                    :pss :sha256 :salt-length 32)))
      (is-true
       (ironclad:verify-signature public-key message short-salt-signature
                                  :pss :sha256 :salt-length 20))
      (is (not (ironclad:verify-signature
                public-key message short-salt-signature
                :pss :sha256 :salt-length 32)))
      ;; Omitting salt-length preserves Ironclad's historical digest-length
      ;; default, so it must also reject the 20-byte-salt vector.
      (is (not (ironclad:verify-signature
                public-key message short-salt-signature :pss :sha256)))
      (is-true
       (ironclad:verify-signature public-key message tls-salt-signature
                                  :pss :sha256 :salt-length 32))
      (is-true
       (ironclad:verify-signature public-key message tls-salt-signature
                                  :pss :sha256))
      ;; TLS CertificateVerify fixes sLen=hLen and therefore rejects the
      ;; otherwise valid 20-byte-salt signature for SHA-256.
      (finishes
        (pure-tls::verify-rsa-pss-signature
         public-key-der message tls-salt-signature :sha256))
      (signals pure-tls:tls-handshake-error
        (pure-tls::verify-rsa-pss-signature
         public-key-der message short-salt-signature :sha256))
      ;; Certificate signatures instead enforce the saltLength carried by the
      ;; certificate AlgorithmIdentifier, and hash the original TBS bytes once.
      (let* ((issuer
               (pure-tls::make-x509-certificate
                :subject-public-key-info
                (list :algorithm :rsa-encryption :public-key public-key-der)))
             (certificate
               (pure-tls::make-x509-certificate
                :tbs-raw message
                :signature-algorithm :rsassa-pss
                :signature-algorithm-params '(:hash :sha256 :salt-length 20)
                :signature short-salt-signature)))
        (is-true (pure-tls::verify-certificate-signature certificate issuer))
        (setf (pure-tls::x509-certificate-signature-algorithm-params certificate)
              '(:hash :sha256 :salt-length 32))
        (is (not (pure-tls::verify-certificate-signature certificate issuer)))))))

(test webpki-rsa-signature-representative-is-canonical
  "A real valid RSA certificate signature has one exact-width representative;
the mathematically equivalent s+n encoding and short encodings are rejected."
  (let* ((issuer (%webpki-cert "eku-server"))
         (leaf (%webpki-cert "eku-server-leaf"))
         (issuer-info
           (pure-tls::x509-certificate-subject-public-key-info issuer))
         (key (pure-tls::parse-rsa-public-key (getf issuer-info :public-key)))
         (n (ironclad:rsa-key-modulus key))
         (signature (pure-tls::x509-certificate-signature leaf))
         (width (length signature))
         (s-plus-n (+ (ironclad:octets-to-integer signature) n))
         (noncanonical
           (ironclad:integer-to-octets s-plus-n :n-bits (* 8 width)))
         (mutated (pure-tls::copy-x509-certificate leaf)))
    (is-true (pure-tls::verify-certificate-signature leaf issuer))
    (is (= width (length noncanonical)))
    (setf (pure-tls::x509-certificate-signature mutated) noncanonical)
    (is (not (pure-tls::verify-certificate-signature mutated issuer)))
    (is (not (pure-tls::rsa-signature-representative-valid-p
              key (subseq signature 1))))))

(test webpki-ecdsa-signature-shape-and-range-are-exact
  "Both TLS and certificate ECDSA paths require exactly two in-range positives."
  (let ((extra (hex-to-bytes
                "30 09 02 01 01 02 01 01 02 01 01"))
        (zero (hex-to-bytes "30 06 02 01 00 02 01 01"))
        (order
          #xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551))
    (dolist (signature (list extra zero
                             (%webpki-der-sequence
                              (list (pure-tls::encode-der-integer order)
                                    (pure-tls::encode-der-integer 1)))))
      (signals pure-tls:tls-error
        (pure-tls::parse-ecdsa-signature signature :secp256r1))
      (signals pure-tls:tls-error
        (pure-tls::parse-ecdsa-cert-signature signature :secp256r1)))))

(test webpki-tls13-certificate-wire-bounds-precede-materialization
  "TLS 1.3 bounds list bytes, entries, empty cert_data, and per-entry extension
count while preserving a valid entry with an empty extension block."
  (let* ((empty (pure-tls::make-octet-vector 0))
         (one (pure-tls::octet-vector 1))
         (entry (%webpki-certificate-entry-bytes one empty)))
    (is (= 1 (length
              (pure-tls::certificate-message-certificate-list
               (pure-tls::parse-certificate-message
                (%webpki-certificate-message-bytes (list entry)))))))
    (signals pure-tls:tls-handshake-error
      (pure-tls::parse-certificate-message
       (%webpki-certificate-message-bytes (list entry entry entry))
       :maximum-certificate-entries 2))
    (signals pure-tls:tls-handshake-error
      (pure-tls::parse-certificate-message
       (%webpki-certificate-message-bytes
        (list (%webpki-certificate-entry-bytes empty empty)))))
    (let ((pure-tls::*max-certificate-list-size* 5))
      (signals pure-tls:tls-handshake-error
        (pure-tls::parse-certificate-message
         (%webpki-certificate-message-bytes (list entry)))))
    (let ((extension-bytes
            (%webpki-concat
             (loop for type from 100
                   repeat (1+ pure-tls::+default-maximum-certificate-entry-extensions+)
                   collect (pure-tls::concat-octet-vectors
                            (pure-tls::encode-uint16 type)
                            (pure-tls::encode-uint16 0))))))
      (signals pure-tls:tls-handshake-error
        (pure-tls::parse-certificate-message
         (%webpki-certificate-message-bytes
          (list (%webpki-certificate-entry-bytes one extension-bytes))))))))

(test webpki-trust-anchor-identity-is-lossless
  "Flattened names/keys do not substitute for exact Name and SPKI DER identity."
  (let* ((root (%webpki-cert "root"))
         (different-name (pure-tls::copy-x509-certificate root))
         (name (pure-tls::x509-certificate-subject root))
         (raw-name (copy-seq (pure-tls::x509-name-raw-der name))))
    (setf (aref raw-name (1- (length raw-name)))
          (logxor 1 (aref raw-name (1- (length raw-name))))
          (pure-tls::x509-certificate-subject different-name)
          (pure-tls::make-x509-name :rdns (copy-tree (pure-tls::x509-name-rdns name))
                                    :raw-der raw-name)
          (pure-tls::x509-certificate-raw-der different-name) nil)
    (is (not (pure-tls::certificate-matches-trust-anchor-p different-name root)))
    (let* ((different-spki (pure-tls::copy-x509-certificate root))
           (spki (copy-list
                  (pure-tls::x509-certificate-subject-public-key-info root)))
           (raw-spki (copy-seq (getf spki :spki-der))))
      (setf (aref raw-spki (1- (length raw-spki)))
            (logxor 1 (aref raw-spki (1- (length raw-spki))))
            (getf spki :spki-der) raw-spki
            (pure-tls::x509-certificate-subject-public-key-info different-spki) spki
            (pure-tls::x509-certificate-raw-der different-spki) nil)
      (is (not (pure-tls::certificate-matches-trust-anchor-p
                different-spki root))))))

(test webpki-ordered-issuer-name-is-lossless
  "RDN grouping/encoding cannot be erased when linking an ordered path."
  (let* ((leaf (%webpki-cert "eku-server-leaf"))
         (issuer (%webpki-cert "eku-server"))
         (different (pure-tls::copy-x509-certificate issuer))
         (subject (pure-tls::x509-certificate-subject issuer))
         (raw (copy-seq (pure-tls::x509-name-raw-der subject))))
    (is-true (pure-tls::certificate-issued-by-p leaf issuer))
    (setf (aref raw (1- (length raw)))
          (logxor 1 (aref raw (1- (length raw))))
          (pure-tls::x509-certificate-subject different)
          (pure-tls::make-x509-name
           :rdns (copy-tree (pure-tls::x509-name-rdns subject)) :raw-der raw))
    (is (not (pure-tls::certificate-issued-by-p leaf different)))))

(defun run-security-regression-tests ()
  "Run the security regression suite.  Returns T if all tests pass."
  (format t "~&=== Running pure-tls Security Regression Tests ===~%~%")
  (run! 'security-regression-tests))
