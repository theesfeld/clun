;;;; http-parser.lisp — an own incremental HTTP/1.1 request parser (PLAN.md Phase 17,
;;;; §3.2/§6). Fed the octets the reactor delivers; "accumulate then parse" (robust over
;;;; a byte-FSM). Bounded by max-header + max-body so adversarial lengths can never grow
;;;; the buffer unboundedly or crash — every malformed shape is a classified :error code.
;;;; Pure CL (no engine): the JS Request is built above this in the runtime layer.

(in-package :clun.net)

(defconstant +cr+ 13) (defconstant +lf+ 10) (defconstant +sp+ 32) (defconstant +colon+ 58)
(defparameter *max-header-bytes* 16384)
(defparameter *max-body-bytes* (* 100 1024 1024))

(defstruct (http-request (:conc-name hr-))
  method target version headers body keep-alive)

(defstruct (http-parser (:conc-name hp-))
  (buf (make-array 4096 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
  (phase :headers)                      ; :headers | :body
  (max-header *max-header-bytes*) (max-body *max-body-bytes*)
  ;; set once the head is parsed:
  method target version headers keep-alive
  (body-start 0) (content-length nil) (chunked nil))

(defun %hp-append (p octets)
  (let* ((buf (hp-buf p)) (old (fill-pointer buf)) (n (length octets)))
    (adjust-array buf (max (array-total-size buf) (+ old n)) :fill-pointer (+ old n))
    (replace buf octets :start1 old)))

(defun %find-crlfcrlf (buf start)
  "Index of the CRLFCRLF terminating the header block (points at the first CR), or NIL."
  (loop for i from start below (- (fill-pointer buf) 3)
        when (and (= (aref buf i) +cr+) (= (aref buf (+ i 1)) +lf+)
                  (= (aref buf (+ i 2)) +cr+) (= (aref buf (+ i 3)) +lf+))
          do (return i)))

(defun %find-crlf (buf start end)
  (loop for i from start below (1- end)
        when (and (= (aref buf i) +cr+) (= (aref buf (+ i 1)) +lf+)) do (return i)))

(defun %octets->string (buf start end)
  "Latin-1 decode of buf[start,end) — header bytes are ASCII/latin-1 (never fails)."
  (let ((s (make-string (- end start))))
    (dotimes (i (- end start) s) (setf (char s i) (code-char (aref buf (+ start i)))))))

(defun %trim (s) (string-trim '(#\Space #\Tab) s))

(defun %parse-request-line (line)
  "METHOD SP request-target SP HTTP/1.x  → (values method target version) or NIL on bad."
  (let ((sp1 (position #\Space line)))
    (when sp1
      (let ((sp2 (position #\Space line :start (1+ sp1))))
        (when sp2
          (let ((method (subseq line 0 sp1))
                (target (subseq line (1+ sp1) sp2))
                (version (subseq line (1+ sp2))))
            (when (and (plusp (length method)) (plusp (length target))
                       (member version '("HTTP/1.1" "HTTP/1.0") :test #'string=)
                       (every (lambda (c) (and (graphic-char-p c) (not (char= c #\Space)))) method))
              (values method target (if (string= version "HTTP/1.1") :http/1.1 :http/1.0)))))))))

(defun %parse-headers (buf start end)
  "Parse header lines in buf[start,end). Returns (values alist ok). Names lowercased;
duplicates comma-joined. Obs-fold (leading space/tab) and a colon-less line → not ok (400)."
  (let ((alist '()) (i start))
    (loop
      (when (>= i end) (return (values (nreverse alist) t)))
      (let ((eol (or (%find-crlf buf i end) end)))
        (cond
          ((= eol i) (setf i (+ eol 2)))                 ; empty line (defensive)
          (t
           (let ((fb (aref buf i)))
             (when (or (= fb +sp+) (= fb 9))             ; obs-fold (leading WSP) → 400
               (return (values nil nil))))
           (let* ((line (%octets->string buf i eol)) (colon (position #\: line)))
             (unless colon (return (values nil nil)))
             (let ((name (string-downcase (%trim (subseq line 0 colon))))
                   (value (%trim (subseq line (1+ colon)))))
               (when (zerop (length name)) (return (values nil nil)))
               (let ((existing (assoc name alist :test #'string=)))
                 (if existing
                     (setf (cdr existing) (concatenate 'string (cdr existing) ", " value))
                     (push (cons name value) alist)))))
           (setf i (+ eol 2))))))))

(defun %header (alist name) (cdr (assoc name alist :test #'string=)))

(defun %keep-alive-p (version headers)
  (let ((conn (let ((c (%header headers "connection"))) (and c (string-downcase c)))))
    (if (eq version :http/1.1)
        (not (and conn (search "close" conn)))
        (and conn (search "keep-alive" conn)))))

(defun %safe-parse-int (s)
  "Non-negative decimal integer or NIL (no signs, no junk)."
  (and (plusp (length s)) (every #'digit-char-p s)
       (ignore-errors (parse-integer s))))

(defun %step-headers (p)
  (let* ((buf (hp-buf p)) (hend (%find-crlfcrlf buf 0)))
    (cond
      ((null hend)
       (if (> (fill-pointer buf) (hp-max-header p))
           (values :error '(431 . "Request Header Fields Too Large"))
           (values :need-more nil)))
      (t
       ;; search through hend so a no-header request (whose request-line CRLF IS the
       ;; start of the CRLFCRLF terminator) still yields rl-end = hend.
       (let ((rl-end (%find-crlf buf 0 (+ hend 2))))
         (unless rl-end (return-from %step-headers (values :error '(400 . "Bad Request"))))
         (multiple-value-bind (method target version)
             (%parse-request-line (%octets->string buf 0 rl-end))
           (unless method (return-from %step-headers (values :error '(400 . "Bad Request"))))
           (multiple-value-bind (headers ok) (%parse-headers buf (+ rl-end 2) hend)
             (unless ok (return-from %step-headers (values :error '(400 . "Bad Request"))))
             (let ((te (let ((v (%header headers "transfer-encoding"))) (and v (string-downcase v))))
                   (cl (%header headers "content-length")))
               (setf (hp-method p) method (hp-target p) target (hp-version p) version
                     (hp-headers p) headers (hp-keep-alive p) (%keep-alive-p version headers)
                     (hp-body-start p) (+ hend 4) (hp-phase p) :body)
               (cond
                 ((and te (search "chunked" te)) (setf (hp-chunked p) t))
                 (cl (let ((n (%safe-parse-int (%trim cl))))
                       (cond ((null n) (return-from %step-headers (values :error '(400 . "Bad Request"))))
                             ((> n (hp-max-body p)) (return-from %step-headers (values :error '(413 . "Payload Too Large"))))
                             (t (setf (hp-content-length p) n)))))
                 (t (setf (hp-content-length p) 0)))
               (%step-body p)))))))))

(defun %emit (p body leftover-start)
  "Build the request, reset the parser keeping any leftover (pipelined) bytes."
  (let ((req (make-http-request :method (hp-method p) :target (hp-target p) :version (hp-version p)
                                :headers (hp-headers p) :body body :keep-alive (hp-keep-alive p)))
        (buf (hp-buf p)))
    (let ((leftover (subseq buf leftover-start (fill-pointer buf))))
      (setf (hp-phase p) :headers (hp-method p) nil (hp-target p) nil (hp-version p) nil
            (hp-headers p) nil (hp-content-length p) nil (hp-chunked p) nil (hp-body-start p) 0)
      (setf (fill-pointer buf) 0)
      (%hp-append p leftover))
    (values :request req)))

(defun %step-body (p)
  (let ((buf (hp-buf p)) (start (hp-body-start p)))
    (cond
      ((hp-chunked p) (%step-chunked p))
      (t (let ((n (hp-content-length p)))
           (if (>= (- (fill-pointer buf) start) n)
               (%emit p (subseq buf start (+ start n)) (+ start n))
               (values :need-more nil)))))))

(defun %step-chunked (p)
  "De-chunk from body-start. Returns :need-more until the terminating 0-chunk arrives,
:error 400 on malformed, :error 413 if the accumulated body exceeds max-body."
  (let* ((buf (hp-buf p)) (i (hp-body-start p)) (end (fill-pointer buf))
         (body (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (loop
      (let ((crlf (%find-crlf buf i end)))
        (when (null crlf) (return (values :need-more nil)))
        (let* ((size-line (%trim (%octets->string buf i crlf)))
               ;; strip any chunk extensions after ';'
               (semi (position #\; size-line))
               (hex (if semi (subseq size-line 0 semi) size-line))
               (size (and (plusp (length hex))
                          (every (lambda (c) (digit-char-p c 16)) hex)
                          (ignore-errors (parse-integer hex :radix 16)))))
          (when (null size) (return (values :error '(400 . "Bad Request"))))
          (when (> (+ (fill-pointer body) size) (hp-max-body p))
            (return (values :error '(413 . "Payload Too Large"))))
          (let ((data-start (+ crlf 2)))
            (cond
              ((zerop size)
               ;; final chunk: expect the trailing CRLF (ignore trailers up to CRLFCRLF)
               (let ((trailer-end (%find-crlfcrlf buf i)))
                 (cond ((and (= (aref-safe buf data-start) +cr+) (= (aref-safe buf (1+ data-start)) +lf+))
                        (return (%emit p (subseq body 0) (+ data-start 2))))
                       (trailer-end (return (%emit p (subseq body 0) (+ trailer-end 4))))
                       (t (return (values :need-more nil))))))
              (t
               (when (< end (+ data-start size 2)) (return (values :need-more nil)))
               (let ((chunk-end (+ data-start size)))
                 (unless (and (= (aref buf chunk-end) +cr+) (= (aref buf (1+ chunk-end)) +lf+))
                   (return (values :error '(400 . "Bad Request"))))
                 (let ((old (fill-pointer body)))
                   (adjust-array body (+ old size) :fill-pointer (+ old size))
                   (replace body buf :start1 old :start2 data-start :end2 chunk-end))
                 (setf i (+ chunk-end 2)))))))))))

(defun aref-safe (buf i) (if (< i (fill-pointer buf)) (aref buf i) -1))

(defun parser-feed (p octets)
  "Append OCTETS and advance. Returns (values EVENT DATA): :need-more / :request req /
:error (code . reason)."
  (%hp-append p octets)
  (ecase (hp-phase p)
    (:headers (%step-headers p))
    (:body (%step-body p))))
