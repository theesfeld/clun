;;;; run-ts-strip.lisp — the TS type-strip conformance harness (PLAN.md §3.3, Phase
;;;; 09). Runs in-image (no subprocess). Two fixture kinds under tests/ts/:
;;;;   strip/<case>.ts   + <case>.expected.js  — strip must be byte-exact AND the
;;;;                                              SAME LENGTH as the input.
;;;;   errors/<case>.ts  + <case>.error         — strip must signal
;;;;                                              unsupported-ts-syntax; the .error
;;;;                                              file's first line is a substring
;;;;                                              the message must contain; an optional
;;;;                                              second line `line:col` is checked.
;;;; (runtime/ .ts cases run through the normal tests/js harness — .ts is listed there.)

(load (merge-pathnames "registry.lisp" *load-truename*))
(asdf:load-system :clun :verbose nil)

(defun slurp (p) (with-open-file (in p :external-format :utf-8)
                   (let ((s (make-string (file-length in)))) (subseq s 0 (read-sequence s in)))))
(defun rel (p) (enough-namestring p *clun-root*))

(defun run-strip-case (ts-path)
  (let* ((exp-path (make-pathname :type nil :name (concatenate 'string (pathname-name ts-path) ".expected")
                                  :defaults ts-path))
         (exp-js (merge-pathnames (make-pathname :type "js") exp-path))
         (src (slurp ts-path))
         (want (slurp exp-js)))
    (handler-case
        (let ((got (clun.transpiler:strip-types src (namestring ts-path))))
          (cond ((/= (length got) (length src))
                 (format t "  (FAIL) ~a — length ~a != source ~a~%" (rel ts-path) (length got) (length src)) nil)
                ((not (string= got want))
                 (format t "  (FAIL) ~a~%    want ~s~%    got  ~s~%" (rel ts-path) want got) nil)
                (t t)))
      (error (e) (format t "  (FAIL) ~a — signalled ~a~%" (rel ts-path) e) nil))))

(defun run-error-case (ts-path)
  (let* ((err-path (make-pathname :type "error" :defaults ts-path))
         (spec (with-open-file (in err-path) (list (read-line in nil "") (read-line in nil nil))))
         (want-msg (first spec)) (want-loc (second spec))
         (src (slurp ts-path)))
    (handler-case
        (progn (clun.transpiler:strip-types src (namestring ts-path))
               (format t "  (FAIL) ~a — expected an error, none signalled~%" (rel ts-path)) nil)
      (clun.transpiler:unsupported-ts-syntax (e)
        (let ((msg (clun.transpiler:uts-message e))
              (loc (format nil "~a:~a" (clun.transpiler:uts-line e) (clun.transpiler:uts-col e))))
          (cond ((not (search want-msg msg))
                 (format t "  (FAIL) ~a — message ~s lacks ~s~%" (rel ts-path) msg want-msg) nil)
                ((and want-loc (plusp (length want-loc)) (not (string= loc want-loc)))
                 (format t "  (FAIL) ~a — loc ~a != ~a~%" (rel ts-path) loc want-loc) nil)
                (t t))))
      (error (e) (format t "  (FAIL) ~a — wrong condition ~a~%" (rel ts-path) e) nil))))

(let ((strip (sort (directory (merge-pathnames "tests/ts/strip/*.ts" *clun-root*)) #'string< :key #'namestring))
      (errs (sort (directory (merge-pathnames "tests/ts/errors/*.ts" *clun-root*)) #'string< :key #'namestring))
      (pass 0) (fail 0))
  (dolist (p strip) (if (run-strip-case p) (incf pass) (incf fail)))
  (dolist (p errs)  (if (run-error-case p) (incf pass) (incf fail)))
  (format t "~%tests/ts (strip+errors): ~a passed, ~a failed (~a total)~%" pass fail (+ pass fail))
  (sb-ext:exit :code (if (zerop fail) 0 1)))
