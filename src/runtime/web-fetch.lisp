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
    ((eng:js-object-p input)
     (let ((href (eng:js-get input "href")) (url (eng:js-get input "url")))
       (cond ((eng:js-string-p href) (eng:to-string href))
             ((eng:js-string-p url) (eng:to-string url))
             (t (eng:to-string input)))))
    (t (eng:to-string input))))

(defun %fetch-normalize (input init)
  "Return a plist (:url :method :headers alist :body octets :signal :redirect) from
INPUT + INIT (INIT overrides). A Request INPUT contributes method/headers/body."
  (let* ((req-input (and (eng:js-object-p input) (eng:js-string-p (eng:js-get input "url"))
                         (not (eng:js-string-p (eng:js-get input "href"))) input))
         (io (and (eng:js-object-p init) init))
         (method (let ((m (or (and io (eng:js-get init "method"))
                              (and req-input (eng:js-get req-input "method")))))
                   (if (and m (eng:js-string-p m)) (string-upcase (eng:to-string m)) "GET")))
         (headers (append (when req-input (%headers-alist (eng:js-get req-input "headers")))
                          (when (and io (not (eng:js-undefined-p (eng:js-get init "headers"))))
                            (%coerce-headers-init (eng:js-get init "headers")))))
         (body-val (cond ((and io (not (eng:js-undefined-p (eng:js-get init "body")))) (eng:js-get init "body"))
                         (req-input (obj-hidden req-input "%body%"))
                         (t nil)))
         (signal (and io (let ((s (eng:js-get init "signal"))) (and (eng:js-object-p s) s))))
         (redirect (if (and io (eng:js-string-p (eng:js-get init "redirect")))
                       (eng:to-string (eng:js-get init "redirect")) "follow")))
    (list :url (%fetch-url-of input) :method method :headers headers
          :body (if body-val (%body->octets body-val) nil) :signal signal :redirect redirect)))

(defun %build-fetch-response (g resp final-url)
  (let ((u8 (eng:u8-from-octets (net:hres-body resp)))
        (hdrs (eng:new-object)) (init (eng:new-object)))
    (dolist (h (net:hres-headers resp)) (eng:data-prop hdrs (car h) (cdr h)))
    (eng:data-prop init "status" (coerce (net:hres-status resp) 'double-float))
    (eng:data-prop init "statusText" (or (net:hres-reason resp) ""))
    (eng:data-prop init "headers" hdrs)
    (let ((r (eng:js-construct (eng:js-get g "Response") (list u8 init))))
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

(defun %do-fetch (g info resolve reject hops)
  (let* ((url-str (getf info :url))
         (record (handler-case (%parse-url url-str)
                   (error () (return-from %do-fetch
                               (eng:js-call reject eng:+undefined+
                                            (list (%fetch-error g "TypeError" (format nil "Failed to parse URL: ~a" url-str)))))))))
    (unless (member (ur-scheme record) '("http") :test #'string=)
      (return-from %do-fetch
        (eng:js-call reject eng:+undefined+
                     (list (%fetch-error g "TypeError"
                                         (if (string= (ur-scheme record) "https")
                                             "fetch: https is not supported yet (Phase 20)"
                                             (format nil "fetch: unsupported scheme ~a" (ur-scheme record))))))))
    ;; a GET/HEAD request cannot carry a body (Fetch spec) — reject rather than send it.
    (when (and (member (getf info :method) '("GET" "HEAD") :test #'string=) (getf info :body))
      (return-from %do-fetch
        (eng:js-call reject eng:+undefined+
                     (list (%fetch-error g "TypeError" "fetch: request with GET/HEAD method cannot have a body")))))
    (let* ((signal (getf info :signal))
           (loop (eng:current-loop))
           (host (handler-case (net:resolve-hostname (ur-host record))
                   (error () (return-from %do-fetch
                               (eng:js-call reject eng:+undefined+
                                            (list (%fetch-error g "TypeError" "fetch: could not resolve host")))))))
           (port (or (ur-port record) 80))
           ;; the Host: header is the ORIGIN authority (hostname + non-default port), NOT the
           ;; dotted-quad we dial after DNS.
           (host-header (if (ur-port record) (format nil "~a:~d" (ur-host record) (ur-port record)) (ur-host record)))
           (path (concatenate 'string (if (plusp (length (ur-path record))) (ur-path record) "/")
                              (if (ur-query record) (concatenate 'string "?" (ur-query record)) ""))))
      ;; already-aborted?
      (when (and signal (eng:js-truthy (eng:js-get signal "aborted")))
        (return-from %do-fetch
          (eng:js-call reject eng:+undefined+ (list (%abort-reason g signal)))))
      (let ((cancel
              (net:http-request-async loop :host host :port port :host-header host-header
                :method (getf info :method) :path path :headers (getf info :headers) :body (getf info :body)
                :timeout *fetch-connect-timeout-ms*
                :on-response
                (lambda (resp)
                  (let ((loc (net:%header (net:hres-headers resp) "location"))
                        (st (net:hres-status resp)))
                    (cond
                      ((and (%redirect-p st) loc (string= (getf info :redirect) "follow"))
                       (if (>= hops 20)
                           (eng:js-call reject eng:+undefined+
                                        (list (%fetch-error g "TypeError" "fetch: too many redirects")))
                           ;; resolve Location against the current URL and re-fetch
                           (let ((next (handler-case (%serialize-url (%parse-url loc record)) (error () nil))))
                             (if next
                                 (let ((info2 (copy-list info)))
                                   (setf (getf info2 :url) next)
                                   (when (%redirect-to-get-p st (getf info :method))
                                     (setf (getf info2 :method) "GET" (getf info2 :body) nil
                                           (getf info2 :headers) (%strip-body-headers (getf info :headers))))
                                   (%do-fetch g info2 resolve reject (1+ hops)))
                                 (eng:js-call resolve eng:+undefined+ (list (%build-fetch-response g resp url-str)))))))
                      ((and (%redirect-p st) (string= (getf info :redirect) "error"))
                       (eng:js-call reject eng:+undefined+ (list (%fetch-error g "TypeError" "fetch: unexpected redirect"))))
                      (t (eng:js-call resolve eng:+undefined+ (list (%build-fetch-response g resp url-str)))))))
                :on-error
                (lambda (code)
                  (if (string= code "abort")
                      (eng:js-call reject eng:+undefined+ (list (%abort-reason g signal)))
                      (eng:js-call reject eng:+undefined+
                                   (list (%fetch-error g "TypeError" (format nil "fetch failed: ~a" code)))))))))
        ;; wire the AbortSignal → cancel the in-flight request
        (when signal
          (let ((add (eng:js-get signal "addEventListener")))
            (when (eng:callable-p add)
              (eng:js-call add signal
                           (list "abort" (eng:make-native-function "" 0
                                           (lambda (th a) (declare (ignore th a)) (funcall cancel) eng:+undefined+)))))))))))

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
