;;;; http-parser-tests.lisp — Phase 17 gate: the incremental HTTP/1.1 request parser,
;;;; incl. the malformed-request suite (§6: every bad shape → a classified :error, never
;;;; a crash) and incremental/pipelined feeds.

(in-package :clun-test)

(defun %req-bytes (&rest lines)
  "Join LINES with CRLF and terminate with a blank line (CRLFCRLF). A trailing NIL line
appends nothing extra; use %raw for full control."
  (sb-ext:string-to-octets
   (format nil "~{~a~c~c~}~c~c" (mapcan (lambda (l) (list l #\Return #\Newline)) lines)
           #\Return #\Newline)
   :external-format :latin-1))

(defun %raw (s) (sb-ext:string-to-octets s :external-format :latin-1))
(defun %raw-lines (&rest lines)
  "Encode LINES with an HTTP CRLF after every line. Include an empty final line
to terminate a chunk trailer section."
  (%raw
   (with-output-to-string (stream)
     (dolist (line lines)
       (format stream "~a~c~c" line #\Return #\Newline)))))
(defun %feed (bytes) (net:parser-feed (net:make-http-parser) bytes))
(defun %body-str (r) (sb-ext:octets-to-string (net:hr-body r) :external-format :latin-1))

(define-test net/parse-get
  (multiple-value-bind (ev r) (%feed (%req-bytes "GET /path?q=1 HTTP/1.1" "Host: example.com"))
    (is eq :request ev)
    (is string= "GET" (net:hr-method r))
    (is string= "/path?q=1" (net:hr-target r))
    (is eq :http/1.1 (net:hr-version r))
    (is string= "example.com" (cdr (assoc "host" (net:hr-headers r) :test #'string=)))
    (true (net:hr-keep-alive r))))                     ; HTTP/1.1 default keep-alive

(define-test net/parse-no-headers
  (multiple-value-bind (ev r) (%feed (%raw (format nil "GET / HTTP/1.1~c~c~c~c" #\Return #\Newline #\Return #\Newline)))
    (is eq :request ev) (is string= "/" (net:hr-target r))))

(define-test net/parse-content-length
  (multiple-value-bind (ev r)
      (%feed (%raw (format nil "POST /x HTTP/1.1~c~cContent-Length: 5~c~c~c~chello" #\Return #\Newline #\Return #\Newline #\Return #\Newline)))
    (is eq :request ev) (is string= "hello" (%body-str r))))

(define-test net/parse-chunked
  (multiple-value-bind (ev r)
      (%feed (concatenate '(vector (unsigned-byte 8))
                          (%req-bytes "POST /c HTTP/1.1"
                                      "Transfer-Encoding: chunked")
                          (%raw-lines "5" "hello" "6" " world" "0" "")))
    (is eq :request ev) (is string= "hello world" (%body-str r))))

(define-test net/chunked-one-byte-feeds-use-linear-bounded-state
  (let* ((count 512)
         (head (%req-bytes "POST /linear HTTP/1.1"
                           "Transfer-Encoding: chunked"))
         (encoded-body
           (%raw
            (with-output-to-string (stream)
              (dotimes (index count)
                (declare (ignore index))
                (format stream "1~c~ca~c~c" #\Return #\Newline
                        #\Return #\Newline))
              (format stream "0~c~c~c~c" #\Return #\Newline
                      #\Return #\Newline))))
         (wire (concatenate '(vector (unsigned-byte 8)) head encoded-body))
         (parser (net:make-http-parser :max-header 128 :max-body count
                                       :max-framing 4096))
         (max-retained 0)
         (max-decoded 0))
    (loop for index below (length wire)
          do (multiple-value-bind (event result)
                 (net:parser-feed parser (subseq wire index (1+ index)))
               (setf max-retained
                     (max max-retained
                          (fill-pointer (net::hp-buf parser)))
                     max-decoded
                     (max max-decoded
                          (fill-pointer (net::hp-chunk-body parser))))
               (if (= index (1- (length wire)))
                   (progn
                     (is eq :request event)
                     (is = count (length (net:hr-body result)))
                     (true (every (lambda (byte) (= byte (char-code #\a)))
                                  (net:hr-body result))))
                   (is eq :need-more event))))
    ;; The old restart-from-body-start decoder retained the whole encoded body.
    (true (<= max-retained (length head)))
    (is = count max-decoded)))

(define-test net/chunked-trailers-preserve-pipelined-leftover
  (let* ((parser (net:make-http-parser))
         (first
           (concatenate
            '(vector (unsigned-byte 8))
            (%req-bytes "POST /first HTTP/1.1" "Transfer-Encoding: chunked")
            (%raw-lines "3" "abc" "0" "X-Trailer: yes" "")
            (%req-bytes "GET /second HTTP/1.1"))))
    (multiple-value-bind (event request) (net:parser-feed parser first)
      (is eq :request event)
      (is string= "/first" (net:hr-target request))
      (is string= "abc" (%body-str request)))
    (multiple-value-bind (event request) (net:parser-feed parser (%raw ""))
      (is eq :request event)
      (is string= "/second" (net:hr-target request)))))

(define-test net/parse-connection-close
  (multiple-value-bind (ev r) (%feed (%req-bytes "GET / HTTP/1.1" "Connection: close"))
    (declare (ignore ev)) (false (net:hr-keep-alive r))))

(define-test net/parse-ordered-duplicate-headers
  (multiple-value-bind (ev r)
      (%feed (%req-bytes "GET / HTTP/1.1" "Cookie: a=1" "X-Trace: first"
                         "Cookie: b=2" "X-Trace: second"))
    (is eq :request ev)
    (is equal '("a=1" "b=2")
        (mapcar #'cdr (remove "cookie" (net:hr-headers r) :key #'car
                              :test-not #'string=)))
    (is string= "a=1; b=2" (net:%header (net:hr-headers r) "cookie"))
    (is string= "first, second" (net:%header (net:hr-headers r) "x-trace"))))

(define-test net/parse-duplicate-connection-close-dominates
  (multiple-value-bind (ev r)
      (%feed (%req-bytes "GET / HTTP/1.1" "Connection: keep-alive" "Connection: upgrade, close"))
    (is eq :request ev)
    (false (net:hr-keep-alive r))))

(define-test net/parse-http10-default-close
  (multiple-value-bind (ev r) (%feed (%req-bytes "GET / HTTP/1.0"))
    (declare (ignore ev)) (false (net:hr-keep-alive r))))

;;; --- malformed suite (each → a classified :error, no crash) -----------------

(define-test net/malformed-request-line
  (is eq :error (%feed (%req-bytes "GET"))))            ; too few tokens

(define-test net/malformed-bad-version
  (is eq :error (%feed (%req-bytes "GET / HTTP/9.9"))))

(define-test net/malformed-bad-content-length
  (multiple-value-bind (ev d) (%feed (%req-bytes "POST / HTTP/1.1" "Content-Length: abc"))
    (is eq :error ev) (is = 400 (car d))))

(define-test net/duplicate-content-length
  (multiple-value-bind (ev r)
      (%feed (%raw (format nil "POST / HTTP/1.1~c~cContent-Length: 4, 4~c~cContent-Length: 4~c~c~c~cbody"
                           #\Return #\Newline #\Return #\Newline #\Return #\Newline
                           #\Return #\Newline)))
    (is eq :request ev)
    (is string= "body" (%body-str r)))
  (multiple-value-bind (ev d)
      (%feed (%req-bytes "POST / HTTP/1.1" "Content-Length: 4" "Content-Length: 5"))
    (is eq :error ev)
    (is = 400 (car d))))

(define-test net/ambiguous-transfer-framing
  (dolist (headers '(("Transfer-Encoding: chunked" "Content-Length: 4")
                     ("Transfer-Encoding: chunked" "Transfer-Encoding: chunked")
                     ("Transfer-Encoding: gzip, chunked")
                     ("Transfer-Encoding: gzip")))
    (multiple-value-bind (ev d)
        (%feed (apply #'%req-bytes "POST / HTTP/1.1" headers))
      (is eq :error ev)
      (is = 400 (car d)))))

(define-test net/malformed-obs-fold
  (multiple-value-bind (ev d) (%feed (%raw (format nil "GET / HTTP/1.1~c~cX: a~c~c b~c~c~c~c" #\Return #\Newline #\Return #\Newline #\Return #\Newline #\Return #\Newline)))
    (is eq :error ev) (is = 400 (car d))))

(define-test net/malformed-header-no-colon
  (is eq :error (%feed (%req-bytes "GET / HTTP/1.1" "NoColonHere"))))

(define-test net/limit-headers-431
  (let ((p (net:make-http-parser)))
    (multiple-value-bind (ev d)
        (net:parser-feed p (%raw (format nil "GET / HTTP/1.1~c~cX: ~a" #\Return #\Newline (make-string 20000 :initial-element #\a))))
      (is eq :error ev) (is = 431 (car d)))))

(define-test net/limit-complete-header-section
  (let* ((wire (%req-bytes "GET / HTTP/1.1" "X-Pad: 123456"))
         (exact (length wire)))
    (is eq :request (net:parser-feed (net:make-http-parser :max-header exact) wire))
    (multiple-value-bind (ev d)
        (net:parser-feed (net:make-http-parser :max-header (1- exact)) wire)
      (is eq :error ev)
      (is = 431 (car d)))
    (let ((p (net:make-http-parser :max-header (1- exact))))
      (is eq :need-more (net:parser-feed p (subseq wire 0 (- exact 3))))
      (multiple-value-bind (ev d) (net:parser-feed p (subseq wire (- exact 3)))
        (is eq :error ev)
        (is = 431 (car d))))))

(define-test net/header-split-feed-linear-state
  (let* ((wire (%req-bytes "GET / HTTP/1.1" "X-Pad: 1234567890"))
         (parser (net:make-http-parser :max-header (length wire))))
    (loop for index below (1- (length wire))
          do (is eq :need-more
                 (net:parser-feed parser (subseq wire index (1+ index))))
             (true (>= (net::hp-header-scan-start parser)
                       (max 0 (- index 3))))
             (true (<= (array-total-size (net::hp-buf parser)) 4096)))
    (is eq :request
        (net:parser-feed parser (subseq wire (1- (length wire)))))))

(define-test net/header-oversize-feed-rejected-before-retention
  (let* ((limit 64)
         (parser (net:make-http-parser :max-header limit))
         (prefix (concatenate '(vector (unsigned-byte 8))
                              (%raw-lines "GET / HTTP/1.1")
                              (%raw "X: ")))
         (attack (make-array (* limit 1024) :element-type '(unsigned-byte 8)
                             :initial-element (char-code #\a))))
    (is eq :need-more (net:parser-feed parser prefix))
    (let ((before-length (fill-pointer (net::hp-buf parser)))
          (before-capacity (array-total-size (net::hp-buf parser))))
      (multiple-value-bind (event detail) (net:parser-feed parser attack)
        (is eq :error event)
        (is = 431 (car detail)))
      (is = before-length (fill-pointer (net::hp-buf parser)))
      (is = before-capacity (array-total-size (net::hp-buf parser))))))

(define-test net/chunk-size-feed-rejected-before-retention
  (let* ((limit 64)
         (parser (net:make-http-parser :max-header limit :max-body 128))
         (attack (make-array (* limit 1024) :element-type '(unsigned-byte 8)
                             :initial-element (char-code #\f))))
    (is eq :need-more
        (net:parser-feed
         parser
         (%req-bytes "POST / HTTP/1.1" "Transfer-Encoding: chunked")))
    (is eq :size (net::hp-chunk-state parser))
    (let ((before-length (fill-pointer (net::hp-buf parser)))
          (before-capacity (array-total-size (net::hp-buf parser))))
      (multiple-value-bind (event detail) (net:parser-feed parser attack)
        (is eq :error event)
        (is = 400 (car detail)))
      (is = before-length (fill-pointer (net::hp-buf parser)))
      (is = before-capacity (array-total-size (net::hp-buf parser))))))

(define-test net/chunk-size-same-feed-rejected-before-retention
  (let* ((limit 64)
         (parser (net:make-http-parser :max-header limit :max-body 128))
         (attack (make-array (* limit 1024) :element-type '(unsigned-byte 8)
                             :initial-element (char-code #\f)))
         (wire (concatenate '(vector (unsigned-byte 8))
                            (%req-bytes "POST / HTTP/1.1"
                                        "Transfer-Encoding: chunked")
                            attack))
         (before-capacity (array-total-size (net::hp-buf parser))))
    (multiple-value-bind (event detail) (net:parser-feed parser wire)
      (is eq :error event)
      (is = 400 (car detail)))
    (is = 0 (fill-pointer (net::hp-buf parser)))
    (is = before-capacity (array-total-size (net::hp-buf parser)))))

(define-test net/chunk-trailer-feed-rejected-before-retention
  (let* ((limit 64)
         (parser (net:make-http-parser :max-header limit :max-body 128))
         (attack (make-array (* limit 1024) :element-type '(unsigned-byte 8)
                             :initial-element (char-code #\x))))
    (is eq :need-more
        (net:parser-feed
         parser
         (concatenate '(vector (unsigned-byte 8))
                      (%req-bytes "POST / HTTP/1.1"
                                  "Transfer-Encoding: chunked")
                      (%raw-lines "0"))))
    (is eq :trailers (net::hp-chunk-state parser))
    (let ((before-length (fill-pointer (net::hp-buf parser)))
          (before-capacity (array-total-size (net::hp-buf parser))))
      (multiple-value-bind (event detail) (net:parser-feed parser attack)
        (is eq :error event)
        (is = 431 (car detail)))
      (is = before-length (fill-pointer (net::hp-buf parser)))
      (is = before-capacity (array-total-size (net::hp-buf parser))))))

(define-test net/chunk-trailer-same-feed-rejected-before-retention
  (let* ((limit 64)
         (parser (net:make-http-parser :max-header limit :max-body 128))
         (attack (make-array (* limit 1024) :element-type '(unsigned-byte 8)
                             :initial-element (char-code #\x)))
         (wire (concatenate '(vector (unsigned-byte 8))
                            (%req-bytes "POST / HTTP/1.1"
                                        "Transfer-Encoding: chunked")
                            (%raw-lines "0")
                            attack))
         (before-capacity (array-total-size (net::hp-buf parser))))
    (multiple-value-bind (event detail) (net:parser-feed parser wire)
      (is eq :error event)
      (is = 431 (car detail)))
    (is = 0 (fill-pointer (net::hp-buf parser)))
    (is = before-capacity (array-total-size (net::hp-buf parser)))))

(define-test net/chunk-framing-has-an-aggregate-budget
  (let ((parser (net:make-http-parser :max-header 128 :max-body 10
                                      :max-framing 12)))
    (multiple-value-bind (event detail)
        (net:parser-feed
         parser
         (concatenate '(vector (unsigned-byte 8))
                      (%req-bytes "POST / HTTP/1.1"
                                  "Transfer-Encoding: chunked")
                      (%raw-lines "1" "a" "1" "b" "0" "")))
      (is eq :error event)
      (is = 400 (car detail)))))

(define-test net/chunk-size-over-body-limit-is-bounded
  (let ((parser (net:make-http-parser :max-header 128 :max-body 10)))
    (multiple-value-bind (event detail)
        (net:parser-feed
         parser
         (concatenate '(vector (unsigned-byte 8))
                      (%req-bytes "POST / HTTP/1.1"
                                  "Transfer-Encoding: chunked")
                      (%raw-lines "ffffffffffffffffffffffffffffffff")))
      (is eq :error event)
      (is = 413 (car detail)))))

(define-test net/limit-body-413
  (let ((p (net:make-http-parser :max-body 10)))
    (multiple-value-bind (ev d) (net:parser-feed p (%req-bytes "POST / HTTP/1.1" "Content-Length: 100"))
      (is eq :error ev) (is = 413 (car d)))))

;;; --- incremental + pipelined ------------------------------------------------

(define-test net/incremental-feed
  (let ((p (net:make-http-parser)))
    (is eq :need-more (net:parser-feed p (%raw (format nil "GET /inc HTTP/1.1~c~cHo" #\Return #\Newline))))
    (multiple-value-bind (ev r) (net:parser-feed p (%raw (format nil "st: y~c~c~c~c" #\Return #\Newline #\Return #\Newline)))
      (is eq :request ev) (is string= "/inc" (net:hr-target r)))))

(define-test net/pipelined
  (let ((p (net:make-http-parser)))
    (multiple-value-bind (ev1 r1)
        (net:parser-feed p (%raw (format nil "GET /1 HTTP/1.1~c~c~c~cGET /2 HTTP/1.1~c~c~c~c"
                                         #\Return #\Newline #\Return #\Newline #\Return #\Newline #\Return #\Newline)))
      (is eq :request ev1) (is string= "/1" (net:hr-target r1))
      (multiple-value-bind (ev2 r2) (net:parser-feed p (%raw ""))
        (is eq :request ev2) (is string= "/2" (net:hr-target r2))))))

;;; --- response streaming ----------------------------------------------------

(defun %stream-response-events (parser wire &key one-byte-p)
  (let ((events '()))
    (if one-byte-p
        (loop for index below (length wire)
              do (setf events
                       (nconc events
                              (net:response-stream-feed
                               parser (subseq wire index (1+ index))))))
        (setf events (net:response-stream-feed parser wire)))
    events))

(defun %stream-data-string (events)
  (sb-ext:octets-to-string
   (apply #'concatenate '(vector (unsigned-byte 8))
          (or (loop for event in events
                    when (eq (car event) :data)
                      collect (cdr event))
              (list (make-array 0 :element-type '(unsigned-byte 8)))))
   :external-format :latin-1))

(define-test net/response-stream-content-length-emits-in-order
  (let* ((parser (net:make-http-response-stream-parser))
         (wire (%raw (format nil
                             "HTTP/1.1 200 OK~c~cContent-Length: 11~c~c~c~chello world"
                             #\Return #\Newline #\Return #\Newline
                             #\Return #\Newline)))
         (events (%stream-response-events parser wire)))
    (is equal '(:headers :data :complete) (mapcar #'car events))
    (is = 200 (net:hres-status (cdar events)))
    (is string= "hello world" (%stream-data-string events))
    (is = 0 (fill-pointer (net::hrs-buf parser)))))

(define-test net/response-stream-chunked-fragments-without-body-buffer
  (let* ((parser (net:make-http-response-stream-parser
                  :max-header 128 :max-body 32 :max-framing 64))
         (wire (concatenate
                '(vector (unsigned-byte 8))
                (%raw (format nil
                              "HTTP/1.1 200 OK~c~cTransfer-Encoding: chunked~c~c~c~c"
                              #\Return #\Newline #\Return #\Newline
                              #\Return #\Newline))
                (%raw-lines "5" "hello" "6" " world" "0" "X-End: yes" "")))
         (events (%stream-response-events parser wire :one-byte-p t)))
    (is eq :headers (caar events))
    (is eq :complete (car (car (last events))))
    (is string= "hello world" (%stream-data-string events))
    (true (> (count :data events :key #'car) 1))
    ;; Only framing bytes are retained; decoded body bytes are handed off.
    (is = 0 (fill-pointer (net::hrs-buf parser)))
    (is = 11 (net::hrs-body-bytes parser))))

(define-test net/response-stream-until-close-finishes-at-eof
  (let* ((parser (net:make-http-response-stream-parser))
         (head (%raw (format nil "HTTP/1.1 200 OK~c~cConnection: close~c~c~c~c"
                             #\Return #\Newline #\Return #\Newline
                             #\Return #\Newline)))
         (events (append (net:response-stream-feed parser head)
                         (net:response-stream-feed parser (%raw "abc"))
                         (net:response-stream-feed parser (%raw "def"))
                         (net:response-stream-finish parser))))
    (is equal '(:headers :data :data :complete) (mapcar #'car events))
    (is string= "abcdef" (%stream-data-string events))))

(define-test net/response-stream-head-completes-without-wire-body
  (let* ((parser (net:make-http-response-stream-parser :head-request-p t))
         (wire (%raw (format nil
                             "HTTP/1.1 200 OK~c~cContent-Length: 4096~c~c~c~c"
                             #\Return #\Newline #\Return #\Newline
                             #\Return #\Newline)))
         (events (net:response-stream-feed parser wire)))
    (is equal '(:headers :complete) (mapcar #'car events))
    (is = 200 (net:hres-status (cdar events)))
    (is = 0 (net::hrs-body-bytes parser))))

(define-test net/response-stream-skips-informational-response
  (let* ((parser (net:make-http-response-stream-parser))
         (wire (concatenate
                '(vector (unsigned-byte 8))
                (%raw (format nil "HTTP/1.1 103 Early Hints~c~cLink: </app.css>~c~c~c~c"
                              #\Return #\Newline #\Return #\Newline
                              #\Return #\Newline))
                (%raw (format nil "HTTP/1.1 200 OK~c~cContent-Length: 2~c~c~c~cok"
                              #\Return #\Newline #\Return #\Newline
                              #\Return #\Newline))))
         (events (net:response-stream-feed parser wire)))
    (is equal '(:headers :data :complete) (mapcar #'car events))
    (is = 200 (net:hres-status (cdar events)))
    (is string= "ok" (%stream-data-string events))))

(define-test net/response-stream-rejects-oversized-input-before-retaining-it
  (let* ((parser (net:make-http-response-stream-parser :max-header 64))
         (attack (make-array (* 1024 1024) :element-type '(unsigned-byte 8)
                             :initial-element (char-code #\a)))
         (initial-capacity (array-total-size (net::hrs-buf parser)))
         (events (net:response-stream-feed parser attack)))
    (is eq :error (caar events))
    (is = 431 (car (cdar events)))
    (is = 0 (fill-pointer (net::hrs-buf parser)))
    (is = initial-capacity (array-total-size (net::hrs-buf parser)))))

(define-test net/response-stream-incomplete-framing-fails-at-eof
  (let ((parser (net:make-http-response-stream-parser)))
    (net:response-stream-feed
     parser
     (%raw (format nil "HTTP/1.1 200 OK~c~cContent-Length: 4~c~c~c~cab"
                   #\Return #\Newline #\Return #\Newline
                   #\Return #\Newline)))
    (let ((events (net:response-stream-finish parser)))
      (is eq :error (caar events))
      (is = 400 (car (cdar events))))))

(define-test net/response-stream-reuse-requires-an-exact-persistent-message
  (let ((parser (net:make-http-response-stream-parser)))
    (net:response-stream-feed
     parser
     (%raw (format nil "HTTP/1.1 200 OK~c~cContent-Length: 3~c~c~c~cabc"
                   #\Return #\Newline #\Return #\Newline
                   #\Return #\Newline)))
    (true (net:response-stream-reusable-p parser)))
  (let ((parser (net:make-http-response-stream-parser)))
    (net:response-stream-feed
     parser
     (%raw (format nil "HTTP/1.1 200 OK~c~cContent-Length: 0~c~cConnection: close~c~c~c~c"
                   #\Return #\Newline #\Return #\Newline #\Return #\Newline
                   #\Return #\Newline)))
    (false (net:response-stream-reusable-p parser)))
  (let ((parser (net:make-http-response-stream-parser)))
    (net:response-stream-feed
     parser
     (%raw (format nil "HTTP/1.1 200 OK~c~c~c~cbody"
                   #\Return #\Newline #\Return #\Newline)))
    (net:response-stream-finish parser)
    (false (net:response-stream-reusable-p parser)))
  (let ((parser (net:make-http-response-stream-parser)))
    (net:response-stream-feed
     parser
     (%raw (format nil "HTTP/1.1 204 No Content~c~c~c~cunexpected"
                   #\Return #\Newline #\Return #\Newline)))
    (false (net:response-stream-reusable-p parser))))
