;;;; purity-scan.lisp — the mechanically-enforced purity gate (PLAN.md §1.1).
;;;;
;;;; Per §1.1 the scan covers "the full ASDF load plan and all vendored sources".
;;;; We take the UNION of two file sets so neither can hide a leak:
;;;;   (1) the ASDF load plan — every cl-source-file required to load :clun and
;;;;       :clun/tests, including vendored dependency files (required-components
;;;;       :other-systems t); this is what actually gets compiled into the image.
;;;;   (2) a directory scan of src/, tests/, and vendor/ (plus root *.asd) — every
;;;;       first-party and vendored source ON DISK, which also catches files a
;;;;       library ships but only loads conditionally (e.g. pure-tls's win/darwin
;;;;       CFFI files before they are stripped in Phase 19) that the plan omits.
;;;; The union is provably a superset of the load plan. Any hit → exit 1.
;;;;
;;;; scripts/ is deliberately NOT scanned: it is build tooling (not load-plan, not
;;;; vendored) and this file necessarily contains the forbidden tokens as its own
;;;; search patterns.

(require :asdf)
(load (merge-pathnames "registry.lisp" *load-truename*))

(defparameter *forbidden*
  ;; Case-insensitive substrings; each names a foreign-code entry point that
  ;; violates the purity contract outside SBCL itself. (sb-posix, sb-unix,
  ;; sb-bsd-sockets, sb-thread, sb-ext, serve-event are ALLOWED contribs.)
  '("cffi" "foreign-funcall" "sb-alien" "define-alien" "make-alien"
    "alien-funcall" "load-shared-object" "load-foreign" "%foreign"))

(defparameter *source-types* '("lisp" "asd" "cl"))

(defun source-files-under (dir)
  "All *.lisp/*.asd/*.cl files at any depth under DIR."
  (loop for type in *source-types*
        nconc (directory
               (merge-pathnames
                (make-pathname :directory '(:relative :wild-inferiors)
                               :name :wild :type type)
                dir))))

(defun load-plan-files (system)
  "Source files ASDF would compile to load SYSTEM, including vendored deps."
  (mapcar #'asdf:component-pathname
          (asdf:required-components system
                                    :other-systems t
                                    :keep-component 'asdf:cl-source-file)))

(defun scan-file (path)
  "Return a list of (line-number token line-text) for each forbidden hit in PATH.
Reads as latin-1 so any byte sequence decodes without error (we match ASCII)."
  (let ((hits '()))
    (with-open-file (in path :direction :input
                             :external-format :latin-1
                             :element-type 'character)
      (loop for line = (read-line in nil nil)
            for n from 1
            while line
            do (let ((low (string-downcase line)))
                 (dolist (tok *forbidden*)
                   (when (search tok low)
                     (push (list n tok line) hits))))))
    (nreverse hits)))

(let* ((plan (append (load-plan-files "clun") (load-plan-files "clun/tests")))
       (on-disk (append (source-files-under (merge-pathnames "src/" *clun-root*))
                        (source-files-under (merge-pathnames "tests/" *clun-root*))
                        (source-files-under (merge-pathnames "vendor/" *clun-root*))
                        (directory (merge-pathnames "*.asd" *clun-root*))))
       ;; Dedup by canonical truename so a plan file and its on-disk twin scan once.
       (files (remove-duplicates (append plan on-disk)
                                 :test #'equal
                                 :key (lambda (p) (namestring (truename p)))))
       (violations 0))
  (dolist (f files)
    (dolist (hit (scan-file f))
      (incf violations)
      (format t "~&PURITY VIOLATION ~a:~a  token ~s~%    ~a~%"
              (uiop:native-namestring f) (first hit) (second hit)
              (string-trim '(#\Space #\Tab) (third hit)))))
  (if (zerop violations)
      (progn
        (format t "~&purity: clean — ~a source file(s) scanned, 0 violations~%"
                (length files))
        (sb-ext:exit :code 0))
      (progn
        (format t "~&purity: FAILED — ~a violation(s)~%~
                   note: no CFFI/foreign code is permitted outside SBCL (PLAN.md §1.1)~%"
                violations)
        (sb-ext:exit :code 1))))
