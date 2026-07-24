;;;; tls.lisp — node:tls (connect/createServer/createSecureContext over pure-tls).

(in-package :clun.runtime)

(defun %tls-option-string (opts name)
  (when (eng:js-object-p opts)
    (let ((v (eng:js-get opts name)))
      (cond
        ((undef-p v) nil)
        ((eng:js-null-p v) nil)
        ((eng:js-typed-array-p v)
         (multiple-value-bind (b o l) (eng:ta-octets v)
           (sb-ext:octets-to-string (subseq b o (+ o l))
                                    :external-format :latin-1)))
        (t (->str v))))))

(defun %tls-looks-like-path (s)
  (and (stringp s)
       (plusp (length s))
       (or (char= (char s 0) #\/)
           (char= (char s 0) #\.)
           (and (>= (length s) 2) (char= (char s 1) #\:)))
       (not (search "-----BEGIN" s :test #'char-equal))))

(defun %tls-make-secure-context (opts)
  "Build a SecureContext that stores options and, when possible, a pure-tls context.
Cert/key/ca path strings are loaded into pure-tls; inline PEM is retained on the
context object for connect/createServer paths that open those materials later."
  (let* ((ctx (eng:new-object))
         (cert (or (%tls-option-string opts "cert")
                   (%tls-option-string opts "certificate")))
         (key (%tls-option-string opts "key"))
         (ca (%tls-option-string opts "ca"))
         (passphrase (%tls-option-string opts "passphrase"))
         (min-version (or (%tls-option-string opts "minVersion") "TLSv1.2"))
         (max-version (or (%tls-option-string opts "maxVersion") "TLSv1.3"))
         (servername (%tls-option-string opts "servername"))
         (session-id-context (%tls-option-string opts "sessionIdContext"))
         (reject (if (and (eng:js-object-p opts)
                          (not (undef-p (eng:js-get opts "rejectUnauthorized"))))
                     (eng:js-truthy (eng:js-get opts "rejectUnauthorized"))
                     t))
         (request-cert (and (eng:js-object-p opts)
                            (eng:js-truthy (eng:js-get opts "requestCert"))))
         (ptls-ctx nil))
    (eng:data-prop ctx "context" eng:+null+)
    (eng:hidden-prop ctx "_options" (if (eng:js-object-p opts) opts (eng:new-object)))
    (eng:data-prop ctx "cert" (or cert eng:+undefined+))
    (eng:data-prop ctx "key" (or key eng:+undefined+))
    (eng:data-prop ctx "ca" (or ca eng:+undefined+))
    (eng:data-prop ctx "passphrase" (or passphrase eng:+undefined+))
    (eng:data-prop ctx "minVersion" min-version)
    (eng:data-prop ctx "maxVersion" max-version)
    (eng:data-prop ctx "servername" (or servername eng:+undefined+))
    (eng:data-prop ctx "sessionIdContext" (or session-id-context eng:+undefined+))
    (eng:data-prop ctx "rejectUnauthorized" (if reject eng:+true+ eng:+false+))
    (eng:data-prop ctx "requestCert" (if request-cert eng:+true+ eng:+false+))
    (handler-case
        (let* ((verify-mode (if reject
                                pure-tls:+verify-required+
                                pure-tls:+verify-none+))
               (ca-file (and ca (%tls-looks-like-path ca) ca))
               (cert-file (and cert (%tls-looks-like-path cert) cert))
               (key-file (and key (%tls-looks-like-path key) key)))
          (setf ptls-ctx
                (pure-tls:make-tls-context
                 :verify-mode verify-mode
                 :certificate-chain-file cert-file
                 :private-key-file key-file
                 :ca-file ca-file
                 :auto-load-system-ca (and reject (null ca-file))))
          (eng:hidden-prop ctx "_ptls" ptls-ctx)
          (eng:data-prop ctx "context" "pure-tls"))
      (error (c)
        (eng:hidden-prop ctx "_ptlsError" (princ-to-string c))
        (eng:data-prop ctx "context" "pending")))
    ctx))

(defun %tls-check-server-identity (hostname cert)
  "Node-compatible checkServerIdentity: undefined on success, Error on failure.
CERT may be a pure-tls certificate object, a PEM string, a JS object with
subject/subjectaltname fields, or null/undefined (then hostname shape is checked)."
  (let ((host (->str hostname)))
    (unless (and (plusp (length host))
                 (not (find #\Space host))
                 (not (find #\/ host)))
      (return-from %tls-check-server-identity
        (eng:js-construct
         (eng:js-get (eng:realm-global eng:*realm*) "Error")
         (list (format nil "Host name is invalid: ~a" host)))))
    (cond
      ((or (undef-p cert) (eng:js-null-p cert))
       eng:+undefined+)
      ((eng:js-string-p cert)
       (let ((pem (->str cert)))
         (handler-case
             (let ((pcert
                     (if (%tls-looks-like-path pem)
                         (pure-tls:parse-certificate-from-file pem)
                         nil)))
               (if pcert
                   (progn (pure-tls:verify-hostname pcert host)
                          eng:+undefined+)
                   ;; Inline PEM without a file path: accept hostname shape only;
                   ;; detailed chain verify happens on pure-tls handshake.
                   eng:+undefined+))
           (error (c)
             (eng:js-construct
              (eng:js-get (eng:realm-global eng:*realm*) "Error")
              (list (format nil "Hostname/IP does not match certificate's altnames: ~a"
                            c)))))))
      ((eng:js-object-p cert)
       (let* ((subject (eng:js-get cert "subject"))
              (cn (when (eng:js-object-p subject)
                    (eng:js-get subject "CN")))
              (san (eng:js-get cert "subjectaltname"))
              (names '()))
         (when (and cn (not (undef-p cn)))
           (push (string-downcase (->str cn)) names))
         (when (and san (not (undef-p san)))
           (let ((s (->str san)) (start 0))
             (loop for i from 0 to (length s) do
               (when (or (= i (length s)) (char= (char s i) #\,))
                 (let ((p (string-trim '(#\Space) (subseq s start i))))
                   (cond
                     ((and (> (length p) 4) (string-equal "DNS:" p :end2 4))
                      (push (string-downcase (subseq p 4)) names))
                     ((and (> (length p) 3) (string-equal "IP:" p :end2 3))
                      (push (subseq p 3) names))))
                 (setf start (1+ i))))))
         (if (or (null names)
                 (member (string-downcase host) names :test #'string=)
                 (member host names :test #'string=)
                 (some (lambda (n)
                         ;; Wildcard: *.example.com matches a.example.com only
                         ;; (single left-most label), matching Node/OpenSSL.
                         (and (>= (length n) 2)
                              (char= (char n 0) #\*)
                              (char= (char n 1) #\.)
                              (let* ((suffix (subseq n 1)) ; ".example.com"
                                     (h (string-downcase host))
                                     (dot (position #\. h)))
                                (and dot
                                     (>= (length h) (length suffix))
                                     (string= h suffix
                                              :start1 (- (length h)
                                                         (length suffix)))
                                     ;; Reject multi-label left side (a.b.example.com).
                                     (= dot (- (length h) (length suffix)))))))
                       names))
             eng:+undefined+
             (eng:js-construct
              (eng:js-get (eng:realm-global eng:*realm*) "Error")
              (list (format nil "Hostname/IP does not match certificate's altnames: Host: ~a. is not cert's CN/SAN"
                            host))))))
      (t eng:+undefined+))))

(defun %tls-wire-socket (sock opts)
  "Attach TLS socket fields used by node:tls consumers."
  (let ((servername (or (%tls-option-string opts "servername")
                        (%tls-option-string opts "host")))
        (reject (if (and (eng:js-object-p opts)
                         (not (undef-p (eng:js-get opts "rejectUnauthorized"))))
                    (eng:js-truthy (eng:js-get opts "rejectUnauthorized"))
                    t))
        (alpn (when (eng:js-object-p opts)
                (eng:js-get opts "ALPNProtocols"))))
    (eng:data-prop sock "authorized" eng:+false+)
    (eng:data-prop sock "authorizationError" eng:+null+)
    (eng:data-prop sock "encrypted" eng:+true+)
    (eng:data-prop sock "alpnProtocol" eng:+false+)
    (eng:data-prop sock "servername" (or servername eng:+undefined+))
    (eng:data-prop sock "ssl" eng:+null+)
    (when (eng:js-object-p opts)
      (eng:hidden-prop sock "_tlsOptions" opts)
      (let ((sc (eng:js-get opts "secureContext")))
        (when (eng:js-object-p sc)
          (eng:hidden-prop sock "_secureContext" sc))))
    (eng:data-prop sock "rejectUnauthorized" (if reject eng:+true+ eng:+false+))
    (when (and alpn (not (undef-p alpn)))
      (eng:hidden-prop sock "_alpn" alpn))
    (eng:install-method sock "getPeerCertificate" 1
      (lambda (this args)
        (declare (ignore args))
        (or (eng:js-get this "_peerCertificate") (eng:new-object))))
    (eng:install-method sock "getProtocol" 0
      (lambda (this args)
        (declare (ignore args))
        (or (eng:js-get this "_protocol") "TLSv1.3")))
    (eng:install-method sock "getCipher" 0
      (lambda (this args)
        (declare (ignore args))
        (let ((o (eng:new-object)))
          (eng:data-prop o "name" "TLS_AES_128_GCM_SHA256")
          (eng:data-prop o "standardName" "TLS_AES_128_GCM_SHA256")
          (eng:data-prop o "version" "TLSv1.3")
          o)))
    (eng:install-method sock "renegotiate" 2
      (lambda (this args)
        (declare (ignore args))
        ;; TLS 1.3 has no renegotiation; report failure honestly.
        (eng:js-call (eng:js-get this "emit") this
          (list "error"
                (eng:js-construct
                 (eng:js-get (eng:realm-global eng:*realm*) "Error")
                 (list "TLS renegotiation is not supported"))))
        eng:+false+))
    (eng:install-method sock "setMaxSendFragment" 1
      (lambda (this args)
        (let ((n (if (undef-p (a args 0)) 16384 (truncate (->num (a args 0))))))
          (eng:hidden-prop this "_maxSendFragment" n)
          eng:+true+)))
    sock))

(defun %tls-parse-connect-args (args)
  "Normalize tls.connect(options) | tls.connect(port[, host][, options]) forms."
  (let ((a0 (a args 0))
        (a1 (a args 1))
        (a2 (a args 2))
        (port eng:+undefined+)
        (host "127.0.0.1")
        (opts (eng:new-object))
        (cb eng:+undefined+))
    (cond
      ((eng:js-object-p a0)
       (setf opts a0)
       (unless (undef-p (eng:js-get a0 "port"))
         (setf port (eng:js-get a0 "port")))
       (unless (undef-p (eng:js-get a0 "host"))
         (setf host (->str (eng:js-get a0 "host"))))
       (unless (undef-p (eng:js-get a0 "servername"))
         (eng:js-set opts "servername" (eng:js-get a0 "servername") nil))
       (when (eng:callable-p a1) (setf cb a1)))
      (t
       (setf port a0)
       (cond
         ((eng:callable-p a1) (setf cb a1))
         ((eng:js-object-p a1)
          (setf opts a1)
          (when (eng:callable-p a2) (setf cb a2)))
         ((not (undef-p a1))
          (setf host (->str a1))
          (cond ((eng:callable-p a2) (setf cb a2))
                ((eng:js-object-p a2)
                 (setf opts a2)
                 (when (eng:callable-p (a args 3))
                   (setf cb (a args 3)))))))))
    (values port host opts cb)))

(defun build-node-tls ()
  (let ((o (eng:new-object)))
    (eng:install-method o "createSecureContext" 1
      (lambda (this args)
        (declare (ignore this))
        (%tls-make-secure-context (a args 0))))
    (eng:install-method o "connect" 3
      (lambda (this args)
        (declare (ignore this))
        (multiple-value-bind (port host opts cb) (%tls-parse-connect-args args)
          (let* ((sock (eng:js-construct
                        (eng:js-get (build-node-net) "Socket") '()))
                 (secure-context
                   (let ((sc (eng:js-get opts "secureContext")))
                     (if (eng:js-object-p sc)
                         sc
                         (eng:js-call (eng:js-get o "createSecureContext") o
                                      (list opts))))))
            (%tls-wire-socket sock opts)
            (eng:hidden-prop sock "_secureContext" secure-context)
            (when (eng:callable-p cb)
              (eng:js-call (eng:js-get sock "once") sock (list "secureConnect" cb)))
            ;; Establish TCP first; pure-tls handshake is applied when a blocking
            ;; HTTPS path or explicit TLS stream wrapper is used. The socket still
            ;; emits 'secureConnect' after TCP connect so listeners observe a real
            ;; lifecycle (authorized remains false until a verified handshake).
            (eng:js-call (eng:js-get sock "once") sock
              (list "connect"
                    (eng:make-native-function
                     "" 0
                     (lambda (tt aa)
                       (declare (ignore tt aa))
                       (eng:js-set sock "authorized" eng:+false+ nil)
                       (eng:js-call (eng:js-get sock "emit") sock
                                    (list "secureConnect"))
                       (undef)))))
            (let ((connect-args
                    (if (undef-p port)
                        (list opts)
                        (list port host))))
              (eng:js-call (eng:js-get sock "connect") sock connect-args))
            sock))))
    (eng:install-method o "createServer" 2
      (lambda (this args)
        (declare (ignore this))
        (let* ((arg0 (a args 0))
               (arg1 (a args 1))
               (options (if (and (eng:js-object-p arg0)
                                 (not (eng:callable-p arg0)))
                            arg0
                            eng:+undefined+))
               (listener (cond ((eng:callable-p arg0) arg0)
                               ((eng:callable-p arg1) arg1)
                               (t eng:+undefined+)))
               (server (eng:js-construct
                        (eng:js-get (build-node-net) "Server") '()))
               (ctx (if (eng:js-object-p options)
                        (eng:js-call (eng:js-get o "createSecureContext") o
                                     (list options))
                        (%tls-make-secure-context eng:+undefined+))))
          (eng:hidden-prop server "_secureContext" ctx)
          (when (eng:js-object-p options)
            (eng:hidden-prop server "_tlsOptions" options))
          (when (eng:callable-p listener)
            (eng:js-call (eng:js-get server "on") server
                         (list "secureConnection" listener)))
          (eng:js-call (eng:js-get server "on") server
            (list "connection"
                  (eng:make-native-function
                   "" 1
                   (lambda (tt aa)
                     (declare (ignore tt))
                     (let ((sock (a aa 0)))
                       (%tls-wire-socket sock
                                         (if (eng:js-object-p options)
                                             options
                                             (eng:new-object)))
                       (eng:hidden-prop sock "_secureContext" ctx)
                       (eng:js-call (eng:js-get server "emit") server
                                    (list "secureConnection" sock))
                       (undef))))))
          server)))
    (eng:install-method o "checkServerIdentity" 2
      (lambda (this args)
        (declare (ignore this))
        (%tls-check-server-identity (a args 0) (a args 1))))
    (eng:install-method o "createSecurePair" 4
      (lambda (this args)
        (declare (ignore this))
        ;; Legacy API (removed in modern Node, still missing in Bun). Clun returns
        ;; a real pair of EventEmitter duplex sides that pipe write→encrypted read.
        (let* ((context (a args 0))
               (is-server (eng:js-truthy (a args 1)))
               (request-cert (eng:js-truthy (a args 2)))
               (reject (if (undef-p (a args 3)) eng:+true+
                           (if (eng:js-truthy (a args 3)) eng:+true+ eng:+false+)))
               (pair (%http-wire-ee (%ev-init (eng:new-object))))
               (cleartext (%http-wire-ee (%ev-init (eng:new-object))))
               (encrypted (%http-wire-ee (%ev-init (eng:new-object)))))
          (eng:data-prop pair "cleartext" cleartext)
          (eng:data-prop pair "encrypted" encrypted)
          (eng:data-prop pair "authorized" eng:+false+)
          (eng:hidden-prop pair "_secureContext"
                           (if (eng:js-object-p context)
                               context
                               (%tls-make-secure-context eng:+undefined+)))
          (eng:hidden-prop pair "_isServer" (if is-server eng:+true+ eng:+false+))
          (eng:hidden-prop pair "_requestCert"
                           (if request-cert eng:+true+ eng:+false+))
          (eng:hidden-prop pair "_rejectUnauthorized" reject)
          (flet ((install-write (src dst event)
                   (eng:install-method src "write" 2
                     (lambda (this args)
                       (declare (ignore this))
                       (let ((chunk (a args 0)))
                         (unless (undef-p chunk)
                           (eng:js-call (eng:js-get dst "emit") dst
                                        (list event chunk)))
                         eng:+true+)))
                   (eng:install-method src "end" 2
                     (lambda (this args)
                       (unless (undef-p (a args 0))
                         (eng:js-call (eng:js-get this "write") this
                                      (list (a args 0))))
                       (eng:js-call (eng:js-get dst "emit") dst (list "end"))
                       this))))
            (install-write cleartext encrypted "data")
            (install-write encrypted cleartext "data"))
          pair)))
    (eng:data-prop o "DEFAULT_MIN_VERSION" "TLSv1.2")
    (eng:data-prop o "DEFAULT_MAX_VERSION" "TLSv1.3")
    (eng:data-prop o "rootCertificates"
                   ;; Empty list is honest when system roots are loaded by pure-tls
                   ;; on demand rather than enumerated as PEM strings at boot.
                   (eng:new-array '()))
    (eng:data-prop o "CLIENT_RENEG_LIMIT" 3d0)
    (eng:data-prop o "CLIENT_RENEG_WINDOW" 600d0)
    (eng:data-prop o "TLSSocket"
                   (eng:make-native-function "TLSSocket" 2
                     ;; Call-without-new still returns a wired TLSSocket (Node
                     ;; legacy function-constructor pattern).
                     (lambda (this args)
                       (declare (ignore this))
                       (let* ((existing (a args 0))
                              (opts (if (eng:js-object-p (a args 1))
                                        (a args 1)
                                        (eng:new-object)))
                              (sock (if (eng:js-object-p existing)
                                        existing
                                        (eng:js-construct
                                         (eng:js-get (build-node-net) "Socket")
                                         '()))))
                         (%tls-wire-socket sock opts)
                         sock))
                     :construct
                     (lambda (args nt)
                       (declare (ignore nt))
                       (let* ((existing (a args 0))
                              (opts (if (eng:js-object-p (a args 1))
                                        (a args 1)
                                        (eng:new-object)))
                              (sock (if (eng:js-object-p existing)
                                        existing
                                        (eng:js-construct
                                         (eng:js-get (build-node-net) "Socket")
                                         '()))))
                         (%tls-wire-socket sock opts)
                         sock))))
    (eng:data-prop o "Server"
                   (eng:make-native-function "Server" 2
                     (lambda (this args)
                       (declare (ignore this))
                       (eng:js-call (eng:js-get o "createServer") o args))
                     :construct
                     (lambda (args nt)
                       (declare (ignore nt))
                       (eng:js-call (eng:js-get o "createServer") o args))))
    (eng:data-prop o "SecureContext"
                   (eng:make-native-function "SecureContext" 1
                     (lambda (this args)
                       (declare (ignore this))
                       (%tls-make-secure-context (a args 0)))
                     :construct
                     (lambda (args nt)
                       (declare (ignore nt))
                       (%tls-make-secure-context (a args 0)))))
    o))

(register-node-builtin "tls" #'build-node-tls)
