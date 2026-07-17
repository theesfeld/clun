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
  "Route a request (a JS Request) to a Response by pathname (req.url is the origin-form
target, e.g. `/json?x=1` — take the part before any query/fragment)."
  (let* ((url (eng:to-string (eng:js-get request "url")))
         (path (subseq url 0 (or (position-if (lambda (c) (member c '(#\? #\#))) url) (length url)))))
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

(defparameter +fetch-signal-probe-src+
  "globalThis.__fetchSignalProbe = (url) => {
     let added = 0, removed = 0, listener = null;
     const signal = { aborted: false, reason: undefined };
     signal.addEventListener = (type, fn) => {
       if (type === 'abort') { added++; listener = fn; }
     };
     signal.removeEventListener = (type, fn) => {
       if (type === 'abort' && fn === listener) { removed++; listener = null; }
     };
     return fetch(url, { signal }).then(async r => ({
       body: await r.text(), added, removed, attached: listener !== null
     }));
   };")

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
             (eng:run-program (eng:parse-program +fetch-signal-probe-src+) ,realm)
             (unwind-protect (progn ,@body)
               (eng:teardown-realm ,realm))))))))

(defun %start-delayed-fetch-server (global loop)
  (net:tcp-listen
   loop "127.0.0.1" 0
   :on-connection
   (lambda (connection)
     (let ((responded nil))
       (setf
        (net:tcp-on-data connection)
        (lambda (peer data)
          (declare (ignore data))
          (unless responded
            (setf responded t)
            (net:tcp-write
             peer
             (sb-ext:string-to-octets
              (format nil
                      "HTTP/1.1 200 OK~c~cContent-Length: 11~c~cConnection: close~c~c~c~chello "
                      #\Return #\Newline #\Return #\Newline
                      #\Return #\Newline #\Return #\Newline)
              :external-format :latin-1))
            (lp:set-timer
             loop 75
             (lambda ()
               (eng:data-prop global "__tailSent" eng:+true+)
               (net:tcp-write
                peer
                (sb-ext:string-to-octets "world" :external-format :latin-1))
               (net:tcp-shutdown peer))))))))))

(defmacro with-delayed-fetch-server ((g port) &body body)
  "Run BODY with a raw HTTP server that sends headers + one body chunk immediately,
then the final chunk after 75ms.  __tailSent exposes whether fetch waited for EOF."
  (let ((realm (gensym)) (loop (gensym)) (listener (gensym)))
    `(let ((,realm (eng:make-realm)))
       (rt:install-runtime ,realm :argv '(:script "[test]" :rest nil) :cwd "/tmp")
       (let ((eng:*realm* ,realm))
         (let* ((,g (eng:realm-global ,realm))
                (,loop (eng:current-loop))
                (,listener (%start-delayed-fetch-server ,g ,loop))
                (,port (net:listener-port ,listener)))
           (eng:data-prop ,g "__tailSent" eng:+false+)
           (unwind-protect (progn ,@body)
             (net:listener-close ,listener)
             (eng:teardown-realm ,realm)))))))

(defun %start-stale-pool-server (loop accepted-count)
  "Serve a persistent response, then send FIN after the client can cache the socket."
  (net:tcp-listen
   loop "127.0.0.1" 0
   :on-connection
   (lambda (connection)
     (incf (car accepted-count))
     (let ((responded nil))
       (setf
        (net:tcp-on-data connection)
        (lambda (peer data)
          (declare (ignore data))
          (unless responded
            (setf responded t)
            (net:tcp-write
             peer
             (sb-ext:string-to-octets
              (format nil
                      "HTTP/1.1 200 OK~c~cContent-Length: 2~c~cConnection: keep-alive~c~c~c~cok"
                      #\Return #\Newline #\Return #\Newline
                      #\Return #\Newline #\Return #\Newline)
              :external-format :latin-1))
            (lp:set-timer loop 5 (lambda () (net:tcp-shutdown peer))))))))))

(defmacro with-stale-pool-server ((g port accepted-count) &body body)
  (let ((realm (gensym)) (loop (gensym)) (listener (gensym)))
    `(let ((,realm (eng:make-realm)))
       (rt:install-runtime ,realm :argv '(:script "[test]" :rest nil) :cwd "/tmp")
       (let ((eng:*realm* ,realm))
         (let* ((,g (eng:realm-global ,realm))
                (,loop (eng:current-loop))
                (,accepted-count (list 0))
                (,listener (%start-stale-pool-server ,loop ,accepted-count))
                (,port (net:listener-port ,listener)))
           (eng:run-program (eng:parse-program +fetch-info-src+) ,realm)
           (unwind-protect (progn ,@body)
             (net:listener-close ,listener)
             (eng:teardown-realm ,realm)))))))

(defun %append-upload-capture (capture octets)
  (let* ((old (fill-pointer capture))
         (new (+ old (length octets))))
    (when (> new (array-total-size capture))
      (adjust-array capture (max new (* 2 (array-total-size capture)))
                    :fill-pointer old))
    (setf (fill-pointer capture) new)
    (replace capture octets :start1 old)))

(defun %start-upload-capture-server (loop capture)
  (let ((terminal
          (sb-ext:string-to-octets
           (format nil "0~c~c~c~c" #\Return #\Newline #\Return #\Newline)
           :external-format :latin-1)))
    (net:tcp-listen
     loop "127.0.0.1" 0
     :on-connection
     (lambda (connection)
       (let ((responded nil))
         (setf
          (net:tcp-on-data connection)
          (lambda (peer data)
            (%append-upload-capture capture data)
            (when (and (not responded)
                       (search terminal capture :end2 (fill-pointer capture)))
              (setf responded t)
              (net:tcp-write
               peer
               (sb-ext:string-to-octets
                (format nil
                        "HTTP/1.1 200 OK~c~cContent-Length: 2~c~cConnection: close~c~c~c~cok"
                        #\Return #\Newline #\Return #\Newline
                        #\Return #\Newline #\Return #\Newline)
                :external-format :latin-1))
              (net:tcp-shutdown peer)))))))))

(defmacro with-upload-capture-server ((g port capture) &body body)
  (let ((realm (gensym)) (loop (gensym)) (listener (gensym)))
    `(let ((,realm (eng:make-realm)))
       (rt:install-runtime ,realm :argv '(:script "[test]" :rest nil) :cwd "/tmp")
       (let ((eng:*realm* ,realm))
         (let* ((,g (eng:realm-global ,realm))
                (,loop (eng:current-loop))
                (,capture
                  (make-array 1024 :element-type '(unsigned-byte 8)
                                   :adjustable t :fill-pointer 0))
                (,listener (%start-upload-capture-server ,loop ,capture))
                (,port (net:listener-port ,listener)))
           (unwind-protect (progn ,@body)
             (net:listener-close ,listener)
             (eng:teardown-realm ,realm)))))))

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

(define-test net/fetch-reuses-an-idle-origin-connection
  (with-fetch-server (g port)
    (let ((loop (eng:current-loop)))
      (multiple-value-bind (kind info) (fetch-info g eng:*realm* port "/text")
        (declare (ignore info))
        (is eq :fulfilled kind))
      (let ((first-idle
              (net::%http-pool-idle-tcps loop "127.0.0.1" port)))
        (is = 1 (length first-idle))
        (multiple-value-bind (kind info) (fetch-info g eng:*realm* port "/json")
          (is eq :fulfilled kind)
          (is = 200 (info-num info "status")))
        (let ((second-idle
                (net::%http-pool-idle-tcps loop "127.0.0.1" port)))
          (is = 1 (length second-idle))
          (is eq (first first-idle) (first second-idle)))))))

(define-test net/fetch-connection-close-is-never-pooled
  (with-fetch-server (g port)
    (multiple-value-bind (kind info)
        (fetch-info g eng:*realm* port "/text"
                    "{headers: {connection: 'close'}}")
      (declare (ignore info))
      (is eq :fulfilled kind))
    (is = 0
        (length (net::%http-pool-idle-tcps
                 (eng:current-loop) "127.0.0.1" port)))))

(define-test net/fetch-evicts-peer-closed-idle-connections
  (with-stale-pool-server (g port accepted-count)
    (multiple-value-bind (kind info) (fetch-info g eng:*realm* port "/first")
      (is eq :fulfilled kind)
      (is string= "ok" (info-str info "body")))
    (let* ((loop (eng:current-loop))
           (idle (net::%http-pool-idle-tcps loop "127.0.0.1" port))
           (first-connection (first idle)))
      (is = 1 (length idle))
      (multiple-value-bind (kind value)
          (eng:run-callback-to-settlement
           (lambda ()
             (jseval eng:*realm*
                     "new Promise(resolve => setTimeout(resolve, 30))"))
           eng:*realm* :timeout-ms 1000)
        (declare (ignore value))
        (is eq :fulfilled kind))
      (is eq :closed (net:tcp-state first-connection))
      (is = 0 (length (net::%http-pool-idle-tcps
                       loop "127.0.0.1" port)))
      (multiple-value-bind (kind info) (fetch-info g eng:*realm* port "/second")
        (is eq :fulfilled kind)
        (is string= "ok" (info-str info "body")))
      (is = 2 (car accepted-count)))))

(define-test net/fetch-pool-isolates-distinct-origins
  (with-fetch-server (g first-port)
    (let* ((loop (eng:current-loop))
           (fetch-handler
             (eng:make-native-function
              "fetch" 1
              (lambda (this args)
                (declare (ignore this))
                (%fetch-route g (eng:arg args 0)))))
           (options (eng:new-object)))
      (eng:data-prop options "port" 0d0)
      (eng:data-prop options "hostname" "127.0.0.1")
      (eng:data-prop options "fetch" fetch-handler)
      (let* ((second-server (rt::%clun-serve g options))
             (second-port (truncate (eng:js-get second-server "port"))))
        (declare (ignore second-server))
        (multiple-value-bind (kind info)
            (fetch-info g eng:*realm* first-port "/first")
          (declare (ignore info))
          (is eq :fulfilled kind))
        (multiple-value-bind (kind info)
            (fetch-info g eng:*realm* second-port "/second")
          (declare (ignore info))
          (is eq :fulfilled kind))
        (let* ((first-idle
                 (net::%http-pool-idle-tcps
                  loop "127.0.0.1" first-port))
               (second-idle
                 (net::%http-pool-idle-tcps
                  loop "127.0.0.1" second-port))
               (first-connection (first first-idle)))
          (is = 1 (length first-idle))
          (is = 1 (length second-idle))
          (isnt eq first-connection (first second-idle))
          (multiple-value-bind (kind info)
              (fetch-info g eng:*realm* first-port "/again")
            (declare (ignore info))
            (is eq :fulfilled kind))
          (is eq first-connection
              (first (net::%http-pool-idle-tcps
                      loop "127.0.0.1" first-port))))))))

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

(define-test net/fetch-abort-preserves-primitive-reason
  (with-fetch-server (g port)
    (multiple-value-bind (kind value)
        (fetch-info g eng:*realm* port "/text"
                    "{signal: AbortSignal.abort('custom-stop')}")
      (is eq :rejected kind)
      (is string= "custom-stop" (eng:to-string value)))))

(define-test net/fetch-redirects-own-one-abort-listener
  (with-fetch-server (g port)
    (multiple-value-bind (kind value)
        (eng:run-callback-to-settlement
         (lambda ()
           (eng:js-call
            (eng:js-get g "__fetchSignalProbe") eng:+undefined+
            (list (format nil "http://127.0.0.1:~d/redir2" port))))
         eng:*realm* :timeout-ms 8000)
      (is eq :fulfilled kind)
      (true (search "\"hi\":\"there\""
                    (eng:to-string (eng:js-get value "body"))))
      (is = 1 (truncate (eng:js-get value "added")))
      (is = 1 (truncate (eng:js-get value "removed")))
      (is eq eng:+false+ (eng:js-get value "attached")))))

(define-test net/fetch-response-body-streams-before-completion
  (with-delayed-fetch-server (g port)
    (multiple-value-bind (kind value)
        (eng:run-callback-to-settlement
         (lambda ()
           (jseval
            eng:*realm*
            (format nil
                    "(async () => {
                       const response = await fetch('http://127.0.0.1:~d/stream');
                       const tailAtResolve = globalThis.__tailSent;
                       const usedBefore = response.bodyUsed;
                       const reader = response.body.getReader();
                       const first = await reader.read();
                       const usedAfter = response.bodyUsed;
                       const second = await reader.read();
                       const end = await reader.read();
                       const decoder = new TextDecoder();
                       return { tailAtResolve, usedBefore, usedAfter,
                                body: decoder.decode(first.value) + decoder.decode(second.value),
                                done: end.done };
                     })()"
                    port)))
         eng:*realm* :timeout-ms 4000)
      (is eq :fulfilled kind)
      (is eq eng:+false+ (eng:js-get value "tailAtResolve"))
      (is eq eng:+false+ (eng:js-get value "usedBefore"))
      (is eq eng:+true+ (eng:js-get value "usedAfter"))
      (is string= "hello world" (eng:to-string (eng:js-get value "body")))
      (is eq eng:+true+ (eng:js-get value "done")))))

(define-test net/fetch-body-async-iteration-is-single-consumption
  (with-delayed-fetch-server (g port)
    (multiple-value-bind (kind value)
        (eng:run-callback-to-settlement
         (lambda ()
           (jseval
            eng:*realm*
            (format nil
                    "(async () => {
                       const response = await fetch('http://127.0.0.1:~d/iterate');
                       const decoder = new TextDecoder();
                       let body = '';
                       for await (const chunk of response.body) body += decoder.decode(chunk);
                       let second = '';
                       try { await response.text(); } catch (error) { second = error.name; }
                       return { body, second, used: response.bodyUsed };
                     })()"
                    port)))
         eng:*realm* :timeout-ms 4000)
      (is eq :fulfilled kind)
      (is string= "hello world" (eng:to-string (eng:js-get value "body")))
      (is string= "TypeError" (eng:to-string (eng:js-get value "second")))
      (is eq eng:+true+ (eng:js-get value "used")))))

(define-test net/fetch-response-clone-tees-delayed-body
  (with-delayed-fetch-server (g port)
    (multiple-value-bind (kind value)
        (eng:run-callback-to-settlement
         (lambda ()
           (jseval
            eng:*realm*
            (format nil
                    "(async () => {
                       const response = await fetch('http://127.0.0.1:~d/clone');
                       const clone = response.clone();
                       const tailAtClone = globalThis.__tailSent;
                       const originalBody = await response.text();
                       const clonedBody = await clone.text();
                       let cloneAfterUse = '';
                       try { response.clone(); } catch (error) { cloneAfterUse = error.name; }
                       return { tailAtClone, originalBody, clonedBody, cloneAfterUse,
                                originalUsed: response.bodyUsed, cloneUsed: clone.bodyUsed };
                     })()"
                    port)))
         eng:*realm* :timeout-ms 4000)
      (is eq :fulfilled kind)
      (is eq eng:+false+ (eng:js-get value "tailAtClone"))
      (is string= "hello world" (eng:to-string (eng:js-get value "originalBody")))
      (is string= "hello world" (eng:to-string (eng:js-get value "clonedBody")))
      (is string= "TypeError" (eng:to-string (eng:js-get value "cloneAfterUse")))
      (is eq eng:+true+ (eng:js-get value "originalUsed"))
      (is eq eng:+true+ (eng:js-get value "cloneUsed")))))

(define-test net/response-clone-and-readable-stream-tee
  (let ((realm (eng:make-realm)))
    (rt:install-runtime realm :argv '(:script "[test]" :rest nil) :cwd "/tmp")
    (unwind-protect
         (let ((eng:*realm* realm))
           (multiple-value-bind (kind value)
               (eng:run-callback-to-settlement
                (lambda ()
                  (jseval
                   realm
                   "(async () => {
                      const response = new Response('abc', {
                        status: 201, statusText: 'Made', headers: { 'x-copy': 'original' }
                      });
                      const heldBody = response.body;
                      const clone = response.clone();
                      clone.headers.set('x-copy', 'clone');
                      const original = await response.text();
                      const copied = await clone.text();

                      const teeResponse = new Response('xy');
                      const source = teeResponse.body;
                      const branches = source.tee();
                      const left = branches[0].getReader();
                      const right = branches[1].getReader();
                      const leftChunk = await left.read();
                      const rightChunk = await right.read();
                      return {
                        original, copied, status: clone.status,
                        originalHeader: response.headers.get('x-copy'),
                        cloneHeader: clone.headers.get('x-copy'),
                        heldLocked: heldBody.locked, sourceLocked: source.locked,
                        leftFirst: leftChunk.value[0], rightSecond: rightChunk.value[1]
                      };
                    })()"))
                realm :timeout-ms 4000)
             (is eq :fulfilled kind)
             (is string= "abc" (eng:to-string (eng:js-get value "original")))
             (is string= "abc" (eng:to-string (eng:js-get value "copied")))
             (is = 201 (truncate (eng:js-get value "status")))
             (is string= "original" (eng:to-string (eng:js-get value "originalHeader")))
             (is string= "clone" (eng:to-string (eng:js-get value "cloneHeader")))
             (is eq eng:+true+ (eng:js-get value "heldLocked"))
             (is eq eng:+true+ (eng:js-get value "sourceLocked"))
             (is = (char-code #\x) (truncate (eng:js-get value "leftFirst")))
             (is = (char-code #\y) (truncate (eng:js-get value "rightSecond")))))
      (eng:teardown-realm realm))))

(define-test net/response-tee-shares-backpressure-and-cancellation
  (let ((realm (eng:make-realm))
        (pauses 0)
        (resumes 0)
        (cancels 0))
    (rt:install-runtime realm :argv '(:script "[test]" :rest nil) :cwd "/tmp")
    (unwind-protect
         (let* ((eng:*realm* realm)
                (source
                  (rt::%new-body-stream
                   :cancel (lambda () (incf cancels))
                   :pause (lambda () (incf pauses))
                   :resume (lambda () (incf resumes))))
                (chunk
                  (make-array 4 :element-type '(unsigned-byte 8)
                              :initial-contents '(1 2 3 4))))
           (multiple-value-bind (first second)
               (rt::%body-stream-tee source :high-water 8 :low-water 3)
             (rt::%body-stream-enqueue source chunk)
             (rt::%body-stream-enqueue source chunk)
             (is = 1 pauses)
             (loop repeat 2 do (rt::%body-stream-queue-pop first))
             (rt::%body-stream-maybe-resume first)
             (is = 0 resumes)
             (rt::%body-stream-cancel-now second eng:+undefined+)
             (is = 1 resumes)
             (is = 0 cancels)
             (rt::%body-stream-cancel-now first eng:+undefined+)
             (is = 1 cancels)))
      (eng:teardown-realm realm))))

(define-test net/fetch-abort-after-headers-errors-body-with-reason
  (with-delayed-fetch-server (g port)
    (multiple-value-bind (kind value)
        (eng:run-callback-to-settlement
         (lambda ()
           (jseval
            eng:*realm*
            (format nil
                    "(async () => {
                       const controller = new AbortController();
                       const response = await fetch('http://127.0.0.1:~d/abort',
                                                    { signal: controller.signal });
                       controller.abort('body-stop');
                       try { await response.text(); return 'fulfilled'; }
                       catch (error) { return error; }
                     })()"
                    port)))
         eng:*realm* :timeout-ms 4000)
      ;; fetch itself fulfilled at headers; only consuming its body rejects.
      (is eq :fulfilled kind)
      (is string= "body-stop" (eng:to-string value)))))

(define-test net/response-body-stream-applies-high-low-water-backpressure
  (let ((realm (eng:make-realm))
        (pauses 0)
        (resumes 0))
    (rt:install-runtime realm :argv '(:script "[test]" :rest nil) :cwd "/tmp")
    (unwind-protect
         (let* ((eng:*realm* realm)
                (stream
                  (clun.runtime::%new-body-stream
                   :pause (lambda () (incf pauses))
                   :resume (lambda () (incf resumes))
                   :high-water 8 :low-water 3))
                (chunk
                  (make-array 4 :element-type '(unsigned-byte 8)
                              :initial-contents '(1 2 3 4))))
           (clun.runtime::%body-stream-enqueue stream chunk)
           (clun.runtime::%body-stream-enqueue stream chunk)
           (is = 1 pauses)
           (is = 8 (clun.runtime::js-body-stream-queued-bytes stream))
           (let ((reader
                   (eng:js-call (eng:js-get stream "getReader") stream '())))
             (loop repeat 2 do
               (multiple-value-bind (kind result)
                   (eng:run-callback-to-settlement
                    (lambda ()
                      (eng:js-call (eng:js-get reader "read") reader '()))
                    realm)
                 (is eq :fulfilled kind)
                 (is eq eng:+false+ (eng:js-get result "done"))))
             (is = 1 resumes)
             (is = 0 (clun.runtime::js-body-stream-queued-bytes stream))))
      (eng:teardown-realm realm))))

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

(define-test net/fetch-streaming-request-body-is-chunked-and-bounded
  (with-upload-capture-server (g port capture)
    (let ((stream (rt::%new-body-stream)))
      (eng:data-prop g "__uploadBody" stream)
      (rt::%body-stream-enqueue
       stream (make-array 3 :element-type '(unsigned-byte 8)
                           :initial-contents '(97 98 99)))
      (rt::%body-stream-enqueue
       stream (make-array 2 :element-type '(unsigned-byte 8)
                           :initial-contents '(100 101)))
      (rt::%body-stream-close stream)
      (multiple-value-bind (kind value)
          (eng:run-callback-to-settlement
           (lambda ()
             (jseval
              eng:*realm*
              (format nil
                      "(async () => {
                         const response = await fetch('http://127.0.0.1:~d/upload', {
                           method: 'POST', body: globalThis.__uploadBody, duplex: 'half'
                         });
                         return { body: await response.text(), locked: globalThis.__uploadBody.locked };
                       })()"
                      port)))
           eng:*realm* :timeout-ms 4000)
        (is eq :fulfilled kind)
        (is string= "ok" (eng:to-string (eng:js-get value "body")))
        (is eq eng:+false+ (eng:js-get value "locked"))
        (let ((wire
                (sb-ext:octets-to-string
                 (subseq capture 0 (fill-pointer capture))
                 :external-format :latin-1)))
          (true (search "Transfer-Encoding: chunked" wire))
          (false (search "Content-Length:" wire))
          (true
           (search
            (format nil "3~c~cabc~c~c2~c~cde~c~c0~c~c~c~c"
                    #\Return #\Newline #\Return #\Newline
                    #\Return #\Newline #\Return #\Newline
                    #\Return #\Newline #\Return #\Newline)
            wire)))))))

(define-test net/fetch-streaming-request-validates-duplex-and-framing
  (with-fetch-server (g port)
    (dolist (options
             (list
              "{ method: 'POST', body: new Response('x').body }"
              "{ method: 'POST', body: new Response('x').body, duplex: 'full' }"
              "{ method: 'POST', body: new Response('x').body, duplex: 'half', headers: { 'content-length': '1' } }"
              "{ method: 'GET', body: new Response('x').body, duplex: 'half' }"))
      (multiple-value-bind (kind value)
          (fetch-info g eng:*realm* port "/text" options)
        (is eq :rejected kind)
        (is string= "TypeError"
            (eng:to-string (eng:js-get value "name")))))))

(define-test net/fetch-streaming-request-preserves-source-error
  (with-upload-capture-server (g port capture)
    (let ((stream (rt::%new-body-stream)))
      (eng:data-prop g "__failedUpload" stream)
      (rt::%body-stream-error stream "upload-broke")
      (multiple-value-bind (kind value)
          (eng:run-callback-to-settlement
           (lambda ()
             (jseval
              eng:*realm*
              (format nil
                      "fetch('http://127.0.0.1:~d/upload', {
                         method: 'POST', body: globalThis.__failedUpload, duplex: 'half'
                       })"
                      port)))
           eng:*realm* :timeout-ms 4000)
        (is eq :rejected kind)
        (is string= "upload-broke" (eng:to-string value))))))

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
