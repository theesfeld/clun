;;;; modules-tests.lisp — end-to-end module system (Phase 07): ESM linking, CJS
;;;; require, ESM↔CJS interop, JSON modules, import.meta. Each test builds a small
;;;; on-disk tree (a fixture app) and runs the entry through the loader, reading a
;;;; result off globalThis.

(in-package :clun-test)

(defun build-app (files)
  "FILES is a list of (relative-path . contents). Write them under a fresh temp dir
and return (values root entry-abs-path) where entry is the first file."
  (let* ((tmp (sys:pathname->native (sb-posix:mkdtemp "/tmp/clun-modapp-XXXXXX")))
         (real (sys:realpath tmp))
         (root (if (and (plusp (length real)) (char= (char real (1- (length real))) #\/))
                   (subseq real 0 (1- (length real))) real)))
    (dolist (f files) (rt-write (sys:path-join root (car f)) (cdr f)))
    (values root (sys:path-join root (caar files)))))

(defun run-app (files)
  "Build + run the fixture app (entry = first file), returning globalThis.R as a
string, or a THROW:<message> / ERR:<type> marker."
  (multiple-value-bind (root entry) (build-app files)
    (declare (ignore root))
    (handler-case
        (let ((r (eng::run-module-file entry :realm (eng:make-realm))))
          (let ((eng::*realm* r))
            (eng:to-string (eng:js-get (eng::realm-global r) "R"))))
      (eng:js-condition (c)
        (let ((eng::*realm* (eng:make-realm)))
          (format nil "THROW:~a" (eng:to-string (eng:js-condition-value c)))))
      (error (e) (format nil "ERR:~a" (type-of e))))))

;;; --- ESM linking ------------------------------------------------------------

(define-test modules/esm-named-and-default
  (is equal "9" (run-app '(("index.mjs" . "import {sq} from './m.mjs'; globalThis.R = sq(3);")
                           ("m.mjs" . "export function sq(x){ return x*x; }"))))
  (is equal "7" (run-app '(("index.mjs" . "import v from './m.mjs'; globalThis.R = v;")
                           ("m.mjs" . "export default 7;"))))
  (is equal "d:1,2" (run-app '(("index.mjs" . "import d, {a,b} from './m.mjs'; globalThis.R = d+':'+a+','+b;")
                               ("m.mjs" . "export const a=1, b=2; export default 'd';")))))

(define-test modules/esm-live-binding
  ;; an imported binding reflects the exporter mutating its own `let` (live, acyclic)
  (is equal "0,1" (run-app '(("index.mjs" . "import {count, bump} from './m.mjs'; const a=count; bump(); globalThis.R = a+','+count;")
                             ("m.mjs" . "export let count=0; export function bump(){ count++; }")))))

(define-test modules/esm-namespace-and-star
  (is equal "1,2" (run-app '(("index.mjs" . "import * as ns from './m.mjs'; globalThis.R = ns.a+','+ns.b;")
                             ("m.mjs" . "export const a=1, b=2;"))))
  (is equal "3" (run-app '(("index.mjs" . "import {a} from './re.mjs'; globalThis.R = a;")
                           ("re.mjs" . "export * from './m.mjs';")
                           ("m.mjs" . "export const a=3;")))))

(define-test modules/esm-reexport-named
  (is equal "5" (run-app '(("index.mjs" . "import {y} from './re.mjs'; globalThis.R = y;")
                           ("re.mjs" . "export {x as y} from './m.mjs';")
                           ("m.mjs" . "export const x=5;")))))

(define-test modules/import-const-binding
  ;; assigning to an import is a TypeError (const binding)
  (is equal "THROW:TypeError: Assignment to constant variable."
      (run-app '(("index.mjs" . "import {a} from './m.mjs'; a = 9; globalThis.R = a;")
                 ("m.mjs" . "export let a=1;")))))

;;; --- CJS require ------------------------------------------------------------

