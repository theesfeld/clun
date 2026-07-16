;;;; proxy-tests.lisp -- Proxy internal-method, invariant, and revocation gates.

(in-package :clun-test)

(define-test proxy/basic-internal-forwarding
  (let* ((realm (eng:make-realm))
         (eng:*realm* realm)
         (target (eng:js-make-object))
         (handler (eng:js-make-object))
         (proxy (eng::%proxy-create target handler)))
    (eng:create-data-property target "value" 7d0)
    (true (eng::js-proxy-p proxy))
    (is eql 7d0 (eng:js-get proxy "value"))
    (true (eng:js-set proxy "value" 9d0 t))
    (is eql 9d0 (eng:js-get target "value"))
    (is equal '("value") (eng:jm-own-property-keys proxy))))

(define-test proxy/call-construct-and-fixed-capabilities
  (is eq eng:+true+
      (ev "(function(){
             function F(x){this.x=x;return x+1}
             var p=new Proxy(F,{apply(t,v,a){return a[0]*2},construct(t,a,n){return {x:a[0]*3}}});
             var r=Proxy.revocable(p,{}),q=r.proxy;
             if(q(4)!==8||new q(5).x!==15||typeof q!=='function')return false;
             r.revoke();
             return typeof q==='function'&&
                    (function(){try{q()}catch(e){return e instanceof TypeError}return false})()&&
                    (function(){try{new q()}catch(e){return e instanceof TypeError}return false})();
           })()")))

(define-test proxy/invariants-and-live-inline-cache
  (is eq eng:+true+
      (ev "(function(){
             var reads=0,writes=0,p=new Proxy({x:1},{
               get(t,k,r){reads++;return reads},
               set(t,k,v,r){writes++;t[k]=v;return true}
             });
             var a=p.x,b=p.x;p.x=4;p.x=5;
             if(a!==1||b!==2||reads!==2||writes!==2)return false;
             var t={};Object.defineProperty(t,'f',{value:1,writable:false,configurable:false});
             try{new Proxy(t,{get(){return 2}}).f}catch(e){return e instanceof TypeError}
             return false;
           })()")))

(define-test proxy/is-array-and-revocation
  (is eq eng:+true+
      (ev "(function(){
             var nested=new Proxy(new Proxy([],{}),{});
             if(!Array.isArray(nested)||Object.prototype.toString.call(nested)!=='[object Array]')return false;
             var r=Proxy.revocable([],{}),p=r.proxy;r.revoke();
             try{Array.isArray(p)}catch(e){return e instanceof TypeError}
             return false;
           })()")))

(define-test proxy/prototype-cycle-scan-stops-at-exotic
  (is eq eng:+true+
      (ev "(function(){
             var hits=0,exotic=new Proxy({},{getPrototypeOf(){hits++;return null}}),o={};
             return Reflect.setPrototypeOf(o,exotic)&&hits===0;
           })()")))
