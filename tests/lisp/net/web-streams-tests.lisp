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
