;;;; shell-tests.lisp -- Phase 65 parser, expansion, and built-in executor core.

(in-package :clun-test)

(defun shell-test-units (source)
  (coerce source 'vector))

(defun shell-test-state (&optional env)
  (clun.runtime::make-shell-state
   :env env :cwd (sys:current-directory) :throws t))

(defun shell-test-output (source &optional env)
  (let ((result (clun.runtime::%shell-execute-units
                 (shell-test-units source) (shell-test-state env) nil)))
    (values (eng:utf8->code-units (clun.runtime::shell-result-stdout result))
            (clun.runtime::shell-result-exit-code result)
            (eng:utf8->code-units
             (clun.runtime::shell-result-stderr result)))))

(define-test shell/lexer-preserves-ordinary-letters
  (let ((tokens (clun.runtime::%shell-lex
                 (shell-test-units "printf hello | tr a-z A-Z"))))
    (is equal '(:word :word :operator :word :word :word)
        (mapcar #'clun.runtime::shell-token-kind tokens))
    (is equal "printf"
        (clun.runtime::shell-fragment-value
         (first (clun.runtime::shell-word-fragments
                 (clun.runtime::shell-token-value (first tokens))))))
    (is equal "|" (clun.runtime::shell-token-value (third tokens)))))

(define-test shell/escaped-newline-is-a-continuation
  (let* ((result (clun.runtime::%shell-execute-units
                  (shell-test-units
                   (format nil "echo one ~c~%two; echo \"three~c~%four\""
                           #\\ #\\))
                  (shell-test-state) nil))
         (output (eng:utf8->code-units
                  (clun.runtime::shell-result-stdout result))))
    (is equal (format nil "one two~%threefour~%") output)
    (is = 0 (clun.runtime::shell-result-exit-code result))))

(define-test shell/empty-substitution-preserves-status
  (multiple-value-bind (output exit-code)
      (shell-test-output "$(exit 1) && echo must-not-run")
    (is equal "" output)
    (is = 1 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output "$(exit 0) && echo did-run")
    (is equal (format nil "did-run~%") output)
    (is = 0 exit-code)))

(define-test shell/interpolation-cannot-create-grammar
  (let* ((units (concatenate
                 'vector (shell-test-units "echo ")
                 (vector (cons :interp "safe; echo injected | false"))))
         (result (clun.runtime::%shell-execute-units units (shell-test-state) nil)))
    (is equal (format nil "safe; echo injected | false~%")
        (eng:utf8->code-units (clun.runtime::shell-result-stdout result)))
    (is = 0 (clun.runtime::shell-result-exit-code result))))

(define-test shell/logical-builtins-and-status
  (multiple-value-bind (output exit-code)
      (shell-test-output "echo one; false || echo two; true && echo three; echo $?")
    (is equal (format nil "one~%two~%three~%0~%") output)
    (is = 0 exit-code)))

(define-test shell/quoted-and-unquoted-variable-expansion
  (let* ((state (shell-test-state (list (cons "VALUE" "a b"))))
         (quoted (clun.runtime::%shell-parse (shell-test-units "echo \"$VALUE\"")))
         (unquoted (clun.runtime::%shell-parse (shell-test-units "echo $VALUE")))
         (quoted-word
           (second (clun.runtime::shell-command-words
                    (first (clun.runtime::shell-pipeline-commands
                            (first (clun.runtime::shell-script-pipelines quoted)))))))
         (unquoted-word
           (second (clun.runtime::shell-command-words
                    (first (clun.runtime::shell-pipeline-commands
                            (first (clun.runtime::shell-script-pipelines unquoted))))))))
    (is equal '("a b")
        (clun.runtime::%shell-word-values quoted-word state nil))
    (is equal '("a" "b")
        (clun.runtime::%shell-word-values unquoted-word state nil))))

(define-test shell/positional-parameters
  (let* ((state (clun.runtime::make-shell-state
                 :env nil :cwd (sys:current-directory) :throws t
                 :positionals '("/tmp/script.bun.sh" "a b" "c")))
         (result (clun.runtime::%shell-execute-units
                  (shell-test-units
                   "echo \"$0|$1|$2|$9|$10\"; [[ \"$1\" == \"a b\" ]] && echo matched")
                  state nil)))
    (is equal (format nil "/tmp/script.bun.sh|a b|c||a b0~%matched~%")
        (eng:utf8->code-units (clun.runtime::shell-result-stdout result)))
    (is = 0 (clun.runtime::shell-result-exit-code result)))
  (multiple-value-bind (stdout stderr status)
      (rt:execute-shell-script "echo $0:$1:$2"
                               :positionals '("standalone" "one"))
    (is equal (format nil "standalone:one:~%")
        (eng:utf8->code-units stdout))
    (is = 0 (length stderr))
    (is = 0 status)))

(define-test shell/backtick-command-substitution
  (multiple-value-bind (output exit-code)
      (shell-test-output "echo `echo one; echo two`")
    (is equal (format nil "one two~%") output)
    (is = 0 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output "echo \"`echo one; echo two`\"")
    (is equal (format nil "one~%two~%") output)
    (is = 0 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output
       (format nil "echo `echo 'foo\\~%bar'`"))
    (is equal (format nil "foobar~%") output)
    (is = 0 exit-code))
  (fail (clun.runtime::%shell-parse
         (shell-test-units "echo `unterminated"))
        clun.runtime::shell-syntax-error))

(define-test shell/compound-word-field-boundaries
  (multiple-value-bind (output exit-code)
      (shell-test-output "echo pre$(echo one two)post")
    (is equal (format nil "preone twopost~%") output)
    (is = 0 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output "VALUE='one two'; echo pre${VALUE}post")
    (is equal (format nil "preone twopost~%") output)
    (is = 0 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output "EMPTY=; echo pre${EMPTY}post; echo $EMPTY")
    (is equal (format nil "prepost~%~%") output)
    (is = 0 exit-code)))

(define-test shell/malformed-pipeline-is-rejected
  (fail (clun.runtime::%shell-parse (shell-test-units "echo ok |"))
        clun.runtime::shell-syntax-error)
  (fail (clun.runtime::%shell-parse (shell-test-units "| echo no"))
        clun.runtime::shell-syntax-error)
  (fail (clun.runtime::%shell-parse (shell-test-units "(echo no"))
        clun.runtime::shell-syntax-error)
  (fail (clun.runtime::%shell-parse (shell-test-units "echo no)"))
        clun.runtime::shell-syntax-error)
  (fail (clun.runtime::%shell-parse (shell-test-units "()"))
        clun.runtime::shell-syntax-error)
  (fail (clun.runtime::%shell-parse (shell-test-units "{ echo no"))
        clun.runtime::shell-syntax-error)
  (fail (clun.runtime::%shell-parse (shell-test-units "{ echo no }"))
        clun.runtime::shell-syntax-error)
  (fail (clun.runtime::%shell-parse (shell-test-units "}"))
        clun.runtime::shell-syntax-error)
  (fail (clun.runtime::%shell-parse (shell-test-units "if true; echo no; fi"))
        clun.runtime::shell-syntax-error)
  (fail (clun.runtime::%shell-parse (shell-test-units "if true; then echo no"))
        clun.runtime::shell-syntax-error)
  (fail (clun.runtime::%shell-parse (shell-test-units "if true; then; fi"))
        clun.runtime::shell-syntax-error))

(define-test shell/merged-output-pipeline
  (let* ((script (clun.runtime::%shell-parse
                  (shell-test-units "ls missing |& cat | cat")))
         (pipeline (first (clun.runtime::shell-script-pipelines script))))
    (is equal '(t nil) (clun.runtime::shell-pipeline-merge-stderr pipeline)))
  (multiple-value-bind (output exit-code error-output)
      (shell-test-output "ls missing |& cat")
    (is equal (format nil "ls: missing: No such file or directory~%") output)
    (is = 0 exit-code)
    (is equal "" error-output))
  (multiple-value-bind (output exit-code error-output)
      (shell-test-output "ls missing | cat")
    (is equal "" output)
    (is = 0 exit-code)
    (is equal (format nil "ls: missing: No such file or directory~%")
        error-output)))

(define-test shell/missing-pipeline-stage-preserves-last-status
  (multiple-value-bind (output exit-code error-output)
      (shell-test-output
       "clun-missing-pipeline-command | /usr/bin/env printf 'after\\n'")
    (is equal (format nil "after~%") output)
    (is = 0 exit-code)
    (is equal
        (format nil "clun: command not found: clun-missing-pipeline-command~%")
        error-output)))

(define-test shell/path-builtins
  (is equal "basename.test.ts"
      (clun.runtime::%shell-basename "js/bun/shell/commands/basename.test.ts"))
  (is equal "catalog" (clun.runtime::%shell-basename "/catalog/"))
  (is equal "/" (clun.runtime::%shell-basename "/"))
  (is equal "Summer2018.pdf"
      (clun.runtime::%shell-basename "C:/Documents/Newsletters/Summer2018.pdf"))
  (is equal "js/bun/shell/commands"
      (clun.runtime::%shell-dirname "js/bun/shell/commands/dirname.test.ts"))
  (is equal "/" (clun.runtime::%shell-dirname "/catalog/"))
  (is equal "C:/Documents/Newsletters"
      (clun.runtime::%shell-dirname "C:/Documents/Newsletters/Summer2018.pdf")))

(define-test shell/echo-newline-rules
  (is equal "hello" (clun.runtime::%shell-echo-output '("hello") nil))
  (is equal (format nil "hello~%")
      (clun.runtime::%shell-echo-output '("hello") t))
  (is equal (format nil "~%")
      (clun.runtime::%shell-echo-output (list (format nil "~%")) t))
  (is equal (format nil "~%~%")
      (clun.runtime::%shell-echo-output (list (format nil "~%~%~%")) t))
  (is equal (format nil "a~%")
      (clun.runtime::%shell-echo-output (list (format nil "a~%~%")) t)))

(define-test shell/exit-wraps-and-terminates-script
  (multiple-value-bind (output exit-code)
      (shell-test-output "exit 62757836; echo unreachable")
    (is equal "" output)
    (is = 204 exit-code))
  (is = 0 (clun.runtime::%shell-parse-exit-code "0"))
  (is = 255 (clun.runtime::%shell-parse-exit-code "-1"))
  (false (clun.runtime::%shell-parse-exit-code "12x")))

(define-test shell/seq-numeric-and-option-semantics
  (flet ((run (&rest arguments)
           (let ((result (clun.runtime::%shell-run-seq arguments)))
             (values (eng:utf8->code-units
                      (clun.runtime::shell-result-stdout result))
                     (eng:utf8->code-units
                      (clun.runtime::shell-result-stderr result))
                     (clun.runtime::shell-result-exit-code result)))))
    (multiple-value-bind (stdout stderr exit-code) (run "0" "5")
      (is equal (format nil "0~%1~%2~%3~%4~%5~%") stdout)
      (is equal "" stderr)
      (is = 0 exit-code))
    (multiple-value-bind (stdout stderr exit-code)
        (run "-s." "-t," "5" "-2" "1")
      (is equal "5.3.1.," stdout)
      (is equal "" stderr)
      (is = 0 exit-code))
    (multiple-value-bind (stdout stderr exit-code) (run "4" "0" "7")
      (is equal "" stdout)
      (is equal (format nil "seq: zero increment~%") stderr)
      (is = 1 exit-code))))

(define-test shell/seq-formatting-and-f32-progress
  (flet ((stdout (&rest arguments)
           (eng:utf8->code-units
            (clun.runtime::shell-result-stdout
             (clun.runtime::%shell-run-seq arguments)))))
    (is equal "001.0,002.0,003.0,"
        (stdout "-f" "%05.1f" "-s," "1" "1" "3"))
    (is equal "08,10,12," (stdout "-w" "-s," "8" "2" "12"))
    (is equal (format nil "16777216~%")
        (stdout "16777216" "16777218"))
    (is equal (format nil "1~%") (stdout "1" "0.00000001" "2"))))

(define-test shell/yes-bounded-pattern-fill
  (let ((target (make-array 9 :element-type '(unsigned-byte 8)
                            :initial-element 46))
        (pattern (eng:code-units->utf8 (format nil "ab~%"))))
    (is = 5 (clun.runtime::%shell-fill-pattern target 2 5 pattern))
    (is equal (format nil "..ab~%ab..") (eng:utf8->code-units target))))

(define-test shell/yes-requires-bounded-target
  (let ((result (clun.runtime::%shell-run-yes nil nil)))
    (is = 1 (clun.runtime::shell-result-exit-code result))
    (is equal "" (eng:utf8->code-units
                   (clun.runtime::shell-result-stdout result)))
    (is equal (format nil "yes: unbounded output requires a streaming sink~%")
        (eng:utf8->code-units
         (clun.runtime::shell-result-stderr result)))))

(define-test shell/pipeline-builtins-use-isolated-state
  (let* ((directory (clun.runtime::%shell-temp-directory))
         (state (shell-test-state)))
    (unwind-protect
         (progn
           (setf (clun.runtime::shell-state-cwd state) directory)
           (let ((result (clun.runtime::%shell-execute-units
                          (shell-test-units "cd / | pwd") state nil)))
             (is equal (format nil "~a~%" directory)
                 (eng:utf8->code-units
                  (clun.runtime::shell-result-stdout result)))
             (is equal directory (clun.runtime::shell-state-cwd state)))
           (let ((result (clun.runtime::%shell-execute-units
                          (shell-test-units
                           "export CLUN_PIPE_VALUE=inner | echo $CLUN_PIPE_VALUE")
                          state nil)))
             (is equal (format nil "~%")
                 (eng:utf8->code-units
                  (clun.runtime::shell-result-stdout result)))
             (false (assoc "CLUN_PIPE_VALUE" (clun.runtime::shell-state-env state)
                           :test #'string=)))
           (let ((result (clun.runtime::%shell-execute-units
                          (shell-test-units
                           "exit 42 | echo after; echo outside") state nil)))
             (is equal (format nil "after~%outside~%")
                 (eng:utf8->code-units
                  (clun.runtime::shell-result-stdout result)))
             (false (clun.runtime::shell-state-terminated state))))
      (ignore-errors (sys:remove-recursive directory)))))

(define-test shell/assignment-only-pipeline-stages-forward-input-and-isolate
  (let* ((state (shell-test-state))
         (result (clun.runtime::%shell-execute-units
                  (shell-test-units
                   "echo before | A=1 B=2 | cat; C=3 | echo after | D=4")
                  state nil)))
    (is equal (format nil "before~%after~%")
        (eng:utf8->code-units (clun.runtime::shell-result-stdout result)))
    (is = 0 (clun.runtime::shell-result-exit-code result))
    (false (assoc "A" (clun.runtime::shell-state-env state) :test #'string=))
    (false (assoc "B" (clun.runtime::shell-state-env state) :test #'string=))
    (false (assoc "C" (clun.runtime::shell-state-env state) :test #'string=))
    (false (assoc "D" (clun.runtime::shell-state-env state) :test #'string=))))

(define-test shell/grouped-subshells-parse-pipe-and-isolate-state
  (multiple-value-bind (output exit-code)
      (shell-test-output
       "A=outer; (A=inner; echo $A) | cat; echo $A")
    (is equal (format nil "inner~%outer~%") output)
    (is = 0 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output
       "(echo a | echo b) | (echo c | echo d) | (echo e | echo f)")
    (is equal (format nil "f~%") output)
    (is = 0 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output "echo input | (cat)")
    (is equal (format nil "input~%") output)
    (is = 0 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output "(false || echo recovered); (exit 7); echo outside")
    (is equal (format nil "recovered~%outside~%") output)
    (is = 0 exit-code)))

(define-test shell/brace-groups-run-in-current-state
  (multiple-value-bind (output exit-code)
      (shell-test-output
       "A=outer; { A=inner; echo $A; }; echo $A")
    (is equal (format nil "inner~%inner~%") output)
    (is = 0 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output
       "{ { echo nested; }; echo outer; } | cat")
    (is equal (format nil "nested~%outer~%") output)
    (is = 0 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output "echo {a,b}; echo }")
    (is equal (format nil "a b~%}~%") output)
    (is = 0 exit-code))
  (let* ((directory (clun.runtime::%shell-temp-directory))
         (state (shell-test-state)))
    (unwind-protect
         (progn
           (setf (clun.runtime::shell-state-cwd state) directory)
           (let ((result (clun.runtime::%shell-execute-units
                          (shell-test-units
                           "{ echo one; echo two; } > grouped; { cat; } < grouped")
                          state nil)))
             (is equal (format nil "one~%two~%")
                 (eng:utf8->code-units
                  (clun.runtime::shell-result-stdout result)))
             (is = 0 (clun.runtime::shell-result-exit-code result))))
      (ignore-errors (sys:remove-recursive directory)))))

(define-test shell/compound-groups-nest-inside-if
  (dolist (case
           '(("if { echo foo; } then echo bar; fi" "foo~%bar~%" 0)
             ("if echo foo; then { echo bar; } fi" "foo~%bar~%" 0)
             ("if echo foo; then { echo bar; } elif echo baz; then echo qux; fi"
              "foo~%bar~%" 0)
             ("if echo foo; then echo bar; elif { echo baz; } then echo qux; fi"
              "foo~%bar~%" 0)
             ("if ! echo foo; then { echo bar; } else echo baz; fi"
              "foo~%baz~%" 0)
             ("if ! echo foo; then echo bar; else { echo baz; } fi"
              "foo~%baz~%" 0)
             ("if { if false; then echo no; else echo nested; fi; } then echo outer; fi"
              "nested~%outer~%" 0)
             ("if (echo subshell); then echo outer; fi"
              "subshell~%outer~%" 0)
             ("if ! { false; }; then echo negated; fi" "negated~%" 0)
             ("! ! { false; }" "" 1)))
    (destructuring-bind (source expected-output expected-code) case
      (multiple-value-bind (output exit-code) (shell-test-output source)
        (is equal (format nil expected-output) output)
        (is = expected-code exit-code)))))

(define-test shell/if-elif-else-compound-command
  (multiple-value-bind (output exit-code)
      (shell-test-output
       "if true | true; then echo yes; else echo no; fi")
    (is equal (format nil "yes~%") output)
    (is = 0 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output
       "if false; then echo no; elif echo condition; then echo yes; else echo no; fi")
    (is equal (format nil "condition~%yes~%") output)
    (is = 0 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output
       "if ! echo first; then echo no; elif ! false; then echo second; else echo final; fi")
    (is equal (format nil "first~%second~%") output)
    (is = 0 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output
       "if true; then if false; then echo no; else echo nested; fi; fi | cat")
    (is equal (format nil "nested~%") output)
    (is = 0 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output "if false; then echo no; fi && echo after")
    (is equal (format nil "after~%") output)
    (is = 0 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output "if true; then false; else true; fi")
    (is equal "" output)
    (is = 1 exit-code)))

(define-test shell/yes-to-immediate-builtin-sink
  (multiple-value-bind (output exit-code) (shell-test-output "yes | true")
    (is equal "" output)
    (is = 0 exit-code))
  (let ((result (clun.runtime::%shell-execute-units
                 (shell-test-units "yes | false") (shell-test-state) nil)))
    (is equal "" (eng:utf8->code-units
                   (clun.runtime::shell-result-stdout result)))
    (is equal "" (eng:utf8->code-units
                   (clun.runtime::shell-result-stderr result)))
    (is = 1 (clun.runtime::shell-result-exit-code result))))

(define-test shell/ordered-descriptor-redirections
  (let* ((directory (clun.runtime::%shell-temp-directory))
         (state (shell-test-state))
         (result (clun.runtime::make-shell-result
                  :stdout (eng:code-units->utf8 (format nil "out~%"))
                  :stderr (eng:code-units->utf8 (format nil "err~%"))
                  :exit-code 7)))
    (labels ((word (value)
               (clun.runtime::make-shell-word
                :fragments
                (list (clun.runtime::make-shell-fragment
                       :kind :literal :value value :quoted nil))))
             (redirect (kind &optional target)
               (clun.runtime::make-shell-redirection
                :kind kind :target (and target (word target))))
             (apply-redirections (&rest redirections)
               (clun.runtime::%shell-apply-output-redirections
                result redirections state nil))
             (text (path)
               (eng:utf8->code-units
                (sys:read-file-octets (sys:path-join directory path)))))
      (unwind-protect
           (progn
             (setf (clun.runtime::shell-state-cwd state) directory)
             (let ((redirected
                     (apply-redirections
                      (redirect :output "both")
                      (redirect :error-to-output))))
               (is equal "" (eng:utf8->code-units
                               (clun.runtime::shell-result-stdout redirected)))
               (is equal "" (eng:utf8->code-units
                               (clun.runtime::shell-result-stderr redirected)))
               (is equal (format nil "out~%err~%") (text "both")))
             (let ((redirected
                     (apply-redirections
                      (redirect :error-to-output)
                      (redirect :output "ordered"))))
               (is equal (format nil "err~%")
                   (eng:utf8->code-units
                    (clun.runtime::shell-result-stdout redirected)))
               (is equal "" (eng:utf8->code-units
                               (clun.runtime::shell-result-stderr redirected)))
               (is equal (format nil "out~%") (text "ordered")))
             (apply-redirections
              (redirect :output "superseded")
              (redirect :output "final"))
             (is equal "" (text "superseded"))
             (is equal (format nil "out~%") (text "final"))
             (apply-redirections (redirect :both-append "both"))
             (is equal (format nil "out~%err~%out~%err~%") (text "both")))
        (ignore-errors (sys:remove-recursive directory))))))

(define-test shell/bounded-nested-brace-expansion
  (is equal '("echo 123")
      (clun.runtime::%shell-brace-expand "echo 123"))
  (is equal '("echo 123" "echo 456" "echo 789" "echo abc")
      (clun.runtime::%shell-brace-expand "echo {123,{456,789},abc}"))
  (is equal '("preacpost" "preadpost" "prebcpost" "prebdpost")
      (clun.runtime::%shell-brace-expand "pre{{a,b}{c,d}}post"))
  (is equal '("a" "bd" "be" "cd" "ce" "f")
      (clun.runtime::%shell-brace-expand "{a,{b,c}{d,e},f}"))
  (is equal '("ace" "acf" "ade" "adf" "bce" "bcf" "bde" "bdf")
      (clun.runtime::%shell-brace-expand "{{a,b}{c,d}{e,f}}"))
  (let* ((tokens (clun.runtime::%shell-brace-tokenize ""))
         (group (clun.runtime::%shell-brace-parse tokens)))
    (is equal "[\"eof\"]" (clun.runtime::%shell-brace-tokens-json tokens))
    (is equal "{\"bubble_up\":null,\"bubble_up_next\":null,\"atoms\":{\"many\":[]}}"
        (clun.runtime::%shell-brace-ast-json group))))

(define-test shell/brace-expansion-composes-with-pathname-globbing
  (let* ((directory (clun.runtime::%shell-temp-directory))
         (state (shell-test-state)))
    (unwind-protect
         (progn
           (setf (clun.runtime::shell-state-cwd state) directory)
           (sys:make-directory (sys:path-join directory "src"))
           (sys:make-directory (sys:path-join directory "lib"))
           (dolist (path '("src/app.ts" "src/util.tsx" "lib/b.ts"
                           "x.ts" "x.,foo" "x.]foo"))
             (sys:write-file-octets
              (sys:path-join directory path)
              (make-array 0 :element-type '(unsigned-byte 8))))
           (let ((result (clun.runtime::%shell-execute-units
                          (shell-test-units "echo src/*.{ts,tsx}") state nil)))
             (is equal
                 (format nil "src/*.ts src/*.tsx src/app.ts src/util.tsx~%")
                 (eng:utf8->code-units
                  (clun.runtime::shell-result-stdout result))))
           (let ((result (clun.runtime::%shell-execute-units
                          (shell-test-units "echo {src,lib}/*.ts") state nil)))
             (is equal
                 (format nil "src/*.ts lib/*.ts lib/b.ts src/app.ts~%")
                 (eng:utf8->code-units
                  (clun.runtime::shell-result-stdout result))))
           (let* ((units (concatenate
                          'vector (shell-test-units "echo *.{ts,")
                          (vector (cons :interp ",foo"))
                          (shell-test-units "}")))
                  (result (clun.runtime::%shell-execute-units units state nil))
                  (output (eng:utf8->code-units
                           (clun.runtime::shell-result-stdout result))))
             (is equal (format nil "*.ts *.,foo x.,foo x.ts~%") output)
             (false (search "x.]foo" output))))
      (ignore-errors (sys:remove-recursive directory)))))

(define-test shell/redirection-open-errors-are-command-statuses
  (let* ((directory (clun.runtime::%shell-temp-directory))
         (state (shell-test-state)))
    (unwind-protect
         (progn
           (setf (clun.runtime::shell-state-cwd state) directory)
           (let ((result
                   (clun.runtime::%shell-execute-units
                    (shell-test-units
                     "touch must-not-exist > missing/output; echo status=$?")
                    state nil)))
             (is equal (format nil "status=1~%")
                 (eng:utf8->code-units
                  (clun.runtime::shell-result-stdout result)))
             (is equal
                 (format nil "clun: redirection: No such file or directory: ~a~%"
                         (sys:path-join directory "missing/output"))
                 (eng:utf8->code-units
                  (clun.runtime::shell-result-stderr result)))
             (is = 0 (clun.runtime::shell-result-exit-code result))
             (is eq nil (sys:path-exists-p
                         (sys:path-join directory "must-not-exist")))))
      (ignore-errors (sys:remove-recursive directory)))))

(define-test shell/ambiguous-redirect-is-a-command-status
  (multiple-value-bind (output exit-code error-output)
      (shell-test-output "EMPTY=; echo value > $EMPTY")
    (is equal "" output)
    (is = 1 exit-code)
    (is equal (format nil "clun: ambiguous redirect~%") error-output)))

(define-test shell/synchronous-redirection-write-errors-are-statuses
  (when (sys:path-exists-p "/dev/full")
    (let ((result
            (clun.runtime::%shell-execute-units
             (shell-test-units
              "echo a > /dev/full || echo recovered; echo b > /dev/full || echo again")
             (shell-test-state) nil)))
      (is equal (format nil "recovered~%again~%")
          (eng:utf8->code-units (clun.runtime::shell-result-stdout result)))
      (is = 0 (clun.runtime::shell-result-exit-code result)))))

(define-test shell/cli-execution-entrypoint
  (multiple-value-bind (stdout stderr status)
      (rt:execute-shell-script "echo hello; false || echo recovered"
                               :cwd (sys:current-directory)
                               :env (sys:environ-alist))
    (is equal (format nil "hello~%recovered~%") (eng:utf8->code-units stdout))
    (is = 0 (length stderr))
    (is = 0 status))
  (multiple-value-bind (stdout stderr status)
      (rt:execute-shell-script "pwd --help"
                               :cwd (sys:current-directory)
                               :env (sys:environ-alist))
    (is = 0 (length stdout))
    (is equal (format nil "pwd: too many arguments~%") (eng:utf8->code-units stderr))
    (is = 1 status)))

(define-test shell/conditional-expression-core
  (let* ((directory (clun.runtime::%shell-temp-directory))
         (state (shell-test-state)))
    (labels ((exit-code (&rest terms)
               (clun.runtime::shell-result-exit-code
                (clun.runtime::%shell-run-condition
                 (append terms (list "]]")) state))))
      (unwind-protect
           (progn
             (setf (clun.runtime::shell-state-cwd state) directory)
             (sys:write-file-octets (sys:path-join directory "file")
                                    (eng:code-units->utf8 "payload"))
             (sys:make-directory (sys:path-join directory "dir"))
             (sys:make-symlink "file" (sys:path-join directory "link"))
             (is = 0 (exit-code "-f" "file"))
             (is = 1 (exit-code "-f" "dir"))
             (is = 0 (exit-code "-d" "dir"))
             (is = 1 (exit-code "-d" "file"))
             (is = 0 (exit-code "-L" "link"))
             (is = 1 (exit-code "-f" ""))
             (is = 1 (exit-code "-d" ""))
             (is = 0 (exit-code "-n" "value"))
             (is = 0 (exit-code "-z" ""))
             (is = 0 (exit-code "alpha" "==" "alpha"))
             (is = 0 (exit-code "alpha" "!=" "beta"))
             (is = 0 (exit-code "alpha" ">" "aardvark"))
             (is = 0 (exit-code "alpha" "<" "beta"))
             (is = 0 (exit-code "7" "-gt" "4"))
             (is = 0 (exit-code "file" "-ef" "file"))
             (is = 0 (exit-code "!" "x" "||" "x"))
             (is = 1 (exit-code "!" "!" "!" "1" "-eq" "1"))
             (is = 0 (exit-code "!" "!" "!" "!" "1" "-eq" "1"))
             (is = 0 (exit-code "" "&&" "x" "||" "y"))
             (is = 0 (exit-code "x" "||" "" "&&" ""))
             (is = 1 (exit-code "(" "x" "||" "" ")" "&&" "")))
        (ignore-errors (sys:remove-recursive directory))))))

(define-test shell/conditional-expansion-preserves-empty-operands
  (multiple-value-bind (output exit-code)
      (shell-test-output
       "CLUN_COND_EMPTY=; [[ -z $CLUN_COND_EMPTY ]] && echo empty")
    (is equal (format nil "empty~%") output)
    (is = 0 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output "true | [[ -n test ]] && echo ok")
    (is equal (format nil "ok~%") output)
    (is = 0 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output
       "[[ ( -z missing || -n value ) && ! -z value ]] && echo grouped")
    (is equal (format nil "grouped~%") output)
    (is = 0 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output "[[ (-n value) ]] && echo compact")
    (is equal (format nil "compact~%") output)
    (is = 0 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output
       "TDIR=/usr/homes/gmacs; [[ $TDIR == /usr/homes/* ]] && echo wildcard")
    (is equal (format nil "wildcard~%") output)
    (is = 0 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output
       "TDIR=/usr/homes/gmacs; [[ $TDIR == '/usr/homes/*' ]]")
    (is equal "" output)
    (is = 1 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output
       "TDIR=/usr/homes/gmacs; [[ $TDIR == /usr/homes/\\* ]]")
    (is equal "" output)
    (is = 1 exit-code))
  (multiple-value-bind (output exit-code)
      (shell-test-output
       "TDIR=/usr/homes/gmacs; PAT='/usr/homes/*'; [[ $TDIR == $PAT ]]")
    (is equal "" output)
    (is = 0 exit-code)))

(define-test shell/conditional-regex
  (flet ((exit-code (source)
           (nth-value 1 (shell-test-output source))))
    (is = 0 (exit-code "[[ 123abc =~ ^[0-9]+[a-z]+$ ]]"))
    (is = 1 (exit-code "[[ 123abc =~ ^[a-z]+$ ]]"))
    (is = 0 (exit-code
             "[[ jbig2dec-0.9-i586-001.tgz =~ ([^-]+)-([^-]+)-([^-]+)-0*([1-9][0-9]*)\\.tgz ]]"))
    (is = 0 (exit-code "[[ a.c =~ 'a.c' ]]"))
    (is = 1 (exit-code "[[ abc =~ 'a.c' ]]"))
    (is = 2 (exit-code "[[ value =~ ( ]]"))
    (is = 0 (exit-code "[[ value || value =~ ( ]]"))))

(define-test shell/conditional-extended-glob
  (flet ((exit-code (source)
           (nth-value 1 (shell-test-output source))))
    (is = 0 (exit-code "shopt -s extglob"))
    (is = 0 (exit-code "arg=-7; [[ $arg == -+([0-9]) ]]"))
    (is = 1 (exit-code "arg=-H; [[ $arg == -+([0-9]) ]]"))
    (is = 0 (exit-code "arg=+4; [[ $arg == ++([0-9]) ]]"))
    (is = 0 (exit-code "[[ 123abc == *?(a)bc ]]"))
    (is = 0 (exit-code "[[ abbbc == a+(b)c ]]"))
    (is = 0 (exit-code "[[ foo == @(foo|bar) ]]"))
    (is = 1 (exit-code "[[ baz == @(foo|bar) ]]"))
    (is = 0 (exit-code "[[ '+([0-9])' == '+([0-9])' ]]"))
    (is = 1 (exit-code "[[ +7 == '+([0-9])' ]]"))))

(define-test shell/conditional-arithmetic
  (flet ((result (source)
           (clun.runtime::%shell-execute-units
            (shell-test-units source) (shell-test-state) nil)))
    (is = 0 (clun.runtime::shell-result-exit-code (result "[[ 7 -eq 4+3 ]]")))
    (is = 0 (clun.runtime::shell-result-exit-code (result "[[ 14 -eq 2+3*4 ]]")))
    (is = 0 (clun.runtime::shell-result-exit-code (result "[[ 20 -eq (2+3)*4 ]]")))
    (is = 0 (clun.runtime::shell-result-exit-code
             (result "IVAR=4+3; [[ $IVAR -eq 7 ]]")))
    (is = 0 (clun.runtime::shell-result-exit-code
             (result "A=7; [[ 7 -eq A ]]")))
    (is = 0 (clun.runtime::shell-result-exit-code
             (result "UNSET=; [[ 7 -gt $UNSET ]]")))
    (is = 0 (clun.runtime::shell-result-exit-code (result "[[ 255 -eq 16#ff ]]")))
    (is = 0 (clun.runtime::shell-result-exit-code
             (result "EXPR='1|2'; [[ 3 -eq $EXPR ]]")))
    (is = 0 (clun.runtime::shell-result-exit-code
             (result "[[ -1 -eq 18446744073709551615 ]]")))
    (let ((invalid (result "[[ 7 -eq 4+ ]]")))
      (is = 1 (clun.runtime::shell-result-exit-code invalid))
      (is equal (format nil "clun: conditional expression: invalid arithmetic expression~%")
          (eng:utf8->code-units (clun.runtime::shell-result-stderr invalid))))
    (is = 1 (clun.runtime::shell-result-exit-code
             (result "A=B; B=A; [[ 0 -eq A ]]")))
    (is = 1 (clun.runtime::shell-result-exit-code (result "[[ 1 -eq 1/0 ]]")))))

(define-test shell/lines-preserve-string-split-boundaries
  (is equal '() (clun.runtime::%shell-lines ""))
  (is equal '("hello") (clun.runtime::%shell-lines "hello"))
  (is equal '("hello" "")
      (clun.runtime::%shell-lines (format nil "hello~%")))
  (is equal '("" "") (clun.runtime::%shell-lines (format nil "~%")))
  (is equal (list (format nil "a~c" #\Return) "b")
      (clun.runtime::%shell-lines (format nil "a~c~%b" #\Return))))

(define-test shell/cat-display-options
  (flet ((transform (text &key number-all number-nonblank show-ends
                                squeeze-blank show-tabs show-nonprinting)
           (eng:utf8->code-units
            (clun.runtime::%shell-cat-transform
             (eng:code-units->utf8 text) number-all number-nonblank show-ends
             squeeze-blank show-tabs show-nonprinting))))
    (is equal (format nil "     1~ca~%     2~c~%     3~cb~%" #\Tab #\Tab #\Tab)
        (transform (format nil "a~%~%b~%") :number-all t))
    (is equal (format nil "a~%~%b~%")
        (transform (format nil "a~%~%~%b~%") :squeeze-blank t))
    (is equal (format nil "a^I$~%")
        (transform (format nil "a~c~%" #\Tab) :show-tabs t :show-ends t))))

(define-test shell/filesystem-builtins
  (let* ((directory (clun.runtime::%shell-temp-directory))
         (state (shell-test-state))
         (empty (make-array 0 :element-type '(unsigned-byte 8))))
    (unwind-protect
         (progn
           (setf (clun.runtime::shell-state-cwd state) directory)
           (is = 0 (clun.runtime::shell-result-exit-code
                    (clun.runtime::%shell-run-mkdir '("-p" "a/b") state)))
           (true (sys:directory-p (sys:path-join directory "a/b")))
           (is = 0 (clun.runtime::shell-result-exit-code
                    (clun.runtime::%shell-run-touch '("one" "two") state)))
           (true (sys:file-p (sys:path-join directory "one")))
           (sys:write-file-octets (sys:path-join directory "one")
                                  (eng:code-units->utf8 "alpha"))
           (sys:write-file-octets (sys:path-join directory "two")
                                  (eng:code-units->utf8 "beta"))
           (let ((result (clun.runtime::%shell-run-cat '("one" "two") state empty)))
             (is equal "alphabeta"
                 (eng:utf8->code-units (clun.runtime::shell-result-stdout result)))
             (is = 0 (clun.runtime::shell-result-exit-code result))))
      (ignore-errors (sys:remove-recursive directory)))))

(define-test shell/rm-recursive-and-symlink-boundary
  (let* ((directory (clun.runtime::%shell-temp-directory))
         (state (shell-test-state)))
    (unwind-protect
         (progn
           (setf (clun.runtime::shell-state-cwd state) directory)
           (sys:make-directory (sys:path-join directory "tree/a") :recursive t)
           (sys:write-file-octets (sys:path-join directory "tree/a/file")
                                  (eng:code-units->utf8 "payload"))
           (let ((result (clun.runtime::%shell-run-rm '("-rv" "tree") state)))
             (is = 0 (clun.runtime::shell-result-exit-code result))
             (is equal (format nil "tree/a/file~%tree/a~%tree~%")
                 (eng:utf8->code-units (clun.runtime::shell-result-stdout result))))
           (false (sys:path-exists-p (sys:path-join directory "tree")))
           (sys:make-directory (sys:path-join directory "victim"))
           (sys:write-file-octets (sys:path-join directory "victim/keep")
                                  (eng:code-units->utf8 "important"))
           (sys:make-symlink "victim" (sys:path-join directory "link"))
           (is = 0 (clun.runtime::shell-result-exit-code
                    (clun.runtime::%shell-run-rm '("-rf" "link") state)))
           (true (sys:file-p (sys:path-join directory "victim/keep")))
           (is = 1 (clun.runtime::shell-result-exit-code
                    (clun.runtime::%shell-run-rm '("-rf" "/") state))))
      (ignore-errors (sys:remove-recursive directory)))))

(define-test shell/mv-target-and-overwrite-semantics
  (let* ((directory (clun.runtime::%shell-temp-directory))
         (state (shell-test-state)))
    (unwind-protect
         (progn
           (setf (clun.runtime::shell-state-cwd state) directory)
           (sys:make-directory (sys:path-join directory "dest"))
           (sys:write-file-octets (sys:path-join directory "one")
                                  (eng:code-units->utf8 "one"))
           (sys:write-file-octets (sys:path-join directory "two")
                                  (eng:code-units->utf8 "two"))
           (is = 0 (clun.runtime::shell-result-exit-code
                    (clun.runtime::%shell-run-mv '("one" "two" "dest") state)))
           (true (sys:file-p (sys:path-join directory "dest/one")))
           (true (sys:file-p (sys:path-join directory "dest/two")))
           (sys:write-file-octets (sys:path-join directory "source")
                                  (eng:code-units->utf8 "source"))
           (sys:write-file-octets (sys:path-join directory "target")
                                  (eng:code-units->utf8 "target"))
           (is = 0 (clun.runtime::shell-result-exit-code
                    (clun.runtime::%shell-run-mv '("-n" "source" "target") state)))
           (is equal "source" (eng:utf8->code-units
                                (sys:read-file-octets (sys:path-join directory "source"))))
           (is equal "target" (eng:utf8->code-units
                                (sys:read-file-octets (sys:path-join directory "target"))))
           (let ((result (clun.runtime::%shell-run-mv
                          '("dest/one" "source" "missing") state)))
             (is = 1 (clun.runtime::shell-result-exit-code result))
             (is equal (format nil "mv: missing: No such file or directory~%")
                 (eng:utf8->code-units (clun.runtime::shell-result-stderr result)))))
      (ignore-errors (sys:remove-recursive directory)))))

(define-test shell/ls-formatting-primitives
  (is equal "rwsr-xr-x" (clun.runtime::%shell-ls-permissions #o104755))
  (is equal "rw-r-S--T" (clun.runtime::%shell-ls-permissions #o103640))
  (is eql #\l (clun.runtime::%shell-ls-entry-type #o120777))
  (is eql #\d (clun.runtime::%shell-ls-entry-type #o040755))
  (is equal "Jan 01  1970" (clun.runtime::%shell-ls-time 0 20000000))
  (is equal "Jan 01 00:00" (clun.runtime::%shell-ls-time 0 0)))

(define-test shell/ls-hidden-recursive-and-partial-errors
  (let* ((directory (clun.runtime::%shell-temp-directory))
         (state (shell-test-state)))
    (unwind-protect
         (progn
           (setf (clun.runtime::shell-state-cwd state) directory)
           (sys:make-directory (sys:path-join directory "tree/sub") :recursive t)
           (dolist (path '("tree/a" "tree/.hidden" "tree/sub/b"))
             (sys:write-file-octets (sys:path-join directory path)
                                    (eng:code-units->utf8 "")))
           (let ((result (clun.runtime::%shell-run-ls '("tree") state)))
             (is = 0 (clun.runtime::shell-result-exit-code result))
             (is equal (format nil "a~%sub~%")
                 (eng:utf8->code-units (clun.runtime::shell-result-stdout result))))
           (let ((result (clun.runtime::%shell-run-ls '("-a" "tree") state)))
             (is equal (format nil ".~%..~%.hidden~%a~%sub~%")
                 (eng:utf8->code-units (clun.runtime::shell-result-stdout result))))
           (let ((result (clun.runtime::%shell-run-ls '("-R" "tree") state)))
             (is equal (format nil "a~%sub~%tree/sub:~%b~%")
                 (eng:utf8->code-units (clun.runtime::shell-result-stdout result))))
           (let ((result (clun.runtime::%shell-run-ls '("tree/a" "missing") state)))
             (is = 1 (clun.runtime::shell-result-exit-code result))
             (is equal (format nil "tree/a~%")
                 (eng:utf8->code-units (clun.runtime::shell-result-stdout result)))
             (is equal (format nil "ls: missing: No such file or directory~%")
                 (eng:utf8->code-units (clun.runtime::shell-result-stderr result)))))
      (ignore-errors (sys:remove-recursive directory)))))

(define-test shell/ls-permission-denied-directory-and-recursive
  "Exact stable/engineering ls.test.ts chmod-000 permission sites (non-root)."
  (let* ((directory (clun.runtime::%shell-temp-directory))
         (state (shell-test-state))
         (restricted (sys:path-join directory "restricted"))
         (level1 (sys:path-join directory "level1"))
         (level2 (sys:path-join level1 "level2"))
         (level3 (sys:path-join level2 "level3")))
    (unwind-protect
         (progn
           (setf (clun.runtime::shell-state-cwd state) directory)
           (sys:make-directory restricted)
           (sys:change-mode restricted #o000)
           (let ((result (clun.runtime::%shell-run-ls '("restricted") state)))
             (sys:change-mode restricted #o755)
             (is = 1 (clun.runtime::shell-result-exit-code result))
             (is equal "" (eng:utf8->code-units
                           (clun.runtime::shell-result-stdout result)))
             (true (search "Permission denied"
                           (eng:utf8->code-units
                            (clun.runtime::shell-result-stderr result)))))
           (sys:make-directory level3 :recursive t)
           (dolist (path '("level1/file1" "level1/file2" "level1/file3"
                           "level1/level2/file4" "level1/level2/file5"
                           "level1/level2/file6"
                           "level1/level2/level3/file7"
                           "level1/level2/level3/file8"
                           "level1/level2/level3/file9"))
             (sys:write-file-octets (sys:path-join directory path)
                                    (eng:code-units->utf8 "")))
           (sys:change-mode level2 #o000)
           (let* ((result (clun.runtime::%shell-run-ls '("-R" "level1") state))
                  (stdout (eng:utf8->code-units
                           (clun.runtime::shell-result-stdout result)))
                  (stderr (eng:utf8->code-units
                           (clun.runtime::shell-result-stderr result))))
             (sys:change-mode level2 #o755)
             (is = 1 (clun.runtime::shell-result-exit-code result))
             (true (search "file1" stdout))
             (true (search "file2" stdout))
             (true (search "file3" stdout))
             (true (search "Permission denied" stderr))))
      (ignore-errors
        (ignore-errors (sys:change-mode restricted #o755))
        (ignore-errors (sys:change-mode level2 #o755))
        (sys:remove-recursive directory)))))

(define-test shell/cp-bounded-recursive-and-symlink-copy
  (let* ((directory (clun.runtime::%shell-temp-directory))
         (state (shell-test-state))
         (payload (make-array 200000 :element-type '(unsigned-byte 8)
                              :initial-element 97)))
    (unwind-protect
         (progn
           (setf (clun.runtime::shell-state-cwd state) directory)
           (sys:write-file-octets (sys:path-join directory "source") payload)
           (sys:change-mode (sys:path-join directory "source") #o751)
           (is = 0 (clun.runtime::shell-result-exit-code
                    (clun.runtime::%shell-run-cp '("source" "copy") state)))
           (is = 200000 (length (sys:read-file-octets
                                 (sys:path-join directory "copy"))))
           (is = #o751 (logand #o777
                                (sys:fstat-mode
                                 (sys:stat* (sys:path-join directory "copy")))))
           (fail (sys:copy-file-stream (sys:path-join directory "source")
                                       (sys:path-join directory "source"))
                 sys:fs-error)
           (is = 200000 (length (sys:read-file-octets
                                 (sys:path-join directory "source"))))
           (sys:make-symlink "copy" (sys:path-join directory "nofollow"))
           (fail (sys:copy-file-stream (sys:path-join directory "source")
                                       (sys:path-join directory "nofollow"))
                 sys:fs-error)
           (is equal "copy" (sys:read-symlink
                              (sys:path-join directory "nofollow")))
           (sys:make-directory (sys:path-join directory "tree/sub") :recursive t)
           (sys:write-file-octets (sys:path-join directory "tree/sub/file")
                                  (eng:code-units->utf8 "nested"))
           (sys:make-symlink "sub/file" (sys:path-join directory "tree/link"))
           (is = 0 (clun.runtime::shell-result-exit-code
                    (clun.runtime::%shell-run-cp '("-R" "tree" "tree-copy") state)))
           (is equal "nested"
               (eng:utf8->code-units
                (sys:read-file-octets (sys:path-join directory "tree-copy/sub/file"))))
           (is equal "sub/file" (sys:read-symlink
                                  (sys:path-join directory "tree-copy/link")))
           (is = 1 (clun.runtime::shell-result-exit-code
                    (clun.runtime::%shell-run-cp
                     '("-R" "tree" "tree/new/deep") state)))
           (false (sys:path-exists-p (sys:path-join directory "tree/new")))
           (sys:write-file-octets (sys:path-join directory "preserved")
                                  (eng:code-units->utf8 "preserved"))
           (is = 0 (clun.runtime::shell-result-exit-code
                    (clun.runtime::%shell-run-cp
                     '("-n" "source" "preserved") state)))
           (is equal "preserved"
               (eng:utf8->code-units
                (sys:read-file-octets (sys:path-join directory "preserved"))))
           (is = 1 (clun.runtime::shell-result-exit-code
                    (clun.runtime::%shell-run-cp '("source" "source") state))))
      (ignore-errors (sys:remove-recursive directory)))))
