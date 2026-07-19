;;;; constants.lisp — node:constants (errno + priority + fs/dlopen flags).

(in-package :clun.runtime)

(defun build-node-constants ()
  (let ((o (eng:new-object)))
    (flet ((c (k v) (eng:data-prop o k (coerce v 'double-float))))
      ;; errno
      (c "E2BIG" 7) (c "EACCES" 13) (c "EADDRINUSE" 98) (c "EADDRNOTAVAIL" 99)
      (c "EAFNOSUPPORT" 97) (c "EAGAIN" 11) (c "EALREADY" 114) (c "EBADF" 9)
      (c "EBUSY" 16) (c "ECONNREFUSED" 111) (c "ECONNRESET" 104) (c "EDESTADDRREQ" 89)
      (c "EEXIST" 17) (c "EFAULT" 14) (c "EFBIG" 27) (c "EHOSTUNREACH" 113)
      (c "EINTR" 4) (c "EINVAL" 22) (c "EIO" 5) (c "EISCONN" 106) (c "EISDIR" 21)
      (c "ELOOP" 40) (c "EMFILE" 24) (c "EMSGSIZE" 90) (c "ENAMETOOLONG" 36)
      (c "ENETUNREACH" 101) (c "ENFILE" 23) (c "ENOBUFS" 105) (c "ENODEV" 19)
      (c "ENOENT" 2) (c "ENOMEM" 12) (c "ENOSPC" 28) (c "ENOTCONN" 107)
      (c "ENOTDIR" 20) (c "ENOTEMPTY" 39) (c "ENOTSOCK" 88) (c "ENOTSUP" 95)
      (c "ENOTTY" 25) (c "ENXIO" 6) (c "EOPNOTSUPP" 95) (c "EOVERFLOW" 75)
      (c "EPERM" 1) (c "EPIPE" 32) (c "EPROTO" 71) (c "EPROTONOSUPPORT" 93)
      (c "EPROTOTYPE" 91) (c "ERANGE" 34) (c "EROFS" 30) (c "ESPIPE" 29)
      (c "ESRCH" 3) (c "ETIMEDOUT" 110) (c "ETXTBSY" 26) (c "EXDEV" 18)
      ;; signals
      (c "SIGHUP" 1) (c "SIGINT" 2) (c "SIGQUIT" 3) (c "SIGILL" 4)
      (c "SIGTRAP" 5) (c "SIGABRT" 6) (c "SIGBUS" 7) (c "SIGFPE" 8)
      (c "SIGKILL" 9) (c "SIGUSR1" 10) (c "SIGSEGV" 11) (c "SIGUSR2" 12)
      (c "SIGPIPE" 13) (c "SIGALRM" 14) (c "SIGTERM" 15)
      ;; priority
      (c "PRIORITY_LOW" 19) (c "PRIORITY_BELOW_NORMAL" 10)
      (c "PRIORITY_NORMAL" 0) (c "PRIORITY_ABOVE_NORMAL" -7)
      (c "PRIORITY_HIGH" -14) (c "PRIORITY_HIGHEST" -20)
      ;; dlopen
      (c "RTLD_LAZY" 1) (c "RTLD_NOW" 2) (c "RTLD_GLOBAL" 256) (c "RTLD_LOCAL" 0)
      ;; openssl
      (c "SSL_OP_ALL" #x80000BFF)
      o)))

(register-node-builtin "constants" #'build-node-constants)
