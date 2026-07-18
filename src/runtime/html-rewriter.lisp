;;;; html-rewriter.lisp — global HTMLRewriter constructor (Phase 75).

(in-package :clun.runtime)

(defstruct (js-html-rewriter
            (:include eng:js-object (class :html-rewriter))
            (:constructor %make-js-html-rewriter))
  core)

(defstruct (js-html-element
            (:include eng:js-object (class :html-element))
            (:constructor %make-js-html-element))
  element)

(defstruct (js-html-text
            (:include eng:js-object (class :html-text-chunk))
            (:constructor %make-js-html-text))
  text)

(defstruct (js-html-comment
            (:include eng:js-object (class :html-comment))
            (:constructor %make-js-html-comment))
  comment)

(defun %require-html-rewriter (value)
  (if (js-html-rewriter-p value)
      value
      (eng:throw-type-error "HTMLRewriter method called on an incompatible receiver")))

(defun %content-and-html-flag (args)
  (let ((content (eng:to-string (eng:arg args 0)))
        (html nil)
        (opts (eng:arg args 1)))
    (when (eng:js-object-p opts)
      (setf html (eng:js-truthy (eng:js-get opts "html"))))
    (values content html)))

(defun %wrap-element (el)
  (let ((obj (%make-js-html-element :proto (eng:intrinsic :object-prototype)
                                    :element el)))
    (eng:install-accessor
     obj "tagName"
     (lambda (this args)
       (declare (ignore args))
       (clun.html:element-tag-name (js-html-element-element this)))
     (lambda (this args)
       (clun.html:element-set-tag-name
        (js-html-element-element this)
        (eng:to-string (eng:arg args 0)))
       eng:+undefined+))
    (eng:install-method obj "getAttribute" 1
      (lambda (this args)
        (or (clun.html:element-get-attribute
             (js-html-element-element this)
             (eng:to-string (eng:arg args 0)))
            eng:+null+)))
    (eng:install-method obj "hasAttribute" 1
      (lambda (this args)
        (eng:js-boolean
         (clun.html:element-has-attribute
          (js-html-element-element this)
          (eng:to-string (eng:arg args 0))))))
    (eng:install-method obj "setAttribute" 2
      (lambda (this args)
        (clun.html:element-set-attribute
         (js-html-element-element this)
         (eng:to-string (eng:arg args 0))
         (eng:to-string (eng:arg args 1)))
        this))
    (eng:install-method obj "removeAttribute" 1
      (lambda (this args)
        (clun.html:element-remove-attribute
         (js-html-element-element this)
         (eng:to-string (eng:arg args 0)))
        this))
    (eng:install-method obj "before" 1
      (lambda (this args)
        (multiple-value-bind (content html) (%content-and-html-flag args)
          (clun.html:element-before
           (js-html-element-element this) content :html html))
        this))
    (eng:install-method obj "after" 1
      (lambda (this args)
        (multiple-value-bind (content html) (%content-and-html-flag args)
          (clun.html:element-after
           (js-html-element-element this) content :html html))
        this))
    (eng:install-method obj "prepend" 1
      (lambda (this args)
        (multiple-value-bind (content html) (%content-and-html-flag args)
          (clun.html:element-prepend
           (js-html-element-element this) content :html html))
        this))
    (eng:install-method obj "append" 1
      (lambda (this args)
        (multiple-value-bind (content html) (%content-and-html-flag args)
          (clun.html:element-append
           (js-html-element-element this) content :html html))
        this))
    (eng:install-method obj "setInnerContent" 1
      (lambda (this args)
        (multiple-value-bind (content html) (%content-and-html-flag args)
          (clun.html:element-set-inner-content
           (js-html-element-element this) content :html html))
        this))
    (eng:install-method obj "remove" 0
      (lambda (this args)
        (declare (ignore args))
        (clun.html:element-remove (js-html-element-element this))
        this))
    (eng:install-method obj "removeAndKeepContent" 0
      (lambda (this args)
        (declare (ignore args))
        (clun.html:element-remove-and-keep-content
         (js-html-element-element this))
        this))
    obj))

(defun %wrap-text (node)
  (let ((obj (%make-js-html-text :proto (eng:intrinsic :object-prototype)
                                 :text node)))
    (eng:install-getter obj "text"
      (lambda (this args)
        (declare (ignore args))
        (clun.html:ht-text (js-html-text-text this))))
    (eng:install-getter obj "lastInTextNode"
      (lambda (this args)
        (declare (ignore args))
        (eng:js-boolean
         (clun.html:ht-last-in-text-node (js-html-text-text this)))))
    (eng:install-getter obj "removed"
      (lambda (this args)
        (declare (ignore this args))
        eng:+false+))
    (eng:install-method obj "replace" 1
      (lambda (this args)
        (multiple-value-bind (content html) (%content-and-html-flag args)
          (clun.html:text-replace (js-html-text-text this) content :html html))
        this))
    (eng:install-method obj "remove" 0
      (lambda (this args)
        (declare (ignore args))
        (clun.html:text-remove (js-html-text-text this))
        this))
    (eng:install-method obj "before" 1
      (lambda (this args)
        (multiple-value-bind (content html) (%content-and-html-flag args)
          (push (cons html content)
                (clun.html::ht-before (js-html-text-text this))))
        this))
    (eng:install-method obj "after" 1
      (lambda (this args)
        (multiple-value-bind (content html) (%content-and-html-flag args)
          (push (cons html content)
                (clun.html::ht-after (js-html-text-text this))))
        this))
    obj))

