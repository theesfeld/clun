;;;; style.lisp — Clun CLI surface: palette, glyphs, emit API, motion.
;;;;
;;;; Canonical home for every user-facing line. Commands must not ad-hoc
;;;; `format *error-output* "clun: …"` — route through emit-* / fail / progress.
;;;;
;;;; Visual language (2026 product CLI):
;;;;   ◆  brand mark (magenta)
;;;;   ●  success (bright green)   /  ✕  failure (bright red)
;;;;   ▲  warning (bright yellow)
;;;;   ›  info / step (bright cyan)
;;;;   →  transition (dim → bright)
;;;;   dense braille spinner while work runs on a TTY
;;;;
;;;; Env: NO_COLOR off; CLUN_FORCE_COLOR / *cli-force-color* force on (beats NO_COLOR).

(in-package :clun.cli)

(defparameter *cli-force-color* nil
  "When T, force ANSI colors even if the sink is not a TTY (tests).")

(defparameter *cli-no-color* nil
  "When T, never emit ANSI (tests / explicit off).")

(defparameter *cli-brand* "clun"
  "Product name used as the default error/success prefix.")

(defparameter *cli-ascii-glyphs* nil
  "When T, use ASCII glyph fallbacks even on a color TTY.")

;;; --- color enablement -------------------------------------------------------

(defun %env-no-color-p ()
  (let ((v (clun.sys:getenv "NO_COLOR")))
    (and v (plusp (length v)))))

(defun %env-force-color-p ()
  (let ((v (clun.sys:getenv "CLUN_FORCE_COLOR")))
    (and v (plusp (length v)) (not (string= v "0")))))

(defun %env-ascii-glyphs-p ()
  (let ((v (clun.sys:getenv "CLUN_ASCII")))
    (and v (plusp (length v)) (not (string= v "0")))))

