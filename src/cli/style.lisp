;;;; style.lisp — ANSI colors and lightweight TTY progress for the CLI.
;;;; Respects NO_COLOR and non-TTY sinks (plain text then).

(in-package :clun.cli)

(defparameter *cli-force-color* nil
  "When T, force ANSI colors even if the sink is not a TTY (tests).")

(defparameter *cli-no-color* nil
  "When T, never emit ANSI (tests / explicit off).")

(defun %env-no-color-p ()
  (let ((v (clun.sys:getenv "NO_COLOR")))
    (and v (plusp (length v)))))

(defun %env-force-color-p ()
  (let ((v (clun.sys:getenv "CLUN_FORCE_COLOR")))
    (and v (plusp (length v)) (not (string= v "0")))))

(defun cli-color-enabled-p (&optional (stream *standard-output*))
  "T when ANSI styling should be applied to STREAM."
  (cond
    (*cli-no-color* nil)
    (*cli-force-color* t)
    ((%env-no-color-p) nil)
    ((%env-force-color-p) t)
    (t
     (handler-case
         #+(and sbcl unix)
         (and (typep stream 'sb-sys:fd-stream)
              (plusp (sb-unix:unix-isatty (sb-sys:fd-stream-fd stream))))
         #-(and sbcl unix)
         (interactive-stream-p stream)
       (error () nil)))))

(defun %sgr (codes text enabled)
  (if (and enabled codes)
      (format nil "~c[~{~a~^;~}m~a~c[0m" #\Esc codes text #\Esc)
      text))

(defun style (text &key (stream *standard-output*) bold dim green yellow red cyan magenta)
  "Return TEXT with optional SGR attributes when color is enabled for STREAM."
  (let ((enabled (cli-color-enabled-p stream))
        (codes '()))
    (when bold (push 1 codes))
    (when dim (push 2 codes))
    (when red (push 31 codes))
    (when green (push 32 codes))
    (when yellow (push 33 codes))
    (when cyan (push 36 codes))
    (when magenta (push 35 codes))
    (%sgr (nreverse codes) text enabled)))

(defun style-ok (text &optional (stream *standard-output*))
  (style text :stream stream :green t :bold t))

(defun style-warn (text &optional (stream *standard-output*))
  (style text :stream stream :yellow t :bold t))

(defun style-err (text &optional (stream *error-output*))
  (style text :stream stream :red t :bold t))

(defun style-info (text &optional (stream *standard-output*))
  (style text :stream stream :cyan t))

(defun style-dim (text &optional (stream *standard-output*))
  (style text :stream stream :dim t))

(defun style-brand (text &optional (stream *standard-output*))
  (style text :stream stream :magenta t :bold t))

;;; --- spinner ----------------------------------------------------------------

(defparameter *spinner-frames*
  #("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  "Braille spinner frames (cute, compact).")

(defparameter *spinner-ascii-frames*
  #("|" "/" "-" "\\")
  "ASCII fallback when the locale cannot show Braille.")

(defun %spinner-frames ()
  (if (cli-color-enabled-p)
      *spinner-frames*
      *spinner-ascii-frames*))

(defstruct (cli-spinner (:conc-name spinner-))
  (label "working")
  (stream *standard-output*)
  (index 0)
  (active nil)
  (frames *spinner-frames*))

(defun make-spinner (&key (label "working") (stream *standard-output*))
  (make-cli-spinner :label label :stream stream :frames (%spinner-frames)))

(defun spinner-tick (spinner)
  "Advance SPINNER one frame (carriage-return line). No-op when not a TTY."
  (unless (cli-color-enabled-p (spinner-stream spinner))
    (return-from spinner-tick nil))
  (let* ((frames (spinner-frames spinner))
         (i (mod (spinner-index spinner) (length frames)))
         (frame (aref frames i)))
    (format (spinner-stream spinner) "~c~a ~a~c"
            #\Return
            (style frame :stream (spinner-stream spinner) :cyan t)
            (spinner-label spinner)
            #\Space)
    (force-output (spinner-stream spinner))
    (incf (spinner-index spinner))
    (setf (spinner-active spinner) t)
    t))

(defun spinner-stop (spinner &key (ok t) (message nil))
  "Clear the spinner line and print a final status."
  (when (spinner-active spinner)
    (format (spinner-stream spinner) "~c~40@t~c" #\Return #\Return)
    (force-output (spinner-stream spinner))
    (setf (spinner-active spinner) nil))
  (let* ((msg (or message (spinner-label spinner)))
         (mark (if ok
                   (style-ok "✔" (spinner-stream spinner))
                   (style-err "✖" (spinner-stream spinner)))))
    (format (spinner-stream spinner) "~a ~a~%" mark msg)
    (force-output (spinner-stream spinner))))

(defmacro with-spinner ((var &key (label "working") (stream '*standard-output*))
                        &body body)
  "Bind VAR to a spinner; stop OK on normal exit, error mark on non-local exit."
  (let ((ok (gensym "OK")))
    `(let ((,var (make-spinner :label ,label :stream ,stream))
           (,ok nil))
       (unwind-protect
            (multiple-value-prog1 (progn ,@body)
              (setf ,ok t))
         (spinner-stop ,var :ok ,ok)))))