(define-test modules/cjs-require-relative
  (is equal "12" (run-app '(("index.mjs" . "import s from './c.cjs'; globalThis.R = s.add(5,7);")
                            ("c.cjs" . "const add=(a,b)=>a+b; module.exports={add};"))))
  ;; require inside a CJS module
  (is equal "42" (run-app '(("index.mjs" . "import v from './a.cjs'; globalThis.R = v;")
                            ("a.cjs" . "const b=require('./b.cjs'); module.exports = b.n;")
                            ("b.cjs" . "module.exports = { n: 42 };")))))

(define-test modules/cjs-exports-alias
  ;; `exports.x = …` and `module.exports = …` both work
  (is equal "3" (run-app '(("index.mjs" . "import m from './c.cjs'; globalThis.R = m.a + m.b;")
                           ("c.cjs" . "exports.a = 1; exports.b = 2;")))))

(define-test modules/cjs-cycle-partial-exports
  ;; a require cycle sees the partial exports of the mid-evaluation module
  (is equal "true" (run-app '(("index.mjs" . "import v from './a.cjs'; globalThis.R = v;")
                              ("a.cjs" . "exports.done=false; const b=require('./b.cjs'); exports.done=true; module.exports = b.sawPartial;")
                              ("b.cjs" . "const a=require('./a.cjs'); module.exports = { sawPartial: (a.done === false) };")))))

;;; --- interop ----------------------------------------------------------------

(define-test modules/import-cjs-default-and-named
  (is equal "hi bob" (run-app '(("index.mjs" . "import d from 'dep'; globalThis.R = d.greet('bob');")
                                ("node_modules/dep/package.json" . "{\"name\":\"dep\",\"main\":\"i.cjs\"}")
                                ("node_modules/dep/i.cjs" . "module.exports={greet:n=>'hi '+n};"))))
  ;; named import of a CJS module = its enumerable export keys (best-effort)
  (is equal "5" (run-app '(("index.mjs" . "import {five} from 'dep'; globalThis.R = five;")
                           ("node_modules/dep/package.json" . "{\"name\":\"dep\",\"main\":\"i.cjs\"}")
                           ("node_modules/dep/i.cjs" . "exports.five = 5;")))))

(define-test modules/require-of-esm-errors
  (is equal "true" (run-app '(("index.mjs" . "import ok from './c.cjs'; globalThis.R = ok;")
                              ("c.cjs" . "try { require('./e.mjs'); module.exports=false; } catch(e){ module.exports = e.message.indexOf('ES Module') >= 0; }")
                              ("e.mjs" . "export default 1;")))))

(define-test modules/scoped-and-conditions
  ;; scoped package resolved through an exports conditions map (import branch)
  (is equal "16" (run-app '(("index.mjs" . "import {sq} from '@acme/m'; globalThis.R = sq(4);")
                            ("node_modules/@acme/m/package.json"
                             . "{\"name\":\"@acme/m\",\"type\":\"module\",\"exports\":{\".\":{\"import\":\"./x.mjs\",\"require\":\"./x.cjs\"}}}")
                            ("node_modules/@acme/m/x.mjs" . "export const sq = x => x*x;")))))

;;; --- JSON + import.meta ------------------------------------------------------

(define-test modules/json-module
  (is equal "42" (run-app '(("index.mjs" . "import d from './d.json'; globalThis.R = d.answer;")
                            ("d.json" . "{\"answer\":42}"))))
  (is equal "1,2,3" (run-app '(("index.mjs" . "import a from './a.json'; globalThis.R = a.join(',');")
                               ("a.json" . "[1,2,3]")))))

