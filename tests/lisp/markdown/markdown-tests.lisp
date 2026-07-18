;;;; markdown-tests.lisp — engine-free Phase 75 Markdown contract.

(in-package :clun-test)

(define-test markdown/basic-html
  (is string= "<h1>Hello <strong>world</strong></h1>
"
              (md:markdown-html "# Hello **world**"))
  (is string= "<p>a <em>b</em> c</p>
"
              (md:markdown-html "a *b* c"))
  (is string= "<p><code>x</code></p>
"
              (md:markdown-html "`x`"))
  (true (search "<del>gone</del>" (md:markdown-html "~~gone~~"))))

(define-test markdown/lists-and-code
  (let ((html (md:markdown-html (format nil "- a~%- b~%"))))
    (true (search "<ul>" html))
    (true (search "<li>" html))
    (true (search "a" html)))
  (let ((html (md:markdown-html (format nil "```js~%console.log(1)~%```~%"))))
    (true (search "<pre><code class=\"language-js\">" html))
    (true (search "console.log(1)" html))))

(define-test markdown/table
  (let ((html (md:markdown-html
               (format nil "| A | B |~%| --- | --- |~%| 1 | 2 |~%"))))
    (true (search "<table>" html))
    (true (search "<th>" html))
    (true (search "<td>" html))))

(define-test markdown/task-list
  (let ((html (md:markdown-html (format nil "- [x] done~%- [ ] todo~%"))))
    (true (search "checkbox" html))
    (true (search "checked" html))))

(define-test markdown/render-callback
  (let ((out (md:markdown-render
              "# Hi **x**"
              (list
               (cons :heading
                     (lambda (children meta)
                       (format nil "<h~d class=\"t\">~a</h~d>"
                               (getf meta :level) children (getf meta :level))))
               (cons :strong
                     (lambda (children meta)
                       (declare (ignore meta))
                       (format nil "<b>~a</b>" children)))))))
    (true (search "class=\"t\"" out))
    (true (search "<b>x</b>" out))))

(define-test markdown/limits
  (fail (md:markdown-html (make-string (1+ md:+max-source-length+)
                                       :initial-element #\a))
        'md:markdown-error))

(define-test markdown/heading-ids
  (let* ((opts (md:make-markdown-options :headings t))
         (html (md:markdown-html "## Hello World" opts)))
    (true (search "id=\"hello-world\"" html))))
