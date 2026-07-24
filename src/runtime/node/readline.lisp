;;;; readline.lisp — node:readline + readline/promises.
;;;; createInterface does real line buffering over input stream 'data' events.

(in-package :clun.runtime)

(defun %rl-wire-ee (obj)
  (let ((ee-proto (eng:js-get (eng:js-get (build-node-events) "EventEmitter")
                              "prototype")))
    (dolist (name '("on" "once" "emit" "removeListener" "off" "addListener"
                    "removeAllListeners" "listenerCount" "listeners"))
      (let ((fn (eng:js-get ee-proto name)))
        (when (eng:callable-p fn) (eng:data-prop obj name fn))))
    obj))

(defun %rl-chunk->string (chunk)
  (cond
    ((stringp chunk) chunk)
    ((eng:js-object-p chunk)
     (let ((to-s (eng:js-get chunk "toString")))
       (if (eng:callable-p to-s)
           (->str (eng:js-call to-s chunk '()))
           (->str chunk))))
    (t (->str chunk))))

(defun %rl-deliver-line (iface line)
  "Emit 'line' and satisfy the oldest pending question callback/promise."
  (eng:data-prop iface "line" line)
  (let ((emit (eng:js-get iface "emit")))
    (when (eng:callable-p emit)
      (eng:js-call emit iface (list "line" line))))
  (let ((pending (eng:js-get iface "%pendingQuestions%")))
    (when (and (listp pending) pending)
      (let ((cb (car pending)))
        (eng:hidden-prop iface "%pendingQuestions%" (cdr pending))
        (when (eng:callable-p cb)
          (eng:js-call cb (undef) (list line)))))))

(defun %rl-feed (iface text)
  "Append TEXT to the interface buffer; deliver complete lines."
  (let* ((buf (or (eng:js-get iface "%buf%") ""))
         (combined (concatenate 'string
                                (if (stringp buf) buf (->str buf))
                                (if (stringp text) text (->str text))))
         (start 0)
         (len (length combined)))
    (loop
      (let ((nl (position #\Newline combined :start start)))
        (unless nl
          (eng:hidden-prop iface "%buf%" (subseq combined start))
          (return))
        (let* ((cr (and (plusp nl) (char= (char combined (1- nl)) #\Return)))
               (line (subseq combined start (if cr (1- nl) nl))))
          (%rl-deliver-line iface line)
          (setf start (1+ nl)))))
    (when (>= start len)
      (eng:hidden-prop iface "%buf%" ""))
    (undef)))

(defun %rl-attach-input (iface input)
  "Listen for 'data' (and 'end') on INPUT stream for line buffering."
  (when (eng:js-object-p input)
    (let ((on (eng:js-get input "on")))
      (when (eng:callable-p on)
        (eng:js-call on input
          (list "data"
                (eng:make-native-function "" 1
                  (lambda (tt aa) (declare (ignore tt))
                    (unless (eng:js-truthy (eng:js-get iface "%paused%"))
                      (%rl-feed iface (%rl-chunk->string (a aa 0))))
                    (undef)))))
        (eng:js-call on input
          (list "end"
                (eng:make-native-function "" 0
                  (lambda (tt aa) (declare (ignore tt aa))
                    (let ((buf (eng:js-get iface "%buf%")))
                      (when (and (stringp buf) (plusp (length buf)))
                        (%rl-deliver-line iface buf)
                        (eng:hidden-prop iface "%buf%" "")))
                    (let ((emit (eng:js-get iface "emit")))
                      (when (eng:callable-p emit)
                        (eng:js-call emit iface (list "close"))))
                    (undef))))))))
  iface)

(defun %rl-make-interface (opts)
  (let ((iface (%rl-wire-ee (%ev-init (eng:new-object)))))
    (eng:data-prop iface "line" "")
    (eng:data-prop iface "cursor" 0d0)
    (eng:data-prop iface "prompt" "> ")
    (eng:hidden-prop iface "%buf%" "")
    (eng:hidden-prop iface "%pendingQuestions%" '())
    (eng:hidden-prop iface "%paused%" eng:+false+)
    (eng:hidden-prop iface "%closed%" eng:+false+)
    (when (eng:js-object-p opts)
      (eng:data-prop iface "input" (eng:js-get opts "input"))
      (eng:data-prop iface "output" (eng:js-get opts "output"))
      (eng:data-prop iface "terminal" (eng:js-get opts "terminal"))
      (let ((p (eng:js-get opts "prompt")))
        (unless (undef-p p) (eng:data-prop iface "prompt" (->str p)))))
    (%rl-attach-input iface (eng:js-get iface "input"))
    (eng:install-method iface "question" 2
      (lambda (this args)
        (let ((query (a args 0)) (cb (a args 1))
              (out (eng:js-get this "output")))
          (when (and (eng:js-object-p out)
                     (eng:callable-p (eng:js-get out "write")))
            (eng:js-call (eng:js-get out "write") out (list query)))
          (when (eng:callable-p cb)
            (let ((pending (or (eng:js-get this "%pendingQuestions%") '())))
              (eng:hidden-prop this "%pendingQuestions%"
                               (append pending (list cb)))))
          (undef))))
    (eng:install-method iface "close" 0
      (lambda (this args) (declare (ignore args))
        (unless (eng:js-truthy (eng:js-get this "%closed%"))
          (eng:hidden-prop this "%closed%" eng:+true+)
          (let ((buf (eng:js-get this "%buf%")))
            (when (and (stringp buf) (plusp (length buf)))
              (%rl-deliver-line this buf)
              (eng:hidden-prop this "%buf%" "")))
          (let ((emit (eng:js-get this "emit")))
            (when (eng:callable-p emit)
              (eng:js-call emit this (list "close")))))
        (undef)))
    (eng:install-method iface "pause" 0
      (lambda (this args) (declare (ignore args))
        (eng:hidden-prop this "%paused%" eng:+true+)
        this))
    (eng:install-method iface "resume" 0
      (lambda (this args) (declare (ignore args))
        (eng:hidden-prop this "%paused%" eng:+false+)
        this))
    (eng:install-method iface "write" 2
      (lambda (this args)
        (let ((data (a args 0))
              (out (eng:js-get this "output")))
          (unless (undef-p data)
            (%rl-feed this (%rl-chunk->string data))
            (when (and (eng:js-object-p out)
                       (eng:callable-p (eng:js-get out "write")))
              (eng:js-call (eng:js-get out "write") out (list data))))
          (undef))))
    (eng:install-method iface "prompt" 1
      (lambda (this args) (declare (ignore args))
        (let ((out (eng:js-get this "output"))
              (p (eng:js-get this "prompt")))
          (when (and (eng:js-object-p out)
                     (eng:callable-p (eng:js-get out "write")))
            (eng:js-call (eng:js-get out "write") out
                         (list (if (undef-p p) "> " (->str p))))))
        (undef)))
    (eng:install-method iface "setPrompt" 1
      (lambda (this args)
        (eng:data-prop this "prompt" (->str (a args 0)))
        (undef)))
    iface))

(defun build-node-readline-promises ()
  (let ((o (eng:new-object)))
    (eng:install-method o "createInterface" 1
      (lambda (this args) (declare (ignore this))
        (let ((iface (%rl-make-interface (a args 0)))
              (g (eng:realm-global eng:*realm*)))
          (eng:install-method iface "question" 1
            (lambda (this args)
              (let ((query (a args 0))
                    (out (eng:js-get this "output")))
                (eng:js-construct (eng:js-get g "Promise")
                  (list (eng:make-native-function "" 2
                          (lambda (tt aa) (declare (ignore tt))
                            (let ((resolve (a aa 0)))
                              (when (and (eng:js-object-p out)
                                         (eng:callable-p (eng:js-get out "write")))
                                (eng:js-call (eng:js-get out "write") out (list query)))
                              (let ((pending (or (eng:js-get this "%pendingQuestions%") '())))
                                (eng:hidden-prop this "%pendingQuestions%"
                                                 (append pending (list resolve))))
                              (undef)))))))))
          iface)))
    o))

(defun build-node-readline ()
  (let ((o (eng:new-object)))
    (eng:install-method o "createInterface" 1
      (lambda (this args) (declare (ignore this))
        (%rl-make-interface (a args 0))))
    (eng:install-method o "cursorTo" 3
      (lambda (this args) (declare (ignore this))
        (let ((stream (a args 0)) (x (a args 1)) (y (a args 2)))
          (when (and (eng:js-object-p stream)
                     (eng:callable-p (eng:js-get stream "write")))
            (let ((seq (if (undef-p y)
                           (format nil "~c[~dG" #\Esc (1+ (truncate (->num x))))
                           (format nil "~c[~d;~dH" #\Esc
                                   (1+ (truncate (->num y)))
                                   (1+ (truncate (->num x)))))))
              (eng:js-call (eng:js-get stream "write") stream (list seq))))
          eng:+true+)))
    (eng:install-method o "moveCursor" 3
      (lambda (this args) (declare (ignore this))
        (let ((stream (a args 0)) (dx (a args 1)) (dy (a args 2)))
          (when (and (eng:js-object-p stream)
                     (eng:callable-p (eng:js-get stream "write")))
            (let ((parts '()))
              (unless (zerop (truncate (->num dx)))
                (let ((n (truncate (->num dx))))
                  (push (format nil "~c[~d~c" #\Esc (abs n) (if (plusp n) #\C #\D))
                        parts)))
              (unless (zerop (truncate (->num dy)))
                (let ((n (truncate (->num dy))))
                  (push (format nil "~c[~d~c" #\Esc (abs n) (if (plusp n) #\B #\A))
                        parts)))
              (when parts
                (eng:js-call (eng:js-get stream "write") stream
                             (list (apply #'concatenate 'string (nreverse parts)))))))
          eng:+true+)))
    (eng:install-method o "clearLine" 2
      (lambda (this args) (declare (ignore this))
        (let ((stream (a args 0))
              (dir (if (undef-p (a args 1)) 0 (truncate (->num (a args 1))))))
          (when (and (eng:js-object-p stream)
                     (eng:callable-p (eng:js-get stream "write")))
            (eng:js-call (eng:js-get stream "write") stream
                         (list (format nil "~c[~dK" #\Esc
                                       (cond ((minusp dir) 1)
                                             ((plusp dir) 0)
                                             (t 2))))))
          eng:+true+)))
    (eng:install-method o "clearScreenDown" 1
      (lambda (this args) (declare (ignore this))
        (let ((stream (a args 0)))
          (when (and (eng:js-object-p stream)
                     (eng:callable-p (eng:js-get stream "write")))
            (eng:js-call (eng:js-get stream "write") stream
                         (list (format nil "~c[0J" #\Esc))))
          eng:+true+)))
    (eng:install-method o "emitKeypressEvents" 2
      (lambda (this args) (declare (ignore this))
        (let ((stream (a args 0)))
          (when (eng:js-object-p stream)
            (eng:hidden-prop stream "%keypressEvents%" eng:+true+)))
        (undef)))
    (eng:data-prop o "promises" (build-node-readline-promises))
    (let* ((proto (eng:new-object))
           (ctor (eng:make-native-function "Interface" 1
                   (lambda (this args)
                     (declare (ignore this))
                     (%rl-make-interface (a args 0)))
                   :construct
                   (lambda (args nt)
                     (declare (ignore nt))
                     (%rl-make-interface (a args 0))))))
      (eng:data-prop ctor "prototype" proto)
      (eng:data-prop o "Interface" ctor))
    o))

(register-node-builtin "readline" #'build-node-readline)
(register-node-builtin "readline/promises" #'build-node-readline-promises)
