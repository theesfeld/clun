;;;; cron-tests.lisp — Phase 76 Clun.cron pure-CL parse + in-process scheduling.

(in-package :clun-test)

(defun %cron-eval (src)
  (let ((realm (eng:make-realm)))
    (unwind-protect
         (progn (rt:install-runtime realm :argv (list :script "[cron-test]" :rest nil)
                                    :cwd "/tmp" :colors nil)
                (eng:eval-source src :realm realm))
      (ignore-errors (eng:teardown-realm realm)))))

(defun %cron-str (src) (eng:to-string (%cron-eval src)))
(defun %cron-num (src) (eng:to-number (%cron-eval src)))

(defun %cron-run (src)
  "Eval SRC driving the loop; return captured stdout."
  (let ((realm (eng:make-realm)) (out (make-string-output-stream)))
    (unwind-protect
         (progn (rt:install-runtime realm :argv (list :script "[cron-run]" :rest nil)
                                    :cwd "/tmp" :colors nil)
                (let ((*standard-output* out)) (eng:eval-source src :realm realm))
                (get-output-stream-string out))
      (ignore-errors (eng:teardown-realm realm)))))

;;; --- parse -------------------------------------------------------------------

(define-test cron/parse-hourly-utc
  (is string= "2026-06-15T09:00:00.000Z"
      (%cron-str "Clun.cron.parse('0 9 * * *', new Date('2026-06-15T00:00:00Z')).toISOString()")))

(define-test cron/parse-strictly-after
  (is string= "2026-06-16T09:00:00.000Z"
      (%cron-str "Clun.cron.parse('0 9 * * *', new Date('2026-06-15T09:00:00Z')).toISOString()")))

(define-test cron/parse-weekday-named
  (is string= "2026-06-15T12:00:00.000Z"
      (%cron-str "Clun.cron.parse('0 12 * * MON', new Date('2026-06-14T23:00:00Z')).toISOString()")))

(define-test cron/parse-feb-29-leap
  (is string= "2028-02-29T00:00:00.000Z"
      (%cron-str "Clun.cron.parse('0 0 29 2 *', new Date('2026-01-01T00:00:00Z')).toISOString()")))

(define-test cron/parse-impossible-null
  (is string= "null"
      (%cron-str "String(Clun.cron.parse('0 0 30 2 *', new Date('2026-01-01T00:00:00Z')))")))

(define-test cron/parse-dom-dow-or
  ;; 0 0 13 * 5 → 13th OR Friday. From 2026-01-01 (Thu) first is Fri Jan 2.
  (is string= "2026-01-02T00:00:00.000Z"
      (%cron-str "Clun.cron.parse('0 0 13 * 5', new Date('2026-01-01T00:00:00Z')).toISOString()")))

(define-test cron/parse-weekday-7-sunday
  (is string= "2026-01-04T00:00:00.000Z"
      (%cron-str "Clun.cron.parse('0 0 * * 7', new Date('2026-01-01T00:00:00Z')).toISOString()")))

(define-test cron/parse-nicknames
  (is string= "2026-06-15T13:00:00.000Z"
      (%cron-str "Clun.cron.parse('@hourly', new Date('2026-06-15T12:00:00Z')).toISOString()"))
  (is string= "2026-06-16T00:00:00.000Z"
      (%cron-str "Clun.cron.parse('@daily', new Date('2026-06-15T12:00:00Z')).toISOString()"))
  (is string= "2027-01-01T00:00:00.000Z"
      (%cron-str "Clun.cron.parse('@yearly', new Date('2026-06-15T00:00:00Z')).toISOString()")))

(define-test cron/parse-steps-and-lists
  (is string= "2026-06-15T00:15:00.000Z"
      (%cron-str "Clun.cron.parse('*/15 * * * *', new Date('2026-06-15T00:00:00Z')).toISOString()"))
  (is string= "2026-06-15T00:15:00.000Z"
      (%cron-str "Clun.cron.parse('0,15,30,45 * * * *', new Date('2026-06-15T00:00:00Z')).toISOString()")))

