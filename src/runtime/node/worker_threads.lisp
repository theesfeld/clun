;;;; worker_threads.lisp — real shared-memory multithreading (Issue #338).
;;;; Workers run on sb-thread with isolated JS heaps. SharedArrayBuffer data
;;;; blocks are the only shared mutable state. MessagePort uses mailboxes +
;;;; loop-post for cross-thread delivery.

(in-package :clun.runtime)

;;; --- per-thread worker context ----------------------------------------------

(defvar *wt-is-main-thread* t)
(defvar *wt-thread-id* 0d0)
(defvar *wt-parent-port* nil)           ; JS MessagePort or null
(defvar *wt-worker-data* eng:+null+)
(defvar *wt-resource-limits* nil)

(defparameter *wt-next-id* 1)
(defparameter *wt-id-lock* (sb-thread:make-mutex :name "clun-wt-id"))

(defun %wt-alloc-thread-id ()
  (sb-thread:with-mutex (*wt-id-lock*)
    (prog1 (coerce *wt-next-id* 'double-float)
      (incf *wt-next-id*))))

;;; --- structured clone with SAB share ----------------------------------------

(defun %wt-clone (v &optional (seen (make-hash-table :test 'eq)))
  "Structured-clone-ish copy for worker messages. SharedArrayBuffer shares the
data block; ArrayBuffer is copied; functions reject."
  (cond
    ((not (eng:js-object-p v)) v)
    ((eng:callable-p v) (%clone-data-error "A function"))
    ((eng:js-shared-array-buffer-p v)
     (or (gethash v seen)
         (let ((out (eng:wrap-shared-array-buffer (eng:js-shared-array-buffer-block v))))
           (setf (gethash v seen) out)
           out)))
    ((eng:js-array-buffer-p v)
     (or (gethash v seen)
         (let* ((bytes (eng:js-array-buffer-bytes v))
                (len (if bytes (length bytes) 0))
                (ctor (eng:js-get (eng:realm-global eng:*realm*) "ArrayBuffer"))
                (out (eng:js-construct ctor (list (coerce len 'double-float)))))
           (when bytes
             (replace (eng:js-array-buffer-bytes out) bytes))
           (setf (gethash v seen) out)
           out)))
    ((eng:js-typed-array-p v)
     (or (gethash v seen)
         (let* ((buf (%wt-clone (eng:js-get v "buffer") seen))
                (ctor (eng:js-get v "constructor"))
                (name (if (eng:js-object-p ctor)
                          (eng:to-string (eng:js-get ctor "name"))
                          "Uint8Array"))
                (local-ctor (eng:js-get (eng:realm-global eng:*realm*) name))
                (offset (eng:js-get v "byteOffset"))
                (length (eng:js-get v "length"))
                (out (if (eng:callable-p local-ctor)
                         (eng:js-construct local-ctor (list buf offset length))
                         (eng:new-object))))
           (setf (gethash v seen) out)
           out)))
    ((eq (eng:js-object-class v) :date)
     (eng:js-construct (eng:js-get (eng:realm-global eng:*realm*) "Date")
                       (list (eng:js-call (eng:js-get v "getTime") v '()))))
    ((gethash v seen))
    ((eng:js-array-p v)
     (let ((out (eng:new-array '())))
       (setf (gethash v seen) out)
       (let ((len (eng:array-length v)))
         (dotimes (i len)
           (eng:create-data-property out (princ-to-string i)
                                     (%wt-clone (eng:js-getv v (princ-to-string i)) seen))))
       out))
    (t
     (let ((out (eng:new-object)))
       (setf (gethash v seen) out)
       (dolist (k (eng:jm-own-property-keys v))
         (when (stringp k)
           (let ((d (eng:obj-own-desc v k)))
             (when (and d (eq (eng:pd-enumerable d) t))
               (eng:data-prop out k (%wt-clone (eng:js-getv v k) seen))))))
       out))))

;;; --- cross-thread MessagePort -----------------------------------------------

(defstruct (wt-port-host (:constructor %make-wt-port-host)
                         (:conc-name wph-))
  (mailbox (sb-concurrency:make-mailbox :name "clun-wt-port"))
  (peer nil)
  (closed nil)
  (lock (sb-thread:make-mutex :name "clun-wt-port"))
  js-object                             ; realm-local MessagePort
  realm
  event-loop
  (loop-handle nil))

(defun %wt-port-deliver (host message)
  "Enqueue MESSAGE onto HOST's event loop and emit 'message'."
  (let ((loop (wph-event-loop host))
        (js (wph-js-object host))
        (realm (wph-realm host)))
    (when (and loop js realm (not (wph-closed host)))
      (lp:loop-post loop
                    (lambda ()
                      (let ((eng:*realm* realm))
                        (let ((cloned (%wt-clone message)))
                          (%ev-emit js "message" (list cloned)))))))))

(defun %wt-port-post (host value)
  (sb-thread:with-mutex ((wph-lock host))
    (when (wph-closed host)
      (return-from %wt-port-post eng:+undefined+))
    (let ((peer (wph-peer host)))
      (unless peer
        (return-from %wt-port-post eng:+undefined+))
      ;; Clone in the *sender* realm first so SAB blocks are captured, then
      ;; deliver the clone structure; receiver re-wraps SAB in its realm.
      (let ((payload (%wt-clone value)))
        (%wt-port-deliver peer payload))))
  eng:+undefined+)

(defun %wt-port-close (host)
  (sb-thread:with-mutex ((wph-lock host))
    (unless (wph-closed host)
      (setf (wph-closed host) t)
      (when (wph-loop-handle host)
        (ignore-errors (lp:handle-unref (wph-loop-handle host)))
        (ignore-errors (lp:handle-deactivate (wph-loop-handle host)))
        (setf (wph-loop-handle host) nil))))
  eng:+undefined+)

(defun %make-linked-ports (realm-a loop-a realm-b loop-b)
  "Two linked port hosts. JS objects are attached later per-realm."
  (let ((a (%make-wt-port-host :realm realm-a :event-loop loop-a))
        (b (%make-wt-port-host :realm realm-b :event-loop loop-b)))
    (setf (wph-peer a) b
          (wph-peer b) a)
    (values a b)))

(defun %bind-js-port (host &optional proto)
  "Create/bind the JS MessagePort object for HOST in the current realm."
  (let* ((obj (%ev-init (if proto (eng:js-make-object proto) (eng:new-object)))))
    (eng:hidden-prop obj "_wtPort" host)
    (setf (wph-js-object host) obj
          (wph-realm host) eng:*realm*
          (wph-event-loop host) (eng:current-loop))
    ;; Keep the loop alive while the port is open.
    (let ((h (lp:make-handle (wph-event-loop host))))
      (lp:handle-activate h)
      (lp:handle-ref h)
      (setf (wph-loop-handle host) h))
    (eng:install-method obj "postMessage" 1
      (lambda (this args)
        (declare (ignore this))
        (%wt-port-post host (eng:arg args 0))))
    (eng:install-method obj "close" 0
      (lambda (this args)
        (declare (ignore this args))
        (%wt-port-close host)))
    (eng:install-method obj "start" 0
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method obj "ref" 0
      (lambda (this args) (declare (ignore args)) this))
    (eng:install-method obj "unref" 0
      (lambda (this args)
        (declare (ignore args))
        (when (wph-loop-handle host)
          (lp:handle-unref (wph-loop-handle host)))
        this))
    (%wire-ee obj)
    obj))

;;; --- Worker host ------------------------------------------------------------

(defstruct (wt-worker-host (:constructor %make-wt-worker-host)
                           (:conc-name wwh-))
  thread
  thread-id
  main-port                             ; wt-port-host on main
  worker-port                           ; wt-port-host on worker (filled in thread)
  (terminated nil)
  (exit-code 0d0)
  js-object
  realm                                 ; main realm
  path
  worker-data)

(defun %wt-resolve-worker-path (filename)
  (let ((s (eng:to-string filename)))
    (cond
      ((and (>= (length s) 7) (string= "file://" s :end2 7))
       (subseq s 7))
      ((clun.sys:absolute-path-p s) s)
      (t (clun.sys:path-join (clun.sys:current-directory) s)))))

(defun %wt-worker-thread (host worker-data-block-or-value path thread-id main-port-peer)
  "Entry point for a worker OS thread."
  (let* ((realm (eng:make-realm))
         (eng:*realm* realm)
         (*wt-is-main-thread* nil)
         (*wt-thread-id* thread-id)
         (*wt-worker-data* eng:+null+)
         (*wt-parent-port* nil)
         (*runtime* nil))
    (install-runtime realm
                     :argv (list :script path :rest nil)
                     :cwd (clun.sys:current-directory))
    (let ((loop (eng:current-loop)))
      ;; Pair ports: peer on main already exists (main-port-peer is the main host's port).
      (let* ((worker-host-port
               (let ((peer main-port-peer))
                 ;; Create worker-side host linked to main's port host.
                 (let ((w (%make-wt-port-host :realm realm :event-loop loop)))
                   (setf (wph-peer w) peer
                         (wph-peer peer) w
                         (wph-realm peer) (wwh-realm host)
                         (wph-event-loop peer)
                         (or (eng:realm-loop (wwh-realm host))
                             (let ((eng:*realm* (wwh-realm host)))
                               (eng:current-loop))))
                   (setf (wwh-worker-port host) w)
                   w)))
             (parent-js (%bind-js-port worker-host-port)))
        (setf *wt-parent-port* parent-js)
        ;; workerData: re-clone into this realm (SAB shares blocks).
        (setf *wt-worker-data*
              (let ((eng:*realm* realm))
                (%wt-clone worker-data-block-or-value)))
        (handler-case
            (progn
              (eng:run-module-file path :realm realm :teardown nil)
              ;; Stay alive while the parent port is open / loop has refs.
              (lp:run-loop loop))
          (error (e)
            (let ((msg (format nil "Worker terminated: ~a" e)))
              (ignore-errors
                (lp:loop-post (wph-event-loop main-port-peer)
                              (lambda ()
                                (let ((eng:*realm* (wwh-realm host))
                                      (js (wwh-js-object host)))
                                  (when js
                                    (%ev-emit js "error"
                                              (list (eng:js-construct
                                                     (eng:js-get (eng:realm-global eng:*realm*) "Error")
                                                     (list msg))))))))))))
        (ignore-errors (eng:teardown-realm realm))
        (let ((js (wwh-js-object host))
              (main-loop (eng:realm-loop (wwh-realm host))))
          (when (and js main-loop)
            (lp:loop-post main-loop
                          (lambda ()
                            (let ((eng:*realm* (wwh-realm host)))
                              (%ev-emit js "exit" (list (wwh-exit-code host))))))))))))

(defun %wt-start-worker (js-worker filename options)
  (let* ((path (%wt-resolve-worker-path filename))
         (worker-data (if (eng:js-object-p options)
                          (eng:js-get options "workerData")
                          eng:+undefined+))
         (wd (if (eng:js-undefined-p worker-data) eng:+null+ worker-data))
         (tid (%wt-alloc-thread-id))
         (main-realm eng:*realm*)
         (main-loop (eng:current-loop))
         (main-port (%make-wt-port-host :realm main-realm :event-loop main-loop))
         (host (%make-wt-worker-host
                :thread-id tid
                :main-port main-port
                :js-object js-worker
                :realm main-realm
                :path path
                :worker-data wd)))
    (eng:hidden-prop js-worker "_wtWorker" host)
    (eng:data-prop js-worker "threadId" tid)
    (%ev-init js-worker)
    (%wire-ee js-worker)
    ;; Bind main-side MessagePort-ish emit surface on the Worker itself
    ;; (Node: worker.on('message'); worker.postMessage).
    (eng:install-method js-worker "postMessage" 1
      (lambda (this args)
        (declare (ignore this))
        (%wt-port-post main-port (eng:arg args 0))))
    (eng:install-method js-worker "terminate" 0
      (lambda (this args)
        (declare (ignore this args))
        (%wt-terminate host)))
    (eng:install-method js-worker "ref" 0
      (lambda (this args) (declare (ignore args)) this))
    (eng:install-method js-worker "unref" 0
      (lambda (this args) (declare (ignore args)) this))
    ;; Deliver messages arriving on main-port to worker 'message' events.
    (setf (wph-js-object main-port) js-worker)
    (let ((h (lp:make-handle main-loop)))
      (lp:handle-activate h)
      (lp:handle-ref h)
      (setf (wph-loop-handle main-port) h))
    ;; Clone workerData in main realm first (capture SAB blocks).
    (let ((wd-payload (%wt-clone wd)))
      (setf (wwh-thread host)
            (sb-thread:make-thread
             (lambda ()
               (%wt-worker-thread host wd-payload path tid main-port))
             :name (format nil "clun-worker-~d" (truncate tid)))))
    js-worker))

(defun %wt-terminate (host)
  (unless (wwh-terminated host)
    (setf (wwh-terminated host) t
          (wwh-exit-code host) 1d0)
    (when (wwh-main-port host)
      (%wt-port-close (wwh-main-port host)))
    (when (wwh-worker-port host)
      (%wt-port-close (wwh-worker-port host)))
    (when (wwh-thread host)
      (ignore-errors (sb-thread:terminate-thread (wwh-thread host)))
      (ignore-errors (sb-thread:join-thread (wwh-thread host) :default nil :timeout 2))))
  ;; Node returns a Promise that resolves to the exit code.
  (eng:js-construct
   (eng:js-get (eng:realm-global eng:*realm*) "Promise")
   (list
    (eng:make-native-function
     "" 2
     (lambda (tt aa)
       (declare (ignore tt))
       (eng:js-call (eng:arg aa 0) eng:+undefined+ (list (wwh-exit-code host)))
       eng:+undefined+)))))

;;; --- module surface ---------------------------------------------------------

(defun build-node-worker-threads ()
  (let ((o (eng:new-object)))
    (eng:data-prop o "isMainThread" (eng:js-boolean *wt-is-main-thread*))
    (eng:data-prop o "parentPort" (or *wt-parent-port* eng:+null+))
    (eng:data-prop o "threadId" *wt-thread-id*)
    (eng:data-prop o "workerData" *wt-worker-data*)
    (eng:data-prop o "resourceLimits" (or *wt-resource-limits* (eng:new-object)))
    (eng:data-prop o "SHARE_ENV" (eng:new-object))
    (eng:install-method o "getEnvironmentData" 1
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method o "setEnvironmentData" 2
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method o "markAsUntransferable" 1
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method o "moveMessagePortToContext" 2
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method o "receiveMessageOnPort" 1
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (let* ((proto (eng:new-object))
           (ctor (eng:make-native-function
                  "Worker" 2
                  (lambda (this args)
                    (when (eng:js-object-p this)
                      (%wt-start-worker this (eng:arg args 0) (eng:arg args 1)))
                    eng:+undefined+)
                  :construct
                  (lambda (args nt)
                    (declare (ignore nt))
                    (let ((obj (eng:js-make-object proto)))
                      (%wt-start-worker obj (eng:arg args 0) (eng:arg args 1))
                      obj)))))
      (eng:data-prop ctor "prototype" proto)
      (eng:data-prop proto "constructor" ctor)
      (eng:data-prop o "Worker" ctor))
    ;; Same-thread MessageChannel (web-platform also provides a global).
    (eng:data-prop o "MessageChannel"
                   (eng:js-get (eng:realm-global eng:*realm*) "MessageChannel"))
    (eng:data-prop o "MessagePort"
                   (eng:make-native-function
                    "MessagePort" 0
                    (lambda (this args) (declare (ignore this args)) eng:+undefined+)))
    (eng:data-prop o "BroadcastChannel"
                   (eng:make-native-function
                    "BroadcastChannel" 1
                    (lambda (this args) (declare (ignore this args)) eng:+undefined+)))
    o))

(register-node-builtin "worker_threads" #'build-node-worker-threads)
