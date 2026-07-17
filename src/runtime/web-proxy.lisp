;;;; web-proxy.lisp -- fetch HTTP proxy selection and request shaping (Phase 28).
;;;; Pure Common Lisp; no system proxy helper or external process participates.

(in-package :clun.runtime)

(defstruct (fetch-proxy (:constructor %make-fetch-proxy))
  host port authorization)

(defparameter *fetch-environment-reader* #'sb-ext:posix-getenv
  "Environment lookup hook. Tests bind this rather than mutating process-global state.")

(defun %fetch-environment (name)
  (funcall *fetch-environment-reader* name))

(defun %proxy-disabled-value-p (value)
  (or (null value)
      (zerop (length value))
      (string= value "''")
      (string= value "\"\"")))

(defun %proxy-unbracket-host (host)
  (if (and (> (length host) 1)
           (char= (char host 0) #\[)
           (char= (char host (1- (length host))) #\]))
      (subseq host 1 (1- (length host)))
      host))

(defun %proxy-base64 (string)
  (let* ((alphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
         (bytes (sb-ext:string-to-octets string :external-format :utf-8))
         (length (length bytes)))
    (with-output-to-string (output)
      (loop for offset from 0 below length by 3
            for remaining = (- length offset)
            for first = (aref bytes offset)
            for second = (if (> remaining 1) (aref bytes (1+ offset)) 0)
            for third = (if (> remaining 2) (aref bytes (+ offset 2)) 0)
            for bits = (logior (ash first 16) (ash second 8) third) do
              (write-char (char alphabet (ldb (byte 6 18) bits)) output)
              (write-char (char alphabet (ldb (byte 6 12) bits)) output)
              (write-char (if (> remaining 1)
                              (char alphabet (ldb (byte 6 6) bits))
                              #\=)
                          output)
              (write-char (if (> remaining 2)
                              (char alphabet (ldb (byte 6 0) bits))
                              #\=)
                          output)))))

(defun %parse-fetch-proxy (value)
  "Parse Bun-compatible string proxy syntax, including an implicit http:// scheme."
  (when (%proxy-disabled-value-p value)
    (return-from %parse-fetch-proxy nil))
  (let* ((normalized
           (if (nth-value 0 (%scheme-prefix value))
               value
               (concatenate 'string "http://" value)))
         (record (%parse-url normalized)))
    (unless (string= (ur-scheme record) "http")
      (error "fetch: unsupported proxy scheme ~a" (ur-scheme record)))
    (unless (and (ur-host record) (plusp (length (ur-host record))))
      (error "fetch: proxy URL has no host"))
    (when (or (not (string= (or (ur-path record) "/") "/"))
              (ur-query record) (ur-fragment record))
      (error "fetch: proxy URL must not contain a path, query, or fragment"))
    (let* ((username (%pct-decode (ur-username record)))
           (password (%pct-decode (ur-password record)))
           (authorization
             (and (or (plusp (length username)) (plusp (length password)))
                  (concatenate 'string "Basic "
                               (%proxy-base64
                                (concatenate 'string username ":" password))))))
      (%make-fetch-proxy
       :host (%proxy-unbracket-host (ur-host record))
       :port (or (ur-port record) 80)
       :authorization authorization))))

(defun %proxy-trim-host (host)
  (string-downcase
   (string-right-trim "." (%proxy-unbracket-host host))))

(defun %proxy-domain-match-p (host pattern)
  (let* ((candidate (%proxy-trim-host host))
         (raw (string-left-trim "." (string-downcase pattern)))
         (suffix (string-right-trim "." raw))
         (candidate-length (length candidate))
         (suffix-length (length suffix)))
    (and (plusp suffix-length)
         (or (string= candidate suffix)
             (and (> candidate-length suffix-length)
                  (string= candidate suffix
                           :start1 (- candidate-length suffix-length))
                  (char= (char candidate
                               (- candidate-length suffix-length 1))
                         #\.))))))

(defun %proxy-entry-host-port (entry)
  "Return a NO_PROXY entry's host and optional port. Empty/malformed entries return NIL."
  (let* ((trimmed (string-trim '(#\Space #\Tab #\Return #\Newline) entry))
         (value
           (if (search "://" trimmed)
               (subseq trimmed (+ (search "://" trimmed) 3))
               trimmed)))
    (cond
      ((zerop (length value)) (values nil nil))
      ((string= value "*") (values "*" nil))
      ((char= (char value 0) #\[)
       (let ((close (position #\] value)))
         (if (null close)
             (values nil nil)
             (let ((tail (subseq value (1+ close))))
               (cond
                 ((zerop (length tail))
                  (values (subseq value 1 close) nil))
                 ((and (> (length tail) 1)
                       (char= (char tail 0) #\:)
                       (every #'digit-char-p (subseq tail 1)))
                  (values (subseq value 1 close)
                          (parse-integer tail :start 1)))
                 (t (values nil nil)))))))
      (t
       (let ((colon (position #\: value :from-end t)))
         (if (and colon
                  (= colon (position #\: value))
                  (< colon (1- (length value)))
                  (every #'digit-char-p (subseq value (1+ colon))))
             (values (subseq value 0 colon)
                     (parse-integer value :start (1+ colon)))
             (values value nil)))))))

(defun %no-proxy-match-p (host port value)
  "Node/curl-style NO_PROXY host/domain matching with exact optional port semantics."
  (and value
       (some
        (lambda (entry)
          (multiple-value-bind (entry-host entry-port)
              (%proxy-entry-host-port entry)
            (and entry-host
                 (or (string= entry-host "*")
                     (and (or (null entry-port) (= entry-port port))
                          (%proxy-domain-match-p host entry-host))))))
        (%url-split value #\,))))

(defun %fetch-proxy-environment-value (scheme)
  (let ((value
          (if (string= scheme "https")
              (or (%fetch-environment "https_proxy")
                  (%fetch-environment "HTTPS_PROXY")
                  (%fetch-environment "http_proxy")
                  (%fetch-environment "HTTP_PROXY"))
              (or (%fetch-environment "http_proxy")
                  (%fetch-environment "HTTP_PROXY")))))
    (unless (%proxy-disabled-value-p value) value)))

(defun %fetch-select-proxy (info record port)
  (let* ((specified-p (getf info :proxy-specified-p))
         (explicit (getf info :proxy))
         (value
           (if specified-p
               (cond
                 ((eng:js-string-p explicit) (eng:to-string explicit))
                 ((or (eng:js-undefined-p explicit)
                      (eq explicit eng:+null+)) nil)
                 (t (error "fetch: proxy must be a string")))
               (%fetch-proxy-environment-value (ur-scheme record))))
         (no-proxy (or (%fetch-environment "NO_PROXY")
                       (%fetch-environment "no_proxy"))))
    (unless (or (%proxy-disabled-value-p value)
                (%no-proxy-match-p (ur-host record) port no-proxy))
      (%parse-fetch-proxy value))))

(defun %fetch-remove-hop-headers (headers)
  (remove-if
   (lambda (header)
     (member (car header) '("proxy-authorization" "proxy-connection")
             :test #'string-equal))
   headers))

(defun %fetch-proxy-authorization (proxy headers)
  (or (fetch-proxy-authorization proxy)
      (cdr (assoc "proxy-authorization" headers :test #'string-equal))))

(defun %fetch-http-proxy-headers (proxy headers)
  (let ((authorization (%fetch-proxy-authorization proxy headers)))
    (append (%fetch-remove-hop-headers headers)
            (list (cons "Proxy-Connection" "close"))
            (when authorization
              (list (cons "Proxy-Authorization" authorization))))))

(defun %fetch-absolute-target (record)
  (let ((target (copy-url-record record)))
    (setf (ur-username target) ""
          (ur-password target) ""
          (ur-fragment target) nil)
    (%serialize-url target)))
