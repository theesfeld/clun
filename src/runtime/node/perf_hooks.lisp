;;;; perf_hooks.lisp — node:perf_hooks (performance.now + timeline + histograms).

(in-package :clun.runtime)

(defun %perf-now ()
  (/ (coerce (sys:monotonic-nanoseconds) 'double-float) 1.0d6))

(defun %perf-entry (name type start duration)
  (let ((entry (eng:new-object)))
    (eng:data-prop entry "name" name)
    (eng:data-prop entry "entryType" type)
    (eng:data-prop entry "startTime" (coerce start 'double-float))
    (eng:data-prop entry "duration" (coerce duration 'double-float))
    entry))

(defun %perf-entries (perf)
  (or (eng:js-get perf "%entries%") '()))

(defun %perf-set-entries (perf list)
  (eng:hidden-prop perf "%entries%" list)
  list)

(defun %perf-notify-observers (perf entry)
  (let ((observers (or (eng:js-get perf "%observers%") '())))
    (dolist (obs observers)
      (when (eng:js-truthy (eng:js-get obs "%active%"))
        (let* ((types (eng:js-get obs "%types%"))
               (etype (->str (eng:js-get entry "entryType")))
               (match (or (null types) (undef-p types)
                          (and (listp types) (member etype types :test #'string=)))))
          (when match
            (let ((pending (or (eng:js-get obs "%pending%") '())))
              (eng:hidden-prop obs "%pending%" (append pending (list entry)))
              (let ((cb (eng:js-get obs "_cb")))
                (when (eng:callable-p cb)
                  (let ((list-obj (eng:new-object))
                        (recs (list entry)))
                    (eng:install-method list-obj "getEntries" 0
                      (lambda (tt aa) (declare (ignore tt aa)) (eng:new-array recs)))
                    (eng:install-method list-obj "getEntriesByName" 2
                      (lambda (tt aa) (declare (ignore tt))
                        (eng:new-array
                         (remove-if-not
                          (lambda (e)
                            (and (string= (->str (eng:js-get e "name")) (->str (a aa 0)))
                                 (or (undef-p (a aa 1))
                                     (string= (->str (eng:js-get e "entryType"))
                                              (->str (a aa 1))))))
                          recs))))
                    (eng:install-method list-obj "getEntriesByType" 1
                      (lambda (tt aa) (declare (ignore tt))
                        (eng:new-array
                         (remove-if-not
                          (lambda (e)
                            (string= (->str (eng:js-get e "entryType"))
                                     (->str (a aa 0))))
                          recs))))
                    (eng:js-call cb obs (list list-obj obs))))))))))))

(defun %perf-push (perf entry)
  (%perf-set-entries perf (append (%perf-entries perf) (list entry)))
  (%perf-notify-observers perf entry)
  entry)

(defun %perf-find-mark-time (perf name)
  (let ((want (->str name)))
    (loop for e in (reverse (%perf-entries perf))
          when (and (string= (->str (eng:js-get e "entryType")) "mark")
                    (string= (->str (eng:js-get e "name")) want))
            return (let ((st (eng:js-get e "startTime")))
                     (if (numberp st) (coerce st 'double-float) (->num st)))
          finally (return nil))))

(defun %perf-resolve-time (perf arg default)
  "ARG is a mark name string, a number, or undefined → DEFAULT."
  (cond
    ((undef-p arg) default)
    ((string= (eng:js-typeof arg) "string")
     (or (%perf-find-mark-time perf (->str arg)) default))
    (t (coerce (->num arg) 'double-float))))

(defun %histogram-record (h value-ns)
  "Record VALUE-NS (nanoseconds) into histogram H; update min/max/mean/stddev."
  (let* ((v (coerce value-ns 'double-float))
         (samples (or (eng:js-get h "%samples%") '()))
         (new-samples (append samples (list v)))
         (n (length new-samples))
         (sum (reduce #'+ new-samples :initial-value 0d0))
         (mean (/ sum n))
         (minv (reduce #'min new-samples))
         (maxv (reduce #'max new-samples))
         (var (if (< n 2) 0d0
                  (/ (reduce #'+ (mapcar (lambda (x) (expt (- x mean) 2)) new-samples)
                             :initial-value 0d0)
                     n)))
         (sd (sqrt var)))
    (eng:hidden-prop h "%samples%" new-samples)
    (eng:data-prop h "min" minv)
    (eng:data-prop h "max" maxv)
    (eng:data-prop h "mean" mean)
    (eng:data-prop h "stddev" sd)
    (eng:data-prop h "count" (coerce n 'double-float))
    (eng:data-prop h "exceeds" 0d0)
    h))

(defun %make-histogram (&key (eld nil) (resolution 10))
  "Build a RecordableHistogram / ELDHistogram JS object."
  (let ((h (eng:new-object))
        (enabled nil)
        (last-ns nil)
        (timer nil)
        (res-ms (max 1 (if (numberp resolution) (truncate resolution) 10))))
    (eng:hidden-prop h "%samples%" '())
    (eng:data-prop h "min" 0d0)
    (eng:data-prop h "max" 0d0)
    (eng:data-prop h "mean" 0d0)
    (eng:data-prop h "stddev" 0d0)
    (eng:data-prop h "count" 0d0)
    (eng:data-prop h "exceeds" 0d0)
    (eng:install-method h "reset" 0
      (lambda (tt aa) (declare (ignore aa))
        (eng:hidden-prop tt "%samples%" '())
        (eng:data-prop tt "min" 0d0)
        (eng:data-prop tt "max" 0d0)
        (eng:data-prop tt "mean" 0d0)
        (eng:data-prop tt "stddev" 0d0)
        (eng:data-prop tt "count" 0d0)
        (eng:data-prop tt "exceeds" 0d0)
        (undef)))
    (eng:install-method h "record" 1
      (lambda (tt aa)
        (%histogram-record tt (->num (a aa 0)))
        (undef)))
    (eng:install-method h "recordDelta" 0
      (lambda (tt aa) (declare (ignore aa))
        (let ((now (coerce (sys:monotonic-nanoseconds) 'double-float)))
          (when last-ns
            (%histogram-record tt (max 0d0 (- now last-ns))))
          (setf last-ns now)
          (undef))))
    (eng:install-method h "percentile" 1
      (lambda (tt aa)
        (let* ((p (->num (a aa 0)))
               (samples (copy-list (or (eng:js-get tt "%samples%") '())))
               (n (length samples)))
          (if (zerop n)
              0d0
              (let* ((sorted (sort samples #'<))
                     (idx (min (1- n)
                               (max 0 (floor (* (min 100d0 (max 0d0 p))
                                                (1- n) 0.01d0))))))
                (nth idx sorted))))))
    (eng:install-method h "enable" 0
      (lambda (tt aa) (declare (ignore aa))
        (when eld
          (unless enabled
            (setf enabled t
                  last-ns (coerce (sys:monotonic-nanoseconds) 'double-float))
            (let* ((g (eng:realm-global eng:*realm*))
                   (set-int (eng:js-get g "setInterval"))
                   (prev last-ns))
              (when (eng:callable-p set-int)
                (setf timer
                      (eng:js-call set-int eng:+undefined+
                        (list (eng:make-native-function "" 0
                                (lambda (t2 a2) (declare (ignore t2 a2))
                                  (when enabled
                                    (let* ((now (coerce (sys:monotonic-nanoseconds)
                                                        'double-float))
                                           (expected (* res-ms 1.0d6))
                                           (delta (max 0d0 (- (- now prev) expected))))
                                      (setf prev now)
                                      (%histogram-record tt delta)))
                                  (undef)))
                              (coerce res-ms 'double-float))))))))
        tt))
    (eng:install-method h "disable" 0
      (lambda (tt aa) (declare (ignore aa))
        (when enabled
          (setf enabled nil)
          (when timer
            (let* ((g (eng:realm-global eng:*realm*))
                   (clear (eng:js-get g "clearInterval")))
              (when (eng:callable-p clear)
                (eng:js-call clear eng:+undefined+ (list timer))))
            (setf timer nil)))
        tt))
    h))

(defun build-node-perf-hooks ()
  (let* ((o (eng:new-object))
         (perf (eng:new-object))
         (time-origin (%perf-now)))
    (eng:hidden-prop perf "%entries%" '())
    (eng:hidden-prop perf "%observers%" '())
    (eng:data-prop perf "timeOrigin" time-origin)
    (eng:install-method perf "now" 0
      (lambda (this args) (declare (ignore this args))
        (- (%perf-now) time-origin)))
    (eng:install-method perf "mark" 1
      (lambda (this args)
        (let* ((name (->str (a args 0)))
               (start (- (%perf-now) time-origin))
               (entry (%perf-entry name "mark" start 0d0)))
          (%perf-push this entry)
          entry)))
    (eng:install-method perf "measure" 3
      (lambda (this args)
        (let* ((name (->str (a args 0)))
               (start-arg (a args 1))
               (end-arg (a args 2))
               (now (- (%perf-now) time-origin))
               (start 0d0)
               (end now))
          (cond
            ((eng:js-object-p start-arg)
             (let ((s (eng:js-get start-arg "start"))
                   (e (eng:js-get start-arg "end"))
                   (d (eng:js-get start-arg "duration")))
               (setf start (%perf-resolve-time this s 0d0))
               (setf end (%perf-resolve-time this e now))
               (unless (undef-p d)
                 (setf end (+ start (coerce (->num d) 'double-float))))))
            (t
             (setf start (%perf-resolve-time this start-arg 0d0))
             (setf end (%perf-resolve-time this end-arg now))))
          (let ((entry (%perf-entry name "measure" start (max 0d0 (- end start)))))
            (%perf-push this entry)
            entry))))
    (eng:install-method perf "clearMarks" 1
      (lambda (this args)
        (let ((name (a args 0))
              (entries (%perf-entries this)))
          (%perf-set-entries this
            (if (undef-p name)
                (remove-if (lambda (e)
                             (string= (->str (eng:js-get e "entryType")) "mark"))
                           entries)
                (remove-if (lambda (e)
                             (and (string= (->str (eng:js-get e "entryType")) "mark")
                                  (string= (->str (eng:js-get e "name")) (->str name))))
                           entries)))
          (undef))))
    (eng:install-method perf "clearMeasures" 1
      (lambda (this args)
        (let ((name (a args 0))
              (entries (%perf-entries this)))
          (%perf-set-entries this
            (if (undef-p name)
                (remove-if (lambda (e)
                             (string= (->str (eng:js-get e "entryType")) "measure"))
                           entries)
                (remove-if (lambda (e)
                             (and (string= (->str (eng:js-get e "entryType")) "measure")
                                  (string= (->str (eng:js-get e "name")) (->str name))))
                           entries)))
          (undef))))
    (eng:install-method perf "getEntries" 0
      (lambda (this args) (declare (ignore args))
        (eng:new-array (%perf-entries this))))
    (eng:install-method perf "getEntriesByName" 2
      (lambda (this args)
        (let ((name (->str (a args 0)))
              (type (a args 1)))
          (eng:new-array
           (remove-if-not
            (lambda (e)
              (and (string= (->str (eng:js-get e "name")) name)
                   (or (undef-p type)
                       (string= (->str (eng:js-get e "entryType")) (->str type)))))
            (%perf-entries this))))))
    (eng:install-method perf "getEntriesByType" 1
      (lambda (this args)
        (let ((type (->str (a args 0))))
          (eng:new-array
           (remove-if-not
            (lambda (e)
              (string= (->str (eng:js-get e "entryType")) type))
            (%perf-entries this))))))
    (eng:data-prop o "performance" perf)
    (let* ((proto (eng:new-object))
           (ctor (eng:make-native-function
                  "PerformanceObserver" 1
                  (lambda (this args)
                    (when (eng:js-object-p this)
                      (eng:hidden-prop this "_cb" (a args 0))
                      (eng:hidden-prop this "%active%" eng:+false+)
                      (eng:hidden-prop this "%pending%" '())
                      (eng:hidden-prop this "%types%" nil)
                      (let ((obs (or (eng:js-get perf "%observers%") '())))
                        (eng:hidden-prop perf "%observers%" (cons this obs))))
                    (undef))
                  :construct
                  (lambda (args nt)
                    (declare (ignore nt))
                    (let ((obj (eng:js-make-object proto)))
                      (eng:hidden-prop obj "_cb" (a args 0))
                      (eng:hidden-prop obj "%active%" eng:+false+)
                      (eng:hidden-prop obj "%pending%" '())
                      (eng:hidden-prop obj "%types%" nil)
                      (let ((obs (or (eng:js-get perf "%observers%") '())))
                        (eng:hidden-prop perf "%observers%" (cons obj obs)))
                      obj)))))
      (eng:data-prop ctor "prototype" proto)
      (eng:install-method proto "observe" 1
        (lambda (this args)
          (let ((opts (a args 0))
                (types nil))
            (when (eng:js-object-p opts)
              (let ((t1 (eng:js-get opts "type"))
                    (et (eng:js-get opts "entryTypes")))
                (cond
                  ((not (undef-p t1)) (setf types (list (->str t1))))
                  ((eng:js-object-p et)
                   (setf types
                         (mapcar #'->str (eng:array-like->list et)))))))
            (eng:hidden-prop this "%types%" types)
            (eng:hidden-prop this "%active%" eng:+true+)
            (undef))))
      (eng:install-method proto "disconnect" 0
        (lambda (this args) (declare (ignore args))
          (eng:hidden-prop this "%active%" eng:+false+)
          (eng:hidden-prop this "%pending%" '())
          (undef)))
      (eng:install-method proto "takeRecords" 0
        (lambda (this args) (declare (ignore args))
          (let ((pending (or (eng:js-get this "%pending%") '())))
            (eng:hidden-prop this "%pending%" '())
            (eng:new-array pending))))
      (eng:data-prop o "PerformanceObserver" ctor))
    (eng:data-prop o "constants" (eng:new-object))
    (eng:install-method o "monitorEventLoopDelay" 1
      (lambda (this args) (declare (ignore this))
        (let ((opts (a args 0))
              (resolution 10))
          (when (eng:js-object-p opts)
            (let ((r (eng:js-get opts "resolution")))
              (unless (undef-p r) (setf resolution (max 1 (truncate (->num r)))))))
          (%make-histogram :eld t :resolution resolution))))
    (eng:install-method o "createHistogram" 1
      (lambda (this args) (declare (ignore this args))
        (%make-histogram :eld nil)))
    o))

(register-node-builtin "perf_hooks" #'build-node-perf-hooks)
