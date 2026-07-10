;;;; numbers-tests.lisp — Number<->String, ToInt32/ToUint32, NaN/Inf/-0 helpers.

(in-package :clun-test)

(define-test numbers/nan-inf-negzero-helpers
  (true (eng:js-nan-p eng:*js-nan*))
  (false (eng:js-nan-p 0d0))
  (false (eng:js-nan-p "x"))
  (true (eng:js-infinite-p eng:+js-infinity+))
  (true (eng:js-infinite-p eng:+js-neg-infinity+))
  (false (eng:js-infinite-p 1d0))
  (true (eng:js-finite-p 1d0))
  (false (eng:js-finite-p eng:*js-nan*))
  (false (eng:js-finite-p eng:+js-infinity+))
  (true (eng:js-neg-zero-p -0d0))
  (false (eng:js-neg-zero-p 0d0))          ; +0 is not -0 (eql -0d0 0d0) => NIL
  (true (eng:js-zero-p 0d0))
  (true (eng:js-zero-p -0d0)))

(define-test numbers/to-string-known-answers
  (dolist (pair '((0d0 . "0") (-0d0 . "0") (1d0 . "1") (-1d0 . "-1")
                  (1.5d0 . "1.5") (-1.5d0 . "-1.5") (0.1d0 . "0.1")
                  (0.5d0 . "0.5") (100d0 . "100") (1000d0 . "1000")
                  (123456789d0 . "123456789")
                  (0.000001d0 . "0.000001")          ; 1e-6 -> fixed
                  (1d-7 . "1e-7")                     ; boundary -> exponential
                  (1d21 . "1e+21")                    ; boundary -> exponential
                  (1d20 . "100000000000000000000")    ; still fixed
                  (1234.5678d0 . "1234.5678")
                  (5d-324 . "5e-324")                 ; least positive subnormal
                  (9007199254740992d0 . "9007199254740992") ; 2^53
                  (1000000000000000128d0 . "1000000000000000100")
                  (3.14159d0 . "3.14159")
                  (-0.0000001d0 . "-1e-7")))
    (is string= (cdr pair) (eng:number->js-string (car pair)))))

(define-test numbers/to-string-nan-inf
  (is string= "NaN" (eng:number->js-string eng:*js-nan*))
  (is string= "Infinity" (eng:number->js-string eng:+js-infinity+))
  (is string= "-Infinity" (eng:number->js-string eng:+js-neg-infinity+)))

(define-test numbers/to-string-round-trips
  ;; every produced string must read back to the same double
  (dolist (x (list 0.1d0 0.2d0 0.3d0 1d0 1.1d0 123.456d0 1d-300 1d300
                   9007199254740993d0 5d-324 1234567890.12345d0 2.2250738585072014d-308))
    (is eql x (eng:js-string->number (eng:number->js-string x)))))

