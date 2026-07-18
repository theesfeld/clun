;;;; clun-markdown.lisp — Clun.markdown JavaScript boundary (Phase 75).

(in-package :clun.runtime)

(defun %markdown-type-error (message)
  (let ((error (eng:make-error-object :type-error-prototype "TypeError" message)))
    (eng:js-set error "code" "ERR_INVALID_ARG_TYPE" nil)
    (eng:throw-js-value error)))

(defun %markdown-range-error (message)
  (let ((error (eng:make-error-object :range-error-prototype "RangeError" message)))
    (eng:js-set error "code" "ERR_OUT_OF_RANGE" nil)
    (eng:throw-js-value error)))

(defun %markdown-input-string (value)
  (cond
    ((eng:js-string-p value) value)
    ((or (eng:js-array-buffer-p value)
         (eng:js-typed-array-p value)
         (eng::js-data-view-p value))
     (eng:utf8->code-units (eng::%source-bytes value)))
    ((eng:js-nullish-p value)
     (%markdown-type-error "Markdown input must be a string or buffer"))
    (t (eng:to-string value))))

(defun %markdown-bool-option (options name default)
  (let ((value (eng:js-get options name)))
    (cond ((eng:js-undefined-p value) default)
          ((eng:js-nullish-p value) default)
          (t (eq (eng:to-boolean value) eng:+true+)))))

(defun %markdown-headings-option (options)
  (let ((value (eng:js-get options "headings")))
    (cond
      ((or (eng:js-undefined-p value) (eng:js-nullish-p value)) nil)
      ((not (eng:js-object-p value))
       (eq (eng:to-boolean value) eng:+true+))
      (t
       (let ((ids (eng:js-get value "ids"))
             (autolink (eng:js-get value "autolink")))
         (cond
           ((and (not (eng:js-undefined-p ids))
                 (eq (eng:to-boolean ids) eng:+true+)
                 (or (eng:js-undefined-p autolink)
                     (eq (eng:to-boolean autolink) eng:+false+)))
            :ids-only)
           ((or (and (not (eng:js-undefined-p ids))
                     (eq (eng:to-boolean ids) eng:+true+))
                (and (not (eng:js-undefined-p autolink))
                     (eq (eng:to-boolean autolink) eng:+true+))
                (and (eng:js-undefined-p ids) (eng:js-undefined-p autolink)))
            t)
           (t nil)))))))

(defun %markdown-options (value)
  (let ((opts (clun.markdown:make-markdown-options)))
    (unless (or (eng:js-nullish-p value) (eng:js-undefined-p value))
      (unless (eng:js-object-p value)
        (%markdown-type-error "Markdown options must be an object"))
      (setf (clun.markdown:markdown-options-tables opts)
            (%markdown-bool-option value "tables" t)
            (clun.markdown:markdown-options-strikethrough opts)
            (%markdown-bool-option value "strikethrough" t)
            (clun.markdown:markdown-options-tasklists opts)
            (%markdown-bool-option value "tasklists" t)
            (clun.markdown:markdown-options-autolinks opts)
            (%markdown-bool-option value "autolinks" nil)
            (clun.markdown:markdown-options-headings opts)
            (%markdown-headings-option value)
            (clun.markdown:markdown-options-hard-soft-breaks opts)
            (%markdown-bool-option value "hardSoftBreaks" nil)
            (clun.markdown:markdown-options-no-html-blocks opts)
            (%markdown-bool-option value "noHtmlBlocks" nil)
            (clun.markdown:markdown-options-no-html-spans opts)
            (%markdown-bool-option value "noHtmlSpans" nil)
            (clun.markdown:markdown-options-tag-filter opts)
            (%markdown-bool-option value "tagFilter" nil)
            (clun.markdown:markdown-options-collapse-whitespace opts)
            (%markdown-bool-option value "collapseWhitespace" nil)))
    opts))

