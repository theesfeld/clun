;;;; dns.lisp — node:dns + dns/promises over pure-CL clun.net DNS.

(in-package :clun.runtime)

(defun %dns-error (code msg)
  (let ((err (eng:js-construct
              (eng:js-get (eng:realm-global eng:*realm*) "Error")
              (list msg))))
    (eng:js-set err "code" code nil)
    (eng:js-set err "errno" code nil)
    (eng:js-set err "syscall" "queryA" nil)
    err))

(defun %dns-lookup-sync (hostname family)
  (handler-case
      (let* ((host (->str hostname))
             (addrs (net:resolve-hostname-all host))
             (want-v6 (eql family 6))
             (want-v4 (eql family 4))
             (filtered
               (cond (want-v6 (remove-if-not #'net:dns-address-ipv6-p addrs))
                     (want-v4 (remove-if #'net:dns-address-ipv6-p addrs))
                     (t addrs))))
        (unless filtered
          (error "ENOTFOUND"))
        (let* ((first (first filtered))
               (text (net:dns-address-text first))
               (fam (if (net:dns-address-ipv6-p first) 6 4)))
          (values text fam)))
    (error ()
      (error "ENOTFOUND"))))

(defun %dns-lookup (hostname options cb)
  (let ((family 0) (all nil))
    (cond
      ((eng:js-number-p options) (setf family (truncate (->num options))))
      ((eng:js-object-p options)
       (let ((f (eng:js-get options "family"))
             (a (eng:js-get options "all")))
         (unless (undef-p f) (setf family (truncate (->num f))))
         (setf all (eng:js-truthy a))))
      ((eng:callable-p options)
       (setf cb options)))
    (handler-case
        (if all
            (let* ((addrs (net:resolve-hostname-all (->str hostname)))
                   (arr (eng:new-array
                         (mapcar (lambda (a)
                                   (let ((o (eng:new-object)))
                                     (eng:data-prop o "address" (net:dns-address-text a))
                                     (eng:data-prop o "family"
                                                    (coerce (if (net:dns-address-ipv6-p a) 6 4)
                                                            'double-float))
                                     o))
                                 addrs))))
              (when (eng:callable-p cb)
                (eng:js-call cb (undef) (list eng:+null+ arr))))
            (multiple-value-bind (addr fam) (%dns-lookup-sync hostname family)
              (when (eng:callable-p cb)
                (eng:js-call cb (undef)
                             (list eng:+null+ addr (coerce fam 'double-float))))))
      (error ()
        (when (eng:callable-p cb)
          (eng:js-call cb (undef)
            (list (%dns-error "ENOTFOUND"
                              (format nil "getaddrinfo ENOTFOUND ~a" hostname)))))))
    (undef)))

(defun build-node-dns ()
  (let ((o (eng:new-object)))
    (eng:install-method o "lookup" 3
      (lambda (this args) (declare (ignore this))
        (%dns-lookup (a args 0) (a args 1) (a args 2))))
    (eng:install-method o "resolve" 3
      (lambda (this args)
        (declare (ignore this))
        (let ((hostname (a args 0))
              (maybe-type (a args 1))
              (cb (a args 2)))
          (when (eng:callable-p maybe-type)
            (setf cb maybe-type))
          (%dns-lookup
           hostname 0
           (eng:make-native-function
            "" 3
            (lambda (tt aa)
              (declare (ignore tt))
              (cond
                ((or (undef-p (a aa 0)) (eng:js-null-p (a aa 0)))
                 (eng:js-call cb (undef)
                              (list eng:+null+ (eng:new-array (list (a aa 1))))))
                (t (eng:js-call cb (undef) (list (a aa 0)))))
              (undef))))
          (undef))))
    (eng:install-method o "resolve4" 2
      (lambda (this args) (declare (ignore this))
        (%dns-lookup (a args 0) 4 (a args 1))))
    (eng:install-method o "resolve6" 2
      (lambda (this args) (declare (ignore this))
        (%dns-lookup (a args 0) 6 (a args 1))))
    (eng:install-method o "reverse" 2
      (lambda (this args) (declare (ignore this))
        (when (eng:callable-p (a args 1))
          (eng:js-call (a args 1) (undef)
            (list eng:+null+ (eng:new-array (list (->str (a args 0)))))))
        (undef)))
    (eng:hidden-prop o "_servers" '("1.1.1.1" "8.8.8.8"))
    (eng:install-method o "getServers" 0
      (lambda (this args) (declare (ignore args))
        (eng:new-array (copy-list (eng:js-get this "_servers")))))
    (eng:install-method o "setServers" 1
      (lambda (this args)
        (let ((v (a args 0)))
          (eng:hidden-prop this "_servers"
                           (if (eng:js-array-p v)
                               (loop for i below (eng:array-length v)
                                     collect (->str (eng:js-getv v (princ-to-string i))))
                               (if (undef-p v) '("1.1.1.1" "8.8.8.8")
                                   (list (->str v)))))
          eng:+undefined+)))
    (eng:data-prop o "ADDRCONFIG" 1024d0)
    (eng:data-prop o "V4MAPPED" 2048d0)
    (eng:data-prop o "ALL" 256d0)
    (eng:data-prop o "promises" (build-node-dns-promises))
    o))

(defun %dns-promise-lookup (hostname family)
  (let ((g (eng:realm-global eng:*realm*)))
    (eng:js-construct
     (eng:js-get g "Promise")
     (list
      (eng:make-native-function
       "" 2
       (lambda (tt aa)
         (declare (ignore tt))
         (handler-case
             (multiple-value-bind (addr fam)
                 (%dns-lookup-sync hostname family)
               (let ((res (eng:new-object)))
                 (eng:data-prop res "address" addr)
                 (eng:data-prop res "family" (coerce fam 'double-float))
                 (eng:js-call (a aa 0) (undef) (list res))))
           (error ()
             (eng:js-call (a aa 1) (undef)
                          (list (%dns-error "ENOTFOUND"
                                            (format nil "getaddrinfo ENOTFOUND ~a"
                                                    hostname))))))
         (undef)))))))

(defun build-node-dns-promises ()
  (let ((o (eng:new-object)))
    (eng:install-method o "lookup" 2
      (lambda (this args)
        (declare (ignore this))
        (let ((family 0) (opts (a args 1)))
          (when (eng:js-object-p opts)
            (let ((f (eng:js-get opts "family")))
              (unless (undef-p f) (setf family (truncate (->num f))))))
          (when (eng:js-number-p opts)
            (setf family (truncate (->num opts))))
          (%dns-promise-lookup (a args 0) family))))
    (eng:install-method o "resolve" 2
      (lambda (this args)
        (declare (ignore this))
        (let ((g (eng:realm-global eng:*realm*)))
          (eng:js-construct
           (eng:js-get g "Promise")
           (list
            (eng:make-native-function
             "" 2
             (lambda (tt aa)
               (declare (ignore tt))
               (handler-case
                   (multiple-value-bind (addr fam)
                       (%dns-lookup-sync (a args 0) 0)
                     (declare (ignore fam))
                     (eng:js-call (a aa 0) (undef)
                                  (list (eng:new-array (list addr)))))
                 (error ()
                   (eng:js-call (a aa 1) (undef)
                                (list (%dns-error "ENOTFOUND" "resolve failed")))))
               (undef))))))))
    o))

(register-node-builtin "dns" #'build-node-dns)
(register-node-builtin "dns/promises" #'build-node-dns-promises)
