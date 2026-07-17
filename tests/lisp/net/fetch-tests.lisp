;;;; fetch-tests.lisp — Phase 18 gate: fetch() vs the Phase-17 Clun.serve server, both
;;;; on ONE reactor loop. Covers the JSON round-trip, text, 4xx/5xx, a redirect chain,
;;;; gzip auto-decode (Content-Encoding: gzip → chipz), abort→AbortError, connection
;;;; refused → TypeError. The fetch client runs on a coroutine thread (the async body),
;;;; so this also exercises the reactor-thread marshalling (LP:RUN-ON-LOOP).

(in-package :clun-test)

;; "gzip-decoded-body" gzipped (gzip CLI) — the server serves these bytes with
;; Content-Encoding: gzip so fetch's client must gunzip them.
(defparameter *gz-blob*
  (make-array 37 :element-type '(unsigned-byte 8)
              :initial-contents '(31 139 8 0 0 0 0 0 0 3 75 175 202 44 208 77 73 77 206 79 73 77
                                  209 77 202 79 169 4 0 208 58 22 245 17 0 0 0)))

(defun %fetch-route (g request)
  "Route a request (a JS Request) by the pathname of its absolute URL."
  (let* ((url (eng:to-string (eng:js-get request "url")))
         (path (clun.runtime::%request-target-path url)))
    (cond
      ((string= path "/json")
       (eng:js-call (eng:js-get (eng:js-get g "Response") "json") (eng:js-get g "Response")
                    (list (let ((o (eng:new-object))) (eng:data-prop o "hi" "there") (eng:data-prop o "n" 42d0) o))))
      ((string= path "/text") (%resp g "plain text body"))
      ((string= path "/404") (%resp g "nope" (%init-status g 404)))
      ((string= path "/500") (%resp g "boom" (%init-status g 500)))
      ((string= path "/redir") (%resp g "" (%init-redirect g 302 "/json")))
      ((string= path "/redir2") (%resp g "" (%init-redirect g 302 "/redir")))    ; chain → /redir → /json
      ((string= path "/loop") (%resp g "" (%init-redirect g 302 "/loop")))       ; infinite redirect
      ((string= path "/r302")
       (%resp g (format nil "~a ct=~a" (eng:to-string (eng:js-get request "method"))
                        (let ((v (eng:js-call (eng:js-get (eng:js-get request "headers") "get")
                                              (eng:js-get request "headers") (list "content-type"))))
                          (if (eng:js-string-p v) (eng:to-string v) "none")))
              (%init-redirect g 302 "/echo")))
      ((string= path "/echo")
       (%resp g (format nil "~a ct=~a" (eng:to-string (eng:js-get request "method"))
                        (let ((v (eng:js-call (eng:js-get (eng:js-get request "headers") "get")
                                              (eng:js-get request "headers") (list "content-type"))))
                          (if (eng:js-string-p v) (eng:to-string v) "none")))))
      ((string= path "/gz")
       (%resp g (eng:u8-from-octets *gz-blob*)
              (let ((init (eng:new-object)) (h (eng:new-object)))
                (eng:data-prop h "content-encoding" "gzip")
                (eng:data-prop h "content-type" "text/plain")
                (eng:data-prop init "headers" h) init)))
      ((string= path "/set-cookies")
       (%resp g "cookies"
              (let ((init (eng:new-object))
                    (pairs (eng:new-array
                            (list (eng:new-array (list "set-cookie" "a=1"))
                                  (eng:new-array (list "set-cookie" "b=2"))))))
                (eng:data-prop init "headers" pairs)
                init)))
      (t (%resp g (format nil "echo ~a" path))))))

