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
            (clun.runtime::shell-result-exit-code result))))

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

(define-test shell/malformed-pipeline-is-rejected
  (fail (clun.runtime::%shell-parse (shell-test-units "echo ok |"))
        clun.runtime::shell-syntax-error)
  (fail (clun.runtime::%shell-parse (shell-test-units "| echo no"))
        clun.runtime::shell-syntax-error))

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

(define-test shell/lines-preserve-string-split-boundaries
  (is equal '() (clun.runtime::%shell-lines ""))
  (is equal '("hello") (clun.runtime::%shell-lines "hello"))
  (is equal '("hello" "")
      (clun.runtime::%shell-lines (format nil "hello~%")))
  (is equal '("" "") (clun.runtime::%shell-lines (format nil "~%")))
  (is equal (list (format nil "a~c" #\Return) "b")
      (clun.runtime::%shell-lines (format nil "a~c~%b" #\Return))))
