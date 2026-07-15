;;;; compile-source-tests.lisp -- Phase-25 COMPILE tier m2 differential coverage.
;;;; Every admitted source-backend construct is exercised with :off as the semantic oracle.  The
;;;; eager run must compile at least one body, reject none, fall back on none, and produce the same
;;;; structured result (including the full observable shape of an uncaught JS exception).

(in-package :clun-test)

(defun ct-property-signature (object key)
  (if (eng::has-property object key)
      (let ((value (eng::js-get object key)))
        (if (eng::js-object-p value)
            (list :object (eng::js-object-class value))
            (list (eng::js-type value) (eng::to-string value))))
      :absent))

(defun ct-value-signature (value)
  "Return a stable, type-preserving description of a JS value.
Error-like objects include NAME and MESSAGE so exception comparisons cannot pass merely because both
runs threw some object.  Differential fixtures return primitives, so other objects need only retain
their internal class here."
  (if (eng::js-object-p value)
      (list :object (eng::js-object-class value)
            (ct-property-signature value "name")
            (ct-property-signature value "message"))
      (list (eng::js-type value) (eng::to-string value))))

(defun ct-run (source mode)
  "Evaluate SOURCE in MODE and return outcome plus the four COMPILE-tier counters."
  (let ((eng::*compile-tier-mode* mode)
        (eng::*cs-trace-executions* nil))
    (eng::cs-reset-telemetry)
    (let* ((realm (eng:make-realm))
           (eng::*realm* realm)
           (outcome
             (handler-case
                 (list :return (ct-value-signature (eng:eval-source source :realm realm)))
               (eng:js-condition (condition)
                 (list :throw (class-name (class-of condition))
                       (ct-value-signature (eng:js-condition-value condition)))))))
      (values outcome
              eng::*cs-compiled-count*
              eng::*cs-ineligible-count*
              eng::*cs-fallback-count*
              eng::*cs-executed-count*))))

(defun ct-diff-check (source &optional expected-string)
  "Check SOURCE under :off and :eager; EXPECTED-STRING, when supplied, is the normal JS result."
  (multiple-value-bind (off off-compiled off-ineligible off-fallback)
      (ct-run source :off)
    (multiple-value-bind (eager eager-compiled eager-ineligible eager-fallback)
        (ct-run source :eager)
      (cond
        ((not (equal off eager))
         (values nil (format nil "outcome mismatch: off=~s eager=~s" off eager) off eager))
        ((or (not (zerop off-compiled)) (not (zerop off-ineligible)) (not (zerop off-fallback)))
         (values nil (format nil "off mode recorded compiled=~d ineligible=~d fallback=~d"
                             off-compiled off-ineligible off-fallback)
                 off eager))
        ((not (zerop eager-ineligible))
         (values nil (format nil "eager rejected ~d intended-coverable bodies" eager-ineligible)
                 off eager))
        ((not (zerop eager-fallback))
         (values nil (format nil "eager fell back for ~d intended-coverable bodies" eager-fallback)
                 off eager))
        ((zerop eager-compiled)
         (values nil "vacuous eager run: compiled zero functions" off eager))
        ((and expected-string
              (not (equal off (list :return (list :string expected-string)))))
         (values nil (format nil "unexpected oracle result: want ~s got ~s" expected-string off)
                 off eager))
        (t (values t nil off eager))))))

(defun ct-diff-eq (source)
  "Compatibility predicate used by the original m1 coverage."
  (nth-value 0 (ct-diff-check source)))

