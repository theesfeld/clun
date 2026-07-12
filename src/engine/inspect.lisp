;;;; inspect.lisp — the ONE shared value inspector (PLAN.md §3.6, Phase 08). Powers
;;;; console.*, util.inspect, Clun.inspect, and test diffs. Bun-flavored formatting
;;;; (double-quoted strings, colon Map/Set form, multiline objects with a trailing
;;;; comma, inline arrays, `[Object ...]` beyond depth, `[Circular]`). Lives in the
;;;; engine for deep access to descriptors / Map-Set / Promise internals; exports
;;;; only INSPECT-VALUE + *INSPECT-DEFAULTS*.

(in-package :clun.engine)

(defparameter *inspect-defaults* '(:depth 2 :breadth 100)
  "Default depth (2) and per-container item cap (100), matching Node/Bun.")

(defvar *inspect-seen* nil "eq-hash of containers on the current path (circular guard).")

(defun %spaces (n) (make-string n :initial-element #\Space))

(defun %ident-key-p (s)
  "True iff string S can appear as an unquoted object key."
  (and (stringp s) (plusp (length s))
       (let ((c0 (char s 0)))
         (or (alpha-char-p c0) (char= c0 #\_) (char= c0 #\$)))
       (every (lambda (c) (or (alphanumericp c) (char= c #\_) (char= c #\$))) s)))

(defun %quote-string (s)
  "Double-quote S with JS escapes (Bun style)."
  (with-output-to-string (o)
    (write-char #\" o)
    (loop for c across s do
      (case c
        (#\" (write-string "\\\"" o))
        (#\\ (write-string "\\\\" o))
        (#\Newline (write-string "\\n" o))
        (#\Tab (write-string "\\t" o))
        (#\Return (write-string "\\r" o))
        (t (if (< (char-code c) #x20)
               (format o "\\x~2,'0X" (char-code c))
               (write-char c o)))))
    (write-char #\" o)))

(defun %callable-display-name (f)
  "A callable's display name: prefer its JS-visible `name` own property (set even
when the internal fname is \"\", e.g. a class with an explicit constructor); else the
internal function-name."
  (let* ((d (obj-own-desc f "name"))
         (n (and d (data-descriptor-p d) (pd-value d))))
    (if (and (stringp n) (plusp (length n))) n (function-name f))))

(defun %ctor-name (o)
  "The constructor name for object O (for `Name {}`), or NIL if plain Object."
  (let ((proto (js-object-proto o)))
    (when (js-object-p proto)
      (let ((ctor (let ((d (obj-own-desc proto "constructor")))
                    (and d (data-descriptor-p d) (pd-value d)))))
        (when (callable-p ctor)
          (let ((n (%callable-display-name ctor)))
            (when (and (stringp n) (plusp (length n)) (not (string= n "Object")))
              n)))))))

(defun %wrapper-p (o)
  (and (js-object-p o) (obj-own-desc o "%primitive%")))

(defun inspect-value (v &key (depth 2) (colors nil) (breadth 100))
  "Return a string rendering of the JS value V, Bun-flavored. DEPTH is the container
recursion budget (2), BREADTH the per-container item cap (100)."
  (declare (ignore colors))
  (let ((*inspect-seen* (make-hash-table :test 'eq)))
    (%ins v depth 0 breadth)))

(defun %ins (v depth indent breadth)
  "Render V at container base column INDENT with remaining DEPTH."
  (cond
    ((eq v +undefined+) "undefined")
    ((eq v +null+) "null")
    ((eq v +true+) "true")
    ((eq v +false+) "false")
    ((typep v 'double-float)
     (cond ((js-neg-zero-p v) "-0")
           (t (number->js-string v))))
    ((integerp v) (format nil "~dn" v))         ; BigInt prints with the `n` suffix
    ((stringp v) (%quote-string v))
    ((js-symbol-p v)
     (let ((d (js-symbol-description v)))
       (format nil "Symbol(~a)" (if (js-undefined-p d) "" d))))
    ((js-object-p v) (%ins-object v depth indent breadth))
    (t (princ-to-string v))))

(defun %ins-object (o depth indent breadth)
  (cond
    ;; callables first (a function is a js-object)
    ((callable-p o)
     (let ((n (%callable-display-name o)))
       (if (and (stringp n) (plusp (length n))) (format nil "[Function: ~a]" n) "[Function]")))
    ;; wrapper primitives: [Number: 5] / [String: "x"] / [Boolean: true]
    ((%wrapper-p o)
     (let ((p (wrapper-primitive o)))
       (format nil "[~a: ~a]"
               (case (js-object-class o) (:number "Number") (:string "String")
                     (:boolean "Boolean") (:symbol "Symbol") (t "Object"))
               (%ins p depth indent breadth))))
    ((js-promise-p o)
     (ecase (js-promise-pstate o)
       (:pending "Promise { <pending> }")
       (:fulfilled (format nil "Promise { ~a }" (%ins (js-promise-value o) (1- depth) indent breadth)))
       (:rejected (format nil "Promise { <rejected> ~a }" (%ins (js-promise-value o) (1- depth) indent breadth)))))
    ((eq (js-object-class o) :date)
     (let ((iso (ignore-errors (js-call (js-get o "toISOString") o '()))))
       (if (stringp iso) iso "Invalid Date")))
    ((eq (js-object-class o) :error)
     (let ((stk (js-get o "stack")))
       (if (stringp stk) stk
           (format nil "~a: ~a" (to-string (js-get o "name")) (to-string (js-get o "message"))))))
    ;; circular
    ((gethash o *inspect-seen*) "[Circular]")
    ((js-map-p o) (%ins-map-set o depth indent breadth :map))
    ((js-set-p o) (%ins-map-set o depth indent breadth :set))
    ((js-array-p o)
     (if (< depth 0) "[Array]" (%ins-array o depth indent breadth)))
    (t (if (< depth 0) "[Object ...]" (%ins-plain o depth indent breadth)))))

(defmacro %with-seen ((o) &body body)
  `(progn (setf (gethash ,o *inspect-seen*) t)
          (unwind-protect (progn ,@body)
            (remhash ,o *inspect-seen*))))

(defun %ins-array (a depth indent breadth)
  (%with-seen (a)
    (let* ((len (array-length a)) (parts '()) (shown 0) (holes 0))
      (flet ((flush-holes ()
               (when (plusp holes)
                 (push (format nil "<~a empty item~:p>" holes) parts)
                 (setf holes 0))))
        (loop for i below len
              until (>= shown breadth)
              do (let ((d (jm-get-own-property a (princ-to-string i))))
                   (if d
                       (progn (flush-holes)
                              (push (%ins (js-getv a (princ-to-string i)) (1- depth) indent breadth) parts)
                              (incf shown))
                       (incf holes))))
        (flush-holes)
        (when (> len breadth)
          (push (format nil "... ~a more item~:p" (- len breadth)) parts)))
      ;; extra (non-index) own enumerable string keys
      (dolist (k (jm-own-property-keys a))
        (when (and (stringp k) (not (string= k "length")) (not (%array-index-p k)))
          (let ((d (jm-get-own-property a k)))
            (when (and d (eq (pd-enumerable d) t))
              (push (format nil "~a: ~a"
                            (if (%ident-key-p k) k (%quote-string k))
                            (%ins-prop a k d (1- depth) indent breadth))
                    parts)))))
      (let ((items (nreverse parts)))
        (if items (format nil "[ ~{~a~^, ~} ]" items) "[]")))))

(defun %array-index-p (k)
  (and (stringp k) (plusp (length k)) (every #'digit-char-p k)))

(defun %ins-map-set (o depth indent breadth kind)
  (%with-seen (o)
    (let* ((md (if (eq kind :map) (js-map-data o) (js-set-data o)))
           (order (md-order md)) (live (md-live md)) (parts '()) (shown 0))
      (loop for e across order
            until (>= shown breadth)
            unless (me-deleted e)
              do (push (if (eq kind :map)
                           (format nil "~a: ~a"
                                   (%ins (me-key e) (1- depth) indent breadth)
                                   (%ins (me-value e) (1- depth) indent breadth))
                           (%ins (me-key e) (1- depth) indent breadth))
                       parts)
                 (incf shown))
      (let ((items (nreverse parts))
            (label (format nil "~a(~a)" (if (eq kind :map) "Map" "Set") live)))
        (if items (format nil "~a { ~{~a~^, ~} }" label items)
            (format nil "~a {}" label))))))

(defun %ins-prop (o key desc depth indent breadth)
  "Render the value of own property KEY (given its DESC) — accessors show [Getter]."
  (declare (ignore o))
  (cond
    ((accessor-descriptor-p desc)
     ;; the absent half of a getter-only/setter-only accessor holds +undefined+
     ;; (pd-set-p true), so test callability, not mere presence.
     (let ((g (callable-p (pd-get desc))) (s (callable-p (pd-set desc))))
       (cond ((and g s) "[Getter/Setter]") (g "[Getter]") (s "[Setter]") (t "undefined"))))
    (t (%ins (pd-value desc) depth indent (or breadth 100)))
    ;; key kept in the lambda list for symmetry; value is in the descriptor
    ))

(defun %ins-plain (o depth indent breadth)
  (%with-seen (o)
    (let ((entries '()) (name (%ctor-name o)))
      (dolist (k (jm-own-property-keys o))
        (let ((d (jm-get-own-property o k)))
          (when (and d (eq (pd-enumerable d) t))
            (let ((keystr (cond ((js-symbol-p k)
                                 (format nil "[Symbol(~a)]"
                                         (let ((dd (js-symbol-description k)))
                                           (if (js-undefined-p dd) "" dd))))
                                ((%ident-key-p k) k)
                                (t (%quote-string k)))))
              (push (cons keystr (%ins-prop o k d (1- depth) (+ indent 2) breadth)) entries)))))
      (setf entries (nreverse entries))
      (let ((prefix (if name (concatenate 'string name " ") "")))
        (if (null entries)
            (concatenate 'string prefix "{}")
            ;; multiline, trailing comma after every entry (Bun)
            (with-output-to-string (s)
              (write-string prefix s)
              (write-string "{" s) (write-char #\Newline s)
              (dolist (e entries)
                (write-string (%spaces (+ indent 2)) s)
                (write-string (car e) s) (write-string ": " s)
                (write-string (cdr e) s) (write-string "," s) (write-char #\Newline s))
              (write-string (%spaces indent) s)
              (write-string "}" s)))))))
