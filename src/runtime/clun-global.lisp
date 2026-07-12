;;;; clun-global.lisp — a minimal `Clun` global (PLAN.md §1.2, Phase 08 stub). The
;;;; full 14-member surface (file/write/spawn/serve/…) lands in later phases; here we
;;;; wire the cheap members that depend only on what exists: version/revision/env/
;;;; argv/main/inspect/deepEquals/sleep.

(in-package :clun.runtime)

(defun install-clun-global (realm rt)
  (declare (ignore rt))
  (let* ((eng:*realm* realm)
         (g (eng:realm-global realm))
         (clun (eng:new-object))
         (proc (eng:js-get g "process")))
    (eng:data-prop clun "version" clun::*clun-version*)
    (eng:data-prop clun "revision" clun::*clun-revision*)
    ;; env / argv mirror process (same objects)
    (when (eng:js-object-p proc)
      (eng:data-prop clun "env" (eng:js-get proc "env"))
      (eng:data-prop clun "argv" (eng:js-get proc "argv")))
    (eng:data-prop clun "main" eng:+undefined+)        ; set to the entry path by the CLI
    (eng:install-method clun "inspect" 1
      (lambda (this args) (declare (ignore this)) (eng:inspect-value (eng:arg args 0))))
    (eng:install-method clun "deepEquals" 2
      (lambda (this args) (declare (ignore this))
        (eng:js-boolean (%deep-equals (eng:arg args 0) (eng:arg args 1)))))
    (eng:install-method clun "sleepSync" 1
      (lambda (this args) (declare (ignore this))
        (let ((ms (eng:to-number (eng:arg args 0))))
          (when (and (= ms ms) (plusp ms)) (sleep (/ ms 1000d0))))
        eng:+undefined+))
    (eng:hidden-prop g "Clun" clun)
    clun))

(defun %deep-equals (a b)
  "A minimal structural equality (SameValueZero on primitives; recursive on plain
objects/arrays). Full Bun deepEquals semantics land with the test runner (Phase 22)."
  (cond
    ((eq a b) t)
    ((and (stringp a) (stringp b)) (string= a b))
    ((and (typep a 'double-float) (typep b 'double-float)) (or (= a b) (and (/= a a) (/= b b))))
    ((and (eng:js-object-p a) (eng:js-object-p b))
     (let ((ka (eng:jm-own-property-keys a)) (kb (eng:jm-own-property-keys b)))
       (and (= (length ka) (length kb))
            (every (lambda (k) (and (stringp k) (%deep-equals (eng:js-get a k) (eng:js-get b k)))) ka))))
    (t nil)))
