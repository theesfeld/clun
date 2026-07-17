;;;; spawn-tests.lisp — Phase 24 milestone 1: Clun.spawnSync (the blocking subprocess matrix).
;;;; Uses PATH-resolved program names (:search t) so it is portable (no /bin/ absolutes — NixOS
;;;; has no /bin/echo). Each test drives a fresh runtime realm and reads back the JS result.

(in-package :clun-test)

(defun %spawn-eval (src)
  "Eval SRC in a fresh runtime realm (cwd /tmp) and return the completion value; tears the realm
down after (releases the loop + its fds, so a long test run does not accrete fd pressure)."
  (let ((realm (eng:make-realm)))
    (unwind-protect
         (progn (rt:install-runtime realm :argv (list :script "[spawn-test]" :rest nil) :cwd "/tmp" :colors nil)
                (eng:eval-source src :realm realm))
      (ignore-errors (eng:teardown-realm realm)))))

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
      (%spawn-str "new TextDecoder().decode(Clun.spawnSync(['sh','-c','printf \"[%s]\" \"$HOME\"'],{env:{FOO:'x'}}).stdout).replace(/[\\[\\]]/g,'').trim()")))

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

;;; --- async Clun.spawn (reactor pipes, .exited, kill, onExit) -----------------
;;; each test evals a script that drives the loop to quiescence (the subprocess handle keeps the
;;; loop alive until the child exits + pipes drain) and logs results we assert on.

(defun %spawn-run (src)
  "Run SRC in a fresh runtime realm (driving the loop) and return captured stdout; tears the realm
down after (releases the loop + its fds)."
  (let ((realm (eng:make-realm)) (out (make-string-output-stream)))
    (unwind-protect
         (progn (rt:install-runtime realm :argv (list :script "[spawn-async]" :rest nil) :cwd "/tmp" :colors nil)
                (let ((*standard-output* out)) (eng:eval-source src :realm realm))
                (get-output-stream-string out))
      (ignore-errors (eng:teardown-realm realm)))))