(defun cli-color-enabled-p (&optional (stream *standard-output*))
  "T when ANSI styling should be applied to STREAM.
Order: explicit Lisp force/off → CLUN_FORCE_COLOR → NO_COLOR → TTY detect.
CLUN_FORCE_COLOR wins over NO_COLOR so demos and recordings can opt back in."
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

(defun style (text &key (stream *standard-output*) bold dim
                     green yellow red cyan magenta blue white
                     bright)
  "Return TEXT with optional SGR attributes when color is enabled for STREAM.
BRIGHT uses the 90–97 bright palette (modern terminals)."
  (let ((enabled (cli-color-enabled-p stream))
        (codes '()))
    (when bold (push 1 codes))
    (when dim (push 2 codes))
    (cond
      (bright
       (when red (push 91 codes))
       (when green (push 92 codes))
       (when yellow (push 93 codes))
       (when blue (push 94 codes))
       (when magenta (push 95 codes))
       (when cyan (push 96 codes))
       (when white (push 97 codes)))
      (t
       (when red (push 31 codes))
       (when green (push 32 codes))
       (when yellow (push 33 codes))
       (when blue (push 34 codes))
       (when magenta (push 35 codes))
       (when cyan (push 36 codes))
       (when white (push 37 codes))))
    (%sgr (nreverse codes) text enabled)))

(defun style-ok (text &optional (stream *standard-output*))
  (style text :stream stream :green t :bold t :bright t))

(defun style-warn (text &optional (stream *standard-output*))
  (style text :stream stream :yellow t :bold t :bright t))

(defun style-err (text &optional (stream *error-output*))
  (style text :stream stream :red t :bold t :bright t))

(defun style-info (text &optional (stream *standard-output*))
  (style text :stream stream :cyan t :bright t))

(defun style-dim (text &optional (stream *standard-output*))
  (style text :stream stream :dim t))

(defun style-brand (text &optional (stream *standard-output*))
  (style text :stream stream :magenta t :bold t :bright t))

(defun style-accent (text &optional (stream *standard-output*))
  "Secondary accent (blue) for meta labels."
  (style text :stream stream :blue t :bright t))

;;; --- glyphs (one place — the product mark language) -------------------------

(defun %use-unicode-glyphs-p ()
  (not (or *cli-ascii-glyphs* (%env-ascii-glyphs-p))))

(defun glyph-ok ()
  (if (%use-unicode-glyphs-p) "●" "*"))

(defun glyph-err ()
  (if (%use-unicode-glyphs-p) "✕" "x"))

(defun glyph-warn ()
  (if (%use-unicode-glyphs-p) "▲" "!"))

(defun glyph-info ()
  (if (%use-unicode-glyphs-p) "›" ">"))

(defun glyph-step ()
  (if (%use-unicode-glyphs-p) "→" "->"))

(defun glyph-brand ()
  (if (%use-unicode-glyphs-p) "◆" "#"))

(defun glyph-up ()
  (if (%use-unicode-glyphs-p) "↑" "^"))

(defun glyph-spin ()
  (if (%use-unicode-glyphs-p) "◎" "o"))

;;; Backward-compatible parameters (resolved at emit time via functions above).
(defparameter *glyph-ok* "●")
(defparameter *glyph-err* "✕")
(defparameter *glyph-warn* "▲")
(defparameter *glyph-info* "›")
(defparameter *glyph-step* "→")

;;; --- brand / command prefix -------------------------------------------------

(defun %cmd-label (command)
  "Build 'clun' or 'clun <command>' for user-facing prefixes."
  (cond
    ((null command) *cli-brand*)
    ((stringp command) (format nil "~a ~a" *cli-brand* command))
    ((symbolp command) (format nil "~a ~a" *cli-brand* (string-downcase (symbol-name command))))
    (t (format nil "~a ~a" *cli-brand* command))))

(defun brand-prefix (&optional command (stream *error-output*) &key (kind :err))
  "Styled brand/command prefix ending with ':'."
  (let ((label (format nil "~a:" (%cmd-label command))))
    (ecase kind
      (:err (style-err label stream))
      (:ok (style-ok label stream))
      (:info (style-info label stream))
      (:brand (style-brand label stream)))))

;;; --- high-level emit API ----------------------------------------------------

(defun emit-ok (message &key (stream *standard-output*) command)
  "Success:  ● message  (bright green)."
  (declare (ignore command))
  (format stream "~a ~a~%"
          (style-ok (glyph-ok) stream)
          message)
  (force-output stream)
  (values))

(defun emit-err (message &key (stream *error-output*) command)
  "Error:  ✕ clun[ cmd]: message  (bright red)."
  (format stream "~a ~a ~a~%"
          (style-err (glyph-err) stream)
          (brand-prefix command stream :kind :err)
          (style-err (princ-to-string message) stream))
  (force-output stream)
  (values))

(defun emit-warn (message &key (stream *standard-output*) command)
  "Warning:  ▲ message  (bright yellow)."
  (declare (ignore command))
  (format stream "~a ~a~%"
          (style-warn (glyph-warn) stream)
          (style-warn (princ-to-string message) stream))
  (force-output stream)
  (values))

(defun emit-info (message &key (stream *standard-output*) command)
  "Info/step:  › message  (bright cyan)."
  (declare (ignore command))
  (format stream "~a ~a~%"
          (style-info (glyph-info) stream)
          message)
  (force-output stream)
  (values))

(defun emit-step (message &key (stream *standard-output*))
  "Explicit step marker:  → message."
  (format stream "~a ~a~%"
          (style-info (glyph-step) stream)
          message)
  (force-output stream)
  (values))

(defun emit-note (message &key (stream *standard-output*))
  "Dim secondary note indented under a prior line."
  (format stream "  ~a ~a~%"
          (style-dim "·" stream)
          (style-dim (princ-to-string message) stream))
  (force-output stream)
  (values))

(defun emit-hint (message &key (stream *error-output*))
  "Actionable hint under an error (dim, indented)."
  (format stream "  ~a ~a~%"
          (style-dim "hint" stream)
          (style-dim (princ-to-string message) stream))
  (force-output stream)
  (values))

(defun emit-plain (message &key (stream *standard-output*))
  "Unstyled line (still flushed). Prefer emit-* when possible."
  (format stream "~a~%" message)
  (force-output stream)
  (values))

(defun emit-brand-line (message &key (stream *standard-output*))
  "Brand-led line:  ◆ clun …"
  (format stream "~a ~a~%"
          (style-brand (glyph-brand) stream)
          message)
  (force-output stream)
  (values))

(defun emit-version (version &key (stream *standard-output*) (revision nil))
  "Chromed version line used by --version."
  (format stream "~a ~a ~a~@[ ~a~]~%"
          (style-brand (glyph-brand) stream)
          (style-brand *cli-brand* stream)
          (style-ok version stream)
          (when revision (style-dim revision stream)))
  (force-output stream)
  (values))

(defun emit-transition (from to &key (stream *standard-output*) prefix)
  "Show FROM → TO with dim old, bright new."
  (format stream "~a~a ~a ~a~%"
          (if prefix (format nil "~a " prefix) "")
          (style-dim (princ-to-string from) stream)
          (style-info (glyph-step) stream)
          (style-ok (princ-to-string to) stream))
  (force-output stream)
  (values))

(defun fail (message &key command (exit 1) (stream *error-output*) hint)
  "Emit an error and return EXIT (default 1). Optional HINT is a dim actionable line."
  (emit-err message :stream stream :command command)
  (when hint (emit-hint hint :stream stream))
  exit)

(defun usage-fail (message &key command (stream *error-output*))
  "Emit a usage error and return exit code 2 with a help hint."
  (fail message :command command :exit 2 :stream stream
        :hint "run `clun --help` for usage"))

;;; --- spinner / animated progress --------------------------------------------

(defparameter *spinner-frames*
  #("⣾" "⣽" "⣻" "⢿" "⡿" "⣟" "⣯" "⣷")
  "Dense braille spinner (kinetic, compact).")

(defparameter *spinner-ascii-frames*
  #("|" "/" "-" "\\")
  "ASCII fallback when glyphs are off.")

(defparameter *spinner-pulse-colors*
  '((:cyan t :bright t)
    (:magenta t :bright t)
    (:blue t :bright t)
    (:cyan t :bright t))
  "Rotate accent colors across spinner frames for a living pulse.")

(defun %spinner-frames ()
  (if (and (cli-color-enabled-p) (%use-unicode-glyphs-p))
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

(defun %spinner-frame-style (frame index stream)
  "Color FRAME with a pulsing accent based on INDEX."
  (let* ((palette *spinner-pulse-colors*)
         (n (length palette))
         (spec (nth (mod index n) palette)))
    (apply #'style frame :stream stream spec)))

(defun spinner-tick (spinner)
  "Advance SPINNER one frame (carriage-return line). No-op when not a TTY."
  (unless (cli-color-enabled-p (spinner-stream spinner))
    (return-from spinner-tick nil))
  (let* ((frames (spinner-frames spinner))
         (i (mod (spinner-index spinner) (length frames)))
         (frame (aref frames i))
         (stream (spinner-stream spinner)))
    (format stream "~c~a ~a  ~a~c"
            #\Return
            (%spinner-frame-style frame i stream)
            (style-dim (spinner-label spinner) stream)
            (style-dim " " stream)
            #\Space)
    (force-output stream)
    (incf (spinner-index spinner))
    (setf (spinner-active spinner) t)
    t))

(defun spinner-clear (spinner)
  "Erase the active spinner line without printing a status."
  (when (spinner-active spinner)
    (format (spinner-stream spinner) "~c~100@t~c" #\Return #\Return)
    (force-output (spinner-stream spinner))
    (setf (spinner-active spinner) nil)))

(defun spinner-stop (spinner &key (ok t) (message nil) (silent nil))
  "Clear the spinner line; unless SILENT, print a final status."
  (spinner-clear spinner)
  (unless silent
    (let* ((stream (spinner-stream spinner))
           (msg (or message (spinner-label spinner)))
           (mark (if ok
                     (style-ok (glyph-ok) stream)
                     (style-err (glyph-err) stream))))
      (format stream "~a ~a~%" mark msg)
      (force-output stream))))

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
On non-TTY sinks, prints a single success line after completion.
On failure, clears the spinner and re-signals so the caller can emit-err."
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
                 (sleep 0.07)))
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
        ((and use-spin ok)
         (spinner-stop spin :ok t :message final))
        (use-spin
         (spinner-clear spin))
        (ok
         (format stream "~a ~a~%" (style-ok (glyph-ok) stream) final)
         (force-output stream))))))

(defmacro with-progress ((label &key (stream '*standard-output*) done-message) &body body)
  "Animate LABEL while BODY runs; optional DONE-MESSAGE (string or (lambda (result)))."
  `(call-with-progress ,label (lambda () ,@body)
                       :done-message ,done-message
                       :stream ,stream))
