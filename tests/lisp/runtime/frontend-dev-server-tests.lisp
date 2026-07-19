;;;; frontend-dev-server-tests.lisp — tooling.frontend-dev-server full port (#189).

(in-package :clun-test)

(defun %fds-write (path text)
  (let ((parent (clun.sys:path-dirname path)))
    (unless (clun.sys:path-exists-p parent)
      (clun.sys:make-directory parent :recursive t :mode #o755)))
  (clun.sys:write-file-octets
   path
   (sb-ext:string-to-octets text :external-format :utf-8)))

(defun %fds-client (loop port request-bytes &key (timeout-ms 4000))
  (let ((got (make-array 0 :element-type '(unsigned-byte 8)
                           :adjustable t :fill-pointer 0)))
    (net:tcp-connect loop "127.0.0.1" port
      :on-connect (lambda (c) (net:tcp-write c request-bytes))
      :on-data (lambda (c data)
                 (declare (ignore c))
                 (loop for b across data do (vector-push-extend b got)))
      :on-close (lambda (c code)
                  (declare (ignore c code))
                  (lp:loop-stop loop)))
    (lp:set-timer loop timeout-ms (lambda () (lp:loop-stop loop)))
    (lp:run-loop loop)
    (sb-ext:octets-to-string got :external-format :latin-1)))

(defun %fds-req (path &key (connection "close") (host "x"))
  (sb-ext:string-to-octets
   (format nil "GET ~a HTTP/1.1~c~cHost: ~a~c~cConnection: ~a~c~c~c~c"
           path #\Return #\Newline host #\Return #\Newline connection
           #\Return #\Newline #\Return #\Newline)
   :external-format :latin-1))

(define-test runtime/fds-html-scan-and-rewrite
  "HTML scanner finds script/link assets; rewrite points them at /_clun/dev/."
  (let* ((root (clun.sys:make-temp-dir "/tmp/clun-fds-"))
         (html-path (clun.sys:path-join root "index.html"))
         (js-path (clun.sys:path-join root "app.js"))
         (css-path (clun.sys:path-join root "style.css")))
    (unwind-protect
         (progn
           (%fds-write js-path "export const n = 1;")
           (%fds-write css-path "body{color:red}")
           (%fds-write html-path
                       (concatenate 'string
                        "<!doctype html><html><head>"
                        "<link rel=\"stylesheet\" href=\"./style.css\">"
                        "</head><body><div id=\"root\"></div>"
                        "<script type=\"module\" src=\"./app.js\"></script>"
                        "</body></html>"))
           (let* ((html (clun.sys:read-file-string html-path))
                  (assets (clun.runtime::fds-scan-html html root))
                  (rewritten (clun.runtime::fds-rewrite-html html assets t)))
             (true (>= (length assets) 2) "finds script and stylesheet")
             (true (search "/_clun/dev/src/" rewritten) "asset URLs rewritten")
             (true (search "/_clun/dev/client.js" rewritten) "HMR client injected")
             (true (null (search "src=\"./app.js\"" rewritten))
                   "relative script src replaced")))
      (ignore-errors (clun.sys:remove-recursive root)))))

(define-test runtime/fds-transform-ts-and-css
  "On-demand transform lowers TS and passes CSS with correct content-types."
  (let* ((root (clun.sys:make-temp-dir "/tmp/clun-fds-x-"))
         (ts (clun.sys:path-join root "mod.ts"))
         (css (clun.sys:path-join root "a.css")))
    (unwind-protect
         (progn
           (%fds-write ts "const x: number = 1; export default x;")
           (%fds-write css "h1{margin:0}")
           (multiple-value-bind (body ctype)
               (clun.runtime::fds-transform-file ts)
             (true (search "text/javascript" ctype))
             (true (not (search ": number" body)) "types stripped")
             (true (search "export default" body)))
           (multiple-value-bind (body ctype)
               (clun.runtime::fds-transform-file css)
             (true (search "text/css" ctype))
             (true (search "margin" body))))
      (ignore-errors (clun.sys:remove-recursive root)))))

(define-test runtime/fds-html-entry-import-and-serve
  "HTML entry brand served under development with rewritten assets + HMR client."
  (let* ((root (clun.sys:make-temp-dir "/tmp/clun-fds-s-"))
         (html (clun.sys:path-join root "index.html"))
         (js (clun.sys:path-join root "main.js")))
    (unwind-protect
         (progn
           (%fds-write js "export const ok = true;")
           (%fds-write html
                       (concatenate 'string
                        "<!doctype html><html><body><h1>hi</h1>"
                        "<script type=\"module\" src=\"./main.js\"></script>"
                        "</body></html>"))
           (let ((realm (eng:make-realm)))
             (rt:install-runtime realm :argv '(:script "[fds]" :rest nil) :cwd root)
             (let ((eng:*realm* realm))
               (unwind-protect
                    (let* ((g (eng:realm-global realm))
                           (page (clun.runtime::make-html-entry html :root root))
                           (opts (eng:new-object))
                           (routes (eng:new-object)))
                      (eng:data-prop routes "/" page)
                      (eng:data-prop opts "hostname" "127.0.0.1")
                      (eng:data-prop opts "port" 0d0)
                      (eng:data-prop opts "development" eng:+true+)
                      (eng:data-prop opts "routes" routes)
                      (let* ((server (clun.runtime::%clun-serve g opts))
                             (port (truncate (eng:js-get server "port")))
                             (loop (eng:current-loop))
                             (resp (%fds-client loop port (%fds-req "/")))
                             (dev (eng:js-truthy (eng:js-get server "development")))
                             (clun (eng:js-get g "Clun"))
                             (ds (eng:js-get clun "devServer"))
                             (active (eng:js-truthy (eng:js-get ds "active")))
                             (hmr (eng:to-string
                                   (eng:js-call (eng:js-get ds "hmrPath")
                                                eng:+undefined+ '()))))
                        (true (clun.runtime::html-entry-p page))
                        (true dev)
                        (true active)
                        (is string= "/_clun/hmr" hmr)
                        (true (search "200" resp) "HTML route 200")
                        (true (search "hi" resp) "HTML body served")
                        (true (search "/_clun/dev/" resp) "rewritten asset URLs")
                        (true (search "client.js" resp) "HMR client injected")
                        (true (search "/_clun/dev/src/" resp) "asset marker present")
                        ;; On-demand transform path used by the asset handler.
                        (multiple-value-bind (body ctype)
                            (clun.runtime::fds-transform-file js)
                          (true (search "text/javascript" ctype))
                          (true (search "export" body)))
                        ;; Client script is served as a fixed path.
                        (let* ((loop2 (eng:current-loop))
                               (client-resp
                                 (%fds-client loop2 port
                                              (%fds-req "/_clun/dev/client.js"))))
                          (true (search "200" client-resp) "HMR client 200")
                          (true (search "WebSocket" client-resp)
                                "HMR client body"))
                        ;; Stop server + unbind session so timers don't hang.
                        (let ((stop (eng:js-get server "stop")))
                          (when (eng:callable-p stop)
                            (eng:js-call stop server (list eng:+true+))))))
                 (eng:teardown-realm realm)))))
      (ignore-errors (clun.sys:remove-recursive root)))))

(define-test runtime/fds-path-isolation
  "Asset URLs outside the isolation root are rejected."
  (let* ((root (clun.sys:make-temp-dir "/tmp/clun-fds-iso-"))
         (html (clun.sys:path-join root "index.html")))
    (unwind-protect
         (progn
           (%fds-write html "<!doctype html><html><body>x</body></html>")
           (let ((realm (eng:make-realm)))
             (rt:install-runtime realm :argv '(:script "[fds]" :rest nil) :cwd root)
             (let ((eng:*realm* realm))
               (unwind-protect
                    (let* ((g (eng:realm-global realm))
                           (page (clun.runtime::make-html-entry html :root root))
                           (opts (eng:new-object))
                           (routes (eng:new-object))
                           (dev (eng:new-object)))
                      (eng:data-prop routes "/" page)
                      (eng:data-prop dev "hmr" eng:+true+)
                      (eng:data-prop dev "root" root)
                      (eng:data-prop opts "hostname" "127.0.0.1")
                      (eng:data-prop opts "port" 0d0)
                      (eng:data-prop opts "development" dev)
                      (eng:data-prop opts "routes" routes)
                      (let* ((server (clun.runtime::%clun-serve g opts))
                             (port (truncate (eng:js-get server "port")))
                             (evil (concatenate
                                    'string "/_clun/dev/src/"
                                    (clun.runtime::%url-encode-path
                                     "/etc/passwd")))
                             (loop (eng:current-loop))
                             (resp (%fds-client loop port (%fds-req evil))))
                        (true (or (search "403" resp)
                                  (search "500" resp)
                                  (search "escapes" resp)
                                  (search "Forbidden" resp)
                                  (search "Not Found" resp))
                              "traversal rejected")
                        (let ((stop (eng:js-get server "stop")))
                          (when (eng:callable-p stop)
                            (eng:js-call stop server (list eng:+true+))))))
                 (eng:teardown-realm realm)))))
      (ignore-errors (clun.sys:remove-recursive root)))))

(define-test runtime/fds-clun-html-entry-helper
  "Clun.devServer.htmlEntry builds a brand without importing a file module."
  (let ((realm (eng:make-realm)))
    (rt:install-runtime realm :argv '(:script "[fds]" :rest nil) :cwd "/tmp")
    (let ((eng:*realm* realm))
      (unwind-protect
           (let* ((g (eng:realm-global realm))
                  (clun (eng:js-get g "Clun"))
                  (dev (eng:js-get clun "devServer"))
                  (fn (eng:js-get dev "htmlEntry"))
                  (entry (eng:js-call fn eng:+undefined+
                                      (list "/tmp/demo.html"))))
             (true (clun.runtime::html-entry-p entry))
             (is string= "html" (eng:to-string (eng:js-get entry "kind")))
             (true (search "demo.html"
                           (eng:to-string (eng:js-get entry "path")))))
        (eng:teardown-realm realm)))))

(define-test runtime/fds-development-object
  "development: { hmr: false } disables HMR client injection."
  (let* ((root (clun.sys:make-temp-dir "/tmp/clun-fds-dev-"))
         (html (clun.sys:path-join root "index.html")))
    (unwind-protect
         (progn
           (%fds-write html "<!doctype html><html><body>nohmr</body></html>")
           (let ((realm (eng:make-realm)))
             (rt:install-runtime realm :argv '(:script "[fds]" :rest nil) :cwd root)
             (let ((eng:*realm* realm))
               (unwind-protect
                    (let* ((g (eng:realm-global realm))
                           (page (clun.runtime::make-html-entry html :root root))
                           (opts (eng:new-object))
                           (routes (eng:new-object))
                           (dev (eng:new-object)))
                      (eng:data-prop routes "/" page)
                      (eng:data-prop dev "hmr" eng:+false+)
                      (eng:data-prop opts "hostname" "127.0.0.1")
                      (eng:data-prop opts "port" 0d0)
                      (eng:data-prop opts "development" dev)
                      (eng:data-prop opts "routes" routes)
                      (let* ((server (clun.runtime::%clun-serve g opts))
                             (port (truncate (eng:js-get server "port")))
                             (loop (eng:current-loop))
                             (resp (%fds-client loop port (%fds-req "/"))))
                        (true (search "nohmr" resp))
                        (true (null (search "client.js" resp))
                              "HMR client not injected when hmr:false")
                        (let ((stop (eng:js-get server "stop")))
                          (when (eng:callable-p stop)
                            (eng:js-call stop server (list eng:+true+))))))
                 (eng:teardown-realm realm)))))
      (ignore-errors (clun.sys:remove-recursive root)))))

(define-test runtime/fds-hmr-client-source
  "HMR client source exposes WebSocket path and accept registry."
  (let ((src (clun.runtime::%hmr-client-source)))
    (true (search "/_clun/hmr" src))
    (true (search "WebSocket" src))
    (true (search "__clunHot" src))
    (true (search "full-reload" src))))

(define-test runtime/fds-html-module-import
  "import page from './index.html' yields HTML entry brand as default export."
  (let* ((root (clun.sys:make-temp-dir "/tmp/clun-fds-imp-"))
         (html (clun.sys:path-join root "index.html"))
         (entry (clun.sys:path-join root "imp.mjs")))
    (unwind-protect
         (progn
           (%fds-write html "<!doctype html><html><body>z</body></html>")
           (%fds-write entry
                       (concatenate 'string
                        "import page from './index.html';"
                        "globalThis.__kind = page.kind;"
                        "globalThis.__path = page.path;"))
           (let ((realm (eng:make-realm)))
             (rt:install-runtime realm
                                 :argv (list :script entry :rest nil)
                                 :cwd root)
             (let ((eng:*realm* realm))
               (unwind-protect
                    (progn
                      (eng:run-module-file entry :realm realm :teardown t)
                      (let* ((g (eng:realm-global realm))
                             (kind (eng:to-string (eng:js-get g "__kind")))
                             (path (eng:to-string (eng:js-get g "__path"))))
                        (is string= "html" kind)
                        (true (search "index.html" path))))
                 (ignore-errors (eng:teardown-realm realm))))))
      (ignore-errors (clun.sys:remove-recursive root)))))
