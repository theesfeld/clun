;;;; sbcl-compat.lisp — the ONE place internal/low-level SBCL APIs live (PLAN.md
;;;; §3.2 GC discipline, §6). Phase 05 needs a self-pipe (the cross-thread /
;;;; signal-context wakeup for serve-event, Appendix C.5) and the poll-backend
;;;; probe. Everything here is pure Lisp: sb-posix/sb-unix/sb-sys, no foreign code.

(in-package :clun.sys)

;;; --- self-pipe (Appendix C.5: signals don't wake serve-event; a byte does) ----

(defstruct (self-pipe (:constructor %make-self-pipe))
  (read-fd 0 :type fixnum)
  (write-fd 0 :type fixnum)
  read-stream)                          ; loop-thread-only drain

(defun %set-nonblocking (fd)
  (let ((flags (sb-posix:fcntl fd sb-posix:f-getfl)))
    (sb-posix:fcntl fd sb-posix:f-setfl (logior flags sb-posix:o-nonblock))))

(defun set-nonblocking (fd)
  "Put FD into O_NONBLOCK mode (for reactor-driven child pipes — Phase 24)."
  (%set-nonblocking fd) fd)

(defun make-self-pipe ()
  "A non-blocking pipe: read end wrapped as a byte fd-stream (drained only by the
loop thread), write end kept raw for allocation-free wakes from any context."
  (multiple-value-bind (r w) (sb-posix:pipe)
    (%set-nonblocking r)
    (%set-nonblocking w)                ; full pipe -> wake is dropped (one is already pending)
    (%make-self-pipe
     :read-fd r :write-fd w
     :read-stream (sb-sys:make-fd-stream r :input t :element-type '(unsigned-byte 8)
                                           :buffering :none :name "clun self-pipe"))))

;; A single shared byte: the kernel only reads it, and pinning is thread-local, so
;; concurrent wakes are safe (a 1-byte pipe write is atomic).
(sb-ext:defglobal *wake-byte* (make-array 1 :element-type '(unsigned-byte 8) :initial-element 1))

(defun self-pipe-wake (sp)
  "Write one wake byte. Allocation-free + syscall-only, so this is legal from a
signal handler / run-program :status-hook (§6 iron rule). EAGAIN (full pipe) is a
no-op: a wake is already pending. unix-write never signals on EAGAIN — it returns
NIL — so no condition is consed here."
  (let ((buf *wake-byte*))
    (sb-sys:with-pinned-objects (buf)
      (sb-unix:unix-write (self-pipe-write-fd sp) buf 0 1))
    nil))

(defun self-pipe-drain (sp)
  "Discard all pending wake bytes. Loop thread only."
  (let ((s (self-pipe-read-stream sp)))
    (loop while (listen s) do (read-byte s nil nil))))

(defun self-pipe-close (sp)
  (ignore-errors (close (self-pipe-read-stream sp)))    ; closes read-fd
  (ignore-errors (sb-posix:close (self-pipe-write-fd sp))))

;;; --- reactor capability probe (Appendix C.5) ---------------------------------

(defun poll-backend-p ()
  "True iff this SBCL's serve-event uses poll() — no FD_SETSIZE cap, fd>1023 ok."
  (let ((unix-poll (find-symbol "UNIX-POLL" :sb-unix)))
    (and unix-poll (fboundp unix-poll) t)))
