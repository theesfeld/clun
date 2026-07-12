;;;; install.lisp — the runtime install hook (PLAN.md §3.6, Phase 08). Augments a
;;;; fresh (eng:make-realm) with console + the full process object + a Clun stub.
;;;; make-realm stays runtime-free so test262 conformance uses a bare realm.

(in-package :clun.runtime)

(defstruct (runtime (:conc-name runtime-))
  (silent nil)                 ; --silent: suppress console.log/info/debug
  (colors nil)                 ; ANSI colors (TTY + FORCE_COLOR/NO_COLOR)
  (exit-code 0)                ; last resolved exit code (cache)
  (exit-listeners '())         ; process.on('exit', …) callbacks
  (exit-fired nil)             ; guard so 'exit' fires exactly once
  (process nil)                ; the process object (main reads .exitCode)
  (realm nil))                 ; the realm (so 'exit' callbacks run with it bound)

(defvar *runtime* nil "The active runtime state (bound around a CLI run).")

(defun safe-integer (v &optional (default 0))
  "Coerce js-value V to a CL integer for host use (exit codes, hrtime). NaN/Infinity
→ DEFAULT. Trap-safe: the runtime runs OUTSIDE the engine's float-trap mask, so a
bare `truncate`/`=` on NaN/Inf would signal — js-nan-p/js-infinite-p inspect bits."
  (let ((n (eng:to-number v)))
    (if (or (eng:js-nan-p n) (eng:js-infinite-p n)) default (truncate n))))

;; A non-local exit thrown by process.exit(n); caught in the CLI top-level.
(define-condition process-exit (error)
  ((code :initarg :code :initform 0 :reader process-exit-code)))

(defun color-allowed-p ()
  "FORCE_COLOR (≠\"0\") overrides NO_COLOR; else NO_COLOR disables; else default on."
  (let ((force (sys:getenv "FORCE_COLOR")) (no (sys:getenv "NO_COLOR")))
    (cond ((and force (not (string= force "0"))) t)
          (no nil)
          (t :default))))

(defun decide-colors (stream)
  "Colors iff the STREAM is a TTY and env allows (FORCE_COLOR forces even non-TTY)."
  (let ((allow (color-allowed-p)))
    (cond ((eq allow t) t)
          ((null allow) nil)
          (t (sys:tty-p stream)))))                 ; :default → follow TTY

(defun install-runtime (realm &key argv cwd (silent nil) (colors :auto))
  "Augment REALM (from eng:make-realm) with console, process, and the Clun stub.
ARGV is the list of user args after the script; CWD the working directory."
  (let ((eng:*realm* realm)
        (rt (make-runtime :silent silent :realm realm
                          :colors (if (eq colors :auto)
                                      (decide-colors *standard-output*)
                                      colors))))
    (let ((*runtime* rt))
      (install-console realm rt)
      (install-process realm rt :argv argv :cwd cwd)
      (install-clun-global realm rt))
    (setf (symbol-value '*runtime*) rt)
    (values realm rt)))

(defun run-exit-handlers (&optional (code 0))
  "Fire process 'exit' listeners exactly once (at normal completion or process.exit).
Errors in a listener propagate to the caller."
  (when (and *runtime* (not (runtime-exit-fired *runtime*)))
    (setf (runtime-exit-fired *runtime*) t (runtime-exit-code *runtime*) code)
    ;; callbacks touch the object API → bind the realm (finish-exit runs us AFTER
    ;; eval-source has unbound *realm*).
    (let ((eng:*realm* (runtime-realm *runtime*)))
      (dolist (cb (reverse (runtime-exit-listeners *runtime*)))
        (eng:js-call cb eng:+undefined+ (list (coerce code 'double-float)))))))