(define-test modules/import-meta
  (is equal "true" (run-app '(("index.mjs" . "globalThis.R = import.meta.main;"))))
  (is equal "true" (run-app '(("index.mjs" . "globalThis.R = import.meta.url.startsWith('file://') && import.meta.filename.endsWith('index.mjs');")))))

;;; --- review-panel regressions -----------------------------------------------

(define-test modules/cjs-this-is-exports
  ;; top-level `this` in a CJS module is module.exports (Node wrapper .call), not global
  (is equal "exports" (run-app '(("index.mjs" . "import m from './c.cjs'; globalThis.R = m.who;")
                                 ("c.cjs" . "module.exports.who = (this === module.exports) ? 'exports' : 'WRONG';"))))
  ;; the `this.x = …` export pattern works and does NOT leak to globalThis
  (is equal "hi5" (run-app '(("index.mjs" . "import m from './c.cjs'; globalThis.R = m.g + m.n;")
                             ("c.cjs" . "this.g = 'hi'; this.n = 5;")))))

(define-test modules/cjs-throw-not-cached
  ;; a CJS module that throws is evicted from the cache; the next require re-runs it
  (is equal "boom#1|boom#2"
      (run-app '(("index.mjs" . "import m from './m.cjs'; globalThis.R = m;")
                 ("m.cjs" . "const a=[]; for (let i=0;i<2;i++){ try{ require('./b.cjs'); }catch(e){ a.push(e.message); } } module.exports=a.join('|');")
                 ("b.cjs" . "globalThis.C=(globalThis.C||0)+1; throw new Error('boom#'+globalThis.C);")))))

(define-test modules/json-default-as-and-named-error
  ;; `import { default as X }` from JSON binds the whole value
  (is equal "8080" (run-app '(("index.mjs" . "import { default as cfg } from './d.json'; globalThis.R = cfg.port;")
                              ("d.json" . "{\"port\":8080}"))))
  ;; a non-default named import from JSON is a link SyntaxError
  (is equal "THROW:SyntaxError: The requested module './d.json' does not provide an export named 'port'"
      (let ((r (run-app '(("index.mjs" . "import { port } from './d.json'; globalThis.R = port;")
                          ("d.json" . "{\"port\":8080}")))))
        ;; path in the message is a temp dir — assert the shape, not the exact path
        (if (and (search "THROW:SyntaxError" r) (search "does not provide an export named 'port'" r))
            "THROW:SyntaxError: The requested module './d.json' does not provide an export named 'port'"
            r))))

(define-test modules/export-default-named-local-binding
  ;; `export default function foo(){}` also creates a usable local `foo` (hoisted)
  (is equal "41:42" (run-app '(("index.mjs" . "import d from './m.mjs'; globalThis.R = d()+':'+globalThis.I;")
                               ("m.mjs" . "export default function foo(){ return 41; } globalThis.I = foo()+1;"))))
  ;; `export default class C {}` creates a usable local `C`
  (is equal "cm:cm" (run-app '(("index.mjs" . "import D from './m.mjs'; globalThis.R = new D().m()+':'+globalThis.J;")
                               ("m.mjs" . "export default class C { m(){return 'cm';} } globalThis.J = new C().m();")))))

(define-test modules/anonymous-default-function
  ;; anonymous `export default function(){}` / `async` / `*` parse and export
  (is equal "9" (run-app '(("index.mjs" . "import d from './m.mjs'; globalThis.R = d();")
                           ("m.mjs" . "export default function(){ return 9; }")))))

(define-test modules/export-early-errors
  ;; duplicate exported name is a SyntaxError
  (is equal "THROW:SyntaxError: Duplicate export 'x'"
      (run-app '(("index.mjs" . "import {x} from './m.mjs'; globalThis.R = x;")
                 ("m.mjs" . "let a=1,b=2; export {a as x}; export {b as x};"))))
  ;; duplicate default export is a SyntaxError
  (is equal "THROW:SyntaxError: Duplicate export 'default'"
      (run-app '(("index.mjs" . "import d from './m.mjs'; globalThis.R = d;")
                 ("m.mjs" . "export default 1; export default 2;"))))
  ;; `export {undeclared}` is a SyntaxError (never a raw Lisp crash)
  (is equal "THROW:SyntaxError: Export 'nope' is not defined in module"
      (run-app '(("index.mjs" . "import {nope} from './m.mjs'; globalThis.R = 1;")
                 ("m.mjs" . "export {nope};"))))
  ;; a duplicate import binding is a SyntaxError
  (is equal "THROW:SyntaxError: Identifier 'x' has already been declared"
      (run-app '(("index.mjs" . "import x from './a.mjs'; import x from './b.mjs'; globalThis.R = x;")
                 ("a.mjs" . "export default 1;")
                 ("b.mjs" . "export default 2;")))))
