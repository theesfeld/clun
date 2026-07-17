;;;; test-router-resources.lisp -- Phase 50 100,000-route construction bounds.

(load (merge-pathnames "registry.lisp" *load-truename*))
(asdf:load-system :clun)

(defconstant +router-resource-count+ 100000)
(defconstant +router-retained-heap-limit+ (* 1024 1024 1024))
(defconstant +router-allocation-limit+ (* 4 1024 1024 1024))
(defconstant +router-construction-seconds-limit+ 60d0)
(defconstant +router-lookup-seconds-limit+ 10d0)

(defun elapsed-seconds (start end)
  (/ (- end start) (coerce internal-time-units-per-second 'double-float)))

(sb-ext:gc :full t)
(let* ((baseline-heap (clun.sys:heap-bytes-used))
       (baseline-consed (sb-ext:get-bytes-consed))
       (routes (clun.engine:new-object nil))
       (action
         (clun.engine:make-native-function
          "route" 1
          (lambda (this args)
            (declare (ignore this args))
            clun.engine:+undefined+)))
       (start (get-internal-real-time)))
  (dotimes (index +router-resource-count+)
    (clun.engine:data-prop routes (format nil "/route/~d" index) action))
  (let* ((created-at (get-internal-real-time))
         (table (clun.runtime::%compile-route-table routes))
         (compiled-at (get-internal-real-time)))
    (unless (= (clun.runtime::route-table-count table) +router-resource-count+)
      (error "100,000-route table count mismatch"))
    (dolist (path '("/route/0" "/route/50000" "/route/99999"))
      (multiple-value-bind (found params)
          (clun.runtime::%match-route-table table path "GET")
        (declare (ignore params))
        (unless (eq found action)
          (error "100,000-route lookup failed for ~a" path))))
    (multiple-value-bind (found params)
        (clun.runtime::%match-route-table table "/route/not-present" "GET")
      (declare (ignore params))
      (when found (error "100,000-route missing lookup produced an action")))
    (let ((lookup-start (get-internal-real-time)))
      (dotimes (index 10000)
        (multiple-value-bind (found params)
            (clun.runtime::%match-route-table
             table (format nil "/route/~d" (mod (* index 7919) +router-resource-count+))
             "GET")
          (declare (ignore params))
          (unless (eq found action)
            (error "100,000-route repeated lookup failed at ~d" index))))
      (let ((lookup-end (get-internal-real-time)))
        (setf routes nil)
        (sb-ext:gc :full t)
        (let* ((create-seconds (elapsed-seconds start created-at))
               (compile-seconds (elapsed-seconds created-at compiled-at))
               (lookup-seconds (elapsed-seconds lookup-start lookup-end))
               (retained-heap (- (clun.sys:heap-bytes-used) baseline-heap))
               (allocated (- (sb-ext:get-bytes-consed) baseline-consed)))
          (when (> (+ create-seconds compile-seconds)
                   +router-construction-seconds-limit+)
            (error "100,000-route construction exceeded ~,1fs: ~,3fs"
                   +router-construction-seconds-limit+
                   (+ create-seconds compile-seconds)))
          (when (> lookup-seconds +router-lookup-seconds-limit+)
            (error "10,000 route lookups exceeded ~,1fs: ~,3fs"
                   +router-lookup-seconds-limit+ lookup-seconds))
          (when (> retained-heap +router-retained-heap-limit+)
            (error "100,000-route retained heap exceeded ~d bytes: ~d"
                   +router-retained-heap-limit+ retained-heap))
          (when (> allocated +router-allocation-limit+)
            (error "100,000-route allocation exceeded ~d bytes: ~d"
                   +router-allocation-limit+ allocated))
          (format t
                  "server.router resources: 100000 routes create=~,3fs compile=~,3fs; 10000 lookups=~,3fs; retained=~d bytes allocated=~d bytes~%"
                  create-seconds compile-seconds lookup-seconds retained-heap allocated))))))
