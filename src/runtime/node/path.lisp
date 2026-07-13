;;;; path.lisp — node:path (POSIX). win32 is present-but-throwing (documented 🟡).
;;;; Pure string algorithms (posix semantics), independent of the host filesystem.

(in-package :clun.runtime)

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

(defun %split (s ch)
  (loop with start = 0 for i = (position ch s :start start)
        collect (subseq s start (or i (length s)))
        while i do (setf start (1+ i))))

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

(defun build-node-path ()
  (let ((o (eng:new-object)))
    (labels ((m (name arity fn) (eng:install-method o name arity fn))
             (cwd () (clun.sys:pathname->native (truename "."))))
      (eng:data-prop o "sep" "/")
      (eng:data-prop o "delimiter" ":")
      (m "basename" 2 (lambda (this args) (declare (ignore this))
                        (%path-basename (a args 0) (a args 1))))
      (m "dirname" 1 (lambda (this args) (declare (ignore this)) (%path-dirname (a args 0))))
      (m "extname" 1 (lambda (this args) (declare (ignore this)) (%path-extname (a args 0))))
      (m "isAbsolute" 1 (lambda (this args) (declare (ignore this))
                          (eng:js-boolean (%path-abs-p (->str (a args 0))))))
      (m "normalize" 1 (lambda (this args) (declare (ignore this)) (%path-normalize (->str (a args 0)))))
      (m "join" 0 (lambda (this args) (declare (ignore this)) (%path-join args)))
      (m "resolve" 0 (lambda (this args) (declare (ignore this)) (%path-resolve args (cwd))))
      (m "relative" 2 (lambda (this args) (declare (ignore this))
                        (%path-relative (%path-resolve (list (a args 0)) (cwd))
                                        (%path-resolve (list (a args 1)) (cwd)))))
      (m "parse" 1 (lambda (this args) (declare (ignore this)) (%path-parse (->str (a args 0)))))
      (m "format" 1 (lambda (this args) (declare (ignore this)) (%path-format (a args 0))))
      ;; posix === self; win32 present-but-throwing (🟡 — documented in the matrix)
      (eng:data-prop o "posix" o)
      (eng:data-prop o "win32" (%win32-throwing))
      o)))

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

(defun %win32-throwing ()
  (let ((o (eng:new-object)))
    (dolist (name '("basename" "dirname" "extname" "isAbsolute" "normalize" "join"
                    "resolve" "relative" "parse" "format"))
      (eng:install-method o name 0
        (lambda (this args) (declare (ignore this args))
          (eng:throw-native-error :error "path.win32 is not supported"))))
    (eng:data-prop o "sep" "\\")
    (eng:data-prop o "delimiter" ";")
    o))

(register-node-builtin "path" #'build-node-path)
