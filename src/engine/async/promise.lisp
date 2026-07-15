;;;; promise.lisp — Promises + the engine job queue (PLAN.md Phase 06, §27.2). Jobs
;;;; feed the Phase 05 loop's microtask queue (`lp:enqueue-microtask`); process.nextTick
;;;; sits ahead of them for free (the loop's drain does nextTick-fully-then-microtask).
;;;; Unhandled rejections are tracked and reported as an uncaught error at loop idle.

(in-package :clun.engine)

(defstruct (js-promise (:include js-object (class :promise)) (:constructor %make-js-promise))
  (pstate :pending)              ; :pending :fulfilled :rejected
  value                          ; fulfillment value or rejection reason
  (fulfill-reactions '())        ; pushed reversed; reversed on fire
  (reject-reactions '())
  (handled nil))                 ; a reject handler was attached / it was awaited

;;; --- the ambient loop + job queue --------------------------------------------

(defun current-loop ()
  "The event loop hosting this realm's jobs (lazy; :workers 0 — coroutines use their
own threads, the worker pool is for later I/O phases)."
  (or (realm-loop *realm*)
      (setf (realm-loop *realm*) (lp:make-event-loop :workers 0))))

(defun enqueue-job (thunk)
  (lp:enqueue-microtask (current-loop) thunk))

(defun make-promise ()
  (%make-js-promise :proto (intrinsic :promise-prototype)))

(defun %promise-type-error (msg)
  (make-error-object :type-error-prototype "TypeError" msg))

;;; --- unhandled-rejection tracking (§ HostPromiseRejectionTracker) -------------

(defun %rejection-table ()
  (or (realm-pending-rejections *realm*)
      (setf (realm-pending-rejections *realm*) (make-hash-table :test 'eq))))

(defun track-rejection (p reason)
  (setf (gethash p (%rejection-table)) reason))
(defun untrack-rejection (p)
  (when (realm-pending-rejections *realm*)
    (remhash p (realm-pending-rejections *realm*))))

(defun report-unhandled-rejections (realm)
  "After the loop idles, a still-tracked rejected promise had no handler — surface
its reason as an uncaught JS exception (→ nonzero exit at the CLI, Phase 08)."
  (let ((tbl (realm-pending-rejections realm)))
    (when (and tbl (plusp (hash-table-count tbl)))
      (let ((reason (block first (maphash (lambda (p r) (declare (ignore p)) (return-from first r)) tbl)
                           +undefined+)))
        (clrhash tbl)
        (throw-js-value reason)))))

;;; --- settle + resolve (thenable adoption, §27.2.1.3) -------------------------

(defun %fire-reactions (reactions)
  (dolist (r (nreverse reactions)) (enqueue-job r)))

(defun %fulfill-promise (p value)
  (when (eq (js-promise-pstate p) :pending)
    (setf (js-promise-pstate p) :fulfilled (js-promise-value p) value)
    (let ((rs (js-promise-fulfill-reactions p)))
      (setf (js-promise-fulfill-reactions p) '() (js-promise-reject-reactions p) '())
      (%fire-reactions rs))))

(defun %reject-promise (p reason)
  (when (eq (js-promise-pstate p) :pending)
    (setf (js-promise-pstate p) :rejected (js-promise-value p) reason)
    (unless (js-promise-handled p) (track-rejection p reason))
    (let ((rs (js-promise-reject-reactions p)))
      (setf (js-promise-fulfill-reactions p) '() (js-promise-reject-reactions p) '())
      (%fire-reactions rs))))

(defun make-resolving-functions (p)
  "(values resolve reject) sharing an [[AlreadyResolved]] guard."
  (let ((already nil))
    (values
     (make-native-function "" 1
       (lambda (this args) (declare (ignore this))
         (unless already (setf already t) (%resolve-promise p (arg args 0))) +undefined+))
     (make-native-function "" 1
       (lambda (this args) (declare (ignore this))
         (unless already (setf already t) (%reject-promise p (arg args 0))) +undefined+)))))

(defun %resolve-promise (p resolution)
  (cond
    ((eq resolution p) (%reject-promise p (%promise-type-error "Chaining cycle detected for promise")))
    ((js-object-p resolution)
     (let ((then (handler-case (js-get resolution "then")
                   (js-condition (c) (%reject-promise p (js-condition-value c))
                     (return-from %resolve-promise)))))
       (if (callable-p then)
           (enqueue-job (lambda () (%thenable-job p resolution then)))
           (%fulfill-promise p resolution))))
    (t (%fulfill-promise p resolution))))

(defun %thenable-job (p thenable then)
  (multiple-value-bind (resolve reject) (make-resolving-functions p)
    (handler-case (js-call then thenable (list resolve reject))
      (js-condition (c) (js-call reject +undefined+ (list (js-condition-value c)))))))

;;; --- then / reactions --------------------------------------------------------

(defun %reaction-job (resolve reject handler default-type value)
  "Run HANDLER (callable or nil) on VALUE, settling the result capability via its
RESOLVE/REJECT functions. With no handler the value passes through."
  (let ((outcome
          (if (callable-p handler)
              (handler-case (cons :value (js-call handler +undefined+ (list value)))
                (js-condition (c) (cons :throw (js-condition-value c))))
              (cons (if (eq default-type :fulfill) :value :throw) value))))
    (if (eq (car outcome) :value)
        (js-call resolve +undefined+ (list (cdr outcome)))
        (js-call reject +undefined+ (list (cdr outcome))))))

(defun perform-promise-then (p on-fulfilled on-rejected resolve reject)
  "§27.2.5.4.1 — attach reactions to P that settle a result capability (RESOLVE/REJECT)."
  (let ((ff (and (callable-p on-fulfilled) on-fulfilled))
        (rf (and (callable-p on-rejected) on-rejected)))
    (setf (js-promise-handled p) t)     ; a handler is attached: no longer unhandled
    (untrack-rejection p)
    (labels ((fj () (%reaction-job resolve reject ff :fulfill (js-promise-value p)))
             (rj () (%reaction-job resolve reject rf :reject (js-promise-value p))))
      (ecase (js-promise-pstate p)
        (:pending (push #'fj (js-promise-fulfill-reactions p))
                  (push #'rj (js-promise-reject-reactions p)))
        (:fulfilled (enqueue-job #'fj))
        (:rejected (enqueue-job #'rj))))))

(defun this-promise (this)
  (if (js-promise-p this) this (throw-type-error "Promise method called on a non-Promise")))

;;; --- capabilities + species (subclass-aware, §27.2.1.5 / §7.3.22) ------------

(defun new-promise-capability (ctor)
  "§27.2.1.5 — construct CTOR with an executor capturing its resolve/reject.
Returns (values promise resolve reject)."
  (unless (constructor-p ctor) (throw-type-error "NewPromiseCapability: not a constructor"))
  (let ((resolve nil) (reject nil) (set nil))
    (let ((promise (js-construct
                    ctor (list (make-native-function "" 2
                                 (lambda (this args) (declare (ignore this))
                                   (when set (throw-type-error "promise resolving functions already set"))
                                   (setf resolve (arg args 0) reject (arg args 1) set t) +undefined+))))))
      (unless (and (callable-p resolve) (callable-p reject))
        (throw-type-error "promise resolve/reject is not callable"))
      (values promise resolve reject))))

(defun species-constructor (o default)
  "§7.3.22 SpeciesConstructor."
  (let ((c (js-get o "constructor")))
    (cond ((js-undefined-p c) default)
          ((not (js-object-p c)) (throw-type-error "constructor is not an object"))
          (t (let ((s (js-get c (well-known :species))))
               (cond ((js-nullish-p s) default)
                     ((constructor-p s) s)
                     (t (throw-type-error "Symbol.species is not a constructor"))))))))

(defun promise-and-caps ()
  "A base promise plus its resolving functions (an internal capability)."
  (let ((p (make-promise)))
    (multiple-value-bind (res rej) (make-resolving-functions p)
      (values p res rej))))

(defun promise-resolve* (c value)
  "§27.2.4.7 PromiseResolve(C, value): return VALUE if it's a promise with constructor
C, else resolve a fresh C-capability with it."
  (if (and (js-promise-p value) (eq (js-get value "constructor") c))
      value
      (multiple-value-bind (p resolve reject) (new-promise-capability c)
        (declare (ignore reject))
        (js-call resolve +undefined+ (list value))
        p)))

(defun base-resolve (value)
  "PromiseResolve with the intrinsic Promise (internal adoption for await/combinators)."
  (if (js-promise-p value) value (promise-resolve* (intrinsic :promise-constructor) value)))

(defun promise-then-generic (thenable on-fulfilled on-rejected)
  "Call THENABLE.then(onFulfilled, onRejected) — subclass/thenable-aware."
  (js-call (js-get thenable "then") thenable (list on-fulfilled on-rejected)))

;;; --- statics: resolve/reject + combinators (all use `this` as constructor C) --
;;; After the capability is built, an abrupt completion during iteration/setup
;;; REJECTS the result promise (IfAbruptRejectPromise, §27.2.4.1.1) — never throws.

(defmacro %if-abrupt-reject ((reject result) &body body)
  `(handler-case (progn ,@body)
     (js-condition (c) (js-call ,reject +undefined+ (list (js-condition-value c))) ,result)))

(defun %promise-all (c iterable settled-p)
  "Promise.all (SETTLED-P nil) / allSettled (SETTLED-P t), constructor C = receiver."
  (multiple-value-bind (result resolve reject) (new-promise-capability c)
   (%if-abrupt-reject (reject result)
    (let ((resolve-method (js-get c "resolve")))
      (unless (callable-p resolve-method)
        (throw-type-error "Promise resolve is not callable"))
      (let ((record (get-iterator-record iterable))
            (vals (make-array 8 :adjustable t :fill-pointer 0))
            (remaining 1)
            (i 0))
        (labels ((done ()
                   (when (zerop (decf remaining))
                     (js-call resolve +undefined+
                              (list (new-array (coerce vals 'list)))))))
          (loop
            (multiple-value-bind (value iteration-done)
                (iterator-step-value record)
              (when iteration-done
                (done)
                (return result))
              (let ((idx i))
                (call-with-iterator-close-on-abrupt
                 record
                 (lambda ()
                   (let ((pr (js-call resolve-method c (list value)))
                         (called nil))
                     (vector-push-extend +undefined+ vals)
                     (incf remaining)
                     (promise-then-generic
                      pr
                      (make-native-function "" 1
                        (lambda (th a)
                          (declare (ignore th))
                          (unless called
                            (setf called t
                                  (aref vals idx)
                                  (if settled-p
                                      (%settled-record :fulfilled (arg a 0))
                                      (arg a 0)))
                            (done))
                          +undefined+))
                      (if settled-p
                          (make-native-function "" 1
                            (lambda (th a)
                              (declare (ignore th))
                              (unless called
                                (setf called t
                                      (aref vals idx)
                                      (%settled-record :rejected (arg a 0)))
                                (done))
                              +undefined+))
                          reject)))))
                (incf i))))))))))

(defun %settled-record (state value)
  (let ((o (new-object)))
    (if (eq state :fulfilled)
        (progn (create-data-property o "status" "fulfilled") (create-data-property o "value" value))
        (progn (create-data-property o "status" "rejected") (create-data-property o "reason" value)))
    o))

(defun %promise-race (c iterable)
  (multiple-value-bind (result resolve reject) (new-promise-capability c)
   (%if-abrupt-reject (reject result)
    (let ((resolve-method (js-get c "resolve")))
      (unless (callable-p resolve-method)
        (throw-type-error "Promise resolve is not callable"))
      (let ((record (get-iterator-record iterable)))
        (loop
          (multiple-value-bind (value done) (iterator-step-value record)
            (when done (return result))
            (call-with-iterator-close-on-abrupt
             record
             (lambda ()
               (promise-then-generic
                (js-call resolve-method c (list value)) resolve reject))))))))))

(defun %promise-any (c iterable)
  (multiple-value-bind (result resolve reject) (new-promise-capability c)
   (%if-abrupt-reject (reject result)
    (let ((resolve-method (js-get c "resolve")))
      (unless (callable-p resolve-method)
        (throw-type-error "Promise resolve is not callable"))
      (let ((record (get-iterator-record iterable))
            (errors (make-array 8 :adjustable t :fill-pointer 0))
            (remaining 1)
            (i 0))
        (labels ((fail ()
                   (when (zerop (decf remaining))
                     (js-call reject +undefined+
                              (list (%aggregate-error (coerce errors 'list)))))))
          (loop
            (multiple-value-bind (value done) (iterator-step-value record)
              (when done
                (fail)
                (return result))
              (let ((idx i))
                (call-with-iterator-close-on-abrupt
                 record
                 (lambda ()
                   (let ((pr (js-call resolve-method c (list value)))
                         (called nil))
                     (vector-push-extend +undefined+ errors)
                     (incf remaining)
                     (promise-then-generic
                      pr resolve
                      (make-native-function "" 1
                        (lambda (th a)
                          (declare (ignore th))
                          (unless called
                            (setf called t (aref errors idx) (arg a 0))
                            (fail))
                          +undefined+))))))
                (incf i))))))))))

(defun %aggregate-error (errors)
  "The rejection reason for Promise.any — an AggregateError instance."
  (let ((e (js-make-object (intrinsic :aggregate-error-prototype) :error)))
    (hidden-prop e "message" "All promises were rejected")
    (hidden-prop e "stack" "AggregateError")
    (data-prop e "errors" (new-array errors))
    e))

(defun %make-aggregate (args)
  "new AggregateError(errors [, message]) (§20.5.7.1)."
  (let ((e (js-make-object (intrinsic :aggregate-error-prototype) :error))
        (errors (arg args 0)) (msg (arg args 1)))
    (unless (js-undefined-p msg) (hidden-prop e "message" (to-string msg)))
    (data-prop e "errors" (new-array (if (js-nullish-p errors) '() (iterable->list errors))))
    (hidden-prop e "stack" "AggregateError")
    e))

(defun %bootstrap-aggregate-error ()
  (let ((aep (js-make-object (intrinsic :error-prototype) :error)))
    (hidden-prop aep "name" "AggregateError")
    (hidden-prop aep "message" "")
    (setf (realm-intrinsic *realm* :aggregate-error-prototype) aep)
    (let ((ctor (make-constructor "AggregateError" 2
                  (lambda (this args) (declare (ignore this)) (%make-aggregate args))
                  :prototype aep
                  :construct-fn (lambda (args nt) (declare (ignore nt)) (%make-aggregate args)))))
      (setf (realm-intrinsic *realm* :aggregate-error-constructor) ctor))))

;;; --- bootstrap ---------------------------------------------------------------

(defun %bootstrap-promise ()
  (%bootstrap-aggregate-error)
  (let ((pp (js-make-object (intrinsic :object-prototype))))
    (setf (realm-intrinsic *realm* :promise-prototype) pp)
    (obj-set-desc pp (well-known :to-string-tag)
                  (data-pd "Promise" :writable nil :enumerable nil :configurable t))
    (install-method pp "then" 2
      (lambda (this args)
        (let* ((p (this-promise this))
               (c (species-constructor p (intrinsic :promise-constructor))))
          (multiple-value-bind (result resolve reject) (new-promise-capability c)
            (perform-promise-then p (arg args 0) (arg args 1) resolve reject)
            result))))
    ;; catch/finally delegate to `this.then` (subclass-aware). js-getv (not js-get)
    ;; so a non-object `this` coerces → JS TypeError, never a host no-applicable-method.
    (install-method pp "catch" 1
      (lambda (this args) (js-call (js-getv this "then") this (list +undefined+ (arg args 0)))))
    ;; finally per §27.2.5.3: thenFinally/catchFinally (length 1) each compute
    ;; PromiseResolve(onFinally()).then(thunk) with a length-0 value-thunk/thrower and
    ;; a SINGLE `then` argument, so the chain awaits onFinally's result + propagates it.
    (install-method pp "finally" 1
      (lambda (this args)
        (let ((on (arg args 0)) (then (js-getv this "then")))
          (if (callable-p on)
              (flet ((then1 (thunk) (lambda (th a) (declare (ignore th))
                       (let* ((v (funcall thunk (arg a 0)))
                              (p (base-resolve (js-call on +undefined+ '()))))
                         (js-call (js-getv p "then") p (list v))))))
                (js-call then this
                  (list (make-native-function "" 1
                          (then1 (lambda (val) (make-native-function "" 0
                                   (lambda (t2 a2) (declare (ignore t2 a2)) val)))))
                        (make-native-function "" 1
                          (then1 (lambda (reason) (make-native-function "" 0
                                   (lambda (t2 a2) (declare (ignore t2 a2)) (throw-js-value reason)))))))))
              (js-call then this (list on on))))))
    (let ((ctor (make-constructor "Promise" 1
                  (lambda (this args) (declare (ignore this args))
                    (throw-type-error "Constructor Promise requires 'new'"))
                  :prototype pp
                  :construct-fn
                  (lambda (args nt)
                    (let ((executor (arg args 0)))
                      (unless (callable-p executor) (throw-type-error "Promise resolver is not a function"))
                      (let ((p (%make-js-promise
                                :proto (let ((pr (and (js-object-p nt) (js-get nt "prototype"))))
                                         (if (js-object-p pr) pr (intrinsic :promise-prototype))))))
                        (multiple-value-bind (resolve reject) (make-resolving-functions p)
                          (handler-case (js-call executor +undefined+ (list resolve reject))
                            (js-condition (c) (js-call reject +undefined+ (list (js-condition-value c))))))
                        p))))))
      (install-method ctor "resolve" 1
        (lambda (this args)
          (unless (js-object-p this) (throw-type-error "Promise.resolve called on non-object"))
          (promise-resolve* this (arg args 0))))
      (install-method ctor "reject" 1
        (lambda (this args)
          (multiple-value-bind (p resolve reject) (new-promise-capability this)
            (declare (ignore resolve))
            (js-call reject +undefined+ (list (arg args 0))) p)))
      (install-method ctor "all" 1 (lambda (this args) (%promise-all this (arg args 0) nil)))
      (install-method ctor "allSettled" 1 (lambda (this args) (%promise-all this (arg args 0) t)))
      (install-method ctor "race" 1 (lambda (this args) (%promise-race this (arg args 0))))
      (install-method ctor "any" 1 (lambda (this args) (%promise-any this (arg args 0))))
      ;; Symbol.species getter returns `this` (§27.2.4.7)
      (install-getter ctor (well-known :species) (lambda (this args) (declare (ignore args)) this))
      (setf (realm-intrinsic *realm* :promise-constructor) ctor))))

;;; --- async globals (Promise + minimal timers/microtask/nextTick) -------------
;;; The full timers globals + process are Phase 14/08; the minimum for the ordering
;;; corpus (microtask vs timer vs nextTick) and Promise-using code lands here.

;; setTimeout returns an opaque Timer JS object (a real js-value, not the raw CL
;; timer struct — which would crash string coercion), holding the timer in a
;; mutable box under %timer% so refresh() can re-arm it in place.
(sb-ext:defglobal *timer-box-key* '#:timer)
(sb-ext:defglobal *timer-id-counter* 0)
(defun %box-timer (timer) (cons *timer-box-key* timer))
(defun %timer-from-id (id)
  (when (js-object-p id)
    (let ((d (obj-own-desc id "%timer%")))
      (when (and d (consp (pd-value d)) (eq (car (pd-value d)) *timer-box-key*))
        (cdr (pd-value d))))))
(defun %timer-toprimitive (o idnum)
  "Install Symbol.toPrimitive → a small integer id (Node's Timeout coerces to a number)."
  (obj-set-desc o (well-known :to-primitive)
    (data-pd (make-native-function "[Symbol.toPrimitive]" 1
               (lambda (this args) (declare (ignore this args)) idnum))
             :writable nil :enumerable nil :configurable t)))

(defun %make-timer-id (timer &key delay callback interval)
  "Wrap a CL timer in an opaque JS Timeout with ref/unref/hasRef/refresh/close +
Symbol.toPrimitive. DELAY/CALLBACK/INTERVAL are captured so refresh() re-arms it."
  (let ((box (%box-timer timer))
        (o (new-object))
        (idnum (coerce (incf *timer-id-counter*) 'double-float)))
    (hidden-prop o "%timer%" box)
    (install-method o "ref" 0
      (lambda (this args) (declare (ignore args))
        (let ((tm (cdr box))) (when tm (lp:timer-ref tm))) this))
    (install-method o "unref" 0
      (lambda (this args) (declare (ignore args))
        (let ((tm (cdr box))) (when tm (lp:timer-unref tm))) this))
    (install-method o "hasRef" 0
      (lambda (this args) (declare (ignore this args))
        (js-boolean (let ((tm (cdr box))) (and tm (lp:timer-refd-p tm) t)))))
    (install-method o "close" 0
      (lambda (this args) (declare (ignore args))
        (let ((tm (cdr box))) (when tm (lp:clear-timer tm))) this))
    (when (and delay callback)
      (install-method o "refresh" 0
        (lambda (this args) (declare (ignore args))
          ;; re-arm from now with the original delay; clear the old CL timer, rebox.
          (let ((tm (cdr box))) (when tm (lp:clear-timer tm)))
          (setf (cdr box) (lp:set-timer (current-loop) delay callback :repeat interval))
          this)))
    (%timer-toprimitive o idnum)
    o))

(defun %make-immediate-id (cancel refd-box)
  "Opaque Immediate: %immediate% boxes the canceller; ref/unref toggle REFD-BOX (a
1-cons flag) — accepted but liveness-inert (documented: immediates run next iteration)."
  (let ((o (new-object)) (idnum (coerce (incf *timer-id-counter*) 'double-float)))
    (hidden-prop o "%immediate%" (cons :immediate cancel))
    (install-method o "ref" 0 (lambda (tt aa) (declare (ignore aa)) (setf (car refd-box) t) tt))
    (install-method o "unref" 0 (lambda (tt aa) (declare (ignore aa)) (setf (car refd-box) nil) tt))
    (install-method o "hasRef" 0 (lambda (tt aa) (declare (ignore tt aa)) (js-boolean (car refd-box))))
    (%timer-toprimitive o idnum)
    o))

(defun %immediate-canceller (id)
  (when (js-object-p id)
    (let ((d (obj-own-desc id "%immediate%")))
      (when (and d (consp (pd-value d)) (eq (car (pd-value d)) :immediate))
        (cdr (pd-value d))))))

(defun %clamp-delay (v)
  "WHATWG timers: delay < 0 → 0; > 2^31-1 (incl. Infinity/NaN via %int) → 1."
  (let ((d (%int v))) (cond ((< d 0) 0) ((> d 2147483647) 1) (t d))))

(defun %bootstrap-async-globals ()
  (let ((g (realm-global *realm*)))
    (hidden-prop g "Promise" (intrinsic :promise-constructor))
    (hidden-prop g "AggregateError" (intrinsic :aggregate-error-constructor))
    (install-method g "queueMicrotask" 1
      (lambda (this args) (declare (ignore this))
        (let ((fn (arg args 0)))
          (unless (callable-p fn) (throw-type-error "queueMicrotask expects a function"))
          (enqueue-job (lambda () (js-call fn +undefined+ '()))))
        +undefined+))
    (install-method g "setTimeout" 2
      (lambda (this args) (declare (ignore this))
        (let ((fn (arg args 0)) (delay (%clamp-delay (arg args 1))) (extra (cddr args)))
          (unless (callable-p fn) (throw-type-error "setTimeout expects a function"))
          (let ((cb (lambda () (js-call fn +undefined+ extra))))
            (%make-timer-id (lp:set-timer (current-loop) delay cb) :delay delay :callback cb)))))
    (install-method g "setInterval" 2
      (lambda (this args) (declare (ignore this))
        (let ((fn (arg args 0)) (delay (%clamp-delay (arg args 1))) (extra (cddr args)))
          (unless (callable-p fn) (throw-type-error "setInterval expects a function"))
          (let ((cb (lambda () (js-call fn +undefined+ extra))) (rp (max 1 delay)))
            (%make-timer-id (lp:set-timer (current-loop) delay cb :repeat rp)
                            :delay delay :callback cb :interval rp)))))
    (install-method g "setImmediate" 1
      (lambda (this args) (declare (ignore this))
        (let ((fn (arg args 0)) (extra (cdr args)))
          (unless (callable-p fn) (throw-type-error "setImmediate expects a function"))
          (let ((cancelled nil) (refd-box (list t)))
            (lp:enqueue-task (current-loop)
                             (lambda () (unless cancelled (js-call fn +undefined+ extra))))
            (%make-immediate-id (lambda () (setf cancelled t)) refd-box)))))
    (install-method g "clearImmediate" 1
      (lambda (this args) (declare (ignore this))
        (let ((c (%immediate-canceller (arg args 0)))) (when c (funcall c))) +undefined+))
    (dolist (name '("clearTimeout" "clearInterval"))
      (install-method g name 1
        (lambda (this args) (declare (ignore this))
          (let ((tm (%timer-from-id (arg args 0)))) (when tm (lp:clear-timer tm))) +undefined+)))
    ;; minimal process.nextTick (dedicated pre-microtask queue); full process is Phase 08
    (let ((proc (new-object)))
      (install-method proc "nextTick" 1
        (lambda (this args) (declare (ignore this))
          (let ((fn (arg args 0)))
            (unless (callable-p fn) (throw-type-error "nextTick expects a function"))
            (lp:enqueue-next-tick (current-loop) (lambda () (js-call fn +undefined+ (rest args)))))
          +undefined+))
      (hidden-prop g "process" proc))))
