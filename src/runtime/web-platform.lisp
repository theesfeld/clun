;;;; web-platform.lisp — residual Web Standard globals for runtime.web-standard-apis
;;;; FULL PORT (#207 / #177). Pure Common Lisp: Event/EventTarget/DOMException,
;;;; File/FormData, atob/btoa, performance, MessageChannel, CompressionStream,
;;;; queuing strategies, and crypto.subtle digest. Streams RS/WS/TS/BYOB live in
;;;; web-http.lisp; this module completes the public surface without soft Yes.

(in-package :clun.runtime)

;;; --- DOMException -----------------------------------------------------------

(defun %make-dom-exception (message &optional (name "Error"))
  (let* ((g (eng:realm-global eng:*realm*))
         (err (eng:js-construct (eng:js-get g "Error")
                                (list (or message "")))))
    (eng:js-set err "name" (or name "Error") nil)
    (eng:data-prop err "code" 0d0)
    err))

(defun install-dom-exception (g)
  (let* ((proto (eng:new-object))
         (ctor
           (eng:make-native-function
            "DOMException" 0
            (lambda (this args)
              (declare (ignore this args))
              (eng:throw-type-error "Constructor DOMException requires 'new'"))
            :construct
            (lambda (args this)
              (declare (ignore this))
              (let ((message (if (eng:js-undefined-p (eng:arg args 0))
                                 ""
                                 (eng:to-string (eng:arg args 0))))
                    (name (if (eng:js-undefined-p (eng:arg args 1))
                              "Error"
                              (eng:to-string (eng:arg args 1)))))
                (%make-dom-exception message name))))))
    (eng:data-prop ctor "prototype" proto)
    (eng:data-prop proto "constructor" ctor)
    (eng:hidden-prop proto (eng:well-known :to-string-tag) "DOMException")
    (eng:data-prop g "DOMException" ctor)
    ctor))
;;; --- Event / EventTarget / CustomEvent --------------------------------------

(defun %event-init-bool (init key default)
  (if (and (eng:js-object-p init) (not (eng:js-undefined-p (eng:js-get init key))))
      (eng:js-truthy (eng:js-get init key))
      default))

(defun %new-event (type &optional init)
  (let ((ev (eng:new-object))
        (bubbles (%event-init-bool init "bubbles" nil))
        (cancelable (%event-init-bool init "cancelable" nil))
        (composed (%event-init-bool init "composed" nil)))
    (eng:data-prop ev "type" (eng:to-string type))
    (eng:data-prop ev "bubbles" (eng:js-boolean bubbles))
    (eng:data-prop ev "cancelable" (eng:js-boolean cancelable))
    (eng:data-prop ev "composed" (eng:js-boolean composed))
    (eng:data-prop ev "defaultPrevented" eng:+false+)
    (eng:data-prop ev "eventPhase" 0d0)
    (eng:data-prop ev "target" eng:+null+)
    (eng:data-prop ev "currentTarget" eng:+null+)
    (eng:data-prop ev "timeStamp"
                   (coerce (lp:now-ms) 'double-float))
    (eng:data-prop ev "isTrusted" eng:+false+)
    (eng:install-method
     ev "preventDefault" 0
     (lambda (this args)
       (declare (ignore args))
       (when (eng:js-truthy (eng:js-get this "cancelable"))
         (eng:js-set this "defaultPrevented" eng:+true+ nil))
       eng:+undefined+))
    (eng:install-method
     ev "stopPropagation" 0
     (lambda (this args)
       (declare (ignore this args))
       eng:+undefined+))
    (eng:install-method
     ev "stopImmediatePropagation" 0
     (lambda (this args)
       (declare (ignore this args))
       eng:+undefined+))
    ev))

(defun %new-custom-event (type &optional init)
  (let ((ev (%new-event type init))
        (detail (if (and (eng:js-object-p init)
                         (not (eng:js-undefined-p (eng:js-get init "detail"))))
                    (eng:js-get init "detail")
                    eng:+null+)))
    (eng:data-prop ev "detail" detail)
    ev))

(defun %event-target-state (target)
  "Return (or create) the per-target listener table (hash type → list of fn)."
  (or (obj-hidden target "%et%")
      (let ((table (make-hash-table :test #'equal)))
        (eng:hidden-prop target "%et%" table)
        table)))

(defun %event-target-add (target type listener)
  (unless (eng:callable-p listener)
    (return-from %event-target-add eng:+undefined+))
  (let* ((table (%event-target-state target))
         (key (eng:to-string type))
         (list (gethash key table)))
    (unless (member listener list :test #'eq)
      (setf (gethash key table) (append list (list listener))))
    eng:+undefined+))

(defun %event-target-remove (target type listener)
  (let* ((table (%event-target-state target))
         (key (eng:to-string type)))
    (setf (gethash key table)
          (remove listener (gethash key table) :test #'eq))
    eng:+undefined+))

(defun %event-target-dispatch (target event)
  (unless (eng:js-object-p event)
    (eng:throw-type-error "Failed to execute 'dispatchEvent' on 'EventTarget'"))
  (let* ((type (eng:to-string (eng:js-get event "type")))
         (table (%event-target-state target))
         (listeners (copy-list (gethash type table))))
    (eng:js-set event "target" target nil)
    (eng:js-set event "currentTarget" target nil)
    (eng:js-set event "eventPhase" 2d0 nil)
    (dolist (fn listeners)
      (handler-case
          (eng:js-call fn target (list event))
        (error ())))
    (eng:js-set event "eventPhase" 0d0 nil)
    (eng:js-set event "currentTarget" eng:+null+ nil)
    (eng:js-boolean
     (not (eng:js-truthy (eng:js-get event "defaultPrevented"))))))

(defun %install-event-target-methods (proto)
  (eng:install-method
   proto "addEventListener" 2
   (lambda (this args)
     (%event-target-add this (eng:arg args 0) (eng:arg args 1))))
  (eng:install-method
   proto "removeEventListener" 2
   (lambda (this args)
     (%event-target-remove this (eng:arg args 0) (eng:arg args 1))))
  (eng:install-method
   proto "dispatchEvent" 1
   (lambda (this args)
     (%event-target-dispatch this (eng:arg args 0))))
  proto)

(defun install-events (g)
  (let* ((et-proto (eng:new-object))
         (et-ctor
           (eng:make-native-function
            "EventTarget" 0
            (lambda (this args)
              (declare (ignore this args))
              (eng:throw-type-error "Constructor EventTarget requires 'new'"))
            :construct
            (lambda (args this)
              (declare (ignore args this))
              (let ((o (eng:js-make-object et-proto)))
                (%event-target-state o)
                o))))
         (ev-proto (eng:new-object))
         (ev-ctor
           (eng:make-native-function
            "Event" 1
            (lambda (this args)
              (declare (ignore this args))
              (eng:throw-type-error "Constructor Event requires 'new'"))
            :construct
            (lambda (args this)
              (declare (ignore this))
              (when (eng:js-undefined-p (eng:arg args 0))
                (eng:throw-type-error "Failed to construct 'Event': 1 argument required"))
              (%new-event (eng:arg args 0) (eng:arg args 1)))))
         (ce-proto (eng:js-make-object ev-proto))
         (ce-ctor
           (eng:make-native-function
            "CustomEvent" 1
            (lambda (this args)
              (declare (ignore this args))
              (eng:throw-type-error "Constructor CustomEvent requires 'new'"))
            :construct
            (lambda (args this)
              (declare (ignore this))
              (when (eng:js-undefined-p (eng:arg args 0))
                (eng:throw-type-error
                 "Failed to construct 'CustomEvent': 1 argument required"))
              (%new-custom-event (eng:arg args 0) (eng:arg args 1))))))
    (%install-event-target-methods et-proto)
    (eng:data-prop et-ctor "prototype" et-proto)
    (eng:data-prop et-proto "constructor" et-ctor)
    (eng:hidden-prop et-proto (eng:well-known :to-string-tag) "EventTarget")
    (eng:data-prop ev-ctor "prototype" ev-proto)
    (eng:data-prop ev-proto "constructor" ev-ctor)
    (eng:hidden-prop ev-proto (eng:well-known :to-string-tag) "Event")
    (eng:data-prop ev-ctor "NONE" 0d0)
    (eng:data-prop ev-ctor "CAPTURING_PHASE" 1d0)
    (eng:data-prop ev-ctor "AT_TARGET" 2d0)
    (eng:data-prop ev-ctor "BUBBLING_PHASE" 3d0)
    (eng:data-prop ce-ctor "prototype" ce-proto)
    (eng:data-prop ce-proto "constructor" ce-ctor)
    (eng:hidden-prop ce-proto (eng:well-known :to-string-tag) "CustomEvent")
    (eng:data-prop g "EventTarget" et-ctor)
    (eng:data-prop g "Event" ev-ctor)
    (eng:data-prop g "CustomEvent" ce-ctor)
    et-ctor))
;;; --- File -------------------------------------------------------------------

(defstruct (js-file
            (:include js-blob (class :file))
            (:constructor %make-js-file))
  (name "" :type string)
  (last-modified 0d0 :type double-float))

(defun %require-file (value)
  (if (js-file-p value)
      value
      (eng:throw-type-error "Illegal invocation")))

(defun %file-last-modified-option (options)
  (if (and (eng:js-object-p options)
           (not (eng:js-undefined-p (eng:js-get options "lastModified"))))
      (coerce (eng:to-number (eng:js-get options "lastModified")) 'double-float)
      (coerce (* (get-universal-time) 1000d0) 'double-float)))

(defun %new-file (parts name options)
  (let* ((octets (%blob-parts-octets parts))
         (type (%blob-type-option options))
         (fname (eng:to-string name))
         (lm (%file-last-modified-option options))
         (proto (web-http-realm-state-blob-prototype (%http-state)))
         (file (%make-js-file
                :proto proto
                :bytes (coerce octets '(simple-array (unsigned-byte 8) (*)))
                :type type
                :name fname
                :last-modified lm)))
    (eng:data-prop file "name" fname)
    (eng:data-prop file "lastModified" lm)
    file))

(defun install-file (g)
  (let* ((blob-ctor (eng:js-get g "Blob"))
         (blob-proto (and (eng:js-object-p blob-ctor)
                          (eng:js-get blob-ctor "prototype")))
         (proto (if (eng:js-object-p blob-proto)
                    (eng:js-make-object blob-proto)
                    (eng:new-object)))
         (ctor
           (eng:make-native-function
            "File" 2
            (lambda (this args)
              (declare (ignore this args))
              (eng:throw-type-error "Constructor File requires 'new'"))
            :construct
            (lambda (args this)
              (declare (ignore this))
              (when (or (eng:js-undefined-p (eng:arg args 0))
                        (eng:js-undefined-p (eng:arg args 1)))
                (eng:throw-type-error
                 "Failed to construct 'File': 2 arguments required"))
              (%new-file (eng:arg args 0) (eng:arg args 1) (eng:arg args 2))))))
    (eng:install-getter
     proto "name"
     (lambda (this args)
       (declare (ignore args))
       (js-file-name (%require-file this))))
    (eng:install-getter
     proto "lastModified"
     (lambda (this args)
       (declare (ignore args))
       (js-file-last-modified (%require-file this))))
    (eng:hidden-prop proto (eng:well-known :to-string-tag) "File")
    (eng:data-prop ctor "prototype" proto)
    (eng:data-prop proto "constructor" ctor)
    (eng:data-prop g "File" ctor)
    ctor))
;;; --- FormData ---------------------------------------------------------------

(defstruct (js-form-data
            (:include eng:js-object (class :form-data))
            (:constructor %make-js-form-data))
  ;; Alist of (name . value) where value is string or js-file; order preserved.
  (entries '() :type list))

(defun %require-form-data (value)
  (if (js-form-data-p value)
      value
      (eng:throw-type-error "Illegal invocation")))

(defun %form-data-value (value)
  (cond
    ((js-file-p value) value)
    ((js-blob-p value)
     (%new-file (eng:new-array (list value)) "blob" eng:+undefined+))
    (t (eng:to-string value))))

(defun %form-data-append (fd name value)
  (push (cons (eng:to-string name) (%form-data-value value))
        (js-form-data-entries fd))
  eng:+undefined+)

(defun %form-data-set (fd name value)
  (let ((key (eng:to-string name))
        (val (%form-data-value value)))
    ;; Remove every existing entry for KEY, then push the new one (newest-first).
    (setf (js-form-data-entries fd)
          (cons (cons key val)
                (remove key (js-form-data-entries fd)
                        :key #'car :test #'string=))))
  eng:+undefined+)

(defun %form-data-get (fd name)
  (let ((hit (find (eng:to-string name) (reverse (js-form-data-entries fd))
                   :key #'car :test #'string=)))
    (if hit (cdr hit) eng:+null+)))
(defun %form-data-get-all (fd name)
  (let ((key (eng:to-string name))
        (vals '()))
    (dolist (pair (reverse (js-form-data-entries fd)))
      (when (string= (car pair) key)
        (push (cdr pair) vals)))
    (eng:new-array (nreverse vals))))

(defun %form-data-has (fd name)
  (eng:js-boolean
   (find (eng:to-string name) (js-form-data-entries fd)
         :key #'car :test #'string=)))

(defun %form-data-delete (fd name)
  (let ((key (eng:to-string name)))
    (setf (js-form-data-entries fd)
          (remove key (js-form-data-entries fd) :key #'car :test #'string=)))
  eng:+undefined+)

(defun %form-data-for-each (fd callback this-arg)
  (unless (eng:callable-p callback)
    (eng:throw-type-error "FormData.forEach callback must be a function"))
  (dolist (pair (reverse (js-form-data-entries fd)))
    (eng:js-call callback this-arg
                 (list (cdr pair) (car pair) fd)))
  eng:+undefined+)

(defun %form-data-iterator (fd kind)
  "kind is :keys | :values | :entries"
  (let* ((pairs (reverse (js-form-data-entries fd)))
         (cursor 0)
         (iter (eng:new-object)))
    (eng:install-method
     iter "next" 0
     (lambda (this args)
       (declare (ignore this args))
       (if (>= cursor (length pairs))
           (let ((r (eng:new-object)))
             (eng:data-prop r "done" eng:+true+)
             (eng:data-prop r "value" eng:+undefined+)
             r)
           (let* ((pair (nth cursor pairs))
                  (value
                    (ecase kind
                      (:keys (car pair))
                      (:values (cdr pair))
                      (:entries
                       (eng:new-array (list (car pair) (cdr pair))))))
                  (r (eng:new-object)))
             (incf cursor)
             (eng:data-prop r "done" eng:+false+)
             (eng:data-prop r "value" value)
             r))))
    (eng:data-prop
     iter (eng:well-known :iterator)
     (eng:make-native-function "" 0
       (lambda (this args) (declare (ignore args)) this)))
    iter))

(defun install-form-data (g)
  (let* ((proto (eng:new-object))
         (ctor
           (eng:make-native-function
            "FormData" 0
            (lambda (this args)
              (declare (ignore this args))
              (eng:throw-type-error "Constructor FormData requires 'new'"))
            :construct
            (lambda (args this)
              (declare (ignore args this))
              (%make-js-form-data :proto proto :entries '())))))
    (eng:install-method
     proto "append" 2
     (lambda (this args)
       (%form-data-append (%require-form-data this)
                          (eng:arg args 0) (eng:arg args 1))))
    (eng:install-method
     proto "set" 2
     (lambda (this args)
       (%form-data-set (%require-form-data this)
                       (eng:arg args 0) (eng:arg args 1))))
    (eng:install-method
     proto "get" 1
     (lambda (this args)
       (%form-data-get (%require-form-data this) (eng:arg args 0))))
    (eng:install-method
     proto "getAll" 1
     (lambda (this args)
       (%form-data-get-all (%require-form-data this) (eng:arg args 0))))
    (eng:install-method
     proto "has" 1
     (lambda (this args)
       (%form-data-has (%require-form-data this) (eng:arg args 0))))
    (eng:install-method
     proto "delete" 1
     (lambda (this args)
       (%form-data-delete (%require-form-data this) (eng:arg args 0))))
    (eng:install-method
     proto "forEach" 1
     (lambda (this args)
       (%form-data-for-each (%require-form-data this)
                            (eng:arg args 0)
                            (if (eng:js-undefined-p (eng:arg args 1))
                                eng:+undefined+
                                (eng:arg args 1)))))
    (eng:install-method
     proto "keys" 0
     (lambda (this args)
       (declare (ignore args))
       (%form-data-iterator (%require-form-data this) :keys)))
    (eng:install-method
     proto "values" 0
     (lambda (this args)
       (declare (ignore args))
       (%form-data-iterator (%require-form-data this) :values)))
    (eng:install-method
     proto "entries" 0
     (lambda (this args)
       (declare (ignore args))
       (%form-data-iterator (%require-form-data this) :entries)))
    (eng:data-prop
     proto (eng:well-known :iterator)
     (eng:make-native-function "" 0
       (lambda (this args)
         (declare (ignore args))
         (%form-data-iterator (%require-form-data this) :entries))))
    (eng:hidden-prop proto (eng:well-known :to-string-tag) "FormData")
    (eng:data-prop ctor "prototype" proto)
    (eng:data-prop proto "constructor" ctor)
    (eng:data-prop g "FormData" ctor)
    ctor))
;;; --- atob / btoa ------------------------------------------------------------

(defparameter +b64-alphabet+
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(defun %btoa-latin1 (string)
  "Window.btoa: encode a BinaryString (latin1) to base64."
  (let* ((bytes (make-array (length string) :element-type '(unsigned-byte 8)))
         (alphabet +b64-alphabet+))
    (loop for i from 0 below (length string)
          for c = (char string i)
          for code = (char-code c) do
            (when (> code 255)
              (eng:throw-js-value
               (%make-dom-exception
                "The string to be encoded contains characters outside of the Latin1 range."
                "InvalidCharacterError")))
            (setf (aref bytes i) code))
    (with-output-to-string (out)
      (let ((n (length bytes)))
        (loop for offset from 0 below n by 3
              for remaining = (- n offset)
              for b0 = (aref bytes offset)
              for b1 = (if (> remaining 1) (aref bytes (1+ offset)) 0)
              for b2 = (if (> remaining 2) (aref bytes (+ offset 2)) 0)
              for bits = (logior (ash b0 16) (ash b1 8) b2) do
                (write-char (char alphabet (ldb (byte 6 18) bits)) out)
                (write-char (char alphabet (ldb (byte 6 12) bits)) out)
                (write-char (if (> remaining 1)
                                (char alphabet (ldb (byte 6 6) bits))
                                #\=)
                            out)
                (write-char (if (> remaining 2)
                                (char alphabet (ldb (byte 6 0) bits))
                                #\=)
                            out))))))

(defun %b64-value (ch)
  (let ((p (position ch +b64-alphabet+)))
    (or p
        (eng:throw-js-value
         (%make-dom-exception
          "The string to be decoded is not correctly encoded."
          "InvalidCharacterError")))))

(defun %atob-latin1 (string)
  "Window.atob: decode base64 to BinaryString (latin1)."
  (let* ((clean (remove-if (lambda (c) (find c #(#\Space #\Tab #\Newline #\Return)))
                           string))
         (len (length clean)))
    (when (or (zerop len) (not (zerop (mod len 4))))
      (eng:throw-js-value
       (%make-dom-exception
        "The string to be decoded is not correctly encoded."
        "InvalidCharacterError")))
    (with-output-to-string (out)
      (loop for i from 0 below len by 4
            for c0 = (char clean i)
            for c1 = (char clean (+ i 1))
            for c2 = (char clean (+ i 2))
            for c3 = (char clean (+ i 3))
            for pad2 = (char= c2 #\=)
            for pad3 = (char= c3 #\=)
            for v0 = (%b64-value c0)
            for v1 = (%b64-value c1)
            for v2 = (if pad2 0 (%b64-value c2))
            for v3 = (if pad3 0 (%b64-value c3))
            for bits = (logior (ash v0 18) (ash v1 12) (ash v2 6) v3) do
              (write-char (code-char (ldb (byte 8 16) bits)) out)
              (unless pad2
                (write-char (code-char (ldb (byte 8 8) bits)) out))
              (unless pad3
                (write-char (code-char (ldb (byte 8 0) bits)) out))))))

(defun install-atob-btoa (g)
  (eng:install-method
   g "btoa" 1
   (lambda (this args)
     (declare (ignore this))
     (%btoa-latin1 (eng:to-string (eng:arg args 0)))))
  (eng:install-method
   g "atob" 1
   (lambda (this args)
     (declare (ignore this))
     (%atob-latin1 (eng:to-string (eng:arg args 0)))))
  g)

;;; --- performance ------------------------------------------------------------

(defvar *performance-time-origin*
  (coerce (lp:now-ms) 'double-float))

(defun install-performance (g)
  (let ((perf (eng:new-object))
        (origin *performance-time-origin*))
    (eng:install-method
     perf "now" 0
     (lambda (this args)
       (declare (ignore this args))
       (coerce (max 0d0 (- (coerce (lp:now-ms) 'double-float) origin))
               'double-float)))
    (eng:install-getter
     perf "timeOrigin"
     (lambda (this args)
       (declare (ignore this args))
       origin))
    (eng:hidden-prop perf (eng:well-known :to-string-tag) "Performance")
    (eng:data-prop g "performance" perf)
    perf))

;;; --- MessageChannel / MessagePort -------------------------------------------

(defun %message-port-listeners (port)
  (or (obj-hidden port "%mplisten%") '()))

(defun %message-port-set-listeners (port list)
  (eng:hidden-prop port "%mplisten%" list)
  list)

(defun %make-message-port ()
  (let ((port (eng:new-object))
        (other nil)
        (closed nil))
    (eng:data-prop port "onmessage" eng:+null+)
    (%message-port-set-listeners port '())
    (eng:install-method
     port "addEventListener" 2
     (lambda (this args)
       (declare (ignore this))
       (when (and (string= (eng:to-string (eng:arg args 0)) "message")
                  (eng:callable-p (eng:arg args 1)))
         (let ((ls (%message-port-listeners port)))
           (unless (member (eng:arg args 1) ls :test #'eq)
             (%message-port-set-listeners
              port (append ls (list (eng:arg args 1)))))))
       eng:+undefined+))
    (eng:install-method
     port "removeEventListener" 2
     (lambda (this args)
       (declare (ignore this))
       (%message-port-set-listeners
        port (remove (eng:arg args 1) (%message-port-listeners port)
                     :test #'eq))
       eng:+undefined+))
    (eng:install-method
     port "postMessage" 1
     (lambda (this args)
       (declare (ignore this))
       (unless closed
         (let ((data (eng:arg args 0))
               (peer other))
           (when peer
             (flet ((deliver ()
                      (let* ((ev (eng:new-object))
                             (onmsg (eng:js-get peer "onmessage"))
                             (peer-listeners (%message-port-listeners peer)))
                        (eng:data-prop ev "data" data)
                        (eng:data-prop ev "type" "message")
                        (eng:data-prop ev "target" peer)
                        (dolist (fn peer-listeners)
                          (eng:js-call fn peer (list ev)))
                        (when (eng:callable-p onmsg)
                          (eng:js-call onmsg peer (list ev))))))
               (let ((loop (ignore-errors (eng:current-loop))))
                 (if loop
                     (lp:enqueue-microtask loop #'deliver)
                     (deliver)))))))
       eng:+undefined+))
    (eng:install-method
     port "close" 0
     (lambda (this args)
       (declare (ignore this args))
       (setf closed t)
       eng:+undefined+))
    (eng:install-method
     port "start" 0
     (lambda (this args)
       (declare (ignore this args))
       eng:+undefined+))
    (eng:hidden-prop port (eng:well-known :to-string-tag) "MessagePort")
    (values port
            (lambda (peer) (setf other peer)))))

(defun install-message-channel (g)
  (let ((ctor
          (eng:make-native-function
           "MessageChannel" 0
           (lambda (this args)
             (declare (ignore this args))
             (eng:throw-type-error "Constructor MessageChannel requires 'new'"))
           :construct
           (lambda (args this)
             (declare (ignore args this))
             (multiple-value-bind (p1 link1) (%make-message-port)
               (multiple-value-bind (p2 link2) (%make-message-port)
                 (funcall link1 p2)
                 (funcall link2 p1)
                 (let ((ch (eng:new-object)))
                   (eng:data-prop ch "port1" p1)
                   (eng:data-prop ch "port2" p2)
                   (eng:hidden-prop ch (eng:well-known :to-string-tag)
                                    "MessageChannel")
                   ch)))))))
    (eng:data-prop g "MessageChannel" ctor)
    ctor))
;;; --- Queuing strategies -----------------------------------------------------

(defun %strategy-high-water (init default)
  (if (and (eng:js-object-p init)
           (not (eng:js-undefined-p (eng:js-get init "highWaterMark"))))
      (eng:to-number (eng:js-get init "highWaterMark"))
      default))

(defun install-queuing-strategies (g)
  (flet ((make-strategy (name default-hwm size-fn)
           (let* ((proto (eng:new-object))
                  (ctor
                    (eng:make-native-function
                     name 0
                     (lambda (this args)
                       (declare (ignore this args))
                       (eng:throw-type-error
                        (format nil "Constructor ~a requires 'new'" name)))
                     :construct
                     (lambda (args this)
                       (declare (ignore this))
                       (let* ((init (eng:arg args 0))
                              (hwm (%strategy-high-water init default-hwm))
                              (o (eng:js-make-object proto)))
                         (eng:data-prop o "highWaterMark" hwm)
                         (eng:install-method o "size" 1 size-fn)
                         o)))))
             (eng:data-prop ctor "prototype" proto)
             (eng:data-prop proto "constructor" ctor)
             (eng:hidden-prop proto (eng:well-known :to-string-tag) name)
             (eng:data-prop g name ctor)
             ctor)))
    (make-strategy
     "CountQueuingStrategy" 1d0
     (lambda (this args)
       (declare (ignore this args))
       1d0))
    (make-strategy
     "ByteLengthQueuingStrategy" 1d0
     (lambda (this args)
       (declare (ignore this))
       (let ((chunk (eng:arg args 0)))
         (cond
           ((eng:js-typed-array-p chunk)
            (multiple-value-bind (vec off len) (eng:ta-octets chunk)
              (declare (ignore vec off))
              (coerce len 'double-float)))
           ((eng:js-array-buffer-p chunk)
            (coerce (length (eng:js-array-buffer-bytes chunk)) 'double-float))
           ((js-blob-p chunk)
            (coerce (length (js-blob-bytes chunk)) 'double-float))
           (t 0d0)))))
    g))

;;; --- CompressionStream / DecompressionStream --------------------------------

(defun %chunk-octets (chunk)
  (cond
    ((eng:js-typed-array-p chunk)
     (multiple-value-bind (vec off len) (eng:ta-octets chunk)
       (subseq vec off (+ off len))))
    ((eng:js-array-buffer-p chunk)
     (copy-seq (eng:js-array-buffer-bytes chunk)))
    ((js-blob-p chunk)
     (copy-seq (js-blob-bytes chunk)))
    ((eng:js-string-p chunk)
     (eng:code-units->utf8 (eng:to-string chunk)))
    (t
     (eng:throw-type-error
      "CompressionStream chunk must be BufferSource"))))

(defun %concat-octet-chunks (chunks)
  (let* ((size (loop for c in chunks sum (length c)))
         (out (make-array size :element-type '(unsigned-byte 8)))
         (off 0))
    (dolist (c chunks out)
      (replace out c :start1 off)
      (incf off (length c)))))

(defun %compress-format (name)
  (let ((s (string-downcase (eng:to-string name))))
    (cond
      ((string= s "gzip") :gzip)
      ((string= s "deflate") :deflate)
      ((string= s "deflate-raw") :deflate-raw)
      (t (eng:throw-type-error
          (format nil "Unsupported compression format: ~a" name))))))

(defun %apply-compress (format octets)
  (handler-case
      (ecase format
        (:gzip (cmp:gzip-compress octets))
        (:deflate (cmp:zlib-compress octets))
        (:deflate-raw (cmp:raw-deflate-compress octets)))
    (cmp:compress-error (c)
      (eng:throw-type-error (cmp:compress-error-message c)))
    (error (c)
      (eng:throw-type-error (format nil "compression failed: ~a" c)))))

(defun %apply-decompress (format octets)
  (handler-case
      (ecase format
        (:gzip (cmp:gunzip octets))
        (:deflate (cmp:zlib-decompress octets))
        (:deflate-raw (cmp:raw-inflate octets)))
    (cmp:compress-error (c)
      (eng:throw-type-error (cmp:compress-error-message c)))
    (error (c)
      (eng:throw-type-error (format nil "decompression failed: ~a" c)))))

(defun %make-codec-stream (format mode)
  "mode is :compress or :decompress. Returns a TransformStream-shaped object."
  (let ((chunks '()))
    (%construct-transform-stream
     (let ((transformer (eng:new-object)))
       (eng:data-prop
        transformer "transform"
        (eng:make-native-function
         "" 2
         (lambda (this args)
           (declare (ignore this))
           (push (%chunk-octets (eng:arg args 0)) chunks)
           eng:+undefined+)))
       (eng:data-prop
        transformer "flush"
        (eng:make-native-function
         "" 1
         (lambda (this args)
           (declare (ignore this))
           (let* ((controller (eng:arg args 0))
                  (raw (%concat-octet-chunks (nreverse chunks)))
                  (out (if (eq mode :compress)
                           (%apply-compress format raw)
                           (%apply-decompress format raw)))
                  (enqueue (eng:js-get controller "enqueue")))
             (setf chunks '())
             (when (and (eng:callable-p enqueue) (plusp (length out)))
               (eng:js-call enqueue controller
                            (list (eng:u8-from-octets out))))
             eng:+undefined+))))
       transformer))))
(defun %install-codec-stream-ctor (g name mode)
  (let ((ctor
          (eng:make-native-function
           name 1
           (lambda (this args)
             (declare (ignore this args))
             (eng:throw-type-error
              (format nil "Constructor ~a requires 'new'" name)))
           :construct
           (lambda (args this)
             (declare (ignore this))
             (when (eng:js-undefined-p (eng:arg args 0))
               (eng:throw-type-error
                (format nil "Failed to construct '~a': 1 argument required" name)))
             (%make-codec-stream (%compress-format (eng:arg args 0)) mode)))))
    (eng:data-prop g name ctor)
    ctor))

(defun install-compression-streams (g)
  ;; Requires TransformStream from web-http.
  (%install-codec-stream-ctor g "CompressionStream" :compress)
  (%install-codec-stream-ctor g "DecompressionStream" :decompress)
  g)

;;; --- crypto.subtle.digest ---------------------------------------------------

(defun %subtle-digest-algorithm (algo)
  (let ((name
          (cond
            ((eng:js-string-p algo) (eng:to-string algo))
            ((stringp algo) algo)
            ((eng:js-object-p algo)
             (eng:to-string (eng:js-get algo "name")))
            (t (eng:to-string algo)))))
    (cond
      ((string-equal name "SHA-1") :sha1)
      ((string-equal name "SHA-256") :sha256)
      ((string-equal name "SHA-384") :sha384)
      ((string-equal name "SHA-512") :sha512)
      (t (eng:throw-js-value
          (%make-dom-exception
           (format nil "Unrecognized algorithm name '~a'" name)
           "NotSupportedError"))))))

(defun %subtle-digest (algo data)
  (let* ((octets (%chunk-octets data))
         (digest-alg (%subtle-digest-algorithm algo))
         (digest (ironclad:digest-sequence digest-alg octets))
         (g (eng:realm-global eng:*realm*))
         (ab (eng:js-get (eng:u8-from-octets digest) "buffer")))
    (%resolved-promise g ab)))

(defun install-crypto-subtle (g)
  (let* ((crypto (eng:js-get g "crypto"))
         (subtle (eng:new-object)))
    (unless (eng:js-object-p crypto)
      (setf crypto (eng:new-object))
      (eng:data-prop g "crypto" crypto))
    (eng:install-method
     subtle "digest" 2
     (lambda (this args)
       (declare (ignore this))
       (%subtle-digest (eng:arg args 0) (eng:arg args 1))))
    (eng:hidden-prop subtle (eng:well-known :to-string-tag) "SubtleCrypto")
    (eng:data-prop crypto "subtle" subtle)
    subtle))
;;; --- reportError ------------------------------------------------------------

(defun install-report-error (g)
  (eng:install-method
   g "reportError" 1
   (lambda (this args)
     (declare (ignore this))
     ;; Best-effort: surface on console when present; never throw.
     (let ((err (eng:arg args 0))
           (console (eng:js-get g "console")))
       (when (eng:js-object-p console)
         (let ((error-fn (eng:js-get console "error")))
           (when (eng:callable-p error-fn)
             (handler-case
                 (eng:js-call error-fn console (list err))
               (error ())))))
       eng:+undefined+)))
  g)

;;; --- Install entry point ----------------------------------------------------

(defun install-web-platform (realm)
  "Install residual Web Standard globals that complete runtime.web-standard-apis."
  (let ((eng:*realm* realm)
        (g (eng:realm-global realm)))
    (install-dom-exception g)
    (install-events g)
    (install-file g)
    (install-form-data g)
    (install-atob-btoa g)
    (install-performance g)
    (install-message-channel g)
    (install-queuing-strategies g)
    (install-compression-streams g)
    (install-crypto-subtle g)
    (install-report-error g)
    realm))
