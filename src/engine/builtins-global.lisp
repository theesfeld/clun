;;;; builtins-global.lisp — the URI functions (Phase 04, §19.2.6) plus a couple of
;;;; global bindings. encode/decode go through WTF-8 (strings.lisp); malformed
;;;; sequences and lone surrogates raise URIError.

(in-package :clun.engine)

(defparameter +uri-unreserved+
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
(defparameter +uri-reserved+ ";/?:@&=+$,#")

(defun throw-uri-error (msg)
  (throw-js-value (make-error-object :uri-error-prototype "URIError" msg)))

(defun %uri-encode (str unescaped)
  (with-output-to-string (out)
    (let ((i 0) (n (length str)))
      (loop while (< i n) do
        (let* ((c (char str i)) (code (char-code c)))
          (cond
            ((find c unescaped) (write-char c out) (incf i))
            (t (let ((cp code))
                 (cond
                   ((high-surrogate-p code)
                    (if (and (< (1+ i) n) (low-surrogate-p (char-code (char str (1+ i)))))
                        (progn (setf cp (+ #x10000 (ash (- code #xD800) 10) (- (char-code (char str (1+ i))) #xDC00))) (incf i 2))
                        (throw-uri-error "URI malformed")))
                   ((low-surrogate-p code) (throw-uri-error "URI malformed"))
                   (t (incf i)))
                 (let ((bytes (make-array 4 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
                   (%push-utf8 cp bytes)
                   (loop for b across bytes do (format out "%~2,'0X" b)))))))))))

(defun %read-pct (str i n)
  "At STR[I]=#\\% read %XX -> (values byte next-index), URIError on malformed."
  (unless (and (< (+ i 3) (1+ n)) (char= (char str i) #\%)) (throw-uri-error "URI malformed"))
  (let ((h (digit-char-p (char str (+ i 1)) 16)) (l (digit-char-p (char str (+ i 2)) 16)))
    (unless (and h l) (throw-uri-error "URI malformed"))
    (values (+ (* h 16) l) (+ i 3))))

(defun %uri-decode (str reserved)
  (with-output-to-string (out)
    (let ((i 0) (n (length str)))
      (loop while (< i n) do
        (let ((c (char str i)))
          (if (char/= c #\%)
              (progn (write-char c out) (incf i))
              (multiple-value-bind (b0 ni) (%read-pct str i n)
                (cond
                  ((< b0 #x80)
                   (let ((ch (code-char b0)))
                     (if (find ch reserved) (write-string (subseq str i ni) out) (write-char ch out)))
                   (setf i ni))
                  (t
                   (let ((len (cond ((>= b0 #xF0) 4) ((>= b0 #xE0) 3) ((>= b0 #xC0) 2)
                                    (t (throw-uri-error "URI malformed"))))
                         (cp (logand b0 (cond ((>= b0 #xF0) #x07) ((>= b0 #xE0) #x0F) (t #x1F)))))
                     (setf i ni)
                     (dotimes (k (1- len))
                       (multiple-value-bind (b nj) (%read-pct str i n)
                         (unless (= (logand b #xC0) #x80) (throw-uri-error "URI malformed"))
                         (setf cp (logior (ash cp 6) (logand b #x3F)) i nj)))
                     (when (or (> cp #x10FFFF)
                               (and (<= #xD800 cp) (<= cp #xDFFF))
                               (and (= len 2) (< cp #x80))
                               (and (= len 3) (< cp #x800))
                               (and (= len 4) (< cp #x10000)))
                       (throw-uri-error "URI malformed"))
                     (let ((tmp (make-array 2 :element-type 'character :adjustable t :fill-pointer 0)))
                       (%push-code-point cp tmp)
                       (write-string tmp out))))))))))))

(defun %bootstrap-global-extra ()
  (let ((g (realm-global *realm*)))
    (macrolet ((uri (name unescaped decode reserved)
                 `(install-method g ,name 1
                    (lambda (this args) (declare (ignore this))
                      ,(if decode
                           `(%uri-decode (to-string (arg args 0)) ,reserved)
                           `(%uri-encode (to-string (arg args 0)) ,unescaped))))))
      (uri "encodeURI" (concatenate 'string +uri-unreserved+ +uri-reserved+) nil nil)
      (uri "encodeURIComponent" +uri-unreserved+ nil nil)
      (uri "decodeURI" nil t +uri-reserved+)
      (uri "decodeURIComponent" nil t ""))))
