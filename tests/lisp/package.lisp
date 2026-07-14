;;;; package.lisp — the CL-side test package. Uses only :cl (§6); parachute
;;;; entry points are imported, and the engine is reached via the `eng` nickname.

(defpackage :clun-test
  (:use :cl)
  (:local-nicknames (:eng :clun.engine) (:lp :clun.loop) (:sys :clun.sys)
                    (:rslv :clun.resolver) (:rt :clun.runtime) (:cli :clun.cli)
                    (:net :clun.net) (:sv :clun.install) (:reg :clun.registry)
                    (:tb :clun.tarball) (:integ :clun.integrity))
  (:import-from :parachute #:define-test #:is #:isnt #:true #:false #:of-type #:fail))
