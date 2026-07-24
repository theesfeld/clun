;;;; stream.lisp — node:stream (+ stream/promises, stream/consumers, stream/web).
;;;; Pure-CL Readable/Writable/Duplex/Transform/PassThrough over EventEmitter.

(in-package :clun.runtime)

(defun %stream-init (obj &key readable writable object-mode high-water-mark)
  (%ev-init obj)
  (eng:hidden-prop obj "_readableState"
                   (let ((s (eng:new-object)))
                     (eng:data-prop s "objectMode" (eng:js-boolean object-mode))
                     (eng:data-prop s "highWaterMark"
                                    (coerce (or high-water-mark 16384) 'double-float))
                     (eng:data-prop s "ended" eng:+false+)
                     (eng:hidden-prop s "buffer" '())
                     s))
  (eng:hidden-prop obj "_writableState"
                   (let ((s (eng:new-object)))
                     (eng:data-prop s "objectMode" (eng:js-boolean object-mode))
                     (eng:data-prop s "highWaterMark"
                                    (coerce (or high-water-mark 16384) 'double-float))
                     (eng:data-prop s "ended" eng:+false+)
                     (eng:data-prop s "finished" eng:+false+)
                     (eng:hidden-prop s "buffer" '())
                     s))
  (eng:data-prop obj "readable" (eng:js-boolean readable))
  (eng:data-prop obj "writable" (eng:js-boolean writable))
  (eng:data-prop obj "destroyed" eng:+false+)
  (when readable
    (let ((state (eng:js-get obj "_readableState")))
      (eng:data-prop state "flowing" eng:+null+)
      (eng:data-prop state "paused" eng:+false+)))
  obj)

(defun %stream-push (this chunk)
  (let* ((state (eng:js-get this "_readableState"))
         (buf (eng:js-get state "buffer"))
         (flowing (eng:js-get state "flowing"))
         (paused (eng:js-truthy (eng:js-get state "paused")))
         (auto-flow (or (eng:js-null-p flowing)
                        (eng:js-undefined-p flowing)
                        (eng:js-truthy flowing))))
    (if (and (not paused) auto-flow)
        (progn
          (eng:js-set state "flowing" eng:+true+ nil)
          (eng:js-call (eng:js-get this "emit") this (list "data" chunk)))
        (eng:hidden-prop state "buffer"
                         (append (if (listp buf) buf '()) (list chunk))))
    eng:+true+))

(defun %stream-read (this)
  (let* ((state (eng:js-get this "_readableState"))
         (buf (eng:js-get state "buffer")))
    (if (and (listp buf) buf)
        (progn (eng:hidden-prop state "buffer" (rest buf)) (first buf))
        eng:+null+)))

(defun %stream-write (this chunk encoding cb)
  (declare (ignore encoding))
  (let* ((state (eng:js-get this "_writableState"))
         (buf (eng:js-get state "buffer")))
    (eng:hidden-prop state "buffer" (append (if (listp buf) buf '()) (list chunk)))
    (eng:js-call (eng:js-get this "emit") this (list "data" chunk))
    (when (eng:callable-p cb) (eng:js-call cb (undef) (list eng:+null+)))
    eng:+true+))

(defun %stream-end (this chunk encoding cb)
  (unless (undef-p chunk)
    (%stream-write this chunk encoding eng:+undefined+))
  (let ((state (eng:js-get this "_writableState")))
    (eng:js-set state "ended" eng:+true+ nil)
    (eng:js-set state "finished" eng:+true+ nil))
  (eng:js-call (eng:js-get this "emit") this (list "finish"))
  (eng:js-call (eng:js-get this "emit") this (list "end"))
  (when (eng:callable-p cb) (eng:js-call cb (undef) '()))
  this)

(defun %stream-destroy (this err)
  (eng:js-set this "destroyed" eng:+true+ nil)
  (unless (undef-p err)
    (eng:js-call (eng:js-get this "emit") this (list "error" err)))
  (eng:js-call (eng:js-get this "emit") this (list "close"))
  this)

(defun %stream-wire-ee (proto)
  (let ((ee-proto (eng:js-get (eng:js-get (build-node-events) "EventEmitter") "prototype")))
    (dolist (name '("on" "once" "emit" "removeListener" "off" "addListener"
                    "removeAllListeners" "listenerCount" "listeners" "prependListener"))
      (let ((fn (eng:js-get ee-proto name)))
        (when (eng:callable-p fn) (eng:data-prop proto name fn))))))

(defun %make-stream-class (name readable writable &key transform)
  (let* ((proto (eng:new-object))
         (ctor (eng:make-native-function
                name 1
                (lambda (this args)
                  (when (eng:js-object-p this)
                    (let ((opts (a args 0)) (om nil) (hwm 16384))
                      (when (eng:js-object-p opts)
                        (setf om (eng:js-truthy (eng:js-get opts "objectMode")))
                        (let ((h (eng:js-get opts "highWaterMark")))
                          (unless (undef-p h) (setf hwm (truncate (->num h))))))
                      (%stream-init this :readable readable :writable writable
                                    :object-mode om :high-water-mark hwm)
                      (when transform
                        (eng:hidden-prop this "_transform"
                                         (if (eng:js-object-p opts)
                                             (eng:js-get opts "transform")
                                             eng:+undefined+)))))
                  (undef))
                :construct
                (lambda (args nt)
                  (declare (ignore nt))
                  (let ((obj (eng:js-make-object proto))
                        (opts (a args 0)) (om nil) (hwm 16384))
                    (when (eng:js-object-p opts)
                      (setf om (eng:js-truthy (eng:js-get opts "objectMode")))
                      (let ((h (eng:js-get opts "highWaterMark")))
                        (unless (undef-p h) (setf hwm (truncate (->num h))))))
                    (%stream-init obj :readable readable :writable writable
                                  :object-mode om :high-water-mark hwm)
                    (when transform
                      (eng:hidden-prop obj "_transform"
                                       (if (eng:js-object-p opts)
                                           (eng:js-get opts "transform")
                                           eng:+undefined+)))
                    obj)))))
    (eng:data-prop ctor "prototype" proto)
    (eng:data-prop proto "constructor" ctor)
    (%stream-wire-ee proto)
    (when readable
      (eng:install-method proto "push" 1
        (lambda (this args) (%stream-push this (a args 0))))
      (eng:install-method proto "read" 1
        (lambda (this args) (declare (ignore args)) (%stream-read this)))
      (eng:install-method proto "resume" 0
        (lambda (this args)
          (declare (ignore args))
          (let ((state (eng:js-get this "_readableState")))
            (eng:js-set state "paused" eng:+false+ nil)
            (eng:js-set state "flowing" eng:+true+ nil)
            ;; Drain buffered chunks as 'data' events (Node-ish flowing mode).
            (loop for chunk = (%stream-read this)
                  until (eng:js-null-p chunk)
                  do (eng:js-call (eng:js-get this "emit") this
                                  (list "data" chunk)))
            (eng:js-call (eng:js-get this "emit") this (list "resume")))
          this))
      (eng:install-method proto "pause" 0
        (lambda (this args)
          (declare (ignore args))
          (let ((state (eng:js-get this "_readableState")))
            (eng:js-set state "paused" eng:+true+ nil)
            (eng:js-set state "flowing" eng:+false+ nil)
            (eng:js-call (eng:js-get this "emit") this (list "pause")))
          this))
      (eng:install-method proto "isPaused" 0
        (lambda (this args)
          (declare (ignore args))
          (let ((state (eng:js-get this "_readableState")))
            (eng:js-boolean (eng:js-truthy (eng:js-get state "paused"))))))
      (eng:install-method proto "pipe" 2
        (lambda (this args)
          (let ((dest (a args 0)))
            (eng:js-call (eng:js-get this "on") this
              (list "data"
                    (eng:make-native-function "" 1
                      (lambda (tt aa) (declare (ignore tt))
                        (when (eng:js-object-p dest)
                          (let ((w (eng:js-get dest "write")))
                            (when (eng:callable-p w)
                              (eng:js-call w dest (list (a aa 0))))))
                        (undef)))))
            (eng:js-call (eng:js-get this "on") this
              (list "end"
                    (eng:make-native-function "" 0
                      (lambda (tt aa) (declare (ignore tt aa))
                        (when (eng:js-object-p dest)
                          (let ((e (eng:js-get dest "end")))
                            (when (eng:callable-p e)
                              (eng:js-call e dest '()))))
                        (undef)))))
            dest))))
    (when writable
      (eng:install-method proto "write" 3
        (lambda (this args)
          (let ((chunk (a args 0)) (enc (a args 1)) (cb (a args 2)))
            (when (eng:callable-p enc) (setf cb enc enc (undef)))
            (if transform
                (let ((tf (eng:js-get this "_transform")))
                  (if (eng:callable-p tf)
                      (progn
                        (eng:js-call tf this
                          (list chunk enc
                                (eng:make-native-function "" 2
                                  (lambda (tt aa) (declare (ignore tt))
                                    (unless (or (undef-p (a aa 0))
                                                (eng:js-null-p (a aa 0)))
                                      (eng:js-call (eng:js-get this "emit") this
                                                   (list "error" (a aa 0))))
                                    (unless (undef-p (a aa 1))
                                      (%stream-push this (a aa 1)))
                                    (when (eng:callable-p cb)
                                      (eng:js-call cb (undef) (list eng:+null+)))
                                    (undef)))))
                        eng:+true+)
                      (%stream-write this chunk enc cb)))
                (%stream-write this chunk enc cb)))))
      (eng:install-method proto "end" 3
        (lambda (this args)
          (let ((chunk (a args 0)) (enc (a args 1)) (cb (a args 2)))
            (when (eng:callable-p chunk) (setf cb chunk chunk (undef)))
            (when (eng:callable-p enc) (setf cb enc enc (undef)))
            (%stream-end this chunk enc cb)))))
    (eng:install-method proto "destroy" 1
      (lambda (this args) (%stream-destroy this (a args 0))))
    ctor))

(defun %stream-finished (stream opts cb)
  (declare (ignore opts))
  (let ((done nil))
    (flet ((finish (&optional err)
             (unless done
               (setf done t)
               (when (eng:callable-p cb)
                 (eng:js-call cb (undef) (list (or err eng:+null+)))))))
      (eng:js-call (eng:js-get stream "once") stream
                   (list "end" (eng:make-native-function "" 0
                                 (lambda (tt aa) (declare (ignore tt aa))
                                   (finish) (undef)))))
      (eng:js-call (eng:js-get stream "once") stream
                   (list "finish" (eng:make-native-function "" 0
                                    (lambda (tt aa) (declare (ignore tt aa))
                                      (finish) (undef)))))
      (eng:js-call (eng:js-get stream "once") stream
                   (list "error" (eng:make-native-function "" 1
                                   (lambda (tt aa) (declare (ignore tt))
                                     (finish (a aa 0)) (undef)))))
      (eng:js-call (eng:js-get stream "once") stream
                   (list "close" (eng:make-native-function "" 0
                                   (lambda (tt aa) (declare (ignore tt aa))
                                     (finish) (undef))))))
    (undef)))

(defun %stream-pipeline (&rest streams-and-cb)
  (let* ((last (car (last streams-and-cb)))
         (cb (if (eng:callable-p last) last eng:+undefined+))
         (streams (if (eng:callable-p last) (butlast streams-and-cb) streams-and-cb)))
    (loop for (a b) on streams while b do
      (when (and (eng:js-object-p a) (eng:js-object-p b))
        (let ((pipe (eng:js-get a "pipe")))
          (when (eng:callable-p pipe) (eng:js-call pipe a (list b))))))
    (when (and streams (eng:callable-p cb))
      (let ((tail (car (last streams))))
        (when (eng:js-object-p tail)
          (%stream-finished tail eng:+undefined+ cb))))
    (undef)))

(defun %stream-promise-settle (resolve reject err)
  (if (or (undef-p err) (eng:js-null-p err))
      (eng:js-call resolve (undef) '())
      (eng:js-call reject (undef) (list err)))
  (undef))

(defun build-node-stream-promises ()
  (let ((o (eng:new-object)))
    (eng:install-method o "finished" 2
      (lambda (this args)
        (declare (ignore this))
        (let ((g (eng:realm-global eng:*realm*))
              (stream (a args 0))
              (opts (a args 1)))
          (eng:js-construct
           (eng:js-get g "Promise")
           (list
            (eng:make-native-function
             "" 2
             (lambda (tt aa)
               (declare (ignore tt))
               (%stream-finished
                stream opts
                (eng:make-native-function
                 "" 1
                 (lambda (t2 a2)
                   (declare (ignore t2))
                   (%stream-promise-settle (a aa 0) (a aa 1) (a a2 0)))))
               (undef))))))))
    (eng:install-method o "pipeline" 0
      (lambda (this args)
        (declare (ignore this))
        (let ((g (eng:realm-global eng:*realm*)))
          (eng:js-construct
           (eng:js-get g "Promise")
           (list
            (eng:make-native-function
             "" 2
             (lambda (tt aa)
               (declare (ignore tt))
               (apply #'%stream-pipeline
                      (append
                       args
                       (list
                        (eng:make-native-function
                         "" 1
                         (lambda (t2 a2)
                           (declare (ignore t2))
                           (%stream-promise-settle (a aa 0) (a aa 1) (a a2 0)))))))
               (undef))))))))
    o))

(defun %stream-chunks-to-result (chunks mode)
  (cond
    ((eq mode :array) (eng:new-array chunks))
    ((eq mode :text)
     (apply #'concatenate 'string (mapcar #'->str chunks)))
    ((eq mode :buffer)
     (%buffer-from-octets
      (apply #'concatenate '(vector (unsigned-byte 8))
             (mapcar (lambda (c)
                       (if (eng:js-typed-array-p c)
                           (multiple-value-bind (b o l) (eng:ta-octets c)
                             (subseq b o (+ o l)))
                           (sb-ext:string-to-octets (->str c)
                                                    :external-format :utf-8)))
                     chunks))))
    (t (eng:new-array chunks))))

(defun %stream-consumer-promise (stream mode)
  (let ((g (eng:realm-global eng:*realm*))
        (parts '()))
    (eng:js-construct
     (eng:js-get g "Promise")
     (list
      (eng:make-native-function
       "" 2
       (lambda (tt aa)
         (declare (ignore tt))
         (eng:js-call (eng:js-get stream "on") stream
                      (list "data"
                            (eng:make-native-function
                             "" 1
                             (lambda (t2 a2)
                               (declare (ignore t2))
                               (push (a a2 0) parts)
                               (undef)))))
         (eng:js-call (eng:js-get stream "on") stream
                      (list "end"
                            (eng:make-native-function
                             "" 0
                             (lambda (t2 a2)
                               (declare (ignore t2 a2))
                               (eng:js-call (a aa 0) (undef)
                                            (list (%stream-chunks-to-result
                                                   (nreverse parts) mode)))
                               (undef)))))
         (eng:js-call (eng:js-get stream "on") stream
                      (list "error"
                            (eng:make-native-function
                             "" 1
                             (lambda (t2 a2)
                               (declare (ignore t2))
                               (eng:js-call (a aa 1) (undef) (list (a a2 0)))
                               (undef)))))
         (undef)))))))

(defun build-node-stream-consumers ()
  (let ((o (eng:new-object)))
    (eng:install-method o "array" 1
      (lambda (this args)
        (declare (ignore this))
        (%stream-consumer-promise (a args 0) :array)))
    (eng:install-method o "text" 1
      (lambda (this args)
        (declare (ignore this))
        (%stream-consumer-promise (a args 0) :text)))
    (eng:install-method o "buffer" 1
      (lambda (this args)
        (declare (ignore this))
        (%stream-consumer-promise (a args 0) :buffer)))
    (eng:install-method o "json" 1
      (lambda (this args)
        (declare (ignore this))
        (%stream-consumer-promise (a args 0) :text)))
    o))

(defun build-node-stream-web ()
  (let ((o (eng:new-object))
        (g (eng:realm-global eng:*realm*)))
    (eng:data-prop o "ReadableStream" (eng:js-get g "ReadableStream"))
    (eng:data-prop o "WritableStream" (eng:js-get g "WritableStream"))
    (eng:data-prop o "TransformStream" (eng:js-get g "TransformStream"))
    (eng:install-method o "toWeb" 1
      (lambda (this args) (declare (ignore this)) (a args 0)))
    (eng:install-method o "fromWeb" 1
      (lambda (this args) (declare (ignore this)) (a args 0)))
    o))

(defun build-node-stream ()
  (let* ((readable (%make-stream-class "Readable" t nil))
         (writable (%make-stream-class "Writable" nil t))
         (duplex (%make-stream-class "Duplex" t t))
         (transform (%make-stream-class "Transform" t t :transform t))
         (passthrough (%make-stream-class "PassThrough" t t))
         (o (eng:new-object)))
    (eng:data-prop o "Readable" readable)
    (eng:data-prop o "Writable" writable)
    (eng:data-prop o "Duplex" duplex)
    (eng:data-prop o "Transform" transform)
    (eng:data-prop o "PassThrough" passthrough)
    (eng:data-prop o "Stream" duplex)
    (eng:install-method o "finished" 3
      (lambda (this args) (declare (ignore this))
        (%stream-finished (a args 0) (a args 1) (a args 2))))
    (eng:install-method o "pipeline" 0
      (lambda (this args) (declare (ignore this))
        (apply #'%stream-pipeline args)))
    (eng:install-method o "compose" 0
      (lambda (this args) (declare (ignore this))
        (apply #'%stream-pipeline (append args (list eng:+undefined+)))
        (first args)))
    (eng:data-prop o "promises" (build-node-stream-promises))
    (eng:data-prop o "consumers" (build-node-stream-consumers))
    (eng:data-prop o "web" (build-node-stream-web))
    o))

(register-node-builtin "stream" #'build-node-stream)
(register-node-builtin "stream/promises" #'build-node-stream-promises)
(register-node-builtin "stream/consumers" #'build-node-stream-consumers)
(register-node-builtin "stream/web" #'build-node-stream-web)
