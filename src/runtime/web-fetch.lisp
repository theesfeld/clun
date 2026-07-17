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
  (let ((box (list nil))                 ; (car box) ← a socket-close thunk, set by the worker
        (done nil))
    (flet ((settle (thunk) (unless done (setf done t) (funcall thunk)))
           (abort-socket () (when (car box) (funcall (car box)))))
      (lp:worker-submit loop
        (lambda () (net:https-request :host host :port port :method method :path path
                                      :headers headers :body body :host-header host-header
                                      :socket-box box))
        (lambda (result)               ; loop thread
          (settle (lambda ()
                    (if (eq (car result) :ok)
                        (funcall on-response (second result))
                        (funcall on-error (net:tls-error-message (second result))))))))
      (when (and timeout (plusp timeout))
        (lp:set-timer loop timeout
          (lambda () (unless done (abort-socket) (settle (lambda () (funcall on-error "timeout")))))))
      (lambda () (unless done (abort-socket) (settle (lambda () (funcall on-error "abort"))))))))

(defun %do-fetch (g info resolve reject hops)
  (let* ((url-str (getf info :url))
         (record (handler-case (%parse-url url-str)
                   (error () (return-from %do-fetch
                               (eng:js-call reject eng:+undefined+
                                            (list (%fetch-error g "TypeError" (format nil "Failed to parse URL: ~a" url-str)))))))))
    (unless (member (ur-scheme record) '("http" "https") :test #'string=)
      (return-from %do-fetch
        (eng:js-call reject eng:+undefined+
                     (list (%fetch-error g "TypeError" (format nil "fetch: unsupported scheme ~a" (ur-scheme record)))))))
    ;; a GET/HEAD request cannot carry a body (Fetch spec) — reject rather than send it.
    (when (and (member (getf info :method) '("GET" "HEAD") :test #'string=) (getf info :body))
      (return-from %do-fetch
        (eng:js-call reject eng:+undefined+
                     (list (%fetch-error g "TypeError" "fetch: request with GET/HEAD method cannot have a body")))))
    (let* ((signal (getf info :signal))
           (loop (eng:current-loop))
           (https (string= (ur-scheme record) "https"))
           (raw-host (ur-host record))
           (port (or (ur-port record) (if https 443 80)))
           ;; the Host: header is the ORIGIN authority (hostname + non-default port).
           (host-header (if (ur-port record) (format nil "~a:~d" raw-host (ur-port record)) raw-host))
           (path (concatenate 'string (if (plusp (length (ur-path record))) (ur-path record) "/")
                              (if (ur-query record) (concatenate 'string "?" (ur-query record)) "")))
           ;; Both transports resolve off the JS loop. Plain HTTP uses the DNS worker
           ;; plus reactor Happy Eyeballs; HTTPS resolves inside its blocking worker.
           (dial-host raw-host))
      ;; already-aborted?
      (when (and signal (eng:js-truthy (eng:js-get signal "aborted")))
        (return-from %do-fetch
          (eng:js-call reject eng:+undefined+ (list (%abort-reason g signal)))))
      (labels ((on-resp (resp)
                 (let ((loc (net:%header (net:hres-headers resp) "location"))
                       (st (net:hres-status resp)))
                   (cond
                     ((and (%redirect-p st) loc (string= (getf info :redirect) "follow"))
                      (if (>= hops 20)
                          (eng:js-call reject eng:+undefined+
                                       (list (%fetch-error g "TypeError" "fetch: too many redirects")))
                          ;; resolve Location against the current URL and re-fetch (scheme re-dispatched)
                          (let ((next (handler-case (%serialize-url (%parse-url loc record)) (error () nil))))
                            (if next
                                (let ((info2 (copy-list info)))
                                  (setf (getf info2 :url) next)
                                  (when (%redirect-to-get-p st (getf info :method))
                                    (setf (getf info2 :method) "GET" (getf info2 :body) nil
                                          (getf info2 :headers) (%strip-body-headers (getf info :headers))))
                                  (%do-fetch g info2 resolve reject (1+ hops)))
                                (eng:js-call resolve eng:+undefined+ (list (%build-fetch-response resp url-str)))))))
                     ((and (%redirect-p st) (string= (getf info :redirect) "error"))
                      (eng:js-call reject eng:+undefined+ (list (%fetch-error g "TypeError" "fetch: unexpected redirect"))))
                     (t (eng:js-call resolve eng:+undefined+ (list (%build-fetch-response resp url-str)))))))
               (on-err (code)
                 (if (string= code "abort")
                     (eng:js-call reject eng:+undefined+ (list (%abort-reason g signal)))
                     (eng:js-call reject eng:+undefined+
                                  (list (%fetch-error g "TypeError" (format nil "fetch failed: ~a" code)))))))
        (let ((cancel
                (if https
                    (%https-request-async loop :host raw-host :port port :host-header host-header
                      :method (getf info :method) :path path :headers (getf info :headers) :body (getf info :body)
                      :timeout *fetch-connect-timeout-ms* :on-response #'on-resp :on-error #'on-err)
                    (net:http-request-async loop :host dial-host :port port :host-header host-header
                      :method (getf info :method) :path path :headers (getf info :headers) :body (getf info :body)
                      :timeout *fetch-connect-timeout-ms* :on-response #'on-resp :on-error #'on-err))))
          ;; wire the AbortSignal → cancel the in-flight request
          (when signal
            (let ((add (eng:js-get signal "addEventListener")))
              (when (eng:callable-p add)
                (eng:js-call add signal
                             (list "abort" (eng:make-native-function "" 0
                                             (lambda (th a) (declare (ignore th a)) (funcall cancel) eng:+undefined+))))))))))))

(defun %abort-reason (g signal)
  (let ((r (and signal (eng:js-get signal "reason"))))
    (if (and r (eng:js-object-p r)) r (%fetch-error g "AbortError" "The operation was aborted"))))

(defun install-fetch (realm)
  (let ((eng:*realm* realm) (g (eng:realm-global realm)))
    (eng:install-method g "fetch" 2
      (lambda (this args) (declare (ignore this))
        (let ((info (%fetch-normalize (eng:arg args 0) (eng:arg args 1)))
              (promise-ctor (eng:js-get g "Promise")))
          (eng:js-construct promise-ctor
            (list (eng:make-native-function "" 2
                    (lambda (th a) (declare (ignore th))
                      (%do-fetch g info (eng:arg a 0) (eng:arg a 1) 0)
                      eng:+undefined+)))))))))
