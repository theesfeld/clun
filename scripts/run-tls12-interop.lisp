;;;; Client side of the hermetic OpenSSL TLS 1.2 interop gate.

(load (merge-pathnames "registry.lisp" *load-truename*))
(asdf:load-system :clun)

(let* ((port-text (sb-ext:posix-getenv "CLUN_TLS12_PORT"))
       (upload-port-text (sb-ext:posix-getenv "CLUN_TLS12_UPLOAD_PORT"))
       (ca-file (sb-ext:posix-getenv "CLUN_TLS12_CA_FILE"))
       (port (and port-text (parse-integer port-text)))
       (upload-port (and upload-port-text (parse-integer upload-port-text))))
  (unless (and port upload-port ca-file)
    (error "CLUN_TLS12_PORT, CLUN_TLS12_UPLOAD_PORT, and CLUN_TLS12_CA_FILE are required"))
  (let ((response (clun.net:https-request
                   :host "localhost" :port port :method "GET" :path "/"
                   :ca-file ca-file)))
    (unless (= 200 (clun.net:hres-status response))
      (error "TLS 1.2 peer returned HTTP ~d" (clun.net:hres-status response)))
    (unless (search "s_server"
                    (sb-ext:octets-to-string (clun.net:hres-body response)
                                             :external-format :latin-1))
      (error "TLS 1.2 peer response body was not the OpenSSL status page")))
  (let ((status nil)
        (chunks '())
        (complete-p nil))
    (clun.net:https-request-stream
     :host "localhost" :port port :method "GET" :path "/"
     :ca-file ca-file
     :on-headers (lambda (head)
                   (setf status (clun.net:hres-status head)))
     :on-data (lambda (chunk) (push chunk chunks))
     :on-complete (lambda () (setf complete-p t)))
    (unless (and (= 200 status) complete-p)
      (error "TLS 1.2 streaming response did not complete"))
    (unless (search
             "s_server"
             (sb-ext:octets-to-string
              (apply #'concatenate '(vector (unsigned-byte 8))
                     (nreverse chunks))
              :external-format :latin-1))
      (error "TLS 1.2 streaming body was not the OpenSSL status page")))
  (let ((status nil)
        (complete-p nil)
        (parts
          (list (sb-ext:string-to-octets "tls12-" :external-format :utf-8)
                (sb-ext:string-to-octets "upload" :external-format :utf-8)))
        (pulls 0))
    (clun.net:https-request-stream
     :host "localhost" :port upload-port :method "POST" :path "/upload"
     :ca-file ca-file
     :request-body-source
     (lambda ()
       (incf pulls)
       (if parts
           (values (pop parts) nil)
           (values nil t)))
     :on-headers (lambda (head)
                   (setf status (clun.net:hres-status head)))
     :on-data (lambda (chunk) (declare (ignore chunk)))
     :on-complete (lambda () (setf complete-p t)))
    (unless (and (= 200 status) complete-p (= 3 pulls))
      (error "TLS 1.2 streaming request body did not complete")))
  ;; Connect to the same loopback peer but authenticate an identity absent from
  ;; the fixture certificate.  Its SAN intentionally contains both localhost
  ;; and 127.0.0.1, so using the address itself would be a false negative.
  (let ((socket (make-instance 'sb-bsd-sockets:inet-socket
                               :type :stream :protocol :tcp))
        (failed nil))
    (unwind-protect
         (progn
           (sb-bsd-sockets:socket-connect
            socket (sb-bsd-sockets:make-inet-address "127.0.0.1") port)
           (let ((stream (sb-bsd-sockets:socket-make-stream
                          socket :input t :output t
                          :element-type '(unsigned-byte 8))))
             (handler-case
                 (clun.net::https-request-tls12
                  stream "wrong.example"
                  (clun.net::%serialize-request "GET" "/" "wrong.example" nil nil)
                  :ca-file ca-file)
               (pure-tls:tls-verification-error () (setf failed t)))))
      (ignore-errors (sb-bsd-sockets:socket-close socket)))
    (unless failed (error "TLS 1.2 wrong-host certificate was accepted")))
  (format t "TLS 1.2 interop: buffered + response/request streaming + wrong-host rejection passed~%"))
