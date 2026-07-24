;;;; http.lisp — node:http createServer/request/get over pure-CL HTTP stack.

(in-package :clun.runtime)

(defun %http-wire-ee (obj)
  (let ((ee-proto (eng:js-get (eng:js-get (build-node-events) "EventEmitter")
                              "prototype")))
    (dolist (name '("on" "once" "emit" "removeListener" "off" "addListener"))
      (eng:data-prop obj name (eng:js-get ee-proto name)))
    obj))

(defun %http-status-reason (code)
  (or (case code
        (100 "Continue") (101 "Switching Protocols")
        (200 "OK") (201 "Created") (202 "Accepted") (204 "No Content")
        (301 "Moved Permanently") (302 "Found") (304 "Not Modified")
        (400 "Bad Request") (401 "Unauthorized") (403 "Forbidden")
        (404 "Not Found") (405 "Method Not Allowed")
        (408 "Request Timeout") (413 "Payload Too Large")
        (500 "Internal Server Error") (501 "Not Implemented")
        (502 "Bad Gateway") (503 "Service Unavailable"))
      "OK"))

(defun %http-chunk->octets (chunk)
  (cond
    ((or (undef-p chunk) (eng:js-null-p chunk))
     (make-array 0 :element-type '(unsigned-byte 8)))
    ((eng:js-typed-array-p chunk)
     (multiple-value-bind (b o l) (eng:ta-octets chunk)
       (subseq b o (+ o l))))
    ((eng:js-array-buffer-p chunk)
     (copy-seq (eng:js-array-buffer-bytes chunk)))
    (t (sb-ext:string-to-octets (->str chunk) :external-format :utf-8))))

(defun %http-octets->js (octets encoding)
  (if (and encoding (plusp (length encoding)))
      (handler-case
          (sb-ext:octets-to-string octets :external-format
                                   (if (string-equal encoding "utf8")
                                       :utf-8
                                       (intern (string-upcase encoding) :keyword)))
        (error ()
          (sb-ext:octets-to-string octets :external-format :latin-1)))
      (%buffer-from-octets octets)))

(defun %http-js-headers-alist (obj)
  "Convert a JS plain object of headers into a lower-cased (name . value) alist."
  (when (eng:js-object-p obj)
    (loop for k in (eng:jm-own-property-keys obj)
          when (stringp k)
            collect (cons (string-downcase k)
                          (->str (eng:js-get obj k))))))

(defun %http-headers-object-from-alist (alist)
  (let ((o (eng:new-object)))
    (dolist (pair alist o)
      (let ((name (car pair))
            (value (cdr pair))
            (prev (eng:js-get o (car pair))))
        (if (undef-p prev)
            (eng:data-prop o name value)
            (eng:js-set o name (format nil "~a, ~a" (->str prev) value) nil))))))

(defun %http-headers-alist-from-msg (msg)
  (let ((h (eng:js-get msg "_headers")))
    (if (eng:js-object-p h)
        (%http-js-headers-alist h)
        '())))

(defun %http-merge-header-object (target obj)
  (when (eng:js-object-p obj)
    (dolist (k (eng:jm-own-property-keys obj))
      (when (stringp k)
        (eng:js-set target (string-downcase k) (eng:js-get obj k) nil)))))

(defun %http-schedule (thunk)
  "Run THUNK on the next event-loop turn so listeners can attach first."
  (let ((loop (ignore-errors (eng:current-loop)))
        (realm eng:*realm*))
    (if loop
        (lp:enqueue-next-tick
         loop
         (lambda ()
           (let ((eng:*realm* realm))
             (funcall thunk))))
        (funcall thunk))))

(defun %http-emit-body (msg octets)
  "Emit data/end for an IncomingMessage once body octets are ready."
  (let ((encoding (eng:js-get msg "_encoding"))
        (body (or octets (make-array 0 :element-type '(unsigned-byte 8)))))
    (eng:hidden-prop msg "_rawBody" body)
    (%http-schedule
     (lambda ()
       (when (plusp (length body))
         (eng:js-call (eng:js-get msg "emit") msg
                      (list "data" (%http-octets->js body
                                                     (if (undef-p encoding)
                                                         nil
                                                         (->str encoding))))))
       (eng:js-call (eng:js-get msg "emit") msg (list "end"))
       (eng:js-call (eng:js-get msg "emit") msg (list "close"))))))

(defun %http-incoming (&key method url status-code status-message headers body
                            http-version socket)
  (let ((msg (%http-wire-ee (%ev-init (eng:new-object))))
        (hdrs (or headers (eng:new-object))))
    (eng:data-prop msg "headers" hdrs)
    (eng:data-prop msg "rawHeaders" (eng:new-array '()))
    (eng:data-prop msg "method" (or method "GET"))
    (eng:data-prop msg "url" (or url "/"))
    (eng:data-prop msg "httpVersion" (or http-version "1.1"))
    (eng:data-prop msg "httpVersionMajor" 1d0)
    (eng:data-prop msg "httpVersionMinor" 1d0)
    (eng:data-prop msg "statusCode"
                   (coerce (or status-code 200) 'double-float))
    (eng:data-prop msg "statusMessage" (or status-message "OK"))
    (eng:data-prop msg "complete" eng:+false+)
    (eng:data-prop msg "readable" eng:+true+)
    (when socket (eng:data-prop msg "socket" socket))
    (eng:hidden-prop msg "_encoding" eng:+null+)
    (eng:hidden-prop msg "_rawBody"
                     (or body (make-array 0 :element-type '(unsigned-byte 8))))
    (eng:install-method msg "setEncoding" 1
      (lambda (this args)
        (let ((enc (if (undef-p (a args 0)) "utf8" (->str (a args 0)))))
          (eng:hidden-prop this "_encoding" enc)
          this)))
    (eng:install-method msg "destroy" 1
      (lambda (this args)
        (unless (undef-p (a args 0))
          (eng:js-call (eng:js-get this "emit") this (list "error" (a args 0))))
        (eng:js-call (eng:js-get this "emit") this (list "close"))
        this))
    msg))

(defun %http-incoming-from-request (hr socket)
  (let* ((version (case (net:hr-version hr)
                    (:http/1.0 "1.0")
                    (t "1.1")))
         (headers (%http-headers-object-from-alist (net:hr-headers hr)))
         (msg (%http-incoming
               :method (net:hr-method hr)
               :url (net:hr-target hr)
               :headers headers
               :http-version version
               :body (or (net:hr-body hr) #())
               :socket socket)))
    (eng:data-prop msg "httpVersionMajor" 1d0)
    (eng:data-prop msg "httpVersionMinor"
                   (if (string= version "1.0") 0d0 1d0))
    msg))

(defun %http-incoming-from-response (hres)
  (let* ((version (case (net:hres-version hres)
                    (:http/1.0 "1.0")
                    (t "1.1")))
         (status (or (net:hres-status hres) 200))
         (reason (or (net:hres-reason hres) (%http-status-reason status)))
         (headers (%http-headers-object-from-alist (net:hres-headers hres)))
         (body (or (net:hres-body hres)
                   (make-array 0 :element-type '(unsigned-byte 8))))
         (msg (%http-incoming
               :status-code status
               :status-message reason
               :headers headers
               :http-version version
               :body body)))
    (eng:data-prop msg "complete" eng:+true+)
    msg))

(defun %http-serialize-response (status reason headers-alist body keep-alive)
  "Build HTTP/1.1 response octets (headers + body)."
  (let* ((status (or status 200))
         (reason (or reason (%http-status-reason status)))
         (body (or body (make-array 0 :element-type '(unsigned-byte 8))))
         (head (make-string-output-stream))
         (has-cl (assoc "content-length" headers-alist :test #'string-equal))
         (has-conn (assoc "connection" headers-alist :test #'string-equal)))
    (format head "HTTP/1.1 ~d ~a~c~c" status reason #\Return #\Newline)
    (dolist (pair headers-alist)
      (unless (member (car pair) '("content-length" "transfer-encoding")
                      :test #'string-equal)
        (format head "~a: ~a~c~c" (car pair) (cdr pair) #\Return #\Newline)))
    (unless has-cl
      (format head "Content-Length: ~d~c~c" (length body) #\Return #\Newline))
    (unless has-conn
      (format head "Connection: ~a~c~c"
              (if keep-alive "keep-alive" "close")
              #\Return #\Newline))
    (format head "~c~c" #\Return #\Newline)
    (let* ((hbytes (sb-ext:string-to-octets (get-output-stream-string head)
                                            :external-format :latin-1))
           (out (make-array (+ (length hbytes) (length body))
                            :element-type '(unsigned-byte 8))))
      (replace out hbytes)
      (replace out body :start1 (length hbytes))
      out)))

(defun %http-server-response (tcp &key (keep-alive t))
  (let ((res (%http-wire-ee (%ev-init (eng:new-object))))
        (headers (eng:new-object)))
    (eng:data-prop res "statusCode" 200d0)
    (eng:data-prop res "statusMessage" "OK")
    (eng:data-prop res "headersSent" eng:+false+)
    (eng:data-prop res "finished" eng:+false+)
    (eng:data-prop res "writableEnded" eng:+false+)
    (eng:hidden-prop res "_headers" headers)
    (eng:hidden-prop res "_tcp" tcp)
    (eng:hidden-prop res "_chunks" '())
    (eng:hidden-prop res "_keepAlive" (if keep-alive eng:+true+ eng:+false+))
    (eng:hidden-prop res "_ended" eng:+false+)
    (eng:install-method res "setHeader" 2
      (lambda (this args)
        (eng:js-set (eng:js-get this "_headers")
                    (string-downcase (->str (a args 0))) (a args 1) nil)
        (undef)))
    (eng:install-method res "getHeader" 1
      (lambda (this args)
        (eng:js-get (eng:js-get this "_headers")
                    (string-downcase (->str (a args 0))))))
    (eng:install-method res "removeHeader" 1
      (lambda (this args)
        (eng:js-set (eng:js-get this "_headers")
                    (string-downcase (->str (a args 0))) eng:+undefined+ nil)
        (undef)))
    (eng:install-method res "getHeaders" 0
      (lambda (this args)
        (declare (ignore args))
        (eng:js-get this "_headers")))
    (eng:install-method res "writeHead" 3
      (lambda (this args)
        (let ((status (a args 0))
              (arg1 (a args 1))
              (arg2 (a args 2)))
          (unless (undef-p status)
            (eng:js-set this "statusCode" (->num status) nil)
            (eng:js-set this "statusMessage"
                        (%http-status-reason (truncate (->num status))) nil))
          (cond
            ((eng:js-string-p arg1)
             (eng:js-set this "statusMessage" (->str arg1) nil)
             (when (eng:js-object-p arg2)
               (%http-merge-header-object (eng:js-get this "_headers") arg2)))
            ((eng:js-object-p arg1)
             (%http-merge-header-object (eng:js-get this "_headers") arg1)))
          (eng:js-set this "headersSent" eng:+true+ nil)
          this)))
    (eng:install-method res "write" 2
      (lambda (this args)
        (let ((chunk (a args 0))
              (cb (a args 1)))
          (when (eng:callable-p chunk)
            (setf cb chunk chunk eng:+undefined+))
          (unless (or (undef-p chunk) (eng:js-null-p chunk))
            (eng:hidden-prop this "_chunks"
                             (append (eng:js-get this "_chunks")
                                     (list (%http-chunk->octets chunk)))))
          (eng:js-set this "headersSent" eng:+true+ nil)
          (when (eng:callable-p cb) (eng:js-call cb (undef) '()))
          eng:+true+)))
    (eng:install-method res "end" 2
      (lambda (this args)
        (if (eng:js-truthy (eng:js-get this "_ended"))
            this
            (let ((chunk (a args 0))
                  (cb (a args 1)))
              (when (eng:callable-p chunk)
                (setf cb chunk chunk eng:+undefined+))
              (unless (or (undef-p chunk) (eng:js-null-p chunk))
                (eng:hidden-prop this "_chunks"
                                 (append (eng:js-get this "_chunks")
                                         (list (%http-chunk->octets chunk)))))
              (eng:hidden-prop this "_ended" eng:+true+)
              (eng:js-set this "writableEnded" eng:+true+ nil)
              (eng:js-set this "finished" eng:+true+ nil)
              (eng:js-set this "headersSent" eng:+true+ nil)
              (let* ((chunks (eng:js-get this "_chunks"))
                     (body (if chunks
                               (apply #'concatenate
                                      '(vector (unsigned-byte 8))
                                      chunks)
                               (make-array 0 :element-type '(unsigned-byte 8))))
                     (status (truncate (->num (eng:js-get this "statusCode"))))
                     (reason (let ((r (eng:js-get this "statusMessage")))
                               (if (or (undef-p r) (eng:js-null-p r))
                                   (%http-status-reason status)
                                   (->str r))))
                     (headers-alist (%http-headers-alist-from-msg this))
                     (keep-alive (eng:js-truthy (eng:js-get this "_keepAlive")))
                     (wire (%http-serialize-response status reason headers-alist
                                                     body keep-alive))
                     (tcp (eng:js-get this "_tcp")))
                (when tcp
                  (ignore-errors (net:tcp-write tcp wire))
                  (unless keep-alive
                    (ignore-errors (net:tcp-shutdown tcp)))))
              (eng:js-call (eng:js-get this "emit") this (list "finish"))
              (eng:js-call (eng:js-get this "emit") this (list "close"))
              (when (eng:callable-p cb) (eng:js-call cb (undef) '()))
              this))))
    res))

(defun %http-bind-connection (handler socket)
  "Parse HTTP/1.1 on SOCKET's TCP handle and invoke HANDLER(req, res)."
  (let ((tcp (eng:js-get socket "_tcp"))
        (parser (net:make-http-parser)))
    (unless tcp
      (return-from %http-bind-connection nil))
    (setf (net:tcp-on-data tcp)
          (lambda (c octets)
            (declare (ignore c))
            (loop
              (multiple-value-bind (event data)
                  (net:parser-feed parser octets)
                (setf octets
                      (make-array 0 :element-type '(unsigned-byte 8)))
                (case event
                  (:need-more (return))
                  (:request
                   (let* ((keep-alive (net:hr-keep-alive data))
                          (req (%http-incoming-from-request data socket))
                          (res (%http-server-response tcp
                                                      :keep-alive keep-alive)))
                     (eng:hidden-prop res "_keepAlive"
                                      (if keep-alive eng:+true+ eng:+false+))
                     (when (eng:callable-p handler)
                       (eng:js-call handler (undef) (list req res)))
                     (%http-emit-body req (or (net:hr-body data) #()))
                     (unless keep-alive (return))))
                  (:error
                   (let ((code (if (consp data) (car data) 400))
                         (reason (if (consp data) (cdr data) "Bad Request")))
                     (ignore-errors
                       (net:tcp-write
                        tcp
                        (%http-serialize-response code reason '()
                                                  (sb-ext:string-to-octets
                                                   (princ-to-string reason)
                                                   :external-format :utf-8)
                                                  nil)))
                     (ignore-errors (net:tcp-close tcp)))
                   (return)))))))
    (setf (net:tcp-on-close tcp)
          (lambda (c code)
            (declare (ignore c code))
            (eng:js-call (eng:js-get socket "emit") socket (list "close"))))
    t))

(defun %http-parse-url-string (s)
  "Parse http(s):// URL string → (values host port path method-default-port)."
  (handler-case
      (let* ((rec (%parse-url s))
             (scheme (ur-scheme rec))
             (host (or (ur-host rec) "127.0.0.1"))
             (port (or (ur-port rec)
                       (if (string= scheme "https") 443 80)))
             (path (concatenate
                    'string
                    (if (plusp (length (ur-path rec))) (ur-path rec) "/")
                    (if (ur-query rec)
                        (concatenate 'string "?" (ur-query rec))
                        ""))))
        (values host port path scheme))
    (error ()
      (values "127.0.0.1" 80 s "http"))))

(defun %http-host-header (host port default-port)
  (if (or (null port) (= port default-port))
      host
      (format nil "~a:~d" host port)))

(defun %http-client-request (opts cb &key (default-port 80) secure)
  (let ((req (%http-wire-ee (%ev-init (eng:new-object))))
        (host "127.0.0.1")
        (port (coerce default-port 'double-float))
        (path "/")
        (method "GET")
        (headers-alist '())
        (timeout nil)
        (agent eng:+undefined+))
    (when (eng:callable-p opts)
      (setf cb opts opts eng:+undefined+))
    (when (eng:js-string-p opts)
      (multiple-value-bind (h p pth scheme) (%http-parse-url-string (->str opts))
        (setf host h
              port (coerce p 'double-float)
              path pth)
        (when (and secure (string= scheme "http"))
          ;; https.request("http://…") still dials the given scheme's port/host.
          (setf port (coerce p 'double-float)))))
    (when (eng:js-object-p opts)
      (unless (undef-p (eng:js-get opts "hostname"))
        (setf host (->str (eng:js-get opts "hostname"))))
      (unless (undef-p (eng:js-get opts "host"))
        (let ((h (->str (eng:js-get opts "host"))))
          (let ((colon (position #\: h :from-end t)))
            (if (and colon (every #'digit-char-p (subseq h (1+ colon))))
                (setf host (subseq h 0 colon)
                      port (coerce (parse-integer (subseq h (1+ colon)))
                                   'double-float))
                (setf host h)))))
      (unless (undef-p (eng:js-get opts "port"))
        (setf port (->num (eng:js-get opts "port"))))
      (unless (undef-p (eng:js-get opts "path"))
        (setf path (->str (eng:js-get opts "path"))))
      (unless (undef-p (eng:js-get opts "method"))
        (setf method (string-upcase (->str (eng:js-get opts "method")))))
      (unless (undef-p (eng:js-get opts "timeout"))
        (setf timeout (truncate (->num (eng:js-get opts "timeout")))))
      (unless (undef-p (eng:js-get opts "agent"))
        (setf agent (eng:js-get opts "agent")))
      (let ((hdrs (eng:js-get opts "headers")))
        (when (eng:js-object-p hdrs)
          (setf headers-alist (%http-js-headers-alist hdrs)))))
    (eng:data-prop req "method" method)
    (eng:data-prop req "path" path)
    (eng:data-prop req "host" host)
    (eng:data-prop req "hostname" host)
    (eng:data-prop req "port" port)
    (eng:data-prop req "protocol" (if secure "https:" "http:"))
    (eng:data-prop req "aborted" eng:+false+)
    (eng:data-prop req "destroyed" eng:+false+)
    (eng:hidden-prop req "_cb" cb)
    (eng:hidden-prop req "_headers"
                     (let ((o (eng:new-object)))
                       (dolist (pair headers-alist o)
                         (eng:data-prop o (car pair) (cdr pair)))))
    (eng:hidden-prop req "_chunks" '())
    (eng:hidden-prop req "_cancel" eng:+null+)
    (eng:hidden-prop req "_timeout" (if timeout
                                        (coerce timeout 'double-float)
                                        eng:+undefined+))
    (eng:hidden-prop req "_agent" agent)
    (eng:hidden-prop req "_secure" (if secure eng:+true+ eng:+false+))
    (eng:hidden-prop req "_defaultPort" (coerce default-port 'double-float))
    (eng:install-method req "setHeader" 2
      (lambda (this args)
        (eng:js-set (eng:js-get this "_headers")
                    (string-downcase (->str (a args 0))) (a args 1) nil)
        (undef)))
    (eng:install-method req "getHeader" 1
      (lambda (this args)
        (eng:js-get (eng:js-get this "_headers")
                    (string-downcase (->str (a args 0))))))
    (eng:install-method req "removeHeader" 1
      (lambda (this args)
        (eng:js-set (eng:js-get this "_headers")
                    (string-downcase (->str (a args 0))) eng:+undefined+ nil)
        (undef)))
    (eng:install-method req "setTimeout" 2
      (lambda (this args)
        (unless (undef-p (a args 0))
          (eng:hidden-prop this "_timeout" (->num (a args 0))))
        (when (eng:callable-p (a args 1))
          (eng:js-call (eng:js-get this "once") this
                       (list "timeout" (a args 1))))
        this))
    (eng:install-method req "write" 2
      (lambda (this args)
        (let ((chunk (a args 0))
              (cb (a args 1)))
          (when (eng:callable-p chunk)
            (setf cb chunk chunk eng:+undefined+))
          (unless (or (undef-p chunk) (eng:js-null-p chunk))
            (eng:hidden-prop this "_chunks"
                             (append (eng:js-get this "_chunks")
                                     (list (%http-chunk->octets chunk)))))
          (when (eng:callable-p cb) (eng:js-call cb (undef) '()))
          eng:+true+)))
    (eng:install-method req "abort" 0
      (lambda (this args)
        (declare (ignore args))
        (eng:js-set this "aborted" eng:+true+ nil)
        (eng:js-set this "destroyed" eng:+true+ nil)
        (let ((cancel (eng:js-get this "_cancel")))
          (when (functionp cancel) (ignore-errors (funcall cancel))))
        (eng:js-call (eng:js-get this "emit") this (list "abort"))
        (eng:js-call (eng:js-get this "emit") this (list "close"))
        (undef)))
    (eng:install-method req "destroy" 1
      (lambda (this args)
        (eng:js-call (eng:js-get this "abort") this '())
        (unless (undef-p (a args 0))
          (eng:js-call (eng:js-get this "emit") this (list "error" (a args 0))))
        this))
    (eng:install-method req "end" 2
      (lambda (this args)
        (let ((chunk (a args 0))
              (cb (a args 1)))
          (when (eng:callable-p chunk)
            (setf cb chunk chunk eng:+undefined+))
          (unless (undef-p chunk)
            (eng:hidden-prop this "_chunks"
                             (append (eng:js-get this "_chunks")
                                     (list (%http-chunk->octets chunk)))))
          (let* ((chunks (eng:js-get this "_chunks"))
                 (body (if chunks
                           (apply #'concatenate
                                  '(vector (unsigned-byte 8))
                                  chunks)
                           nil))
                 (headers (%http-headers-alist-from-msg this))
                 (host (->str (eng:js-get this "host")))
                 (port (truncate (->num (eng:js-get this "port"))))
                 (path (->str (eng:js-get this "path")))
                 (method (->str (eng:js-get this "method")))
                 (secure (eng:js-truthy (eng:js-get this "_secure")))
                 (default-port (truncate
                                (->num (eng:js-get this "_defaultPort"))))
                 (host-header (%http-host-header host port default-port))
                 (timeout (eng:js-get this "_timeout"))
                 (timeout-ms (if (undef-p timeout)
                                 nil
                                 (truncate (->num timeout))))
                 (loop (eng:current-loop))
                 (callback (eng:js-get this "_cb")))
            (labels ((deliver-response (hres)
                       (let ((res (%http-incoming-from-response hres)))
                         (when (eng:callable-p callback)
                           (eng:js-call callback (undef) (list res)))
                         (eng:js-call (eng:js-get this "emit") this
                                      (list "response" res))
                         (%http-emit-body res (or (net:hres-body hres) #()))
                         (eng:js-call (eng:js-get this "emit") this
                                      (list "close"))))
                     (fail (code)
                       (eng:js-call (eng:js-get this "emit") this
                         (list "error"
                               (eng:js-construct
                                (eng:js-get (eng:realm-global eng:*realm*)
                                            "Error")
                                (list (format nil "http request failed: ~a"
                                              code)))))))
              (handler-case
                  (if secure
                      (let* ((box (list nil))
                             (job
                               (lp:worker-submit-cancellable
                                loop
                                (lambda (token)
                                  (net:https-request
                                   :host host :port port :method method
                                   :path path :headers headers :body body
                                   :host-header host-header
                                   :verify t
                                   :socket-box box
                                   :cancelled-p
                                   (lambda () (lp:worker-cancelled-p token))))
                                (lambda (result)
                                  (case (first result)
                                    (:ok (deliver-response (second result)))
                                    (:cancelled (fail "abort"))
                                    (:err
                                     (fail (net:tls-error-message
                                            (second result))))
                                    (t (fail "ECONNRESET")))))))
                        (eng:hidden-prop this "_cancel"
                                         (lambda ()
                                           (when (car box)
                                             (ignore-errors (funcall (car box))))
                                           (lp:cancel-worker-job job))))
                      (let ((cancel
                              (net:http-request-async
                               loop
                               :host host :port port :method method :path path
                               :headers headers :body body
                               :host-header host-header
                               :timeout timeout-ms
                               :on-response #'deliver-response
                               :on-error #'fail)))
                        (eng:hidden-prop this "_cancel" cancel)))
                (error (c) (fail (princ-to-string c))))))
          (when (eng:callable-p cb) (eng:js-call cb (undef) '()))
          this)))
    req))

(defun %http-status-codes ()
  (let ((sc (eng:new-object)))
    (eng:data-prop sc "200" "OK")
    (eng:data-prop sc "201" "Created")
    (eng:data-prop sc "202" "Accepted")
    (eng:data-prop sc "204" "No Content")
    (eng:data-prop sc "301" "Moved Permanently")
    (eng:data-prop sc "302" "Found")
    (eng:data-prop sc "304" "Not Modified")
    (eng:data-prop sc "400" "Bad Request")
    (eng:data-prop sc "401" "Unauthorized")
    (eng:data-prop sc "403" "Forbidden")
    (eng:data-prop sc "404" "Not Found")
    (eng:data-prop sc "405" "Method Not Allowed")
    (eng:data-prop sc "408" "Request Timeout")
    (eng:data-prop sc "413" "Payload Too Large")
    (eng:data-prop sc "500" "Internal Server Error")
    (eng:data-prop sc "501" "Not Implemented")
    (eng:data-prop sc "502" "Bad Gateway")
    (eng:data-prop sc "503" "Service Unavailable")
    sc))

(defun %http-make-agent (opts)
  (let ((agent (eng:new-object)))
    (eng:data-prop agent "protocol" "http:")
    (eng:data-prop agent "maxSockets"
                   (if (and (eng:js-object-p opts)
                            (not (undef-p (eng:js-get opts "maxSockets"))))
                       (->num (eng:js-get opts "maxSockets"))
                       5d0))
    (eng:data-prop agent "maxFreeSockets"
                   (if (and (eng:js-object-p opts)
                            (not (undef-p (eng:js-get opts "maxFreeSockets"))))
                       (->num (eng:js-get opts "maxFreeSockets"))
                       256d0))
    (eng:data-prop agent "maxTotalSockets"
                   (if (and (eng:js-object-p opts)
                            (not (undef-p (eng:js-get opts "maxTotalSockets"))))
                       (->num (eng:js-get opts "maxTotalSockets"))
                       eng:+undefined+))
    (eng:data-prop agent "keepAlive"
                   (if (and (eng:js-object-p opts)
                            (eng:js-truthy (eng:js-get opts "keepAlive")))
                       eng:+true+ eng:+false+))
    (eng:data-prop agent "keepAliveMsecs"
                   (if (and (eng:js-object-p opts)
                            (not (undef-p (eng:js-get opts "keepAliveMsecs"))))
                       (->num (eng:js-get opts "keepAliveMsecs"))
                       1000d0))
    (eng:data-prop agent "scheduling" "lifo")
    (eng:data-prop agent "requests" (eng:new-object))
    (eng:data-prop agent "sockets" (eng:new-object))
    (eng:data-prop agent "freeSockets" (eng:new-object))
    (eng:install-method agent "destroy" 0
      (lambda (this args)
        (declare (ignore args))
        (eng:js-set this "sockets" (eng:new-object) nil)
        (eng:js-set this "freeSockets" (eng:new-object) nil)
        (eng:js-set this "requests" (eng:new-object) nil)
        (undef)))
    agent))

(defun build-node-http ()
  (let ((o (eng:new-object)))
    (eng:install-method o "createServer" 2
      (lambda (this args)
        (declare (ignore this))
        (let* ((arg0 (a args 0))
               (arg1 (a args 1))
               (handler (cond ((eng:callable-p arg0) arg0)
                              ((eng:callable-p arg1) arg1)
                              (t eng:+undefined+)))
               (options (if (and (eng:js-object-p arg0)
                                 (not (eng:callable-p arg0)))
                            arg0
                            eng:+undefined+))
               (server (eng:js-construct
                        (eng:js-get (build-node-net) "Server") '())))
          (when (eng:js-object-p options)
            (eng:hidden-prop server "_httpOptions" options))
          (eng:hidden-prop server "_requestListener" handler)
          (eng:js-call (eng:js-get server "on") server
                       (list "connection"
                             (eng:make-native-function
                              "" 1
                              (lambda (tt aa)
                                (declare (ignore tt))
                                (let ((sock (a aa 0))
                                      (h (eng:js-get server "_requestListener")))
                                  (%http-bind-connection h sock)
                                  (undef))))))
          server)))
    (eng:install-method o "request" 3
      (lambda (this args)
        (declare (ignore this))
        (%http-client-request (a args 0) (a args 1)
                              :default-port 80 :secure nil)))
    (eng:install-method o "get" 3
      (lambda (this args)
        (declare (ignore this))
        (let ((req (%http-client-request (a args 0) (a args 1)
                                         :default-port 80 :secure nil)))
          (eng:js-call (eng:js-get req "end") req '())
          req)))
    (eng:data-prop o "METHODS"
                   (eng:new-array '("GET" "POST" "PUT" "DELETE" "HEAD" "OPTIONS"
                                    "PATCH" "TRACE" "CONNECT")))
    (eng:data-prop o "STATUS_CODES" (%http-status-codes))
    (eng:data-prop o "Agent"
                   (eng:make-native-function
                    "Agent" 1
                    (lambda (this args)
                      (when (eng:js-object-p this)
                        (let ((built (%http-make-agent (a args 0))))
                          (dolist (k (eng:jm-own-property-keys built))
                            (when (stringp k)
                              (eng:data-prop this k (eng:js-get built k))))))
                      (undef))
                    :construct
                    (lambda (args nt)
                      (declare (ignore nt))
                      (%http-make-agent (a args 0)))))
    (eng:data-prop o "globalAgent" (%http-make-agent eng:+undefined+))
    (eng:data-prop o "IncomingMessage"
                   (eng:make-native-function
                    "IncomingMessage" 1
                    (lambda (this args)
                      (declare (ignore this))
                      (%http-incoming :socket (a args 0)))
                    :construct
                    (lambda (args nt)
                      (declare (ignore nt))
                      (%http-incoming :socket (a args 0)))))
    (eng:data-prop o "ServerResponse"
                   (eng:make-native-function
                    "ServerResponse" 1
                    (lambda (this args)
                      (declare (ignore this))
                      (%http-server-response
                       (let ((req (a args 0)))
                         (when (eng:js-object-p req)
                           (let ((sock (eng:js-get req "socket")))
                             (when (eng:js-object-p sock)
                               (eng:js-get sock "_tcp")))))))
                    :construct
                    (lambda (args nt)
                      (declare (ignore nt))
                      (%http-server-response
                       (let ((req (a args 0)))
                         (when (eng:js-object-p req)
                           (let ((sock (eng:js-get req "socket")))
                             (when (eng:js-object-p sock)
                               (eng:js-get sock "_tcp")))))))))
    (eng:data-prop o "ClientRequest"
                   (eng:make-native-function
                    "ClientRequest" 2
                    (lambda (this args)
                      (declare (ignore this))
                      (%http-client-request (a args 0) (a args 1)))
                    :construct
                    (lambda (args nt)
                      (declare (ignore nt))
                      (%http-client-request (a args 0) (a args 1)))))
    (eng:data-prop o "Server"
                   (eng:js-get (build-node-net) "Server"))
    (eng:install-method o "validateHeaderName" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((name (->str (a args 0))))
          (unless (and (plusp (length name))
                       (every (lambda (c)
                                (or (alphanumericp c)
                                    (find c "!#$%&'*+-.^_`|~" :test #'char=)))
                              name))
            (eng:throw-type-error
             (format nil "Header name must be a valid HTTP token [\"~a\"]" name)))
          (undef))))
    (eng:install-method o "validateHeaderValue" 2
      (lambda (this args)
        (declare (ignore this))
        (let ((name (->str (a args 0)))
              (value (->str (a args 1))))
          (when (some (lambda (c) (or (char= c #\Return) (char= c #\Newline)
                                      (char= c #\Null)))
                      value)
            (eng:throw-type-error
             (format nil "Invalid character in header content [\"~a\"]" name)))
          (undef))))
    o))

(register-node-builtin "http" #'build-node-http)
