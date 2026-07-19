;;;; frontend-dev-server.lisp — tooling.frontend-dev-server FULL PORT (#189 / Phase 68 / epic #177).
;;;;
;;;; Pure Common Lisp browser-focused development server that meets and exceeds Bun's
;;;; HTML-entry + HMR surface (`Bun.serve({ routes: { "/": homepage }, development })`):
;;;;   * HTML module imports (`import page from "./index.html"`) produce HTML entry brands
;;;;   * Clun.serve routes accept HTML entries; scripts/links are transformed on demand
;;;;   * TS/TSX/JSX lowered via existing pure-CL transpiler hooks; CSS served as modules
;;;;   * development: true | { hmr, console, origin } enables HMR WebSocket + client inject
;;;;   * Pure-CL stat-poll file watching (no FSEvents/inotify FFI); broadcasts over HMR WS
;;;;   * Origin/host allow-list, path isolation (no `..` traversal outside roots)
;;;;   * Clun.devServer introspection (exceeds Bun), overlay error payloads, full-reload fallback
;;;;   * Soft integration with tooling.hot-reload when `*hot-reload-mode*` / Clun.hot exist

(in-package :clun.runtime)

;;; --- constants --------------------------------------------------------------

(defparameter *fds-asset-prefix* "/_clun/dev/"
  "URL prefix for transformed frontend assets served by the dev server.")

(defparameter *fds-hmr-path* "/_clun/hmr"
  "WebSocket upgrade path for browser HMR clients.")

(defparameter *fds-client-path* "/_clun/dev/client.js"
  "Injected browser HMR client module URL.")

(defparameter *fds-poll-ms* 80
  "Stat-poll interval for HTML-entry dependency watching (pure CL).")

(defparameter *fds-coalesce-ms* 40
  "Debounce window after the first detected asset change.")

;;; --- HTML entry brand -------------------------------------------------------

(defstruct (js-html-entry
            (:include eng:js-object (class :html-entry))
            (:constructor %make-js-html-entry))
  path                                  ; absolute filesystem path to the .html
  (root nil))                           ; optional project root for isolation

(defun html-entry-p (value)
  (js-html-entry-p value))

(defun make-html-entry (path &key root)
  "Build a Bun-shaped HTML entry brand for PATH (absolute)."
  (let* ((abs (clun.sys:normalize-path path))
         (entry (%make-js-html-entry
                 :proto (eng:intrinsic :object-prototype)
                 :path abs
                 :root (or root (clun.sys:path-dirname abs)))))
    (eng:data-prop entry "path" abs)
    (eng:data-prop entry "kind" "html")
    (eng:data-prop entry "toString" (eng:make-native-function "toString" 0
                                    (lambda (this args)
                                      (declare (ignore args))
                                      (js-html-entry-path this))))
    entry))

;;; --- development options ----------------------------------------------------

(defstruct (fds-dev-options
            (:constructor %make-fds-dev-options)
            (:conc-name fds-dev-))
  (enabled nil)
  (hmr t)
  (console nil)
  (origins nil)                         ; list of allowed Origin / Host strings, or NIL = any
  (root nil))                           ; isolation root directory

(defun %parse-development-option (opts)
  "Parse Clun.serve `development` into FDS-DEV-OPTIONS or NIL when disabled."
  (let ((value (eng:js-get opts "development")))
    (cond
      ((or (eng:js-undefined-p value) (eng:js-null-p value)
           (eq value eng:+false+))
       nil)
      ((eq value eng:+true+)
       (%make-fds-dev-options :enabled t :hmr t))
      ((eng:js-object-p value)
       (let* ((hmr-v (eng:js-get value "hmr"))
              (console-v (eng:js-get value "console"))
              (origin-v (eng:js-get value "origin"))
              (root-v (eng:js-get value "root"))
              (hmr (if (eng:js-undefined-p hmr-v) t (eng:js-truthy hmr-v)))
              (console (and (not (eng:js-undefined-p console-v))
                            (eng:js-truthy console-v)))
              (origins
                (cond
                  ((eng:js-undefined-p origin-v) nil)
                  ((eng:js-string-p origin-v) (list (eng:to-string origin-v)))
                  ((eng:js-array-p origin-v)
                   (loop for i from 0 below (eng:array-length origin-v)
                         for el = (eng:js-get origin-v (princ-to-string i))
                         when (eng:js-string-p el)
                         collect (eng:to-string el)))
                  (t nil)))
              (root (when (eng:js-string-p root-v)
                      (clun.sys:normalize-path (eng:to-string root-v)))))
         (%make-fds-dev-options :enabled t :hmr hmr :console console
                                :origins origins :root root)))
      (t
       ;; Truthy non-object (e.g. 1) → enabled defaults.
       (if (eng:js-truthy value)
           (%make-fds-dev-options :enabled t :hmr t)
           nil)))))

;;; --- per-server session -----------------------------------------------------

(defstruct (fds-session
            (:constructor %make-fds-session)
            (:conc-name fds-))
  server
  (dev nil)                             ; fds-dev-options
  (html-routes (make-hash-table :test 'equal)) ; pattern → html-entry
  (watch-sigs (make-hash-table :test 'equal))  ; path → signature string
  (clients '())                         ; list of ws-session or send-fn
  (client-senders '())                  ; list of (lambda (text) ...)
  (timer nil)
  (coalesce-deadline 0)
  (coalesced-paths '())
  (reloads 0)
  (last-error nil)
  (started-ms 0)
  (last-reload-ms 0)
  (console-logs '()))

(defvar *fds-sessions* (make-hash-table :test 'eq)
  "server object → fds-session while development mode is active.")

(defvar *fds-active* nil
  "The most recently armed frontend-dev session (for Clun.devServer).")

(defun %file-signature (path)
  "Portable change signature: size + mtime-ns + inode when available + content hash head."
  (handler-case
      (let* ((stat (clun.sys:stat* path))
             (size (clun.sys:fstat-size stat))
             (mtime (clun.sys:fstat-mtime-ns stat))
             (ino (clun.sys:fstat-ino stat))
             (octets (clun.sys:read-file-octets path))
             (n (min (length octets) 4096))
             (acc 2166136261))
        (loop for i from 0 below n
              do (setf acc (logand #xffffffff
                                   (* (logxor acc (aref octets i)) 16777619))))
        (format nil "~a:~a:~a:~x" size mtime ino acc))
    (error () "")))

(defun %path-under-root-p (path root)
  "T when normalized PATH is ROOT or a descendant (path isolation)."
  (let* ((p (clun.sys:normalize-path path))
         (r (clun.sys:normalize-path root)))
    (or (string= p r)
        (and (> (length p) (length r))
             (string= p r :end1 (length r))
             (char= (char p (length r)) #\/)))))

(defun %assert-path-allowed (path session)
  (let ((root (or (and (fds-dev session) (fds-dev-root (fds-dev session)))
                  (and *runtime* (runtime-realm *runtime*)
                       (let ((cwd (eng:js-get
                                   (eng:js-get (eng:realm-global (runtime-realm *runtime*))
                                               "process")
                                   "cwd")))
                         (when (eng:callable-p cwd)
                           (eng:to-string (eng:js-call cwd eng:+undefined+ '())))))
                  (clun.sys:pathname->native
                   (handler-case (truename ".") (error () "."))))))
    (unless (%path-under-root-p path root)
      (error "frontend-dev-server: path escapes isolation root: ~a" path))
    path))

;;; --- HTML scan / rewrite ----------------------------------------------------

(defun %scan-html-assets (html base-dir)
  "Return list of plists (:kind :script|:style|:module :raw :abs) from HTML."
  (let ((results '())
        (n (length html))
        (i 0))
    (labels ((skip-ws (j)
               (loop while (and (< j n) (member (char html j)
                                               '(#\Space #\Tab #\Newline #\Return)
                                               :test #'char=))
                     do (incf j))
               j)
             (read-attr (j name)
               "Return (values value end-index) for attribute NAME at/after j, or NIL."
               (let ((needle (concatenate 'string name "=")))
                 (loop while (< j n)
                       do (let ((c (char html j)))
                            (when (char= c #\>)
                              (return-from read-attr (values nil j)))
                            (when (and (<= (+ j (length needle)) n)
                                       (string-equal html needle
                                                     :start1 j
                                                     :end1 (+ j (length needle))))
                              (let* ((k (+ j (length needle)))
                                     (quote (when (and (< k n)
                                                       (member (char html k)
                                                               '(#\" #\') :test #'char=))
                                              (char html k)))
                                     (start (if quote (1+ k) k))
                                     (end (if quote
                                              (or (position quote html :start start) n)
                                              (or (position-if
                                                   (lambda (ch)
                                                     (member ch '(#\Space #\Tab #\Newline
                                                                  #\Return #\> #\/)
                                                             :test #'char=))
                                                   html :start start)
                                                  n))))
                                (return-from read-attr
                                  (values (subseq html start end)
                                          (if quote (1+ end) end)))))
                            (incf j)))
                 (values nil j)))
             (resolve-ref (ref)
               (when (and ref (plusp (length ref))
                          (not (or (search "://" ref)
                                   (and (>= (length ref) 2)
                                        (char= (char ref 0) #\/)
                                        (char= (char ref 1) #\/))
                                   (char= (char ref 0) #\#)
                                   (char= (char ref 0) #\?)
                                   (and (>= (length ref) 5)
                                        (string-equal "data:" ref :end2 5)))))
                 (let ((joined
                         (if (char= (char ref 0) #\/)
                             ref
                             (clun.sys:normalize-path
                              (clun.sys:path-join base-dir ref)))))
                   (when (and (char/= (char ref 0) #\/)
                              (clun.sys:file-p joined))
                     joined)
                   (cond
                     ((char= (char ref 0) #\/) nil) ; site-absolute: leave alone
                     ((clun.sys:file-p joined) joined)
                     (t joined))))))
      (loop while (< i n)
            do (let ((lt (position #\< html :start i)))
                 (unless lt (return))
                 (let* ((tag-start lt)
                        (name-end (or (position-if
                                       (lambda (ch)
                                         (member ch '(#\Space #\Tab #\Newline #\Return
                                                      #\> #\/) :test #'char=))
                                       html :start (1+ lt))
                                      n))
                        (tag (string-downcase (subseq html (1+ lt) name-end))))
                   (cond
                     ((string= tag "script")
                      (multiple-value-bind (src j) (read-attr name-end "src")
                        (let ((abs (resolve-ref src))
                              (type-v (nth-value 0 (read-attr name-end "type"))))
                          (when abs
                            (push (list :kind (if (and type-v
                                                       (search "module" type-v
                                                               :test #'char-equal))
                                                  :module
                                                  :script)
                                        :raw src
                                        :abs abs
                                        :tag-start tag-start
                                        :attr-start (- j (length src)
                                                       (if (and (< j n)
                                                                (member (char html (1- j))
                                                                        '(#\" #\')
                                                                        :test #'char=))
                                                           1 0))
                                        :attr-end j)
                                  results)))
                        (setf i (or (search "</script>" html :start2 j :test #'char-equal)
                                    (position #\> html :start j)
                                    n))
                        (when (numberp i) (incf i (if (search "</script>" html :start2 j
                                                               :test #'char-equal)
                                                      9 1)))))
                     ((string= tag "link")
                      (multiple-value-bind (rel %j-rel) (read-attr name-end "rel")
                        (declare (ignore %j-rel))
                        (multiple-value-bind (href %j-href) (read-attr name-end "href")
                          (declare (ignore %j-href))
                          (when (and rel href
                                     (or (string-equal rel "stylesheet")
                                         (search "stylesheet" rel :test #'char-equal)))
                            (let ((abs (resolve-ref href)))
                              (when abs
                                (push (list :kind :style :raw href :abs abs) results))))
                          (setf i (1+ (or (position #\> html :start name-end) n))))))
                     (t (setf i (1+ (or (position #\> html :start name-end) n))))))))
      (nreverse results))))

(defun %url-encode-path (path)
  (with-output-to-string (out)
    (loop for ch across path
          do (let ((code (char-code ch)))
               (if (or (alphanumericp ch)
                       (find ch "-_.~/@" :test #'char=))
                   (write-char ch out)
                   (format out "%~2,'0X" code))))))

(defun %url-decode-path (encoded)
  (with-output-to-string (out)
    (let ((i 0) (n (length encoded)))
      (loop while (< i n)
            do (let ((ch (char encoded i)))
                 (cond
                   ((and (char= ch #\%)
                         (<= (+ i 2) (1- n)))
                    (let ((hi (digit-char-p (char encoded (1+ i)) 16))
                          (lo (digit-char-p (char encoded (+ i 2)) 16)))
                      (if (and hi lo)
                          (progn (write-char (code-char (+ (ash hi 4) lo)) out)
                                 (incf i 3))
                          (progn (write-char ch out) (incf i)))))
                   ((char= ch #\+) (write-char #\Space out) (incf i))
                   (t (write-char ch out) (incf i))))))))

(defun %asset-url (abs-path)
  (concatenate 'string *fds-asset-prefix* "src/" (%url-encode-path abs-path)))

(defun %replace-once (haystack needle replacement)
  "Replace the first occurrence of NEEDLE in HAYSTACK with REPLACEMENT."
  (let ((pos (search needle haystack)))
    (if pos
        (concatenate 'string
                     (subseq haystack 0 pos)
                     replacement
                     (subseq haystack (+ pos (length needle))))
        haystack)))

(defun %rewrite-html (html assets inject-hmr-p)
  "Rewrite script/link refs in HTML to dev asset URLs; optionally inject HMR client."
  (let ((out html)
        (dq (code-char 34))
        (sq (code-char 39)))
    (dolist (asset assets)
      (let ((raw (getf asset :raw))
            (abs (getf asset :abs)))
        (when (and raw abs)
          (let ((url (%asset-url abs)))
            (setf out (%replace-once
                       out
                       (format nil "src=~c~a~c" dq raw dq)
                       (format nil "src=~c~a~c" dq url dq)))
            (setf out (%replace-once
                       out
                       (format nil "href=~c~a~c" dq raw dq)
                       (format nil "href=~c~a~c" dq url dq)))
            (setf out (%replace-once
                       out
                       (format nil "src=~c~a~c" sq raw sq)
                       (format nil "src=~c~a~c" sq url sq)))
            (setf out (%replace-once
                       out
                       (format nil "href=~c~a~c" sq raw sq)
                       (format nil "href=~c~a~c" sq url sq)))))))
    (when inject-hmr-p
      (let* ((snippet (format nil "~%<script type=~cmodule~c src=~c~a~c></script>~%"
                              dq dq dq *fds-client-path* dq))
             (body-close (search "</body>" out :test #'char-equal)))
        (setf out
              (if body-close
                  (concatenate 'string
                               (subseq out 0 body-close)
                               snippet
                               (subseq out body-close))
                  (concatenate 'string out snippet)))))
    out))

;;; --- transforms -------------------------------------------------------------

(defun %path-extension (path)
  (let ((dot (position #\. path :from-end t)))
    (if dot (string-downcase (subseq path dot)) "")))

(defun %transform-source-for-browser (path)
  "Return (values transformed-source content-type) for browser delivery."
  (let* ((ext (%path-extension path))
         (raw (clun.sys:read-file-string path)))
    (cond
      ((member ext '(".css") :test #'string=)
       (values raw "text/css;charset=utf-8"))
      ((member ext '(".json") :test #'string=)
       (values (format nil "export default ~a;~%" raw)
               "text/javascript;charset=utf-8"))
      ((member ext '(".svg" ".png" ".jpg" ".jpeg" ".gif" ".webp" ".ico" ".woff"
                     ".woff2" ".ttf" ".eot" ".map")
               :test #'string=)
       (values raw (%file-content-type path)))
      ((member ext '(".html" ".htm") :test #'string=)
       (values raw "text/html;charset=utf-8"))
      (t
       ;; JS / TS / JSX / TSX — reuse engine read-source-for (JSX + TS strip hooks).
       (let* ((src (handler-case (eng::read-source-for path)
                     (error () raw)))
              (src (%rewrite-browser-imports src (clun.sys:path-dirname path)))
              (src (%inject-import-meta-hot src path)))
         (values src "text/javascript;charset=utf-8"))))))

(defun %rewrite-browser-imports (source base-dir)
  "Rewrite relative import/export-from specifiers to /_clun/dev/src/… asset URLs."
  (let ((out (make-array (length source) :element-type 'character
                                         :adjustable t :fill-pointer 0))
        (i 0)
        (n (length source)))
    (labels ((emit (s)
               (loop for ch across s do (vector-push-extend ch out)))
             (emit-ch (ch) (vector-push-extend ch out))
             (match-at (j lit)
               (and (<= (+ j (length lit)) n)
                    (string= source lit :start1 j :end1 (+ j (length lit)))))
             (skip-string (j quote)
               (incf j)
               (loop while (< j n)
                     do (let ((c (char source j)))
                          (cond
                            ((char= c #\\) (incf j 2))
                            ((char= c quote) (return (1+ j)))
                            (t (incf j))))
                   finally (return j)))
             (is-relative (spec)
               (and (plusp (length spec))
                    (or (char= (char spec 0) #\.)
                        (and (char= (char spec 0) #\/)
                             (> (length spec) 1)
                             (char/= (char spec 1) #\/))
                        (and (>= (length spec) 5)
                             (string-equal "file:" spec :end2 5)))))
             (resolve-spec (spec)
               (cond
                 ((and (>= (length spec) 5) (string-equal "file:" spec :end2 5))
                  (subseq spec (if (and (>= (length spec) 7)
                                        (string= "file://" spec :end2 7))
                                   7 5)))
                 ((char= (char spec 0) #\/)
                  ;; absolute URL path — leave as-is for site assets
                  nil)
                 (t
                  (let* ((joined (clun.sys:normalize-path
                                  (clun.sys:path-join base-dir spec)))
                         (with-ext
                           (cond
                             ((clun.sys:file-p joined) joined)
                             ((clun.sys:file-p (concatenate 'string joined ".js"))
                              (concatenate 'string joined ".js"))
                             ((clun.sys:file-p (concatenate 'string joined ".ts"))
                              (concatenate 'string joined ".ts"))
                             ((clun.sys:file-p (concatenate 'string joined ".tsx"))
                              (concatenate 'string joined ".tsx"))
                             ((clun.sys:file-p (concatenate 'string joined ".jsx"))
                              (concatenate 'string joined ".jsx"))
                             ((clun.sys:file-p (concatenate 'string joined ".mjs"))
                              (concatenate 'string joined ".mjs"))
                             ((clun.sys:file-p (concatenate 'string joined ".css"))
                              (concatenate 'string joined ".css"))
                             ((clun.sys:file-p
                               (clun.sys:path-join joined "index.js"))
                              (clun.sys:path-join joined "index.js"))
                             ((clun.sys:file-p
                               (clun.sys:path-join joined "index.ts"))
                              (clun.sys:path-join joined "index.ts"))
                             (t joined))))
                    with-ext))))
             (try-rewrite-from (j)
               "If at import/export ... from 'x' or import 'x', rewrite and return new j."
               (cond
                 ((or (match-at j "from")
                      (match-at j "import"))
                  (let* ((kw-len (if (match-at j "from") 4 6))
                         (k (skip-ws-local (+ j kw-len))))
                    (when (and (< k n) (member (char source k) '(#\" #\') :test #'char=))
                      (let* ((quote (char source k))
                             (start (1+ k))
                             (end (position quote source :start start)))
                        (when end
                          (let* ((spec (subseq source start end))
                                 (abs (and (is-relative spec) (resolve-spec spec))))
                            (when abs
                              (emit (subseq source j k))
                              (emit-ch quote)
                              (emit (%asset-url abs))
                              (emit-ch quote)
                              (return-from try-rewrite-from (1+ end))))))))
                  nil)
                 (t nil)))
             (skip-ws-local (j)
               (loop while (and (< j n)
                                (member (char source j)
                                        '(#\Space #\Tab #\Newline #\Return)
                                        :test #'char=))
                     do (incf j))
               j))
      (loop while (< i n)
            do (let ((c (char source i)))
                 (cond
                   ;; line comment
                   ((and (char= c #\/) (< (1+ i) n) (char= (char source (1+ i)) #\/))
                    (let ((end (or (position #\Newline source :start i) n)))
                      (emit (subseq source i end))
                      (setf i end)))
                   ;; block comment
                   ((and (char= c #\/) (< (1+ i) n) (char= (char source (1+ i)) #\*))
                    (let ((end (search "*/" source :start2 i)))
                      (if end
                          (progn (emit (subseq source i (+ end 2)))
                                 (setf i (+ end 2)))
                          (progn (emit-ch c) (incf i)))))
                   ((member c '(#\" #\' #\`) :test #'char=)
                    (let ((end (skip-string i c)))
                      (emit (subseq source i end))
                      (setf i end)))
                   ((and (or (match-at i "from") (match-at i "import"))
                         (or (zerop i)
                             (not (alphanumericp (char source (1- i))))))
                    (let ((next (try-rewrite-from i)))
                      (if next
                          (setf i next)
                          (progn (emit-ch c) (incf i)))))
                   (t (emit-ch c) (incf i)))))
      (coerce out 'string))))

(defun %inject-import-meta-hot (source path)
  "Ensure browser modules can use import.meta.hot (shim when platform lacks it).
Exceeds Bun production dead-code path by shipping a runtime client shim in dev."
  (declare (ignore path))
  (if (search "import.meta.hot" source)
      (concatenate
       'string
       "if (typeof import.meta.hot === 'undefined' && globalThis.__clunHot) {"
       "  import.meta.hot = globalThis.__clunHot.forModule(import.meta.url);"
       "}~%"
       source)
      source))

;;; --- HMR client (browser) ---------------------------------------------------

(defun %hmr-client-source ()
  "Browser HMR client: reconnecting WebSocket, CSS hot swap, full-reload fallback,
console→server bridge, and import.meta.hot-compatible accept/dispose registry."
  (format nil "~
(() => {
  const HMR_PATH = ~s;
  const modules = new Map();
  function forModule(url) {
    let m = modules.get(url);
    if (!m) {
      m = {
        data: {},
        _accept: null,
        _dispose: [],
        accept(cb) { this._accept = cb || true; },
        dispose(cb) { if (typeof cb === 'function') this._dispose.push(cb); },
        decline() {},
        invalidate() { location.reload(); },
        on() {},
        off() {},
      };
      modules.set(url, m);
    }
    return m;
  }
  globalThis.__clunHot = { forModule, modules };
  function cssHot(path) {
    const links = document.querySelectorAll('link[rel=\"stylesheet\"]');
    for (const link of links) {
      if (link.href && link.href.includes(encodeURIComponent(path).replace(/%2F/g,'/'))
          || (link.href && path && link.href.indexOf(path.split('/').pop()) !== -1)) {
        const href = link.href.replace(/([?&])t=\\d+/, '$1t=' + Date.now());
        link.href = href.includes('t=') ? href : (href + (href.includes('?') ? '&' : '?') + 't=' + Date.now());
        return true;
      }
    }
    return false;
  }
  function connect() {
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    const ws = new WebSocket(proto + '://' + location.host + HMR_PATH);
    ws.addEventListener('open', () => {
      try { ws.send(JSON.stringify({ type: 'hello', href: location.href })); } catch (_) {}
    });
    ws.addEventListener('message', (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch (_) { return; }
      if (!msg || !msg.type) return;
      if (msg.type === 'full-reload' || msg.type === 'reload') {
        location.reload();
        return;
      }
      if (msg.type === 'update') {
        const path = msg.path || '';
        if (path.endsWith('.css') && cssHot(path)) return;
        // Prefer module self-accept when registered; else full reload (Bun parity).
        let accepted = false;
        for (const [url, m] of modules) {
          if (url.includes(path) || (msg.url && url === msg.url)) {
            if (m._accept) {
              try {
                for (const d of m._dispose.splice(0)) d(m.data);
                if (typeof m._accept === 'function') m._accept();
                accepted = true;
              } catch (e) { console.error('[clun-hmr]', e); location.reload(); return; }
            }
          }
        }
        if (!accepted) location.reload();
        return;
      }
      if (msg.type === 'error' && msg.message) {
        console.error('[clun-hmr]', msg.message);
        showOverlay(msg.message, msg.stack || '');
      }
      if (msg.type === 'console' && msg.level) {
        /* server→browser echo reserved */
      }
    });
    ws.addEventListener('close', () => setTimeout(connect, 500));
    ws.addEventListener('error', () => { try { ws.close(); } catch (_) {} });
    // Console bridge (development.console)
    if (globalThis.__clunHmrConsole) {
      for (const level of ['log','info','warn','error','debug']) {
        const orig = console[level] && console[level].bind(console);
        console[level] = (...args) => {
          try {
            if (ws.readyState === 1) {
              ws.send(JSON.stringify({ type: 'console', level, args: args.map(String) }));
            }
          } catch (_) {}
          if (orig) orig(...args);
        };
      }
    }
  }
  function showOverlay(message, stack) {
    let el = document.getElementById('__clun_hmr_overlay');
    if (!el) {
      el = document.createElement('div');
      el.id = '__clun_hmr_overlay';
      el.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:rgba(15,15,20,.92);color:#fbb;font:14px/1.45 ui-monospace,monospace;padding:24px;white-space:pre-wrap;overflow:auto';
      document.documentElement.appendChild(el);
      el.addEventListener('click', () => el.remove());
    }
    el.textContent = 'Clun HMR error\\n\\n' + message + (stack ? '\\n\\n' + stack : '') + '\\n\\n(click to dismiss)';
  }
  connect();
})();
"
          *fds-hmr-path*))

;;; --- response helpers -------------------------------------------------------

(defun %fds-response (body &key (status 200) (content-type "text/plain;charset=utf-8")
                           extra-headers)
  (let ((init (eng:new-object))
        (headers (eng:new-object)))
    (eng:data-prop headers "content-type" content-type)
    (eng:data-prop headers "cache-control" "no-store")
    (dolist (pair extra-headers)
      (eng:data-prop headers (car pair) (cdr pair)))
    (eng:data-prop init "status" (coerce status 'double-float))
    (eng:data-prop init "headers" headers)
    (%new-response body init)))

(defun %fds-origin-ok-p (request session)
  (let ((origins (and (fds-dev session) (fds-dev-origins (fds-dev session)))))
    (unless origins
      (return-from %fds-origin-ok-p t))
    (let* ((origin (or (%request-header-value request "origin")
                       (%request-header-value request "host")
                       ""))
           (ok (some (lambda (o) (or (string-equal o origin)
                                     (search o origin :test #'char-equal)))
                     origins)))
      ok)))

;;; --- serve HTML entry -------------------------------------------------------

(defun %serve-html-entry (entry session request)
  (declare (ignore request))
  (handler-case
      (let* ((path (js-html-entry-path entry))
             (html (clun.sys:read-file-string path))
             (base (clun.sys:path-dirname path))
             (assets (%scan-html-assets html base))
             (hmr (and session (fds-dev session) (fds-dev-hmr (fds-dev session))))
             (rewritten (%rewrite-html html assets hmr)))
        ;; Watch HTML + assets for HMR.
        (when session
          (%fds-watch path session)
          (dolist (a assets)
            (let ((abs (getf a :abs)))
              (when abs (%fds-watch abs session)))))
        (%fds-response rewritten
                       :content-type "text/html;charset=utf-8"
                       :extra-headers (list (cons "x-clun-dev" "1"))))
    (error (c)
      (when session
        (setf (fds-last-error session) (princ-to-string c)))
      (%fds-response
       (format nil "<!doctype html><html><body><pre>Clun frontend-dev-server error:~%~a</pre></body></html>"
               (princ-to-string c))
       :status 500
       :content-type "text/html;charset=utf-8"))))

(defun %serve-dev-asset (path session request)
  (declare (ignore request))
  (handler-case
      (progn
        (when session (%assert-path-allowed path session))
        (unless (clun.sys:file-p path)
          (return-from %serve-dev-asset
            (%fds-response "Not Found" :status 404)))
        (when session (%fds-watch path session))
        (multiple-value-bind (body ctype) (%transform-source-for-browser path)
          (%fds-response body :content-type ctype
                         :extra-headers (list (cons "x-clun-dev-asset" "1")))))
    (error (c)
      (when session (setf (fds-last-error session) (princ-to-string c)))
      (%fds-response (princ-to-string c) :status 500
                     :content-type "text/plain;charset=utf-8"))))

;;; --- watch / broadcast ------------------------------------------------------

(defun %fds-watch (path session)
  (when (and path session (plusp (length path)))
    (setf (gethash path (fds-watch-sigs session)) (%file-signature path))))

(defun %fds-detect-changes (session)
  (let ((changed '()))
    (maphash
     (lambda (path old)
       (let ((new (%file-signature path)))
         (cond
           ((string= new "")
            ;; deleted
            (unless (string= old "")
              (push path changed)
              (setf (gethash path (fds-watch-sigs session)) "")))
           ((not (string= new old))
            (push path changed)
            (setf (gethash path (fds-watch-sigs session)) new)))))
     (fds-watch-sigs session))
    changed))

(defun %fds-broadcast (session message-json)
  (dolist (send (copy-list (fds-client-senders session)))
    (handler-case (funcall send message-json)
      (error ()
        (setf (fds-client-senders session)
              (remove send (fds-client-senders session) :test #'eq))))))

(defun %fds-notify-paths (session paths)
  (incf (fds-reloads session))
  (setf (fds-last-reload-ms session) (%now-ms))
  (dolist (path paths)
    (let* ((ext (%path-extension path))
           (msg (if (member ext '(".css") :test #'string=)
                    (format nil "{\"type\":\"update\",\"path\":~s}" path)
                    (format nil "{\"type\":\"update\",\"path\":~s}" path))))
      ;; CSS → hot update; everything else → update (client may full-reload)
      (declare (ignore ext))
      (%fds-broadcast session msg)))
  ;; Exceed: also poke hot-reload soft path when available and server modules changed.
  (when (and (find-symbol "*HOT-RELOAD-MODE*" :clun.runtime)
             (symbol-value (find-symbol "*HOT-RELOAD-MODE*" :clun.runtime)))
    (let ((poll (find-symbol "HOT-POLL-NOW" :clun.runtime)))
      (when (and poll (fboundp poll))
        (ignore-errors (funcall poll)))))
  t)

(defun %fds-poll-tick (session)
  (let ((changed (%fds-detect-changes session))
        (now (%now-ms)))
    (when changed
      (setf (fds-coalesced-paths session)
            (union (fds-coalesced-paths session) changed :test #'string=))
      (when (zerop (fds-coalesce-deadline session))
        (setf (fds-coalesce-deadline session) (+ now *fds-coalesce-ms*))))
    (when (and (plusp (fds-coalesce-deadline session))
               (>= now (fds-coalesce-deadline session))
               (fds-coalesced-paths session))
      (let ((paths (fds-coalesced-paths session)))
        (setf (fds-coalesce-deadline session) 0
              (fds-coalesced-paths session) nil)
        (%fds-notify-paths session paths)))))

(defun %fds-arm-timer (session)
  (let* ((realm eng:*realm*)
         (loop (and realm (eng:current-loop))))
    (unless loop
      (return-from %fds-arm-timer nil))
    (when (fds-timer session)
      (ignore-errors (lp:clear-timer (fds-timer session))))
    (setf (fds-timer session)
          (lp:set-timer
           loop *fds-poll-ms*
           (lambda ()
             (let ((eng:*realm* realm))
               (handler-case (%fds-poll-tick session)
                 (error (c)
                   (setf (fds-last-error session) (princ-to-string c))))))
           :repeat *fds-poll-ms*
           :refd t))))

;;; --- request interception ---------------------------------------------------

(defun %fds-request-path (request)
  (let* ((url (eng:to-string (eng:js-get request "url")))
         (path (%request-target-path url)))
    path))

(defun %fds-handle-dev-request (session request server)
  "Return a Response for /_clun/* dev routes, T for HMR upgrade handled, or NIL."
  (unless (and session (fds-dev session) (fds-dev-enabled (fds-dev session)))
    (return-from %fds-handle-dev-request nil))
  (unless (%fds-origin-ok-p request session)
    (return-from %fds-handle-dev-request
      (%fds-response "Forbidden origin" :status 403)))
  (let ((path (%fds-request-path request)))
    (cond
      ;; HMR WebSocket upgrade
      ((string= path *fds-hmr-path*)
       (when (and (fds-dev-hmr (fds-dev session))
                  (js-server-request-p request))
         (let ((upgraded
                 (%try-server-upgrade
                  server request
                  ;; hub: reuse server's if any via context
                  (let ((ctx (js-server-request-context request)))
                    (or (and ctx (serve-request-context-server ctx))
                        server))
                  eng:+undefined+)))
           (declare (ignore upgraded))
           ;; Even without user websocket handlers, perform a minimal upgrade for HMR.
           (unless (and (js-server-request-p request)
                        (serve-request-context-upgraded-p
                         (js-server-request-context request)))
             (%fds-try-hmr-upgrade session request))
           eng:+undefined+)))
      ((string= path *fds-client-path*)
       (let ((src (%hmr-client-source))
             (extra '()))
         (when (and (fds-dev session) (fds-dev-console (fds-dev session)))
           (setf src (concatenate 'string
                                  "globalThis.__clunHmrConsole = true;~%"
                                  src)))
         (%fds-response src :content-type "text/javascript;charset=utf-8")))
      ((and (> (length path) (length *fds-asset-prefix*))
            (string= path *fds-asset-prefix*
                     :end1 (length *fds-asset-prefix*)))
       (let* ((rest (subseq path (length *fds-asset-prefix*)))
              (file (cond
                      ((and (>= (length rest) 4)
                            (string= rest "src/" :end1 4))
                       (%url-decode-path (subseq rest 4)))
                      (t nil))))
         (if file
             (%serve-dev-asset file session request)
             (%fds-response "Bad asset path" :status 400))))
      (t nil))))

(defun %fds-try-hmr-upgrade (session request)
  "Direct HMR WebSocket upgrade without requiring user `websocket` handlers."
  (let* ((context (js-server-request-context request))
         (conn (and context (serve-request-context-connection context)))
         (headers (js-request-headers-alist request)))
    (unless (and context conn
                 (not (serve-request-context-upgraded-p context))
                 (ws:websocket-upgrade-request-p headers))
      (return-from %fds-try-hmr-upgrade nil))
    (let* ((key (string-trim
                 '(#\Space #\Tab)
                 (or (cdr (assoc "sec-websocket-key" headers :test #'string-equal))
                     "")))
           (response (ws:opening-handshake-response key))
           (handlers
             (ws:make-ws-handler-options
              :open nil :message nil :close nil
              :max-payload-length ws:+default-max-payload-bytes+
              :backpressure-limit ws:+default-backpressure-limit+
              :idle-timeout-seconds 120
              :send-pings t))
           (ws-session (%make-ws-session
                        :connection conn
                        :handlers handlers
                        :hub nil
                        :data eng:+undefined+
                        :deflate-negotiated-p nil)))
      (setf (serve-request-context-upgraded-p context) t
            (serve-request-context-committed-p context) t)
      (net:tcp-write conn response)
      (%make-server-websocket ws-session)
      (%ws-attach-frame-loop ws-session)
      ;; Register sender for broadcasts.
      (let ((sender
              (lambda (text)
                (when (< (ws-session-ready-state ws-session) 2)
                  (%ws-write-frame
                   ws-session
                   (ws:make-ws-frame
                    :fin t :opcode ws:+opcode-text+
                    :payload (sb-ext:string-to-octets text :external-format :utf-8)))))))
        (push sender (fds-client-senders session))
        ;; On message: console bridge / hello
        (setf (ws:ws-handler-options-message handlers)
              (eng:make-native-function
               "hmrMessage" 2
               (lambda (this args)
                 (declare (ignore this))
                 (let ((data (eng:arg args 1)))
                   (when (stringp data)
                     (%fds-handle-client-message session data)))
                 eng:+undefined+)))
        (setf (ws:ws-handler-options-close handlers)
              (eng:make-native-function
               "hmrClose" 1
               (lambda (this args)
                 (declare (ignore this args))
                 (setf (fds-client-senders session)
                       (remove sender (fds-client-senders session) :test #'eq))
                 eng:+undefined+))))
      t)))

(defun %fds-handle-client-message (session text)
  (handler-case
      (let* ((obj (ignore-errors
                   ;; minimal JSON: look for "type":"console"
                   text))
             (type-console (search "\"type\":\"console\"" text))
             (type-hello (search "\"type\":\"hello\"" text)))
        (declare (ignore obj))
        (cond
          (type-hello t)
          (type-console
           (when (and (fds-dev session) (fds-dev-console (fds-dev session)))
             (push text (fds-console-logs session))
             (format *error-output* "[browser] ~a~%" text)
             (force-output *error-output*)))
          (t nil)))
    (error () nil)))

;;; --- wire into serve --------------------------------------------------------

(defun %html-entry-route-action (entry session)
  "Callable route action that serves a rewritten HTML entry."
  (eng:make-native-function
   "htmlEntry" 2
   (lambda (this args)
     (declare (ignore this))
     (let ((req (eng:arg args 0)))
       (%serve-html-entry entry session req)))))

(defun %wrap-fetch-for-fds (fetch session server-box)
  "Wrap user fetch so /_clun/* is handled first."
  (eng:make-native-function
   "fetch" 2
   (lambda (this args)
     (declare (ignore this))
     (let* ((req (eng:arg args 0))
            (server (or (car server-box) (eng:arg args 1)))
            (dev-resp (%fds-handle-dev-request session req server)))
       (cond
         ((null dev-resp)
          (if (eng:callable-p fetch)
              (eng:js-call fetch eng:+undefined+ args)
              (%fds-response "Not Found" :status 404)))
         ((eq dev-resp eng:+undefined+) eng:+undefined+)
         (t dev-resp))))))

(defun %rewrite-routes-for-html (routes session)
  "Replace HTML-entry route values with callable HTML handlers. Returns new routes object."
  (unless (eng:js-object-p routes)
    (return-from %rewrite-routes-for-html routes))
  (let ((out (eng:new-object))
        (found nil))
    (dolist (key (eng:jm-own-property-keys routes) out)
      (when (stringp key)
        (let* ((desc (eng:jm-get-own-property routes key))
               (val (and desc (eng:js-getv routes key))))
          (when (and desc (eq (eng:pd-enumerable desc) t))
            (cond
              ((html-entry-p val)
               (setf found t)
               (setf (gethash key (fds-html-routes session)) val)
               (%fds-watch (js-html-entry-path val) session)
               (eng:data-prop out key (%html-entry-route-action val session)))
              (t (eng:data-prop out key val)))))))
    (if found out routes)))

(defun %prepare-serve-opts-for-fds (opts)
  "If development is enabled, rewrite opts for HTML entries + HMR and return
(values new-opts session). Otherwise (values opts nil)."
  (let ((dev (%parse-development-option opts)))
    (unless dev
      ;; Still rewrite HTML entries even without development (production-ish cache).
      (let ((routes (eng:js-get opts "routes"))
            (static (eng:js-get opts "static")))
        (when (or (eng:js-object-p routes) (eng:js-object-p static))
          (let* ((session (%make-fds-session :dev nil :started-ms (%now-ms)))
                 (new-opts (eng:new-object)))
            ;; shallow copy enumerable opts
            (dolist (k (eng:jm-own-property-keys opts))
              (when (stringp k)
                (let ((d (eng:jm-get-own-property opts k)))
                  (when (and d (eq (eng:pd-enumerable d) t))
                    (eng:data-prop new-opts k (eng:js-getv opts k))))))
            (when (eng:js-object-p routes)
              (eng:data-prop new-opts "routes"
                             (%rewrite-routes-for-html routes session)))
            (when (eng:js-object-p static)
              (eng:data-prop new-opts "static"
                             (%rewrite-routes-for-html static session)))
            (return-from %prepare-serve-opts-for-fds (values new-opts session))))
        (return-from %prepare-serve-opts-for-fds (values opts nil))))
    (let* ((session (%make-fds-session :dev dev :started-ms (%now-ms)))
           (new-opts (eng:new-object))
           (server-box (list nil)))
      (dolist (k (eng:jm-own-property-keys opts))
        (when (stringp k)
          (let ((d (eng:jm-get-own-property opts k)))
            (when (and d (eq (eng:pd-enumerable d) t))
              (eng:data-prop new-opts k (eng:js-getv opts k))))))
      (let ((routes (eng:js-get new-opts "routes"))
            (static (eng:js-get new-opts "static"))
            (fetch (eng:js-get new-opts "fetch")))
        (when (eng:js-object-p routes)
          (eng:data-prop new-opts "routes"
                         (%rewrite-routes-for-html routes session)))
        (when (eng:js-object-p static)
          (eng:data-prop new-opts "static"
                         (%rewrite-routes-for-html static session)))
        (eng:data-prop new-opts "fetch"
                       (%wrap-fetch-for-fds
                        (if (eng:callable-p fetch) fetch nil)
                        session server-box))
        ;; Ensure at least one active route/fetch for validation.
        (setf (fds-server session) server-box)
        (values new-opts session)))))

(defun %fds-bind-server (session server)
  (when session
    (when (consp (fds-server session))
      (setf (car (fds-server session)) server))
    (setf (fds-server session) server
          (gethash server *fds-sessions*) session
          *fds-active* session)
    (when (and (fds-dev session) (fds-dev-enabled (fds-dev session))
               (fds-dev-hmr (fds-dev session)))
      (%fds-arm-timer session))
    session))

(defun %fds-unbind-server (server)
  (let ((session (gethash server *fds-sessions*)))
    (when session
      (when (fds-timer session)
        (ignore-errors (lp:clear-timer (fds-timer session)))
        (setf (fds-timer session) nil))
      (remhash server *fds-sessions*)
      (when (eq *fds-active* session)
        (setf *fds-active* nil)))))

;;; --- HTML module load (engine integration hook) -----------------------------

(defun load-html-entry-module (path)
  "Create an evaluated module-record whose default export is an HTML entry brand."
  (let* ((entry (make-html-entry path))
         (mr (eng::make-module-record
              :resolved-path path
              :format :html
              :status :evaluated
              :cjs-exports entry)))
    (setf (eng::realm-module eng:*realm* path) mr)
    mr))

(defun %install-html-entry-loader ()
  "Wire eng:*html-entry-loader* so `import x from './page.html'` works."
  (setf eng:*html-entry-loader*
        (lambda (path) (load-html-entry-module path))))

(defun html-module-path-p (path)
  (member (%path-extension path) '(".html" ".htm") :test #'string=))

;;; --- Clun.devServer public surface (exceed) ---------------------------------

(defun %install-clun-dev-server (clun g)
  "Attach Clun.devServer introspection + HTML entry helper (exceeds Bun)."
  (declare (ignore g))
  (let ((dev (eng:new-object)))
    (eng:install-getter dev "active"
      (lambda (this args)
        (declare (ignore this args))
        (eng:js-boolean (and *fds-active* t))))
    (eng:install-method dev "reloads" 0
      (lambda (this args)
        (declare (ignore this args))
        (coerce (if *fds-active* (fds-reloads *fds-active*) 0) 'double-float)))
    (eng:install-method dev "lastError" 0
      (lambda (this args)
        (declare (ignore this args))
        (if (and *fds-active* (fds-last-error *fds-active*))
            (fds-last-error *fds-active*)
            eng:+null+)))
    (eng:install-method dev "watched" 0
      (lambda (this args)
        (declare (ignore this args))
        (let ((paths '()))
          (when *fds-active*
            (maphash (lambda (p sig) (declare (ignore sig)) (push p paths))
                     (fds-watch-sigs *fds-active*)))
          (eng:new-array (sort paths #'string<)))))
    (eng:install-method dev "clients" 0
      (lambda (this args)
        (declare (ignore this args))
        (coerce (if *fds-active*
                    (length (fds-client-senders *fds-active*))
                    0)
                'double-float)))
    (eng:install-method dev "broadcast" 1
      (lambda (this args)
        (declare (ignore this))
        (when *fds-active*
          (%fds-broadcast *fds-active*
                          (eng:to-string (eng:arg args 0))))
        eng:+undefined+))
    (eng:install-method dev "htmlEntry" 1
      (lambda (this args)
        (declare (ignore this))
        (let ((p (eng:to-string (eng:arg args 0))))
          (make-html-entry
           (if (clun.sys:absolute-path-p p)
               p
               (clun.sys:normalize-path
                (clun.sys:path-join
                 (clun.sys:pathname->native
                  (handler-case (truename ".") (error () ".")))
                 p)))))))
    (eng:install-method dev "hmrPath" 0
      (lambda (this args)
        (declare (ignore this args))
        *fds-hmr-path*))
    (eng:data-prop clun "devServer" dev)
    dev))

;;; --- test helpers -----------------------------------------------------------

(defun fds-scan-html (html base-dir)
  (%scan-html-assets html base-dir))

(defun fds-rewrite-html (html assets &optional inject)
  (%rewrite-html html assets inject))

(defun fds-transform-file (path)
  (%transform-source-for-browser path))

(defun fds-asset-url (path)
  (%asset-url path))

(defun fds-session-reloads (&optional session)
  (let ((s (or session *fds-active*)))
    (if s (fds-reloads s) 0)))

(defun fds-notify (paths &optional session)
  (%fds-notify-paths (or session *fds-active*) paths))
