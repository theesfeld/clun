;;;; runtime-tests.lisp — console / process / .env / CLI-args (Phase 08). Installs
;;;; the runtime onto a fresh realm and drives snippets, capturing *standard-output*.

(in-package :clun-test)

(defun run-rt (src &key (silent nil))
  "Install the runtime on a fresh realm, eval SRC, return captured stdout."
  (let ((realm (eng:make-realm)) (out (make-string-output-stream)))
    (rt:install-runtime realm :argv (list :script "[test]" :rest '("a" "b"))
                              :cwd "/tmp" :silent silent :colors nil)
    (let ((*standard-output* out))
      (eng:eval-source src :realm realm))
    (get-output-stream-string out)))

(defun run-rt-err (src)
  "Like run-rt but capture *error-output*."
  (let ((realm (eng:make-realm)) (err (make-string-output-stream)))
    (rt:install-runtime realm :argv (list :script "[test]") :cwd "/tmp" :colors nil)
    (let ((*error-output* err)) (eng:eval-source src :realm realm))
    (get-output-stream-string err)))

;;; --- console ---------------------------------------------------------------

(define-test runtime/console-basic
  (is equal (format nil "hello~%") (run-rt "console.log('hello')"))
  (is equal (format nil "1 2 3~%") (run-rt "console.log(1,2,3)"))
  ;; nested object arg → multiline via the inspector
  (is equal (format nil "x {~%  a: 1,~%} [ 1, 2 ]~%") (run-rt "console.log('x',{a:1},[1,2])")))

(define-test runtime/console-format-specifiers
  (is equal (format nil "str 42 7 3.14~%") (run-rt "console.log('%s %d %i %f','str',42,7.9,3.14)"))
  ;; %c consumes its arg and emits nothing — the spaces around it remain (Node)
  (is equal (format nil "pct % and  styled~%") (run-rt "console.log('pct %% and %c styled','x')"))
  (is equal (format nil "a=1~%") (run-rt "console.log('a=%d',1)"))
  ;; leftover args appended
  (is equal (format nil "hi 1 2~%") (run-rt "console.log('hi',1,2)")))

(define-test runtime/console-streams-and-silent
  ;; warn/error go to stderr, not stdout
  (is equal "" (run-rt "console.warn('w'); console.error('e')"))
  (is equal (format nil "w~%e~%") (run-rt-err "console.warn('w'); console.error('e')"))
  ;; --silent suppresses log/info/debug but NOT warn/error
  (is equal "" (run-rt "console.log('x')" :silent t))
  (is equal (format nil "w~%") (run-rt-err "console.warn('w')")))

(define-test runtime/console-format-nonfinite-no-crash
  ;; %d/%i/%f on NaN/Infinity/undefined must never trap (review #3/#4)
  (is equal (format nil "NaN NaN Infinity~%") (run-rt "console.log('%d %d %d', undefined, NaN, Infinity)"))
  (is equal (format nil "-Infinity~%") (run-rt "console.log('%i', -1/0)"))
  (is equal (format nil "3~%") (run-rt "console.log('%d', 3.9)"))
  ;; %s on a Symbol renders Symbol(desc), not a crash (review #5)
  (is equal (format nil "Symbol(s)~%") (run-rt "console.log('%s', Symbol('s'))")))

;;; --- process ---------------------------------------------------------------

(define-test runtime/process-fields
  (is equal (format nil "~a ~a~%" (sys:platform-name) (sys:machine-arch))
      (run-rt "console.log(process.platform, process.arch)"))
  (is equal (format nil "true~%") (run-rt "console.log(typeof process.pid === 'number')"))
  (is equal (format nil "22.11.0~%") (run-rt "console.log(process.versions.node)"))
  (is equal (format nil "true~%") (run-rt "console.log(process.version === 'v'+process.versions.node)"))
  (is equal (format nil "true~%") (run-rt "console.log(typeof process.cwd() === 'string')"))
  (is equal (format nil "[ \"a\", \"b\" ]~%") (run-rt "console.log(process.argv.slice(2))")))

(define-test runtime/process-hrtime-memory
  (is equal (format nil "true~%") (run-rt "var h=process.hrtime(); console.log(Array.isArray(h) && h.length===2)"))
  (is equal (format nil "true~%") (run-rt "console.log(typeof process.memoryUsage().heapUsed === 'number')"))
  (is equal (format nil "true~%") (run-rt "console.log(process.stdout.write('') === true)")))

;;; --- Clun stub -------------------------------------------------------------

(define-test runtime/clun-global
  (is equal (format nil "true~%") (run-rt "console.log(typeof Clun.version === 'string')"))
  (is equal (format nil "9~%") (run-rt "console.log(Clun.inspect(9))"))
  (is equal (format nil "true~%") (run-rt "console.log(Clun.deepEquals({a:1,b:[2]},{a:1,b:[2]}))"))
  (is equal (format nil "false~%") (run-rt "console.log(Clun.deepEquals({a:1},{a:2}))")))

;;; --- .env parsing ----------------------------------------------------------

(define-test runtime/dotenv-parse
  (let ((pairs (clun.cli::%dotenv-parse
                (format nil "# comment~%GREETING=hello~%export NUM=\"42\"~%QUOTED='a b'~%~%EMPTY=~%TRAIL=x # c"))))
    (is equal "hello" (cdr (assoc "GREETING" pairs :test #'string=)))
    (is equal "42" (cdr (assoc "NUM" pairs :test #'string=)))
    (is equal "a b" (cdr (assoc "QUOTED" pairs :test #'string=)))
    (is equal "" (cdr (assoc "EMPTY" pairs :test #'string=)))
    (is equal "x" (cdr (assoc "TRAIL" pairs :test #'string=)))))

;;; --- CLI arg parsing -------------------------------------------------------

(define-test cli/parse-args
  (is eq :version (cli:cli-action (cli:parse-cli-args '("-v"))))
  (is eq :revision (cli:cli-action (cli:parse-cli-args '("--revision"))))
  (is eq :help (cli:cli-action (cli:parse-cli-args '("--help"))))
  (let ((r (cli:parse-cli-args '("-e" "1+1"))))
    (is eq :eval (cli:cli-action r))
    (is equal "1+1" (cli:cli-get r :code)))
  (let ((r (cli:parse-cli-args '("-p" "x" "arg1" "arg2"))))
    (is eq :print (cli:cli-action r))
    (is equal '("arg1" "arg2") (cli:cli-get r :args)))
  (let ((r (cli:parse-cli-args '("app.js" "--flag" "x"))))
    (is eq :run (cli:cli-action r))
    (is equal "app.js" (cli:cli-get r :file))
    (is equal '("--flag" "x") (cli:cli-get r :args)))       ; positional-stop
  (let ((r (cli:parse-cli-args '("run" "build.js" "extra"))))
    (is eq :run (cli:cli-action r))
    (is equal "build.js" (cli:cli-get r :file))
    (is equal '("extra") (cli:cli-get r :args)))
  (let ((r (cli:parse-cli-args '("--cwd" "/tmp" "app.js"))))
    (is equal "/tmp" (cli:cli-get r :cwd)))
  (is eq :error (cli:cli-action (cli:parse-cli-args '("--nope"))))
  (is eq :error (cli:cli-action (cli:parse-cli-args '("-e")))))    ; missing code
