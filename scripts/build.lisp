;;;; build.lisp — produce build/clun via save-lisp-and-die.
;;;; Run from the Makefile after its disposable ASDF compile pass. This image
;;;; only loads warm FASLs, so compiler state is not retained in build/clun.

(load (merge-pathnames "registry.lisp" *load-truename*))

(asdf:load-system :clun)

;; Optional build metadata: stamp the short git revision if a repo/commit exists.
;; This is build tooling (not a runtime implementation crutch); absence is fine.
(let ((rev (ignore-errors
             (string-trim
              '(#\Newline #\Return #\Space)
              (with-output-to-string (out)
                (sb-ext:run-program "git" '("rev-parse" "--short" "HEAD")
                                    :search t :output out :error nil))))))
  (when (and (stringp rev) (plusp (length rev)))
    (setf clun::*clun-revision* rev)))

(let ((out (merge-pathnames "build/clun" *clun-root*)))
  (ensure-directories-exist out)
  (format t "~&building ~a (revision ~a)~%" out clun::*clun-revision*)
  (sb-ext:save-lisp-and-die out
                            :toplevel #'clun:main
                            :executable t
                            ;; Pass all argv to clun:main; SBCL must not parse
                            ;; --version/--help itself.
                            :save-runtime-options t))
