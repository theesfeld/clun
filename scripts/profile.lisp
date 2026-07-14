;;;; profile.lisp — Phase 25 "measure first": statistical profile of a benchmark under the real
;;;; engine, so optimization work is guided by where time ACTUALLY goes (not a static guess).
;;;; Uses sb-sprof (an SBCL contrib — pure, no foreign code). Run:
;;;;   CLUN_BENCH=bench/richards.js sbcl --dynamic-space-size 4096 --non-interactive \
;;;;     --no-userinit --no-sysinit --load scripts/profile.lisp
(load (merge-pathnames "registry.lisp" *load-truename*))
(asdf:load-system :clun)
(require :sb-sprof)
(in-package :clun.engine)

(defun run-bench-profiled (path)
  (let ((realm (make-realm)))
    (clun.runtime:install-runtime realm :argv (list :script path :rest nil)
                                        :cwd (namestring cl-user::*clun-root*) :silent nil)
    (sb-sprof:with-profiling (:max-samples 200000 :sample-interval 0.001 :mode :cpu :report :flat :loop nil)
      (run-module-file path :realm realm))))

(let ((path (namestring (merge-pathnames (or (sb-ext:posix-getenv "CLUN_BENCH") "bench/richards.js")
                                         cl-user::*clun-root*))))
  (format t "~&=== profiling ~a ===~%" path)
  (run-bench-profiled path)
  (finish-output))
