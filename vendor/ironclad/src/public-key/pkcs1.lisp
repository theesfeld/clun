;;;; -*- mode: lisp; indent-tabs-mode: nil -*-
;;;; pkcs1.lisp -- implementation of OAEP and PSS schemes

(in-package :crypto)


;;; Mask generation function
(defun mgf (digest-name seed num-bytes)
  "Expand the SEED to a NUM-BYTES bytes vector using the DIGEST-NAME digest."
  (loop
     with result = #()
     with digest-len = (digest-length digest-name)
     for digest = (make-digest digest-name) then (reinitialize-instance digest)
     for counter from 0 to (floor num-bytes digest-len)
     for counter-bytes = (integer-to-octets counter :n-bits 32)
     for tmp = (digest-sequence digest (concatenate '(vector (unsigned-byte 8))
                                                    seed
                                                    counter-bytes))
     do (setf result (concatenate '(vector (unsigned-byte 8)) result tmp))
     finally (return (subseq result 0 num-bytes))))

(declaim (notinline oaep-encode))
;; In the tests, this function is redefined to use a constant value
;; instead of a random one. Therefore it must not be inlined or the tests
;; will fail.
(defun oaep-encode (digest-name message num-bytes &optional label)
  "Return a NUM-BYTES bytes vector containing the OAEP encoding of the MESSAGE
using the DIGEST-NAME digest (and the optional LABEL octet vector)."
  (let* ((digest-name (if (eq digest-name t) :sha1 digest-name))
         (digest-len (digest-length digest-name)))
    (assert (<= (length message) (- num-bytes (* 2 digest-len) 2)))
    (let* ((digest (make-digest digest-name))
           (label (or label (coerce #() '(vector (unsigned-byte 8)))))
           (padding-len (- num-bytes (length message) (* 2 digest-len) 2))
           (padding (make-array padding-len :element-type '(unsigned-byte 8) :initial-element 0))
           (l-hash (digest-sequence digest label))
           (db (concatenate '(vector (unsigned-byte 8)) l-hash padding #(1) message))
           (seed (random-data digest-len))
           (db-mask (mgf digest-name seed (- num-bytes digest-len 1)))
           (masked-db (map '(vector (unsigned-byte 8)) #'logxor db db-mask))
           (seed-mask (mgf digest-name masked-db digest-len))
           (masked-seed (map '(vector (unsigned-byte 8)) #'logxor seed seed-mask)))
      (concatenate '(vector (unsigned-byte 8)) #(0) masked-seed masked-db))))

(defun oaep-decode (digest-name message &optional label)
  "Return an octet vector containing the data that was encoded in the MESSAGE with OAEP
using the DIGEST-NAME digest (and the optional LABEL octet vector)."
  (let* ((digest-name (if (eq digest-name t) :sha1 digest-name))
         (digest-len (digest-length digest-name)))
    (assert (>= (length message) (+ (* 2 digest-len) 2)))
    (let* ((digest (make-digest digest-name))
           (label (or label (coerce #() '(vector (unsigned-byte 8)))))
           (zero-byte (elt message 0))
           (masked-seed (subseq message 1 (1+ digest-len)))
           (masked-db (subseq message (1+ digest-len)))
           (seed-mask (mgf digest-name masked-db digest-len))
           (seed (map '(vector (unsigned-byte 8)) #'logxor masked-seed seed-mask))
           (db-mask (mgf digest-name seed (- (length message) digest-len 1)))
           (db (map '(vector (unsigned-byte 8)) #'logxor masked-db db-mask))
           (l-hash1 (digest-sequence digest label))
           (l-hash2 (subseq db 0 digest-len))
           (padding-len (loop
                           for i from digest-len below (length db)
                           while (zerop (elt db i))
                           finally (return (- i digest-len))))
           (one-byte (elt db (+ digest-len padding-len))))
      (unless (and (zerop zero-byte) (= 1 one-byte) (equalp l-hash1 l-hash2))
        (error 'oaep-decoding-error))
      (subseq db (+ digest-len padding-len 1)))))

(declaim (notinline pss-encode))
;; In the tests, this function is redefined to use a constant value
;; instead of a random one. Therefore it must not be inlined or the tests
;; will fail.
(defun pss-encode (digest-name message num-bytes &optional salt-length em-bits)
  (let* ((digest-name (if (eq digest-name t) :sha1 digest-name))
         (digest-len (digest-length digest-name))
         ;; Preserve the historical API default: PSS salt length equals the
         ;; digest output length unless the caller supplies an exact value.
         (salt-length (if (null salt-length) digest-len salt-length))
         (em-bits (or em-bits (1- (* 8 num-bytes))))
         (unused-bits (- (* 8 num-bytes) em-bits)))
    (assert (and (integerp salt-length)
                 (not (minusp salt-length))
                 (<= (+ digest-len salt-length 2) num-bytes)
                 (<= 0 unused-bits 7)))
    (let* ((m-hash (digest-sequence digest-name message))
           (salt (random-data salt-length))
           (m1 (concatenate '(vector (unsigned-byte 8)) #(0 0 0 0 0 0 0 0) m-hash salt))
           (h (digest-sequence digest-name m1))
           (ps (make-array (- num-bytes digest-len salt-length 2)
                           :element-type '(unsigned-byte 8)
                           :initial-element 0))
           (db (concatenate '(vector (unsigned-byte 8)) ps #(1) salt))
           (db-mask (mgf digest-name h (- num-bytes digest-len 1)))
           (masked-db (map '(vector (unsigned-byte 8)) #'logxor db db-mask))
           (first-octet-mask (1- (ash 1 (- 8 unused-bits)))))
      (setf (elt masked-db 0) (logand (elt masked-db 0) first-octet-mask))
      (concatenate '(vector (unsigned-byte 8)) masked-db h #(188)))))

(defun pss-verify (digest-name message encoded-message &optional salt-length em-bits)
  (let* ((digest-name (if (eq digest-name t) :sha1 digest-name))
         (digest-len (digest-length digest-name))
         (salt-length (if (null salt-length) digest-len salt-length))
         (em-len (length encoded-message))
         (em-bits (or em-bits (1- (* 8 em-len))))
         (unused-bits (- (* 8 em-len) em-bits)))
    (and (integerp salt-length)
         (not (minusp salt-length))
         (<= 0 unused-bits 7)
         (<= (+ digest-len salt-length 2) em-len)
         (= (elt encoded-message (1- em-len)) #xbc)
         (let* ((db-length (- em-len digest-len 1))
                (masked-db (subseq encoded-message 0 db-length))
                (first-octet-mask (1- (ash 1 (- 8 unused-bits)))))
           ;; RFC 8017 requires the unused high bits to arrive as zero; merely
           ;; clearing them after unmasking would accept noncanonical EM values.
           (and (zerop (logand (elt masked-db 0)
                               (logxor first-octet-mask #xff)))
                (let* ((m-hash (digest-sequence digest-name message))
                       (h (subseq encoded-message db-length (1- em-len)))
                       (db-mask (mgf digest-name h db-length))
                       (db (map '(vector (unsigned-byte 8))
                                #'logxor masked-db db-mask))
                       (ps-length (- em-len digest-len salt-length 2)))
                  (setf (elt db 0) (logand (elt db 0) first-octet-mask))
                  (let* ((ps (subseq db 0 ps-length))
                         (one-byte (elt db ps-length))
                         (salt (subseq db (1+ ps-length)))
                         (m1 (concatenate '(vector (unsigned-byte 8))
                                          #(0 0 0 0 0 0 0 0) m-hash salt))
                         (h1 (digest-sequence digest-name m1)))
                    (and (= 1 one-byte)
                         (loop for octet across ps always (zerop octet))
                         (equalp h h1)))))))))
