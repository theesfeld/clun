;;;; sys-tests.lisp — path discipline, JSON reader, and fs primitives (Phase 07).

(in-package :clun-test)

(defun rt-write (path content)
  "Write CONTENT to PATH (a POSIX string), creating parent dirs. Shared with the
resolver corpus."
  (ensure-directories-exist (sys:native->pathname path))
  (with-open-file (s (sys:native->pathname path)
                     :direction :output :if-exists :supersede :if-does-not-exist :create)
    (write-string content s)))

;;; --- paths (lexical, no fs) -------------------------------------------------

(define-test sys/path-join
  (is equal "/a/b/c"   (sys:path-join "/a/b" "c"))
  (is equal "/a/b/c/d" (sys:path-join "/a/b" "c" "d"))
  (is equal "a/b"      (sys:path-join "a" "b"))
  (is equal "/abs"     (sys:path-join "/a/b" "/abs"))   ; absolute part wins
  (is equal "/a/b"     (sys:path-join "/a/b" "")))

(define-test sys/path-dirname-basename
  (is equal "/a/b" (sys:path-dirname "/a/b/c"))
  (is equal "/"    (sys:path-dirname "/a"))
  (is equal "."    (sys:path-dirname "a"))
  (is equal "c"    (sys:path-basename "/a/b/c"))
  (is equal "c"    (sys:path-basename "/a/b/c/"))
  (is equal "a"    (sys:path-basename "a")))

(define-test sys/path-extension
  (is equal ".js"   (sys:path-extension "foo.js"))
  (is equal ".js"   (sys:path-extension "foo.min.js"))
  (is equal ""      (sys:path-extension "foo"))
  (is equal ""      (sys:path-extension ".dotfile"))   ; leading dot is not an ext
  (is equal ".json" (sys:path-extension "/a/b/pkg.json")))

(define-test sys/normalize-path
  (is equal "/a/c/d" (sys:normalize-path "/a/b/../c/./d"))
  (is equal "/a"     (sys:normalize-path "/a/b/.."))
  (is equal "/"      (sys:normalize-path "/a/.."))
  (is equal "/"      (sys:normalize-path "/a/../.."))   ; can't escape root
  (is equal "a/b"    (sys:normalize-path "a/./b"))
  (is equal "../x"   (sys:normalize-path "../x")))      ; relative .. kept

(define-test sys/absolute-p
  (true  (sys:absolute-path-p "/a"))
  (false (sys:absolute-path-p "a"))
  (false (sys:absolute-path-p "./a")))

;;; --- native-namestring boundary (the `[` crash guard, §3.2) ----------------

(define-test sys/bracket-path-safe
  ;; a raw string with `[` must not crash SBCL pathname parsing; round-trips.
  (let ((p (sys:native->pathname "/tmp/has[bracket].txt")))
    (is equal "/tmp/has[bracket].txt" (sys:pathname->native p))))

