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

(defun %serialize-request (method path host-header headers body)
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
      (format head "Accept-Encoding: gzip~c~c" #\Return #\Newline))
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
