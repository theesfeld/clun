;;;; ts-emit.lisp — Bun/TS-compatible runtime emits for non-erasable TypeScript
;;;; constructs (enums, runtime namespaces, parameter properties). Phase 39 /
;;;; language.typescript Yes strip: length may change; no full tsc typecheck.

(in-package :clun.transpiler)

(defun erase-fill (src start end)
  "Whitespace fill for [START, END) preserving line terminators (same as strip)."
  (let ((out (make-string (- end start) :initial-element #\Space)))
    (loop for i from start below end
          for j from 0
          when (eng:line-terminator-p (char-code (char src i)))
            do (setf (char out j) (char src i)))
    out))

(defun render-plan (src erasures replacements)
  "Apply ERASURES (start . end) and REPLACEMENTS (start end text). When REPLACEMENTS
is empty, length-preserving space-fill (Phase 09). Otherwise stitch rewrites:
erasures become space-fill spans; replacements substitute text (may change length)."
  (if (null replacements)
      (let ((out (copy-seq (coerce src 'simple-string))))
        (dolist (span erasures out)
          (loop for i from (car span) below (cdr span)
                unless (eng:line-terminator-p (char-code (char out i)))
                  do (setf (char out i) #\Space))))
      (let* ((ops (append
                   (mapcar (lambda (e)
                             (list (car e) (cdr e) (erase-fill src (car e) (cdr e))))
                           erasures)
                   (mapcar (lambda (r) (list (first r) (second r) (third r)))
                           replacements)))
             (sorted (sort (copy-list ops) #'< :key #'first)))
        (with-output-to-string (o)
          (let ((pos 0))
            (dolist (op sorted)
              (destructuring-bind (s e text) op
                (when (< s pos)
                  ;; overlapping / nested plan entry — skip stale region
                  (when (>= e pos)
                    (write-string text o)
                    (setf pos e)))
                (when (>= s pos)
                  (when (< pos s) (write-string (subseq src pos s) o))
                  (write-string text o)
                  (setf pos e))))
            (when (< pos (length src))
              (write-string (subseq src pos) o)))))))

;;; --- enum emit --------------------------------------------------------------

(defun enum-member-numeric-p (init)
  (and (consp init) (eq (car init) :num)))

(defun enum-member-string-p (init)
  (and (consp init) (eq (car init) :str)))

(defun eval-enum-const (expr env)
  "Fold a tiny constant enum initializer. EXPR is a list of tokens as
(:num n) (:str s) (:id name) (:op op). ENV maps member name → folded value.
Returns (:num n), (:str s), or nil if not foldable."
  (cond
    ((null expr) nil)
    ((and (= (length expr) 1) (eq (caar expr) :num)) (car expr))
    ((and (= (length expr) 1) (eq (caar expr) :str)) (car expr))
    ((and (= (length expr) 1) (eq (caar expr) :id))
     (let ((v (gethash (cadar expr) env)))
       (cond ((numberp v) (list :num v))
             ((stringp v) (list :str v))
             (t nil))))
    ;; unary +/-
    ((and (>= (length expr) 2) (eq (caar expr) :op)
          (member (cadar expr) '("+" "-") :test #'string=))
     (let ((rest (eval-enum-const (cdr expr) env)))
       (when (enum-member-numeric-p rest)
         (list :num (if (string= (cadar expr) "-")
                        (- (cadr rest))
                        (cadr rest))))))
    ;; binary + - * /
    ((and (= (length expr) 3)
          (eq (caadr expr) :op)
          (member (cadadr expr) '("+" "-" "*" "/") :test #'string=))
     (let ((a (eval-enum-const (list (first expr)) env))
           (b (eval-enum-const (list (third expr)) env))
           (op (cadadr expr)))
       (when (and (enum-member-numeric-p a) (enum-member-numeric-p b))
         (list :num
               (cond ((string= op "+") (+ (cadr a) (cadr b)))
                     ((string= op "-") (- (cadr a) (cadr b)))
                     ((string= op "*") (* (cadr a) (cadr b)))
                     ((string= op "/") (if (zerop (cadr b)) nil
                                           (/ (cadr a) (cadr b)))))))))
    (t nil)))

(defun format-enum-value (init)
  (cond ((enum-member-numeric-p init)
         (let ((n (cadr init)))
           (if (and (floatp n) (= n (floor n)))
               (format nil "~d" (floor n))
               (princ-to-string n))))
        ((enum-member-string-p init)
         (format nil "~s" (cadr init)))
        ((and (consp init) (eq (car init) :src)) (cadr init))
        (t "void 0")))

(defun emit-enum-js (name members &key export-p)
  "Emit a Bun/TS-shaped enum IIFE. MEMBERS is a list of (name-string init) where
INIT is (:num n), (:str s), (:src text), or nil (auto)."
  (let ((env (make-hash-table :test #'equal))
        (next 0)
        (have-next t)
        (body (make-string-output-stream)))
    (dolist (m members)
      (destructuring-bind (mname init) m
        (let* ((folded (cond ((null init)
                              (if have-next (list :num next) nil))
                             ((or (enum-member-numeric-p init)
                                  (enum-member-string-p init))
                              init)
                             ((and (consp init) (eq (car init) :expr))
                              (or (eval-enum-const (cadr init) env)
                                  (list :src (caddr init))))
                             (t init)))
               (final (or folded (list :src "void 0")))
               (str-p (enum-member-string-p final)))
          (when (enum-member-numeric-p final)
            (setf next (1+ (cadr final))
                  have-next t)
            (setf (gethash mname env) (cadr final)))
          (when (enum-member-string-p final)
            (setf have-next nil)
            (setf (gethash mname env) (cadr final)))
          (when (and (consp final) (eq (car final) :src))
            (setf have-next nil))
          (let ((val (format-enum-value final)))
            (if str-p
                (format body "~a[~s]=~a;" name mname val)
                (format body "~a[~a[~s]=~a]=~s;" name name mname val mname))))))
    (format nil "~:[~;export ~]var ~a;(function(~a){~a})(~a||(~a={}));"
            export-p name name (get-output-stream-string body) name name)))

;;; --- namespace emit ----------------------------------------------------------

(defun emit-namespace-js (name body-js &key export-p outer-assign)
  "Wrap BODY-JS in a namespace IIFE bound to NAME.
OUTER-ASSIGN when non-nil is the left-hand form for nested namespaces
(e.g. \"Inner = N.Inner\")."
  (if outer-assign
      (format nil "let ~a;(function(~a){~a})(~a||(~a={}));"
              name name body-js outer-assign outer-assign)
      (format nil "~:[~;export ~]var ~a;(function(~a){~a})(~a||(~a={}));"
              export-p name name body-js name name)))

(defun emit-param-prop-assigns (names)
  "Constructor body insert: this.x=x; for each parameter property name."
  (with-output-to-string (o)
    (dolist (n names)
      (format o "this.~a=~a;" n n))))
