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
  (lifecycle-lock (sb-thread:make-mutex :name "clun-loop-lifecycle"))
  (destruction-waitqueue (sb-thread:make-waitqueue :name "clun-loop-destruction"))
  (resources '())                       ; loop-resource tokens, newest first
  (extensions (make-hash-table :test #'eq)) ; loop-owned subsystem state
  (posters 0 :type (unsigned-byte 64))   ; in-flight lock-free LOOP-POST producers
  (destroyer nil)                       ; thread performing synchronous teardown
  (destroying nil)
  (destroyed nil)
  signal-state                          ; signals.lisp
  workers                               ; worker-pool (workers.lisp)
  (thread nil)                          ; the thread running run-loop (reactor-thread affinity)
  (reactor-thread nil)                  ; persistent owner of user fd registrations
  (running nil)
  (stop-requested nil))

;;; --- explicitly owned OS resources -----------------------------------------

(defstruct (loop-resource (:constructor %make-loop-resource (loop owner cleanup)))
  loop owner cleanup (active t))

(defmacro with-loop-lifecycle-lock ((loop) &body body)
  `(sb-thread:with-mutex ((el-lifecycle-lock ,loop)) ,@body))

(defun %ensure-loop-open-locked (loop operation)
  (when (or (el-destroying loop) (el-destroyed loop))
    (error "cannot ~a on a destroyed event loop" operation))
  loop)

(defun loop-extension (loop key)
  "Return the loop-owned subsystem value stored under KEY, or NIL."
  (with-loop-lifecycle-lock (loop)
    (gethash key (el-extensions loop))))

(defun (setf loop-extension) (value loop key)
  "Store VALUE as subsystem state owned by LOOP."
  (with-loop-lifecycle-lock (loop)
    (%ensure-loop-open-locked loop "store loop extension state")
    (setf (gethash key (el-extensions loop)) value)))

(defun begin-loop-destruction (loop)
  "Atomically prevent new work/resource registration. Return true only to the
caller responsible for performing destruction. Concurrent idempotent callers
wait until that caller has completed the synchronous teardown."
  (with-loop-lifecycle-lock (loop)
    (loop
      (cond
        ((el-destroyed loop) (return nil))
        ((el-destroying loop)
         ;; A cleanup callback may defensively destroy its own loop. It is already
         ;; owned by this thread, so waiting here would deadlock.
         (when (eq (el-destroyer loop) sb-thread:*current-thread*)
           (return nil))
         (sb-thread:condition-wait (el-destruction-waitqueue loop)
                                   (el-lifecycle-lock loop)))
        ((el-running loop)
         (error "cannot destroy a running event loop; stop it and wait for RUN-LOOP"))
        ((and (el-fd-handlers loop)
              (el-reactor-thread loop)
              (not (eq (el-reactor-thread loop) sb-thread:*current-thread*))
              (sb-thread:thread-alive-p (el-reactor-thread loop)))
         (error "cannot destroy an event loop with live fd handlers off its reactor thread"))
        (t
         (setf (el-destroyer loop) sb-thread:*current-thread*
               (el-destroying loop) t)
         (return t))))))

(defun finish-loop-destruction (loop)
  (with-loop-lifecycle-lock (loop)
    (setf (el-destroyer loop) nil
          (el-destroying loop) nil
          (el-destroyed loop) t)
    (sb-thread:condition-broadcast (el-destruction-waitqueue loop)))
  (values))

(defun %register-loop-resource-locked (loop owner cleanup)
  (%ensure-loop-open-locked loop "register a resource")
  (when (find owner (el-resources loop) :key #'loop-resource-owner :test #'eq)
    (error "loop resource is already registered: ~s" owner))
  (let ((resource (%make-loop-resource loop owner cleanup)))
    (push resource (el-resources loop))
    resource))

(defun register-loop-resource (loop owner cleanup)
  "Keep OWNER reachable until normal close or loop destruction, and remember the
synchronous CLEANUP that makes its OS lifetime end explicitly. Reactor registrations
alone are not ownership: dropping a handler while leaving an SBCL socket to its GC
finalizer can close a later, recycled descriptor."
  (check-type cleanup function)
  (with-loop-lifecycle-lock (loop)
    (%register-loop-resource-locked loop owner cleanup)))

(defun %unregister-loop-resource-locked (resource)
  (when (and resource (loop-resource-active resource))
    (let ((loop (loop-resource-loop resource)))
      (setf (loop-resource-active resource) nil
            (el-resources loop)
            (delete resource (el-resources loop) :test #'eq))))
  resource)

(defun unregister-loop-resource (resource)
  "Release RESOURCE after its owner has been explicitly closed. Idempotent."
  (when resource
    (let ((loop (loop-resource-loop resource)))
      (with-loop-lifecycle-lock (loop)
        (%unregister-loop-resource-locked resource))))
  resource)

(defun close-loop-resources (loop)
  "Close every still-owned resource after reactor handlers are detached and before
the self-pipe is torn down.
The registry is detached under the lifecycle lock and callbacks run outside it, so a
cleanup can safely release its own token. One failure must not strand later resources."
  (let ((resources
          (with-loop-lifecycle-lock (loop)
            (let ((owned (el-resources loop)))
              (dolist (resource owned)
                (setf (loop-resource-active resource) nil))
              (setf (el-resources loop) nil)
              owned))))
    (dolist (resource resources)
      (ignore-errors (funcall (loop-resource-cleanup resource)))))
  (values))

;;; --- handles / refcounting (§3.2 lifetime) -----------------------------------
;;; A handle contributes 1 to the loop's ref-count exactly while it is both refd
;;; and active. Ref'd timers, in-flight worker jobs, and (later) sockets own one.

(defstruct (handle (:constructor %make-handle) (:conc-name handle-))
  loop (refd t) (active nil) (counted nil) (kind :generic))

(defun make-handle (loop &key (refd t) (kind :generic))
  (%make-handle :loop loop :refd refd :kind kind))

(defun %handle-recount-locked (h)
  (let ((should (and (handle-refd h) (handle-active h))))
    (cond ((and should (not (handle-counted h)))
           (setf (handle-counted h) t) (incf (el-ref-count (handle-loop h))))
          ((and (not should) (handle-counted h))
           (setf (handle-counted h) nil) (decf (el-ref-count (handle-loop h)))))))

(defun %handle-activate-locked (h)
  (%ensure-loop-open-locked (handle-loop h) "activate a handle")
  (setf (handle-active h) t)
  (%handle-recount-locked h))

(defun %handle-deactivate-locked (h)
  (setf (handle-active h) nil)
  (%handle-recount-locked h))

(defun handle-activate (h)
  (with-loop-lifecycle-lock ((handle-loop h))
    (%handle-activate-locked h)))

(defun handle-deactivate (h)
  (with-loop-lifecycle-lock ((handle-loop h))
    (%handle-deactivate-locked h)))

(defun handle-ref (h)
  (with-loop-lifecycle-lock ((handle-loop h))
    (%ensure-loop-open-locked (handle-loop h) "reference a handle")
    (setf (handle-refd h) t)
    (%handle-recount-locked h)))

(defun handle-unref (h)
  (with-loop-lifecycle-lock ((handle-loop h))
    (setf (handle-refd h) nil)
    (%handle-recount-locked h)))

(defun %register-loop-handle-resource-locked (loop owner cleanup handle)
  "Register OWNER and activate HANDLE as one lifecycle admission."
  (unless (eq loop (handle-loop handle))
    (error "resource handle belongs to a different event loop"))
  (let ((resource (%register-loop-resource-locked loop owner cleanup)))
    (handler-case
        (progn
          (%handle-activate-locked handle)
          resource)
      (error (e)
        (%unregister-loop-resource-locked resource)
        (error e)))))

(defun register-loop-handle-resource (loop owner cleanup handle)
  "Atomically admit an owned resource and its active liveness handle.
Destruction observes either the complete pair or neither of them."
  (check-type cleanup function)
  (check-type handle handle)
  (with-loop-lifecycle-lock (loop)
    (%register-loop-handle-resource-locked loop owner cleanup handle)))

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
  ;; This path is used by run-program status hooks in interrupt context, so it must
  ;; never take a mutex. The producer count lets destruction wait out a poster that
  ;; passed the first state check before DESTROYING became visible.
  (when (or (el-destroying loop) (el-destroyed loop))
    (return-from loop-post nil))
  (sb-ext:atomic-incf (el-posters loop))
  (unwind-protect
       (unless (or (el-destroying loop) (el-destroyed loop))
         (sb-concurrency:send-message (el-mailbox loop) thunk)
         (clun.sys:self-pipe-wake (el-self-pipe loop))
         t)
    (sb-ext:atomic-incf (el-posters loop) -1)))

(defvar *on-foreign-thread* nil
  "Bound to T on a coroutine's own thread (an async function body). serve-event dispatches
an fd handler ONLY for a registration made by the thread that runs it, so a coroutine
thread must never touch the reactor directly — even before run-loop has started, since the
loop will run on a DIFFERENT (driver) thread. The main/driver thread leaves this NIL, so
its pre-run setup (the classic `register listeners then run-loop` pattern) stays synchronous.")

(defun loop-on-thread-p (loop)
  "T iff the caller may touch LOOP's reactor synchronously. A recorded reactor owner
persists after RUN-LOOP returns because its SBCL fd registrations are thread-local; only
that owner may mutate them. Before any owner is claimed, ordinary driver-thread setup is
synchronous, while coroutine-thread setup is marshalled through LOOP-POST."
  (let ((owner (or (el-thread loop) (el-reactor-thread loop))))
    (if owner
        (eq owner sb-thread:*current-thread*)
        (not *on-foreign-thread*))))

(defun run-on-loop (loop thunk)
  "Run THUNK on LOOP's thread: directly if already there, else marshal via LOOP-POST.
Deferred thunks run at the next PROCESS-COMPLETIONS; the queued post keeps the loop
alive in the meantime (IMMEDIATE-WORK-P sees the mailbox)."
  (if (loop-on-thread-p loop)
      (funcall thunk)
      (unless (loop-post loop thunk)
        (error "cannot schedule work on a destroyed event loop"))))
