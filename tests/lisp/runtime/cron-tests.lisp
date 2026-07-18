;;;; cron-tests.lisp — pure-CL Clun.cron parser + in-process scheduling (Issue #136).

(in-package :clun-test)

(defun cron-iso (expr from-iso)
  (let* ((from-ms
           (let ((realm (eng:make-realm)))
             (unwind-protect
                  (progn
                    (rt:install-runtime realm :argv (list :script "[cron]") :cwd "/tmp" :colors nil)
                    (let ((eng:*realm* realm))
                      (eng::js-date-tv
                       (eng:js-construct (eng:js-get (eng:realm-global realm) "Date")
                                         (list from-iso)))))
               (eng:teardown-realm realm))))
         (parsed (rt::parse-cron-expression expr))
         (next (rt::cron-next-ms parsed from-ms)))
    (when next
      (let ((realm (eng:make-realm)))
        (unwind-protect
             (progn
               (rt:install-runtime realm :argv (list :script "[cron]") :cwd "/tmp" :colors nil)
               (let* ((eng:*realm* realm)
                      (d (eng:js-construct (eng:js-get (eng:realm-global realm) "Date")
                                           (list next))))
                 (eng:js-call (eng:js-get d "toISOString") d '())))
          (eng:teardown-realm realm))))))

(define-test cron/parse-expression-nicknames
  (let ((h (rt::parse-cron-expression "@hourly")))
    (true (rt::cron-expr-p h))
    (is = 1 (rt::cron-expr-minutes h))
    (true (rt::cron-expr-days-wildcard-p h))
    (true (rt::cron-expr-weekdays-wildcard-p h)))
  (let ((d (rt::parse-cron-expression "@daily")))
    (is = 1 (rt::cron-expr-minutes d))
    (is = 1 (rt::cron-expr-hours d))))

(define-test cron/parse-rejects-bad
  (fail (rt::parse-cron-expression "invalid expr") rt::cron-parse-error)
  (fail (rt::parse-cron-expression "* * * *") rt::cron-parse-error)
  (fail (rt::parse-cron-expression "60 * * * *") rt::cron-parse-error)
  (fail (rt::parse-cron-expression "* * * * * *") rt::cron-parse-error))

(define-test cron/next-utc-basic
  (is equal "2026-06-15T09:00:00.000Z"
      (cron-iso "0 9 * * *" "2026-06-15T00:00:00.000Z"))
  (is equal "2026-06-16T09:00:00.000Z"
      (cron-iso "0 9 * * *" "2026-06-15T09:00:00.000Z"))
  (is equal "2026-06-15T12:00:00.000Z"
      (cron-iso "0 12 * * MON" "2026-06-14T23:00:00.000Z")))

(define-test cron/next-leap-and-impossible
  (is equal "2028-02-29T00:00:00.000Z"
      (cron-iso "0 0 29 2 *" "2026-01-01T00:00:00.000Z"))
  (true (null (cron-iso "0 0 30 2 *" "2026-01-01T00:00:00.000Z"))))

(define-test cron/next-dom-dow-or
  ;; 13th OR Friday: from 2026-01-01 (Thu) → Fri Jan 2
  (is equal "2026-01-02T00:00:00.000Z"
      (cron-iso "0 0 13 * 5" "2026-01-01T00:00:00.000Z")))

(define-test cron/next-weekday-7-sunday
  (is equal "2026-01-02T00:00:00.000Z"
      (cron-iso "0 0 * * 1-7" "2026-01-01T00:00:00.000Z"))
  (is equal "2026-01-04T00:00:00.000Z"
      (cron-iso "0 0 * * 7" "2026-01-01T00:00:00.000Z"))
  (is equal "2026-01-03T00:00:00.000Z"
      (cron-iso "0 0 * * 6-7" "2026-01-01T00:00:00.000Z")))

(define-test cron/runtime-api-shape
  (is equal (format nil "function true function function~%")
      (run-rt
       "var j=Clun.cron('@hourly',function(){});console.log(typeof Clun.cron,typeof Clun.cron.parse==='function',typeof j.stop,typeof j.unref);j.stop()")))

(define-test cron/runtime-parse
  (is equal (format nil "2026-06-15T09:00:00.000Z null~%")
      (run-rt
       "var n=Clun.cron.parse('0 9 * * *', new Date('2026-06-15T00:00:00Z'));var z=Clun.cron.parse('0 0 30 2 *', new Date('2026-01-01T00:00:00Z'));console.log(n.toISOString(), z)")))

(define-test cron/runtime-validate
  (is equal (format nil "invalid nofuture notstring~%")
      (run-rt
       "function t(fn){try{fn();return 'ok'}catch(e){return /Invalid cron/.test(e.message)?'invalid':/no future/.test(e.message)?'nofuture':/string cron/.test(e.message)?'notstring':'other:'+e.message}}console.log(t(()=>Clun.cron('bad',()=>{})),t(()=>Clun.cron('0 0 30 2 *',()=>{})),t(()=>Clun.cron(123,()=>{})))")))

(define-test cron/runtime-stop-idempotent
  (is equal (format nil "* * * * *~%ok~%")
      (run-rt
       "var j=Clun.cron('* * * * *',()=>{});console.log(j.cron);j.stop();j.stop();j.ref();console.log('ok')")))

(define-test cron/runtime-named-fields
  (is equal (format nil "0 9 * JAN-DEC MON-FRI~%")
      (run-rt
       "var j=Clun.cron('0 9 * JAN-DEC MON-FRI',()=>{});console.log(j.cron);j.stop()")))
