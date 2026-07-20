;;;; style.lisp — modern CLI surface: color, progress, and one emit API.
;;;;
;;;; Every user-facing success/error/warn/info line should go through this file
;;;; (or thin wrappers that call it). Ad-hoc `format *error-output* "clun: …"`
;;;; elsewhere is a bug — route it here so TTY/NO_COLOR, glyphs, and wording stay
;;;; consistent.
;;;;
;;;; Design (2026 product feel — Bun/uv/cargo-adjacent):
;;;;   ✔  green success     (style-ok)
;;;;   ✖  red failure       (style-err) — also plain `clun: …` for errors
;;;;   !  yellow warning    (style-warn)
;;;;   ·  cyan info / step  (style-info)
;;;;   dim secondary text
;;;;   braille spinner while long work runs on a TTY
;;;;
;;;; Env: NO_COLOR disables; CLUN_FORCE_COLOR / *cli-force-color* forces.

(in-package :clun.cli)

(defparameter *cli-force-color* nil
  "When T, force ANSI colors even if the sink is not a TTY (tests).")

(defparameter *cli-no-color* nil
  "When T, never emit ANSI (tests / explicit off).")

(defparameter *cli-brand* "clun"
  "Product name used as the default error/success prefix.")

;;; --- color enablement -------------------------------------------------------

(defun %env-no-color-p ()
  (let ((v (clun.sys:getenv "NO_COLOR")))
    (and v (plusp (length v)))))

(defun %env-force-color-p ()
  (let ((v (clun.sys:getenv "CLUN_FORCE_COLOR")))
    (and v (plusp (length v)) (not (string= v "0")))))