(define-test cron/parse-invalid-throws
  (is string= "TypeError"
      (%cron-str "(() => { try { Clun.cron.parse('invalid'); return 'NO'; } catch (e) { return e.name; } })()"))
  (is string= "TypeError"
      (%cron-str "(() => { try { Clun.cron.parse('* * * *'); return 'NO'; } catch (e) { return e.name; } })()"))
  (is string= "TypeError"
      (%cron-str "(() => { try { Clun.cron.parse(123); return 'NO'; } catch (e) { return e.name; } })()")))

;;; --- in-process job ----------------------------------------------------------

(define-test cron/job-handle-shape
  (is string= "* * * * *"
      (%cron-str "(() => { const j = Clun.cron('* * * * *', () => {}); const c = j.cron; j.stop(); return c; })()"))
  (is string= "function"
      (%cron-str "(() => { const j = Clun.cron('@hourly', () => {}); const t = typeof j.stop; j.stop(); return t; })()"))
  (is string= "true"
      (%cron-str "(() => { const j = Clun.cron('* * * * *', () => {}); const ok = j.unref() === j && j.ref() === j && j.stop() === j; return String(ok); })()")))

(define-test cron/job-invalid-expression
  (is string= "TypeError"
      (%cron-str "(() => { try { Clun.cron('invalid expr', () => {}); return 'NO'; } catch (e) { return e.name; } })()"))
  (is string= "TypeError"
      (%cron-str "(() => { try { Clun.cron('0 0 30 2 *', () => {}); return 'NO'; } catch (e) { return e.name; } })()")))

(define-test cron/job-stop-before-fire
  (is string= "false"
      (%cron-str "(() => { let called = false; const j = Clun.cron('* * * * *', () => { called = true; }); j.stop(); return String(called); })()")))

(define-test cron/job-named-fields
  (is string= "0 9 * JAN-DEC MON-FRI"
      (%cron-str "(() => { const j = Clun.cron('0 9 * JAN-DEC MON-FRI', () => {}); const c = j.cron; j.stop(); return c; })()")))

(define-test cron/os-level-fail-closed
  (let ((realm (eng:make-realm)))
    (unwind-protect
         (progn
           (rt:install-runtime realm :argv (list :script "[cron-os]" :rest nil)
                               :cwd "/tmp" :colors nil)
           (eng:eval-source
            "globalThis.osName = 'NO';
             globalThis.osMsg = '';
             Clun.cron('./worker.js', '@daily', 'daily-cleanup')
               .then(() => { globalThis.osName = 'RESOLVED'; },
                     (e) => { globalThis.osName = e.name; globalThis.osMsg = e.message; });"
            :realm realm)
           (let ((g (eng:realm-global realm)))
             (is string= "Error" (eng:js-get g "osName"))
             (true (search "not available" (eng:js-get g "osMsg")))))
      (ignore-errors (eng:teardown-realm realm)))))

(define-test cron/remove-fail-closed
  (let ((realm (eng:make-realm)))
    (unwind-protect
         (progn
           (rt:install-runtime realm :argv (list :script "[cron-rm]" :rest nil)
                               :cwd "/tmp" :colors nil)
           (eng:eval-source
            "globalThis.rmName = 'NO';
             Clun.cron.remove('weekly-report')
               .then(() => { globalThis.rmName = 'OK'; },
                     (e) => { globalThis.rmName = e.name; });"
            :realm realm)
           (is string= "Error" (eng:js-get (eng:realm-global realm) "rmName")))
      (ignore-errors (eng:teardown-realm realm)))))

;;; --- pure-CL parser unit (no JS) ---------------------------------------------

(define-test cron/cl-parser-nicknames
  (let ((e (rt::parse-cron-expression "@hourly")))
    (true (rt::cron-expression-p e))
    (is = 1 (rt::cronx-minutes e))
    (true (rt::cronx-days-wildcard e))))

(define-test cron/cl-next-occurrence
  (let* ((e (rt::parse-cron-expression "0 9 * * *"))
         (from (eng::%compose-tv 2026 5 15 0 0 0 0)) ; 2026-06-15T00:00:00Z (month 0-based in compose)
         (next (rt::cron-next-ms e from)))
    (is = (eng::%compose-tv 2026 5 15 9 0 0 0) next)))
