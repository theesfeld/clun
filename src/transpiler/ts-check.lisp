;;;; ts-check.lisp — pure-CL structural TypeScript typecheck surface (Issue #192).
;;;; Exceeds Bun (no typecheck) with a practical single-file checker: literal vs
;;;; annotation mismatches, undeclared identifiers (JS/TS ambient globals), and
;;;; excess properties on object-literal assignments to simple object types.
;;;; Not a full tsc substitute; ships as `clun tsc` for usability beyond Bun strip.

(in-package :clun.transpiler)

(defstruct (ts-diag (:conc-name tsd-))
  (message "" :type string)
  (line 1 :type fixnum)
  (col 1 :type fixnum)
  (path nil)
  (severity :error))

(defparameter *ts-ambient-globals*
  '("undefined" "NaN" "Infinity" "console" "process" "Clun" "Bun" "globalThis"
    "global" "window" "document" "module" "exports" "require" "Object" "Array"
    "String" "Number" "Boolean" "Symbol" "BigInt" "Function" "Error" "TypeError"
    "RangeError" "SyntaxError" "ReferenceError" "URIError" "EvalError" "Date"
    "Math" "JSON" "RegExp" "Map" "Set" "WeakMap" "WeakSet" "Promise" "Proxy"
    "Reflect" "ArrayBuffer" "DataView" "Int8Array" "Uint8Array" "Uint8ClampedArray"
    "Int16Array" "Uint16Array" "Int32Array" "Uint32Array" "Float32Array"
    "Float64Array" "BigInt64Array" "BigUint64Array" "parseInt" "parseFloat"
    "isNaN" "isFinite" "encodeURI" "decodeURI" "encodeURIComponent"
    "decodeURIComponent" "eval" "setTimeout" "clearTimeout" "setInterval"
    "clearInterval" "queueMicrotask" "structuredClone" "atob" "btoa"
    "fetch" "Response" "Request" "Headers" "URL" "URLSearchParams" "Buffer"
    "TextEncoder" "TextDecoder" "AbortController" "AbortSignal" "Event"
    "EventTarget" "MessageChannel" "MessagePort" "performance" "crypto"
    "navigator" "location" "localStorage" "sessionStorage" "FormData" "Blob"
    "File" "FileReader" "ReadableStream" "WritableStream" "TransformStream"
    "ByteLengthQueuingStrategy" "CountQueuingStrategy" "DOMException"
    "AggregateError" "WeakRef" "FinalizationRegistry" "SharedArrayBuffer"
    "Atomics" "WebAssembly" "reportError" "true" "false" "null" "this"
    "arguments" "super")
  "Ambient identifiers / builtins so single-file check stays quiet on host APIs.")

(defparameter *ts-keywords*
  '("typeof" "void" "delete" "in" "instanceof" "yield" "await" "async" "of"
    "from" "as" "satisfies" "get" "set" "static" "public" "private" "protected"
    "readonly" "override" "abstract" "declare" "enum" "namespace" "module"
    "interface" "type" "implements" "extends" "keyof" "infer" "is" "asserts"
    "out" "unique" "never" "unknown" "any" "object" "string" "number" "boolean"
    "bigint" "symbol" "function" "class" "const" "let" "var" "import" "export"
    "default" "return" "if" "else" "for" "while" "do" "switch" "case" "break"
    "continue" "try" "catch" "finally" "throw" "with" "debugger" "new")
  "Keywords that are never free-variable references.")

(defun %diag (path tok message)
  (make-ts-diag :message message
                :line (if tok (eng:token-line tok) 1)
                :col (if tok (1+ (eng:token-col tok)) 1)
                :path path
                :severity :error))

