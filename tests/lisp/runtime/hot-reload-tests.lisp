;;;; hot-reload-tests.lisp — tooling.hot-reload full port (#188).
;;;; Pure-CL suite: server identity reload preserves the listener and live
;;;; connections; soft module re-eval keeps globalThis; failed reload recovers;
;;;; import.meta.hot dispose/data; watcher change detection.

(in-package :clun-test)

(defun %hot-write (path text)
  (let ((parent (clun.sys:path-dirname path)))
    (unless (clun.sys:path-exists-p parent)
      (clun.sys:make-directory parent :recursive t :mode #o755)))
  (clun.sys:write-file-octets
   path
   (sb-ext:string-to-octets text :external-format :utf-8)))

(defun %hot-client (loop port request-bytes &key (timeout-ms 4000))
  "One-shot request/response over a fresh TCP connection."
  (let ((got (make-array 0 :element-type '(unsigned-byte 8)
                           :adjustable t :fill-pointer 0)))
    (net:tcp-connect loop "127.0.0.1" port
      :on-connect (lambda (c) (net:tcp-write c request-bytes))
      :on-data (lambda (c data) (declare (ignore c))
                 (loop for b across data do (vector-push-extend b got)))
      :on-close (lambda (c code) (declare (ignore c code)) (lp:loop-stop loop)))
    (lp:set-timer loop timeout-ms (lambda () (lp:loop-stop loop)))
    (lp:run-loop loop)
    (sb-ext:octets-to-string got :external-format :latin-1)))

(defun %hot-req (path &key (connection "close"))
  (sb-ext:string-to-octets
   (format nil "GET ~a HTTP/1.1~c~cHost: x~c~cConnection: ~a~c~c~c~c"
           path #\Return #\Newline #\Return #\Newline connection
           #\Return #\Newline #\Return #\Newline)
   :external-format :latin-1))

(define-test runtime/hot-server-reload-swaps-handler
  "server.reload (and identity reload) swaps fetch without rebinding the port."
  (let ((realm (eng:make-realm)))
    (rt:install-runtime realm :argv '(:script "[hot]" :rest nil) :cwd "/tmp")
    (let ((eng:*realm* realm)
          (rt::*hot-reload-mode* :hot))
      (unwind-protect
           (let* ((g (eng:realm-global realm))
                  (loop (eng:current-loop))
                  (v1 (eng:make-native-function "fetch" 1
                        (lambda (this args) (declare (ignore this args))
                          (eng:js-construct (eng:js-get g "Response")
                                            (list "v1")))))
                  (v2 (eng:make-native-function "fetch" 1
                        (lambda (this args) (declare (ignore this args))
                          (eng:js-construct (eng:js-get g "Response")
                                            (list "v2")))))
                  (opts (eng:new-object)))
             (eng:data-prop opts "port" 0d0)
             (eng:data-prop opts "hostname" "127.0.0.1")
             (eng:data-prop opts "fetch" v1)
             (let* ((server (clun.runtime::%clun-serve g opts))
                    (port (truncate (eng:js-get server "port")))
                    (opts2 (eng:new-object)))
               (eng:data-prop opts2 "port" (coerce port 'double-float))
               (eng:data-prop opts2 "hostname" "127.0.0.1")
               (eng:data-prop opts2 "fetch" v2)
               ;; Identity reload: second serve returns the same server object.
               (let ((again (clun.runtime::%clun-serve g opts2)))
                 (true (eq server again) "identity reload reuses server object"))
               (let ((resp (%hot-client loop port (%hot-req "/"))))
                 (true (search "v2" resp) "handler swapped to v2")
                 (true (search "200" resp)))))
        (setf rt::*hot-reload-mode* nil)
        (rt::hot-stop-all-servers t)
        (eng:teardown-realm realm)))))

(define-test runtime/hot-reload-preserves-connection
  "An open keep-alive TCP connection survives server.reload and serves the new handler."
  (let ((realm (eng:make-realm)))
    (rt:install-runtime realm :argv '(:script "[hot]" :rest nil) :cwd "/tmp")
    (let ((eng:*realm* realm)
          (rt::*hot-reload-mode* :hot))
      (unwind-protect
           (let* ((g (eng:realm-global realm))
                  (loop (eng:current-loop))
                  (tag (list "before"))
                  (fetch (eng:make-native-function "fetch" 1
                           (lambda (this args) (declare (ignore this args))
                             (eng:js-construct (eng:js-get g "Response")
                                               (list (car tag))))))
                  (opts (eng:new-object)))
             (eng:data-prop opts "port" 0d0)
             (eng:data-prop opts "hostname" "127.0.0.1")
             (eng:data-prop opts "fetch" fetch)
             (let* ((server (clun.runtime::%clun-serve g opts))
                    (port (truncate (eng:js-get server "port")))
                    (got (make-array 0 :element-type '(unsigned-byte 8)
                                       :adjustable t :fill-pointer 0))
                    (phase :connect)
                    (conn-box (list nil)))
               (net:tcp-connect loop "127.0.0.1" port
                 :on-connect
                 (lambda (c)
                   (setf (car conn-box) c)
                   (net:tcp-write c (%hot-req "/a" :connection "keep-alive"))
                   (setf phase :wait1))
                 :on-data
                 (lambda (c data)
                   (loop for b across data do (vector-push-extend b got))
                   (let ((text (sb-ext:octets-to-string got :external-format :latin-1)))
                     (when (and (eq phase :wait1) (search "before" text))
                       ;; Swap handler while the connection is still open.
                       (setf (car tag) "after"
                             (fill-pointer got) 0
                             phase :wait2)
                       (let ((opts2 (eng:new-object))
                             (fetch2 (eng:make-native-function "fetch" 1
                                       (lambda (this args)
                                         (declare (ignore this args))
                                         (eng:js-construct
                                          (eng:js-get g "Response")
                                          (list (car tag)))))))
                         (eng:data-prop opts2 "port" (coerce port 'double-float))
                         (eng:data-prop opts2 "hostname" "127.0.0.1")
                         (eng:data-prop opts2 "fetch" fetch2)
                         (clun.runtime::%clun-serve g opts2))
                       (net:tcp-write c (%hot-req "/b" :connection "close")))))
                 :on-close
                 (lambda (c code) (declare (ignore c code))
                   (lp:loop-stop loop)))
               (lp:set-timer loop 5000 (lambda () (lp:loop-stop loop)))
               (lp:run-loop loop)
               (let ((text (sb-ext:octets-to-string got :external-format :latin-1)))
                 (true (search "after" text)
                       "second request on same connection sees reloaded handler"))))
        (setf rt::*hot-reload-mode* nil)
        (rt::hot-stop-all-servers t)
        (eng:teardown-realm realm)))))

(define-test runtime/hot-soft-reload-module-graph
  "Soft reload re-evaluates a changed entry while preserving a global counter."
  (let* ((root (clun.sys:make-temp-dir "/tmp/clun-hot-"))
         (entry (clun.sys:path-join root "counter.mjs")))
    (unwind-protect
         (progn
           (%hot-write
            entry
            "globalThis.n = (globalThis.n || 0) + 1; globalThis.last = 'A';")
           (let ((realm (eng:make-realm)))
             (rt:install-runtime realm :argv (list :script entry :rest nil) :cwd root)
             (let ((eng:*realm* realm)
                   (rt::*hot-reload-mode* :hot))
               (unwind-protect
                    (progn
                      (multiple-value-bind (path format)
                          (eng::resolve-specifier
                           (eng::entry->specifier entry)
                           root '("node" "import"))
                        (let ((mr (eng::load-any path format)))
                          (setf (eng::realm-entry-module realm) mr)
                          (eng::evaluate-module mr)))
                      (let* ((g (eng:realm-global realm))
                             (n1 (eng:to-number (eng:js-get g "n")))
                             (session (rt::make-hot-session realm entry :hot)))
                        (setf rt::*hot-session* session)
                        (is = 1 (truncate n1) "first eval sets n=1")
                        (%hot-write
                         entry
                         "globalThis.n = (globalThis.n || 0) + 1; globalThis.last = 'B';")
                        (true (rt::%soft-reload session (list entry)))
                        (is = 2 (truncate (eng:to-number (eng:js-get g "n")))
                            "globalThis.n survives and increments")
                        (is string= "B" (eng:to-string (eng:js-get g "last"))
                            "new source body ran")
                        (is = 1 (rt::hot-session-reloads session))))
                 (setf rt::*hot-session* nil
                       rt::*hot-reload-mode* nil)
                 (eng:teardown-realm realm)))))
      (ignore-errors (clun.sys:remove-recursive root)))))

(define-test runtime/hot-failed-reload-keeps-prior
  "A syntax error on soft reload is reported and does not wipe prior globals."
  (let* ((root (clun.sys:make-temp-dir "/tmp/clun-hot-fail-"))
         (entry (clun.sys:path-join root "ok.mjs")))
    (unwind-protect
         (progn
           (%hot-write entry "globalThis.marker = 'alive';")
           (let ((realm (eng:make-realm)))
             (rt:install-runtime realm :argv (list :script entry :rest nil) :cwd root)
             (let ((eng:*realm* realm)
                   (rt::*hot-reload-mode* :hot))
               (unwind-protect
                    (progn
                      (multiple-value-bind (path format)
                          (eng::resolve-specifier
                           (eng::entry->specifier entry)
                           root '("node" "import"))
                        (let ((mr (eng::load-any path format)))
                          (setf (eng::realm-entry-module realm) mr)
                          (eng::evaluate-module mr)))
                      (let ((session (rt::make-hot-session realm entry :hot))
                            (g (eng:realm-global realm)))
                        (setf rt::*hot-session* session)
                        (%hot-write entry "this is not { valid js")
                        (let ((ok (rt::%soft-reload session (list entry))))
                          (false ok "soft reload must report failure on syntax error")
                          (true (stringp (rt::hot-session-last-error session))
                                "last-error records the failure"))
                        (is string= "alive"
                            (eng:to-string (eng:js-get g "marker"))
                            "prior global state retained after failed reload")))
                 (setf rt::*hot-session* nil
                       rt::*hot-reload-mode* nil)
                 (eng:teardown-realm realm)))))
      (ignore-errors (clun.sys:remove-recursive root)))))

(define-test runtime/hot-import-meta-hot-dispose-and-data
  "import.meta.hot.dispose runs and import.meta.hot.data persists across soft reload."
  (let* ((root (clun.sys:make-temp-dir "/tmp/clun-hot-meta-"))
         (entry (clun.sys:path-join root "hmr.mjs")))
    (unwind-protect
         (progn
           (%hot-write
            entry
            (concatenate
             'string
             "const hot = import.meta.hot;"
             "if (hot) {"
             "  hot.data.hits = (hot.data.hits || 0) + 1;"
             "  globalThis.hits = hot.data.hits;"
             "  hot.dispose(function () {"
             "    globalThis.disposed = (globalThis.disposed || 0) + 1;"
             "  });"
             "}"))
           (let ((realm (eng:make-realm)))
             (rt:install-runtime realm :argv (list :script entry :rest nil) :cwd root)
             (let ((eng:*realm* realm)
                   (rt::*hot-reload-mode* :hot))
               (unwind-protect
                    (progn
                      (multiple-value-bind (path format)
                          (eng::resolve-specifier
                           (eng::entry->specifier entry)
                           root '("node" "import"))
                        (let ((mr (eng::load-any path format)))
                          (setf (eng::realm-entry-module realm) mr)
                          (eng::evaluate-module mr)))
                      (let ((session (rt::make-hot-session realm entry :hot))
                            (g (eng:realm-global realm)))
                        (setf rt::*hot-session* session)
                        (is = 1 (truncate (eng:to-number (eng:js-get g "hits"))))
                        (%hot-write
                         entry
                         (concatenate
                          'string
                          "const hot = import.meta.hot;"
                          "if (hot) {"
                          "  hot.data.hits = (hot.data.hits || 0) + 1;"
                          "  globalThis.hits = hot.data.hits;"
                          "  hot.dispose(function () {"
                          "    globalThis.disposed = (globalThis.disposed || 0) + 1;"
                          "  });"
                          "}"))
                        (true (rt::%soft-reload session (list entry)))
                        (is = 2 (truncate (eng:to-number (eng:js-get g "hits")))
                            "hot.data.hits persisted")
                        (is = 1 (truncate (eng:to-number (eng:js-get g "disposed")))
                            "dispose callback fired once")))
                 (setf rt::*hot-session* nil
                       rt::*hot-reload-mode* nil)
                 (eng:teardown-realm realm)))))
      (ignore-errors (clun.sys:remove-recursive root)))))

(define-test runtime/hot-stat-signature-detects-change
  "Portable stat signatures change when file contents are rewritten."
  (let* ((root (clun.sys:make-temp-dir "/tmp/clun-hot-stat-"))
         (path (clun.sys:path-join root "f.js")))
    (unwind-protect
         (progn
           (%hot-write path "one")
           (let ((a (rt::%stat-signature path)))
             (true (consp a))
             (sleep 1.1) ; second-granularity mtime on some hosts
             (%hot-write path "two")
             (let ((b (rt::%stat-signature path)))
               (true (consp b))
               (false (equal a b) "mtime/size/ino signature changes after rewrite"))))
      (ignore-errors (clun.sys:remove-recursive root)))))

(define-test runtime/hot-cli-flags-parse
  (let ((r (cli:parse-cli-args '("--hot" "app.js"))))
    (is eq :run (cli:cli-action r))
    (true (cli:cli-get r :hot))
    (false (cli:cli-get r :watch))
    (is string= "app.js" (cli:cli-get r :file)))
  (let ((r (cli:parse-cli-args '("--watch" "--no-clear-screen" "run" "app.js"))))
    (true (cli:cli-get r :watch))
    (true (cli:cli-get r :no-clear-screen))
    (is string= "run" (cli:cli-get r :subcommand))
    (is string= "app.js" (cli:cli-get r :file)))
  (let ((r (cli:parse-cli-args '("--hot" "--watch" "app.js"))))
    (is eq :error (cli:cli-action r))))
