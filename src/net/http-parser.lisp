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
  status reason version headers body keep-alive
  ;; True only for a non-2xx response from an HTTPS proxy's CONNECT request.
  ;; Fetch exposes this response but must not apply origin redirect handling.
  (proxy-response-p nil))

(defstruct (http-headers-ready (:conc-name hhr-))
  "Headers-complete event for progressive request-body streaming.
BODY-REMAINING is the Content-Length budget (NIL for chunked)."
  method target version headers keep-alive
  (body-remaining nil)
  (chunked-p nil))

(defstruct (http-parser (:conc-name hp-))
  (buf (make-array 4096 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
  (phase :headers)                      ; :headers | :body
  (max-header *max-header-bytes*) (max-body *max-body-bytes*)
  ;; Chunk metadata is bounded independently from decoded body bytes.  NIL uses
  ;; max-header; callers that deliberately accept unusually fragmented bodies
  ;; can opt into a larger finite budget.
  (max-framing nil)
  (response nil)                        ; T = parse responses (status line, until-close body)
  (header-scan-start 0 :type (integer 0 *))
  ;; set once the head is parsed:
  method target version status reason headers keep-alive
  (body-start 0) (content-length nil) (chunked nil) (until-close nil)
  ;; Progressive request body: emit :headers then :body-chunk / :body-end.
  ;; Opt-in via MAKE-HTTP-PARSER :STREAM-BODY T (Clun.serve enables it).
  (want-stream-body-p nil)
  (stream-body-p nil)
  (headers-emitted-p nil)
  (body-remaining 0 :type (integer 0 *))
  ;; Incremental chunk decoder state.  Consumed wire bytes are compacted out of
  ;; BUF; decoded bytes live in CHUNK-BODY and are copied once per chunk.
  (chunk-state :size)                   ; :size | :data | :trailers
  chunk-size
  (chunk-scan-start 0 :type (integer 0 *))
  (chunk-trailer-scan-start 0 :type (integer 0 *))
  (chunk-framing-bytes 0 :type (integer 0 *))
  (chunk-body (make-array 0 :element-type '(unsigned-byte 8)
                            :adjustable t :fill-pointer 0)))

(defun make-http-response-parser (&key (max-header *max-header-bytes*)
                                       (max-body *max-body-bytes*) max-framing)
  (make-http-parser :response t :max-header max-header :max-body max-body
                    :max-framing max-framing))

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

(defun %hp-append (p octets &key (start 0) (end (length octets)))
  (let* ((buf (hp-buf p)) (old (fill-pointer buf)) (n (- end start)))
    (let ((needed (+ old n))
          (capacity (array-total-size buf)))
      (when (> needed capacity)
        (loop while (< capacity needed)
              do (setf capacity (* 2 (max capacity 1))))
        (adjust-array buf capacity :fill-pointer needed))
      (setf (fill-pointer buf) needed))
    (replace buf octets :start1 old :start2 start :end2 end)))

(defun %octet-view (octets start end)
  "A non-copying view of OCTETS[START,END), used by bounded feed preflights."
  (if (and (zerop start) (= end (length octets)))
      octets
      (make-array (- end start) :element-type '(unsigned-byte 8)
                  :displaced-to octets :displaced-index-offset start)))

(defun %discard-buffer-prefix (p count)
  "Remove COUNT already-consumed octets without allocating another wire buffer."
  (let* ((buf (hp-buf p))
         (end (fill-pointer buf))
         (remaining (- end count)))
    (when (plusp remaining)
      (replace buf buf :start1 0 :start2 count :end2 end))
    (setf (fill-pointer buf) remaining)
    buf))

(defun %chunk-framing-limit (p)
  (or (hp-max-framing p) (hp-max-header p)))

(defun %chunk-add-framing (p count)
  "Account consumed chunk metadata.  Return false instead of crossing the cap."
  (let ((total (+ (hp-chunk-framing-bytes p) count)))
    (when (<= total (%chunk-framing-limit p))
      (setf (hp-chunk-framing-bytes p) total)
      t)))

(defun %chunk-body-append (p source end)
  "Append SOURCE[0,END) geometrically to the persistent decoded body."
  (let* ((body (hp-chunk-body p))
         (old (fill-pointer body))
         (needed (+ old end))
         (capacity (array-total-size body)))
    (when (> needed capacity)
      (loop while (< capacity needed)
            do (setf capacity (* 2 (max capacity 1))))
      (adjust-array body capacity :fill-pointer needed))
    (setf (fill-pointer body) needed)
    (replace body source :start1 old :end2 end)
    body))

(defun %find-crlfcrlf-across-feed-from (p octets start limit)
  "Find CRLFCRLF in BUF+OCTETS up to absolute LIMIT without retaining OCTETS."
  (let* ((buf (hp-buf p))
         (old (fill-pointer buf))
         (total (+ old (length octets)))
         (end (min total limit))
         (start (min start end)))
    (labels ((byte-at (index)
               (if (< index old)
                   (aref buf index)
                   (aref octets (- index old)))))
      (loop for index from start below (- end 3)
            when (and (= (byte-at index) +cr+)
                      (= (byte-at (+ index 1)) +lf+)
                      (= (byte-at (+ index 2)) +cr+)
                      (= (byte-at (+ index 3)) +lf+))
              do (return index)))))

(defun %find-crlfcrlf-across-feed (p octets limit)
  "Find an allowed header terminator without first retaining OCTETS.
LIMIT is the maximum complete header-section length, including CRLFCRLF."
  (%find-crlfcrlf-across-feed-from
   p octets (hp-header-scan-start p) limit))

(defun %find-crlf-across-feed (p octets start limit)
  "Find CRLF in BUF+OCTETS up to absolute LIMIT without retaining OCTETS."
  (let* ((buf (hp-buf p))
         (old (fill-pointer buf))
         (total (+ old (length octets)))
         (end (min total limit))
         (start (min start end)))
    (labels ((byte-at (index)
               (if (< index old)
                   (aref buf index)
                   (aref octets (- index old)))))
      (loop for index from start below (1- end)
            when (and (= (byte-at index) +cr+)
                      (= (byte-at (1+ index)) +lf+))
              do (return index)))))

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

(defun %http-token-character-p (character)
  "Whether CHARACTER is one of RFC 9110's ASCII field-name token characters."
  (or (and (char>= character #\a) (char<= character #\z))
      (and (char>= character #\A) (char<= character #\Z))
      (and (char>= character #\0) (char<= character #\9))
      (find character "!#$%&'*+-.^_`|~" :test #'char=)))

(defun %valid-field-value-p (value)
  "The byte parser already bounds VALUE to Latin-1; reject framing/injection bytes."
  (notany (lambda (character)
            (member character '(#\Null #\Return #\Newline) :test #'char=))
          value))

(defun %parse-headers (buf start end)
  "Parse header lines in buf[start,end). Return ordered, lower-cased raw pairs.
Duplicates stay distinct so Cookie, Set-Cookie, and framing fields can apply their own
combination rules. Invalid names/values, obs-fold, and colon-less lines return not ok."
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
             (let* ((raw-name (subseq line 0 colon))
                    (raw-value (subseq line (1+ colon))))
               (when (or (zerop (length raw-name))
                         (not (every #'%http-token-character-p raw-name))
                         (not (%valid-field-value-p raw-value)))
                 (return (values nil nil)))
               ;; Validation precedes OWS trimming. The ordered pair is the transport
               ;; representation; it must not erase duplicate Set-Cookie fields.
               (push (cons (string-downcase raw-name) (%trim raw-value)) alist)))
           (setf i (+ eol 2))))))))

(defun %header-values (alist name)
  "All values for NAME in wire order."
  (loop for (field-name . value) in alist
        when (string= field-name name)
          collect value))

(defun %header (alist name)
  "The Headers.get-style joined value for NAME, or NIL when absent."
  (let ((values (%header-values alist name)))
    (when values
      (format nil (if (string= name "cookie") "~{~a~^; ~}" "~{~a~^, ~}") values))))

(defun %comma-members (values)
  "Split ordered field VALUES on commas, retaining empty members for validation."
  (loop for value in values append
    (loop with start = 0
          for comma = (position #\, value :start start)
          collect (%trim (subseq value start comma))
          while comma
          do (setf start (1+ comma)))))

(defun %keep-alive-p (version headers)
  (let* ((members (%comma-members (%header-values headers "connection")))
         (close-p (find "close" members :test #'string-equal))
         (keep-alive-p (find "keep-alive" members :test #'string-equal)))
    (if (eq version :http/1.1)
        (not close-p)
        (and keep-alive-p (not close-p)))))

(defun %safe-parse-int (s)
  "Non-negative decimal integer or NIL (no signs, no junk)."
  (and (plusp (length s)) (every #'digit-char-p s)
       (ignore-errors (parse-integer s))))

(defun %step-headers (p)
  (let* ((buf (hp-buf p))
         (hend (%find-crlfcrlf buf (hp-header-scan-start p))))
    (cond
      ((null hend)
       ;; Only the final three retained bytes can begin a terminator completed by
       ;; the next feed. Persisting this cursor makes one-byte feeds linear.
       (setf (hp-header-scan-start p)
             (max 0 (- (fill-pointer buf) 3)))
       (if (> (fill-pointer buf) (hp-max-header p))
           (values :error '(431 . "Request Header Fields Too Large"))
           (values :need-more nil)))
      ((> (+ hend 4) (hp-max-header p))
       ;; The bound covers the complete first header section, not merely feeds that
       ;; happen to arrive without the terminator and not any pipelined successor.
       (values :error '(431 . "Request Header Fields Too Large")))
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

(defun %start-chunked-body (p body-start)
  "Initialize one message's incremental chunk decoder and discard its parsed head."
  (setf (hp-chunked p) t
        (hp-body-start p) 0
        (hp-chunk-state p) :size
        (hp-chunk-size p) nil
        (hp-chunk-scan-start p) 0
        (hp-chunk-trailer-scan-start p) 0
        (hp-chunk-framing-bytes p) 0
        (fill-pointer (hp-chunk-body p)) 0)
  (%discard-buffer-prefix p body-start))

(defun %headers-ready-event (p)
  (make-http-headers-ready
   :method (hp-method p)
   :target (hp-target p)
   :version (hp-version p)
   :headers (hp-headers p)
   :keep-alive (hp-keep-alive p)
   :body-remaining (hp-content-length p)
   :chunked-p (and (hp-chunked p) t)))

(defun %frame-body (p headers version body-start no-body)
  (declare (ignore version))
  (let* ((te-values (%header-values headers "transfer-encoding"))
         (cl-values (%header-values headers "content-length"))
         (cl-members (%comma-members cl-values))
         (lengths (mapcar #'%safe-parse-int cl-members)))
    (setf (hp-body-start p) body-start
          (hp-phase p) :body
          (hp-stream-body-p p) nil
          (hp-headers-emitted-p p) nil
          (hp-body-remaining p) 0)
    (cond
      ;; Reject ambiguous framing before considering a response's no-body status.
      ((and te-values cl-values)
       (return-from %frame-body (values :error '(400 . "Bad Request"))))
      ((and te-values
            (or (/= (length te-values) 1)
                (not (string-equal (%trim (first te-values)) "chunked"))))
       (return-from %frame-body (values :error '(400 . "Bad Request"))))
      ((and cl-values
            (or (some #'null lengths)
                (not (every (lambda (n) (= n (first lengths))) (rest lengths)))))
       (return-from %frame-body (values :error '(400 . "Bad Request"))))
      (no-body (setf (hp-content-length p) 0))
      (te-values (%start-chunked-body p body-start))
      (cl-values
       (let ((n (first lengths)))
         (if (> n (hp-max-body p))
             (return-from %frame-body (values :error '(413 . "Payload Too Large")))
             (setf (hp-content-length p) n
                   (hp-body-remaining p) n))))
      ((hp-response p) (setf (hp-until-close p) t))    ; no framing → read until the peer closes
      (t (setf (hp-content-length p) 0)))
    ;; Progressive request streaming (opt-in): headers first when a non-empty
    ;; body is expected. Default buffered mode preserves the historic :request event.
    (when (and (hp-want-stream-body-p p) (not (hp-response p)))
      (cond
        ((and (hp-content-length p) (plusp (hp-content-length p)))
         (setf (hp-stream-body-p p) t
               (hp-headers-emitted-p p) t)
         (return-from %frame-body (values :headers (%headers-ready-event p))))
        ((hp-chunked p)
         (setf (hp-stream-body-p p) t
               (hp-headers-emitted-p p) t)
         (return-from %frame-body (values :headers (%headers-ready-event p))))))
    (%step-body p)))

(defun %reset-parser-head (p leftover-start)
  "Reset head/body state after a completed message; retain leftover wire bytes."
  (let* ((buf (hp-buf p))
         (leftover (subseq buf leftover-start (fill-pointer buf))))
    (setf (hp-phase p) :headers (hp-method p) nil (hp-target p) nil (hp-version p) nil
          (hp-status p) nil (hp-reason p) nil
          (hp-headers p) nil (hp-content-length p) nil (hp-chunked p) nil (hp-until-close p) nil
          (hp-body-start p) 0 (hp-header-scan-start p) 0
          (hp-stream-body-p p) nil (hp-headers-emitted-p p) nil (hp-body-remaining p) 0
          (hp-chunk-state p) :size (hp-chunk-size p) nil
          (hp-chunk-scan-start p) 0 (hp-chunk-trailer-scan-start p) 0
          (hp-chunk-framing-bytes p) 0
          (fill-pointer (hp-chunk-body p)) 0)
    (setf (fill-pointer buf) 0)
    (%hp-append p leftover)))

(defun %emit (p body leftover-start)
  "Build the request/response, reset the parser keeping any leftover (pipelined) bytes."
  (let ((result
          (if (hp-response p)
              (make-http-response :status (hp-status p) :reason (hp-reason p) :version (hp-version p)
                                  :headers (hp-headers p) :body body :keep-alive (hp-keep-alive p))
              (make-http-request :method (hp-method p) :target (hp-target p) :version (hp-version p)
                                 :headers (hp-headers p) :body body :keep-alive (hp-keep-alive p)))))
    (%reset-parser-head p leftover-start)
    (values (if (http-response-p result) :response :request) result)))

(defun %emit-body-end (p leftover-start)
  "Finish a progressive request body stream and reset the parser."
  (let ((keep-alive (hp-keep-alive p)))
    (%reset-parser-head p leftover-start)
    (values :body-end keep-alive)))

(defun %step-body (p)
  (let ((buf (hp-buf p)) (start (hp-body-start p)))
    (cond
      ((hp-chunked p) (%step-chunked p))
      ((hp-until-close p)                               ; body ends at EOF → response-finish
       (if (> (- (fill-pointer buf) start) (hp-max-body p))
           (values :error '(413 . "Payload Too Large"))   ; bound the unframed body too (DoS guard)
           (values :need-more nil)))
      ((and (hp-stream-body-p p) (not (hp-response p)))
       ;; Progressive Content-Length body: emit available octets as :body-chunk,
       ;; and :body-end (with optional final chunk) when the budget is exhausted.
       (let* ((available (- (fill-pointer buf) start))
              (want (hp-body-remaining p))
              (n (min available want)))
         (cond
           ((zerop want)
            (%emit-body-end p start))
           ((zerop n)
            (values :need-more nil))
           (t
            (let ((chunk (subseq buf start (+ start n)))
                  (left (- want n)))
              (setf (hp-body-start p) (+ start n)
                    (hp-body-remaining p) left)
              (%discard-buffer-prefix p (hp-body-start p))
              (setf (hp-body-start p) 0)
              (if (zerop left)
                  (let ((keep-alive (hp-keep-alive p)))
                    (%reset-parser-head p 0)
                    (values :body-end (cons chunk keep-alive)))
                  (values :body-chunk chunk)))))))
      (t (let ((n (hp-content-length p)))
           (if (>= (- (fill-pointer buf) start) n)
               (%emit p (subseq buf start (+ start n)) (+ start n))
               (values :need-more nil)))))))

(defun response-finish (p)
  "The client calls this on EOF: for an until-close body, emit the response with whatever
body accumulated. Returns (:response resp) or NIL if no response was in progress."
  (when (and (hp-response p) (eq (hp-phase p) :body) (hp-until-close p))
    (%emit p (subseq (hp-buf p) (hp-body-start p) (fill-pointer (hp-buf p))) (fill-pointer (hp-buf p)))))

(defun %parse-bounded-chunk-size (line limit)
  "Parse LINE's hexadecimal size without constructing an attacker-sized bignum.
The second value is :MALFORMED, :TOO-LARGE, or NIL."
  (let* ((trimmed (%trim line))
         (semi (position #\; trimmed))
         (hex (if semi (subseq trimmed 0 semi) trimmed)))
    (cond
      ((or (zerop (length hex))
           (not (every (lambda (character) (digit-char-p character 16)) hex)))
       (values nil :malformed))
      (t
       (let ((size 0))
         (loop for character across hex
               do
           (let ((digit (digit-char-p character 16)))
             ;; Check before multiplication so SIZE never grows past LIMIT.
             (when (> size (floor (- limit digit) 16))
               (return (values nil :too-large)))
             (setf size (+ (* size 16) digit)))
               finally (return (values size nil))))))))

(defun %chunk-body-copy (p)
  (let ((body (hp-chunk-body p)))
    (subseq body 0 (fill-pointer body))))

(defun %step-chunked (p)
  "Incrementally decode one bounded chunked body in linear time."
  (loop
    (let* ((buf (hp-buf p))
           (end (fill-pointer buf)))
      (ecase (hp-chunk-state p)
        (:size
         (let ((crlf (%find-crlf buf (hp-chunk-scan-start p) end)))
           (cond
             ((null crlf)
              (setf (hp-chunk-scan-start p) (max 0 (1- end)))
              (return
                (if (> end (hp-max-header p))
                    (values :error '(400 . "Bad Request"))
                    (values :need-more nil))))
             ((> (+ crlf 2) (hp-max-header p))
              (return (values :error '(400 . "Bad Request"))))
             (t
              (multiple-value-bind (size failure)
                  (%parse-bounded-chunk-size
                   (%octets->string buf 0 crlf)
                   (- (hp-max-body p) (fill-pointer (hp-chunk-body p))))
                (case failure
                  (:malformed
                   (return (values :error '(400 . "Bad Request"))))
                  (:too-large
                   (return (values :error '(413 . "Payload Too Large")))))
                (unless (%chunk-add-framing p (+ crlf 2))
                  (return (values :error '(400 . "Bad Request"))))
                (%discard-buffer-prefix p (+ crlf 2))
                (setf (hp-chunk-size p) size
                      (hp-chunk-scan-start p) 0
                      (hp-chunk-state p) (if (zerop size) :trailers :data)))))))
        (:data
         (let ((size (hp-chunk-size p)))
           (when (< end (+ size 2))
             (return (values :need-more nil)))
           (unless (and (= (aref buf size) +cr+)
                        (= (aref buf (1+ size)) +lf+))
             (return (values :error '(400 . "Bad Request"))))
           (unless (%chunk-add-framing p 2)
             (return (values :error '(400 . "Bad Request"))))
           (cond
             ((hp-stream-body-p p)
              (let ((chunk (subseq buf 0 size)))
                (%discard-buffer-prefix p (+ size 2))
                (setf (hp-chunk-size p) nil
                      (hp-chunk-state p) :size
                      (hp-chunk-scan-start p) 0)
                (return (values :body-chunk chunk))))
             (t
              (%chunk-body-append p buf size)
              (%discard-buffer-prefix p (+ size 2))
              (setf (hp-chunk-size p) nil
                    (hp-chunk-state p) :size
                    (hp-chunk-scan-start p) 0)))))
        (:trailers
         (cond
           ;; Empty trailer section: the CRLF directly follows the zero-size line.
           ((and (>= end 2) (= (aref buf 0) +cr+) (= (aref buf 1) +lf+))
            (unless (%chunk-add-framing p 2)
              (return (values :error '(400 . "Bad Request"))))
            (return
              (if (hp-stream-body-p p)
                  (let ((keep-alive (hp-keep-alive p)))
                    (%reset-parser-head p 2)
                    (values :body-end (cons
                                       (make-array 0 :element-type '(unsigned-byte 8))
                                       keep-alive)))
                  (%emit p (%chunk-body-copy p) 2))))
           (t
            (let ((trailer-end
                    (%find-crlfcrlf buf
                                    (hp-chunk-trailer-scan-start p))))
              (cond
                (trailer-end
                 (let ((section-length (+ trailer-end 4)))
                   (when (> section-length (hp-max-header p))
                     (return (values :error
                                     '(431 . "Request Header Fields Too Large"))))
                   (unless (%chunk-add-framing p section-length)
                     (return (values :error '(400 . "Bad Request"))))
                   (return (%emit p (%chunk-body-copy p) section-length))))
                (t
                 (setf (hp-chunk-trailer-scan-start p)
                       (max 0 (- end 3)))
                 (return
                   (if (> end (hp-max-header p))
                       (values :error
                               '(431 . "Request Header Fields Too Large"))
                       (values :need-more nil)))))))))))))

(defun %preflight-chunk-framing-feed (p octets)
  "Return an HTTP error when OCTETS would cross an incomplete framing bound.
The check runs before `%hp-append`, so a single oversized feed is never retained."
  (let* ((retained (fill-pointer (hp-buf p)))
         (total (+ retained (length octets)))
         (limit (hp-max-header p)))
    (case (hp-chunk-state p)
      (:size
       (when (and (> total limit)
                  (null (%find-crlf-across-feed
                         p octets (hp-chunk-scan-start p) limit)))
         '(400 . "Bad Request")))
      (:trailers
       (when (and (> total limit)
                  ;; The empty trailer section is one CRLF, not CRLFCRLF.
                  (not (eql 0 (%find-crlf-across-feed p octets 0 2)))
                  (null (%find-crlfcrlf-across-feed-from
                         p octets (hp-chunk-trailer-scan-start p) limit)))
         '(431 . "Request Header Fields Too Large"))))))

(defun parser-feed (p octets)
  "Append OCTETS and advance. Returns (values EVENT DATA): :need-more / :request req /
:error (code . reason). Oversized feeds are ingested at parser-state boundaries so
header, chunk-size, and trailer limits are enforced before retaining later bytes."
  (let ((start 0)
        (end (length octets)))
    (loop
      with event
      with data
      do
         (let* ((incoming (%octet-view octets start end))
                (remaining (- end start)))
           (ecase (hp-phase p)
             (:headers
              (let* ((old (fill-pointer (hp-buf p)))
                     (total (+ old remaining))
                     (limit (hp-max-header p))
                     (terminator
                       (and (> total limit)
                            (%find-crlfcrlf-across-feed p incoming limit))))
                (when (and (> total limit) (null terminator))
                  (return-from parser-feed
                    (values :error '(431 . "Request Header Fields Too Large"))))
                (if terminator
                    ;; Parse the bounded head first. The remaining bytes may begin
                    ;; chunk framing and must pass that state's pre-append check.
                    (let ((count (max 0 (- (+ terminator 4) old))))
                      (%hp-append p octets :start start :end (+ start count))
                      (incf start count))
                    (progn
                      (%hp-append p octets :start start :end end)
                      (setf start end)))
                (multiple-value-setq (event data) (%step-headers p))))
             (:body
              (if (not (hp-chunked p))
                  (progn
                    (%hp-append p octets :start start :end end)
                    (setf start end)
                    (multiple-value-setq (event data) (%step-body p)))
                  (let* ((old (fill-pointer (hp-buf p)))
                         (total (+ old remaining))
                         (limit (hp-max-header p))
                         (error (%preflight-chunk-framing-feed p incoming)))
                    (when error
                      (return-from parser-feed (values :error error)))
                    (case (hp-chunk-state p)
                      (:size
                       (let ((line-end
                               (and (> total limit)
                                    (%find-crlf-across-feed
                                     p incoming (hp-chunk-scan-start p) limit))))
                         (if line-end
                             (let ((count (max 0 (- (+ line-end 2) old))))
                               (%hp-append p octets :start start
                                           :end (+ start count))
                               (incf start count))
                             (progn
                               (%hp-append p octets :start start :end end)
                               (setf start end)))))
                      (:data
                       ;; Do not retain bytes belonging to the next framing state
                       ;; until the current data terminator has been consumed.
                       (let* ((required (+ (hp-chunk-size p) 2))
                              (count (min remaining (max 0 (- required old)))))
                         (%hp-append p octets :start start :end (+ start count))
                         (incf start count)))
                      (:trailers
                       (let* ((empty-end
                                (and (> total limit)
                                     (eql 0 (%find-crlf-across-feed
                                             p incoming 0 2))
                                     2))
                              (section
                                (and (> total limit) (null empty-end)
                                     (%find-crlfcrlf-across-feed-from
                                      p incoming
                                      (hp-chunk-trailer-scan-start p) limit)))
                              (section-end (or empty-end
                                               (and section (+ section 4)))))
                         (if section-end
                             (let ((count (max 0 (- section-end old))))
                               (%hp-append p octets :start start
                                           :end (+ start count))
                               (incf start count))
                             (progn
                               (%hp-append p octets :start start :end end)
                               (setf start end))))))
                    (multiple-value-setq (event data) (%step-body p)))))))
         (cond
           ;; A bounded state boundary was consumed; apply the next state's
           ;; preflight to the unretained suffix in this same socket read.
           ((and (eq event :need-more) (< start end)))
           ;; Progressive body events: keep feeding the same socket read so a
           ;; large body can surface as multiple :body-chunk events without
           ;; waiting for another readable notification.
           ((and (eq event :body-chunk) (< start end))
            ;; Stash the remaining feed for the next parser-feed invocation by
            ;; appending after the current body state has retained its own bytes.
            (%hp-append p octets :start start :end end)
            (return (values event data)))
           ;; Preserve pipelined bytes after emitting one message. They are parsed
           ;; by the caller's next feed, matching the existing one-event contract.
           ((and (member event '(:request :response :headers :body-end))
                 (< start end))
            (%hp-append p octets :start start :end end)
            (return (values event data)))
           (t
            (return (values event data)))))))

;;; --- response streaming ----------------------------------------------------

(defstruct (http-response-stream-parser
            (:conc-name hrs-)
            (:constructor %make-http-response-stream-parser))
  (buf (make-array 4096 :element-type '(unsigned-byte 8)
                        :adjustable t :fill-pointer 0))
  (phase :headers)                       ; headers/fixed/until-close/chunk-*/done/error
  (max-header *max-header-bytes*)
  (max-body *max-body-bytes*)
  (max-framing *max-header-bytes*)
  (head-request-p nil)
  status reason version headers keep-alive
  (remaining 0 :type (integer 0 *))
  (body-bytes 0 :type (integer 0 *))
  (framing-bytes 0 :type (integer 0 *))
  (terminal-p nil)
  (reusable-p t))

(defun make-http-response-stream-parser
    (&key (max-header *max-header-bytes*)
          (max-body *max-body-bytes*)
          (max-framing max-header)
          (head-request-p nil))
  "Create a bounded response-only parser that emits headers and body chunks.

RESPONSE-STREAM-FEED returns a list of (KIND . VALUE) events. KIND is :HEADERS,
:DATA, :COMPLETE, or :ERROR. Unlike MAKE-HTTP-RESPONSE-PARSER, this parser never
retains decoded body bytes after emitting them."
  (%make-http-response-stream-parser
   :max-header max-header :max-body max-body :max-framing max-framing
   :head-request-p head-request-p))

(defun %hrs-clear-buffer (parser)
  (setf (fill-pointer (hrs-buf parser)) 0))

(defun %hrs-buffer-push (parser byte)
  (let* ((buffer (hrs-buf parser))
         (length (fill-pointer buffer)))
    (when (= length (array-total-size buffer))
      (adjust-array buffer (* 2 (max 1 length)) :fill-pointer length))
    (vector-push byte buffer)
    buffer))

(defun %hrs-buffer-ends-with-p (parser bytes)
  (let* ((buffer (hrs-buf parser))
         (end (fill-pointer buffer))
         (count (length bytes)))
    (and (>= end count)
         (loop for index below count
               always (= (aref buffer (+ (- end count) index))
                         (aref bytes index))))))

(defparameter +http-crlf+
  (make-array 2 :element-type '(unsigned-byte 8)
                :initial-contents (list +cr+ +lf+)))

(defparameter +http-head-end+
  (make-array 4 :element-type '(unsigned-byte 8)
                :initial-contents (list +cr+ +lf+ +cr+ +lf+)))

(defun %hrs-framing-add (parser count)
  (let ((next (+ (hrs-framing-bytes parser) count)))
    (when (<= next (hrs-max-framing parser))
      (setf (hrs-framing-bytes parser) next)
      t)))

(defun %hrs-parse-head (parser)
  "Parse and frame the complete header block in PARSER.
Returns (values response-head error-pair)."
  (let* ((buffer (hrs-buf parser))
         (length (fill-pointer buffer))
         (header-end (- length 4))
         (line-end (%find-crlf buffer 0 (+ header-end 2))))
    (unless line-end
      (return-from %hrs-parse-head
        (values nil '(400 . "Bad Response"))))
    (multiple-value-bind (version status reason)
        (%parse-status-line (%octets->string buffer 0 line-end))
      (unless version
        (return-from %hrs-parse-head
          (values nil '(400 . "Bad Response"))))
      (multiple-value-bind (headers valid-p)
          (%parse-headers buffer (+ line-end 2) header-end)
        (unless valid-p
          (return-from %hrs-parse-head
            (values nil '(400 . "Bad Response"))))
        (let* ((transfer-values (%header-values headers "transfer-encoding"))
               (length-values (%header-values headers "content-length"))
               (length-members (%comma-members length-values))
               (lengths (mapcar #'%safe-parse-int length-members))
               (no-body-p (or (hrs-head-request-p parser)
                              (member status '(204 304)))))
          (cond
            ((and transfer-values length-values)
             (return-from %hrs-parse-head
               (values nil '(400 . "Bad Response"))))
            ((and transfer-values
                  (or (/= (length transfer-values) 1)
                      (not (string-equal
                            (%trim (first transfer-values)) "chunked"))))
             (return-from %hrs-parse-head
               (values nil '(400 . "Bad Response"))))
            ((and length-values
                  (or (some #'null lengths)
                      (not (every (lambda (number)
                                    (= number (first lengths)))
                                  (rest lengths)))))
             (return-from %hrs-parse-head
               (values nil '(400 . "Bad Response")))))
          (setf (hrs-status parser) status
                (hrs-reason parser) reason
                (hrs-version parser) version
                (hrs-headers parser) headers
                (hrs-keep-alive parser) (%keep-alive-p version headers))
          (cond
            ;; Informational responses do not settle Fetch. Reset for the final
            ;; response, which may already follow in the same socket read.
            ((< status 200)
             (setf (hrs-phase parser) :headers
                   (hrs-remaining parser) 0))
            (no-body-p
             (setf (hrs-phase parser) :fixed
                   (hrs-remaining parser) 0))
            (transfer-values
             (setf (hrs-phase parser) :chunk-size))
            (length-values
             (let ((content-length (first lengths)))
               (when (> content-length (hrs-max-body parser))
                 (return-from %hrs-parse-head
                   (values nil '(413 . "Payload Too Large"))))
               (setf (hrs-phase parser) :fixed
                     (hrs-remaining parser) content-length)))
            (t
             (setf (hrs-phase parser) :until-close
                   (hrs-reusable-p parser) nil)))
          (%hrs-clear-buffer parser)
          (values
           (make-http-response
            :status status :reason reason :version version
            :headers headers
            :body (make-array 0 :element-type '(unsigned-byte 8))
            :keep-alive (hrs-keep-alive parser))
           nil))))))

(defun %hrs-error (parser code reason)
  (setf (hrs-phase parser) :error
        (hrs-terminal-p parser) t
        (hrs-reusable-p parser) nil)
  (%hrs-clear-buffer parser)
  (cons :error (cons code reason)))

(defun %hrs-complete (parser)
  (setf (hrs-phase parser) :done
        (hrs-terminal-p parser) t)
  (%hrs-clear-buffer parser)
  (cons :complete nil))

(defun response-stream-feed (parser octets)
  "Consume OCTETS and return ordered (:HEADERS/:DATA/:COMPLETE/:ERROR) events.
At most the bounded header or chunk-framing state is retained between calls."
  (when (hrs-terminal-p parser)
    (return-from response-stream-feed nil))
  (let ((events '())
        (index 0)
        (end (length octets)))
    (labels ((emit (kind value)
               (push (cons kind value) events))
             (fail (code reason)
               (push (%hrs-error parser code reason) events)))
      (loop while (and (< index end) (not (hrs-terminal-p parser))) do
        (case (hrs-phase parser)
          (:headers
           (%hrs-buffer-push parser (aref octets index))
           (incf index)
           (cond
             ((> (fill-pointer (hrs-buf parser)) (hrs-max-header parser))
              (fail 431 "Response Header Fields Too Large"))
             ((%hrs-buffer-ends-with-p parser +http-head-end+)
              (multiple-value-bind (head error) (%hrs-parse-head parser)
                (if error
                    (fail (car error) (cdr error))
                    (unless (< (hrs-status parser) 200)
                      (emit :headers head)
                      (when (and (eq (hrs-phase parser) :fixed)
                                 (zerop (hrs-remaining parser)))
                        (push (%hrs-complete parser) events))))))))
          (:fixed
           (let ((count (min (hrs-remaining parser) (- end index))))
             (when (plusp count)
               (let ((next (+ (hrs-body-bytes parser) count)))
                 (when (> next (hrs-max-body parser))
                   (fail 413 "Payload Too Large"))
                 (unless (hrs-terminal-p parser)
                   (emit :data (subseq octets index (+ index count)))
                   (setf (hrs-body-bytes parser) next)
                   (decf (hrs-remaining parser) count)
                   (incf index count))))
             (when (and (not (hrs-terminal-p parser))
                        (zerop (hrs-remaining parser)))
               (push (%hrs-complete parser) events))))
          (:until-close
           (let ((count (- end index)))
             (when (plusp count)
               (let ((next (+ (hrs-body-bytes parser) count)))
                 (if (> next (hrs-max-body parser))
                     (fail 413 "Payload Too Large")
                     (progn
                       (emit :data (subseq octets index end))
                       (setf (hrs-body-bytes parser) next
                             index end)))))))
          (:chunk-size
           (%hrs-buffer-push parser (aref octets index))
           (incf index)
           (let ((line-length (fill-pointer (hrs-buf parser))))
             (cond
               ((or (> line-length (hrs-max-header parser))
                    (> (+ (hrs-framing-bytes parser) line-length)
                       (hrs-max-framing parser)))
                (fail 400 "Bad Response"))
               ((%hrs-buffer-ends-with-p parser +http-crlf+)
                (multiple-value-bind (size failure)
                    (%parse-bounded-chunk-size
                     (%octets->string (hrs-buf parser) 0 (- line-length 2))
                     (- (hrs-max-body parser) (hrs-body-bytes parser)))
                  (cond
                    ((eq failure :too-large)
                     (fail 413 "Payload Too Large"))
                    (failure
                     (fail 400 "Bad Response"))
                    ((not (%hrs-framing-add parser line-length))
                     (fail 400 "Bad Response"))
                    (t
                     (%hrs-clear-buffer parser)
                     (setf (hrs-remaining parser) size
                           (hrs-phase parser)
                           (if (zerop size) :chunk-trailers :chunk-data)))))))))
          (:chunk-data
           (let ((count (min (hrs-remaining parser) (- end index))))
             (when (plusp count)
               (emit :data (subseq octets index (+ index count)))
               (incf (hrs-body-bytes parser) count)
               (decf (hrs-remaining parser) count)
               (incf index count))
             (when (zerop (hrs-remaining parser))
               (%hrs-clear-buffer parser)
               (setf (hrs-phase parser) :chunk-data-crlf))))
          (:chunk-data-crlf
           (%hrs-buffer-push parser (aref octets index))
           (incf index)
           (let ((length (fill-pointer (hrs-buf parser))))
             (cond
               ((and (= length 1)
                     (/= (aref (hrs-buf parser) 0) +cr+))
                (fail 400 "Bad Response"))
               ((= length 2)
                (if (and (= (aref (hrs-buf parser) 0) +cr+)
                         (= (aref (hrs-buf parser) 1) +lf+)
                         (%hrs-framing-add parser 2))
                    (progn
                      (%hrs-clear-buffer parser)
                      (setf (hrs-phase parser) :chunk-size))
                    (fail 400 "Bad Response"))))))
          (:chunk-trailers
           (%hrs-buffer-push parser (aref octets index))
           (incf index)
           (let ((length (fill-pointer (hrs-buf parser))))
             (cond
               ((> length (hrs-max-header parser))
                (fail 431 "Response Header Fields Too Large"))
               ((> (+ (hrs-framing-bytes parser) length)
                   (hrs-max-framing parser))
                (fail 400 "Bad Response"))
               ((or (and (= length 2)
                         (%hrs-buffer-ends-with-p parser +http-crlf+))
                    (%hrs-buffer-ends-with-p parser +http-head-end+))
                (unless (%hrs-framing-add parser length)
                  (fail 400 "Bad Response"))
                (unless (hrs-terminal-p parser)
                  ;; Validate non-empty trailers with the same header grammar.
                  (when (> length 2)
                    (multiple-value-bind (ignored valid-p)
                        (%parse-headers (hrs-buf parser) 0 (- length 4))
                      (declare (ignore ignored))
                      (unless valid-p (fail 400 "Bad Response"))))
                  (unless (hrs-terminal-p parser)
                    (push (%hrs-complete parser) events)))))))
          (otherwise
           (setf index end))))
      ;; A complete response followed by bytes in the same read cannot be safely
      ;; returned to a sequential-request pool: Clun never pipelines requests.
      (when (and (hrs-terminal-p parser) (< index end))
        (setf (hrs-reusable-p parser) nil))
      (nreverse events))))

(defun response-stream-reusable-p (parser)
  "True only after a cleanly framed response with no unread or trailing bytes."
  (and (hrs-terminal-p parser)
       (eq (hrs-phase parser) :done)
       (hrs-reusable-p parser)
       (hrs-keep-alive parser)))

(defun response-stream-finish (parser)
  "Finish PARSER at clean EOF and return terminal events.
Only an EOF-framed response may complete here; every other incomplete state fails."
  (cond
    ((hrs-terminal-p parser) nil)
    ((eq (hrs-phase parser) :until-close)
     (list (%hrs-complete parser)))
    (t
     (list (%hrs-error parser 400 "Connection closed before complete response")))))
