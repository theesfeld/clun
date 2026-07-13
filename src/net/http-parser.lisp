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

(defstruct (http-response (:conc-name hres-))
  status reason version headers body keep-alive)

(defstruct (http-parser (:conc-name hp-))
  (buf (make-array 4096 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
  (phase :headers)                      ; :headers | :body
  (max-header *max-header-bytes*) (max-body *max-body-bytes*)
  (response nil)                        ; T = parse responses (status line, until-close body)
  ;; set once the head is parsed:
  method target version status reason headers keep-alive
  (body-start 0) (content-length nil) (chunked nil) (until-close nil))

(defun make-http-response-parser (&key (max-header *max-header-bytes*) (max-body *max-body-bytes*))
  (make-http-parser :response t :max-header max-header :max-body max-body))

(defun %parse-status-line (line)
  "HTTP/1.x SP code SP reason → (values version code reason) or NIL."
  (let ((sp1 (position #\Space line)))
    (when sp1
      (let* ((ver (subseq line 0 sp1))
             (rest (subseq line (1+ sp1)))
             (sp2 (position #\Space rest))
             (code-str (if sp2 (subseq rest 0 sp2) rest))
             (reason (if sp2 (subseq rest (1+ sp2)) "")))
        (when (and (member ver '("HTTP/1.1" "HTTP/1.0") :test #'string=)
                   (= (length code-str) 3) (every #'digit-char-p code-str))
          (values (if (string= ver "HTTP/1.1") :http/1.1 :http/1.0)
                  (parse-integer code-str) reason))))))

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
         (let ((line (%octets->string buf 0 rl-end)))
           (if (hp-response p) (%head-response p line buf rl-end hend) (%head-request p line buf rl-end hend))))))))

(defun %head-request (p line buf rl-end hend)
  (multiple-value-bind (method target version) (%parse-request-line line)
    (unless method (return-from %head-request (values :error '(400 . "Bad Request"))))
    (multiple-value-bind (headers ok) (%parse-headers buf (+ rl-end 2) hend)
      (unless ok (return-from %head-request (values :error '(400 . "Bad Request"))))
      (setf (hp-method p) method (hp-target p) target (hp-version p) version
            (hp-headers p) headers (hp-keep-alive p) (%keep-alive-p version headers))
      (%frame-body p headers version (+ hend 4) nil))))

(defun %head-response (p line buf rl-end hend)
  (multiple-value-bind (version code reason) (%parse-status-line line)
    (unless version (return-from %head-response (values :error '(400 . "Bad Response"))))
    (multiple-value-bind (headers ok) (%parse-headers buf (+ rl-end 2) hend)
      (unless ok (return-from %head-response (values :error '(400 . "Bad Response"))))
      (setf (hp-status p) code (hp-reason p) reason (hp-version p) version
            (hp-headers p) headers (hp-keep-alive p) (%keep-alive-p version headers))
      ;; a 204/304 or HEAD-style response has no body; else content-length / chunked /
      ;; (responses only) read-until-close.
      (%frame-body p headers version (+ hend 4)
                   (or (member code '(204 304)) (< code 200))))))

(defun %frame-body (p headers version body-start no-body)
  (declare (ignore version))
  (let ((te (let ((v (%header headers "transfer-encoding"))) (and v (string-downcase v))))
        (cl (%header headers "content-length")))
    (setf (hp-body-start p) body-start (hp-phase p) :body)
    (cond
      (no-body (setf (hp-content-length p) 0))
      ((and te (search "chunked" te)) (setf (hp-chunked p) t))
      (cl (let ((n (%safe-parse-int (%trim cl))))
            (cond ((null n) (return-from %frame-body (values :error '(400 . "Bad Request"))))
                  ((> n (hp-max-body p)) (return-from %frame-body (values :error '(413 . "Payload Too Large"))))
                  (t (setf (hp-content-length p) n)))))
      ((hp-response p) (setf (hp-until-close p) t))    ; no framing → read until the peer closes
      (t (setf (hp-content-length p) 0)))
    (%step-body p)))

(defun %emit (p body leftover-start)
  "Build the request/response, reset the parser keeping any leftover (pipelined) bytes."
  (let ((result
          (if (hp-response p)
              (make-http-response :status (hp-status p) :reason (hp-reason p) :version (hp-version p)
                                  :headers (hp-headers p) :body body :keep-alive (hp-keep-alive p))
              (make-http-request :method (hp-method p) :target (hp-target p) :version (hp-version p)
                                 :headers (hp-headers p) :body body :keep-alive (hp-keep-alive p))))
        (buf (hp-buf p)))
    (let ((leftover (subseq buf leftover-start (fill-pointer buf))))
      (setf (hp-phase p) :headers (hp-method p) nil (hp-target p) nil (hp-version p) nil
            (hp-status p) nil (hp-reason p) nil
            (hp-headers p) nil (hp-content-length p) nil (hp-chunked p) nil (hp-until-close p) nil
            (hp-body-start p) 0)
      (setf (fill-pointer buf) 0)
      (%hp-append p leftover))
    (values (if (http-response-p result) :response :request) result)))

(defun %step-body (p)
  (let ((buf (hp-buf p)) (start (hp-body-start p)))
    (cond
      ((hp-chunked p) (%step-chunked p))
      ((hp-until-close p)                               ; body ends at EOF → response-finish
       (if (> (- (fill-pointer buf) start) (hp-max-body p))
           (values :error '(413 . "Payload Too Large"))   ; bound the unframed body too (DoS guard)
           (values :need-more nil)))
      (t (let ((n (hp-content-length p)))
           (if (>= (- (fill-pointer buf) start) n)
               (%emit p (subseq buf start (+ start n)) (+ start n))
               (values :need-more nil)))))))

(defun response-finish (p)
  "The client calls this on EOF: for an until-close body, emit the response with whatever
body accumulated. Returns (:response resp) or NIL if no response was in progress."
  (when (and (hp-response p) (eq (hp-phase p) :body) (hp-until-close p))
    (%emit p (subseq (hp-buf p) (hp-body-start p) (fill-pointer (hp-buf p))) (fill-pointer (hp-buf p)))))

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
