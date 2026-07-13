;;;; abort.lisp — AbortController / AbortSignal globals (PLAN.md Phase 14).
;;;; We have no EventTarget/DOMException in v1, so AbortSignal is a minimal,
;;;; self-contained EventTarget for the single `abort` event; the abort reason
;;;; defaults to an Error with name "AbortError" (DOMException is post-v1 🟡).
;;;; Consumed by node:timers/promises and (later) fetch.

(in-package :clun.runtime)

(defun %abort-error (msg name)
  "An Error with .name patched (AbortError / TimeoutError) — our DOMException stand-in."
  (let ((e (eng:js-construct (eng:js-get (eng:realm-global eng:*realm*) "Error") (list msg))))
    (eng:js-set e "name" name nil)
    e))

(defun %make-abort-event (target)
  (let ((ev (eng:new-object)))
    (eng:data-prop ev "type" "abort")
    (eng:data-prop ev "target" target)
    ev))

(defun %make-abort-signal ()
  "Return (values signal abort-fn). ABORT-FN (reason) performs the abort steps once:
set aborted+reason, then fire onabort + each 'abort' listener with an event."
  (let* ((sig (eng:new-object))
         (aborted nil)
         (reason eng:+undefined+)
         (listeners '()))
    (eng:install-getter sig "aborted"
      (lambda (this args) (declare (ignore this args)) (eng:js-boolean aborted)))
    (eng:install-getter sig "reason"
      (lambda (this args) (declare (ignore this args)) reason))
    (eng:data-prop sig "onabort" eng:+null+)
    (eng:install-method sig "addEventListener" 2
      (lambda (this args) (declare (ignore this))
        (when (and (string= (eng:to-string (eng:arg args 0)) "abort")
                   (eng:callable-p (eng:arg args 1)))
          (pushnew (eng:arg args 1) listeners :test #'eq))
        eng:+undefined+))
    (eng:install-method sig "removeEventListener" 2
      (lambda (this args) (declare (ignore this))
        (setf listeners (remove (eng:arg args 1) listeners :test #'eq))
        eng:+undefined+))
    (eng:install-method sig "dispatchEvent" 1
      (lambda (this args) (declare (ignore this args)) eng:+true+))
    (eng:install-method sig "throwIfAborted" 0
      (lambda (this args) (declare (ignore this args))
        (when aborted (eng:throw-js-value reason))
        eng:+undefined+))
    (values
     sig
     (lambda (r)
       (unless aborted
         (setf aborted t
               reason (if (eng:js-undefined-p r)
                          (%abort-error "This operation was aborted" "AbortError")
                          r))
         (let ((onabort (eng:js-get sig "onabort"))
               (ev (%make-abort-event sig))
               (snapshot (reverse listeners)))     ; registration order
           (setf listeners '())
           (dolist (cb snapshot) (eng:js-call cb sig (list ev)))
           (when (eng:callable-p onabort) (eng:js-call onabort sig (list ev)))))))))

(defun %make-abort-controller ()
  (multiple-value-bind (sig abort-fn) (%make-abort-signal)
    (let ((o (eng:new-object)))
      (eng:data-prop o "signal" sig)
      (eng:install-method o "abort" 1
        (lambda (this args) (declare (ignore this)) (funcall abort-fn (eng:arg args 0)) eng:+undefined+))
      o)))

(defun %abort-signal-any (iterable)
  "AbortSignal.any(signals): abort as soon as any input signal is/becomes aborted,
adopting that signal's reason. Accepts an array-like (iterables beyond arrays 🟡)."
  (multiple-value-bind (sig abort-fn) (%make-abort-signal)
    (block done
      (dolist (s (and (eng:js-object-p iterable) (eng:array-like->list iterable)))
        (when (eng:js-object-p s)
          (if (eng:js-truthy (eng:js-get s "aborted"))
              (progn (funcall abort-fn (eng:js-get s "reason")) (return-from done))
              (let ((add (eng:js-get s "addEventListener")))
                (when (eng:callable-p add)
                  (eng:js-call add s
                               (list "abort"
                                     (eng:make-native-function "" 0
                                       (lambda (tt aa) (declare (ignore tt aa))
                                         (funcall abort-fn (eng:js-get s "reason"))
                                         eng:+undefined+))))))))))
    sig))

(defun install-abort (g)
  ;; AbortSignal: not directly constructible; statics abort/timeout/any.
  (let ((sig-ctor (eng:make-native-function "AbortSignal" 0
                    (lambda (this args) (declare (ignore this args))
                      (eng:throw-type-error "Illegal constructor"))
                    :construct (lambda (args nt) (declare (ignore args nt))
                                 (eng:throw-type-error "Illegal constructor")))))
    (eng:install-method sig-ctor "abort" 1
      (lambda (this args) (declare (ignore this))
        (multiple-value-bind (sig abort-fn) (%make-abort-signal)
          (funcall abort-fn (eng:arg args 0)) sig)))
    (eng:install-method sig-ctor "timeout" 1
      (lambda (this args) (declare (ignore this))
        (multiple-value-bind (sig abort-fn) (%make-abort-signal)
          (let* ((ms (eng:to-number (eng:arg args 0)))
                 (setto (eng:js-get g "setTimeout"))
                 (id (eng:js-call setto eng:+undefined+
                                  (list (eng:make-native-function "" 0
                                          (lambda (tt aa) (declare (ignore tt aa))
                                            (funcall abort-fn (%abort-error "The operation timed out" "TimeoutError"))
                                            eng:+undefined+))
                                        (if (and (not (eng:js-nan-p ms)) (plusp ms)) ms 0d0)))))
            ;; a pending timeout signal must NOT keep the process alive (Node unref's it)
            (let ((u (and (eng:js-object-p id) (eng:js-get id "unref"))))
              (when (eng:callable-p u) (eng:js-call u id '()))))
          sig)))
    (eng:install-method sig-ctor "any" 1
      (lambda (this args) (declare (ignore this)) (%abort-signal-any (eng:arg args 0))))
    (eng:data-prop g "AbortSignal" sig-ctor))
  ;; AbortController: requires new; .signal + .abort(reason).
  (let ((ctrl-ctor (eng:make-native-function "AbortController" 0
                     (lambda (this args) (declare (ignore this args))
                       (eng:throw-type-error "Constructor AbortController requires 'new'"))
                     :construct (lambda (args nt) (declare (ignore args nt))
                                  (%make-abort-controller)))))
    (eng:data-prop g "AbortController" ctrl-ctor)))
