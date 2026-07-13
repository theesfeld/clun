;;;; web-http.lisp — the Headers / Request / Response web classes (PLAN.md Phase 17,
;;;; §3.6), built in CL against the engine object API (no JS in the impl). Installed as
;;;; realm globals; reused by fetch (Phase 18). The HTTP server (clun-serve.lisp) builds
;;;; a Request per parsed request and reads a Response back via the %-helpers here.

(in-package :clun.runtime)

;;; --- Headers (case-insensitive multimap over an ordered alist box) ----------

(defun %hdr-trim (s) (string-trim '(#\Space #\Tab #\Return #\Newline) s))

(defun obj-hidden (o key)
  "Read a hidden CL value stashed on O under KEY (a cons box); NIL if absent."
  (let ((d (eng:obj-own-desc o key)))
    (and d (eng:pd-value d))))

(defun %headers-store (h) (obj-hidden h "%store%"))          ; the box's car holds the alist

(defun %hdr-normalize (name) (string-downcase (%hdr-trim (eng:to-string name))))

(defun %new-headers (&optional init-alist)
  "A JS Headers object backed by a CL alist box (lowercased name . value), so both JS
and the server (CL) can read/mutate it."
  (let* ((box (list (copy-alist (or init-alist '()))))   ; box = (alist); (car box) is the alist
         (h (eng:new-object)))
    (eng:hidden-prop h "%store%" box)
    (labels ((store () (car box))
             (put (name value) (setf (car box) (nconc (store) (list (cons name value)))))
             (find-all (name) (remove name (store) :key #'car :test-not #'string=)))
      (eng:install-method h "get" 1
        (lambda (this args) (declare (ignore this))
          (let* ((n (%hdr-normalize (eng:arg args 0)))
                 (vals (mapcar #'cdr (find-all n))))
            (if vals (format nil "~{~a~^, ~}" vals) eng:+null+))))
      (eng:install-method h "has" 1
        (lambda (this args) (declare (ignore this))
          (eng:js-boolean (and (assoc (%hdr-normalize (eng:arg args 0)) (store) :test #'string=) t))))
      (eng:install-method h "set" 2
        (lambda (this args) (declare (ignore this))
          (let ((n (%hdr-normalize (eng:arg args 0))))
            (setf (car box) (remove n (store) :key #'car :test #'string=))
            (put n (%hdr-trim (eng:to-string (eng:arg args 1)))))
          eng:+undefined+))
      (eng:install-method h "append" 2
        (lambda (this args) (declare (ignore this))
          (put (%hdr-normalize (eng:arg args 0)) (%hdr-trim (eng:to-string (eng:arg args 1))))
          eng:+undefined+))
      (eng:install-method h "delete" 1
        (lambda (this args) (declare (ignore this))
          (setf (car box) (remove (%hdr-normalize (eng:arg args 0)) (store) :key #'car :test #'string=))
          eng:+undefined+))
      (eng:install-method h "forEach" 1
        (lambda (this args)
          (let ((cb (eng:arg args 0)))
            (dolist (pair (%headers-sorted-merged box))
              (eng:js-call cb eng:+undefined+ (list (cdr pair) (car pair) this))))
          eng:+undefined+))
      (flet ((pairs-array () (eng:new-array (mapcar (lambda (p) (eng:new-array (list (car p) (cdr p))))
                                                    (%headers-sorted-merged box))))
             (keys-array () (eng:new-array (mapcar #'car (%headers-sorted-merged box))))
             (vals-array () (eng:new-array (mapcar #'cdr (%headers-sorted-merged box)))))
        (eng:install-method h "entries" 0 (lambda (this args) (declare (ignore this args)) (pairs-array)))
        (eng:install-method h "keys" 0 (lambda (this args) (declare (ignore this args)) (keys-array)))
        (eng:install-method h "values" 0 (lambda (this args) (declare (ignore this args)) (vals-array)))
        ;; @@iterator = entries()'s array iterator (so `for..of headers` works)
        (eng:create-data-property h (eng:well-known :iterator)
          (eng:make-native-function "" 0
            (lambda (this args) (declare (ignore this args))
              (let ((a (pairs-array))) (eng:js-call (eng:js-getv a (eng:well-known :iterator)) a '())))))))
    h))

(defun %headers-sorted-merged (box)
  "The header pairs, duplicate names comma-joined, sorted by name (Fetch iteration order)."
  (let ((names (remove-duplicates (mapcar #'car (car box)) :test #'string= :from-end t)))
    (sort (mapcar (lambda (n)
                    (cons n (format nil "~{~a~^, ~}"
                                    (mapcar #'cdr (remove n (car box) :key #'car :test-not #'string=)))))
                  names)
          #'string< :key #'car)))

(defun %headers-alist (h)
  "Read a Headers object's merged (name . value) pairs from CL (for serialization)."
  (let ((box (%headers-store h)))
    (if box (%headers-sorted-merged box) '())))

(defun %coerce-headers-init (init)
  "A JS headers init (a Headers object, a plain object, or an array of pairs) → an alist."
  (cond
    ((not (eng:js-object-p init)) '())
    ((%headers-store init) (copy-alist (car (%headers-store init))))   ; another Headers
    ((eng:js-array-p init)
     (loop for i below (eng:array-length init)
           for pair = (eng:js-getv init (princ-to-string i))
           when (eng:js-object-p pair)
             collect (cons (%hdr-normalize (eng:js-getv pair "0"))
                           (%hdr-trim (eng:to-string (eng:js-getv pair "1"))))))
    (t (loop for k in (eng:jm-own-property-keys init)
             when (stringp k)
               collect (cons (string-downcase k) (%hdr-trim (eng:to-string (eng:js-getv init k))))))))

;;; --- Request ----------------------------------------------------------------

(defun %req-body (this) (or (obj-hidden this "%body%") (make-array 0 :element-type '(unsigned-byte 8))))

(defun %request-prototype (g)
  "A per-realm cached Request prototype: text/json/arrayBuffer/bytes read THIS's hidden
body, and `headers` is a lazy getter — so building a per-request object is cheap (no
~15 closures each), which is what the throughput gate needs."
  (or (obj-hidden g "%RequestProto%")
      (let ((p (eng:new-object)))
        (eng:install-method p "text" 0
          (lambda (this args) (declare (ignore args))
            (%resolved-promise g (sb-ext:octets-to-string (%req-body this) :external-format :utf-8))))
        (eng:install-method p "bytes" 0
          (lambda (this args) (declare (ignore args)) (%resolved-promise g (eng:u8-from-octets (%req-body this)))))
        (eng:install-method p "arrayBuffer" 0
          (lambda (this args) (declare (ignore args))
            (%resolved-promise g (eng:js-get (eng:u8-from-octets (%req-body this)) "buffer"))))
        (eng:install-method p "json" 0
          (lambda (this args) (declare (ignore args))
            (let ((json (eng:js-get g "JSON")))
              (%resolved-promise g (eng:js-call (eng:js-get json "parse") json
                                                (list (sb-ext:octets-to-string (%req-body this) :external-format :utf-8)))))))
        (eng:install-getter p "headers"
          (lambda (this args) (declare (ignore args))
            (or (obj-hidden this "%headers-obj%")
                (let ((h (%new-headers (obj-hidden this "%headers-alist%"))))
                  (eng:hidden-prop this "%headers-obj%" h) h))))
        (eng:hidden-prop g "%RequestProto%" p)
        p)))

(defun %make-request (method url headers-alist body-octets)
  "A cheap JS Request over the shared prototype: eager method/url, lazy headers + body."
  (let* ((g (eng:realm-global eng:*realm*))
         (o (eng:js-make-object (%request-prototype g))))
    (eng:data-prop o "method" method)
    (eng:data-prop o "url" url)
    (eng:hidden-prop o "%headers-alist%" headers-alist)
    (eng:hidden-prop o "%body%" body-octets)
    o))

;;; --- Response ---------------------------------------------------------------

(defun %status-text (code)
  (case code (200 "OK") (201 "Created") (204 "No Content") (301 "Moved Permanently")
    (302 "Found") (304 "Not Modified") (400 "Bad Request") (401 "Unauthorized")
    (403 "Forbidden") (404 "Not Found") (405 "Method Not Allowed") (413 "Payload Too Large")
    (431 "Request Header Fields Too Large") (500 "Internal Server Error")
    (503 "Service Unavailable") (t "")))

(defun %init-response (o body init)
  "Populate a Response object O from BODY + INIT ({status,statusText,headers})."
  (let* ((status (if (and (eng:js-object-p init) (eng:js-number-p (eng:js-get init "status")))
                     (truncate (eng:to-number (eng:js-get init "status"))) 200))
         (stext (if (and (eng:js-object-p init) (eng:js-string-p (eng:js-get init "statusText")))
                    (eng:to-string (eng:js-get init "statusText")) (%status-text status)))
         (hinit (and (eng:js-object-p init) (eng:js-get init "headers"))))
    (eng:data-prop o "status" (coerce status 'double-float))
    (eng:data-prop o "statusText" stext)
    (eng:data-prop o "ok" (eng:js-boolean (and (>= status 200) (< status 300))))
    (eng:data-prop o "headers" (%new-headers (%coerce-headers-init hinit)))
    (eng:hidden-prop o "%body%" body)
    o))

(defun %body->octets (body)
  "A Request/Response body init → an octet vector. string→utf8, typed-array/ArrayBuffer
→bytes, Clun.file→read fully, null/undefined→empty, anything else→utf8 of its string.
Shared by the Request constructor AND the Response serializer (so they never diverge)."
  (cond
    ((or (null body) (eng:js-undefined-p body) (eng:js-null-p body))
     (make-array 0 :element-type '(unsigned-byte 8)))
    ((eng:js-string-p body) (eng:code-units->utf8 (eng:to-string body)))
    ((eng:js-typed-array-p body)
     (multiple-value-bind (v o l) (eng:ta-octets body) (subseq v o (+ o l))))
    ((eng:js-array-buffer-p body) (copy-seq (eng:js-array-buffer-bytes body)))
    ((and (eng:js-object-p body) (eng:js-string-p (eng:js-get body "name")))  ; a Clun.file
     (handler-case (clun.sys:read-file-octets (eng:to-string (eng:js-get body "name")))
       (error () (make-array 0 :element-type '(unsigned-byte 8)))))
    (t (eng:code-units->utf8 (eng:to-string body)))))

(defun %response-body-octets (resp)
  "(values octets default-content-type) for a Response's body."
  (let ((body (obj-hidden resp "%body%")))
    (values (%body->octets body)
            (when (eng:js-string-p body) "text/plain;charset=utf-8"))))

(defun install-web-http (realm)
  (let ((eng:*realm* realm) (g (eng:realm-global realm)))
    ;; Headers
    (let ((hc (eng:make-native-function "Headers" 1
                (lambda (this args) (declare (ignore this args)) (eng:throw-type-error "Headers requires 'new'"))
                :construct (lambda (args nt) (declare (ignore nt))
                             (%new-headers (%coerce-headers-init (eng:arg args 0)))))))
      (eng:hidden-prop g "Headers" hc))
    ;; Request (constructible: new Request(url, init))
    (let ((rc (eng:make-native-function "Request" 2
                (lambda (this args) (declare (ignore this args)) (eng:throw-type-error "Request requires 'new'"))
                :construct (lambda (args nt) (declare (ignore nt))
                             (let* ((url (eng:to-string (eng:arg args 0)))
                                    (init (eng:arg args 1))
                                    (method (if (and (eng:js-object-p init) (eng:js-string-p (eng:js-get init "method")))
                                                (string-upcase (eng:to-string (eng:js-get init "method"))) "GET"))
                                    (hinit (and (eng:js-object-p init) (eng:js-get init "headers")))
                                    (body (and (eng:js-object-p init) (eng:js-get init "body"))))
                               (%make-request method url (%coerce-headers-init hinit) (%body->octets body)))))))
      (eng:hidden-prop g "Request" rc))
    ;; Response
    (let ((rc (eng:make-native-function "Response" 2
                (lambda (this args) (declare (ignore this args)) (eng:throw-type-error "Response requires 'new'"))
                :construct (lambda (args nt) (declare (ignore nt))
                             (%init-response (eng:new-object) (eng:arg args 0) (eng:arg args 1))))))
      (eng:install-method rc "json" 2
        (lambda (this args) (declare (ignore this))
          (let* ((json (eng:js-get g "JSON"))
                 (str (eng:to-string (eng:js-call (eng:js-get json "stringify") json (list (eng:arg args 0)))))
                 (resp (%init-response (eng:new-object) str (eng:arg args 1))))
            ;; default content-type application/json unless overridden
            (let ((h (eng:js-get resp "headers")))
              (unless (eng:js-truthy (eng:js-call (eng:js-get h "has") h (list "content-type")))
                (eng:js-call (eng:js-get h "set") h (list "content-type" "application/json;charset=utf-8"))))
            resp)))
      (eng:hidden-prop g "Response" rc))))
