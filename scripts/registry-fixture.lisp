;;;; registry-fixture.lisp — `make registry-fixture`. Starts the Phase-21 in-process registry
;;;; fixture on an ephemeral loopback port, prints its package inventory, verifies every served
;;;; tarball's bytes against its advertised dist.integrity (sha512), and does one real
;;;; over-the-wire metadata+tarball round-trip through the registry client. Exits 0 iff healthy.
;;;; This is the reusable entry point the Phase-21 gate requires and Phases 22–23 install tests
;;;; drive via clun-test:start-fixture-registry.

(load (merge-pathnames "registry.lisp" *load-truename*))

(handler-bind ((warning (lambda (w) (muffle-warning w))))
  (asdf:load-system :clun/tests))

(in-package :clun-test)

(defun %fixture-main ()
  (let ((loop (lp:make-event-loop :workers 0)))
    (multiple-value-bind (listener reg base) (start-fixture-registry loop)
      (format t "~&clun registry fixture listening at ~a~%" base)
      (let ((model-ok t) (npkg 0) (nver 0) (wire-ok nil) (wire-err nil))
        ;; inventory + hermetic integrity check (every served tarball verifies)
        (maphash
         (lambda (name json)
           (incf npkg)
           (let ((md (reg:parse-metadata json)))
             (dolist (v (sort (reg:metadata-version-strings md) #'string<))
               (incf nver)
               (let* ((vm (reg:metadata-version md v))
                      (bytes (gethash (%tgz-filename name v) (fixture-registry-tarballs reg)))
                      (good (and bytes (string= (reg:vm-dist-integrity vm) (tarball-integrity bytes)))))
                 (unless good (setf model-ok nil))
                 (format t "  ~30a ~8a ~a  [~a]~%" name v (reg:vm-dist-integrity vm)
                         (if good "ok" "MISMATCH"))))))
         (fixture-registry-metadata reg))
        ;; one real over-the-wire round-trip: resolve → download → verify
        (reg:fetch-metadata-async loop "left-pad" :override base :retries 0
          :on-ok (lambda (md)
                   (let* ((vm (reg:metadata-version md "1.3.0"))
                          (url (reg:vm-dist-tarball vm))
                          (path (subseq url (length base)))
                          (want (reg:vm-dist-integrity vm)))
                     (multiple-value-bind (h p) (reg:parse-registry-base base)
                       (net:http-request-async loop :host h :port p :method "GET" :path path
                         :on-response (lambda (resp)
                                        (setf wire-ok (string= want (tarball-integrity (net:hres-body resp))))
                                        (lp:loop-stop loop))
                         :on-error (lambda (c) (setf wire-err c) (lp:loop-stop loop))))))
          :on-err (lambda (c) (setf wire-err c) (lp:loop-stop loop)))
        (lp:run-loop loop)
        (net:listener-close listener)
        (lp:destroy-event-loop loop)
        (format t "~&~%fixture: ~d packages, ~d versions | integrity ~a | over-the-wire ~a~%"
                npkg nver (if model-ok "OK" "FAIL") (if wire-ok "OK" "FAIL"))
        (when wire-err (format t "  over-the-wire error: ~a~%" wire-err))
        (sb-ext:exit :code (if (and model-ok wire-ok) 0 1))))))

(%fixture-main)
