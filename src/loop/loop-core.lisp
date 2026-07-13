;;;; loop-core.lisp — the event-loop struct, the JS-facing queues, the handle
;;;; refcount model, and the microtask drain (PLAN.md Phase 05, §3.2). Callbacks
;;;; are opaque CL thunks in Phase 05 (the gate's "stub queue"); Phase 06 wires JS
;;;; jobs into these same queues without touching this contract.

(in-package :clun.loop)

;;; --- monotonic time (internal-time-units-per-second = 1e6 on this host) -------

(declaim (inline now-ms))
(defun now-ms ()
  (values (floor (get-internal-real-time) (floor internal-time-units-per-second 1000))))

;;; --- O(1) FIFO (cons head/tail) ----------------------------------------------

(defstruct (fifo (:constructor make-fifo))
  head tail (count 0 :type fixnum))

(declaim (inline fifo-empty-p))
(defun fifo-empty-p (q) (null (fifo-head q)))

(defun fifo-push (q x)
  (let ((cell (cons x nil)))
    (if (fifo-tail q) (setf (cdr (fifo-tail q)) cell) (setf (fifo-head q) cell))
    (setf (fifo-tail q) cell))
  (incf (fifo-count q))
  x)

(defun fifo-pop (q)
  "(values item present-p)."
  (let ((cell (fifo-head q)))
    (if cell
        (progn (setf (fifo-head q) (cdr cell))
               (unless (fifo-head q) (setf (fifo-tail q) nil))
               (decf (fifo-count q))
               (car cell))
        nil)))

;;; --- the loop ----------------------------------------------------------------

(defstruct (event-loop (:constructor %make-event-loop) (:conc-name el-))
  self-pipe
  mailbox                               ; sb-concurrency:mailbox — cross-thread posts
  (ref-count 0 :type fixnum)
  (next-tick (make-fifo))               ; process.nextTick — drained first, fully
  (microtasks (make-fifo))              ; Promise jobs (P06)
  (tasks (make-fifo))                   ; macrotask/immediate stub
  timers                                ; timer-heap (timers.lisp)
  (timer-seq 0 :type fixnum)
  (fd-handlers '())                     ; (fd . sb-sys-handler) alist (reactor.lisp)
  signal-state                          ; signals.lisp
  workers                               ; worker-pool (workers.lisp)
  (thread nil)                          ; the thread running run-loop (reactor-thread affinity)
  (running nil)
  (stop-requested nil))

;;; --- handles / refcounting (§3.2 lifetime) -----------------------------------
;;; A handle contributes 1 to the loop's ref-count exactly while it is both refd
;;; and active. Ref'd timers, in-flight worker jobs, and (later) sockets own one.

(defstruct (handle (:constructor %make-handle) (:conc-name handle-))
  loop (refd t) (active nil) (counted nil) (kind :generic))

(defun make-handle (loop &key (refd t) (kind :generic))
  (%make-handle :loop loop :refd refd :kind kind))

(defun %handle-recount (h)
  (let ((should (and (handle-refd h) (handle-active h))))
    (cond ((and should (not (handle-counted h)))
           (setf (handle-counted h) t) (incf (el-ref-count (handle-loop h))))
          ((and (not should) (handle-counted h))
           (setf (handle-counted h) nil) (decf (el-ref-count (handle-loop h)))))))

(defun handle-activate (h)   (setf (handle-active h) t)   (%handle-recount h))
(defun handle-deactivate (h) (setf (handle-active h) nil) (%handle-recount h))
(defun handle-ref (h)        (setf (handle-refd h) t)     (%handle-recount h))
(defun handle-unref (h)      (setf (handle-refd h) nil)   (%handle-recount h))

;;; --- queues + microtask drain ------------------------------------------------

(defun enqueue-next-tick (loop thunk) (fifo-push (el-next-tick loop) thunk))
(defun enqueue-microtask (loop thunk) (fifo-push (el-microtasks loop) thunk))
(defun enqueue-task      (loop thunk) (fifo-push (el-tasks loop) thunk))

(defun drain-microtasks (loop)
  "Drain the nextTick queue fully, then run ONE microtask, then repeat — so
nextTicks scheduled by a microtask run before the next microtask (Node semantics)."
  (let ((nt (el-next-tick loop)) (mt (el-microtasks loop)))
    (loop
      (loop until (fifo-empty-p nt) do (funcall (fifo-pop nt)))
      (if (fifo-empty-p mt) (return) (funcall (fifo-pop mt))))))

(defun run-at-dispatch (loop thunk)
  "A loop dispatch point: run one callback, then drain microtasks (§3.2)."
  (funcall thunk)
  (drain-microtasks loop))

;;; --- liveness ----------------------------------------------------------------

(declaim (ftype (function (t) t) pending-signals-p))    ; defined in signals.lisp

(defun immediate-work-p (loop)
  "Queued work that MUST run before the loop may exit. Beyond the three JS queues
this includes a non-empty cross-thread mailbox and any undrained signal delta —
both are already-accepted work (a completion posted by a worker, an external
loop-post, or a signal delivered at shutdown) that would otherwise be dropped."
  (or (not (fifo-empty-p (el-tasks loop)))
      (not (fifo-empty-p (el-microtasks loop)))
      (not (fifo-empty-p (el-next-tick loop)))
      (plusp (sb-concurrency:mailbox-count (el-mailbox loop)))
      (pending-signals-p loop)))

(defun loop-alive-p (loop)
  "The loop runs while any handle keeps it alive OR immediate work is queued.
Unref'd timers/handles do NOT keep it alive (they only fire if it is running)."
  (or (plusp (el-ref-count loop)) (immediate-work-p loop)))

;;; --- thread-safe post (used by workers, signals-free external producers) ------

(defun loop-post (loop thunk)
  "Enqueue THUNK to run on the loop thread and wake the loop. Safe from any thread."
  (sb-concurrency:send-message (el-mailbox loop) thunk)
  (clun.sys:self-pipe-wake (el-self-pipe loop)))

(defvar *on-foreign-thread* nil
  "Bound to T on a coroutine's own thread (an async function body). serve-event dispatches
an fd handler ONLY for a registration made by the thread that runs it, so a coroutine
thread must never touch the reactor directly — even before run-loop has started, since the
loop will run on a DIFFERENT (driver) thread. The main/driver thread leaves this NIL, so
its pre-run setup (the classic `register listeners then run-loop` pattern) stays synchronous.")

(defun loop-on-thread-p (loop)
  "T iff the caller may touch LOOP's reactor synchronously. When the loop is running, that
means being its run-loop thread. When it is NOT yet running, the caller is doing setup that
will be dispatched once run-loop starts — safe UNLESS we are on a coroutine thread (the loop
will run elsewhere), in which case the op must be marshalled via LOOP-POST."
  (let ((th (el-thread loop)))
    (if th
        (eq th sb-thread:*current-thread*)
        (not *on-foreign-thread*))))

(defun run-on-loop (loop thunk)
  "Run THUNK on LOOP's thread: directly if already there, else marshal via LOOP-POST.
Deferred thunks run at the next PROCESS-COMPLETIONS; the queued post keeps the loop
alive in the meantime (IMMEDIATE-WORK-P sees the mailbox)."
  (if (loop-on-thread-p loop) (funcall thunk) (loop-post loop thunk)))
