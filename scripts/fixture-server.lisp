;;;; fixture-server.lisp — start the Phase-21 local registry fixture as a PERSISTENT server (for the
;;;; binary-level install e2e in examples/e2e-install.sh). Binds an ephemeral loopback port, writes
;;;; the base URL to $CLUN_FIXTURE_URLFILE (default /tmp/clun-fixture-url), and serves until killed.

(load (merge-pathnames "registry.lisp" *load-truename*))

(handler-bind ((warning (lambda (w) (muffle-warning w))))
  (asdf:load-system :clun/tests))

(in-package :clun-test)

(let ((loop (lp:make-event-loop :workers 0)))
  (multiple-value-bind (listener reg base) (start-fixture-registry loop)
    (declare (ignore reg listener))
    (let ((urlfile (or (sb-ext:posix-getenv "CLUN_FIXTURE_URLFILE") "/tmp/clun-fixture-url")))
      (with-open-file (s urlfile :direction :output :if-exists :supersede :if-does-not-exist :create)
        (write-string base s))
      (format t "clun registry fixture serving at ~a (url written to ~a)~%" base urlfile)
      (finish-output))
    (lp:run-loop loop)))   ; the listener keeps the loop alive → serves until the process is killed