(defun %type-atom (s)
  (let ((t0 (string-trim '(#\Space #\Tab #\Newline #\Return) s)))
    (cond ((member t0 '("number" "Number") :test #'string=) :number)
          ((member t0 '("string" "String") :test #'string=) :string)
          ((member t0 '("boolean" "Boolean") :test #'string=) :boolean)
          ((member t0 '("bigint" "BigInt") :test #'string=) :bigint)
          ((string= t0 "null") :null)
          ((member t0 '("undefined" "void") :test #'string=) :undefined)
          ((member t0 '("any" "unknown") :test #'string=) :any)
          (t :other))))

(defun %lit-kind (tok)
  (when tok
    (case (eng:token-type tok)
      (:num :number)
      (:bigint :bigint)
      (:string :string)
      (:name (let ((v (eng:token-value tok)))
               (cond ((or (string= v "true") (string= v "false")) :boolean)
                     ((string= v "null") :null)
                     ((string= v "undefined") :undefined)
                     (t nil))))
      (t nil))))

(defun %slice-type (src toks start end)
  (if (>= start end)
      ""
      (subseq src
              (eng:token-start (aref toks start))
              (eng:token-end (aref toks (1- end))))))

(defun %obj-keys-from-type (type-text)
  (let ((keys '())
        (i 0)
        (n (length type-text)))
    (loop while (< i n) do
      (let ((c (char type-text i)))
        (if (or (alpha-char-p c) (char= c #\_) (char= c #\$))
            (let ((j i))
              (loop while (and (< j n)
                               (let ((ch (char type-text j)))
                                 (or (alphanumericp ch)
                                     (char= ch #\_)
                                     (char= ch #\$))))
                    do (incf j))
              (let ((name (subseq type-text i j))
                    (k j))
                (loop while (and (< k n)
                                 (member (char type-text k)
                                         '(#\Space #\Tab #\?)))
                      do (incf k))
                (when (and (< k n) (char= (char type-text k) #\:))
                  (push name keys))
                (setf i j)))
            (incf i))))
    (nreverse keys)))

(defun %obj-lit-keys (toks i end)
  (unless (tpunct= toks i "{")
    (return-from %obj-lit-keys (cons nil i)))
  (let ((keys '())
        (depth 0)
        (j i))
    (loop while (< j end) do
      (cond
        ((tpunct= toks j "{")
         (incf depth)
         (incf j))
        ((tpunct= toks j "}")
         (decf depth)
         (incf j)
         (when (zerop depth) (return)))
        ((and (= depth 1)
              (or (eq (ttype toks j) :name) (eq (ttype toks j) :string))
              (or (tpunct= toks (1+ j) ":")
                  (tpunct= toks (1+ j) ",")
                  (tpunct= toks (1+ j) "}")))
         (push (if (eq (ttype toks j) :string)
                   (eng:token-value (aref toks j))
                   (tval toks j))
               keys)
         (incf j))
        (t (incf j))))
    (cons (nreverse keys) j)))

(defun %check-var-init (src toks i n path diags declared)
  (let ((j (1+ i)))
    (when (eq (ttype toks j) :name)
      (setf (gethash (tval toks j) declared) t)
      (incf j)
      (when (tpunct= toks j ":")
        (let* ((ty-start (1+ j))
               (ty-end (skip-type toks ty-start))
               (ty-text (%slice-type src toks ty-start ty-end))
               (atom (%type-atom ty-text)))
          (setf j ty-end)
          (when (tpunct= toks j "=")
            (incf j)
            (when (< j n)
              (let ((lit (%lit-kind (aref toks j))))
                (when (and lit
                           atom
                           (not (eq atom :any))
                           (not (eq atom :other))
                           (not (eq lit atom)))
                  (push (%diag path (aref toks j)
                               (format nil "Type '~(~a~)' is not assignable to type '~a'"
                                       lit
                                       (string-trim '(#\Space) ty-text)))
                        diags)))
              (let ((trimmed (string-trim '(#\Space #\Tab #\Newline) ty-text)))
                (when (and (tpunct= toks j "{")
                           (plusp (length trimmed))
                           (char= (char trimmed 0) #\{))
                  (let ((want (%obj-keys-from-type ty-text))
                        (got (car (%obj-lit-keys toks j n))))
                    (dolist (k got)
                      (unless (member k want :test #'string=)
                        (push (%diag path (aref toks j)
                                     (format nil "Object literal may only specify known properties; '~a' does not exist on type"
                                             k))
                              diags)))))))))))
    (values (1+ i) diags)))

(defun %collect-import-bindings (toks i n declared)
  (let ((j (1+ i)))
    (cond
      ((and (eq (ttype toks j) :name) (tpunct= toks (1+ j) "="))
       (setf (gethash (tval toks j) declared) t))
      ((eq (ttype toks j) :name)
       (setf (gethash (tval toks j) declared) t))
      ((tpunct= toks j "{")
       (incf j)
       (loop while (and (< j n) (not (tpunct= toks j "}"))) do
         (when (and (eq (ttype toks j) :name)
                    (not (tname= toks j "type")))
           (if (and (tname= toks (1+ j) "as")
                    (eq (ttype toks (+ j 2)) :name))
               (progn
                 (setf (gethash (tval toks (+ j 2)) declared) t)
                 (incf j 3))
               (progn
                 (setf (gethash (tval toks j) declared) t)
                 (incf j))))
         (when (tpunct= toks j ",") (incf j)))))))

(defun %free-ident-p (toks i declared ambient keywords)
  (and (eq (ttype toks i) :name)
       (not (eng:token-escaped (aref toks i)))
       (not (gethash (tval toks i) declared))
       (not (gethash (tval toks i) ambient))
       (not (gethash (tval toks i) keywords))
       (not (and (> i 0) (tpunct= toks (1- i) ".")))
       (not (tpunct= toks (1+ i) ":"))
       (not (and (> i 0) (tname= toks (1- i) "import")))
       (not (and (> i 0) (tname= toks (1- i) "export")))
       (not (and (> i 0) (tname= toks (1- i) "function")))
       (not (and (> i 0) (tname= toks (1- i) "class")))
       (not (and (> i 0) (tname= toks (1- i) "const")))
       (not (and (> i 0) (tname= toks (1- i) "let")))
       (not (and (> i 0) (tname= toks (1- i) "var")))
       (not (and (> i 0) (tname= toks (1- i) "enum")))
       (not (and (> i 0) (tname= toks (1- i) "namespace")))
       (not (and (> i 0) (tname= toks (1- i) "interface")))
       (not (and (> i 0) (tname= toks (1- i) "type")))
       (not (and (> i 0) (tname= toks (1- i) "as")))
       (not (and (> i 0) (tpunct= toks (1- i) "@")))))

(defun typecheck-source (source path)
  "Return a list of TS-DIAG for SOURCE at PATH. Empty list = clean."
  (let* ((toks (tokenize source path))
         (n (length toks))
         (diags '())
         (declared (make-hash-table :test #'equal))
         (ambient (make-hash-table :test #'equal))
         (keywords (make-hash-table :test #'equal)))
    (dolist (g *ts-ambient-globals*) (setf (gethash g ambient) t))
    (dolist (k *ts-keywords*) (setf (gethash k keywords) t))
    (loop for i from 0 below n do
      (cond
        ((and (or (tname= toks i "const") (tname= toks i "let") (tname= toks i "var"))
              (eq (ttype toks (1+ i)) :name)
              (not (and (tname= toks i "const") (tname= toks (1+ i) "enum"))))
         (setf (gethash (tval toks (1+ i)) declared) t))
        ((and (tname= toks i "function") (eq (ttype toks (1+ i)) :name))
         (setf (gethash (tval toks (1+ i)) declared) t))
        ((and (tname= toks i "class") (eq (ttype toks (1+ i)) :name))
         (setf (gethash (tval toks (1+ i)) declared) t))
        ((and (tname= toks i "const") (tname= toks (1+ i) "enum")
              (eq (ttype toks (+ i 2)) :name))
         (setf (gethash (tval toks (+ i 2)) declared) t))
        ((and (tname= toks i "enum") (eq (ttype toks (1+ i)) :name))
         (setf (gethash (tval toks (1+ i)) declared) t))
        ((and (or (tname= toks i "namespace") (tname= toks i "module"))
              (eq (ttype toks (1+ i)) :name))
         (setf (gethash (tval toks (1+ i)) declared) t))
        ((tname= toks i "import")
         (%collect-import-bindings toks i n declared))))
    (let ((i 0))
      (loop while (< i n) do
        (cond
          ((or (tname= toks i "const") (tname= toks i "let") (tname= toks i "var"))
           (multiple-value-bind (ni nd)
               (%check-var-init source toks i n path diags declared)
             (setf i ni
                   diags nd)))
          ((%free-ident-p toks i declared ambient keywords)
           (push (%diag path (aref toks i)
                        (format nil "Cannot find name '~a'" (tval toks i)))
                 diags)
           (incf i))
          (t (incf i)))))
    (nreverse diags)))

(defun format-diag (d)
  (format nil "~@[~a~]:~a:~a - error TSClun: ~a"
          (tsd-path d) (tsd-line d) (tsd-col d) (tsd-message d)))

(defun typecheck-file (path)
  (let* ((src (sys:read-file-string path))
         (diags (typecheck-source src path)))
    (values diags (if diags 1 0))))

(defun typecheck-paths (paths &key (stream *error-output*))
  (let ((code 0)
        (count 0))
    (dolist (p paths)
      (multiple-value-bind (diags ec) (typecheck-file p)
        (dolist (d diags)
          (format stream "~a~%" (format-diag d))
          (incf count))
        (when (plusp ec) (setf code 1))))
    (when (plusp count)
      (format stream "Found ~a error~:p.~%" count))
    code))
