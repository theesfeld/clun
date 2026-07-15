;;;; Deterministic Phase 25b test262 execution-gap analyzer.
;;;;
;;;; Run with SBCL --script.  This file deliberately has no dependency on ASDF,
;;;; Clun, UIOP, or scripts/test262.lisp: loading the runner would execute the
;;;; entire corpus as a side effect.

(defpackage :clun-test262-buckets
  (:use :cl))

(in-package :clun-test262-buckets)

(defparameter *allowed-classifications* '("pass" "fail" "skip" "crash"))

;; Keep this list byte-for-byte in semantic sync with *skip-features* and the
;; additions in *exec-skip* in scripts/test262.lisp.
(defparameter *exec-skip-features*
  '("class-fields-public" "class-fields-private" "class-methods-private"
    "class-static-methods-private" "class-static-fields-public"
    "class-static-fields-private" "class-static-block" "decorators"
    "top-level-await" "dynamic-import" "import-assertions" "import-attributes"
    "import-defer" "source-phase-imports" "source-phase-imports-module-source"
    "numeric-separator-literal" "logical-assignment-operators"
    "optional-chaining" "coalesce-expression" "explicit-resource-management"
    "regexp-v-flag" "import-meta" "hashbang" "regexp-modifiers"
    "regexp-duplicate-named-groups" "arbitrary-module-namespace-names"
    "Proxy" "Reflect" "SharedArrayBuffer" "Atomics" "object-spread"
    "object-rest" "iterator-helpers" "tail-call-optimization" "IsHTMLDDA"
    "cross-realm" "Array.prototype.flat" "Array.prototype.flatMap"
    "String.prototype.replaceAll" "resizable-arraybuffer"
    "regexp-unicode-property-escapes" "regexp-match-indices"))

(defparameter *work-buckets*
  '("binding-patterns"
    "dynamic-scope-eval"
    "async-iteration"
    "async-generators"
    "generators"
    "classes"
    "binary-data"
    "regexp"
    "iterator-protocol"
    "promises"
    "collections"
    "arrays"
    "objects"
    "functions-arguments"
    "operators-references"
    "primitive-builtins"
    "other-runtime"))

(defparameter *primitive-builtin-roots*
  '("String" "Number" "Math" "Date" "JSON" "Symbol" "Error" "Boolean"
    "Infinity" "NaN" "undefined" "decodeURI" "decodeURIComponent"
    "encodeURI" "encodeURIComponent" "isFinite" "isNaN" "parseFloat"
    "parseInt" "global"))

(defparameter *phase-37-features*
  '("Array.fromAsync" "Error.isError" "FinalizationRegistry" "Float16Array"
    "Math.sumPrecise" "Object.hasOwn" "RegExp.escape"
    "String.prototype.isWellFormed" "String.prototype.toWellFormed" "Temporal"
    "WeakRef" "align-detached-buffer-semantics-with-web-reality"
    "array-grouping" "await-dictionary" "change-array-by-copy"
    "class-fields-private" "class-fields-public" "error-stack-accessor"
    "immutable-arraybuffer" "json-parse-with-source" "promise-try"
    "promise-with-resolvers" "set-methods" "symbols-as-weakmap-keys" "upsert"))

(defparameter *phase-37-paths*
  '("expressions/class/cpn-class-expr-accessors-computed-property-name-from-expression-coalesce.js"
    "expressions/class/cpn-class-expr-computed-property-name-from-expression-coalesce.js"
    "expressions/object/cpn-obj-lit-computed-property-name-from-expression-coalesce.js"
    "statements/class/cpn-class-decl-accessors-computed-property-name-from-expression-coalesce.js"
    "statements/class/cpn-class-decl-computed-property-name-from-expression-coalesce.js"
    "expressions/class/cpn-class-expr-accessors-computed-property-name-from-integer-separators.js"
    "expressions/class/cpn-class-expr-computed-property-name-from-integer-separators.js"
    "expressions/object/cpn-obj-lit-computed-property-name-from-integer-separators.js"
    "statements/class/cpn-class-decl-accessors-computed-property-name-from-integer-separators.js"
    "statements/class/cpn-class-decl-computed-property-name-from-integer-separators.js"
    ;; These two older tests use Proxy without declaring the Proxy feature. Proxy is
    ;; explicitly Phase 37 work; ownership changes do not skip them or alter the denominator.
    "built-ins/Object/seal/seal-proxy.js"
    "built-ins/Object/seal/throws-when-false.js"))

(defparameter *top-count-limit* 25)

