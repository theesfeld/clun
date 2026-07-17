;;;; password.lisp -- bounded password hashing and encoded-hash verification.
;;;;
;;;; This layer is independent of the JavaScript engine.  It accepts octets,
;;;; owns strict PHC/MCF parsing, and delegates only the primitive KDF rounds to
;;;; vendored Ironclad.  No attacker-controlled cost reaches a KDF unchecked.

(in-package :clun.password)

(defconstant +default-argon-memory-cost+ 65536)
(defconstant +default-argon-time-cost+ 2)
(defconstant +default-bcrypt-cost+ 10)
(defconstant +max-password-bytes+ 1048576)
(defconstant +max-encoded-hash-bytes+ 4096)
(defconstant +max-argon-memory-cost+ 4194304)
(defconstant +max-argon-time-cost+ 65536)
(defconstant +max-argon-parallelism+ 64)
(defconstant +argon-salt-length+ 32)
(defconstant +argon-tag-length+ 32)
(defconstant +bcrypt-salt-length+ 16)
(defconstant +bcrypt-tag-length+ 23)

(defparameter +base64-alphabet+
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
(defparameter +bcrypt-base64-alphabet+
  "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

(define-condition password-error (error)
  ((kind :initarg :kind :reader password-error-kind)
   (detail :initarg :detail :initform nil :reader password-error-detail))
  (:report (lambda (condition stream)
             (if (password-error-detail condition)
                 (format stream "~A: ~A"
                         (password-error-kind condition)
                         (password-error-detail condition))
                 (format stream "~A" (password-error-kind condition))))))

(defun %fail (kind &optional detail)
  (error 'password-error :kind kind :detail detail))

(defun %wipe (octets)
  (when (typep octets '(array (unsigned-byte 8) (*)))
    (fill octets 0))
  nil)

(defun %bounded-octets (value label limit &key nonempty)
  (unless (typep value '(vector (unsigned-byte 8)))
    (error 'type-error :datum value
                       :expected-type '(vector (unsigned-byte 8))))
  (when (> (length value) limit)
    (%fail :input-too-long (format nil "~A exceeds ~D bytes" label limit)))
  (when (and nonempty (zerop (length value)))
    (%fail :invalid-argument (format nil "~A must not be empty" label)))
  (let ((copy (make-array (length value) :element-type '(unsigned-byte 8))))
    (replace copy value)
    copy))

(defun %ascii-string (octets)
  (when (> (length octets) +max-encoded-hash-bytes+)
    (%fail :input-too-long "encoded hash is too long"))
  (let ((string (make-string (length octets))))
    (dotimes (index (length octets) string)
      (let ((byte (aref octets index)))
        (when (> byte 127)
          (%fail :invalid-encoding "encoded hash must be ASCII"))
        (setf (char string index) (code-char byte))))))

(defun %split (string delimiter)
  (let ((start 0) (parts nil))
    (loop for end = (position delimiter string :start start)
          do (push (subseq string start end) parts)
          if end do (setf start (1+ end))
          else do (return (nreverse parts)))))

(defun %prefixp (prefix string)
  (and (<= (length prefix) (length string))
       (string= prefix string :end2 (length prefix))))

(defun %parse-decimal (string label minimum maximum)
  (when (or (zerop (length string)) (> (length string) 10))
    (%fail :invalid-encoding (format nil "invalid ~A" label)))
  (let ((value 0))
    (loop for character across string
          for digit = (- (char-code character) (char-code #\0))
          do (unless (<= 0 digit 9)
               (%fail :invalid-encoding (format nil "invalid ~A" label)))
             (setf value (+ (* value 10) digit))
             (when (> value maximum)
               (%fail :weak-parameters (format nil "~A exceeds its limit" label))))
    (when (< value minimum)
      (%fail :weak-parameters (format nil "~A is below its minimum" label)))
    value))

(defun %base64-value (character alphabet)
  (or (position character alphabet :test #'char=)
      (%fail :invalid-encoding "invalid base64 character")))

(defun %base64-encode (octets alphabet)
  (let* ((length (length octets))
         (output (make-string (ceiling (* length 8) 6)))
         (accumulator 0)
         (bits 0)
         (out 0))
    (loop for byte across octets
          do (setf accumulator (logior (ash accumulator 8) byte)
                   bits (+ bits 8))
             (loop while (>= bits 6)
                   do (decf bits 6)
                      (setf (char output out)
                            (char alphabet (logand (ash accumulator (- bits)) #x3f)))
                      (incf out)
                      (setf accumulator (if (zerop bits)
                                            0
                                            (logand accumulator (1- (ash 1 bits)))))))
    (when (plusp bits)
      (setf (char output out)
            (char alphabet (logand (ash accumulator (- 6 bits)) #x3f))))
    output))

(defun %base64-decode (string alphabet expected-length)
  (when (or (position #\= string)
            (= (mod (length string) 4) 1)
            (/= (length string) (ceiling (* expected-length 8) 6)))
    (%fail :invalid-encoding "invalid base64 length"))
  (let ((output (make-array expected-length :element-type '(unsigned-byte 8)))
        (accumulator 0)
        (bits 0)
        (out 0))
    (loop for character across string
          for value = (%base64-value character alphabet)
          do (setf accumulator (logior (ash accumulator 6) value)
                   bits (+ bits 6))
             (when (>= bits 8)
               (decf bits 8)
               (when (>= out expected-length)
                 (%fail :invalid-encoding "base64 output overflow"))
               (setf (aref output out)
                     (logand (ash accumulator (- bits)) #xff))
               (incf out)
               (setf accumulator (if (zerop bits)
                                     0
                                     (logand accumulator (1- (ash 1 bits)))))))
    (unless (and (= out expected-length) (zerop accumulator)
                 (string= string (%base64-encode output alphabet)))
      (%wipe output)
      (%fail :invalid-encoding "non-canonical base64"))
    output))

(defun %base64-decode-variable (string alphabet minimum maximum)
  (let ((decoded-length (floor (* (length string) 6) 8)))
    (unless (<= minimum decoded-length maximum)
      (%fail :invalid-encoding "decoded base64 length is out of range"))
    (%base64-decode string alphabet decoded-length)))

(defun %argon-algorithm-name (algorithm)
  (case algorithm
    (:argon2d "argon2d")
    (:argon2i "argon2i")
    (:argon2id "argon2id")
    (otherwise (%fail :unsupported-algorithm "expected argon2d, argon2i, or argon2id"))))

(defun %validate-argon-costs (memory-cost time-cost &optional (parallelism 1))
  (unless (and (integerp memory-cost) (<= 8 memory-cost +max-argon-memory-cost+))
    (%fail :weak-parameters "Argon2 memoryCost must be between 8 and 4194304"))
  (unless (and (integerp time-cost) (<= 1 time-cost +max-argon-time-cost+))
    (%fail :weak-parameters "Argon2 timeCost must be between 1 and 65536"))
  (unless (and (integerp parallelism) (<= 1 parallelism +max-argon-parallelism+))
    (%fail :weak-parameters "Argon2 parallelism must be between 1 and 64"))
  (when (< memory-cost (* 8 parallelism))
    (%fail :weak-parameters "Argon2 memoryCost must be at least 8 * parallelism"))
  (values))

(defun %validate-bcrypt-cost (cost)
  (unless (and (integerp cost) (<= 4 cost 31))
    (%fail :weak-parameters "bcrypt cost must be between 4 and 31"))
  cost)

(defun %erase-argon-work-area (kdf)
  (let ((slot 'crypto::work-area))
    (when (and (slot-exists-p kdf slot) (slot-boundp kdf slot))
      (fill (slot-value kdf slot) 0))))

(defun %argon-type-id (algorithm)
  (ecase algorithm (:argon2d 0) (:argon2i 1) (:argon2id 2)))

(defun %argon-data-independent-p (algorithm pass slice)
  (or (eq algorithm :argon2i)
      (and (eq algorithm :argon2id) (zerop pass) (< slice 2))))

(defun %argon-reference-index (pass slice index segment-length lane-length same-lane-p
                               pseudo-random)
  (let* ((area-size
           (if (zerop pass)
               (if (zerop slice)
                   (1- index)
                   (+ (* slice segment-length)
                      (if same-lane-p (1- index)
                          (if (zerop index) -1 0))))
               (+ (- lane-length segment-length)
                  (if same-lane-p (1- index)
                      (if (zerop index) -1 0)))))
         (relative (logand pseudo-random #xffffffff))
         (relative (ash (* relative relative) -32))
         (relative (- (1- area-size)
                      (ash (* area-size relative) -32)))
         (start (if (zerop pass)
                    0
                    (if (= slice 3) 0 (* (1+ slice) segment-length)))))
    (mod (+ start relative) lane-length)))

(defun %argon-address-block (state pass lane slice memory-cost time-cost type counter)
  (let ((block (crypto::argon2-block state)))
    (fill block 0)
    (setf (aref block 0) pass
          (aref block 1) lane
          (aref block 2) slice
          (aref block 3) memory-cost
          (aref block 4) time-cost
          (aref block 5) type
          (aref block 6) counter)
    (crypto::argon2-unary-g block)
    (crypto::argon2-unary-g block)
    block))

(defun %derive-argon-lanes (state algorithm password salt memory-cost time-cost
                            parallelism tag-length)
  "Argon2 v=19 sequential lane scheduler over Ironclad's pure compression core."
  (let* ((type (%argon-type-id algorithm))
         (memory-blocks (- memory-cost (mod memory-cost (* 4 parallelism))))
         (segment-length (floor memory-blocks (* 4 parallelism)))
         (lane-length (* segment-length 4))
         (work-area (crypto::argon2-work-area state))
         (digester (crypto::argon2-digester state))
         (no-data (make-array 0 :element-type '(unsigned-byte 8)))
         (initial-hash (make-array 72 :element-type '(unsigned-byte 8)))
         (tmp-area (make-array 1024 :element-type '(unsigned-byte 8)))
         (tmp-block (make-array 128 :element-type '(unsigned-byte 64))))
    (labels ((u32 (value) (crypto::argon2-update-digester-32 digester value))
             (block-index (lane index) (+ (* lane lane-length) index)))
      (unwind-protect
           (progn
             (reinitialize-instance digester :key no-data :digest-length 64)
             (u32 parallelism)
             (u32 tag-length)
             (u32 memory-cost)
             (u32 time-cost)
             (u32 #x13)
             (u32 type)
             (u32 (length password))
             (crypto:update-mac digester password)
             (u32 (length salt))
             (crypto:update-mac digester salt)
             (u32 0)                    ; secret length
             (u32 0)                    ; associated-data length
             (crypto:produce-mac digester :digest initial-hash)

             (dotimes (lane parallelism)
               (dotimes (column 2)
                 (setf (crypto:ub32ref/le initial-hash 64) column
                       (crypto:ub32ref/le initial-hash 68) lane)
                 (crypto::argon2-extended-hash state tmp-area 1024 initial-hash 72)
                 (crypto::argon2-load-block tmp-block tmp-area)
                 (crypto::argon2-copy-block
                  work-area tmp-block :start1 (block-index lane column))))

             ;; Slices are outside lanes: every lane's preceding slice is
             ;; complete before any lane begins the next, as required by the
             ;; parallel Argon2 schedule. Lanes themselves execute sequentially.
             (dotimes (pass time-cost)
               (dotimes (slice 4)
                 (dotimes (lane parallelism)
                   (let* ((data-independent
                            (%argon-data-independent-p algorithm pass slice))
                          (start-index (if (and (zerop pass) (zerop slice)) 2 0))
                          (address-counter 0)
                          (address-block nil))
                     (loop for index from start-index below segment-length
                           do
                              (when (and data-independent
                                         (or (= index start-index)
                                             (zerop (mod index 128))))
                                (incf address-counter)
                                (setf address-block
                                      (%argon-address-block
                                       state pass lane slice memory-blocks
                                       time-cost type address-counter)))
                              (let* ((current-in-lane (+ (* slice segment-length) index))
                                     (previous-in-lane
                                       (if (zerop current-in-lane)
                                           (1- lane-length)
                                           (1- current-in-lane)))
                                     (previous (block-index lane previous-in-lane))
                                     (pseudo
                                       (if data-independent
                                           (aref address-block (mod index 128))
                                           (aref work-area (* previous 128))))
                                     (reference-lane
                                       (if (and (zerop pass) (zerop slice))
                                           lane
                                           (mod (ash pseudo -32) parallelism)))
                                     (reference-index
                                       (%argon-reference-index
                                        pass slice index segment-length lane-length
                                        (= lane reference-lane) pseudo))
                                     (current (block-index lane current-in-lane))
                                     (reference (block-index reference-lane
                                                             reference-index)))
                                (if (zerop pass)
                                    (crypto::argon2-g-copy work-area current previous
                                                          reference)
                                    (crypto::argon2-g-xor work-area current previous
                                                         reference))))))))

             (crypto::argon2-copy-block
              tmp-block work-area :start2 (block-index 0 (1- lane-length)))
             (loop for lane from 1 below parallelism
                   do (crypto::argon2-xor-block
                       tmp-block work-area
                       :start2 (block-index lane (1- lane-length))))
             (crypto::argon2-store-block tmp-area tmp-block)
             (let ((result (make-array tag-length :element-type '(unsigned-byte 8))))
               (crypto::argon2-extended-hash state result tag-length tmp-area 1024)
               result))
        (%wipe initial-hash)
        (%wipe tmp-area)
        (fill tmp-block 0)))))

(defun %derive-argon (algorithm password salt memory-cost time-cost
                      &optional (tag-length +argon-tag-length+) (parallelism 1))
  (%validate-argon-costs memory-cost time-cost parallelism)
  (let ((kdf nil) (derived nil))
    (unwind-protect
         (handler-case
             (progn
               (setf kdf (crypto:make-kdf
                          algorithm
                          :block-count (- memory-cost
                                          (mod memory-cost (* 4 parallelism))))
                     derived (%derive-argon-lanes
                              kdf algorithm password salt memory-cost time-cost
                              parallelism tag-length))
               derived)
           (password-error (condition) (error condition))
           (error (condition)
             (%fail :unexpected (princ-to-string condition))))
      (when kdf (%erase-argon-work-area kdf)))))

(defun %bcrypt-password (password)
  (if (> (length password) 72)
      (crypto:digest-sequence :sha512 password)
      password))

(defun %derive-bcrypt (password salt cost)
  (%validate-bcrypt-cost cost)
  (handler-case
      (crypto:derive-key (crypto:make-kdf :bcrypt) password salt
                         (ash 1 cost) 24)
    (password-error (condition) (error condition))
    (error (condition) (%fail :unexpected (princ-to-string condition)))))

(defun %constant-time= (left right)
  (and (= (length left) (length right))
       (crypto:constant-time-equal left right)))

(defun %argon-encode (algorithm memory-cost time-cost salt tag)
  (format nil "$~A$v=19$m=~D,t=~D,p=1$~A$~A"
          (%argon-algorithm-name algorithm) memory-cost time-cost
          (%base64-encode salt +base64-alphabet+)
          (%base64-encode tag +base64-alphabet+)))

(defun %bcrypt-encode (cost salt derived)
  (format nil "$2b$~2,'0D$~A~A" cost
          (%base64-encode salt +bcrypt-base64-alphabet+)
          (%base64-encode (subseq derived 0 +bcrypt-tag-length+)
                          +bcrypt-base64-alphabet+)))

(defun hash-password (password &key (algorithm :argon2id)
                                    (memory-cost +default-argon-memory-cost+)
                                    (time-cost +default-argon-time-cost+)
                                    (cost +default-bcrypt-cost+)
                                    salt)
  "Hash PASSWORD octets and return Bun-compatible PHC/MCF ASCII text."
  (let ((owned-password (%bounded-octets password "password"
                                         +max-password-bytes+ :nonempty t))
        (owned-salt nil)
        (derived nil)
        (prepared nil))
    (unwind-protect
         (ecase algorithm
           ((:argon2d :argon2i :argon2id)
            (%validate-argon-costs memory-cost time-cost)
            (setf owned-salt
                  (if salt
                      (%bounded-octets salt "salt" +argon-salt-length+)
                      (clun.sys:os-random-bytes +argon-salt-length+)))
            (unless (= (length owned-salt) +argon-salt-length+)
              (%fail :invalid-argument "Argon2 salt must be 32 bytes"))
            (setf derived (%derive-argon algorithm owned-password owned-salt
                                         memory-cost time-cost))
            (%argon-encode algorithm memory-cost time-cost owned-salt derived))
           (:bcrypt
            (%validate-bcrypt-cost cost)
            (setf owned-salt
                  (if salt
                      (%bounded-octets salt "salt" +bcrypt-salt-length+)
                      (clun.sys:os-random-bytes +bcrypt-salt-length+)))
            (unless (= (length owned-salt) +bcrypt-salt-length+)
              (%fail :invalid-argument "bcrypt salt must be 16 bytes"))
            (setf prepared (%bcrypt-password owned-password)
                  derived (%derive-bcrypt prepared owned-salt cost))
            (%bcrypt-encode cost owned-salt derived)))
      (when (and prepared (not (eq prepared owned-password))) (%wipe prepared))
      (%wipe derived)
      (%wipe owned-salt)
      (%wipe owned-password))))

(defun %parse-argon-parameters (segment)
  (let ((memory nil) (time nil) (parallelism nil))
    (dolist (pair (%split segment #\,))
      (let ((pieces (%split pair #\=)))
        (unless (= (length pieces) 2)
          (%fail :invalid-encoding "invalid Argon2 parameter"))
        (let ((name (first pieces)) (value (second pieces)))
          (cond
            ((string= name "m")
             (when memory (%fail :invalid-encoding "duplicate m parameter"))
             (setf memory (%parse-decimal value "memory cost" 8
                                          +max-argon-memory-cost+)))
            ((string= name "t")
             (when time (%fail :invalid-encoding "duplicate t parameter"))
             (setf time (%parse-decimal value "time cost" 1
                                        +max-argon-time-cost+)))
            ((string= name "p")
             (when parallelism (%fail :invalid-encoding "duplicate p parameter"))
             (setf parallelism (%parse-decimal value "parallelism" 1
                                               +max-argon-parallelism+)))
            (t (%fail :invalid-encoding "unknown Argon2 parameter"))))))
    (unless (and memory time parallelism)
      (%fail :invalid-encoding "missing Argon2 parameter"))
    (%validate-argon-costs memory time parallelism)
    (values memory time parallelism)))

(defun %parse-argon (encoded)
  (let ((parts (%split encoded #\$)))
    (unless (and (member (length parts) '(5 6)) (string= (first parts) ""))
      (%fail :invalid-encoding "invalid Argon2 PHC shape"))
    (let* ((name (second parts))
           (algorithm (cond ((string= name "argon2d") :argon2d)
                            ((string= name "argon2i") :argon2i)
                            ((string= name "argon2id") :argon2id)
                            (t (%fail :unsupported-algorithm name))))
           (version-p (= (length parts) 6))
           (parameter-index (if version-p 3 2)))
      (when (and version-p (not (string= (third parts) "v=19")))
        (%fail :invalid-encoding "only Argon2 version 19 is accepted"))
      (multiple-value-bind (memory time parallelism)
          (%parse-argon-parameters (nth parameter-index parts))
        (values algorithm memory time
                parallelism
                (%base64-decode-variable (nth (1+ parameter-index) parts)
                                         +base64-alphabet+ 8 1024)
                (%base64-decode-variable (nth (+ parameter-index 2) parts)
                                         +base64-alphabet+ 4 1024))))))

(defun %parse-bcrypt-mcf (encoded)
  (unless (= (length encoded) 60)
    (%fail :invalid-encoding "bcrypt MCF must be 60 bytes"))
  (unless (and (char= (char encoded 0) #\$)
               (char= (char encoded 1) #\2)
               (find (char encoded 2) "abxy" :test #'char=)
               (char= (char encoded 3) #\$)
               (char= (char encoded 6) #\$))
    (%fail :invalid-encoding "invalid bcrypt MCF prefix"))
  (let ((cost (%parse-decimal (subseq encoded 4 6) "bcrypt cost" 4 31)))
    (values cost
            (%base64-decode (subseq encoded 7 29)
                            +bcrypt-base64-alphabet+ +bcrypt-salt-length+)
            (%base64-decode (subseq encoded 29)
                            +bcrypt-base64-alphabet+ +bcrypt-tag-length+))))

(defun %parse-bcrypt-phc (encoded)
  (let ((parts (%split encoded #\$)))
    (unless (and (= (length parts) 5) (string= (first parts) "")
                 (string= (second parts) "bcrypt"))
      (%fail :invalid-encoding "invalid bcrypt PHC shape"))
    (let ((parameter (third parts)))
      (unless (and (> (length parameter) 2)
                   (string= parameter "r=" :end1 2 :end2 2))
        (%fail :invalid-encoding "invalid bcrypt rounds"))
      (values (%parse-decimal (subseq parameter 2) "bcrypt cost" 4 31)
              (%base64-decode (fourth parts) +base64-alphabet+
                              +bcrypt-salt-length+)
              (%base64-decode (fifth parts) +base64-alphabet+
                              +bcrypt-tag-length+)))))

(defun %verify-argon (password encoded explicit-algorithm)
  (multiple-value-bind (algorithm memory time parallelism salt expected)
      (%parse-argon encoded)
    (unwind-protect
         (progn
           (when (and explicit-algorithm (not (eq algorithm explicit-algorithm)))
             (%fail :unsupported-algorithm "algorithm does not match encoded hash"))
           (let ((computed (%derive-argon algorithm password salt memory time
                                           (length expected) parallelism)))
             (unwind-protect (%constant-time= computed expected)
               (%wipe computed))))
      (%wipe salt)
      (%wipe expected))))

(defun %verify-bcrypt (password encoded)
  (multiple-value-bind (cost salt expected)
      (if (%prefixp "$2" encoded)
          (%parse-bcrypt-mcf encoded)
          (%parse-bcrypt-phc encoded))
    (let ((prepared nil) (computed nil))
      (unwind-protect
           (progn
             (setf prepared (%bcrypt-password password)
                   computed (%derive-bcrypt prepared salt cost))
             (%constant-time= (subseq computed 0 +bcrypt-tag-length+) expected))
        (when (and prepared (not (eq prepared password))) (%wipe prepared))
        (%wipe computed)
        (%wipe salt)
        (%wipe expected)))))

(defun validate-encoded-password-hash (encoded-hash &optional algorithm)
  "Parse and validate ENCODED-HASH without running its password KDF.
This is the synchronous admission boundary for asynchronous verification: bad
encodings and hostile cost parameters are rejected before work is queued."
  (let ((owned-hash (%bounded-octets encoded-hash "encoded hash"
                                     +max-encoded-hash-bytes+)))
    (unwind-protect
         (if (zerop (length owned-hash))
             nil
             (let ((encoded (%ascii-string owned-hash)))
               (cond
                 ((or (and algorithm (member algorithm '(:argon2d :argon2i :argon2id)))
                      (and (null algorithm)
                           (or (%prefixp "$argon2d$" encoded)
                               (%prefixp "$argon2i$" encoded)
                               (%prefixp "$argon2id$" encoded))))
                  (multiple-value-bind (parsed memory time parallelism salt expected)
                      (%parse-argon encoded)
                    (declare (ignore memory time parallelism))
                    (unwind-protect
                         (progn
                           (when (and algorithm (not (eq parsed algorithm)))
                             (%fail :unsupported-algorithm
                                    "algorithm does not match encoded hash"))
                           t)
                      (%wipe salt)
                      (%wipe expected))))
                 ((or (eq algorithm :bcrypt)
                      (and (null algorithm)
                           (or (%prefixp "$2" encoded)
                               (%prefixp "$bcrypt$" encoded))))
                  (multiple-value-bind (cost salt expected)
                      (if (%prefixp "$2" encoded)
                          (%parse-bcrypt-mcf encoded)
                          (%parse-bcrypt-phc encoded))
                    (declare (ignore cost))
                    (unwind-protect t
                      (%wipe salt)
                      (%wipe expected))))
                 (t (%fail :unsupported-algorithm
                           "cannot infer password algorithm")))))
      (%wipe owned-hash))))

(defun verify-password (password encoded-hash &optional algorithm)
  "Verify PASSWORD octets against PHC/MCF ENCODED-HASH octets.
Returns NIL for a validly encoded mismatch and signals PASSWORD-ERROR for an
invalid encoding, unsupported algorithm, or hostile parameters."
  (let ((owned-password (%bounded-octets password "password"
                                         +max-password-bytes+))
        (owned-hash (%bounded-octets encoded-hash "encoded hash"
                                     +max-encoded-hash-bytes+)))
    (unwind-protect
         (if (or (zerop (length owned-password))
                 (zerop (length owned-hash)))
             nil
             (let ((encoded (%ascii-string owned-hash)))
               (cond
                 ((or (and algorithm (member algorithm '(:argon2d :argon2i :argon2id)))
                      (and (null algorithm)
                           (or (%prefixp "$argon2d$" encoded)
                               (%prefixp "$argon2i$" encoded)
                               (%prefixp "$argon2id$" encoded))))
                  (%verify-argon owned-password encoded algorithm))
                 ((or (eq algorithm :bcrypt)
                      (and (null algorithm)
                           (or (%prefixp "$2" encoded)
                               (%prefixp "$bcrypt$" encoded))))
                  (%verify-bcrypt owned-password encoded))
                 (t (%fail :unsupported-algorithm "cannot infer password algorithm")))))
      (%wipe owned-password)
      (%wipe owned-hash))))
