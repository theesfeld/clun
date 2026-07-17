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

(defun %serialize-request (method path host-header headers body
                           &optional (default-accept-encoding "gzip"))
  "Build the request bytes: request line + Host + user headers + framing + Accept-Encoding
+ Connection: close (v1 does not pool) + body. HOST-HEADER is the ORIGIN authority
(hostname + non-default port) for the Host: line — NOT the resolved dotted-quad we dial."
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
    (when (plusp blen) (format head "Content-Length: ~d~c~c" blen #\Return #\Newline))
    (format head "Connection: close~c~c" #\Return #\Newline)
    (format head "~c~c" #\Return #\Newline)
    (let ((hbytes (%client-ascii-octets (get-output-stream-string head))))
      (if (plusp blen)
          (let ((out (make-array (+ (length hbytes) blen) :element-type '(unsigned-byte 8))))
            (replace out hbytes) (replace out body :start1 (length hbytes)) out)
          hbytes))))

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
               (resolve-hostname-all host))
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

(defun http-request-stream-async
    (loop &key host port method path headers body timeout host-header
               on-headers on-data on-complete on-error)
  "Issue one HTTP request and deliver its response incrementally.

ON-HEADERS receives a bodyless HTTP-RESPONSE as soon as framing is validated.
ON-DATA receives bounded decoded octet chunks, and ON-COMPLETE marks clean body
completion. ON-ERROR may run before or after headers. The three return values are
idempotent CANCEL, PAUSE, and RESUME thunks. PAUSE/RESUME control reactor reads,
providing end-to-end inbound backpressure instead of merely bounding a user queue.

Identity bodies stream directly. If a peer sends gzip/deflate despite the default
identity request, encoded bytes remain bounded and are decoded at completion so
callers never observe compressed bytes as response data."
  (let ((parser (make-http-response-stream-parser
                 :head-request-p (string-equal method "HEAD")))
        (conn nil)
        (done nil)
        (timer nil)
        (dns-job nil)
        (connect-cancel nil)
        (paused nil)
        (content-format nil)
        (encoded-body nil)
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
                   (cleanup)
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
         (start-connect (addresses)
           (unless done
             (setf connect-cancel
                   (tcp-connect-happy
                    loop addresses port
                    :on-connect
                    (lambda (connection)
                      (setf conn connection)
                      (tcp-write
                       connection
                       (%serialize-request method path hh headers body "identity"))
                      (when paused (tcp-pause connection)))
                    :on-data
                    (lambda (connection data)
                      (declare (ignore connection))
                      (deliver-events (response-stream-feed parser data)))
                    :on-close
                    (lambda (connection code)
                      (declare (ignore connection))
                      (unless done
                        (let ((events (response-stream-finish parser)))
                          (if events
                              (deliver-events events)
                              (fail (or code "connection closed"))))))
                    :on-error
                    (lambda (connection code)
                      (declare (ignore connection))
                      (fail code))))))
         (cancel () (fail "abort"))
         (pause ()
           (unless done
             (setf paused t)
             (when conn (tcp-pause conn))))
         (resume ()
           (unless done
             (setf paused nil)
             (when conn (tcp-resume conn)))))
      (setf dns-job
            (lp:worker-submit-cancellable
             loop
             (lambda (token)
               (when (lp:worker-cancelled-p token)
                 (error 'socket-open-error :code "ECANCELED" :op "resolve"))
               (resolve-hostname-all host))
             (lambda (result)
               (unless done
                 (case (first result)
                   (:ok (start-connect (second result)))
                   (:cancelled nil)
                   (t
                    (fail
                     (if (and (second result)
                              (typep (second result) 'socket-open-error))
                         (socket-open-error-code (second result))
                         "ENOTFOUND"))))))))
      (when (and timeout (plusp timeout))
        (setf timer
              (lp:set-timer loop timeout (lambda () (fail "timeout")))))
      (values #'cancel #'pause #'resume))))
