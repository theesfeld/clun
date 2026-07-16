;;;; csrf.lisp -- engine-free authenticated CSRF token core (Phase 35).
;;;;
;;;; The runtime owns JavaScript coercion, text encoding, clock/CSPRNG access, and
;;;; public errors.  This layer receives validated octets and explicit time/random
;;;; inputs so its wire and authentication behavior is deterministic and testable.

(in-package :clun.csrf)

(defconstant +payload-length+ 32)
(defconstant +nonce-length+ 16)
(defconstant +max-token-length+ 96)
(defconstant +max-base64-raw-length+ 256)
(defconstant +max-base64-normalized-length+ 128)
(defconstant +max-hex-length+ 192)
(defconstant +max-input-bytes+ 1048576)
(defconstant +max-u64+ #xffffffffffffffff)
(defconstant +default-age-ms+ 86400000)

(defparameter +base64-alphabet+
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
(defparameter +base64url-alphabet+
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
(defparameter +hex-alphabet+ "0123456789abcdef")

(deftype octet-vector () '(vector (unsigned-byte 8)))
(deftype simple-octet-vector () '(simple-array (unsigned-byte 8) (*)))

(defun %simple-octets (value label &key (nonempty nil) (bounded nil))
  (unless (typep value 'octet-vector)
    (error 'type-error :datum value :expected-type 'octet-vector))
  (let ((length (length value)))
    (when (and nonempty (zerop length))
      (error "~A must not be empty" label))
    (when (and bounded (> length +max-input-bytes+))
      (error "~A exceeds the ~D-byte limit" label +max-input-bytes+))
    (if (typep value 'simple-octet-vector)
        value
        (let ((copy (make-array length :element-type '(unsigned-byte 8))))
          (replace copy value)
          copy))))

(defun %session-octets (value)
  (and value (%simple-octets value "session ID" :nonempty t :bounded t)))

(defun %u64 (value label)
  (declare (ignore label))
  (unless (typep value '(integer 0 #.+max-u64+))
    (error 'type-error :datum value :expected-type '(integer 0 #.+max-u64+)))
  value)

(defun %algorithm-spec (algorithm)
  "Return Ironclad's digest designator and the corresponding HMAC length."
  (case algorithm
    (:sha256 (values :sha256 32))
    (:sha384 (values :sha384 48))
    (:sha512 (values :sha512 64))
    (:sha512/256 (values :sha512/256 32))
    (:blake2b256 (values :blake2/256 32))
    (:blake2b512 (values :blake2 64))
    (otherwise
     (error 'type-error
            :datum algorithm
            :expected-type
            '(member :sha256 :sha384 :sha512 :sha512/256
                     :blake2b256 :blake2b512)))))

(defun %encoding (encoding)
  (unless (member encoding '(:base64 :base64url :hex) :test #'eq)
    (error 'type-error :datum encoding
                       :expected-type '(member :base64 :base64url :hex)))
  encoding)

(defun %write-u64be (value target start)
  (dotimes (index 8 target)
    (setf (aref target (+ start index))
          (ldb (byte 8 (* 8 (- 7 index))) value))))

(defun %read-u64be (source start)
  (let ((value 0))
    (dotimes (index 8 value)
      (setf value (logior (ash value 8) (aref source (+ start index)))))))

(defun %payload (timestamp-ms nonce expires-in)
  (let ((payload (make-array +payload-length+
                             :element-type '(unsigned-byte 8))))
    (%write-u64be timestamp-ms payload 0)
    (replace payload nonce :start1 8)
    (%write-u64be expires-in payload 24)
    payload))

(defun %hmac (secret digest payload session-id)
  (let ((hmac (crypto:make-hmac secret digest)))
    (crypto:update-hmac hmac payload)
    (when session-id
      (crypto:update-hmac hmac session-id))
    (crypto:hmac-digest hmac)))

(defun %hex-encode (octets)
  (let ((output (make-string (* 2 (length octets)))))
    (loop for byte across octets
          for index from 0 by 2
          do (setf (char output index)
                   (char +hex-alphabet+ (ldb (byte 4 4) byte))
                   (char output (1+ index))
                   (char +hex-alphabet+ (ldb (byte 4 0) byte))))
    output))

(defun %base64-encode (octets url-p)
  (let* ((length (length octets))
         (alphabet (if url-p +base64url-alphabet+ +base64-alphabet+))
         (output-length (if url-p
                            (ceiling (* length 8) 6)
                            (* 4 (ceiling length 3))))
         (output (make-string output-length))
         (out 0))
    (loop for start from 0 below length by 3
          for remaining = (- length start)
          for count = (min remaining 3)
          for first = (aref octets start)
          for second = (if (> count 1) (aref octets (1+ start)) 0)
          for third = (if (> count 2) (aref octets (+ start 2)) 0)
          do (setf (char output out)
                   (char alphabet (ldb (byte 6 2) first))
                   (char output (1+ out))
                   (char alphabet
                         (logior (ash (logand first #x03) 4)
                                 (ldb (byte 4 4) second))))
             (incf out 2)
             (when (> count 1)
               (setf (char output out)
                     (char alphabet
                           (logior (ash (logand second #x0f) 2)
                                   (ldb (byte 2 6) third))))
               (incf out))
             (when (> count 2)
               (setf (char output out)
                     (char alphabet (logand third #x3f)))
               (incf out))
             (unless url-p
               (loop repeat (- 3 count)
                     do (setf (char output out) #\=)
                        (incf out))))
    output))

(defun %encode-token (raw encoding)
  (ecase encoding
    (:hex (%hex-encode raw))
    (:base64 (%base64-encode raw nil))
    (:base64url (%base64-encode raw t))))

(defun %terminal-nul-stripped-end (string)
  (let ((end (length string)))
    (if (and (plusp end) (zerop (char-code (char string (1- end)))))
        (1- end)
        end)))

(defun %hex-value (character)
  (let ((code (char-code character)))
    (cond ((<= (char-code #\0) code (char-code #\9))
           (- code (char-code #\0)))
          ((<= (char-code #\a) code (char-code #\f))
           (+ 10 (- code (char-code #\a))))
          ((<= (char-code #\A) code (char-code #\F))
           (+ 10 (- code (char-code #\A))))
          (t nil))))

(defun %decode-hex (token expected-length)
  (let ((end (%terminal-nul-stripped-end token)))
    (unless (and (<= end +max-hex-length+)
                 (evenp end)
                 (= end (* 2 expected-length)))
      (return-from %decode-hex nil))
    (let ((output (make-array expected-length
                              :element-type '(unsigned-byte 8))))
      (dotimes (index expected-length output)
        (let ((high (%hex-value (char token (* 2 index))))
              (low (%hex-value (char token (1+ (* 2 index))))))
          (unless (and high low)
            (return-from %decode-hex nil))
          (setf (aref output index) (logior (ash high 4) low)))))))

(defun %base64-trim-character-p (character)
  (member (char-code character) '(9 10 11 13 32) :test #'=))

(defun %base64-value (character)
  (let ((code (char-code character)))
    (cond ((<= (char-code #\A) code (char-code #\Z))
           (- code (char-code #\A)))
          ((<= (char-code #\a) code (char-code #\z))
           (+ 26 (- code (char-code #\a))))
          ((<= (char-code #\0) code (char-code #\9))
           (+ 52 (- code (char-code #\0))))
          ((or (= code (char-code #\+)) (= code (char-code #\-))) 62)
          ((or (= code (char-code #\/)) (= code (char-code #\_))) 63)
          (t nil))))

(defun %decode-base64 (token expected-length)
  ;; The raw cap is checked before even inspecting the terminal code unit.
  (when (> (length token) +max-base64-raw-length+)
    (return-from %decode-base64 nil))
  (let* ((end (%terminal-nul-stripped-end token))
         (start 0))
    (loop while (and (< start end)
                     (%base64-trim-character-p (char token start)))
          do (incf start))
    (loop while (and (< start end)
                     (%base64-trim-character-p (char token (1- end))))
          do (decf end))
    (when (> (- end start) +max-base64-normalized-length+)
      (return-from %decode-base64 nil))
    (let ((output (make-array expected-length
                              :element-type '(unsigned-byte 8)))
          (quartet (make-array 4 :element-type '(unsigned-byte 8)))
          (quartet-length 0)
          (out 0))
      (labels ((emit (byte)
                 (when (>= out expected-length)
                   (return-from %decode-base64 nil))
                 (setf (aref output out) byte)
                 (incf out))
               (emit-full-quartet ()
                 (emit (logior (ash (aref quartet 0) 2)
                               (ash (aref quartet 1) -4)))
                 (emit (logior (ash (logand (aref quartet 1) #x0f) 4)
                               (ash (aref quartet 2) -2)))
                 (emit (logior (ash (logand (aref quartet 2) #x03) 6)
                               (aref quartet 3)))))
        (loop for index from start below end
              for character = (char token index)
              for code = (char-code character)
              for value = (%base64-value character)
              do (when (> code 127)
                   (return-from %decode-base64 nil))
                 (when value
                   (setf (aref quartet quartet-length) value)
                   (incf quartet-length)
                   (when (= quartet-length 4)
                     (emit-full-quartet)
                     (setf quartet-length 0))))
        (case quartet-length
          (0 nil)
          (1 (return-from %decode-base64 nil))
          (2 (emit (logior (ash (aref quartet 0) 2)
                           (ash (aref quartet 1) -4))))
          (3 (emit (logior (ash (aref quartet 0) 2)
                           (ash (aref quartet 1) -4)))
             (emit (logior (ash (logand (aref quartet 1) #x0f) 4)
                           (ash (aref quartet 2) -2)))))
        (and (= out expected-length) output)))))

(defun %decode-token (token encoding expected-length)
  (unless (stringp token)
    (error 'type-error :datum token :expected-type 'string))
  (ecase encoding
    (:hex (%decode-hex token expected-length))
    ((:base64 :base64url) (%decode-base64 token expected-length))))

(defun %authenticated-age-valid-p (timestamp age now-ms)
  (or (zerop age)
      (let ((limit (+ timestamp age)))
        (and (<= limit +max-u64+)
             (<= now-ms limit)))))

(defun core-generate (secret-octets
                      &key session-id
                        (expires-in +default-age-ms+)
                        (encoding :base64url)
                        (algorithm :sha256)
                        (timestamp-ms nil timestamp-supplied-p)
                        (nonce nil nonce-supplied-p))
  "Generate a version-0 CSRF token from validated octets and explicit entropy/time.

SECRET-OCTETS and SESSION-ID are replacement-mode UTF-8 bytes supplied by the
runtime.  TIMESTAMP-MS and EXPIRES-IN are unsigned 64-bit integers.  NONCE is
exactly 16 octets.  No clock or random source is consulted here."
  (unless timestamp-supplied-p (error "TIMESTAMP-MS is required"))
  (unless nonce-supplied-p (error "NONCE is required"))
  (let* ((secret (%simple-octets secret-octets "secret" :nonempty t :bounded t))
         (session (%session-octets session-id))
         (timestamp (%u64 timestamp-ms "timestamp"))
         (expiry (%u64 expires-in "expiresIn"))
         (nonce (%simple-octets nonce "nonce")))
    (unless (= (length nonce) +nonce-length+)
      (error "NONCE must contain exactly ~D octets" +nonce-length+))
    (%encoding encoding)
    (multiple-value-bind (digest digest-length) (%algorithm-spec algorithm)
      (let* ((payload (%payload timestamp nonce expiry))
             (mac (%hmac secret digest payload session))
             (raw (make-array (+ +payload-length+ digest-length)
                              :element-type '(unsigned-byte 8))))
        (unless (= (length mac) digest-length)
          (error "Digest ~S produced a ~D-byte HMAC; expected ~D"
                 digest (length mac) digest-length))
        (replace raw payload)
        (replace raw mac :start1 +payload-length+)
        (%encode-token raw encoding)))))

(defun core-verify (token secret-octets
                    &key session-id
                      (max-age +default-age-ms+)
                      (encoding :base64url)
                      (algorithm :sha256)
                      (now-ms nil now-supplied-p))
  "Authenticate TOKEN and then apply its embedded age and caller MAX-AGE.

Malformed tokens and all authentication/expiry failures return NIL.  The
runtime must validate public arguments before calling this octet-oriented core."
  (unless now-supplied-p (error "NOW-MS is required"))
  (let* ((secret (%simple-octets secret-octets "secret" :nonempty t :bounded t))
         (session (%session-octets session-id))
         (now (%u64 now-ms "now"))
         (caller-age (%u64 max-age "maxAge")))
    (%encoding encoding)
    (multiple-value-bind (digest digest-length) (%algorithm-spec algorithm)
      (let* ((expected-length (+ +payload-length+ digest-length))
             (raw (%decode-token token encoding expected-length)))
        (unless raw (return-from core-verify nil))
        (let* ((payload (subseq raw 0 +payload-length+))
               (actual-mac (subseq raw +payload-length+))
               (expected-mac (%hmac secret digest payload session)))
          ;; Length is fixed by the selected public algorithm before the CT call.
          (unless (= (length expected-mac) digest-length)
            (error "Digest ~S produced a ~D-byte HMAC; expected ~D"
                   digest (length expected-mac) digest-length))
          (unless (crypto:constant-time-equal actual-mac expected-mac)
            (return-from core-verify nil))
          ;; Authenticated fields are interpreted only after the MAC succeeds.
          (let ((timestamp (%read-u64be payload 0))
                (embedded-age (%read-u64be payload 24)))
            (and (%authenticated-age-valid-p timestamp embedded-age now)
                 (%authenticated-age-valid-p timestamp caller-age now))))))))
