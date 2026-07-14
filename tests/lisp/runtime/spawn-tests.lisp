;;;; spawn-tests.lisp — Phase 24 milestone 1: Clun.spawnSync (the blocking subprocess matrix).
;;;; Uses PATH-resolved program names (:search t) so it is portable (no /bin/ absolutes — NixOS
;;;; has no /bin/echo). Each test drives a fresh runtime realm and reads back the JS result.

(in-package :clun-test)

(defun %spawn-eval (src)
  "Eval SRC in a fresh runtime realm (cwd /tmp) and return the completion value."
  (let ((realm (eng:make-realm)))
    (rt:install-runtime realm :argv (list :script "[spawn-test]" :rest nil) :cwd "/tmp" :colors nil)
    (eng:eval-source src :realm realm)))

(defun %spawn-str (src) (eng:to-string (%spawn-eval src)))
(defun %spawn-num (src) (eng:to-number (%spawn-eval src)))

(define-test spawn/echo-captures-stdout
  (is string= "hello world"
      (%spawn-str "new TextDecoder().decode(Clun.spawnSync(['echo','hello','world']).stdout).trim()"))
  (is = 0 (%spawn-num "Clun.spawnSync(['echo','x']).exitCode"))
  (is string= "true" (%spawn-str "String(Clun.spawnSync(['echo','x']).success)"))
  (is string= "true" (%spawn-str "String(Clun.spawnSync(['echo','x']).signalCode === null)"))
  (is string= "true" (%spawn-str "String(Clun.spawnSync(['echo','x']).pid > 0)")))

(define-test spawn/exit-code-propagates
  (is = 3 (%spawn-num "Clun.spawnSync(['sh','-c','exit 3']).exitCode"))
  (is string= "false" (%spawn-str "String(Clun.spawnSync(['sh','-c','exit 3']).success)"))
  (is = 0 (%spawn-num "Clun.spawnSync(['sh','-c','exit 0']).exitCode")))

(define-test spawn/signal-code
  ;; a child killed by a signal → exitCode null, signalCode the signal NAME
  (is string= "SIGTERM" (%spawn-str "Clun.spawnSync(['sh','-c','kill -TERM $$']).signalCode"))
  (is string= "true" (%spawn-str "String(Clun.spawnSync(['sh','-c','kill -TERM $$']).exitCode === null)"))
  (is string= "SIGKILL" (%spawn-str "Clun.spawnSync(['sh','-c','kill -KILL $$']).signalCode")))

(define-test spawn/stdin-feeds-child
  (is string= "piped-input"
      (%spawn-str "new TextDecoder().decode(Clun.spawnSync(['cat'],{stdin:'piped-input'}).stdout)"))
  ;; a Uint8Array stdin
  (is string= "AB"
      (%spawn-str "new TextDecoder().decode(Clun.spawnSync(['cat'],{stdin:new Uint8Array([65,66])}).stdout)")))

(define-test spawn/env-override
  (is string= "bar"
      (%spawn-str "new TextDecoder().decode(Clun.spawnSync(['sh','-c','echo $FOO'],{env:{FOO:'bar'}}).stdout).trim()"))
  ;; env REPLACES (not merges): an unset var is empty
  (is string= ""
      (%spawn-str "new TextDecoder().decode(Clun.spawnSync(['sh','-c','echo -n \"[$HOME]\"'],{env:{FOO:'x'}}).stdout).replace(/[\\[\\]]/g,'').trim()")))

(define-test spawn/stdio-modes
  ;; ignore → stdout is null; inherit → stdout is null (goes to the terminal)
  (is string= "true" (%spawn-str "String(Clun.spawnSync(['echo','x'],{stdout:'ignore'}).stdout === null)"))
  (is string= "true" (%spawn-str "String(Clun.spawnSync(['echo','x'],{stdout:'inherit'}).stdout === null)")))

(define-test spawn/large-output-no-deadlock
  ;; 5 MB of stdout must come back intact (a temp-file sink means no full-pipe deadlock)
  (is = 5000000 (%spawn-num "Clun.spawnSync(['sh','-c','yes x | head -c 5000000']).stdout.length")))

(define-test spawn/cwd-is-honoured
  (let ((dir (clun.sys:make-temp-dir "/tmp/clun-spawncwd-")))
    (unwind-protect
         (let ((out (%spawn-str (format nil "new TextDecoder().decode(Clun.spawnSync(['sh','-c','pwd'],{cwd:'~a'}).stdout).trim()" dir))))
           (true (search (clun.sys:path-basename dir) out) "pwd reflects the cwd option"))
      (ignore-errors (clun.sys:remove-recursive dir)))))

(define-test spawn/not-found-throws-catchable
  ;; a missing program → a catchable JS Error, never a raw Lisp backtrace
  (is string= "Error"
      (%spawn-str "(() => { try { Clun.spawnSync(['clun-no-such-prog-xyz']); return 'NO-THROW'; } catch (e) { return e.name; } })()"))
  ;; a non-array command → TypeError
  (is string= "TypeError"
      (%spawn-str "(() => { try { Clun.spawnSync('echo'); return 'NO-THROW'; } catch (e) { return e.name; } })()")))
