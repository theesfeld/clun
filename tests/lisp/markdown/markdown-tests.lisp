;;;; markdown-tests.lisp — pure-CL Markdown substrate (Phase 75).

(in-package :clun-test)

(define-test markdown/basic-html
  (is equal "<h1>Hello <strong>world</strong></h1>
"
      (clun.markdown:markdown-to-html "# Hello **world**"))
  (is equal "<p>a <em>b</em> c</p>
"
      (clun.markdown:markdown-to-html "a *b* c"))
  (is equal "<p><code>x</code></p>
"
      (clun.markdown:markdown-to-html "`x`")))

(define-test markdown/gfm-table-and-strike
  (let ((html (clun.markdown:markdown-to-html
               (format nil "| A | B |~%| --- | --- |~%| 1 | 2 |"))))
    (true (search "<table>" html))
    (true (search "<th>" html))
    (true (search "1" html)))
  (true (search "<del>gone</del>"
                (clun.markdown:markdown-to-html "~~gone~~"))))

(define-test markdown/lists-and-tasks
  (let ((html (clun.markdown:markdown-to-html
               (format nil "- a~%- b"))))
    (true (search "<ul>" html))
    (true (search "<li>a</li>" html)))
  (let ((html (clun.markdown:markdown-to-html
               (format nil "- [x] done~%- [ ] todo"))))
    (true (search "checkbox" html))
    (true (search "checked" html))))

(define-test markdown/code-fence
  (let ((html (clun.markdown:markdown-to-html
               (format nil "```js~%const x = 1;~%```"))))
    (true (search "language-js" html))
    (true (search "const x = 1;" html))))

(define-test markdown/callback-render
  (let ((out (clun.markdown:markdown-render
              "# Hi **there**"
              (list :heading
                    (lambda (children meta)
                      (declare (ignore meta))
                      (format nil "[H:~a]" children))
                    :strong
                    (lambda (children)
                      (format nil "[B:~a]" children))))))
    (true (search "[H:" out))
    (true (search "[B:there]" out))))

(define-test markdown/bounds
  (fail (clun.markdown:markdown-to-html
         (make-string (1+ clun.markdown:+max-source-length+)
                      :initial-element #\a))
        'clun.markdown:markdown-error))
