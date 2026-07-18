;;;; html-rewriter.lisp — global HTMLRewriter constructor (Phase 75).

(in-package :clun.runtime)

(defstruct (js-html-rewriter
            (:include eng:js-object (class :html-rewriter))
            (:constructor %make-js-html-rewriter))
  core)                                 ; clun.html:rewriter

(defstruct (js-html-element
            (:include eng:js-object (class :html-rewriter-element))
            (:constructor %make-js-html-element))
  node)

(defstruct (js-html-text
            (:include eng:js-object (class :html-rewriter-text))
            (:constructor %make-js-html-text))
  node)

(defstruct (js-html-comment
            (:include eng:js-object (class :html-rewriter-comment))
            (:constructor %make-js-html-comment))
  node)

(defvar *html-rewriter-realm-states*
  (make-hash-table :test #'eq :weakness :key))

(defstruct (html-rewriter-realm-state
            (:constructor %make-html-rewriter-realm-state))
  constructor
  prototype
  element-prototype
  text-prototype
  comment-prototype)

(defun %html-rewriter-state (&optional (realm eng:*realm*))
  (or (gethash realm *html-rewriter-realm-states*)
      (error "HTMLRewriter is not installed in this realm")))

(defun %html-type-error (message)
  (let ((error (eng:make-error-object :type-error-prototype "TypeError" message)))
    (eng:js-set error "code" "ERR_INVALID_ARG_TYPE" nil)
    (eng:throw-js-value error)))

(defun %html-range-error (message)
  (let ((error (eng:make-error-object :range-error-prototype "RangeError" message)))
    (eng:js-set error "code" "ERR_OUT_OF_RANGE" nil)
    (eng:throw-js-value error)))

(defun %require-html-rewriter (value member)
  (if (js-html-rewriter-p value)
      value
      (%html-type-error
       (format nil "Can only call HTMLRewriter.~a on instances of HTMLRewriter"
               member))))

(defun %content-and-html-flag (args)
  (let* ((content (eng:to-string (eng:arg args 0)))
         (options (eng:arg args 1))
         (html-p nil))
    (when (and (eng:js-object-p options)
               (eq (eng:to-boolean (eng:js-get options "html")) eng:+true+))
      (setf html-p t))
    (values content html-p)))

(defun %wrap-element (node state)
  (%make-js-html-element :proto (html-rewriter-realm-state-element-prototype state)
                         :node node))

(defun %wrap-text (node state)
  (%make-js-html-text :proto (html-rewriter-realm-state-text-prototype state)
                      :node node))

(defun %wrap-comment (node state)
  (%make-js-html-comment :proto (html-rewriter-realm-state-comment-prototype state)
                         :node node))

(defun %handlers-from-js (handlers state)
  (unless (eng:js-object-p handlers)
    (%html-type-error "HTMLRewriter handlers must be an object"))
  (let ((plist '())
        (element-fn (eng:js-get handlers "element"))
        (text-fn (eng:js-get handlers "text"))
        (comments-fn (eng:js-get handlers "comments")))
    (when (eng:callable-p element-fn)
      (setf plist
            (list* :element
                   (let ((fn element-fn))
                     (lambda (node)
                       (eng:js-call fn eng:+undefined+
                                    (list (%wrap-element node state)))))
                   plist)))
    (when (eng:callable-p text-fn)
      (setf plist
            (list* :text
                   (let ((fn text-fn))
                     (lambda (node)
                       (eng:js-call fn eng:+undefined+
                                    (list (%wrap-text node state)))))
                   plist)))
    (when (eng:callable-p comments-fn)
      (setf plist
            (list* :comments
                   (let ((fn comments-fn))
                     (lambda (node)
                       (eng:js-call fn eng:+undefined+
                                    (list (%wrap-comment node state)))))
                   plist)))
    plist))

(defun %document-handlers-from-js (handlers state)
  (declare (ignore state))
  (unless (eng:js-object-p handlers)
    (%html-type-error "HTMLRewriter document handlers must be an object"))
  (let ((plist '())
        (keys '(("doctype" . :doctype)
                ("comments" . :comments)
                ("text" . :text)
                ("end" . :end))))
    (dolist (pair keys)
      (let ((fn (eng:js-get handlers (car pair))))
        (when (eng:callable-p fn)
          (setf plist
                (list* (cdr pair)
                       (let ((js-fn fn))
                         (lambda (node)
                           (declare (ignore node))
                           (eng:js-call js-fn eng:+undefined+ '())))
                       plist)))))
    plist))

(defun %html-input-string (value)
  (cond
    ((eng:js-string-p value) value)
    ((or (eng:js-array-buffer-p value)
         (eng:js-typed-array-p value)
         (eng::js-data-view-p value))
     (eng:utf8->code-units (eng::%source-bytes value)))
    ((js-response-p value)
     (let ((body (js-response-body value)))
       (cond
         ((eng:js-string-p body) body)
         ((or (eng:js-array-buffer-p body)
              (eng:js-typed-array-p body))
          (eng:utf8->code-units (eng::%source-bytes body)))
         ((eng:js-nullish-p body) "")
         (t (eng:to-string body)))))
    ((eng:js-nullish-p value)
     (%html-type-error "HTMLRewriter.transform input must be a string, buffer, or Response"))
    (t (eng:to-string value))))

(defun %install-element-prototype (prototype)
  (eng:install-method
   prototype "getAttribute" 1
   (lambda (this args)
     (let ((node (js-html-element-node this)))
       (or (clun.html:element-get-attribute node (eng:to-string (eng:arg args 0)))
           eng:+null+))))
  (eng:install-method
   prototype "hasAttribute" 1
   (lambda (this args)
     (eng:js-boolean
      (clun.html:element-has-attribute
       (js-html-element-node this) (eng:to-string (eng:arg args 0))))))
  (eng:install-method
   prototype "setAttribute" 2
   (lambda (this args)
     (clun.html:element-set-attribute
      (js-html-element-node this)
      (eng:to-string (eng:arg args 0))
      (eng:to-string (eng:arg args 1)))
     this))
  (eng:install-method
   prototype "removeAttribute" 1
   (lambda (this args)
     (clun.html:element-remove-attribute
      (js-html-element-node this) (eng:to-string (eng:arg args 0)))
     this))
  (eng:install-getter
   prototype "tagName"
   (lambda (this args)
     (declare (ignore args))
     (clun.html:element-tag-name (js-html-element-node this))))
  (eng:install-getter
   prototype "namespaceURI"
   (lambda (this args)
     (declare (ignore args))
     (clun.html:element-namespace-uri (js-html-element-node this))))
  (eng:install-getter
   prototype "selfClosing"
   (lambda (this args)
     (declare (ignore args))
     (eng:js-boolean
      (clun.html:element-self-closing (js-html-element-node this)))))
  (eng:install-getter
   prototype "canHaveContent"
   (lambda (this args)
     (declare (ignore args))
     (eng:js-boolean
      (clun.html:element-can-have-content (js-html-element-node this)))))
  (eng:install-getter
   prototype "removed"
   (lambda (this args)
     (declare (ignore args))
     (eng:js-boolean
      (clun.html:element-removed (js-html-element-node this)))))
  (eng:install-method
   prototype "before" 2
   (lambda (this args)
     (multiple-value-bind (content html-p) (%content-and-html-flag args)
       (clun.html:element-before (js-html-element-node this) content :html html-p))
     this))
  (eng:install-method
   prototype "after" 2
   (lambda (this args)
     (multiple-value-bind (content html-p) (%content-and-html-flag args)
       (clun.html:element-after (js-html-element-node this) content :html html-p))
     this))
  (eng:install-method
   prototype "prepend" 2
   (lambda (this args)
     (multiple-value-bind (content html-p) (%content-and-html-flag args)
       (clun.html:element-prepend (js-html-element-node this) content :html html-p))
     this))
  (eng:install-method
   prototype "append" 2
   (lambda (this args)
     (multiple-value-bind (content html-p) (%content-and-html-flag args)
       (clun.html:element-append (js-html-element-node this) content :html html-p))
     this))
  (eng:install-method
   prototype "setInnerContent" 2
   (lambda (this args)
     (multiple-value-bind (content html-p) (%content-and-html-flag args)
       (clun.html:element-set-inner-content
        (js-html-element-node this) content :html html-p))
     this))
  (eng:install-method
   prototype "remove" 0
   (lambda (this args)
     (declare (ignore args))
     (clun.html:element-remove (js-html-element-node this))
     this))
  (eng:install-method
   prototype "removeAndKeepContent" 0
   (lambda (this args)
     (declare (ignore args))
     (clun.html:element-remove-and-keep-content (js-html-element-node this))
     this))
  prototype)

(defun %install-text-prototype (prototype)
  (eng:install-getter
   prototype "text"
   (lambda (this args)
     (declare (ignore args))
     (clun.html:text-chunk-text (js-html-text-node this))))
  (eng:install-getter
   prototype "lastInTextNode"
   (lambda (this args)
     (declare (ignore args))
     (eng:js-boolean
      (clun.html:text-chunk-last-in-text-node (js-html-text-node this)))))
  (eng:install-getter
   prototype "removed"
   (lambda (this args)
     (declare (ignore args))
     (eng:js-boolean
      (clun.html:text-chunk-removed (js-html-text-node this)))))
  (eng:install-method
   prototype "before" 2
   (lambda (this args)
     (multiple-value-bind (content html-p) (%content-and-html-flag args)
       (clun.html:text-chunk-before (js-html-text-node this) content :html html-p))
     this))
  (eng:install-method
   prototype "after" 2
   (lambda (this args)
     (multiple-value-bind (content html-p) (%content-and-html-flag args)
       (clun.html:text-chunk-after (js-html-text-node this) content :html html-p))
     this))
  (eng:install-method
   prototype "replace" 2
   (lambda (this args)
     (multiple-value-bind (content html-p) (%content-and-html-flag args)
       (clun.html:text-chunk-replace (js-html-text-node this) content :html html-p))
     this))
  (eng:install-method
   prototype "remove" 0
   (lambda (this args)
     (declare (ignore args))
     (clun.html:text-chunk-remove (js-html-text-node this))
     this))
  prototype)

(defun %install-comment-prototype (prototype)
  (eng:install-getter
   prototype "text"
   (lambda (this args)
     (declare (ignore args))
     (clun.html:comment-text (js-html-comment-node this))))
  (eng:install-getter
   prototype "removed"
   (lambda (this args)
     (declare (ignore args))
     (eng:js-boolean
      (clun.html:comment-removed (js-html-comment-node this)))))
  (eng:install-method
   prototype "before" 2
   (lambda (this args)
     (multiple-value-bind (content html-p) (%content-and-html-flag args)
       (clun.html:comment-before (js-html-comment-node this) content :html html-p))
     this))
  (eng:install-method
   prototype "after" 2
   (lambda (this args)
     (multiple-value-bind (content html-p) (%content-and-html-flag args)
       (clun.html:comment-after (js-html-comment-node this) content :html html-p))
     this))
  (eng:install-method
   prototype "replace" 2
   (lambda (this args)
     (multiple-value-bind (content html-p) (%content-and-html-flag args)
       (clun.html:comment-replace (js-html-comment-node this) content :html html-p))
     this))
  (eng:install-method
   prototype "remove" 0
   (lambda (this args)
     (declare (ignore args))
     (clun.html:comment-remove (js-html-comment-node this))
     this))
  prototype)

(defun install-html-rewriter (realm)
  "Install the realm-local HTMLRewriter constructor on the global object."
  (let* ((eng:*realm* realm)
         (g (eng:realm-global realm))
         (prototype (eng:new-object))
         (element-prototype (%install-element-prototype (eng:new-object)))
         (text-prototype (%install-text-prototype (eng:new-object)))
         (comment-prototype (%install-comment-prototype (eng:new-object)))
         (state (%make-html-rewriter-realm-state
                 :prototype prototype
                 :element-prototype element-prototype
                 :text-prototype text-prototype
                 :comment-prototype comment-prototype))
         (constructor nil))
    (eng:install-method
     prototype "on" 2
     (lambda (this args)
       (let ((rewriter (%require-html-rewriter this "on"))
             (selector (eng:to-string (eng:arg args 0)))
             (handlers (eng:arg args 1)))
         (clun.html:rewriter-on
          (js-html-rewriter-core rewriter)
          selector
          (%handlers-from-js handlers state))
         this)))
    (eng:install-method
     prototype "onDocument" 1
     (lambda (this args)
       (let ((rewriter (%require-html-rewriter this "onDocument"))
             (handlers (eng:arg args 0)))
         (clun.html:rewriter-on-document
          (js-html-rewriter-core rewriter)
          (%document-handlers-from-js handlers state))
         this)))
    (eng:install-method
     prototype "transform" 1
     (lambda (this args)
       (let* ((rewriter (%require-html-rewriter this "transform"))
              (input (eng:arg args 0))
              (response-p (js-response-p input)))
         (handler-case
             (let ((html (clun.html:rewriter-transform
                          (js-html-rewriter-core rewriter)
                          (%html-input-string input))))
               (if response-p
                   (eng:js-construct (eng:js-get g "Response") (list html))
                   html))
           (clun.html:html-error (condition)
             (if (eq (clun.html:html-error-code condition) :limit)
                 (%html-range-error (clun.html:html-error-reason condition))
                 (%html-type-error (clun.html:html-error-reason condition))))))))
    (setf constructor
          (eng:make-native-function
           "HTMLRewriter" 0
           (lambda (this args)
             (declare (ignore this args))
             (%html-type-error
              "HTMLRewriter constructor cannot be invoked without 'new'"))
           :construct
           (lambda (args new-target)
             (declare (ignore args))
             (%make-js-html-rewriter
              :proto (eng::nt-prototype new-target prototype)
              :core (clun.html:make-rewriter)))))
    (eng::obj-set-desc constructor "prototype"
                       (eng::data-pd prototype :writable nil :enumerable nil
                                              :configurable nil))
    (eng::obj-set-desc prototype "constructor"
                       (eng::data-pd constructor :writable t :enumerable nil
                                                :configurable t))
    (setf (html-rewriter-realm-state-constructor state) constructor)
    (setf (gethash realm *html-rewriter-realm-states*) state)
    (eng:data-prop g "HTMLRewriter" constructor)
    constructor))
