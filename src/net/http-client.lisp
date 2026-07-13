;;;; http-client.lisp — a reactor HTTP/1.1 client over the Phase-16 tcp-connect (PLAN.md
;;;; Phase 18, §3.2). One request/response per call (fetch orchestrates redirects); the
;;;; response is parsed with the Phase-17 response parser, de-chunked, and gunzipped
;;;; (chipz) if Content-Encoding: gzip. Pure CL, callback-based; timeouts via the loop's
;;;; timer heap; returns a cancel thunk the fetch layer wires to an AbortSignal.

(in-package :clun.net)

(defun %dotted-quad-p (s)
  (and (plusp (length s)) (every (lambda (c) (or (digit-char-p c) (char= c #\.))) s) (find #\. s)))

(defun resolve-hostname (host)
  "A hostname → a dotted-quad IPv4 string for make-inet-address. localhost + IP literals are
direct; else blocking sb-bsd-sockets:get-host-by-name (v1 — no getaddrinfo; AAAA is post-v1)."
  (cond
    ((null host) "127.0.0.1")
    ((string-equal host "localhost") "127.0.0.1")
    ((%dotted-quad-p host) host)
    (t (handler-case
           (format nil "~{~d~^.~}"
                   (coerce (sb-bsd-sockets:host-ent-address (sb-bsd-sockets:get-host-by-name host)) 'list))
         (error () (error 'socket-open-error :code "ENOTFOUND" :op "getaddrinfo"))))))

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

(defun %decode-body (resp)
  "Gunzip RESP's body in place if Content-Encoding: gzip (or deflate); else leave it."
  (let ((enc (let ((v (%header (hres-headers resp) "content-encoding"))) (and v (string-downcase v)))))
    (when enc
      (handler-case
          (cond ((search "gzip" enc) (setf (hres-body resp) (chipz:decompress nil :gzip (hres-body resp))))
                ((search "deflate" enc) (setf (hres-body resp) (chipz:decompress nil :zlib (hres-body resp)))))
        (error () nil)))                  ; a decode failure leaves the raw body (best-effort)
    resp))

(defun http-request-async (loop &key host port method path headers body timeout host-header on-response on-error)
  "Issue one HTTP request; call ON-RESPONSE with the parsed+decoded http-response, or
ON-ERROR with a code string (parse error / timeout / abort / connection error). Returns
a CANCEL thunk (abort in flight → ON-ERROR \"abort\"). HOST-HEADER (the origin authority
for the Host: line) defaults to HOST when the caller does not pass a distinct value."
  (let ((parser (make-http-response-parser)) (conn nil) (done nil) (timer nil)
        (hh (or host-header host)))
    (labels ((cleanup () (setf done t) (when timer (lp:clear-timer timer))
                       (when conn (tcp-close conn)))
             (fail (code) (unless done (cleanup) (funcall on-error code)))
             (ok (resp) (unless done (cleanup) (funcall on-response (%decode-body resp)))))
      (setf conn
            (tcp-connect loop host port
              :on-connect (lambda (c) (tcp-write c (%serialize-request method path hh headers body)))
              :on-data (lambda (c data) (declare (ignore c))
                         (multiple-value-bind (ev d) (parser-feed parser data)
                           (case ev
                             (:response (ok d))
                             (:error (fail (format nil "HTTP parse error ~a" (car d)))))))
              :on-close (lambda (c code) (declare (ignore c))
                          (unless done
                            (multiple-value-bind (ev d) (response-finish parser)  ; until-close body @ EOF
                              (if (eq ev :response) (ok d) (fail (or code "connection closed"))))))
              :on-error (lambda (c code) (declare (ignore c)) (fail code))))
      (when (and timeout (plusp timeout))
        (setf timer (lp:set-timer loop timeout (lambda () (fail "timeout")))))
      (lambda () (fail "abort")))))