(define-test numbers/string-to-number
  (macrolet ((n= (str want) `(is eql ,want (eng:js-string->number ,str))))
    (n= "" 0d0)
    (n= "   " 0d0)
    (n= "0" 0d0)
    (n= "42" 42d0)
    (n= "  42  " 42d0)
    (n= "-42" -42d0)
    (n= "+42" 42d0)
    (n= "3.14" 3.14d0)
    (n= ".5" 0.5d0)
    (n= "5." 5d0)
    (n= "1e3" 1000d0)
    (n= "1E3" 1000d0)
    (n= "1.5e-3" 0.0015d0)
    (n= "0x10" 16d0)
    (n= "0X1F" 31d0)
    (n= "0o17" 15d0)
    (n= "0b1010" 10d0)
    (n= "010" 10d0)                    ; no legacy octal in ToNumber
    (n= "Infinity" eng:+js-infinity+)
    (n= "+Infinity" eng:+js-infinity+)
    (n= "-Infinity" eng:+js-neg-infinity+)))

(define-test numbers/string-to-number-nan
  (dolist (s '("abc" "1e" "0x" "0xG" "1.2.3" "- 1" "1 2" "++1" "0b" "0b2"
               "Infinityx" "NaN" "." "1e+" "-"))
    (true (eng:js-nan-p (eng:js-string->number s)))))

(define-test numbers/string-to-number-ascii-digits-only
  ;; ECMA §12.9.3 admits ONLY ASCII digits; non-ASCII Nd chars -> NaN, never a value.
  (flet ((s (&rest codes) (map 'string #'code-char codes)))
    (dolist (bad (list (s #x0661)                       ; Arabic-Indic 1
                       (s #x0662 #x0663)                ; Arabic-Indic 23
                       (s #xFF11)                       ; fullwidth 1
                       (s #xFF11 #xFF12 #xFF13)         ; fullwidth 123
                       (s #x0967)                       ; Devanagari 1
                       (s #x31 #x0662)                  ; "1" + Arabic 2 (mixed)
                       (s #x30 #x2E #x0662)             ; "0." + Arabic 2 (fraction)
                       (s #x31 #x65 #x0662)             ; "1e" + Arabic 2 (exponent)
                       (s #x30 #x78 #x0663)))           ; "0x" + Arabic 3 (hex body)
      (true (eng:js-nan-p (eng:js-string->number bad))))))

(define-test numbers/string-to-number-huge
  ;; gate-named "huge strings": over/underflow must resolve without giant bignums
  (is eql eng:+js-infinity+ (eng:js-string->number (make-string 400 :initial-element #\9)))
  (is eql 0d0 (eng:js-string->number
               (concatenate 'string "0." (make-string 400 :initial-element #\0) "1")))
  (is eql eng:+js-infinity+ (eng:js-string->number "1e400"))
  (is eql eng:+js-infinity+ (eng:js-string->number "1e1000000"))   ; must be fast, not O(exp)
  (is eql 0d0 (eng:js-string->number "1e-400"))
  (is eql 0d0 (eng:js-string->number "1e-1000000"))
  (is eql -0d0 (eng:js-string->number "-1e-400"))                  ; underflow keeps sign
  (true (eng:js-neg-zero-p (eng:js-string->number "-1e-400")))
  (is eql 1.8446744073709552d19 (eng:js-string->number "0xffffffffffffffff")))

(define-test numbers/to-int32
  (macrolet ((i= (in want) `(is eql ,want (eng:to-int32 ,in))))
    (i= 0d0 0) (i= -0d0 0) (i= 1d0 1) (i= -1d0 -1)
    (i= 3.9d0 3) (i= -3.9d0 -3)
    (i= 2147483647d0 2147483647)       ; 2^31-1
    (i= 2147483648d0 -2147483648)      ; 2^31 wraps to min
    (i= 4294967296d0 0)                ; 2^32 -> 0
    (i= 4294967297d0 1)                ; 2^32+1 -> 1
    (i= -1d0 -1)
    (i= eng:*js-nan* 0)
    (i= eng:+js-infinity+ 0)
    (i= eng:+js-neg-infinity+ 0)
    ;; true modulo-2^32 reduction of huge magnitudes (matches V8: 1e21|0)
    (i= 1d21 -559939584)
    (i= -1d21 559939584)
    (i= 4294967297.9d0 1)              ; fractional beyond 2^32
    (i= 2147483648.9d0 -2147483648))
  ;; ToInt32 goes through ToNumber, so strings work
  (is eql 255 (eng:to-int32 "0xFF"))
  (is eql 1 (eng:to-int32 eng:+true+)))

(define-test numbers/to-uint32
  (macrolet ((u= (in want) `(is eql ,want (eng:to-uint32 ,in))))
    (u= 0d0 0) (u= 1d0 1)
    (u= -1d0 4294967295)               ; 2^32-1
    (u= 4294967296d0 0)
    (u= 4294967297d0 1)
    (u= -2147483648d0 2147483648)
    (u= eng:*js-nan* 0)
    (u= eng:+js-infinity+ 0)
    (u= 3.9d0 3)
    (u= 1d21 3735027712)              ; huge magnitude mod 2^32 (V8: 1e21>>>0)
    (u= -1d21 559939584)))
