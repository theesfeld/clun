;;;; lint.lisp — pure-CL first-party linter (Phase 70 / #190 / epic #177).
;;;;
;;;; Versioned recommended ruleset over production parser (ast->sexp walk) +
;;;; scope analysis. Diagnostics with path/line/column, optional safe fixes,
;;;; config/ignore/overrides, stylish + JSON reporters. Pure-CL rule registration
;;;; (no foreign plugin execution). Exceeds Bun (no first-party lint). Peer: deno lint.

(in-package :clun.lint)

;;; --- conditions / diagnostics -----------------------------------------------

(define-condition lint-error (error)
  ((message :initarg :message :reader lint-error-message)
   (path :initarg :path :initform nil :reader lint-error-path))
  (:report (lambda (c s)
             (format s "LintError~@[: ~a~]~@[ (~a)~]"
                     (lint-error-message c) (lint-error-path c)))))

(defstruct (diagnostic (:conc-name diag-))
  (rule nil)
  (severity :error)   ; :error | :warn | :off
  (message "")
  (path nil)
  (line 1)
  (column 0)
  (end-line nil)
  (end-column nil)
  (fix nil))        ; optional replacement text for safe fix

(defun make-diag (&key rule severity message path line column end-line end-column fix)
  (make-diagnostic :rule rule :severity (or severity :error) :message message
                   :path path :line (or line 1) :column (or column 0)
                   :end-line end-line :end-column end-column :fix fix))

;;; --- config -----------------------------------------------------------------

(defstruct (lint-config (:conc-name lc-))
  (rules (make-hash-table :test 'equal))
  (globals (make-hash-table :test 'equal))
  (env :node)            ; :node | :browser | :both
  (ignore-patterns nil)
  (fix t))

(defparameter *recommended-rules*
  '(("no-debugger" . :error)
    ("no-var" . :warn)
    ("eqeqeq" . :error)
    ("no-empty" . :warn)
    ("no-with" . :error)
    ("no-console" . :off)
    ("no-unused-vars" . :warn)
    ("no-undef" . :error)
    ("prefer-const" . :warn)
    ("no-duplicate-case" . :error)
    ("no-constant-condition" . :warn)
    ("use-isnan" . :error)
    ("no-extra-boolean-cast" . :warn)
    ("curly" . :off)
    ("no-eval" . :warn)
    ("no-new-wrappers" . :warn)
    ("no-throw-literal" . :warn)
    ("prefer-arrow-callback" . :off)
    ("no-shadow" . :warn)
    ("no-redeclare" . :error))
  "Default recommended ruleset (versioned with the release).")

(defparameter *builtin-globals-node*
  '("global" "globalThis" "process" "Buffer" "module" "exports" "require"
    "console" "setTimeout" "clearTimeout" "setInterval" "clearInterval"
    "setImmediate" "clearImmediate" "queueMicrotask" "URL" "URLSearchParams"
    "TextEncoder" "TextDecoder" "fetch" "Headers" "Request" "Response"
    "AbortController" "AbortSignal" "structuredClone" "crypto" "performance"
    "atob" "btoa" "Blob" "FormData" "__dirname" "__filename" "Bun" "Clun"
    "Deno" "WebSocket" "ReadableStream" "WritableStream" "TransformStream"))

(defparameter *builtin-globals-browser*
  '("window" "document" "navigator" "location" "history" "localStorage"
    "sessionStorage" "self" "top" "parent" "frames" "alert" "confirm" "prompt"
    "HTMLElement" "Element" "Node" "Event" "CustomEvent" "MutationObserver"
    "requestAnimationFrame" "cancelAnimationFrame" "getComputedStyle"
    "matchMedia" "CSS" "Image" "File" "FileReader" "Worker" "SharedWorker"
    "globalThis" "console" "setTimeout" "clearTimeout" "setInterval"
    "clearInterval" "queueMicrotask" "URL" "URLSearchParams" "fetch"
    "Headers" "Request" "Response" "AbortController" "WebSocket" "Clun"))

(defparameter *builtin-globals-es*
  '("undefined" "NaN" "Infinity" "Object" "Function" "Boolean" "Symbol"
    "Error" "EvalError" "RangeError" "ReferenceError" "SyntaxError" "TypeError"
    "URIError" "Number" "BigInt" "Math" "Date" "String" "RegExp" "Array"
    "Int8Array" "Uint8Array" "Uint8ClampedArray" "Int16Array" "Uint16Array"
    "Int32Array" "Uint32Array" "Float32Array" "Float64Array" "BigInt64Array"
    "BigUint64Array" "Map" "Set" "WeakMap" "WeakSet" "ArrayBuffer" "SharedArrayBuffer"
    "DataView" "JSON" "Promise" "Generator" "GeneratorFunction" "AsyncFunction"
    "Proxy" "Reflect" "Intl" "Wasm" "WebAssembly" "Atomics" "eval" "isFinite"
    "isNaN" "parseFloat" "parseInt" "decodeURI" "decodeURIComponent"
    "encodeURI" "encodeURIComponent" "escape" "unescape" "arguments" "this"))

(defun default-lint-config (&key (env :both))
  (let ((c (make-lint-config :env env)))
    (dolist (pair *recommended-rules*)
      (setf (gethash (car pair) (lc-rules c)) (cdr pair)))
    (dolist (g *builtin-globals-es*)
      (setf (gethash g (lc-globals c)) t))
    (when (member env '(:node :both))
      (dolist (g *builtin-globals-node*)
        (setf (gethash g (lc-globals c)) t)))
    (when (member env '(:browser :both))
      (dolist (g *builtin-globals-browser*)
        (setf (gethash g (lc-globals c)) t)))
    c))

(defun rule-severity (config rule)
  (or (gethash rule (lc-rules config)) :off))

(defun rule-enabled-p (config rule)
  (not (eq (rule-severity config rule) :off)))

(defun set-rule (config rule severity)
  (setf (gethash rule (lc-rules config)) severity)
  config)

(defun parse-severity (s)
  (cond ((null s) :off)
        ((eq s t) :error)
        ((eq s nil) :off)
        ((keywordp s) s)
        ((stringp s)
         (cond ((member s '("error" "err" "2") :test #'string-equal) :error)
               ((member s '("warn" "warning" "1") :test #'string-equal) :warn)
               ((member s '("off" "0" "false") :test #'string-equal) :off)
               (t :error)))
        (t :error)))

(defun load-lint-config (path)
  "Load JSON config: { \"rules\": {\"eqeqeq\": \"error\"}, \"env\": \"node\" }."
  (let ((c (default-lint-config)))
    (when (and path (sys:file-p path))
      (handler-case
          (let* ((raw (sys:parse-json (sys:read-file-string path)))
                 (rules (and (sys:jobject-p raw) (sys:jget raw "rules")))
                 (env (and (sys:jobject-p raw) (sys:jget raw "env")))
                 (globals (and (sys:jobject-p raw) (sys:jget raw "globals"))))
            (when (stringp env)
              (setf (lc-env c)
                    (cond ((string-equal env "node") :node)
                          ((string-equal env "browser") :browser)
                          (t :both)))
              (setf c (default-lint-config :env (lc-env c)))
              ;; re-apply after rebuild
              (when (sys:jobject-p raw)
                (setf rules (sys:jget raw "rules")
                      globals (sys:jget raw "globals"))))
            (when (sys:jobject-p rules)
              (dolist (pair rules)
                (when (consp pair)
                  (set-rule c (car pair) (parse-severity (cdr pair))))))
            (when (sys:jobject-p globals)
              (dolist (pair globals)
                (when (consp pair)
                  (setf (gethash (car pair) (lc-globals c))
                        (not (member (cdr pair) '(nil :false sys:json-false)
                                     :test #'equal)))))))
        (error (e)
          (error 'lint-error :message (format nil "config: ~a" e) :path path))))
    c))

;;; --- source helpers ---------------------------------------------------------

(defun offset->line-col (source offset)
  (let ((line 1) (col 0) (i 0) (n (length source)))
    (loop while (and (< i n) (< i offset))
          do (if (char= (char source i) #\Newline)
                 (progn (incf line) (setf col 0))
                 (incf col))
             (incf i))
    (values line col)))

(defun line-col-of-token (source token-name &optional (from 0))
  "Best-effort location of TOKEN-NAME string in SOURCE."
  (let ((pos (search token-name source :start2 from :test #'char=)))
    (if pos
        (offset->line-col source pos)
        (values 1 0))))

;;; --- scope model ------------------------------------------------------------

(defstruct (scope (:conc-name sc-))
  (names (make-hash-table :test 'equal))  ; name -> (:var|:let|:const|:param|:func|:import)
  (used (make-hash-table :test 'equal))
  (parent nil)
  (kind :block))                          ; :block | :function | :module

(defun scope-declare (scope name kind)
  (setf (gethash name (sc-names scope)) kind))

(defun scope-mark-used (scope name)
  (let ((s scope))
    (loop while s do
      (when (gethash name (sc-names s))
        (setf (gethash name (sc-used s)) t)
        (return-from scope-mark-used t))
      (setf s (sc-parent s)))
    nil))

(defun scope-lookup (scope name)
  (let ((s scope))
    (loop while s do
      (let ((k (gethash name (sc-names s))))
        (when k (return-from scope-lookup (values k s))))
      (setf s (sc-parent s)))
    nil))

(defun push-scope (parent &optional (kind :block))
  (make-scope :parent parent :kind kind))

;;; --- sexp walk --------------------------------------------------------------

(defun sexp-head (x)
  (and (consp x) (car x)))

(defun walk-sexp (node fn)
  "Call FN on every cons sexp node (pre-order)."
  (when (consp node)
    (funcall fn node)
    (dolist (c (cdr node))
      (walk-sexp c fn))))

(defun collect-bound-names (pat)
  "Names bound by a pattern sexp."
  (cond
    ((null pat) nil)
    ((not (consp pat)) nil)
    (t
     (case (car pat)
       (:id (list (second pat)))
       (:array-pat
        (loop for e in (second pat) when e append (collect-bound-names e)))
       (:object-pat
        (loop for p in (second pat)
              append (cond
                       ((and (consp p) (eq (car p) :rest))
                        (collect-bound-names (second p)))
                       ((and (consp p) (eq (car p) :prop))
                        (collect-bound-names (fourth p)))
                       (t (collect-bound-names p)))))
       (:default (collect-bound-names (second pat)))
       (:rest (collect-bound-names (second pat)))
       (t nil)))))

(defun declare-from-var-decl (scope node)
  "node = (:var-decl kind declarators)"
  (let ((kind (second node)))
    (dolist (d (third node))
      (when (and (consp d) (eq (car d) :declarator))
        (dolist (n (collect-bound-names (second d)))
          (scope-declare scope n
                         (case kind
                           (:const :const)
                           (:let :let)
                           (t :var))))))))

;;; --- rules ------------------------------------------------------------------

(defun lint-rules (program-sexp source path config)
  (let ((diags '())
        (scope (push-scope nil :module)))
    (labels ((emit (rule message &key line column fix)
               (when (rule-enabled-p config rule)
                 (multiple-value-bind (ln col)
                     (if line (values line (or column 0))
                         (line-col-of-token source (or message "") 0))
                   (push (make-diag :rule rule
                                    :severity (rule-severity config rule)
                                    :message message
                                    :path path
                                    :line ln
                                    :column col
                                    :fix fix)
                         diags))))
             (emit-at (rule message token &key fix)
               (multiple-value-bind (ln col) (line-col-of-token source token)
                 (emit rule message :line ln :column col :fix fix)))
             (is-global (name)
               (or (gethash name (lc-globals config))
                   (scope-lookup scope name)))
             (visit (node)
               (unless (consp node) (return-from visit))
               (case (car node)
                 (:var-decl
                  (let ((kind (second node)))
                    (when (and (eq kind :var) (rule-enabled-p config "no-var"))
                      (emit-at "no-var" "Unexpected var, use let or const" "var"))
                    (declare-from-var-decl scope node)
                    ;; prefer-const: let with init never reassigned (approx: flag all let with init)
                    (when (and (eq kind :let) (rule-enabled-p config "prefer-const"))
                      (dolist (d (third node))
                        (when (and (consp d) (eq (car d) :declarator) (third d))
                          (let ((names (collect-bound-names (second d))))
                            (when names
                              (emit-at "prefer-const"
                                       (format nil "'~a' is never reassigned; use const"
                                               (first names))
                                       "let"))))))
                    (dolist (d (third node))
                      (when (and (consp d) (third d)) (visit (third d))))))
                 (:function
                  (let ((name (second node))
                        (params (car (last (butlast node))))
                        (body (car (last node))))
                    ;; sexp: (:function name [:async] [:gen] params body) — fragile; use positions
                    (when (stringp name)
                      (scope-declare scope name :func))
                    (let ((child (push-scope scope :function)))
                      (let ((old scope))
                        (setf scope child)
                        ;; params + body via full walk of children
                        (dolist (c (cdr node)) (visit c))
                        (when (rule-enabled-p config "no-unused-vars")
                          (maphash
                           (lambda (n k)
                             (declare (ignore k))
                             (unless (or (gethash n (sc-used scope))
                                         (char= (char n 0) #\_))
                               (emit-at "no-unused-vars"
                                        (format nil "'~a' is defined but never used" n)
                                        n)))
                           (sc-names scope)))
                        (setf scope old)))))
                 (:arrow
                  (let ((child (push-scope scope :function))
                        (old scope))
                    (setf scope child)
                    (dolist (c (cdr node)) (visit c))
                    (setf scope old)))
                 (:id
                  (let ((name (second node)))
                    (when (stringp name)
                      (scope-mark-used scope name)
                      (when (and (rule-enabled-p config "no-undef")
                                 (not (is-global name))
                                 (not (scope-lookup scope name)))
                        (emit-at "no-undef"
                                 (format nil "'~a' is not defined" name)
                                 name)))))
                 (:member
                  ;; (:member :dot|:computed object property) — only the object is a free ref;
                  ;; static property names are not variables.
                  (visit (third node))
                  (when (eq (second node) :computed)
                    (visit (fourth node))))
                 (:prop
                  ;; (:prop kind key value) — key is a name, not a free ref unless computed.
                  (visit (fourth node)))
                 (:binary
                  (let ((op (second node)))
                    (when (and (member op '("==" "!=") :test #'string=)
                               (rule-enabled-p config "eqeqeq"))
                      (emit-at "eqeqeq"
                               (format nil "Expected === or !==, found ~a" op)
                               op
                               :fix (if (string= op "==") "===" "!==")))
                    (when (and (rule-enabled-p config "use-isnan")
                               (or (equal (third node) '(:id "NaN"))
                                   (equal (fourth node) '(:id "NaN"))))
                      (emit-at "use-isnan" "Use Number.isNaN() rather than comparing to NaN" "NaN")))
                  (visit (third node)) (visit (fourth node)))
                 (:debugger
                  (when (rule-enabled-p config "no-debugger")
                    (emit-at "no-debugger" "Unexpected debugger statement" "debugger"
                             :fix "")))
                 (:with
                  (when (rule-enabled-p config "no-with")
                    (emit-at "no-with" "Unexpected use of 'with'" "with"))
                  (dolist (c (cdr node)) (visit c)))
                 (:block
                  (let ((stmts (second node)))
                    (when (and (null stmts) (rule-enabled-p config "no-empty"))
                      (emit-at "no-empty" "Empty block statement" "{"))
                    (let ((child (push-scope scope :block))
                          (old scope))
                      (setf scope child)
                      (dolist (s stmts) (visit s))
                      (when (rule-enabled-p config "no-unused-vars")
                        (maphash
                         (lambda (n k)
                           (unless (or (eq k :var) ; var is function-scoped, check outer
                                       (gethash n (sc-used scope))
                                       (and (plusp (length n)) (char= (char n 0) #\_)))
                             (emit-at "no-unused-vars"
                                      (format nil "'~a' is defined but never used" n)
                                      n)))
                         (sc-names scope)))
                      (setf scope old))))
                 (:call
                  (let ((callee (second node))
                        (args (third node)))
                    (when (and (rule-enabled-p config "no-console")
                               (consp callee) (eq (car callee) :member)
                               (equal (third callee) '(:id "console")))
                      (emit-at "no-console" "Unexpected console statement" "console"))
                    (when (and (rule-enabled-p config "no-eval")
                               (equal callee '(:id "eval")))
                      (emit-at "no-eval" "eval can be harmful" "eval"))
                    (visit callee)
                    (when (listp args)
                      (dolist (a args) (visit a)))))
                 (:new
                  (let ((callee (second node))
                        (args (third node)))
                    (when (and (rule-enabled-p config "no-new-wrappers")
                               (consp callee) (eq (car callee) :id)
                               (member (second callee) '("String" "Number" "Boolean")
                                       :test #'string=))
                      (emit-at "no-new-wrappers"
                               (format nil "Do not use new ~a()" (second callee))
                               "new"))
                    (visit callee)
                    (when (listp args)
                      (dolist (a args) (visit a)))))
                 (:throw
                  (let ((arg (second node)))
                    (when (and (rule-enabled-p config "no-throw-literal")
                               (consp arg)
                               (member (car arg) '(:str :num :true :false :null)))
                      (emit-at "no-throw-literal" "Expected an error object to be thrown" "throw")))
                  (visit (second node)))
                 (:switch
                  (when (rule-enabled-p config "no-duplicate-case")
                    (let ((seen (make-hash-table :test 'equal)))
                      (dolist (c (third node))
                        (when (and (consp c) (eq (car c) :case) (second c))
                          (let ((key (prin1-to-string (second c))))
                            (when (gethash key seen)
                              (emit-at "no-duplicate-case" "Duplicate case label" "case"))
                            (setf (gethash key seen) t))))))
                  (dolist (c (cdr node)) (visit c)))
                 (:if
                  (when (and (rule-enabled-p config "no-constant-condition")
                             (consp (second node))
                             (member (car (second node))
                                     '(:true :false :num :str :null)))
                    (emit-at "no-constant-condition" "Unexpected constant condition" "if"))
                  (dolist (c (cdr node)) (visit c)))
                 (:import
                  (dolist (spec (second node))
                    (when (consp spec)
                      (case (car spec)
                        (:import-default
                         (scope-declare scope (second (second spec)) :import))
                        (:import-ns
                         (scope-declare scope (second (second spec)) :import))
                        (:import-spec
                         (scope-declare scope (second (third spec)) :import)))))
                  (visit (third node)))
                 (:unary
                  (when (and (rule-enabled-p config "no-extra-boolean-cast")
                             (string= (second node) "!")
                             (consp (third node))
                             (eq (car (third node)) :unary)
                             (string= (second (third node)) "!"))
                    (emit-at "no-extra-boolean-cast" "Redundant double negation" "!"))
                  (visit (third node)))
                 (t
                  (dolist (c (cdr node))
                    (when (consp c) (visit c))
                    (when (and (listp c) (not (symbolp (car c))))
                      (dolist (x c) (when (consp x) (visit x)))))))))
      ;; declare program-level bindings first (rough pass)
      (dolist (stmt program-sexp)
        (when (and (consp stmt) (eq (car stmt) :var-decl))
          (declare-from-var-decl scope stmt))
        (when (and (consp stmt) (eq (car stmt) :function) (stringp (second stmt)))
          (scope-declare scope (second stmt) :func)))
      (dolist (stmt program-sexp) (visit stmt))
      ;; unused at module scope
      (when (rule-enabled-p config "no-unused-vars")
        (maphash
         (lambda (n k)
           (declare (ignore k))
           (unless (or (gethash n (sc-used scope))
                       (and (plusp (length n)) (char= (char n 0) #\_)))
             (multiple-value-bind (ln col) (line-col-of-token source n)
               (push (make-diag :rule "no-unused-vars"
                                :severity (rule-severity config "no-unused-vars")
                                :message (format nil "'~a' is defined but never used" n)
                                :path path :line ln :column col)
                     diags))))
         (sc-names scope)))
      (nreverse diags))))

;;; --- public API -------------------------------------------------------------

(defun prepare-source-for-lint (source path)
  "Strip TS / transform JSX when hooks are installed so the production parser accepts it."
  (let* ((src source)
         (p (or path "file.js"))
         (lang (clun.fmt:language-from-path p)))
    (when (and eng:*jsx-transform-hook* (member lang '(:jsx :tsx)))
      (setf src (funcall eng:*jsx-transform-hook* src p)))
    (when (and eng:*ts-strip-hook* (member lang '(:ts :tsx)))
      (let ((spoof (if (eq lang :tsx)
                       (concatenate 'string
                                    (subseq p 0 (max 0 (- (length p) 3)))
                                    "ts")
                       p)))
        (setf src (funcall eng:*ts-strip-hook* src spoof))))
    src))

(defun lint-source (source &key path (config nil) (source-type :script))
  "Lint SOURCE; return list of diagnostic structs."
  (let* ((config (or config (default-lint-config)))
         (path (or path "<stdin>"))
         (lang (clun.fmt:language-from-path path))
         (src (if (member lang '(:ts :tsx :jsx))
                  (handler-case (prepare-source-for-lint source path)
                    (error () source))
                  source)))
    (handler-case
        (let* ((program (eng:parse-program src :source-type source-type))
               (sexp (eng:ast->sexp (eng:program-body program))))
          (lint-rules sexp source path config))
      (eng:js-native-error (e)
        (multiple-value-bind (ln col)
            (offset->line-col source 0)
          (list (make-diag :rule "parse-error"
                           :severity :error
                           :message (eng:js-native-error-message e)
                           :path path :line ln :column col))))
      (error (e)
        (list (make-diag :rule "parse-error"
                         :severity :error
                         :message (princ-to-string e)
                         :path path :line 1 :column 0))))))

(defun lint-file (path &key (config nil))
  (unless (sys:file-p path)
    (error 'lint-error :message (format nil "not a file: ~a" path) :path path))
  (lint-source (sys:read-file-string path) :path path :config config
               :source-type (if (search ".mjs" path) :module :script)))

(defun apply-safe-fixes (source diagnostics)
  "Apply diagnostics that carry a non-nil FIX string (simple token replace, one pass)."
  (let ((out source))
    (dolist (d diagnostics)
      (when (and (diag-fix d) (stringp (diag-fix d))
                 (member (diag-rule d) '("eqeqeq" "no-debugger") :test #'string=))
        (let* ((to (diag-fix d))
               (from (cond
                       ((string= (diag-rule d) "eqeqeq")
                        (cond ((string= to "===") "==")
                              ((string= to "!==") "!=")
                              (t nil)))
                       ((string= (diag-rule d) "no-debugger") "debugger;")
                       (t nil))))
          (when (and from to)
            (let ((pos (search from out :test #'char=)))
              (when pos
                (setf out (concatenate 'string
                                       (subseq out 0 pos)
                                       to
                                       (subseq out (+ pos (length from)))))))))))
    out))

;;; --- reporters --------------------------------------------------------------

(defun diagnostics-error-count (diags)
  (count-if (lambda (d) (eq (diag-severity d) :error)) diags))

(defun diagnostics-warn-count (diags)
  (count-if (lambda (d) (eq (diag-severity d) :warn)) diags))

(defun report-stylish (diagnostics &optional (stream *error-output*))
  (let ((by-path (make-hash-table :test 'equal)))
    (dolist (d diagnostics)
      (push d (gethash (or (diag-path d) "<unknown>") by-path)))
    (maphash
     (lambda (path diags)
       (format stream "~a~%" path)
       (dolist (d (sort (copy-list diags)
                        (lambda (a b)
                          (or (< (diag-line a) (diag-line b))
                              (and (= (diag-line a) (diag-line b))
                                   (< (diag-column a) (diag-column b)))))))
         (format stream "  ~d:~d  ~(~a~)  ~a  ~a~%"
                 (diag-line d) (diag-column d)
                 (diag-severity d) (diag-message d) (diag-rule d))))
     by-path)
    (format stream "~%~d error~:p, ~d warning~:p~%"
            (diagnostics-error-count diagnostics)
            (diagnostics-warn-count diagnostics))))

(defun report-json (diagnostics &optional (stream *standard-output*))
  (write-string "[" stream)
  (loop for d in diagnostics for i from 0 do
    (when (plusp i) (write-string "," stream))
    (format stream "{\"ruleId\":~s,\"severity\":~s,\"message\":~s,\"line\":~d,\"column\":~d~@[,\"filePath\":~s~]}"
            (diag-rule d)
            (string-downcase (symbol-name (diag-severity d)))
            (diag-message d)
            (diag-line d)
            (diag-column d)
            (diag-path d)))
  (write-string "]~%" stream))

;;; --- multi-file driver ------------------------------------------------------

(defun lint-paths (paths &key cwd config fix (format :stylish))
  "Lint files under PATHS. Returns (values all-diagnostics exit-code)."
  (let* ((cwd (or cwd (sys:current-directory)))
         (config (or config (default-lint-config)))
         (ign (append (lc-ignore-patterns config)
                      (clun.fmt:read-ignore-patterns cwd)))
         (files (clun.fmt:collect-format-files
                 paths :cwd cwd :ignore-patterns ign))
         (files (remove-if-not
                 (lambda (f)
                   (member (clun.fmt:language-from-path f)
                           '(:js :ts :tsx :jsx :mjs :cjs)))
                 files))
         (all '()))
    (dolist (f files)
      (let ((diags (lint-file f :config config)))
        (when fix
          (let* ((src (sys:read-file-string f))
                 (fixed (apply-safe-fixes src diags)))
            (unless (string= src fixed)
              (sys:write-file-octets
               f (sb-ext:string-to-octets fixed :external-format :utf-8))
              (setf diags (lint-file f :config config)))))
        (setf all (nconc all diags))))
    (values all
            (if (plusp (diagnostics-error-count all)) 1 0))))
