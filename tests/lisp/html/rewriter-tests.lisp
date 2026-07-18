;;;; rewriter-tests.lisp — pure-CL HTMLRewriter substrate (Phase 75).

(in-package :clun-test)

(define-test html/selector-parse
  (let ((sel (clun.html:parse-selector "div.note#x")))
    (true (clun.html::selector-p sel)))
  (fail (clun.html:parse-selector "") 'clun.html:html-rewriter-error))

(define-test html/rewrite-attr
  (let* ((rw (clun.html:make-empty-rewriter)))
    (clun.html:rewriter-on
     rw "img"
     (list :element
           (lambda (el)
             (clun.html:element-set-attribute el "src" "new.png"))))
    (is equal
        "<img src=\"new.png\">"
        (clun.html:transform-html rw "<img src=\"old.png\">"))))

(define-test html/rewrite-before-after
  (let* ((rw (clun.html:make-empty-rewriter)))
    (clun.html:rewriter-on
     rw "p"
     (list :element
           (lambda (el)
             (clun.html:element-before el "[" )
             (clun.html:element-after el "]"))))
    (is equal
        "[<p>hi</p>]"
        (clun.html:transform-html rw "<p>hi</p>"))))

(define-test html/set-inner-content
  (let* ((rw (clun.html:make-empty-rewriter)))
    (clun.html:rewriter-on
     rw "div"
     (list :element
           (lambda (el)
             (clun.html:element-set-inner-content el "<b>x</b>" :html t))))
    (is equal
        "<div><b>x</b></div>"
        (clun.html:transform-html rw "<div>old</div>"))))

(define-test html/class-selector
  (let* ((rw (clun.html:make-empty-rewriter)))
    (clun.html:rewriter-on
     rw "span.red"
     (list :element
           (lambda (el)
             (clun.html:element-set-attribute el "data-ok" "1"))))
    (let ((out (clun.html:transform-html
                rw "<span class=\"red\">a</span><span>b</span>")))
      (true (search "data-ok=\"1\"" out))
      (true (search "<span>b</span>" out)))))

(define-test html/text-handler
  (let* ((rw (clun.html:make-empty-rewriter)))
    (clun.html:rewriter-on
     rw "p"
     (list :text
           (lambda (tnode)
             (clun.html:text-replace tnode "Z"))))
    (is equal
        "<p>Z</p>"
        (clun.html:transform-html rw "<p>hello</p>"))))

(define-test html/remove-element
  (let* ((rw (clun.html:make-empty-rewriter)))
    (clun.html:rewriter-on
     rw "script"
     (list :element
           (lambda (el) (clun.html:element-remove el))))
    (is equal
        "<div></div>"
        (clun.html:transform-html rw "<div><script>x</script></div>"))))
