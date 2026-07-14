;;;; spawn.lisp — Clun.spawnSync, the blocking subprocess primitive (PLAN.md Phase 24, §3.3). A thin
;;;; wrapper over sb-ext:run-program :wait t. Piped stdout/stderr are redirected to TEMP FILES (a full
;;;; pipe would deadlock a synchronous read of any size — the file absorbs it), read back after exit as
;;;; Uint8Arrays; stdin data is written to a temp file used as :input. The async `Clun.spawn` (below)
;;;; runs run-program :wait nil with non-blocking stdout/stderr/stdin pipes on the reactor + an
;;;; .exited promise. Pure CL (sb-ext:run-program is the sanctioned subprocess API, PLAN §1.1). No
;;;; zombies: run-program auto-reaps.

(in-package :clun.runtime)

(defparameter *signal-names*
  '((1 . "SIGHUP") (2 . "SIGINT") (3 . "SIGQUIT") (4 . "SIGILL") (6 . "SIGABRT") (8 . "SIGFPE")
    (9 . "SIGKILL") (11 . "SIGSEGV") (13 . "SIGPIPE") (14 . "SIGALRM") (15 . "SIGTERM"))
  "Signal number → name (the common set; unknown → SIGnn).")

(defun %signal-name (n) (or (cdr (assoc n *signal-names*)) (format nil "SIG~d" n)))

(defun %cmd->argv (cmd)
  "A JS array [program, ...args] → a non-empty CL list of strings, or a JS TypeError."
  (unless (eng:js-array-p cmd)
    (eng:throw-type-error "Clun.spawnSync: the first argument must be an array of strings"))
  (let ((argv (loop for i below (eng:array-length cmd)
                    collect (eng:to-string (eng:js-getv cmd (princ-to-string i))))))
    (when (null argv) (eng:throw-type-error "Clun.spawnSync: the command array is empty"))
    argv))

(defun %opt (opts key) (if (and opts (eng:js-object-p opts)) (eng:js-get opts key) eng:+undefined+))

(defun %opt-string (opts key)
  (let ((v (%opt opts key))) (unless (eng:js-undefined-p v) (eng:to-string v))))

(defun %stdio-mode (opts key)
  "The stdio mode for KEY (\"stdout\"/\"stderr\"): :pipe (default) / :inherit / :ignore."
  (let ((v (%opt-string opts key)))
    (cond ((null v) :pipe)
          ((string= v "inherit") :inherit)
          ((string= v "ignore") :ignore)
          (t :pipe))))

(defun %stdio-target (mode path)
  (ecase mode (:pipe path) (:inherit t) (:ignore nil)))

(defun %env-list (g opts)
  "opts.env (a JS object) → a list of \"K=V\" strings, or NIL to inherit the current environment."
  (let ((env (%opt opts "env")))
    (when (eng:js-object-p env)
      (let* ((object (eng:js-get g "Object"))
             (keys (eng:js-call (eng:js-get object "keys") object (list env))))
        (loop for i below (eng:array-length keys)
              for k = (eng:to-string (eng:js-getv keys (princ-to-string i)))
              collect (format nil "~a=~a" k (eng:to-string (eng:js-getv env k))))))))

(defun %stdin-octets (opts)
  "opts.stdin as octets to feed the child (a string / typed-array / ArrayBuffer), or NIL."
  (let ((v (%opt opts "stdin")))
    (cond ((eng:js-undefined-p v) nil)
          ((eng:js-typed-array-p v) (multiple-value-bind (a o l) (eng:ta-octets v) (subseq a o (+ o l))))
          ((eng:js-array-buffer-p v) (copy-seq (eng:js-array-buffer-bytes v)))
          ((eng:js-object-p v) nil)                 ; "inherit"/"ignore" objects unsupported in sync → ignore
          (t (eng:code-units->utf8 (eng:to-string v))))))

