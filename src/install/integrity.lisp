;;;; integrity.lisp — Subresource-Integrity (SRI) over package tarball bytes (PLAN.md Phase 22,
;;;; §3.5). npm's `dist.integrity` is an SRI hash of the gzipped `.tgz` bytes; every downloaded
;;;; tarball is verified against it BEFORE extraction commits, so a TLS compromise (or a corrupt
;;;; cache) cannot by itself corrupt an install. Pure CL (ironclad digests + cl-base64), no engine.

(in-package :clun.integrity)

(define-condition integrity-error (error)
  ((message :initarg :message :reader integrity-error-message :initform "integrity error"))
  (:report (lambda (c s) (write-string (integrity-error-message c) s))))

(defstruct (sri (:conc-name sri-))
  algorithm                             ; a keyword ironclad understands: :sha512 / :sha256 / :sha1
  digest)                               ; the raw digest bytes (decoded from the SRI's base64)

;; strongest first — npm may list several hashes; we verify against the strongest we support.
(defparameter *sri-algorithms*
  '(("sha512" . :sha512) ("sha384" . :sha384) ("sha256" . :sha256) ("sha1" . :sha1)))
(defparameter *sri-strength* '(:sha512 :sha384 :sha256 :sha1))

(defun %algo-keyword (name)
  (cdr (assoc (string-downcase name) *sri-algorithms* :test #'string=)))

(defun split-whitespace (s)
  "Split S on whitespace, dropping empty tokens."
  (let ((out '()) (i 0) (n (length s)))
    (flet ((ws-p (c) (member c '(#\Space #\Tab #\Newline #\Return))))
      (loop while (< i n) do
        (loop while (and (< i n) (ws-p (char s i))) do (incf i))
        (let ((start i))
          (loop while (and (< i n) (not (ws-p (char s i)))) do (incf i))
          (when (> i start) (push (subseq s start i) out)))))
    (nreverse out)))

(defun parse-one-sri (token)
  "Parse one `algo-base64[?opts]` SRI token → an sri, or NIL if the algorithm is unsupported or the
base64 is malformed."
  (let* ((q (position #\? token))
         (core (if q (subseq token 0 q) token))
         (dash (position #\- core)))
    (when dash
      (let ((algo (%algo-keyword (subseq core 0 dash)))
            (b64 (subseq core (1+ dash))))
        (when (and algo (plusp (length b64)))
          (handler-case (make-sri :algorithm algo :digest (cl-base64:base64-string-to-usb8-array b64))
            (error () nil)))))))

(defun parse-sri (string)
  "Parse an SRI metadata STRING (one or more space-separated hashes) → the STRONGEST supported sri.
Signals integrity-error if none is parseable/supported."
  (let ((sris (loop for tok in (split-whitespace string)
                    for s = (parse-one-sri tok) when s collect s)))
    (unless sris
      (error 'integrity-error :message (format nil "no supported hash in integrity ~s" string)))
    (or (loop for algo in *sri-strength*
              thereis (find algo sris :key #'sri-algorithm))
        (first sris))))

(defun digest-bytes (algorithm octets)
  "The raw digest of OCTETS under ALGORITHM (a keyword: :sha512 / :sha256 / :sha1 …)."
  (ironclad:digest-sequence algorithm octets))

(defun sri-string (algorithm octets)
  "The SRI string `algo-<base64>` of OCTETS (e.g. for computing dist.integrity)."
  (format nil "~a-~a" (string-downcase (symbol-name algorithm))
          (cl-base64:usb8-array-to-base64-string (digest-bytes algorithm octets))))

(defun %b64-prefix (bytes &optional (n 12))
  (let ((s (cl-base64:usb8-array-to-base64-string bytes)))
    (subseq s 0 (min n (length s)))))

(defun verify-integrity (octets integrity)
  "Verify OCTETS against INTEGRITY (an SRI string or an sri struct). Returns T, or signals
integrity-error on a mismatch / unsupported algorithm. The digest is public data (not a secret),
so a plain equalp compare is correct — no constant-time requirement."
  (let* ((sri (if (sri-p integrity) integrity (parse-sri integrity)))
         (got (digest-bytes (sri-algorithm sri) octets)))
    (if (equalp got (sri-digest sri))
        t
        (error 'integrity-error
               :message (format nil "integrity mismatch (~a): expected ~a…, got ~a…"
                                (string-downcase (symbol-name (sri-algorithm sri)))
                                (%b64-prefix (sri-digest sri)) (%b64-prefix got))))))
