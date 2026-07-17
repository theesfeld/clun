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
