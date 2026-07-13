;;;; reactor.lisp — serve-event wrapper (PLAN.md Phase 05, §3.2). fd readiness →
;;;; registered handler (which enqueues only; JS runs at dispatch points). Poll
;;;; backend verified (Appendix C.5). Sockets/pipes register here from Phase 16 on.

(in-package :clun.loop)

(defvar *reactor-poll-backend* nil
  "Set by PROBE-REACTOR at loop creation; T iff serve-event uses poll().")

(defun probe-reactor ()
  (setf *reactor-poll-backend* (clun.sys:poll-backend-p))
  (unless *reactor-poll-backend*
    (warn "clun.loop: serve-event lacks unix-poll — fd>1023 may hit FD_SETSIZE ~
           (Appendix C.5). Proceeding; sockets phase must revisit."))
  *reactor-poll-backend*)

(defun reactor-add (loop fd direction fn)
  "Register FN (called with FD) for DIRECTION (:input or :output) on FD."
  (let ((h (sb-sys:add-fd-handler fd direction fn)))
    (push (cons fd h) (el-fd-handlers loop))
    h))

(defun reactor-remove (loop handler)
  (sb-sys:remove-fd-handler handler)
  (setf (el-fd-handlers loop) (delete handler (el-fd-handlers loop) :key #'cdr))
  (values))

(defun %fd-closed-p (fd)
  "T iff FD is not a currently-open descriptor (fstat → EBADF). sb-posix is an allowed
SBCL contrib (§1.1)."
  (null (ignore-errors (sb-posix:fstat fd))))

(defun prune-closed-fd-handlers (loop)
  "Unregister every reactor handler whose fd has been closed; return the count pruned.
A handler left on a closed fd makes SBCL's serve-event signal a bad-fd error (verified),
which would otherwise kill the loop. This recovers from the narrow race where an fd is
closed before its handler is unregistered — a re-entrant close during dispatch, a peer
reset, or a GC finalizer closing an orphaned socket under memory pressure (§6). Only
handlers WE track (el-fd-handlers) are touched; the run-loop self-pipe handler is not."
  (let ((pruned 0))
    (setf (el-fd-handlers loop)
          (remove-if (lambda (pair)
                       (when (%fd-closed-p (car pair))
                         (ignore-errors (sb-sys:remove-fd-handler (cdr pair)))
                         (incf pruned)
                         t))
                     (el-fd-handlers loop)))
    pruned))

(defun reactor-poll (loop timeout-ms)
  "Block up to TIMEOUT-MS in poll, dispatching every ready fd handler. Returns T if an
event was served, NIL on timeout. If a handler's fd was closed out from under serve-event
(→ a bad-fd error), prune the stale handler(s) and continue rather than let the loop die."
  ;; serve-event wants seconds; substrate code, no float-trap masking needed.
  (handler-case (sb-sys:serve-event (/ timeout-ms 1000.0d0))
    (error (e)
      ;; Only swallow if we actually found + pruned a closed-fd handler; otherwise this
      ;; was a genuine error from a handler callback — re-signal it.
      (if (plusp (prune-closed-fd-handlers loop)) nil (error e)))))
