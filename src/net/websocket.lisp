;;;; websocket.lisp — Phase 51 scaffold: pure-CL WebSocket types and fail-closed errors.
;;;; Full RFC 6455 framing, handshake, and Bun-shaped Pub/Sub land in later milestones.
;;;; See docs/design/phase-51.md. No foreign libraries; no silent half-implementation.

(in-package :clun.websocket)

;;; --- RFC 6455 opcodes (scaffold constants for later framing work) -----------

(defconstant +opcode-continuation+ #x0)
(defconstant +opcode-text+         #x1)
(defconstant +opcode-binary+       #x2)
(defconstant +opcode-close+        #x8)
(defconstant +opcode-ping+         #x9)
(defconstant +opcode-pong+         #xA)

;; String constants use DEFPARAMETER: SBCL DEFCONSTANT rejects non-EQL reload of
;; equal string literals (compile-time vs load-time objects).
(defparameter +ws-guid+ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  "RFC 6455 accept-key material (used by a future handshake implementation).")

(defconstant +default-max-payload-bytes+ #.(* 16 1024 1024)
  "Bun-shaped default max message size (16 MiB) for a future bounded reassembly path.")

(defconstant +default-backpressure-limit+ #.(* 16 1024 1024)
  "Bun-shaped default per-connection buffered send budget.")
;;; --- Conditions -------------------------------------------------------------

(define-condition websocket-error (error)
  ((message :initarg :message :reader websocket-error-message))
  (:report (lambda (c s)
             (format s "WebSocket error: ~a" (websocket-error-message c)))))

(define-condition websocket-unsupported (websocket-error)
  ()
  (:report (lambda (c s)
             (format s "~a" (websocket-error-message c)))))

(defun websocket-not-implemented-message (&optional (surface "WebSocket"))
  "Stable user-facing text for fail-closed Phase 51 stubs."
  (format nil "~a is not implemented in Clun (Phase 51). ~
               Pure Common Lisp WebSocket is designed (docs/design/phase-51.md); ~
               the server and Pub/Sub stack are not available yet."
          surface))

(defun signal-websocket-unsupported (&optional (surface "WebSocket"))
  "Signal WEBSOCKET-UNSUPPORTED for pure-CL callers (tests, future framing)."
  (error 'websocket-unsupported
         :message (websocket-not-implemented-message surface)))

;;; --- Frame / handler type scaffolds (unfilled protocol slots) ---------------

(defstruct (ws-frame
            (:constructor make-ws-frame)
            (:conc-name ws-frame-))
  "RFC 6455 frame header+payload scaffold. Not parsed or written in M0."
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
  "Mirror of Bun WebSocketHandler option slots for a future serve compile path."
  (max-payload-length +default-max-payload-bytes+ :type (integer 0 *))
  (backpressure-limit +default-backpressure-limit+ :type (integer 0 *))
  (close-on-backpressure-limit nil :type boolean)
  (idle-timeout-seconds 120 :type (integer 0 *))
  (publish-to-self nil :type boolean)
  (send-pings t :type boolean)
  (permessage-deflate nil))

;;; --- M0 protocol entry points (fail closed) ---------------------------------

(defun handshake-accept-key (sec-websocket-key)
  "Future: SHA-1(key||GUID) base64. M0: fail closed."
  (declare (ignore sec-websocket-key))
  (signal-websocket-unsupported "WebSocket handshake"))

(defun encode-frame (frame)
  "Future: RFC 6455 frame writer. M0: fail closed."
  (declare (ignore frame))
  (signal-websocket-unsupported "WebSocket framing"))

(defun decode-frame (octets &key (start 0) end)
  "Future: RFC 6455 frame reader. M0: fail closed."
  (declare (ignore octets start end))
  (signal-websocket-unsupported "WebSocket framing"))
