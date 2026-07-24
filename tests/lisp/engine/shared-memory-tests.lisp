;;;; shared-memory-tests.lisp — SharedArrayBuffer + Atomics (Issue #338).

(in-package :clun-test)

(defun sm-ev (src)
  (let* ((realm (eng:make-realm)) (v (eng:eval-source src :realm realm)))
    (let ((eng::*realm* realm)) (eng:to-string v))))

(defun sm-throws (src)
  (handler-case (progn (sm-ev src) nil) (eng:js-condition () t) (error () t)))

(define-test shared-memory/sab-basics
  (is string= "function" (sm-ev "typeof SharedArrayBuffer"))
  (is string= "16" (sm-ev "String(new SharedArrayBuffer(16).byteLength)"))
  (is string= "[object SharedArrayBuffer]"
      (sm-ev "Object.prototype.toString.call(new SharedArrayBuffer(4))"))
  (is string= "4" (sm-ev "String(new SharedArrayBuffer(8).slice(2,6).byteLength)"))
  (true (sm-throws "SharedArrayBuffer(4)"))
  (true (sm-throws "new SharedArrayBuffer(7*1125899906842624)")))

(define-test shared-memory/typedarray-over-sab
  (is string= "1,2,3"
      (sm-ev "var s=new SharedArrayBuffer(4); var a=new Uint8Array(s); a[0]=1;a[1]=2;a[2]=3; a[0]+','+a[1]+','+a[2]"))
  (is string= "true"
      (sm-ev "var s=new SharedArrayBuffer(8); var a=new Int32Array(s); a[0]=42; String(a.buffer===s)"))
  (is string= "99"
      (sm-ev "var s=new SharedArrayBuffer(4); var a=new Int32Array(s); var d=new DataView(s); a[0]=99; String(d.getInt32(0,true))")))

(define-test shared-memory/atomics-rmw
  (is string= "object" (sm-ev "typeof Atomics"))
  (is string= "0,1,1"
      (sm-ev "var a=new Int32Array(new SharedArrayBuffer(4)); var o=Atomics.add(a,0,1); o+','+a[0]+','+Atomics.load(a,0)"))
  (is string= "5,3"
      (sm-ev "var a=new Int32Array(new SharedArrayBuffer(4)); Atomics.store(a,0,5); var o=Atomics.sub(a,0,2); o+','+a[0]"))
  (is string= "0xff,0xf"
      (sm-ev "var a=new Int32Array(new SharedArrayBuffer(4)); Atomics.store(a,0,0xff); var o=Atomics.and(a,0,0x0f); '0x'+o.toString(16)+',0x'+a[0].toString(16)"))
  (is string= "10,20"
      (sm-ev "var a=new Int32Array(new SharedArrayBuffer(4)); Atomics.store(a,0,10); var o=Atomics.exchange(a,0,20); o+','+a[0]"))
  (is string= "1,2"
      (sm-ev "var a=new Int32Array(new SharedArrayBuffer(4)); Atomics.store(a,0,1); var o=Atomics.compareExchange(a,0,1,2); o+','+a[0]"))
  (is string= "1,1"
      (sm-ev "var a=new Int32Array(new SharedArrayBuffer(4)); Atomics.store(a,0,1); var o=Atomics.compareExchange(a,0,9,2); o+','+a[0]"))
  (is string= "true,true"
      (sm-ev "String(Atomics.isLockFree(4))+','+String(Atomics.isLockFree(8))"))
  (true (sm-throws "Atomics.add(new Float64Array(new SharedArrayBuffer(8)),0,1)")))

(define-test shared-memory/atomics-on-arraybuffer
  ;; Atomics RMW on non-shared buffers is allowed by the JS engine model we use
  ;; for single-thread correctness (V8 allows it for non-wait ops).
  (is string= "3"
      (sm-ev "var a=new Int32Array(new ArrayBuffer(4)); Atomics.store(a,0,3); String(Atomics.load(a,0))")))

(define-test shared-memory/atomics-wait-notify-single
  (is string= "not-equal"
      (sm-ev "var a=new Int32Array(new SharedArrayBuffer(4)); Atomics.store(a,0,1); Atomics.wait(a,0,0,10)"))
  (is string= "timed-out"
      (sm-ev "var a=new Int32Array(new SharedArrayBuffer(4)); Atomics.wait(a,0,0,0)"))
  (true (sm-throws "Atomics.wait(new Int32Array(new ArrayBuffer(4)),0,0,1)")))

(define-test shared-memory/atomics-cross-thread
  "Two SBCL threads, each with its own realm, share one SAB data block."
  (let* ((main (eng:make-realm))
         (eng:*realm* main)
         (sab (eng:eval-source "new SharedArrayBuffer(4)" :realm main))
         (block (eng:js-shared-array-buffer-block sab))
         (result nil)
         (done nil)
         (waiter
           (sb-thread:make-thread
            (lambda ()
              (let* ((r (eng:make-realm))
                     (eng:*realm* r)
                     (local (eng:wrap-shared-array-buffer block))
                     (g (eng:realm-global r)))
                (eng:data-prop g "sab" local)
                (setf result
                      (eng:to-string
                       (eng:eval-source
                        "var a=new Int32Array(sab); Atomics.wait(a,0,0,2000)"
                        :realm r)))
                (setf done t)))
            :name "sab-waiter")))
    (sleep 0.05)
    (let ((eng:*realm* main))
      (eng:data-prop (eng:realm-global main) "sab" sab)
      (eng:eval-source
       "var a=new Int32Array(sab); Atomics.store(a,0,1); Atomics.notify(a,0,1)"
       :realm main))
    (sb-thread:join-thread waiter :timeout 3)
    (true done)
    (is string= "ok" result)))
