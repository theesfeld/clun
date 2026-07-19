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
  (connection-closed-p nil)
  ;; Phase 51 M1: upgrade hijacks the TCP connection out of the HTTP driver.
  (upgraded-p nil)
  connection
  server
  websocket-handlers)

;;; --- Phase 51: ServerWebSocket session + topic hub --------------------------

(defstruct (ws-topic-hub
            (:constructor %make-ws-topic-hub)
            (:conc-name ws-topic-hub-))
  "In-memory Pub/Sub table: topic string → list of ws-session."
  (topics (make-hash-table :test #'equal)))

(defstruct (ws-session
            (:constructor %make-ws-session)
            (:conc-name ws-session-))
  "Per-connection WebSocket state after a successful server.upgrade."
  connection
  handlers
  hub
  js-ws
  (ready-state 1)                       ; 0 CONNECTING 1 OPEN 2 CLOSING 3 CLOSED
  (buffer (make-array 0 :element-type '(unsigned-byte 8)
                        :adjustable t :fill-pointer 0))
  (close-sent-p nil)
  (close-received-p nil)
  (data eng:+undefined+)
  (subscriptions (make-hash-table :test #'equal))
  (frag-opcode nil)
  (frag-rsv1 nil)
  (frag-buffer (make-array 0 :element-type '(unsigned-byte 8)
                             :adjustable t :fill-pointer 0))
  (deflate-negotiated-p nil))

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

(defstruct (stream-send-plan (:constructor %make-stream-send-plan))
  "Progressive Transfer-Encoding: chunked write plan for a ReadableStream body."
  head
  body-stream
  method
  keep-alive
  (active-p t)
  reader)

(defparameter +chunked-response-end+
  (%ascii-octets (format nil "0~c~c~c~c" #\Return #\Newline #\Return #\Newline))
  "Final zero-length chunk + trailer terminator for HTTP/1.1 chunked responses.")

(defun %chunked-response-frame (octets)
  "Frame one non-empty response body chunk using HTTP/1.1 chunked coding."
  (when (zerop (length octets))
    (return-from %chunked-response-frame
      (make-array 0 :element-type '(unsigned-byte 8))))
  (let* ((prefix (%ascii-octets
                  (format nil "~x~c~c" (length octets) #\Return #\Newline)))
         (suffix (%ascii-octets (format nil "~c~c" #\Return #\Newline)))
         (result (make-array (+ (length prefix) (length octets) (length suffix))
                             :element-type '(unsigned-byte 8))))
    (replace result prefix)
    (replace result octets :start1 (length prefix))
    (replace result suffix :start1 (+ (length prefix) (length octets)))
    result))

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

(defun %serialize-stream-response (resp method keep-alive request)
  "Build a progressive chunked write plan for a ReadableStream Response body."
  (multiple-value-bind (status status-text) (%response-status-and-text resp)
    (let* ((user (%response-headers-for-wire resp request))
           (user (remove-if (lambda (pair)
                              (member (car pair)
                                      '("content-length" "transfer-encoding"
                                        "connection" "date")
                                      :test #'string=))
                            user))
           (head (make-string-output-stream)))
      (format head "HTTP/1.1 ~d ~a~c~c" status status-text #\Return #\Newline)
      (format head "Date: ~a~c~c" (%http-date) #\Return #\Newline)
      (dolist (p user)
        (format head "~a: ~a~c~c" (%header-title-case (car p))
                (cdr p) #\Return #\Newline))
      (format head "Transfer-Encoding: chunked~c~c" #\Return #\Newline)
      (format head "Connection: ~a~c~c"
              (if keep-alive "keep-alive" "close") #\Return #\Newline)
      (format head "~c~c" #\Return #\Newline)
      (%make-stream-send-plan
       :head (%ascii-octets (get-output-stream-string head))
       :body-stream (js-response-body-stream resp)
       :method method
       :keep-alive keep-alive))))

(defun %serialize-response (resp method keep-alive &optional request static-p)
  "Freeze a Response into wire octets, a lazy file source, or a stream-send plan.
HEAD omits the body. Date/Content-Length/Connection/Transfer-Encoding are set by
us (user copies of those are dropped)."
  (%require-response resp)
  (when (js-clun-file-p (%response-body-value resp))
    (multiple-value-bind (status status-text) (%response-status-and-text resp)
      (return-from %serialize-response
        (%make-file-response-source
         :file (%response-body-value resp) :method method
         :keep-alive keep-alive :request request :status status
         :status-text status-text
         :headers (%response-headers-for-wire resp request)))))
  (when (%response-streaming-body-p resp)
    (return-from %serialize-response
      (%serialize-stream-response resp method keep-alive request)))
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

(defun %dispatch (req fetch err-handler routes commit
                  &key connection server websocket-handlers)
  "Run one request and call COMMIT exactly once with (payload keep-alive context).
COMMIT is connection-owned, so late Promise settlement cannot write after teardown.
When CONTEXT is upgraded to WebSocket, COMMIT is not invoked with HTTP payload."
  (let* ((context (%make-serve-request-context
                   :connection connection
                   :server server
                   :websocket-handlers websocket-handlers))
         (request (%make-server-request
                   (net:hr-method req) (%server-request-url req)
                   (net:hr-headers req) (net:hr-body req) context))
         (keep-alive (net:hr-keep-alive req))
         (method (net:hr-method req))
         (settled-p nil)
         (error-handler-started-p nil))
    (labels
        ((upgraded-p ()
           (serve-request-context-upgraded-p context))
         (commit-default ()
           (unless (or settled-p (upgraded-p))
             (setf settled-p t
                   (serve-request-context-committed-p context) t)
             (funcall commit (%default-error-octets method request) nil context)))
         (call-action (action &optional static-p)
           (cond
             ((upgraded-p)
              (setf settled-p t
                    (serve-request-context-committed-p context) t))
             ((%response-like-p action) (commit-response action static-p))
             ((js-clun-file-p action)
              (commit-response (%new-response action eng:+undefined+) static-p))
             ((eng:callable-p action)
              (let ((result
                      (eng:js-call action eng:+undefined+
                                   (list request (or server eng:+undefined+)))))
                (cond
                  ((upgraded-p)
                   (setf settled-p t
                         (serve-request-context-committed-p context) t))
                  ((eng:js-promise-p result)
                   (%promise-then result #'commit-response #'route-error))
                  (t (commit-response result)))))
             (t (commit-response (%not-found-response)))))
         (commit-response (response &optional static-p)
           (cond
             ((or settled-p (upgraded-p))
              (setf settled-p t
                    (serve-request-context-committed-p context) t))
             ((%response-like-p response)
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
                (condition () (commit-default))))
             ((or (eng:js-undefined-p response) (eng:js-null-p response))
              ;; Bun: upgrade success often returns undefined — do not 500.
              (when (upgraded-p)
                (setf settled-p t
                      (serve-request-context-committed-p context) t))
              (unless settled-p
                (route-error response)))
             (t (route-error response))))
         (finish-error-handler (response)
           (if (%response-like-p response)
               (commit-response response)
               (commit-default)))
         (route-error (error-value)
           (unless (or settled-p error-handler-started-p (upgraded-p))
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

(defun %serve-stream-get-reader (stream)
  (cond
    ((js-body-stream-p stream) (%body-stream-reader stream))
    ((js-readable-stream-p stream) (%make-default-reader stream))
    (t (eng:throw-type-error "Response body stream is not readable"))))

(defun %serve-stream-reader-read (reader)
  (cond
    ((js-body-reader-p reader) (%body-reader-read reader))
    ((js-readable-stream-reader-p reader) (%reader-read reader))
    (t (eng:throw-type-error "Invalid body stream reader"))))

(defun %send-stream-plan (connection plan complete)
  "Write PLAN headers, then pump ReadableStream body chunks as Transfer-Encoding: chunked."
  (let ((active-p t)
        (head-sent-p nil)
        (reader nil))
    (labels
        ((finish (success-p)
           (when active-p
             (setf active-p nil
                   (stream-send-plan-active-p plan) nil
                   (net:tcp-on-drain connection) nil)
             (funcall complete success-p)))
         (write-and-maybe-wait (octets continue)
           (cond
             ((not active-p) nil)
             ((eq (net:tcp-state connection) :closed) (finish nil) nil)
             (t
              (when (plusp (length octets))
                (net:tcp-write connection octets))
              (if (plusp (net:tcp-queued-bytes connection))
                  (progn
                    (setf (net:tcp-on-drain connection)
                          (lambda (c)
                            (declare (ignore c))
                            (when active-p (funcall continue))))
                    nil)
                  t))))
         (end-body ()
           (when (write-and-maybe-wait +chunked-response-end+ #'end-body)
             (finish t)))
         (pull ()
           (when active-p
             (handler-case
                 (cond
                   ((eq (net:tcp-state connection) :closed) (finish nil))
                   ((string= (stream-send-plan-method plan) "HEAD")
                    (finish t))
                   (t
                    (%promise-then
                     (%serve-stream-reader-read reader)
                     (lambda (result)
                       (when active-p
                         (handler-case
                             (if (eng:js-truthy (eng:js-get result "done"))
                                 (end-body)
                                 (let* ((chunk
                                          (%body->octets
                                           (eng:js-get result "value")))
                                        (framed (%chunked-response-frame chunk)))
                                   (if (write-and-maybe-wait framed #'pull)
                                       (pull)
                                       nil)))
                           (eng:js-condition () (finish nil))
                           (condition () (finish nil)))))
                     (lambda (ignored)
                       (declare (ignore ignored))
                       (finish nil)))))
               (eng:js-condition () (finish nil))
               (condition () (finish nil))))))
      (handler-case
          (progn
            (setf reader
                  (%serve-stream-get-reader (stream-send-plan-body-stream plan)))
            (setf (stream-send-plan-reader plan) reader)
            (when (write-and-maybe-wait (stream-send-plan-head plan)
                                        (lambda ()
                                          (unless head-sent-p
                                            (setf head-sent-p t)
                                            (pull))))
              (setf head-sent-p t)
              (pull)))
        (eng:js-condition () (finish nil))
        (condition () (finish nil))))))

(defun %serve-connection (conn fetch-cell err-handler-cell routes-cell
                          server websocket-cell
                          &key (max-body net:*max-body-bytes*)
                               (idle-timeout-sec 10)
                               event-loop)
  "Drive one accepted connection.

MAX-BODY is the parser payload budget (Bun maxRequestBodySize).
IDLE-TIMEOUT-SEC is Bun idleTimeout in seconds (0 disables; default 10; max 255).
Wire activity (read or write) re-arms the idle timer.
SERVER / WEBSOCKET-CELL enable Phase 51 M1 upgrade when handlers are configured."
  (let* ((event-loop (or event-loop (eng:current-loop)))
         (parser (net:make-http-parser :max-body max-body))
         (next-sequence 0)
         (next-commit 0)
         (ready (make-hash-table :test #'eql))
         (contexts '())
         (active-file-plan nil)
         (active-stream-plan nil)
         (closed-p nil)
         (final-request-seen-p nil)
         (upgraded-p nil)
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
           (when active-stream-plan
             (setf (stream-send-plan-active-p active-stream-plan) nil
                   active-stream-plan nil))
           (maphash
            (lambda (sequence entry)
              (declare (ignore sequence))
              (let ((payload (first entry)))
                (when (file-send-plan-p payload)
                  (%close-file-send-plan payload))
                (when (stream-send-plan-p payload)
                  (setf (stream-send-plan-active-p payload) nil))))
            ready)
           (dolist (context contexts)
             (setf (serve-request-context-connection-closed-p context) t))
           (setf contexts '())
           (clrhash ready))
         (finish-slot (keep-alive context success-p)
           (setf active-file-plan nil
                 active-stream-plan nil
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
         (busy-p ()
           (or active-file-plan active-stream-plan))
         (flush-ready ()
           (when upgraded-p (return-from flush-ready nil))
           (loop while (not (busy-p)) do
             (multiple-value-bind (entry present-p) (gethash next-commit ready)
               (unless (and present-p (not closed-p)) (return))
               (remhash next-commit ready)
               (destructuring-bind (payload keep-alive context) entry
                 (when (file-response-source-p payload)
                   (multiple-value-setq (payload keep-alive)
                     (materialize-file-source payload)))
                 (cond
                   ((file-send-plan-p payload)
                    (setf active-file-plan payload)
                    (arm-idle)
                    (%send-file-plan
                     conn payload
                     (lambda (success-p)
                       (finish-slot keep-alive context success-p))))
                   ((stream-send-plan-p payload)
                    (setf active-stream-plan payload)
                    (arm-idle)
                    (%send-stream-plan
                     conn payload
                     (lambda (success-p)
                       (finish-slot keep-alive context success-p))))
                   (t
                    (incf next-commit)
                    (setf contexts (delete context contexts :test #'eq))
                    (write-octets payload)
                    (unless keep-alive
                      (setf closed-p t
                            (serve-request-context-connection-closed-p context) t)
                      (mark-contexts-closed)
                      (net:tcp-shutdown conn))))))))
         (queue-response (sequence payload keep-alive context)
           (cond
             ((or closed-p upgraded-p
                  (serve-request-context-upgraded-p context))
              (when (file-send-plan-p payload)
                (%close-file-send-plan payload))
              (when (stream-send-plan-p payload)
                (setf (stream-send-plan-active-p payload) nil))
              (when (serve-request-context-upgraded-p context)
                (setf upgraded-p t
                      final-request-seen-p t)))
             (t
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
              (unless (or final-request-seen-p upgraded-p)
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
                                                     request-context))
                                   :connection conn
                                   :server server
                                   :websocket-handlers (car websocket-cell)))))
                         (when (serve-request-context-upgraded-p context)
                           (setf upgraded-p t
                                 final-request-seen-p t)
                           (return))
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
  "Fail closed for residual Phase 51 surfaces."
  (eng:throw-type-error (ws:websocket-not-implemented-message surface)))

(defun %compile-websocket-handlers (opts)
  "Compile Clun.serve `websocket` option into WS-HANDLER-OPTIONS, or NIL."
  (let ((value (eng:js-get opts "websocket")))
    (cond
      ((eng:js-undefined-p value) nil)
      ((not (eng:js-object-p value))
       (eng:throw-type-error "Clun.serve: `websocket` must be an object"))
      (t
       (flet ((opt-fn (name)
                (let ((fn (eng:js-get value name)))
                  (cond
                    ((eng:js-undefined-p fn) nil)
                    ((eng:callable-p fn) fn)
                    (t (eng:throw-type-error
                        (format nil "Clun.serve: websocket.~a must be a function"
                                name))))))
              (opt-int (name default)
                (let ((v (eng:js-get value name)))
                  (cond
                    ((eng:js-undefined-p v) default)
                    ((eng:js-number-p v)
                     (max 0 (truncate (eng:to-number v))))
                    (t default)))))
         (ws:make-ws-handler-options
          :open (opt-fn "open")
          :message (opt-fn "message")
          :close (opt-fn "close")
          :ping (opt-fn "ping")
          :pong (opt-fn "pong")
          :drain (opt-fn "drain")
          :max-payload-length
          (opt-int "maxPayloadLength" ws:+default-max-payload-bytes+)
          :backpressure-limit
          (opt-int "backpressureLimit" ws:+default-backpressure-limit+)
          :idle-timeout-seconds
          (opt-int "idleTimeout" 120)
          :send-pings
          (let ((v (eng:js-get value "sendPings")))
            (if (eng:js-undefined-p v) t (eng:js-truthy v)))
          :publish-to-self
          (let ((v (eng:js-get value "publishToSelf")))
            (if (eng:js-undefined-p v) nil (eng:js-truthy v)))
          :close-on-backpressure-limit
          (let ((v (eng:js-get value "closeOnBackpressureLimit")))
            (if (eng:js-undefined-p v) nil (eng:js-truthy v)))
          :permessage-deflate
          (let ((v (eng:js-get value "perMessageDeflate")))
            (cond
              ((eng:js-undefined-p v) nil)
              ((eng:js-object-p v) t)
              (t (eng:js-truthy v))))))))))

(defun %ws-payload-js (payload opcode)
  "Map a WebSocket payload to a JS string (text) or Array of byte numbers (binary)."
  (cond
    ((= opcode ws:+opcode-text+)
     (handler-case
         (sb-ext:octets-to-string payload :external-format :utf-8)
       (error ()
         (eng:throw-type-error "WebSocket text frame is not valid UTF-8"))))
    (t
     (eng:new-array
      (loop for b across payload collect (coerce b 'double-float))))))

(defun %ws-write-frame (session frame)
  (when (and session
             (not (eq (net:tcp-state (ws-session-connection session)) :closed))
             (< (ws-session-ready-state session) 3))
    (net:tcp-write (ws-session-connection session) (ws:encode-frame frame))))

(defun %ws-set-ready-state (session state)
  (setf (ws-session-ready-state session) state)
  (when (ws-session-js-ws session)
    (eng:data-prop (ws-session-js-ws session) "readyState"
                    (coerce state 'double-float))))

(defun %ws-hub-subscribe (hub session topic)
  (let* ((topic (eng:to-string topic))
         (table (ws-topic-hub-topics hub))
         (list (gethash topic table)))
    (unless (member session list :test #'eq)
      (setf (gethash topic table) (cons session list)))
    (setf (gethash topic (ws-session-subscriptions session)) t)
    t))

(defun %ws-hub-unsubscribe (hub session topic)
  (let* ((topic (eng:to-string topic))
         (table (ws-topic-hub-topics hub))
         (list (gethash topic table)))
    (when list
      (setf list (delete session list :test #'eq))
      (if list
          (setf (gethash topic table) list)
          (remhash topic table)))
    (remhash topic (ws-session-subscriptions session))
    t))

(defun %ws-hub-unsubscribe-all (hub session)
  (maphash (lambda (topic present)
             (declare (ignore present))
             (%ws-hub-unsubscribe hub session topic))
           (ws-session-subscriptions session))
  (clrhash (ws-session-subscriptions session)))

(defun %ws-hub-subscriber-count (hub topic)
  (length (gethash (eng:to-string topic) (ws-topic-hub-topics hub))))

(defun %ws-hub-publish (hub topic opcode payload &key (except nil) (compress nil))
  "Fan-out PAYLOAD to every subscriber of TOPIC. Returns delivered count."
  (let* ((topic (eng:to-string topic))
         (subs (copy-list (gethash topic (ws-topic-hub-topics hub))))
         (n 0)
         (wire-payload payload)
         (rsv1 nil))
    (when (and compress payload)
      (handler-case
          (let ((c (ws:compress-permessage-deflate payload)))
            (setf wire-payload c rsv1 t))
        (condition ()
          (setf wire-payload payload rsv1 nil))))
    (dolist (session subs)
      (unless (or (eq session except)
                  (>= (ws-session-ready-state session) 2))
        (let ((frame (ws:make-ws-frame
                      :fin t :rsv1 (and rsv1 (ws-session-deflate-negotiated-p session))
                      :opcode opcode :payload wire-payload)))
          (unless (and rsv1 (not (ws-session-deflate-negotiated-p session)))
            (%ws-write-frame session
                             (if (and rsv1 (ws-session-deflate-negotiated-p session))
                                 frame
                                 (ws:make-ws-frame :fin t :opcode opcode :payload payload)))
            (incf n)))))
    n))

(defun %ws-close-session (session code reason &key (send-close t))
  "Transition SESSION toward CLOSED, optionally emitting a close frame."
  (when (>= (ws-session-ready-state session) 3)
    (return-from %ws-close-session nil))
  (when (and send-close (not (ws-session-close-sent-p session))
             (< (ws-session-ready-state session) 3)
             (not (eq (net:tcp-state (ws-session-connection session)) :closed)))
    (handler-case
        (%ws-write-frame session (ws:make-close-frame code reason))
      (condition () nil))
    (setf (ws-session-close-sent-p session) t)
    (%ws-set-ready-state session 2))
  (when (or (ws-session-close-received-p session)
            (not send-close))
    (%ws-set-ready-state session 3)
    (when (ws-session-hub session)
      (%ws-hub-unsubscribe-all (ws-session-hub session) session))
    (let ((close-fn (ws:ws-handler-options-close (ws-session-handlers session)))
          (js (ws-session-js-ws session)))
      (when (and close-fn js)
        (handler-case
            (eng:js-call close-fn eng:+undefined+
                         (list js
                               (coerce code 'double-float)
                               (or reason "")))
          (condition () nil))))
    (ignore-errors (net:tcp-shutdown (ws-session-connection session))))
  t)

(defun %ws-deliver-message (session opcode payload rsv1)
  "Inflate (if needed) and invoke the message handler."
  (let ((handlers (ws-session-handlers session))
        (js (ws-session-js-ws session))
        (data payload))
    (when rsv1
      (unless (ws-session-deflate-negotiated-p session)
        (%ws-close-session session 1002 "unexpected RSV1")
        (return-from %ws-deliver-message nil))
      (handler-case
          (setf data
                (ws:inflate-permessage-deflate
                 payload
                 :max-bytes (ws:ws-handler-options-max-payload-length handlers)))
        (ws:websocket-protocol-error ()
          (%ws-close-session session 1002 "deflate error")
          (return-from %ws-deliver-message nil))))
    (let ((max (ws:ws-handler-options-max-payload-length handlers)))
      (when (> (length data) max)
        (%ws-close-session session 1009 "message too big")
        (return-from %ws-deliver-message nil)))
    (when (ws:ws-handler-options-message handlers)
      (handler-case
          (eng:js-call (ws:ws-handler-options-message handlers)
                       eng:+undefined+
                       (list js (%ws-payload-js data opcode)))
        (condition () nil)))
    t))

(defun %ws-handle-frame (session frame)
  (let ((opcode (ws:ws-frame-opcode frame))
        (payload (ws:ws-frame-payload frame))
        (handlers (ws-session-handlers session))
        (js (ws-session-js-ws session)))
    (cond
      ((= opcode ws:+opcode-ping+)
       (%ws-write-frame session (ws:make-pong-frame payload))
       (when (ws:ws-handler-options-ping handlers)
         (handler-case
             (eng:js-call (ws:ws-handler-options-ping handlers) eng:+undefined+
                          (list js (%ws-payload-js payload ws:+opcode-binary+)))
           (condition () nil))))
      ((= opcode ws:+opcode-pong+)
       (when (ws:ws-handler-options-pong handlers)
         (handler-case
             (eng:js-call (ws:ws-handler-options-pong handlers) eng:+undefined+
                          (list js (%ws-payload-js payload ws:+opcode-binary+)))
           (condition () nil))))
      ((= opcode ws:+opcode-close+)
       (setf (ws-session-close-received-p session) t)
       (multiple-value-bind (code reason)
           (handler-case (ws:parse-close-payload payload)
             (ws:websocket-protocol-error ()
               (values 1002 "protocol error")))
         (unless (ws-session-close-sent-p session)
           (%ws-write-frame session (ws:make-close-frame code reason))
           (setf (ws-session-close-sent-p session) t))
         (%ws-close-session session code reason :send-close nil)))
      ((or (= opcode ws:+opcode-text+)
           (= opcode ws:+opcode-binary+)
           (= opcode ws:+opcode-continuation+))
       (handler-case
           (let ((frag (or (ws-session-frag-opcode session)
                           (make-instance 'standard-object))))
             (declare (ignore frag))
             ;; Local fragment state lives on the session slots.
             (cond
               ((= opcode ws:+opcode-continuation+)
                (unless (ws-session-frag-opcode session)
                  (%ws-close-session session 1002 "unexpected continuation")
                  (return-from %ws-handle-frame nil))
                (when (ws:ws-frame-rsv1 frame)
                  (%ws-close-session session 1002 "RSV1 on continuation")
                  (return-from %ws-handle-frame nil))
                (let ((max (ws:ws-handler-options-max-payload-length handlers))
                      (buf (ws-session-frag-buffer session)))
                  (when (> (+ (length buf) (length payload)) max)
                    (%ws-close-session session 1009 "message too big")
                    (return-from %ws-handle-frame nil))
                  (loop for b across payload do (vector-push-extend b buf))
                  (when (ws:ws-frame-fin frame)
                    (let ((op (ws-session-frag-opcode session))
                          (r1 (ws-session-frag-rsv1 session))
                          (data (coerce (subseq buf 0)
                                        '(simple-array (unsigned-byte 8) (*)))))
                      (setf (ws-session-frag-opcode session) nil
                            (ws-session-frag-rsv1 session) nil
                            (fill-pointer buf) 0)
                      (%ws-deliver-message session op data r1)))))
               (t
                (when (ws-session-frag-opcode session)
                  (%ws-close-session session 1002 "nested data frame")
                  (return-from %ws-handle-frame nil))
                (when (and (ws:ws-frame-rsv1 frame)
                           (not (ws-session-deflate-negotiated-p session)))
                  (%ws-close-session session 1002 "unexpected RSV1")
                  (return-from %ws-handle-frame nil))
                (if (ws:ws-frame-fin frame)
                    (%ws-deliver-message session opcode payload
                                         (ws:ws-frame-rsv1 frame))
                    (let ((max (ws:ws-handler-options-max-payload-length handlers))
                          (buf (ws-session-frag-buffer session)))
                      (when (> (length payload) max)
                        (%ws-close-session session 1009 "message too big")
                        (return-from %ws-handle-frame nil))
                      (setf (ws-session-frag-opcode session) opcode
                            (ws-session-frag-rsv1 session) (ws:ws-frame-rsv1 frame)
                            (fill-pointer buf) 0)
                      (loop for b across payload do (vector-push-extend b buf)))))))
         (ws:websocket-protocol-error ()
           (%ws-close-session session 1002 "protocol error"))))
      (t
       (%ws-close-session session 1002 "unknown opcode")))))

(defun %ws-attach-frame-loop (session)
  "Replace the HTTP on-data driver with a WebSocket frame pump."
  (let ((conn (ws-session-connection session)))
    (setf (net:tcp-on-data conn)
          (lambda (c octets)
            (declare (ignore c))
            (block ws-data
              (when (>= (ws-session-ready-state session) 3)
                (return-from ws-data nil))
              (let ((buf (ws-session-buffer session))
                    (allow (ws-session-deflate-negotiated-p session)))
                (loop for b across octets do (vector-push-extend b buf))
                (loop
                  (multiple-value-bind (frame next)
                      (handler-case
                          (ws:decode-frame buf :start 0 :end (length buf)
                                           :allow-rsv1 allow)
                        (ws:websocket-protocol-error ()
                          (%ws-close-session session 1002 "protocol error")
                          (return-from ws-data nil)))
                    (unless frame (return))
                    (let* ((remaining (- (length buf) next))
                           (kept (if (plusp remaining)
                                     (subseq buf next)
                                     (make-array 0 :element-type '(unsigned-byte 8)))))
                      (setf (fill-pointer buf) 0)
                      (loop for b across kept do (vector-push-extend b buf)))
                    (%ws-handle-frame session frame)
                    (when (>= (ws-session-ready-state session) 3)
                      (return))))))))
    session))

(defun %ws-coerce-send-payload (value)
  "Return (values opcode payload-octets) for ws.send / sendText / sendBinary."
  (cond
    ((eng:js-string-p value)
     (values ws:+opcode-text+
             (sb-ext:string-to-octets (eng:to-string value)
                                      :external-format :utf-8)))
    ((eng:js-number-p value)
     (values ws:+opcode-text+
             (sb-ext:string-to-octets
              (princ-to-string (eng:to-number value))
              :external-format :utf-8)))
    ((typep value '(vector (unsigned-byte 8)))
     (values ws:+opcode-binary+
             (coerce value '(simple-array (unsigned-byte 8) (*)))))
    ((eng:js-object-p value)
     (let* ((len-v (eng:js-get value "length"))
            (len (if (eng:js-number-p len-v)
                     (max 0 (truncate (eng:to-number len-v)))
                     0))
            (out (make-array len :element-type '(unsigned-byte 8))))
       (dotimes (i len)
         (let ((b (eng:js-get value i)))
           (setf (aref out i)
                 (if (eng:js-number-p b)
                     (logand (truncate (eng:to-number b)) #xff)
                     0))))
       (values ws:+opcode-binary+ out)))
    (t
     (values ws:+opcode-text+
             (sb-ext:string-to-octets (eng:to-string value)
                                      :external-format :utf-8)))))

(defun %ws-send-payload (session opcode payload &key compress)
  (when (>= (ws-session-ready-state session) 2)
    (return-from %ws-send-payload -1))
  (let ((rsv1 nil)
        (wire payload))
    (when (and compress (ws-session-deflate-negotiated-p session))
      (handler-case
          (progn
            (setf wire (ws:compress-permessage-deflate payload)
                  rsv1 t))
        (condition ()
          (setf wire payload rsv1 nil))))
    (%ws-write-frame session
                     (ws:make-ws-frame :fin t :rsv1 rsv1
                                       :opcode opcode :payload wire))
    (length payload)))

(defun %make-server-websocket (session)
  "Build the JS ServerWebSocket brand for SESSION."
  (let ((ws-obj (eng:new-object))
        (hub (ws-session-hub session)))
    (setf (ws-session-js-ws session) ws-obj)
    (eng:data-prop ws-obj "readyState" 1d0)
    (eng:data-prop ws-obj "data" (ws-session-data session))
    (eng:data-prop ws-obj "binaryType" "nodebuffer")
    (eng:install-method ws-obj "send" 1
      (lambda (this args)
        (declare (ignore this))
        (block send
          (when (>= (ws-session-ready-state session) 2)
            (return-from send -1d0))
          (multiple-value-bind (opcode payload)
              (%ws-coerce-send-payload (eng:arg args 0))
            (let ((compress (eng:js-truthy (eng:arg args 1))))
              (coerce (%ws-send-payload session opcode payload
                                        :compress compress)
                      'double-float))))))
    (eng:install-method ws-obj "sendText" 1
      (lambda (this args)
        (declare (ignore this))
        (block send-text
          (when (>= (ws-session-ready-state session) 2)
            (return-from send-text -1d0))
          (let* ((text (eng:to-string (eng:arg args 0)))
                 (payload (sb-ext:string-to-octets text :external-format :utf-8)))
            (coerce (%ws-send-payload session ws:+opcode-text+ payload) 'double-float)))))
    (eng:install-method ws-obj "sendBinary" 1
      (lambda (this args)
        (declare (ignore this))
        (block send-binary
          (when (>= (ws-session-ready-state session) 2)
            (return-from send-binary -1d0))
          (multiple-value-bind (opcode payload)
              (%ws-coerce-send-payload (eng:arg args 0))
            (declare (ignore opcode))
            (coerce (%ws-send-payload session ws:+opcode-binary+ payload)
                    'double-float)))))
    (eng:install-method ws-obj "close" 2
      (lambda (this args)
        (declare (ignore this))
        (let* ((code-v (eng:arg args 0))
               (reason-v (eng:arg args 1))
               (code (if (eng:js-number-p code-v)
                         (truncate (eng:to-number code-v))
                         1000))
               (reason (if (eng:js-undefined-p reason-v)
                           ""
                           (eng:to-string reason-v))))
          (%ws-close-session session code reason)
          eng:+undefined+)))
    (eng:install-method ws-obj "ping" 1
      (lambda (this args)
        (declare (ignore this))
        (multiple-value-bind (opcode payload)
            (if (eng:js-undefined-p (eng:arg args 0))
                (values ws:+opcode-ping+
                        (make-array 0 :element-type '(unsigned-byte 8)))
                (%ws-coerce-send-payload (eng:arg args 0)))
          (declare (ignore opcode))
          (%ws-write-frame session (ws:make-ping-frame payload))
          eng:+undefined+)))
    (eng:install-method ws-obj "pong" 1
      (lambda (this args)
        (declare (ignore this))
        (multiple-value-bind (opcode payload)
            (if (eng:js-undefined-p (eng:arg args 0))
                (values ws:+opcode-pong+
                        (make-array 0 :element-type '(unsigned-byte 8)))
                (%ws-coerce-send-payload (eng:arg args 0)))
          (declare (ignore opcode))
          (%ws-write-frame session (ws:make-pong-frame payload))
          eng:+undefined+)))
    (eng:install-method ws-obj "subscribe" 1
      (lambda (this args)
        (declare (ignore this))
        (when hub
          (%ws-hub-subscribe hub session (eng:arg args 0)))
        eng:+undefined+))
    (eng:install-method ws-obj "unsubscribe" 1
      (lambda (this args)
        (declare (ignore this))
        (when hub
          (%ws-hub-unsubscribe hub session (eng:arg args 0)))
        eng:+undefined+))
    (eng:install-method ws-obj "isSubscribed" 1
      (lambda (this args)
        (declare (ignore this))
        (eng:js-boolean
         (and hub
              (gethash (eng:to-string (eng:arg args 0))
                       (ws-session-subscriptions session))))))
    (eng:install-method ws-obj "publish" 2
      (lambda (this args)
        (declare (ignore this))
        (if (null hub)
            0d0
            (multiple-value-bind (opcode payload)
                (%ws-coerce-send-payload (eng:arg args 1))
              (let* ((topic (eng:arg args 0))
                     (compress (eng:js-truthy (eng:arg args 2)))
                     (except
                       (unless (ws:ws-handler-options-publish-to-self
                                (ws-session-handlers session))
                         session)))
                (coerce
                 (%ws-hub-publish hub topic opcode payload
                                  :except except :compress compress)
                 'double-float))))))
    (eng:install-getter ws-obj "subscriptions"
      (lambda (this args)
        (declare (ignore this args))
        (eng:new-array
         (loop for topic being the hash-keys of (ws-session-subscriptions session)
               collect topic))))
    ws-obj))

(defun %try-server-upgrade (server request hub &optional options)
  "Attempt HTTP→WebSocket upgrade. Returns T on success, NIL on refusal."
  (unless (js-server-request-p request)
    (return-from %try-server-upgrade nil))
  (let* ((context (js-server-request-context request))
         (handlers (and context (serve-request-context-websocket-handlers context)))
         (conn (and context (serve-request-context-connection context)))
         (headers (js-request-headers-alist request))
         (hub (if (typep hub 'ws-topic-hub)
                  hub
                  (let ((from-server (serve-request-context-server context)))
                    (cond
                      ((typep from-server 'ws-topic-hub) from-server)
                      ((eq from-server server) hub)
                      (t hub))))))
    (declare (ignore server))
    (unless (and context conn handlers
                 (not (serve-request-context-upgraded-p context))
                 (not (serve-request-context-committed-p context))
                 (ws:websocket-upgrade-request-p headers))
      (return-from %try-server-upgrade nil))
    (let* ((key (string-trim
                 '(#\Space #\Tab)
                 (or (cdr (assoc "sec-websocket-key" headers :test #'string-equal))
                     "")))
           (protocol
             (let ((p (and options (not (eng:js-undefined-p options))
                           (eng:js-object-p options)
                           (eng:js-get options "headers"))))
               (when (and p (eng:js-object-p p))
                 (let ((v (eng:js-get p "Sec-WebSocket-Protocol")))
                   (unless (eng:js-undefined-p v) (eng:to-string v))))))
           (data
             (if (and options (eng:js-object-p options)
                      (not (eng:js-undefined-p (eng:js-get options "data"))))
                 (eng:js-get options "data")
                 eng:+undefined+))
           (want-deflate
             (and (ws:ws-handler-options-permessage-deflate handlers)
                  (ws:client-offers-permessage-deflate-p headers)))
           (extensions (when want-deflate "permessage-deflate"))
           (response (ws:opening-handshake-response key
                                                    :protocol protocol
                                                    :extensions extensions))
           (session (%make-ws-session
                     :connection conn
                     :handlers handlers
                     :hub (and (typep hub 'ws-topic-hub) hub)
                     :data data
                     :deflate-negotiated-p (and want-deflate t))))
      (setf (serve-request-context-upgraded-p context) t
            (serve-request-context-committed-p context) t)
      (net:tcp-write conn response)
      (%make-server-websocket session)
      (%ws-attach-frame-loop session)
      (let ((open (ws:ws-handler-options-open handlers)))
        (when open
          (handler-case
              (eng:js-call open eng:+undefined+ (list (ws-session-js-ws session)))
            (condition () nil))))
      t)))

(defun %install-websocket-methods (server websocket-cell hub-cell)
  "Install Bun-shaped upgrade/publish/subscriberCount on SERVER."
  (eng:install-method server "upgrade" 2
    (lambda (this args)
      (declare (ignore this))
      (unless (car websocket-cell)
        (%throw-websocket-not-implemented "server.upgrade"))
      (let ((req (eng:arg args 0))
            (opts (eng:arg args 1)))
        (eng:js-boolean
         (%try-server-upgrade server req (car hub-cell) opts)))))
  (eng:install-method server "publish" 3
    (lambda (this args)
      (declare (ignore this))
      (let ((hub (car hub-cell)))
        (if (null hub)
            0d0
            (multiple-value-bind (opcode payload)
                (%ws-coerce-send-payload (eng:arg args 1))
              (coerce
               (%ws-hub-publish hub (eng:arg args 0) opcode payload
                                :compress (eng:js-truthy (eng:arg args 2)))
               'double-float))))))
  (eng:install-method server "subscriberCount" 1
    (lambda (this args)
      (declare (ignore this))
      (let ((hub (car hub-cell)))
        (coerce
         (if hub
             (%ws-hub-subscriber-count hub (eng:arg args 0))
             0)
         'double-float))))
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
  (let* ((fetch (%serve-callable-option opts "fetch"))
         (err-handler (%serve-callable-option opts "error"))
         (routes (%compile-serve-route-table
                  (eng:js-get opts "routes") (eng:js-get opts "static")))
         (websocket (%compile-websocket-handlers opts)))
    (unless (or fetch (and routes (plusp (route-table-count routes))))
      (eng:throw-type-error
       "Clun.serve requires a fetch function or at least one active route"))
    (values fetch err-handler routes websocket)))
(defun %clun-serve (g opts)
  (multiple-value-bind (fetch err-handler routes websocket)
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
           (websocket-cell (list websocket))
           (hub-cell (list (%make-ws-topic-hub)))
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
                      server websocket-cell
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
            (multiple-value-bind (new-fetch new-error new-routes new-ws)
                (%compile-serve-dispatch-options (eng:arg args 0))
              (setf (car fetch-cell) new-fetch
                    (car err-handler-cell) new-error
                    (car routes-cell) new-routes
                    (car websocket-cell) new-ws))
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
        (%install-websocket-methods server websocket-cell hub-cell)
        server))))