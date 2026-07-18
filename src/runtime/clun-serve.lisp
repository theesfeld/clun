;;;; clun-serve.lisp — Clun.serve (PLAN.md Phase 17, §3.6; Phase 49 lifecycle slice).
;;;; Wires the Phase-16 socket layer + the HTTP parser + the web classes + the user's
;;;; JS `fetch` handler. Fully async on the reactor: a synchronous Response is written
;;;; immediately; a Promise<Response> is written from its .then continuation (drained
;;;; after the reactor, P17 loop change). Keep-alive, chunked in / content-length out,
;;;; 431/413 limits, HEAD, Date header, 503 shedding, idleTimeout, maxRequestBodySize,
;;;; graceful stop, and force stop(true).

(in-package :clun.runtime)

(defparameter *serve-max-connections* 10000
  "Above this many concurrent connections, new ones get a 503 + close (shedding).")

(defstruct (serve-request-context
            (:constructor %make-serve-request-context))
  (committed-p nil)
  (connection-closed-p nil))

(defun %http-date-at (universal-time)
  (multiple-value-bind (s mi h d mo y dow) (decode-universal-time universal-time 0)
    (format nil "~a, ~2,'0d ~a ~d ~2,'0d:~2,'0d:~2,'0d GMT"
            (nth dow '("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun"))
            d (nth (1- mo) '("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))
            y h mi s)))

(defun %http-date () (%http-date-at (get-universal-time)))

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

(defun %request-header-value (request name)
  "Return the ordered, comma-joined request field value for NAME, or NIL."
  (when (js-request-p request)
    (let ((values
            (loop for (field-name . value) in (js-request-headers-alist request)
                  when (string-equal field-name name)
                    collect value)))
      (when values (format nil "~{~a~^, ~}" values)))))

(defun %buffer-etag (body)
  "Return a deterministic strong ETag for a buffered response representation."
  (format nil "\"sha256-~a\""
          (ironclad:byte-array-to-hex-string
           (ironclad:digest-sequence :sha256 body))))

(defun %etag-opaque-value (tag)
  "Normalize optional weak syntax for GET/HEAD If-None-Match comparison."
  (let ((tag (%ascii-ows-trim tag)))
    (if (and (>= (length tag) 2)
             (char-equal (char tag 0) #\W)
             (char= (char tag 1) #\/))
        (%ascii-ows-trim (subseq tag 2))
        tag)))

(defun %if-none-match-p (field-value etag)
  "Perform the RFC weak comparison used by If-None-Match for GET and HEAD."
  (when field-value
    (loop with expected = (%etag-opaque-value etag)
          with start = 0
          for comma = (position #\, field-value :start start)
          for candidate = (%ascii-ows-trim
                           (subseq field-value start comma))
          thereis (or (string= candidate "*")
                      (string= (%etag-opaque-value candidate) expected))
          while comma
          do (setf start (1+ comma)))))

(defun %if-none-match-wildcard-p (field-value)
  (and field-value
       (loop with start = 0
             for comma = (position #\, field-value :start start)
             thereis (string= "*" (%ascii-ows-trim
                                    (subseq field-value start comma)))
             while comma
             do (setf start (1+ comma)))))

(define-condition file-response-unavailable (error)
  ((path :initarg :path :reader file-response-unavailable-path)
   (code :initarg :code :reader file-response-unavailable-code)))

(defstruct (file-send-plan (:constructor %make-file-send-plan))
  head
  stream
  (remaining 0 :type (integer 0 *))
  (buffer (make-array 65536 :element-type '(unsigned-byte 8))))

(defstruct (file-response-source (:constructor %make-file-response-source))
  file
  method
  keep-alive
  request
  status
  status-text
  headers)

(defun %close-file-send-plan (plan)
  (when (file-send-plan-stream plan)
    (ignore-errors (close (file-send-plan-stream plan)))
    (setf (file-send-plan-stream plan) nil))
  plan)

(defun %response-status-and-text (response)
  (let* ((status-value (eng:js-get response "status"))
         (status (if (eng:js-number-p status-value)
                     (truncate (eng:to-number status-value))
                     (eng:throw-type-error "Invalid HTTP response status")))
         (text-value (eng:js-get response "statusText"))
         (text (if (and (eng:js-string-p text-value)
                        (plusp (length (eng:to-string text-value))))
                   (%byte-string text-value "Invalid HTTP status text")
                   (%status-text status))))
    (unless (<= 200 status 599)
      (eng:throw-type-error "Invalid HTTP response status"))
    (values status text)))

(defun %file-content-type (path)
  (let* ((raw (string-downcase (or (clun.sys:path-extension path) "")))
         (extension (if (and (plusp (length raw)) (char= (char raw 0) #\.))
                        (subseq raw 1)
                        raw)))
    (cond
      ((member extension '("txt" "text") :test #'string=)
       "text/plain;charset=utf-8")
      ((member extension '("html" "htm") :test #'string=)
       "text/html;charset=utf-8")
      ((string= extension "css") "text/css;charset=utf-8")
      ((member extension '("js" "mjs" "cjs") :test #'string=)
       "text/javascript;charset=utf-8")
      ((string= extension "json") "application/json;charset=utf-8")
      ((string= extension "svg") "image/svg+xml")
      ((string= extension "png") "image/png")
      ((member extension '("jpg" "jpeg") :test #'string=) "image/jpeg")
      ((string= extension "gif") "image/gif")
      ((string= extension "webp") "image/webp")
      ((string= extension "wasm") "application/wasm")
      ((string= extension "pdf") "application/pdf")
      (t "application/octet-stream"))))

(defun %decimal-integer (string)
  (and (plusp (length string))
       (every #'digit-char-p string)
       (ignore-errors (parse-integer string))))

(defun %parse-byte-range (value size)
  "Parse one HTTP bytes range. Return KIND, START, END; malformed or multi ranges are ignored."
  (let* ((value (and value (%ascii-ows-trim value)))
         (equals (and value (position #\= value))))
    (unless (and equals
                 (string-equal "bytes" (%ascii-ows-trim (subseq value 0 equals))))
      (return-from %parse-byte-range (values :ignore nil nil)))
    (let* ((spec (%ascii-ows-trim (subseq value (1+ equals))))
           (dash (position #\- spec)))
      (when (or (find #\, spec) (null dash))
        (return-from %parse-byte-range (values :ignore nil nil)))
      (let* ((first (%ascii-ows-trim (subseq spec 0 dash)))
             (last (%ascii-ows-trim (subseq spec (1+ dash))))
             (start (%decimal-integer first))
             (end (%decimal-integer last)))
        (cond
          ((and (null start) (null end)) (values :ignore nil nil))
          ((null start)
           (cond ((or (zerop end) (zerop size))
                  (values :unsatisfiable nil nil))
                 (t (values :range (max 0 (- size end)) (1- size)))))
          ((>= start size) (values :unsatisfiable nil nil))
          ((and end (< end start)) (values :ignore nil nil))
          (t (values :range start (min (or end (1- size)) (1- size)))))))))

(defun %month-number (name)
  (let ((position (position name
                            '("Jan" "Feb" "Mar" "Apr" "May" "Jun"
                              "Jul" "Aug" "Sep" "Oct" "Nov" "Dec")
                            :test #'string-equal)))
    (and position (1+ position))))

(defun %parse-http-date (value)
  "Parse IMF-fixdate and the ISO-8601 form commonly emitted by Date.toISOString()."
  (handler-case
      (cond
        ((and (= (length value) 29)
              (char= (char value 3) #\,)
              (string-equal "GMT" value :start2 26))
         (let ((month (%month-number (subseq value 8 11))))
           (and month
                (encode-universal-time
                 (parse-integer value :start 23 :end 25)
                 (parse-integer value :start 20 :end 22)
                 (parse-integer value :start 17 :end 19)
                 (parse-integer value :start 5 :end 7)
                 month (parse-integer value :start 12 :end 16) 0))))
        ((and (>= (length value) 20)
              (char= (char value 4) #\-)
              (char= (char value 7) #\-)
              (member (char value 10) '(#\T #\Space) :test #'char=)
              (char= (char value 13) #\:)
              (char= (char value 16) #\:))
         (encode-universal-time
          (parse-integer value :start 17 :end 19)
          (parse-integer value :start 14 :end 16)
          (parse-integer value :start 11 :end 13)
          (parse-integer value :start 8 :end 10)
          (parse-integer value :start 5 :end 7)
          (parse-integer value :start 0 :end 4) 0))
        (t nil))
    (error () nil)))

(defun %open-file-response (path)
  (handler-case
      (clun.sys:open-regular-file-stream path :no-follow t)
    (clun.sys:fs-error (error)
      (if (member (clun.sys:fs-error-code error)
                  '("ENOENT" "EACCES" "EISDIR" "ELOOP") :test #'string=)
          (error 'file-response-unavailable
                 :path path :code (clun.sys:fs-error-code error))
          (error error)))))

(defun %file-response-available-p (file)
  "Validate a static file route without retaining a descriptor in the response queue."
  (multiple-value-bind (stream stat)
      (%open-file-response (js-clun-file-path file))
    (declare (ignore stat))
    (close stream)
    t))

(defun %serialize-file-response (source)
  "Prepare a bounded descriptor-backed response without reading the file eagerly."
  (let* ((file (file-response-source-file source))
         (method (file-response-source-method source))
         (keep-alive (file-response-source-keep-alive source))
         (request (file-response-source-request source))
         (original-status (file-response-source-status source))
         (original-text (file-response-source-status-text source))
         (user (file-response-source-headers source))
         (path (js-clun-file-path file))
         (stream nil))
    (multiple-value-bind (opened stat) (%open-file-response path)
      (setf stream opened)
      (handler-case
          (let* ((total-size (clun.sys:fstat-size stat))
                   (view-start (min total-size (js-clun-file-start file)))
                   (view-end (min total-size
                                  (or (js-clun-file-end file) total-size)))
                   (size (max 0 (- view-end view-start)))
                   (etag-field (assoc "etag" user :test #'string=))
                   (last-modified-field
                     (assoc "last-modified" user :test #'string=))
                   (last-modified
                     (if last-modified-field
                         (cdr last-modified-field)
                         (%http-date-at
                          (+ 2208988800
                             (floor (clun.sys:fstat-mtime-ns stat) 1000000000)))))
                   (if-none-match (%request-header-value request "if-none-match"))
                   (if-modified-since
                     (%request-header-value request "if-modified-since"))
                   (conditional-method-p
                     (member method '("GET" "HEAD") :test #'string=))
                   (not-modified-p
                     (and (= original-status 200) conditional-method-p
                          (if if-none-match
                              (or (%if-none-match-wildcard-p if-none-match)
                                  (and etag-field
                                       (%if-none-match-p if-none-match
                                                         (cdr etag-field))))
                              (let ((since (%parse-http-date
                                            (or if-modified-since "")))
                                    (modified (%parse-http-date last-modified)))
                                (and since modified (<= modified since))))))
                   (content-range-field
                     (assoc "content-range" user :test #'string=))
                   (range-value
                     (and (= original-status 200) conditional-method-p
                          (not not-modified-p) (null content-range-field)
                          (not (js-clun-file-sliced-p file))
                          (%request-header-value request "range")))
                   (range-kind :ignore)
                   (range-start 0)
                   (range-end (max 0 (1- size)))
                   (wire-status (if not-modified-p 304 original-status))
                   (wire-text (if not-modified-p (%status-text 304) original-text)))
              (when range-value
                (multiple-value-setq (range-kind range-start range-end)
                  (%parse-byte-range range-value size))
                (case range-kind
                  (:range (setf wire-status 206 wire-text (%status-text 206)))
                  (:unsatisfiable
                   (setf wire-status 416 wire-text (%status-text 416)))))
              (let* ((send-length
                       (cond (not-modified-p nil)
                             ((eq range-kind :unsatisfiable) 0)
                             ((eq range-kind :range)
                              (1+ (- range-end range-start)))
                             (t size)))
                     (has-content-type
                       (assoc "content-type" user :test #'string=))
                     (has-accept-ranges
                       (assoc "accept-ranges" user :test #'string=))
                     (head (make-string-output-stream)))
                (format head "HTTP/1.1 ~d ~a~c~c" wire-status wire-text
                        #\Return #\Newline)
                (format head "Date: ~a~c~c" (%http-date) #\Return #\Newline)
                (dolist (field user)
                  (format head "~a: ~a~c~c" (%header-title-case (car field))
                          (cdr field) #\Return #\Newline))
                (unless last-modified-field
                  (format head "Last-Modified: ~a~c~c" last-modified
                          #\Return #\Newline))
                (when (and (not not-modified-p) (not has-content-type))
                  (format head "Content-Type: ~a~c~c" (%file-content-type path)
                          #\Return #\Newline))
                (when (and (member range-kind '(:range :unsatisfiable))
                           (not has-accept-ranges))
                  (format head "Accept-Ranges: bytes~c~c" #\Return #\Newline))
                (case range-kind
                  (:range
                   (format head "Content-Range: bytes ~d-~d/~d~c~c"
                           range-start range-end size #\Return #\Newline))
                  (:unsatisfiable
                   (format head "Content-Range: bytes */~d~c~c"
                           size #\Return #\Newline)))
                (when send-length
                  (format head "Content-Length: ~d~c~c" send-length
                          #\Return #\Newline))
                (format head "Connection: ~a~c~c~c~c"
                        (if keep-alive "keep-alive" "close")
                        #\Return #\Newline #\Return #\Newline)
                (let ((head-octets
                        (%ascii-octets (get-output-stream-string head))))
                  (cond
                    ((or not-modified-p
                         (string= method "HEAD")
                         (zerop (or send-length 0)))
                     (close stream)
                     (setf stream nil)
                     head-octets)
                    (t
                     (file-position stream
                                    (+ view-start
                                       (if (eq range-kind :range)
                                           range-start
                                           0)))
                     (%make-file-send-plan
                      :head head-octets :stream stream
                      :remaining send-length))))))
        (condition (error)
          (when stream (ignore-errors (close stream)))
          (error error))))))

(defun %serialize-response (resp method keep-alive &optional request static-p)
  "Freeze a Response into wire octets or a lazy file source. HEAD omits the body.
Date/Content-Length/Connection are set by us (user copies of those are dropped)."
  (%require-response resp)
  (when (js-clun-file-p (%response-body-value resp))
    (multiple-value-bind (status status-text) (%response-status-and-text resp)
      (return-from %serialize-response
        (%make-file-response-source
         :file (%response-body-value resp) :method method
         :keep-alive keep-alive :request request :status status
         :status-text status-text
         :headers (%response-headers-for-wire resp request)))))
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
           (etag-field (assoc "etag" user :test #'string=))
           (etag (and static-p (= status 200)
                      (not (js-clun-file-p (%response-body-value resp)))
                      (if etag-field (cdr etag-field) (%buffer-etag body))))
           (not-modified-p
             (and etag
                  (member method '("GET" "HEAD") :test #'string=)
                  (%if-none-match-p
                   (%request-header-value request "if-none-match") etag)))
           (wire-status (if not-modified-p 304 status))
           (wire-stext (if not-modified-p (%status-text 304) stext))
           (has-ct (assoc "content-type" user :test #'string=))
           (head (make-string-output-stream)))
      (unless (<= 200 status 599)
        (eng:throw-type-error "Invalid HTTP response status"))
      (format head "HTTP/1.1 ~d ~a~c~c" wire-status wire-stext #\Return #\Newline)
      (format head "Date: ~a~c~c" (%http-date) #\Return #\Newline)
      (dolist (p user)
        (format head "~a: ~a~c~c" (%header-title-case (car p))
                (cdr p) #\Return #\Newline))
      (when (and etag (not etag-field))
        (format head "ETag: ~a~c~c" etag #\Return #\Newline))
      (when (and (not not-modified-p) default-ct (not has-ct))
        (format head "Content-Type: ~a~c~c" default-ct #\Return #\Newline))
      (unless not-modified-p
        (format head "Content-Length: ~d~c~c" (length body) #\Return #\Newline))
      (format head "Connection: ~a~c~c" (if keep-alive "keep-alive" "close") #\Return #\Newline)
      (format head "~c~c" #\Return #\Newline)
      (let* ((hbytes (%ascii-octets (get-output-stream-string head)))
             (send-body (and (not not-modified-p)
                             (not (string= method "HEAD"))
                             (plusp (length body))))
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

(defun %not-found-response ()
  (let ((init (eng:new-object)))
    (eng:data-prop init "status" 404d0)
    (%new-response "Not Found" init)))

(defun %request-target-query (target)
  (let ((query (position #\? target))
        (fragment (position #\# target)))
    (if query
        (subseq target query (or (and fragment (> fragment query) fragment)
                                 (length target)))
        "")))

(defun %server-request-url (request)
  "Derive the public Request URL from Host, never absolute-form authority.

The listener is HTTP-only at this layer. Route matching retains the raw target,
while the JavaScript Request receives an absolute URL as required by the web API."
  (let* ((headers (net:hr-headers request))
         (host (or (cdr (assoc "host" headers :test #'string-equal))
                   "localhost"))
         (target (net:hr-target request)))
    (concatenate 'string "http://" host
                 (%request-target-path target)
                 (%request-target-query target))))

(defun %default-error-octets (method request)
  (handler-case
      (%serialize-response (%default-error-response) method nil request)
    (condition ()
      ;; Cookie/header core validation should make this unreachable. Keep the
      ;; connection fail-closed if an internal invariant is ever violated.
      (%simple-response-octets 500 "Internal Server Error" nil))))

(defun %dispatch (req fetch err-handler routes commit)
  "Run one request and call COMMIT exactly once with (payload keep-alive context).
COMMIT is connection-owned, so late Promise settlement cannot write after teardown."
  (let* ((context (%make-serve-request-context))
         (request (%make-server-request
                   (net:hr-method req) (%server-request-url req)
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
         (call-action (action &optional static-p)
           (cond
             ((%response-like-p action) (commit-response action static-p))
             ((js-clun-file-p action)
              (commit-response (%new-response action eng:+undefined+) static-p))
             ((eng:callable-p action)
              (let ((result
                      (eng:js-call action eng:+undefined+ (list request))))
                (if (eng:js-promise-p result)
                    (%promise-then result #'commit-response #'route-error)
                    (commit-response result))))
             (t (commit-response (%not-found-response)))))
         (commit-response (response &optional static-p)
           (unless settled-p
             (if (%response-like-p response)
                 (handler-case
                     (let ((file (%response-body-value response)))
                       (when (and static-p (js-clun-file-p file))
                         (%file-response-available-p file))
                       (let ((payload
                               (%serialize-response response method keep-alive
                                                    request static-p)))
                       (setf settled-p t
                             (serve-request-context-committed-p context) t)
                         (funcall commit payload keep-alive context)))
                   (file-response-unavailable ()
                     (if (and static-p fetch)
                         (call-action fetch)
                         (commit-response (%not-found-response))))
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
          (multiple-value-bind (route-action params)
              (%match-route-table routes (net:hr-target req) method)
            (when route-action
              (%install-request-route-params request params))
            (call-action (or route-action fetch) (and route-action t)))
        (eng:js-condition (condition)
          (route-error (eng:js-condition-value condition)))
        (condition () (route-error eng:+undefined+))))
    context))

;;; --- connection driver ------------------------------------------------------

(defun %send-file-plan (connection plan complete)
  "Write PLAN a chunk at a time and resume only after socket backpressure drains."
  (let ((active-p t))
    (labels
        ((finish (success-p)
           (when active-p
             (setf active-p nil
                   (net:tcp-on-drain connection) nil)
             (%close-file-send-plan plan)
             (funcall complete success-p)))
         (pump (&optional ignored)
           (declare (ignore ignored))
           (when active-p
             (handler-case
                 (cond
                   ((eq (net:tcp-state connection) :closed) (finish nil))
                   ((plusp (net:tcp-queued-bytes connection))
                    (setf (net:tcp-on-drain connection) #'pump))
                   (t
                    (loop while active-p do
                      (when (zerop (file-send-plan-remaining plan))
                        (finish t)
                        (return))
                      (let* ((buffer (file-send-plan-buffer plan))
                             (wanted (min (length buffer)
                                          (file-send-plan-remaining plan)))
                             (read (read-sequence buffer
                                                  (file-send-plan-stream plan)
                                                  :end wanted)))
                        (when (zerop read)
                          ;; The opened file was truncated after fstat. Headers are
                          ;; already committed, so close instead of corrupting framing.
                          (finish nil)
                          (return))
                        (decf (file-send-plan-remaining plan) read)
                        (net:tcp-write
                         connection
                         (if (= read (length buffer)) buffer (subseq buffer 0 read)))
                        (when (plusp (net:tcp-queued-bytes connection))
                          (setf (net:tcp-on-drain connection) #'pump)
                          (return))))))
               (condition () (finish nil))))))
      (net:tcp-write connection (file-send-plan-head plan))
      (pump))))

(defun %serve-connection (conn fetch-cell err-handler-cell routes-cell
                          &key (max-body net:*max-body-bytes*)
                               (idle-timeout-sec 10)
                               event-loop)
  "Drive one accepted connection.

MAX-BODY is the parser payload budget (Bun maxRequestBodySize).
IDLE-TIMEOUT-SEC is Bun idleTimeout in seconds (0 disables; default 10; max 255).
Wire activity (read or write) re-arms the idle timer."
  (let* ((event-loop (or event-loop (eng:current-loop)))
         (parser (net:make-http-parser :max-body max-body))
         (next-sequence 0)
         (next-commit 0)
         (ready (make-hash-table :test #'eql))
         (contexts '())
         (active-file-plan nil)
         (closed-p nil)
         (final-request-seen-p nil)
         (idle-timer nil)
         (outer-close (net:tcp-on-close conn)))
    (labels
        ((clear-idle ()
           (when idle-timer
             (lp:clear-timer idle-timer)
             (setf idle-timer nil)))
         (arm-idle ()
           (clear-idle)
           (when (and (not closed-p)
                      idle-timeout-sec
                      (plusp idle-timeout-sec))
             (setf idle-timer
                   (lp:set-timer
                    event-loop
                    (* idle-timeout-sec 1000)
                    (lambda ()
                      (unless closed-p
                        (setf closed-p t)
                        (mark-contexts-closed)
                        (net:tcp-close conn)))))))
         (write-octets (octets)
           (unless closed-p
             (net:tcp-write conn octets)
             (arm-idle)))
         (register-context (context)
           (pushnew context contexts :test #'eq)
           context)
         (mark-contexts-closed ()
           (clear-idle)
           (when active-file-plan
             (%close-file-send-plan active-file-plan)
             (setf active-file-plan nil))
           (maphash
            (lambda (sequence entry)
              (declare (ignore sequence))
              (let ((payload (first entry)))
                (when (file-send-plan-p payload)
                  (%close-file-send-plan payload))))
            ready)
           (dolist (context contexts)
             (setf (serve-request-context-connection-closed-p context) t))
           (setf contexts '())
           (clrhash ready))
         (finish-slot (keep-alive context success-p)
           (setf active-file-plan nil
                 contexts (delete context contexts :test #'eq))
           (cond
             ((or closed-p (not success-p))
              (setf closed-p t
                    (serve-request-context-connection-closed-p context) t)
              (mark-contexts-closed)
              (net:tcp-close conn))
             (t
              (incf next-commit)
              (if keep-alive
                  (progn
                    (arm-idle)
                    (flush-ready))
                  (progn
                    (setf closed-p t
                          (serve-request-context-connection-closed-p context) t)
                    (mark-contexts-closed)
                    (net:tcp-shutdown conn))))))
         (materialize-file-source (source)
           (handler-case
               (values (%serialize-file-response source)
                       (file-response-source-keep-alive source))
             (file-response-unavailable ()
               (values
                (%serialize-response
                 (%not-found-response) (file-response-source-method source)
                 (file-response-source-keep-alive source)
                 (file-response-source-request source))
                (file-response-source-keep-alive source)))
             (condition ()
               (values
                (%default-error-octets
                 (file-response-source-method source)
                 (file-response-source-request source))
                nil))))
         (flush-ready ()
           (loop while (null active-file-plan) do
             (multiple-value-bind (entry present-p) (gethash next-commit ready)
               (unless (and present-p (not closed-p)) (return))
               (remhash next-commit ready)
               (destructuring-bind (payload keep-alive context) entry
                 (when (file-response-source-p payload)
                   (multiple-value-setq (payload keep-alive)
                     (materialize-file-source payload)))
                 (if (file-send-plan-p payload)
                     (progn
                       (setf active-file-plan payload)
                       (arm-idle)
                       (%send-file-plan
                        conn payload
                        (lambda (success-p)
                          (finish-slot keep-alive context success-p))))
                     (progn
                       (incf next-commit)
                       (setf contexts (delete context contexts :test #'eq))
                       (write-octets payload)
                       (unless keep-alive
                         (setf closed-p t
                               (serve-request-context-connection-closed-p context) t)
                         (mark-contexts-closed)
                         (net:tcp-shutdown conn))))))))
         (queue-response (sequence payload keep-alive context)
           (if closed-p
               (progn
                 (when (file-send-plan-p payload)
                   (%close-file-send-plan payload))
                 (setf (serve-request-context-connection-closed-p context) t))
               (progn
                 (register-context context)
                 (setf (gethash sequence ready)
                       (list payload keep-alive context))
                 (flush-ready)))))
      (setf (net:tcp-on-close conn)
            (lambda (c code)
              (setf closed-p t)
              (mark-contexts-closed)
              (when outer-close (funcall outer-close c code))))
      (setf (net:tcp-on-data conn)
            (lambda (c octets)
              (declare (ignore c))
              (arm-idle)
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
                                   data (car fetch-cell) (car err-handler-cell)
                                   (car routes-cell)
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
                       (return))))))))
      (arm-idle))))

;;; --- Clun.serve -------------------------------------------------------------

(defun %serve-callable-option (opts name)
  (let ((value (eng:js-get opts name)))
    (cond
      ((eng:js-undefined-p value) nil)
      ((eng:callable-p value) value)
      (t (eng:throw-type-error
          (format nil "Clun.serve: `~a` must be a function" name))))))

(defun %throw-websocket-not-implemented (&optional (surface "WebSocket"))
  "Fail closed for Phase 51: clear TypeError, never a silent half-upgrade."
  (eng:throw-type-error (ws:websocket-not-implemented-message surface)))

(defun %reject-websocket-serve-option (opts)
  "Clun.serve rejects an explicit `websocket` option until Phase 51 M1+."
  (unless (eng:js-undefined-p (eng:js-get opts "websocket"))
    (%throw-websocket-not-implemented "Clun.serve({ websocket })")))

(defun %install-websocket-fail-closed-methods (server)
  "Expose Bun-shaped names that refuse WebSocket work with a clear error."
  (eng:install-method server "upgrade" 1
    (lambda (this args)
      (declare (ignore this args))
      (%throw-websocket-not-implemented "server.upgrade")))
  (eng:install-method server "publish" 2
    (lambda (this args)
      (declare (ignore this args))
      (%throw-websocket-not-implemented "server.publish")))
  (eng:install-method server "subscriberCount" 1
    (lambda (this args)
      (declare (ignore this args))
      (%throw-websocket-not-implemented "server.subscriberCount")))
  server)

(defun %serve-idle-timeout-option (opts)
  "Bun.serve idleTimeout in seconds: default 10, 0 disables, max 255."
  (let ((value (eng:js-get opts "idleTimeout")))
    (cond
      ((or (eng:js-undefined-p value) (eng:js-null-p value)) 10)
      ((eng:js-number-p value)
       (let* ((raw (eng:to-number value))
              (n (truncate raw)))
         (when (or (eng:js-nan-p raw) (eng:js-infinite-p raw) (/= raw n)
                   (minusp n) (> n 255))
           (eng:throw-range-error
            "Clun.serve: idleTimeout must be an integer between 0 and 255"))
         n))
      (t (eng:throw-type-error
          "Clun.serve: idleTimeout must be a number")))))

(defun %serve-max-request-body-size-option (opts)
  "Bun.serve maxRequestBodySize in bytes. Unset keeps the parser default."
  (let ((value (eng:js-get opts "maxRequestBodySize")))
    (cond
      ((or (eng:js-undefined-p value) (eng:js-null-p value))
       net:*max-body-bytes*)
      ((eng:js-number-p value)
       (let* ((raw (eng:to-number value))
              (n (truncate raw)))
         (when (or (eng:js-nan-p raw) (eng:js-infinite-p raw) (/= raw n)
                   (minusp n))
           (eng:throw-range-error
            "Clun.serve: maxRequestBodySize must be a non-negative integer"))
         n))
      (t (eng:throw-type-error
          "Clun.serve: maxRequestBodySize must be a number")))))

(defun %compile-serve-dispatch-options (opts)
  (unless (eng:js-object-p opts)
    (eng:throw-type-error "Clun.serve requires an options object"))
  (%reject-websocket-serve-option opts)
  (let* ((fetch (%serve-callable-option opts "fetch"))
         (err-handler (%serve-callable-option opts "error"))
         (routes (%compile-serve-route-table
                  (eng:js-get opts "routes") (eng:js-get opts "static"))))
    (unless (or fetch (and routes (plusp (route-table-count routes))))
      (eng:throw-type-error
       "Clun.serve requires a fetch function or at least one active route"))
    (values fetch err-handler routes)))
(defun %clun-serve (g opts)
  (multiple-value-bind (fetch err-handler routes)
      (%compile-serve-dispatch-options opts)
    (let* ((port (let ((p (eng:js-get opts "port")))
                   (if (eng:js-number-p p) (truncate (eng:to-number p)) 3000)))
           (host (let ((h (eng:js-get opts "hostname")))
                   (if (eng:js-string-p h) (eng:to-string h) "0.0.0.0")))
           (idle-timeout-sec (%serve-idle-timeout-option opts))
           (max-body (%serve-max-request-body-size-option opts))
           (loop (eng:current-loop))
           (conns (list 0))                  ; box: live connection count
           (active (list '()))               ; box: live tcp connection list
           (stopping (list nil)) (stop-resolve (list nil))
           (fetch-cell (list fetch))
           (err-handler-cell (list err-handler))
           (routes-cell (list routes))
           (server (eng:new-object)))
      (let ((listener
              (net:tcp-listen loop host port :backlog 1024
                :on-connection
                (lambda (conn)
                  (cond
                    ((or (car stopping) (>= (car conns) *serve-max-connections*))
                     (%write-simple conn 503 "Service Unavailable" nil)
                     (net:tcp-shutdown conn))
                    (t
                     (incf (car conns))
                     (push conn (car active))
                     (setf (net:tcp-on-close conn)
                           (lambda (c code) (declare (ignore c code))
                             (setf (car active)
                                   (delete conn (car active) :test #'eq))
                             (decf (car conns))
                             (when (and (car stopping) (zerop (car conns))
                                        (car stop-resolve))
                               (funcall (car stop-resolve)))))
                     (setf (net:tcp-on-error conn)
                           (lambda (c code) (declare (ignore c code)) nil))
                     (%serve-connection
                      conn fetch-cell err-handler-cell routes-cell
                      :max-body max-body
                      :idle-timeout-sec idle-timeout-sec
                      :event-loop loop)))))))
        (eng:data-prop server "port"
                       (coerce (net:listener-port listener) 'double-float))
        (eng:data-prop server "hostname" host)
        (eng:data-prop server "url"
          (format nil "http://~a:~a/"
                  (if (string= host "0.0.0.0") "localhost" host)
                  (net:listener-port listener)))
        (eng:data-prop server "idleTimeout"
                       (coerce idle-timeout-sec 'double-float))
        (eng:data-prop server "maxRequestBodySize"
                       (coerce max-body 'double-float))
        (eng:install-method server "fetch" 1
          (lambda (this args)
            (declare (ignore this))
            (let ((handler (car fetch-cell)))
              (if (null handler)
                  (%rejected-promise
                   g (eng:make-error-object
                      :type-error-prototype "TypeError"
                      "fetch() requires the server to have a fetch handler"))
                  (handler-case
                      (let* ((input (eng:arg args 0))
                             (request
                               (cond
                                 ((js-request-p input) input)
                                 ((eng:js-string-p input)
                                  (let* ((value (eng:to-string input))
                                         (base (eng:to-string
                                                (eng:js-get server "url")))
                                         (url
                                           (cond
                                             ((search "://" value) value)
                                             ((and (plusp (length value))
                                                   (char= (char value 0) #\/))
                                              (concatenate
                                               'string
                                               (subseq base 0 (1- (length base)))
                                               value))
                                             (t (concatenate 'string base value)))))
                                    (%make-client-request "GET" url '() #())))
                                 (t
                                  (eng:throw-type-error
                                   "server.fetch expects a Request or string")))))
                        (eng:js-call handler eng:+undefined+
                                     (list request server)))
                    (eng:js-condition (condition)
                      (%rejected-promise
                       g (eng:js-condition-value condition)))
                    (condition (condition)
                      (%rejected-promise
                       g (eng:make-error-object
                          :error-prototype "Error"
                          (princ-to-string condition)))))))))
        (eng:install-method server "reload" 1
          (lambda (this args)
            (declare (ignore this))
            (multiple-value-bind (new-fetch new-error new-routes)
                (%compile-serve-dispatch-options (eng:arg args 0))
              (setf (car fetch-cell) new-fetch
                    (car err-handler-cell) new-error
                    (car routes-cell) new-routes))
            server))
        (eng:install-method server "stop" 1
          (lambda (this args)
            (declare (ignore this))
            ;; Bun: stop(closeActiveConnections?: boolean) — truthy force closes
            ;; in-flight sockets immediately; graceful waits for them to drain.
            (let ((force (eng:js-truthy (eng:arg args 0))))
              (setf (car stopping) t)
              (net:listener-close listener)
              (cond
                ((zerop (car conns))
                 (%resolved-promise g eng:+undefined+))
                (t
                 (eng:js-construct
                  (eng:js-get g "Promise")
                  (list (eng:make-native-function
                         "" 2
                         (lambda (th a)
                           (declare (ignore th))
                           (let ((res (eng:arg a 0))
                                 (settled nil))
                             (labels ((resolve ()
                                        (unless settled
                                          (setf settled t)
                                          (eng:js-call res eng:+undefined+
                                                       (list eng:+undefined+)))))
                               (setf (car stop-resolve) #'resolve)
                               (when force
                                 (dolist (conn (copy-list (car active)))
                                   (ignore-errors (net:tcp-close conn))))
                               (when (zerop (car conns))
                                 (resolve)))
                             eng:+undefined+))))))))))
        (eng:install-method server "ref" 0
          (lambda (th a) (declare (ignore th a)) eng:+undefined+))
        (eng:install-method server "unref" 0
          (lambda (th a) (declare (ignore th a)) eng:+undefined+))
        (%install-websocket-fail-closed-methods server)
        server))))