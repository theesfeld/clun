;;;; environment.lisp — runtime lexical environments (PLAN.md Phase 03, §3).
;;;; A frame is a simple-vector of slots; environments chain by parent. The emitter
;;;; pre-resolves every reference to (depth . index), so access is a parent walk +
;;;; svref with no name lookup. let/const slots start as +tdz+ (§6.2.4).

(in-package :clun.engine)

(defstruct (environment (:constructor make-environment (slots &optional parent))
                        (:conc-name env-) (:copier nil))
  (slots #() :type simple-vector)
  (parent nil))

(defvar +tdz+ (make-symbol "TDZ")
  "Temporal-Dead-Zone sentinel; reading a slot still holding it is a ReferenceError.")

(declaim (inline env-ancestor))
(defun env-ancestor (env depth)
  (dotimes (i depth env) (setf env (env-parent env))))

(defun frame-ref (env depth index name)
  (let ((v (svref (env-slots (env-ancestor env depth)) index)))
    (if (eq v +tdz+)
        (throw-reference-error (format nil "cannot access '~a' before initialization" name))
        v)))

(defun frame-set (env depth index value)
  (setf (svref (env-slots (env-ancestor env depth)) index) value))

(defun frame-init (env depth index value)
  "Initialize a slot (bypasses the TDZ read check; for declaration evaluation)."
  (setf (svref (env-slots (env-ancestor env depth)) index) value))

(defun new-frame (size parent &optional (fill +undefined+))
  (make-environment (make-array size :initial-element fill) parent))

;;; --- realm (per-realm intrinsics indirection, §3.1) -------------------------

(defstruct (realm (:conc-name realm-) (:constructor %make-realm) (:copier nil))
  (intrinsics (make-hash-table :test 'eq))
  global
  (loop nil)                     ; the event-loop hosting this realm's jobs (Phase 06)
  (coroutines '())               ; live coroutines, for teardown (Phase 06)
  (pending-rejections nil)       ; hash promise->reason of unhandled rejections (Phase 06)
  (modules nil)                  ; module registry: resolved-path(string) -> module-record (Phase 07)
  (entry-module nil))            ; the graph's entry module (import.meta.main, Phase 07)

(defvar *realm* nil "The realm current code runs in (bound by the evaluator).")

(defun realm-module (realm path)
  "The module-record registered under real PATH in REALM, or NIL."
  (let ((tbl (realm-modules realm)))
    (and tbl (gethash path tbl))))

(defun (setf realm-module) (record realm path)
  (let ((tbl (or (realm-modules realm)
                 (setf (realm-modules realm) (make-hash-table :test 'equal)))))
    (setf (gethash path tbl) record)))

(declaim (inline realm-intrinsic))
(defun realm-intrinsic (r key) (gethash key (realm-intrinsics r)))
(defun (setf realm-intrinsic) (v r key) (setf (gethash key (realm-intrinsics r)) v))
(defun intrinsic (key) (gethash key (realm-intrinsics *realm*)))