(defun %spawn-result (g proc stdout-octets stderr-octets)
  (let ((o (eng:new-object))
        (status (sb-ext:process-status proc))
        (code (sb-ext:process-exit-code proc)))
    (eng:data-prop o "pid" (coerce (or (sb-ext:process-pid proc) -1) 'double-float))
    (cond
      ((eq status :exited)
       (eng:data-prop o "exitCode" (coerce (or code 0) 'double-float))
       (eng:data-prop o "signalCode" eng:+null+)
       (eng:data-prop o "success" (eng:js-boolean (eql code 0))))
      ((eq status :signaled)
       (eng:data-prop o "exitCode" eng:+null+)
       (eng:data-prop o "signalCode" (%signal-name (or code 0)))
       (eng:data-prop o "success" eng:+false+))
      (t
       (eng:data-prop o "exitCode" (if code (coerce code 'double-float) eng:+null+))
       (eng:data-prop o "signalCode" eng:+null+)
       (eng:data-prop o "success" (eng:js-boolean (eql code 0)))))
    (eng:data-prop o "stdout" (if stdout-octets (eng:u8-from-octets stdout-octets) eng:+null+))
    (eng:data-prop o "stderr" (if stderr-octets (eng:u8-from-octets stderr-octets) eng:+null+))
    o))

(defun %spawn-sync (g cmd opts)
  (let* ((argv (%cmd->argv cmd))
         (program (first argv)) (args (rest argv))
         (cwd (%opt-string opts "cwd"))
         (env (%env-list g opts))
         (stdin-octets (%stdin-octets opts))
         (out-mode (%stdio-mode opts "stdout"))
         (err-mode (%stdio-mode opts "stderr"))
         (tmp (clun.sys:make-temp-dir "/tmp/clun-spawn-")))
    (unwind-protect
         (let* ((out-path (clun.sys:path-join tmp "out"))
                (err-path (clun.sys:path-join tmp "err"))
                (in-path (when stdin-octets (clun.sys:path-join tmp "in"))))
           (when stdin-octets (clun.sys:write-file-octets in-path stdin-octets))
           (let ((proc (handler-case
                           (apply #'sb-ext:run-program program args
                                  :search t :wait t
                                  :output (%stdio-target out-mode out-path)
                                  :error (%stdio-target err-mode err-path)
                                  :input in-path
                                  (append (when cwd (list :directory cwd))
                                          (when env (list :environment env))))
                         (error (e)
                           (eng:throw-js-value
                            (eng:js-construct (eng:js-get g "Error")
                                              (list (format nil "Clun.spawnSync ~a: ~a" program e))))))))
             (%spawn-result g proc
                            (and (eq out-mode :pipe) (clun.sys:read-file-octets out-path))
                            (and (eq err-mode :pipe) (clun.sys:read-file-octets err-path)))))
      (ignore-errors (clun.sys:remove-recursive tmp)))))

(defun install-spawn (clun g)
  "Install Clun.spawnSync + Clun.spawn onto the CLUN global object (G is the realm global)."
  (eng:install-method clun "spawnSync" 2
    (lambda (this args) (declare (ignore this))
      (%spawn-sync g (eng:arg args 0) (eng:arg args 1))))
  (eng:install-method clun "spawn" 2
    (lambda (this args) (declare (ignore this))
      (%spawn g (eng:arg args 0) (eng:arg args 1)))))

;;; ============================ async Clun.spawn ==============================
;;; run-program :wait nil; stdout/stderr/stdin pipes go non-blocking onto the reactor; the
;;; :status-hook (interrupt context) marshals the child-exit to the loop via lp:loop-post ONLY
;;; (§6 iron rule). .exited resolves at child-exit; stdout/stderr promises resolve at pipe EOF; a
;;; loop handle stays active until the child has exited AND all read pipes have drained (no early
;;; loop exit, no zombies — run-program auto-reaps).

(defparameter *proc-read-chunk* 65536)

(defstruct (subproc (:conc-name sp-))
  proc loop handle g jsobj
  exit-code signal-code exited-resolve on-exit
  (child-exited nil) (open-reads 0) (settled nil)
  stdin-fd stdin-stream (stdin-queue '()) (stdin-tail '()) stdin-handler (stdin-ended nil)
  stdout-fd stdout-stream stdout-buf stdout-resolve
  stderr-fd stderr-stream stderr-buf stderr-resolve)

(defun %read-fd (fd buf)
  "Non-blocking read FD into BUF → n>0 | 0 (EOF) | :again | :error."
  (sb-sys:with-pinned-objects (buf)
    (multiple-value-bind (n err) (sb-unix:unix-read fd (sb-sys:vector-sap buf) (length buf))
      (cond ((and n (plusp n)) n)
            ((eql n 0) 0)
            ((member err (list sb-unix:eagain sb-unix:ewouldblock)) :again)
            (t :error)))))

(defun %write-fd (fd octets off)
  "Non-blocking write octets[off..] to FD → bytes-written | :again | :error."
  (let ((len (- (length octets) off)))
    (if (<= len 0) 0
        (sb-sys:with-pinned-objects (octets)
          (multiple-value-bind (n err) (sb-unix:unix-write fd octets off len)
            (cond ((and n (>= n 0)) n)
                  ((member err (list sb-unix:eagain sb-unix:ewouldblock)) :again)
                  (t :error)))))))

(defun %new-adjustable () (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))

(defun %append-octets (buf src n)
  (let ((old (fill-pointer buf)))
    (adjust-array buf (max (array-total-size buf) (+ old n)) :fill-pointer (+ old n))
    (replace buf src :start1 old :end2 n)))

(defun %sp-settle-check (sp)
  "Close the process and deactivate its loop handle after exit and pipe EOF."
  (when (and (sp-child-exited sp) (zerop (sp-open-reads sp)) (not (sp-settled sp)))
    (setf (sp-settled sp) t)
    (ignore-errors (sb-ext:process-close (sp-proc sp)))
    (when (sp-handle sp) (lp:handle-deactivate (sp-handle sp)))))

(defun %sp-resolve-output (sp which)
  (let ((resolve (if (eq which :stdout) (sp-stdout-resolve sp) (sp-stderr-resolve sp)))
        (buf (if (eq which :stdout) (sp-stdout-buf sp) (sp-stderr-buf sp))))
    (when resolve
      (eng:js-call resolve eng:+undefined+
                   (list (eng:u8-from-octets (coerce buf '(simple-array (unsigned-byte 8) (*)))))))))

(defun %sp-add-reader (sp fd which)
  "Register a reactor :input reader draining FD into the WHICH buffer; on EOF/err resolve the
WHICH promise + release one read."
  (incf (sp-open-reads sp))
  (let ((rbuf (make-array *proc-read-chunk* :element-type '(unsigned-byte 8)))
        (buf (if (eq which :stdout) (sp-stdout-buf sp) (sp-stderr-buf sp)))
        (handler nil))
    (flet ((finish ()
             (when handler (lp:reactor-remove (sp-loop sp) handler) (setf handler nil))
             ;; close via the STREAM (not the raw fd): run-program's :stream fd-streams carry an
             ;; :auto-close GC finalizer; a raw sb-posix:close leaves it armed on a number the OS
             ;; can recycle → a later GC would close an unrelated fd (§6 use-after-close). (close
             ;; stream) closes the fd exactly once and cancels the finalizer.
             (let ((stream (if (eq which :stdout) (sp-stdout-stream sp) (sp-stderr-stream sp))))
               (if stream
                   (progn (ignore-errors (close stream))
                          (if (eq which :stdout) (setf (sp-stdout-stream sp) nil) (setf (sp-stderr-stream sp) nil)))
                   (ignore-errors (sb-posix:close fd))))
             (%sp-resolve-output sp which)
             (decf (sp-open-reads sp))
             (%sp-settle-check sp)))
      (setf handler
            (lp:reactor-add (sp-loop sp) fd :input
              (lambda (fd*) (declare (ignore fd*))
                (loop
                  (let ((n (%read-fd fd rbuf)))
                    (cond ((eq n :again) (return))
                          ((eql n 0) (finish) (return))
                          ((eq n :error) (finish) (return))
                          (t (%append-octets buf rbuf n)))))))))))

;;; --- stdin writer ---
(defun %sp-stdin-flush (sp)
  (loop while (sp-stdin-queue sp) do
    (let* ((chunk (car (sp-stdin-queue sp))) (octets (car chunk)) (off (cdr chunk)))
      (let ((n (%write-fd (sp-stdin-fd sp) octets off)))
        (cond
          ((eq n :again) (%sp-stdin-want-writable sp) (return-from %sp-stdin-flush))
          ((eq n :error) (%sp-stdin-close sp) (return-from %sp-stdin-flush))
          (t (if (>= (+ off n) (length octets))
                 (pop (sp-stdin-queue sp))
                 (setf (cdr chunk) (+ off n))))))))
  ;; queue drained
  (setf (sp-stdin-tail sp) nil)
  (when (sp-stdin-handler sp)
    (lp:reactor-remove (sp-loop sp) (sp-stdin-handler sp)) (setf (sp-stdin-handler sp) nil))
  (when (sp-stdin-ended sp) (%sp-stdin-close sp)))

(defun %sp-stdin-want-writable (sp)
  (unless (sp-stdin-handler sp)
    (setf (sp-stdin-handler sp)
          (lp:reactor-add (sp-loop sp) (sp-stdin-fd sp) :output
            (lambda (fd) (declare (ignore fd)) (%sp-stdin-flush sp))))))

(defun %sp-stdin-close (sp)
  (when (sp-stdin-handler sp)
    (lp:reactor-remove (sp-loop sp) (sp-stdin-handler sp)) (setf (sp-stdin-handler sp) nil))
  ;; close the STREAM (owns the fd + its :auto-close finalizer), not the raw fd — see the reader.
  (when (sp-stdin-stream sp) (ignore-errors (close (sp-stdin-stream sp))) (setf (sp-stdin-stream sp) nil))
  (setf (sp-stdin-fd sp) nil))

(defun %sp-stdin-write (sp octets)
  (when (and (sp-stdin-fd sp) (not (sp-stdin-ended sp)) (plusp (length octets)))
    (let ((chunk (cons octets 0)))
      (if (sp-stdin-tail sp)
          (setf (cdr (sp-stdin-tail sp)) (list chunk) (sp-stdin-tail sp) (cdr (sp-stdin-tail sp)))
          (setf (sp-stdin-queue sp) (list chunk) (sp-stdin-tail sp) (sp-stdin-queue sp)))
      (%sp-stdin-flush sp))))

(defun %sp-stdin-end (sp)
  (setf (sp-stdin-ended sp) t)
  (unless (sp-stdin-queue sp) (%sp-stdin-close sp)))

;;; --- finalize (loop thread, posted by the status-hook) ---
(defun %sp-finalize (sp)
  ;; the :status-hook fires on EVERY status change (including :stopped from SIGSTOP/job control), so
  ;; only COMMIT when the child has actually terminated — otherwise a paused child would resolve
  ;; .exited prematurely + permanently. :running/:stopped are ignored (the next hook, on real exit,
  ;; finalizes).
  (let ((status (sb-ext:process-status (sp-proc sp))))
    (when (and (not (sp-child-exited sp)) (member status '(:exited :signaled)))
      (setf (sp-child-exited sp) t)
      ;; the child is gone — release the stdin writer even if JS never called end() (no fd leak)
      (%sp-stdin-close sp) (setf (sp-stdin-queue sp) '() (sp-stdin-tail sp) nil)
      (let ((code (sb-ext:process-exit-code (sp-proc sp))))
      (cond ((eq status :signaled)
             (setf (sp-signal-code sp) (%signal-name (or code 0)) (sp-exit-code sp) nil))
            (t (setf (sp-exit-code sp) (or code 0))))
      ;; update the JS-visible props + resolve .exited + call onExit
      (%sp-publish sp)
      (when (sp-exited-resolve sp)
        (eng:js-call (sp-exited-resolve sp) eng:+undefined+
                     (list (if (sp-exit-code sp) (coerce (sp-exit-code sp) 'double-float) eng:+null+))))
      (when (and (sp-on-exit sp) (eng:callable-p (sp-on-exit sp)))
        (ignore-errors
          (eng:js-call (sp-on-exit sp) eng:+undefined+
                       (list (if (sp-exit-code sp) (coerce (sp-exit-code sp) 'double-float) eng:+null+)
                             (if (sp-signal-code sp) (sp-signal-code sp) eng:+null+)))))
      (%sp-settle-check sp)))))

(defun %sp-publish (sp)
  "Update the JS Subprocess object's exitCode/signalCode data props after the child exits."
  (let ((o (sp-jsobj sp)))
    (when o
      (eng:data-prop o "exitCode" (if (sp-exit-code sp) (coerce (sp-exit-code sp) 'double-float) eng:+null+))
      (eng:data-prop o "signalCode" (if (sp-signal-code sp) (sp-signal-code sp) eng:+null+)))))

(defun %deferred (g)
  "A new Promise capturing its resolve fn → (values promise resolve)."
  (let (res)
    (let ((p (eng:js-construct (eng:js-get g "Promise")
               (list (eng:make-native-function "" 2
                       (lambda (this a) (declare (ignore this))
                         (setf res (eng:arg a 0)) eng:+undefined+))))))
      (values p res))))

(defun %sig->number (v)
  "A kill() signal arg (a number or a name like \"SIGTERM\"/\"TERM\") → a signal number (default 15)."
  (cond ((eng:js-undefined-p v) 15)
        ((eng:js-number-p v) (truncate (eng:to-number v)))
        (t (let* ((s (eng:to-string v))
                  (name (if (and (>= (length s) 3) (string-equal "SIG" s :end2 3)) s (concatenate 'string "SIG" s))))
             (or (car (rassoc name *signal-names* :test #'string=)) 15)))))

(defun %make-subprocess-object (sp g stdout-mode stderr-mode stdin-mode)
  (let ((o (eng:new-object)))
    (setf (sp-jsobj sp) o)
    (eng:data-prop o "pid" (coerce (or (sb-ext:process-pid (sp-proc sp)) -1) 'double-float))
    (eng:data-prop o "exitCode" eng:+null+)
    (eng:data-prop o "signalCode" eng:+null+)
    ;; .exited — resolves to the exit code (or null on a signal) when the child exits
    (multiple-value-bind (p res) (%deferred g)
      (setf (sp-exited-resolve sp) res)
      (eng:data-prop o "exited" p))
    ;; piped stdout/stderr → a Promise<Uint8Array> resolved at pipe EOF (a documented divergence from
    ;; Bun's ReadableStream; enough for read-all consumers + the dual-pipe gate).
    (if (eq stdout-mode :pipe)
        (multiple-value-bind (p res) (%deferred g) (setf (sp-stdout-resolve sp) res) (eng:data-prop o "stdout" p))
        (eng:data-prop o "stdout" eng:+null+))
    (if (eq stderr-mode :pipe)
        (multiple-value-bind (p res) (%deferred g) (setf (sp-stderr-resolve sp) res) (eng:data-prop o "stderr" p))
        (eng:data-prop o "stderr" eng:+null+))
    ;; piped stdin → a writer { write(data), end() }
    (if (eq stdin-mode :pipe)
        (let ((w (eng:new-object)))
          (eng:install-method w "write" 1
            (lambda (th a) (declare (ignore th))
              (%sp-stdin-write sp (%to-octets (eng:arg a 0))) eng:+undefined+))
          (eng:install-method w "end" 0
            (lambda (th a) (declare (ignore th a)) (%sp-stdin-end sp) eng:+undefined+))
          (eng:data-prop o "stdin" w))
        (eng:data-prop o "stdin" eng:+null+))
    (eng:install-method o "kill" 1
      (lambda (th a) (declare (ignore th))
        (ignore-errors (sb-ext:process-kill (sp-proc sp) (%sig->number (eng:arg a 0)) :pid))
        eng:+undefined+))
    o))

(defun %to-octets (v)
  (cond ((eng:js-typed-array-p v) (multiple-value-bind (a o l) (eng:ta-octets v) (subseq a o (+ o l))))
        ((eng:js-array-buffer-p v) (copy-seq (eng:js-array-buffer-bytes v)))
        (t (eng:code-units->utf8 (eng:to-string v)))))

(defun %spawn (g cmd opts)
  (let* ((argv (%cmd->argv cmd))
         (program (first argv)) (args (rest argv))
         (cwd (%opt-string opts "cwd"))
         (env (%env-list g opts))
         (out-mode (%stdio-mode opts "stdout"))
         (err-mode (%stdio-mode opts "stderr"))
         (in-mode (%stdio-mode opts "stdin"))
         (loop (eng:current-loop))
         (sp (make-subproc :loop loop :g g :stdout-buf (%new-adjustable) :stderr-buf (%new-adjustable)
                           :on-exit (let ((cb (%opt opts "onExit"))) (when (eng:callable-p cb) cb))))
         ;; pre-allocate the finalize thunk ONCE: the :status-hook fires in interrupt context, so it
         ;; must only lp:loop-post an already-consed thunk (§6 — no per-interrupt allocation).
         (finalize-thunk (lambda () (%sp-finalize sp)))
         (proc (handler-case
                   (apply #'sb-ext:run-program program args
                          :search t :wait nil
                          :output (if (eq out-mode :pipe) :stream (%stdio-target out-mode nil))
                          :error (if (eq err-mode :pipe) :stream (%stdio-target err-mode nil))
                          :input (if (eq in-mode :pipe) :stream (%stdio-target in-mode nil))
                          :status-hook (lambda (p) (declare (ignore p)) (lp:loop-post loop finalize-thunk))
                          (append (when cwd (list :directory cwd))
                                  (when env (list :environment env))))
                 (error (e)
                   (eng:throw-js-value
                    (eng:js-construct (eng:js-get g "Error")
                                      (list (format nil "Clun.spawn ~a: ~a" program e))))))))
    (setf (sp-proc sp) proc
          (sp-handle sp) (lp:make-handle loop :kind :subprocess))
    (lp:handle-activate (sp-handle sp))
    ;; register the pipes on the loop thread (spawn may be called from a coroutine thread). Wrapped:
    ;; a mid-setup failure after a successful fork must NOT orphan the active handle (the loop would
    ;; hang) or leak the pipe fds — tear the child down + settle instead.
    (lp:run-on-loop loop
      (lambda ()
        (handler-case
            (progn
              (when (eq out-mode :pipe)
                (let ((s (sb-ext:process-output proc)))
                  (setf (sp-stdout-stream sp) s)
                  (let ((fd (clun.sys:stream-fd s))) (clun.sys:set-nonblocking fd) (%sp-add-reader sp fd :stdout))))
              (when (eq err-mode :pipe)
                (let ((s (sb-ext:process-error proc)))
                  (setf (sp-stderr-stream sp) s)
                  (let ((fd (clun.sys:stream-fd s))) (clun.sys:set-nonblocking fd) (%sp-add-reader sp fd :stderr))))
              (when (eq in-mode :pipe)
                (let ((s (sb-ext:process-input proc)))
                  (setf (sp-stdin-stream sp) s (sp-stdin-fd sp) (clun.sys:stream-fd s))
                  (clun.sys:set-nonblocking (sp-stdin-fd sp))))
              ;; a status-hook may already have fired before we got here (fast child) — finalize now
              (unless (or (sp-child-exited sp) (member (sb-ext:process-status proc) '(:running :stopped)))
                (%sp-finalize sp))
              (%sp-settle-check sp))
          (error ()
            (ignore-errors (%sp-stdin-close sp))
            (dolist (s (list (sp-stdout-stream sp) (sp-stderr-stream sp)))
              (when s (ignore-errors (close s))))
            (setf (sp-stdout-stream sp) nil (sp-stderr-stream sp) nil (sp-open-reads sp) 0 (sp-child-exited sp) t)
            (ignore-errors (sb-ext:process-kill proc 9 :pid))
            (ignore-errors (sb-ext:process-close proc))
            (when (sp-exited-resolve sp)
              (ignore-errors (eng:js-call (sp-exited-resolve sp) eng:+undefined+ (list eng:+null+))))
            (unless (sp-settled sp)
              (setf (sp-settled sp) t)
              (when (sp-handle sp) (lp:handle-deactivate (sp-handle sp))))))))
    (%make-subprocess-object sp g out-mode err-mode in-mode)))
