;;;; dns.lisp -- bounded pure-Common-Lisp DNS A/AAAA resolver (Phase 28).

(in-package :clun.net)

(defconstant +dns-type-a+ 1)
(defconstant +dns-type-cname+ 5)
(defconstant +dns-type-aaaa+ 28)
(defconstant +dns-class-in+ 1)
(defconstant +dns-max-message-bytes+ 65535)
(defconstant +dns-max-records+ 128)
(defconstant +dns-max-name-depth+ 16)
(defconstant +dns-max-cname-depth+ 8)
(defconstant +dns-cache-capacity+ 256)
(defconstant +dns-cancel-poll-ms+ 25)

(define-condition dns-error (socket-open-error)
  ((message :initarg :message :reader dns-error-message))
  (:report (lambda (condition stream)
             (format stream "~a: ~a"
                     (socket-open-error-code condition)
                     (dns-error-message condition)))))

(defstruct (dns-address (:constructor make-dns-address
                         (&key text ipv6-p (ttl 0))))
  (text "" :type string)
  (ipv6-p nil :type boolean)
  (ttl 0 :type (integer 0 *)))

(defstruct (dns-cache-entry (:constructor %make-dns-cache-entry))
  addresses
  (expires-at 0 :type integer))

(defvar *dns-cache* (make-hash-table :test 'equal))
(defvar *dns-cache-lock* (sb-thread:make-mutex :name "clun-dns-cache"))
(defvar *dns-id* 0)
(defvar *dns-id-lock* (sb-thread:make-mutex :name "clun-dns-id"))

(defun %monotonic-ms ()
  (truncate (* 1000 (get-internal-real-time)) internal-time-units-per-second))

(defun %dns-fail (code control &rest arguments)
  (error 'dns-error :code code :op "resolve"
                    :message (apply #'format nil control arguments)))

(defun %dns-check-cancelled (cancelled-p)
  (when (and cancelled-p (funcall cancelled-p))
    (%dns-fail "ECANCELED" "DNS resolution was cancelled")))

(defun %dns-u16 (octets offset)
  (when (> (+ offset 2) (length octets))
    (%dns-fail "EBADRESP" "truncated 16-bit DNS field"))
  (logior (ash (aref octets offset) 8)
          (aref octets (1+ offset))))

(defun %dns-u32 (octets offset)
  (when (> (+ offset 4) (length octets))
    (%dns-fail "EBADRESP" "truncated 32-bit DNS field"))
  (logior (ash (aref octets offset) 24)
          (ash (aref octets (+ offset 1)) 16)
          (ash (aref octets (+ offset 2)) 8)
          (aref octets (+ offset 3))))

(defun %dns-set-u16 (octets offset value)
  (setf (aref octets offset) (ldb (byte 8 8) value)
        (aref octets (1+ offset)) (ldb (byte 8 0) value))
  octets)

(defun %dns-next-id ()
  (sb-thread:with-mutex (*dns-id-lock*)
    (setf *dns-id* (logand #xffff (1+ *dns-id*)))))

(defun %dns-normalize-name (host)
  (let* ((trimmed (string-downcase
                   (string-trim '(#\Space #\Tab #\Return #\Linefeed) host)))
         (name (if (and (plusp (length trimmed))
                        (char= (char trimmed (1- (length trimmed))) #\.))
                   (subseq trimmed 0 (1- (length trimmed)))
                   trimmed)))
    (when (or (zerop (length name)) (> (length name) 253))
      (%dns-fail "EINVAL" "invalid DNS name length"))
    name))

(defun %dns-labels (name)
  (let ((labels '()) (start 0) (length (length name)))
    (loop for end = (or (position #\. name :start start) length)
          for label = (subseq name start end)
          do (when (or (zerop (length label)) (> (length label) 63))
               (%dns-fail "EINVAL" "invalid DNS label in ~a" name))
             (unless (every (lambda (character)
                              (let ((code (char-code character)))
                                (and (<= 1 code 127)
                                     (not (member character
                                                  '(#\Space #\Tab #\Return #\Linefeed))))))
                            label)
               (%dns-fail "EINVAL" "non-ASCII DNS name is unsupported"))
             (push label labels)
          when (= end length) do (return)
          do (setf start (1+ end)))
    (nreverse labels)))

(defun %dns-encode-query (name qtype &optional (id (%dns-next-id)))
  "Encode one recursive IN query. Returns (values packet transaction-id)."
  (let* ((normalized (%dns-normalize-name name))
         (labels (%dns-labels normalized))
         (size (+ 12 1 4 (reduce #'+ labels :key #'length
                                 :initial-value (length labels))))
         (packet (make-array size :element-type '(unsigned-byte 8)
                                  :initial-element 0))
         (offset 12))
    (%dns-set-u16 packet 0 id)
    (%dns-set-u16 packet 2 #x0100)
    (%dns-set-u16 packet 4 1)
    (dolist (label labels)
      (setf (aref packet offset) (length label))
      (incf offset)
      (dotimes (index (length label))
        (setf (aref packet offset) (char-code (char label index)))
        (incf offset)))
    (incf offset)
    (%dns-set-u16 packet offset qtype)
    (%dns-set-u16 packet (+ offset 2) +dns-class-in+)
    (values packet id)))

(defun %dns-read-name (packet offset)
  "Decode one possibly-compressed DNS name. Returns (values name next-offset)."
  (labels ((decode (position depth visited)
             (when (or (>= depth +dns-max-name-depth+)
                       (>= position (length packet)))
               (%dns-fail "EBADRESP" "invalid compressed DNS name"))
             (when (member position visited)
               (%dns-fail "EBADRESP" "DNS compression pointer loop"))
             (let ((length-octet (aref packet position)))
               (cond
                 ((zerop length-octet) (values '() (1+ position)))
                 ((= (logand length-octet #xc0) #xc0)
                  (when (>= (1+ position) (length packet))
                    (%dns-fail "EBADRESP" "truncated DNS compression pointer"))
                  (let ((target (logior (ash (logand length-octet #x3f) 8)
                                        (aref packet (1+ position)))))
                    (when (>= target (length packet))
                      (%dns-fail "EBADRESP" "out-of-range DNS compression pointer"))
                    (multiple-value-bind (labels ignored)
                        (decode target (1+ depth) (cons position visited))
                      (declare (ignore ignored))
                      (values labels (+ position 2)))))
                 ((not (zerop (logand length-octet #xc0)))
                  (%dns-fail "EBADRESP" "reserved DNS label encoding"))
                 (t
                  (when (> length-octet 63)
                    (%dns-fail "EBADRESP" "oversized DNS label"))
                  (let ((end (+ position 1 length-octet)))
                    (when (> end (length packet))
                      (%dns-fail "EBADRESP" "truncated DNS label"))
                    (let ((label (make-string length-octet)))
                      (dotimes (index length-octet)
                        (let ((code (aref packet (+ position 1 index))))
                          (when (or (zerop code) (> code 127))
                            (%dns-fail "EBADRESP" "non-ASCII DNS response label"))
                          (setf (char label index) (code-char code))))
                      (multiple-value-bind (tail next)
                          (decode end (1+ depth) (cons position visited))
                        (values (cons (string-downcase label) tail) next)))))))))
    (multiple-value-bind (labels next) (decode offset 0 '())
      (when (or (> (length labels) 128)
                (> (reduce #'+ labels :key #'length
                           :initial-value (max 0 (1- (length labels))))
                   253))
        (%dns-fail "EBADRESP" "decoded DNS name exceeds bounds"))
      (values (format nil "~{~a~^.~}" labels) next))))

(defun %dns-ipv4-text (packet offset)
  (format nil "~d.~d.~d.~d"
          (aref packet offset) (aref packet (+ offset 1))
          (aref packet (+ offset 2)) (aref packet (+ offset 3))))

(defun %dns-ipv6-text (packet offset)
  (let* ((groups (coerce (loop for index from 0 below 16 by 2
                               collect (%dns-u16 packet (+ offset index)))
                         'vector))
         (best-start nil)
         (best-length 0)
         (run-start nil))
    ;; RFC 5952-style rendering: compress the first longest zero run, but only
    ;; when it spans at least two 16-bit groups.
    (dotimes (index 9)
      (if (and (< index 8) (zerop (aref groups index)))
          (unless run-start (setf run-start index))
          (when run-start
            (let ((run-length (- index run-start)))
              (when (> run-length best-length)
                (setf best-start run-start
                      best-length run-length)))
            (setf run-start nil))))
    (string-downcase
     (if (< best-length 2)
         (format nil "~{~x~^:~}" (coerce groups 'list))
         (format nil "~{~x~^:~}::~{~x~^:~}"
                 (coerce (subseq groups 0 best-start) 'list)
                 (coerce (subseq groups (+ best-start best-length)) 'list))))))

(defun %dns-rcode-code (rcode)
  (case rcode
    (1 "EBADRESP")
    (2 "EAI_AGAIN")
    (3 "ENOTFOUND")
    (4 "ENOTSUP")
    (5 "EACCES")
    (t "EAI_FAIL")))

(defun %dns-parse-response (packet expected-id query-name qtype)
  "Parse a bounded DNS response. Returns addresses, minimum TTL, canonical name and TC flag."
  (when (or (< (length packet) 12) (> (length packet) +dns-max-message-bytes+))
    (%dns-fail "EBADRESP" "invalid DNS response length"))
  (unless (= (%dns-u16 packet 0) expected-id)
    (%dns-fail "EBADRESP" "DNS transaction ID mismatch"))
  (let* ((flags (%dns-u16 packet 2))
         (rcode (logand flags #x000f))
         (truncated (not (zerop (logand flags #x0200))))
         (qdcount (%dns-u16 packet 4))
         (ancount (%dns-u16 packet 6))
         (nscount (%dns-u16 packet 8))
         (arcount (%dns-u16 packet 10))
         (record-count (+ ancount nscount arcount))
         (offset 12)
         (cnames (make-hash-table :test 'equal))
         (records '()))
    (unless (not (zerop (logand flags #x8000)))
      (%dns-fail "EBADRESP" "DNS packet is not a response"))
    (unless (zerop (logand flags #x7800))
      (%dns-fail "EBADRESP" "unsupported DNS opcode"))
    (unless (zerop rcode)
      (%dns-fail (%dns-rcode-code rcode) "DNS server returned rcode ~d" rcode))
    (when (or (zerop qdcount) (> qdcount 4) (> record-count +dns-max-records+))
      (%dns-fail "EBADRESP" "DNS section counts exceed bounds"))
    ;; A UDP response with TC set is not safe to parse as a partial resource-record
    ;; stream. Its authenticated transaction/header are enough to trigger TCP retry.
    (when truncated
      (return-from %dns-parse-response
        (values '() 0 (%dns-normalize-name query-name) t)))
    (dotimes (question qdcount)
      (multiple-value-bind (name next) (%dns-read-name packet offset)
        (setf offset next)
        (when (> (+ offset 4) (length packet))
          (%dns-fail "EBADRESP" "truncated DNS question"))
        (when (zerop question)
          (unless (and (string= name (%dns-normalize-name query-name))
                       (= (%dns-u16 packet offset) qtype)
                       (= (%dns-u16 packet (+ offset 2)) +dns-class-in+))
            (%dns-fail "EBADRESP" "DNS response question mismatch")))
        (incf offset 4)))
    (dotimes (index record-count)
      (declare (ignore index))
      (multiple-value-bind (owner next) (%dns-read-name packet offset)
        (setf offset next)
        (when (> (+ offset 10) (length packet))
          (%dns-fail "EBADRESP" "truncated DNS resource record"))
        (let* ((type (%dns-u16 packet offset))
               (class (%dns-u16 packet (+ offset 2)))
               (ttl (%dns-u32 packet (+ offset 4)))
               (rdlength (%dns-u16 packet (+ offset 8)))
               (rdata (+ offset 10))
               (end (+ rdata rdlength)))
          (when (> end (length packet))
            (%dns-fail "EBADRESP" "DNS RDATA exceeds packet"))
          (when (= class +dns-class-in+)
            (cond
              ((and (= type +dns-type-a+) (= rdlength 4))
               (push (list owner +dns-type-a+ (%dns-ipv4-text packet rdata) ttl)
                     records))
              ((and (= type +dns-type-aaaa+) (= rdlength 16))
               (push (list owner +dns-type-aaaa+ (%dns-ipv6-text packet rdata) ttl)
                     records))
              ((= type +dns-type-cname+)
               (multiple-value-bind (target next-rdata) (%dns-read-name packet rdata)
                 (when (> next-rdata end)
                   (%dns-fail "EBADRESP" "CNAME exceeds its RDATA"))
                 (setf (gethash owner cnames) (cons target ttl))))))
          (setf offset end))))
    (let ((canonical (%dns-normalize-name query-name))
          (minimum-ttl nil))
      (dotimes (depth +dns-max-cname-depth+)
        (declare (ignore depth))
        (let ((alias (gethash canonical cnames)))
          (unless alias (return))
          (setf minimum-ttl (if minimum-ttl (min minimum-ttl (cdr alias)) (cdr alias))
                canonical (car alias))))
      (when (gethash canonical cnames)
        (%dns-fail "EBADRESP" "DNS CNAME chain exceeds bounds"))
      (let ((addresses
              (loop for (owner type text ttl) in (nreverse records)
                    when (and (string= owner canonical) (= type qtype))
                      collect (make-dns-address :text text
                                                :ipv6-p (= type +dns-type-aaaa+)
                                                :ttl ttl))))
        (dolist (address addresses)
          (setf minimum-ttl
                (if minimum-ttl
                    (min minimum-ttl (dns-address-ttl address))
                    (dns-address-ttl address))))
        (values addresses (or minimum-ttl 0) canonical truncated)))))

(defun %dns-nameserver-native (nameserver)
  (if (find #\: nameserver)
      (values 'sb-bsd-sockets:inet6-socket
              (sb-bsd-sockets:make-inet6-address nameserver))
      (values 'sb-bsd-sockets:inet-socket
              (sb-bsd-sockets:make-inet-address nameserver))))

(defun %dns-wait (socket direction deadline-ms &optional cancelled-p)
  "Wait for socket readiness while making worker cancellation promptly observable."
  (loop
    (%dns-check-cancelled cancelled-p)
    (let ((remaining (- deadline-ms (%monotonic-ms))))
      (unless (plusp remaining) (return nil))
      (when (sb-sys:wait-until-fd-usable
             (sb-bsd-sockets:socket-file-descriptor socket)
             direction
             (/ (min remaining +dns-cancel-poll-ms+) 1000.0d0)
             nil)
        (%dns-check-cancelled cancelled-p)
        (return t)))))

(defun %dns-send-all (socket octets deadline-ms &optional cancelled-p)
  (loop with offset = 0
        while (< offset (length octets)) do
          (unless (%dns-wait socket :output deadline-ms cancelled-p)
            (%dns-fail "ETIMEOUT" "DNS write timed out"))
          (let ((sent (handler-case
                          (sb-bsd-sockets:socket-send
                           socket
                           (if (zerop offset) octets
                               (make-array (- (length octets) offset)
                                           :element-type '(unsigned-byte 8)
                                           :displaced-to octets
                                           :displaced-index-offset offset))
                           (- (length octets) offset))
                        (sb-bsd-sockets:interrupted-error () 0))))
            (when (or (null sent) (zerop sent))
              (unless (%dns-wait socket :output deadline-ms cancelled-p)
                (%dns-fail "ETIMEOUT" "DNS write timed out")))
            (incf offset (or sent 0))))
  octets)

(defun %dns-recv-exact (socket count deadline-ms &optional cancelled-p)
  (let ((result (make-array count :element-type '(unsigned-byte 8)))
        (offset 0))
    (loop while (< offset count) do
      (unless (%dns-wait socket :input deadline-ms cancelled-p)
        (%dns-fail "ETIMEOUT" "DNS read timed out"))
      (let ((buffer (make-array (- count offset) :element-type '(unsigned-byte 8))))
        (multiple-value-bind (ignored received)
            (sb-bsd-sockets:socket-receive socket buffer (length buffer)
                                           :element-type '(unsigned-byte 8))
          (declare (ignore ignored))
          (when (or (null received) (zerop received))
            (%dns-fail "ECONNRESET" "DNS TCP peer closed early"))
          (replace result buffer :start1 offset :end2 received)
          (incf offset received))))
    result))

(defun %dns-udp-query (nameserver port packet timeout-ms &optional cancelled-p)
  (multiple-value-bind (socket-class native) (%dns-nameserver-native nameserver)
    (let ((socket (make-instance socket-class :type :datagram :protocol :udp))
          (deadline (+ (%monotonic-ms) timeout-ms)))
      (unwind-protect
           (progn
             (setf (sb-bsd-sockets:non-blocking-mode socket) t)
             (handler-case (sb-bsd-sockets:socket-connect socket native port)
               (sb-bsd-sockets:operation-in-progress ()))
             (%dns-send-all socket packet deadline cancelled-p)
             (unless (%dns-wait socket :input deadline cancelled-p)
               (%dns-fail "ETIMEOUT" "DNS UDP query timed out"))
             (let ((buffer (make-array +dns-max-message-bytes+
                                       :element-type '(unsigned-byte 8))))
               (multiple-value-bind (ignored count)
                   (sb-bsd-sockets:socket-receive
                    socket buffer (length buffer) :element-type '(unsigned-byte 8))
                 (declare (ignore ignored))
                 (unless (and count (plusp count))
                   (%dns-fail "EBADRESP" "empty DNS UDP response"))
                 (subseq buffer 0 count))))
        (ignore-errors (sb-bsd-sockets:socket-close socket :abort t))))))

(defun %dns-tcp-query (nameserver port packet timeout-ms &optional cancelled-p)
  (multiple-value-bind (socket-class native) (%dns-nameserver-native nameserver)
    (let ((socket (make-instance socket-class :type :stream :protocol :tcp))
          (deadline (+ (%monotonic-ms) timeout-ms)))
      (unwind-protect
           (progn
             (setf (sb-bsd-sockets:non-blocking-mode socket) t)
             (handler-case (sb-bsd-sockets:socket-connect socket native port)
               (sb-bsd-sockets:operation-in-progress ()))
             (unless (%dns-wait socket :output deadline cancelled-p)
               (%dns-fail "ETIMEOUT" "DNS TCP connect timed out"))
             (unless (zerop (sb-bsd-sockets:sockopt-error socket))
               (%dns-fail "ECONNREFUSED" "DNS TCP connect failed"))
             (let ((framed (make-array (+ 2 (length packet))
                                       :element-type '(unsigned-byte 8))))
               (%dns-set-u16 framed 0 (length packet))
               (replace framed packet :start1 2)
               (%dns-send-all socket framed deadline cancelled-p))
             (let* ((head (%dns-recv-exact socket 2 deadline cancelled-p))
                    (length (%dns-u16 head 0)))
               (when (or (zerop length) (> length +dns-max-message-bytes+))
                 (%dns-fail "EBADRESP" "invalid DNS TCP frame length"))
               (%dns-recv-exact socket length deadline cancelled-p)))
        (ignore-errors (sb-bsd-sockets:socket-close socket :abort t))))))

(defun %dns-read-resolv-conf (&optional
                                (path (or (sb-ext:posix-getenv "CLUN_RESOLV_CONF")
                                          "/etc/resolv.conf")))
  (let ((servers '()))
    (when (probe-file path)
      (with-open-file (stream path :direction :input :external-format :utf-8)
        (loop for line = (read-line stream nil nil)
              while line do
                (let* ((comment (or (position #\# line) (position #\; line)
                                    (length line)))
                       (words (remove "" (uiop:split-string
                                           (subseq line 0 comment)
                                           :separator '(#\Space #\Tab))
                                      :test #'string=)))
                  (when (and (>= (length words) 2)
                             (string-equal (first words) "nameserver"))
                    (push (second words) servers))))))
    (nreverse (remove-duplicates servers :test #'string=))))

(defun %dns-query-type
    (name qtype nameservers port timeout-ms &optional (depth 0) cancelled-p)
  (when (> depth +dns-max-cname-depth+)
    (%dns-fail "EBADRESP" "DNS CNAME recursion exceeds bounds"))
  (let ((last-error nil))
    (dolist (nameserver nameservers)
      (dotimes (attempt 2)
        (declare (ignore attempt))
        (handler-case
            (multiple-value-bind (query id) (%dns-encode-query name qtype)
              (let ((response
                      (%dns-udp-query nameserver port query timeout-ms
                                      cancelled-p)))
                (multiple-value-bind (addresses ttl canonical truncated)
                    (%dns-parse-response response id name qtype)
                  (when truncated
                    (setf response
                          (%dns-tcp-query nameserver port query timeout-ms
                                          cancelled-p))
                    (multiple-value-setq (addresses ttl canonical truncated)
                      (%dns-parse-response response id name qtype))
                    (when truncated
                      (%dns-fail "EBADRESP" "truncated DNS TCP response")))
                  (cond
                    (addresses (return-from %dns-query-type (values addresses ttl)))
                    ((not (string= canonical (%dns-normalize-name name)))
                     (return-from %dns-query-type
                       (%dns-query-type canonical qtype nameservers port timeout-ms
                                        (1+ depth) cancelled-p)))
                    (t (return-from %dns-query-type (values '() ttl)))))))
          (dns-error (condition)
            (when (string= (socket-open-error-code condition) "ECANCELED")
              (error condition))
            (setf last-error condition)
            (when (member (socket-open-error-code condition)
                          '("ENOTFOUND" "EINVAL" "ENOTSUP" "EACCES")
                          :test #'string=)
              (return))))))
    (if last-error
        (error last-error)
        (%dns-fail "ENOTFOUND" "no DNS answer for ~a" name))))

(defun %interleave-dns-addresses (ipv6 ipv4)
  "Interleave address families while preserving each DNS answer's order."
  (let ((result '()))
    (loop while (or ipv6 ipv4) do
      (when ipv6 (push (pop ipv6) result))
      (when ipv4 (push (pop ipv4) result)))
    (nreverse result)))

(defun %valid-ipv4-literal-p (host)
  (let ((parts (uiop:split-string host :separator '(#\.))))
    (and (= (length parts) 4)
         (every (lambda (part)
                  (and (plusp (length part))
                       (every #'digit-char-p part)
                       (let ((value (ignore-errors (parse-integer part))))
                         (and value (<= 0 value 255)))))
                parts))))

(defun %ipv6-literal-p (host)
  (and (find #\: host)
       (handler-case
           (progn (sb-bsd-sockets:make-inet6-address host) t)
         (error () nil))))

(defun %dns-unbracket-host (host)
  (if (and (> (length host) 1)
           (char= (char host 0) #\[)
           (char= (char host (1- (length host))) #\]))
      (subseq host 1 (1- (length host)))
      host))

(defun %dns-now-seconds ()
  (truncate (get-internal-real-time) internal-time-units-per-second))

(defun %dns-copy-addresses (addresses)
  (mapcar (lambda (address)
            (make-dns-address :text (dns-address-text address)
                              :ipv6-p (dns-address-ipv6-p address)
                              :ttl (dns-address-ttl address)))
          addresses))

(defun %dns-cache-get (name)
  (sb-thread:with-mutex (*dns-cache-lock*)
    (let ((entry (gethash name *dns-cache*)))
      (when entry
        (if (> (dns-cache-entry-expires-at entry) (%dns-now-seconds))
            (%dns-copy-addresses (dns-cache-entry-addresses entry))
            (remhash name *dns-cache*))))))

(defun %dns-cache-put (name addresses ttl)
  (let ((ttl (max 1 (min ttl 3600))))
    (sb-thread:with-mutex (*dns-cache-lock*)
      (when (>= (hash-table-count *dns-cache*) +dns-cache-capacity+)
        (let ((oldest-key nil) (oldest-time most-positive-fixnum))
          (maphash (lambda (key entry)
                     (when (< (dns-cache-entry-expires-at entry) oldest-time)
                       (setf oldest-key key
                             oldest-time (dns-cache-entry-expires-at entry))))
                   *dns-cache*)
          (when oldest-key (remhash oldest-key *dns-cache*))))
      (setf (gethash name *dns-cache*)
            (%make-dns-cache-entry
             :addresses (%dns-copy-addresses addresses)
             :expires-at (+ (%dns-now-seconds) ttl)))))
  addresses)

(defun resolve-hostname-all
    (host &key nameservers (port 53) (timeout-ms 1500) (use-cache t)
               cancelled-p)
  "Resolve HOST to interleaved AAAA/A candidates without libc name-service calls."
  (let ((host (%dns-unbracket-host (or host "127.0.0.1"))))
    (%dns-check-cancelled cancelled-p)
    (cond
      ((%valid-ipv4-literal-p host)
       (list (make-dns-address :text host :ipv6-p nil)))
      ((%ipv6-literal-p host)
       (list (make-dns-address :text host :ipv6-p t)))
      ((string-equal host "localhost")
       (list (make-dns-address :text "::1" :ipv6-p t)
             (make-dns-address :text "127.0.0.1" :ipv6-p nil)))
      (t
       (let* ((name (%dns-normalize-name host))
              (cached (and use-cache (%dns-cache-get name))))
         (when cached (return-from resolve-hostname-all cached))
         (let ((servers (or nameservers (%dns-read-resolv-conf))))
           (unless servers
             (%dns-fail "ENOTFOUND" "no DNS nameserver is configured"))
           (let ((error6 nil) (error4 nil))
             (multiple-value-bind (ipv6 ttl6)
                 (handler-case
                     (%dns-query-type name +dns-type-aaaa+ servers port timeout-ms
                                      0 cancelled-p)
                   (dns-error (condition)
                     (when (string= (socket-open-error-code condition) "ECANCELED")
                       (error condition))
                     (setf error6 condition)
                     (values '() 0)))
               (multiple-value-bind (ipv4 ttl4)
                   (handler-case
                       (%dns-query-type name +dns-type-a+ servers port timeout-ms
                                        0 cancelled-p)
                     (dns-error (condition)
                       (when (string= (socket-open-error-code condition) "ECANCELED")
                         (error condition))
                       (setf error4 condition)
                       (values '() 0)))
               (let ((addresses
                       (remove-duplicates (%interleave-dns-addresses ipv6 ipv4)
                                          :test #'string=
                                          :key #'dns-address-text)))
                 (unless addresses
                   (error (or error4 error6
                              (make-condition 'dns-error :code "ENOTFOUND"
                                  :op "resolve"
                                  :message (format nil "no A or AAAA records for ~a"
                                                   name)))))
                 (when use-cache
                   (%dns-cache-put name addresses
                                   (cond ((and (plusp ttl6) (plusp ttl4))
                                          (min ttl6 ttl4))
                                         ((plusp ttl6) ttl6)
                                         ((plusp ttl4) ttl4)
                                         (t 1))))
                 addresses))))))))))

(defun resolve-hostname (host)
  "Compatibility helper returning the first Happy-Eyeballs candidate as text."
  (dns-address-text (first (resolve-hostname-all host))))
