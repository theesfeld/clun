;;;; clun-serve.lisp — Clun.serve (PLAN.md Phase 17, §3.6). Wires the Phase-16 socket
;;;; layer + the HTTP parser + the web classes + the user's JS `fetch` handler. Fully
;;;; async on the reactor: a synchronous Response is written immediately; a Promise<
;;;; Response> is written from its .then continuation (drained after the reactor, P17
;;;; loop change). Keep-alive, chunked in / content-length out, 431/413 limits, HEAD,
;;;; Date header, 503 shedding, graceful stop.

(in-package :clun.runtime)

(defparameter *serve-max-connections* 10000
  "Above this many concurrent connections, new ones get a 503 + close (shedding).")

(defstruct (serve-request-context
            (:constructor %make-serve-request-context))
  (committed-p nil)
  (connection-closed-p nil))

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

(defun %response-like-p (value)
  "Only the private Response runtime subtype is accepted by Clun.serve."
  (%response-object-p value))

(defun %automatic-cookie-fields (request)
  "Snapshot REQUEST's mutation-only CookieMap view without mutating its Response."
  (if (and (js-server-request-p request)
           (js-server-request-cookie-cache-initialized-p request))
      (clun.cookies:cookie-map-response-fields
       (js-cookie-map-state
        (js-server-request-cookie-cache request)))
      '()))

(defun %response-headers-for-wire (response request)
  "Validate and return manual fields followed by automatic cookie mutations."
  (let* ((headers (%require-headers (eng:js-get response "headers")))
         (manual
           (loop for (raw-name . raw-value) in (%headers-raw-alist headers)
                 for name = (%hdr-normalize raw-name)
                 for value = (%hdr-value raw-value)
                 unless (member name '("content-length" "connection" "date")
                                :test #'string=)
                   collect (cons name value)))
         (automatic
           (loop for value in (%automatic-cookie-fields request)
                 collect (cons "set-cookie" (%hdr-value value)))))
    (nconc manual automatic)))

(defun %serialize-response (resp method keep-alive &optional request)
  "A Response JS object → the full HTTP/1.1 response octet vector. HEAD omits the body.
Date/Content-Length/Connection are set by us (user copies of those are dropped)."
  (%require-response resp)
  (multiple-value-bind (body default-ct) (%response-body-octets resp)
    (let* ((status-value (eng:js-get resp "status"))
           (status (if (eng:js-number-p status-value)
                       (truncate (eng:to-number status-value))
                       (eng:throw-type-error "Invalid HTTP response status")))
           (stext (let ((s (eng:js-get resp "statusText")))
                    (if (and (eng:js-string-p s)
                             (plusp (length (eng:to-string s))))
                        (%byte-string s "Invalid HTTP status text")
                        (%status-text status))))
           (user (%response-headers-for-wire resp request))
           (has-ct (assoc "content-type" user :test #'string=))
           (head (make-string-output-stream)))
      (unless (<= 200 status 599)
        (eng:throw-type-error "Invalid HTTP response status"))
      (format head "HTTP/1.1 ~d ~a~c~c" status stext #\Return #\Newline)
      (format head "Date: ~a~c~c" (%http-date) #\Return #\Newline)
      (dolist (p user)
        (format head "~a: ~a~c~c" (%header-title-case (car p))
                (cdr p) #\Return #\Newline))
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

(defun %simple-response-octets (status reason keep-alive)
  "Build the canned parser/shedding response without writing partial state."
  (let* ((body (%ascii-octets reason))
         (s (format nil "HTTP/1.1 ~d ~a~c~cDate: ~a~c~cContent-Type: text/plain~c~cContent-Length: ~d~c~cConnection: ~a~c~c~c~c"
                    status reason #\Return #\Newline (%http-date) #\Return #\Newline #\Return #\Newline
                    (length body) #\Return #\Newline (if keep-alive "keep-alive" "close") #\Return #\Newline
                    #\Return #\Newline)))
    (concatenate '(vector (unsigned-byte 8)) (%ascii-octets s) body)))

(defun %write-simple (conn status reason keep-alive)
  "Write a canned response used before a JavaScript request context exists."
  (net:tcp-write conn (%simple-response-octets status reason keep-alive)))

;;; --- per-request dispatch ---------------------------------------------------

(defun %promise-then (promise on-ok on-err)
  (let ((then (eng:js-get promise "then")))
    (if (eng:callable-p then)
        (eng:js-call then promise
          (list (eng:make-native-function "" 1 (lambda (th a) (declare (ignore th)) (funcall on-ok (eng:arg a 0)) eng:+undefined+))
                (eng:make-native-function "" 1 (lambda (th a) (declare (ignore th)) (funcall on-err (eng:arg a 0)) eng:+undefined+))))
        (funcall on-ok promise))))

(defun %default-error-response ()
  (let ((init (eng:new-object)))
    (eng:data-prop init "status" 500d0)
    (%new-response "Internal Server Error" init)))

(defun %default-error-octets (method request)
  (handler-case
      (%serialize-response (%default-error-response) method nil request)
    (condition ()
      ;; Cookie/header core validation should make this unreachable. Keep the
      ;; connection fail-closed if an internal invariant is ever violated.
      (%simple-response-octets 500 "Internal Server Error" nil))))

(defun %dispatch (req fetch err-handler commit)
  "Run one request and call COMMIT exactly once with (octets keep-alive context).
COMMIT is connection-owned, so late Promise settlement cannot write after teardown."
  (let* ((context (%make-serve-request-context))
         (request (%make-server-request
                   (net:hr-method req) (net:hr-target req)
                   (net:hr-headers req) (net:hr-body req) context))
         (keep-alive (net:hr-keep-alive req))
         (method (net:hr-method req))
         (settled-p nil)
         (error-handler-started-p nil))
    (labels
        ((commit-default ()
           (unless settled-p
             (setf settled-p t
                   (serve-request-context-committed-p context) t)
             (funcall commit (%default-error-octets method request) nil context)))
         (commit-response (response)
           (unless settled-p
             (if (%response-like-p response)
                 (handler-case
                     (let ((octets (%serialize-response response method keep-alive
                                                        request)))
                       (setf settled-p t
                             (serve-request-context-committed-p context) t)
                       (funcall commit octets keep-alive context))
                   (condition () (commit-default)))
                 (route-error response))))
         (finish-error-handler (response)
           (if (%response-like-p response)
               (commit-response response)
               (commit-default)))
         (route-error (error-value)
           (unless (or settled-p error-handler-started-p)
             (setf error-handler-started-p t)
             (if (not (eng:callable-p err-handler))
                 (commit-default)
                 (handler-case
                     (let ((result
                             (eng:js-call err-handler eng:+undefined+
                                          (list error-value))))
                       (if (eng:js-promise-p result)
                           (%promise-then result #'finish-error-handler
                                          (lambda (ignored)
                                            (declare (ignore ignored))
                                            (commit-default)))
                           (finish-error-handler result)))
                   (condition () (commit-default)))))))
      (handler-case
          (let ((result (eng:js-call fetch eng:+undefined+ (list request))))
            (if (eng:js-promise-p result)
                (%promise-then result #'commit-response #'route-error)
                (commit-response result)))
        (eng:js-condition (condition)
          (route-error (eng:js-condition-value condition)))
        (condition () (route-error eng:+undefined+))))
    context))

;;; --- connection driver ------------------------------------------------------

(defun %serve-connection (conn fetch err-handler)
  (let ((parser (net:make-http-parser))
        (next-sequence 0)
        (next-commit 0)
        (ready (make-hash-table :test #'eql))
        (contexts '())
        (closed-p nil)
        (final-request-seen-p nil)
        (outer-close (net:tcp-on-close conn)))
    (labels
        ((register-context (context)
           (pushnew context contexts :test #'eq)
           context)
         (mark-contexts-closed ()
           (dolist (context contexts)
             (setf (serve-request-context-connection-closed-p context) t))
           (setf contexts '())
           (clrhash ready))
         (flush-ready ()
           (loop
             (multiple-value-bind (entry present-p) (gethash next-commit ready)
               (unless (and present-p (not closed-p)) (return))
               (remhash next-commit ready)
               (incf next-commit)
               (destructuring-bind (octets keep-alive context) entry
                 (setf contexts (delete context contexts :test #'eq))
                 (net:tcp-write conn octets)
                 (unless keep-alive
                   (setf closed-p t
                         (serve-request-context-connection-closed-p context) t)
                   (mark-contexts-closed)
                   (net:tcp-shutdown conn))))))
         (queue-response (sequence octets keep-alive context)
           (if closed-p
               (setf (serve-request-context-connection-closed-p context) t)
               (progn
                 (register-context context)
                 (setf (gethash sequence ready)
                       (list octets keep-alive context))
                 (flush-ready)))))
      (setf (net:tcp-on-close conn)
            (lambda (c code)
              (setf closed-p t)
              (mark-contexts-closed)
              (when outer-close (funcall outer-close c code))))
      (setf (net:tcp-on-data conn)
            (lambda (c octets)
              (declare (ignore c))
              (unless final-request-seen-p
                (loop
                  (multiple-value-bind (event data) (net:parser-feed parser octets)
                    (setf octets (make-array 0 :element-type '(unsigned-byte 8)))
                    (case event
                      (:need-more (return))
                      (:request
                       (unless (net:hr-keep-alive data)
                         ;; Latch before invoking the handler. A later read callback
                         ;; must never dispatch beyond the connection's final slot.
                         (setf final-request-seen-p t))
                       (let* ((sequence next-sequence)
                              (context
                                (progn
                                  (incf next-sequence)
                                  (%dispatch
                                   data fetch err-handler
                                   (lambda (bytes keep-alive request-context)
                                     (queue-response sequence bytes keep-alive
                                                     request-context))))))
                         (unless (serve-request-context-committed-p context)
                           (register-context context))
                         (when closed-p
                           (setf (serve-request-context-connection-closed-p
                                  context) t)))
                       ;; A request that asks to close owns the final pipeline slot.
                       (unless (net:hr-keep-alive data) (return)))
                      (:error
                       (setf final-request-seen-p t)
                       (let ((sequence next-sequence))
                         (incf next-sequence)
                         (queue-response
                          sequence
                          (%simple-response-octets (car data) (cdr data) nil)
                          nil (%make-serve-request-context)))
                       (return)))))))))))

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
