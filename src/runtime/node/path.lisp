;;;; path.lisp — node:path (POSIX + pure-CL win32 string algorithms).
;;;; Independent of the host filesystem. win32 is Node-compatible pure string math
;;;; so require('path').win32 works on every Clun host (Refs #108).

(in-package :clun.runtime)

;;; ---------------------------------------------------------------------------
;;; Shared helpers
;;; ---------------------------------------------------------------------------

(defun %split (s ch)
  (loop with start = 0 for i = (position ch s :start start)
        collect (subseq s start (or i (length s)))
        while i do (setf start (1+ i))))

(defun %path-sep-join (parts sep)
  (format nil (concatenate 'string "~{~a~^" sep "~}") parts))

;;; ---------------------------------------------------------------------------
;;; POSIX
;;; ---------------------------------------------------------------------------

(defun %path-abs-p (s) (and (plusp (length s)) (char= (char s 0) #\/)))

(defun %path-normalize-string (parts allow-above-root)
  "Normalize a list of path segments (already split on '/'), resolving '.' and '..'.
Returns the collapsed segment list."
  (let ((res '()))
    (dolist (p parts (nreverse res))
      (cond
        ((or (string= p "") (string= p ".")))
        ((string= p "..")
         (cond (res (if (string= (car res) "..") (push p res) (pop res)))
               (allow-above-root (push p res))))
        (t (push p res))))))

(defun %path-normalize (path)
  (when (string= path "") (return-from %path-normalize "."))
  (let* ((abs (%path-abs-p path))
         (trailing (and (> (length path) 1) (char= (char path (1- (length path))) #\/)))
         (segs (%path-normalize-string (%split path #\/) (not abs)))
         (joined (format nil "~{~a~^/~}" segs)))
    (when (string= joined "") (setf joined (if abs "/" ".")))
    (when (and trailing (not (char= (char joined (1- (length joined))) #\/)))
      (setf joined (concatenate 'string joined "/")))
    (if (and abs (not (%path-abs-p joined))) (concatenate 'string "/" joined) joined)))

(defun %path-join (parts)
  (let ((nonempty (remove "" (mapcar #'->str parts) :test #'string=)))
    (if (null nonempty) "."
        (%path-normalize (format nil "~{~a~^/~}" nonempty)))))

(defun %path-resolve (parts base-cwd)
  "Node path.resolve: process args RIGHT-to-LEFT (then cwd, leftmost) until absolute."
  (let ((resolved "") (abs nil))
    (loop for p in (append (reverse (mapcar #'->str parts)) (list base-cwd))
          until abs
          when (plusp (length p))
            do (setf resolved (if (string= resolved "") p (concatenate 'string p "/" resolved))
                     abs (%path-abs-p p)))
    (let ((norm (%path-normalize-string (%split resolved #\/) (not abs))))
      (let ((joined (format nil "~{~a~^/~}" norm)))
        (if abs (concatenate 'string "/" joined)
            (if (string= joined "") "." joined))))))

(defun %path-basename (path &optional ext)
  (let* ((p (string-right-trim "/" (->str path)))
         (slash (position #\/ p :from-end t))
         (base (if slash (subseq p (1+ slash)) p)))
    (if (and ext (not (undef-p ext)))
        (let ((e (->str ext)))
          (if (and (> (length base) (length e))
                   (string= e (subseq base (- (length base) (length e)))))
              (subseq base 0 (- (length base) (length e)))
              base))
        base)))

(defun %path-dirname (path)
  (let* ((p (string-right-trim "/" (->str path))))
    (when (string= p "") (return-from %path-dirname (if (%path-abs-p (->str path)) "/" ".")))
    (let ((slash (position #\/ p :from-end t)))
      (cond ((null slash) ".")
            ((zerop slash) "/")
            (t (subseq p 0 slash))))))

(defun %path-extname (path)
  ;; A '.' starts an extension only if a NON-dot char precedes it in the basename, so
  ;; leading-dot names have no ext: extname('..')='', extname('.bashrc')='', extname('a.')='.'.
  (let* ((base (%path-basename path))
         (dot (position #\. base :from-end t)))
    (if (or (null dot) (zerop dot) (every (lambda (c) (char= c #\.)) (subseq base 0 dot)))
        "" (subseq base dot))))

(defun %path-relative (from to)
  (if (string= from to) ""
      (let* ((fs (remove "" (%split from #\/) :test #'string=))
             (ts (remove "" (%split to #\/) :test #'string=))
             (common (loop for f in fs for t* in ts while (string= f t*) count t)))
        (format nil "~{~a~^/~}"
                (append (make-list (- (length fs) common) :initial-element "..")
                        (nthcdr common ts))))))

(defun %path-parse (path)
  (let* ((o (eng:new-object)) (dir (%path-dirname path)) (base (%path-basename path))
         (ext (%path-extname path))
         (name (if (plusp (length ext)) (subseq base 0 (- (length base) (length ext))) base)))
    (eng:data-prop o "root" (if (%path-abs-p path) "/" ""))
    (eng:data-prop o "dir" (if (string= dir ".") (if (%path-abs-p path) "/" "") dir))
    (eng:data-prop o "base" base)
    (eng:data-prop o "ext" ext)
    (eng:data-prop o "name" name)
    o))

(defun %path-format (obj)
  ;; Node: dir = dir||root; base = base||name+ext; if !dir -> base; else
  ;; dir===root ? dir+base : dir+sep+base.
  (let* ((g (lambda (k) (let ((v (eng:js-get obj k))) (if (undef-p v) "" (->str v)))))
         (root (funcall g "root")) (dir-in (funcall g "dir"))
         (base (let ((b (funcall g "base")))
                 (if (plusp (length b)) b (concatenate 'string (funcall g "name") (funcall g "ext")))))
         (dir (if (plusp (length dir-in)) dir-in root)))
    (cond ((string= dir "") base)
          ((string= dir root) (concatenate 'string dir base))
          (t (concatenate 'string dir "/" base)))))

;;; ---------------------------------------------------------------------------
;;; Win32 — pure string algorithms (Node lib/path.js win32 semantics)
;;; ---------------------------------------------------------------------------

(defun %win-sep-p (c) (or (char= c #\\) (char= c #\/)))

(defun %win-device-root-p (c)
  (and (characterp c)
       (or (char<= #\A c #\Z) (char<= #\a c #\z))))

(defun %win-cwd ()
  "Host cwd rewritten with backslashes for win32.resolve (Node-on-POSIX behavior)."
  (substitute #\\ #\/ (clun.sys:pathname->native (truename "."))))

(defun %win-split-segments (path)
  "Split PATH on / or \\ into non-separator segments (empty segments dropped)."
  (let ((parts '()) (start 0) (n (length path)))
    (loop for i from 0 below n do
      (when (%win-sep-p (char path i))
        (when (< start i) (push (subseq path start i) parts))
        (setf start (1+ i))))
    (when (< start n) (push (subseq path start) parts))
    (nreverse parts)))

(defun %win-normalize-string (path allow-above-root)
  "Resolve . and .. in PATH with both / and \\ treated as separators; emit \\."
  (let ((res '()))
    (dolist (p (%win-split-segments path)
               (format nil "~{~a~^\\~}" (nreverse res)))
      (cond
        ((or (string= p "") (string= p ".")))
        ((string= p "..")
         (cond (res
                (if (string= (car res) "..")
                    (push p res)
                    (pop res)))
               (allow-above-root (push p res))))
        (t (push p res))))))

(defun %win-unc-root-end (path)
  "When PATH starts with // or \\\\ server\\share, return (values device root-end).
DEVICE is e.g. \\\\server\\share; ROOT-END is the index after the share (and trailing seps)."
  (let ((len (length path)))
    (unless (and (>= len 2) (%win-sep-p (char path 0)) (%win-sep-p (char path 1)))
      (return-from %win-unc-root-end (values nil 0)))
    (let ((j 2) (last 2))
      ;; server
      (loop while (and (< j len) (not (%win-sep-p (char path j)))) do (incf j))
      (when (or (>= j len) (= j last))
        (return-from %win-unc-root-end (values nil 1)))
      (let ((first-part (subseq path last j)))
        (setf last j)
        (loop while (and (< j len) (%win-sep-p (char path j))) do (incf j))
        (when (or (>= j len) (= j last))
          (return-from %win-unc-root-end (values nil 1)))
        (setf last j)
        (loop while (and (< j len) (not (%win-sep-p (char path j)))) do (incf j))
        (cond
          ((or (string= first-part ".") (string= first-part "?"))
           (values (concatenate 'string "\\\\" first-part) 4))
          ((= j len)
           (values (format nil "\\\\~a\\~a" first-part (subseq path last)) j))
          ((/= j last)
           (values (format nil "\\\\~a\\~a" first-part (subseq path last j)) j))
          (t (values nil 1)))))))

(defun %win-root-info (path)
  "Return (values device root-end is-absolute). DEVICE may be NIL, \"C:\", or UNC."
  (let ((len (length path)))
    (when (zerop len)
      (return-from %win-root-info (values nil 0 nil)))
    (let ((code (char path 0)))
      (cond
        ((= len 1)
         (if (%win-sep-p code)
             (values nil 1 t)
             (values nil 0 nil)))
        ((%win-sep-p code)
         (if (%win-sep-p (char path 1))
             (multiple-value-bind (device root-end) (%win-unc-root-end path)
               (if device
                   (values device root-end t)
                   (values nil 1 t)))
             (values nil 1 t)))
        ((and (%win-device-root-p code) (char= (char path 1) #\:))
         (let ((device (subseq path 0 2))
               (root-end 2)
               (abs nil))
           (when (and (> len 2) (%win-sep-p (char path 2)))
             (setf abs t root-end 3))
           (values device root-end abs)))
        (t (values nil 0 nil))))))

(defun %win-is-absolute (path)
  (let ((len (length path)))
    (when (zerop len) (return-from %win-is-absolute nil))
    (or (%win-sep-p (char path 0))
        (and (> len 2)
             (%win-device-root-p (char path 0))
             (char= (char path 1) #\:)
             (%win-sep-p (char path 2))))))

(defun %win-normalize (path)
  (when (string= path "") (return-from %win-normalize "."))
  (let ((len (length path)))
    (when (= len 1)
      (return-from %win-normalize
        (if (char= (char path 0) #\/) "\\" path)))
    (multiple-value-bind (device root-end is-abs) (%win-root-info path)
      (let* ((tail (if (< root-end len)
                       (%win-normalize-string (subseq path root-end) (not is-abs))
                       ""))
             (trailing (and (plusp len) (%win-sep-p (char path (1- len))))))
        (when (and (string= tail "") (not is-abs))
          (setf tail "."))
        (when (and (plusp (length tail)) trailing)
          (setf tail (concatenate 'string tail "\\")))
        (cond
          ((null device)
           (if is-abs (concatenate 'string "\\" tail) tail))
          (is-abs
           (concatenate 'string device "\\" tail))
          (t
           (concatenate 'string device tail)))))))

(defun %win-join (parts)
  (let ((nonempty (remove "" (mapcar #'->str parts) :test #'string=)))
    (when (null nonempty) (return-from %win-join "."))
    (let* ((first (car nonempty))
           (joined (format nil "~{~a~^\\~}" nonempty))
           (needs-replace t)
           (slash-count 0))
      (when (%win-sep-p (char first 0))
        (incf slash-count)
        (when (and (> (length first) 1) (%win-sep-p (char first 1)))
          (incf slash-count)
          (when (and (> (length first) 2)
                     (not (%win-sep-p (char first 2))))
            (setf needs-replace nil))))
      (when needs-replace
        (loop while (and (< slash-count (length joined))
                         (%win-sep-p (char joined slash-count)))
              do (incf slash-count))
        (when (>= slash-count 2)
          (setf joined (concatenate 'string "\\" (subseq joined slash-count)))))
      (%win-normalize joined))))

(defun %win-resolve (parts)
  "Node path.win32.resolve — right-to-left until absolute on a device."
  (let ((resolved-device "")
        (resolved-tail "")
        (resolved-absolute nil)
        (args (mapcar #'->str parts))
        (cwd (%win-cwd)))
    (loop for i from (1- (length args)) downto -1
          until (and resolved-absolute (plusp (length resolved-device)))
          do
      (let ((path (if (>= i 0)
                      (nth i args)
                      (if (zerop (length resolved-device))
                          cwd
                          ;; Drive-relative cwd fallback: use process cwd when
                          ;; drive-specific env (=C:) is unavailable.
                          (let ((c cwd))
                            (if (and (>= (length c) 2)
                                     (string-equal (subseq c 0 2) resolved-device)
                                     (or (= (length c) 2)
                                         (%win-sep-p (char c 2))))
                                c
                                (concatenate 'string resolved-device "\\")))))))
        (when (plusp (length path))
          (multiple-value-bind (device root-end is-abs) (%win-root-info path)
            (let ((device-ok t))
              (when device
                (if (plusp (length resolved-device))
                    (unless (string-equal device resolved-device)
                      (setf device-ok nil))
                    (setf resolved-device device)))
              (when device-ok
                (unless resolved-absolute
                  (setf resolved-tail (concatenate 'string (subseq path root-end)
                                                  "\\" resolved-tail)
                        resolved-absolute is-abs))))))))
    (setf resolved-tail (%win-normalize-string resolved-tail (not resolved-absolute)))
    (cond
      (resolved-absolute
       (concatenate 'string resolved-device "\\" resolved-tail))
      ((or (plusp (length resolved-device)) (plusp (length resolved-tail)))
       (concatenate 'string resolved-device resolved-tail))
      (t "."))))

(defun %win-dirname (path)
  (let ((len (length path)))
    (when (zerop len) (return-from %win-dirname "."))
    (when (= len 1)
      (return-from %win-dirname (if (%win-sep-p (char path 0)) path ".")))
    (multiple-value-bind (device root-end is-abs) (%win-root-info path)
      (declare (ignore device is-abs))
      (let ((offset root-end)
            (root-end-mark (if (plusp root-end) root-end -1))
            (end -1)
            (matched-slash t))
        ;; UNC with only the root returns the whole path.
        (when (and (>= len 2) (%win-sep-p (char path 0)) (%win-sep-p (char path 1)))
          (multiple-value-bind (unc-dev unc-end) (%win-unc-root-end path)
            (when (and unc-dev (= unc-end len))
              (return-from %win-dirname path))
            (when unc-dev
              (setf root-end-mark (1+ unc-end) offset (1+ unc-end)))))
        (loop for i from (1- len) downto offset do
          (if (%win-sep-p (char path i))
              (when (not matched-slash)
                (setf end i)
                (return))
              (setf matched-slash nil)))
        (when (= end -1)
          (if (= root-end-mark -1)
              (return-from %win-dirname ".")
              (setf end root-end-mark)))
        (subseq path 0 end)))))

(defun %win-basename (path &optional ext)
  (let* ((s (->str path))
         (start 0)
         (end -1)
         (matched-slash t)
         (len (length s)))
    (when (and (>= len 2)
               (%win-device-root-p (char s 0))
               (char= (char s 1) #\:))
      (setf start 2))
    (if (and ext (not (undef-p ext)) (plusp (length (->str ext))))
        (let ((suffix (->str ext))
              (ext-idx (1- (length (->str ext))))
              (first-non-slash-end -1))
          (when (string= suffix s) (return-from %win-basename ""))
          (loop for i from (1- len) downto start do
            (let ((c (char s i)))
              (if (%win-sep-p c)
                  (when (not matched-slash)
                    (setf start (1+ i))
                    (return))
                  (progn
                    (when (= first-non-slash-end -1)
                      (setf matched-slash nil first-non-slash-end (1+ i)))
                    (when (>= ext-idx 0)
                      (if (char= c (char suffix ext-idx))
                          (when (minusp (decf ext-idx))
                            (setf end i))
                          (setf ext-idx -1 end first-non-slash-end)))))))
          (when (= start end) (setf end first-non-slash-end))
          (when (= end -1) (setf end len))
          (subseq s start end))
        (progn
          (loop for i from (1- len) downto start do
            (if (%win-sep-p (char s i))
                (when (not matched-slash)
                  (setf start (1+ i))
                  (return))
                (when (= end -1)
                  (setf matched-slash nil end (1+ i)))))
          (if (= end -1) "" (subseq s start end))))))

(defun %win-extname (path)
  (let* ((s (->str path))
         (start 0)
         (start-dot -1)
         (start-part 0)
         (end -1)
         (matched-slash t)
         (pre-dot-state 0)
         (len (length s)))
    (when (and (>= len 2)
               (char= (char s 1) #\:)
               (%win-device-root-p (char s 0)))
      (setf start 2 start-part 2))
    (loop for i from (1- len) downto start do
      (let ((c (char s i)))
        (cond
          ((%win-sep-p c)
           (when (not matched-slash)
             (setf start-part (1+ i))
             (return))
           ;; else continue
           )
          (t
           (when (= end -1)
             (setf matched-slash nil end (1+ i)))
           (cond
             ((char= c #\.)
              (if (= start-dot -1)
                  (setf start-dot i)
                  (when (/= pre-dot-state 1)
                    (setf pre-dot-state 1))))
             ((/= start-dot -1)
              (setf pre-dot-state -1)))))))
    (if (or (= start-dot -1) (= end -1) (= pre-dot-state 0)
            (and (= pre-dot-state 1)
                 (= start-dot (1- end))
                 (= start-dot (1+ start-part))))
        ""
        (subseq s start-dot end))))

(defun %win-relative (from to)
  (let ((from-r (%win-resolve (list from)))
        (to-r (%win-resolve (list to))))
    (when (string= from-r to-r) (return-from %win-relative ""))
    (let ((from-l (string-downcase from-r))
          (to-l (string-downcase to-r)))
      (when (string= from-l to-l) (return-from %win-relative ""))
      ;; Different devices → absolute target (Node).
      (when (and (>= (length from-l) 2) (>= (length to-l) 2)
                 (char= (char from-l 1) #\:) (char= (char to-l 1) #\:)
                 (char/= (char from-l 0) (char to-l 0)))
        (return-from %win-relative to-r))
      (let* ((from-parts (remove "" (%split from-l #\\) :test #'string=))
             (to-parts (remove "" (%split to-l #\\) :test #'string=))
             (from-orig-parts (remove "" (%split from-r #\\) :test #'string=))
             (to-orig-parts (remove "" (%split to-r #\\) :test #'string=))
             (common (loop for f in from-parts for t* in to-parts
                           while (string= f t*) count t)))
        (when (zerop common)
          (return-from %win-relative to-r))
        (format nil "~{~a~^\\~}"
                (append (make-list (- (length from-parts) common) :initial-element "..")
                        (nthcdr common to-orig-parts)))))))

(defun %win-parse (path)
  (let* ((o (eng:new-object))
         (len (length path)))
    (eng:data-prop o "root" "")
    (eng:data-prop o "dir" "")
    (eng:data-prop o "base" "")
    (eng:data-prop o "ext" "")
    (eng:data-prop o "name" "")
    (when (zerop len) (return-from %win-parse o))
    (when (= len 1)
      (if (%win-sep-p (char path 0))
          (progn (eng:data-prop o "root" path) (eng:data-prop o "dir" path))
          (progn (eng:data-prop o "base" path) (eng:data-prop o "name" path)))
      (return-from %win-parse o))
    (multiple-value-bind (device root-end is-abs) (%win-root-info path)
      (declare (ignore device is-abs))
      (let ((root (if (plusp root-end) (subseq path 0 root-end) "")))
        ;; UNC root-only: entire path is root+dir.
        (when (and (>= len 2) (%win-sep-p (char path 0)) (%win-sep-p (char path 1)))
          (multiple-value-bind (unc-dev unc-end) (%win-unc-root-end path)
            (when (and unc-dev (= unc-end len))
              (eng:data-prop o "root" path)
              (eng:data-prop o "dir" path)
              (return-from %win-parse o))
            (when (and unc-dev (< unc-end len))
              ;; include trailing separator in root for UNC with leftovers
              (setf root (subseq path 0 (1+ unc-end))
                    root-end (1+ unc-end)))))
        (when (and (%win-device-root-p (char path 0))
                   (char= (char path 1) #\:)
                   (<= len 2))
          (eng:data-prop o "root" path)
          (eng:data-prop o "dir" path)
          (return-from %win-parse o))
        (when (and (%win-device-root-p (char path 0))
                   (char= (char path 1) #\:)
                   (= len 3)
                   (%win-sep-p (char path 2)))
          (eng:data-prop o "root" path)
          (eng:data-prop o "dir" path)
          (return-from %win-parse o))
        (when (plusp root-end) (eng:data-prop o "root" root))
        (let ((base (%win-basename path))
              (ext (%win-extname path))
              (dir-str (%win-dirname path)))
          (eng:data-prop o "base" base)
          (eng:data-prop o "ext" ext)
          (eng:data-prop o "name"
                         (if (plusp (length ext))
                             (subseq base 0 (- (length base) (length ext)))
                             base))
          ;; Node: if dir is root use root (incl trailing sep); else strip trailing sep.
          (eng:data-prop o "dir"
                         (if (or (string= dir-str ".")
                                 (and (plusp (length root))
                                      (string= dir-str (string-right-trim "\\/" root))))
                             root
                             dir-str))
          o)))))

(defun %win-format (obj)
  (let* ((g (lambda (k) (let ((v (eng:js-get obj k))) (if (undef-p v) "" (->str v)))))
         (root (funcall g "root")) (dir-in (funcall g "dir"))
         (base (let ((b (funcall g "base")))
                 (if (plusp (length b)) b
                     (let ((ext (funcall g "ext")))
                       (concatenate 'string (funcall g "name")
                                    (if (and (plusp (length ext))
                                             (char/= (char ext 0) #\.))
                                        (concatenate 'string "." ext)
                                        ext))))))
         (dir (if (plusp (length dir-in)) dir-in root)))
    (cond ((string= dir "") base)
          ((string= dir root) (concatenate 'string dir base))
          (t (concatenate 'string dir "\\" base)))))

(defun %win-to-namespaced-path (path)
  (when (or (not (stringp path)) (zerop (length path)))
    (return-from %win-to-namespaced-path path))
  (let ((resolved (%win-resolve (list path))))
    (when (<= (length resolved) 2)
      (return-from %win-to-namespaced-path path))
    (cond
      ((and (%win-sep-p (char resolved 0))
            (%win-sep-p (char resolved 1))
            (not (find (char resolved 2) '(#\? #\.))))
       (concatenate 'string "\\\\?\\UNC\\" (subseq resolved 2)))
      ((and (%win-device-root-p (char resolved 0))
            (char= (char resolved 1) #\:)
            (%win-sep-p (char resolved 2)))
       (concatenate 'string "\\\\?\\" resolved))
      (t resolved))))

;;; ---------------------------------------------------------------------------
;;; Module object construction
;;; ---------------------------------------------------------------------------

(defun %install-path-methods (o methods)
  "METHODS is an alist of (name arity function)."
  (dolist (m methods)
    (destructuring-bind (name arity fn) m
      (eng:install-method o name arity fn)))
  o)

(defun %build-posix-path ()
  (let ((o (eng:new-object)))
    (labels ((cwd () (clun.sys:pathname->native (truename "."))))
      (eng:data-prop o "sep" "/")
      (eng:data-prop o "delimiter" ":")
      (%install-path-methods
       o
       `(("basename" 2 ,(lambda (this args) (declare (ignore this))
                          (%path-basename (a args 0) (a args 1))))
         ("dirname" 1 ,(lambda (this args) (declare (ignore this))
                         (%path-dirname (a args 0))))
         ("extname" 1 ,(lambda (this args) (declare (ignore this))
                         (%path-extname (a args 0))))
         ("isAbsolute" 1 ,(lambda (this args) (declare (ignore this))
                            (eng:js-boolean (%path-abs-p (->str (a args 0))))))
         ("normalize" 1 ,(lambda (this args) (declare (ignore this))
                           (%path-normalize (->str (a args 0)))))
         ("join" 0 ,(lambda (this args) (declare (ignore this)) (%path-join args)))
         ("resolve" 0 ,(lambda (this args) (declare (ignore this))
                         (%path-resolve args (cwd))))
         ("relative" 2 ,(lambda (this args) (declare (ignore this))
                          (%path-relative (%path-resolve (list (a args 0)) (cwd))
                                          (%path-resolve (list (a args 1)) (cwd)))))
         ("parse" 1 ,(lambda (this args) (declare (ignore this))
                       (%path-parse (->str (a args 0)))))
         ("format" 1 ,(lambda (this args) (declare (ignore this))
                        (%path-format (a args 0))))
         ("toNamespacedPath" 1 ,(lambda (this args) (declare (ignore this))
                                  ;; POSIX no-op
                                  (->str (a args 0))))))
      o)))

(defun %build-win32-path ()
  (let ((o (eng:new-object)))
    (eng:data-prop o "sep" "\\")
    (eng:data-prop o "delimiter" ";")
    (%install-path-methods
     o
     `(("basename" 2 ,(lambda (this args) (declare (ignore this))
                        (%win-basename (a args 0) (a args 1))))
       ("dirname" 1 ,(lambda (this args) (declare (ignore this))
                       (%win-dirname (->str (a args 0)))))
       ("extname" 1 ,(lambda (this args) (declare (ignore this))
                       (%win-extname (a args 0))))
       ("isAbsolute" 1 ,(lambda (this args) (declare (ignore this))
                          (eng:js-boolean (%win-is-absolute (->str (a args 0))))))
       ("normalize" 1 ,(lambda (this args) (declare (ignore this))
                         (%win-normalize (->str (a args 0)))))
       ("join" 0 ,(lambda (this args) (declare (ignore this)) (%win-join args)))
       ("resolve" 0 ,(lambda (this args) (declare (ignore this))
                       (%win-resolve args)))
       ("relative" 2 ,(lambda (this args) (declare (ignore this))
                        (%win-relative (->str (a args 0)) (->str (a args 1)))))
       ("parse" 1 ,(lambda (this args) (declare (ignore this))
                     (%win-parse (->str (a args 0)))))
       ("format" 1 ,(lambda (this args) (declare (ignore this))
                      (%win-format (a args 0))))
       ("toNamespacedPath" 1 ,(lambda (this args) (declare (ignore this))
                                (%win-to-namespaced-path (->str (a args 0)))))))
    ;; Legacy alias
    (eng:data-prop o "_makeLong" (eng:js-get o "toNamespacedPath"))
    o))

(defun build-node-path ()
  (let ((posix (%build-posix-path))
        (win32 (%build-win32-path)))
    ;; Cross-links match Node: path.posix.win32 === path.win32, etc.
    (eng:data-prop posix "posix" posix)
    (eng:data-prop posix "win32" win32)
    (eng:data-prop win32 "posix" posix)
    (eng:data-prop win32 "win32" win32)
    ;; On non-Windows hosts the default export is posix.
    posix))

(register-node-builtin "path" #'build-node-path)
