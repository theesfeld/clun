;;;; clun-serve.lisp — Clun.serve (PLAN.md Phase 17, §3.6). Wires the Phase-16 socket
;;;; layer + the HTTP parser + the web classes + the user's JS `fetch` handler. Fully
;;;; async on the reactor: a synchronous Response is written immediately; a Promise<
;;;; Response> is written from its .then continuation (drained after the reactor, P17
;;;; loop change). Keep-alive, chunked in / content-length out, 431/413 limits, HEAD,
;;;; Date header, 503 shedding, graceful stop.

(in-package :clun.runtime)

(defparameter *serve-max-connections* 10000
  "Above this many concurrent connections, new ones get a 503 + close (shedding).")

(defun %http-date ()
  (multiple-value-bind (s mi h d mo y dow) (decode-universal-time (get-universal-time) 0)
    (format nil "~a, ~2,'0d ~a ~d ~2,'0d:~2,'0d:~2,'0d GMT"
            (nth dow '("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun"))
            d (nth (1- mo) '("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))
            y h mi s)))

(defun %strip-crlf (s)
  "Remove CR/LF from a header name/value — prevents response splitting (§6)."
  (if (find-if (lambda (c) (or (char= c #\Return) (char= c #\Newline))) s)
      (remove-if (lambda (c) (or (char= c #\Return) (char= c #\Newline))) s)
      s))

(defun %ascii-octets (string)
  (let ((v (make-array (length string) :element-type '(unsigned-byte 8))))
    (dotimes (i (length string) v) (setf (aref v i) (logand (char-code (char string i)) #xff)))))

;;; --- response serialization -------------------------------------------------

(defun %response-like-p (v)
  (and (eng:js-object-p v) (eng:js-number-p (eng:js-get v "status"))
       (eng:js-object-p (eng:js-get v "headers"))))

(defun %serialize-response (resp method keep-alive)
  "A Response JS object → the full HTTP/1.1 response octet vector. HEAD omits the body.
Date/Content-Length/Connection are set by us (user copies of those are dropped)."
  (multiple-value-bind (body default-ct) (%response-body-octets resp)
    (let* ((status (truncate (eng:to-number (eng:js-get resp "status"))))
           (stext (let ((s (eng:js-get resp "statusText")))
                    (if (and (eng:js-string-p s) (plusp (length (eng:to-string s)))) (eng:to-string s)
                        (%status-text status))))
           (user (remove-if (lambda (p) (member (car p) '("content-length" "connection" "date") :test #'string=))
                            (%headers-alist (eng:js-get resp "headers"))))
           (has-ct (assoc "content-type" user :test #'string=))
           (head (make-string-output-stream)))
      (format head "HTTP/1.1 ~d ~a~c~c" status (%strip-crlf stext) #\Return #\Newline)
      (format head "Date: ~a~c~c" (%http-date) #\Return #\Newline)
      ;; strip CR/LF from names + values so a handler can't inject headers / split the
      ;; response (§6 security) — WHATWG forbids them in header values.
      (dolist (p user) (format head "~a: ~a~c~c" (%strip-crlf (%header-title-case (car p)))
                               (%strip-crlf (cdr p)) #\Return #\Newline))
      (when (and default-ct (not has-ct))
        (format head "Content-Type: ~a~c~c" default-ct #\Return #\Newline))
      (format head "Content-Length: ~d~c~c" (length body) #\Return #\Newline)
      (format head "Connection: ~a~c~c" (if keep-alive "keep-alive" "close") #\Return #\Newline)
      (format head "~c~c" #\Return #\Newline)
      (let* ((hbytes (%ascii-octets (get-output-stream-string head)))
             (send-body (and (not (string= method "HEAD")) (plusp (length body))))
             (out (make-array (+ (length hbytes) (if send-body (length body) 0))
                              :element-type '(unsigned-byte 8))))
        (replace out hbytes)
        (when send-body (replace out body :start1 (length hbytes)))
        out))))

(defun %header-title-case (name)
  "lower-case-header → Title-Case (cosmetic; HTTP header names are case-insensitive)."
  (let ((s (copy-seq name)) (up t))
    (dotimes (i (length s) s)
      (let ((c (char s i)))
        (cond ((char= c #\-) (setf up t))
              (up (setf (char s i) (char-upcase c) up nil)))))))

(defun %write-simple (conn status reason keep-alive)
  "Write a canned bodyless (well, tiny) response (used for parser 431/413/400 + 503)."
  (let* ((body (%ascii-octets reason))
         (s (format nil "HTTP/1.1 ~d ~a~c~cDate: ~a~c~cContent-Type: text/plain~c~cContent-Length: ~d~c~cConnection: ~a~c~c~c~c"
                    status reason #\Return #\Newline (%http-date) #\Return #\Newline #\Return #\Newline
                    (length body) #\Return #\Newline (if keep-alive "keep-alive" "close") #\Return #\Newline
                    #\Return #\Newline)))
    (net:tcp-write conn (concatenate '(vector (unsigned-byte 8)) (%ascii-octets s) body))))

;;; --- per-request dispatch ---------------------------------------------------

(defun %promise-then (promise on-ok on-err)
  (let ((then (eng:js-get promise "then")))
    (if (eng:callable-p then)
        (eng:js-call then promise
          (list (eng:make-native-function "" 1 (lambda (th a) (declare (ignore th)) (funcall on-ok (eng:arg a 0)) eng:+undefined+))
                (eng:make-native-function "" 1 (lambda (th a) (declare (ignore th)) (funcall on-err (eng:arg a 0)) eng:+undefined+))))
        (funcall on-ok promise))))

(defun %respond (conn resp method keep-alive)
  (cond
    ((%response-like-p resp)
     (net:tcp-write conn (%serialize-response resp method keep-alive))
     (unless keep-alive (net:tcp-shutdown conn)))
    (t (%write-simple conn 500 "Internal Server Error" nil) (net:tcp-shutdown conn))))

(defun %respond-error (conn err err-handler method keep-alive)
  "Route a handler throw / rejection to the user `error` handler (if it returns a
Response) else a default 500."
  (let ((resp (and (eng:callable-p err-handler)
                   (ignore-errors
                    (let ((r (eng:js-call err-handler eng:+undefined+ (list err))))
                      (and (%response-like-p r) r))))))
    (declare (ignore method))
    (if resp
        (progn (net:tcp-write conn (%serialize-response resp "GET" keep-alive))
               (unless keep-alive (net:tcp-shutdown conn)))
        (progn (%write-simple conn 500 "Internal Server Error" nil) (net:tcp-shutdown conn)))))

(defun %dispatch (conn req fetch err-handler)
  (let* ((request (%make-request (net:hr-method req) (net:hr-target req)
                                 (net:hr-headers req) (net:hr-body req)))
         (keep-alive (net:hr-keep-alive req))
         (method (net:hr-method req)))
    (handler-case
        (let ((result (eng:js-call fetch eng:+undefined+ (list request))))
          (if (eng:js-promise-p result)
              (%promise-then result
                             (lambda (resp) (%respond conn resp method keep-alive))
                             (lambda (e) (%respond-error conn e err-handler method keep-alive)))
              (%respond conn result method keep-alive)))
      (eng:js-condition (c) (%respond-error conn (eng:js-condition-value c) err-handler method keep-alive))
      (error () (%write-simple conn 500 "Internal Server Error" nil) (net:tcp-shutdown conn)))))

;;; --- connection driver ------------------------------------------------------

(defun %serve-connection (conn fetch err-handler)
  (let ((parser (net:make-http-parser)))
    (setf (net:tcp-on-data conn)
          (lambda (c octets)
            (loop
              (multiple-value-bind (event data) (net:parser-feed parser octets)
                (setf octets (make-array 0 :element-type '(unsigned-byte 8)))   ; only the first feed carries bytes
                (case event
                  (:need-more (return))
                  (:request (%dispatch c data fetch err-handler)
                            (unless (eq (net:tcp-state c) :open) (return)))
                  (:error (%write-simple c (car data) (cdr data) nil)
                          (net:tcp-shutdown c) (return)))))))))

;;; --- Clun.serve -------------------------------------------------------------

(defun %clun-serve (g opts)
  (unless (eng:js-object-p opts) (eng:throw-type-error "Clun.serve requires an options object"))
  (let* ((fetch (eng:js-get opts "fetch"))
         (err-handler (eng:js-get opts "error"))
         (port (let ((p (eng:js-get opts "port"))) (if (eng:js-number-p p) (truncate (eng:to-number p)) 3000)))
         (host (let ((h (eng:js-get opts "hostname"))) (if (eng:js-string-p h) (eng:to-string h) "0.0.0.0")))
         (loop (eng:current-loop))
         (conns (list 0))                    ; box: live connection count
         (stopping (list nil)) (stop-resolve (list nil))
         (server (eng:new-object)))
    (unless (eng:callable-p fetch) (eng:throw-type-error "Clun.serve: `fetch` must be a function"))
    (let ((listener
            (net:tcp-listen loop host port :backlog 1024
              :on-connection
              (lambda (conn)
                (cond
                  ((or (car stopping) (>= (car conns) *serve-max-connections*))
                   (%write-simple conn 503 "Service Unavailable" nil) (net:tcp-shutdown conn))
                  (t
                   (incf (car conns))
                   (setf (net:tcp-on-close conn)
                         (lambda (c code) (declare (ignore c code))
                           (decf (car conns))
                           (when (and (car stopping) (zerop (car conns)) (car stop-resolve))
                             (funcall (car stop-resolve)))))
                   (setf (net:tcp-on-error conn) (lambda (c code) (declare (ignore c code)) nil))
                   (%serve-connection conn fetch err-handler)))))))
      (eng:data-prop server "port" (coerce (net:listener-port listener) 'double-float))
      (eng:data-prop server "hostname" host)
      (eng:data-prop server "url"
        (format nil "http://~a:~a/" (if (string= host "0.0.0.0") "localhost" host) (net:listener-port listener)))
      (eng:install-method server "stop" 1
        (lambda (this args) (declare (ignore this args))
          (setf (car stopping) t)
          (net:listener-close listener)
          (if (zerop (car conns))
              (%resolved-promise g eng:+undefined+)
              (eng:js-construct (eng:js-get g "Promise")
                (list (eng:make-native-function "" 2
                        (lambda (th a) (declare (ignore th))
                          (let ((res (eng:arg a 0)))
                            (setf (car stop-resolve)
                                  (lambda () (eng:js-call res eng:+undefined+ (list eng:+undefined+)))))
                          eng:+undefined+)))))))
      (eng:install-method server "ref" 0 (lambda (th a) (declare (ignore th a)) eng:+undefined+))
      (eng:install-method server "unref" 0 (lambda (th a) (declare (ignore th a)) eng:+undefined+))
      server)))
