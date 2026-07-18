;;;; websocket.lisp — Phase 51: pure-CL RFC 6455 handshake + framing + Pub/Sub hub.
;;;; Server handshake (Sec-WebSocket-Accept), frame encode/decode for text,
;;;; binary, ping, pong, and close; topic hub for server.publish / subscribe.
;;;; Client WebSocket, compression, and full fragmentation reassembly remain
;;;; later milestones. See docs/design/phase-51.md. No foreign libraries.

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
  "Stable user-facing text for Phase 51 surfaces not yet implemented (client, etc.)."
  (format nil "~a is not implemented in Clun (Phase 51). ~
               Pure Common Lisp WebSocket framing/handshake and Pub/Sub are available; ~
               remaining surfaces land in later milestones ~
               (docs/design/phase-51.md)."
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

(defun opening-handshake-response (sec-websocket-key &key protocol)
  "HTTP/1.1 101 Switching Protocols response octets for KEY (and optional protocol)."
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
         (text (apply #'concatenate 'string (append parts (list crlf)))))
    (%ascii-octets text)))

;;; --- Frame encode / decode --------------------------------------------------

(defun %control-opcode-p (opcode)
  (or (= opcode +opcode-close+)
      (= opcode +opcode-ping+)
      (= opcode +opcode-pong+)))

(defun %validate-frame (frame)
  (let ((opcode (ws-frame-opcode frame))
        (payload (ws-frame-payload frame)))
    (when (or (ws-frame-rsv1 frame)
              (ws-frame-rsv2 frame)
              (ws-frame-rsv3 frame))
      (%protocol-error "RSV bits must be 0 without negotiated extensions"))
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
  (%validate-frame frame)
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

(defun decode-frame (octets &key (start 0) end)
  "Parse one frame from OCTETS[START..END).

Returns (values frame next-index) when a complete frame is available,
(values nil start) when more bytes are needed, or signals
WEBSOCKET-PROTOCOL-ERROR on a clear protocol violation."
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
          (%validate-frame frame)
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

;;; --- Topic hub (Bun-shaped Pub/Sub) ----------------------------------------
;;;
;;; Pure in-memory membership tables. Subscribers are opaque EQ identities
;;; (runtime ws-session objects). Fan-out I/O lives in clun-serve; this layer
;;; only tracks who is subscribed to which topic.

(defstruct (ws-topic-hub
            (:constructor make-ws-topic-hub)
            (:conc-name ws-topic-hub-))
  "Server-wide topic → subscriber list. EQ subscribers; EQUAL topics."
  (topics (make-hash-table :test #'equal) :type hash-table)
  ;; Reverse index: subscriber → list of topic strings (for close cleanup).
  (by-subscriber (make-hash-table :test #'eq) :type hash-table))

(defun topic-hub-subscribe (hub subscriber topic)
  "Subscribe SUBSCRIBER to TOPIC. Idempotent. Returns T if newly added."
  (check-type topic string)
  (let* ((topics (ws-topic-hub-topics hub))
         (by (ws-topic-hub-by-subscriber hub))
         (members (gethash topic topics))
         (already (member subscriber members :test #'eq)))
    (unless already
      (setf (gethash topic topics) (cons subscriber members))
      (setf (gethash subscriber by)
            (cons topic (gethash subscriber by)))
      t)))

(defun topic-hub-unsubscribe (hub subscriber topic)
  "Unsubscribe SUBSCRIBER from TOPIC. Returns T if it was a member."
  (check-type topic string)
  (let* ((topics (ws-topic-hub-topics hub))
         (by (ws-topic-hub-by-subscriber hub))
         (members (gethash topic topics))
         (was (member subscriber members :test #'eq)))
    (when was
      (let ((rest (remove subscriber members :test #'eq)))
        (if rest
            (setf (gethash topic topics) rest)
            (remhash topic topics)))
      (let ((owned (remove topic (gethash subscriber by) :test #'string=)))
        (if owned
            (setf (gethash subscriber by) owned)
            (remhash subscriber by)))
      t)))

(defun topic-hub-unsubscribe-all (hub subscriber)
  "Remove SUBSCRIBER from every topic. Returns the number of topics cleared."
  (let ((owned (copy-list (gethash subscriber (ws-topic-hub-by-subscriber hub)))))
    (dolist (topic owned)
      (topic-hub-unsubscribe hub subscriber topic))
    (length owned)))

(defun topic-hub-subscribed-p (hub subscriber topic)
  "True when SUBSCRIBER is currently subscribed to TOPIC."
  (check-type topic string)
  (and (member subscriber (gethash topic (ws-topic-hub-topics hub)) :test #'eq)
       t))

(defun topic-hub-subscriptions (hub subscriber)
  "Return a fresh list of topic strings SUBSCRIBER is subscribed to."
  (copy-list (gethash subscriber (ws-topic-hub-by-subscriber hub))))

(defun topic-hub-subscriber-count (hub topic)
  "Number of live subscribers on TOPIC (0 if unknown)."
  (check-type topic string)
  (length (gethash topic (ws-topic-hub-topics hub))))

(defun topic-hub-subscribers (hub topic)
  "Return a fresh list of subscribers on TOPIC (may include closed sockets)."
  (check-type topic string)
  (copy-list (gethash topic (ws-topic-hub-topics hub))))
