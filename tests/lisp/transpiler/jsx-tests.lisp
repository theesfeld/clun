;;;; jsx-tests.lisp — parachute unit tests for pure-CL JSX/TSX transform (#186).

(in-package :clun-test)

(defun jx (src &optional (path "t.jsx"))
  (clun.transpiler:transform-jsx src path))

(define-test jsx/automatic-element
  (let ((out (jx "const el = <div className=\"x\">hi</div>;")))
    (true (search "__jsx" out))
    (true (search "\"div\"" out))
    (true (search "className" out))
    (true (search "hi" out))))

(define-test jsx/classic-pragma
  (let ((out (jx (format nil "// @jsxRuntime classic~%const el = <span/>;"))))
    (true (search "React.createElement" out))
    (true (search "\"span\"" out))))

(define-test jsx/fragment
  (let ((out (jx "const el = <><a/><b/></>;")))
    (true (search "__Fragment" out))
    (true (or (search "__jsxs" out) (search "__jsx" out)))))

(define-test jsx/spread-attr
  (let ((out (jx "const el = <div {...props}/>;")))
    (true (search "..." out))
    (true (search "props" out))))

(define-test jsx/component-member
  (let ((out (jx "const el = <Foo.Bar w={1}/>;")))
    (true (search "Foo.Bar" out))
    (false (search "\"Foo.Bar\"" out))))

(define-test jsx/self-closing-intrinsic
  (let ((out (jx "const el = <br/>;")))
    (true (search "\"br\"" out))))

(define-test jsx/entity-text
  (let ((out (jx "const el = <p>a&amp;b</p>;")))
    (true (search "a&b" out))))

(define-test jsx/comparison-not-jsx
  (let ((out (jx "const c = a < b && c > d;")))
    (true (search "a < b" out))
    (false (search "__jsx" out))))
