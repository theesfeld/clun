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

(defun reactor-poll (loop timeout-ms)
  "Block up to TIMEOUT-MS in poll, dispatching every ready fd handler. Returns T if
an event was served, NIL on timeout."
  (declare (ignore loop))
  ;; serve-event wants seconds; substrate code, no float-trap masking needed.
  (sb-sys:serve-event (/ timeout-ms 1000.0d0)))