(define-test sys/stat-at-entry-path-is-linux-only
  ;; macOS exposes /dev/fd as a directory, but not directory descriptors as
  ;; traversable /dev/fd/FD/NAME paths. The platform decision must precede the
  ;; host's descriptor-root probes so this remains testable on every runner.
  (is equal "/tmp/pages/index.tsx"
      (sys::%stat-at-entry-path
       "darwin" "/tmp/pages/index.tsx" 17 "index.tsx"))
  (let ((linux-path
          (sys::%stat-at-entry-path
           "linux" "/tmp/pages/index.tsx" 17 "index.tsx")))
    (if (or (sys:directory-p "/dev/fd")
            (sys:directory-p "/proc/self/fd"))
        (true (member linux-path
                      '("/dev/fd/17/index.tsx"
                        "/proc/self/fd/17/index.tsx")
                      :test #'string=))
        (is equal "/tmp/pages/index.tsx" linux-path))))

;;; --- JSON reader ------------------------------------------------------------

(define-test sys/json-scalars
  (is eql 1.0d0 (sys:parse-json "1"))
  (is eql -2.5d0 (sys:parse-json "-2.5"))
  (is eql 1000.0d0 (sys:parse-json "1e3"))
  (is equal "hi" (sys:parse-json "\"hi\""))
  (is eq sys:json-true  (sys:parse-json "true"))
  (is eq sys:json-false (sys:parse-json "false"))
  (is eq sys:json-null  (sys:parse-json "null")))

(define-test sys/json-string-escapes
  (is equal (format nil "a~cb" #\Newline) (sys:parse-json "\"a\\nb\""))
  (is equal "\"q\"" (sys:parse-json "\"\\\"q\\\"\""))
  (is equal "/" (sys:parse-json "\"\\/\""))
  (is equal "A" (sys:parse-json "\"\\u0041\""))
  ;; surrogate pair -> astral codepoint (U+1F600)
  (is eql #x1F600 (char-code (char (sys:parse-json "\"\\uD83D\\uDE00\"") 0))))

(define-test sys/json-object-order
  ;; objects preserve key order (exports condition matching depends on it)
  (let ((o (sys:parse-json "{\"z\":1,\"a\":2,\"m\":3}")))
    (is equal '("z" "a" "m") (mapcar #'car o))
    (is eql 2.0d0 (sys:jget o "a"))
    (is eq :missing (sys:jget o "nope" :missing))))

(define-test sys/json-nested-and-arrays
  (let ((o (sys:parse-json "{\"a\":[1,2,{\"b\":true}],\"c\":{}}")))
    (is eql 3 (length (sys:jget o "a")))
    (is eq sys:json-true (sys:jget (aref (sys:jget o "a") 2) "b"))
    (is eq :empty-object (sys:jget o "c")))
  (is eql 0 (length (sys:parse-json "[]"))))

(define-test sys/json-errors
  (is eq :caught (handler-case (sys:parse-json "{bad}") (sys:json-error () :caught)))
  (is eq :caught (handler-case (sys:parse-json "[1,2")  (sys:json-error () :caught)))
  (is eq :caught (handler-case (sys:parse-json "1 2")   (sys:json-error () :caught)))
  (is eq :caught (handler-case (sys:parse-json "")      (sys:json-error () :caught)))
  ;; trailing-dot / bare-exponent numbers are invalid JSON (review fix)
  (is eq :caught (handler-case (sys:parse-json "1.")    (sys:json-error () :caught)))
  (is eq :caught (handler-case (sys:parse-json "1.e3")  (sys:json-error () :caught)))
  (is eq :caught (handler-case (sys:parse-json "1e")    (sys:json-error () :caught))))

(define-test sys/json-review-fixes
  ;; a magnitude past the double range coerces to Infinity, not a parse error
  (true (sb-ext:float-infinity-p (sys:parse-json "1e400")))
  (true (plusp (sys:parse-json "1e400")))
  ;; duplicate key: last value wins, first position kept (matches JSON.parse)
  (is eql 2.0d0 (sys:jget (sys:parse-json "{\"a\":1,\"a\":2}") "a"))
  (is equal '("a" "b") (mapcar #'car (sys:parse-json "{\"a\":1,\"b\":2,\"a\":3}"))))

(define-test sys/fs-bracket-roundtrip
  ;; read-directory returns verbatim names (no wildcard-escaping of `[`) so they
  ;; round-trip back through path-join + stat (review fix)
  (let ((dir (sys:pathname->native (sb-posix:mkdtemp "/tmp/clun-fsbr-XXXXXX"))))
    (rt-write (sys:path-join dir "a[b].js") "x")
    (let ((names (sys:read-directory dir)))
      (is equal '("a[b].js") names)
      (true (sys:path-exists-p (sys:path-join dir (first names)))))))

;;; --- fs primitives ----------------------------------------------------------

(define-test sys/fs-primitives
  (let* ((dir (sys:pathname->native (sb-posix:mkdtemp "/tmp/clun-fstest-XXXXXX")))
         (f (sys:path-join dir "hello.txt")))
    (rt-write f "world")
    (true  (sys:path-exists-p f))
    (true  (sys:file-p f))
    (false (sys:directory-p f))
    (true  (sys:directory-p dir))
    (false (sys:file-p dir))
    (false (sys:path-exists-p (sys:path-join dir "nope")))
    (is equal "world" (sys:read-file-string f))
    (is equal (sys:realpath f) (sys:realpath f))     ; stable
    (true (member "hello.txt" (sys:read-directory dir) :test #'string=))))

;;; --- JSON writer (Phase 23: lockfile / package.json serialisation) ----------

(define-test sys/write-json-roundtrip
  ;; parse → write → parse is a fixpoint for the reader representation
  (let* ((src "{\"name\":\"p\",\"version\":\"1.0.0\",\"deps\":{\"a\":\"^1.0.0\",\"b\":\"2.0.0\"},\"list\":[1,2,3],\"nested\":{\"x\":true,\"y\":null,\"z\":false},\"empty\":{}}")
         (v1 (sys:parse-json src))
         (out (sys:write-json v1))
         (v2 (sys:parse-json out)))
    ;; structural round-trip via a second serialisation with sorted keys (canonical)
    (is equal (sys:write-json v1 :sort-keys t) (sys:write-json v2 :sort-keys t))
    (is equal "p" (sys:jget v2 "name"))
    (is equal "^1.0.0" (sys:jget (sys:jget v2 "deps") "a"))
    (is eq sys:json-true (sys:jget (sys:jget v2 "nested") "x"))
    (is eq sys:json-null (sys:jget (sys:jget v2 "nested") "y"))))

(define-test sys/write-json-deterministic-and-integers
  ;; sort-keys gives a deterministic order regardless of input key order; integers have no ".0"
  (let ((a (sys:parse-json "{\"b\":1,\"a\":2}"))
        (b (sys:parse-json "{\"a\":2,\"b\":1}")))
    (is equal (sys:write-json a :sort-keys t) (sys:write-json b :sort-keys t) "sorted order is canonical"))
  (is equal "1" (sys:write-json 1 :indent 0))
  (is equal "42" (sys:write-json (sys:jget (sys:parse-json "{\"n\":42}") "n") :indent 0))
  (is equal "[]" (sys:write-json (sys:jget (sys:parse-json "{\"a\":[]}") "a") :indent 0))
  (is equal "{}" (sys:write-json :empty-object :indent 0)))
