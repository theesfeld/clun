;;;; events.lisp — node:events EventEmitter (PLAN.md Phase 12).
;;;; Listeners live as JS arrays under _events[name]; every mutation rebuilds a
;;;; fresh array, emit snapshots first. errorMonitor is skipped (no fresh-Symbol
;;;; mint in the exposed API); on/once/emit/removeListener + error-throw are done.

(in-package :clun.runtime)

(defun %ev-store (this) (eng:js-get this "_events"))

(defun %ev-make-error (msg)
  (eng:js-construct (eng:js-get (eng:realm-global eng:*realm*) "Error") (list msg)))

(defun %ev-list (this name)
  "The CL list of listeners currently registered for NAME (may be empty)."
  (let ((arr (eng:js-get (%ev-store this) name)))
    (if (eng:js-array-p arr) (eng:array-like->list arr) '())))

(defun %ev-set-list (this name listeners)
  (eng:js-set (%ev-store this) name (eng:new-array listeners) nil))

(defun %ev-append (this name fn)
  (%ev-set-list this name (append (%ev-list this name) (list fn))))

(defun %ev-count (this name) (length (%ev-list this name)))

(defun %ev-matches (listener fn)
  "T if LISTENER is FN, or a once-wrapper whose stored listener is FN."
  (or (eng:js-strict-eq listener fn)
      (and (eng:js-object-p listener)
           (eng:js-strict-eq (eng:js-get listener "listener") fn))))

(defun %ev-emit (this name js-args &optional capture)
  "Snapshot listeners for NAME, invoke each with THIS + JS-ARGS; return count. With
CAPTURE, a listener that returns a rejecting thenable routes the rejection to an
`error` emit (captureRejections; subset of Symbol.for('nodejs.rejection'))."
  (let ((snapshot (%ev-list this name)))
    (dolist (fn snapshot)
      (let ((r (eng:js-call fn this js-args)))
        (when (and capture (eng:js-object-p r))
          (let ((then (eng:js-get r "then")))
            (when (eng:callable-p then)
              (eng:js-call then r
                (list eng:+undefined+
                      (eng:make-native-function "" 1
                        (lambda (tt aa) (declare (ignore tt))
                          (eng:js-call (eng:js-get this "emit") this (list "error" (a aa 0)))
                          (undef))))))))))
    (length snapshot)))

(defun %ev-capture-opt (opts)
  "True when OPTS is an object with a truthy captureRejections."
  (and (eng:js-object-p opts) (eng:js-truthy (eng:js-get opts "captureRejections"))))

(defun %ev-max-listeners (this)
  (let ((n (eng:js-get this "_maxListeners")))
    (if (undef-p n) 10d0 (->num n))))

(defun %ev-once (name-key)
  "Grab the global Promise constructor for the static once() helper."
  (declare (ignore name-key))
  (eng:js-get (eng:realm-global eng:*realm*) "Promise"))

(defun %ev-init (obj &optional capture)
  (eng:hidden-prop obj "_events" (eng:new-object))
  (when capture (eng:hidden-prop obj "_captureRejections" eng:+true+))
  obj)

(defun build-node-events ()
  ;; make-native-function gives no .prototype, so build it explicitly and wire construct.
  (let* ((proto (eng:new-object))
         (ctor (eng:make-native-function "EventEmitter" 0
                 (lambda (this args)
                   (when (eng:js-object-p this) (%ev-init this (%ev-capture-opt (a args 0)))) (undef))
                 :construct (lambda (args nt)
                              (let ((p (and (eng:js-object-p nt) (eng:js-get nt "prototype"))))
                                (%ev-init (eng:js-make-object (if (eng:js-object-p p) p proto))
                                          (%ev-capture-opt (a args 0))))))))
    (eng:data-prop ctor "prototype" proto)
    (eng:data-prop proto "constructor" ctor)
    (progn
      (labels ((m (name arity fn) (eng:install-method proto name arity fn)))
        (labels ((add-listener (this args)
                   (let ((name (->str (a args 0))) (fn (a args 1)))
                     (when (plusp (%ev-count this "newListener"))
                       (%ev-emit this "newListener" (list (a args 0) fn)))
                     (%ev-append this name fn)
                     this)))
          (m "on" 2 #'add-listener)
          (m "addListener" 2 #'add-listener))
        (m "once" 2
           (lambda (this args)
             (let* ((name (->str (a args 0))) (fn (a args 1)) (wrapper nil))
               ;; the wrapper removes ITSELF by identity — not every listener === fn,
               ;; so `once(x,f); on(x,f)` keeps the on() listener after the once fires.
               (setf wrapper (eng:make-native-function "" 0
                               (lambda (wthis wargs)
                                 (%ev-set-list wthis name
                                               (remove wrapper (%ev-list wthis name) :test #'eq))
                                 (eng:js-call fn wthis wargs))))
               (eng:data-prop wrapper "listener" fn)
               (when (plusp (%ev-count this "newListener"))
                 (%ev-emit this "newListener" (list (a args 0) fn)))
               (%ev-append this name wrapper)
               this)))
        (labels ((remove-listener (this args)
                   (let ((name (->str (a args 0))) (fn (a args 1)))
                     (multiple-value-bind (kept removed) (%ev-remove-first this name fn)
                       (declare (ignore kept))
                       (when removed
                         (%ev-emit this "removeListener" (list (a args 0) fn))))
                     this)))
          (m "removeListener" 2 #'remove-listener)
          (m "off" 2 #'remove-listener))
        (m "removeAllListeners" 1
           (lambda (this args)
             (if (undef-p (a args 0))
                 (eng:hidden-prop this "_events" (eng:new-object))
                 (%ev-set-list this (->str (a args 0)) '()))
             this))
        (m "emit" 0
           (lambda (this args)
             (let* ((name (->str (a args 0))) (rest (cdr args))
                    (count (%ev-count this name))
                    ;; captureRejections never applies to the 'error' event itself (no loop)
                    (capture (and (not (string= name "error"))
                                  (eng:js-truthy (eng:js-get this "_captureRejections")))))
               (when (and (string= name "error") (zerop count))
                 (let ((e (a args 1)))       ; no-arg error emit throws a real Error, not undefined
                   (eng:throw-js-value (if (undef-p e) (%ev-make-error "Unhandled error.") e))))
               (%ev-emit this name rest capture)
               (eng:js-boolean (plusp count)))))
        (m "listeners" 1
           (lambda (this args)
             (eng:new-array
              (mapcar (lambda (l) (if (and (eng:js-object-p l)
                                           (not (undef-p (eng:js-get l "listener"))))
                                      (eng:js-get l "listener") l))
                      (%ev-list this (->str (a args 0)))))))
        (m "rawListeners" 1
           (lambda (this args) (eng:new-array (%ev-list this (->str (a args 0))))))
        (m "listenerCount" 2
           (lambda (this args)
             (let ((fn (a args 1)))
               (coerce (if (undef-p fn) (%ev-count this (->str (a args 0)))
                           (count-if (lambda (l) (%ev-matches l fn)) (%ev-list this (->str (a args 0)))))
                       'double-float))))
        (m "eventNames" 0
           (lambda (this args) (declare (ignore args))
             (eng:new-array
              (remove-if-not
               (lambda (k) (plusp (%ev-count this k)))
               (remove-if-not #'stringp (eng:jm-own-property-keys (%ev-store this)))))))
        (m "prependListener" 2
           (lambda (this args)
             (let ((name (->str (a args 0))) (fn (a args 1)))
               (when (plusp (%ev-count this "newListener"))    ; newListener fires before insert
                 (%ev-emit this "newListener" (list (a args 0) fn)))
               (%ev-set-list this name (cons fn (%ev-list this name)))
               this)))
        (m "setMaxListeners" 1
           (lambda (this args)
             (eng:hidden-prop this "_maxListeners" (->num (a args 0))) this))
        (m "getMaxListeners" 0
           (lambda (this args) (declare (ignore args)) (%ev-max-listeners this))))
      ;; statics
      (eng:data-prop ctor "EventEmitter" ctor)
      (eng:data-prop ctor "defaultMaxListeners" 10d0)
      (eng:data-prop ctor "captureRejections" eng:+false+)
      (eng:install-method ctor "once" 3
        (lambda (this args) (declare (ignore this))
          (%static-once (a args 0) (->str (a args 1)) (a args 2))))
      (eng:install-method ctor "listenerCount" 2
        (lambda (this args) (declare (ignore this))
          (coerce (%ev-count (a args 0) (->str (a args 1))) 'double-float))))
    ctor))

(defun %ev-remove (this name fn)
  "Remove every listener matching FN under NAME (used by the once-wrapper)."
  (%ev-set-list this name
                (remove-if (lambda (l) (%ev-matches l fn)) (%ev-list this name))))

(defun %ev-remove-first (this name fn)
  "Remove only the FIRST listener matching FN. Returns (values kept removed-p)."
  (let ((removed nil) (kept '()))
    (dolist (l (%ev-list this name))
      (if (and (not removed) (%ev-matches l fn))
          (setf removed t)
          (push l kept)))
    (when removed (%ev-set-list this name (nreverse kept)))
    (values kept removed)))

(defun %static-once (emitter name opts)
  "events.once(emitter, name[, opts]): a Promise resolving to the next emit's args (a
JS array). Unless NAME is 'error', an 'error' emit rejects it. opts.signal (an
AbortSignal) rejects with the abort reason (immediately if already aborted). All
listeners are detached on settle."
  (let* ((g (eng:realm-global eng:*realm*))
         (promise-ctor (eng:js-get g "Promise"))
         (signal (and (eng:js-object-p opts)
                      (let ((s (eng:js-get opts "signal"))) (and (eng:js-object-p s) s))))
         (want-error (not (string= name "error"))))
    (eng:js-construct
     promise-ctor
     (list (eng:make-native-function "" 2
             (lambda (this args) (declare (ignore this))
               (let ((resolve (a args 0)) (reject (a args 1))
                     (on (eng:js-get emitter "on"))
                     (off (eng:js-get emitter "removeListener"))
                     (event-fn nil) (error-fn nil) (abort-fn nil))
                 (labels ((cleanup ()
                            (eng:js-call off emitter (list name event-fn))
                            (when (and want-error error-fn) (eng:js-call off emitter (list "error" error-fn)))
                            (when (and signal abort-fn)
                              (let ((rm (eng:js-get signal "removeEventListener")))
                                (when (eng:callable-p rm) (eng:js-call rm signal (list "abort" abort-fn)))))))
                   (if (and signal (eng:js-truthy (eng:js-get signal "aborted")))
                       (eng:js-call reject (undef) (list (eng:js-get signal "reason")))
                       (progn
                         (setf event-fn (eng:make-native-function "" 0
                                          (lambda (wt wa) (declare (ignore wt))
                                            (cleanup)
                                            (eng:js-call resolve (undef) (list (eng:new-array wa)))
                                            (undef))))
                         (eng:js-call on emitter (list name event-fn))
                         (when want-error
                           (setf error-fn (eng:make-native-function "" 1
                                            (lambda (wt wa) (declare (ignore wt))
                                              (cleanup)
                                              (eng:js-call reject (undef) (list (a wa 0)))
                                              (undef))))
                           (eng:js-call on emitter (list "error" error-fn)))
                         (when signal
                           (let ((add (eng:js-get signal "addEventListener")))
                             (when (eng:callable-p add)
                               (setf abort-fn (eng:make-native-function "" 0
                                                (lambda (wt wa) (declare (ignore wt wa))
                                                  (cleanup)
                                                  (eng:js-call reject (undef) (list (eng:js-get signal "reason")))
                                                  (undef))))
                               (eng:js-call add signal (list "abort" abort-fn))))))))
                 (undef))))))))

(register-node-builtin "events" #'build-node-events)
