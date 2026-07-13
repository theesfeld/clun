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
      (%feed (%raw (format nil "POST /c HTTP/1.1~c~cTransfer-Encoding: chunked~c~c~c~c5~c~chello~c~c6~c~c world~c~c0~c~c~c~c"
                           #\Return #\Newline #\Return #\Newline #\Return #\Newline #\Return #\Newline #\Return #\Newline
                           #\Return #\Newline #\Return #\Newline #\Return #\Newline #\Return #\Newline #\Return #\Newline)))
    (is eq :request ev) (is string= "hello world" (%body-str r))))

(define-test net/parse-connection-close
  (multiple-value-bind (ev r) (%feed (%req-bytes "GET / HTTP/1.1" "Connection: close"))
    (declare (ignore ev)) (false (net:hr-keep-alive r))))

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
