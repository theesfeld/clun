;;;; binary-tests.lisp — BigInt + ArrayBuffer/TypedArray/DataView/Text codecs (Phase 11).

(in-package :clun-test)

(defun bev (src)
  "eval-source in a fresh realm; ToString the result in that realm."
  (let* ((realm (eng:make-realm)) (v (eng:eval-source src :realm realm)))
    (let ((eng::*realm* realm)) (eng:to-string v))))

(defun bthrows (src)
  (handler-case (progn (bev src) nil) (eng:js-condition () t) (error () t)))

(define-test bigint/basics
  (is string= "bigint" (bev "typeof 10n"))
  (is string= "true"   (bev "10n === 10n"))
  (is string= "false"  (bev "10n === 10"))
  (is string= "true"   (bev "1n == 1"))
  (is string= "true"   (bev "9007199254740993n == 9007199254740993n"))
  (is string= "5,6,12,3,2,1024" (bev "[2n+3n,10n-4n,3n*4n,17n/5n,17n%5n,2n**10n].join(',')"))
  (is string= "1267650600228229401496703205376" (bev "(2n**100n).toString()"))
  (is string= "false,true" (bev "[!!0n, !!5n].join(',')")))

(define-test bigint/mixing-and-unary
  (true (bthrows "1n + 1"))
  (true (bthrows "1n - 1"))
  (true (bthrows "1n & 1"))
  (true (bthrows "+5n"))
  (true (bthrows "Number(5n)"))
  (true (bthrows "1n >>> 1n"))
  (is string= "-5" (bev "String(-5n)"))
  (is string= "true" (bev "String(1n < 2)"))
  (is string= "true" (bev "String(2n <= 2)")))

(define-test bigint/bitwise
  (is string= "8,15,6,-6,16,64"
      (bev "[12n & 10n, 12n | 3n, 5n ^ 3n, ~5n, 1n << 4n, 256n >> 2n].join(',')")))

(define-test bigint/constructor-and-statics
  (is string= "10,255,1" (bev "[BigInt(10),BigInt('0xff'),BigInt(true)].join(',')"))
  (true (bthrows "BigInt(1.5)"))
  (true (bthrows "new BigInt(1)"))
  (is string= "ff,11111111" (bev "[(255n).toString(16),(255n).toString(2)].join(',')"))
  (true (bthrows "(1n).toString(37)"))
  (is string= "0,255,-1" (bev "[BigInt.asUintN(8,256n),BigInt.asUintN(8,255n),BigInt.asIntN(8,255n)].join(',')"))
  (is string= "[object BigInt]" (bev "Object.prototype.toString.call(1n)")))

(define-test binary/arraybuffer
  (is string= "8,false" (bev "var b=new ArrayBuffer(8); b.byteLength+','+ArrayBuffer.isView(b)"))
  (is string= "4" (bev "String(new ArrayBuffer(8).slice(2,6).byteLength)"))
  (true (bthrows "new ArrayBuffer(7*1125899906842624)"))       ; 7 PiB → RangeError
  ;; transfer detaches the source
  (is string= "true" (bev "var b=new ArrayBuffer(4); b.transfer(); b.byteLength===0+''; String(b.byteLength===0)")))

(define-test binary/typedarray-core
  (is string= "4,4,0" (bev "var a=new Uint8Array(4); a.length+','+a.byteLength+','+a[0]"))
  (is string= "255,0,255" (bev "var a=new Uint8Array(3); a[0]=255;a[1]=256;a[2]=-1; a[0]+','+a[1]+','+a[2]"))
  (is string= "-56" (bev "var a=new Int8Array(1); a[0]=200; String(a[0])"))
  (is string= "255,0" (bev "var a=new Uint8ClampedArray(2); a[0]=300;a[1]=-5; a[0]+','+a[1]"))
  (is string= "2,2,4" (bev "var b=new ArrayBuffer(8);var a=new Int16Array(b,2,2); a.length+','+a.byteOffset+','+a.byteLength"))
  (is string= "[object Uint8Array]" (bev "Object.prototype.toString.call(new Uint8Array(1))"))
  (is string= "4,8" (bev "Uint32Array.BYTES_PER_ELEMENT+','+Float64Array.BYTES_PER_ELEMENT")))

(define-test binary/typedarray-methods
  (is string= "2,4,6" (bev "new Uint8Array([1,2,3]).map(x=>x*2).join(',')"))
  (is string= "2,4" (bev "new Int8Array([1,2,3,4]).filter(x=>x%2===0).join(',')"))
  (is string= "10" (bev "String(new Uint8Array([1,2,3,4]).reduce((a,b)=>a+b,0))"))
  (is string= "6" (bev "String(new Uint8Array([1,2,3]).reduce((a,b)=>a+b))"))
  (is string= "0,3,2,1" (bev "new Uint8Array([1,2,3]).reduceRight((a,b)=>a+','+b,'0')"))
  (is string= "undefined,1" (bev "new Uint8Array([1]).reduce((a,b)=>String(a)+','+b,undefined)"))
  (true (bthrows "new Uint8Array().reduce((a,b)=>a+b)"))
  (is string= "0,10,20,0" (bev "var a=new Uint8Array(4); a.set([10,20],1); a.join(',')"))
  (is string= "3,2,1" (bev "new Uint8Array([1,2,3]).reverse().join(',')"))
  (is string= "1,2,3" (bev "new Uint8Array([3,1,2]).sort().join(',')"))
  (is string= "9,8,7" (bev "[...new Uint8Array([9,8,7])].join(',')"))
  (is string= "1,2,3" (bev "Uint8Array.of(1,2,3).join(',')"))
  (is string= "3" (bev "String(new Uint8Array([1,2,3]).at(-1))"))
  ;; subarray shares the buffer
  (is string= "99" (bev "var a=new Uint8Array([1,2,3,4]); a.subarray(1,3)[0]=99; String(a[1])")))

(define-test binary/dataview
  (is string= "-1,4294967295" (bev "var d=new DataView(new ArrayBuffer(8)); d.setInt32(0,-1); d.getInt32(0)+','+d.getUint32(0)"))
  (is string= "258,513" (bev "var d=new DataView(new ArrayBuffer(4)); d.setInt16(0,258); d.getInt16(0)+','+d.getInt16(0,true)"))
  (is string= "3.14" (bev "var d=new DataView(new ArrayBuffer(8)); d.setFloat64(0,3.14); String(d.getFloat64(0))"))
  (true (bthrows "new DataView(new ArrayBuffer(2)).getInt32(0)")))          ; OOB → RangeError

(define-test binary/bigint64-and-text
  (is string= "9007199254740993,bigint" (bev "var a=new BigInt64Array(1); a[0]=9007199254740993n; a[0]+','+typeof a[0]"))
  (is string= "18446744073709551615" (bev "var a=new BigUint64Array(1); a[0]=-1n; String(a[0])"))
  (is string= "104,195,169,108,108,111" (bev "[...new TextEncoder().encode('héllo')].join(',')"))
  (is string= "héllo" (bev "new TextDecoder().decode(new Uint8Array([104,195,169,108,108,111]))"))
  (is string= "日本語" (bev "new TextDecoder().decode(new TextEncoder().encode('日本語'))"))
  (true (bthrows "new TextDecoder('utf-16')")))                             ; non-UTF-8 label → RangeError