(defun %markdown-meta-object (meta)
  (let ((object (eng:new-object)))
    (loop for (key value) on meta by #'cddr do
      (let ((name (string-downcase (symbol-name key))))
        ;; JS meta uses camelCase for listItem fields already as keywords.
        (setf name (case key
                     (:level "level")
                     (:id "id")
                     (:language "language")
                     (:ordered "ordered")
                     (:start "start")
                     (:depth "depth")
                     (:index "index")
                     (:checked "checked")
                     (:href "href")
                     (:src "src")
                     (:title "title")
                     (:align "align")
                     (otherwise name)))
        (cond
          ((null value) nil)
          ((eq value t) (eng:data-prop object name eng:+true+))
          ((eq value nil) nil)
          ((integerp value)
           (eng:data-prop object name (coerce value 'double-float)))
          ((stringp value) (eng:data-prop object name value))
          (t (eng:data-prop object name (princ-to-string value))))))
    object))

(defparameter +markdown-handler-keys+
  '(("heading" . :heading)
    ("paragraph" . :paragraph)
    ("blockquote" . :blockquote)
    ("code" . :code)
    ("list" . :list)
    ("listItem" . :list-item)
    ("hr" . :hr)
    ("table" . :table)
    ("thead" . :thead)
    ("tbody" . :tbody)
    ("tr" . :tr)
    ("th" . :th)
    ("td" . :td)
    ("html" . :html)
    ("strong" . :strong)
    ("emphasis" . :emphasis)
    ("link" . :link)
    ("image" . :image)
    ("codespan" . :codespan)
    ("strikethrough" . :strikethrough)
    ("text" . :text)))

(defun %markdown-callback-table (handlers)
  (when (or (eng:js-nullish-p handlers) (eng:js-undefined-p handlers))
    (return-from %markdown-callback-table nil))
  (unless (eng:js-object-p handlers)
    (%markdown-type-error "Markdown render handlers must be an object"))
  (let ((alist '()))
    (dolist (pair +markdown-handler-keys+)
      (let* ((key (car pair))
             (kind (cdr pair))
             (fn (eng:js-get handlers key)))
        (when (eng:callable-p fn)
          (push
           (cons kind
                 (let ((js-fn fn))
                   (lambda (children meta)
                     (let* ((meta-arg (if meta
                                          (%markdown-meta-object meta)
                                          eng:+undefined+))
                            (result (eng:js-call js-fn eng:+undefined+
                                                 (list children meta-arg))))
                       (cond
                         ((or (eng:js-nullish-p result)
                              (eng:js-undefined-p result))
                          nil)
                         (t (eng:to-string result)))))))
           alist))))
    alist))

(defun %markdown-protect (thunk)
  (handler-case (funcall thunk)
    (clun.markdown:markdown-error (condition)
      (if (eq (clun.markdown:markdown-error-code condition) :limit)
          (%markdown-range-error (clun.markdown:markdown-error-reason condition))
          (%markdown-type-error (clun.markdown:markdown-error-reason condition))))))

(defun make-clun-markdown ()
  (let ((namespace (eng:new-object)))
    (eng:data-prop
     namespace "html"
     (eng:make-native-function
      "html" 2
      (lambda (this args)
        (declare (ignore this))
        (%markdown-protect
         (lambda ()
           (clun.markdown:markdown-html
            (%markdown-input-string (eng:arg args 0))
            (%markdown-options (eng:arg args 1))))))))
    (eng:data-prop
     namespace "render"
     (eng:make-native-function
      "render" 2
      (lambda (this args)
        (declare (ignore this))
        (%markdown-protect
         (lambda ()
           (let ((source (%markdown-input-string (eng:arg args 0)))
                 (handlers (eng:arg args 1)))
             (or (clun.markdown:markdown-render
                  source
                  (%markdown-callback-table handlers)
                  (clun.markdown:make-markdown-options))
                 "")))))))
    (eng:data-prop
     namespace "react"
     (eng:make-native-function
      "react" 2
      (lambda (this args)
        (declare (ignore this args))
        (eng:throw-native-error
         :error "Clun.markdown.react is not implemented (no React runtime)"))))
    (eng:data-prop
     namespace "ansi"
     (eng:make-native-function
      "ansi" 2
      (lambda (this args)
        (declare (ignore this))
        (%markdown-protect
         (lambda ()
           (let* ((source (%markdown-input-string (eng:arg args 0)))
                  (callbacks
                   (list
                    (cons :heading
                          (lambda (children meta)
                            (declare (ignore meta))
                            children))
                    (cons :paragraph
                          (lambda (children meta)
                            (declare (ignore meta))
                            (format nil "~a~%" children)))
                    (cons :strong (lambda (c m) (declare (ignore m)) c))
                    (cons :emphasis (lambda (c m) (declare (ignore m)) c))
                    (cons :codespan (lambda (c m) (declare (ignore m)) c))
                    (cons :link (lambda (c m) (declare (ignore m)) c))
                    (cons :image (lambda (c m) (declare (ignore c m)) ""))
                    (cons :code
                          (lambda (c m)
                            (declare (ignore m))
                            (format nil "~a~%" c))))))
             (or (clun.markdown:markdown-render
                  source callbacks (clun.markdown:make-markdown-options))
                 "")))))))
    namespace))

(defun install-clun-markdown (clun)
  (eng:nonconfigurable-data-prop clun "markdown" (make-clun-markdown))
  clun)
