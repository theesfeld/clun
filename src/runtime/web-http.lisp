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
  (body-used-p nil)
  headers-object
  body-stream)

(defstruct (js-server-request
            (:include js-request (class :server-request))
            (:constructor %make-js-server-request))
  context
  cookie-cache
  (cookie-cache-initialized-p nil))

(defstruct (js-response
            (:include eng:js-object (class :response))
            (:constructor %make-js-response))
  body
  (body-used-p nil)
  body-stream
  (body-null-p nil))

(defstruct (js-body-stream
            (:include eng:js-object (class :readable-stream))
            (:constructor %make-js-body-stream))
  (queue '())
  queue-tail
  (queued-bytes 0 :type (integer 0 *))
  (pending '())
  pending-tail
  collector
  (closed-p nil)
  (errored-p nil)
  error
  (locked-p nil)
  (disturbed-p nil)
  cancel
  pause
  resume
  (backpressured-p nil)
  (high-water (* 1024 1024) :type (integer 1 *))
  (low-water (* 512 1024) :type (integer 0 *))
  terminal-callback
  tee-targets)

(defstruct (js-body-reader
            (:include eng:js-object (class :readable-stream-reader))
            (:constructor %make-js-body-reader))
  stream
  (released-p nil))

(defstruct (body-read-request (:constructor %make-body-read-request))
  reader resolve reject)

(defstruct (body-collector (:constructor %make-body-collector))
  (buffer (make-array (* 64 1024) :element-type '(unsigned-byte 8)
                                   :adjustable t :fill-pointer 0))
  resolve reject transform)

(defstruct (body-tee (:constructor %make-body-tee))
  source
  first
  second
  (first-active-p t)
  (second-active-p t)
  (transport-paused-p nil))


(defstruct (js-blob
            (:include eng:js-object (class :blob))
            (:constructor %make-js-blob))
  (bytes (make-array 0 :element-type '(unsigned-byte 8)) :type vector)
  (type "" :type string))

;;; Web Streams: Response/Request.body ReadableStream consumers, constructible
;;; ReadableStream (default + BYOB), WritableStream, TransformStream with
;;; pipeTo/pipeThrough. Queuing strategies and CompressionStream live in
;;; web-platform.lisp (FULL PORT #207).

(defstruct (js-readable-stream
            (:include eng:js-object (class :readable-stream))
            (:constructor %make-js-readable-stream))
  ;; FIFO of chunk values (JS objects / typed arrays). Empty + closed → done.
  (queue '() :type list)
  (closed-p nil)
  error
  (locked-p nil)
  reader
  (disturbed-p nil)
  owner                 ; Request/Response when this is a body stream, else nil
  owner-kind            ; :request | :response | nil
  cancel-callback       ; optional JS function
  ;; Deferred Fetch body materialization: avoid opening Clun.file/FIFOs on
  ;; mere `.body` access; materialize one chunk on first read/cancel/mixin.
  (lazy-body-p nil)
  lazy-body-function
  ;; When true, empty+open reads wait (TransformStream output). Default false:
  ;; empty+open → EOF (legacy Partial body / start-only streams).
  (wait-for-data-p nil)
  ;; Pending reader.read() deferreds: list of (resolve . reject) callables.
  (pending-reads '() :type list))

(defstruct (js-readable-stream-reader
            (:include eng:js-object (class :readable-stream-default-reader))
            (:constructor %make-js-readable-stream-reader))
  stream
  (closed-promise nil)
  (closed-resolve nil)
  (closed-reject nil)
  (released-p nil))

(defstruct (js-readable-stream-controller
            (:include eng:js-object (class :readable-stream-default-controller))
            (:constructor %make-js-readable-stream-controller))
  stream)

(defstruct (js-writable-stream
            (:include eng:js-object (class :writable-stream))
            (:constructor %make-js-writable-stream))
  (locked-p nil)
  writer
  (closed-p nil)
  error
  start-callback
  write-callback
  close-callback
  abort-callback
  underlying-sink        ; this-arg for sink methods
  controller
  (closed-promise nil)
  (closed-resolve nil)
  (closed-reject nil)
  ;; Optional back-link used by TransformStream write/close/abort.
  transform
  (in-flight-p nil)
  (pending-writes '() :type list))

(defstruct (js-writable-stream-writer
            (:include eng:js-object (class :writable-stream-default-writer))
            (:constructor %make-js-writable-stream-writer))
  stream
  (released-p nil)
  (ready-promise nil)
  (closed-promise nil)
  (closed-resolve nil)
  (closed-reject nil))

(defstruct (js-writable-stream-controller
            (:include eng:js-object (class :writable-stream-default-controller))
            (:constructor %make-js-writable-stream-controller))
  stream)

(defstruct (js-transform-stream
            (:include eng:js-object (class :transform-stream))
            (:constructor %make-js-transform-stream))
  readable
  writable
  transform-callback
  flush-callback
  transformer            ; underlying transformer object (this-arg for methods)
  controller
  (backpressure-promise nil)
  (backpressure-resolve nil))

(defstruct (js-transform-stream-controller
            (:include eng:js-object (class :transform-stream-default-controller))
            (:constructor %make-js-transform-stream-controller))
  stream)

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
  response-prototype
  readable-stream-constructor
  readable-stream-prototype
  readable-stream-reader-prototype
  readable-stream-controller-prototype
  writable-stream-constructor
  writable-stream-prototype
  writable-stream-writer-prototype
  writable-stream-controller-prototype
  transform-stream-constructor
  transform-stream-prototype
  transform-stream-controller-prototype)

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

(defun %normalize-blob-type (type)
  (if (every (lambda (character)
               (<= #x20 (char-code character) #x7e))
             type)
      (string-downcase type)
      ""))

(defun %body-content-type (value)
  (let ((headers (eng:js-get value "headers")))
    (if (js-headers-p headers)
        (or (car (%header-values headers "content-type")) "")
        "")))

(defun %body-used-p (value)
  (cond
    ((js-response-p value)
     (or (js-response-body-used-p value)
         (let ((stream (js-response-body-stream value)))
           (cond
             ((js-body-stream-p stream)
              (js-body-stream-disturbed-p stream))
             ((js-readable-stream-p stream)
              (js-readable-stream-disturbed-p stream))
             (t nil)))))
    ((js-request-p value) (js-request-body-used-p value))
    (t nil)))

(defun %body-stream-slot (value)
  (cond
    ((js-response-p value) (js-response-body-stream value))
    ((js-request-p value) (js-request-body-stream value))
    (t nil)))

(defun %set-body-stream-slot (value stream)
  (cond
    ((js-response-p value) (setf (js-response-body-stream value) stream))
    ((js-request-p value) (setf (js-request-body-stream value) stream)))
  stream)

(defun %body-raw-value (value)
  (cond
    ((js-response-p value) (js-response-body value))
    ((js-request-p value) (js-request-body value))
    (t nil)))

(defun %body-is-absent-p (value)
  "True when the Fetch body source is null/undefined (Response.body → null)."
  (let ((raw (%body-raw-value value)))
    (or (null raw) (eng:js-null-p raw) (eng:js-undefined-p raw))))

(defun %disturb-body-stream (value)
  "Mark a cached body stream disturbed so later reader.read() sees EOF."
  (let ((stream (%body-stream-slot value)))
    (when (js-readable-stream-p stream)
      (setf (js-readable-stream-disturbed-p stream) t)
      (setf (js-readable-stream-lazy-body-p stream) nil)
      (setf (js-readable-stream-lazy-body-function stream) nil)
      (setf (js-readable-stream-queue stream) '())
      (setf (js-readable-stream-closed-p stream) t))))

(defun %mark-body-used (value)
  (cond
    ((js-response-p value)
     (setf (js-response-body-used-p value) t)
     (let ((stream (js-response-body-stream value)))
       (when (js-body-stream-p stream)
         (setf (js-body-stream-disturbed-p stream) t))))
    ((js-request-p value)
     (setf (js-request-body-used-p value) t)
     (setf (js-request-body value)
           (make-array 0 :element-type '(unsigned-byte 8)))))
  (%disturb-body-stream value)
  value)

(defun %body-stream-locked-p (value)
  (let ((stream (%body-stream-slot value)))
    (or (and (js-readable-stream-p stream)
             (js-readable-stream-locked-p stream))
        (and (js-body-stream-p stream)
             (js-body-stream-locked-p stream)))))

(defun %consume-body-octets (value body-function)
  "Return body octets once.  Subsequent mixin reads and clone after use reject.
Rejects when the body stream is locked by getReader()."
  (when (%body-used-p value)
    (eng:throw-type-error "Body has already been used"))
  (when (%body-stream-locked-p value)
    (eng:throw-type-error "Body stream is locked"))
  (let ((octets (copy-seq (funcall body-function value))))
    (%mark-body-used value)
    octets))

;;; --- ReadableStream (bounded) ----------------------------------------------

(defun %read-result (value done-p)
  (let ((o (eng:new-object)))
    (eng:data-prop o "value" (if done-p eng:+undefined+ value))
    (eng:data-prop o "done" (eng:js-boolean done-p))
    o))

(defun %reader-closed-deferred (reader)
  "Ensure CLOSED promise resolvers exist on READER."
  (unless (js-readable-stream-reader-closed-promise reader)
    (let ((global (eng:realm-global eng:*realm*))
          resolve reject)
      (let ((promise
              (eng:js-construct
               (eng:js-get global "Promise")
               (list (eng:make-native-function
                      "" 2
                      (lambda (this a)
                        (declare (ignore this))
                        (setf resolve (eng:arg a 0)
                              reject (eng:arg a 1))
                        eng:+undefined+))))))
        (setf (js-readable-stream-reader-closed-promise reader) promise
              (js-readable-stream-reader-closed-resolve reader) resolve
              (js-readable-stream-reader-closed-reject reader) reject))))
  (js-readable-stream-reader-closed-promise reader))

(defun %reader-resolve-closed (reader)
  (let ((resolve (js-readable-stream-reader-closed-resolve reader)))
    (when resolve
      (eng:js-call resolve eng:+undefined+ (list eng:+undefined+))
      (setf (js-readable-stream-reader-closed-resolve reader) nil
            (js-readable-stream-reader-closed-reject reader) nil))))

(defun %reader-reject-closed (reader reason)
  (let ((reject (js-readable-stream-reader-closed-reject reader)))
    (when reject
      (eng:js-call reject eng:+undefined+ (list reason))
      (setf (js-readable-stream-reader-closed-resolve reader) nil
            (js-readable-stream-reader-closed-reject reader) nil))))

(defun %stream-error-type (message)
  (let ((g (eng:realm-global eng:*realm*)))
    (eng:js-construct (eng:js-get g "TypeError") (list message))))

(defun %notify-owner-body-used (stream)
  "When a body-owned stream is read/cancelled, mark the Fetch body used."
  (let ((owner (js-readable-stream-owner stream)))
    (when owner
      (unless (%body-used-p owner)
        (cond
          ((js-response-p owner)
           (setf (js-response-body-used-p owner) t)
           (setf (js-response-body owner) eng:+null+))
          ((js-request-p owner)
           (setf (js-request-body-used-p owner) t)
           (setf (js-request-body owner)
                 (make-array 0 :element-type '(unsigned-byte 8)))))))))

(defun %stream-fulfill-pending-read (stream chunk done-p)
  "Settle one deferred reader.read() if any; otherwise enqueue CHUNK."
  (let ((pending (js-readable-stream-pending-reads stream)))
    (if pending
        (let* ((pair (pop (js-readable-stream-pending-reads stream)))
               (resolve (car pair)))
          (setf (js-readable-stream-disturbed-p stream) t)
          (%notify-owner-body-used stream)
          (when (eng:callable-p resolve)
            (eng:js-call resolve eng:+undefined+
                         (list (%read-result (if done-p eng:+undefined+ chunk)
                                             done-p))))
          t)
        nil)))

(defun %stream-reject-pending-reads (stream reason)
  (dolist (pair (js-readable-stream-pending-reads stream))
    (let ((reject (cdr pair)))
      (when (eng:callable-p reject)
        (eng:js-call reject eng:+undefined+ (list reason)))))
  (setf (js-readable-stream-pending-reads stream) '()))

(defun %stream-resolve-pending-reads-done (stream)
  (dolist (pair (js-readable-stream-pending-reads stream))
    (let ((resolve (car pair)))
      (when (eng:callable-p resolve)
        (eng:js-call resolve eng:+undefined+
                     (list (%read-result eng:+undefined+ t))))))
  (setf (js-readable-stream-pending-reads stream) '()))

(defun %stream-enqueue (stream chunk)
  (when (js-readable-stream-closed-p stream)
    (eng:throw-type-error "ReadableStream is closed"))
  (when (js-readable-stream-error stream)
    (eng:throw-type-error "ReadableStream is errored"))
  (unless (%stream-fulfill-pending-read stream chunk nil)
    (setf (js-readable-stream-queue stream)
          (append (js-readable-stream-queue stream) (list chunk))))
  eng:+undefined+)

(defun %stream-close (stream)
  (unless (or (js-readable-stream-closed-p stream)
              (js-readable-stream-error stream))
    (setf (js-readable-stream-closed-p stream) t)
    (%stream-resolve-pending-reads-done stream)
    (let ((reader (js-readable-stream-reader stream)))
      (when (and (js-readable-stream-reader-p reader)
                 (null (js-readable-stream-queue stream)))
        (%reader-resolve-closed reader))))
  eng:+undefined+)

(defun %stream-error (stream reason)
  (unless (or (js-readable-stream-closed-p stream)
              (js-readable-stream-error stream))
    (setf (js-readable-stream-error stream) reason)
    (%stream-reject-pending-reads stream reason)
    (let ((reader (js-readable-stream-reader stream)))
      (when (js-readable-stream-reader-p reader)
        (%reader-reject-closed reader reason))))
  eng:+undefined+)

(defun %stream-materialize-lazy-body (stream)
  "Turn a deferred body-owned stream into a single closed Uint8Array chunk."
  (when (js-readable-stream-lazy-body-p stream)
    (setf (js-readable-stream-lazy-body-p stream) nil)
    (let* ((owner (js-readable-stream-owner stream))
           (fn (js-readable-stream-lazy-body-function stream))
           (octets
             (cond
               ((and owner fn (not (%body-used-p owner)))
                (copy-seq (funcall fn owner)))
               (t (make-array 0 :element-type '(unsigned-byte 8))))))
      (setf (js-readable-stream-queue stream)
            (list (eng:u8-from-octets octets)))
      (setf (js-readable-stream-closed-p stream) t)
      (setf (js-readable-stream-lazy-body-function stream) nil))))

(defun %stream-pull-chunk (stream)
  "Pop one queued chunk, or return (values nil :done|:pending|:error reason)."
  (%stream-materialize-lazy-body stream)
  (cond
    ((js-readable-stream-error stream)
     (values nil :error (js-readable-stream-error stream)))
    ((js-readable-stream-queue stream)
     (let ((chunk (pop (js-readable-stream-queue stream))))
       (setf (js-readable-stream-disturbed-p stream) t)
       (%notify-owner-body-used stream)
       (values chunk :value nil)))
    ((js-readable-stream-closed-p stream)
     (setf (js-readable-stream-disturbed-p stream) t)
     (values nil :done nil))
    (t (values nil :pending nil))))

(defun %reader-read-pending-promise (stream)
  "Defer a read until enqueue/close/error on a live (wait-for-data) stream."
  (let ((global (eng:realm-global eng:*realm*))
        resolve reject)
    (let ((promise
            (eng:js-construct
             (eng:js-get global "Promise")
             (list (eng:make-native-function
                    "" 2
                    (lambda (this a)
                      (declare (ignore this))
                      (setf resolve (eng:arg a 0)
                            reject (eng:arg a 1))
                      eng:+undefined+))))))
      (setf (js-readable-stream-pending-reads stream)
            (append (js-readable-stream-pending-reads stream)
                    (list (cons resolve reject))))
      promise)))

;;; --- BYOB (ReadableStreamBYOBReader) ---------------------------------------

(defvar *byob-readers* (make-hash-table :test #'eq :weakness :key)
  "Readers obtained via getReader({mode:'byob'}).")
(defvar *byob-pending-octets* (make-hash-table :test #'eq :weakness :key)
  "Per-stream residual octets for partial BYOB fills.")

(defun %chunk-to-octets (chunk)
  (cond
    ((null chunk) (make-array 0 :element-type '(unsigned-byte 8)))
    ((eng:js-typed-array-p chunk) (eng:buffer-source-octets chunk))
    ((eng:js-array-buffer-p chunk) (eng:buffer-source-octets chunk))
    ((or (eng:js-string-p chunk) (stringp chunk))
     (sb-ext:string-to-octets (eng:to-string chunk) :external-format :utf-8))
    (t (%body->octets chunk))))

(defun %copy-octets-into-view (view octets)
  (unless (eng:js-typed-array-p view)
    (eng:throw-type-error "BYOB read requires an ArrayBufferView"))
  (when (null (eng:js-array-buffer-bytes (eng::js-typed-array-abuffer view)))
    (eng:throw-type-error "ArrayBuffer is detached"))
  (multiple-value-bind (bytes offset length) (eng:ta-octets view)
    (let ((n (min length (length octets))))
      (when (plusp n)
        (replace bytes octets :start1 offset :end1 (+ offset n) :end2 n))
      (values (if (= n length) view (eng:ta-subview view 0 n))
              n
              (if (< n (length octets)) (subseq octets n) nil)))))

(defun %byob-reader-read (reader view)
  "Fill VIEW from the stream queue (BYOB). Returns a read-result promise."
  (let ((global (eng:realm-global eng:*realm*)))
    (when (js-readable-stream-reader-released-p reader)
      (return-from %byob-reader-read
        (%rejected-promise
         global (%stream-error-type "This readable stream reader has been released"))))
    (unless (eng:js-typed-array-p view)
      (return-from %byob-reader-read
        (%rejected-promise
         global (%stream-error-type "BYOB read requires an ArrayBufferView"))))
    (let ((stream (js-readable-stream-reader-stream reader)))
      (%stream-materialize-lazy-body stream)
      (when (js-readable-stream-error stream)
        (return-from %byob-reader-read
          (%rejected-promise global (js-readable-stream-error stream))))
      (let ((octets
              (or (gethash stream *byob-pending-octets*)
                  (multiple-value-bind (chunk kind reason)
                      (%stream-pull-chunk stream)
                    (declare (ignore reason))
                    (ecase kind
                      (:value (%chunk-to-octets chunk))
                      (:done nil)
                      (:error nil)
                      (:pending nil))))))
        (cond
          ((null octets)
           (if (or (js-readable-stream-closed-p stream)
                   (not (js-readable-stream-wait-for-data-p stream)))
               (progn
                 (unless (js-readable-stream-closed-p stream)
                   (setf (js-readable-stream-closed-p stream) t))
                 (%reader-resolve-closed reader)
                 (%resolved-promise global (%read-result eng:+undefined+ t)))
               ;; Park: not fully supported for BYOB pending; treat as EOF.
               (progn
                 (setf (js-readable-stream-closed-p stream) t)
                 (%reader-resolve-closed reader)
                 (%resolved-promise global (%read-result eng:+undefined+ t)))))
          ((zerop (length octets))
           (remhash stream *byob-pending-octets*)
           (%byob-reader-read reader view))
          (t
           (multiple-value-bind (filled copied remaining)
               (%copy-octets-into-view view octets)
             (declare (ignore copied))
             (if remaining
                 (setf (gethash stream *byob-pending-octets*) remaining)
                 (remhash stream *byob-pending-octets*))
             (setf (js-readable-stream-disturbed-p stream) t)
             (%notify-owner-body-used stream)
             (when (and (js-readable-stream-closed-p stream)
                        (null (js-readable-stream-queue stream))
                        (null remaining))
               (%reader-resolve-closed reader))
             (%resolved-promise global (%read-result filled nil)))))))))

(defun %reader-read (reader)
  (let ((global (eng:realm-global eng:*realm*)))
    (when (js-readable-stream-reader-released-p reader)
      (return-from %reader-read
        (%rejected-promise
         global (%stream-error-type "This readable stream reader has been released"))))
    (let ((stream (js-readable-stream-reader-stream reader)))
      (multiple-value-bind (chunk kind reason) (%stream-pull-chunk stream)
        (ecase kind
          (:value
           (when (and (js-readable-stream-closed-p stream)
                      (null (js-readable-stream-queue stream)))
             (%reader-resolve-closed reader))
           (%resolved-promise global (%read-result chunk nil)))
          (:done
           (%reader-resolve-closed reader)
           (%resolved-promise global (%read-result eng:+undefined+ t)))
          (:error
           (%rejected-promise global reason))
          (:pending
           (if (js-readable-stream-wait-for-data-p stream)
               (%reader-read-pending-promise stream)
               ;; Legacy Partial: pre-buffered/start()-closed streams only;
               ;; an open empty queue is treated as closed EOF.
               (progn
                 (setf (js-readable-stream-closed-p stream) t)
                 (%reader-resolve-closed reader)
                 (%resolved-promise global
                                    (%read-result eng:+undefined+ t))))))))))

(defun %reader-cancel (reader reason)
  (let ((global (eng:realm-global eng:*realm*)))
    (when (js-readable-stream-reader-released-p reader)
      (return-from %reader-cancel
        (%rejected-promise
         global (%stream-error-type "This readable stream reader has been released"))))
    (let* ((stream (js-readable-stream-reader-stream reader))
           (cb (js-readable-stream-cancel-callback stream)))
      ;; Drop lazy body without materializing (cancel must not open FIFOs).
      (setf (js-readable-stream-lazy-body-p stream) nil)
      (setf (js-readable-stream-lazy-body-function stream) nil)
      (setf (js-readable-stream-disturbed-p stream) t)
      (setf (js-readable-stream-queue stream) '())
      (setf (js-readable-stream-closed-p stream) t)
      (%stream-resolve-pending-reads-done stream)
      (%notify-owner-body-used stream)
      (when (and cb (eng:callable-p cb))
        (ignore-errors (eng:js-call cb eng:+undefined+ (list reason))))
      (%reader-resolve-closed reader)
      (%resolved-promise global eng:+undefined+))))

(defun %reader-release-lock (reader)
  (when (js-readable-stream-reader-released-p reader)
    (return-from %reader-release-lock eng:+undefined+))
  (let ((stream (js-readable-stream-reader-stream reader)))
    (setf (js-readable-stream-reader-released-p reader) t)
    (setf (js-readable-stream-locked-p stream) nil)
    (setf (js-readable-stream-reader stream) nil)
    ;; Spec rejects closed; Partial resolves so consumers can drop the reader.
    (%reader-resolve-closed reader))
  eng:+undefined+)

(defun %make-default-reader (stream)
  (when (js-readable-stream-locked-p stream)
    (eng:throw-type-error "ReadableStream is locked"))
  (let* ((state (%http-state))
         (reader
           (%make-js-readable-stream-reader
            :proto (web-http-realm-state-readable-stream-reader-prototype state)
            :stream stream)))
    (setf (js-readable-stream-locked-p stream) t
          (js-readable-stream-reader stream) reader)
    (%reader-closed-deferred reader)
    (when (and (js-readable-stream-closed-p stream)
               (null (js-readable-stream-queue stream))
               (null (js-readable-stream-error stream)))
      (%reader-resolve-closed reader))
    (when (js-readable-stream-error stream)
      (%reader-reject-closed reader (js-readable-stream-error stream)))
    reader))

(defun %install-readable-stream-reader-prototype (prototype)
  (%define-accessor
   prototype "closed"
   (lambda (this args)
     (declare (ignore args))
     (unless (js-readable-stream-reader-p this)
       (eng:throw-type-error "Illegal invocation"))
     (%reader-closed-deferred this))
   nil)
  (%install-prototype-method
   prototype "read" 1
   (lambda (this args)
     (unless (js-readable-stream-reader-p this)
       (eng:throw-type-error "Illegal invocation"))
     (if (gethash this *byob-readers*)
         (let ((view (eng:arg args 0)))
           (if (or (eng:js-undefined-p view) (eng:js-nullish-p view))
               (%rejected-promise
                (eng:realm-global eng:*realm*)
                (%stream-error-type "BYOB read requires a view argument"))
               (%byob-reader-read this view)))
         (%reader-read this))))
  (%install-prototype-method
   prototype "cancel" 1
   (lambda (this args)
     (unless (js-readable-stream-reader-p this)
       (eng:throw-type-error "Illegal invocation"))
     (%reader-cancel this (eng:arg args 0))))
  (%install-prototype-method
   prototype "releaseLock" 0
   (lambda (this args)
     (declare (ignore args))
     (unless (js-readable-stream-reader-p this)
       (eng:throw-type-error "Illegal invocation"))
     (%reader-release-lock this)))
  (%define-data prototype (eng:well-known :to-string-tag)
                "ReadableStreamDefaultReader"
                :writable nil :enumerable nil :configurable t)
  prototype)

(defun %install-readable-stream-controller-prototype (prototype)
  (%install-prototype-method
   prototype "enqueue" 1
   (lambda (this args)
     (unless (js-readable-stream-controller-p this)
       (eng:throw-type-error "Illegal invocation"))
     (%stream-enqueue (js-readable-stream-controller-stream this)
                      (eng:arg args 0))))
  (%install-prototype-method
   prototype "close" 0
   (lambda (this args)
     (declare (ignore args))
     (unless (js-readable-stream-controller-p this)
       (eng:throw-type-error "Illegal invocation"))
     (%stream-close (js-readable-stream-controller-stream this))))
  (%install-prototype-method
   prototype "error" 1
   (lambda (this args)
     (unless (js-readable-stream-controller-p this)
       (eng:throw-type-error "Illegal invocation"))
     (%stream-error (js-readable-stream-controller-stream this)
                    (eng:arg args 0))))
  (%define-data prototype (eng:well-known :to-string-tag)
                "ReadableStreamDefaultController"
                :writable nil :enumerable nil :configurable t)
  prototype)

(defun %install-readable-stream-prototype (prototype)
  (%define-accessor
   prototype "locked"
   (lambda (this args)
     (declare (ignore args))
     (unless (js-readable-stream-p this)
       (eng:throw-type-error "Illegal invocation"))
     (eng:js-boolean (js-readable-stream-locked-p this)))
   nil)
  (%install-prototype-method
   prototype "getReader" 0
   (lambda (this args)
     (unless (js-readable-stream-p this)
       (eng:throw-type-error "Illegal invocation"))
     (let* ((options (eng:arg args 0))
            (mode (and (eng:js-object-p options)
                       (eng:js-get options "mode")))
            (byob-p (and mode (eng:js-string-p mode)
                         (string= (eng:to-string mode) "byob")))
            (reader (%make-default-reader this)))
       (when byob-p
         (setf (gethash reader *byob-readers*) t)
         ;; BYOB partial fills need residual tracking on the stream.
         (unless (gethash this *byob-pending-octets*)
           (setf (gethash this *byob-pending-octets*) nil)))
       reader)))
  (%install-prototype-method
   prototype "cancel" 1
   (lambda (this args)
     (unless (js-readable-stream-p this)
       (eng:throw-type-error "Illegal invocation"))
     (if (js-readable-stream-locked-p this)
         (%rejected-promise
          (eng:realm-global eng:*realm*)
          (%stream-error-type "Cannot cancel a locked stream"))
         (let ((reader (%make-default-reader this)))
           (%reader-cancel reader (eng:arg args 0))))))
  (%install-prototype-method
   prototype "pipeTo" 1
   (lambda (this args)
     (unless (js-readable-stream-p this)
       (eng:throw-type-error "Illegal invocation"))
     (%readable-pipe-to this (eng:arg args 0))))
  (%install-prototype-method
   prototype "pipeThrough" 1
   (lambda (this args)
     (unless (js-readable-stream-p this)
       (eng:throw-type-error "Illegal invocation"))
     (%readable-pipe-through this (eng:arg args 0))))
  (%define-data prototype (eng:well-known :to-string-tag) "ReadableStream"
                :writable nil :enumerable nil :configurable t)
  prototype)

(defun %readable-pipe-to (stream dest)
  "Drain STREAM into WritableStream DEST (bounded, pure-CL)."
  (let ((global (eng:realm-global eng:*realm*)))
    (unless (js-writable-stream-p dest)
      (return-from %readable-pipe-to
        (%rejected-promise
         global (%stream-error-type "pipeTo destination must be a WritableStream"))))
    (when (js-readable-stream-locked-p stream)
      (return-from %readable-pipe-to
        (%rejected-promise global (%stream-error-type "ReadableStream is locked"))))
    (when (js-writable-stream-locked-p dest)
      (return-from %readable-pipe-to
        (%rejected-promise global (%stream-error-type "WritableStream is locked"))))
    (let ((reader (%make-default-reader stream))
          (writer (%make-default-writer dest)))
      (handler-case
          (loop
            (multiple-value-bind (chunk kind reason)
                (%stream-pull-chunk stream)
              (ecase kind
                (:value
                 (eng:js-call (eng:js-get writer "write") writer (list chunk)))
                (:done
                 (eng:js-call (eng:js-get writer "close") writer '())
                 (%reader-release-lock reader)
                 (return (%resolved-promise global eng:+undefined+)))
                (:error
                 (ignore-errors
                   (eng:js-call (eng:js-get writer "abort") writer (list reason)))
                 (%reader-release-lock reader)
                 (return (%rejected-promise global reason)))
                (:pending
                 (setf (js-readable-stream-closed-p stream) t)
                 (eng:js-call (eng:js-get writer "close") writer '())
                 (%reader-release-lock reader)
                 (return (%resolved-promise global eng:+undefined+))))))
        (eng:js-condition (c)
          (ignore-errors
            (eng:js-call (eng:js-get writer "abort") writer
                         (list (eng:js-condition-value c))))
          (%reader-cancel reader (eng:js-condition-value c))
          (%rejected-promise global (eng:js-condition-value c)))
        (error (c)
          (let ((reason (%stream-error-type (princ-to-string c))))
            (ignore-errors
              (eng:js-call (eng:js-get writer "abort") writer (list reason)))
            (%reader-cancel reader reason)
            (%rejected-promise global reason)))))))

(defun %readable-pipe-through (stream transform)
  (unless (js-transform-stream-p transform)
    (eng:throw-type-error "pipeThrough requires a TransformStream"))
  (let ((writable (js-transform-stream-writable transform))
        (readable (js-transform-stream-readable transform)))
    (%readable-pipe-to stream writable)
    readable))

(defun %new-readable-stream (&key queue closed-p owner owner-kind
                                   cancel-callback lazy-body-p
                                   lazy-body-function wait-for-data-p)
  (let* ((state (%http-state))
         (stream
           (%make-js-readable-stream
            :proto (web-http-realm-state-readable-stream-prototype state)
            :queue (copy-list queue)
            :closed-p closed-p
            :owner owner
            :owner-kind owner-kind
            :cancel-callback cancel-callback
            :lazy-body-p lazy-body-p
            :lazy-body-function lazy-body-function
            :wait-for-data-p wait-for-data-p)))
    stream))

(defun %controller-for (stream)
  (%make-js-readable-stream-controller
   :proto (web-http-realm-state-readable-stream-controller-prototype
           (%http-state))
   :stream stream))

(defun %construct-readable-stream (underlying-source)
  "Minimal `new ReadableStream({ start(controller), cancel })`."
  (let* ((stream (%new-readable-stream :closed-p nil :wait-for-data-p t))
         (controller (%controller-for stream))
         (source (if (eng:js-object-p underlying-source)
                     underlying-source
                     eng:+undefined+)))
    (unless (eng:js-undefined-p source)
      (let ((cancel (eng:js-get source "cancel")))
        (when (eng:callable-p cancel)
          (setf (js-readable-stream-cancel-callback stream) cancel)))
      (let ((start (eng:js-get source "start")))
        (when (eng:callable-p start)
          (eng:js-call start source (list controller)))))
    ;; If start never closed/enqueued, leave open until first pending read → EOF.
    stream))

(defun %make-readable-stream-constructor (prototype)
  (let ((constructor
          (eng:make-native-function
           "ReadableStream" 0
           (lambda (this args)
             (declare (ignore this args))
             (eng:throw-type-error "ReadableStream requires 'new'"))
           :construct
           (lambda (args new-target)
             (declare (ignore new-target))
             (%construct-readable-stream (eng:arg args 0))))))
    (%set-constructor-prototype constructor prototype)
    constructor))

;;; --- WritableStream (pure-CL) ----------------------------------------------

(defun %writable-closed-deferred (stream)
  "Ensure the stream-level closed promise resolvers exist."
  (unless (js-writable-stream-closed-promise stream)
    (let ((global (eng:realm-global eng:*realm*))
          resolve reject)
      (let ((promise
              (eng:js-construct
               (eng:js-get global "Promise")
               (list (eng:make-native-function
                      "" 2
                      (lambda (this a)
                        (declare (ignore this))
                        (setf resolve (eng:arg a 0)
                              reject (eng:arg a 1))
                        eng:+undefined+))))))
        (setf (js-writable-stream-closed-promise stream) promise
              (js-writable-stream-closed-resolve stream) resolve
              (js-writable-stream-closed-reject stream) reject))))
  (js-writable-stream-closed-promise stream))

(defun %writable-resolve-closed (stream)
  (let ((resolve (js-writable-stream-closed-resolve stream)))
    (when resolve
      (eng:js-call resolve eng:+undefined+ (list eng:+undefined+))
      (setf (js-writable-stream-closed-resolve stream) nil
            (js-writable-stream-closed-reject stream) nil)))
  (let ((writer (js-writable-stream-writer stream)))
    (when (js-writable-stream-writer-p writer)
      (let ((w-resolve (js-writable-stream-writer-closed-resolve writer)))
        (when w-resolve
          (eng:js-call w-resolve eng:+undefined+ (list eng:+undefined+))
          (setf (js-writable-stream-writer-closed-resolve writer) nil
                (js-writable-stream-writer-closed-reject writer) nil))))))

(defun %mark-promise-handled (promise)
  "Avoid eval-source treating intentional closed-rejections (abort/error) as
uncaught unhandled rejections when the user never attached writer.closed."
  (when (eng:js-promise-p promise)
    (setf (eng::js-promise-handled promise) t)
    (ignore-errors (eng::untrack-rejection promise))))

(defun %writable-reject-closed (stream reason)
  (let ((reject (js-writable-stream-closed-reject stream))
        (promise (js-writable-stream-closed-promise stream)))
    (%mark-promise-handled promise)
    (when reject
      (eng:js-call reject eng:+undefined+ (list reason))
      (setf (js-writable-stream-closed-resolve stream) nil
            (js-writable-stream-closed-reject stream) nil)))
  (let ((writer (js-writable-stream-writer stream)))
    (when (js-writable-stream-writer-p writer)
      (let ((w-reject (js-writable-stream-writer-closed-reject writer))
            (w-promise (js-writable-stream-writer-closed-promise writer)))
        (%mark-promise-handled w-promise)
        (when w-reject
          (eng:js-call w-reject eng:+undefined+ (list reason))
          (setf (js-writable-stream-writer-closed-resolve writer) nil
                (js-writable-stream-writer-closed-reject writer) nil))))))

(defun %writable-error (stream reason)
  (unless (or (js-writable-stream-closed-p stream)
              (js-writable-stream-error stream))
    (setf (js-writable-stream-error stream) reason
          (js-writable-stream-closed-p stream) t)
    (%writable-reject-closed stream reason))
  eng:+undefined+)

(defun %promise-from-maybe-thenable (global value)
  "If VALUE is thenable, return it; else a resolved promise of VALUE."
  (if (and (eng:js-object-p value)
           (eng:callable-p (eng:js-get value "then")))
      value
      (%resolved-promise global value)))

(defun %call-sink-method (fn this-arg args global)
  "Call FN; return a promise that settles with its result/error."
  (if (eng:callable-p fn)
      (handler-case
          (let ((result (eng:js-call fn this-arg args)))
            (%promise-from-maybe-thenable global result))
        (eng:js-condition (c)
          (%rejected-promise global (eng:js-condition-value c)))
        (error (e)
          (%rejected-promise
           global (%stream-error-type (princ-to-string e)))))
      (%resolved-promise global eng:+undefined+)))

(defun %writable-sink-this (stream)
  (or (js-writable-stream-underlying-sink stream) eng:+undefined+))

(defun %writable-do-write (stream chunk)
  (let* ((global (eng:realm-global eng:*realm*))
         (cb (js-writable-stream-write-callback stream))
         (controller (js-writable-stream-controller stream))
         (transform (js-writable-stream-transform stream)))
    (cond
      ((js-writable-stream-error stream)
       (%rejected-promise global (js-writable-stream-error stream)))
      ((js-writable-stream-closed-p stream)
       (%rejected-promise
        global (%stream-error-type "WritableStream is closed")))
      (transform
       (%transform-handle-write transform chunk))
      (t
       (%call-sink-method cb (%writable-sink-this stream)
                          (list chunk controller) global)))))

(defun %writable-do-close (stream)
  (let* ((global (eng:realm-global eng:*realm*))
         (cb (js-writable-stream-close-callback stream))
         (controller (js-writable-stream-controller stream))
         (transform (js-writable-stream-transform stream)))
    (cond
      ((js-writable-stream-error stream)
       (%rejected-promise global (js-writable-stream-error stream)))
      ((js-writable-stream-closed-p stream)
       (%rejected-promise
        global (%stream-error-type "WritableStream is closed")))
      (transform
       (%transform-handle-close transform))
      (t
       (multiple-value-bind (out resolve reject)
           (%writable-make-deferred global)
         (let ((p (%call-sink-method cb (%writable-sink-this stream)
                                     (list controller) global)))
           (eng:js-call
            (eng:js-get p "then") p
            (list (eng:make-native-function
                   "" 1
                   (lambda (this a)
                     (declare (ignore this a))
                     (setf (js-writable-stream-closed-p stream) t)
                     (%writable-resolve-closed stream)
                     (eng:js-call resolve eng:+undefined+
                                  (list eng:+undefined+))
                     eng:+undefined+))
                  (eng:make-native-function
                   "" 1
                   (lambda (this a)
                     (declare (ignore this))
                     (let ((reason (eng:arg a 0)))
                       (%writable-error stream reason)
                       (eng:js-call reject eng:+undefined+ (list reason)))
                     eng:+undefined+))))
           out))))))

(defun %writable-make-deferred (global)
  "Return (values promise resolve reject)."
  (let (resolve reject)
    (let ((promise
            (eng:js-construct
             (eng:js-get global "Promise")
             (list (eng:make-native-function
                    "" 2
                    (lambda (this a)
                      (declare (ignore this))
                      (setf resolve (eng:arg a 0)
                            reject (eng:arg a 1))
                      eng:+undefined+))))))
      (values promise resolve reject))))

(defun %writable-mark-aborted (stream err)
  "Mark STREAM aborted without invoking closed-promise rejectors synchronously.
Closed promises are rejected via a microtask so writer.abort() can return a
fulfilled promise before any rejection reactions run."
  (unless (or (js-writable-stream-closed-p stream)
              (js-writable-stream-error stream))
    (setf (js-writable-stream-error stream) err
          (js-writable-stream-closed-p stream) t)
    (let ((global (eng:realm-global eng:*realm*)))
      ;; Prefer queue-microtask when a loop exists; else reject immediately.
      (let ((loop (ignore-errors (eng:current-loop))))
        (if loop
            (lp:enqueue-microtask
             loop
             (lambda ()
               (%writable-reject-closed stream err)))
            (%writable-reject-closed stream err)))))
  eng:+undefined+)

(defun %writable-do-abort (stream reason)
  "Error the stream with REASON after sink.abort; abort() itself fulfills."
  (let* ((global (eng:realm-global eng:*realm*))
         (cb (js-writable-stream-abort-callback stream))
         (transform (js-writable-stream-transform stream))
         (err (if (or (eng:js-undefined-p reason) (eng:js-nullish-p reason))
                  (%stream-error-type "Aborted")
                  reason)))
    (cond
      ((js-writable-stream-closed-p stream)
       ;; Already closed/errored: abort is a no-op success (Partial).
       (%resolved-promise global eng:+undefined+))
      (transform
       (%transform-handle-abort transform reason))
      (t
       (when (eng:callable-p cb)
         (handler-case
             (let ((result (eng:js-call cb (%writable-sink-this stream)
                                        (list reason))))
               (when (and (eng:js-object-p result)
                          (eng:callable-p (eng:js-get result "then")))
                 (return-from %writable-do-abort
                   (multiple-value-bind (out resolve reject)
                       (%writable-make-deferred global)
                     (declare (ignore reject))
                     (eng:js-call
                      (eng:js-get result "then") result
                      (list (eng:make-native-function
                             "" 1
                             (lambda (this a)
                               (declare (ignore this a))
                               (%writable-mark-aborted stream err)
                               (eng:js-call resolve eng:+undefined+
                                            (list eng:+undefined+))
                               eng:+undefined+))
                            (eng:make-native-function
                             "" 1
                             (lambda (this a)
                               (declare (ignore this))
                               (%writable-mark-aborted stream (eng:arg a 0))
                               (eng:js-call resolve eng:+undefined+
                                            (list eng:+undefined+))
                               eng:+undefined+))))
                     out))))
           (eng:js-condition (c)
             (%writable-mark-aborted stream (eng:js-condition-value c))
             (return-from %writable-do-abort
               (%resolved-promise global eng:+undefined+)))
           (error ()
             ;; Keep going; still abort the stream with ERR.
             nil)))
       (%writable-mark-aborted stream err)
       (%resolved-promise global eng:+undefined+)))))

(defun %writer-closed-deferred (writer)
  (unless (js-writable-stream-writer-closed-promise writer)
    (let ((stream (js-writable-stream-writer-stream writer)))
      (%writable-closed-deferred stream)
      (let ((global (eng:realm-global eng:*realm*))
            resolve reject)
        (let ((promise
                (eng:js-construct
                 (eng:js-get global "Promise")
                 (list (eng:make-native-function
                        "" 2
                        (lambda (this a)
                          (declare (ignore this))
                          (setf resolve (eng:arg a 0)
                                reject (eng:arg a 1))
                          eng:+undefined+))))))
          (setf (js-writable-stream-writer-closed-promise writer) promise
                (js-writable-stream-writer-closed-resolve writer) resolve
                (js-writable-stream-writer-closed-reject writer) reject)
          (cond
            ((js-writable-stream-error stream)
             (eng:js-call reject eng:+undefined+
                          (list (js-writable-stream-error stream)))
             (setf (js-writable-stream-writer-closed-resolve writer) nil
                   (js-writable-stream-writer-closed-reject writer) nil))
            ((js-writable-stream-closed-p stream)
             (eng:js-call resolve eng:+undefined+ (list eng:+undefined+))
             (setf (js-writable-stream-writer-closed-resolve writer) nil
                   (js-writable-stream-writer-closed-reject writer) nil)))))))
  (js-writable-stream-writer-closed-promise writer))

(defun %writer-ready-promise (writer)
  (or (js-writable-stream-writer-ready-promise writer)
      (let* ((global (eng:realm-global eng:*realm*))
             (stream (js-writable-stream-writer-stream writer))
             (p (if (js-writable-stream-error stream)
                    (%rejected-promise global
                                       (js-writable-stream-error stream))
                    (%resolved-promise global eng:+undefined+))))
        (setf (js-writable-stream-writer-ready-promise writer) p)
        p)))

(defun %make-default-writer (stream)
  (when (js-writable-stream-locked-p stream)
    (eng:throw-type-error "WritableStream is locked"))
  (let* ((state (%http-state))
         (writer
           (%make-js-writable-stream-writer
            :proto (web-http-realm-state-writable-stream-writer-prototype state)
            :stream stream)))
    (setf (js-writable-stream-locked-p stream) t
          (js-writable-stream-writer stream) writer)
    (%writable-closed-deferred stream)
    (%writer-closed-deferred writer)
    (%writer-ready-promise writer)
    writer))

(defun %writer-write (writer chunk)
  (let ((global (eng:realm-global eng:*realm*)))
    (when (js-writable-stream-writer-released-p writer)
      (return-from %writer-write
        (%rejected-promise
         global (%stream-error-type
                 "This writable stream writer has been released"))))
    (%writable-do-write (js-writable-stream-writer-stream writer) chunk)))

(defun %writer-close (writer)
  (let ((global (eng:realm-global eng:*realm*)))
    (when (js-writable-stream-writer-released-p writer)
      (return-from %writer-close
        (%rejected-promise
         global (%stream-error-type
                 "This writable stream writer has been released"))))
    (%writable-do-close (js-writable-stream-writer-stream writer))))

(defun %writer-abort (writer reason)
  (let ((global (eng:realm-global eng:*realm*)))
    (when (js-writable-stream-writer-released-p writer)
      (return-from %writer-abort
        (%rejected-promise
         global (%stream-error-type
                 "This writable stream writer has been released"))))
    (%writable-do-abort (js-writable-stream-writer-stream writer) reason)))

(defun %writer-release-lock (writer)
  (when (js-writable-stream-writer-released-p writer)
    (return-from %writer-release-lock eng:+undefined+))
  (let ((stream (js-writable-stream-writer-stream writer)))
    (setf (js-writable-stream-writer-released-p writer) t
          (js-writable-stream-locked-p stream) nil
          (js-writable-stream-writer stream) nil)
    ;; Spec rejects writer.closed/ready after release; Partial resolves closed
    ;; only if still open so consumers can drop the writer cleanly.
    (unless (or (js-writable-stream-closed-p stream)
                (js-writable-stream-error stream))
      (let ((reject (js-writable-stream-writer-closed-reject writer)))
        (when reject
          (eng:js-call reject eng:+undefined+
                       (list (%stream-error-type
                              "This writable stream writer has been released")))
          (setf (js-writable-stream-writer-closed-resolve writer) nil
                (js-writable-stream-writer-closed-reject writer) nil)))))
  eng:+undefined+)

(defun %install-writable-stream-writer-prototype (prototype)
  (%define-accessor
   prototype "closed"
   (lambda (this args)
     (declare (ignore args))
     (unless (js-writable-stream-writer-p this)
       (eng:throw-type-error "Illegal invocation"))
     (%writer-closed-deferred this))
   nil)
  (%define-accessor
   prototype "ready"
   (lambda (this args)
     (declare (ignore args))
     (unless (js-writable-stream-writer-p this)
       (eng:throw-type-error "Illegal invocation"))
     (%writer-ready-promise this))
   nil)
  (%define-accessor
   prototype "desiredSize"
   (lambda (this args)
     (declare (ignore args))
     (unless (js-writable-stream-writer-p this)
       (eng:throw-type-error "Illegal invocation"))
     (let ((stream (js-writable-stream-writer-stream this)))
       (cond
         ((js-writable-stream-error stream) eng:+null+)
         ((js-writable-stream-closed-p stream) 0d0)
         (t 1d0))))
   nil)
  (%install-prototype-method
   prototype "write" 1
   (lambda (this args)
     (unless (js-writable-stream-writer-p this)
       (eng:throw-type-error "Illegal invocation"))
     (%writer-write this (eng:arg args 0))))
  (%install-prototype-method
   prototype "close" 0
   (lambda (this args)
     (declare (ignore args))
     (unless (js-writable-stream-writer-p this)
       (eng:throw-type-error "Illegal invocation"))
     (%writer-close this)))
  (%install-prototype-method
   prototype "abort" 1
   (lambda (this args)
     (unless (js-writable-stream-writer-p this)
       (eng:throw-type-error "Illegal invocation"))
     (%writer-abort this (eng:arg args 0))))
  (%install-prototype-method
   prototype "releaseLock" 0
   (lambda (this args)
     (declare (ignore args))
     (unless (js-writable-stream-writer-p this)
       (eng:throw-type-error "Illegal invocation"))
     (%writer-release-lock this)))
  (%define-data prototype (eng:well-known :to-string-tag)
                "WritableStreamDefaultWriter"
                :writable nil :enumerable nil :configurable t)
  prototype)

(defun %install-writable-stream-controller-prototype (prototype)
  (%install-prototype-method
   prototype "error" 1
   (lambda (this args)
     (unless (js-writable-stream-controller-p this)
       (eng:throw-type-error "Illegal invocation"))
     (%writable-error (js-writable-stream-controller-stream this)
                      (eng:arg args 0))))
  (%define-data prototype (eng:well-known :to-string-tag)
                "WritableStreamDefaultController"
                :writable nil :enumerable nil :configurable t)
  prototype)

(defun %install-writable-stream-prototype (prototype)
  (%define-accessor
   prototype "locked"
   (lambda (this args)
     (declare (ignore args))
     (unless (js-writable-stream-p this)
       (eng:throw-type-error "Illegal invocation"))
     (eng:js-boolean (js-writable-stream-locked-p this)))
   nil)
  (%install-prototype-method
   prototype "getWriter" 0
   (lambda (this args)
     (declare (ignore args))
     (unless (js-writable-stream-p this)
       (eng:throw-type-error "Illegal invocation"))
     (%make-default-writer this)))
  (%install-prototype-method
   prototype "abort" 1
   (lambda (this args)
     (unless (js-writable-stream-p this)
       (eng:throw-type-error "Illegal invocation"))
     (if (js-writable-stream-locked-p this)
         (%rejected-promise
          (eng:realm-global eng:*realm*)
          (%stream-error-type "Cannot abort a locked stream"))
         (let ((writer (%make-default-writer this)))
           (%writer-abort writer (eng:arg args 0))))))
  (%install-prototype-method
   prototype "close" 0
   (lambda (this args)
     (declare (ignore args))
     (unless (js-writable-stream-p this)
       (eng:throw-type-error "Illegal invocation"))
     (if (js-writable-stream-locked-p this)
         (%rejected-promise
          (eng:realm-global eng:*realm*)
          (%stream-error-type "Cannot close a locked stream"))
         (let ((writer (%make-default-writer this)))
           (%writer-close writer)))))
  (%define-data prototype (eng:well-known :to-string-tag) "WritableStream"
                :writable nil :enumerable nil :configurable t)
  prototype)

(defun %writable-controller-for (stream)
  (%make-js-writable-stream-controller
   :proto (web-http-realm-state-writable-stream-controller-prototype
           (%http-state))
   :stream stream))

(defun %construct-writable-stream (underlying-sink)
  "Minimal `new WritableStream({ start, write, close, abort })`."
  (let* ((stream
           (%make-js-writable-stream
            :proto (web-http-realm-state-writable-stream-prototype
                    (%http-state))))
         (controller (%writable-controller-for stream))
         (sink (if (eng:js-object-p underlying-sink)
                   underlying-sink
                   eng:+undefined+)))
    (setf (js-writable-stream-controller stream) controller)
    (%writable-closed-deferred stream)
    (unless (eng:js-undefined-p sink)
      (setf (js-writable-stream-underlying-sink stream) sink)
      (let ((write (eng:js-get sink "write")))
        (when (eng:callable-p write)
          (setf (js-writable-stream-write-callback stream) write)))
      (let ((close (eng:js-get sink "close")))
        (when (eng:callable-p close)
          (setf (js-writable-stream-close-callback stream) close)))
      (let ((abort (eng:js-get sink "abort")))
        (when (eng:callable-p abort)
          (setf (js-writable-stream-abort-callback stream) abort)))
      (let ((start (eng:js-get sink "start")))
        (when (eng:callable-p start)
          (handler-case
              (eng:js-call start sink (list controller))
            (eng:js-condition (c)
              (%writable-error stream (eng:js-condition-value c)))
            (error (e)
              (%writable-error stream
                               (%stream-error-type (princ-to-string e))))))))
    stream))

(defun %make-writable-stream-constructor (prototype)
  (let ((constructor
          (eng:make-native-function
           "WritableStream" 0
           (lambda (this args)
             (declare (ignore this args))
             (eng:throw-type-error "WritableStream requires 'new'"))
           :construct
           (lambda (args new-target)
             (declare (ignore new-target))
             (%construct-writable-stream (eng:arg args 0))))))
    (%set-constructor-prototype constructor prototype)
    constructor))

;;; --- TransformStream (pure-CL) ---------------------------------------------

(defun %transform-controller-enqueue (controller chunk)
  (let* ((ts (js-transform-stream-controller-stream controller))
         (readable (js-transform-stream-readable ts)))
    (%stream-enqueue readable chunk)
    eng:+undefined+))

(defun %transform-controller-error (controller reason)
  (let* ((ts (js-transform-stream-controller-stream controller))
         (readable (js-transform-stream-readable ts))
         (writable (js-transform-stream-writable ts)))
    (%stream-error readable reason)
    (%writable-error writable reason)
    eng:+undefined+))

(defun %transform-controller-terminate (controller)
  (let* ((ts (js-transform-stream-controller-stream controller))
         (readable (js-transform-stream-readable ts))
         (writable (js-transform-stream-writable ts)))
    (%stream-close readable)
    (%writable-error writable
                     (%stream-error-type "TransformStream terminated"))
    eng:+undefined+))

(defun %transform-handle-write (ts chunk)
  (let* ((global (eng:realm-global eng:*realm*))
         (controller (js-transform-stream-controller ts))
         (this-arg (or (js-transform-stream-transformer ts) eng:+undefined+))
         (fn (js-transform-stream-transform-callback ts)))
    (if (eng:callable-p fn)
        (%call-sink-method fn this-arg (list chunk controller) global)
        (progn
          (%transform-controller-enqueue controller chunk)
          (%resolved-promise global eng:+undefined+)))))

(defun %transform-handle-close (ts)
  (let* ((global (eng:realm-global eng:*realm*))
         (controller (js-transform-stream-controller ts))
         (readable (js-transform-stream-readable ts))
         (writable (js-transform-stream-writable ts))
         (this-arg (or (js-transform-stream-transformer ts) eng:+undefined+))
         (fn (js-transform-stream-flush-callback ts))
         (p (if (eng:callable-p fn)
                (%call-sink-method fn this-arg (list controller) global)
                (%resolved-promise global eng:+undefined+))))
    (eng:js-call
     (eng:js-get p "then") p
     (list (eng:make-native-function
            "" 1
            (lambda (this a)
              (declare (ignore this a))
              (%stream-close readable)
              (setf (js-writable-stream-closed-p writable) t)
              (%writable-resolve-closed writable)
              eng:+undefined+))
           (eng:make-native-function
            "" 1
            (lambda (this a)
              (declare (ignore this))
              (let ((reason (eng:arg a 0)))
                (%stream-error readable reason)
                (%writable-error writable reason))
              eng:+undefined+))))
    p))

(defun %transform-handle-abort (ts reason)
  (let* ((global (eng:realm-global eng:*realm*))
         (readable (js-transform-stream-readable ts))
         (writable (js-transform-stream-writable ts))
         (err (if (or (eng:js-undefined-p reason) (eng:js-nullish-p reason))
                  (%stream-error-type "Aborted")
                  reason)))
    (%stream-error readable err)
    (%writable-error writable err)
    (%resolved-promise global eng:+undefined+)))

(defun %install-transform-stream-controller-prototype (prototype)
  (%install-prototype-method
   prototype "enqueue" 1
   (lambda (this args)
     (unless (js-transform-stream-controller-p this)
       (eng:throw-type-error "Illegal invocation"))
     (%transform-controller-enqueue this (eng:arg args 0))))
  (%install-prototype-method
   prototype "error" 1
   (lambda (this args)
     (unless (js-transform-stream-controller-p this)
       (eng:throw-type-error "Illegal invocation"))
     (%transform-controller-error this (eng:arg args 0))))
  (%install-prototype-method
   prototype "terminate" 0
   (lambda (this args)
     (declare (ignore args))
     (unless (js-transform-stream-controller-p this)
       (eng:throw-type-error "Illegal invocation"))
     (%transform-controller-terminate this)))
  (%define-data prototype (eng:well-known :to-string-tag)
                "TransformStreamDefaultController"
                :writable nil :enumerable nil :configurable t)
  prototype)

(defun %install-transform-stream-prototype (prototype)
  (%define-accessor
   prototype "readable"
   (lambda (this args)
     (declare (ignore args))
     (unless (js-transform-stream-p this)
       (eng:throw-type-error "Illegal invocation"))
     (js-transform-stream-readable this))
   nil)
  (%define-accessor
   prototype "writable"
   (lambda (this args)
     (declare (ignore args))
     (unless (js-transform-stream-p this)
       (eng:throw-type-error "Illegal invocation"))
     (js-transform-stream-writable this))
   nil)
  (%define-data prototype (eng:well-known :to-string-tag) "TransformStream"
                :writable nil :enumerable nil :configurable t)
  prototype)

(defun %construct-transform-stream (transformer)
  "Minimal `new TransformStream({ start, transform, flush })`."
  (let* ((state (%http-state))
         (ts
           (%make-js-transform-stream
            :proto (web-http-realm-state-transform-stream-prototype state)))
         (controller
           (%make-js-transform-stream-controller
            :proto (web-http-realm-state-transform-stream-controller-prototype
                    state)
            :stream ts))
         (readable
           (%new-readable-stream :closed-p nil :wait-for-data-p t))
         (writable
           (%make-js-writable-stream
            :proto (web-http-realm-state-writable-stream-prototype state)
            :transform ts))
         (source (if (eng:js-object-p transformer)
                     transformer
                     eng:+undefined+)))
    (setf (js-writable-stream-controller writable)
          (%writable-controller-for writable))
    (%writable-closed-deferred writable)
    (setf (js-transform-stream-readable ts) readable
          (js-transform-stream-writable ts) writable
          (js-transform-stream-controller ts) controller)
    (unless (eng:js-undefined-p source)
      (setf (js-transform-stream-transformer ts) source)
      (let ((transform (eng:js-get source "transform")))
        (when (eng:callable-p transform)
          (setf (js-transform-stream-transform-callback ts) transform)))
      (let ((flush (eng:js-get source "flush")))
        (when (eng:callable-p flush)
          (setf (js-transform-stream-flush-callback ts) flush)))
      (let ((start (eng:js-get source "start")))
        (when (eng:callable-p start)
          (handler-case
              (eng:js-call start source (list controller))
            (eng:js-condition (c)
              (%transform-controller-error
               controller (eng:js-condition-value c)))
            (error (e)
              (%transform-controller-error
               controller
               (%stream-error-type (princ-to-string e))))))))
    ;; Default identity transform when none provided.
    (unless (eng:callable-p (js-transform-stream-transform-callback ts))
      (setf (js-transform-stream-transform-callback ts)
            (eng:make-native-function
             "transform" 2
             (lambda (this args)
               (declare (ignore this))
               (%transform-controller-enqueue
                (eng:arg args 1) (eng:arg args 0))
               eng:+undefined+))))
    ts))

(defun %make-transform-stream-constructor (prototype)
  (let ((constructor
          (eng:make-native-function
           "TransformStream" 0
           (lambda (this args)
             (declare (ignore this args))
             (eng:throw-type-error "TransformStream requires 'new'"))
           :construct
           (lambda (args new-target)
             (declare (ignore new-target))
             (%construct-transform-stream (eng:arg args 0))))))
    (%set-constructor-prototype constructor prototype)
    constructor))

(defun %body-stream-for (value body-function)
  "Return (and cache) a one-chunk ReadableStream for a Request/Response body.
Access alone does not mark bodyUsed or materialize Clun.file bodies;
getReader/read or mixin consumers do."
  (let ((existing (%body-stream-slot value)))
    (cond
      ((js-readable-stream-p existing)
       (return-from %body-stream-for existing))
      ((js-body-stream-p existing)
       (return-from %body-stream-for existing))
      ((%body-used-p value)
       (return-from %body-stream-for eng:+null+))
      ((%body-is-absent-p value)
       (return-from %body-stream-for eng:+null+)))
    (let* ((kind (cond ((js-response-p value) :response)
                       ((js-request-p value) :request)
                       (t nil)))
           (stream
             (%new-readable-stream
              :queue '()
              :closed-p nil
              :owner value
              :owner-kind kind
              :lazy-body-p t
              :lazy-body-function body-function)))
      (%set-body-stream-slot value stream)
      stream)))

(defun %install-body-methods (prototype require-function body-function)
  (let ((global (eng:realm-global eng:*realm*)))
    (%define-accessor
     prototype "bodyUsed"
     (lambda (this args) (declare (ignore args))
       (funcall require-function this)
       (eng:js-boolean (%body-used-p this)))
     nil)
    ;; Accessing .body does not consume buffered bodies; getReader/read does.
    ;; Stress fixtures probe the getter without reading bytes.
    (%define-accessor
     prototype "body"
     (lambda (this args) (declare (ignore args))
       (funcall require-function this)
       (%body-stream-for this body-function))
     nil)
    (%install-prototype-method
     prototype "text" 0
     (lambda (this args) (declare (ignore args))
       (funcall require-function this)
       (%resolved-promise global
                          (%body-text-decode
                           (%consume-body-octets this body-function)))))
    (%install-prototype-method
     prototype "blob" 0
     (lambda (this args) (declare (ignore args))
       (funcall require-function this)
       (let ((octets (%consume-body-octets this body-function)))
         (%resolved-promise
          global
          (%make-js-blob
           :proto (web-http-realm-state-blob-prototype (%http-state))
           :bytes octets
           :type (%normalize-blob-type (%body-content-type this)))))))
    (%install-prototype-method
     prototype "bytes" 0
     (lambda (this args) (declare (ignore args))
       (funcall require-function this)
       (%resolved-promise
        global
        (eng:u8-from-octets (%consume-body-octets this body-function)))))
    (%install-prototype-method
     prototype "arrayBuffer" 0
     (lambda (this args) (declare (ignore args))
       (funcall require-function this)
       (%resolved-promise
        global
        (eng:js-get
         (eng:u8-from-octets (%consume-body-octets this body-function))
         "buffer"))))
    (%install-prototype-method
     prototype "json" 0
     (lambda (this args) (declare (ignore args))
       (funcall require-function this)
       (let ((json (eng:js-get global "JSON"))
             (octets (%consume-body-octets this body-function)))
         (%resolved-promise
          global
          (eng:js-call (eng:js-get json "parse") json
                       (list (%body-text-decode octets)))))))))

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

;;; --- response body streams -------------------------------------------------

(defun %body-stream-error-object (message)
  (eng:make-error-object :type-error-prototype "TypeError" message))

(defun %body-iterator-result (value done-p)
  (let ((result (eng:new-object)))
    (eng:data-prop result "value" value)
    (eng:data-prop result "done" (eng:js-boolean done-p))
    result))

(defun %body-resolve (function value)
  (eng:js-call function eng:+undefined+ (list value)))

(defun %body-stream-terminal (stream)
  (let ((callback (js-body-stream-terminal-callback stream)))
    (when callback
      (setf (js-body-stream-terminal-callback stream) nil)
      (funcall callback))))

(defun %body-stream-queue-push (stream chunk)
  (let ((cell (list chunk)))
    (if (js-body-stream-queue-tail stream)
        (setf (cdr (js-body-stream-queue-tail stream)) cell
              (js-body-stream-queue-tail stream) cell)
        (setf (js-body-stream-queue stream) cell
              (js-body-stream-queue-tail stream) cell)))
  (incf (js-body-stream-queued-bytes stream) (length chunk)))

(defun %body-stream-queue-pop (stream)
  (let ((chunk (car (js-body-stream-queue stream))))
    (when chunk
      (setf (js-body-stream-queue stream)
            (cdr (js-body-stream-queue stream)))
      (unless (js-body-stream-queue stream)
        (setf (js-body-stream-queue-tail stream) nil))
      (decf (js-body-stream-queued-bytes stream) (length chunk)))
    chunk))

(defun %body-stream-pending-push (stream request)
  (let ((cell (list request)))
    (if (js-body-stream-pending-tail stream)
        (setf (cdr (js-body-stream-pending-tail stream)) cell
              (js-body-stream-pending-tail stream) cell)
        (setf (js-body-stream-pending stream) cell
              (js-body-stream-pending-tail stream) cell))))

(defun %body-stream-pending-pop (stream)
  (let ((request (car (js-body-stream-pending stream))))
    (when request
      (setf (js-body-stream-pending stream)
            (cdr (js-body-stream-pending stream)))
      (unless (js-body-stream-pending stream)
        (setf (js-body-stream-pending-tail stream) nil)))
    request))

(defun %body-stream-resolve-read (request chunk done-p)
  (%body-resolve
   (body-read-request-resolve request)
   (%body-iterator-result
    (if done-p eng:+undefined+ (eng:u8-from-octets chunk))
    done-p)))

(defun %body-stream-reject-read (request reason)
  (%body-resolve (body-read-request-reject request) reason))

(defun %body-stream-maybe-resume (stream)
  (when (and (js-body-stream-backpressured-p stream)
             (<= (js-body-stream-queued-bytes stream)
                 (js-body-stream-low-water stream)))
    (setf (js-body-stream-backpressured-p stream) nil)
    (let ((resume (js-body-stream-resume stream)))
      (when resume (funcall resume)))))

(defun %body-collector-append (collector chunk)
  (let* ((buffer (body-collector-buffer collector))
         (old (fill-pointer buffer))
         (next (+ old (length chunk)))
         (limit net:*max-body-bytes*))
    (when (> next limit)
      (error "response body exceeded the size limit"))
    (when (> next (array-total-size buffer))
      (adjust-array buffer
                    (min limit
                         (max next (* 2 (max 1 (array-total-size buffer)))))
                    :fill-pointer old))
    (setf (fill-pointer buffer) next)
    (replace buffer chunk :start1 old)))

(defun %body-collector-reject (stream reason)
  (let ((collector (js-body-stream-collector stream)))
    (when collector
      (setf (js-body-stream-collector stream) nil
            (js-body-stream-locked-p stream) nil)
      (%body-resolve (body-collector-reject collector) reason))))

(defun %body-collector-finish (stream)
  (let ((collector (js-body-stream-collector stream)))
    (when collector
      (setf (js-body-stream-collector stream) nil
            (js-body-stream-locked-p stream) nil)
      (let ((octets
              (subseq (body-collector-buffer collector) 0
                      (fill-pointer (body-collector-buffer collector)))))
        (handler-case
            (%body-resolve
             (body-collector-resolve collector)
             (funcall (body-collector-transform collector) octets))
          (eng:js-condition (condition)
            (%body-resolve (body-collector-reject collector)
                           (eng:js-condition-value condition)))
          (error (condition)
            (%body-resolve
             (body-collector-reject collector)
             (%body-stream-error-object (princ-to-string condition)))))))))

(defun %body-stream-enqueue (stream chunk)
  "Hand one transport chunk to STREAM and apply its high-water backpressure."
  (when (and (not (js-body-stream-closed-p stream))
             (not (js-body-stream-errored-p stream))
             (plusp (length chunk)))
    (if (js-body-stream-tee-targets stream)
        (dolist (target (js-body-stream-tee-targets stream))
          (%body-stream-enqueue target chunk))
        (cond
          ((js-body-stream-collector stream)
           (handler-case
               (%body-collector-append (js-body-stream-collector stream) chunk)
             (error (condition)
               (%body-stream-error
                stream (%body-stream-error-object (princ-to-string condition))))))
          ((js-body-stream-pending stream)
           (%body-stream-resolve-read
            (%body-stream-pending-pop stream) chunk nil))
          (t
           (%body-stream-queue-push stream chunk)
           (when (and (not (js-body-stream-backpressured-p stream))
                      (>= (js-body-stream-queued-bytes stream)
                          (js-body-stream-high-water stream)))
             (setf (js-body-stream-backpressured-p stream) t)
             (let ((pause (js-body-stream-pause stream)))
               (when pause (funcall pause))))))))
  stream)

(defun %body-stream-close (stream)
  (unless (or (js-body-stream-closed-p stream)
              (js-body-stream-errored-p stream))
    (setf (js-body-stream-closed-p stream) t)
    (if (js-body-stream-tee-targets stream)
        (dolist (target (js-body-stream-tee-targets stream))
          (%body-stream-close target))
        (progn
          (loop for request = (%body-stream-pending-pop stream)
                while request
                do (%body-stream-resolve-read request nil t))
          (%body-collector-finish stream)))
    (%body-stream-terminal stream))
  stream)

(defun %body-stream-error (stream reason)
  (unless (or (js-body-stream-closed-p stream)
              (js-body-stream-errored-p stream))
    (setf (js-body-stream-errored-p stream) t
          (js-body-stream-error stream) reason
          (js-body-stream-queue stream) nil
          (js-body-stream-queue-tail stream) nil
          (js-body-stream-queued-bytes stream) 0)
    (if (js-body-stream-tee-targets stream)
        (dolist (target (js-body-stream-tee-targets stream))
          (%body-stream-error target reason))
        (progn
          (loop for request = (%body-stream-pending-pop stream)
                while request
                do (%body-stream-reject-read request reason))
          (%body-collector-reject stream reason)))
    (%body-stream-maybe-resume stream)
    (%body-stream-terminal stream))
  stream)

(defun %body-stream-cancel-now (stream reason)
  (declare (ignore reason))
  ;; Cancel always disturbs the stream and drops residual chunks, including
  ;; already-closed buffered Response bodies (string init enqueues then closes).
  (let ((cancel (js-body-stream-cancel stream))
        (was-open-p (not (or (js-body-stream-closed-p stream)
                             (js-body-stream-errored-p stream)))))
    (setf (js-body-stream-cancel stream) nil
          (js-body-stream-queue stream) nil
          (js-body-stream-queue-tail stream) nil
          (js-body-stream-queued-bytes stream) 0
          (js-body-stream-closed-p stream) t
          (js-body-stream-disturbed-p stream) t)
    (loop for request = (%body-stream-pending-pop stream)
          while request
          do (%body-stream-resolve-read request nil t))
    (%body-collector-finish stream)
    (when was-open-p
      (%body-stream-maybe-resume stream)
      (%body-stream-terminal stream)
      (when cancel (funcall cancel))))
  stream)

(defun %body-reader-read (reader)
  (multiple-value-bind (promise resolve reject) (eng::promise-and-caps)
    (let ((stream (js-body-reader-stream reader)))
      (cond
        ((js-body-reader-released-p reader)
         (%body-resolve reject
                        (%body-stream-error-object
                         "The reader has been released")))
        (t
         (setf (js-body-stream-disturbed-p stream) t)
         (cond
           ((js-body-stream-queue stream)
            (%body-stream-resolve-read
             (%make-body-read-request :reader reader
                                      :resolve resolve :reject reject)
             (%body-stream-queue-pop stream) nil)
            (%body-stream-maybe-resume stream))
           ((js-body-stream-errored-p stream)
            (%body-resolve reject (js-body-stream-error stream)))
           ((js-body-stream-closed-p stream)
            (%body-stream-resolve-read
             (%make-body-read-request :reader reader
                                      :resolve resolve :reject reject)
             nil t))
           (t
            (%body-stream-pending-push
             stream
             (%make-body-read-request :reader reader
                                      :resolve resolve :reject reject)))))))
    promise))

(defun %body-reader-has-pending-p (reader)
  (find reader (js-body-stream-pending (js-body-reader-stream reader))
        :key #'body-read-request-reader :test #'eq))

(defun %body-reader-release (reader)
  (unless (js-body-reader-released-p reader)
    (when (%body-reader-has-pending-p reader)
      (eng:throw-type-error "Cannot release a reader with pending read requests"))
    (setf (js-body-reader-released-p reader) t
          (js-body-stream-locked-p (js-body-reader-stream reader)) nil))
  eng:+undefined+)

(defun %body-tee-active-p (tee)
  (or (body-tee-first-active-p tee)
      (body-tee-second-active-p tee)))

(defun %body-tee-sync-backpressure (tee)
  (let* ((source (body-tee-source tee))
         (blocked-p
           (or (and (body-tee-first-active-p tee)
                    (js-body-stream-backpressured-p (body-tee-first tee)))
               (and (body-tee-second-active-p tee)
                    (js-body-stream-backpressured-p (body-tee-second tee))))))
    (cond
      ((and blocked-p (not (body-tee-transport-paused-p tee)))
       (setf (body-tee-transport-paused-p tee) t
             (js-body-stream-backpressured-p source) t)
       (let ((pause (js-body-stream-pause source)))
         (when pause (funcall pause))))
      ((and (not blocked-p) (body-tee-transport-paused-p tee))
       (setf (body-tee-transport-paused-p tee) nil
             (js-body-stream-backpressured-p source) nil)
       (let ((resume (js-body-stream-resume source)))
         (when resume (funcall resume))))))
  tee)

(defun %body-tee-cancel-branch (tee branch)
  (cond
    ((eq branch (body-tee-first tee))
     (setf (body-tee-first-active-p tee) nil))
    ((eq branch (body-tee-second tee))
     (setf (body-tee-second-active-p tee) nil)))
  (if (%body-tee-active-p tee)
      (%body-tee-sync-backpressure tee)
      (progn
        (setf (body-tee-transport-paused-p tee) nil
              (js-body-stream-backpressured-p (body-tee-source tee)) nil)
        (%body-stream-cancel-now (body-tee-source tee) eng:+undefined+)))
  (values))

(defun %body-stream-reader (stream)
  (when (js-body-stream-locked-p stream)
    (eng:throw-type-error "ReadableStream is locked"))
  (let ((reader
          (%make-js-body-reader
           :proto (eng:intrinsic :object-prototype) :stream stream)))
    (setf (js-body-stream-locked-p stream) t)
    (let ((read-function
            (eng:make-native-function
             "read" 0
             (lambda (this args)
               (declare (ignore args))
               (%body-reader-read
                (if (js-body-reader-p this)
                    this
                    (eng:throw-type-error "Illegal invocation")))))))
      (eng:data-prop reader "read" read-function)
      (eng:data-prop reader "next" read-function))
    (eng:install-method
     reader "cancel" 1
     (lambda (this args)
       (unless (js-body-reader-p this)
         (eng:throw-type-error "Illegal invocation"))
       (if (js-body-reader-released-p this)
           (%rejected-promise
            (eng:realm-global eng:*realm*)
            (%body-stream-error-object "The reader has been released"))
           (progn
             (%body-stream-cancel-now
              (js-body-reader-stream this) (eng:arg args 0))
             (%resolved-promise
              (eng:realm-global eng:*realm*) eng:+undefined+)))))
    (eng:install-method
     reader "releaseLock" 0
     (lambda (this args)
       (declare (ignore args))
       (%body-reader-release
        (if (js-body-reader-p this)
            this
            (eng:throw-type-error "Illegal invocation")))))
    (eng:install-method
     reader "return" 1
     (lambda (this args)
       (unless (js-body-reader-p this)
         (eng:throw-type-error "Illegal invocation"))
       (%body-stream-cancel-now (js-body-reader-stream this) (eng:arg args 0))
       (setf (js-body-reader-released-p this) t
             (js-body-stream-locked-p (js-body-reader-stream this)) nil)
       (%resolved-promise
        (eng:realm-global eng:*realm*)
        (%body-iterator-result eng:+undefined+ t))))
    (eng:create-data-property
     reader (eng:well-known :async-iterator)
     (eng:make-native-function
      "[Symbol.asyncIterator]" 0
      (lambda (this args) (declare (ignore args)) this)))
    reader))

(defun %new-body-stream (&key cancel pause resume terminal-callback
                              (high-water (* 1024 1024))
                              (low-water (* 512 1024)))
  (let* ((state (ignore-errors (%http-state)))
         (proto (or (and state
                         (web-http-realm-state-readable-stream-prototype state))
                    (eng:intrinsic :object-prototype)))
         (stream
           (%make-js-body-stream
            :proto proto
            :cancel cancel :pause pause :resume resume
            :terminal-callback terminal-callback
            :high-water high-water :low-water low-water)))
    (eng:install-getter
     stream "locked"
     (lambda (this args)
       (declare (ignore args))
       (eng:js-boolean
        (js-body-stream-locked-p
         (if (js-body-stream-p this)
             this
             (eng:throw-type-error "Illegal invocation"))))))
    (eng:install-method
     stream "getReader" 0
     (lambda (this args)
       (declare (ignore args))
       (%body-stream-reader
        (if (js-body-stream-p this)
            this
            (eng:throw-type-error "Illegal invocation")))))
    (eng:install-method
     stream "cancel" 1
     (lambda (this args)
       (unless (js-body-stream-p this)
         (eng:throw-type-error "Illegal invocation"))
       (if (js-body-stream-locked-p this)
           (%rejected-promise
            (eng:realm-global eng:*realm*)
            (%body-stream-error-object "Cannot cancel a locked ReadableStream"))
           (progn
             (%body-stream-cancel-now this (eng:arg args 0))
             (%resolved-promise
              (eng:realm-global eng:*realm*) eng:+undefined+)))))
    (eng:install-method
     stream "tee" 0
     (lambda (this args)
       (declare (ignore args))
       (multiple-value-bind (first second)
           (%body-stream-tee
            (if (js-body-stream-p this)
                this
                (eng:throw-type-error "Illegal invocation")))
         (eng:new-array (list first second)))))
    (let ((iterator-function
            (eng:make-native-function
             "values" 0
             (lambda (this args)
               (declare (ignore args))
               (%body-stream-reader
                (if (js-body-stream-p this)
                    this
                    (eng:throw-type-error "Illegal invocation")))))))
      (eng:data-prop stream "values" iterator-function)
      (eng:create-data-property stream (eng:well-known :async-iterator)
                                iterator-function))
    stream))

(defun %body-stream-tee
    (source &key (high-water net:*max-body-bytes*)
                 (low-water (floor net:*max-body-bytes* 2)))
  "Lock SOURCE and return two bounded branches fed by its current and future bytes."
  (when (js-body-stream-locked-p source)
    (eng:throw-type-error "ReadableStream is locked"))
  (let* ((first (%new-body-stream :high-water high-water :low-water low-water))
         (second (%new-body-stream :high-water high-water :low-water low-water))
         (tee
           (%make-body-tee
            :source source :first first :second second
            :transport-paused-p (js-body-stream-backpressured-p source))))
    (%body-stream-bind-transport
     first
     :cancel (lambda () (%body-tee-cancel-branch tee first))
     :pause (lambda () (%body-tee-sync-backpressure tee))
     :resume (lambda () (%body-tee-sync-backpressure tee)))
    (%body-stream-bind-transport
     second
     :cancel (lambda () (%body-tee-cancel-branch tee second))
     :pause (lambda () (%body-tee-sync-backpressure tee))
     :resume (lambda () (%body-tee-sync-backpressure tee)))
    (setf (js-body-stream-locked-p source) t
          (js-body-stream-tee-targets source) (list first second))
    (loop for chunk = (%body-stream-queue-pop source)
          while chunk
          do (%body-stream-enqueue first chunk)
             (%body-stream-enqueue second chunk))
    (cond
      ((js-body-stream-errored-p source)
       (%body-stream-error first (js-body-stream-error source))
       (%body-stream-error second (js-body-stream-error source)))
      ((js-body-stream-closed-p source)
       (%body-stream-close first)
       (%body-stream-close second))
      (t (%body-tee-sync-backpressure tee)))
    (values first second)))

(defun %body-stream-bind-transport
    (stream &key cancel pause resume terminal-callback)
  (setf (js-body-stream-cancel stream) cancel
        (js-body-stream-pause stream) pause
        (js-body-stream-resume stream) resume
        (js-body-stream-terminal-callback stream) terminal-callback)
  stream)

(defun %body-stream-consume (stream transform)
  (multiple-value-bind (promise resolve reject) (eng::promise-and-caps)
    (cond
      ((or (js-body-stream-disturbed-p stream)
           (js-body-stream-locked-p stream))
       (%body-resolve
        reject
        (%body-stream-error-object "Body has already been consumed")))
      (t
       (setf (js-body-stream-disturbed-p stream) t
             (js-body-stream-locked-p stream) t
             (js-body-stream-collector stream)
             (%make-body-collector :resolve resolve :reject reject
                                   :transform transform))
       (handler-case
           (loop for chunk = (%body-stream-queue-pop stream)
                 while chunk
                 do (%body-collector-append
                     (js-body-stream-collector stream) chunk))
         (error (condition)
           (%body-stream-error
            stream (%body-stream-error-object (princ-to-string condition)))))
       (%body-stream-maybe-resume stream)
       (cond
         ((js-body-stream-errored-p stream)
          (%body-collector-reject stream (js-body-stream-error stream)))
         ((js-body-stream-closed-p stream)
          (%body-collector-finish stream)))))
    promise))
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
            (%normalize-blob-type (eng:to-string value))))
      ""))

(defun %new-blob-from-octets (octets &optional (type ""))
  "Construct a Blob from raw octets for shell ShellOutput / $.blob helpers."
  (%make-js-blob
   :proto (web-http-realm-state-blob-prototype (%http-state))
   :bytes (coerce (copy-seq octets) '(simple-array (unsigned-byte 8) (*)))
   :type (%normalize-blob-type type)))

(defun %new-blob (parts options)
  (%new-blob-from-octets (%blob-parts-octets parts) (%blob-type-option options)))

(defun %blob-octets-copy (blob)
  "Return a fresh octet vector for BLOB (shell redirections and body copies)."
  (copy-seq (js-blob-bytes (%require-blob blob))))

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

(defun %response-stream (response)
  (js-response-body-stream (%require-response response)))

(defun %materialize-deferred-file-body (response)
  "Copy a deferred Clun.file body into RESPONSE's ReadableStream once.

`new Response(Clun.file(...))` deliberately keeps the file plan lazy so construction
never blocks on FIFO/special files. Server serialization uses the file handle directly;
body consumers (text/bytes/blob/getReader) call this helper first."
  (let ((body (js-response-body response))
        (stream (js-response-body-stream response)))
    (when (and (js-clun-file-p body)
               stream
               (not (js-body-stream-closed-p stream))
               (not (js-body-stream-errored-p stream))
               (null (js-body-stream-queue stream))
               (null (js-body-stream-collector stream))
               (null (js-body-stream-pending stream)))
      (let ((octets
              (handler-case (%clun-file-octets body)
                (error ()
                  (make-array 0 :element-type '(unsigned-byte 8))))))
        (when (plusp (length octets))
          (%body-stream-enqueue stream octets))
        (%body-stream-close stream))))
  response)

(defun %clone-response (value)
  (let* ((response (%require-response value))
         (stream (js-response-body-stream response))
         (body (js-response-body response)))
    (when (or (js-body-stream-disturbed-p stream)
              (js-body-stream-locked-p stream))
      (eng:throw-type-error "Body has already been consumed"))
    (flet ((copy-response-metadata (clone)
             (eng:data-prop clone "status" (eng:js-get response "status"))
             (eng:data-prop clone "statusText" (eng:js-get response "statusText"))
             (eng:data-prop clone "ok" (eng:js-get response "ok"))
             (eng:data-prop clone "headers"
                            (%new-headers (eng:js-get response "headers")))
             (let ((url (eng:js-get response "url")))
               (unless (eng:js-undefined-p url)
                 (eng:data-prop clone "url" url)))
             clone))
      (if (and (js-clun-file-p body)
               (not (js-body-stream-closed-p stream))
               (null (js-body-stream-queue stream)))
          ;; Deferred file plans clone by reference without opening the path.
          (copy-response-metadata
           (%make-js-response
            :proto (web-http-realm-state-response-prototype (%http-state))
            :body body
            :body-stream (%new-body-stream)
            :body-null-p (js-response-body-null-p response)))
          (multiple-value-bind (first second) (%body-stream-tee stream)
            (setf (js-response-body-stream response) first)
            (copy-response-metadata
             (%make-js-response
              :proto (web-http-realm-state-response-prototype (%http-state))
              :body body
              :body-stream second
              :body-null-p (js-response-body-null-p response))))))))

(defun %install-response-body-method
    (prototype name transform)
  (%install-prototype-method
   prototype name 0
   (lambda (this args)
     (declare (ignore args))
     (let* ((response (%require-response this))
            (stream (js-response-body-stream response)))
       (when (or (%body-used-p response)
                 (and (js-body-stream-p stream)
                      (or (js-body-stream-disturbed-p stream)
                          (js-body-stream-locked-p stream))))
         (eng:throw-type-error
          (if (and (js-body-stream-p stream)
                   (js-body-stream-locked-p stream)
                   (not (js-body-stream-disturbed-p stream)))
              "Body stream is locked"
              "Body has already been used")))
       (%materialize-deferred-file-body response)
       (%body-stream-consume (js-response-body-stream response) transform)))))

(defun %install-response-prototype (prototype)
  (let ((global (eng:realm-global eng:*realm*)))
    (%install-response-body-method
     prototype "text" #'%body-text-decode)
    (%install-response-body-method
     prototype "bytes" #'eng:u8-from-octets)
    (%install-response-body-method
     prototype "arrayBuffer"
     (lambda (octets)
       (eng:js-get (eng:u8-from-octets octets) "buffer")))
    (%install-response-body-method
     prototype "json"
     (lambda (octets)
       (let ((json (eng:js-get global "JSON")))
         (eng:js-call (eng:js-get json "parse") json
                      (list (%body-text-decode octets)))))))
  (%define-accessor
   prototype "body"
   (lambda (this args)
     (declare (ignore args))
     (let ((response (%require-response this)))
       (if (js-response-body-null-p response)
           eng:+null+
           (progn
             (%materialize-deferred-file-body response)
             (js-response-body-stream response)))))
   nil)
  (%define-accessor
   prototype "bodyUsed"
   (lambda (this args)
     (declare (ignore args))
     (eng:js-boolean
      (js-body-stream-disturbed-p (%response-stream this))))
   nil)
  (%install-prototype-method
   prototype "blob" 0
   (lambda (this args)
     (declare (ignore args))
     (let ((response (%require-response this))
           (type (%normalize-blob-type (%body-content-type this))))
       (%materialize-deferred-file-body response)
       (%body-stream-consume
        (js-response-body-stream response)
        (lambda (octets)
          (%make-js-blob
           :proto (web-http-realm-state-blob-prototype (%http-state))
           :bytes octets
           :type type))))))
  (%install-prototype-method
   prototype "clone" 0
   (lambda (this args)
     (declare (ignore args))
     (%clone-response this)))
  prototype)

(defun %response-streaming-body-p (response)
  "True when RESPONSE should be written with Transfer-Encoding: chunked.

Explicit null bodies use Content-Length: 0. ReadableStream bodies are chunked
even when the stream has already closed with queued chunks."
  (let* ((response (%require-response response))
         (body (js-response-body response))
         (stream (js-response-body-stream response)))
    (cond
      ((js-response-body-null-p response) nil)
      ((js-readable-stream-p stream) t)
      ((js-readable-stream-p body) t)
      ((js-body-stream-p body) t)
      ((and (js-body-stream-p stream)
            (or (null body) (eng:js-null-p body) (eng:js-undefined-p body)))
       t)
      (t nil))))

(defun %init-response (object body init &key body-stream body-null-p)
  "Populate and return a branded Response.  OBJECT is retained for old CL callers
but an ordinary object is never promoted into the Response brand.

BODY may be a ReadableStream (streamed on the wire as chunked Transfer-Encoding
by Clun.serve), a Clun.file (lazy file response), or a buffered value."
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
         (headers (%new-headers headers-init))
         (stream-body-p
           (or (js-readable-stream-p body) (js-body-stream-p body)))
         (stream (or body-stream
                     (and stream-body-p body)
                     (%new-body-stream)))
         (deferred-file-p (and (not body-stream)
                               (not stream-body-p)
                               (js-clun-file-p body))))
    (when (and (js-blob-p body)
               (null (%header-values headers "content-type")))
      (let ((content-type (%blob-response-content-type body)))
        (when content-type
          (%headers-set headers "content-type" content-type))))
    (setf (js-response-body response) (if stream-body-p eng:+null+ body)
          (js-response-body-stream response) stream
          (js-response-body-null-p response)
          (cond
            (body-stream body-null-p)
            (stream-body-p nil)
            (t (or (null body) (eng:js-undefined-p body)
                   (eng:js-null-p body)))))
    ;; Clun.file bodies stay deferred so construction cannot hang on FIFO/special
    ;; files. Serve freezes them through file-response-source; body methods materialize.
    ;; Stream bodies remain open for progressive chunked write-out.
    (unless (or body-stream stream-body-p deferred-file-p)
      (let ((octets (%body->octets body)))
        (when (plusp (length octets))
          (%body-stream-enqueue stream octets))
        (%body-stream-close stream)))
    (eng:data-prop response "status" (coerce status 'double-float))
    (eng:data-prop response "statusText" status-text)
    (eng:data-prop response "ok"
                   (eng:js-boolean (and (>= status 200) (< status 300))))
    (eng:data-prop response "headers" headers)
    response))

(defun %new-response (body init)
  (%init-response nil body init))

(defun %new-stream-response (stream init &key body-null-p)
  (%init-response nil nil init :body-stream stream :body-null-p body-null-p))

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
               (readable-stream-prototype (eng:new-object))
               (readable-stream-reader-prototype (eng:new-object))
               (readable-stream-controller-prototype (eng:new-object))
               (writable-stream-prototype (eng:new-object))
               (writable-stream-writer-prototype (eng:new-object))
               (writable-stream-controller-prototype (eng:new-object))
               (transform-stream-prototype (eng:new-object))
               (transform-stream-controller-prototype (eng:new-object))
               (state
                 (%make-web-http-realm-state
                  :headers-prototype headers-prototype
                  :headers-iterator-prototype headers-iterator-prototype
                  :request-prototype request-prototype
                  :server-request-prototype server-request-prototype
                  :blob-prototype blob-prototype
                  :response-prototype response-prototype
                  :readable-stream-prototype readable-stream-prototype
                  :readable-stream-reader-prototype
                  readable-stream-reader-prototype
                  :readable-stream-controller-prototype
                  readable-stream-controller-prototype
                  :writable-stream-prototype writable-stream-prototype
                  :writable-stream-writer-prototype
                  writable-stream-writer-prototype
                  :writable-stream-controller-prototype
                  writable-stream-controller-prototype
                  :transform-stream-prototype transform-stream-prototype
                  :transform-stream-controller-prototype
                  transform-stream-controller-prototype)))
          ;; Install state before helpers allocate branded instances.
          (setf (gethash realm *web-http-realm-states*) state)
          (%install-headers-prototype headers-prototype)
          (%install-headers-iterator-prototype headers-iterator-prototype)
          (%install-request-prototype request-prototype)
          (%install-blob-prototype blob-prototype)
          (%install-response-prototype response-prototype)
          (%install-readable-stream-prototype readable-stream-prototype)
          (%install-readable-stream-reader-prototype
           readable-stream-reader-prototype)
          (%install-readable-stream-controller-prototype
           readable-stream-controller-prototype)
          (%install-writable-stream-prototype writable-stream-prototype)
          (%install-writable-stream-writer-prototype
           writable-stream-writer-prototype)
          (%install-writable-stream-controller-prototype
           writable-stream-controller-prototype)
          (%install-transform-stream-prototype transform-stream-prototype)
          (%install-transform-stream-controller-prototype
           transform-stream-controller-prototype)
          (setf (web-http-realm-state-headers-constructor state)
                (%make-headers-constructor headers-prototype)
                (web-http-realm-state-request-constructor state)
                (%make-request-constructor request-prototype)
                (web-http-realm-state-blob-constructor state)
                (%make-blob-constructor blob-prototype)
                (web-http-realm-state-response-constructor state)
                (%make-response-constructor response-prototype)
                (web-http-realm-state-readable-stream-constructor state)
                (%make-readable-stream-constructor readable-stream-prototype)
                (web-http-realm-state-writable-stream-constructor state)
                (%make-writable-stream-constructor writable-stream-prototype)
                (web-http-realm-state-transform-stream-constructor state)
                (%make-transform-stream-constructor transform-stream-prototype))
          state))
    (let ((state (%http-state realm)))
      (eng:hidden-prop global "Headers"
                       (web-http-realm-state-headers-constructor state))
      (eng:hidden-prop global "Request"
                       (web-http-realm-state-request-constructor state))
      (eng:hidden-prop global "Blob"
                       (web-http-realm-state-blob-constructor state))
      (eng:hidden-prop global "Response"
                       (web-http-realm-state-response-constructor state))
      (eng:hidden-prop global "ReadableStream"
                       (web-http-realm-state-readable-stream-constructor state))
      (eng:hidden-prop global "WritableStream"
                       (web-http-realm-state-writable-stream-constructor state))
      (eng:hidden-prop global "TransformStream"
                       (web-http-realm-state-transform-stream-constructor
                        state)))
    realm))
