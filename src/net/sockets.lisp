;;;; sockets.lisp — non-blocking TCP handle layer on the Phase-05 serve-event reactor
;;;; (PLAN.md Phase 16, §3.2). Callback-based (CL closures now; Phase 17+ marshals to
;;;; JS). All reactor-add/-remove happen on the loop thread (serve-event dispatches an
;;;; fd handler only for a registration made by the thread running it — the run-loop
;;;; thread; set up listeners before run-loop or inside a handler). Verified sb-bsd-
;;;; sockets facts (Appendix C.7): non-blocking connect signals operation-in-progress;
;;;; accept/recv return NIL on EAGAIN; send returns a partial count when the buffer
;;;; fills; accepted sockets are NOT non-blocking by default (we set it); send :nosignal
;;;; turns write-to-closed-peer into a catchable socket-error (no SIGPIPE).

(in-package :clun.net)

(defparameter *default-read-size* 262144
  "Bytes drained per readable event's recv call. Larger = fewer socket-receive calls
(each has FFI overhead) on a busy stream → higher single-connection throughput.")

(define-condition socket-open-error (error)
  ((code :initarg :code :reader socket-open-error-code)
   (op :initarg :op :reader socket-open-error-op))
  (:report (lambda (c s) (format s "~a: ~a" (socket-open-error-op c) (socket-open-error-code c)))))

;;; --- error code mapping (socket-error subclass -> JS-visible errno name) -----

(defun socket-error-code (condition &optional (default "EIO"))
  "Map an sb-bsd-sockets condition to a JS-visible errno string."
  (typecase condition
    (sb-bsd-sockets:connection-refused-error "ECONNREFUSED")
    (sb-bsd-sockets:network-unreachable-error "ENETUNREACH")
    (sb-bsd-sockets:operation-timeout-error "ETIMEDOUT")
    (sb-bsd-sockets:not-connected-error "ENOTCONN")
    (sb-bsd-sockets:address-in-use-error "EADDRINUSE")
    (sb-bsd-sockets:operation-not-permitted-error "EPERM")
    (sb-bsd-sockets:invalid-argument-error "EINVAL")
    (sb-bsd-sockets:bad-file-descriptor-error "EBADF")
    (sb-bsd-sockets:no-buffers-error "ENOBUFS")
    ;; the base socket-error carries no distinguishing subclass — on a TCP stream this
    ;; is dominated by write-to-closed-peer (broken pipe); report EPIPE unless overridden.
    (sb-bsd-sockets:socket-error default)
    (t default)))

;;; --- the tcp handle ---------------------------------------------------------

(defstruct (tcp (:conc-name tcp-) (:predicate tcp-p))
  socket fd loop handle
  (state :open)                         ; :connecting :open :closed
  read-handler write-handler            ; reactor handler objects (or NIL)
  (write-queue '()) (write-tail '())    ; FIFO of (cons octets offset) chunks pending
  (queued-bytes 0 :type integer)
  (reading nil)                         ; is the :input handler registered?
  (backpressured nil)                   ; a partial send registered :output → on-drain owed
  (close-after-drain nil)               ; tcp-shutdown: close once the write queue empties
  (read-buf nil)
  on-connect on-data on-close on-error on-drain)

(defstruct (listener (:conc-name listener-) (:predicate listener-p))
  socket fd loop handle address port on-connection (read-handler nil) (closed nil))

;;; --- low-level helpers ------------------------------------------------------

(defun %nonblock (socket) (setf (sb-bsd-sockets:non-blocking-mode socket) t) socket)

(defun %inet-address (host ipv6)
  (if ipv6 (sb-bsd-sockets:make-inet6-address host) (sb-bsd-sockets:make-inet-address host)))

(defun %new-socket (ipv6)
  (make-instance (if ipv6 'sb-bsd-sockets:inet6-socket 'sb-bsd-sockets:inet-socket)
                 :type :stream :protocol :tcp))

(defun %safe-close-socket (socket)
  (ignore-errors (sb-bsd-sockets:socket-close socket :abort t)))

;;; --- reading ----------------------------------------------------------------

(defun %start-reading (tcp)
  "Register the :input reactor handler (idempotent)."
  (unless (tcp-reading tcp)
    (setf (tcp-reading tcp) t
          (tcp-read-handler tcp)
          (lp:reactor-add (tcp-loop tcp) (tcp-fd tcp) :input
                          (lambda (fd) (declare (ignore fd)) (%on-readable tcp))))))

(defun %stop-reading (tcp)
  (when (tcp-read-handler tcp)
    (lp:reactor-remove (tcp-loop tcp) (tcp-read-handler tcp))
    (setf (tcp-read-handler tcp) nil (tcp-reading tcp) nil)))

(defun %on-readable (tcp)
  "Drain readable data: recv until EAGAIN (NIL) or EOF (0). Delivers to on-data."
  (when (eq (tcp-state tcp) :open)
    (let ((buf (or (tcp-read-buf tcp)
                   (setf (tcp-read-buf tcp)
                         (make-array *default-read-size* :element-type '(unsigned-byte 8))))))
      (handler-case
          (loop
            (multiple-value-bind (b n)
                (sb-bsd-sockets:socket-receive (tcp-socket tcp) buf *default-read-size*
                                               :element-type '(unsigned-byte 8))
              (declare (ignore b))
              (cond
                ((null n) (return))              ; EAGAIN — nothing more for now
                ((zerop n) (%finish-close tcp nil) (return))   ; orderly EOF (peer closed)
                (t (when (tcp-on-data tcp)
                     (funcall (tcp-on-data tcp) tcp (subseq buf 0 n)))
                   (unless (eq (tcp-state tcp) :open) (return))))))
        (sb-bsd-sockets:interrupted-error ())    ; EINTR — try again next readiness
        (sb-bsd-sockets:socket-error (e) (%fail tcp e))))))

;;; --- writing (queue + backpressure) -----------------------------------------

(defun tcp-write (tcp octets)
  "Queue OCTETS (a byte vector) for sending; flush as much as the socket accepts now.
Returns the number of bytes still queued (backpressure signal). A zero-length write is
a no-op (socket-send rejects an empty/non-(unsigned-byte 8) vector — CASE-FAILURE).

Off the loop thread (an async handler writing after an await) the queue mutation + flush
are marshalled onto the loop thread; the return is then only an advisory snapshot."
  (if (lp:loop-on-thread-p (tcp-loop tcp))
      (%do-write tcp octets)
      (progn (lp:loop-post (tcp-loop tcp) (lambda () (%do-write tcp octets)))
             (tcp-queued-bytes tcp))))

(defun %do-write (tcp octets)
  (when (and (eq (tcp-state tcp) :open) (plusp (length octets)))
    (let ((chunk (cons octets 0)))
      (if (tcp-write-tail tcp)
          (setf (cdr (tcp-write-tail tcp)) (list chunk) (tcp-write-tail tcp) (cdr (tcp-write-tail tcp)))
          (setf (tcp-write-queue tcp) (list chunk) (tcp-write-tail tcp) (tcp-write-queue tcp))))
    (incf (tcp-queued-bytes tcp) (length octets))
    (%flush tcp))
  (tcp-queued-bytes tcp))

(defun %flush (tcp)
  "Send queued chunks until the kernel buffer is full (partial send) or the queue drains.
Registers the :output handler while there is a backlog; drains it + fires on-drain when empty."
  (when (eq (tcp-state tcp) :open)
    (handler-case
        (loop while (tcp-write-queue tcp) do
          (let* ((chunk (car (tcp-write-queue tcp)))
                 (octets (car chunk)) (off (cdr chunk)) (len (- (length octets) off))
                 (sent (sb-bsd-sockets:socket-send (tcp-socket tcp) (%chunk-view octets off) len
                                                   :nosignal t)))
            (let ((sent (or sent 0)))            ; NIL (rare) = 0 sent
              (decf (tcp-queued-bytes tcp) sent)
              (cond
                ((>= (+ off sent) (length octets))  ; whole chunk gone
                 (pop (tcp-write-queue tcp))
                 (unless (tcp-write-queue tcp) (setf (tcp-write-tail tcp) nil)))
                (t (setf (cdr chunk) (+ off sent)) ; partial — buffer full
                   (%want-writable tcp)
                   (return-from %flush))))))
      (sb-bsd-sockets:interrupted-error () (%want-writable tcp) (return-from %flush))
      (sb-bsd-sockets:socket-error (e) (%fail tcp e) (return-from %flush))
      ;; any other condition from a send (e.g. a malformed chunk) fails the connection
      ;; cleanly rather than escaping the loop thread as a raw backtrace (§6).
      (error (e) (%fail tcp e) (return-from %flush)))
    ;; queue drained: stop watching for writable; fire on-drain ONLY if we had actually
    ;; backpressured (Node 'drain' is an edge, not "queue is empty right now").
    (%stop-writable tcp)
    (when (tcp-backpressured tcp)
      (setf (tcp-backpressured tcp) nil)
      (when (tcp-on-drain tcp) (funcall (tcp-on-drain tcp) tcp)))
    ;; flush-then-close (tcp-shutdown): the queue is now empty → close.
    (when (tcp-close-after-drain tcp) (%finish-close tcp nil))))

(defun %chunk-view (octets off)
  "A zero-copy view of OCTETS from OFF (socket-send accepts a displaced array — verified).
Copying here would be O(n) per partial send → O(n²) to drain a large write."
  (if (zerop off) octets
      (make-array (- (length octets) off) :element-type '(unsigned-byte 8)
                  :displaced-to octets :displaced-index-offset off)))

(defun %want-writable (tcp)
  (setf (tcp-backpressured tcp) t)      ; a backlog now exists → on-drain is owed
  (unless (tcp-write-handler tcp)
    (setf (tcp-write-handler tcp)
          (lp:reactor-add (tcp-loop tcp) (tcp-fd tcp) :output
                          (lambda (fd) (declare (ignore fd)) (%flush tcp))))))

(defun %stop-writable (tcp)
  (when (tcp-write-handler tcp)
    (lp:reactor-remove (tcp-loop tcp) (tcp-write-handler tcp))
    (setf (tcp-write-handler tcp) nil)))

;;; --- close / error ----------------------------------------------------------

(defun %fail (tcp condition)
  (let ((code (socket-error-code condition)))
    (when (tcp-on-error tcp) (funcall (tcp-on-error tcp) tcp code))
    (%finish-close tcp code)))

(defun %finish-close (tcp code)
  "Tear down the reactor registrations, close the fd, deactivate the handle, fire on-close."
  (unless (eq (tcp-state tcp) :closed)
    (setf (tcp-state tcp) :closed)
    (%stop-reading tcp)
    (%stop-writable tcp)
    (%safe-close-socket (tcp-socket tcp))
    (when (tcp-handle tcp) (lp:handle-deactivate (tcp-handle tcp)))
    (when (tcp-on-close tcp) (funcall (tcp-on-close tcp) tcp code))))

(defun tcp-close (tcp)
  "Close now (drops any unflushed queue). For a graceful flush-then-close use tcp-shutdown.
Marshalled onto the loop thread (reactor-remove + fd close must not run off it — an abort
callback firing on a coroutine thread would otherwise leave a stale handler on a reused fd)."
  (lp:run-on-loop (tcp-loop tcp)
    (lambda () (unless (eq (tcp-state tcp) :closed) (%finish-close tcp nil))))
  (values))

(defun tcp-shutdown (tcp)
  "Graceful close: if the write queue is already empty, close now; otherwise close as
soon as it drains (the response's bytes are guaranteed to go out first)."
  (lp:run-on-loop (tcp-loop tcp)
    (lambda ()
      (when (eq (tcp-state tcp) :open)
        (if (plusp (tcp-queued-bytes tcp))
            (setf (tcp-close-after-drain tcp) t)
            (unless (eq (tcp-state tcp) :closed) (%finish-close tcp nil))))))
  (values))

;;; --- wrapping an established socket -----------------------------------------

(defun %wrap (loop socket &key on-data on-close on-error on-drain (state :open))
  "Wrap a connected SOCKET into a tcp: non-blocking + TCP_NODELAY, a ref'd loop handle."
  (%nonblock socket)
  (ignore-errors (setf (sb-bsd-sockets:sockopt-tcp-nodelay socket) t))
  ;; larger socket buffers → more bytes per readiness → fewer reactor round-trips on a
  ;; busy stream (the kernel clamps to net.core.{r,w}mem_max). Best-effort.
  (ignore-errors (setf (sb-bsd-sockets:sockopt-receive-buffer socket) (* 4 1024 1024)))
  (ignore-errors (setf (sb-bsd-sockets:sockopt-send-buffer socket) (* 4 1024 1024)))
  (let* ((fd (sb-bsd-sockets:socket-file-descriptor socket))
         (h (lp:make-handle loop :kind :socket))
         (tcp (make-tcp :socket socket :fd fd :loop loop :handle h :state state
                        :on-data on-data :on-close on-close :on-error on-error :on-drain on-drain)))
    (lp:handle-activate h)              ; a live socket keeps the loop alive
    tcp))

(defun tcp-peer (tcp)
  "(values address-vector port) of the peer, or NIL."
  (ignore-errors (sb-bsd-sockets:socket-peername (tcp-socket tcp))))
(defun tcp-local (tcp)
  (ignore-errors (sb-bsd-sockets:socket-name (tcp-socket tcp))))

;;; --- listener ---------------------------------------------------------------

(defun tcp-listen (loop host port &key ipv6 (backlog 128) on-connection)
  "Bind + listen on HOST:PORT (PORT 0 → an ephemeral port, read back via listener-port).
ON-CONNECTION is (lambda (tcp)) for each accepted connection — set its on-data/on-close
inside; reading starts after it returns."
  (let ((socket (%new-socket ipv6)))
    (handler-case
        (progn
          (setf (sb-bsd-sockets:sockopt-reuse-address socket) t)
          (%nonblock socket)
          (sb-bsd-sockets:socket-bind socket (%inet-address host ipv6) port)
          (sb-bsd-sockets:socket-listen socket backlog)
          (multiple-value-bind (addr real-port) (sb-bsd-sockets:socket-name socket)
            (let* ((fd (sb-bsd-sockets:socket-file-descriptor socket))
                   (h (lp:make-handle loop :kind :listener))
                   (l (make-listener :socket socket :fd fd :loop loop :handle h
                                     :address addr :port real-port :on-connection on-connection)))
              (lp:handle-activate h)
              ;; the accept handler must be registered on the loop thread (Clun.serve may
              ;; be called from an async function body — a coroutine thread).
              (lp:run-on-loop loop
                (lambda ()
                  (setf (listener-read-handler l)
                        (lp:reactor-add loop fd :input
                                        (lambda (fd) (declare (ignore fd)) (%on-acceptable l))))))
              l)))
      (sb-bsd-sockets:socket-error (e)
        (%safe-close-socket socket)
        (error 'socket-open-error :code (socket-error-code e) :op "listen")))))

(defun %on-acceptable (listener)
  "Accept every pending connection (until EAGAIN), wrap + hand to on-connection, start reading."
  (when (not (listener-closed listener))
    (loop
      (let ((child (handler-case (sb-bsd-sockets:socket-accept (listener-socket listener))
                     (sb-bsd-sockets:interrupted-error () nil)
                     (sb-bsd-sockets:socket-error () nil))))
        (unless child (return))          ; NIL = EAGAIN / no more pending
        (let ((tcp (%wrap (listener-loop listener) child)))
          (when (listener-on-connection listener)
            (funcall (listener-on-connection listener) tcp))
          (when (eq (tcp-state tcp) :open) (%start-reading tcp)))))))

(defun listener-close (listener)
  (lp:run-on-loop (listener-loop listener)
    (lambda ()
      (unless (listener-closed listener)
        (setf (listener-closed listener) t)
        (when (listener-read-handler listener)
          (lp:reactor-remove (listener-loop listener) (listener-read-handler listener)))
        (%safe-close-socket (listener-socket listener))
        (when (listener-handle listener) (lp:handle-deactivate (listener-handle listener))))))
  (values))

;;; --- connect ----------------------------------------------------------------

(defun tcp-connect (loop host port &key ipv6 on-connect on-data on-close on-error)
  "Non-blocking connect to HOST:PORT. ON-CONNECT (lambda (tcp)) fires once the connection
is established; a failure fires ON-ERROR with a code (ECONNREFUSED…) then closes.

The tcp handle is created + returned synchronously, but the connect syscall and its
reactor registration are marshalled onto the loop thread (tcp-connect is routinely
called from an async function body, i.e. a coroutine thread — see LP:RUN-ON-LOOP)."
  (let* ((socket (%new-socket ipv6))
         (tcp (%wrap loop socket :on-data on-data :on-close on-close :on-error on-error
                                 :state :connecting)))
    (setf (tcp-on-connect tcp) on-connect)
    (lp:run-on-loop loop
      (lambda ()
        (handler-case
            (progn
              (sb-bsd-sockets:socket-connect socket (%inet-address host ipv6) port)
              ;; connected synchronously (rare on loopback) — promote immediately
              (%complete-connect tcp))
          (sb-bsd-sockets:operation-in-progress ()
            ;; EINPROGRESS — writable readiness signals connect completion
            (setf (tcp-write-handler tcp)
                  (lp:reactor-add loop (tcp-fd tcp) :output
                                  (lambda (fd) (declare (ignore fd)) (%on-connect-writable tcp)))))
          (sb-bsd-sockets:socket-error (e) (%fail tcp e)))))
    tcp))

(defun %on-connect-writable (tcp)
  "Writable after EINPROGRESS: peername succeeds → connected; else surface the real error."
  (%stop-writable tcp)
  (if (ignore-errors (sb-bsd-sockets:socket-peername (tcp-socket tcp)))
      (%complete-connect tcp)
      ;; a failed async connect: a recv surfaces the specific errno (e.g. ECONNREFUSED)
      (handler-case
          (progn (sb-bsd-sockets:socket-receive (tcp-socket tcp)
                                                (make-array 1 :element-type '(unsigned-byte 8)) 1
                                                :element-type '(unsigned-byte 8))
                 (%fail-code tcp "ECONNREFUSED"))
        (sb-bsd-sockets:socket-error (e) (%fail tcp e)))))

(defun %complete-connect (tcp)
  (when (eq (tcp-state tcp) :connecting)
    (setf (tcp-state tcp) :open)
    (when (tcp-on-connect tcp) (funcall (tcp-on-connect tcp) tcp))
    (when (eq (tcp-state tcp) :open)
      (%start-reading tcp)
      (%flush tcp))))                    ; send anything queued during on-connect

(defun %fail-code (tcp code)
  (when (tcp-on-error tcp) (funcall (tcp-on-error tcp) tcp code))
  (%finish-close tcp code))
