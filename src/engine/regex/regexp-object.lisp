;;;; regexp-object.lisp — the RegExp exotic object + prototype + String delegation
;;;; (PLAN.md §3.1, Phase 10). Builds a js-regexp from an AST-compiled cl-ppcre scanner.

(in-package :clun.engine)

(defstruct (js-regexp (:include js-object (class :regexp)) (:constructor %make-js-regexp))
  (source "" :type simple-string) (flags "" :type simple-string)
  scanner name-alist (group-count 0 :type fixnum) (flag-bits 0 :type fixnum))

(defconstant +rf-g+ 1) (defconstant +rf-i+ 2) (defconstant +rf-m+ 4)
(defconstant +rf-s+ 8) (defconstant +rf-u+ 16) (defconstant +rf-y+ 32) (defconstant +rf-d+ 64)

(defun flags->bits (flags)
  ;; logior (not incf) so a stray duplicate is idempotent, never additively aliased into
  ;; a different flag bit. validate-regexp-flags rejects duplicates before we get here.
  (let ((b 0))
    (loop for c across flags do
      (setf b (logior b (case c (#\g +rf-g+) (#\i +rf-i+) (#\m +rf-m+) (#\s +rf-s+)
                          (#\u +rf-u+) (#\y +rf-y+) (#\d +rf-d+) (t 0)))))
    b))

(defun validate-regexp-flags (flags)
  "§22.2.3.4: the flags string may contain only d,g,i,m,s,u,y and no duplicates —
otherwise a SyntaxError. The literal path validates in the lexer; the RegExp()
constructor path reaches this. /v (and any other char) is rejected here (a loud gap)."
  (let ((seen 0))
    (loop for c across flags
          for bit = (case c (#\d +rf-d+) (#\g +rf-g+) (#\i +rf-i+) (#\m +rf-m+)
                          (#\s +rf-s+) (#\u +rf-u+) (#\y +rf-y+) (t nil))
          do (cond ((null bit)
                    (throw-syntax-error (format nil "Invalid flags supplied to RegExp constructor '~a'" flags)))
                   ((logtest seen bit)
                    (throw-syntax-error (format nil "Invalid flags supplied to RegExp constructor '~a'" flags)))
                   (t (setf seen (logior seen bit)))))))

(defun rf-set (re bit) (logtest (js-regexp-flag-bits re) bit))

;;; --- compile a pattern+flags into an immutable rx-compiled -------------------

(defun compile-regexp-literal (pattern flags)
  "Parse + translate PATTERN/FLAGS into an rx-compiled (scanner + metadata). Any
malformed pattern / unsupported gap surfaces as a JS SyntaxError."
  (validate-regexp-flags flags)
  (multiple-value-bind (ast ncap name-alist) (parse-js-regex pattern flags)
    (let ((tree (translate-regex ast ncap name-alist flags)))
      ;; /m and /s (dotall) are realized in the parse tree (JS LineTerminator set), not
      ;; via PPCRE's LF-only modes; only /i maps to a create-scanner mode. :single-line-mode
      ;; is ON unconditionally so :everything (which we emit ONLY for dotall `.` and [^],
      ;; never a bare PPCRE `.`) matches newline too; it affects nothing else we generate.
      (multiple-value-bind (scanner reg-names)
          (handler-case (pp:create-scanner tree :case-insensitive-mode (and (find #\i flags) t)
                                                :single-line-mode t)
            (error (e) (throw-syntax-error (format nil "Invalid regular expression: ~a" e))))
        (declare (ignore reg-names))
        (make-rx-compiled :source (escape-regexp-source pattern)
                          :flags flags :scanner scanner :name-alist name-alist
                          :group-count ncap :flag-bits (flags->bits flags))))))

(defun escape-regexp-source (pattern)
  "§22.2.3.2.5 EscapeRegExpPattern: return a source string S such that /S/ re-lexes to an
equivalent pattern — every unescaped '/' becomes '\\/' and LineTerminators become their
escapes. Empty pattern → \"(?:)\". Already-escaped pairs pass through verbatim."
  (if (zerop (length pattern))
      "(?:)"
      (with-output-to-string (o)
        (let ((i 0) (len (length pattern)))
          (loop while (< i len) do
            (let ((c (char pattern i)))
              (cond
                ((char= c #\\)                          ; keep the escaped pair verbatim
                 (write-char c o)
                 (when (< (1+ i) len) (write-char (char pattern (1+ i)) o))
                 (incf i 2))
                ((char= c #\/) (write-string "\\/" o) (incf i))
                ((char= c #\Newline) (write-string "\\n" o) (incf i))
                ((char= c #\Return) (write-string "\\r" o) (incf i))
                ((char= c (code-char #x2028)) (write-string "\\u2028" o) (incf i))
                ((char= c (code-char #x2029)) (write-string "\\u2029" o) (incf i))
                (t (write-char c o) (incf i)))))))))

(defun regexp-from-compiled (rxc &optional (prototype (intrinsic :regexp-prototype)))
  "A fresh js-regexp sharing RXC's immutable compiled data; lastIndex = 0."
  (let ((re (%make-js-regexp :proto prototype
                             :source (rxc-source rxc) :flags (rxc-flags rxc)
                             :scanner (rxc-scanner rxc) :name-alist (rxc-name-alist rxc)
                             :group-count (rxc-group-count rxc) :flag-bits (rxc-flag-bits rxc))))
    (obj-set-desc re "lastIndex" (data-pd 0d0 :writable t :enumerable nil :configurable nil))
    re))

(defun make-regexp (pattern flags &optional (prototype (intrinsic :regexp-prototype)))
  (regexp-from-compiled (compile-regexp-literal pattern flags) prototype))

;;; --- exec -------------------------------------------------------------------

(defun regexp-exec (re s)
  "ES RegExpBuiltinExec → a match array or +null+; advances lastIndex for g/y."
  (let* ((global (rf-set re +rf-g+)) (sticky (rf-set re +rf-y+))
         (li (if (or global sticky) (truncate (to-length (js-get re "lastIndex"))) 0))
         (len (length s)))
    (if (> li len)
        (progn (when (or global sticky) (js-set re "lastIndex" 0d0 t)) +null+)
        ;; :real-start-pos 0 — scan begins at LI but ^ / \b / lookbehind are evaluated
        ;; against the WHOLE string (absolute), not relative to LI. Without it every
        ;; g/y restart re-anchors ^/\b at LI (corrupting match/split/replace).
        (multiple-value-bind (ms me rs re-ends)
            (pp:scan (js-regexp-scanner re) s :start li :real-start-pos 0)
          (cond
            ((or (null ms) (and sticky (/= ms li)))
             (when (or global sticky) (js-set re "lastIndex" 0d0 t)) +null+)
            (t (when (or global sticky) (js-set re "lastIndex" (coerce me 'double-float) t))
               (build-match-result re s ms me rs re-ends)))))))

(defun build-match-result (re s ms me reg-starts reg-ends)
  (let* ((n (js-regexp-group-count re))
         (elts (list (subseq s ms me))))
    (dotimes (i n)
      (let ((rst (and reg-starts (aref reg-starts i))) (ren (and reg-ends (aref reg-ends i))))
        (push (if (and rst ren) (subseq s rst ren) +undefined+) elts)))
    (let ((arr (new-array (nreverse elts))))
      (data-prop arr "index" (coerce ms 'double-float))
      (data-prop arr "input" s)
      (data-prop arr "groups"
                 (if (js-regexp-name-alist re)
                     (let ((g (js-make-object +null+)))
                       (loop for (name . idx) in (js-regexp-name-alist re)
                             for rst = (and reg-starts (aref reg-starts (1- idx)))
                             for ren = (and reg-ends (aref reg-ends (1- idx)))
                             do (data-prop g name (if (and rst ren) (subseq s rst ren) +undefined+)))
                       g)
                     +undefined+))
      arr)))

;;; --- bootstrap: RegExp constructor + prototype ------------------------------

(defun this-regexp (this) (if (js-regexp-p this) this (throw-type-error "not a RegExp")))

(defun is-regexp (v)
  "§22.2.7.1 IsRegExp: if V[@@match] is not undefined, ToBoolean it; else V is a RegExp
iff it is a js-regexp exotic object. (So re[Symbol.match]=false makes IsRegExp false.)"
  (and (js-object-p v)
       (let ((m (js-get v (well-known :match))))
         (if (js-undefined-p m) (js-regexp-p v) (js-truthy m)))))

(defun %bootstrap-regexp ()
  (let ((rp (js-make-object (intrinsic :object-prototype) :object)))
    (setf (realm-intrinsic *realm* :regexp-prototype) rp)
    ;; exec / test / toString
    (install-method rp "exec" 1
      (lambda (this args) (regexp-exec (this-regexp this) (to-string (arg args 0)))))
    (install-method rp "test" 1
      (lambda (this args) (js-boolean (not (js-null-p (regexp-exec (this-regexp this) (to-string (arg args 0))))))))
    (install-method rp "toString" 0
      (lambda (this args) (declare (ignore args))
        (cond ((js-regexp-p this)
               (format nil "/~a/~a" (js-regexp-source this) (js-regexp-flags this)))
              ;; §22.2.6.13: R must be an Object; source/flags are read generically
              ;; (a plain object with those props stringifies too — not only RegExps).
              ((js-object-p this)
               (format nil "/~a/~a" (to-string (js-get this "source")) (to-string (js-get this "flags"))))
              (t (throw-type-error "RegExp.prototype.toString called on non-object")))))
    ;; getters
    (install-getter rp "source" (lambda (this args) (declare (ignore args))
                                  (if (js-regexp-p this) (js-regexp-source this)
                                      (if (eq this rp) "(?:)" (throw-type-error "not a RegExp")))))
    (flet ((flag-getter (bit) (lambda (this args) (declare (ignore args))
                                (if (js-regexp-p this) (js-boolean (rf-set this bit))
                                    (if (eq this rp) +undefined+ (throw-type-error "not a RegExp"))))))
      (install-getter rp "global" (flag-getter +rf-g+))
      (install-getter rp "ignoreCase" (flag-getter +rf-i+))
      (install-getter rp "multiline" (flag-getter +rf-m+))
      (install-getter rp "dotAll" (flag-getter +rf-s+))
      (install-getter rp "unicode" (flag-getter +rf-u+))
      (install-getter rp "sticky" (flag-getter +rf-y+))
      (install-getter rp "hasIndices" (flag-getter +rf-d+)))
    (install-getter rp "flags" (lambda (this args) (declare (ignore args))
                                 ;; recompose in canonical order d g i m s u y (spec)
                                 (if (js-object-p this)
                                     (with-output-to-string (o)
                                       (dolist (pair '(("hasIndices" . "d") ("global" . "g")
                                                       ("ignoreCase" . "i") ("multiline" . "m")
                                                       ("dotAll" . "s") ("unicode" . "u") ("sticky" . "y")))
                                         (when (js-truthy (js-get this (car pair))) (write-string (cdr pair) o))))
                                     (throw-type-error "not an object"))))
    ;; @@ methods
    (install-symbol-method rp (well-known :match) "[Symbol.match]" 1 #'regexp-@@match)
    (install-symbol-method rp (well-known :match-all) "[Symbol.matchAll]" 1 #'regexp-@@match-all)
    (install-symbol-method rp (well-known :search) "[Symbol.search]" 1 #'regexp-@@search)
    (install-symbol-method rp (well-known :replace) "[Symbol.replace]" 2 #'regexp-@@replace)
    (install-symbol-method rp (well-known :split) "[Symbol.split]" 2 #'regexp-@@split)
    ;; constructor
    (let ((ctor (make-constructor "RegExp" 2 (lambda (this args) (regexp-construct this args nil))
                                  :construct-fn (lambda (args nt)
                                                  (regexp-construct
                                                   nil args t (nt-prototype nt rp)))
                                  :prototype rp)))
      (setf (realm-intrinsic *realm* :regexp-constructor) ctor)
      (hidden-prop (realm-global *realm*) "RegExp" ctor))
    ;; expose the regexp/string well-known symbols as Symbol.* statics (only Symbol.iterator/
    ;; hasInstance/toPrimitive/toStringTag/asyncIterator were installed at %bootstrap-symbol;
    ;; without these the user-facing @@ protocol — obj[Symbol.replace] etc. — is unreachable).
    (let ((sym-ctor (intrinsic :symbol-constructor)))
      (when sym-ctor
        (loop for (js-name . key) in '(("match" . :match) ("matchAll" . :match-all)
                                       ("replace" . :replace) ("search" . :search)
                                       ("split" . :split) ("species" . :species))
              do (hidden-prop sym-ctor js-name (well-known key)))))
    ;; re-install String methods to delegate to the @@ methods
    (install-string-regex-methods)
    rp))

(defun install-symbol-method (obj sym name arity fn)
  (obj-set-desc obj sym (data-pd (make-native-function name arity fn)
                                 :writable t :enumerable nil :configurable t)))

(defun regexp-construct (this args newp &optional (prototype (intrinsic :regexp-prototype)))
  "RegExp(pattern, flags): copy a RegExp arg / override flags / compile strings. NEWP is
true for `new RegExp(...)`, nil for a plain `RegExp(...)` call."
  (declare (ignore this))
  (let ((pattern (arg args 0)) (flags (arg args 1)))
    (cond
      ;; §22.2.4.1 step 2.b: RegExp(re) called (not new) with undefined flags and
      ;; re.constructor === RegExp → return re unchanged (identity short-circuit). Gated on
      ;; IsRegExp (consults @@match), not js-regexp-p — re[Symbol.match]=false ⇒ new object.
      ((and (not newp) (is-regexp pattern) (js-undefined-p flags)
            (eq (js-get pattern "constructor") (intrinsic :regexp-constructor)))
       pattern)
      ((js-regexp-p pattern)
       (make-regexp (js-regexp-source pattern)
                    (if (js-undefined-p flags) (js-regexp-flags pattern) (to-string flags))
                    prototype))
      (t (make-regexp (if (js-undefined-p pattern) "" (to-string pattern))
                      (if (js-undefined-p flags) "" (to-string flags))
                      prototype)))))

;;; --- @@ methods -------------------------------------------------------------

(defun regexp-@@match (this args)
  (let ((re (this-regexp this)) (s (to-string (arg args 0))))
    (if (rf-set re +rf-g+)
        (progn (js-set re "lastIndex" 0d0 t)
               (let ((matches '()))
                 (loop (let ((r (regexp-exec re s)))
                         (when (js-null-p r) (return))
                         (let ((m0 (to-string (js-getv r "0"))))
                           (push m0 matches)
                           (when (zerop (length m0))       ; zero-width: bump lastIndex
                             (js-set re "lastIndex"
                                     (coerce (1+ (truncate (to-length (js-get re "lastIndex")))) 'double-float) t)))))
                 (if matches (new-array (nreverse matches)) +null+)))
        (regexp-exec re s))))

(defun regexp-@@search (this args)
  (let ((re (this-regexp this)) (s (to-string (arg args 0))))
    (multiple-value-bind (ms me) (pp:scan (js-regexp-scanner re) s :start 0)
      (declare (ignore me))
      (coerce (or ms -1) 'double-float))))

(defun regexp-@@match-all (this args)
  "Return a RegExpStringIterator (a fresh regex clone, global semantics)."
  (let* ((re (this-regexp this)) (s (to-string (arg args 0)))
         (clone (make-regexp (js-regexp-source re) (js-regexp-flags re)))
         (done nil))
    (js-set clone "lastIndex" (coerce (to-length (js-get re "lastIndex")) 'double-float) t)
    (let ((it (js-make-object (intrinsic :iterator-prototype) :object)))
      (flet ((mk (value doneb)
               (let ((res (js-make-object (intrinsic :object-prototype))))
                 (data-prop res "value" value) (data-prop res "done" (js-boolean doneb))
                 res)))
        (install-method it "next" 0
          (lambda (this2 args2) (declare (ignore this2 args2))
            (if done
                (mk +undefined+ t)
                (let ((m (regexp-exec clone s)))
                  (cond
                    ((js-null-p m) (setf done t) (mk +undefined+ t))
                    (t (unless (rf-set clone +rf-g+) (setf done t))  ; non-global: one result
                       (when (and (rf-set clone +rf-g+) (zerop (length (to-string (js-getv m "0")))))
                         (js-set clone "lastIndex"
                                 (coerce (1+ (truncate (to-length (js-get clone "lastIndex")))) 'double-float) t))
                       (mk m nil))))))))
      (obj-set-desc it (well-known :iterator)
                    (data-pd (make-native-function "[Symbol.iterator]" 0
                               (lambda (self a) (declare (ignore a)) self))
                             :writable t :enumerable nil :configurable t))
      it)))

(defun regexp-@@replace (this args)
  (let* ((re (this-regexp this)) (s (to-string (arg args 0)))
         (rep (arg args 1)) (fnp (callable-p rep))
         (rep-str (unless fnp (to-string rep)))
         (global (rf-set re +rf-g+))
         (out (make-string-output-stream)) (last-end 0))
    (when global (js-set re "lastIndex" 0d0 t))
    (block done
      (loop
        (let ((m (regexp-exec re s)))
          (when (js-null-p m) (return-from done))
          (let* ((matched (to-string (js-getv m "0")))
                 (pos (truncate (to-number (js-get m "index"))))
                 (ncap (js-regexp-group-count re)))
            (write-string (subseq s last-end pos) out)
            (if fnp
                (let ((cargs (list matched)))
                  (dotimes (i ncap) (setf cargs (cons (js-getv m (princ-to-string (1+ i))) cargs)))
                  (setf cargs (nreverse cargs))
                  ;; args: match, cap1..capN, offset, string, [groups if named] (§22.2.6.11)
                  (let ((tail (list (coerce pos 'double-float) s))
                        (groups (js-get m "groups")))
                    (unless (js-undefined-p groups) (setf tail (append tail (list groups))))
                    (write-string (to-string (js-call rep +undefined+ (append cargs tail))) out)))
                (write-string (%regexp-substitution matched s pos m ncap rep-str) out))
            (setf last-end (+ pos (length matched)))
            (unless global (return-from done))
            (when (zerop (length matched))
              (js-set re "lastIndex"
                      (coerce (1+ (truncate (to-length (js-get re "lastIndex")))) 'double-float) t))))))
    (write-string (subseq s last-end) out)
    (get-output-stream-string out)))

(defun %regexp-substitution (matched s position m ncap template)
  "Expand $$ $& $` $' $n $<name> in TEMPLATE for a match M."
  (with-output-to-string (o)
    (let ((i 0) (len (length template)))
      (loop while (< i len) do
        (let ((c (char template i)))
          (if (and (char= c #\$) (< (1+ i) len))
              (let ((d (char template (1+ i))))
                (cond
                  ((char= d #\$) (write-char #\$ o) (incf i 2))
                  ((char= d #\&) (write-string matched o) (incf i 2))
                  ((char= d #\`) (write-string (subseq s 0 position) o) (incf i 2))
                  ((char= d #\') (write-string (subseq s (+ position (length matched))) o) (incf i 2))
                  ((digit-char-p d)
                   ;; $n or $nn (1..ncap)
                   (let* ((two (and (< (+ i 2) len) (digit-char-p (char template (+ i 2)))))
                          (n2 (and two (+ (* 10 (digit-char-p d)) (digit-char-p (char template (+ i 2))))))
                          (n1 (digit-char-p d)))
                     (cond ((and n2 (<= 1 n2 ncap))
                            (write-string (%cap-str m n2) o) (incf i 3))
                           ((<= 1 n1 ncap) (write-string (%cap-str m n1) o) (incf i 2))
                           (t (write-char #\$ o) (incf i)))))
                  ((and (char= d #\<) (js-object-p (js-get m "groups")))
                   (let ((close (position #\> template :start (+ i 2))))
                     (if close
                         (let ((v (js-get (js-get m "groups") (subseq template (+ i 2) close))))
                           (unless (js-undefined-p v) (write-string (to-string v) o))
                           (setf i (1+ close)))
                         (progn (write-char #\$ o) (incf i)))))
                  (t (write-char #\$ o) (incf i))))
              (progn (write-char c o) (incf i))))))))

(defun %cap-str (m n)
  (let ((v (js-getv m (princ-to-string n)))) (if (js-undefined-p v) "" (to-string v))))

(defun regexp-@@split (this args)
  (let* ((re (this-regexp this)) (s (to-string (arg args 0)))
         (limit (let ((l (arg args 1))) (if (js-undefined-p l) most-positive-fixnum (truncate (to-uint32 l)))))
         (splitter (make-regexp (js-regexp-source re)
                                (let ((f (js-regexp-flags re))) (if (find #\y f) f (concatenate 'string f "y")))))
         (out '()) (last 0) (len (length s)))
    (when (zerop limit) (return-from regexp-@@split (new-array '())))
    (when (zerop len)
      (return-from regexp-@@split
        (if (js-null-p (regexp-exec splitter s)) (new-array (list "")) (new-array '()))))
    (let ((p 0))
      (loop while (< p len) do
        (js-set splitter "lastIndex" (coerce p 'double-float) t)
        (let ((m (regexp-exec splitter s)))
          (if (js-null-p m) (incf p)
              (let* ((e (truncate (to-number (js-get splitter "lastIndex")))))
                (if (= e last) (incf p)
                    (progn
                      (push (subseq s last p) out)
                      (when (>= (length out) limit) (return-from regexp-@@split (new-array (nreverse out))))
                      ;; captured groups become split elements
                      (dotimes (i (js-regexp-group-count re))
                        (push (js-getv m (princ-to-string (1+ i))) out)
                        (when (>= (length out) limit) (return-from regexp-@@split (new-array (nreverse out)))))
                      (setf last e p e)))))))
      (push (subseq s last) out)
      (new-array (nreverse out)))))

;;; --- String.prototype delegation --------------------------------------------

(defun install-string-regex-methods ()
  (let ((sp (intrinsic :string-prototype)))
    (flet ((coerce-rx (arg extra-flags)
             (if (js-regexp-p arg) arg
                 (make-regexp (if (js-undefined-p arg) "" (to-string arg)) (or extra-flags "")))))
      ;; match / matchAll / search: delegate to the @@ method
      (install-method sp "match" 1
        (lambda (this args)
          (require-object-coercible this)
          (let* ((s (to-string this)) (arg (arg args 0)))
            ;; §22.1.3.*: the @@ method is looked up ONLY when the arg is an Object — a
            ;; primitive search value must NOT trigger its (inherited) @@ getter.
            (let ((m (and (js-object-p arg) (get-method arg (well-known :match)))))
              (if (callable-p m) (js-call m arg (list s))
                  (js-call (get-method (coerce-rx arg nil) (well-known :match)) (coerce-rx arg nil) (list s)))))))
      (install-method sp "matchAll" 1
        (lambda (this args)
          (require-object-coercible this)
          (let* ((s (to-string this)) (arg (arg args 0)))
            (when (and (js-regexp-p arg) (not (rf-set arg +rf-g+)))
              (throw-type-error "String.prototype.matchAll called with a non-global RegExp"))
            (let ((m (and (js-object-p arg) (get-method arg (well-known :match-all)))))
              (if (callable-p m) (js-call m arg (list s))
                  (js-call (get-method (coerce-rx arg "g") (well-known :match-all)) (coerce-rx arg "g") (list s)))))))
      (install-method sp "search" 1
        (lambda (this args)
          (require-object-coercible this)
          (let* ((s (to-string this)) (arg (arg args 0)))
            (let ((m (and (js-object-p arg) (get-method arg (well-known :search)))))
              (if (callable-p m) (js-call m arg (list s))
                  (js-call (get-method (coerce-rx arg nil) (well-known :search)) (coerce-rx arg nil) (list s)))))))
      ;; replace / replaceAll / split: delegate when the arg carries the @@ method,
      ;; else fall back to the existing string-search implementation
      (install-method sp "replace" 2
        (lambda (this args)
          (require-object-coercible this)
          (let ((sv (arg args 0)) (rv (arg args 1)))
            (let ((m (and (js-object-p sv) (get-method sv (well-known :replace)))))
              (if (callable-p m) (js-call m sv (list (to-string this) rv))
                  (%string-replace this sv rv nil))))))
      (install-method sp "replaceAll" 2
        (lambda (this args)
          (require-object-coercible this)
          (let ((sv (arg args 0)) (rv (arg args 1)))
            (when (and (js-regexp-p sv) (not (rf-set sv +rf-g+)))
              (throw-type-error "String.prototype.replaceAll called with a non-global RegExp"))
            (let ((m (and (js-object-p sv) (get-method sv (well-known :replace)))))
              (if (callable-p m) (js-call m sv (list (to-string this) rv))
                  (%string-replace this sv rv t))))))
      (install-method sp "split" 2
        (lambda (this args)
          (require-object-coercible this)
          (let ((sep (arg args 0)) (lim (arg args 1)))
            (let ((m (and (js-object-p sep) (get-method sep (well-known :split)))))
              (if (callable-p m)
                  (js-call m sep (list (to-string this) lim))
                  ;; string path (§22.1.3.23): ToString(this) [3], ToUint32(limit) [6],
                  ;; ToString(separator) [7] — ALWAYS, and BEFORE the lim=0 check [8].
                  ;; This full coercion ORDER is observable (test262 split/limit-touint32-
                  ;; error, …-valueof-throws, separator-tostring-error).
                  (let* ((s (to-string this))
                         (limit (if (js-undefined-p lim) most-positive-fixnum
                                    (truncate (to-uint32 lim))))
                         (rsep (to-string sep)))          ; step 7: unconditional
                    (cond ((zerop limit) (new-array '()))          ; [8] lim = 0 → []
                          ((js-undefined-p sep) (new-array (list s))) ; [9] undefined sep → [S]
                          (t (%string-split s rsep limit))))))))))))
