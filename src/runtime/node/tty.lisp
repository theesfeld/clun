;;;; tty.lisp — node:tty (isatty + ReadStream/WriteStream with real ANSI/color).

(in-package :clun.runtime)

(defun %tty-stream-for-fd (fd)
  (cond ((= fd 0) *standard-input*)
        ((= fd 2) *error-output*)
        (t *standard-output*)))

(defun %tty-write-ansi (fd seq)
  "Write ANSI sequence to the stream backing FD (1=stdout, 2=stderr)."
  (let ((stream (%tty-stream-for-fd (truncate fd))))
    (write-string seq stream)
    (finish-output stream)
    eng:+true+))

(defun %tty-color-depth (&optional env)
  "Node-compatible color depth: 1 | 4 | 8 | 24 from FORCE_COLOR/NO_COLOR/COLORTERM/TERM.
ENV, when a JS object, overrides process env keys (Node WriteStream#getColorDepth(env))."
  (flet ((env-get (name)
           (if (eng:js-object-p env)
               (let ((v (eng:js-get env name)))
                 (if (or (eng:js-undefined-p v) (eng:js-null-p v))
                     nil
                     (->str v)))
               (sys:getenv name))))
    (let ((force (env-get "FORCE_COLOR"))
          (no (env-get "NO_COLOR"))
          (colorterm (or (env-get "COLORTERM") ""))
          (term (or (env-get "TERM") "")))
      (cond
        ((and no (plusp (length no))) 1)
        ((and force (string= force "0")) 1)
        ((and force (or (string= force "3")
                        (and (plusp (length force))
                             (every #'digit-char-p force)
                             (>= (parse-integer force :junk-allowed t) 3))))
         24)
        ((and force (string= force "2")) 8)
        ((and force (or (string= force "1") (string= force "true")
                        (plusp (length force))))
         4)
        ((or (search "truecolor" colorterm :test #'char-equal)
             (search "24bit" colorterm :test #'char-equal))
         24)
        ((or (search "256color" term :test #'char-equal)
             (search "256" term :test #'char-equal))
         8)
        ((or (search "color" term :test #'char-equal)
             (member term '("xterm" "screen" "vt100" "ansi" "linux" "rxvt")
                     :test #'string-equal))
         4)
        (t 1)))))

(defun %tty-has-colors (count &optional env)
  "True when the terminal can display at least COUNT colors (Node hasColors)."
  (let* ((n (cond ((or (undef-p count) (eng:js-null-p count)
                       (eng:js-object-p count))
                   16)
                  (t (max 1 (truncate (->num count))))))
         (need (cond ((<= n 2) 1)
                     ((<= n 16) 4)
                     ((<= n 256) 8)
                     (t 24)))
         (depth (%tty-color-depth (if (eng:js-object-p count) count env))))
    (>= depth need)))

(defun %tty-clear-line (fd dir)
  "ANSI clear-line: dir 0=right, 1=left, 2=entire (CSI n K)."
  (let ((d (cond ((undef-p dir) 0)
                 (t (truncate (->num dir))))))
    (%tty-write-ansi fd (format nil "~c[~dK" #\Esc (max 0 (min 2 d))))))

(defun %tty-cursor-to (fd x &optional y)
  "ANSI cursor position. y omitted → column only (CSI n G); else CSI row;col H."
  (let ((col (1+ (max 0 (truncate (->num x))))))
    (if (or (undef-p y) (eng:js-null-p y))
        (%tty-write-ansi fd (format nil "~c[~dG" #\Esc col))
        (let ((row (1+ (max 0 (truncate (->num y))))))
          (%tty-write-ansi fd (format nil "~c[~d;~dH" #\Esc row col))))))

(defun %tty-move-cursor (fd dx dy)
  (let ((x (if (undef-p dx) 0 (truncate (->num dx))))
        (y (if (undef-p dy) 0 (truncate (->num dy)))))
    (when (/= y 0)
      (%tty-write-ansi fd (format nil "~c[~d~c" #\Esc (abs y) (if (plusp y) #\B #\A))))
    (when (/= x 0)
      (%tty-write-ansi fd (format nil "~c[~d~c" #\Esc (abs x) (if (plusp x) #\C #\D))))
    eng:+true+))

(defun %tty-clear-screen-down (fd)
  (%tty-write-ansi fd (format nil "~c[0J" #\Esc)))

(defun %tty-fd (this)
  (let ((fd (eng:js-get this "fd")))
    (if (undef-p fd) 1 (truncate (->num fd)))))

(defun build-node-tty ()
  (let ((o (eng:new-object)))
    (eng:install-method o "isatty" 1
      (lambda (this args) (declare (ignore this))
        (let ((fd (truncate (->num (a args 0)))))
          (eng:js-boolean
           (cond ((= fd 0) (sys:tty-p *standard-input*))
                 ((= fd 1) (sys:tty-p *standard-output*))
                 ((= fd 2) (sys:tty-p *error-output*))
                 (t nil))))))
    (let* ((ws-proto (eng:new-object))
           (ws-ctor
            (eng:make-native-function
             "WriteStream" 1
             (lambda (this args)
               (when (eng:js-object-p this)
                 (eng:data-prop this "fd" (->num (a args 0)))
                 (eng:data-prop this "isTTY" eng:+true+)
                 (eng:data-prop this "columns" 80d0)
                 (eng:data-prop this "rows" 24d0))
               (undef))
             :construct
             (lambda (args nt)
               (declare (ignore nt))
               (let ((obj (eng:js-make-object ws-proto)))
                 (eng:data-prop obj "fd" (->num (a args 0)))
                 (eng:data-prop obj "isTTY" eng:+true+)
                 (eng:data-prop obj "columns" 80d0)
                 (eng:data-prop obj "rows" 24d0)
                 obj)))))
      (eng:data-prop ws-ctor "prototype" ws-proto)
      (eng:install-method ws-proto "getColorDepth" 1
        (lambda (this args)
          (declare (ignore this))
          (coerce (%tty-color-depth (a args 0)) 'double-float)))
      (eng:install-method ws-proto "hasColors" 2
        (lambda (this args)
          (declare (ignore this))
          (eng:js-boolean (%tty-has-colors (a args 0) (a args 1)))))
      (eng:install-method ws-proto "clearLine" 1
        (lambda (this args)
          (%tty-clear-line (%tty-fd this) (a args 0))))
      (eng:install-method ws-proto "cursorTo" 2
        (lambda (this args)
          (%tty-cursor-to (%tty-fd this) (a args 0) (a args 1))))
      (eng:install-method ws-proto "moveCursor" 2
        (lambda (this args)
          (%tty-move-cursor (%tty-fd this) (a args 0) (a args 1))))
      (eng:install-method ws-proto "clearScreenDown" 0
        (lambda (this args)
          (declare (ignore args))
          (%tty-clear-screen-down (%tty-fd this))))
      (eng:install-method ws-proto "getWindowSize" 0
        (lambda (this args)
          (declare (ignore args))
          (eng:new-array
           (list (or (eng:js-get this "columns") 80d0)
                 (or (eng:js-get this "rows") 24d0)))))
      (eng:data-prop o "WriteStream" ws-ctor))
    (let* ((rs-proto (eng:new-object))
           (rs-ctor
            (eng:make-native-function
             "ReadStream" 1
             (lambda (this args)
               (when (eng:js-object-p this)
                 (eng:data-prop this "fd" (->num (a args 0)))
                 (eng:data-prop this "isTTY" eng:+true+)
                 (eng:data-prop this "isRaw" eng:+false+))
               (undef))
             :construct
             (lambda (args nt)
               (declare (ignore nt))
               (let ((obj (eng:js-make-object rs-proto)))
                 (eng:data-prop obj "fd" (->num (a args 0)))
                 (eng:data-prop obj "isTTY" eng:+true+)
                 (eng:data-prop obj "isRaw" eng:+false+)
                 obj)))))
      (eng:data-prop rs-ctor "prototype" rs-proto)
      (eng:install-method rs-proto "setRawMode" 1
        (lambda (this args)
          (eng:js-set this "isRaw" (eng:js-boolean (eng:js-truthy (a args 0))) nil)
          this))
      (eng:data-prop o "ReadStream" rs-ctor))
    o))

(register-node-builtin "tty" #'build-node-tty)
