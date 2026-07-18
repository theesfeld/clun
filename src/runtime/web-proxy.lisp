;;;; web-proxy.lisp -- fetch HTTP proxy selection and request shaping (Phase 28).
;;;; Pure Common Lisp; no system proxy helper or external process participates.

(in-package :clun.runtime)

(defstruct (fetch-proxy (:constructor %make-fetch-proxy))
  host port authorization
  ;; Extra hop headers from proxy: { url, headers } (CONNECT / absolute-form only).
  (extra-headers nil :type list))

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

(defun %parse-fetch-proxy (value &key extra-headers)
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
       :authorization authorization
       :extra-headers (copy-list extra-headers)))))

(defun %coerce-proxy-extra-headers (headers-value)
  "Normalize proxy.headers object/Headers into an alist of string pairs."
  (cond
    ((or (null headers-value)
         (eng:js-undefined-p headers-value)
         (eq headers-value eng:+null+))
     nil)
    ((js-headers-p headers-value)
     (%headers-raw-alist headers-value))
    ((eng:js-object-p headers-value)
     (%coerce-headers-init headers-value))
    (t (error "fetch: proxy.headers must be a Headers object or record"))))

(defun %coerce-fetch-proxy (value)
  "Accept string proxy URLs or Bun object form { url, headers? }."
  (cond
    ((or (null value)
         (eng:js-undefined-p value)
         (eq value eng:+null+))
     nil)
    ((eng:js-string-p value)
     (%parse-fetch-proxy (eng:to-string value)))
    ((stringp value)
     (%parse-fetch-proxy value))
    ((eng:js-object-p value)
     (let* ((url-val (eng:js-get value "url"))
            (headers-val (eng:js-get value "headers"))
            (url
              (cond
                ((eng:js-string-p url-val) (eng:to-string url-val))
                ((stringp url-val) url-val)
                ((or (eng:js-undefined-p url-val) (null url-val)
                     (eq url-val eng:+null+))
                 (error "fetch: proxy object requires a url string"))
                (t (eng:to-string url-val))))
            (extra (%coerce-proxy-extra-headers headers-val)))
       (%parse-fetch-proxy url :extra-headers extra)))
    (t (error "fetch: proxy must be a string or { url, headers }"))))

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
         (proxy
           (if specified-p
               (cond
                 ((or (eng:js-undefined-p explicit)
                      (eq explicit eng:+null+))
                  nil)
                 ((and (eng:js-string-p explicit)
                       (%proxy-disabled-value-p (eng:to-string explicit)))
                  nil)
                 (t (%coerce-fetch-proxy explicit)))
               (let ((env (%fetch-proxy-environment-value (ur-scheme record))))
                 (and env (%parse-fetch-proxy env)))))
         (no-proxy (or (%fetch-environment "NO_PROXY")
                       (%fetch-environment "no_proxy"))))
    (unless (or (null proxy)
                (%no-proxy-match-p (ur-host record) port no-proxy))
      proxy)))

(defun %fetch-remove-hop-headers (headers)
  (remove-if
   (lambda (header)
     (member (car header) '("proxy-authorization" "proxy-connection")
             :test #'string-equal))
   headers))

(defun %fetch-proxy-authorization (proxy headers)
  (or (fetch-proxy-authorization proxy)
      (cdr (assoc "proxy-authorization" headers :test #'string-equal))))

(defun %fetch-merge-proxy-extra-headers (headers proxy)
  "Append proxy.headers onto HEADERS without clobbering Proxy-Authorization from URL creds."
  (let ((extra (and proxy (fetch-proxy-extra-headers proxy))))
    (if (null extra)
        headers
        (append headers
                (remove-if
                 (lambda (header)
                   (member (car header)
                           '("proxy-authorization" "host" "content-length"
                             "transfer-encoding")
                           :test #'string-equal))
                 extra)))))

(defun %fetch-http-proxy-headers (proxy headers)
  (let ((authorization (%fetch-proxy-authorization proxy headers)))
    (%fetch-merge-proxy-extra-headers
     (append (%fetch-remove-hop-headers headers)
             (list (cons "Proxy-Connection" "close"))
             (when authorization
               (list (cons "Proxy-Authorization" authorization))))
     proxy)))

(defun %fetch-connect-proxy-headers (proxy)
  "Headers exclusive to the CONNECT envelope (authorization + proxy.headers)."
  (let ((authorization (fetch-proxy-authorization proxy))
        (extra (fetch-proxy-extra-headers proxy)))
    (append
     (when authorization
       (list (cons "Proxy-Authorization" authorization)))
     (remove-if
      (lambda (header)
        (member (car header)
                '("host" "proxy-authorization" "proxy-connection"
                  "content-length" "transfer-encoding")
                :test #'string-equal))
      extra))))

(defun %fetch-absolute-target (record)
  (let ((target (copy-url-record record)))
    (setf (ur-username target) ""
          (ur-password target) ""
          (ur-fragment target) nil)
    (%serialize-url target)))
