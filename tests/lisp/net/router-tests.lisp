;;;; router-tests.lisp -- Phase 50 immutable route-table core.

(in-package :clun-test)

(defun %router-action (name)
  (eng:make-native-function name 1
    (lambda (this args)
      (declare (ignore this args))
      eng:+undefined+)))

(defun %router-routes (&rest pairs)
  (let ((routes (eng:new-object)))
    (dolist (pair pairs routes)
      (eng:data-prop routes (car pair) (cdr pair)))))

(defmacro with-router-realm (&body body)
  `(let ((realm (eng:make-realm)))
     (rt:install-runtime realm :argv '(:script "[router-test]" :rest nil)
                               :cwd "/tmp")
     (let ((eng:*realm* realm))
       (unwind-protect (progn ,@body)
         (eng:teardown-realm realm)))))

(define-test net/router-precedence-params-and-query
  (with-router-realm
    (let* ((exact (%router-action "exact"))
           (parameter (%router-action "parameter"))
           (wildcard (%router-action "wildcard"))
           (root (%router-action "root"))
           (table
             (rt::%compile-route-table
              (%router-routes
               (cons "/api/users" exact)
               (cons "/api/users/:id" parameter)
               (cons "/api/*" wildcard)
               (cons "/*" root)))))
      (multiple-value-bind (action params)
          (rt::%match-route-table table "/api/users?all=1" "GET")
        (is eq exact action)
        (is equal '() params))
      (multiple-value-bind (action params)
          (rt::%match-route-table table "/api/users/alice%40example.com?q=1" "GET")
        (is eq parameter action)
        (is equal '(("id" . "alice@example.com")) params))
      (multiple-value-bind (action params)
          (rt::%match-route-table table "/api/unknown/deep" "GET")
        (is eq wildcard action)
        (is equal '(("*" . "unknown/deep")) params))
      (multiple-value-bind (action params)
          (rt::%match-route-table table "/outside" "GET")
        (is eq root action)
        (is equal '(("*" . "outside")) params)))))

(define-test net/router-method-fallthrough-and-head
  (with-router-realm
    (let* ((get (%router-action "get"))
           (post (%router-action "post"))
           (fallback (%router-action "fallback"))
           (methods (eng:new-object)))
      (eng:data-prop methods "GET" get)
      (eng:data-prop methods "POST" post)
      (let ((table
              (rt::%compile-route-table
               (%router-routes (cons "/method" methods)
                               (cons "/*" fallback)))))
        (multiple-value-bind (action params)
            (rt::%match-route-table table "/method" "POST")
          (declare (ignore params))
          (is eq post action))
        (multiple-value-bind (action params)
            (rt::%match-route-table table "/method" "HEAD")
          (declare (ignore params))
          (is eq get action))
        (multiple-value-bind (action params)
            (rt::%match-route-table table "/method" "PUT")
          (declare (ignore params))
          (is eq fallback action))))))

(define-test net/router-percent-decoding-and-absolute-form
  (with-router-realm
    (let* ((action (%router-action "unicode"))
           (table
             (rt::%compile-route-table
              (%router-routes (cons "/users/:id" action)))))
      (multiple-value-bind (matched params)
          (rt::%match-route-table
           table "https://spoofed.example/users/%C3%A9?ignored=yes" "GET")
        (is eq action matched)
        (is equal `(("id" . ,(string (code-char #xE9)))) params))
      (multiple-value-bind (matched params)
          (rt::%match-route-table table "/users/%E9" "GET")
        (is eq action matched)
        (is equal `(("id" . ,(string (code-char #xFFFD)))) params)))))

(define-test net/router-validation
  (with-router-realm
    (fail (rt::%compile-route-table
           (%router-routes (cons "/test/:123" (%router-action "bad"))))
          eng:js-condition)
    (fail (rt::%compile-route-table
           (%router-routes (cons "/test/:same/:same" (%router-action "bad"))))
          eng:js-condition)
    (fail (rt::%compile-route-table
           (%router-routes (cons "/test/*/tail" (%router-action "bad"))))
          eng:js-condition)
    (fail (rt::%compile-route-table
           (%router-routes (cons "/test" 123d0)))
          eng:js-condition)))

(define-test net/router-installs-decoded-params
  (with-router-realm
    (let ((request (eng:new-object)))
      (rt::%install-request-route-params
       request '(("id" . "42") ("*" . "a/b")))
      (let ((params (eng:js-get request "params")))
        (is string= "42" (eng:js-get params "id"))
        (is string= "a/b" (eng:js-get params "*"))))))

(define-test net/router-file-range-parser
  (flet ((parsed (value size)
           (multiple-value-list (rt::%parse-byte-range value size))))
    (is equal '(:range 0 3) (parsed "bytes=0-3" 16))
    (is equal '(:range 4 15) (parsed "bytes=4-" 16))
    (is equal '(:range 12 15) (parsed "bytes=-4" 16))
    (is equal '(:range 2 5) (parsed "Bytes = 2-5" 16))
    (is equal '(:range 0 15) (parsed "bytes=0-999" 16))
    (is equal '(:unsatisfiable nil nil) (parsed "bytes=100-200" 16))
    (is equal '(:unsatisfiable nil nil) (parsed "bytes=-4" 0))
    (is equal '(:ignore nil nil) (parsed "bytes=0-1,4-5" 16))
    (is equal '(:ignore nil nil) (parsed "items=0-3" 16))))

(define-test net/router-http-conditional-parsers
  (let* ((instant (encode-universal-time 59 58 23 31 12 2099 0))
         (http-date (rt::%http-date-at instant)))
    (is = instant (rt::%parse-http-date http-date))
    (is = instant (rt::%parse-http-date "2099-12-31T23:58:59.000Z"))
    (is equal nil (rt::%parse-http-date "not-a-date"))
    (true (rt::%if-none-match-p "\"other\", W/\"match\"" "\"match\""))
    (false (rt::%if-none-match-p "\"other\"" "\"match\""))
    (true (rt::%if-none-match-wildcard-p "\"other\", *"))))

(define-test net/router-file-responses-defer-open-until-write-turn
  (with-router-realm
    (let* ((path
             (namestring
              (asdf:system-relative-pathname
               :clun "tests/compat/server.router/server.js")))
           (file (rt::%clun-file (eng:realm-global realm) path))
           (response (rt::%new-response file eng:+undefined+))
           (source (rt::%serialize-response response "GET" t)))
      (true (rt::file-response-source-p source))
      (let ((plan (rt::%serialize-file-response source)))
        (true (rt::file-send-plan-p plan))
        (true (plusp (rt::file-send-plan-remaining plan)))
        (rt::%close-file-send-plan plan)
        (is equal nil (rt::file-send-plan-stream plan))))))