(defun cli-color-enabled-p (&optional (stream *standard-output*))
  "T when ANSI styling should be applied to STREAM.
Order: explicit Lisp force/off → CLUN_FORCE_COLOR → NO_COLOR → TTY detect.
CLUN_FORCE_COLOR wins over NO_COLOR so CI demos and recordings can opt back in."
  (cond
    (*cli-no-color* nil)
    (*cli-force-color* t)
    ((%env-force-color-p) t)
    ((%env-no-color-p) nil)
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

;;; --- glyphs (one place) -----------------------------------------------------

(defparameter *glyph-ok* "✔")
(defparameter *glyph-err* "✖")
(defparameter *glyph-warn* "!")
(defparameter *glyph-info* "·")
(defparameter *glyph-step* "→")

;;; --- brand / command prefix -------------------------------------------------

(defun %cmd-label (command)
  "Build 'clun' or 'clun <command>' for user-facing prefixes."
  (cond
    ((null command) *cli-brand*)
    ((stringp command) (format nil "~a ~a" *cli-brand* command))
    ((symbolp command) (format nil "~a ~a" *cli-brand* (string-downcase (symbol-name command))))
    (t (format nil "~a ~a" *cli-brand* command))))

(defun brand-prefix (&optional command (stream *error-output*))
  "Styled brand/command prefix ending with ':' (e.g. clun: / clun install:)."
  (style-err (format nil "~a:" (%cmd-label command)) stream))

;;; --- high-level emit API (THE place for messages) ---------------------------

(defun emit-ok (message &key (stream *standard-output*) command)
  "Print a success line:  ✔ message  (optional dim command context is unused for OK)."
  (declare (ignore command))
  (format stream "~a ~a~%" (style-ok *glyph-ok* stream) message)
  (force-output stream)
  (values))

(defun emit-err (message &key (stream *error-output*) command)
  "Print an error line:  clun[ cmd]: message  in red."
  (format stream "~a ~a~%"
          (brand-prefix command stream)
          (style-err (princ-to-string message) stream))
  (force-output stream)
  (values))

(defun emit-warn (message &key (stream *standard-output*) command)
  "Print a warning:  ! message  (yellow)."
  (declare (ignore command))
  (format stream "~a ~a~%" (style-warn *glyph-warn* stream) message)
  (force-output stream)
  (values))

(defun emit-info (message &key (stream *standard-output*) command)
  "Print an info/step line:  · message  (cyan)."
  (declare (ignore command))
  (format stream "~a ~a~%" (style-info *glyph-info* stream) message)
  (force-output stream)
  (values))

(defun emit-note (message &key (stream *standard-output*))
  "Dim secondary note (no glyph)."
  (format stream "  ~a ~a~%"
          (style-dim "note:" stream)
          (style-dim (princ-to-string message) stream))
  (force-output stream)
  (values))

(defun emit-plain (message &key (stream *standard-output*))
  "Unstyled line (still flushed). Prefer emit-* when possible."
  (format stream "~a~%" message)
  (force-output stream)
  (values))

(defun fail (message &key command (exit 1) (stream *error-output*) hint)
  "Emit an error and return EXIT (default 1). Optional HINT prints as a dim note."
  (emit-err message :stream stream :command command)
  (when hint (emit-note hint :stream stream))
  exit)

(defun usage-fail (message &key command (stream *error-output*))
  "Emit a usage error and return exit code 2 with a help hint."
  (fail message :command command :exit 2 :stream stream
        :hint "run `clun --help` for usage"))

;;; --- spinner / animated progress --------------------------------------------

(defparameter *spinner-frames*
  #("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  "Braille spinner frames (compact, modern terminals).")

(defparameter *spinner-ascii-frames*
  #("|" "/" "-" "\\")
  "ASCII fallback when color/TTY is off or glyphs unavailable.")

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
    (format (spinner-stream spinner) "~c~80@t~c" #\Return #\Return)
    (force-output (spinner-stream spinner))
    (setf (spinner-active spinner) nil))
  (let* ((msg (or message (spinner-label spinner)))
         (mark (if ok
                   (style-ok *glyph-ok* (spinner-stream spinner))
                   (style-err *glyph-err* (spinner-stream spinner)))))
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

(defun call-with-progress (label thunk &key done-message (stream *standard-output*))
  "Run THUNK while animating a TTY spinner labelled LABEL.
DONE-MESSAGE may be a string or a function of the thunk's primary return value.
On non-TTY sinks, prints a single ✔ line after success (no animation).
Errors propagate after the spinner is stopped with ✖."
  (let* ((use-spin (cli-color-enabled-p stream))
         (spin (when use-spin (make-spinner :label label :stream stream)))
         (stop nil)
         (thread nil)
         (ok nil)
         (result nil)
         (final label))
    (when use-spin
      (setf thread
            (sb-thread:make-thread
             (lambda ()
               (loop until stop do
                 (spinner-tick spin)
                 (sleep 0.08)))
             :name "clun-cli-spinner")))
    (unwind-protect
         (progn
           (setf result (funcall thunk))
           (setf ok t
                 final (cond
                         ((functionp done-message) (funcall done-message result))
                         (done-message done-message)
                         (t label)))
           result)
      (setf stop t)
      (when thread
        (ignore-errors (sb-thread:join-thread thread :timeout 0.5)))
      (cond
        ;; Success: ✔ final. Failure: clear the spinner line only — the caller
        ;; (cli:fail / condition handler) prints the real human error.
        ((and use-spin ok)
         (spinner-stop spin :ok t :message final))
        (use-spin
         (when (spinner-active spin)
           (format stream "~c~80@t~c" #\Return #\Return)
           (force-output stream)
           (setf (spinner-active spin) nil)))
        (ok
         (format stream "~a ~a~%" (style-ok *glyph-ok* stream) final)
         (force-output stream))))))

(defmacro with-progress ((label &key (stream '*standard-output*) done-message) &body body)
  "Animate LABEL while BODY runs; optional DONE-MESSAGE (string or (lambda (result)))."
  `(call-with-progress ,label (lambda () ,@body)
                       :done-message ,done-message
                       :stream ,stream))
