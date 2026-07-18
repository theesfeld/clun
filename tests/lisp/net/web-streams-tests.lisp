;;;; web-streams-tests.lisp — Phase 38 Partial: Response/Request.body ReadableStream
;;;; consumer (one-chunk getReader/read, cancel, lock vs mixin methods).

(in-package :clun-test)

(defun %ws-run (realm src)
  (eng:eval-source src :realm realm))

(defun %with-runtime (thunk)
  (let ((realm (eng:make-realm)))
    (rt:install-runtime realm :argv '(:script "[test]" :rest nil) :cwd "/tmp")
    (unwind-protect
         (let ((eng:*realm* realm))
           (funcall thunk realm (eng:realm-global realm)))
      (eng:teardown-realm realm))))

(define-test web-streams/response-body-get-reader-read
  (%with-runtime
   (lambda (realm g)
     (declare (ignore g))
     (multiple-value-bind (kind value)
         (eng:run-callback-to-settlement
          (lambda ()
            (%ws-run
             realm
             "(() => {
                const r = new Response('stream-body');
                if (r.bodyUsed) throw new Error('used-before');
                const stream = r.body;
                if (stream == null) throw new Error('body-null');
                if (typeof ReadableStream === 'undefined') throw new Error('no-RS');
                if (!(stream instanceof ReadableStream)) throw new Error('not-RS');
                if (stream.locked) throw new Error('locked-early');
                const reader = stream.getReader();
                if (!stream.locked) throw new Error('not-locked');
                return reader.read().then((first) => {
                  if (first.done) throw new Error('first-done');
                  const text = new TextDecoder().decode(first.value);
                  if (text !== 'stream-body') throw new Error('bad-chunk:' + text);
                  if (!r.bodyUsed) throw new Error('not-used-after-read');
                  return reader.read().then((second) => {
                    if (!second.done) throw new Error('second-not-done');
                    return text;
                  });
                });
              })()"))
          realm)
       (is eq :fulfilled kind)
       (is string= "stream-body" (eng:to-string value))))))

(define-test web-streams/response-body-access-does-not-consume
  (%with-runtime
   (lambda (realm g)
     (declare (ignore g))
     (multiple-value-bind (kind value)
         (eng:run-callback-to-settlement
          (lambda ()
            (%ws-run
             realm
             "(() => {
                const r = new Response('still-there');
                void r.body;
                if (r.bodyUsed) throw new Error('used-on-access');
                return r.text().then((t) => {
                  if (!r.bodyUsed) throw new Error('not-used-after-text');
                  return t;
                });
              })()"))
          realm)
       (is eq :fulfilled kind)
       (is string= "still-there" (eng:to-string value))))))

(define-test web-streams/response-null-body
  (%with-runtime
   (lambda (realm g)
     (declare (ignore g))
     (multiple-value-bind (kind value)
         (eng:run-callback-to-settlement
          (lambda ()
            (%ws-run
             realm
             "(() => {
                const r = new Response(null);
                if (r.body !== null) throw new Error('expected-null-body');
                return 'ok';
              })()"))
          realm)
       (is eq :fulfilled kind)
       (is string= "ok" (eng:to-string value))))))

(define-test web-streams/locked-stream-blocks-text
  (%with-runtime
   (lambda (realm g)
     (declare (ignore g))
     (multiple-value-bind (kind value)
         (eng:run-callback-to-settlement
          (lambda ()
            (%ws-run
             realm
             "(() => {
                const r = new Response('locked');
                r.body.getReader();
                try {
                  r.text();
                  return 'did-not-throw';
                } catch (e) {
                  return e && e.name === 'TypeError' ? 'type-error' : String(e);
                }
              })()"))
          realm)
       (is eq :fulfilled kind)
       (is string= "type-error" (eng:to-string value))))))

(define-test web-streams/reader-cancel-marks-used
  (%with-runtime
   (lambda (realm g)
     (declare (ignore g))
     (multiple-value-bind (kind value)
         (eng:run-callback-to-settlement
          (lambda ()
            (%ws-run
             realm
             "(() => {
                const r = new Response('cancel-me');
                const reader = r.body.getReader();
                return reader.cancel().then(() => {
                  if (!r.bodyUsed) throw new Error('not-used');
                  return reader.read().then((chunk) =>
                    chunk.done ? 'cancelled-eof' : 'still-data');
                });
              })()"))
          realm)
       (is eq :fulfilled kind)
       (is string= "cancelled-eof" (eng:to-string value))))))

(define-test web-streams/construct-start-controller
  (%with-runtime
   (lambda (realm g)
     (declare (ignore g))
     (multiple-value-bind (kind value)
         (eng:run-callback-to-settlement
          (lambda ()
            (%ws-run
             realm
             "(() => {
                const stream = new ReadableStream({
                  start(controller) {
                    controller.enqueue(new TextEncoder().encode('hi'));
                    controller.close();
                  }
                });
                const reader = stream.getReader();
                return reader.read().then((first) => {
                  const text = new TextDecoder().decode(first.value);
                  return reader.read().then((second) =>
                    second.done ? text : 'not-done');
                });
              })()"))
          realm)
       (is eq :fulfilled kind)
       (is string= "hi" (eng:to-string value))))))

(define-test web-streams/request-body-stream
  (%with-runtime
   (lambda (realm g)
     (declare (ignore g))
     (multiple-value-bind (kind value)
         (eng:run-callback-to-settlement
          (lambda ()
            (%ws-run
             realm
             "(() => {
                const req = new Request('https://example.com', {
                  method: 'POST',
                  body: 'req-body'
                });
                return req.body.getReader().read().then((chunk) => {
                  if (chunk.done) throw new Error('done');
                  return new TextDecoder().decode(chunk.value);
                });
              })()"))
          realm)
       (is eq :fulfilled kind)
       (is string= "req-body" (eng:to-string value))))))

(define-test web-streams/writable-stream-write-close
  (%with-runtime
   (lambda (realm g)
     (declare (ignore g))
     (multiple-value-bind (kind value)
         (eng:run-callback-to-settlement
          (lambda ()
            (%ws-run
             realm
             "(() => {
                const parts = [];
                const ws = new WritableStream({
                  write(chunk) { parts.push(new TextDecoder().decode(chunk)); },
                  close() { parts.push('closed'); }
                });
                const w = ws.getWriter();
                return w.write(new TextEncoder().encode('ab'))
                  .then(() => w.write(new TextEncoder().encode('cd')))
                  .then(() => w.close())
                  .then(() => parts.join(','));
              })()"))
          realm)
       (is eq :fulfilled kind)
       (is string= "ab,cd,closed" (eng:to-string value))))))

(define-test web-streams/transform-stream-identity
  (%with-runtime
   (lambda (realm g)
     (declare (ignore g))
     (multiple-value-bind (kind value)
         (eng:run-callback-to-settlement
          (lambda ()
            (%ws-run
             realm
             "(() => {
                const ts = new TransformStream();
                const w = ts.writable.getWriter();
                const r = ts.readable.getReader();
                const p = r.read().then((first) => {
                  const text = new TextDecoder().decode(first.value);
                  return r.read().then((second) =>
                    second.done ? text : 'not-done');
                });
                return w.write(new TextEncoder().encode('pipe-me'))
                  .then(() => w.close())
                  .then(() => p);
              })()"))
          realm)
       (is eq :fulfilled kind)
       (is string= "pipe-me" (eng:to-string value))))))

(define-test web-streams/transform-stream-custom
  (%with-runtime
   (lambda (realm g)
     (declare (ignore g))
     (multiple-value-bind (kind value)
         (eng:run-callback-to-settlement
          (lambda ()
            (%ws-run
             realm
             "(() => {
                const ts = new TransformStream({
                  transform(chunk, controller) {
                    const t = new TextDecoder().decode(chunk).toUpperCase();
                    controller.enqueue(new TextEncoder().encode(t));
                  }
                });
                const w = ts.writable.getWriter();
                const r = ts.readable.getReader();
                const p = r.read().then((first) =>
                  new TextDecoder().decode(first.value));
                return w.write(new TextEncoder().encode('hi'))
                  .then(() => w.close())
                  .then(() => p);
              })()"))
          realm)
       (is eq :fulfilled kind)
       (is string= "HI" (eng:to-string value))))))

(define-test web-streams/byob-reader-fills-view
  (%with-runtime
   (lambda (realm g)
     (declare (ignore g))
     (multiple-value-bind (kind value)
         (eng:run-callback-to-settlement
          (lambda ()
            (%ws-run
             realm
             "(() => {
                const stream = new ReadableStream({
                  start(controller) {
                    controller.enqueue(new TextEncoder().encode('abcdef'));
                    controller.close();
                  }
                });
                const reader = stream.getReader({ mode: 'byob' });
                const view = new Uint8Array(3);
                return reader.read(view).then((first) => {
                  if (first.done) throw new Error('done-early');
                  const a = new TextDecoder().decode(first.value);
                  const view2 = new Uint8Array(8);
                  return reader.read(view2).then((second) => {
                    if (second.done) throw new Error('done-mid');
                    const b = new TextDecoder().decode(second.value);
                    return reader.read(new Uint8Array(1)).then((third) =>
                      third.done ? (a + '|' + b) : 'extra');
                  });
                });
              })()"))
          realm)
       (is eq :fulfilled kind)
       (is string= "abc|def" (eng:to-string value))))))


(define-test web-streams/large-transfer-bounded
  "Multi-MiB synthetic body through Transform without retaining the whole body."
  (%with-runtime
   (lambda (realm g)
     (declare (ignore g))
     (multiple-value-bind (kind value)
         (eng:run-callback-to-settlement
          (lambda ()
            (%ws-run
             realm
             "(() => {
                const chunkSize = 65536;
                const chunks = 64; // 4 MiB total
                let produced = 0;
                let consumed = 0;
                const ts = new TransformStream({
                  transform(chunk, controller) {
                    consumed += chunk.byteLength || chunk.length || 0;
                    controller.enqueue(chunk);
                  }
                });
                const w = ts.writable.getWriter();
                const r = ts.readable.getReader();
                async function produce() {
                  for (let i = 0; i < chunks; i++) {
                    const u8 = new Uint8Array(chunkSize);
                    u8.fill(i & 0xff);
                    await w.write(u8);
                    produced += chunkSize;
                  }
                  await w.close();
                }
                async function consume() {
                  while (true) {
                    const x = await r.read();
                    if (x.done) break;
                  }
                }
                return Promise.all([produce(), consume()]).then(() =>
                  produced + ',' + consumed + ',' +
                  (produced === consumed ? 'ok' : 'mismatch'));
              })()"))
          realm)
       (is eq :fulfilled kind)
       (is string= "4194304,4194304,ok" (eng:to-string value))))))
