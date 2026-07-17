;;;; http-client.lisp — a reactor HTTP/1.1 client over the Phase-16 tcp-connect (PLAN.md
;;;; Phase 18, §3.2). One request/response per call (fetch orchestrates redirects); the
;;;; response is parsed with the Phase-17 response parser, de-chunked, and gunzipped
;;;; (chipz) if Content-Encoding: gzip. Pure CL, callback-based; timeouts via the loop's
;;;; timer heap; returns a cancel thunk the fetch layer wires to an AbortSignal.

(in-package :clun.net)

(define-condition http-content-decoding-error (error)
  ((message :initarg :message :reader http-content-decoding-error-message))
  (:report (lambda (condition stream)
             (write-string (http-content-decoding-error-message condition) stream))))

(defparameter *max-decoded-body-bytes* *max-body-bytes*
  "Hard cap for an HTTP response after content decoding.  This prevents a small
gzip or deflate response from expanding beyond the parser's body budget.")

(defun %client-ascii-octets (s)
  (let ((v (make-array (length s) :element-type '(unsigned-byte 8))))
    (dotimes (i (length s) v) (setf (aref v i) (logand (char-code (char s i)) #xff)))))

(defun %request-framing-header-p (headers)
  (or (assoc "content-length" headers :test #'string-equal)
      (assoc "transfer-encoding" headers :test #'string-equal)))

(defun %request-keep-alive-p (headers)
  (not (find "close"
             (%comma-members
              (loop for (name . value) in headers
                    when (string-equal name "connection") collect value))
             :test #'string-equal)))

(defun %serialize-request (method path host-header headers body
                           &optional (default-accept-encoding "gzip")
                                     stream-body-p persistent-p)
  "Build the request bytes: request line + Host + user headers + framing + Accept-Encoding
+ a default persistent-connection header + body. HOST-HEADER is the ORIGIN authority
(hostname + non-default port) for the Host: line — NOT the resolved dotted-quad we dial."
  (when (and stream-body-p body)
    (error "a request cannot have both buffered and streaming bodies"))
  (when (and stream-body-p (%request-framing-header-p headers))
    (error "streaming request bodies cannot set Content-Length or Transfer-Encoding"))
  (let ((head (make-string-output-stream))
        (blen (if body (length body) 0)))
    (format head "~a ~a HTTP/1.1~c~c" method (if (plusp (length path)) path "/") #\Return #\Newline)
    (format head "Host: ~a~c~c" host-header #\Return #\Newline)
    (dolist (h headers)
      ;; strip CR/LF from header values (request smuggling guard)
      (format head "~a: ~a~c~c" (car h)
              (remove-if (lambda (c) (member c '(#\Return #\Newline))) (cdr h)) #\Return #\Newline))
    (unless (assoc "accept-encoding" headers :test #'string-equal)
      (format head "Accept-Encoding: ~a~c~c" default-accept-encoding
              #\Return #\Newline))
    (cond
      (stream-body-p
       (format head "Transfer-Encoding: chunked~c~c" #\Return #\Newline))
      ((plusp blen)
       (format head "Content-Length: ~d~c~c" blen #\Return #\Newline)))
    (unless (assoc "connection" headers :test #'string-equal)
      (format head "Connection: ~a~c~c"
              (if persistent-p "keep-alive" "close") #\Return #\Newline))
    (format head "~c~c" #\Return #\Newline)
    (let ((hbytes (%client-ascii-octets (get-output-stream-string head))))
      (if (plusp blen)
          (let ((out (make-array (+ (length hbytes) blen) :element-type '(unsigned-byte 8))))
            (replace out hbytes) (replace out body :start1 (length hbytes)) out)
          hbytes))))

(defun %chunked-request-frame (octets)
  "Frame one non-empty request-body chunk using HTTP/1.1 chunked coding."
  (when (zerop (length octets))
    (return-from %chunked-request-frame
      (make-array 0 :element-type '(unsigned-byte 8))))
  (let* ((prefix
           (%client-ascii-octets
            (format nil "~x~c~c" (length octets) #\Return #\Newline)))
         (suffix (%client-ascii-octets (format nil "~c~c" #\Return #\Newline)))
         (result
           (make-array (+ (length prefix) (length octets) (length suffix))
                       :element-type '(unsigned-byte 8))))
    (replace result prefix)
    (replace result octets :start1 (length prefix))
    (replace result suffix :start1 (+ (length prefix) (length octets)))
    result))

(defparameter +chunked-request-end+
  (%client-ascii-octets (format nil "0~c~c~c~c" #\Return #\Newline
                                #\Return #\Newline)))

(defun %decompress-body-bounded (format octets &key (max-bytes *max-decoded-body-bytes*))
  "Decode OCTETS in FORMAT without ever retaining more than MAX-BYTES of output."
  (handler-case
      (flexi-streams:with-input-from-sequence (input octets)
        (let* ((decoded (chipz:make-decompressing-stream format input))
               (capacity (max 1 (min (* 256 1024) max-bytes)))
               (output (make-array capacity :element-type '(unsigned-byte 8)
                                            :adjustable t :fill-pointer 0))
               (buffer (make-array (* 64 1024) :element-type '(unsigned-byte 8))))
          (loop for count = (read-sequence buffer decoded)
                while (plusp count) do
                  (when (> (+ (fill-pointer output) count) max-bytes)
                    (error 'http-content-decoding-error
                           :message "decoded HTTP body exceeded the size limit"))
                  (let* ((start (fill-pointer output))
                         (new (+ start count)))
                    (when (> new (array-total-size output))
                      (adjust-array output
                                    (min max-bytes
                                         (max new (* 2 (array-total-size output))))
                                    :fill-pointer start))
                    (setf (fill-pointer output) new)
                    (replace output buffer :start1 start :end2 count)))
          (coerce output '(simple-array (unsigned-byte 8) (*)))))
    (http-content-decoding-error (condition) (error condition))
    (chipz:decompression-error (condition)
      (error 'http-content-decoding-error
             :message (format nil "invalid compressed HTTP body: ~a" condition)))
    (error (condition)
      (error 'http-content-decoding-error
             :message (format nil "HTTP content decoding failed: ~a" condition)))))

(defun %decode-body (resp)
  "Decode a gzip or zlib-deflate RESP body in place; malformed input fails closed."
  (let ((enc (let ((value (%header (hres-headers resp) "content-encoding")))
               (and value (string-downcase value)))))
    (cond
      ((and enc (search "gzip" enc))
       (setf (hres-body resp) (%decompress-body-bounded :gzip (hres-body resp))))
      ((and enc (search "deflate" enc))
       (setf (hres-body resp) (%decompress-body-bounded :zlib (hres-body resp)))))
    resp))

(defun http-request-async (loop &key host port method path headers body timeout host-header on-response on-error)
  "Issue one HTTP request; call ON-RESPONSE with the parsed+decoded http-response, or
ON-ERROR with a code string (parse error / timeout / abort / connection error). Returns
a CANCEL thunk (abort in flight → ON-ERROR \"abort\"). HOST-HEADER (the origin authority
for the Host: line) defaults to HOST when the caller does not pass a distinct value."
  (let ((parser (make-http-response-parser)) (conn nil) (done nil) (timer nil)
        (dns-job nil) (connect-cancel nil)
        (hh (or host-header host)))
    (labels ((cleanup ()
               (setf done t)
               (when timer (lp:clear-timer timer))
               (when dns-job (lp:cancel-worker-job dns-job))
               (when connect-cancel (funcall connect-cancel))
               (when conn (tcp-close conn)))
             (fail (code) (unless done (cleanup) (funcall on-error code)))
             (ok (resp)
               (unless done
                 (handler-case
                     (let ((decoded (%decode-body resp)))
                       (cleanup)
                       (funcall on-response decoded))
                   (http-content-decoding-error (condition)
                     (fail (princ-to-string condition))))))
             (start-connect (addresses)
               (unless done
                 (setf connect-cancel
                       (tcp-connect-happy loop addresses port
                         :on-connect
                         (lambda (c)
                           (setf conn c)
                           (tcp-write c (%serialize-request method path hh headers body)))
                         :on-data
                         (lambda (c data)
                           (declare (ignore c))
                           (multiple-value-bind (event value) (parser-feed parser data)
                             (case event
                               (:response (ok value))
                               (:error
                                (fail (format nil "HTTP parse error ~a" (car value)))))))
                         :on-close
                         (lambda (c code)
                           (declare (ignore c))
                           (unless done
                             (multiple-value-bind (event value) (response-finish parser)
                               (if (eq event :response)
                                   (ok value)
                                   (fail (or code "connection closed"))))))
                         :on-error
                         (lambda (c code)
                           (declare (ignore c))
                           (fail code)))))))
      ;; DNS is blocking protocol I/O, so it belongs on the fixed worker pool. The
      ;; resolver returns an A/AAAA-interleaved candidate list consumed by the reactor
      ;; race above. Cancellation prevents a late DNS completion from opening sockets.
      (setf dns-job
            (lp:worker-submit-cancellable
             loop
             (lambda (token)
               (when (lp:worker-cancelled-p token)
                 (error 'socket-open-error :code "ECANCELED" :op "resolve"))
               (resolve-hostname-all
                host :cancelled-p
                (lambda () (lp:worker-cancelled-p token))))
             (lambda (result)
               (unless done
                 (case (first result)
                   (:ok (start-connect (second result)))
                   (:cancelled nil)
                   (t (fail (if (and (second result)
                                     (typep (second result) 'socket-open-error))
                                (socket-open-error-code (second result))
                                "ENOTFOUND"))))))))
      (when (and timeout (plusp timeout))
        (setf timer (lp:set-timer loop timeout (lambda () (fail "timeout")))))
      (lambda () (fail "abort")))))

(defun %stream-append-bounded (buffer octets max-bytes)
  "Append OCTETS to adjustable BUFFER without crossing MAX-BYTES."
  (let* ((old (fill-pointer buffer))
         (next (+ old (length octets))))
    (when (> next max-bytes)
      (error 'http-content-decoding-error
             :message "encoded HTTP body exceeded the size limit"))
    (when (> next (array-total-size buffer))
      (adjust-array buffer
                    (min max-bytes
                         (max next (* 2 (max 1 (array-total-size buffer)))))
                    :fill-pointer old))
    (setf (fill-pointer buffer) next)
    (replace buffer octets :start1 old)
    buffer))

(defun %response-content-encoding (response)
  (let ((value (%header (hres-headers response) "content-encoding")))
    (and value (string-downcase value))))

;;; --- per-loop HTTP/1.1 connection pool ------------------------------------

(defparameter *http-pool-max-idle-per-key* 8)
(defparameter *http-pool-idle-timeout-ms* 30000)
(defconstant +http-pool-extension-key+ 'http-connection-pool)

(defstruct (http-connection-pool (:constructor %make-http-connection-pool (loop)))
  loop
  (buckets (make-hash-table :test #'equal)))

(defstruct (http-pool-entry (:constructor %make-http-pool-entry (pool key tcp)))
  pool key tcp timer (idle-p t))

(defun %http-pool (loop)
  (or (lp:loop-extension loop +http-pool-extension-key+)
      (setf (lp:loop-extension loop +http-pool-extension-key+)
            (%make-http-connection-pool loop))))

(defun %tcp-address-family (tcp)
  (multiple-value-bind (address port) (tcp-peer tcp)
    (declare (ignore port))
    (case (and address (length address))
      (4 :ipv4)
      (16 :ipv6)
      (otherwise :unknown))))

(defun %http-pool-key (host port family)
  (list (string-downcase host) port family :plain))

(defun %http-pool-drop-entry (entry &key close)
  (when (http-pool-entry-idle-p entry)
    (setf (http-pool-entry-idle-p entry) nil)
    (let* ((pool (http-pool-entry-pool entry))
           (key (http-pool-entry-key entry))
           (bucket (gethash key (http-connection-pool-buckets pool)))
           (timer (http-pool-entry-timer entry)))
      (setf (gethash key (http-connection-pool-buckets pool))
            (delete entry bucket :test #'eq))
      (unless (gethash key (http-connection-pool-buckets pool))
        (remhash key (http-connection-pool-buckets pool)))
      (when timer
        (setf (http-pool-entry-timer entry) nil)
        (lp:clear-timer timer))
      (when close
        (tcp-close (http-pool-entry-tcp entry)))))
  (values))

(defun %http-pool-release (loop host port tcp)
  "Return TCP to LOOP's origin/family pool. Call only on the reactor thread."
  (unless (and (eq (tcp-state tcp) :open)
               (zerop (tcp-queued-bytes tcp)))
    (return-from %http-pool-release nil))
  (let* ((pool (%http-pool loop))
         (key (%http-pool-key host port (%tcp-address-family tcp)))
         (bucket (gethash key (http-connection-pool-buckets pool))))
    (when (>= (length bucket) *http-pool-max-idle-per-key*)
      (return-from %http-pool-release nil))
    (let ((entry (%make-http-pool-entry pool key tcp)))
      (push entry (gethash key (http-connection-pool-buckets pool)))
      (setf (tcp-on-drain tcp) nil
            (tcp-on-data tcp)
            (lambda (connection octets)
              (declare (ignore connection octets))
              ;; No request is outstanding, so any application bytes make this
              ;; sequential HTTP/1.1 connection unsafe to hand out again.
              (%http-pool-drop-entry entry :close t))
            (tcp-on-error tcp)
            (lambda (connection code)
              (declare (ignore connection code))
              (%http-pool-drop-entry entry))
            (tcp-on-close tcp)
            (lambda (connection code)
              (declare (ignore connection code))
              (%http-pool-drop-entry entry)))
      (setf (http-pool-entry-timer entry)
            (lp:set-timer loop *http-pool-idle-timeout-ms*
                          (lambda () (%http-pool-drop-entry entry :close t))
                          :refd nil))
      (lp:handle-unref (tcp-handle tcp))
      (tcp-resume tcp)
      t)))

(defun %http-pool-acquire (loop host port)
  "Take one live idle connection for HOST:PORT, preferring IPv6 when available."
  (let ((pool (%http-pool loop)))
    (dolist (family '(:ipv6 :ipv4 :unknown))
      (let* ((key (%http-pool-key host port family))
             (bucket (gethash key (http-connection-pool-buckets pool))))
        (loop while bucket do
          (let ((entry (pop bucket)))
            (setf (gethash key (http-connection-pool-buckets pool)) bucket)
            (unless bucket
              (remhash key (http-connection-pool-buckets pool)))
            (when (http-pool-entry-idle-p entry)
              (setf (http-pool-entry-idle-p entry) nil)
              (let ((timer (http-pool-entry-timer entry))
                    (tcp (http-pool-entry-tcp entry)))
                (when timer
                  (setf (http-pool-entry-timer entry) nil)
                  (lp:clear-timer timer))
                (when (eq (tcp-state tcp) :open)
                  (setf (tcp-on-data tcp) nil
                        (tcp-on-close tcp) nil
                        (tcp-on-error tcp) nil
                        (tcp-on-drain tcp) nil)
                  (lp:handle-ref (tcp-handle tcp))
                  (return-from %http-pool-acquire tcp)))))))))
  nil)

(defun %http-pool-idle-tcps (loop host port)
  "Internal test probe: snapshot idle TCP wrappers for one plain HTTP origin."
  (let ((pool (lp:loop-extension loop +http-pool-extension-key+))
        (result '()))
    (when pool
      (dolist (family '(:ipv6 :ipv4 :unknown))
        (dolist (entry (gethash (%http-pool-key host port family)
                                (http-connection-pool-buckets pool)))
          (when (http-pool-entry-idle-p entry)
            (push (http-pool-entry-tcp entry) result)))))
    result))

(defun http-request-stream-async
    (loop &key host port method path headers body timeout host-header
               request-body-stream-p on-request-ready
               on-headers on-data on-complete on-error)
  "Issue one HTTP request and deliver its response incrementally.

ON-HEADERS receives a bodyless HTTP-RESPONSE as soon as framing is validated.
ON-DATA receives bounded decoded octet chunks, and ON-COMPLETE marks clean body
completion. ON-ERROR may run before or after headers. The three return values are
idempotent CANCEL, PAUSE, and RESUME thunks. PAUSE/RESUME control reactor reads,
providing end-to-end inbound backpressure instead of merely bounding a user queue.

Identity bodies stream directly. If a peer sends gzip/deflate despite the default
identity request, encoded bytes remain bounded and are decoded at completion so
callers never observe compressed bytes as response data.

When REQUEST-BODY-STREAM-P is true, ON-REQUEST-READY receives WRITE and FINISH
callbacks after connect. WRITE accepts (octets continuation), sends one chunked
frame, and returns true when the socket accepted it without backpressure; otherwise
CONTINUATION runs on the drain edge. FINISH emits the sole terminal chunk."
  (let ((parser (make-http-response-stream-parser
                 :head-request-p (string-equal method "HEAD")))
        (conn nil)
        (done nil)
        (timer nil)
        (dns-job nil)
        (connect-cancel nil)
        (paused nil)
        (request-body-bytes 0)
        (request-finished-p (not request-body-stream-p))
        (content-format nil)
        (encoded-body nil)
        (request-keep-alive-p (%request-keep-alive-p headers))
        (hh (or host-header host)))
    (labels
        ((cleanup ()
           (setf done t)
           (when timer
             (lp:clear-timer timer)
             (setf timer nil))
           (when dns-job
             (lp:cancel-worker-job dns-job)
             (setf dns-job nil))
           (when connect-cancel
             (funcall connect-cancel)
             (setf connect-cancel nil))
           (when conn
             (tcp-close conn)
             (setf conn nil)))
         (fail (code)
           (unless done
             (cleanup)
             (when on-error (funcall on-error code))))
         (finish ()
           (unless done
             (handler-case
                 (progn
                   (when encoded-body
                     (let ((decoded
                             (%decompress-body-bounded
                              content-format
                              (subseq encoded-body 0
                                      (fill-pointer encoded-body)))))
                       (when (plusp (length decoded))
                         (funcall on-data decoded))))
                   (let ((connection conn)
                         (reusable-p
                           (and conn
                                request-keep-alive-p
                                request-finished-p
                                (response-stream-reusable-p parser)
                                (eq (tcp-state conn) :open)
                                (zerop (tcp-queued-bytes conn)))))
                     ;; Keep CLEANUP as the sole terminal-state transition, but
                     ;; detach an eligible connection before it closes resources.
                     (when reusable-p (setf conn nil))
                     (cleanup)
                     (when reusable-p
                       (unless (%http-pool-release loop host port connection)
                         (tcp-close connection))))
                   (when on-complete (funcall on-complete)))
               (http-content-decoding-error (condition)
                 (fail (princ-to-string condition))))))
         (deliver-events (events)
           (dolist (event events)
             (unless done
               (case (car event)
                 (:headers
                  (let ((encoding (%response-content-encoding (cdr event))))
                    (cond
                      ((and encoding (search "gzip" encoding))
                       (setf content-format :gzip))
                      ((and encoding (search "deflate" encoding))
                       (setf content-format :zlib)))
                    (when content-format
                      (setf encoded-body
                            (make-array (* 64 1024)
                                        :element-type '(unsigned-byte 8)
                                        :adjustable t :fill-pointer 0)))
                    (when on-headers (funcall on-headers (cdr event)))))
                 (:data
                  (handler-case
                      (if encoded-body
                          (%stream-append-bounded
                           encoded-body (cdr event) *max-body-bytes*)
                          (when on-data (funcall on-data (cdr event))))
                    (http-content-decoding-error (condition)
                      (fail (princ-to-string condition)))))
                 (:complete (finish))
                 (:error
                  (fail (format nil "HTTP parse error ~a" (car (cdr event)))))))))
         (connection-data (connection data)
           (declare (ignore connection))
           (deliver-events (response-stream-feed parser data)))
         (connection-close (connection code)
           (declare (ignore connection))
           (unless done
             (let ((events (response-stream-finish parser)))
               (if events
                   (deliver-events events)
                   (fail (or code "connection closed"))))))
         (connection-error (connection code)
           (declare (ignore connection))
           (fail code))
         (start-request (connection)
           (unless done
             (setf conn connection
                   connect-cancel nil
                   (tcp-on-data connection) #'connection-data
                   (tcp-on-close connection) #'connection-close
                   (tcp-on-error connection) #'connection-error
                   (tcp-on-drain connection) nil)
             ;; Fetch duplex "half" does not expose a response until the
             ;; upload is complete. The kernel may receive it, but the
             ;; reactor leaves it unread until the terminal chunk is queued.
             (when (or paused request-body-stream-p)
               (tcp-pause connection))
             (tcp-write
              connection
              (%serialize-request method path hh headers body "identity"
                                  request-body-stream-p t))
             (when request-body-stream-p
               (handler-case
                   (if on-request-ready
                       (funcall
                        on-request-ready
                        (lambda (chunk continuation)
                          (if (or done request-finished-p)
                              nil
                              (let ((framed (%chunked-request-frame chunk)))
                                (if (zerop (length framed))
                                    t
                                    (progn
                                      (incf request-body-bytes (length chunk))
                                      (when (> request-body-bytes *max-body-bytes*)
                                        (error
                                         "streaming request body exceeded the size limit"))
                                      (setf (tcp-on-drain connection)
                                            (lambda (drained)
                                              (declare (ignore drained))
                                              (setf (tcp-on-drain connection) nil)
                                              (unless done
                                                (funcall continuation))))
                                      (let ((queued (tcp-write connection framed)))
                                        (when (zerop queued)
                                          (setf (tcp-on-drain connection) nil))
                                        (zerop queued)))))))
                        (lambda ()
                          (unless (or done request-finished-p)
                            (setf request-finished-p t
                                  (tcp-on-drain connection) nil)
                            (tcp-write connection +chunked-request-end+)
                            (unless paused
                              (tcp-resume connection)))))
                       (fail "streaming request body has no producer"))
                 (error (condition)
                   (fail (princ-to-string condition)))))
             (when paused (tcp-pause connection))))
         (start-connect (addresses)
           (unless done
             (let ((cancel
                     (tcp-connect-happy
                      loop addresses port
                      :on-connect #'start-request
                      :on-data #'connection-data
                      :on-close #'connection-close
                      :on-error #'connection-error)))
               ;; TCP-CONNECT-HAPPY may settle synchronously. Never retain its
               ;; cancel thunk after a winner has become a pooled candidate.
               (cond
                 (done (funcall cancel))
                 (conn nil)
                 (t (setf connect-cancel cancel))))))
         (start-dns ()
           (setf dns-job
                 (lp:worker-submit-cancellable
                  loop
                  (lambda (token)
                    (when (lp:worker-cancelled-p token)
                      (error 'socket-open-error :code "ECANCELED" :op "resolve"))
                    (resolve-hostname-all
                     host :cancelled-p
                     (lambda () (lp:worker-cancelled-p token))))
                  (lambda (result)
                    (setf dns-job nil)
                    (unless done
                      (case (first result)
                        (:ok (start-connect (second result)))
                        (:cancelled nil)
                        (t
                         (fail
                          (if (and (second result)
                                   (typep (second result) 'socket-open-error))
                              (socket-open-error-code (second result))
                              "ENOTFOUND")))))))))
         (begin ()
           (unless done
             (when (and timeout (plusp timeout))
               (setf timer
                     (lp:set-timer loop timeout (lambda () (fail "timeout")))))
             (let ((pooled (%http-pool-acquire loop host port)))
               (if pooled
                   (start-request pooled)
                   (start-dns)))))
         (cancel (&optional (code "abort")) (fail code))
         (pause ()
           (unless done
             (setf paused t)
             (when conn (tcp-pause conn))))
         (resume ()
           (unless done
             (setf paused nil)
             (when (and conn request-finished-p) (tcp-resume conn)))))
      (lp:run-on-loop loop #'begin)
      (values #'cancel #'pause #'resume))))
