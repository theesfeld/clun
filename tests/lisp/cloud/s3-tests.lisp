;;;; s3-tests.lisp — Pure-CL S3 client (Issue #185 / FULL PORT / Phase 53).

(in-package :clun-test)

(defun %s3-error-kind (thunk)
  (handler-case (progn (funcall thunk) nil)
    (clun.s3:s3-error (c) (clun.s3:s3-error-kind c))))

(defun %fixed-ut ()
  ;; 2013-05-24T00:00:00Z — classic AWS SigV4 example moment
  (encode-universal-time 0 0 0 24 5 2013 0))

(define-test cloud/s3-uri-encode
  (is string= "foo" (clun.s3:%uri-encode "foo"))
  (is string= "a%2Fb" (clun.s3:%uri-encode "a/b" :encode-slash t))
  (is string= "a/b" (clun.s3:%uri-encode "a/b" :encode-slash nil))
  (is string= "a%20b" (clun.s3:%uri-encode "a b"))
  (is string= "~" (clun.s3:%uri-encode "~")))

(define-test cloud/s3-empty-payload-hash
  (is string=
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      (clun.s3:%empty-payload-hash))
  (is string= (clun.s3:%empty-payload-hash)
      (clun.s3:%sha256-hex (make-array 0 :element-type '(unsigned-byte 8)))))

(define-test cloud/s3-signing-key-deterministic
  ;; AWS docs: secret wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY
  ;; date 20150830 region us-east-1 service iam
  (let* ((secret "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
         (key (clun.s3:signing-key secret "20150830" "us-east-1" "iam"))
         (hex (clun.s3:%hex key)))
    (is string=
        "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9"
        hex)))

(define-test cloud/s3-canonical-request-shape
  (multiple-value-bind (canon signed)
      (clun.s3:create-canonical-request
       "GET" "/test.txt" "Action=ListUsers&Version=2010-05-08"
       '(("host" . "example.amazonaws.com")
         ("x-amz-date" . "20150830T123600Z"))
       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    (true (search "GET" canon))
    (true (search "host:example.amazonaws.com" canon))
    (true (search "host;x-amz-date" signed))
    (is string= "host;x-amz-date" signed)))

(define-test cloud/s3-credentials-precedence
  (let ((opts (clun.s3:make-s3-options
               :access-key-id "AKIA_EXPLICIT"
               :secret-access-key "secret_explicit"
               :bucket "b1"
               :region "eu-west-1"
               :endpoint "http://127.0.0.1:9000"
               :path-style t)))
    (is string= "AKIA_EXPLICIT" (clun.s3:s3o-access-key-id opts))
    (is string= "secret_explicit" (clun.s3:s3o-secret-access-key opts))
    (is string= "b1" (clun.s3:s3o-bucket opts))
    (is string= "eu-west-1" (clun.s3:s3o-region opts))
    (true (clun.s3:s3o-path-style opts))
    (false (clun.s3:s3o-virtual-hosted-style opts))))

(define-test cloud/s3-path-style-endpoint
  (let* ((opts (clun.s3:make-s3-options
                :access-key-id "k" :secret-access-key "s"
                :bucket "mybucket" :region "us-east-1"
                :endpoint "http://localhost:9000"
                :path-style t))
         (ep (clun.s3:resolve-endpoint opts)))
    (is string= "localhost" (clun.s3::s3e-host ep))
    (is = 9000 (clun.s3::s3e-port ep))
    (is string= "/mybucket" (clun.s3::s3e-path-prefix ep))
    (is string= "/mybucket/a/b.txt"
        (clun.s3:object-canonical-uri ep "a/b.txt"))))

(define-test cloud/s3-virtual-hosted-endpoint
  (let* ((opts (clun.s3:make-s3-options
                :access-key-id "k" :secret-access-key "s"
                :bucket "mybucket" :region "us-west-2"
                :virtual-hosted-style t))
         (ep (clun.s3:resolve-endpoint opts)))
    (true (search "mybucket." (clun.s3::s3e-host ep)))
    (is string= "" (clun.s3::s3e-path-prefix ep))
    (is string= "/a.txt" (clun.s3:object-canonical-uri ep "a.txt"))))

(define-test cloud/s3-presign-contains-signature
  (let* ((clun.s3:*s3-clock* #'%fixed-ut)
         (opts (clun.s3:make-s3-options
                :access-key-id "AKID" :secret-access-key "SECRET"
                :bucket "bucket" :region "us-east-1"
                :endpoint "https://s3.amazonaws.com"
                :path-style t))
         (url (clun.s3:presign opts "hello.txt" :expires-in 3600
                               :timestamp (%fixed-ut))))
    (true (search "X-Amz-Algorithm=AWS4-HMAC-SHA256" url))
    (true (search "X-Amz-Signature=" url))
    (true (search "X-Amz-Expires=3600" url))
    (true (search "/bucket/hello.txt" url))))

(define-test cloud/s3-missing-credentials
  (is eq :missing-credentials
      (%s3-error-kind
       (lambda ()
         (let ((opts (clun.s3:make-s3-options
                      :access-key-id "tmp" :secret-access-key "tmp"
                      :bucket "b")))
           (setf (clun.s3:s3o-access-key-id opts) nil
                 (clun.s3:s3o-secret-access-key opts) nil)
           (clun.s3:require-credentials opts :need-bucket t))))))

(define-test cloud/s3-hermetic-put-get-delete
  (clun.s3:with-s3-mock (mock :access-key-id "k" :secret-access-key "s")
    (declare (ignore mock))
    (let* ((client (clun.s3:make-s3-client
                    :access-key-id "k" :secret-access-key "s"
                    :bucket "test-bucket" :region "us-east-1"
                    :endpoint "http://s3.mock.local"
                    :path-style t
                    :retry 0))
           (payload "hello clun s3"))
      (multiple-value-bind (etag n)
          (clun.s3:s3-put client "greeting.txt" payload
                          :content-type "text/plain")
        (true (stringp etag))
        (is = (length (sb-ext:string-to-octets payload :external-format :utf-8)) n))
      (is string= payload (clun.s3:s3-get-text client "greeting.txt"))
      (true (clun.s3:s3-exists client "greeting.txt"))
      (let ((st (clun.s3:s3-stat client "greeting.txt")))
        (true (plusp (clun.s3:s3s-size st)))
        (true (stringp (clun.s3:s3s-etag st))))
      (is = (length (sb-ext:string-to-octets payload :external-format :utf-8))
          (clun.s3:s3-size client "greeting.txt"))
      (true (clun.s3:s3-delete client "greeting.txt"))
      (false (clun.s3:s3-exists client "greeting.txt")))))

(define-test cloud/s3-hermetic-list-prefix
  (clun.s3:with-s3-mock (mock)
    (declare (ignore mock))
    (let ((client (clun.s3:make-s3-client
                   :access-key-id "test-key" :secret-access-key "test-secret"
                   :bucket "b" :region "us-east-1"
                   :endpoint "http://s3.mock.local" :path-style t :retry 0)))
      (clun.s3:s3-put client "a/1.txt" "one")
      (clun.s3:s3-put client "a/2.txt" "two")
      (clun.s3:s3-put client "b/3.txt" "three")
      (let* ((listing (clun.s3:s3-list client :prefix "a/"))
             (keys (mapcar (lambda (c) (getf c :key)) (getf listing :contents))))
        (true (member "a/1.txt" keys :test #'string=))
        (true (member "a/2.txt" keys :test #'string=))
        (false (member "b/3.txt" keys :test #'string=))
        (is = 2 (length keys))))))

(define-test cloud/s3-hermetic-range-get
  (clun.s3:with-s3-mock (mock)
    (declare (ignore mock))
    (let ((client (clun.s3:make-s3-client
                   :access-key-id "test-key" :secret-access-key "test-secret"
                   :bucket "b" :region "us-east-1"
                   :endpoint "http://s3.mock.local" :path-style t :retry 0)))
      (clun.s3:s3-put client "range.bin" "0123456789")
      (let ((part (clun.s3:s3-get-text client "range.bin" :range (cons 2 5))))
        (is string= "2345" part)))))

(define-test cloud/s3-hermetic-file-handle
  (clun.s3:with-s3-mock (mock)
    (declare (ignore mock))
    (let* ((client (clun.s3:make-s3-client
                    :access-key-id "test-key" :secret-access-key "test-secret"
                    :bucket "b" :region "us-east-1"
                    :endpoint "http://s3.mock.local" :path-style t :retry 0))
           (file (clun.s3:s3-file client "file.json")))
      (clun.s3:s3-file-write file "{\"ok\":true}" :content-type "application/json")
      (is string= "{\"ok\":true}" (clun.s3:s3-file-text file))
      (true (clun.s3:s3-file-exists file))
      (true (clun.s3:s3-file-delete file))
      (false (clun.s3:s3-file-exists file)))))

(define-test cloud/s3-hermetic-not-found
  (clun.s3:with-s3-mock (mock)
    (declare (ignore mock))
    (let ((client (clun.s3:make-s3-client
                   :access-key-id "test-key" :secret-access-key "test-secret"
                   :bucket "b" :region "us-east-1"
                   :endpoint "http://s3.mock.local" :path-style t :retry 0)))
      (is eq :not-found
          (%s3-error-kind
           (lambda () (clun.s3:s3-get client "missing.txt")))))))

(define-test cloud/s3-hermetic-batch-delete
  (clun.s3:with-s3-mock (mock)
    (declare (ignore mock))
    (let ((client (clun.s3:make-s3-client
                   :access-key-id "test-key" :secret-access-key "test-secret"
                   :bucket "b" :region "us-east-1"
                   :endpoint "http://s3.mock.local" :path-style t :retry 0)))
      (clun.s3:s3-put client "x" "1")
      (clun.s3:s3-put client "y" "2")
      (true (stringp (clun.s3:s3-delete-objects client '("x" "y")))))))

(define-test cloud/s3-sign-request-headers
  (let* ((clun.s3:*s3-clock* #'%fixed-ut)
         (opts (clun.s3:make-s3-options
                :access-key-id "AKID" :secret-access-key "SECRET"
                :bucket "bucket" :region "us-east-1"
                :endpoint "http://localhost:9000" :path-style t)))
    (multiple-value-bind (auth amz hash signed headers)
        (clun.s3:sign-request opts :method "PUT" :key "obj" :body "hi"
                                   :timestamp (%fixed-ut))
      (true (search "AWS4-HMAC-SHA256" auth))
      (true (search "Signature=" auth))
      (true (stringp amz))
      (true (stringp hash))
      (true (search "host" signed))
      (true (assoc "authorization" headers :test #'string-equal))
      (true (assoc "x-amz-date" headers :test #'string-equal)))))

(define-test cloud/s3-exceed-surface-present
  "Exceed-Bun APIs are exported and callable."
  (true (fboundp 'clun.s3:s3-copy))
  (true (fboundp 'clun.s3:s3-delete-objects))
  (true (fboundp 'clun.s3:s3-create-multipart))
  (true (fboundp 'clun.s3:s3-write))
  (true (fboundp 'clun.s3:presign))
  (true (fboundp 'clun.s3:with-s3-mock)))
