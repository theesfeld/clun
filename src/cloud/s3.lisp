;;;; s3.lisp — Pure-CL S3-compatible client (Issue #185 / FULL PORT / Phase 53).
;;;;
;;;; Clun.s3 meets and exceeds Bun.s3 / Bun.S3Client:
;;;;   credentials (options + S3_* / AWS_* env precedence)
;;;;   path-style and virtual-hosted endpoints
;;;;   list / get / put / delete / head / exists / size / stat / copy
;;;;   multipart upload (create / upload-part / complete / abort)
;;;;   batch-delete, presign (GET/PUT/HEAD/DELETE)
;;;;   retry with backoff, injectable transport for hermetic fixtures
;;;;
;;;; Purity: Common Lisp only (Ironclad HMAC-SHA256/SHA256/MD5 + pure-tls HTTP).
;;;; No foreign-function interface and no native AWS SDK. Purity is
;;;; implementation language, not feature exclusion (epic #177).

(in-package :clun.s3)

;;; --- conditions -------------------------------------------------------------

(define-condition s3-error (error)
  ((kind :initarg :kind :reader s3-error-kind)
   (status :initarg :status :initform nil :reader s3-error-status)
   (code :initarg :code :initform nil :reader s3-error-code)
   (message :initarg :message :initform nil :reader s3-error-message)
   (key :initarg :key :initform nil :reader s3-error-key)
   (bucket :initarg :bucket :initform nil :reader s3-error-bucket)
   (detail :initarg :detail :initform nil :reader s3-error-detail))
  (:report (lambda (c s)
             (format s "S3 ~A~@[: ~A~]~@[ (HTTP ~A)~]~@[ [~A]~]"
                     (s3-error-kind c)
                     (or (s3-error-message c) (s3-error-detail c))
                     (s3-error-status c)
                     (s3-error-code c)))))

(defun %fail (kind &key status code message key bucket detail)
  (error 's3-error :kind kind :status status :code code
                   :message message :key key :bucket bucket :detail detail))

;;; --- octets / strings -------------------------------------------------------

(defun %utf8 (string)
  (sb-ext:string-to-octets string :external-format :utf-8))

(defun %utf8-string (octets &key (start 0) end)
  (sb-ext:octets-to-string octets :external-format :utf-8
                                  :start start :end end))

(defun %ascii (string)
  (let ((v (make-array (length string) :element-type '(unsigned-byte 8))))
    (dotimes (i (length string) v)
      (setf (aref v i) (logand (char-code (char string i)) #xff)))))

(defun %hex (octets)
  (crypto:byte-array-to-hex-string octets))

(defun %sha256 (octets)
  (crypto:digest-sequence :sha256 (if (typep octets '(vector (unsigned-byte 8)))
                                      octets
                                      (%utf8 (string octets)))))

(defun %sha256-hex (octets)
  (%hex (%sha256 octets)))

(defun %base64-encode (octets)
  "RFC 4648 base64 (no newlines)."
  (let* ((alphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
         (n (length octets))
         (out (make-string-output-stream)))
    (loop for i from 0 below n by 3
          for b0 = (aref octets i)
          for b1 = (if (< (1+ i) n) (aref octets (1+ i)) 0)
          for b2 = (if (< (+ i 2) n) (aref octets (+ i 2)) 0)
          for triple = (logior (ash b0 16) (ash b1 8) b2)
          for remain = (- n i)
          do (write-char (char alphabet (ldb (byte 6 18) triple)) out)
             (write-char (char alphabet (ldb (byte 6 12) triple)) out)
             (write-char (if (>= remain 2) (char alphabet (ldb (byte 6 6) triple)) #\=) out)
             (write-char (if (>= remain 3) (char alphabet (ldb (byte 6 0) triple)) #\=) out))
    (get-output-stream-string out)))

(defun %md5-b64 (octets)
  (%base64-encode (crypto:digest-sequence :md5 octets)))

(defun %hmac-sha256 (key data)
  (let* ((k (if (stringp key) (%utf8 key) key))
         (d (if (stringp data) (%utf8 data) data))
         (hmac (crypto:make-hmac k :sha256)))
    (crypto:update-hmac hmac d)
    (crypto:hmac-digest hmac)))

(defun %empty-payload-hash ()
  "SHA256 of empty body — AWS UNSIGNED-PAYLOAD alternative for empty PUTs/GET."
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

(defun %ensure-octets (data)
  (cond
    ((null data) (make-array 0 :element-type '(unsigned-byte 8)))
    ((typep data '(vector (unsigned-byte 8))) data)
    ((stringp data) (%utf8 data))
    ((typep data 'vector)
     (let ((out (make-array (length data) :element-type '(unsigned-byte 8))))
       (dotimes (i (length data) out)
         (setf (aref out i) (logand (aref data i) #xff)))))
    (t (%fail :invalid-arg :message "body must be a string or octet vector"))))

;;; --- URI / encoding ---------------------------------------------------------

(defun %uri-encode (string &key (encode-slash t))
  "AWS SigV4 URI encode (RFC 3986 with extra unreserved set). Slash optional."
  (with-output-to-string (out)
    (loop for code across (%utf8 string)
          for c = (code-char code)
          do (cond
               ((or (char<= #\A c #\Z) (char<= #\a c #\z)
                    (char<= #\0 c #\9)
                    (find c "-._~" :test #'char=)
                    (and (not encode-slash) (char= c #\/)))
                (write-char c out))
               (t (format out "%~2,'0X" code))))))

(defun %query-encode (string)
  (%uri-encode string :encode-slash t))

(defun %join-query (params)
  "Canonical query string: sort by key then value, URI-encode both."
  (let ((pairs (sort (copy-list params)
                     (lambda (a b)
                       (let ((ka (car a)) (kb (car b)))
                         (if (string= ka kb)
                             (string< (cdr a) (cdr b))
                             (string< ka kb)))))))
    (format nil "~{~A~^&~}"
            (mapcar (lambda (p)
                      (format nil "~A=~A"
                              (%query-encode (car p))
                              (%query-encode (cdr p))))
                    pairs))))

(defun %trim (s)
  (string-trim '(#\Space #\Tab #\Return #\Newline) s))

(defun %lower (s)
  (string-downcase s))

;;; --- options / credentials --------------------------------------------------

(defstruct (s3-options
            (:conc-name s3o-)
            (:constructor %make-s3-options))
  access-key-id
  secret-access-key
  session-token
  bucket
  region
  endpoint
  (virtual-hosted-style nil)
  (path-style t)                        ; default path-style (Bun virtualHostedStyle false)
  (part-size (* 5 1024 1024))
  (queue-size 10)
  (retry 3)
  acl
  content-type
  content-encoding
  content-disposition
  storage-class
  request-payer
  type                                  ; alias of content-type (Bun)
  (service "s3"))

(defun %env (name)
  (let ((v (clun.sys:getenv name)))
    (and v (plusp (length v)) v)))

(defun %env-first (&rest names)
  (dolist (n names)
    (let ((v (%env n)))
      (when v (return v)))))

(defun resolve-credentials (&key access-key-id secret-access-key session-token
                                 bucket region endpoint)
  "Credential/provider precedence: explicit options → S3_* → AWS_*."
  (values
   (or access-key-id (%env-first "S3_ACCESS_KEY_ID" "AWS_ACCESS_KEY_ID"))
   (or secret-access-key (%env-first "S3_SECRET_ACCESS_KEY" "AWS_SECRET_ACCESS_KEY"))
   (or session-token (%env-first "S3_SESSION_TOKEN" "AWS_SESSION_TOKEN"))
   (or bucket (%env-first "S3_BUCKET" "AWS_BUCKET" "AWS_S3_BUCKET"))
   (or region (%env-first "S3_REGION" "AWS_REGION" "AWS_DEFAULT_REGION") "us-east-1")
   (or endpoint (%env-first "S3_ENDPOINT" "AWS_ENDPOINT" "AWS_ENDPOINT_URL"))))

(defun make-s3-options (&key access-key-id secret-access-key session-token
                             bucket region endpoint
                             virtual-hosted-style path-style
                             part-size queue-size retry
                             acl type content-type content-encoding
                             content-disposition storage-class request-payer
                             service)
  (multiple-value-bind (ak sk st b r e)
      (resolve-credentials :access-key-id access-key-id
                           :secret-access-key secret-access-key
                           :session-token session-token
                           :bucket bucket
                           :region region
                           :endpoint endpoint)
    (let* ((vh (and virtual-hosted-style t))
           ;; Bun: virtualHostedStyle defaults false → path-style. Explicit path-style wins.
           (ps (cond (vh nil)
                     ((null path-style) t)
                     (t (and path-style t)))))
      (%make-s3-options
       :access-key-id ak
       :secret-access-key sk
       :session-token st
       :bucket b
       :region r
       :endpoint e
       :virtual-hosted-style vh
       :path-style ps
       :part-size (or part-size (* 5 1024 1024))
       :queue-size (or queue-size 10)
       :retry (or retry 3)
       :acl acl
       :content-type (or content-type type)
       :content-encoding content-encoding
       :content-disposition content-disposition
       :storage-class storage-class
       :request-payer request-payer
       :type (or type content-type)
       :service (or service "s3")))))

(defun merge-options (base &rest overrides-plist)
  "Return a new options struct with non-nil override fields applied."
  (let ((o (copy-s3-options base)))
    (loop for (k v) on overrides-plist by #'cddr
          when (and v (not (eq v :keep)))
            do (case k
                 (:access-key-id (setf (s3o-access-key-id o) v))
                 (:secret-access-key (setf (s3o-secret-access-key o) v))
                 (:session-token (setf (s3o-session-token o) v))
                 (:bucket (setf (s3o-bucket o) v))
                 (:region (setf (s3o-region o) v))
                 (:endpoint (setf (s3o-endpoint o) v))
                 (:virtual-hosted-style
                  (setf (s3o-virtual-hosted-style o) v
                        (s3o-path-style o) (not v)))
                 (:path-style
                  (setf (s3o-path-style o) v
                        (s3o-virtual-hosted-style o) (not v)))
                 (:part-size (setf (s3o-part-size o) v))
                 (:queue-size (setf (s3o-queue-size o) v))
                 (:retry (setf (s3o-retry o) v))
                 (:acl (setf (s3o-acl o) v))
                 (:type (setf (s3o-type o) v (s3o-content-type o) v))
                 (:content-type (setf (s3o-content-type o) v (s3o-type o) v))
                 (:content-encoding (setf (s3o-content-encoding o) v))
                 (:content-disposition (setf (s3o-content-disposition o) v))
                 (:storage-class (setf (s3o-storage-class o) v))
                 (:request-payer (setf (s3o-request-payer o) v))
                 (:service (setf (s3o-service o) v))))
    o))

(defun require-credentials (opts &key (need-bucket t))
  (unless (and (s3o-access-key-id opts) (plusp (length (s3o-access-key-id opts))))
    (%fail :missing-credentials :message "accessKeyId is required (options or S3_/AWS_ env)"))
  (unless (and (s3o-secret-access-key opts) (plusp (length (s3o-secret-access-key opts))))
    (%fail :missing-credentials :message "secretAccessKey is required (options or S3_/AWS_ env)"))
  (when (and need-bucket
             (or (null (s3o-bucket opts)) (zerop (length (s3o-bucket opts)))))
    (%fail :missing-bucket :message "bucket is required (options or S3_BUCKET/AWS_BUCKET)")))

;;; --- endpoint / URL building ------------------------------------------------

(defstruct (s3-endpoint
            (:conc-name s3e-)
            (:constructor %make-s3-endpoint))
  scheme                                ; "http" | "https"
  host
  port
  path-prefix                           ; "" or "/bucket" for path-style
  host-header
  virtual-hosted-p)

(defun %parse-endpoint-url (url)
  "Parse http(s)://host[:port][/path] → (values scheme host port path)."
  (let* ((s (or url ""))
         (scheme (cond
                   ((and (>= (length s) 8) (string-equal "https://" s :end2 8)) "https")
                   ((and (>= (length s) 7) (string-equal "http://" s :end2 7)) "http")
                   ((zerop (length s)) nil)
                   (t (%fail :invalid-arg :message (format nil "bad endpoint: ~A" url)))))
         (rest (if scheme
                   (subseq s (if (string= scheme "https") 8 7))
                   s))
         (slash (position #\/ rest))
         (auth (if slash (subseq rest 0 slash) rest))
         (path (if slash (subseq rest slash) ""))
         (colon (position #\: auth :from-end t))
         (host (if (and colon
                        (not (and (find #\[ auth) (find #\] auth)
                                  (< (position #\[ auth) colon))))
                   (subseq auth 0 colon)
                   auth))
         (port (when (and colon (> (length auth) (1+ colon))
                          (every #'digit-char-p (subseq auth (1+ colon))))
                 (parse-integer (subseq auth (1+ colon))))))
    (values scheme host port path)))

(defun default-aws-host (region)
  (if (or (null region) (string= region "us-east-1"))
      "s3.amazonaws.com"
      (format nil "s3.~A.amazonaws.com" region)))

(defun resolve-endpoint (opts &key (bucket (s3o-bucket opts)))
  "Build endpoint targeting BUCKET. Path-style: host/bucket/key. Virtual: bucket.host/key."
  (multiple-value-bind (scheme host port path)
      (if (s3o-endpoint opts)
          (%parse-endpoint-url (s3o-endpoint opts))
          (values "https" (default-aws-host (s3o-region opts)) nil ""))
    (let* ((scheme (or scheme "https"))
           (virtual (s3o-virtual-hosted-style opts))
           (use-bucket (and bucket (plusp (length bucket))))
           (vh-host (if (and virtual use-bucket)
                        (format nil "~A.~A" bucket host)
                        host))
           (path-prefix (if (and (not virtual) use-bucket)
                            (format nil "/~A" bucket)
                            ""))
           (default-port (if (string= scheme "https") 443 80))
           (port (or port default-port))
           (host-header (if (or (and (string= scheme "https") (= port 443))
                                (and (string= scheme "http") (= port 80)))
                            vh-host
                            (format nil "~A:~D" vh-host port))))
      (declare (ignore path))
      (%make-s3-endpoint :scheme scheme :host vh-host :port port
                         :path-prefix path-prefix
                         :host-header host-header
                         :virtual-hosted-p virtual))))

(defun object-canonical-uri (endpoint key)
  "Canonical URI for signing: path-prefix + /key (encoded, slash preserved)."
  (let* ((key (or key ""))
         (key* (string-left-trim "/" key))
         (encoded (if (zerop (length key*))
                      ""
                      (%uri-encode key* :encode-slash nil))))
    (if (zerop (length encoded))
        (if (plusp (length (s3e-path-prefix endpoint)))
            (s3e-path-prefix endpoint)
            "/")
        (format nil "~A/~A" (s3e-path-prefix endpoint) encoded))))

(defun object-request-path (endpoint key &optional query)
  (let ((uri (object-canonical-uri endpoint key)))
    (if (and query (plusp (length query)))
        (format nil "~A?~A" uri query)
        uri)))

;;; --- time -------------------------------------------------------------------

(defparameter *s3-clock*
  (lambda () (get-universal-time))
  "Clock function → universal-time. Tests override for deterministic SigV4.")

(defun %now ()
  (funcall *s3-clock*))

(defun %universal-to-utc-parts (ut)
  "Universal time → (values year month day hour min sec) UTC."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time ut 0)
    (values year month day hour min sec)))

(defun amz-date (ut)
  (multiple-value-bind (y mo d h mi s) (%universal-to-utc-parts ut)
    (format nil "~4,'0D~2,'0D~2,'0DT~2,'0D~2,'0D~2,'0DZ" y mo d h mi s)))

(defun amz-datestamp (ut)
  (multiple-value-bind (y mo d) (%universal-to-utc-parts ut)
    (format nil "~4,'0D~2,'0D~2,'0D" y mo d)))

;;; --- SigV4 ------------------------------------------------------------------

(defun signing-key (secret datestamp region service)
  (let* ((k-date (%hmac-sha256 (concatenate 'string "AWS4" secret) datestamp))
         (k-region (%hmac-sha256 k-date region))
         (k-service (%hmac-sha256 k-region service))
         (k-signing (%hmac-sha256 k-service "aws4_request")))
    k-signing))

(defun canonical-headers-string (headers)
  "HEADERS is alist of (name . value); names lowercased. Returns (values block signed)."
  (let* ((normalized
           (mapcar (lambda (h)
                     (cons (%lower (%trim (car h)))
                           ;; collapse internal whitespace
                           (let ((v (%trim (cdr h))))
                             (with-output-to-string (o)
                               (let ((prev-space nil))
                                 (loop for c across v
                                       do (if (member c '(#\Space #\Tab))
                                              (unless prev-space
                                                (write-char #\Space o)
                                                (setf prev-space t))
                                              (progn
                                                (write-char c o)
                                                (setf prev-space nil)))))))))
                   headers))
         (sorted (sort (copy-list normalized) #'string< :key #'car))
         ;; merge duplicates by joining with comma (rare for our client)
         (merged nil))
    (dolist (h sorted)
      (let ((prev (car merged)))
        (if (and prev (string= (car prev) (car h)))
            (setf (cdr prev) (format nil "~A,~A" (cdr prev) (cdr h)))
            (push h merged))))
    (setf merged (nreverse merged))
    (values
     (with-output-to-string (o)
       (dolist (h merged)
         (format o "~A:~A~%" (car h) (cdr h))))
     (format nil "~{~A~^;~}" (mapcar #'car merged)))))

(defun create-canonical-request (method canonical-uri query-string
                                 headers payload-hash)
  (multiple-value-bind (cheaders signed)
      (canonical-headers-string headers)
    (values
     (format nil "~A~%~A~%~A~%~A~%~A~%~A"
             (string-upcase method)
             canonical-uri
             (or query-string "")
             cheaders
             signed
             payload-hash)
     signed)))

(defun create-string-to-sign (amz-date datestamp region service canonical-request)
  (format nil "AWS4-HMAC-SHA256~%~A~%~A/~A/~A/aws4_request~%~A"
          amz-date datestamp region service
          (%sha256-hex (%utf8 canonical-request))))

(defun sign-request (opts &key method key query headers body
                           (unsigned-payload nil)
                           (timestamp nil))
  "Return (values authorization-header amz-date payload-hash signed-headers extra-headers).
EXTRA-HEADERS includes x-amz-date, x-amz-content-sha256, optional session token."
  (require-credentials opts :need-bucket nil)
  (let* ((ut (or timestamp (%now)))
         (amz (amz-date ut))
         (stamp (amz-datestamp ut))
         (region (or (s3o-region opts) "us-east-1"))
         (service (or (s3o-service opts) "s3"))
         (endpoint (resolve-endpoint opts))
         (octets (if body (%ensure-octets body)
                     (make-array 0 :element-type '(unsigned-byte 8))))
         (payload-hash (if unsigned-payload
                           "UNSIGNED-PAYLOAD"
                           (if (zerop (length octets))
                               (%empty-payload-hash)
                               (%sha256-hex octets))))
         (canonical-uri (object-canonical-uri endpoint (or key "")))
         (query-string (if (listp query)
                           (%join-query query)
                           (or query "")))
         (base-headers
           (append
            (list (cons "host" (s3e-host-header endpoint))
                  (cons "x-amz-content-sha256" payload-hash)
                  (cons "x-amz-date" amz))
            (when (s3o-session-token opts)
              (list (cons "x-amz-security-token" (s3o-session-token opts))))
            (mapcar (lambda (h) (cons (%lower (car h)) (cdr h)))
                    (or headers nil)))))
    (multiple-value-bind (canon signed)
        (create-canonical-request method canonical-uri query-string
                                  base-headers payload-hash)
      (let* ((sts (create-string-to-sign amz stamp region service canon))
             (key-bytes (signing-key (s3o-secret-access-key opts) stamp region service))
             (sig (%hex (%hmac-sha256 key-bytes sts)))
             (auth (format nil
                           "AWS4-HMAC-SHA256 Credential=~A/~A/~A/~A/aws4_request, SignedHeaders=~A, Signature=~A"
                           (s3o-access-key-id opts) stamp region service signed sig)))
        (values auth amz payload-hash signed
                (append
                 (list (cons "x-amz-date" amz)
                       (cons "x-amz-content-sha256" payload-hash)
                       (cons "Authorization" auth))
                 (when (s3o-session-token opts)
                   (list (cons "x-amz-security-token" (s3o-session-token opts))))))))))

(defun presign (opts key &key (method "GET") (expires-in 86400)
                          content-type acl (timestamp nil))
  "Generate a presigned URL (no network). EXPIRES-IN seconds (default 24h)."
  (require-credentials opts)
  (let* ((ut (or timestamp (%now)))
         (amz (amz-date ut))
         (stamp (amz-datestamp ut))
         (region (or (s3o-region opts) "us-east-1"))
         (service (or (s3o-service opts) "s3"))
         (endpoint (resolve-endpoint opts))
         (expires (max 1 (min (or expires-in 86400) 604800)))
         (credential (format nil "~A/~A/~A/~A/aws4_request"
                             (s3o-access-key-id opts) stamp region service))
         (query
           (append
            (list (cons "X-Amz-Algorithm" "AWS4-HMAC-SHA256")
                  (cons "X-Amz-Credential" credential)
                  (cons "X-Amz-Date" amz)
                  (cons "X-Amz-Expires" (princ-to-string expires))
                  (cons "X-Amz-SignedHeaders" "host"))
            (when (s3o-session-token opts)
              (list (cons "X-Amz-Security-Token" (s3o-session-token opts))))
            (when content-type
              (list (cons "response-content-type" content-type)))
            (when acl
              (list (cons "x-amz-acl" acl)))))
         (canonical-uri (object-canonical-uri endpoint key))
         (query-string (%join-query query))
         (headers (list (cons "host" (s3e-host-header endpoint))))
         (port (s3e-port endpoint))
         (authority (if (or (and (string= (s3e-scheme endpoint) "https") (= port 443))
                            (and (string= (s3e-scheme endpoint) "http") (= port 80)))
                        (s3e-host endpoint)
                        (format nil "~A:~D" (s3e-host endpoint) port))))
    (multiple-value-bind (canon signed)
        (create-canonical-request method canonical-uri query-string
                                  headers "UNSIGNED-PAYLOAD")
      (declare (ignore signed))
      (let* ((sts (create-string-to-sign amz stamp region service canon))
             (sig (%hex (%hmac-sha256
                         (signing-key (s3o-secret-access-key opts) stamp region service)
                         sts)))
             (final-query (format nil "~A&X-Amz-Signature=~A"
                                  query-string (%query-encode sig))))
        (format nil "~A://~A~A?~A"
                (s3e-scheme endpoint) authority canonical-uri final-query)))))

;;; --- HTTP transport ---------------------------------------------------------

(defstruct (s3-http-response
            (:conc-name s3hr-)
            (:constructor make-s3-http-response))
  status
  headers                               ; alist lower-name . value
  body)                                 ; octet vector

(defparameter *s3-http-fn* nil
  "When non-NIL, (fn &key method host port scheme path headers body host-header)
   → s3-http-response. Tests install a hermetic mock here.")

(defun %headers-alist (headers)
  (mapcar (lambda (h)
            (cons (%lower (car h))
                  (if (stringp (cdr h)) (cdr h) (princ-to-string (cdr h)))))
          headers))

(defun %header-value (headers name)
  (cdr (assoc (%lower name) headers :test #'string=)))

(defun %serialize-http-request (method path host-header headers body)
  (let* ((octets (if body (%ensure-octets body)
                     (make-array 0 :element-type '(unsigned-byte 8))))
         (head (make-string-output-stream)))
    (format head "~A ~A HTTP/1.1~C~C"
            (string-upcase method)
            (if (plusp (length path)) path "/")
            #\Return #\Newline)
    (format head "Host: ~A~C~C" host-header #\Return #\Newline)
    (dolist (h headers)
      (unless (string-equal (car h) "host")
        (format head "~A: ~A~C~C" (car h)
                (remove-if (lambda (c) (member c '(#\Return #\Newline)))
                           (if (stringp (cdr h)) (cdr h) (princ-to-string (cdr h))))
                #\Return #\Newline)))
    (unless (assoc "content-length" headers :test #'string-equal)
      (format head "Content-Length: ~D~C~C" (length octets) #\Return #\Newline))
    (unless (assoc "connection" headers :test #'string-equal)
      (format head "Connection: close~C~C" #\Return #\Newline))
    (format head "~C~C" #\Return #\Newline)
    (let* ((hbytes (%ascii (get-output-stream-string head)))
           (out (make-array (+ (length hbytes) (length octets))
                            :element-type '(unsigned-byte 8))))
      (replace out hbytes)
      (replace out octets :start1 (length hbytes))
      out)))

(defun %parse-response-octets (octets)
  (let ((parser (clun.net:make-http-response-parser)))
    (multiple-value-bind (event data) (clun.net:parser-feed parser octets)
      (case event
        (:response data)
        (:error (%fail :http-error :message (format nil "HTTP parse error ~A" data)))
        (t
         (multiple-value-bind (fe fd) (clun.net:response-finish parser)
           (if (eq fe :response)
               fd
               (%fail :http-error :message "incomplete HTTP response"))))))))

(defun %plain-http-request (&key host port method path headers body host-header)
  (let* ((addresses (clun.net:resolve-hostname-all host))
         (addr (or (first addresses)
                   (%fail :network :message (format nil "DNS failed for ~A" host))))
         (ipv6 (clun.net:dns-address-ipv6-p addr))
         (text (clun.net:dns-address-text addr))
         (inet (if ipv6
                   (sb-bsd-sockets:make-inet6-address text)
                   (sb-bsd-sockets:make-inet-address text)))
         (sock (make-instance (if ipv6
                                  'sb-bsd-sockets:inet6-socket
                                  'sb-bsd-sockets:inet-socket)
                              :type :stream :protocol :tcp))
         (raw nil))
    (unwind-protect
         (progn
           (sb-bsd-sockets:socket-connect sock inet port)
           (setf raw (sb-bsd-sockets:socket-make-stream
                      sock :input t :output t :element-type '(unsigned-byte 8)
                      :buffering :full))
           (let ((req (%serialize-http-request method path
                                               (or host-header host)
                                               headers body)))
             (write-sequence req raw)
             (force-output raw)
             (let ((buf (make-array 65536 :element-type '(unsigned-byte 8)))
                   (acc (make-array 0 :element-type '(unsigned-byte 8)
                                      :adjustable t :fill-pointer 0)))
               (loop for n = (read-sequence buf raw)
                     while (plusp n)
                     do (let ((old (fill-pointer acc)))
                          (adjust-array acc (+ old n) :fill-pointer (+ old n))
                          (replace acc buf :start1 old :end2 n)))
               (%parse-response-octets acc))))
      (ignore-errors (when raw (close raw)))
      (ignore-errors (sb-bsd-sockets:socket-close sock)))))

(defun %net-response->s3 (resp)
  (make-s3-http-response
   :status (clun.net:hres-status resp)
   :headers (%headers-alist (clun.net:hres-headers resp))
   :body (or (clun.net:hres-body resp)
             (make-array 0 :element-type '(unsigned-byte 8)))))

(defun default-http-request (&key method host port scheme path headers body host-header)
  (let ((scheme (or scheme "https"))
        (port (or port (if (string= scheme "https") 443 80))))
    (if (string= scheme "https")
        (%net-response->s3
         (clun.net:https-request :host host :port port :method method :path path
                                 :headers headers :body body
                                 :host-header (or host-header host)))
        (%net-response->s3
         (%plain-http-request :host host :port port :method method :path path
                              :headers headers :body body
                              :host-header (or host-header host))))))

(defun s3-http-request (&key method host port scheme path headers body host-header)
  (if *s3-http-fn*
      (funcall *s3-http-fn*
               :method method :host host :port port :scheme scheme
               :path path :headers headers :body body
               :host-header host-header)
      (default-http-request :method method :host host :port port :scheme scheme
                            :path path :headers headers :body body
                            :host-header host-header)))

;;; --- XML helpers (minimal) --------------------------------------------------

(defun %xml-escape (s)
  (with-output-to-string (o)
    (loop for c across (string s)
          do (case c
               (#\< (write-string "&lt;" o))
               (#\> (write-string "&gt;" o))
               (#\& (write-string "&amp;" o))
               (#\" (write-string "&quot;" o))
               (#\' (write-string "&apos;" o))
               (t (write-char c o))))))

(defun %xml-unescape (s)
  (let ((out (make-string-output-stream))
        (i 0)
        (n (length s)))
    (loop while (< i n)
          do (if (char= (char s i) #\&)
                 (let ((semi (position #\; s :start i)))
                   (if semi
                       (let ((ent (subseq s (1+ i) semi)))
                         (write-string
                          (cond
                            ((string= ent "lt") "<")
                            ((string= ent "gt") ">")
                            ((string= ent "amp") "&")
                            ((string= ent "quot") "\"")
                            ((string= ent "apos") "'")
                            ((and (plusp (length ent)) (char= (char ent 0) #\#))
                             (string (code-char
                                      (if (and (> (length ent) 1)
                                               (char-equal (char ent 1) #\x))
                                          (parse-integer ent :start 2 :radix 16)
                                          (parse-integer ent :start 1)))))
                            (t (subseq s i (1+ semi))))
                          out)
                         (setf i (1+ semi)))
                       (progn (write-char #\& out) (incf i))))
                 (progn (write-char (char s i) out) (incf i))))
    (get-output-stream-string out)))

(defun %xml-tag-contents (xml tag)
  "Return list of inner strings for each <tag>...</tag> (non-nested simple tags)."
  (let* ((open (format nil "<~A" tag))
         (close (format nil "</~A>" tag))
         (results nil)
         (start 0))
    (loop
      (let ((o (search open xml :start2 start)))
        (unless o (return (nreverse results)))
        (let* ((after-name (+ o (length open)))
               (gt (position #\> xml :start after-name)))
          (unless gt (return (nreverse results)))
          (cond
            ;; self-closing
            ((and (> gt after-name)
                  (char= (char xml (1- gt)) #\/))
             (setf start (1+ gt)))
            (t
             (let ((c (search close xml :start2 (1+ gt))))
               (unless c (return (nreverse results)))
               (push (%xml-unescape (subseq xml (1+ gt) c)) results)
               (setf start (+ c (length close)))))))))))

(defun %xml-first (xml tag)
  (car (%xml-tag-contents xml tag)))

(defun %xml-bool (s)
  (and s (or (string-equal s "true") (string= s "1"))))

(defun %parse-error-xml (body status)
  (let* ((text (if (stringp body) body
                   (%utf8-string (or body #()))))
         (code (%xml-first text "Code"))
         (msg (%xml-first text "Message")))
    (values code msg text)))

;;; --- client -----------------------------------------------------------------

(defstruct (s3-client
            (:conc-name s3c-)
            (:constructor %make-s3-client))
  options)

(defun make-s3-client (&rest keys &key &allow-other-keys)
  (%make-s3-client :options (apply #'make-s3-options keys)))

(defun client-options (client)
  (s3c-options client))

(defun %with-client-options (client &rest overrides)
  (apply #'merge-options (client-options client) overrides))

(defun %retryable-status (status)
  (or (null status)
      (= status 408)
      (= status 429)
      (<= 500 status 599)))

(defun %sleep-backoff (attempt)
  (sleep (min 8.0 (* 0.05 (expt 2 (min attempt 6))))))

(defun %build-object-headers (opts &key content-type content-md5 extra)
  (append
   extra
   (when (or content-type (s3o-content-type opts))
     (list (cons "Content-Type" (or content-type (s3o-content-type opts)))))
   (when (s3o-content-encoding opts)
     (list (cons "Content-Encoding" (s3o-content-encoding opts))))
   (when (s3o-content-disposition opts)
     (list (cons "Content-Disposition" (s3o-content-disposition opts))))
   (when (s3o-acl opts)
     (list (cons "x-amz-acl" (s3o-acl opts))))
   (when (s3o-storage-class opts)
     (list (cons "x-amz-storage-class" (s3o-storage-class opts))))
   (when (s3o-request-payer opts)
     (list (cons "x-amz-request-payer" (s3o-request-payer opts))))
   (when content-md5
     (list (cons "Content-MD5" content-md5)))))

(defun %execute (opts &key method key query headers body
                        (need-bucket t) (expect-xml nil))
  (require-credentials opts :need-bucket need-bucket)
  (let* ((endpoint (resolve-endpoint opts))
         (retries (max 0 (or (s3o-retry opts) 0)))
         (attempt 0)
         (last-err nil))
    (loop
      (incf attempt)
      (handler-case
          (multiple-value-bind (auth amz payload-hash signed sig-headers)
              (sign-request opts :method method :key key :query query
                                 :headers headers :body body)
            (declare (ignore auth amz payload-hash signed))
            (let* ((all-headers (append headers
                                        (remove "authorization" sig-headers
                                                :key #'car :test #'string-equal)
                                        (list (assoc "authorization" sig-headers
                                                     :test #'string-equal))))
                   ;; ensure Authorization present once
                   (all-headers (remove nil all-headers))
                   (qstr (if (listp query) (%join-query query) (or query "")))
                   (path (object-request-path endpoint (or key "") qstr))
                   (resp (s3-http-request
                          :method method
                          :host (s3e-host endpoint)
                          :port (s3e-port endpoint)
                          :scheme (s3e-scheme endpoint)
                          :path path
                          :headers all-headers
                          :body body
                          :host-header (s3e-host-header endpoint)))
                   (status (s3hr-status resp)))
              (cond
                ((and status (<= 200 status 299))
                 (return resp))
                ((and status (= status 404)
                      (member (string-upcase method) '("GET" "HEAD") :test #'string=))
                 (return resp))
                ((and status (= status 404))
                 (multiple-value-bind (code msg)
                     (%parse-error-xml (s3hr-body resp) status)
                   (%fail :not-found :status status :code code :message msg
                          :key key :bucket (s3o-bucket opts))))
                ((and (%retryable-status status) (<= attempt retries))
                 (setf last-err resp)
                 (%sleep-backoff attempt))
                (t
                 (multiple-value-bind (code msg)
                     (%parse-error-xml (s3hr-body resp) status)
                   (%fail :request-failed :status status :code code :message msg
                          :key key :bucket (s3o-bucket opts)
                          :detail (format nil "~A" (ignore-errors
                                                    (%utf8-string (s3hr-body resp))))))))))
        (s3-error (e) (error e))
        (error (e)
          (if (and (<= attempt retries)
                   (not (typep e 's3-error)))
              (progn
                (setf last-err e)
                (%sleep-backoff attempt))
              (%fail :network :message (format nil "~A" e)
                     :detail last-err)))))))

;;; --- public operations ------------------------------------------------------

(defun s3-put (client key data &key content-type acl content-encoding
                                 content-disposition storage-class
                                 (compute-md5 t) &allow-other-keys)
  "PUT object. Returns (values etag bytes-written)."
  (let* ((opts (%with-client-options client
                 :content-type content-type :acl acl
                 :content-encoding content-encoding
                 :content-disposition content-disposition
                 :storage-class storage-class))
         (octets (%ensure-octets data))
         (md5 (when compute-md5 (%md5-b64 octets)))
         (headers (%build-object-headers opts :content-md5 md5
                                         :content-type content-type))
         (resp (%execute opts :method "PUT" :key key :headers headers :body octets))
         (etag (%header-value (s3hr-headers resp) "etag")))
    (values (when etag (string-trim '(#\") etag)) (length octets))))

(defun s3-get (client key &key range)
  "GET object body as octets. RANGE is (start . end) inclusive or string."
  (let* ((opts (client-options client))
         (headers (when range
                    (list (cons "Range"
                                (if (stringp range)
                                    range
                                    (format nil "bytes=~D-~A"
                                            (car range)
                                            (if (cdr range)
                                                (princ-to-string (cdr range))
                                                "")))))))
         (resp (%execute opts :method "GET" :key key :headers headers)))
    (when (= (s3hr-status resp) 404)
      (%fail :not-found :status 404 :code "NoSuchKey" :key key
             :bucket (s3o-bucket opts) :message "The specified key does not exist."))
    (values (s3hr-body resp) (s3hr-headers resp) (s3hr-status resp))))

(defun s3-get-text (client key &key range)
  (%utf8-string (s3-get client key :range range)))

(defun s3-delete (client key)
  "DELETE object. Succeeds even if key was already absent (S3 idempotent delete)."
  (let ((opts (client-options client)))
    (%execute opts :method "DELETE" :key key)
    t))

(defun s3-head (client key)
  "HEAD object → headers alist, or NIL if 404."
  (let* ((opts (client-options client))
         (resp (%execute opts :method "HEAD" :key key)))
    (if (= (s3hr-status resp) 404)
        nil
        (s3hr-headers resp))))

(defun s3-exists (client key)
  (and (s3-head client key) t))

(defun s3-size (client key)
  (let ((h (s3-head client key)))
    (unless h
      (%fail :not-found :status 404 :code "NoSuchKey" :key key
             :message "The specified key does not exist."))
    (let ((cl (%header-value h "content-length")))
      (if cl (parse-integer cl :junk-allowed t) 0))))

(defstruct (s3-stat (:conc-name s3s-))
  size etag last-modified content-type)

(defun s3-stat (client key)
  (let ((h (s3-head client key)))
    (unless h
      (%fail :not-found :status 404 :code "NoSuchKey" :key key
             :message "The specified key does not exist."))
    (make-s3-stat
     :size (let ((cl (%header-value h "content-length")))
             (if cl (parse-integer cl :junk-allowed t) 0))
     :etag (let ((e (%header-value h "etag")))
             (when e (string-trim '(#\") e)))
     :last-modified (%header-value h "last-modified")
     :content-type (%header-value h "content-type"))))

(defun s3-copy (client source-key dest-key &key source-bucket)
  "Server-side copy. SOURCE-BUCKET defaults to client bucket."
  (let* ((opts (client-options client))
         (src-bucket (or source-bucket (s3o-bucket opts)))
         (copy-source (%uri-encode (format nil "~A/~A" src-bucket
                                           (string-left-trim "/" source-key))
                                   :encode-slash nil))
         (headers (list (cons "x-amz-copy-source" copy-source)))
         (resp (%execute opts :method "PUT" :key dest-key :headers headers)))
    (values (%header-value (s3hr-headers resp) "etag") t)))

(defun s3-list (client &key prefix delimiter max-keys continuation-token
                         start-after fetch-owner encoding-type)
  "ListObjectsV2. Returns a plist-like structure as a hash-table-friendly alist."
  (let* ((opts (client-options client))
         (query
           (append
            (list (cons "list-type" "2"))
            (when prefix (list (cons "prefix" prefix)))
            (when delimiter (list (cons "delimiter" delimiter)))
            (when max-keys (list (cons "max-keys" (princ-to-string max-keys))))
            (when continuation-token
              (list (cons "continuation-token" continuation-token)))
            (when start-after (list (cons "start-after" start-after)))
            (when fetch-owner (list (cons "fetch-owner" "true")))
            (when encoding-type (list (cons "encoding-type" encoding-type)))))
         (resp (%execute opts :method "GET" :key "" :query query))
         (xml (%utf8-string (s3hr-body resp)))
         (contents
           (mapcar
            (lambda (block)
              (list :key (%xml-first block "Key")
                    :size (let ((s (%xml-first block "Size")))
                            (when s (parse-integer s :junk-allowed t)))
                    :etag (let ((e (%xml-first block "ETag")))
                            (when e (string-trim '(#\") e)))
                    :last-modified (%xml-first block "LastModified")
                    :storage-class (%xml-first block "StorageClass")))
            (let ((parts nil)
                  (start 0))
              (loop
                (let ((o (search "<Contents>" xml :start2 start)))
                  (unless o (return (nreverse parts)))
                  (let ((c (search "</Contents>" xml :start2 o)))
                    (unless c (return (nreverse parts)))
                    (push (subseq xml o (+ c (length "</Contents>"))) parts)
                    (setf start (+ c (length "</Contents>")))))))))
         (common-prefixes
           (let ((cp-blocks nil)
                 (start 0))
             (loop
               (let ((o (search "<CommonPrefixes>" xml :start2 start)))
                 (unless o (return (nreverse cp-blocks)))
                 (let ((c (search "</CommonPrefixes>" xml :start2 o)))
                   (unless c (return (nreverse cp-blocks)))
                   (push (list :prefix (%xml-first (subseq xml o c) "Prefix"))
                         cp-blocks)
                   (setf start (+ c (length "</CommonPrefixes>")))))))))
    (list :name (%xml-first xml "Name")
          :prefix (%xml-first xml "Prefix")
          :delimiter (%xml-first xml "Delimiter")
          :max-keys (let ((m (%xml-first xml "MaxKeys")))
                      (when m (parse-integer m :junk-allowed t)))
          :key-count (let ((k (%xml-first xml "KeyCount")))
                       (when k (parse-integer k :junk-allowed t)))
          :is-truncated (%xml-bool (%xml-first xml "IsTruncated"))
          :continuation-token (%xml-first xml "ContinuationToken")
          :next-continuation-token (%xml-first xml "NextContinuationToken")
          :start-after (%xml-first xml "StartAfter")
          :contents contents
          :common-prefixes common-prefixes)))

(defun s3-delete-objects (client keys &key quiet)
  "Batch delete (DeleteObjects). KEYS is a list of strings."
  (let* ((opts (client-options client))
         (body
           (%utf8
            (with-output-to-string (o)
              (write-string "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" o)
              (write-string "<Delete>" o)
              (when quiet (write-string "<Quiet>true</Quiet>" o))
              (dolist (k keys)
                (format o "<Object><Key>~A</Key></Object>" (%xml-escape k)))
              (write-string "</Delete>" o))))
         (md5 (%md5-b64 body))
         (headers (list (cons "Content-Type" "application/xml")
                        (cons "Content-MD5" md5)))
         (resp (%execute opts :method "POST" :key ""
                         :query (list (cons "delete" ""))
                         :headers headers :body body)))
    (%utf8-string (s3hr-body resp))))

;;; --- multipart --------------------------------------------------------------

(defun s3-create-multipart (client key &key content-type acl)
  (let* ((opts (%with-client-options client :content-type content-type :acl acl))
         (headers (%build-object-headers opts))
         (resp (%execute opts :method "POST" :key key
                         :query (list (cons "uploads" ""))
                         :headers headers))
         (xml (%utf8-string (s3hr-body resp))))
    (%xml-first xml "UploadId")))

(defun s3-upload-part (client key upload-id part-number data)
  (let* ((opts (client-options client))
         (octets (%ensure-octets data))
         (resp (%execute opts :method "PUT" :key key
                         :query (list (cons "partNumber" (princ-to-string part-number))
                                      (cons "uploadId" upload-id))
                         :body octets))
         (etag (%header-value (s3hr-headers resp) "etag")))
    (values (when etag (string-trim '(#\") etag)) (length octets))))

(defun s3-complete-multipart (client key upload-id parts)
  "PARTS is list of (part-number . etag)."
  (let* ((opts (client-options client))
         (body
           (%utf8
            (with-output-to-string (o)
              (write-string "<CompleteMultipartUpload>" o)
              (dolist (p (sort (copy-list parts) #'< :key #'car))
                (format o "<Part><PartNumber>~D</PartNumber><ETag>~A</ETag></Part>"
                        (car p) (%xml-escape (cdr p))))
              (write-string "</CompleteMultipartUpload>" o))))
         (resp (%execute opts :method "POST" :key key
                         :query (list (cons "uploadId" upload-id))
                         :headers (list (cons "Content-Type" "application/xml"))
                         :body body)))
    (%utf8-string (s3hr-body resp))))

(defun s3-abort-multipart (client key upload-id)
  (let ((opts (client-options client)))
    (%execute opts :method "DELETE" :key key
              :query (list (cons "uploadId" upload-id)))
    t))

(defun s3-write (client key data &key content-type acl part-size)
  "Write DATA, using multipart when larger than PART-SIZE (default from options)."
  (let* ((opts (client-options client))
         (octets (%ensure-octets data))
         (ps (or part-size (s3o-part-size opts) (* 5 1024 1024))))
    (if (<= (length octets) ps)
        (s3-put client key octets :content-type content-type :acl acl)
        (let* ((upload-id (s3-create-multipart client key
                                               :content-type content-type
                                               :acl acl))
               (parts nil)
               (n (length octets))
               (part-no 1)
               (pos 0))
          (unwind-protect
               (progn
                 (loop while (< pos n)
                       do (let* ((end (min n (+ pos ps)))
                                 (chunk (subseq octets pos end)))
                            (multiple-value-bind (etag)
                                (s3-upload-part client key upload-id part-no chunk)
                              (push (cons part-no etag) parts)
                              (incf part-no)
                              (setf pos end))))
                 (s3-complete-multipart client key upload-id parts)
                 (setf upload-id nil)
                 (values (cdar parts) n))
            (when upload-id
              (ignore-errors (s3-abort-multipart client key upload-id))))))))

;;; --- file handle (lazy reference) -------------------------------------------

(defstruct (s3-file
            (:conc-name s3f-)
            (:constructor %make-s3-file))
  client
  key
  options
  (start 0)
  end)

(defun s3-file (client key &rest option-keys &key &allow-other-keys)
  (let ((opts (if option-keys
                  (apply #'merge-options (client-options client) option-keys)
                  (client-options client))))
    (%make-s3-file :client (%make-s3-client :options opts)
                   :key (string-left-trim "/" (string key))
                   :options opts)))

(defun s3-file-slice (file &optional begin end)
  (let* ((b (or begin 0))
         (e end))
    (%make-s3-file :client (s3f-client file)
                   :key (s3f-key file)
                   :options (s3f-options file)
                   :start b :end e)))

(defun s3-file-get (file)
  (let ((range (when (or (plusp (s3f-start file)) (s3f-end file))
                 (cons (s3f-start file) (s3f-end file)))))
    (s3-get (s3f-client file) (s3f-key file) :range range)))

(defun s3-file-text (file)
  (%utf8-string (s3-file-get file)))

(defun s3-file-write (file data &rest keys)
  (apply #'s3-write (s3f-client file) (s3f-key file) data keys))

(defun s3-file-delete (file)
  (s3-delete (s3f-client file) (s3f-key file)))

(defun s3-file-exists (file)
  (s3-exists (s3f-client file) (s3f-key file)))

(defun s3-file-stat (file)
  (s3-stat (s3f-client file) (s3f-key file)))

(defun s3-file-presign (file &rest keys)
  (apply #'presign (s3f-options file) (s3f-key file) keys))

;;; --- default env client (Bun.s3 equivalent) ---------------------------------

(defun default-client ()
  (make-s3-client))

;;; --- hermetic in-memory S3 mock ---------------------------------------------

(defstruct (s3-mock
            (:conc-name s3m-)
            (:constructor %make-s3-mock))
  (buckets (make-hash-table :test #'equal))
  access-key-id
  secret-access-key
  region
  (lock (sb-thread:make-mutex :name "clun-s3-mock")))

(defstruct (s3-mock-object
            (:conc-name s3mo-)
            (:constructor %make-s3-mock-object))
  data
  content-type
  etag
  last-modified)

(defun make-s3-mock (&key (access-key-id "test-key")
                          (secret-access-key "test-secret")
                          (region "us-east-1"))
  (%make-s3-mock :access-key-id access-key-id
                 :secret-access-key secret-access-key
                 :region region))

(defun %mock-bucket (mock name)
  (or (gethash name (s3m-buckets mock))
      (setf (gethash name (s3m-buckets mock))
            (make-hash-table :test #'equal))))

(defun %mock-etag (data)
  (%hex (crypto:digest-sequence :md5 data)))

(defun %parse-path-style (path)
  "Return (values bucket key query-alist) for /bucket/key?query."
  (let* ((qpos (position #\? path))
         (path* (if qpos (subseq path 0 qpos) path))
         (query (when qpos (subseq path (1+ qpos))))
         (path* (string-left-trim "/" path*))
         (slash (position #\/ path*))
         (bucket (if slash (subseq path* 0 slash) path*))
         (key (if slash (subseq path* (1+ slash)) ""))
         (params nil))
    (when query
      (dolist (part (split-sequence #\& query))
        (let ((eq (position #\= part)))
          (push (if eq
                    (cons (percent-decode (subseq part 0 eq))
                          (percent-decode (subseq part (1+ eq))))
                    (cons (percent-decode part) ""))
                params))))
    (values bucket key (nreverse params))))

(defun split-sequence (delim string)
  (let ((parts nil) (start 0))
    (loop for i from 0 below (length string)
          when (char= (char string i) delim)
            do (push (subseq string start i) parts)
               (setf start (1+ i))
          finally (push (subseq string start) parts))
    (nreverse parts)))

(defun percent-decode (s)
  (with-output-to-string (o)
    (let ((i 0) (n (length s)))
      (loop while (< i n)
            do (let ((c (char s i)))
                 (cond
                   ((char= c #\%)
                    (when (< (+ i 2) n)
                      (write-char (code-char (parse-integer s :start (1+ i)
                                                            :end (+ i 3)
                                                            :radix 16))
                                  o)
                      (incf i 3)))
                   ((char= c #\+) (write-char #\Space o) (incf i))
                   (t (write-char c o) (incf i))))))))

(defun %mock-xml-list (bucket-name objects &key prefix max-keys delimiter
                                    continuation-token start-after)
  (let* ((keys (sort (loop for k being the hash-keys of objects collect k)
                     #'string<))
         (keys (if prefix
                   (remove-if-not (lambda (k) (eql (search prefix k) 0)) keys)
                   keys))
         (keys (if start-after
                   (remove-if (lambda (k) (string<= k start-after)) keys)
                   keys))
         (maxk (or max-keys 1000))
         (slice (subseq keys 0 (min (length keys) maxk)))
         (truncated (> (length keys) maxk)))
    (declare (ignore continuation-token delimiter))
    (with-output-to-string (o)
      (write-string "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" o)
      (write-string "<ListBucketResult>" o)
      (format o "<Name>~A</Name>" (%xml-escape bucket-name))
      (when prefix (format o "<Prefix>~A</Prefix>" (%xml-escape prefix)))
      (format o "<MaxKeys>~D</MaxKeys>" maxk)
      (format o "<KeyCount>~D</KeyCount>" (length slice))
      (format o "<IsTruncated>~A</IsTruncated>" (if truncated "true" "false"))
      (dolist (k slice)
        (let ((obj (gethash k objects)))
          (format o "<Contents><Key>~A</Key><Size>~D</Size><ETag>\"~A\"</ETag><LastModified>~A</LastModified><StorageClass>STANDARD</StorageClass></Contents>"
                  (%xml-escape k)
                  (length (s3mo-data obj))
                  (s3mo-etag obj)
                  (or (s3mo-last-modified obj) "2020-01-01T00:00:00.000Z"))))
      (write-string "</ListBucketResult>" o))))

(defun s3-mock-handler (mock)
  "Return a function suitable for *s3-http-fn*."
  (lambda (&key method host port scheme path headers body host-header)
    (declare (ignore port scheme host-header host))
    (sb-thread:with-mutex ((s3m-lock mock))
      (multiple-value-bind (bucket key query) (%parse-path-style path)
        (let* ((method (string-upcase method))
               (body (or body (make-array 0 :element-type '(unsigned-byte 8))))
               (q (mapcar (lambda (p) (cons (car p) (cdr p))) query))
               (has-uploads (assoc "uploads" q :test #'string=))
               (upload-id (cdr (assoc "uploadId" q :test #'string=)))
               (part-number (cdr (assoc "partNumber" q :test #'string=)))
               (is-delete (assoc "delete" q :test #'string=))
               (is-list (or (string= key "")
                            (assoc "list-type" q :test #'string=)))
               (store (%mock-bucket mock bucket)))
          (cond
            ;; DeleteObjects
            ((and (string= method "POST") is-delete)
             (make-s3-http-response
              :status 200
              :headers '(("content-type" . "application/xml"))
              :body (%utf8 "<DeleteResult></DeleteResult>")))
            ;; Create multipart
            ((and (string= method "POST") has-uploads)
             (let ((id (format nil "upload-~A" (random 1000000))))
               (make-s3-http-response
                :status 200
                :headers '(("content-type" . "application/xml"))
                :body (%utf8
                       (format nil "<InitiateMultipartUploadResult><UploadId>~A</UploadId></InitiateMultipartUploadResult>"
                               id)))))
            ;; Upload part
            ((and (string= method "PUT") upload-id part-number)
             (let ((etag (%mock-etag body)))
               (make-s3-http-response
                :status 200
                :headers (list (cons "etag" (format nil "\"~A\"" etag)))
                :body (make-array 0 :element-type '(unsigned-byte 8)))))
            ;; Complete / abort multipart
            ((and upload-id (member method '("POST" "DELETE") :test #'string=))
             (when (string= method "POST")
               ;; store body as object if complete
               (setf (gethash key store)
                     (%make-s3-mock-object
                      :data body
                      :content-type "application/octet-stream"
                      :etag (%mock-etag body)
                      :last-modified "2020-01-01T00:00:00.000Z")))
             (make-s3-http-response
              :status 200
              :headers '(("content-type" . "application/xml"))
              :body (%utf8 (if (string= method "POST")
                               "<CompleteMultipartUploadResult></CompleteMultipartUploadResult>"
                               ""))))
            ;; List
            ((and (string= method "GET") (or (string= key "") is-list)
                  (or (assoc "list-type" q :test #'string=)
                      (string= key "")))
             (let ((xml (%mock-xml-list
                         bucket store
                         :prefix (cdr (assoc "prefix" q :test #'string=))
                         :max-keys (let ((m (cdr (assoc "max-keys" q :test #'string=))))
                                     (when m (parse-integer m :junk-allowed t)))
                         :start-after (cdr (assoc "start-after" q :test #'string=)))))
               (make-s3-http-response
                :status 200
                :headers '(("content-type" . "application/xml"))
                :body (%utf8 xml))))
            ;; PUT object
            ((string= method "PUT")
             (let* ((ct (or (%header-value (%headers-alist headers) "content-type")
                            "application/octet-stream"))
                    (etag (%mock-etag body)))
               (setf (gethash key store)
                     (%make-s3-mock-object
                      :data (copy-seq body)
                      :content-type ct
                      :etag etag
                      :last-modified "2020-01-01T00:00:00.000Z"))
               (make-s3-http-response
                :status 200
                :headers (list (cons "etag" (format nil "\"~A\"" etag)))
                :body (make-array 0 :element-type '(unsigned-byte 8)))))
            ;; GET object
            ((string= method "GET")
             (let ((obj (gethash key store)))
               (if obj
                   (let* ((data (s3mo-data obj))
                          (range (%header-value (%headers-alist headers) "range"))
                          (slice data))
                     (when range
                       (let* ((eq (position #\= range))
                              (spec (when eq (subseq range (1+ eq))))
                              (dash (when spec (position #\- spec)))
                              (start (if dash (parse-integer spec :end dash
                                                             :junk-allowed t) 0))
                              (end (if (and dash (< (1+ dash) (length spec))
                                            (plusp (length (subseq spec (1+ dash)))))
                                       (parse-integer spec :start (1+ dash)
                                                      :junk-allowed t)
                                       (1- (length data)))))
                         (setf slice (subseq data start (min (length data) (1+ end))))))
                     (make-s3-http-response
                      :status (if range 206 200)
                      :headers (list (cons "content-type" (s3mo-content-type obj))
                                     (cons "etag" (format nil "\"~A\"" (s3mo-etag obj)))
                                     (cons "content-length"
                                           (princ-to-string (length slice)))
                                     (cons "last-modified" (s3mo-last-modified obj)))
                      :body slice))
                   (make-s3-http-response
                    :status 404
                    :headers '(("content-type" . "application/xml"))
                    :body (%utf8 "<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error>")))))
            ;; HEAD
            ((string= method "HEAD")
             (let ((obj (gethash key store)))
               (if obj
                   (make-s3-http-response
                    :status 200
                    :headers (list (cons "content-type" (s3mo-content-type obj))
                                   (cons "etag" (format nil "\"~A\"" (s3mo-etag obj)))
                                   (cons "content-length"
                                         (princ-to-string (length (s3mo-data obj))))
                                   (cons "last-modified" (s3mo-last-modified obj)))
                    :body (make-array 0 :element-type '(unsigned-byte 8)))
                   (make-s3-http-response
                    :status 404
                    :headers nil
                    :body (make-array 0 :element-type '(unsigned-byte 8))))))
            ;; DELETE
            ((string= method "DELETE")
             (remhash key store)
             (make-s3-http-response
              :status 204
              :headers nil
              :body (make-array 0 :element-type '(unsigned-byte 8))))
            (t
             (make-s3-http-response
              :status 400
              :headers '(("content-type" . "application/xml"))
              :body (%utf8 (format nil "<Error><Code>InvalidRequest</Code><Message>~A ~A</Message></Error>"
                                   method path))))))))))

(defmacro with-s3-mock ((mock &rest mock-keys) &body body)
  "Bind *s3-http-fn* to a hermetic mock and evaluate BODY."
  `(let* ((,mock (make-s3-mock ,@mock-keys))
          (*s3-http-fn* (s3-mock-handler ,mock)))
     ,@body))
