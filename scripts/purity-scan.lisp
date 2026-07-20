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

;;; Issue #265 / Phase 48 operator decision: users may load real machine-code
;;; addons. Exactly one source file may contain the foreign load/call boundary;
;;; the pure-CL host elsewhere processes and hooks those libraries.
(defparameter *allowlisted-relative*
  '("src/ffi/machine-boundary.lisp"))

(defparameter *source-types* '("lisp" "asd" "cl"))

(defun allowlisted-p (path)
  "True when PATH is the documented user-native load/call boundary."
  (let* ((true (ignore-errors (namestring (truename path))))
         (root (ignore-errors (namestring (truename *clun-root*)))))
    (when (and true root)
      (let ((rel (if (and (>= (length true) (length root))
                          (string= true root :end1 (length root)))
                     (string-left-trim "/\\" (subseq true (length root)))
                     true)))
        (member rel *allowlisted-relative* :test #'string-equal)))))

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
    (if (allowlisted-p f)
        (format t "~&purity: allowlist skip ~a (user-native load/call boundary; Issue #265)~%"
                (uiop:native-namestring f))
        (dolist (hit (scan-file f))
          (incf violations)
          (format t "~&PURITY VIOLATION ~a:~a  token ~s~%    ~a~%"
                  (uiop:native-namestring f) (first hit) (second hit)
                  (string-trim '(#\Space #\Tab) (third hit))))))
  (if (zerop violations)
      (progn
        (format t "~&purity: clean — ~a source file(s) scanned, 0 violations~
                   (user-native boundary allowlist: ~{~a~^, ~})~%"
                (length files) *allowlisted-relative*)
        (sb-ext:exit :code 0))
      (progn
        (format t "~&purity: FAILED — ~a violation(s)~%~
                   note: foreign load/call tokens only allowed in ~{~a~^, ~} (Issue #265);~
                   elsewhere Clun remains pure CL (PLAN.md §1.1)~%"
                violations *allowlisted-relative*)
        (sb-ext:exit :code 1))))
