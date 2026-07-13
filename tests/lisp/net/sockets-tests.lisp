;;;; sockets-tests.lisp — Phase 16 gate: the non-blocking TCP layer on the reactor.
;;;; A single-threaded event loop drives BOTH an echo server and the clients (the
;;;; reactor multiplexes every fd). Gate: 2,000 sequential + 500 concurrent echoes;
;;;; /proc/self/fd stable (zero leaks); >= 100 MB/s single-connection loopback; plus
;;;; connect-refused code mapping + port-0 real-port reporting.

(in-package :clun-test)

(defmacro with-net-loop ((var) &body body)
  `(let ((,var (lp:make-event-loop :workers 0)))
     (unwind-protect (progn ,@body) (lp:destroy-event-loop ,var))))

(defun s->o (s) (sb-ext:string-to-octets s :external-format :utf-8))
(defun ob () (make-array 0 :element-type '(unsigned-byte 8)))
(defun ocat (a b) (concatenate '(vector (unsigned-byte 8)) a b))
(defun fd-count () (length (sys:read-directory "/proc/self/fd")))

(defun start-echo-server (loop &key (backlog 1024))
  "A listener that echoes every received chunk straight back to the sender."
  (net:tcp-listen loop "127.0.0.1" 0 :backlog backlog
    :on-connection (lambda (c)
                     (setf (net:tcp-on-data c) (lambda (conn data) (net:tcp-write conn data))
                           (net:tcp-on-error c) (lambda (conn code) (declare (ignore conn code)) nil)))))

(defun run-echoes (loop port n &key concurrent)
  "Open N echo connections (all at once if CONCURRENT, else one after the previous
closes). Each sends a unique message + verifies the echo. Returns (values done errors)."
  (let ((done 0) (errors 0))
    (labels ((client (i)
               (let ((msg (s->o (format nil "ping-~a-~a" i (* i 7)))) (acc (ob)))
                 (net:tcp-connect loop "127.0.0.1" port
                   :on-connect (lambda (c) (net:tcp-write c msg))
                   :on-data (lambda (c data)
                              (setf acc (ocat acc data))
                              (when (>= (length acc) (length msg))
                                (unless (equalp acc msg) (incf errors))
                                (net:tcp-close c)))
                   :on-close (lambda (c code) (declare (ignore c code))
                               (incf done)
                               (cond (concurrent (when (>= done n) (lp:loop-stop loop)))
                                     ((< done n) (client done))
                                     (t (lp:loop-stop loop))))
                   :on-error (lambda (c code) (declare (ignore c code)) (incf errors))))))
      (if concurrent (dotimes (i n) (client i)) (client 0))
      (lp:run-loop loop)
      (values done errors))))

(define-test net/port-zero-real-port
  (with-net-loop (loop)
    (let ((server (start-echo-server loop)))
      (unwind-protect
           (progn (true (integerp (net:listener-port server)))
                  (true (plusp (net:listener-port server))))       ; port 0 -> a real ephemeral port
        (net:listener-close server)))))

(define-test net/echo-roundtrip
  (with-net-loop (loop)
    (let ((server (start-echo-server loop)))
      (unwind-protect
           (multiple-value-bind (done errors) (run-echoes loop (net:listener-port server) 5)
             (is = 5 done) (is = 0 errors))
        (net:listener-close server)))))

(define-test net/echo-sequential-2000
  (with-net-loop (loop)
    (let ((server (start-echo-server loop)))
      (unwind-protect
           (multiple-value-bind (done errors) (run-echoes loop (net:listener-port server) 2000)
             (is = 2000 done) (is = 0 errors))
        (net:listener-close server)))))

(define-test net/echo-concurrent-500
  (with-net-loop (loop)
    (let ((server (start-echo-server loop)))
      (unwind-protect
           (multiple-value-bind (done errors) (run-echoes loop (net:listener-port server) 500 :concurrent t)
             (is = 500 done) (is = 0 errors))
        (net:listener-close server)))))

(define-test net/fd-no-leak
  (with-net-loop (loop)
    (let ((server (start-echo-server loop)))
      (unwind-protect
           (let ((base (fd-count)))
             (run-echoes loop (net:listener-port server) 400)   ; 400 open+close cycles
             ;; every client + accepted socket is closed; only base fds remain
             (is <= (abs (- (fd-count) base)) 1))
        (net:listener-close server)))))

(define-test net/connect-refused
  (with-net-loop (loop)
    ;; bind then immediately close a listener to obtain a definitely-closed port
    (let ((tmp (net:tcp-listen loop "127.0.0.1" 0)) (dead-port nil) (code nil))
      (setf dead-port (net:listener-port tmp))
      (net:listener-close tmp)
      (net:tcp-connect loop "127.0.0.1" dead-port
        :on-connect (lambda (c) (declare (ignore c)) (setf code :connected) (lp:loop-stop loop))
        :on-error (lambda (c err) (declare (ignore c)) (setf code err))
        :on-close (lambda (c err) (declare (ignore c err)) (lp:loop-stop loop)))
      (lp:run-loop loop)
      (is equal "ECONNREFUSED" code))))

(define-test net/throughput-loopback
  (with-net-loop (loop)
    (let* ((total (* 64 1024 1024))          ; 64 MB
           (got 0) (t0 nil) (t1 nil)
           (server (net:tcp-listen loop "127.0.0.1" 0
                     :on-connection (lambda (c)
                                      (setf (net:tcp-on-data c)
                                            (lambda (conn data) (declare (ignore conn))
                                              (incf got (length data))
                                              (when (>= got total)
                                                (setf t1 (get-internal-real-time))
                                                (lp:loop-stop loop))))))))
      (unwind-protect
           (progn
             (net:tcp-connect loop "127.0.0.1" (net:listener-port server)
               :on-connect (lambda (c)
                             (setf t0 (get-internal-real-time))
                             (net:tcp-write c (make-array total :element-type '(unsigned-byte 8)
                                                                :initial-element 88))))
             (lp:run-loop loop)
             (is = total got)
             (let* ((secs (/ (float (- t1 t0)) internal-time-units-per-second))
                    (mbps (/ (/ total 1048576.0) (max secs 1d-6))))
               (format t "~&    [throughput] ~,1f MB/s (~,3fs for 64 MB)~%" mbps secs)
               (true (>= mbps 100))))
        (net:listener-close server)))))
