;;;; websocket.lisp — Phase 51: pure-CL RFC 6455 handshake + framing + deflate.
;;;; Server handshake (Sec-WebSocket-Accept), frame encode/decode for text,
;;;; binary, ping, pong, close, fragmentation helpers, and bounded
;;;; permessage-deflate inflate (chipz). Pub/Sub and client live in runtime.
;;;; See docs/design/phase-51.md. No foreign libraries.

(in-package :clun.websocket)

;;; --- RFC 6455 opcodes -------------------------------------------------------

(defconstant +opcode-continuation+ #x0)
(defconstant +opcode-text+         #x1)
(defconstant +opcode-binary+       #x2)
(defconstant +opcode-close+        #x8)
(defconstant +opcode-ping+         #x9)
(defconstant +opcode-pong+         #xA)

;; String constants use DEFPARAMETER: SBCL DEFCONSTANT rejects non-EQL reload of
;; equal string literals (compile-time vs load-time objects).
(defparameter +ws-guid+ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  "RFC 6455 §1.3 accept-key material.")

(defconstant +default-max-payload-bytes+ #.(* 16 1024 1024)
  "Bun-shaped default max message size (16 MiB).")

(defconstant +default-backpressure-limit+ #.(* 16 1024 1024)
  "Bun-shaped default per-connection buffered send budget.")

(defconstant +max-control-payload+ 125
  "RFC 6455: control frames must have payload length ≤ 125.")

(defparameter +base64-alphabet+
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

;;; --- Conditions -------------------------------------------------------------

(define-condition websocket-error (error)
  ((message :initarg :message :reader websocket-error-message))
  (:report (lambda (c s)
             (format s "WebSocket error: ~a" (websocket-error-message c)))))

(define-condition websocket-unsupported (websocket-error)
  ()
  (:report (lambda (c s)
             (format s "~a" (websocket-error-message c)))))

(define-condition websocket-protocol-error (websocket-error)
  ()
  (:report (lambda (c s)
             (format s "WebSocket protocol error: ~a"
                     (websocket-error-message c)))))

(defun websocket-not-implemented-message (&optional (surface "WebSocket"))
  "Stable user-facing text for surfaces that remain intentionally absent."
  (format nil "~a is not implemented in Clun (Phase 51). ~
               See docs/design/phase-51.md."
          surface))

(defun signal-websocket-unsupported (&optional (surface "WebSocket"))
  "Signal WEBSOCKET-UNSUPPORTED for unimplemented Phase 51 surfaces."
  (error 'websocket-unsupported
         :message (websocket-not-implemented-message surface)))

(defun %protocol-error (fmt &rest args)
  (error 'websocket-protocol-error
         :message (apply #'format nil fmt args)))

;;; --- Frame / handler type scaffolds ----------------------------------------

(defstruct (ws-frame
            (:constructor make-ws-frame)
            (:conc-name ws-frame-))
  "RFC 6455 frame header + payload."
  (fin t :type boolean)
  (rsv1 nil :type boolean)
  (rsv2 nil :type boolean)
  (rsv3 nil :type boolean)
  (opcode 0 :type (integer 0 15))
  (masked nil :type boolean)
  (payload (make-array 0 :element-type '(unsigned-byte 8))
           :type (simple-array (unsigned-byte 8) (*)))
  (mask-key nil))

(defstruct (ws-handler-options
            (:constructor make-ws-handler-options)
            (:conc-name ws-handler-options-))
  "Mirror of Bun WebSocketHandler option slots for the serve compile path."
  (max-payload-length +default-max-payload-bytes+ :type (integer 0 *))
  (backpressure-limit +default-backpressure-limit+ :type (integer 0 *))
  (close-on-backpressure-limit nil :type boolean)
  (idle-timeout-seconds 120 :type (integer 0 *))
  (publish-to-self nil :type boolean)
  (send-pings t :type boolean)
  (permessage-deflate nil)
  open
  message
  close
  ping
  pong
  drain)

;;; --- Octet / base64 helpers -------------------------------------------------

(defun %ascii-octets (string)
  (let ((v (make-array (length string) :element-type '(unsigned-byte 8))))
    (dotimes (i (length string) v)
      (setf (aref v i) (logand (char-code (char string i)) #xff)))))

(defun %base64-encode (octets)
  "Standard base64 (with padding) over a byte vector. Used for accept keys."
  (let* ((length (length octets))
         (output-length (* 4 (ceiling length 3)))
         (output (make-string output-length))
         (out 0)
         (alphabet +base64-alphabet+))
    (loop for start from 0 below length by 3
          for remaining = (- length start)
          for count = (min remaining 3)
          for first = (aref octets start)
          for second = (if (> count 1) (aref octets (1+ start)) 0)
          for third = (if (> count 2) (aref octets (+ start 2)) 0)
          do (setf (char output out)
                   (char alphabet (ldb (byte 6 2) first))
                   (char output (1+ out))
                   (char alphabet
                         (logior (ash (logand first #x03) 4)
                                 (ldb (byte 4 4) second))))
             (incf out 2)
             (when (> count 1)
               (setf (char output out)
                     (char alphabet
                           (logior (ash (logand second #x0f) 2)
                                   (ldb (byte 2 6) third))))
               (incf out))
             (when (> count 2)
               (setf (char output out)
                     (char alphabet (logand third #x3f)))
               (incf out))
             (loop repeat (- 3 count)
                   do (setf (char output out) #\=)
                      (incf out)))
    output))

(defun mask-payload (payload mask-key &key (start 0) end)
  "XOR PAYLOAD[START..END) with the 4-byte MASK-KEY. Returns a fresh vector."
  (let* ((end (or end (length payload)))
         (len (- end start))
         (out (make-array len :element-type '(unsigned-byte 8)))
         (key (if (and (typep mask-key '(simple-array (unsigned-byte 8) (*)))
                       (= (length mask-key) 4))
                  mask-key
                  (%protocol-error "mask key must be exactly 4 bytes"))))
    (dotimes (i len out)
      (setf (aref out i)
            (logxor (aref payload (+ start i))
                    (aref key (mod i 4)))))))

;;; --- Handshake --------------------------------------------------------------

(defun handshake-accept-key (sec-websocket-key)
  "RFC 6455 §1.3: base64(SHA-1(key || GUID)). KEY is the Sec-WebSocket-Key value."
  (unless (and (stringp sec-websocket-key)
               (plusp (length sec-websocket-key)))
    (%protocol-error "Sec-WebSocket-Key must be a non-empty string"))
  (let* ((material (concatenate 'string sec-websocket-key +ws-guid+))
         (octets (%ascii-octets material))
         (digest (crypto:digest-sequence :sha1 octets)))
    (%base64-encode digest)))

(defun %header-value (headers name)
  "Return the first case-insensitive header value from an alist, or NIL."
  (cdr (assoc name headers :test #'string-equal)))

(defun %header-token-member-p (field token)
  "True when TOKEN appears as a comma-separated HTTP token in FIELD."
  (when field
    (loop with start = 0
          with needle = (string-downcase token)
          for comma = (position #\, field :start start)
          for part = (string-trim '(#\Space #\Tab) (subseq field start comma))
          thereis (string-equal part needle)
          while comma
          do (setf start (1+ comma)))))

(defun websocket-upgrade-request-p (headers)
  "True when HEADERS (alist) look like a valid WebSocket opening handshake."
  (let ((upgrade (%header-value headers "upgrade"))
        (connection (%header-value headers "connection"))
        (key (%header-value headers "sec-websocket-key"))
        (version (%header-value headers "sec-websocket-version")))
    (and upgrade
         (string-equal (string-trim '(#\Space #\Tab) upgrade) "websocket")
         connection
         (%header-token-member-p connection "Upgrade")
         key
         (plusp (length (string-trim '(#\Space #\Tab) key)))
         version
         (string= (string-trim '(#\Space #\Tab) version) "13"))))

(defun opening-handshake-response (sec-websocket-key &key protocol extensions)
  "HTTP/1.1 101 Switching Protocols response octets for KEY."
  (let* ((accept (handshake-accept-key
                  (string-trim '(#\Space #\Tab) sec-websocket-key)))
         (crlf (format nil "~c~c" #\Return #\Newline))
         (parts
           (list "HTTP/1.1 101 Switching Protocols" crlf
                 "Upgrade: websocket" crlf
                 "Connection: Upgrade" crlf
                 "Sec-WebSocket-Accept: " accept crlf))
         (parts (if protocol
                    (append parts
                            (list "Sec-WebSocket-Protocol: " protocol crlf))
                    parts))
         (parts (if extensions
                    (append parts
                            (list "Sec-WebSocket-Extensions: " extensions crlf))
                    parts))
         (text (apply #'concatenate 'string (append parts (list crlf)))))
    (%ascii-octets text)))

;;; --- Frame encode / decode --------------------------------------------------

(defun %control-opcode-p (opcode)
  (or (= opcode +opcode-close+)
      (= opcode +opcode-ping+)
      (= opcode +opcode-pong+)))

(defun %validate-frame (frame &key allow-rsv1)
  (let ((opcode (ws-frame-opcode frame))
        (payload (ws-frame-payload frame)))
    (when (or (and (ws-frame-rsv1 frame) (not allow-rsv1))
              (ws-frame-rsv2 frame)
              (ws-frame-rsv3 frame))
      (%protocol-error "RSV bits must be 0 without negotiated extensions"))
    (when (and (%control-opcode-p opcode) (ws-frame-rsv1 frame))
      (%protocol-error "control frames must not set RSV1"))
    (when (and (%control-opcode-p opcode) (not (ws-frame-fin frame)))
      (%protocol-error "control frames must not be fragmented"))
    (when (and (%control-opcode-p opcode)
               (> (length payload) +max-control-payload+))
      (%protocol-error "control frame payload exceeds 125 bytes"))
    (when (and (not (%control-opcode-p opcode))
               (not (member opcode
                            (list +opcode-continuation+
                                  +opcode-text+
                                  +opcode-binary+)
                            :test #'=)))
      (%protocol-error "unknown opcode ~d" opcode))
    frame))

(defun encode-frame (frame &key mask)
  "Serialize FRAME to wire octets. MASK is NIL (server) or a 4-byte key (client)."
  (%validate-frame frame :allow-rsv1 (ws-frame-rsv1 frame))
  (let* ((payload (ws-frame-payload frame))
         (len (length payload))
         (masked-p (and mask t))
         (mask-key (when masked-p
                     (if (and (typep mask '(simple-array (unsigned-byte 8) (*)))
                              (= (length mask) 4))
                         mask
                         (%protocol-error "mask key must be exactly 4 bytes"))))
         (wire-payload (if masked-p
                           (mask-payload payload mask-key)
                           payload))
         (header-len
           (+ 2
              (cond ((< len 126) 0)
                    ((<= len 65535) 2)
                    (t 8))
              (if masked-p 4 0)))
         (out (make-array (+ header-len len)
                          :element-type '(unsigned-byte 8)))
         (i 0))
    (setf (aref out i)
          (logior (if (ws-frame-fin frame) #x80 0)
                  (if (ws-frame-rsv1 frame) #x40 0)
                  (if (ws-frame-rsv2 frame) #x20 0)
                  (if (ws-frame-rsv3 frame) #x10 0)
                  (logand (ws-frame-opcode frame) #x0f)))
    (incf i)
    (setf (aref out i)
          (logior (if masked-p #x80 0)
                  (cond ((< len 126) len)
                        ((<= len 65535) 126)
                        (t 127))))
    (incf i)
    (cond
      ((< len 126))
      ((<= len 65535)
       (setf (aref out i) (ldb (byte 8 8) len)
             (aref out (1+ i)) (ldb (byte 8 0) len))
       (incf i 2))
      (t
       (dotimes (b 8)
         (setf (aref out (+ i b))
               (ldb (byte 8 (* 8 (- 7 b))) len)))
       (incf i 8)))
    (when masked-p
      (dotimes (b 4)
        (setf (aref out (+ i b)) (aref mask-key b)))
      (incf i 4))
    (replace out wire-payload :start1 i)
    out))

(defun decode-frame (octets &key (start 0) end allow-rsv1)
  "Parse one frame from OCTETS[START..END).

Returns (values frame next-index) when a complete frame is available,
(values nil start) when more bytes are needed, or signals
WEBSOCKET-PROTOCOL-ERROR on a clear protocol violation.
ALLOW-RSV1 permits RSV1 for negotiated permessage-deflate."
  (let* ((end (or end (length octets)))
         (available (- end start)))
    (when (< available 2)
      (return-from decode-frame (values nil start)))
    (let* ((b0 (aref octets start))
           (b1 (aref octets (1+ start)))
           (fin (logbitp 7 b0))
           (rsv1 (logbitp 6 b0))
           (rsv2 (logbitp 5 b0))
           (rsv3 (logbitp 4 b0))
           (opcode (logand b0 #x0f))
           (masked (logbitp 7 b1))
           (len7 (logand b1 #x7f))
           (offset 2)
           (payload-len len7))
      (cond
        ((= len7 126)
         (when (< available (+ 2 2))
           (return-from decode-frame (values nil start)))
         (setf payload-len
               (logior (ash (aref octets (+ start 2)) 8)
                       (aref octets (+ start 3)))
               offset 4)
         (when (< payload-len 126)
           (%protocol-error "non-minimal 16-bit payload length")))
        ((= len7 127)
         (when (< available (+ 2 8))
           (return-from decode-frame (values nil start)))
         (setf payload-len 0)
         (dotimes (b 8)
           (setf payload-len
                 (logior (ash payload-len 8)
                         (aref octets (+ start 2 b)))))
         (setf offset 10)
         (when (< payload-len 65536)
           (%protocol-error "non-minimal 64-bit payload length"))
         ;; Reject lengths that do not fit a fixnum-friendly size.
         (when (>= payload-len (ash 1 53))
           (%protocol-error "payload length too large"))))
      (let* ((mask-len (if masked 4 0))
             (total (+ offset mask-len payload-len)))
        (when (< available total)
          (return-from decode-frame (values nil start)))
        (let* ((mask-key
                 (when masked
                   (let ((k (make-array 4 :element-type '(unsigned-byte 8))))
                     (replace k octets
                              :start2 (+ start offset)
                              :end2 (+ start offset 4))
                     k)))
               (payload-start (+ start offset mask-len))
               (payload-end (+ payload-start payload-len))
               (raw (if (zerop payload-len)
                        (make-array 0 :element-type '(unsigned-byte 8))
                        (subseq octets payload-start payload-end)))
               (payload (if masked
                            (mask-payload raw mask-key)
                            (coerce raw '(simple-array (unsigned-byte 8) (*)))))
               (frame
                 (make-ws-frame
                  :fin fin :rsv1 rsv1 :rsv2 rsv2 :rsv3 rsv3
                  :opcode opcode :masked masked
                  :payload payload :mask-key mask-key)))
          (%validate-frame frame :allow-rsv1 allow-rsv1)
          (values frame (+ start total)))))))

;;; --- Close payload helpers --------------------------------------------------

(defun make-close-payload (code &optional (reason ""))
  "Encode a close frame payload: 2-byte status CODE + UTF-8 REASON."
  (let* ((reason-octets
           (if (and reason (plusp (length reason)))
               (sb-ext:string-to-octets reason :external-format :utf-8)
               (make-array 0 :element-type '(unsigned-byte 8))))
         (out (make-array (+ 2 (length reason-octets))
                          :element-type '(unsigned-byte 8))))
    (unless (<= 0 code 65535)
      (%protocol-error "close code out of range"))
    (when (> (length reason-octets) 123)
      (%protocol-error "close reason exceeds 123 bytes"))
    (setf (aref out 0) (ldb (byte 8 8) code)
          (aref out 1) (ldb (byte 8 0) code))
    (replace out reason-octets :start1 2)
    out))

(defun parse-close-payload (payload)
  "Return (values code reason-string) from a close frame payload."
  (let ((len (length payload)))
    (cond
      ((zerop len) (values 1005 ""))
      ((= len 1) (%protocol-error "close payload of length 1 is illegal"))
      (t
       (let ((code (logior (ash (aref payload 0) 8) (aref payload 1)))
             (reason
               (if (> len 2)
                   (handler-case
                       (sb-ext:octets-to-string
                        (subseq payload 2) :external-format :utf-8)
                     (error ()
                       (%protocol-error "close reason is not valid UTF-8")))
                   "")))
         (values code reason))))))

;;; --- Convenience frame builders ---------------------------------------------

(defun make-text-frame (text &key (fin t))
  (make-ws-frame
   :fin fin :opcode +opcode-text+
   :payload (sb-ext:string-to-octets text :external-format :utf-8)))

(defun make-binary-frame (octets &key (fin t))
  (make-ws-frame
   :fin fin :opcode +opcode-binary+
   :payload (coerce octets '(simple-array (unsigned-byte 8) (*)))))

(defun make-ping-frame (&optional (payload #()))
  (make-ws-frame
   :fin t :opcode +opcode-ping+
   :payload (coerce payload '(simple-array (unsigned-byte 8) (*)))))

(defun make-pong-frame (&optional (payload #()))
  (make-ws-frame
   :fin t :opcode +opcode-pong+
   :payload (coerce payload '(simple-array (unsigned-byte 8) (*)))))

(defun make-close-frame (code &optional (reason ""))
  (make-ws-frame
   :fin t :opcode +opcode-close+
   :payload (make-close-payload code reason)))

;;; --- Mask key / client helpers ---------------------------------------------

(defun random-mask-key ()
  "Return a fresh 4-byte mask key from the OS CSPRNG."
  (clun.sys:os-random-bytes 4))

(defun client-opening-handshake-request (host path &key (key nil) protocol extensions)
  "Build client HTTP upgrade request octets for PATH on HOST.
Returns (values request-octets sec-websocket-key)."
  (let* ((key (or key (%base64-encode (clun.sys:os-random-bytes 16))))
         (crlf (format nil "~c~c" #\Return #\Newline))
         (path (if (and path (plusp (length path))) path "/"))
         (parts
           (list "GET " path " HTTP/1.1" crlf
                 "Host: " host crlf
                 "Upgrade: websocket" crlf
                 "Connection: Upgrade" crlf
                 "Sec-WebSocket-Key: " key crlf
                 "Sec-WebSocket-Version: 13" crlf))
         (parts (if protocol
                    (append parts (list "Sec-WebSocket-Protocol: " protocol crlf))
                    parts))
         (parts (if extensions
                    (append parts (list "Sec-WebSocket-Extensions: " extensions crlf))
                    parts))
         (text (apply #'concatenate 'string (append parts (list crlf)))))
    (values (%ascii-octets text) key)))

(defun parse-http-response-head (octets &key (start 0) end)
  "Parse HTTP response status-line + headers from OCTETS.
Returns (values status header-alist body-start) or NIL if incomplete."
  (let* ((end (or end (length octets)))
         (text (handler-case
                   (sb-ext:octets-to-string
                    (subseq octets start end) :external-format :latin-1)
                 (error () (return-from parse-http-response-head nil))))
         (sep (search (format nil "~c~c~c~c" #\Return #\Newline #\Return #\Newline)
                      text)))
    (unless sep (return-from parse-http-response-head nil))
    (let* ((head (subseq text 0 sep))
           (lines (loop with start = 0
                        for pos = (search (format nil "~c~c" #\Return #\Newline)
                                          head :start2 start)
                        collect (subseq head start (or pos (length head)))
                        while pos
                        do (setf start (+ pos 2))))
           (status-line (first lines))
           (status
             (let ((sp1 (position #\Space status-line)))
               (when sp1
                 (let ((sp2 (position #\Space status-line :start (1+ sp1))))
                   (ignore-errors
                     (parse-integer status-line
                                    :start (1+ sp1)
                                    :end (or sp2 (length status-line))))))))
           (headers
             (loop for line in (rest lines)
                   for colon = (position #\: line)
                   when colon
                     collect (cons (string-trim '(#\Space #\Tab)
                                                (subseq line 0 colon))
                                   (string-trim '(#\Space #\Tab)
                                                (subseq line (1+ colon)))))))
      (values status headers (+ start sep 4)))))

(defun extension-token-member-p (field token)
  "True when TOKEN appears as a comma-separated extension token in FIELD."
  (when field
    (loop with start = 0
          with needle = (string-downcase token)
          for comma = (position #\, field :start start)
          for part = (string-trim '(#\Space #\Tab) (subseq field start comma))
          for semi = (position #\; part)
          for name = (string-downcase
                      (string-trim '(#\Space #\Tab)
                                   (if semi (subseq part 0 semi) part)))
          thereis (string= name needle)
          while comma
          do (setf start (1+ comma)))))

;;; --- Fragment reassembly helpers -------------------------------------------

(defun fragment-start-p (opcode)
  "True when OPCODE begins a (possibly fragmented) data message."
  (or (= opcode +opcode-text+) (= opcode +opcode-binary+)))

(defun append-octets (buffer octets)
  "Append OCTETS onto adjustable BUFFER (fill-pointer vector)."
  (let* ((need (+ (fill-pointer buffer) (length octets)))
         (cap (array-total-size buffer)))
    (when (> need cap)
      (adjust-array buffer (max need (* 2 (max 1 cap)))
                    :fill-pointer (fill-pointer buffer)))
    (let ((start (fill-pointer buffer)))
      (incf (fill-pointer buffer) (length octets))
      (replace buffer octets :start1 start))
    buffer))

;;; --- permessage-deflate (RFC 7692) via chipz inflate ------------------------

(defparameter +pmd-trailer+
  (make-array 4 :element-type '(unsigned-byte 8)
              :initial-contents '(#x00 #x00 #xff #xff))
  "Empty DEFLATE block trailer stripped from compressed message payloads.")

(defparameter +default-max-inflate-bytes+ #.(* 16 1024 1024)
  "Hard expansion cap for a single compressed WebSocket message.")

(defun inflate-permessage-deflate (payload &key (max-bytes +default-max-inflate-bytes+))
  "Inflate a permessage-deflate message PAYLOAD (without the trailing empty block).
Signals WEBSOCKET-PROTOCOL-ERROR on malformed input or expansion past MAX-BYTES."
  (let ((input (make-array (+ (length payload) 4)
                           :element-type '(unsigned-byte 8))))
    (replace input payload)
    (replace input +pmd-trailer+ :start1 (length payload))
    (handler-case
        (flexi-streams:with-input-from-sequence (in input)
          (let* ((stream (chipz:make-decompressing-stream 'chipz:deflate in))
                 (capacity (max 1 (min (* 256 1024) max-bytes)))
                 (output (make-array capacity :element-type '(unsigned-byte 8)
                                              :adjustable t :fill-pointer 0))
                 (buffer (make-array (* 64 1024) :element-type '(unsigned-byte 8))))
            (loop for count = (read-sequence buffer stream)
                  while (plusp count) do
                    (when (> (+ (fill-pointer output) count) max-bytes)
                      (%protocol-error "permessage-deflate expansion exceeded cap"))
                    (let* ((start (fill-pointer output))
                           (new (+ start count)))
                      (when (> new (array-total-size output))
                        (adjust-array output
                                      (min max-bytes
                                           (max new (* 2 (array-total-size output))))
                                      :fill-pointer start))
                      (setf (fill-pointer output) new)
                      (replace output buffer :start1 start :end2 count)))
            (coerce output '(simple-array (unsigned-byte 8) (*)))))
      (websocket-protocol-error (c) (error c))
      (chipz:decompression-error (c)
        (%protocol-error "permessage-deflate inflate failed: ~a" c))
      (error (c)
        (%protocol-error "permessage-deflate inflate failed: ~a" c)))))

(defun deflate-stored-block (payload &key (final t))
  "Encode PAYLOAD as raw DEFLATE stored (uncompressed) block(s).
RFC 7692 allows any valid DEFLATE stream; stored blocks keep purity simple."
  (let ((out (make-array 0 :element-type '(unsigned-byte 8)
                           :adjustable t :fill-pointer 0))
        (len (length payload))
        (pos 0))
    (if (zerop len)
        (progn
          (vector-push-extend #x01 out)
          (vector-push-extend #x00 out)
          (vector-push-extend #x00 out)
          (vector-push-extend #xff out)
          (vector-push-extend #xff out)
          (coerce out '(simple-array (unsigned-byte 8) (*))))
        (loop while (< pos len)
              for chunk = (min 65535 (- len pos))
              for last = (and final (= (+ pos chunk) len))
              for nlen = (logand (lognot chunk) #xffff)
              do
                (vector-push-extend (if last #x01 #x00) out)
                (vector-push-extend (ldb (byte 8 0) chunk) out)
                (vector-push-extend (ldb (byte 8 8) chunk) out)
                (vector-push-extend (ldb (byte 8 0) nlen) out)
                (vector-push-extend (ldb (byte 8 8) nlen) out)
                (loop for i from 0 below chunk
                      do (vector-push-extend (aref payload (+ pos i)) out))
                (incf pos chunk)
              finally
                (return (coerce out '(simple-array (unsigned-byte 8) (*))))))))

(defun compress-permessage-deflate (payload)
  "Compress PAYLOAD for permessage-deflate (RFC 7692 §7.2.1).
Emit non-final stored block(s) + empty final block, then strip the trailing
0x00 0x00 0xff 0xff empty-block tail so the receiver can re-append it."
  (let* ((parts '())
         (len (length payload))
         (pos 0))
    (if (zerop len)
        ;; Empty message: empty final block with trailer stripped → single 0x01.
        (make-array 1 :element-type '(unsigned-byte 8) :initial-element #x01)
        (progn
          (loop while (< pos len)
                for end = (min len (+ pos 65535))
                for chunk = (subseq payload pos end)
                ;; All data blocks are non-final; the empty final carries BFINAL.
                do (push (deflate-stored-block chunk :final nil) parts)
                   (setf pos end))
          (let* ((empty-final (make-array 5 :element-type '(unsigned-byte 8)
                                          :initial-contents '(#x01 #x00 #x00 #xff #xff)))
                 (joined (apply #'concatenate
                                '(simple-array (unsigned-byte 8) (*))
                                (append (nreverse parts) (list empty-final))))
                 (jlen (length joined)))
            ;; Strip 0x00 0x00 0xff 0xff empty-block payload/length tail.
            (subseq joined 0 (- jlen 4)))))))

;;; --- Fragment reassembly ----------------------------------------------------

(defstruct (ws-fragment-state
            (:constructor make-ws-fragment-state)
            (:conc-name ws-fragment-state-))
  "Bounded fragmented-message reassembly for one connection."
  (active-p nil :type boolean)
  (opcode 0 :type (integer 0 15))
  (rsv1 nil :type boolean)
  (buffer (make-array 0 :element-type '(unsigned-byte 8)
                        :adjustable t :fill-pointer 0)))

(defun fragment-reset (state)
  (setf (ws-fragment-state-active-p state) nil
        (ws-fragment-state-opcode state) 0
        (ws-fragment-state-rsv1 state) nil
        (fill-pointer (ws-fragment-state-buffer state)) 0)
  state)

(defun fragment-feed (state frame &key (max-payload +default-max-payload-bytes+))
  "Feed a data/continuation FRAME into STATE.

Returns:
  :need-more — waiting for more fragments
  (values :message opcode payload rsv1) — complete message
  signals WEBSOCKET-PROTOCOL-ERROR on illegal sequences or oversize."
  (let ((opcode (ws-frame-opcode frame))
        (fin (ws-frame-fin frame))
        (payload (ws-frame-payload frame))
        (rsv1 (ws-frame-rsv1 frame)))
    (cond
      ((%control-opcode-p opcode)
       (%protocol-error "control frames must not enter fragment reassembly"))
      ((= opcode +opcode-continuation+)
       (unless (ws-fragment-state-active-p state)
         (%protocol-error "unexpected continuation frame"))
       (when (or rsv1 (ws-frame-rsv2 frame) (ws-frame-rsv3 frame))
         (%protocol-error "RSV bits must be clear on continuation frames"))
       (when (> (+ (length (ws-fragment-state-buffer state)) (length payload))
                max-payload)
         (%protocol-error "fragmented message exceeds maxPayloadLength"))
       (let ((buf (ws-fragment-state-buffer state)))
         (loop for b across payload do (vector-push-extend b buf)))
       (if fin
           (let* ((out (coerce (subseq (ws-fragment-state-buffer state) 0)
                               '(simple-array (unsigned-byte 8) (*))))
                  (op (ws-fragment-state-opcode state))
                  (r1 (ws-fragment-state-rsv1 state)))
             (fragment-reset state)
             (values :message op out r1))
           :need-more))
      ((or (= opcode +opcode-text+) (= opcode +opcode-binary+))
       (when (ws-fragment-state-active-p state)
         (%protocol-error "new data frame while reassembly is active"))
       (when (or (ws-frame-rsv2 frame) (ws-frame-rsv3 frame))
         (%protocol-error "RSV2/RSV3 must be 0"))
       (if fin
           (progn
             (when (> (length payload) max-payload)
               (%protocol-error "message exceeds maxPayloadLength"))
             (values :message opcode
                     (coerce payload '(simple-array (unsigned-byte 8) (*)))
                     rsv1))
           (progn
             (when (> (length payload) max-payload)
               (%protocol-error "fragmented message exceeds maxPayloadLength"))
             (setf (ws-fragment-state-active-p state) t
                   (ws-fragment-state-opcode state) opcode
                   (ws-fragment-state-rsv1 state) rsv1
                   (fill-pointer (ws-fragment-state-buffer state)) 0)
             (let ((buf (ws-fragment-state-buffer state)))
               (loop for b across payload do (vector-push-extend b buf)))
             :need-more)))
      (t (%protocol-error "unknown data opcode ~d" opcode)))))

;;; --- Topic hub (Pub/Sub) ----------------------------------------------------

(defstruct (ws-topic-hub
            (:constructor make-ws-topic-hub
                (&key (topics (make-hash-table :test #'equal))
                      (lock nil)))
            (:conc-name ws-topic-hub-))
  "Server-wide topic → session membership. Sessions are opaque objects
compared with EQ; the serve layer stores session structs."
  (topics (make-hash-table :test #'equal) :type hash-table))

(defun topic-subscribe (hub session topic)
  "Subscribe SESSION to TOPIC (string). Idempotent. Returns T."
  (let* ((topic (string topic))
         (set (gethash topic (ws-topic-hub-topics hub))))
    (unless set
      (setf set (make-hash-table :test #'eq)
            (gethash topic (ws-topic-hub-topics hub)) set))
    (setf (gethash session set) t)
    t))

(defun topic-unsubscribe (hub session topic)
  "Remove SESSION from TOPIC. Returns T if it was subscribed."
  (let* ((topic (string topic))
         (set (gethash topic (ws-topic-hub-topics hub))))
    (when set
      (let ((was (remhash session set)))
        (when (zerop (hash-table-count set))
          (remhash topic (ws-topic-hub-topics hub)))
        was))))

(defun topic-unsubscribe-all (hub session)
  "Drop SESSION from every topic. Returns number of topics removed from."
  (let ((n 0))
    (maphash
     (lambda (topic set)
       (when (remhash session set)
         (incf n)
         (when (zerop (hash-table-count set))
           (remhash topic (ws-topic-hub-topics hub)))))
     (ws-topic-hub-topics hub))
    n))

(defun topic-subscribed-p (hub session topic)
  (let ((set (gethash (string topic) (ws-topic-hub-topics hub))))
    (and set (gethash session set) t)))

(defun topic-subscriptions (hub session)
  "Return a fresh list of topic strings SESSION is subscribed to."
  (let ((out '()))
    (maphash
     (lambda (topic set)
       (when (gethash session set)
         (push topic out)))
     (ws-topic-hub-topics hub))
    (nreverse out)))

(defun topic-subscriber-count (hub topic)
  (let ((set (gethash (string topic) (ws-topic-hub-topics hub))))
    (if set (hash-table-count set) 0)))

(defun topic-subscribers (hub topic)
  "Return a fresh list of session objects subscribed to TOPIC."
  (let ((set (gethash (string topic) (ws-topic-hub-topics hub)))
        (out '()))
    (when set
      (maphash (lambda (session present)
                 (declare (ignore present))
                 (push session out))
               set))
    out))
(defun parse-sec-websocket-extensions (field)
  "Return a list of (name . params-alist) from a Sec-WebSocket-Extensions header."
  (when (and field (plusp (length field)))
    (loop with start = 0
          with out = '()
          for comma = (position #\, field :start start)
          for part = (string-trim '(#\Space #\Tab) (subseq field start comma))
          do (when (plusp (length part))
               (let* ((semi (position #\; part))
                      (name (string-trim '(#\Space #\Tab)
                                         (if semi (subseq part 0 semi) part)))
                      (params '()))
                 (when semi
                   (loop with pstart = (1+ semi)
                         for next = (position #\; part :start pstart)
                         for p = (string-trim '(#\Space #\Tab)
                                              (subseq part pstart next))
                         do (when (plusp (length p))
                              (let ((eq-pos (position #\= p)))
                                (if eq-pos
                                    (push (cons (string-trim
                                                 '(#\Space #\Tab)
                                                 (subseq p 0 eq-pos))
                                                (string-trim
                                                 '(#\Space #\Tab #\")
                                                 (subseq p (1+ eq-pos))))
                                          params)
                                    (push (cons p t) params))))
                            (setf pstart (if next (1+ next) (length part)))
                         while next))
                 (push (cons name (nreverse params)) out)))
             (setf start (if comma (1+ comma) (length field)))
          while comma
          finally (return (nreverse out)))))

(defun client-offers-permessage-deflate-p (headers)
  "True when client Sec-WebSocket-Extensions offers permessage-deflate."
  (let ((field (%header-value headers "sec-websocket-extensions")))
    (or (extension-token-member-p field "permessage-deflate")
        (some (lambda (ext) (string-equal (car ext) "permessage-deflate"))
              (or (parse-sec-websocket-extensions field) '())))))

(defun make-client-key ()
  "Base64 16-byte nonce for Sec-WebSocket-Key."
  (%base64-encode (clun.sys:os-random-bytes 16)))
