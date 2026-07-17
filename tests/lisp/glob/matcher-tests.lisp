;;;; matcher-tests.lisp -- engine-free Phase 30 Glob compiler coverage.

(in-package :clun-test)

(defun glob-true (pattern candidate)
  (true (glob:glob-match-p pattern candidate)
        "~s should match ~s" pattern candidate))

(defun glob-false (pattern candidate)
  (false (glob:glob-match-p pattern candidate)
         "~s should not match ~s" pattern candidate))

(defun glob-brace-pattern (count final)
  (with-output-to-string (output)
    (write-char #\{ output)
    (dotimes (index count)
      (when (plusp index) (write-char #\, output))
      (write-char #\x output))
    (when final
      (when (plusp count) (write-char #\, output))
      (write-char final output))
    (write-char #\} output)))

(defun glob-split-tabs (line)
  (let ((fields '())
        (start 0))
    (loop for tab = (position #\Tab line :start start)
          do (push (subseq line start tab) fields)
          if tab do (setf start (1+ tab))
          else do (return (nreverse fields)))))

(define-test glob-anchors-and-segment-wildcards
  (glob-true "" "")
  (glob-false "" "x")
  (glob-true "literal" "literal")
  (glob-false "literal" "Literal")
  (glob-true "?" "x")
  (glob-false "?" "/")
  (glob-false "?" "")
  (glob-true "a*b?c" "abZZbxc")
  (glob-false "*" "a/b")
  (glob-true "***" "segment")
  (glob-false "***" "a/b")
  ;; Direct matching has no dot suppression.
  (glob-true "*" ".hidden"))

(define-test glob-component-globstar
  (glob-true "**" "a/b/c")
  (glob-true "src/**/*.ts" "src/x.ts")
  (glob-true "src/**/*.ts" "src/a/b/x.ts")
  (glob-false "src/**/*.ts" "other/x.ts")
  (glob-true "a/**/b" "a/b")
  (glob-true "a/**/b" "a/x/y/b")
  (glob-true "a/**" "a/")
  (glob-true "a/**" "a/x/y")
  (glob-false "a/**" "a")
  (glob-true "**/*abc*" "deep/path/xabcx")
  (glob-true "**/**/x" "x")
  (glob-true "**/**/x" "a/b/x")
  ;; Raw brace boundaries prevent the outer slash from becoming part of the
  ;; globstar component, matching the stable executable.
  (glob-false "{**,foo}/bar" "bar")
  (glob-true "{**,foo}/bar" "x/bar")
  (glob-false "{**,foo}/bar" "x/y/bar")
  (glob-true "{**}" "segment")
  (glob-false "{**}" "a/b")
  (glob-false "{**,x}/bar" "a/b/bar")
  (glob-true "{**/b,x}" "b")
  (glob-true "{x,**/b}" "b")
  ;; Removing leading whole-pattern negation must not turn a raw !**
  ;; component into globstar syntax.
  (glob-true "!**" "a/b")
  (glob-false "!**" "segment")
  (glob-false "!!**" "a/b")
  (glob-true "!!**" "segment")
  ;; Stable Bun collapses adjacent complete ** components even though a
  ;; stripped leading ! is not otherwise a raw component boundary.
  (glob-false "!**/**" "a")
  (glob-true "!!**/**" "a")
  (glob-false "!**/**/a" "a")
  (glob-true "!**/a" "a")
  (glob-false "!{,**/b,-" "b"))

(define-test glob-globstar-final-component
  :parent glob-component-globstar
  (glob-false "**/*" "")
  (glob-false "**/*" "/")
  (glob-false "**/*" "a/")
  (glob-true "**/*" "a")
  (glob-true "**/*" "/a")
  (glob-false "a/**/*" "a/")
  (glob-true "a/**/*" "a/x")
  (glob-false "**/**/*" "")
  (glob-true "**/**/*" "a")
  ;; The stable rule is narrow: longer star runs, brace-local stars, and a
  ;; star followed by another component still retain zero-length behavior.
  (glob-true "**/***" "")
  (glob-true "**/{*}" "")
  (glob-true "**/*/" "/")
  (glob-true "**/*/*" "/")
  (glob-true "a/**/b/*" "a/b/"))

(define-test glob-classes-ranges-and-negation
  (glob-true "[abc]" "b")
  (glob-false "[abc]" "z")
  (glob-true "[a/]" "/")
  (glob-true "[!abc]" "z")
  (glob-false "[^abc]" "b")
  (glob-true "[a-z]" "m")
  (glob-false "[z-a]" "z")
  (glob-true "[]a]" "]")
  (glob-true "[-a]" "-")
  (glob-true "[a-]" "-")
  (glob-true "[a\\-c]" "-")
  (glob-true "[\\n]" (string #\Newline))
  (glob-true "[\\]]" "]")
  (glob-true "{[a,b],x}" ",")
  (glob-true "{[a,b],x}" "x"))

(define-test glob-braces
  (glob-true "{a}" "a")
  (glob-true "{}" "")
  (glob-true "{,}" "")
  (glob-true "{a,}" "")
  (glob-true "{a,}" "a")
  (glob-true "pre{a,b,c}post" "prebpost")
  (glob-true "{a,{b,c}}" "c")
  (glob-true "{{a,b},c}" "b")
  (glob-true "{src/**,README.md}" "src/a")
  (glob-false "{src/**,README.md}" "src/a/b")
  (glob-true "{src/**,README.md}" "README.md")
  (glob-false "{src/**,README.md}" "other"))

(define-test glob-escapes-negation-and-literal-extglobs
  (glob-true "\\*" "*")
  (glob-true "\\!a" "!a")
  (glob-true "a\\nb" (format nil "a~%b"))
  (glob-true "a\\tb" (format nil "a~cb" #\Tab))
  (glob-false "!a" "a")
  (glob-true "!a" "b")
  (glob-true "!!a" "a")
  (glob-true "!!!a" "b")
  (glob-true "@(a|b)" "@(a|b)")
  (glob-false "@(a|b)" "a")
  ;; The initial ! is whole-pattern negation, never an extglob operator.
  (glob-false "!(a|b)" "(a|b)")
  (glob-true "!(a|b)" "a"))

(define-test glob-malformed-patterns
  (glob-false "[" "[")
  (glob-false "[]" "[]")
  (glob-false "abc\\" "abc")
  (glob-false "{a" "a")
  (glob-true "{a,b" "a")
  (glob-false "{a,b" "b")
  (glob-true "{a,b,c" "b")
  (glob-false "{a,b,c" "c")
  (glob-true "{a,," "")
  (glob-true "{,a," "a")
  (glob-false "{a,[]}\\" "a")
  ;; Forward correction: commas remain class members even when the class is
  ;; unterminated, so they cannot manufacture empty brace branches.
  (glob-false "{[,," "")
  ;; Clun corrections keep malformed classes branch-local and validate suffix
  ;; text after sequential nested braces instead of inheriting Bun's state leak.
  (glob-false "{a[],a,/[[" "a/")
  (glob-false "{a}{}," "a")
  (glob-true "x{a,b" "xa")
  (glob-true "{a,{b,c}" "a")
  (glob-false "{a,{b,c}" "b")
  ;; Negation complements the non-matching malformed base program.
  (glob-true "![" "anything")
  (glob-false "!![" "anything"))

(define-test glob-unicode-scalars-and-lone-surrogates
  (let ((emoji #(#xd83d #xde00))
        (lone-high #(#xd800))
        (lone-low #(#xdc00)))
    (glob-true "?" emoji)
    (glob-true "?" lone-high)
    (glob-true "?" lone-low)
    (glob-true emoji emoji)
    (glob-true lone-high lone-high)
    (glob-false lone-high lone-low)
    (glob-true #(#x5b #xd83d #xde00 #x5d) emoji)
    (glob-true #(#x5b #xd800 #x2d #xd802 #x5d) #(#xd801))
    (glob-false "??" emoji)))

(define-test glob-immutable-reentrant-program
  (let ((compiled (glob:compile-glob "src/**/*.{js,ts}")))
    (of-type glob:compiled-glob compiled)
    (dotimes (iteration 100)
      (declare (ignore iteration))
      (glob-true compiled "src/x.js")
      (glob-true compiled "src/a/x.ts")
      (glob-false compiled "src/x.css"))))

(define-test glob-shipped-match-corpus
  (let ((path (merge-pathnames "tests/compat/filesystem.glob/match-corpus.tsv"
                               (asdf:system-source-directory :clun)))
        (rows 0))
    (with-open-file (input path :direction :input :external-format :utf-8)
      (read-line input nil)
      (loop for line = (read-line input nil)
            while line
            for fields = (glob-split-tabs line)
            do (is = 6 (length fields) "complete corpus row ~s" line)
               (incf rows)
               (if (string= (fifth fields) "true")
                   (glob-true (third fields) (fourth fields))
                   (glob-false (third fields) (fourth fields)))))
    ;; This is the currently translated partial inventory, not a claim that
    ;; every upstream assertion has already been dispositioned.
    (is = 104 rows "all currently shipped matcher rows executed")))

(define-test glob-resource-bounds
  (let* ((stars (make-string 100000 :initial-element #\*))
         (questions (make-string 100000 :initial-element #\?))
         (deep-unclosed (make-string 40000 :initial-element #\{))
         (star-program (glob:compile-glob stars))
         (question-program (glob:compile-glob questions)))
    (true (< (length (clun.glob::compiled-glob-program star-program)) 8)
          "adjacent segment stars collapse into a constant-size program")
    (is = 100001
        (length (clun.glob::compiled-glob-program question-program)))
    (glob-true star-program "bounded")
    (glob-false question-program "short")
    (glob-false deep-unclosed "anything"))
  ;; Exactly 10,000 branch transitions can reach the final z. One later
  ;; branch is deliberately outside the frozen per-match budget.
  (glob-true (glob-brace-pattern 9999 #\z) "z")
  (glob-false (glob-brace-pattern 10000 #\z) "z")
  (let ((ten-deep "{{{{{{{{{{x}}}}}}}}}}")
        (eleven-deep "{{{{{{{{{{{x}}}}}}}}}}}"))
    (glob-true ten-deep "x")
    (glob-false eleven-deep "x")
    (glob-true (format nil "{ok,~a}" eleven-deep) "ok")))
