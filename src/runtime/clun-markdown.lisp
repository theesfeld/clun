;;;; clun-markdown.lisp — Clun.markdown.html / .render / .react (Phase 75).

(in-package :clun.runtime)

(defun %markdown-input-string (value)
  (cond
    ((eng:js-undefined-p value) "")
    ((or (eng:js-array-buffer-p value)
         (eng:js-typed-array-p value)
         (eng::js-data-view-p value))
     (eng:utf8->code-units (eng::%source-bytes value)))
    (t (eng:to-string value))))

(defun %markdown-option-bool (options key default)
  (if (not (eng:js-object-p options))
      default
      (let ((v (eng:js-get options key)))
        (if (eng:js-nullish-p v)
            default
            (eng:js-truthy v)))))

(defun %markdown-options-from-js (value)
  (if (not (eng:js-object-p value))
      (clun.markdown:default-options)
      (let ((plist '()))
        (flet ((push-bool (key lisp-key &optional (default t))
                 (setf plist (list* lisp-key
                                    (%markdown-option-bool value key default)
                                    plist))))
          (push-bool "tables" :tables t)
          (push-bool "strikethrough" :strikethrough t)
          (push-bool "tasklists" :tasklists t)
          (push-bool "hardSoftBreaks" :hard-soft-breaks nil)
          (push-bool "wikiLinks" :wiki-links nil)
          (push-bool "underline" :underline nil)
          (push-bool "latexMath" :latex-math nil)
          (push-bool "collapseWhitespace" :collapse-whitespace nil)
          (push-bool "permissiveAtxHeaders" :permissive-atx nil)
          (push-bool "noIndentedCodeBlocks" :no-indented-code nil)
          (push-bool "noHtmlBlocks" :no-html-blocks nil)
          (push-bool "noHtmlSpans" :no-html-spans nil)
          (push-bool "tagFilter" :tag-filter nil)
          (let ((al (eng:js-get value "autolinks")))
            (cond
              ((eng:js-nullish-p al) nil)
              ((eq al eng:+true+) (setf plist (list* :autolinks t plist)))
              ((eng:js-object-p al)
               (setf plist
                     (list* :autolinks
                            (list :url (%markdown-option-bool al "url" nil)
                                  :www (%markdown-option-bool al "www" nil)
                                  :email (%markdown-option-bool al "email" nil))
                            plist)))))
          (let ((h (eng:js-get value "headings")))
            (cond
              ((eng:js-nullish-p h) nil)
              ((eq h eng:+true+) (setf plist (list* :headings t plist)))
              ((eng:js-object-p h)
               (setf plist
                     (list* :headings
                            (list :ids (%markdown-option-bool h "ids" nil)
                                  :autolink (%markdown-option-bool h "autolink" nil))
                            plist)))))
          (clun.markdown:options-from-plist plist)))))

(defun %markdown-meta-object (meta)
  (let ((o (eng:new-object)))
    (loop for (k v) on meta by #'cddr
          do (let ((key (string-downcase (symbol-name k))))
               ;; camelCase a few known keys
               (setf key (case k
                           (:language "language")
                           (:ordered "ordered")
                           (:checked "checked")
                           (:start "start")
                           (:depth "depth")
                           (:index "index")
                           (:level "level")
                           (:href "href")
                           (:src "src")
                           (:title "title")
                           (:align "align")
                           (:id "id")
                           (t key)))
               (cond
                 ((null v) nil)
                 ((eq v :absent) nil)
                 ((eq v t) (eng:data-prop o key eng:+true+))
                 ((eq v nil) (eng:data-prop o key eng:+false+))
                 ((stringp v) (eng:data-prop o key v))
                 ((integerp v) (eng:data-prop o key (coerce v 'double-float)))
                 (t (eng:data-prop o key v)))))
    o))

(defun %markdown-callbacks-from-js (obj)
  (unless (eng:js-object-p obj)
    (return-from %markdown-callbacks-from-js '()))
  (let ((names '((:heading . "heading")
                 (:paragraph . "paragraph")
                 (:blockquote . "blockquote")
                 (:code . "code")
                 (:list . "list")
                 (:list-item . "listItem")
                 (:hr . "hr")
                 (:table . "table")
                 (:thead . "thead")
                 (:tbody . "tbody")
                 (:tr . "tr")
                 (:th . "th")
                 (:td . "td")
                 (:html . "html")
                 (:strong . "strong")
                 (:emphasis . "emphasis")
                 (:link . "link")
                 (:image . "image")
                 (:codespan . "codespan")
                 (:strikethrough . "strikethrough")
                 (:underline . "underline")
                 (:text . "text")))
        (plist '()))
    (dolist (pair names)
      (let ((fn (eng:js-get obj (cdr pair))))
        (when (eng:callable-p fn)
          (setf plist
                (list* (car pair)
                       (lambda (children &optional meta)
                         (let* ((args (if meta
                                          (list children (%markdown-meta-object meta))
                                          (list children)))
                                (result (eng:js-call fn eng:+undefined+ args)))
                           (cond
                             ((or (eng:js-null-p result)
                                  (eng:js-undefined-p result))
                              nil)
                             ((stringp result) result)
                             (t (eng:to-string result)))))
                       plist)))))
    plist))

(defun %markdown-html (args)
  (let* ((source (%markdown-input-string (eng:arg args 0)))
         (options (%markdown-options-from-js (eng:arg args 1))))
    (handler-case
        (clun.markdown:markdown-to-html source options)
      (clun.markdown:markdown-error (e)
        (eng:throw-native-error :error (clun.markdown:markdown-error-reason e))))))

(defun %markdown-render (args)
  (let* ((source (%markdown-input-string (eng:arg args 0)))
         (second (eng:arg args 1))
         (third (eng:arg args 2))
         (callbacks-obj (if (eng:js-object-p second) second eng:+undefined+))
         (options-obj (cond
                        ((eng:js-object-p third) third)
                        ;; when second looks like options (no callbacks), treat as options
                        ((and (eng:js-object-p second)
                              (not (eng:callable-p (eng:js-get second "heading")))
                              (not (eng:callable-p (eng:js-get second "text")))
                              (not (eng:callable-p (eng:js-get second "paragraph"))))
                         second)
                        (t eng:+undefined+)))
         (callbacks (%markdown-callbacks-from-js callbacks-obj))
         (options (%markdown-options-from-js options-obj)))
    (handler-case
        (clun.markdown:markdown-render source callbacks options)
      (clun.markdown:markdown-error (e)
        (eng:throw-native-error :error (clun.markdown:markdown-error-reason e))))))

(defun %markdown-react (args)
  "Minimal react-shaped renderer: returns an array of element-like objects."
  (let* ((source (%markdown-input-string (eng:arg args 0)))
         (options (%markdown-options-from-js (eng:arg args 1)))
         (html (handler-case
                   (clun.markdown:markdown-to-html source options)
                 (clun.markdown:markdown-error (e)
                   (eng:throw-native-error
                    :error (clun.markdown:markdown-error-reason e)))))
         (el (eng:new-object)))
    (eng:data-prop el "type" "div")
    (eng:data-prop el "props"
                   (let ((p (eng:new-object)))
                     (eng:data-prop p "dangerouslySetInnerHTML"
                                    (let ((d (eng:new-object)))
                                      (eng:data-prop d "__html" html)
                                      d))
                     p))
    el))

(defun make-clun-markdown ()
  (let ((namespace (eng:new-object)))
    (eng:data-prop
     namespace "html"
     (eng:make-native-function
      "html" 1
      (lambda (this args) (declare (ignore this)) (%markdown-html args))))
    (eng:data-prop
     namespace "render"
     (eng:make-native-function
      "render" 1
      (lambda (this args) (declare (ignore this)) (%markdown-render args))))
    (eng:data-prop
     namespace "react"
     (eng:make-native-function
      "react" 1
      (lambda (this args) (declare (ignore this)) (%markdown-react args))))
    namespace))

(defun install-clun-markdown (clun)
  (eng:nonconfigurable-data-prop clun "markdown" (make-clun-markdown))
  clun)
