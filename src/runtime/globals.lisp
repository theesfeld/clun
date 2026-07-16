;;;; globals.lisp — process-wide globals installed by the runtime (Phase 12):
;;;; structuredClone and the WebCrypto subset (crypto.randomUUID/getRandomValues).

(in-package :clun.runtime)

(defun install-globals (realm)
  (let ((eng:*realm* realm) (g (eng:realm-global realm)))
    (install-structured-clone g)
    (install-crypto g)
    (install-buffer-global g)
    (install-abort g)                       ; AbortController/AbortSignal (Phase 14)
    (install-web-http realm)                ; Headers/Request/Response (Phase 17)
    (install-web-cookies realm)             ; Clun.Cookie/CookieMap (Phase 32)
    (install-web-url realm)                 ; URL/URLSearchParams (Phase 18)
    (install-fetch realm)))                 ; fetch (Phase 18)

(defun install-buffer-global (g)
  "Expose the node:buffer Buffer constructor as the `Buffer` global (Node has it always).
🟡 minor divergence: this instance is not eq to require('buffer').Buffer (both identical)."
  (let ((buf (eng:js-get (build-node-buffer) "Buffer")))
    (when (eng:js-object-p buf) (eng:data-prop g "Buffer" buf))))

;;; --- structuredClone (JSON-grade deep clone) -------------------------------

(defun install-structured-clone (g)
  (eng:install-method g "structuredClone" 1
    (lambda (this args) (declare (ignore this))
      (%structured-clone (eng:arg args 0) (make-hash-table :test 'eq)))))

(defun %clone-data-error (what)
  "Throw a DataCloneError (an Error with name patched) — as structuredClone does."
  (let ((e (eng:js-construct (eng:js-get (eng:realm-global eng:*realm*) "Error")
                             (list (format nil "~a could not be cloned." what)))))
    (eng:js-set e "name" "DataCloneError" nil)
    (eng:throw-js-value e)))

(defun %structured-clone (v seen)
  (cond
    ((not (eng:js-object-p v)) v)                     ; primitives are immutable
    ((eng:callable-p v) (%clone-data-error "A function"))
    ((eq (eng:js-object-class v) :date)               ; Date -> a fresh Date of the same instant
     (eng:js-construct (eng:js-get (eng:realm-global eng:*realm*) "Date")
                       (list (eng:js-call (eng:js-get v "getTime") v '()))))
    ((gethash v seen))                                ; preserve shared refs / cycles
    ((eng:js-array-p v)
     (let ((out (eng:new-array '())))
       (setf (gethash v seen) out)
       (let ((len (eng:array-length v)))
         (dotimes (i len)
           (eng:create-data-property out (princ-to-string i)
                                     (%structured-clone (eng:js-getv v (princ-to-string i)) seen))))
       out))
    (t (let ((out (eng:new-object)))
         (setf (gethash v seen) out)
         (dolist (k (eng:jm-own-property-keys v))
           (when (stringp k)
             (let ((d (eng:obj-own-desc v k)))
               (when (and d (eq (eng:pd-enumerable d) t))   ; descriptor field is CL t, not +true+
                 (eng:data-prop out k (%structured-clone (eng:js-getv v k) seen))))))
         out))))

;;; --- crypto (randomUUID / getRandomValues) ---------------------------------

(defun install-crypto (g)
  (let ((crypto (eng:new-object)))
    (eng:install-method crypto "randomUUID" 0
      (lambda (this args) (declare (ignore this args)) (%random-uuid)))
    (eng:install-method crypto "getRandomValues" 1
      (lambda (this args) (declare (ignore this))
        (let ((ta (eng:arg args 0)))
          (eng:crypto-fill-random ta)         ; fills the view's bytes; errors on a bad arg
          ta)))
    (eng:data-prop g "crypto" crypto)))

(defun %random-uuid ()
  "A v4 UUID from 16 CSPRNG bytes (RFC 4122: version nibble 4, variant bits 10)."
  (let ((b (clun.sys:os-random-bytes 16)))
    (setf (aref b 6) (logior #x40 (logand (aref b 6) #x0F))     ; version 4
          (aref b 8) (logior #x80 (logand (aref b 8) #x3F)))    ; variant 10
    (flet ((hx (lo hi) (string-downcase (with-output-to-string (o)
                                          (loop for i from lo below hi do (format o "~2,'0X" (aref b i)))))))
      (format nil "~a-~a-~a-~a-~a" (hx 0 4) (hx 4 6) (hx 6 8) (hx 8 10) (hx 10 16)))))
