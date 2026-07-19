;;;; perf_hooks.lisp — node:perf_hooks (performance.now + PerformanceObserver).

(in-package :clun.runtime)

(defun %perf-now ()
  (/ (coerce (sys:monotonic-nanoseconds) 'double-float) 1.0d6))

(defun build-node-perf-hooks ()
  (let* ((o (eng:new-object))
         (perf (eng:new-object))
         (time-origin (%perf-now)))
    (eng:data-prop perf "timeOrigin" time-origin)
    (eng:install-method perf "now" 0
      (lambda (this args) (declare (ignore this args))
        (- (%perf-now) time-origin)))
    (eng:install-method perf "mark" 1
      (lambda (this args) (declare (ignore this))
        (let ((entry (eng:new-object)))
          (eng:data-prop entry "name" (->str (a args 0)))
          (eng:data-prop entry "entryType" "mark")
          (eng:data-prop entry "startTime" (- (%perf-now) time-origin))
          (eng:data-prop entry "duration" 0d0)
          entry)))
    (eng:install-method perf "measure" 3
      (lambda (this args) (declare (ignore this))
        (let ((entry (eng:new-object)))
          (eng:data-prop entry "name" (->str (a args 0)))
          (eng:data-prop entry "entryType" "measure")
          (eng:data-prop entry "startTime" 0d0)
          (eng:data-prop entry "duration" 0d0)
          entry)))
    (eng:install-method perf "clearMarks" 1
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method perf "clearMeasures" 1
      (lambda (this args) (declare (ignore this args)) eng:+undefined+))
    (eng:install-method perf "getEntries" 0
      (lambda (this args) (declare (ignore this args)) (eng:new-array '())))
    (eng:install-method perf "getEntriesByName" 2
      (lambda (this args) (declare (ignore this args)) (eng:new-array '())))
    (eng:install-method perf "getEntriesByType" 1
      (lambda (this args) (declare (ignore this args)) (eng:new-array '())))
    (eng:data-prop o "performance" perf)
    (let* ((proto (eng:new-object))
           (ctor (eng:make-native-function
                  "PerformanceObserver" 1
                  (lambda (this args)
                    (when (eng:js-object-p this)
                      (eng:hidden-prop this "_cb" (a args 0)))
                    (undef))
                  :construct
                  (lambda (args nt)
                    (declare (ignore nt))
                    (let ((obj (eng:js-make-object proto)))
                      (eng:hidden-prop obj "_cb" (a args 0))
                      obj)))))
      (eng:data-prop ctor "prototype" proto)
      (eng:install-method proto "observe" 1
        (lambda (this args) (declare (ignore this args)) eng:+undefined+))
      (eng:install-method proto "disconnect" 0
        (lambda (this args) (declare (ignore this args)) eng:+undefined+))
      (eng:install-method proto "takeRecords" 0
        (lambda (this args) (declare (ignore this args)) (eng:new-array '())))
      (eng:data-prop o "PerformanceObserver" ctor))
    (eng:data-prop o "constants" (eng:new-object))
    (eng:install-method o "monitorEventLoopDelay" 1
      (lambda (this args) (declare (ignore this args))
        (let ((h (eng:new-object)))
          (eng:install-method h "enable" 0
            (lambda (tt aa) (declare (ignore tt aa)) eng:+undefined+))
          (eng:install-method h "disable" 0
            (lambda (tt aa) (declare (ignore tt aa)) eng:+undefined+))
          (eng:data-prop h "min" 0d0)
          (eng:data-prop h "max" 0d0)
          (eng:data-prop h "mean" 0d0)
          (eng:data-prop h "stddev" 0d0)
          h)))
    o))

(register-node-builtin "perf_hooks" #'build-node-perf-hooks)
