;;;; compile-source-tests.lisp — Phase-25 COMPILE tier (m1).
;;;; The tier's correctness obligation is OBSERVABLE IDENTITY: for every function the source backend
;;;; compiles, its cl:compiled body must behave exactly like the per-node closure tree. These tests run
;;;; each program under *compile-tier-mode* :off (closure tree) and :eager (compiled body) and assert the
;;;; results are identical — AND that the source backend actually compiled ≥1 function (never vacuous).

(in-package :clun-test)

(defun ct-run (src mode)
  "Eval SRC with the COMPILE tier in MODE; return (values result compiled-count fallback-count)."
  (let ((eng::*compile-tier-mode* mode)
        (eng::*cs-compiled-count* 0)
        (eng::*cs-fallback-count* 0))
    (let ((r (eng:eval-source src)))
      (values r eng::*cs-compiled-count* eng::*cs-fallback-count*))))

(defun ct-diff-eq (src)
  "T iff SRC yields byte-identical string results under :off and :eager AND :eager compiled ≥1 function."
  (let ((off (eng::to-string (ct-run src :off))))
    (multiple-value-bind (e n fb) (ct-run src :eager)
      (declare (ignore fb))
      (and (plusp n) (string= off (eng::to-string e))))))

(define-test compile-source/differential-off-vs-eager
  ;; constructor member-writes + methods: reads/writes, arithmetic, comparison, conditional, logical,
  ;; unary, nested member chains, method calls, a driver loop exercising them thousands of times.
  (true (ct-diff-eq
         "function Vec(x,y){ this.x = x; this.y = y; }
          Vec.prototype.add    = function(o){ return this.x + o.x + (this.y + o.y); };
          Vec.prototype.dot    = function(o){ return this.x * o.x + this.y * o.y; };
          Vec.prototype.pick   = function(o){ return this.x < o.x ? this.x : o.x; };
          Vec.prototype.neg    = function(){ return -this.x - this.y; };
          Vec.prototype.flag   = function(o){ return (this.x > 0 && o.y < 10) || this.y === o.x; };
          Vec.prototype.combine= function(o){ return this.add(o) - this.dot(o) + this.pick(o); };
          var acc = 0;
          for (var i = 0; i < 500; i++) {
            var a = new Vec(i % 7, i % 5); var b = new Vec((i+3) % 11, (i+1) % 4);
            acc = acc + a.combine(b) + a.neg() + (a.flag(b) ? 1 : -1);
          }
          acc;"))
  ;; if/else chains, string returns, computed member assignment, typeof.
  (true (ct-diff-eq
         "function classify(n){ if (n < 0) { return 'neg'; } else { if (n === 0) { return 'zero'; } else { return 'pos'; } } }
          function tag(o, k){ o[k] = classify(o.v); return o[k]; }
          var out = '';
          for (var i = -3; i < 4; i++){ var o = { v: i }; out = out + tag(o, 'kind') + (typeof o.v) + ':'; }
          out;"))
  ;; every relational/equality/bit operator (the js-boolean-wrap contract).
  (true (ct-diff-eq
         "function ops(a,b){ return (a & b) + (a | b) + (a ^ b) + (a << 1) + (a >> 1) + (a % 3)
                                    + (a <= b ? 1 : 0) + (a >= b ? 1 : 0) + (a != b ? 1 : 0) + (a !== b ? 1 : 0); }
          var s = 0; for (var i = 0; i < 300; i++){ s = s + ops(i, i % 13); } s;"))
  ;; a coverable function that THROWS must throw identically (member read on undefined).
  (is eq t (let ((thrown-off nil) (thrown-eager nil))
             (handler-case (ct-run "function f(o){ return o.x; } f(undefined);" :off)
               (eng:js-condition () (setf thrown-off t)))
             (handler-case (ct-run "function f(o){ return o.x; } f(undefined);" :eager)
               (eng:js-condition () (setf thrown-eager t)))
             (eq thrown-off thrown-eager))))