(defun ct-nullish-backend-value (left right backend)
  "Evaluate a manually constructed LEFT ?? RIGHT through BACKEND.
The parser does not admit coalesce-expression yet, so this emitter regression deliberately starts at
the AST boundary instead of pretending a parser-raised SyntaxError exercised either emitter."
  (let* ((node (eng::make-logical-expression
                :operator "??"
                :left (eng::make-literal :value left)
                :right (eng::make-literal :value right)))
         (comp (eng::make-comp)))
    (ecase backend
      (:closure (funcall (eng::compile-node comp node) nil))
      (:source
       (let* ((tag (list 'ct-nullish-return))
              (body (eng::cs-compile-body
                     comp (list (eng::make-return-statement :argument node)) tag
                     "ct-nullish-manual")))
         (unless body (error "manual nullish source compilation fell back"))
         (catch tag (funcall body nil) eng:+undefined+))))))

(defparameter *ct-m2-cases*
  (list
   (list "var, top-level lexical bindings, nested scope, and shadowing" "23:2:3"
         "function f(x){ var a=x; let b=a+1; const c=b+1; { let b=20; const d=b+2; a+=d; } return a+':'+b+':'+c; } f(1);")
   (list "nested lexical TDZ" "ReferenceError:string"
         "function f(){ try { { var ignored=x; let x=1; } } catch(e) { return e.name+':'+typeof e.message; } return 'miss'; } f();")
   (list "while, do-while, for-var, for-let, continue, and break" "19:8:9:6"
         "function f(){ var w=0,i=0; while(i<8){ i++; if(i===2)continue; if(i===7)break; w+=i; } var d=0,j=0; do { j++; if(j===2)continue; d+=j; } while(j<4); var n=0; for(var k=0;k<6;k++){ if(k===1)continue; if(k===5)break; n+=k; } var l=0; for(let q=0;q<4;q++){ l+=q; } return w+':'+d+':'+n+':'+l; } f();")
   (list "prefix and postfix identifier/member updates" "3:5:5:4:6:6"
         "function f(){ var x=3; var a=x++; var b=++x; var o={n:4}; var c=o.n++; var k='n'; var d=++o[k]; return a+':'+b+':'+x+':'+c+':'+d+':'+o.n; } f();")
   (list "new, constructor return rules, new.target, and non-constructable errors"
         "9:true:explicit:TypeError"
         "function Box(x){ this.x=x; this.seen=(new.target===Box); return 17; } function Factory(){ this.kind='implicit'; return {kind:'explicit'}; } function f(){ var a=new Box(9); var b=new Factory(); var bad='none'; try { new Math.max(); } catch(e) { bad=e.name; } return a.x+':'+a.seen+':'+b.kind+':'+bad; } f();")
   (list "array holes, freshness, length, and left-to-right evaluation" "abab:3:false:x:a:b"
         "function f(){ var log=''; function step(x){ log+=x; return x; } function make(){ return [step('a'),,step('b')]; } var a=make(),b=make(); a[0]='x'; return log+':'+a.length+':'+(1 in a)+':'+a[0]+':'+b[0]+':'+a[2]; } f();")
   (list "simple objects, computed keys, freshness, and property evaluation order"
         "akvbakvb:v:b:a"
         "function f(){ var log=''; function key(){ log+='k'; return 'x'; } function val(x){ log+=x; return x; } function make(){ return {a:val('a'),[key()]:val('v'),b:val('b')}; } var o=make(),p=make(); o.a='changed'; return log+':'+o.x+':'+o.b+':'+p.a; } f();")
   (list "catch binding, optional catch binding, shadowing, and caught rethrow"
         "outer:inner:true:nobind:again!"
         "function f(){ let e='outer'; var a=''; try { throw 'inner'; } catch(e) { let x=e; a=x+':'+(e==='inner'); } var b=''; try { throw 7; } catch { b='nobind'; } try { try { throw 'again'; } catch(e) { throw e+'!'; } } catch(e) { b+=':'+e; } return e+':'+a+':'+b; } f();")
   (list "switch match/default/fallthrough/break" "ab:b:dc:c:z"
         "function sw(x){ var out=''; switch(x){ case 1:out+='a'; case 2:out+='b';break; default:out+='d'; case 3:out+='c';break; case 4:out+='z'; } return out; } sw(1)+':'+sw(2)+':'+sw(9)+':'+sw(3)+':'+sw(4);")
   (list "switch preserves enclosing continue target" "0zxz3z"
         "function f(){ var out=''; for(var i=0;i<4;i++){ switch(i){ case 1:continue; case 2:out+='x';break; default:out+=i; } out+='z'; } return out; } f();")
   (list "switch cases share one lexical TDZ scope" "ReferenceError"
         "function f(n){ let x='outer'; try { switch(n){ case 0:return x; case 1:let x='inner';return x; } } catch(e){ return e.name; } return 'miss'; } f(0);")
   (list "bare var preserves parameters and hoisted functions" "7:9"
         "function f(x){ function g(){return 9;} var x; var g; return x+':'+g(); } f(7);")
   (list "lexical for initializer observes its own TDZ" "ReferenceError"
         "function f(){ let x=1; try { for(let x=x;false;){ } } catch(e){ return e.name; } return 'miss'; } f();")
   (list "member references evaluate base/key once before RHS" "okr|okr|ok:11:2"
         "function f(){ var log='',boxes=[{x:1},{x:2}],i=0; function base(){log+='o';return boxes[i++];} function key(){log+='k';return 'x';} function rhs(){log+='r';return 5;} base()[key()]=rhs(); i=0;log+='|';base()[key()]+=rhs(); i=0;log+='|';base()[key()]++; return log+':'+boxes[0].x+':'+boxes[1].x; } f();")
   (list "arguments object reads, writes, and length" "3:3:5:2:x"
         "function f(a,b){ var before=arguments[0]; arguments[0]+=2; return before+':'+a+':'+arguments[0]+':'+arguments.length+':'+b; } f(3,'x');")
   (list "compound assignments and sequence value/order" "abc:3.25:4:4"
         "function f(){ var x=5,o={n:3},order=''; function rhs(v){ order+=v; return 2; } x+=rhs('a'); x*=rhs('b'); x-=1; x/=2; x%=5; x**=2; o.n<<=1; o.n|=1; o.n^=2; o.n&=7; o.n>>=1; o.n>>>=0; var y=(order+='c',x+=1,o.n+=2); return order+':'+x+':'+o.n+':'+y; } f();")
   (list "m1 arithmetic, relational, equality, and bitwise baseline" "89"
         "function ops(a,b){ return (a&b)+(a|b)+(a^b)+(a<<1)+(a>>1)+(a%3)+(a<=b?1:0)+(a>=b?1:0)+(a!=b?1:0)+(a!==b?1:0); } ''+ops(17,5);")))

(define-test compile-source/nullish-falsy-emitter-regression
  (dolist (case (list (list 0d0 "right" 0d0 "zero")
                      (list "" "right" "" "empty string")
                      (list eng:+false+ "right" eng:+false+ "false")
                      (list eng:+null+ "right" "right" "null")
                      (list eng:+undefined+ "right" "right" "undefined")))
    (destructuring-bind (left right expected name) case
      (eng::cs-reset-telemetry)
      (let ((closure (ct-value-signature (ct-nullish-backend-value left right :closure)))
            (source (ct-value-signature (ct-nullish-backend-value left right :source)))
            (wanted (ct-value-signature expected)))
        (is equal wanted closure "closure ?? preserves/coalesces ~a" name)
        (is equal closure source "source ?? matches closure for ~a" name)
        (is = 1 eng::*cs-compiled-count* "source ?? compiled for ~a" name)
        (is = 0 eng::*cs-fallback-count* "source ?? did not fall back for ~a" name)))))

(define-test compile-source/m2-differential-matrix
  (dolist (case *ct-m2-cases*)
    (destructuring-bind (name expected source) case
      (multiple-value-bind (ok reason) (ct-diff-check source expected)
        (true ok "~a: ~a" name reason)))))

(define-test compile-source/direct-eval-is-ineligible
  (let ((source "function f(){if(false)eval('1');return 'ok';}f();"))
    (multiple-value-bind (off) (ct-run source :off)
      (multiple-value-bind (eager compiled ineligible fallback) (ct-run source :eager)
        (is equal off eager)
        (is = 0 compiled)
        (is = 1 ineligible)
        (is = 0 fallback)
        (true (loop for entry being the hash-values of eng::*cs-function-status*
                    thereis (equal entry '(:ineligible ("direct-eval")))))))))

(define-test compile-source/m2-exception-identity
  ;; Arbitrary primitive throws retain both JS type and exact value.
  (dolist (case '(("string throw" "function f(){throw 'boom';} f();" :string "boom")
                  ("number rethrow" "function f(){try{throw 41;}catch(e){throw e+1;}} f();"
                   :number "42")))
    (destructuring-bind (name source type value) case
      (multiple-value-bind (ok reason off) (ct-diff-check source)
        (true ok "~a: ~a" name reason)
        (is eq :throw (first off) "~a completion" name)
        (is eq type (first (third off)) "~a thrown JS type" name)
        (is string= value (second (third off)) "~a thrown JS value" name))))
  ;; Engine-raised failures compare the Error object class plus exact name/message, not just "threw".
  (multiple-value-bind (ok reason off)
      (ct-diff-check "function f(o){return o.x;} f(undefined);")
    (true ok "native TypeError: ~a" reason)
    (is eq :throw (first off))
    (let ((value (third off)))
      (is eq :object (first value))
      (is string= "TypeError" (second (third value)))
      (true (plusp (length (second (fourth value)))) "TypeError message is retained"))))