(define-test spawn/async-exit-and-signal
  (let ((o (%spawn-run "
    Clun.spawn(['sh','-c','exit 5']).exited.then(c => console.log('exit5='+c));
    const s = Clun.spawn(['sh','-c','kill -TERM $$']);
    s.exited.then(c => console.log('sig exit='+c+' code='+s.signalCode));")))
    (true (search "exit5=5" o) ".exited resolves to the exit code")
    (true (search "sig exit=null code=SIGTERM" o) "a signalled child → null exit + signalCode")))

(define-test spawn/async-stdout-pipe
  (let ((o (%spawn-run "
    const p = Clun.spawn(['echo','piped-hello'], {stdout:'pipe'});
    p.stdout.then(b => console.log('out=['+new TextDecoder().decode(b).trim()+']'));")))
    (true (search "out=[piped-hello]" o) "piped stdout drains to a Uint8Array promise")))

(define-test spawn/async-dual-pipe-10mb-no-deadlock
  ;; write 10 MB to stdin AND read 10 MB from stdout concurrently through `cat` — the classic
  ;; full-pipe deadlock, avoided by non-blocking concurrent reactor drain.
  (let ((o (%spawn-run "
    const big = 'x'.repeat(10000000);
    const cat = Clun.spawn(['cat'], {stdin:'pipe', stdout:'pipe'});
    cat.stdin.write(big); cat.stdin.end();
    cat.stdout.then(b => console.log('big='+b.length));")))
    (true (search "big=10000000" o) "10 MB round-trips through a dual pipe without deadlock")))

(define-test spawn/async-kill
  (let ((o (%spawn-run "
    const k = Clun.spawn(['sh','-c','exec sleep 30']);
    k.kill();
    k.exited.then(c => console.log('killed exit='+c+' sig='+k.signalCode));")))
    (true (search "killed exit=null sig=SIGTERM" o) "kill() terminates the child (SIGTERM)")))

(define-test spawn/async-onexit
  (let ((o (%spawn-run "
    Clun.spawn(['sh','-c','exit 7'], {onExit: (code,sig) => console.log('onexit code='+code+' sig='+sig)});")))
    (true (search "onexit code=7 sig=null" o) "onExit fires with (code, signal)")))

(define-test spawn/async-1000-spawns-no-leak
  ;; 1,000 spawns, one at a time via a .then chain: each child is reaped before the next spawns, so
  ;; sequential completion IS the zero-zombie / no-fd-leak proof (a leak would accumulate and
  ;; eventually fail to spawn). Sequential rather than 1,000-concurrent: a concurrent burst opens
  ;; ~3,000 transient fds at once, exceeding the default 1024 fd ulimit under full-suite load — a
  ;; system-resource stress, not a clun behaviour.
  (let ((o (%spawn-run "
    let count = 0, allzero = true;
    function next() {
      if (count >= 1000) { console.log('total=' + count + ' allzero=' + allzero); return; }
      count++;
      Clun.spawn(['true'], {stdout:'ignore', stderr:'ignore'}).exited
        .then(c => { if (c !== 0) allzero = false; next(); });
    }
    next();")))
    (true (search "total=1000 allzero=true" o) "1,000 sequential spawns all exit 0, none leak/hang")))

;;; --- Issue #104 residual: object form, AbortSignal, timeout, killed, ref/unref ---

(define-test spawn/object-form-cmd
  (is string= "hello"
      (%spawn-str "new TextDecoder().decode(Clun.spawnSync({cmd:['echo','hello']}).stdout).trim()"))
  (is = 0 (%spawn-num "Clun.spawnSync({cmd:['true'], cwd:'/tmp'}).exitCode"))
  (let ((o (%spawn-run "
    const p = Clun.spawn({cmd:['echo','obj-form'], stdout:'pipe'});
    p.stdout.then(b => console.log('obj=['+new TextDecoder().decode(b).trim()+']'));")))
    (true (search "obj=[obj-form]" o) "async object form cmd drains stdout")))

(define-test spawn/sync-timeout-kills
  ;; sleep longer than timeout → killed via killSignal (default SIGTERM)
  (is string= "SIGTERM"
      (%spawn-str "Clun.spawnSync(['sleep','5'], {timeout:50}).signalCode"))
  (is string= "true"
      (%spawn-str "String(Clun.spawnSync(['sleep','5'], {timeout:50}).killed)"))
  (is string= "SIGKILL"
      (%spawn-str "Clun.spawnSync(['sleep','5'], {timeout:50, killSignal:'SIGKILL'}).signalCode")))

(define-test spawn/sync-abort-signal
  (is string= "SIGTERM"
      (%spawn-str "(() => { const c = new AbortController(); c.abort(); return Clun.spawnSync(['sleep','5'], {signal:c.signal}).signalCode; })()"))
  (is string= "true"
      (%spawn-str "(() => { const c = new AbortController(); c.abort(); return String(Clun.spawnSync(['sleep','5'], {signal:c.signal}).killed); })()")))

(define-test spawn/async-timeout-and-killed
  (let ((o (%spawn-run "
    const p = Clun.spawn(['sleep','30'], {timeout:40, stdout:'ignore', stderr:'ignore'});
    p.exited.then(c => console.log('to exit='+c+' sig='+p.signalCode+' killed='+p.killed));")))
    (true (search "to exit=null sig=SIGTERM killed=true" o)
          "async timeout kills with SIGTERM and sets killed")))

(define-test spawn/async-abort-signal
  (let ((o (%spawn-run "
    const c = new AbortController();
    const p = Clun.spawn(['sleep','30'], {signal:c.signal, killSignal:'SIGKILL', stdout:'ignore', stderr:'ignore'});
    setTimeout(() => c.abort(), 20);
    p.exited.then(c => console.log('ab exit='+c+' sig='+p.signalCode+' killed='+p.killed));")))
    (true (search "ab exit=null sig=SIGKILL killed=true" o)
          "AbortSignal abort kills with killSignal")))

(define-test spawn/async-kill-sets-killed
  (let ((o (%spawn-run "
    const k = Clun.spawn(['sh','-c','exec sleep 30'], {stdout:'ignore', stderr:'ignore'});
    console.log('before='+k.killed);
    k.kill();
    k.exited.then(() => console.log('after='+k.killed+' sig='+k.signalCode));")))
    (true (search "before=false" o) "killed is false before kill()")
    (true (search "after=true sig=SIGTERM" o) "kill() sets killed true")))

(define-test spawn/async-ref-unref-callable
  ;; Smoke: ref/unref return the subprocess; unref does not prevent exit settlement when
  ;; other work keeps the loop alive (the .exited chain).
  (let ((o (%spawn-run "
    const p = Clun.spawn(['true'], {stdout:'ignore', stderr:'ignore'});
    const u = p.unref();
    const r = p.ref();
    console.log('same='+(u===p)+','+(r===p));
    p.exited.then(c => console.log('refok='+c));")))
    (true (search "same=true,true" o) "ref/unref return the subprocess")
    (true (search "refok=0" o) "child still settles after ref/unref")))
