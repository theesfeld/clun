;;;; ct-diff.lisp — Phase-25 COMPILE-tier m1 differential harness.
;;;; Runs a battery of JS programs (each exercising the source backend's coverable subset) under
;;;; *compile-tier-mode* :off (closure tree) and :eager (cl:compiled body), asserting byte-identical
;;;; results. Confirms the cs path is actually taken (non-zero compiled count) so the test isn't vacuous.
;;;; Run: sbcl --non-interactive --no-userinit --no-sysinit --load scripts/registry.lisp --load scripts/ct-diff.lisp

(load (merge-pathnames "registry.lisp" *load-truename*))
(handler-bind ((warning #'muffle-warning)) (asdf:load-system :clun))

(in-package :clun.engine)

(defvar *cases*
  (list
   ;; constructor with member-writes + methods: reads, writes, arithmetic, comparison, conditional,
   ;; logical, method calls, unary, nested member chains, a driver loop calling them many times.
   "function Vec(x,y){ this.x = x; this.y = y; }
    Vec.prototype.add    = function(o){ return this.x + o.x + (this.y + o.y); };
    Vec.prototype.dot    = function(o){ return this.x * o.x + this.y * o.y; };
    Vec.prototype.pick   = function(o){ return this.x < o.x ? this.x : o.x; };
    Vec.prototype.neg    = function(){ return -this.x - this.y; };
    Vec.prototype.flag   = function(o){ return (this.x > 0 && o.y < 10) || this.y === o.x; };
    Vec.prototype.combine= function(o){ return this.add(o) - this.dot(o) + this.pick(o); };
    var acc = 0;
    for (var i = 0; i < 2000; i++) {
      var a = new Vec(i % 7, i % 5);
      var b = new Vec((i+3) % 11, (i+1) % 4);
      acc = acc + a.combine(b) + a.neg() + (a.flag(b) ? 1 : -1);
    }
    acc;"
   ;; string keys, typeof, member assignment to computed index, nested if/else chains.
   "function classify(n){ if (n < 0) { return 'neg'; } else { if (n === 0) { return 'zero'; } else { return 'pos'; } } }
    function tag(o, k){ o[k] = classify(o.v); return o[k]; }
    var out = '';
    for (var i = -3; i < 4; i++){ var o = { v: i }; out = out + tag(o, 'kind') + (typeof o.v) + ':'; }
    out;"
   ;; equality/relational operator coverage + bit ops + remainder.
   "function ops(a,b){ return (a & b) + (a | b) + (a ^ b) + (a << 1) + (a >> 1) + (a % 3) + (a <= b ? 1 : 0) + (a >= b ? 1 : 0) + (a != b ? 1 : 0) + (a !== b ? 1 : 0); }
    var s = 0; for (var i = 0; i < 500; i++){ s = s + ops(i, i % 13); } s;"))

(let ((pass 0) (fail 0))
  (dolist (src *cases*)
    (setf *cs-compiled-count* 0 *cs-fallback-count* 0)
    (let* ((off   (let ((*compile-tier-mode* :off))   (to-string (eval-source src))))
           (n-off *cs-compiled-count*))
      (declare (ignore n-off))
      (setf *cs-compiled-count* 0 *cs-fallback-count* 0)
      (let* ((eager   (let ((*compile-tier-mode* :eager)) (to-string (eval-source src))))
             (n-eager *cs-compiled-count*)
             (n-fb    *cs-fallback-count*))
        (cond
          ((not (string= off eager))
           (incf fail)
           (format t "~&FAIL: off=~s eager=~s (compiled=~d fallback=~d)~%" off eager n-eager n-fb))
          ((zerop n-eager)
           (incf fail)
           (format t "~&FAIL(vacuous): identical but source backend compiled 0 functions~%"))
          (t
           (incf pass)
           (format t "~&PASS: ~s  (eager compiled ~d fn, fell back ~d)~%"
                   (if (> (length off) 40) (concatenate 'string (subseq off 0 40) "...") off)
                   n-eager n-fb)))))
    )
  (format t "~%=== ct-diff: ~d passed, ~d failed ===~%" pass fail)
  (sb-ext:exit :code (if (zerop fail) 0 1)))
