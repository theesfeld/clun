;;;; url-tests.lisp — Phase 18 gate: the WHATWG URL + URLSearchParams corpus (a
;;;; WPT-derived subset). All pure/synchronous (no loop): parse components, relative
;;;; resolution, dot-segment normalization, IPv4/IPv6 hosts, default-port elision,
;;;; percent-encoding, IDNA rejection, setters, and URLSearchParams (form-urlencoded).

(in-package :clun-test)

(defun url-realm ()
  "A realm with the runtime globals (URL/URLSearchParams live there)."
  (let ((realm (eng:make-realm)))
    (rt:install-runtime realm :argv '(:script "[test]" :rest nil) :cwd "/tmp")
    realm))

(defmacro with-url-realm ((var) &body body)
  "Bind VAR to a fresh runtime realm; tear it down afterward."
  `(let ((,var (url-realm)))
     (unwind-protect (progn ,@body) (eng:teardown-realm ,var))))

(defun jseval (realm src)
  "Evaluate the JS expression SRC in REALM and return the resulting JS value."
  (let ((eng:*realm* realm))
    (eng:run-program (eng:parse-program (format nil "globalThis.__r = (~a);" src)) realm)
    (eng:js-get (eng:realm-global realm) "__r")))

(defun jss (realm src) (eng:to-string (jseval realm src)))
(defun jsthrows (realm src)
  "The error `name` iff evaluating SRC throws a JS exception, else NIL."
  (handler-case (progn (jseval realm src) nil)
    (eng:js-condition (c)
      (let ((v (eng:js-condition-value c)))
        (if (eng:js-object-p v) (eng:to-string (eng:js-get v "name")) "throw")))))

;;; --- absolute parse: components ---------------------------------------------

(define-test url/components
  (with-url-realm (r)
    (let ((base "new URL('http://user:pw@Example.COM:8080/a/b?x=1&y=2#frag')"))
      (is string= "http:" (jss r (format nil "~a.protocol" base)))
      (is string= "user" (jss r (format nil "~a.username" base)))
      (is string= "pw" (jss r (format nil "~a.password" base)))
      (is string= "example.com:8080" (jss r (format nil "~a.host" base)))    ; host lower-cased
      (is string= "example.com" (jss r (format nil "~a.hostname" base)))
      (is string= "8080" (jss r (format nil "~a.port" base)))
      (is string= "/a/b" (jss r (format nil "~a.pathname" base)))
      (is string= "?x=1&y=2" (jss r (format nil "~a.search" base)))
      (is string= "#frag" (jss r (format nil "~a.hash" base)))
      (is string= "http://example.com:8080" (jss r (format nil "~a.origin" base))))))

(define-test url/default-port-elision
  (with-url-realm (r)
    (is string= "" (jss r "new URL('http://x:80/').port"))          ; :80 elided for http
    (is string= "x" (jss r "new URL('http://x:80/').host"))
    (is string= "" (jss r "new URL('https://x:443/').port"))
    (is string= "8080" (jss r "new URL('http://x:8080/').port"))    ; non-default kept
    (is string= "http://h/" (jss r "new URL('http://h').href"))     ; empty path → "/"
    (is string= "/" (jss r "new URL('http://h').pathname"))))

(define-test url/hosts
  (with-url-realm (r)
    (is string= "[::1]" (jss r "new URL('http://[::1]:9/p').hostname"))    ; IPv6 literal
    (is string= "9" (jss r "new URL('http://[::1]:9/p').port"))
    (is string= "127.0.0.1" (jss r "new URL('http://127.0.0.1/').hostname"))
    (is string= "file:" (jss r "new URL('file:///etc/hosts').protocol"))   ; file: empty host OK
    (is string= "" (jss r "new URL('file:///etc/hosts').host"))
    (is string= "/etc/hosts" (jss r "new URL('file:///etc/hosts').pathname"))
    (is string= "TypeError" (jsthrows r "new URL('http://ex\\u00e4mple.com/')")) ; IDNA → loud error
    (is string= "TypeError" (jsthrows r "new URL('not a url')"))))          ; no scheme/base

(define-test url/dot-segments
  (with-url-realm (r)
    (is string= "/a/c" (jss r "new URL('http://h/a/./b/../c').pathname"))
    (is string= "/" (jss r "new URL('http://h/a/../').pathname"))
    (is string= "/b" (jss r "new URL('http://h/../../b').pathname"))))     ; can't go above root

(define-test url/percent-encoding
  (with-url-realm (r)
    (is string= "http://x/a%20b?c%20d#e%20f" (jss r "new URL('http://x/a b?c d#e f').href"))
    (is string= "/p%22q" (jss r "new URL('http://x/p\\u0022q').pathname"))))

;;; --- relative resolution ----------------------------------------------------

(define-test url/relative
  (with-url-realm (r)
    (is string= "http://h/a/g" (jss r "new URL('../g','http://h/a/b/c').href"))
    (is string= "http://other/x" (jss r "new URL('//other/x','http://h/a').href")) ; network-path
    (is string= "http://h/a/b?y=2" (jss r "new URL('?y=2','http://h/a/b?x=1').href")) ; query-only keeps path
    (is string= "http://h/a/b#top" (jss r "new URL('#top','http://h/a/b').href"))  ; frag-only keeps path
    (is string= "http://h/x" (jss r "new URL('/x','http://h/a/b').href"))          ; absolute path
    (is string= "http://h/a/b/?q" (jss r "new URL('','http://h/a/b/?q').href"))))  ; empty keeps path+query, drops frag

;;; --- setters ----------------------------------------------------------------

(define-test url/setters
  (with-url-realm (r)
    (is string= "http://x:8443/" (jss r "(()=>{let z=new URL('http://x/');z.port='8443';return z.href})()"))
    (is string= "#abc" (jss r "(()=>{let z=new URL('http://x/');z.hash='abc';return z.hash})()"))
    (is string= "?a=1&b=2" (jss r "(()=>{let z=new URL('http://x/');z.search='a=1&b=2';return z.search})()"))
    (is string= "http://x/p/q" (jss r "(()=>{let z=new URL('http://x/');z.pathname='/p/q';return z.href})()"))
    (is string= "y.com" (jss r "(()=>{let z=new URL('http://x/');z.hostname='y.com';return z.hostname})()"))))

(define-test url/canparse-tojson
  (with-url-realm (r)
    (is eq eng:+true+ (jseval r "URL.canParse('http://x/')"))
    (is eq eng:+false+ (jseval r "URL.canParse('nonsense')"))
    (is string= "http://x/p" (jss r "new URL('http://x/p').toJSON()"))))

;;; --- URLSearchParams ---------------------------------------------------------

(define-test url/searchparams-basics
  (with-url-realm (r)
    (is string= "1" (jss r "new URLSearchParams('a=1&b=2&a=3').get('a')"))
    (is string= "1,3" (jss r "new URLSearchParams('a=1&b=2&a=3').getAll('a').join(',')"))
    (is eq eng:+true+ (jseval r "new URLSearchParams('a=1&b=2').has('b')"))
    (is eq eng:+false+ (jseval r "new URLSearchParams('a=1').has('z')"))
    (is = 3d0 (jseval r "new URLSearchParams('a=1&b=2&a=3').size"))
    (is string= "b c" (jss r "new URLSearchParams('a=b+c').get('a')"))         ; + → space
    (is string= "a=b+c" (jss r "(()=>{let s=new URLSearchParams();s.set('a','b c');return s.toString()})()"))))

(define-test url/searchparams-mutation
  (with-url-realm (r)
    (is string= "a=1&b=2&a=3&c=x+y"
        (jss r "(()=>{let s=new URLSearchParams('a=1&b=2&a=3');s.append('c','x y');return s.toString()})()"))
    (is string= "9" (jss r "(()=>{let s=new URLSearchParams('a=1&a=3');s.set('a','9');return s.getAll('a').join(',')})()"))
    (is string= "a=1&m=2&z=3" (jss r "(()=>{let s=new URLSearchParams('z=3&a=1&m=2');s.sort();return s.toString()})()"))
    (is string= "a=1" (jss r "(()=>{let s=new URLSearchParams('a=1&b=2');s.delete('b');return s.toString()})()"))))

;;; --- Phase-18 review-panel regressions --------------------------------------

(define-test url/review-regressions
  (with-url-realm (r)
    ;; [1] special-scheme backslashes normalize to "/" (\ is a literal backslash)
    (is string= "/a/b" (jss r "new URL('http://h/a\\u005cb').pathname"))
    (is string= "https://example.com/p" (jss r "new URL('https:\\u005c\\u005cexample.com\\u005cp').href"))
    ;; [2] empty-username + password round-trips (no silent data loss)
    (is string= "http://:secret@host/p" (jss r "new URL('http://:secret@host/p').href"))
    (is string= "secret" (jss r "new URL(new URL('http://:secret@host/p').href).password"))
    ;; [4]/[6] a port > 65535 is a parse failure, not a stored bignum (→ would crash a socket)
    (is string= "TypeError" (jsthrows r "new URL('http://h:65536/')"))
    ;; [7] port setter parses leading digits, ignores a no-leading-digit value
    (is string= "8080" (jss r "(()=>{let u=new URL('http://h/');u.port='8080xyz';return u.port})()"))
    (is string= "9" (jss r "(()=>{let u=new URL('http://h:9/');u.port='abc';return u.port})()"))
    ;; [11] IPv6 hex lower-cased
    (is string= "[2001:db8::1]" (jss r "new URL('http://[2001:DB8::1]/').hostname"))
    ;; [13] percent-encoded dot-segments removed
    (is string= "/b" (jss r "new URL('http://h/a/%2e%2e/b').pathname"))))

(define-test url/searchparams-linked
  ;; mutating url.searchParams reflects back into url.search / url.href
  (with-url-realm (r)
    (is string= "http://x/?a=1&b=2"
        (jss r "(()=>{let u=new URL('http://x/?a=1');u.searchParams.append('b','2');return u.href})()"))
    (is string= "?c=3"
        (jss r "(()=>{let u=new URL('http://x/?a=1&b=2');u.searchParams.delete('a');u.searchParams.delete('b');u.searchParams.set('c','3');return u.search})()"))))
