;;;; ct-diff.lisp -- Phase-25 COMPILE-tier m2 differential and seeded-fuzz gate.
;;;; Run: sbcl --non-interactive --no-userinit --no-sysinit --load scripts/registry.lisp --load scripts/ct-diff.lisp

(load (merge-pathnames "registry.lisp" *load-truename*))
(handler-bind ((warning #'muffle-warning)) (asdf:load-system :clun))

(in-package :clun.engine)

(defun ct-property-signature (object key)
  (if (has-property object key)
      (let ((value (js-get object key)))
        (if (js-object-p value) (list :object (js-object-class value))
            (list (js-type value) (to-string value))))
      :absent))

(defun ct-value-signature (value)
  (if (js-object-p value)
      (list :object (js-object-class value)
            (ct-property-signature value "name")
            (ct-property-signature value "message"))
      (list (js-type value) (to-string value))))

(defun ct-run (source mode)
  (let ((*compile-tier-mode* mode) (*cs-trace-executions* nil))
    (cs-reset-telemetry)
    (let* ((realm (make-realm))
           (*realm* realm)
           (outcome
             (handler-case
                 (list :return (ct-value-signature (eval-source source :realm realm)))
               (js-condition (condition)
                 (list :throw (class-name (class-of condition))
                       (ct-value-signature (js-condition-value condition)))))))
      (values outcome *cs-compiled-count* *cs-ineligible-count* *cs-fallback-count*))))

(defun ct-check (name source &optional expected-string)
  (multiple-value-bind (off off-compiled off-ineligible off-fallback) (ct-run source :off)
    (multiple-value-bind (eager compiled ineligible fallback) (ct-run source :eager)
      (let ((reason
              (cond ((not (equal off eager))
                     (format nil "outcome mismatch: off=~s eager=~s" off eager))
                    ((or (not (zerop off-compiled)) (not (zerop off-ineligible))
                         (not (zerop off-fallback)))
                     (format nil "off counters compiled=~d ineligible=~d fallback=~d"
                             off-compiled off-ineligible off-fallback))
                    ((not (zerop ineligible))
                     (format nil "eager rejected ~d intended-coverable bodies" ineligible))
                    ((not (zerop fallback))
                     (format nil "eager fell back for ~d intended-coverable bodies" fallback))
                    ((zerop compiled) "vacuous eager run: compiled zero functions")
                    ((and expected-string
                          (not (equal off (list :return (list :string expected-string)))))
                     (format nil "unexpected oracle result: want ~s got ~s" expected-string off)))))
        (if reason
            (progn (format t "~&FAIL ~a: ~a~%" name reason) nil)
            (progn (format t "~&PASS ~a (compiled=~d)~%" name compiled) t))))))

(defun ct-nullish-backend-value (left right backend)
  "Exercise ?? from a hand-built AST because the parser intentionally rejects coalesce-expression."
  (let* ((node (make-logical-expression
                :operator "??" :left (make-literal :value left) :right (make-literal :value right)))
         (comp (make-comp)))
    (ecase backend
      (:closure (funcall (compile-node comp node) nil))
      (:source
       (let* ((tag (list 'ct-nullish-return))
              (body (cs-compile-body comp (list (make-return-statement :argument node)) tag
                                     "ct-nullish-manual")))
         (if body (catch tag (funcall body nil) +undefined+) +undefined+))))))

(defun ct-check-nullish-emitter ()
  (let ((ok t))
    (dolist (case (list (list 0d0 "right" 0d0 "zero")
                        (list "" "right" "" "empty-string")
                        (list +false+ "right" +false+ "false")
                        (list +null+ "right" "right" "null")
                        (list +undefined+ "right" "right" "undefined")))
      (destructuring-bind (left right expected name) case
        (cs-reset-telemetry)
        (let ((closure (ct-value-signature (ct-nullish-backend-value left right :closure)))
              (source (ct-value-signature (ct-nullish-backend-value left right :source)))
              (wanted (ct-value-signature expected)))
          (unless (and (equal wanted closure) (equal closure source)
                       (= *cs-compiled-count* 1) (zerop *cs-fallback-count*))
            (setf ok nil)
            (format t "~&FAIL nullish-emitter-~a: want=~s closure=~s source=~s compiled=~d fallback=~d~%"
                    name wanted closure source *cs-compiled-count* *cs-fallback-count*)))))
    (when ok (format t "~&PASS nullish-emitter-falsy-and-nullish (5 AST cases)~%"))
    ok))

(defparameter *fixed-cases*
  (list
   (list "bindings-shadow-tdz" "23:2:3:ReferenceError"
         "function f(x){var a=x;let b=a+1;const c=b+1;{let b=20;const d=b+2;a+=d;}var t='none';try{{var q=z;let z=1;}}catch(e){t=e.name;}return a+':'+b+':'+c+':'+t;} f(1);")
   (list "loops-control" "19:8:9:6"
         "function f(){var w=0,i=0;while(i<8){i++;if(i===2)continue;if(i===7)break;w+=i;}var d=0,j=0;do{j++;if(j===2)continue;d+=j;}while(j<4);var n=0;for(var k=0;k<6;k++){if(k===1)continue;if(k===5)break;n+=k;}var l=0;for(let q=0;q<4;q++){l+=q;}return w+':'+d+':'+n+':'+l;} f();")
   (list "updates" "3:5:5:4:6:6"
         "function f(){var x=3,a=x++,b=++x,o={n:4},c=o.n++,k='n',d=++o[k];return a+':'+b+':'+x+':'+c+':'+d+':'+o.n;} f();")
   (list "new-new-target" "9:true:explicit:TypeError"
         "function Box(x){this.x=x;this.seen=new.target===Box;return 17;}function Factory(){return {kind:'explicit'};}function f(){var a=new Box(9),b=new Factory(),bad='none';try{new Math.max();}catch(e){bad=e.name;}return a.x+':'+a.seen+':'+b.kind+':'+bad;}f();")
   (list "array-hole-fresh-order" "abab:3:false:x:a:b"
         "function f(){var log='';function step(x){log+=x;return x;}function make(){return [step('a'),,step('b')];}var a=make(),b=make();a[0]='x';return log+':'+a.length+':'+(1 in a)+':'+a[0]+':'+b[0]+':'+a[2];}f();")
   (list "object-computed-fresh-order" "akvbakvb:v:b:a"
         "function f(){var log='';function key(){log+='k';return 'x';}function val(x){log+=x;return x;}function make(){return {a:val('a'),[key()]:val('v'),b:val('b')};}var o=make(),p=make();o.a='changed';return log+':'+o.x+':'+o.b+':'+p.a;}f();")
   (list "throw-catch-shadow-rethrow" "outer:inner:true:nobind:again!"
         "function f(){let e='outer';var a='';try{throw 'inner';}catch(e){let x=e;a=x+':'+(e==='inner');}var b='';try{throw 7;}catch{b='nobind';}try{try{throw 'again';}catch(e){throw e+'!';}}catch(e){b+=':'+e;}return e+':'+a+':'+b;}f();")
   (list "switch-default-fallthrough-break" "ab:b:dc:c:z"
         "function sw(x){var out='';switch(x){case 1:out+='a';case 2:out+='b';break;default:out+='d';case 3:out+='c';break;case 4:out+='z';}return out;}sw(1)+':'+sw(2)+':'+sw(9)+':'+sw(3)+':'+sw(4);")
   (list "switch-continue-target" "0zxz3z"
         "function f(){var out='';for(var i=0;i<4;i++){switch(i){case 1:continue;case 2:out+='x';break;default:out+=i;}out+='z';}return out;}f();")
   (list "switch-case-lexical-tdz" "ReferenceError"
         "function f(n){let x='outer';try{switch(n){case 0:return x;case 1:let x='inner';return x;}}catch(e){return e.name;}return 'miss';}f(0);")
   (list "bare-var-preserves-bindings" "7:9"
         "function f(x){function g(){return 9;}var x;var g;return x+':'+g();}f(7);")
   (list "lexical-for-initializer-tdz" "ReferenceError"
         "function f(){let x=1;try{for(let x=x;false;){} }catch(e){return e.name;}return 'miss';}f();")
   (list "member-reference-order-once" "okr|okr|ok:11:2"
         "function f(){var log='',boxes=[{x:1},{x:2}],i=0;function base(){log+='o';return boxes[i++];}function key(){log+='k';return 'x';}function rhs(){log+='r';return 5;}base()[key()]=rhs();i=0;log+='|';base()[key()]+=rhs();i=0;log+='|';base()[key()]++;return log+':'+boxes[0].x+':'+boxes[1].x;}f();")
   (list "arguments" "3:3:5:2:x"
         "function f(a,b){var before=arguments[0];arguments[0]+=2;return before+':'+a+':'+arguments[0]+':'+arguments.length+':'+b;}f(3,'x');")
   (list "compound-sequence" "abc:3.25:4:4"
         "function f(){var x=5,o={n:3},order='';function rhs(v){order+=v;return 2;}x+=rhs('a');x*=rhs('b');x-=1;x/=2;x%=5;x**=2;o.n<<=1;o.n|=1;o.n^=2;o.n&=7;o.n>>=1;o.n>>>=0;var y=(order+='c',x+=1,o.n+=2);return order+':'+x+':'+o.n+':'+y;}f();")
   ;; Uncaught cases deliberately have no expected normal string. CT-CHECK compares condition class,
   ;; JS value type/value, and Error name/message through the structured outcome signature.
   (list "uncaught-string-value" nil "function f(){throw 'boom';}f();")
   (list "uncaught-number-rethrow" nil "function f(){try{throw 41;}catch(e){throw e+1;}}f();")
   (list "uncaught-native-typeerror" nil "function f(o){return o.x;}f(undefined);")))

;;; Seeded property-style differential generation.  The LCG and all choices are explicit, so the same
;;; corpus is reproduced on every architecture and a failure can be replayed by its printed case name.
(defconstant +fuzz-modulus+ #x100000000)
(defconstant +fuzz-seed+ #x25c0ffee)

(defun fuzz-next (state)
  (mod (+ (* state 1664525) 1013904223) +fuzz-modulus+))

(defun fuzz-pick (state choices)
  (let ((next (fuzz-next state)))
    (values (nth (mod next (length choices)) choices) next)))

(defun make-fuzz-case (index state)
  (multiple-value-bind (compound state) (fuzz-pick state '("+=" "-=" "*=" "^=" "|=" "&=" "<<=" ">>=" ">>>="))
    (let* ((next (fuzz-next state)) (a (+ 1 (mod next 17)))
           (next (fuzz-next next)) (b (+ 1 (mod next 13)))
           (next (fuzz-next next)) (c (+ 1 (mod next 11)))
           (next (fuzz-next next)) (limit (+ 2 (mod next 6)))
           (next (fuzz-next next)) (skip (mod next limit))
           (next (fuzz-next next)) (fallback (+ 1 (mod next 9)))
           (source
             (format nil
                     "function fuzz~d(a,b,c){var x=a,y=b,o={n:c},arr=[a,,b,c],trace='';for(let i=0;i<~d;i++){x~a((i+~d)%5)+1;o.n+=i;if(i===~d){trace+='s';continue;}y+=(arr[(i+1)%4]===undefined?~d:arr[(i+1)%4]);trace+=i;}var post=x++;var pre=++o.n;var seq=(trace+='q',y+=2,x+o.n+y);switch((a+b+c)%4){case 0:trace+='a';break;case 1:trace+='b';case 2:trace+='c';break;default:trace+='d';}try{if((seq%3)===0)throw seq;}catch(e){trace+='t';y+=e%7;}return trace+':'+x+':'+y+':'+o.n+':'+post+':'+pre+':'+seq;}fuzz~d(~d,~d,~d);"
                     index limit compound fallback skip fallback index a b c)))
      (values (format nil "fuzz-~2,'0d-seed-~8,'0x" index next) source next))))

(let ((pass 0) (fail 0) (state +fuzz-seed+))
  (if (ct-check-nullish-emitter) (incf pass) (incf fail))
  (dolist (case *fixed-cases*)
    (destructuring-bind (name expected source) case
      (if (ct-check name source expected) (incf pass) (incf fail))))
  (dotimes (i 32)
    (multiple-value-bind (name source next) (make-fuzz-case i state)
      (setf state next)
      (if (ct-check name source) (incf pass) (incf fail))))
  (format t "~%=== ct-diff m2: ~d passed, ~d failed; fuzz-seed=~8,'0x final-state=~8,'0x ===~%"
          pass fail +fuzz-seed+ state)
  (sb-ext:exit :code (if (zerop fail) 0 1)))
