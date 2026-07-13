;;;; timers.lisp — own binary min-heap timer queue (PLAN.md Phase 05, §3.2;
;;;; sb-ext:timer is unusable — Appendix C.6). Ordered by (deadline, seq); seq
;;;; breaks ties FIFO (Node-faithful). Cancellation is lazy (skip on pop).

(in-package :clun.loop)

(defstruct (timer (:constructor %make-timer) (:conc-name timer-))
  (deadline 0 :type integer)            ; now-ms units
  (seq 0 :type fixnum)
  callback
  (interval nil)                        ; nil = one-shot; ms = repeating
  handle
  (cancelled nil))

(defstruct (timer-heap (:constructor make-timer-heap))
  (vec (make-array 16 :adjustable t :fill-pointer 0)))

(declaim (inline timer<))
(defun timer< (a b)
  (or (< (timer-deadline a) (timer-deadline b))
      (and (= (timer-deadline a) (timer-deadline b))
           (< (timer-seq a) (timer-seq b)))))

(defun %sift-up (v i)
  (loop while (plusp i)
        for p = (ash (1- i) -1)
        while (timer< (aref v i) (aref v p))
        do (rotatef (aref v i) (aref v p)) (setf i p)))

(defun %sift-down (v i)
  (let ((n (fill-pointer v)))
    (loop
      (let ((l (+ (* 2 i) 1)) (r (+ (* 2 i) 2)) (m i))
        (when (and (< l n) (timer< (aref v l) (aref v m))) (setf m l))
        (when (and (< r n) (timer< (aref v r) (aref v m))) (setf m r))
        (when (= m i) (return))
        (rotatef (aref v i) (aref v m)) (setf i m)))))

(defun heap-push (h timer)
  (let ((v (timer-heap-vec h)))
    (vector-push-extend timer v)
    (%sift-up v (1- (fill-pointer v)))))

(defun heap-peek (h)
  (let ((v (timer-heap-vec h))) (when (plusp (fill-pointer v)) (aref v 0))))

(defun heap-pop (h)
  (let* ((v (timer-heap-vec h)) (n (fill-pointer v)))
    (when (plusp n)
      (let ((top (aref v 0)))
        (setf (aref v 0) (aref v (1- n)))
        (decf (fill-pointer v))
        (when (plusp (fill-pointer v)) (%sift-down v 0))
        top))))

(defun %drop-dead-tops (h)
  (loop for top = (heap-peek h)
        while (and top (timer-cancelled top))
        do (heap-pop h)))

;;; --- public API --------------------------------------------------------------

(defun set-timer (loop delay-ms callback &key repeat (refd t))
  "Schedule CALLBACK after max(0,DELAY-MS). REPEAT (ms) reschedules it. A ref'd
timer keeps the loop alive; an unref'd one only fires if the loop is running."
  (let* ((delay (max 0 delay-ms))
         (timer (%make-timer
                 :deadline (+ (now-ms) delay)
                 :seq (incf (el-timer-seq loop))
                 :callback callback
                 :interval (and repeat (max 1 repeat))
                 :handle (make-handle loop :refd refd :kind :timer))))
    (heap-push (el-timers loop) timer)
    (handle-activate (timer-handle timer))
    timer))

(defun clear-timer (timer)
  (unless (timer-cancelled timer)
    (setf (timer-cancelled timer) t)
    (handle-deactivate (timer-handle timer))))

;;; ref/unref: a ref'd timer keeps the loop alive; an unref'd one only fires if the
;;; loop is otherwise running (Node's Timeout.ref/unref/hasRef). Delegated to the
;;; handle so the refcount bookkeeping stays in one place.
(defun timer-ref (timer) (handle-ref (timer-handle timer)) timer)
(defun timer-unref (timer) (handle-unref (timer-handle timer)) timer)
(defun timer-refd-p (timer) (handle-refd (timer-handle timer)))

(defun next-timer-delay (loop)
  "Ms until the earliest live timer, or NIL if none."
  (let ((h (el-timers loop)))
    (%drop-dead-tops h)
    (let ((top (heap-peek h)))
      (when top (max 0 (- (timer-deadline top) (now-ms)))))))

(defun expire-due-timers (loop)
  "Fire every live timer due at loop entry. Timers scheduled DURING this batch get
a seq beyond the snapshot, so a 0 ms timer set by a callback waits for the next
iteration (Node-faithful); repeating timers likewise re-fire next round."
  (let* ((h (el-timers loop)) (now (now-ms)) (max-seq (el-timer-seq loop)))
    (loop for top = (heap-peek h)
          while (and top (<= (timer-deadline top) now) (<= (timer-seq top) max-seq))
          do (heap-pop h)
             (unless (timer-cancelled top)
               (let ((cb (timer-callback top)))
                 (cond
                   ((timer-interval top)
                    (setf (timer-deadline top) (+ now (timer-interval top))
                          (timer-seq top) (incf (el-timer-seq loop)))
                    (heap-push h top)
                    (run-at-dispatch loop cb))
                   (t
                    (handle-deactivate (timer-handle top))
                    (run-at-dispatch loop cb))))))))
