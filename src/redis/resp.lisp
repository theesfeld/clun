;;;; resp.lisp — Redis Serialization Protocol (RESP2 + selected RESP3) pure-CL.
;;;; FULL PORT #184 / epic #177. Pure Common Lisp; SBCL octet I/O only.

(in-package :clun.redis)

(define-condition redis-error (error)
  ((message :initarg :message :reader redis-error-message)
   (code :initarg :code :initform "ERR_REDIS" :reader redis-error-code))
  (:report (lambda (c s)
             (format s "Redis error: ~A" (redis-error-message c)))))

(define-condition redis-reply-error (redis-error)
  ()
  (:report (lambda (c s)
             (format s "Redis reply error: ~A" (redis-error-message c)))))

(defun %fail (message &optional (code "ERR_REDIS"))
  (error 'redis-error :message message :code code))

(defun %utf8-octets (string)
  (sb-ext:string-to-octets (if (stringp string) string (princ-to-string string))
                           :external-format :utf-8))

(defun %utf8-string (octets &key (start 0) end)
  (sb-ext:octets-to-string octets :external-format :utf-8
                                  :start start :end end))

(defun %concat-parts (parts)
  (let* ((total 0)
         (out nil)
         (i 0))
    (dolist (p parts) (incf total (length p)))
    (setf out (make-array total :element-type '(unsigned-byte 8)))
    (dolist (p parts out)
      (replace out p :start1 i)
      (incf i (length p)))))

(defun %ascii-line (fmt &rest args)
  (%utf8-octets (apply #'format nil fmt args)))

;;; --- encode -----------------------------------------------------------------

(defun resp-encode-value (value)
  "Encode a single RESP value (string / integer / null / list / octets)."
  (cond
    ((null value)
     (%ascii-line "$-1~C~C" #\Return #\Newline))
    ((eq value :null-array)
     (%ascii-line "*-1~C~C" #\Return #\Newline))
    ((eq value t)
     (%ascii-line "#t~C~C" #\Return #\Newline))
    ((eq value :false)
     (%ascii-line "#f~C~C" #\Return #\Newline))
    ((integerp value)
     (%ascii-line ":~D~C~C" value #\Return #\Newline))
    ((stringp value)
     (let ((oct (%utf8-octets value)))
       (%concat-parts
        (list (%ascii-line "$~D~C~C" (length oct) #\Return #\Newline)
              oct
              (%ascii-line "~C~C" #\Return #\Newline)))))
    ((typep value '(vector (unsigned-byte 8)))
     (%concat-parts
      (list (%ascii-line "$~D~C~C" (length value) #\Return #\Newline)
            value
            (%ascii-line "~C~C" #\Return #\Newline))))
    ((listp value)
     (%concat-parts
      (cons (%ascii-line "*~D~C~C" (length value) #\Return #\Newline)
            (mapcar #'resp-encode-value value))))
    (t
     (resp-encode-value (princ-to-string value)))))

(defun resp-encode (args)
  "Encode a Redis command ARG list (strings/numbers) as a RESP bulk array."
  (resp-encode-value
   (mapcar (lambda (a)
             (cond
               ((stringp a) a)
               ((typep a '(vector (unsigned-byte 8))) a)
               (t (princ-to-string a))))
           args)))

(defun resp-encode-error (message)
  (%ascii-line "-~A~C~C" message #\Return #\Newline))

(defun resp-encode-simple (string)
  (%ascii-line "+~A~C~C" string #\Return #\Newline))

;;; --- decode from stream -----------------------------------------------------

(defun %read-line-crlf (stream)
  (let ((out (make-array 64 :element-type '(unsigned-byte 8)
                         :adjustable t :fill-pointer 0)))
    (loop
      (let ((b (read-byte stream nil :eof)))
        (when (eq b :eof)
          (%fail "unexpected EOF reading RESP line"))
        (when (= b 13)
          (let ((n (read-byte stream nil :eof)))
            (when (eq n :eof)
              (%fail "unexpected EOF after CR"))
            (unless (= n 10)
              (%fail "expected LF after CR in RESP"))
            (return (%utf8-string out))))
        (vector-push-extend b out)))))

(defun resp-decode-from-stream (stream &key (errors-as-condition t))
  "Read one RESP value from a binary STREAM.
   When ERRORS-AS-CONDITION is T (default), error replies signal REDIS-REPLY-ERROR.
   Returns the decoded Lisp value."
  (let ((tag (read-byte stream nil :eof)))
    (when (eq tag :eof)
      (%fail "unexpected EOF reading RESP type"))
    (case tag
      (#.(char-code #\+)
       (%read-line-crlf stream))
      (#.(char-code #\-)
       (let ((msg (%read-line-crlf stream)))
         (if errors-as-condition
             (error 'redis-reply-error :message msg :code "ERR")
             (list :error msg))))
      (#.(char-code #\:)
       (parse-integer (%read-line-crlf stream)))
      (#.(char-code #\$)
       (let ((n (parse-integer (%read-line-crlf stream))))
         (when (= n -1)
           (return-from resp-decode-from-stream nil))
         (when (minusp n)
           (%fail (format nil "invalid bulk length ~D" n)))
         (let ((buf (make-array n :element-type '(unsigned-byte 8))))
           (let ((got (read-sequence buf stream)))
             (unless (= got n)
               (%fail "short bulk string read")))
           (let ((cr (read-byte stream nil :eof))
                 (lf (read-byte stream nil :eof)))
             (unless (and (eql cr 13) (eql lf 10))
               (%fail "bulk string missing CRLF")))
           (%utf8-string buf))))
      (#.(char-code #\*)
       (let ((n (parse-integer (%read-line-crlf stream))))
         (when (= n -1)
           (return-from resp-decode-from-stream nil))
         (when (minusp n)
           (%fail (format nil "invalid array length ~D" n)))
         (loop repeat n
               collect (resp-decode-from-stream stream
                                                :errors-as-condition errors-as-condition))))
      ;; RESP3 boolean
      (#.(char-code #\#)
       (let ((line (%read-line-crlf stream)))
         (cond
           ((or (string= line "t") (string= line "T")) t)
           ((or (string= line "f") (string= line "F")) nil)
           (t (%fail (format nil "invalid RESP3 boolean ~S" line))))))
      ;; RESP3 null
      (#.(char-code #\_)
       (%read-line-crlf stream)
       nil)
      ;; RESP3 double
      (#.(char-code #\,)
       (let ((line (%read-line-crlf stream)))
         (read-from-string line)))
      ;; RESP3 blob error
      (#.(char-code #\!)
       (let ((n (parse-integer (%read-line-crlf stream))))
         (let ((buf (make-array (max 0 n) :element-type '(unsigned-byte 8))))
           (when (plusp n) (read-sequence buf stream))
           (read-byte stream) (read-byte stream)
           (let ((msg (%utf8-string buf)))
             (if errors-as-condition
                 (error 'redis-reply-error :message msg :code "ERR")
                 (list :error msg))))))
      ;; RESP3 map → plist alist as flat list of pairs for JS conversion
      (#.(char-code #\%)
       (let ((n (parse-integer (%read-line-crlf stream))))
         (loop repeat n
               collect (resp-decode-from-stream stream
                                                :errors-as-condition errors-as-condition)
               collect (resp-decode-from-stream stream
                                                :errors-as-condition errors-as-condition))))
      ;; RESP3 set → list
      (#.(char-code #\~)
       (let ((n (parse-integer (%read-line-crlf stream))))
         (loop repeat n
               collect (resp-decode-from-stream stream
                                                :errors-as-condition errors-as-condition))))
      (t
       (%fail (format nil "unknown RESP type tag ~A" tag))))))

;;; --- decode from buffer (returns value + next index) ------------------------

(defun %find-crlf (octets start end)
  (loop for i from start below (1- end)
        when (and (= (aref octets i) 13)
                  (= (aref octets (1+ i)) 10))
          return i
        finally (return nil)))

(defun resp-decode-buffer (octets &optional (start 0) (end (length octets))
                            &key (errors-as-condition t))
  "Decode one RESP value from OCTETS. Returns (values value next-index) or
   (values :incomplete start) when more bytes are needed."
  (when (>= start end)
    (return-from resp-decode-buffer (values :incomplete start)))
  (let ((tag (aref octets start)))
    (labels ((line-at (i)
               (let ((cr (%find-crlf octets i end)))
                 (unless cr
                   (return-from resp-decode-buffer (values :incomplete start)))
                 (values (%utf8-string octets :start i :end cr) (+ cr 2))))
             (decode-at (i)
               (when (>= i end)
                 (return-from resp-decode-buffer (values :incomplete start)))
               (let ((tg (aref octets i)))
                 (case tg
                   (#.(char-code #\+)
                    (multiple-value-bind (line next) (line-at (1+ i))
                      (values line next)))
                   (#.(char-code #\-)
                    (multiple-value-bind (line next) (line-at (1+ i))
                      (if errors-as-condition
                          (error 'redis-reply-error :message line :code "ERR")
                          (values (list :error line) next))))
                   (#.(char-code #\:)
                    (multiple-value-bind (line next) (line-at (1+ i))
                      (values (parse-integer line) next)))
                   (#.(char-code #\$)
                    (multiple-value-bind (line next) (line-at (1+ i))
                      (let ((n (parse-integer line)))
                        (when (= n -1)
                          (return-from decode-at (values nil next)))
                        (when (> (+ next n 2) end)
                          (return-from resp-decode-buffer (values :incomplete start)))
                        (let ((s (%utf8-string octets :start next :end (+ next n))))
                          (values s (+ next n 2))))))
                   (#.(char-code #\*)
                    (multiple-value-bind (line next) (line-at (1+ i))
                      (let ((n (parse-integer line)))
                        (when (= n -1)
                          (return-from decode-at (values nil next)))
                        (let ((items '())
                              (pos next))
                          (dotimes (_ n)
                            (multiple-value-bind (v npos) (decode-at pos)
                              (when (eq v :incomplete)
                                (return-from resp-decode-buffer
                                  (values :incomplete start)))
                              (push v items)
                              (setf pos npos)))
                          (values (nreverse items) pos)))))
                   (#.(char-code #\#)
                    (multiple-value-bind (line next) (line-at (1+ i))
                      (values (or (string= line "t") (string= line "T")) next)))
                   (#.(char-code #\_)
                    (multiple-value-bind (_line next) (line-at (1+ i))
                      (declare (ignore _line))
                      (values nil next)))
                   (t
                    (%fail (format nil "unknown RESP type tag ~A" tg)))))))
      (decode-at start))))
