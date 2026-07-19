;;;; web-platform-tests.lisp — residual Web Standard globals (#207).

(in-package :clun-test)

(defun %wp-run (realm src)
  (eng:eval-source src :realm realm))

(defun %with-wp-runtime (thunk)
  (let ((realm (eng:make-realm)))
    (rt:install-runtime realm :argv '(:script "[test]" :rest nil) :cwd "/tmp")
    (unwind-protect
         (let ((eng:*realm* realm))
           (funcall thunk realm (eng:realm-global realm)))
      (eng:teardown-realm realm))))

(define-test web-platform/globals-present
  (%with-wp-runtime
   (lambda (realm g)
     (declare (ignore g))
     (multiple-value-bind (kind value)
         (eng:run-callback-to-settlement
          (lambda ()
            (%wp-run
             realm
             "(() => {
                const names = [
                  'EventTarget','Event','CustomEvent','DOMException',
                  'File','FormData','MessageChannel','CompressionStream',
                  'DecompressionStream','CountQueuingStrategy',
                  'ByteLengthQueuingStrategy','performance','atob','btoa'
                ];
                for (const n of names) {
                  if (typeof globalThis[n] === 'undefined')
                    throw new Error('missing:' + n);
                }
                if (typeof crypto.subtle.digest !== 'function')
                  throw new Error('no-subtle');
                return 'ok';
              })()"))
          realm)
       (is eq :fulfilled kind)
       (is string= "ok" (eng:to-string value))))))

(define-test web-platform/form-data-and-file
  (%with-wp-runtime
   (lambda (realm g)
     (declare (ignore g))
     (multiple-value-bind (kind value)
         (eng:run-callback-to-settlement
          (lambda ()
            (%wp-run
             realm
             "(() => {
                const fd = new FormData();
                fd.append('a', '1');
                fd.append('a', '2');
                if (fd.get('a') !== '1') throw new Error('get-first');
                if (fd.getAll('a').length !== 2) throw new Error('getAll');
                fd.set('a', 'x');
                if (fd.get('a') !== 'x') throw new Error('set');
                const f = new File([new TextEncoder().encode('z')], 'z.txt');
                if (f.name !== 'z.txt') throw new Error('name');
                if (f.size !== 1) throw new Error('size');
                return 'ok';
              })()"))
          realm)
       (is eq :fulfilled kind)
       (is string= "ok" (eng:to-string value))))))

(define-test web-platform/event-target
  (%with-wp-runtime
   (lambda (realm g)
     (declare (ignore g))
     (multiple-value-bind (kind value)
         (eng:run-callback-to-settlement
          (lambda ()
            (%wp-run
             realm
             "(() => {
                const t = new EventTarget();
                let n = 0;
                t.addEventListener('e', (ev) => { n += ev.detail; });
                t.dispatchEvent(new CustomEvent('e', { detail: 3 }));
                if (n !== 3) throw new Error('detail');
                return 'ok';
              })()"))
          realm)
       (is eq :fulfilled kind)
       (is string= "ok" (eng:to-string value))))))

(define-test web-platform/atob-btoa
  (%with-wp-runtime
   (lambda (realm g)
     (declare (ignore g))
     (multiple-value-bind (kind value)
         (eng:run-callback-to-settlement
          (lambda ()
            (%wp-run
             realm
             "(() => {
                if (btoa('Man') !== 'TWFu') throw new Error('btoa');
                if (atob('TWFu') !== 'Man') throw new Error('atob');
                return 'ok';
              })()"))
          realm)
       (is eq :fulfilled kind)
       (is string= "ok" (eng:to-string value))))))

(define-test web-platform/compression-roundtrip
  (%with-wp-runtime
   (lambda (realm g)
     (declare (ignore g))
     (multiple-value-bind (kind value)
         (eng:run-callback-to-settlement
          (lambda ()
            (%wp-run
             realm
             "(async () => {
                const text = 'hello-web-platform';
                const cs = new CompressionStream('gzip');
                const w = cs.writable.getWriter();
                const r = cs.readable.getReader();
                const rp = r.read();
                await w.write(new TextEncoder().encode(text));
                await w.close();
                const compressed = await rp;
                if (compressed.done) throw new Error('no-gz');
                const ds = new DecompressionStream('gzip');
                const dw = ds.writable.getWriter();
                const dr = ds.readable.getReader();
                const outP = dr.read();
                await dw.write(compressed.value);
                await dw.close();
                const out = await outP;
                if (new TextDecoder().decode(out.value) !== text)
                  throw new Error('roundtrip');
                return 'ok';
              })()"))
          realm)
       (is eq :fulfilled kind)
       (is string= "ok" (eng:to-string value))))))

(define-test web-platform/subtle-digest-sha256
  (%with-wp-runtime
   (lambda (realm g)
     (declare (ignore g))
     (multiple-value-bind (kind value)
         (eng:run-callback-to-settlement
          (lambda ()
            (%wp-run
             realm
             "(async () => {
                const ab = await crypto.subtle.digest(
                  'SHA-256', new TextEncoder().encode('abc'));
                if (ab.byteLength !== 32) throw new Error('len');
                return 'ok';
              })()"))
          realm)
       (is eq :fulfilled kind)
       (is string= "ok" (eng:to-string value))))))
