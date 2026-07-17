;;;; web-fetch.lisp — the fetch() global (PLAN.md Phase 18, §3.2). Ties URL (web-url) +
;;;; the reactor HTTP client (net) + Headers/Request/Response (web-http) + AbortSignal
;;;; (Phase 14) together. fetch(input, init) → Promise<Response>. Redirects are followed
;;;; here (≤20); the client does one request/response. Network errors / abort / timeout
;;;; reject with a TypeError / an AbortError-named error.

(in-package :clun.runtime)

(defparameter *fetch-connect-timeout-ms* 120000
  "A safety-net timeout so a stuck connect can't hang forever; real cancellation is via
an AbortSignal (e.g. AbortSignal.timeout(ms)).")

(defun %fetch-error (g name message)
  (let ((e (eng:js-construct (eng:js-get g "Error") (list message))))
    (eng:js-set e "name" name nil) e))

(defun %fetch-url-of (input)
  "The URL string from a fetch input: a string, a URL (href/toString), or a Request (url)."
  (cond
    ((eng:js-string-p input) (eng:to-string input))
    ((js-request-p input) (eng:to-string (eng:js-get input "url")))
    ((eng:js-object-p input)
     (let ((href (eng:js-get input "href")))
       (if (eng:js-string-p href) (eng:to-string href) (eng:to-string input))))
    (t (eng:to-string input))))

(defun %fetch-normalize (input init)
  "Return a plist (:url :method :headers alist :body octets :signal :redirect) from
INPUT + INIT (INIT overrides). A Request INPUT contributes method/headers/body."
  (let* ((req-input (and (js-request-p input) input))
         (io (and (eng:js-object-p init) init))
         (method (let ((m (or (and io (eng:js-get init "method"))
                              (and req-input (eng:js-get req-input "method")))))
                   (if (and m (eng:js-string-p m)) (string-upcase (eng:to-string m)) "GET")))
         (init-headers (and io (eng:js-get init "headers")))
         (headers
           (cond ((and io (not (eng:js-undefined-p init-headers)))
                  (%coerce-headers-init init-headers))
                 (req-input
                  (%headers-raw-alist (%request-headers-object req-input)))
                 (t '())))
         (body-val (cond ((and io (not (eng:js-undefined-p (eng:js-get init "body")))) (eng:js-get init "body"))
                         (req-input (%request-body-value req-input))
                         (t nil)))
         (signal (and io (let ((s (eng:js-get init "signal"))) (and (eng:js-object-p s) s))))
         (redirect (if (and io (eng:js-string-p (eng:js-get init "redirect")))
                       (eng:to-string (eng:js-get init "redirect")) "follow")))
    (list :url (%fetch-url-of input) :method method :headers headers
          :body (if body-val (%body->octets body-val) nil) :signal signal :redirect redirect)))

(defun %build-fetch-response (resp final-url)
  (let ((u8 (eng:u8-from-octets (net:hres-body resp)))
        (init (eng:new-object)))
    (eng:data-prop init "status" (coerce (net:hres-status resp) 'double-float))
    (eng:data-prop init "statusText" (or (net:hres-reason resp) ""))
    ;; Construct from ordered pairs so repeated Set-Cookie fields survive fetch.
    (eng:data-prop init "headers" (%new-headers (net:hres-headers resp)))
    (let ((r (%new-response u8 init)))
      (eng:data-prop r "url" final-url)
      r)))

(defun %build-stream-fetch-response (head stream final-url method)
  "Build the public Response as soon as HEAD is available.  STREAM remains owned by
the active transport until completion, cancellation, or failure."
  (let ((init (eng:new-object))
        (status (net:hres-status head)))
    (eng:data-prop init "status" (coerce status 'double-float))
    (eng:data-prop init "statusText" (or (net:hres-reason head) ""))
    (eng:data-prop init "headers" (%new-headers (net:hres-headers head)))
    (let ((response
            (%new-stream-response
             stream init
             :body-null-p
             (or (string= method "HEAD")
                 (member status '(204 304))
                 (< status 200)))))
      (eng:data-prop response "url" final-url)
      response)))

(defun %redirect-p (status) (member status '(301 302 303 307 308)))

(defun %redirect-to-get-p (status method)
  "Does STATUS on a request with METHOD force a GET (dropping the body)? 303 always; 301/302
only for POST (the historical browser behavior); 307/308 preserve method + body."
  (or (= status 303)
      (and (member status '(301 302)) (string= method "POST"))))

(defun %strip-body-headers (headers)
  "Drop content-* request headers when a redirect converts the request to a bodiless GET —
they describe a body that no longer exists (Content-Type/Length/Encoding/Language/Location)."
  (remove-if (lambda (h)
               (member (string-downcase (car h))
                       '("content-type" "content-length" "content-encoding"
                         "content-language" "content-location")
                       :test #'string=))
             headers))

(defun %https-request-async (loop &key host port method path headers body host-header
                                       timeout on-response on-error)
  "HTTPS transport: net:https-request runs BLOCKING on the worker pool; its completion runs
on the loop thread → ON-RESPONSE (an http-response) / ON-ERROR (a code string). Returns a
cancel thunk that closes the worker's socket to unblock its read (abort/timeout). CA trust =
$SSL_CERT_FILE / the system bundle (net's %system-ca-file). Certs always fail closed."
  (let ((box (list nil))                 ; (car box) <- current socket-close thunk
        (done nil)
        (timer nil)
        (job nil))
    (labels ((abort-socket ()
               (when (car box) (ignore-errors (funcall (car box)))))
             (cleanup ()
               (when timer
                 (lp:clear-timer timer)
                 (setf timer nil)))
             (settle (thunk &key cancel-worker)
               (unless done
                 (setf done t)
                 (cleanup)
                 (when cancel-worker
                   (abort-socket)
                   (when job (lp:cancel-worker-job job)))
                 (funcall thunk))))
      (setf job
            (lp:worker-submit-cancellable
             loop
             (lambda (token)
               (when (lp:worker-cancelled-p token)
                 (error 'net:socket-open-error :code "ECANCELED" :op "https"))
               (net:https-request :host host :port port :method method :path path
                                  :headers headers :body body :host-header host-header
                                  :socket-box box))
             (lambda (result)             ; loop thread
               (case (first result)
                 (:ok (settle (lambda () (funcall on-response (second result)))))
                 (:cancelled
                  (settle (lambda () (funcall on-error "abort"))))
                 (t
                  (settle
                   (lambda ()
                     (funcall on-error (net:tls-error-message (second result))))))))))
      (when (and timeout (plusp timeout))
        (setf timer
              (lp:set-timer
               loop timeout
               (lambda ()
                 (settle (lambda () (funcall on-error "timeout"))
                         :cancel-worker t)))))
      (lambda ()
        (settle (lambda () (funcall on-error "abort")) :cancel-worker t)))))

(defstruct (fetch-operation (:constructor %make-fetch-operation))
  global resolve reject signal listener active-cancel response-stream
  ;; SETTLED-P is the public fetch promise.  TERMINAL-P is the response body /
  ;; transport lifecycle.  A streaming fetch deliberately settles before terminal.
  (settled-p nil)
  (terminal-p nil))

(defun %abort-reason (g signal)
  (let ((reason (and signal (eng:js-get signal "reason"))))
    ;; AbortController.abort(value) preserves any supplied JavaScript value,
    ;; including strings, numbers, null, and false. Only undefined selects the
    ;; default AbortError stand-in.
    (if (and signal (not (eng:js-undefined-p reason)))
        reason
        (%fetch-error g "AbortError" "The operation was aborted"))))

(defun %fetch-operation-detach (operation)
  (let ((signal (fetch-operation-signal operation))
        (listener (fetch-operation-listener operation)))
    (when (and signal listener)
      (let ((remove (eng:js-get signal "removeEventListener")))
        (when (eng:callable-p remove)
          (eng:js-call remove signal (list "abort" listener)))))
    (setf (fetch-operation-listener operation) nil)))

(defun %fetch-operation-finish (operation)
  "End transport ownership and detach the one operation-scoped abort listener."
  (unless (fetch-operation-terminal-p operation)
    (setf (fetch-operation-terminal-p operation) t
          (fetch-operation-active-cancel operation) nil)
    (%fetch-operation-detach operation)))

(defun %fetch-operation-settle (operation kind value)
  "Settle a non-streaming or pre-header fetch and finish the operation."
  (unless (fetch-operation-settled-p operation)
    (setf (fetch-operation-settled-p operation) t)
    (eng:js-call (ecase kind
                   (:resolve (fetch-operation-resolve operation))
                   (:reject (fetch-operation-reject operation)))
                 eng:+undefined+ (list value)))
  (%fetch-operation-finish operation))

(defun %fetch-operation-resolve-stream (operation stream response)
  "Fulfil fetch at response headers while retaining body lifecycle ownership."
  (unless (fetch-operation-settled-p operation)
    (setf (fetch-operation-settled-p operation) t
          (fetch-operation-response-stream operation) stream)
    (eng:js-call (fetch-operation-resolve operation)
                 eng:+undefined+ (list response))))

(defun %fetch-operation-fail (operation reason)
  "Reject before headers, or error an already-exposed response body after headers."
  (unless (fetch-operation-terminal-p operation)
    (if (fetch-operation-settled-p operation)
        (let ((stream (fetch-operation-response-stream operation)))
          (when stream (%body-stream-error stream reason))
          ;; A defensive fallback for a settled operation without a body stream.
          (unless stream (%fetch-operation-finish operation)))
        (%fetch-operation-settle operation :reject reason))))

(defun %fetch-operation-abort (operation)
  (unless (fetch-operation-terminal-p operation)
    (let ((cancel (fetch-operation-active-cancel operation)))
      (setf (fetch-operation-active-cancel operation) nil)
      ;; Transport cancellation normally calls the current hop's ON-ERROR
      ;; synchronously.  The fallback covers a transport already between hops.
      (when cancel (funcall cancel)))
    (unless (fetch-operation-terminal-p operation)
      (%fetch-operation-fail
       operation
       (%abort-reason (fetch-operation-global operation)
                      (fetch-operation-signal operation))))))

(defun %fetch-operation-install-signal (operation)
  (let ((signal (fetch-operation-signal operation)))
    (when signal
      (if (eng:js-truthy (eng:js-get signal "aborted"))
          (%fetch-operation-abort operation)
          (let ((add (eng:js-get signal "addEventListener")))
            (when (eng:callable-p add)
              (let ((listener
                      (eng:make-native-function
                       "" 0
                       (lambda (this args)
                         (declare (ignore this args))
                         (%fetch-operation-abort operation)
                         eng:+undefined+))))
                (setf (fetch-operation-listener operation) listener)
                (eng:js-call add signal (list "abort" listener)))))))))

(defun %redirect-info (info record location status)
  "Return the next normalized request for one valid redirect, or NIL."
  (let ((next
          (handler-case
              (%serialize-url (%parse-url location record))
            (error () nil))))
    (when next
      (let ((redirected (copy-list info)))
        (setf (getf redirected :url) next)
        (when (%redirect-to-get-p status (getf info :method))
          (setf (getf redirected :method) "GET"
                (getf redirected :body) nil
                (getf redirected :headers)
                (%strip-body-headers (getf info :headers))))
        redirected))))

(defun %do-fetch (operation info hops)
  (when (fetch-operation-terminal-p operation)
    (return-from %do-fetch eng:+undefined+))
  (let* ((g (fetch-operation-global operation))
         (url-str (getf info :url))
         (record
           (handler-case (%parse-url url-str)
             (error ()
               (return-from %do-fetch
                 (%fetch-operation-settle
                  operation :reject
                  (%fetch-error g "TypeError"
                                (format nil "Failed to parse URL: ~a" url-str))))))))
    (unless (member (ur-scheme record) '("http" "https") :test #'string=)
      (return-from %do-fetch
        (%fetch-operation-settle
         operation :reject
         (%fetch-error g "TypeError"
                       (format nil "fetch: unsupported scheme ~a"
                               (ur-scheme record))))))
    (when (and (member (getf info :method) '("GET" "HEAD") :test #'string=)
               (getf info :body))
      (return-from %do-fetch
        (%fetch-operation-settle
         operation :reject
         (%fetch-error g "TypeError"
                       "fetch: request with GET/HEAD method cannot have a body"))))
    (let* ((signal (fetch-operation-signal operation))
           (loop (eng:current-loop))
           (https (string= (ur-scheme record) "https"))
           (raw-host (ur-host record))
           (port (or (ur-port record) (if https 443 80)))
           (host-header
             (if (ur-port record)
                 (format nil "~a:~d" raw-host (ur-port record))
                 raw-host))
           (path
             (concatenate
              'string
              (if (plusp (length (ur-path record))) (ur-path record) "/")
              (if (ur-query record)
                  (concatenate 'string "?" (ur-query record))
                  ""))))
      (if https
          ;; The TLS 1.2 worker is still buffered.  It preserves the same abort and
          ;; redirect lifecycle while the pure-TLS streaming adapter is completed.
          (labels
              ((on-response (response)
                 (setf (fetch-operation-active-cancel operation) nil)
                 (let ((location
                         (net:%header (net:hres-headers response) "location"))
                       (status (net:hres-status response)))
                   (cond
                     ((and (%redirect-p status) location
                           (string= (getf info :redirect) "follow"))
                      (if (>= hops 20)
                          (%fetch-operation-settle
                           operation :reject
                           (%fetch-error g "TypeError" "fetch: too many redirects"))
                          (let ((redirected
                                  (%redirect-info info record location status)))
                            (if redirected
                                (%do-fetch operation redirected (1+ hops))
                                (%fetch-operation-settle
                                 operation :resolve
                                 (%build-fetch-response response url-str))))))
                     ((and (%redirect-p status)
                           (string= (getf info :redirect) "error"))
                      (%fetch-operation-settle
                       operation :reject
                       (%fetch-error g "TypeError" "fetch: unexpected redirect")))
                     (t
                      (%fetch-operation-settle
                       operation :resolve
                       (%build-fetch-response response url-str))))))
               (on-error (code)
                 (setf (fetch-operation-active-cancel operation) nil)
                 (%fetch-operation-fail
                  operation
                  (if (string= code "abort")
                      (%abort-reason g signal)
                      (%fetch-error g "TypeError"
                                    (format nil "fetch failed: ~a" code))))))
            (setf (fetch-operation-active-cancel operation)
                  (%https-request-async
                   loop :host raw-host :port port :host-header host-header
                   :method (getf info :method) :path path
                   :headers (getf info :headers) :body (getf info :body)
                   :timeout *fetch-connect-timeout-ms*
                   :on-response #'on-response :on-error #'on-error)))
          (let ((stream nil)
                (cancel nil)
                (pause nil)
                (resume nil)
                (redirecting-p nil))
            (labels
                ((stop-current-hop ()
                   ;; Suppress the cancellation callback only while deliberately
                   ;; abandoning a redirect response before starting the next hop.
                   (setf redirecting-p t
                         (fetch-operation-active-cancel operation) nil)
                   (when cancel (funcall cancel))
                   (setf redirecting-p nil))
                 (expose-response (head)
                   (setf stream (%new-body-stream))
                   (%body-stream-bind-transport
                    stream :cancel cancel :pause pause :resume resume
                    :terminal-callback
                    (lambda () (%fetch-operation-finish operation)))
                   (%fetch-operation-resolve-stream
                    operation stream
                    (%build-stream-fetch-response
                     head stream url-str (getf info :method))))
                 (on-headers (head)
                   (let ((location
                           (net:%header (net:hres-headers head) "location"))
                         (status (net:hres-status head)))
                     (cond
                       ((and (%redirect-p status) location
                             (string= (getf info :redirect) "follow"))
                        (if (>= hops 20)
                            (progn
                              (stop-current-hop)
                              (%fetch-operation-settle
                               operation :reject
                               (%fetch-error g "TypeError"
                                             "fetch: too many redirects")))
                            (let ((redirected
                                    (%redirect-info info record location status)))
                              (if redirected
                                  (progn
                                    (stop-current-hop)
                                    (%do-fetch operation redirected (1+ hops)))
                                  (expose-response head)))))
                       ((and (%redirect-p status)
                             (string= (getf info :redirect) "error"))
                        (stop-current-hop)
                        (%fetch-operation-settle
                         operation :reject
                         (%fetch-error g "TypeError"
                                       "fetch: unexpected redirect")))
                       (t (expose-response head)))))
                 (on-data (chunk)
                   (when stream (%body-stream-enqueue stream chunk)))
                 (on-complete ()
                   (setf (fetch-operation-active-cancel operation) nil)
                   (if stream
                       (%body-stream-close stream)
                       (%fetch-operation-finish operation)))
                 (on-error (code)
                   (setf (fetch-operation-active-cancel operation) nil)
                   (unless redirecting-p
                     (%fetch-operation-fail
                      operation
                      (if (string= code "abort")
                          (%abort-reason g signal)
                          (%fetch-error
                           g "TypeError" (format nil "fetch failed: ~a" code)))))))
              (multiple-value-setq (cancel pause resume)
                (net:http-request-stream-async
                 loop :host raw-host :port port :host-header host-header
                 :method (getf info :method) :path path
                 :headers (getf info :headers) :body (getf info :body)
                 :timeout *fetch-connect-timeout-ms*
                 :on-headers #'on-headers :on-data #'on-data
                 :on-complete #'on-complete :on-error #'on-error))
              (setf (fetch-operation-active-cancel operation) cancel)))))))

(defun install-fetch (realm)
  (let ((eng:*realm* realm) (g (eng:realm-global realm)))
    (eng:install-method g "fetch" 2
      (lambda (this args) (declare (ignore this))
        (let ((info (%fetch-normalize (eng:arg args 0) (eng:arg args 1)))
              (promise-ctor (eng:js-get g "Promise")))
          (eng:js-construct promise-ctor
            (list (eng:make-native-function "" 2
                    (lambda (th a) (declare (ignore th))
                      (let ((operation
                              (%make-fetch-operation
                               :global g :resolve (eng:arg a 0)
                               :reject (eng:arg a 1)
                               :signal (getf info :signal))))
                        (%fetch-operation-install-signal operation)
                        (unless (fetch-operation-settled-p operation)
                          (%do-fetch operation info 0)))
                      eng:+undefined+)))))))))
