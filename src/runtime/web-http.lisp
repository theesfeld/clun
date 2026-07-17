;;;; web-http.lisp -- branded Headers / Request / Response runtime objects.

(in-package :clun.runtime)

;;; Runtime-owned slots are deliberately not JavaScript properties.  Prototype
;;; spoofing therefore cannot forge a Headers, Request, or Response brand.

(defstruct (js-headers
            (:include eng:js-object (class :headers))
            (:constructor %make-js-headers))
  (store '() :type list))

(defstruct (js-headers-iterator
            (:include eng:js-object (class :headers-iterator))
            (:constructor %make-js-headers-iterator))
  headers
  (kind :entries)
  (cursor 0 :type (integer 0 *))
  (done-p nil))

(defstruct (js-request
            (:include eng:js-object (class :request))
            (:constructor %make-js-request))
  (headers-alist '() :type list)
  (body #() :type vector)
  headers-object)

(defstruct (js-server-request
            (:include js-request (class :server-request))
            (:constructor %make-js-server-request))
  context
  cookie-cache
  (cookie-cache-initialized-p nil))

(defstruct (js-response
            (:include eng:js-object (class :response))
            (:constructor %make-js-response))
  body)

(defstruct (js-blob
            (:include eng:js-object (class :blob))
            (:constructor %make-js-blob))
  (bytes (make-array 0 :element-type '(unsigned-byte 8)) :type vector)
  (type "" :type string))

(defstruct (web-http-realm-state
            (:constructor %make-web-http-realm-state))
  headers-constructor
  headers-prototype
  headers-iterator-prototype
  request-constructor
  request-prototype
  server-request-prototype
  blob-constructor
  blob-prototype
  response-constructor
  response-prototype)

(defvar *web-http-realm-states*
  (make-hash-table :test #'eq :weakness :key))

(defun %http-state (&optional (realm eng:*realm*))
  (or (gethash realm *web-http-realm-states*)
      (error "The web HTTP runtime is not installed in this realm")))

(defun obj-hidden (object key)
  "Compatibility reader for unrelated legacy runtime objects.

Headers, Request, Response, and cookie state never use this mechanism."
  (let ((descriptor (and (eng:js-object-p object)
                         (eng:obj-own-desc object key))))
    (and descriptor (eng:pd-value descriptor))))

;;; --- shared property helpers ------------------------------------------------

(defun %define-data (object key value &key (writable t) (enumerable nil)
                                        (configurable t))
  (eng::obj-set-desc object key
                     (eng::data-pd value :writable writable
                                         :enumerable enumerable
                                         :configurable configurable))
  value)

(defun %define-accessor (object key getter setter
                         &key (enumerable nil) (configurable t))
  (eng::obj-set-desc
   object key
   (eng::accessor-pd
    (eng:make-native-function (format nil "get ~a" key) 0 getter)
    (if setter
        (eng:make-native-function (format nil "set ~a" key) 1 setter)
        eng:+undefined+)
    :enumerable enumerable :configurable configurable)))

(defun %install-prototype-method (prototype name arity function
                                  &key (enumerable nil) (configurable t))
  (let ((method (eng:make-native-function name arity function)))
    (%define-data prototype name method :writable t
                                        :enumerable enumerable
                                        :configurable configurable)
    method))

(defun %set-constructor-prototype (constructor prototype)
  (%define-data constructor "prototype" prototype
                :writable nil :enumerable nil :configurable nil)
  (%define-data prototype "constructor" constructor
                :writable t :enumerable nil :configurable t))

(defun %error-with-code (kind message code)
  (let ((error (eng:make-error-object
                (ecase kind
                  (:type-error :type-error-prototype)
                  (:range-error :range-error-prototype))
                (ecase kind
                  (:type-error "TypeError")
                  (:range-error "RangeError"))
                message)))
    (when code (eng:js-set error "code" code nil))
    (eng:throw-js-value error)))

;;; --- Headers ----------------------------------------------------------------

(defun %ascii-http-token-character-p (character)
  (let ((code (char-code character)))
    (or (<= (char-code #\0) code (char-code #\9))
        (<= (char-code #\A) code (char-code #\Z))
        (<= (char-code #\a) code (char-code #\z))
        (find character "!#$%&'*+-.^_`|~" :test #'char=))))

(defun %ascii-ows-trim (string)
  (string-trim '(#\Space #\Tab) string))

(defun %hdr-normalize (value)
  (let ((name (eng:to-string value)))
    (unless (and (plusp (length name))
                 (every #'%ascii-http-token-character-p name))
      (eng:throw-type-error "Invalid HTTP header name"))
    (string-downcase name)))

(defun %byte-string (value error-message)
  (let ((string (eng:to-string value)))
    (unless (every (lambda (character)
                     (let ((code (char-code character)))
                       (and (<= code #xff)
                            (not (member code '(0 10 13))))))
                   string)
      (eng:throw-type-error error-message))
    string))

(defun %hdr-value (value)
  (%ascii-ows-trim (%byte-string value "Invalid HTTP header value")))

(defun %require-headers (value)
  (if (js-headers-p value)
      value
      (eng:throw-type-error "Illegal invocation")))

(defun %headers-store (headers)
  "Return the private ordered store for a genuinely branded Headers object."
  (js-headers-store (%require-headers headers)))

(defun %header-values (headers name)
  (loop for (stored-name . value) in (js-headers-store headers)
        when (string= stored-name name)
          collect value))

(defun %join-header-values (name values)
  (format nil (if (string= name "cookie") "~{~a~^; ~}" "~{~a~^, ~}")
          values))

(defun %headers-iteration-alist (headers)
  "Fetch iteration view: sorted merged fields, then distinct Set-Cookie fields."
  (let* ((store (js-headers-store (%require-headers headers)))
         (ordinary-names
           (sort (remove-duplicates
                  (loop for (name . nil) in store
                        unless (string= name "set-cookie") collect name)
                  :test #'string=)
                 #'string<))
         (ordinary
           (loop for name in ordinary-names
                 collect (cons name
                               (%join-header-values
                                name
                                (loop for (stored-name . value) in store
                                      when (string= name stored-name)
                                        collect value)))))
         (set-cookies
           (loop for (name . value) in store
                 when (string= name "set-cookie")
                   collect (cons name value))))
    (nconc ordinary set-cookies)))

(defun %headers-sorted-merged (headers-or-box)
  "Compatibility name for the public Headers iteration view."
  (cond ((js-headers-p headers-or-box)
         (%headers-iteration-alist headers-or-box))
        ;; Old callers occasionally passed a one-element alist box.  Preserve
        ;; their data shape without reintroducing it as a public-object store.
        ((and (consp headers-or-box) (listp (car headers-or-box)))
         (let ((headers (%new-headers (car headers-or-box))))
           (%headers-iteration-alist headers)))
        (t '())))

(defun %headers-alist (headers)
  "Return a fresh transport view, retaining each Set-Cookie field."
  (copy-tree (%headers-iteration-alist headers)))

(defun %headers-raw-alist (headers)
  "Return a fresh exact ordered-pair copy for fetch/server transport code."
  (copy-tree (js-headers-store (%require-headers headers))))

(defun %headers-put (headers name value)
  (setf (js-headers-store headers)
        (nconc (js-headers-store headers) (list (cons name value)))))

(defun %headers-set (headers name value)
  ;; Conversion and validation complete before the first mutation.
  (let ((normalized-name (%hdr-normalize name))
        (normalized-value (%hdr-value value)))
    (setf (js-headers-store headers)
          (remove normalized-name (js-headers-store headers)
                  :key #'car :test #'string=))
    (%headers-put headers normalized-name normalized-value)))

(defun %headers-append (headers name value)
  (let ((normalized-name (%hdr-normalize name))
        (normalized-value (%hdr-value value)))
    (%headers-put headers normalized-name normalized-value)))

(defun %headers-convert-sequence-init (init iterator-method)
  "Materialize HeadersInit's nested sequence before validating any row."
  (let ((outer (eng:get-iterator-record init iterator-method))
        (rows '()))
    (loop
      (multiple-value-bind (pair done-p)
          (eng:iterator-step-value outer)
        (when done-p (return (nreverse rows)))
        (push
         (eng:call-with-iterator-close-on-abrupt
          outer
          (lambda ()
            (unless (eng:js-object-p pair)
              (%error-with-code :type-error "Value is not a sequence"
                                "ERR_INVALID_ARG_TYPE"))
            (let ((inner-method
                    (eng:get-method pair (eng:well-known :iterator))))
              (when (eng:js-undefined-p inner-method)
                (eng:throw-type-error "Type error"))
              (let ((inner (eng:get-iterator-record pair inner-method))
                    (row '()))
                (loop
                  ;; A failing iterator step is already terminal.  Only an
                  ;; abrupt conversion of a yielded value closes this inner
                  ;; iterator; the enclosing guard still closes OUTER.
                  (multiple-value-bind (item item-done-p)
                      (eng:iterator-step-value inner)
                    (when item-done-p (return (nreverse row)))
                    (push
                     (eng:call-with-iterator-close-on-abrupt
                      inner (lambda () (eng:to-string item)))
                     row)))))))
         rows)))))

(defun %headers-convert-record-init (init)
  "Snapshot keys and convert every currently enumerable string value first."
  (let ((entries '()))
    (dolist (key (eng:jm-own-property-keys init) (nreverse entries))
      (when (stringp key)
        (let ((descriptor (eng:jm-get-own-property init key)))
          (when (and descriptor (eq (eng:pd-enumerable descriptor) t))
            (push (cons key (eng:to-string (eng:js-getv init key)))
                  entries)))))))

(defun %copy-headers-init-into (target init)
  (cond
    ((or (null init) (eng:js-undefined-p init)) target)
    ((js-headers-p init)
     (setf (js-headers-store target) (copy-tree (js-headers-store init)))
     target)
    ((eng:js-object-p init)
     (let ((iterator-method
             (eng:get-method init (eng:well-known :iterator))))
       (if (eng:js-undefined-p iterator-method)
           (dolist (entry (%headers-convert-record-init init) target)
             (%headers-put target (%hdr-normalize (car entry))
                           (%hdr-value (cdr entry))))
           (dolist (row (%headers-convert-sequence-init init iterator-method)
                        target)
             (unless (= (length row) 2)
               (eng:throw-type-error
                "Header sub-sequence must contain exactly two items"))
             (%headers-put target (%hdr-normalize (first row))
                           (%hdr-value (second row)))))))
    (t (eng:throw-type-error "Type error"))))

(defun %new-headers (&optional init)
  (let* ((state (%http-state))
         (headers (%make-js-headers
                   :proto (web-http-realm-state-headers-prototype state)
                   :store '())))
    (cond
      ;; CL ordered alists are used only by trusted network/runtime callers.
      ((and (listp init)
            (every (lambda (entry)
                     (and (consp entry) (stringp (car entry))
                          (stringp (cdr entry))))
                   init))
       (dolist (entry init headers)
         (%headers-put headers (%hdr-normalize (car entry))
                       (%hdr-value (cdr entry)))))
      (t (%copy-headers-init-into headers init)))))

(defun %coerce-headers-init (init)
  "Convert a JavaScript HeadersInit into a fresh ordered raw alist."
  (%headers-raw-alist (%new-headers init)))

(defun %headers-iterator (headers kind)
  (%make-js-headers-iterator
   :proto (web-http-realm-state-headers-iterator-prototype (%http-state))
   :headers headers :kind kind :cursor 0))

(defun %headers-iterator-result (iterator)
  (let ((result (eng:new-object)))
    (if (js-headers-iterator-done-p iterator)
        (progn
          (eng:create-data-property result "value" eng:+undefined+)
          (eng:create-data-property result "done" eng:+true+))
        (let* ((pairs
                 (%headers-iteration-alist
                  (js-headers-iterator-headers iterator)))
               (index (js-headers-iterator-cursor iterator))
               (pair (nth index pairs)))
          (if pair
              (progn
                (incf (js-headers-iterator-cursor iterator))
                (eng:create-data-property
                 result "value"
                 (ecase (js-headers-iterator-kind iterator)
                   (:entries (eng:new-array (list (car pair) (cdr pair))))
                   (:keys (car pair))
                   (:values (cdr pair))))
                (eng:create-data-property result "done" eng:+false+))
              (progn
                (setf (js-headers-iterator-done-p iterator) t)
                (eng:create-data-property result "value" eng:+undefined+)
                (eng:create-data-property result "done" eng:+true+)))))
    result))

(defun %install-headers-iterator-prototype (prototype)
  (%install-prototype-method
   prototype "next" 0
   (lambda (this args)
     (declare (ignore args))
     (unless (js-headers-iterator-p this)
       (%error-with-code :type-error
                         "Cannot call next() on a non-Iterator object"
                         "ERR_INVALID_THIS"))
     (%headers-iterator-result this)))
  (%define-data prototype (eng:well-known :to-string-tag) "Headers Iterator"
                :writable nil :enumerable nil :configurable t)
  prototype)

(defun %install-headers-prototype (prototype)
  (%install-prototype-method
   prototype "get" 1
   (lambda (this args)
     (let ((headers (%require-headers this)))
       (when (null args)
         (%error-with-code :type-error "Not enough arguments" "ERR_MISSING_ARGS"))
       (let* ((name (%hdr-normalize (eng:arg args 0)))
              (values (%header-values headers name)))
         (if values (%join-header-values name values) eng:+null+)))))
  (%install-prototype-method
   prototype "has" 1
   (lambda (this args)
     (let ((headers (%require-headers this)))
       (when (null args)
         (%error-with-code :type-error "Not enough arguments" "ERR_MISSING_ARGS"))
       (let ((name (%hdr-normalize (eng:arg args 0))))
         (eng:js-boolean (not (null (%header-values headers name))))))))
  (%install-prototype-method
   prototype "set" 2
   (lambda (this args)
     (let ((headers (%require-headers this)))
       (when (< (length args) 2)
         (%error-with-code :type-error "Not enough arguments" "ERR_MISSING_ARGS"))
       (%headers-set headers (eng:arg args 0) (eng:arg args 1)))
     eng:+undefined+))
  (%install-prototype-method
   prototype "append" 2
   (lambda (this args)
     (let ((headers (%require-headers this)))
       (when (< (length args) 2)
         (%error-with-code :type-error "Not enough arguments" "ERR_MISSING_ARGS"))
       (%headers-append headers (eng:arg args 0) (eng:arg args 1)))
     eng:+undefined+))
  (%install-prototype-method
   prototype "delete" 1
   (lambda (this args)
     (let ((headers (%require-headers this)))
       (when (null args)
         (%error-with-code :type-error "Not enough arguments" "ERR_MISSING_ARGS"))
       (let ((name (%hdr-normalize (eng:arg args 0))))
         (setf (js-headers-store headers)
               (remove name (js-headers-store headers)
                       :key #'car :test #'string=))))
     eng:+undefined+))
  (%install-prototype-method
   prototype "forEach" 1
   (lambda (this args)
     (let ((headers (%require-headers this))
           (callback (eng:arg args 0))
           (this-arg (eng:arg args 1)))
       (unless (eng:callable-p callback)
         (eng:throw-type-error "Cannot call callback on a non-function"))
       (loop with cursor = 0
             for pair = (nth cursor (%headers-iteration-alist headers))
             while pair
             do (incf cursor)
                (eng:js-call callback this-arg
                             (list (cdr pair) (car pair) headers))))
     eng:+undefined+))
  (let ((entries
          (%install-prototype-method
           prototype "entries" 0
           (lambda (this args) (declare (ignore args))
             (%headers-iterator (%require-headers this) :entries)))))
    (%install-prototype-method
     prototype "keys" 0
     (lambda (this args) (declare (ignore args))
       (%headers-iterator (%require-headers this) :keys)))
    (%install-prototype-method
     prototype "values" 0
     (lambda (this args) (declare (ignore args))
       (%headers-iterator (%require-headers this) :values)))
    (%install-prototype-method
     prototype "getAll" 1
     (lambda (this args)
       (let ((headers (%require-headers this)))
         (when (null args)
           (%error-with-code :type-error "Missing argument" nil))
         (let ((name (%hdr-normalize (eng:arg args 0))))
           (unless (string= name "set-cookie")
             (eng:throw-type-error "Only \"set-cookie\" is supported."))
           (eng:new-array (copy-list (%header-values headers name))))))
     :enumerable t)
    (%install-prototype-method
     prototype "getSetCookie" 0
     (lambda (this args) (declare (ignore args))
       (eng:new-array
        (copy-list (%header-values (%require-headers this) "set-cookie"))))
     :enumerable t)
    (%define-data prototype (eng:well-known :iterator) entries
                  :writable t :enumerable nil :configurable t))
  prototype)

;;; --- Request ----------------------------------------------------------------

(defun %body-text-decode (octets)
  (handler-case
      (sb-ext:octets-to-string
       octets :external-format '(:utf-8 :replacement #\Replacement_Character))
    (error ()
      (map 'string (lambda (byte) (code-char (logand byte #xff))) octets))))

(defun %require-request (value)
  (if (js-request-p value)
      value
      (eng:throw-type-error "Illegal invocation")))

(defun %request-body-value (request)
  (js-request-body (%require-request request)))

(defun %req-body (request)
  (or (%request-body-value request)
      (make-array 0 :element-type '(unsigned-byte 8))))

(defun %request-headers-object (request)
  (let ((request (%require-request request)))
    (or (js-request-headers-object request)
        (setf (js-request-headers-object request)
              (%new-headers (js-request-headers-alist request))))))

(defun %install-body-methods (prototype require-function body-function)
  (let ((global (eng:realm-global eng:*realm*)))
    (%install-prototype-method
     prototype "text" 0
     (lambda (this args) (declare (ignore args))
       (funcall require-function this)
       (%resolved-promise global
                          (%body-text-decode (funcall body-function this)))))
    (%install-prototype-method
     prototype "bytes" 0
     (lambda (this args) (declare (ignore args))
       (funcall require-function this)
       (%resolved-promise global
                          (eng:u8-from-octets (funcall body-function this)))))
    (%install-prototype-method
     prototype "arrayBuffer" 0
     (lambda (this args) (declare (ignore args))
       (funcall require-function this)
       (%resolved-promise
        global
        (eng:js-get (eng:u8-from-octets (funcall body-function this)) "buffer"))))
    (%install-prototype-method
     prototype "json" 0
     (lambda (this args) (declare (ignore args))
       (funcall require-function this)
       (let ((json (eng:js-get global "JSON")))
         (%resolved-promise
          global
          (eng:js-call (eng:js-get json "parse") json
                       (list (%body-text-decode
                              (funcall body-function this))))))))))

(defun %install-request-prototype (prototype)
  (%install-body-methods prototype #'%require-request #'%req-body)
  (%define-accessor
   prototype "headers"
   (lambda (this args) (declare (ignore args))
     (%request-headers-object this))
   nil)
  prototype)

(defun %request-prototype (&optional ignored)
  (declare (ignore ignored))
  (web-http-realm-state-request-prototype (%http-state)))

(defun %allocate-request (server-p method url headers-alist body-octets
                          &optional context)
  (let* ((state (%http-state))
         (prototype (if server-p
                        (web-http-realm-state-server-request-prototype state)
                        (web-http-realm-state-request-prototype state)))
         (request
           (if server-p
               (%make-js-server-request
                :proto prototype :headers-alist (copy-tree headers-alist)
                :body body-octets :context context)
               (%make-js-request
                :proto prototype :headers-alist (copy-tree headers-alist)
                :body body-octets))))
    (eng:data-prop request "method" method)
    (eng:data-prop request "url" url)
    request))

(defun %make-client-request (method url headers-alist body-octets)
  (%allocate-request nil method url headers-alist body-octets))

(defun %request-input-url (input)
  (cond
    ((js-request-p input)
     (eng:to-string (eng:js-get input "url")))
    ((eng:js-object-p input)
     (let ((url (eng:js-get input "url")))
       (if (eng:js-undefined-p url)
           (eng:to-string input)
           (eng:to-string url))))
    (t (eng:to-string input))))

(defun %make-server-request (method url headers-alist body-octets
                             &optional context)
  (%allocate-request t method url headers-alist body-octets context))

(defun %make-request (method url headers-alist body-octets)
  "Compatibility entry used by Clun.serve; server requests get the private subtype."
  (%make-server-request method url headers-alist body-octets))

(defun %server-request-prototype ()
  (web-http-realm-state-server-request-prototype (%http-state)))

;;; --- Blob -------------------------------------------------------------------

(defun %require-blob (value)
  (if (js-blob-p value)
      value
      (eng:throw-type-error "Illegal invocation")))

(defun %blob-part-octets (part)
  (cond
    ((js-blob-p part) (copy-seq (js-blob-bytes part)))
    ((eng:js-typed-array-p part)
     (multiple-value-bind (vector offset length) (eng:ta-octets part)
       (subseq vector offset (+ offset length))))
    ((eng:js-array-buffer-p part)
     (copy-seq (eng:js-array-buffer-bytes part)))
    (t (eng:code-units->utf8 (eng:to-string part)))))

(defun %blob-parts-octets (parts)
  (cond
    ((eng:js-undefined-p parts)
     (make-array 0 :element-type '(unsigned-byte 8)))
    ((not (eng:js-array-p parts))
     (eng:throw-type-error "Blob parts must be an Array"))
    (t
     (let ((chunks '())
           (size 0))
       (dotimes (index (eng:array-length parts))
         (let ((chunk (%blob-part-octets
                       (eng:js-getv parts (princ-to-string index)))))
           (incf size (length chunk))
           (push chunk chunks)))
       (let ((bytes (make-array size :element-type '(unsigned-byte 8)))
             (offset 0))
         (dolist (chunk (nreverse chunks) bytes)
           (replace bytes chunk :start1 offset)
           (incf offset (length chunk))))))))

(defun %blob-type-option (options)
  (if (eng:js-object-p options)
      (let ((value (eng:js-get options "type")))
        (if (eng:js-undefined-p value)
            ""
            (let ((type (eng:to-string value)))
              (if (every (lambda (character)
                           (<= #x20 (char-code character) #x7e))
                         type)
                  (string-downcase type)
                  ""))))
      ""))

(defun %new-blob (parts options)
  (%make-js-blob
   :proto (web-http-realm-state-blob-prototype (%http-state))
   :bytes (%blob-parts-octets parts)
   :type (%blob-type-option options)))

(defun %blob-response-content-type (blob)
  (let ((type (js-blob-type blob)))
    (cond
      ((zerop (length type)) nil)
      ((and (>= (length type) 5)
            (string= "text/" type :end2 5)
            (null (search "charset=" type :test #'char-equal)))
       (concatenate 'string type ";charset=utf-8"))
      (t type))))

(defun %install-blob-prototype (prototype)
  (%define-accessor
   prototype "size"
   (lambda (this args)
     (declare (ignore args))
     (coerce (length (js-blob-bytes (%require-blob this))) 'double-float))
   nil)
  (%define-accessor
   prototype "type"
   (lambda (this args)
     (declare (ignore args))
     (js-blob-type (%require-blob this)))
   nil)
  (let ((global (eng:realm-global eng:*realm*)))
    (%install-prototype-method
     prototype "text" 0
     (lambda (this args)
       (declare (ignore args))
       (%resolved-promise
        global (%body-text-decode
                (copy-seq (js-blob-bytes (%require-blob this)))))))
    (%install-prototype-method
     prototype "bytes" 0
     (lambda (this args)
       (declare (ignore args))
       (%resolved-promise
        global (eng:u8-from-octets
                (copy-seq (js-blob-bytes (%require-blob this)))))))
    (%install-prototype-method
     prototype "arrayBuffer" 0
     (lambda (this args)
       (declare (ignore args))
       (%resolved-promise
        global
        (eng:js-get
         (eng:u8-from-octets
          (copy-seq (js-blob-bytes (%require-blob this))))
         "buffer")))))
  (%define-data prototype (eng:well-known :to-string-tag) "Blob"
                :writable nil :enumerable nil :configurable t)
  prototype)

;;; --- Response ---------------------------------------------------------------

(defun %status-text (code)
  (case code
    (200 "OK") (201 "Created") (204 "No Content")
    (206 "Partial Content")
    (301 "Moved Permanently") (302 "Found") (304 "Not Modified")
    (400 "Bad Request") (401 "Unauthorized") (403 "Forbidden")
    (404 "Not Found") (405 "Method Not Allowed")
    (416 "Range Not Satisfiable")
    (413 "Payload Too Large") (431 "Request Header Fields Too Large")
    (500 "Internal Server Error") (503 "Service Unavailable")
    (t "")))

(defun %require-response (value)
  (if (js-response-p value)
      value
      (eng:throw-type-error "Illegal invocation")))

(defun %response-object-p (value)
  (js-response-p value))

(defun %body->octets (body)
  (cond
    ((or (null body) (eng:js-undefined-p body) (eng:js-null-p body))
     (make-array 0 :element-type '(unsigned-byte 8)))
    ((eng:js-string-p body) (eng:code-units->utf8 (eng:to-string body)))
    ((eng:js-typed-array-p body)
     (multiple-value-bind (vector offset length) (eng:ta-octets body)
       (subseq vector offset (+ offset length))))
    ((eng:js-array-buffer-p body)
     (copy-seq (eng:js-array-buffer-bytes body)))
    ((js-blob-p body)
     (copy-seq (js-blob-bytes body)))
    ((js-clun-file-p body)
     (handler-case
         (%clun-file-octets body)
       (error () (make-array 0 :element-type '(unsigned-byte 8)))))
    (t (eng:code-units->utf8 (eng:to-string body)))))

(defun %response-body-value (response)
  (js-response-body (%require-response response)))

(defun %response-body-vector (response)
  (%body->octets (%response-body-value response)))

(defun %install-response-prototype (prototype)
  (%install-body-methods prototype #'%require-response #'%response-body-vector)
  prototype)

(defun %init-response (object body init)
  "Populate and return a branded Response.  OBJECT is retained for old CL callers
but an ordinary object is never promoted into the Response brand."
  (let* ((state (%http-state))
         (response
           (if (js-response-p object)
               object
               (%make-js-response
                :proto (web-http-realm-state-response-prototype state))))
         (init-object-p (eng:js-object-p init))
         (status-value (and init-object-p (eng:js-get init "status")))
         (status (if (eng:js-number-p status-value)
                     (truncate (eng:to-number status-value))
                     200))
         (status-text-value
           (and init-object-p (eng:js-get init "statusText")))
         (status-text
           (if (and status-text-value
                    (not (eng:js-undefined-p status-text-value)))
               (%byte-string status-text-value "Invalid HTTP status text")
               (%status-text status)))
         (headers-init (and init-object-p (eng:js-get init "headers")))
         (headers (%new-headers headers-init)))
    (when (and (js-blob-p body)
               (null (%header-values headers "content-type")))
      (let ((content-type (%blob-response-content-type body)))
        (when content-type
          (%headers-set headers "content-type" content-type))))
    (setf (js-response-body response) body)
    (eng:data-prop response "status" (coerce status 'double-float))
    (eng:data-prop response "statusText" status-text)
    (eng:data-prop response "ok"
                   (eng:js-boolean (and (>= status 200) (< status 300))))
    (eng:data-prop response "headers" headers)
    response))

(defun %new-response (body init)
  (%init-response nil body init))

(defun %response-body-octets (response)
  "Return (values octets default-content-type) for a real Response."
  (let ((body (%response-body-value response)))
    (values (%body->octets body)
            (when (eng:js-string-p body) "text/plain;charset=utf-8"))))

;;; --- installation -----------------------------------------------------------

(defun %make-headers-constructor (prototype)
  (let ((constructor
          (eng:make-native-function
           "Headers" 1
           (lambda (this args)
             (declare (ignore this args))
             (eng:throw-type-error "Headers requires 'new'"))
           :construct
           (lambda (args new-target)
             (declare (ignore new-target))
             (%new-headers (eng:arg args 0))))))
    (%set-constructor-prototype constructor prototype)
    constructor))

(defun %make-request-constructor (prototype)
  (let ((constructor
          (eng:make-native-function
           "Request" 2
           (lambda (this args)
             (declare (ignore this args))
             (eng:throw-type-error "Request requires 'new'"))
           :construct
           (lambda (args new-target)
             (declare (ignore new-target))
             (let* ((url (%request-input-url (eng:arg args 0)))
                    (init (eng:arg args 1))
                    (init-object-p (eng:js-object-p init))
                    (method-value (and init-object-p
                                       (eng:js-get init "method")))
                    (method (if (eng:js-string-p method-value)
                                (string-upcase (eng:to-string method-value))
                                "GET"))
                    (headers-init (and init-object-p
                                       (eng:js-get init "headers")))
                    (body (and init-object-p (eng:js-get init "body"))))
               (%make-client-request
                method url (%coerce-headers-init headers-init)
                (%body->octets body)))))))
    (%set-constructor-prototype constructor prototype)
    constructor))

(defun %make-blob-constructor (prototype)
  (let ((constructor
          (eng:make-native-function
           "Blob" 0
           (lambda (this args)
             (declare (ignore this args))
             (eng:throw-type-error "Blob requires 'new'"))
           :construct
           (lambda (args new-target)
             (declare (ignore new-target))
             (%new-blob (eng:arg args 0) (eng:arg args 1))))))
    (%set-constructor-prototype constructor prototype)
    constructor))

(defun %make-response-constructor (prototype)
  (let ((constructor
          (eng:make-native-function
           "Response" 2
           (lambda (this args)
             (declare (ignore this args))
             (eng:throw-type-error "Response requires 'new'"))
           :construct
           (lambda (args new-target)
             (declare (ignore new-target))
             (%new-response (eng:arg args 0) (eng:arg args 1))))))
    (%set-constructor-prototype constructor prototype)
    (%install-prototype-method
     constructor "json" 2
     (lambda (this args)
       (declare (ignore this))
       (let* ((global (eng:realm-global eng:*realm*))
              (json (eng:js-get global "JSON"))
              (string
                (eng:to-string
                 (eng:js-call (eng:js-get json "stringify") json
                              (list (eng:arg args 0)))))
              (response (%new-response string (eng:arg args 1)))
              (headers (eng:js-get response "headers")))
         (unless (eng:js-truthy
                  (eng:js-call (eng:js-get headers "has") headers
                               (list "content-type")))
           (eng:js-call (eng:js-get headers "set") headers
                        (list "content-type"
                              "application/json;charset=utf-8")))
         response)))
    (%install-prototype-method
     constructor "redirect" 2
     (lambda (this args)
       (declare (ignore this))
       (let* ((url (eng:to-string (eng:arg args 0)))
              (status-value (eng:arg args 1))
              (status (if (eng:js-undefined-p status-value)
                          302
                          (truncate (eng:to-number status-value)))))
         (unless (member status '(301 302 303 307 308))
           (eng:throw-range-error "Invalid redirect status code"))
         (let ((init (eng:new-object))
               (headers (eng:new-object)))
           (eng:data-prop init "status" (coerce status 'double-float))
           (eng:data-prop headers "Location" url)
           (eng:data-prop init "headers" headers)
           (%new-response eng:+null+ init)))))
    constructor))

(defun install-web-http (realm)
  (let ((eng:*realm* realm)
        (global (eng:realm-global realm)))
    (or (gethash realm *web-http-realm-states*)
        (let* ((headers-prototype (eng:new-object))
               (headers-iterator-prototype
                 (eng:js-make-object (eng:intrinsic :iterator-prototype)))
               (request-prototype (eng:new-object))
               (server-request-prototype
                 (eng:js-make-object request-prototype))
               (blob-prototype (eng:new-object))
               (response-prototype (eng:new-object))
               (state
                 (%make-web-http-realm-state
                  :headers-prototype headers-prototype
                  :headers-iterator-prototype headers-iterator-prototype
                  :request-prototype request-prototype
                  :server-request-prototype server-request-prototype
                  :blob-prototype blob-prototype
                  :response-prototype response-prototype)))
          ;; Install state before helpers allocate branded instances.
          (setf (gethash realm *web-http-realm-states*) state)
          (%install-headers-prototype headers-prototype)
          (%install-headers-iterator-prototype headers-iterator-prototype)
          (%install-request-prototype request-prototype)
          (%install-blob-prototype blob-prototype)
          (%install-response-prototype response-prototype)
          (setf (web-http-realm-state-headers-constructor state)
                (%make-headers-constructor headers-prototype)
                (web-http-realm-state-request-constructor state)
                (%make-request-constructor request-prototype)
                (web-http-realm-state-blob-constructor state)
                (%make-blob-constructor blob-prototype)
                (web-http-realm-state-response-constructor state)
                (%make-response-constructor response-prototype))
          state))
    (let ((state (%http-state realm)))
      (eng:hidden-prop global "Headers"
                       (web-http-realm-state-headers-constructor state))
      (eng:hidden-prop global "Request"
                       (web-http-realm-state-request-constructor state))
      (eng:hidden-prop global "Blob"
                       (web-http-realm-state-blob-constructor state))
      (eng:hidden-prop global "Response"
                       (web-http-realm-state-response-constructor state)))
    realm))
