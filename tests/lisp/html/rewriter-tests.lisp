;;;; rewriter-tests.lisp — engine-free Phase 75 HTMLRewriter substrate.

(in-package :clun-test)

(define-test html/parse-serialize-roundtrip
  (let* ((src "<div class=\"x\"><p>hi</p><!--c--></div>")
         (doc (html:parse-html src))
         (out (html:serialize-html doc)))
    (true (search "<div" out))
    (true (search "class=\"x\"" out))
    (true (search "<p>hi</p>" out))
    (true (search "<!--c-->" out))))

(define-test html/selector-tag-class-id
  (let* ((doc (html:parse-html
               "<div id=\"root\" class=\"box main\"><span data-x=\"1\">t</span></div>"))
         (div (first (html:html-node-children doc)))
         (span (first (html:html-node-children div))))
    (true (html:selector-matches-p "div" div '()))
    (true (html:selector-matches-p "div.box" div '()))
    (true (html:selector-matches-p "div#root" div '()))
    (true (html:selector-matches-p "div.box.main" div '()))
    (true (html:selector-matches-p "span[data-x]" span (list div)))
    (true (html:selector-matches-p "span[data-x=\"1\"]" span (list div)))
    (true (html:selector-matches-p "div span" span (list div)))
    (true (html:selector-matches-p "div > span" span (list div)))
    (false (html:selector-matches-p "p" div '()))))

(define-test html/rewrite-set-attribute
  (let* ((rw (html:make-rewriter)))
    (html:rewriter-on
     rw "img"
     (list :element
           (lambda (el)
             (html:element-set-attribute el "alt" "x"))))
    (let ((out (html:rewriter-transform rw "<img src=\"a.png\">")))
      (true (search "alt=\"x\"" out))
      (true (search "src=\"a.png\"" out)))))

(define-test html/rewrite-before-after
  (let* ((rw (html:make-rewriter)))
    (html:rewriter-on
     rw "p"
     (list :element
           (lambda (el)
             (html:element-before el "<b>" :html t)
             (html:element-after el "</b>" :html t))))
    (let ((out (html:rewriter-transform rw "<p>hi</p>")))
      (true (search "<b><p>hi</p></b>" out)))))

(define-test html/rewrite-remove
  (let* ((rw (html:make-rewriter)))
    (html:rewriter-on
     rw "script"
     (list :element (lambda (el) (html:element-remove el))))
    (let ((out (html:rewriter-transform
                rw "<div><script>alert(1)</script><p>ok</p></div>")))
      (false (search "script" out))
      (true (search "<p>ok</p>" out)))))

(define-test html/rewrite-set-inner
  (let* ((rw (html:make-rewriter)))
    (html:rewriter-on
     rw "div"
     (list :element
           (lambda (el)
             (html:element-set-inner-content el "<span>n</span>" :html t))))
    (let ((out (html:rewriter-transform rw "<div>old</div>")))
      (true (search "<span>n</span>" out))
      (false (search "old" out)))))

(define-test html/limits
  (fail (html:parse-html (make-string (1+ html:+max-source-length+)
                                      :initial-element #\a))
        'html:html-error))