(defun %init-status (g status)
  (let ((init (eng:new-object))) (eng:data-prop init "status" (coerce status 'double-float)) init))
(defun %init-redirect (g status location)
  (let ((init (eng:new-object)) (h (eng:new-object)))
    (eng:data-prop init "status" (coerce status 'double-float))
    (eng:data-prop h "location" location) (eng:data-prop init "headers" h) init))

(defparameter +fetch-info-src+
  ;; a JS helper resolving to a plain object so the CL side can read fields without
  ;; chaining .then in Lisp; text()'s promise is awaited here.
  "globalThis.__fetchInfo = (url, opts) => fetch(url, opts).then(async r => ({
     status: r.status, statusText: r.statusText, ok: r.ok, url: r.url,
     ct: r.headers.get('content-type') || '',
     setCookies: JSON.stringify(r.headers.getSetCookie()),
     body: await r.text() }));")

(defmacro with-fetch-server ((g port) &body body)
  "Start Clun.serve (routing via %fetch-route) on 127.0.0.1:0; bind G + PORT and install
__fetchInfo; run BODY (which drives fetches via FETCH-INFO); tear the realm down."
  (let ((realm (gensym)) (loop (gensym)) (fetch (gensym)) (opts (gensym)) (server (gensym)))
    `(let ((,realm (eng:make-realm)))
       (rt:install-runtime ,realm :argv '(:script "[test]" :rest nil) :cwd "/tmp")
       (let ((eng:*realm* ,realm))
         (let* ((,g (eng:realm-global ,realm))
                (,loop (eng:current-loop))
                (,fetch (eng:make-native-function "fetch" 1
                          (lambda (this args) (declare (ignore this)) (%fetch-route ,g (eng:arg args 0)))))
                (,opts (eng:new-object)))
           (declare (ignore ,loop))
           (eng:data-prop ,opts "port" 0d0) (eng:data-prop ,opts "hostname" "127.0.0.1")
           (eng:data-prop ,opts "fetch" ,fetch)
           (let* ((,server (clun.runtime::%clun-serve ,g ,opts))
                  (,port (truncate (eng:js-get ,server "port"))))
             (declare (ignorable ,port))
             (eng:run-program (eng:parse-program +fetch-info-src+) ,realm)
             (unwind-protect (progn ,@body)
               (eng:teardown-realm ,realm))))))))

(defun fetch-info (g realm port path &optional opts-src)
  "fetch http://127.0.0.1:PORT/PATH and return the settled info object (or throw kind)."
  (let ((url (format nil "http://127.0.0.1:~d~a" port path)))
    (multiple-value-bind (kind value)
        (eng:run-callback-to-settlement
         (lambda ()
           (eng:js-call (eng:js-get g "__fetchInfo") eng:+undefined+
                        (list url (if opts-src (jseval realm opts-src) eng:+undefined+))))
         realm :timeout-ms 8000)
      (values kind value))))

(defun info-field (info key) (eng:js-get info key))
(defun info-str (info key) (eng:to-string (eng:js-get info key)))
(defun info-num (info key) (truncate (eng:js-get info key)))

(define-test net/fetch-text
  (with-fetch-server (g port)
    (multiple-value-bind (kind info) (fetch-info g eng:*realm* port "/text")
      (is eq :fulfilled kind)
      (is = 200 (info-num info "status"))
      (is eq eng:+true+ (info-field info "ok"))
      (is string= "plain text body" (info-str info "body")))))

(define-test net/fetch-json
  (with-fetch-server (g port)
    (multiple-value-bind (kind info) (fetch-info g eng:*realm* port "/json")
      (is eq :fulfilled kind)
      (is = 200 (info-num info "status"))
      (true (search "application/json" (info-str info "ct")))
      (true (search "\"hi\":\"there\"" (info-str info "body")))
      (true (search "\"n\":42" (info-str info "body"))))))

(define-test net/fetch-4xx-5xx
  (with-fetch-server (g port)
    (multiple-value-bind (kind info) (fetch-info g eng:*realm* port "/404")
      (is eq :fulfilled kind)                       ; a 404 fulfills (not a network error)
      (is = 404 (info-num info "status"))
      (is eq eng:+false+ (info-field info "ok"))
      (is string= "nope" (info-str info "body")))
    (multiple-value-bind (kind info) (fetch-info g eng:*realm* port "/500")
      (is eq :fulfilled kind)
      (is = 500 (info-num info "status")))))

(define-test net/fetch-redirect-chain
  (with-fetch-server (g port)
    ;; /redir2 → /redir → /json, followed automatically; final status 200, JSON body
    (multiple-value-bind (kind info) (fetch-info g eng:*realm* port "/redir2")
      (is eq :fulfilled kind)
      (is = 200 (info-num info "status"))
      (true (search "\"hi\":\"there\"" (info-str info "body"))))))

(define-test net/fetch-gzip
  (with-fetch-server (g port)
    (multiple-value-bind (kind info) (fetch-info g eng:*realm* port "/gz")
      (is eq :fulfilled kind)
      (is = 200 (info-num info "status"))
      (is string= "gzip-decoded-body" (info-str info "body")))))    ; auto-gunzipped

(define-test net/fetch-preserves-set-cookie-fields
  (with-fetch-server (g port)
    (multiple-value-bind (kind info) (fetch-info g eng:*realm* port "/set-cookies")
      (is eq :fulfilled kind)
      (is string= "[\"a=1\",\"b=2\"]" (info-str info "setCookies")))))

(define-test net/fetch-abort
  (with-fetch-server (g port)
    ;; an already-aborted signal → the promise rejects with an AbortError
    (multiple-value-bind (kind value)
        (fetch-info g eng:*realm* port "/text" "{signal: AbortSignal.abort()}")
      (is eq :rejected kind)
      (is string= "AbortError" (eng:to-string (eng:js-get value "name"))))))

(define-test net/response-nonutf8-body-no-crash
  ;; [5] a Response over invalid UTF-8 decodes leniently (U+FFFD), never a raw Lisp
  ;; UTF-8 decode backtrace (§6). No server needed.
  (let ((realm (eng:make-realm)))
    (rt:install-runtime realm :argv '(:script "[test]" :rest nil) :cwd "/tmp")
    (unwind-protect
         (let* ((eng:*realm* realm) (g (eng:realm-global realm)))
           (multiple-value-bind (kind value)
               (eng:run-callback-to-settlement
                (lambda ()
                  (let* ((u8 (eng:u8-from-octets (make-array 3 :element-type '(unsigned-byte 8)
                                                             :initial-contents '(255 254 65))))
                         (resp (eng:js-construct (eng:js-get g "Response") (list u8))))
                    (eng:js-call (eng:js-get resp "text") resp '())))
                realm)
             (is eq :fulfilled kind)
             (true (plusp (length (eng:to-string value))))))    ; decoded, didn't crash
      (eng:teardown-realm realm))))

(define-test net/fetch-redirect-cap
  ;; [3] an infinite redirect loop rejects with a TypeError, never resolves with the 3xx
  (with-fetch-server (g port)
    (multiple-value-bind (kind value) (fetch-info g eng:*realm* port "/loop")
      (is eq :rejected kind)
      (is string= "TypeError" (eng:to-string (eng:js-get value "name")))
      (true (search "redirect" (eng:to-string (eng:js-get value "message")))))))

(define-test net/fetch-post-302-becomes-get
  ;; [8]/[14] a 302 on a POST → the followed request is a GET with the body + content-type dropped
  (with-fetch-server (g port)
    (multiple-value-bind (kind info)
        (fetch-info g eng:*realm* port "/r302"
                    "{method:'POST', body:'DATA', headers:{'content-type':'text/plain'}}")
      (is eq :fulfilled kind)
      (is string= "GET ct=none" (info-str info "body")))))    ; landed as GET, no content-type

(define-test net/fetch-get-with-body-rejects
  ;; [15] a GET/HEAD request cannot carry a body → TypeError
  (with-fetch-server (g port)
    (multiple-value-bind (kind value)
        (fetch-info g eng:*realm* port "/text" "{method:'GET', body:'nope'}")
      (is eq :rejected kind)
      (is string= "TypeError" (eng:to-string (eng:js-get value "name"))))))

(define-test net/fetch-connection-refused
  (with-fetch-server (g port)
    ;; port 1 is not listening → the client's connect fails → TypeError
    (multiple-value-bind (kind value)
        (eng:run-callback-to-settlement
         (lambda () (eng:js-call (eng:js-get g "__fetchInfo") eng:+undefined+
                                 (list "http://127.0.0.1:1/x" eng:+undefined+)))
         eng:*realm* :timeout-ms 8000)
      (is eq :rejected kind)
      (is string= "TypeError" (eng:to-string (eng:js-get value "name"))))))
