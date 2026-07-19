;;; record-layer.lisp --- TLS 1.3 Record Layer Protocol
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Anthony Green <green@moxielogic.com>
;;;
;;; Implements the TLS 1.3 record layer (RFC 8446 Section 5).

(in-package #:pure-tls)

;;;; TLS Record Structure
;;;
;;; Plaintext record (before encryption):
;;;   struct {
;;;     ContentType type;
;;;     ProtocolVersion legacy_record_version = 0x0303;  /* TLS 1.2 */
;;;     uint16 length;
;;;     opaque fragment[TLSPlaintext.length];
;;;   } TLSPlaintext;
;;;
;;; Ciphertext record (after encryption, TLS 1.3):
;;;   struct {
;;;     ContentType opaque_type = application_data; /* 23 */
;;;     ProtocolVersion legacy_record_version = 0x0303;
;;;     uint16 length;
;;;     opaque encrypted_record[TLSCiphertext.length];
;;;   } TLSCiphertext;

(defstruct tls-record
  "A TLS record."
  (content-type 0 :type octet)
  (version +tls-1.2+ :type fixnum)
  (fragment nil :type (or null octet-vector)))

;;;; Record Layer I/O

(defun read-exact-bytes (stream buffer count &optional request-context)
  "Read exactly COUNT bytes from STREAM into BUFFER.
   Loops until all bytes are read or EOF is reached.
   Returns the number of bytes actually read (may be less than COUNT at EOF).
   If REQUEST-CONTEXT is provided, checks for deadline/cancellation before each read."
  (let ((total-read 0))
    (loop while (< total-read count)
          do (check-tls-context)
             (let ((bytes-read (read-sequence buffer stream
                                              :start total-read
                                              :end count)))
               (when (= bytes-read total-read)
                 ;; No progress - EOF reached
                 (return total-read))
               (setf total-read bytes-read)))
    total-read))

(defun read-tls-record (stream &optional request-context)
  "Read a TLS record from STREAM.
   Returns a TLS-RECORD structure or signals an error.
   Uses a stack-allocated 5-byte header and a pool-allocated read buffer
   to avoid per-record heap allocation.  The read buffer is recycled via
   the enclosing WITH-BUFFER-CONTEXT; the returned fragment is an
   exact-sized copy safe for use beyond the context scope.
   Properly handles short reads from the underlying stream.
   Validates legacy_record_version per RFC 8446 Section 5.1.
   If REQUEST-CONTEXT is provided, checks for deadline/cancellation during reads."
  (let ((header (make-array 5 :element-type '(unsigned-byte 8) :initial-element 0)))
    (declare (type (simple-array (unsigned-byte 8) (5)) header)
             (dynamic-extent header))
    ;; Read 5-byte header (loop until complete or EOF)
    (let ((bytes-read (read-exact-bytes stream header 5 request-context)))
      (declare (type fixnum bytes-read))
      (when (zerop bytes-read)
        (error 'tls-connection-closed :clean nil))
      (when (< bytes-read 5)
        (error 'tls-decode-error
               :message (format nil "Incomplete record header: expected 5 bytes, got ~D"
                                bytes-read))))
    ;; Parse header
    (let* ((content-type (aref header 0))
           (version (decode-uint16 header 1))
           (length (decode-uint16 header 3)))
      (declare (type fixnum content-type version length))
      ;; Validate content type - must be a valid TLS content type (20-24)
      ;; This quickly rejects SSLv2 records which have high-bit-set bytes
      ;; in position 0, preventing us from waiting forever for invalid lengths.
      (unless (and (>= content-type +content-type-change-cipher-spec+)  ; 20
                   (<= content-type 24))  ; heartbeat is 24
        (error 'tls-decode-error
               :message (format nil ":WRONG_VERSION_NUMBER: Invalid content type ~D (not a valid TLS record)"
                                content-type)))
      ;; RFC 8446 Section 5.1: legacy_record_version SHOULD be 0x0303 for
      ;; all TLS 1.3 records, but implementations MUST NOT check this field.
      ;; Accept any record version for maximum compatibility.
      ;; Validate length
      (when (> length +max-record-size-with-padding+)
        (error 'tls-record-overflow :size length))
      ;; Read into a pool-allocated buffer (tier-sized, recycled by context
      ;; exit), then copy exact LENGTH bytes into the returned fragment.
      ;; The pool buffer avoids per-record GC pressure on the read path.
      (let ((read-buffer (if *buffer-context*
                             (buffer-pool-allocate *buffer-pool* length)
                             (make-octet-vector length))))
        (let ((bytes-read (read-exact-bytes stream read-buffer length request-context)))
          (declare (type fixnum bytes-read))
          (when (< bytes-read length)
            (error 'tls-decode-error
                   :message (format nil "Incomplete record fragment: expected ~D bytes, got ~D"
                                    length bytes-read))))
        ;; Copy exact-size fragment from pool buffer.  The pool buffer
        ;; stays on the context list and is recycled on scope exit.
        (let ((fragment (make-octet-vector length)))
          (replace fragment read-buffer :end2 length)
          (make-tls-record :content-type content-type
                           :version version
                           :fragment fragment))))))

(defun write-tls-record (stream record)
  "Write a TLS record to STREAM.  Uses stack-allocated 5-byte header
   instead of heap-allocating via make-octet-vector."
  (let* ((fragment (tls-record-fragment record))
         (length (length fragment))
         (header (make-array 5 :element-type '(unsigned-byte 8) :initial-element 0)))
    (declare (type (simple-array (unsigned-byte 8) (5)) header)
             (type fixnum length)
             (dynamic-extent header))
    ;; Validate length
    (when (> length +max-record-size-with-padding+)
      (error 'tls-record-overflow :size length))
    ;; Build header
    (setf (aref header 0) (tls-record-content-type record))
    (setf (aref header 1) (ldb (byte 8 8) (tls-record-version record)))
    (setf (aref header 2) (ldb (byte 8 0) (tls-record-version record)))
    (setf (aref header 3) (ldb (byte 8 8) length))
    (setf (aref header 4) (ldb (byte 8 0) length))
    ;; Write header and fragment
    (write-sequence header stream)
    (write-sequence fragment stream)
    (force-output stream)))

(defun make-plaintext-record (content-type data)
  "Create a plaintext TLS record."
  (make-tls-record :content-type content-type
                   :version +tls-1.2+
                   :fragment data))

;;;; Record Encryption/Decryption

(defconstant +max-ccs-messages+ 32
  "Maximum number of change_cipher_spec messages allowed (DoS protection).")

(defstruct (record-layer (:constructor %make-record-layer))
  "TLS record layer state."
  (read-cipher nil :type (or null aead-cipher))
  (write-cipher nil :type (or null aead-cipher))
  (cipher-suite 0 :type fixnum)
  (stream nil)
  (max-send-fragment +max-record-size+ :type fixnum)
  (ccs-count 0 :type fixnum)
  ;; Alert state is deliberately independent from socket/stream closure.  This
  ;; implementation elects to reciprocate a peer close once, while a peer
  ;; fatal must never receive a newly manufactured alert.
  (peer-close-received-p nil :type boolean)
  (local-close-sent-p nil :type boolean)
  (fatal-alert-sent-p nil :type boolean)
  (peer-fatal-alert-received-p nil :type boolean)
  (request-context nil :type t))

(defun make-record-layer (stream &key (max-send-fragment +max-record-size+)
                                      request-context)
  "Create a new record layer for the given stream.
   MAX-SEND-FRAGMENT sets the maximum plaintext size for outgoing records.
   REQUEST-CONTEXT is an optional cl-cancel context for timeout/cancellation support."
  (%make-record-layer :stream stream
                      :max-send-fragment max-send-fragment
                      :request-context request-context))

(defun record-layer-install-keys (layer direction key iv cipher-suite)
  "Install encryption keys for the specified direction (:read or :write)."
  (let ((cipher (make-aead cipher-suite key iv)))
    (ecase direction
      (:read (setf (record-layer-read-cipher layer) cipher))
      (:write (setf (record-layer-write-cipher layer) cipher)))
    (setf (record-layer-cipher-suite layer) cipher-suite)))

(defun record-layer-read (layer)
  "Read and potentially decrypt a record from the record layer.
   Returns (VALUES content-type plaintext).
   Uses WITH-BUFFER-CONTEXT so pool-allocated read buffers inside
   read-tls-record are automatically recycled on scope exit.
   The returned fragment is always a fresh exact-sized buffer safe
   for use beyond the context scope."
  (when (or (record-layer-fatal-alert-sent-p layer)
            (record-layer-peer-fatal-alert-received-p layer)
            (record-layer-peer-close-received-p layer))
    (error 'tls-error :message ":READ_AFTER_TERMINAL_ALERT:"))
  (check-tls-context)
  (with-buffer-context (*buffer-pool*)
    (let* ((record (read-tls-record (record-layer-stream layer)
                                     (record-layer-request-context layer)))
           (content-type (tls-record-content-type record))
           (fragment (tls-record-fragment record))
           (cipher (record-layer-read-cipher layer)))
      ;; Handle change_cipher_spec (ignored in TLS 1.3 but may be sent)
      (when (= content-type +content-type-change-cipher-spec+)
        ;; Count CCS messages to prevent DoS
        (incf (record-layer-ccs-count layer))
        (when (> (record-layer-ccs-count layer) +max-ccs-messages+)
          (record-layer-write-alert layer +alert-level-fatal+ +alert-unexpected-message+)
          (error 'tls-handshake-error
                 :message ":TOO_MANY_EMPTY_FRAGMENTS: Too many change_cipher_spec messages"))
        ;; Just return and let caller handle/ignore
        (return-from record-layer-read
          (values content-type fragment)))
      ;; If encryption is established, all records MUST be encrypted (content-type 23)
      ;; RFC 8446 Section 5.1: After the handshake keys are installed, all records
      ;; except CCS must use the encrypted record format (application_data wrapper)
      (when cipher
        (unless (= content-type +content-type-application-data+)
          (record-layer-write-alert layer +alert-level-fatal+ +alert-unexpected-message+)
          (error 'tls-handshake-error
                 :message (format nil ":INVALID_OUTER_RECORD_TYPE: Expected encrypted record (23), got ~D"
                                 content-type)))
        ;; Decrypt the record — stack-allocate the 5-byte AAD header
        (let ((header (make-array 5 :element-type '(unsigned-byte 8) :initial-element 0)))
          (declare (type (simple-array (unsigned-byte 8) (5)) header)
                   (dynamic-extent header))
          (setf (aref header 0) content-type
                (aref header 1) (ldb (byte 8 8) (tls-record-version record))
                (aref header 2) (ldb (byte 8 0) (tls-record-version record))
                (aref header 3) (ldb (byte 8 8) (length fragment))
                (aref header 4) (ldb (byte 8 0) (length fragment)))
          ;; tls13-decrypt-record returns (plaintext, content-type)
          ;; We need to return (content-type, plaintext)
          ;; Catch record overflow to send alert before re-raising
          (handler-bind ((tls-record-overflow
                           (lambda (c)
                             (declare (ignore c))
                             (record-layer-write-alert layer
                                                       +alert-level-fatal+
                                                       +alert-record-overflow+))))
            (multiple-value-bind (plaintext inner-content-type)
                (tls13-decrypt-record cipher fragment header)
              (return-from record-layer-read
                (values inner-content-type plaintext))))))
      ;; No encryption - return plaintext record
      (values content-type fragment))))

(defun record-layer-terminal-output-p (layer)
  "Whether LAYER has permanently closed its local record-output direction."
  (or (record-layer-fatal-alert-sent-p layer)
      (record-layer-peer-fatal-alert-received-p layer)
      (record-layer-local-close-sent-p layer)))

(defun ensure-record-layer-writable (layer)
  "Reject record output after a fatal alert or local close_notify."
  (when (record-layer-terminal-output-p layer)
    (error 'tls-error :message ":WRITE_AFTER_TERMINAL_ALERT:")))

(defun record-layer-write (layer content-type data &key allow-terminal)
  "Write and potentially encrypt a record to the record layer.

ALLOW-TERMINAL is reserved for the one alert that establishes terminal state."
  (unless allow-terminal
    (ensure-record-layer-writable layer))
  (let* ((cipher (record-layer-write-cipher layer))
         (stream (record-layer-stream layer)))
    (if cipher
        ;; Encrypted write
        (let* ((encrypted (tls13-encrypt-record cipher content-type data))
               (record (make-tls-record
                        :content-type +content-type-application-data+
                        :version +tls-1.2+
                        :fragment encrypted)))
          (write-tls-record stream record))
        ;; Plaintext write
        (let ((record (make-plaintext-record content-type data)))
          (write-tls-record stream record)))))

(defun record-layer-write-alert (layer level description)
  "Write an alert record once for terminal alerts.

Fatal alerts and close_notify are idempotent.  Once a complete peer fatal has
been received, no alert is written in response."
  (when (or (record-layer-peer-fatal-alert-received-p layer)
            (record-layer-fatal-alert-sent-p layer)
            (record-layer-local-close-sent-p layer))
    (return-from record-layer-write-alert nil))
  (cond
    ((= level +alert-level-fatal+)
     ;; Mark before I/O so a short write cannot trigger a duplicate retry.
     (setf (record-layer-fatal-alert-sent-p layer) t))
    ((= description +alert-close-notify+)
     (setf (record-layer-local-close-sent-p layer) t)))
  (let ((data (octet-vector level description)))
    (record-layer-write layer +content-type-alert+ data :allow-terminal t))
  t)

(defun record-layer-write-handshake (layer handshake-data)
  "Write a handshake record, fragmenting if necessary."
  (record-layer-write-fragmented layer +content-type-handshake+ handshake-data))

(defun record-layer-write-application-data (layer data)
  "Write application data, fragmenting if necessary."
  (record-layer-write-fragmented layer +content-type-application-data+ data))

(defun record-layer-write-change-cipher-spec (layer)
  "Write a dummy change_cipher_spec record for middlebox compatibility.
   Per RFC 8446 Appendix D.4, TLS 1.3 implementations SHOULD send
   a single CCS record immediately after the first ClientHello (client)
   or ServerHello (server) for compatibility with broken middleboxes.
   The CCS record is always sent unencrypted with content byte 0x01."
  (ensure-record-layer-writable layer)
  (let* ((ccs-data (octet-vector 1))  ; Single byte 0x01
         (record (make-tls-record :content-type +content-type-change-cipher-spec+
                                  :version +tls-1.2+
                                  :fragment ccs-data)))
    (write-tls-record (record-layer-stream layer) record)))

;;;; Record Fragmentation

(defun fragment-data (data max-size)
  "Split DATA into fragments of at most MAX-SIZE bytes.
   Returns a list of octet vectors."
  (if (<= (length data) max-size)
      (list data)
      (loop for start from 0 below (length data) by max-size
            collect (subseq data start (min (+ start max-size) (length data))))))

(defun record-layer-write-fragmented (layer content-type data)
  "Write DATA as potentially multiple records, fragmenting if necessary.
   Respects the max-send-fragment setting of the record layer.
   MAX-SEND-FRAGMENT is the maximum plaintext payload size before encryption."
  (let ((max-size (record-layer-max-send-fragment layer)))
    (dolist (fragment (fragment-data data max-size))
      (record-layer-write layer content-type fragment))))

;;;; Alert Processing

(defun process-alert (content &optional record-layer)
  "Process an alert record and signal appropriate condition.
   RECORD-LAYER, if provided, is used to send response alerts before erroring."
  (when (< (length content) 2)
    ;; Send decode_error alert for malformed alerts
    (when record-layer
      (handler-case
          (record-layer-write-alert record-layer +alert-level-fatal+ +alert-decode-error+)
        (error () nil)))
    (error 'tls-error :message ":BAD_ALERT: Alert too short"))
  ;; An alert record must be exactly 2 bytes - reject "double alerts"
  (when (> (length content) 2)
    (when record-layer
      (handler-case
          (record-layer-write-alert record-layer +alert-level-fatal+ +alert-decode-error+)
        (error () nil)))
    (error 'tls-error :message ":BAD_ALERT: Alert record too long"))
  (let ((level (aref content 0))
        (description (aref content 1)))
    ;; RFC 9846 section 6 retains AlertLevel only for TLS 1.2 compatibility:
    ;; receivers MUST ignore it. AlertDescription alone determines semantics.
    (cond
      ((= description +alert-close-notify+)
       (when record-layer
         (setf (record-layer-peer-close-received-p record-layer) t)
         ;; RFC 9846 section 6.1 makes the two write directions independent and
         ;; does not carry TLS 1.2's mandatory reciprocal-alert rule. We choose
         ;; to close our still-open write side immediately. The independent
         ;; local flag makes that one-shot policy safe when a stream handler
         ;; also observes the clean-close condition.
         (handler-case
             (record-layer-write-alert record-layer
                                       +alert-level-warning+
                                       +alert-close-notify+)
           (error () nil)))
       (error 'tls-connection-closed :clean t))
      ((= description +alert-user-canceled+)
       ;; RFC 9846 section 6.1 permits recipients to ignore user_canceled.
       nil)
      (t
       ;; Every other known or unknown description is terminal peer input.
       ;; Never manufacture an alert in response, regardless of the legacy
       ;; level byte supplied by the peer.
       (when record-layer
         (setf (record-layer-peer-fatal-alert-received-p record-layer) t))
       (error 'tls-alert-error :level level :description description)))))
