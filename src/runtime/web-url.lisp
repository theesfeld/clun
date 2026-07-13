;;;; web-url.lisp — WHATWG URL + URLSearchParams (PLAN.md Phase 18, §3.2), built in CL
;;;; against the engine object API. A pragmatic subset of the WHATWG URL Standard:
;;;; special schemes (http/https/ws/wss/ftp/file), // authority, userinfo, IPv4/IPv6
;;;; hosts, default-port elision, relative resolution, dot-segment normalization,
;;;; percent-encoding. Non-ASCII hosts raise a loud "IDNA not supported" (§3.2).
;;;; Documented gaps: IDNA/punycode, some WPT setter edge cases.

(in-package :clun.runtime)

(defstruct (url-record (:conc-name ur-))
  (scheme "") (username "") (password "") host (port nil) (path "") (query nil) (fragment nil)
  (cannot-be-base nil))

(defparameter *special-ports*
  '(("http" . 80) ("https" . 443) ("ws" . 80) ("wss" . 443) ("ftp" . 21) ("file" . nil)))
(defun %special-p (scheme) (and (assoc scheme *special-ports* :test #'string=) t))
(defun %default-port (scheme) (cdr (assoc scheme *special-ports* :test #'string=)))

(defun %url-error (fmt &rest args)
  (eng:throw-type-error (apply #'format nil fmt args)))

;;; --- percent-encoding -------------------------------------------------------

(defun %pct-encode-byte (b out) (format out "%~2,'0X" b))

(defun %pct-encode (string safe-p)
  "Percent-encode STRING (UTF-8) keeping bytes for which (SAFE-P byte) is true."
  (with-output-to-string (out)
    (loop for b across (eng:code-units->utf8 string) do
      (if (funcall safe-p b) (write-char (code-char b) out) (%pct-encode-byte b out)))))

(defun %c0-or-space-p (b) (or (<= b #x20) (>= b #x7f)))
(defun %frag-unsafe (b) (or (%c0-or-space-p b) (member b '(#x22 #x3c #x3e #x60)))) ; " < > `
(defun %query-unsafe (b) (or (%c0-or-space-p b) (member b '(#x22 #x23 #x3c #x3e)))) ; " # < >
(defun %path-unsafe (b) (or (%query-unsafe b) (member b '(#x3f #x60 #x7b #x7d)))) ; ? ` { }
(defun %userinfo-unsafe (b) (or (%path-unsafe b) (member b '(#x2f #x3a #x3b #x3d #x40 #x5b #x5c #x5d #x5e #x7c))))

(defun %pct-frag (s) (%pct-encode s (lambda (b) (not (%frag-unsafe b)))))
(defun %pct-query (s) (%pct-encode s (lambda (b) (not (%query-unsafe b)))))
(defun %pct-path (s) (%pct-encode s (lambda (b) (not (%path-unsafe b)))))
(defun %pct-userinfo (s) (%pct-encode s (lambda (b) (not (%userinfo-unsafe b)))))

(defun %pct-decode (s)
  "Percent-decode S → a string (UTF-8 of the decoded bytes)."
  (let ((bytes (make-array (length s) :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
        (i 0) (n (length s)))
    (loop while (< i n) do
      (let ((c (char s i)))
        (if (and (char= c #\%) (< (+ i 2) n)
                 (digit-char-p (char s (+ i 1)) 16) (digit-char-p (char s (+ i 2)) 16))
            (progn (vector-push-extend (parse-integer s :start (1+ i) :end (+ i 3) :radix 16) bytes)
                   (incf i 3))
            (progn (vector-push-extend (logand (char-code c) #xff) bytes) (incf i)))))
    (handler-case (sb-ext:octets-to-string (copy-seq bytes) :external-format :utf-8)
      (error () (map 'string #'code-char bytes)))))

;;; --- host + path helpers ----------------------------------------------------

(defun %parse-host (str special &optional scheme)
  "Validate/normalize a host STR. IPv6 in [...]; non-ASCII → IDNA error; else lower-cased
reg-name/IPv4 (special) or opaque host (non-special). An empty host is valid for `file`
(file:///path) but not for the other special schemes (http/https/ws/wss/ftp)."
  (cond
    ((and (plusp (length str)) (char= (char str 0) #\[))
     (let ((close (position #\] str)))
       (unless close (%url-error "Invalid URL: unterminated IPv6 host"))
       (string-downcase (subseq str 0 (1+ close)))))   ; keep [..]; IPv6 hex is case-insensitive → lower
    (t
     (when (some (lambda (c) (>= (char-code c) #x80)) str)
       (%url-error "Invalid URL: IDNA (non-ASCII host) is not supported"))
     (when (and special (not (equal scheme "file")) (zerop (length str)))
       (%url-error "Invalid URL: host is empty"))
     (if special (string-downcase (%pct-decode str)) str))))

(defun %url-split (s ch)
  "Split S on every CH (keeping empty segments incl. a trailing one). Named uniquely —
a plain %split lives in node/path.lisp too, and a later-loading same-named defun would
clobber this one in the shared clun.runtime package (the function-name-collision rule)."
  (let ((parts '()) (start 0))
    (dotimes (i (length s)) (when (char= (char s i) ch) (push (subseq s start i) parts) (setf start (1+ i))))
    (push (subseq s start) parts)
    (nreverse parts)))

(defun %single-dot-seg-p (s) (or (string= s ".") (string-equal s "%2e")))
(defun %double-dot-seg-p (s)
  (or (string= s "..") (string-equal s ".%2e") (string-equal s "%2e.") (string-equal s "%2e%2e")))

(defun %remove-dot-segments (path)
  "RFC-3986 dot-segment removal over a /-separated PATH (a trailing ./.. keeps the slash).
Percent-encoded dots (%2e / %2E, ASCII case-insensitive) count as dot-segments too (WHATWG)."
  (let* ((segs (%url-split path #\/))
         (trailing (let ((last (car (last segs)))) (or (%single-dot-seg-p last) (%double-dot-seg-p last))))
         (out '()))
    (dolist (s segs)
      (cond ((%single-dot-seg-p s) nil)
            ((%double-dot-seg-p s) (when (and out (not (string= (car out) ""))) (pop out)))
            (t (push s out))))
    (let ((result (format nil "~{~a~^/~}" (nreverse out))))
      (if (and trailing (plusp (length result)) (not (char= (char result (1- (length result))) #\/)))
          (concatenate 'string result "/")
          result))))

(defun %strip-url-whitespace (s)
  "Remove tab/CR/LF and trim leading/trailing C0-control + space (WHATWG cleanup)."
  (string-trim '(#\Space #\Tab #\Return #\Newline #\Nul)
               (remove-if (lambda (c) (member c '(#\Tab #\Return #\Newline))) s)))

;;; --- the parser -------------------------------------------------------------

(defun %normalize-backslashes (s)
  "Replace every backslash with a slash in the part of S before the first ? or # (WHATWG
maps \\ to / for SPECIAL schemes in the //authority + path states, but NOT in the query or
fragment). So `http://h/a\\b` → path `/a/b` and `https:\\\\h\\p` gains its authority."
  (let ((cut (or (position-if (lambda (c) (member c '(#\? #\#))) s) (length s))))
    (if (find #\\ s :end cut)
        (concatenate 'string (substitute #\/ #\\ (subseq s 0 cut)) (subseq s cut))
        s)))

(defun %scheme-prefix (s)
  "If S starts with `scheme:` return (values scheme rest), else NIL."
  (let ((colon (position #\: s)))
    (when (and colon (plusp colon)
               (alpha-char-p (char s 0))
               (every (lambda (c) (or (alphanumericp c) (member c '(#\+ #\- #\.)))) (subseq s 0 colon)))
      (values (string-downcase (subseq s 0 colon)) (subseq s (1+ colon))))))

(defun %parse-authority-and-rest (rest scheme record)
  "REST begins just after `scheme:`; parse //authority then path/query/fragment into RECORD."
  (let ((special (%special-p scheme)))
    (cond
      ((and (>= (length rest) 2) (string= (subseq rest 0 2) "//"))
       (let* ((after (subseq rest 2))
              (auth-end (or (position-if (lambda (c) (member c '(#\/ #\? #\#))) after) (length after)))
              (authority (subseq after 0 auth-end))
              (tail (subseq after auth-end))
              (at (position #\@ authority :from-end t)))
         (when at
           (let* ((userinfo (subseq authority 0 at)) (colon (position #\: userinfo)))
             (setf (ur-username record) (%pct-userinfo (if colon (subseq userinfo 0 colon) userinfo)))
             (when colon (setf (ur-password record) (%pct-userinfo (subseq userinfo (1+ colon)))))))
         (let* ((hostport (subseq authority (if at (1+ at) 0)))
                (pcolon (and (not (find #\] hostport))    ; not inside IPv6
                             (position #\: hostport)))
                (hp2 (if (find #\] hostport)
                         (let ((cl (position #\] hostport))) (position #\: hostport :start cl))
                         pcolon)))
           (setf (ur-host record) (%parse-host (subseq hostport 0 (or hp2 (length hostport))) special scheme))
           (when hp2
             (let ((ps (subseq hostport (1+ hp2))))
               (when (plusp (length ps))
                 (unless (every #'digit-char-p ps) (%url-error "Invalid URL: bad port"))
                 (let ((p (parse-integer ps)))
                   ;; a port > 2^16-1 is a URL parse FAILURE, not a stored bignum — else
                   ;; fetch would hand 65536 to socket-connect and crash raw (§6).
                   (when (> p 65535) (%url-error "Invalid URL: port out of range"))
                   (setf (ur-port record) (unless (eql p (%default-port scheme)) p)))))))
         (%parse-path-query-fragment tail scheme record)))
      (t (%parse-path-query-fragment rest scheme record)))))

(defun %parse-path-query-fragment (s scheme record)
  (let* ((hash (position #\# s))
         (before-hash (if hash (subseq s 0 hash) s))
         (frag (when hash (subseq s (1+ hash))))
         (qmark (position #\? before-hash))
         (path (if qmark (subseq before-hash 0 qmark) before-hash))
         (query (when qmark (subseq before-hash (1+ qmark)))))
    (when frag (setf (ur-fragment record) (%pct-frag frag)))
    (when query (setf (ur-query record) (%pct-query query)))
    (let ((special (%special-p scheme)))
      (when (and special (plusp (length path)) (not (char= (char path 0) #\/)))
        (setf path (concatenate 'string "/" path)))
      ;; a special-scheme URL with an authority normalizes an empty path to "/"
      ;; (WHATWG: `new URL("http://h").pathname` is "/", not "").
      (when (and special (ur-host record) (zerop (length path)))
        (setf path "/"))
      (setf (ur-path record)
            (if (and (plusp (length path)) (find #\/ path)) (%pct-path (%remove-dot-segments path))
                (%pct-path path))))))

(defun %parse-url (input &optional base)
  "Parse INPUT (optionally relative to BASE, a url-record) → a url-record, or throw."
  (let ((s (%strip-url-whitespace input)))
    (multiple-value-bind (scheme rest) (%scheme-prefix s)
      (cond
        (scheme                                        ; absolute URL
         (let ((r (make-url-record :scheme scheme)))
           (if (%special-p scheme)
               (%parse-authority-and-rest (%normalize-backslashes rest) scheme r)
               ;; non-special: opaque unless //
               (if (and (>= (length rest) 2) (string= (subseq rest 0 2) "//"))
                   (%parse-authority-and-rest rest scheme r)
                   (progn (setf (ur-cannot-be-base r) t)
                          (%parse-path-query-fragment rest scheme r))))
           r))
        (base                                          ; relative resolution
         (%resolve-relative (if (%special-p (ur-scheme base)) (%normalize-backslashes s) s) base))
        (t (%url-error "Invalid URL: ~a (no scheme, no base)" input))))))

(defun %resolve-relative (s base)
  (let ((r (make-url-record :scheme (ur-scheme base) :username (ur-username base)
                            :password (ur-password base) :host (ur-host base) :port (ur-port base))))
    (cond
      ((zerop (length s))                              ; empty → copy base (minus fragment)
       (setf (ur-path r) (ur-path base) (ur-query r) (ur-query base)))
      ((char= (char s 0) #\#)                          ; fragment-only: keep base path + query
       (setf (ur-path r) (ur-path base) (ur-query r) (ur-query base)
             (ur-fragment r) (%pct-frag (subseq s 1))))
      ((char= (char s 0) #\?)                          ; query-only: keep base path, replace query
       (let* ((hash (position #\# s))
              (q (subseq s 1 (or hash (length s))))
              (fr (when hash (subseq s (1+ hash)))))
         (setf (ur-path r) (ur-path base) (ur-query r) (%pct-query q))
         (when fr (setf (ur-fragment r) (%pct-frag fr)))))
      ((and (>= (length s) 2) (string= (subseq s 0 2) "//"))  ; network-path
       (%parse-authority-and-rest s (ur-scheme base) r))
      ((char= (char s 0) #\/) (%parse-path-query-fragment s (ur-scheme base) r))  ; absolute path
      (t                                               ; relative path — merge with base
       (let* ((bp (ur-path base)) (slash (position #\/ bp :from-end t))
              (merged (concatenate 'string (if slash (subseq bp 0 (1+ slash)) "/") s)))
         (%parse-path-query-fragment merged (ur-scheme base) r))))
    r))

;;; --- serialization ----------------------------------------------------------

(defun %serialize-host (r)
  (with-output-to-string (o)
    (when (ur-host r)
      (write-string (ur-host r) o)
      (when (ur-port r) (format o ":~d" (ur-port r))))))

(defun %serialize-url (r)
  (with-output-to-string (o)
    (format o "~a:" (ur-scheme r))
    (when (ur-host r)
      (write-string "//" o)
      ;; emit userinfo when EITHER credential is non-empty (WHATWG "includes credentials"):
      ;; `http://:pw@host` must round-trip, else the password is silently lost.
      (when (or (plusp (length (ur-username r))) (plusp (length (ur-password r))))
        (write-string (ur-username r) o)
        (when (plusp (length (ur-password r))) (format o ":~a" (ur-password r)))
        (write-char #\@ o))
      (write-string (%serialize-host r) o))
    (write-string (ur-path r) o)
    (when (ur-query r) (format o "?~a" (ur-query r)))
    (when (ur-fragment r) (format o "#~a" (ur-fragment r)))))

(defun %url-origin (r)
  (if (member (ur-scheme r) '("http" "https" "ws" "wss" "ftp") :test #'string=)
      (format nil "~a://~a" (ur-scheme r) (%serialize-host r))
      "null"))

;;; --- application/x-www-form-urlencoded --------------------------------------

(defun %form-decode (s) (%pct-decode (substitute #\Space #\+ s)))

(defun %form-encode (s)
  "x-www-form-urlencoded byte encoding: alnum + *-._ verbatim, space→+, else %XX."
  (with-output-to-string (out)
    (loop for b across (eng:code-units->utf8 s) do
      (cond ((= b #x20) (write-char #\+ out))
            ((or (<= #x30 b #x39) (<= #x41 b #x5a) (<= #x61 b #x7a) (member b '(#x2a #x2d #x2e #x5f)))
             (write-char (code-char b) out))
            (t (%pct-encode-byte b out))))))

(defun %usp-parse (query)
  "Parse a query string (no leading ?) → a list of (name . value) pairs."
  (when (and query (plusp (length query)))
    (loop for part in (%url-split query #\&)
          unless (zerop (length part))
            collect (let ((eq (position #\= part)))
                      (if eq (cons (%form-decode (subseq part 0 eq)) (%form-decode (subseq part (1+ eq))))
                          (cons (%form-decode part) ""))))))

(defun %usp-serialize (pairs)
  (format nil "~{~a~^&~}" (mapcar (lambda (p) (format nil "~a=~a" (%form-encode (car p)) (%form-encode (cdr p)))) pairs)))

(defun %coerce-usp-init (init)
  "new URLSearchParams(init): a string / array-of-pairs / plain object / another USP → pairs."
  (cond
    ((eng:js-string-p init)
     (let ((s (eng:to-string init))) (%usp-parse (if (and (plusp (length s)) (char= (char s 0) #\?)) (subseq s 1) s))))
    ((and (eng:js-object-p init) (obj-hidden init "%usp%")) (copy-alist (car (obj-hidden init "%usp%"))))
    ((eng:js-array-p init)
     (loop for i below (eng:array-length init)
           for pair = (eng:js-getv init (princ-to-string i))
           when (eng:js-object-p pair)
             collect (cons (eng:to-string (eng:js-getv pair "0")) (eng:to-string (eng:js-getv pair "1")))))
    ((eng:js-object-p init)
     (loop for k in (eng:jm-own-property-keys init) when (stringp k)
           collect (cons k (eng:to-string (eng:js-getv init k)))))
    (t '())))

(defun %make-urlsearchparams (pairs &optional commit)
  "A URLSearchParams over PAIRS (an alist box). COMMIT (or NIL), called after each mutation
with the serialized string, links it back to an owning URL's query."
  (let ((box (list pairs)) (o (eng:new-object)))
    (eng:hidden-prop o "%usp%" box)
    (labels ((pairs () (car box))
             (changed () (setf (car box) (car box)) (when commit (funcall commit (%usp-serialize (car box))))))
      (flet ((commit-after (fn) (funcall fn) (changed)))
        (eng:install-method o "get" 1
          (lambda (this args) (declare (ignore this))
            (let ((p (assoc (eng:to-string (eng:arg args 0)) (pairs) :test #'string=))) (if p (cdr p) eng:+null+))))
        (eng:install-method o "getAll" 1
          (lambda (this args) (declare (ignore this))
            (let ((n (eng:to-string (eng:arg args 0))))
              (eng:new-array (mapcar #'cdr (remove n (pairs) :key #'car :test-not #'string=))))))
        (eng:install-method o "has" 1
          (lambda (this args) (declare (ignore this))
            (eng:js-boolean (and (assoc (eng:to-string (eng:arg args 0)) (pairs) :test #'string=) t))))
        (eng:install-method o "append" 2
          (lambda (this args) (declare (ignore this))
            (commit-after (lambda () (setf (car box) (append (car box)
                            (list (cons (eng:to-string (eng:arg args 0)) (eng:to-string (eng:arg args 1))))))))
            eng:+undefined+))
        (eng:install-method o "set" 2
          (lambda (this args) (declare (ignore this))
            (let ((n (eng:to-string (eng:arg args 0))) (v (eng:to-string (eng:arg args 1))))
              (commit-after (lambda () (setf (car box)
                              (if (assoc n (car box) :test #'string=)
                                  (let ((done nil))
                                    (loop for p in (car box)
                                          when (string= (car p) n)
                                            append (if done '() (progn (setf done t) (list (cons n v))))
                                          else collect p))
                                  (append (car box) (list (cons n v))))))))
            eng:+undefined+))
        (eng:install-method o "delete" 1
          (lambda (this args) (declare (ignore this))
            (commit-after (lambda () (setf (car box) (remove (eng:to-string (eng:arg args 0)) (car box) :key #'car :test #'string=))))
            eng:+undefined+))
        (eng:install-method o "sort" 0
          (lambda (this args) (declare (ignore this args))
            (commit-after (lambda () (setf (car box) (stable-sort (copy-list (car box)) #'string< :key #'car))))
            eng:+undefined+))
        (eng:install-method o "forEach" 1
          (lambda (this args)
            (let ((cb (eng:arg args 0)))
              (dolist (p (pairs)) (eng:js-call cb eng:+undefined+ (list (cdr p) (car p) this))))
            eng:+undefined+))
        (eng:install-getter o "size" (lambda (this args) (declare (ignore this args)) (coerce (length (pairs)) 'double-float)))
        (flet ((entries-arr () (eng:new-array (mapcar (lambda (p) (eng:new-array (list (car p) (cdr p)))) (pairs)))))
          (eng:install-method o "entries" 0 (lambda (this args) (declare (ignore this args)) (entries-arr)))
          (eng:install-method o "keys" 0 (lambda (this args) (declare (ignore this args)) (eng:new-array (mapcar #'car (pairs)))))
          (eng:install-method o "values" 0 (lambda (this args) (declare (ignore this args)) (eng:new-array (mapcar #'cdr (pairs)))))
          (eng:install-method o "toString" 0 (lambda (this args) (declare (ignore this args)) (%usp-serialize (pairs))))
          (eng:create-data-property o (eng:well-known :iterator)
            (eng:make-native-function "" 0 (lambda (this args) (declare (ignore this args))
              (let ((a (entries-arr))) (eng:js-call (eng:js-getv a (eng:well-known :iterator)) a '()))))))))
    o))

;;; --- URL --------------------------------------------------------------------

(defun %make-url-object (record)
  (let ((o (eng:new-object)) (sp nil))
    (eng:hidden-prop o "%url%" record)
    (labels ((href () (%serialize-url record))
             (getter (name fn) (eng:install-getter o name (lambda (th a) (declare (ignore th a)) (funcall fn))))
             (both (name gfn sfn)
               (eng:install-accessor o name
                 (lambda (th a) (declare (ignore th a)) (funcall gfn))
                 (lambda (th a) (declare (ignore th)) (funcall sfn (eng:to-string (eng:arg a 0))) eng:+undefined+))))
      (getter "protocol" (lambda () (concatenate 'string (ur-scheme record) ":")))
      (getter "username" (lambda () (ur-username record)))
      (getter "password" (lambda () (ur-password record)))
      (getter "host" (lambda () (%serialize-host record)))
      (getter "origin" (lambda () (%url-origin record)))
      (both "href" #'href
            (lambda (v) (let ((r (%parse-url v))) (setf record r) (eng:hidden-prop o "%url%" r) (setf sp nil))))
      (both "hostname" (lambda () (or (ur-host record) ""))
            (lambda (v) (setf (ur-host record) (%parse-host v (%special-p (ur-scheme record))))))
      (both "port" (lambda () (if (ur-port record) (princ-to-string (ur-port record)) ""))
            ;; WHATWG port setter: empty → clear; else parse LEADING digits ("80abc"→80),
            ;; and ignore (no-op) a value with no leading digit or a number > 2^16-1.
            (lambda (v)
              (if (zerop (length v))
                  (setf (ur-port record) nil)
                  (let ((end (or (position-if-not #'digit-char-p v) (length v))))
                    (when (plusp end)
                      (let ((p (parse-integer v :end end)))
                        (when (<= p 65535)
                          (setf (ur-port record) (unless (eql p (%default-port (ur-scheme record))) p)))))))))
      (both "pathname" (lambda () (ur-path record))
            (lambda (v) (setf (ur-path record) (%pct-path (if (%special-p (ur-scheme record)) (%remove-dot-segments (if (and (plusp (length v)) (char= (char v 0) #\/)) v (concatenate 'string "/" v))) v)))))
      (both "search" (lambda () (if (and (ur-query record) (plusp (length (ur-query record)))) (concatenate 'string "?" (ur-query record)) ""))
            (lambda (v) (let ((q (if (and (plusp (length v)) (char= (char v 0) #\?)) (subseq v 1) v)))
                          (setf (ur-query record) (if (plusp (length q)) (%pct-query q) nil))
                          (when sp (%usp-reset sp (%usp-parse (ur-query record)))))))
      (both "hash" (lambda () (if (and (ur-fragment record) (plusp (length (ur-fragment record)))) (concatenate 'string "#" (ur-fragment record)) ""))
            (lambda (v) (setf (ur-fragment record) (if (plusp (length v)) (%pct-frag (if (char= (char v 0) #\#) (subseq v 1) v)) nil))))
      (eng:install-getter o "searchParams"
        (lambda (th a) (declare (ignore th a))
          (or sp (setf sp (%make-urlsearchparams (%usp-parse (ur-query record))
                                                 (lambda (str) (setf (ur-query record) (if (plusp (length str)) str nil))))))))
      (eng:install-method o "toString" 0 (lambda (th a) (declare (ignore th a)) (href)))
      (eng:install-method o "toJSON" 0 (lambda (th a) (declare (ignore th a)) (href))))
    o))

(defun %usp-reset (usp new-pairs)
  (let ((box (obj-hidden usp "%usp%"))) (when box (setf (car box) new-pairs))))

(defun install-web-url (realm)
  (let ((eng:*realm* realm) (g (eng:realm-global realm)))
    (eng:hidden-prop g "URL"
      (eng:make-native-function "URL" 2
        (lambda (this args) (declare (ignore this args)) (eng:throw-type-error "URL requires 'new'"))
        :construct (lambda (args nt) (declare (ignore nt))
                     (let* ((input (eng:to-string (eng:arg args 0)))
                            (base-arg (eng:arg args 1))
                            (base (when (and base-arg (not (eng:js-undefined-p base-arg)))
                                    (%parse-url (eng:to-string base-arg)))))
                       (%make-url-object (%parse-url input base))))))
    ;; URL.canParse(input[, base]) — a static convenience
    (let ((urlc (eng:js-get g "URL")))
      (eng:install-method urlc "canParse" 2
        (lambda (this args) (declare (ignore this))
          (eng:js-boolean (handler-case
                              (progn (%parse-url (eng:to-string (eng:arg args 0))
                                                 (let ((b (eng:arg args 1)))
                                                   (when (and b (not (eng:js-undefined-p b))) (%parse-url (eng:to-string b)))))
                                     t)
                            (error () nil))))))
    (eng:hidden-prop g "URLSearchParams"
      (eng:make-native-function "URLSearchParams" 1
        (lambda (this args) (declare (ignore this args)) (eng:throw-type-error "URLSearchParams requires 'new'"))
        :construct (lambda (args nt) (declare (ignore nt))
                     (%make-urlsearchparams (%coerce-usp-init (eng:arg args 0))))))))
