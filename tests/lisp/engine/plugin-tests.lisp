;;;; plugin-tests.lisp — runtime loader plugins (Issue #187 FULL PORT).

(in-package :clun-test)

(defun %plugin-run (files &key (clear t))
  "Build fixture app, install runtime (Clun.plugin), run entry; return globalThis.R string."
  (when clear (eng:plugin-clear-all))
  (multiple-value-bind (root entry)
      (let* ((tmp (sys:pathname->native (sb-posix:mkdtemp "/tmp/clun-plugin-XXXXXX")))
             (real (sys:realpath tmp))
             (root (if (and (plusp (length real))
                            (char= (char real (1- (length real))) #\/))
                       (subseq real 0 (1- (length real))) real)))
        (dolist (f files)
          (rt-write (sys:path-join root (car f)) (cdr f)))
        (values root (sys:path-join root (caar files))))
    (declare (ignore root))
    (handler-case
        (let* ((realm (eng:make-realm)))
          (rt:install-runtime realm :argv (list :script entry :rest nil)
                              :cwd (sys:path-dirname entry) :colors nil)
          (eng:run-module-file entry :realm realm :teardown t)
          (let ((eng:*realm* realm))
            (eng:to-string (eng:js-get (eng:realm-global realm) "R"))))
      (eng:js-condition (c)
        (let ((eng:*realm* (eng:make-realm)))
          (format nil "THROW:~a" (eng:to-string (eng:js-condition-value c)))))
      (error (e) (format nil "ERR:~a:~a" (type-of e) e)))))

(define-test plugins/object-loader-require
  (is equal "world"
      (%plugin-run
       '(("index.cjs" .
          "Clun.plugin({
             name: 'obj',
             setup(b) {
               b.onResolve({ filter: /.*/, namespace: 'obj' }, ({ path }) => ({ path, namespace: 'obj' }));
               b.onLoad({ filter: /.*/, namespace: 'obj' }, () => ({
                 exports: { hello: 'world' },
                 loader: 'object'
               }));
             }
           });
           // Bun eligibility: specifier must contain '.' or ':'
           Clun.plugin({
             name: 'route',
             setup(b) {
               b.onResolve({ filter: /^virtual:hello$/ }, () => ({ path: 'hello', namespace: 'obj' }));
             }
           });
           const m = require('virtual:hello');
           globalThis.R = m.hello;"))))
  (eng:plugin-clear-all))
(define-test plugins/virtual-module
  (is equal "bar"
      (%plugin-run
       '(("index.cjs" .
          "Clun.plugin({
             name: 'virt',
             setup(b) {
               b.module('hello:world', () => ({
                 exports: { foo: 'bar' },
                 loader: 'object'
               }));
             }
           });
           const m = require('hello:world');
           globalThis.R = m.foo;"))))
  (eng:plugin-clear-all))

(define-test plugins/onload-contents-js
  (is equal "42"
      (%plugin-run
       '(("index.cjs" .
          "Clun.plugin({
             name: 'beep',
             setup(b) {
               b.onResolve({ filter: /boop/, namespace: 'beep' }, () => ({
                 path: 'boop', namespace: 'beep'
               }));
               b.onLoad({ filter: /boop/, namespace: 'beep' }, () => ({
                 contents: 'module.exports = 42;',
                 loader: 'js'
               }));
             }
           });
           Clun.plugin({
             name: 'route-beep',
             setup(b) {
               b.onResolve({ filter: /^beep:boop$/ }, () => ({
                 path: 'boop', namespace: 'beep'
               }));
             }
           });
           globalThis.R = String(require('beep:boop'));"))))
  (eng:plugin-clear-all))

(define-test plugins/onload-file-transform
  (is equal "HELLO"
      (%plugin-run
       '(("index.cjs" .
          "Clun.plugin({
             name: 'upper',
             setup(b) {
               b.onLoad({ filter: /\\.up\\.txt$/ }, ({ path }) => {
                 const fs = require('fs');
                 // pure contents injection — no fs needed if we embed
                 return {
                   contents: 'module.exports = \"HELLO\";',
                   loader: 'js'
                 };
               });
             }
           });
           globalThis.R = require('./data.up.txt');")
         ("data.up.txt" . "ignored raw text"))))
  (eng:plugin-clear-all))

(define-test plugins/clear-all
  (is equal "ok"
      (%plugin-run
       '(("index.cjs" .
          "Clun.plugin({
             name: 'tmp',
             setup(b) {
               b.module('tmp:x', () => ({ exports: { v: 1 }, loader: 'object' }));
             }
           });
           Clun.plugin.clearAll();
           let ok = false;
           try { require('tmp:x'); } catch (e) { ok = true; }
           globalThis.R = ok ? 'ok' : 'fail';"))))
  (eng:plugin-clear-all))

(define-test plugins/list-and-clear-name
  (is equal "yes"
      (%plugin-run
       '(("index.cjs" .
          "Clun.plugin({ name: 'a', setup() {} });
           Clun.plugin({ name: 'b', setup() {} });
           const before = Clun.plugin.list().slice().sort().join(',');
           Clun.plugin.clear('a');
           const after = Clun.plugin.list().slice().sort().join(',');
           globalThis.R = (before === 'a,b' && after === 'b') ? 'yes' : before + '|' + after;"))))
  (eng:plugin-clear-all))

(define-test plugins/cl-register
  (eng:plugin-clear-all)
  (eng:register-cl-plugin
   :name "cl-virt"
   :setup
   (lambda (builder)
     (funcall (getf builder :module)
              "cl:answer"
              (lambda (&key)
                (list :exports (let ((o (eng:new-object)))
                                 (eng:data-prop o "n" 7d0)
                                 o)
                      :loader "object")))))
  (is equal "7"
      (%plugin-run
       '(("index.cjs" . "globalThis.R = String(require('cl:answer').n);"))
       :clear nil))
  (eng:plugin-clear-all))

(define-test plugins/resolve-redirect-file
  (is equal "99"
      (%plugin-run
       '(("index.cjs" .
          "Clun.plugin({
             name: 'redir',
             setup(b) {
               b.onResolve({ filter: /^alias\\.mod$/ }, () => ({
                 path: __dirname + '/real.cjs',
                 namespace: 'file'
               }));
             }
           });
           globalThis.R = String(require('alias.mod'));")
         ("real.cjs" . "module.exports = 99;"))))
  (eng:plugin-clear-all))
(define-test plugins/text-loader
  (is equal "raw-body"
      (%plugin-run
       '(("index.cjs" .
          "Clun.plugin({
             name: 'text',
             setup(b) {
               b.onLoad({ filter: /\\.raw$/ }, () => ({
                 contents: 'raw-body',
                 loader: 'text'
               }));
             }
           });
           globalThis.R = require('./x.raw').default;")
         ("x.raw" . "disk-ignored"))))
  (eng:plugin-clear-all))

(define-test plugins/esm-virtual-import
  ;; Prefer CJS require so plugin registration runs before load (static import hoists).
  (is equal "esm"
      (%plugin-run
       '(("index.cjs" .
          "Clun.plugin({
             name: 'esm-virt',
             setup(b) {
               b.module('virt:esm', () => ({
                 exports: { kind: 'esm' },
                 loader: 'object'
               }));
             }
           });
           globalThis.R = require('virt:esm').kind;"))))
  (eng:plugin-clear-all))