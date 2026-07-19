;;;; ffi-tests.lisp — pure-CL FFI / native-addon host (Issue #178).

(in-package :clun-test)

(defun %ffi-kind (thunk)
  (handler-case (progn (funcall thunk) nil)
    (clun.ffi:ffi-error (c) (clun.ffi:ffi-error-kind c))))

(define-test ffi/types
  (is string= "i32" (clun.ffi:normalize-type-name "i32"))
  (is string= "int32_t" (clun.ffi:normalize-type-name "int32_t"))
  (is eql 5 (clun.ffi:type-id "i32"))
  (is eq :int (clun.ffi:type-category "i32"))
  (is eq :ptr (clun.ffi:type-category "pointer"))
  (is eq :cstring (clun.ffi:type-category "cstring"))
  (true (plusp (length (clun.ffi:ffi-type-enum-alist))))
  (is eq :invalid-type
      (%ffi-kind (lambda () (clun.ffi:type-id "not-a-real-type")))))

(define-test ffi/heap-and-reads
  (clun.ffi:reset-ffi-state)
  (let* ((p (clun.ffi:heap-alloc 16))
         (e (clun.ffi:lookup-ptr p)))
    (true (plusp p))
    (true (clun.ffi:ptr-entry-p e))
    (clun.ffi:write-u8 p 0 42)
    (clun.ffi:write-u32 p 4 65535)
    (is eql 42 (clun.ffi:read-u8 p 0))
    (is eql 65535 (clun.ffi:read-u32 p 4))
    (is eq :range
        (%ffi-kind (lambda () (clun.ffi:read-u8 p 100))))
    (clun.ffi:heap-free p)
    (is eq :invalid-ptr
        (%ffi-kind (lambda () (clun.ffi:read-u8 p 0))))))

(define-test ffi/cstring
  (clun.ffi:reset-ffi-state)
  (let* ((p (clun.ffi:alloc-cstring "hello-ffi"))
         (s (clun.ffi:read-cstring p)))
    (is string= "hello-ffi" s)
    (is string= "hell" (clun.ffi:read-cstring p 0 4))))

(define-test ffi/builtin-library-call
  (clun.ffi:reset-ffi-state)
  (let* ((handle (clun.ffi:open-library
                  "clun_demo"
                  `(("add" :args ("i32" "i32") :returns "i32")
                    ("version" :args () :returns "cstring"))))
         (bound (getf handle :bound))
         (add (gethash "add" bound))
         (ver (gethash "version" bound)))
    (is eql 5 (clun.ffi:call-symbol add '(2 3)))
    (let ((vp (clun.ffi:call-symbol ver '())))
      (true (integerp vp))
      (is string= "clun-ffi-1.0.0" (clun.ffi:read-cstring vp)))
    (true (member "clun_demo" (clun.ffi:list-libraries) :test #'string=))))

(define-test ffi/register-library
  (clun.ffi:reset-ffi-state)
  (clun.ffi:register-library
   "adder"
   `(("add" :args ("i32" "i32") :returns "i32"
            :fn ,(lambda (a b) (+ a b)))
     ("neg" :args ("i32") :returns "i32"
            :fn ,(lambda (a) (- a)))))
  (let* ((h (clun.ffi:open-library
             "adder"
             `(("add" :args ("i32" "i32") :returns "i32")
               ("neg" :args ("i32") :returns "i32"))))
         (add (gethash "add" (getf h :bound)))
         (neg (gethash "neg" (getf h :bound))))
    (is eql 30 (clun.ffi:call-symbol add '(10 20)))
    (is eql -7 (clun.ffi:call-symbol neg '(7)))))

(define-test ffi/link-symbols
  (clun.ffi:reset-ffi-state)
  (let* ((fn (lambda (a b) (* a b)))
         (pid (clun.ffi:register-fn-ptr fn
                                        (list :args '("i32" "i32") :returns "i32")))
         (h (clun.ffi:link-symbols
             `(("mul" :args ("i32" "i32") :returns "i32" :ptr ,pid))))
         (mul (gethash "mul" (getf h :bound))))
    (is eql 42 (clun.ffi:call-symbol mul '(6 7)))))

(define-test ffi/cc-c-like
  (clun.ffi:reset-ffi-state)
  (let* ((src "int add(int a, int b) { return a + b; }
int sub(int a, int b) { return a - b; }
")
         (lib (clun.ffi:compile-cc-source
               src
               `(("add" :args ("i32" "i32") :returns "i32")
                 ("sub" :args ("i32" "i32") :returns "i32"))))
         (h (clun.ffi:open-library
             (clun.ffi:fl-name lib)
             `(("add" :args ("i32" "i32") :returns "i32")
               ("sub" :args ("i32" "i32") :returns "i32"))))
         (add (gethash "add" (getf h :bound)))
         (sub (gethash "sub" (getf h :bound))))
    (is eql 9 (clun.ffi:call-symbol add '(4 5)))
    (is eql 3 (clun.ffi:call-symbol sub '(10 7)))))

(define-test ffi/napi-addon
  (clun.ffi:reset-ffi-state)
  (let ((exports (clun.ffi:load-addon "clun_napi_demo")))
    (true (hash-table-p exports))
    (is string= "hello-from-pure-cl-napi" (funcall (gethash "hello" exports)))
    (is eql 7 (funcall (gethash "add" exports) 3 4))
    (is string= "1.0.0" (gethash "version" exports)))
  (true (member "clun_napi_demo" (clun.ffi:list-addons) :test #'string=)))

(define-test ffi/view-source
  (let ((src (clun.ffi:view-source-for-symbol "add" '("i32" "i32") "i32")))
    (true (search "add" src))
    (true (search "pure-CL" src))))

(define-test ffi/suffix
  (let ((s (clun.ffi:shared-library-suffix)))
    (true (member s '("so" "dylib" "dll") :test #'string=))))

(define-test ffi/memory-roundtrip-via-demo
  (clun.ffi:reset-ffi-state)
  (let* ((p (clun.ffi:heap-alloc 8))
         (h (clun.ffi:open-library
             "clun_demo"
             `(("write_u32" :args ("ptr" "u32") :returns "void")
               ("read_u32" :args ("ptr") :returns "u32"))))
         (w (gethash "write_u32" (getf h :bound)))
         (r (gethash "read_u32" (getf h :bound))))
    (clun.ffi:call-symbol w (list p 123456789))
    (is eql 123456789 (clun.ffi:call-symbol r (list p)))
    (is eql 123456789 (clun.ffi:read-u32 p 0))))

(define-test ffi/js-bun-ffi-surface
  "Smoke Clun.ffi / native / napi JS surface (script context; bun:ffi via Clun.ffi)."
  (clun.ffi:reset-ffi-state)
  (let ((realm (eng:make-realm)))
    (rt:install-runtime realm :argv '(:script "[ffi-test]" :rest nil)
                        :cwd "/tmp" :colors nil)
    (eng:run-source
     "
const lib = Clun.ffi.dlopen('clun_demo', {
  add: { args: ['i32', 'i32'], returns: 'i32' },
  version: { returns: 'cstring', args: [] },
});
globalThis.sum = lib.symbols.add(20, 22);
// cstring returns are decoded to JS strings by the pure-CL host
globalThis.ver = lib.symbols.version();
const p = Clun.ffi.alloc(8);
const wlib = Clun.ffi.dlopen('clun_demo', {
  write_u32: { args: ['ptr', 'u32'], returns: 'void' },
  read_u32: { args: ['ptr'], returns: 'u32' },
});
wlib.symbols.write_u32(p, 99);
globalThis.r = wlib.symbols.read_u32(p);
const libs = Clun.ffi.listLibraries();
globalThis.hasDemo = libs.indexOf('clun_demo') >= 0 || libs.indexOf('libclun_demo') >= 0;
const napi = { exports: {} };
process.dlopen(napi, 'clun_napi_demo');
globalThis.hello = napi.exports.hello();
globalThis.suffix = Clun.ffi.suffix;
globalThis.backend = Clun.ffi.backend;
globalThis.nativeBackend = Clun.native.backend;
globalThis.napiBackend = Clun.napi.backend;
"
     :realm realm)
    (let ((eng:*realm* realm)
          (g (eng:realm-global realm)))
      (is = 42d0 (eng:js-get g "sum"))
      (is string= "clun-ffi-1.0.0" (eng:js-get g "ver"))
      (is = 99d0 (eng:js-get g "r"))
      (true (eng:js-string-p (eng:js-get g "suffix")))
      (true (eq eng:+true+ (eng:js-get g "hasDemo")))
      (is string= "pure-cl" (eng:js-get g "backend"))
      (is string= "hello-from-pure-cl-napi" (eng:js-get g "hello"))
      (is string= "pure-cl" (eng:js-get g "nativeBackend"))
      (is string= "pure-cl" (eng:js-get g "napiBackend")))))