(defun %wrap-comment (node)
  (let ((obj (%make-js-html-comment :proto (eng:intrinsic :object-prototype)
                                    :comment node)))
    (eng:install-getter obj "text"
      (lambda (this args)
        (declare (ignore args))
        (clun.html:hc-text (js-html-comment-comment this))))
    (eng:install-method obj "replace" 1
      (lambda (this args)
        (multiple-value-bind (content html) (%content-and-html-flag args)
          (clun.html:comment-replace
           (js-html-comment-comment this) content :html html))
        this))
    (eng:install-method obj "remove" 0
      (lambda (this args)
        (declare (ignore args))
        (clun.html:comment-remove (js-html-comment-comment this))
        this))
    obj))

(defun %handlers-plist-from-js (obj)
  (unless (eng:js-object-p obj)
    (eng:throw-type-error "Expected handler object"))
  (flet ((wrap (key lisp-key wrapper)
           (let ((fn (eng:js-get obj key)))
             (when (eng:callable-p fn)
               (list lisp-key
                     (lambda (native)
                       (eng:js-call fn eng:+undefined+
                                    (list (funcall wrapper native)))))))))
    (append (wrap "element" :element #'%wrap-element)
            (wrap "text" :text #'%wrap-text)
            (wrap "comments" :comments #'%wrap-comment))))

(defun %document-handlers-from-js (obj)
  (unless (eng:js-object-p obj)
    (eng:throw-type-error "Expected document handler object"))
  (flet ((wrap (key lisp-key)
           (let ((fn (eng:js-get obj key)))
             (when (eng:callable-p fn)
               (list lisp-key
                     (lambda (arg)
                       (eng:js-call fn eng:+undefined+
                                    (list (if (stringp arg) arg eng:+undefined+)))))))))
    (append (wrap "doctype" :doctype)
            (wrap "comments" :comments)
            (wrap "text" :text)
            (wrap "end" :end))))

(defun %rewriter-input-string (value)
  (cond
    ((stringp value) value)
    ((eng:js-string-p value) (eng:to-string value))
    ((or (eng:js-array-buffer-p value)
         (eng:js-typed-array-p value)
         (eng::js-data-view-p value))
     (eng:utf8->code-units (eng::%source-bytes value)))
    ((%response-object-p value)
     ;; buffered body only for this phase
     (let ((octets (%response-body-vector value)))
       (if octets
           (eng:utf8->code-units octets)
           "")))
    (t (eng:to-string value))))

(defun %html-rewriter-transform (this args)
  (let* ((rw (%require-html-rewriter this))
         (input (eng:arg args 0))
         (source (%rewriter-input-string input))
         (result
           (handler-case
               (clun.html:transform-html (js-html-rewriter-core rw) source)
             (clun.html:html-rewriter-error (e)
               (eng:throw-native-error
                :error (clun.html:html-rewriter-error-reason e))))))
    (if (%response-object-p input)
        (let* ((g (eng:realm-global eng:*realm*))
               (response-ctor (eng:js-get g "Response")))
          (eng:js-construct response-ctor (list result)))
        result)))

(defun %make-html-rewriter-instance ()
  (let ((obj (%make-js-html-rewriter
              :proto (eng:intrinsic :object-prototype)
              :core (clun.html:make-empty-rewriter))))
    (eng:install-method obj "on" 2
      (lambda (this args)
        (let ((rw (%require-html-rewriter this))
              (selector (eng:to-string (eng:arg args 0)))
              (handlers (%handlers-plist-from-js (eng:arg args 1))))
          (handler-case
              (clun.html:rewriter-on (js-html-rewriter-core rw) selector handlers)
            (clun.html:html-rewriter-error (e)
              (eng:throw-type-error
               (clun.html:html-rewriter-error-reason e))))
          this)))
    (eng:install-method obj "onDocument" 1
      (lambda (this args)
        (let ((rw (%require-html-rewriter this))
              (handlers (%document-handlers-from-js (eng:arg args 0))))
          (clun.html:rewriter-on-document (js-html-rewriter-core rw) handlers)
          this)))
    (eng:install-method obj "transform" 1
      (lambda (this args) (%html-rewriter-transform this args)))
    obj))

(defun install-html-rewriter (g)
  "Install the HTMLRewriter constructor on the realm global object."
  (let ((ctor
          (eng:make-native-function
           "HTMLRewriter" 0
           (lambda (this args)
             (declare (ignore this args))
             (eng:throw-type-error
              "Constructor HTMLRewriter requires 'new'"))
           :construct
           (lambda (args new-target)
             (declare (ignore args new-target))
             (%make-html-rewriter-instance)))))
    (eng:data-prop g "HTMLRewriter" ctor)
    ctor))