(defstruct metadata
  (features '() :type list)
  (flags '() :type list)
  (includes '() :type list)
  (runner-features '() :type list)
  (runner-flags '() :type list)
  (negative-parse-p nil))

(defstruct row
  (path "" :type string)
  (classification "" :type string)
  source-path
  metadata
  (owner "" :type string)
  (phase-owner "" :type string)
  (work-bucket "" :type string)
  (topic "" :type string))

(defun script-directory ()
  (make-pathname :name nil :type nil
                 :defaults (or *load-truename*
                               (error "cannot determine the script pathname"))))

(defparameter *repo-root*
  (truename (merge-pathnames "../" (script-directory))))

(defparameter *language-root*
  (truename (merge-pathnames "vendor-data/test262/test/language/" *repo-root*)))

(defparameter *builtins-root*
  (truename (merge-pathnames "vendor-data/test262/test/built-ins/" *repo-root*)))

(defparameter *vendor-commit-path*
  (merge-pathnames "vendor-data/test262/COMMIT" *repo-root*))

(defun starts-with-p (prefix string &key (test #'char=))
  (and (<= (length prefix) (length string))
       (loop for i below (length prefix)
             always (funcall test (char prefix i) (char string i)))))

(defun contains-p (needle haystack &key (test #'char=))
  (not (null (search needle haystack :test test))))

(defun split-on-char (string separator)
  "Split STRING at every SEPARATOR, retaining empty fields."
  (loop with start = 0
        for end = (position separator string :start start)
        collect (subseq string start end)
        while end
        do (setf start (1+ end))))

(defun join-strings (strings separator)
  (with-output-to-string (out)
    (loop for string in strings
          for first = t then nil
          unless first do (write-string separator out)
          do (write-string string out))))

(defun first-n (items count)
  (loop for item in items
        repeat count
        collect item))

(defun trim-line (string)
  (string-trim '(#\Space #\Tab #\Newline #\Return) string))

(defun string-member-p (item items)
  (not (null (member item items :test #'string=))))

(defun any-string-member-p (needles items)
  (some (lambda (needle) (string-member-p needle items)) needles))

(defun any-prefix-p (prefix strings)
  (some (lambda (string) (starts-with-p prefix string)) strings))

(defun any-contains-p (needle strings &key (test #'char=))
  (some (lambda (string) (contains-p needle string :test test)) strings))

(defun read-file-octets (path)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((bytes (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (unless (= (read-sequence bytes in) (length bytes))
        (error "short read from ~a" path))
      bytes)))

(defun octets-as-code-unit-string (octets)
  "Map octets one-for-one to characters; test262 frontmatter is ASCII."
  (map 'string (lambda (octet)
                 (or (code-char octet)
                     (error "implementation has no character for octet ~d" octet)))
       octets))

(defun read-source (path)
  (octets-as-code-unit-string (read-file-octets path)))

(defun read-one-line (path)
  (with-open-file (in path :external-format :utf-8)
    (let ((line (read-line in nil nil)))
      (unless line
        (error "~a is empty" path))
      (when (read-line in nil nil)
        (error "~a must contain exactly one line" path))
      (trim-line line))))

;;; Frontmatter parsing intentionally mirrors scripts/test262.lisp.

(defun frontmatter (source)
  (let ((start (search "/*---" source))
        (end (search "---*/" source)))
    (when (and start end (< start end))
      (subseq source (+ start 5) end))))

(defun frontmatter-list (frontmatter key)
  (let ((key-position (and frontmatter (search key frontmatter))))
    (when key-position
      (let* ((left (position #\[ frontmatter :start key-position))
             (right (and left (position #\] frontmatter :start left))))
        (when (and left right)
          (loop for token in (split-on-char
                              (subseq frontmatter (1+ left) right) #\,)
                for trimmed = (trim-line token)
                unless (string= trimmed "")
                  collect trimmed))))))

(defun full-frontmatter-list (frontmatter key)
  "Read a test262 YAML list in either flow ([a, b]) or block (- a) form."
  (when frontmatter
    (let* ((lines (split-on-char frontmatter #\Newline))
           (line-index
             (position-if
              (lambda (line)
                (and (plusp (length line))
                     (not (member (char line 0) '(#\Space #\Tab)))
                     (starts-with-p key line)))
              lines)))
      (when line-index
        (let* ((line (nth line-index lines))
               (remainder (trim-line (subseq line (length key)))))
          (cond
            ((starts-with-p "[" remainder)
             (let* ((flow (join-strings (subseq lines line-index) (string #\Newline)))
                    (left (position #\[ flow))
                    (right (and left (position #\] flow :start left))))
               (unless right
                 (error "unterminated inline frontmatter list for ~a" key))
               (loop for token in (split-on-char (subseq flow (1+ left) right) #\,)
                     for trimmed = (trim-line token)
                     unless (string= trimmed "") collect trimmed)))
            ((string= remainder "")
             (loop for item in (subseq lines (1+ line-index))
                   for trimmed = (trim-line item)
                   if (starts-with-p "- " trimmed)
                     collect (trim-line (subseq trimmed 2))
                   else if (string= trimmed "")
                     do (progn)
                   else
                     do (loop-finish)))
            (t nil)))))))

(defun negative-parse-p (frontmatter)
  (let ((negative (and frontmatter (search "negative:" frontmatter))))
    (and negative
         (not (null (search "phase: parse" frontmatter :start2 negative))))))

(defun parse-metadata (source)
  (let ((fm (frontmatter source)))
    (make-metadata :features (full-frontmatter-list fm "features:")
                   :flags (full-frontmatter-list fm "flags:")
                   :includes (full-frontmatter-list fm "includes:")
                   :runner-features (frontmatter-list fm "features:")
                   :runner-flags (frontmatter-list fm "flags:")
                   :negative-parse-p (not (null (negative-parse-p fm))))))

(defun static-skip-reason (metadata)
  "Return the first current execution-runner static skip reason, or NIL."
  (cond
    ((metadata-negative-parse-p metadata) "negative parse test")
    ((find-if (lambda (feature)
                (string-member-p feature *exec-skip-features*))
              (metadata-runner-features metadata))
     (format nil "unsupported feature ~a"
             (find-if (lambda (feature)
                        (string-member-p feature *exec-skip-features*))
                      (metadata-runner-features metadata))))
    ((string-member-p "module" (metadata-runner-flags metadata)) "module flag")
    ((string-member-p "raw" (metadata-runner-flags metadata)) "raw flag")
    (t nil)))

;;; Ledger and path validation.

(defun parse-ledger-line (line line-number)
  (let ((tab (position #\Tab line)))
    (unless tab
      (error "ledger line ~d is not PATH<TAB>CLASSIFICATION" line-number))
    (when (position #\Tab line :start (1+ tab))
      (error "ledger line ~d has more than two TSV fields" line-number))
    (let ((path (subseq line 0 tab))
          (classification (subseq line (1+ tab))))
      (when (zerop (length path))
        (error "ledger line ~d has an empty path" line-number))
      (unless (string-member-p classification *allowed-classifications*)
        (error "ledger line ~d has unknown classification ~s"
               line-number classification))
      (values path classification))))

(defun validate-next-path (previous path line-number)
  (when previous
    (cond
      ((string= previous path)
       (error "duplicate ledger path ~s at line ~d" path line-number))
      ((not (string< previous path))
       (error "ledger paths are not sorted at line ~d: ~s follows ~s"
              line-number path previous))))
  path)

(defun safe-relative-path-p (path)
  (and (plusp (length path))
       (not (char= (char path 0) #\/))
       (not (position #\\ path))
       (not (position #\Tab path))
       (not (position #\Newline path))
       (not (position #\Return path))
       (not (position #\* path))
       (not (position #\? path))
       (let ((parts (split-on-char path #\/)))
         (and (every #'plusp (mapcar #'length parts))
              (notany (lambda (part)
                        (or (string= part ".") (string= part "..")))
                      parts)))))

(defun pathname-below-root-p (path root)
  (starts-with-p (namestring root) (namestring path)))

(defun resolve-test-path (path)
  (unless (safe-relative-path-p path)
    (error "unsafe or non-canonical test262 path ~s" path))
  (unless (and (> (length path) 3)
               (string= ".js" (subseq path (- (length path) 3))))
    (error "test262 path does not name a .js file: ~s" path))
  (when (contains-p "_FIXTURE" path)
    (error "runner-excluded fixture appears in ledger: ~s" path))
  (let* ((builtin-p (starts-with-p "built-ins/" path))
         (relative (if builtin-p (subseq path (length "built-ins/")) path))
         (root (if builtin-p *builtins-root* *language-root*))
         (candidate (merge-pathnames relative root))
         (existing (probe-file candidate)))
    (unless existing
      (error "ledger path does not resolve to vendored test262: ~s" path))
    (let ((resolved (truename existing)))
      (unless (pathname-below-root-p resolved root)
        (error "ledger path escapes vendored test262: ~s" path))
      resolved)))

(defun runner-corpus-paths-below (root prefix)
  "Return the runner spellings for every non-fixture .js file below ROOT."
  (let ((root-name (namestring root)))
    (loop for path in (directory (merge-pathnames "**/*.js" root))
          for full = (namestring path)
          unless (contains-p "_FIXTURE" full)
            collect
            (progn
              (unless (starts-with-p root-name full)
                (error "test262 corpus path escapes its root: ~a" path))
              (concatenate 'string prefix (subseq full (length root-name)))))))

(defun runner-corpus-paths ()
  "Enumerate the exact execution corpus and normalize it like runner REL-NAME."
  (sort (append (runner-corpus-paths-below *language-root* "")
                (runner-corpus-paths-below *builtins-root* "built-ins/"))
        #'string<))

(defun validate-exact-corpus-paths (actual expected)
  "Require sorted ACTUAL ledger paths to equal sorted EXPECTED corpus paths."
  (loop
    (cond
      ((and (null actual) (null expected)) (return t))
      ((null actual)
       (error "classification ledger is missing corpus path ~s" (first expected)))
      ((null expected)
       (error "classification ledger has unexpected corpus path ~s" (first actual)))
      ((string= (first actual) (first expected))
       (setf actual (rest actual) expected (rest expected)))
      ((string< (first actual) (first expected))
       (error "classification ledger has unexpected corpus path ~s" (first actual)))
      (t
       (error "classification ledger is missing corpus path ~s" (first expected))))))

(defun validate-static-skip-classification (path classification skip-reason)
  "Require the ledger's skip class to match the runner's static decision exactly."
  (cond
    ((and (string= classification "skip") (null skip-reason))
     (error "ledger classifies non-skippable path ~s as skip" path))
    ((and (not (string= classification "skip")) skip-reason)
     (error "ledger classifies statically skippable path ~s as ~a (~a)"
            path classification skip-reason)))
  t)

;;; Ownership, topic, and mutually exclusive work-bucket mapping.

(defun path-parts-without-file (path)
  (butlast (split-on-char path #\/)))

(defun path-owner (path)
  (let ((parts (split-on-char path #\/)))
    (if (string= (first parts) "built-ins")
        (progn
          (unless (second parts)
            (error "malformed built-ins path ~s" path))
          (format nil "builtin:~a" (second parts)))
        (format nil "language:~a" (first parts)))))

(defun path-topic (path)
  (let ((directories (path-parts-without-file path)))
    (if (string= (first directories) "built-ins")
        (let ((count (if (and (third directories)
                              (string= (third directories) "prototype"))
                         4
                         3)))
          (join-strings (first-n directories count) "/"))
        (join-strings (first-n (cons "language" directories) 3) "/"))))

(defun builtin-root (path)
  (let ((parts (split-on-char path #\/)))
    (and (string= (first parts) "built-ins") (second parts))))

(defun path-component-p (path component)
  (string-member-p component (split-on-char path #\/)))

(defun metadata-feature-p (metadata feature)
  (string-member-p feature (metadata-features metadata)))

(defun any-metadata-feature-p (metadata features)
  (any-string-member-p features (metadata-features metadata)))

(defun phase-owner-for (path metadata)
  (if (or (intersection (metadata-features metadata) *phase-37-features*
                        :test #'string=)
          (string-member-p path *phase-37-paths*))
      "phase-37"
      "phase-25b"))

(defun bucket-for (path metadata)
  "Return the first matching Phase 25b work bucket.  Order is contractual."
  (let* ((lower (string-downcase path))
         (root (builtin-root path))
         (features (metadata-features metadata))
         (includes (metadata-includes metadata)))
    (cond
      ((or (any-metadata-feature-p
            metadata
            '("destructuring-binding" "destructuring-assignment"
              "default-parameters"))
           (contains-p "/dstr/" lower)
           (contains-p "/destructuring/" lower))
       "binding-patterns")
      ((or (starts-with-p "eval-code/direct/" path)
           (starts-with-p "statements/with/" path))
       "dynamic-scope-eval")
      ((or (metadata-feature-p metadata "async-iteration")
           (path-component-p path "for-await-of")
           (starts-with-p "built-ins/Array/fromAsync/" path)
           (and root (string= root "AsyncFromSyncIteratorPrototype")))
       "async-iteration")
      ((or (contains-p "async-generator" lower)
           (contains-p "asyncgenerator" lower))
       "async-generators")
      ((or (metadata-feature-p metadata "generators")
           (contains-p "generator" lower))
       "generators")
      ((or (path-component-p path "class")
           (path-component-p path "super")
           (starts-with-p "computed-property-names/class/" path))
       "classes")
      ((or (and root
                (or (starts-with-p "TypedArray" root)
                    (string-member-p root '("ArrayBuffer" "DataView" "BigInt"))))
           (any-metadata-feature-p
            metadata '("TypedArray" "ArrayBuffer" "BigInt" "Float16Array"
                       "align-detached-buffer-semantics-with-web-reality"
                       "immutable-arraybuffer" "arraybuffer-transfer"))
           (any-string-member-p
            '("testTypedArray.js" "detachArrayBuffer.js" "byteConversionValues.js")
            includes))
       "binary-data")
      ((or (and root (string= root "RegExp"))
           (starts-with-p "literals/regexp/" path)
           (any-prefix-p "regexp-" features)
           (any-metadata-feature-p
            metadata '("Symbol.match" "Symbol.matchAll" "Symbol.replace"
                       "Symbol.search" "Symbol.split"))
           (any-string-member-p '("regExpUtils.js") includes))
       "regexp")
      ((or (any-metadata-feature-p
            metadata '("Symbol.iterator" "Symbol.asyncIterator"))
           (contains-p "iterator" lower)
           (any-string-member-p '("compareIterator.js") includes))
       "iterator-protocol")
      ((or (and root (string= root "Promise"))
           (any-contains-p "promise" features :test #'char-equal))
       "promises")
      ((and root (string-member-p root '("Map" "Set" "WeakMap" "WeakSet")))
       "collections")
      ((or (and root (string= root "Array"))
           (some (lambda (feature)
                   (let ((name (string-downcase feature)))
                     (or (starts-with-p "array." name)
                         (starts-with-p "array-" name)
                         (starts-with-p "change-array" name))))
                 features))
       "arrays")
      ((or (and root (string= root "Object"))
           (starts-with-p "expressions/object/" path)
           (any-prefix-p "Object." features))
       "objects")
      ((or (and root
                (string-member-p root
                                 '("Function" "AsyncFunction" "GeneratorFunction")))
           (starts-with-p "arguments-object/" path)
           (starts-with-p "function-code/" path)
           (some (lambda (component)
                   (path-component-p path component))
                 '("function" "arrow-function" "async-function" "call"
                   "new.target" "rest-parameters"))
           (any-metadata-feature-p
            metadata '("arrow-function" "async-functions")))
       "functions-arguments")
      ((or (some (lambda (component)
                   (path-component-p path component))
                 '("assignment" "compound-assignment" "prefix-increment"
                   "postfix-increment" "prefix-decrement" "postfix-decrement"
                   "delete" "property-accessors" "reference" "tagged-template"
                   "template-literal"))
           (starts-with-p "types/reference/" path)
           (starts-with-p "identifier-resolution/" path))
       "operators-references")
      ((and root (string-member-p root *primitive-builtin-roots*))
       "primitive-builtins")
      (t "other-runtime"))))

;;; Deterministic provenance and count tables.

(defconstant +fnv1a-64-offset+ #xcbf29ce484222325)
(defconstant +fnv1a-64-prime+ #x100000001b3)
(defconstant +uint64-mask+ #xffffffffffffffff)

(defun fnv1a-64-octets (octets)
  (loop with hash = +fnv1a-64-offset+
        for octet across octets
        do (setf hash (logand +uint64-mask+
                              (* (logxor hash octet) +fnv1a-64-prime+)))
        finally (return hash)))

(defun fnv1a-64-file (path)
  (fnv1a-64-octets (read-file-octets path)))

(defun fnv1a-64-string (string)
  (fnv1a-64-octets
   (map 'vector (lambda (character)
                  (let ((code (char-code character)))
                    (unless (< code 256)
                      (error "self-test FNV input is not an octet string"))
                    code))
        string)))

(defun digest-string (digest)
  (format nil "~16,'0x" digest))

(defun increment-count (table key)
  (incf (gethash key table 0)))

(defun sorted-counts (table)
  (sort (loop for key being the hash-keys of table using (hash-value count)
              collect (cons key count))
        (lambda (left right)
          (or (> (cdr left) (cdr right))
              (and (= (cdr left) (cdr right))
                   (string< (car left) (car right)))))))

(defun markdown-code (string)
  (with-output-to-string (out)
    (write-char #\` out)
    (loop for character across string
          do (when (char= character #\`) (write-char #\\ out))
             (write-char character out))
    (write-char #\` out)))

(defun validate-provenance-text (label text)
  (when (or (zerop (length text))
            (position #\Newline text)
            (position #\Return text))
    (error "~a must be non-empty, single-line text" label))
  text)

(defun load-ledger (ledger-path)
  (let ((rows '())
        (previous nil)
        (crash-count 0))
    (with-open-file (in ledger-path :external-format :utf-8)
      (loop for line = (read-line in nil nil)
            for line-number from 1
            while line
            do (multiple-value-bind (path classification)
                   (parse-ledger-line line line-number)
                 (validate-next-path previous path line-number)
                 (setf previous path)
                 (let* ((source-path (resolve-test-path path))
                        (metadata (parse-metadata (read-source source-path)))
                        (skip-reason (static-skip-reason metadata)))
                   (validate-static-skip-classification
                    path classification skip-reason)
                   (when (string= classification "crash")
                     (incf crash-count))
                   (push (make-row :path path
                                   :classification classification
                                   :source-path source-path
                                   :metadata metadata
                                   :owner (path-owner path)
                                   :phase-owner (phase-owner-for path metadata)
                                   :work-bucket (bucket-for path metadata)
                                   :topic (path-topic path))
                         rows)))))
    (when (zerop (length rows))
      (error "classification ledger is empty"))
    (when (plusp crash-count)
      (error "classification ledger contains ~d crash~:p; required count is zero"
             crash-count))
    (let ((ordered (nreverse rows)))
      (validate-exact-corpus-paths
       (mapcar #'row-path ordered) (runner-corpus-paths))
      ordered)))

(defun passlist-entry-ledger-path (entry)
  "Map the runner's pass-list spelling to its execution-ledger spelling.

Built-in paths retain their built-ins/ prefix. Language paths are already
relative to vendor-data/test262/test/language, exactly as rel-name writes them."
  (if (starts-with-p "built-ins/" entry)
      entry
      entry))

(defun passlist-entries-from-lines (lines &key resolve-files)
  "Parse canonical pass-list LINES and return sorted ledger path spellings."
  (let ((entries '())
        (previous nil))
    (loop for line in lines
          for line-number from 1
          for trimmed = (trim-line line)
          unless (or (string= trimmed "")
                     (char= (char trimmed 0) #\#))
            do (unless (string= line trimmed)
                 (error "pass-list entry at line ~d has non-canonical whitespace"
                        line-number))
               (unless (safe-relative-path-p trimmed)
                 (error "unsafe or non-canonical pass-list path ~s at line ~d"
                        trimmed line-number))
               (when previous
                 (cond
                   ((string= previous trimmed)
                    (error "duplicate pass-list path ~s at line ~d"
                           trimmed line-number))
                   ((not (string< previous trimmed))
                    (error "pass-list paths are not sorted at line ~d: ~s follows ~s"
                           line-number trimmed previous))))
               (setf previous trimmed)
               (when resolve-files
                 ;; resolve-test-path also enforces the built-ins-vs-language map.
                 (resolve-test-path trimmed))
               (push (passlist-entry-ledger-path trimmed) entries))
    (when (null entries)
      (error "execution pass-list has no entries"))
    (nreverse entries)))

(defun load-passlist (passlist-path)
  (with-open-file (in passlist-path :external-format :utf-8)
    (passlist-entries-from-lines
     (loop for line = (read-line in nil nil)
           while line collect line)
     :resolve-files t)))

(defun validate-passlist-against-ledger (entries rows)
  "Require every frozen pass-list entry to occur exactly once as a current pass."
  (let ((ledger (make-hash-table :test #'equal)))
    (dolist (row rows)
      (when (nth-value 1 (gethash (row-path row) ledger))
        (error "duplicate ledger path while validating pass-list: ~s"
               (row-path row)))
      (setf (gethash (row-path row) ledger) row))
    (dolist (entry entries)
      (multiple-value-bind (row present-p) (gethash entry ledger)
        (unless present-p
          (error "frozen pass-list path is absent from classification ledger: ~s"
                 entry))
        (unless (string= (row-classification row) "pass")
          (error "frozen pass-list path is classified ~a instead of pass: ~s"
                 (row-classification row) entry))))
    (length entries)))

(defun stable-repo-input-name (path label)
  (let ((resolved (truename path)))
    (unless (pathname-below-root-p resolved *repo-root*)
      (error "~a must resolve below the repository root: ~a" label path))
    (subseq (namestring resolved) (length (namestring *repo-root*)))))

(defun provenance-lines (ledger-name passlist-name source-revision
                         vendor-commit digest)
  (list "generator: scripts/test262-buckets.lisp"
        (format nil "vendor-test262-commit: ~a" vendor-commit)
        (format nil "source-revision: ~a" source-revision)
        (format nil "classification-ledger: ~a" ledger-name)
        (format nil "frozen-passlist: ~a" passlist-name)
        (format nil "classification-ledger-fnv-1a-64: ~a"
                (digest-string digest))))

(defun metadata-tsv-field (values)
  (dolist (value values)
    (when (or (position #\Tab value)
              (position #\Newline value)
              (position #\Return value))
      (error "frontmatter value cannot be represented in TSV: ~s" value)))
  (if values (join-strings values ",") "-"))

(defun write-gaps (path rows provenance)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create :external-format :utf-8)
    (dolist (line provenance)
      (format out "# ~a~%" line))
    (format out "path~cowner~cphase_owner~cwork_bucket~ctopic~cfeatures~cflags~cincludes~%"
            #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab)
    (dolist (row rows)
      (when (string= (row-classification row) "fail")
        (let ((metadata (row-metadata row)))
          (format out "~a~c~a~c~a~c~a~c~a~c~a~c~a~c~a~%"
                  (row-path row) #\Tab
                  (row-owner row) #\Tab
                  (row-phase-owner row) #\Tab
                  (row-work-bucket row) #\Tab
                  (row-topic row) #\Tab
                  (metadata-tsv-field (metadata-features metadata)) #\Tab
                  (metadata-tsv-field (metadata-flags metadata)) #\Tab
                  (metadata-tsv-field (metadata-includes metadata))))))))

(defun write-count-section (out title table &key final-p)
  (let* ((counts (sorted-counts table))
         (shown (first-n counts *top-count-limit*)))
    (format out "## Top ~d ~a~%~%" *top-count-limit* title)
    (format out "| Count | Value |~%|---:|---|~%")
    (if shown
        (dolist (entry shown)
          (format out "| ~d | ~a |~%" (cdr entry) (markdown-code (car entry))))
        (format out "| 0 | (none) |~%"))
    (format out "~%Counts are sorted by count descending, then raw value ascending. " )
    (if (> (length counts) *top-count-limit*)
        (format out "Showing ~d of ~d distinct values.~%"
                *top-count-limit* (length counts))
        (format out "All ~d distinct values are shown.~%" (length counts)))
    (unless final-p (terpri out))))

(defun write-report (path rows provenance frozen-baseline-count)
  (let ((class-counts (make-hash-table :test #'equal))
        (bucket-counts (make-hash-table :test #'equal))
        (phase-owner-counts (make-hash-table :test #'equal))
        (owner-counts (make-hash-table :test #'equal))
        (topic-counts (make-hash-table :test #'equal))
        (feature-counts (make-hash-table :test #'equal))
        (include-counts (make-hash-table :test #'equal)))
    (dolist (row rows)
      (increment-count class-counts (row-classification row))
      (when (string= (row-classification row) "fail")
        (increment-count bucket-counts (row-work-bucket row))
        (increment-count phase-owner-counts (row-phase-owner row))
        (increment-count owner-counts (row-owner row))
        (increment-count topic-counts (row-topic row))
        (dolist (feature (metadata-features (row-metadata row)))
          (increment-count feature-counts feature))
        (dolist (include (metadata-includes (row-metadata row)))
          (increment-count include-counts include))))
    (let* ((total (length rows))
           (pass (gethash "pass" class-counts 0))
           (fail (gethash "fail" class-counts 0))
           (skip (gethash "skip" class-counts 0))
           (crash (gethash "crash" class-counts 0))
           (eligible (+ pass fail))
           (target (ceiling (* eligible 9) 10))
           (lift (max 0 (- target pass)))
           (current-pass-delta (- pass frozen-baseline-count))
           (pass-rate (if (zerop eligible) 0d0 (* 100d0 (/ pass eligible)))))
      (ensure-directories-exist path)
      (with-open-file (out path :direction :output :if-exists :supersede
                                :if-does-not-exist :create :external-format :utf-8)
        (format out "# test262 execution failure buckets~%~%")
        (format out "This is a deterministic analysis of the authoritative execution " )
        (format out "classification ledger. Only `fail` rows contribute to the bucket and tag counts.~%~%")
        (format out "## Provenance~%~%| Item | Value |~%|---|---|~%")
        (dolist (line provenance)
          (let ((separator (search ": " line)))
            (format out "| ~a | ~a |~%"
                    (subseq line 0 separator)
                    (markdown-code (subseq line (+ separator 2))))))
        (format out "~%The digest is FNV-1a-64 over the ledger's exact input bytes; it is not SHA.~%~%")
        (format out "## Exact coverage target~%~%")
        (format out "| Measure | Exact value |~%|---|---:|~%")
        (format out "| Total | ~d |~%| Pass | ~d |~%| Fail | ~d |~%| Skip | ~d |~%"
                total pass fail skip)
        (format out "| Crash | ~d |~%| Eligible (`pass + fail`) | ~d |~%" crash eligible)
        (format out "| Pass rate | ~d / ~d = ~,6f% |~%" pass eligible pass-rate)
        (format out "| Frozen baseline pass count | ~d |~%" frozen-baseline-count)
        (format out "| Current-pass delta from frozen baseline | ~@d |~%"
                current-pass-delta)
        (format out "| `ceil(90% * eligible)` | ~d |~%" target)
        (format out "| Required pass lift | ~d |~%~%" lift)
        (format out "## Phase-owner counts~%~%")
        (format out "| Phase owner | Fail rows |~%|---|---:|~%")
        (format out "| `phase-25b` | ~d |~%"
                (gethash "phase-25b" phase-owner-counts 0))
        (format out "| `phase-37` | ~d |~%~%"
                (gethash "phase-37" phase-owner-counts 0))
        (format out "Phase ownership is orthogonal to the implementation work buckets below.~%~%")
        (format out "## Work-bucket counts~%~%")
        (format out "| Order | Work bucket | Fail rows |~%|---:|---|---:|~%")
        (loop for bucket in *work-buckets*
              for order from 1
              do (format out "| ~d | ~a | ~d |~%"
                         order (markdown-code bucket) (gethash bucket bucket-counts 0)))
        (format out "~%The work buckets are mutually exclusive, first-match wins, and their counts sum to ~d.~%~%"
                fail)
        (write-count-section out "owner counts" owner-counts)
        (write-count-section out "topic counts" topic-counts)
        (write-count-section out "raw feature counts" feature-counts)
        (write-count-section out "raw include counts" include-counts :final-p t)))))

;;; Command-line handling and built-in tests.

(defun parse-options (arguments)
  (when (and arguments (string= (first arguments) "--self-test"))
    (unless (= (length arguments) 1)
      (error "--self-test cannot be combined with other options"))
    (return-from parse-options (list :self-test t)))
  (let ((known '("--ledger" "--passlist" "--gaps" "--report"
                 "--source-revision")))
    (unless (evenp (length arguments))
      (error "options must be NAME VALUE pairs"))
    (let ((values (make-hash-table :test #'equal)))
      (loop for (name value) on arguments by #'cddr
            do (unless (string-member-p name known)
                 (error "unknown option ~s" name))
               (when (nth-value 1 (gethash name values))
                 (error "duplicate option ~a" name))
               (setf (gethash name values) value))
      (let ((ledger (gethash "--ledger" values))
            (passlist (gethash "--passlist" values))
            (gaps (gethash "--gaps" values))
            (report (gethash "--report" values))
            (source-revision (gethash "--source-revision" values)))
      (unless (and ledger passlist gaps report source-revision)
        (error "usage: --ledger PATH --passlist PATH --gaps PATH --report PATH --source-revision TEXT"))
      (when (or (string= ledger passlist)
                (string= ledger gaps) (string= ledger report)
                (string= passlist gaps) (string= passlist report)
                (string= gaps report))
        (error "ledger, passlist, gaps, and report paths must be distinct"))
      (list :ledger ledger :passlist passlist :gaps gaps :report report
              :source-revision source-revision)))))

(defun require-test (condition description)
  (unless condition
    (error "self-test failed: ~a" description)))

(defun signals-error-p (thunk)
  (handler-case
      (progn (funcall thunk) nil)
    (error () t)))

(defun run-self-test ()
  (let* ((source (format nil "/*---~%features: [generators, destructuring-binding]~%~
flags: [async, noStrict]~%includes: [assert.js, compareArray.js]~%~
negative:~%  phase: parse~%---*/~%0;"))
         (metadata (parse-metadata source)))
    (require-test (equal (metadata-features metadata)
                         '("generators" "destructuring-binding"))
                  "frontmatter feature parsing")
    (require-test (equal (metadata-flags metadata) '("async" "noStrict"))
                  "frontmatter flag parsing")
    (require-test (equal (metadata-includes metadata)
                         '("assert.js" "compareArray.js"))
                  "frontmatter include parsing")
    (require-test (equal (metadata-runner-features metadata)
                         '("generators" "destructuring-binding"))
                  "runner-mirror inline feature parsing")
    (require-test (equal (metadata-runner-flags metadata)
                         '("async" "noStrict"))
                  "runner-mirror inline flag parsing")
    (require-test (metadata-negative-parse-p metadata)
                  "negative parse metadata parsing"))
  (let* ((source (format nil "/*---~%features:~%  - Array.fromAsync~%  - Symbol.iterator~%~
flags:~%  - async~%includes:~%  - asyncHelpers.js~%---*/~%0;"))
         (metadata (parse-metadata source)))
    (require-test (equal (metadata-features metadata)
                         '("Array.fromAsync" "Symbol.iterator"))
                  "block feature parsing")
    (require-test (equal (metadata-flags metadata) '("async"))
                  "block flag parsing")
    (require-test (equal (metadata-includes metadata) '("asyncHelpers.js"))
                  "block include parsing")
    (require-test (null (metadata-runner-features metadata))
                  "runner mirror remains bracket-only for block features")
    (require-test (null (metadata-runner-flags metadata))
                  "runner mirror remains bracket-only for block flags")
    (require-test (string= "phase-37" (phase-owner-for "ordinary.js" metadata))
                  "block feature phase ownership"))
  (let* ((source (format nil "/*---~%features:~%  - optional-chaining~%~
flags: [onlyStrict]~%---*/~%0;"))
         (metadata (parse-metadata source)))
    (require-test (equal (metadata-features metadata) '("optional-chaining"))
                  "full parser sees block unsupported feature")
    (require-test (equal (metadata-runner-features metadata) '("onlyStrict"))
                  "runner mirror preserves bracket-search behavior")
    (require-test (null (static-skip-reason metadata))
                  "block metadata does not reinterpret the fixed runner ledger"))
  (require-test (= (length *phase-37-features*) 25)
                "phase-37 feature manifest size")
  (require-test (= (length *phase-37-paths*) 12)
                "phase-37 path manifest size")
  (require-test
   (string= "phase-37"
            (phase-owner-for (first *phase-37-paths*) (make-metadata)))
   "phase-37 exact path override")
  (require-test
   (string= "phase-25b"
            (phase-owner-for "statements/if/ordinary.js" (make-metadata)))
   "default phase ownership")
  (let ((plain (make-metadata)))
    (require-test
     (string= "binding-patterns"
              (bucket-for "eval-code/direct/x.js"
                          (make-metadata
                           :features '("destructuring-binding"
                                       "async-iteration"))))
     "binding patterns own all precedence overlaps")
    (require-test
     (string= "dynamic-scope-eval"
              (bucket-for "eval-code/direct/x.js"
                          (make-metadata :features '("generators"))))
     "dynamic scope precedence")
    (require-test
     (string= "async-iteration"
              (bucket-for "expressions/async-generator/x.js"
                          (make-metadata :features '("async-iteration"))))
     "async iteration precedence")
    (require-test
     (string= "async-generators"
              (bucket-for "expressions/async-generator/x.js" plain))
     "async generator mapping")
    (require-test
     (string= "binding-patterns"
              (bucket-for "statements/class/x.js"
                          (make-metadata :features '("destructuring-binding"))))
     "binding pattern precedence")
    (require-test
     (string= "binary-data"
              (bucket-for "built-ins/TypedArray/prototype/map/x.js"
                          (make-metadata :features '("Symbol.iterator"))))
     "binary data precedence")
    (require-test
     (string= "iterator-protocol"
              (bucket-for "built-ins/Array/from/x.js"
                          (make-metadata :features '("Symbol.iterator"))))
     "iterator protocol precedence")
    (require-test
     (string= "builtin:Array" (path-owner "built-ins/Array/from/x.js"))
     "built-in owner")
    (require-test
     (string= "language:statements" (path-owner "statements/class/x.js"))
     "language owner")
    (require-test
     (string= "built-ins/Array/prototype/reduce"
              (path-topic "built-ins/Array/prototype/reduce/x.js"))
     "prototype topic")
    (require-test
     (string= "language:statements" (path-owner "statements/class/x.js"))
     "language owner"))
  (require-test
   (signals-error-p (lambda () (parse-ledger-line "missing-tab" 1)))
   "malformed ledger line rejection")
  (require-test
   (signals-error-p (lambda () (parse-ledger-line "x.js\tunknown" 1)))
   "unknown classification rejection")
  (require-test
   (signals-error-p (lambda () (validate-next-path "x.js" "x.js" 2)))
   "duplicate path rejection")
  (require-test
   (signals-error-p (lambda () (validate-next-path "z.js" "a.js" 2)))
   "unsorted path rejection")
  (require-test
   (validate-exact-corpus-paths '("a.js" "b.js") '("a.js" "b.js"))
   "exact corpus path-set acceptance")
  (require-test
   (signals-error-p
    (lambda ()
      (validate-exact-corpus-paths '("a.js") '("a.js" "b.js"))))
   "missing corpus path rejection")
  (require-test
   (signals-error-p
    (lambda ()
      (validate-exact-corpus-paths '("a.js" "b.js") '("a.js"))))
   "extra corpus path rejection")
  (require-test
   (validate-static-skip-classification "ordinary.js" "fail" nil)
   "non-skip classification agreement")
  (require-test
   (validate-static-skip-classification
    "unsupported.js" "skip" "unsupported feature example")
   "skip classification agreement")
  (require-test
   (signals-error-p
    (lambda ()
      (validate-static-skip-classification "ordinary.js" "skip" nil)))
   "unjustified skip rejection")
  (require-test
   (signals-error-p
    (lambda ()
      (validate-static-skip-classification
       "unsupported.js" "pass" "unsupported feature example")))
   "statically skippable non-skip rejection")
  (require-test
   (string= "built-ins/Array/x.js"
            (passlist-entry-ledger-path "built-ins/Array/x.js"))
   "built-in pass-list mapping")
  (require-test
   (string= "statements/class/x.js"
            (passlist-entry-ledger-path "statements/class/x.js"))
   "language pass-list mapping")
  (require-test
   (equal (passlist-entries-from-lines
           '("# generated" "" "a.js" "built-ins/Array/x.js"))
          '("a.js" "built-ins/Array/x.js"))
   "pass-list comment filtering and mapping")
  (require-test
   (signals-error-p
    (lambda () (passlist-entries-from-lines '("a.js" "a.js"))))
   "duplicate pass-list rejection")
  (require-test
   (signals-error-p
    (lambda () (passlist-entries-from-lines '("built-ins/Array/x.js" "a.js"))))
   "unsorted pass-list rejection")
  (require-test
   (signals-error-p
    (lambda () (passlist-entries-from-lines '(" a.js"))))
   "non-canonical pass-list whitespace rejection")
  (let ((pass-rows (list (make-row :path "a.js" :classification "pass")
                         (make-row :path "built-ins/Array/x.js"
                                   :classification "pass"))))
    (require-test
     (= 2 (validate-passlist-against-ledger
           '("a.js" "built-ins/Array/x.js") pass-rows))
     "pass-list entries match current passes exactly once")
    (require-test
     (signals-error-p
      (lambda ()
        (validate-passlist-against-ledger
         '("a.js")
         (list (make-row :path "a.js" :classification "fail")))))
     "pass-list regression rejection")
    (require-test
     (signals-error-p
      (lambda ()
        (validate-passlist-against-ledger
         '("missing.js") pass-rows)))
     "missing pass-list row rejection")
    (require-test
     (signals-error-p
      (lambda ()
        (validate-passlist-against-ledger
         '("a.js")
         (list (make-row :path "a.js" :classification "pass")
               (make-row :path "a.js" :classification "pass")))))
     "duplicate ledger row rejection during pass-list validation"))
  (require-test
   (static-skip-reason
    (make-metadata :runner-features '("optional-chaining")))
   "feature static skip")
  (require-test
   (static-skip-reason (make-metadata :runner-flags '("module")))
   "flag static skip")
  (require-test (string= (metadata-tsv-field '()) "-")
                "empty metadata TSV sentinel")
  (require-test (= (fnv1a-64-string "") #xcbf29ce484222325)
                "FNV-1a empty vector")
  (require-test (= (fnv1a-64-string "hello") #xa430d84680aabd0b)
                "FNV-1a known vector")
  (format t "test262-buckets self-test: OK~%"))

(defun run-analysis (options)
  (let* ((ledger (getf options :ledger))
         (passlist (getf options :passlist))
         (gaps (getf options :gaps))
         (report (getf options :report))
         (source-revision
           (validate-provenance-text "source revision"
                                     (getf options :source-revision)))
         (vendor-commit
           (validate-provenance-text "vendor test262 commit"
                                     (read-one-line *vendor-commit-path*)))
         (ledger-name (stable-repo-input-name ledger "classification ledger"))
         (passlist-name (stable-repo-input-name passlist "frozen pass-list"))
         (digest (fnv1a-64-file ledger))
         (rows (load-ledger ledger))
         (passlist-entries (load-passlist passlist))
         (frozen-baseline-count
           (validate-passlist-against-ledger passlist-entries rows))
         (provenance
           (provenance-lines ledger-name passlist-name source-revision
                             vendor-commit digest)))
    (write-gaps gaps rows provenance)
    (write-report report rows provenance frozen-baseline-count)
    (format t "test262-buckets: wrote ~d fail rows to ~a and ~a~%"
            (count "fail" rows :test #'string= :key #'row-classification)
            gaps report)))

(defun main ()
  (handler-case
      (let ((options (parse-options (cdr sb-ext:*posix-argv*))))
        (if (getf options :self-test)
            (run-self-test)
            (run-analysis options)))
    (error (condition)
      (format *error-output* "test262-buckets: ERROR: ~a~%" condition)
      (sb-ext:exit :code 2))))

(main)
