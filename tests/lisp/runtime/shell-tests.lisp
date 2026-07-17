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
             (is = 0 (exit-code "7" "-gt" "4"))
             (is = 0 (exit-code "file" "-ef" "file")))
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
    (is = 0 exit-code)))

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
