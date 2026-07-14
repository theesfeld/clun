;;;; semver.lisp — node-semver, ported to pure Common Lisp (Phase 21). This is the
;;;; install pipeline's version library: parse/compare/increment SemVer strings and
;;;; parse/render/test/intersect ranges (caret/tilde/hyphen/x-range/star desugaring,
;;;; loose + includePrerelease). No engine dependency; numeric components use CL
;;;; bignums. Ported from vendor node-semver (CLUN-PIN SHA 6e05b76…): classes/{semver,
;;;; comparator,range}, internal/{re,identifiers}, functions/*, ranges/*.

(in-package :clun.install)

;;; --- constants --------------------------------------------------------------

(defconstant +max-length+ 256 "Longest accepted version/range string (node MAX_LENGTH).")
(defconstant +max-safe-integer+ 9007199254740991
  "2^53-1: a numeric component above this is rejected as too big.")

(define-condition invalid-version (error)
  ((input :initarg :input :reader invalid-version-input)
   (reason :initarg :reason :initform "invalid" :reader invalid-version-reason))
  (:report (lambda (c s) (format s "Invalid version ~s: ~a"
                                 (invalid-version-input c) (invalid-version-reason c)))))

(define-condition invalid-range (error)
  ((input :initarg :input :reader invalid-range-input))
  (:report (lambda (c s) (format s "Invalid SemVer range: ~s" (invalid-range-input c)))))

;;; --- the version struct -----------------------------------------------------

;; prerelease is a list of components: each is an integer (numeric id) or a string.
;; build is a list of strings. version is the canonical "major.minor.patch[-pre]" text.
(defstruct (semver (:constructor %make-semver))
  (major 0)
  (minor 0)
  (patch 0)
  (prerelease nil)
  (build nil)
  (version "" :type string)
  (loose nil))

;;; --- character / string helpers ---------------------------------------------

(declaim (inline ws-char-p digit-char-p* letter-dash-number-p))

(defun ws-char-p (c)
  "JS \\s: space, tab, and the common line terminators (enough for trimming)."
  (member c '(#\Space #\Tab #\Newline #\Return #\Page #\Vt #\No-Break_Space)))

(defun digit-char-p* (c) (char<= #\0 c #\9))

(defun letter-p (c) (or (char<= #\a c #\z) (char<= #\A c #\Z)))

(defun letter-dash-number-p (c)
  "[a-zA-Z0-9-] — the build/identifier alphabet."
  (or (letter-p c) (digit-char-p* c) (char= c #\-)))

(defun all-digits-p (s)
  "True iff S is non-empty and entirely ASCII digits."
  (and (plusp (length s)) (every #'digit-char-p* s)))

(defun trim-ws (s)
  "Trim leading/trailing JS whitespace from S."
  (string-trim '(#\Space #\Tab #\Newline #\Return #\Page #\Vt #\No-Break_Space) s))

(defun collapse-ws (s)
  "Trim S then collapse every run of whitespace to a single space (Range.raw)."
  (let ((s (trim-ws s))
        (out (make-string-output-stream))
        (prev-ws nil))
    (loop for c across s
          do (if (ws-char-p c)
                 (unless prev-ws (write-char #\Space out) (setf prev-ws t))
                 (progn (write-char c out) (setf prev-ws nil))))
    (get-output-stream-string out)))

(defun split-string (s ch)
  "Split S on character CH into a list of substrings (empty parts kept)."
  (loop with start = 0
        for i = (position ch s :start start)
        collect (subseq s start (or i (length s)))
        while i do (setf start (1+ i))))

(defun split-ws (s)
  "Split S on runs of whitespace, dropping empty parts (used for tokenizing)."
  (let ((parts nil) (start nil) (n (length s)))
    (dotimes (i n)
      (if (ws-char-p (char s i))
          (when start (push (subseq s start i) parts) (setf start nil))
          (unless start (setf start i))))
    (when start (push (subseq s start n) parts))
    (nreverse parts)))

(defun js-split-ws-re (s)
  "Faithful JS `s.split(/\\s+/)`: split on whitespace runs, but keep a leading
empty (when S starts with ws) and yield [\"\"] for the empty string."
  (let ((n (length s)))
    (if (zerop n)
        (list "")
        (let ((parts nil) (i 0))
          ;; leading empty if the string starts with whitespace
          (when (ws-char-p (char s 0))
            (push "" parts)
            (loop while (and (< i n) (ws-char-p (char s i))) do (incf i)))
          (loop while (< i n)
                do (let ((start i))
                     (loop while (and (< i n) (not (ws-char-p (char s i)))) do (incf i))
                     (push (subseq s start i) parts)
                     (loop while (and (< i n) (ws-char-p (char s i))) do (incf i))))
          (nreverse parts)))))

;;; --- a tiny cursor-based matcher (hand parser, no regex) ---------------------

;; The reference builds these components out of shared regex tokens. We match the
;; same grammar with a cursor: each %m-* returns the new position or NIL (no match).

(defun %m-numeric-id (s pos)
  "Strict numeric identifier: 0 | [1-9][0-9]* . Returns end pos or NIL."
  (let ((n (length s)))
    (when (< pos n)
      (cond ((char= (char s pos) #\0) (1+ pos))
            ((char<= #\1 (char s pos) #\9)
             (loop for i from (1+ pos) below n
                   while (digit-char-p* (char s i)) finally (return i)))
            (t nil)))))

(defun %m-numeric-id-loose (s pos)
  "Loose numeric identifier: [0-9]+ . Returns end pos or NIL."
  (let ((n (length s)))
    (if (and (< pos n) (digit-char-p* (char s pos)))
        (loop for i from (1+ pos) below n
              while (digit-char-p* (char s i)) finally (return i))
        nil)))

(defun %m-nonnumeric-id (s pos)
  "Non-numeric identifier: \\d*[a-zA-Z-][a-zA-Z0-9-]* . Returns end pos or NIL."
  (let ((n (length s)) (i pos))
    (loop while (and (< i n) (digit-char-p* (char s i))) do (incf i))
    (when (and (< i n) (or (letter-p (char s i)) (char= (char s i) #\-)))
      (incf i)
      (loop while (and (< i n) (letter-dash-number-p (char s i))) do (incf i))
      i)))

(defun %m-prerelease-id (s pos loose)
  "One prerelease identifier: non-numeric first, else numeric. Returns end or NIL."
  (or (%m-nonnumeric-id s pos)
      (if loose (%m-numeric-id-loose s pos) (%m-numeric-id s pos))))

(defun %m-dotted (s pos matcher)
  "id (. id)* using MATCHER for one id. Returns end pos or NIL."
  (let ((e (funcall matcher s pos)))
    (when e
      (loop
        (if (and (< e (length s)) (char= (char s e) #\.))
            (let ((e2 (funcall matcher s (1+ e))))
              (if e2 (setf e e2) (return e)))
            (return e))))))

(defun %m-build-id (s pos)
  "One build identifier: [a-zA-Z0-9-]+ . Returns end or NIL."
  (let ((n (length s)))
    (if (and (< pos n) (letter-dash-number-p (char s pos)))
        (loop for i from (1+ pos) below n
              while (letter-dash-number-p (char s i)) finally (return i))
        nil)))

;;; --- version parsing --------------------------------------------------------

(defun numberify-prerelease (str)
  "Turn STR into an int if it is all-digit and in safe range, else keep the string."
  (if (all-digits-p str)
      (let ((num (parse-integer str)))
        (if (and (>= num 0) (< num +max-safe-integer+)) num str))
      str))

(defun %match-full (s loose)
  "Match a full version string (post-trim). Returns (values major minor patch
prerelease-string build-string) or NIL. LOOSE allows v/=/ws prefixes, loose
numeric ids, and a hyphen-less prerelease."
  (let ((n (length s)) (pos 0))
    ;; prefix: FULL uses optional v?; LOOSE uses [v=\s]*
    (if loose
        (loop while (and (< pos n)
                         (or (char= (char s pos) #\v) (char= (char s pos) #\=)
                             (ws-char-p (char s pos))))
              do (incf pos))
        (when (and (< pos n) (char= (char s pos) #\v)) (incf pos)))
    (let* ((num-m (if loose #'%m-numeric-id-loose #'%m-numeric-id))
           (e1 (funcall num-m s pos)))
      (unless e1 (return-from %match-full nil))
      (unless (and (< e1 n) (char= (char s e1) #\.)) (return-from %match-full nil))
      (let ((major (subseq s pos e1)) (p2 (1+ e1)))
        (let ((e2 (funcall num-m s p2)))
          (unless e2 (return-from %match-full nil))
          (unless (and (< e2 n) (char= (char s e2) #\.)) (return-from %match-full nil))
          (let ((minor (subseq s p2 e2)) (p3 (1+ e2)))
            (let ((e3 (funcall num-m s p3)))
              (unless e3 (return-from %match-full nil))
              (let ((patch (subseq s p3 e3)) (pos e3) (prerelease nil) (build nil))
                ;; prerelease: FULL requires "-…"; LOOSE allows optional "-".
                (when (< pos n)
                  (let ((had-dash (char= (char s pos) #\-)))
                    (when (or had-dash loose)
                      (let* ((start (if had-dash (1+ pos) pos))
                             (pe (%m-dotted s start
                                            (lambda (ss pp) (%m-prerelease-id ss pp loose)))))
                        ;; In strict mode a lone "-" with no id is not a match here;
                        ;; in loose mode the optional dash means we may match at pos.
                        (when (and pe (or had-dash (> pe pos)) (> pe start))
                          (setf prerelease (subseq s start pe) pos pe))))))
                ;; build: "+id(.id)*"
                (when (and (< pos n) (char= (char s pos) #\+))
                  (let ((be (%m-dotted s (1+ pos) #'%m-build-id)))
                    (when be (setf build (subseq s (1+ pos) be) pos be))))
                (when (< pos n) (return-from %match-full nil))
                (values major minor patch prerelease build)))))))))

(defun parse-components (major-s minor-s patch-s pre-s build-s input)
  "Build a semver from matched substrings, applying the too-big check."
  (let ((major (parse-integer major-s))
        (minor (parse-integer minor-s))
        (patch (parse-integer patch-s)))
    (when (> major +max-safe-integer+)
      (error 'invalid-version :input input :reason "Invalid major version"))
    (when (> minor +max-safe-integer+)
      (error 'invalid-version :input input :reason "Invalid minor version"))
    (when (> patch +max-safe-integer+)
      (error 'invalid-version :input input :reason "Invalid patch version"))
    (let ((prerelease (when (and pre-s (plusp (length pre-s)))
                        (mapcar #'numberify-prerelease (split-string pre-s #\.))))
          (build (when (and build-s (plusp (length build-s)))
                   (split-string build-s #\.))))
      (let ((v (%make-semver :major major :minor minor :patch patch
                             :prerelease prerelease :build build)))
        (setf (semver-version v) (format-version v))
        v))))

(defun format-version (v)
  "Canonical version text: major.minor.patch[-prerelease] (build excluded)."
  (with-output-to-string (s)
    (format s "~d.~d.~d" (semver-major v) (semver-minor v) (semver-patch v))
    (when (semver-prerelease v)
      (write-char #\- s)
      (loop for (p . rest) on (semver-prerelease v)
            do (princ p s) (when rest (write-char #\. s))))))

(defun parse-version (version &key loose)
  "Parse a version STRING into a semver struct, or signal INVALID-VERSION.
LOOSE accepts v/= prefixes, hyphen-less prereleases, and loose numeric ids."
  (unless (stringp version)
    (error 'invalid-version :input version :reason "Must be a string"))
  (when (> (length version) +max-length+)
    (error 'invalid-version :input version :reason "version is longer than 256 characters"))
  (multiple-value-bind (ma mi pa pre bld) (%match-full (trim-ws version) loose)
    (unless ma (error 'invalid-version :input version :reason "not a version"))
    (let ((v (parse-components ma mi pa pre bld version)))
      (setf (semver-loose v) (and loose t))
      v)))

(defun version-valid-p (version &key loose)
  "Return the canonical version string if VERSION parses, else NIL."
  (handler-case (semver-version (parse-version version :loose loose))
    (invalid-version () nil)))

(defun ->semver (x &key loose)
  "Coerce X (string or semver) to a semver struct."
  (if (semver-p x) x (parse-version x :loose loose)))

;;; --- identifier + version comparison ----------------------------------------

(defun compare-identifiers (a b)
  "node compareIdentifiers: numbers sort below strings; strings lexicographically."
  (let ((anum (integerp a)) (bnum (integerp b)))
    (cond ((and anum bnum) (cond ((= a b) 0) ((< a b) -1) (t 1)))
          ((and anum (not bnum)) -1)
          ((and bnum (not anum)) 1)
          (t (let ((as (if anum (princ-to-string a) a))
                   (bs (if bnum (princ-to-string b) b)))
               (cond ((string= as bs) 0) ((string< as bs) -1) (t 1)))))))

(defun compare-main (a b)
  (cond ((< (semver-major a) (semver-major b)) -1)
        ((> (semver-major a) (semver-major b)) 1)
        ((< (semver-minor a) (semver-minor b)) -1)
        ((> (semver-minor a) (semver-minor b)) 1)
        ((< (semver-patch a) (semver-patch b)) -1)
        ((> (semver-patch a) (semver-patch b)) 1)
        (t 0)))

(defun compare-pre (a b)
  "Prerelease precedence (semver.org §11): no-prerelease > has-prerelease."
  (let ((pa (semver-prerelease a)) (pb (semver-prerelease b)))
    (cond ((and pa (not pb)) -1)
          ((and (not pa) pb) 1)
          ((and (not pa) (not pb)) 0)
          (t (loop
               (let ((ea (endp pa)) (eb (endp pb)))
                 (cond ((and ea eb) (return 0))
                       (eb (return 1))
                       (ea (return -1))
                       (t (let ((c (compare-identifiers (car pa) (car pb))))
                            (unless (zerop c) (return c))
                            (setf pa (cdr pa) pb (cdr pb)))))))))))

(defun semver-compare (a b)
  "Compare two semver structs: -1/0/1 (build metadata ignored)."
  (if (string= (semver-version a) (semver-version b))
      0
      (let ((m (compare-main a b))) (if (zerop m) (compare-pre a b) m))))

(defun version-compare (a b &key loose)
  "Compare versions A and B (strings or semvers): -1, 0, or 1."
  (semver-compare (->semver a :loose loose) (->semver b :loose loose)))

(defun version-equal (a b &key loose)
  "True iff A and B compare equal (build metadata ignored)."
  (zerop (version-compare a b :loose loose)))

;;; --- increment / truncate ---------------------------------------------------

(defun prerelease-identifier-p (prerelease identifier)
  "node isPrereleaseIdentifier: does IDENTIFIER (dotted) prefix-match PRERELEASE?"
  (let ((ids (split-string identifier #\.)))
    (and (<= (length ids) (length prerelease))
         (loop for id in ids
               for p in prerelease
               always (zerop (compare-identifiers p (numberify-prerelease id)))))))

(defun %valid-prerelease-arg-p (identifier loose)
  "True iff `-IDENTIFIER` parses as a prerelease whose captured text = IDENTIFIER."
  (let* ((s (concatenate 'string "-" identifier))
         (n (length s)))
    (and (> n 1) (char= (char s 0) #\-)
         (let ((pe (%m-dotted s 1 (lambda (ss pp) (%m-prerelease-id ss pp loose)))))
           (and pe (= pe n) (string= (subseq s 1 pe) identifier))))))

(defun %number-truthy-p (x)
  "Mirror JS `Number(x) ? true : false` for identifierBase: number → nonzero;
string → parsed nonzero (else NaN=false); nil/:false/:unset → false."
  (cond ((null x) nil)
        ((eq x :false) nil)
        ((eq x :unset) nil)
        ((numberp x) (/= x 0))
        ((stringp x) (let ((n (ignore-errors
                                (let ((*read-default-float-format* 'double-float))
                                  (read-from-string x nil nil)))))
                       (and (numberp n) (/= n 0))))
        (t t)))

(defun %inc-pre (v identifier identifier-base loose)
  "Port of the SemVer 'pre' increment branch. Mutates and returns V."
  (declare (ignore loose))
  (let ((base (if (%number-truthy-p identifier-base) 1 0)))
    (if (null (semver-prerelease v))
        (setf (semver-prerelease v) (list base))
        (let* ((pre (copy-list (semver-prerelease v)))
               (len (length pre))
               (i len) (bumped nil))
          (loop while (>= (decf i) 0)
                do (when (integerp (nth i pre))
                     (setf (nth i pre) (1+ (nth i pre)) bumped t)
                     (return)))
          (unless bumped
            ;; didn't increment anything → check for the "already exists" error
            (when (and (stringp identifier)
                       (string= identifier (join-prerelease pre))
                       (eq identifier-base :false))
              (error 'invalid-version :input (semver-version v)
                                      :reason "identifier already exists"))
            (setf pre (append pre (list base))))
          (setf (semver-prerelease v) pre)))
    (when (and identifier (stringp identifier) (plusp (length identifier)))
      (let ((prerelease (if (eq identifier-base :false)
                            (list identifier)
                            (list identifier base))))
        (if (prerelease-identifier-p (semver-prerelease v) identifier)
            (let ((pbase (nth (length (split-string identifier #\.))
                              (semver-prerelease v))))
              (when (not (integerp pbase))
                (setf (semver-prerelease v) prerelease)))
            (setf (semver-prerelease v) prerelease))))
    v))

(defun join-prerelease (pre)
  (with-output-to-string (s)
    (loop for (p . rest) on pre do (princ p s) (when rest (write-char #\. s)))))

(defun %inc (v release identifier identifier-base loose)
  "Port of SemVer.inc. RELEASE is a string; mutates and returns V."
  (when (and (>= (length release) 3) (string= (subseq release 0 3) "pre"))
    (when (and (or (null identifier) (and (stringp identifier) (zerop (length identifier))))
               (eq identifier-base :false))
      (error 'invalid-version :input release :reason "identifier is empty"))
    (when (and identifier (stringp identifier) (plusp (length identifier)))
      (unless (%valid-prerelease-arg-p identifier loose)
        (error 'invalid-version :input identifier :reason "invalid identifier"))))
  (cond
    ((string= release "premajor")
     (setf (semver-prerelease v) nil (semver-patch v) 0 (semver-minor v) 0
           (semver-major v) (1+ (semver-major v)))
     (%inc v "pre" identifier identifier-base loose))
    ((string= release "preminor")
     (setf (semver-prerelease v) nil (semver-patch v) 0
           (semver-minor v) (1+ (semver-minor v)))
     (%inc v "pre" identifier identifier-base loose))
    ((string= release "prepatch")
     (setf (semver-prerelease v) nil)
     (%inc v "patch" identifier identifier-base loose)
     (%inc v "pre" identifier identifier-base loose))
    ((string= release "prerelease")
     (when (null (semver-prerelease v))
       (%inc v "patch" identifier identifier-base loose))
     (%inc v "pre" identifier identifier-base loose))
    ((string= release "release")
     (when (null (semver-prerelease v))
       (error 'invalid-version :input (semver-version v) :reason "not a prerelease"))
     (setf (semver-prerelease v) nil))
    ((string= release "major")
     (when (or (/= (semver-minor v) 0) (/= (semver-patch v) 0) (null (semver-prerelease v)))
       (setf (semver-major v) (1+ (semver-major v))))
     (setf (semver-minor v) 0 (semver-patch v) 0 (semver-prerelease v) nil))
    ((string= release "minor")
     (when (or (/= (semver-patch v) 0) (null (semver-prerelease v)))
       (setf (semver-minor v) (1+ (semver-minor v))))
     (setf (semver-patch v) 0 (semver-prerelease v) nil))
    ((string= release "patch")
     (when (null (semver-prerelease v))
       (setf (semver-patch v) (1+ (semver-patch v))))
     (setf (semver-prerelease v) nil))
    ((string= release "pre")
     (%inc-pre v identifier identifier-base loose))
    (t (error 'invalid-version :input release :reason "invalid increment argument")))
  (setf (semver-version v) (format-version v))
  v)

(defun version-inc (version release &key loose identifier (identifier-base :unset))
  "node inc: bump VERSION by RELEASE, returning the new version string or NIL.
IDENTIFIER-BASE of :false disables the numeric suffix; :unset means not provided."
  (handler-case
      (let ((v (->semver (if (semver-p version) (semver-version version) version)
                         :loose loose)))
        ;; node: `identifierBase === false` is the only special case; anything else
        ;; (undefined/unset/a value) is truthy-ish for `Number(identifierBase)`.
        (semver-version (%inc v release identifier
                              (if (eq identifier-base :unset) nil identifier-base)
                              loose)))
    (invalid-version () nil)))

(defparameter +release-types+ '("major" "premajor" "minor" "preminor" "patch"
                                "prepatch" "prerelease")
  "node RELEASE_TYPES: the truncation/increment release identifiers.")

(defun version-truncate (version truncation &key loose)
  "node truncate: drop lower-precedence components. Returns a version string or NIL.
For pre* truncations, returns the version unchanged (prerelease preserved)."
  (unless (member truncation +release-types+ :test #'string=)
    (return-from version-truncate nil))
  (handler-case
      (let ((v (->semver (if (semver-p version) (semver-version version) version)
                         :loose loose)))
        (if (and (>= (length truncation) 3) (string= (subseq truncation 0 3) "pre"))
            (semver-version v)
            (progn
              (setf (semver-prerelease v) nil)
              (cond ((string= truncation "major")
                     (setf (semver-minor v) 0 (semver-patch v) 0))
                    ((string= truncation "minor")
                     (setf (semver-patch v) 0)))
              (setf (semver-version v) (format-version v))
              (semver-version v))))
    (invalid-version () nil)))

;;; --- comparators ------------------------------------------------------------

;; A comparator is an operator string (one of "" "<" "<=" ">" ">=") plus a semver,
;; or the ANY sentinel (operator "", semver :any → matches everything).
(defstruct (comparator (:constructor %make-comparator))
  (operator "" :type string)
  (semver :any)          ; :any or a semver struct
  (value "" :type string)
  (loose nil))

(defun comparator-any-p (c) (eq (comparator-semver c) :any))

(defun parse-comparator-string (comp loose)
  "Parse a single trimmed comparator like '>=1.2.3' or '' (ANY). Signals on junk."
  (let* ((n (length comp)) (pos 0) (op ""))
    (when (zerop n)
      (return-from parse-comparator-string
        (%make-comparator :operator "" :semver :any :value "" :loose loose)))
    ;; GTLT: ((?:<|>)?=?)
    (when (and (< pos n) (member (char comp pos) '(#\< #\>)))
      (incf pos))
    (when (and (< pos n) (char= (char comp pos) #\=))
      (incf pos))
    (setf op (subseq comp 0 pos))
    (when (string= op "=") (setf op ""))
    (let ((rest (subseq comp pos)))
      (if (zerop (length rest))
          (%make-comparator :operator op :semver :any :value "" :loose loose)
          (let ((v (parse-version rest :loose loose)))
            (%make-comparator :operator op :semver v
                              :value (concatenate 'string op (semver-version v))
                              :loose loose))))))

(defun comparator-test (c version)
  "Does VERSION (a semver) satisfy comparator C?"
  (if (comparator-any-p c)
      t
      (let ((op (comparator-operator c)) (cmp (semver-compare version (comparator-semver c))))
        (cond ((or (string= op "") (string= op "=") (string= op "==")) (zerop cmp))
              ((string= op ">") (plusp cmp))
              ((string= op ">=") (>= cmp 0))
              ((string= op "<") (minusp cmp))
              ((string= op "<=") (<= cmp 0))
              (t nil)))))

;;; --- range desugaring (caret/tilde/hyphen/x-range/star) ---------------------

(defun x-p (id)
  "node isX: nil/empty, or x/X/* means 'any' in an x-range position."
  (or (null id) (zerop (length id))
      (string-equal id "x") (string= id "*")))

;; XRANGEPLAIN matcher: [v=\s]*(M)(?:.(m)(?:.(p)(?:-pre)?(?:+build)?)?)?
;; Returns (values M m p pr) as strings/NIL, plus end pos, or NIL if no leading id.
(defun match-xrange-plain (s pos loose)
  (let* ((n (length s)) (i pos)
         (xid (lambda (ss pp)
                (cond ((and (< pp (length ss)) (member (char ss pp) '(#\x #\X #\*)))
                       (1+ pp))
                      (loose (%m-numeric-id-loose ss pp))
                      (t (%m-numeric-id ss pp))))))
    ;; [v=\s]*
    (loop while (and (< i n) (or (char= (char s i) #\v) (char= (char s i) #\=)
                                 (ws-char-p (char s i))))
          do (incf i))
    (let ((e1 (funcall xid s i)))
      (unless e1 (return-from match-xrange-plain nil))
      (let ((mm (subseq s i e1)) (m nil) (p nil) (pr nil) (pos e1))
        (when (and (< pos n) (char= (char s pos) #\.))
          (let ((e2 (funcall xid s (1+ pos))))
            (when e2
              (setf m (subseq s (1+ pos) e2) pos e2)
              (when (and (< pos n) (char= (char s pos) #\.))
                (let ((e3 (funcall xid s (1+ pos))))
                  (when e3
                    (setf p (subseq s (1+ pos) e3) pos e3)
                    ;; optional prerelease
                    (let ((had-dash (and (< pos n) (char= (char s pos) #\-))))
                      (when (or had-dash (and loose (< pos n)
                                              (not (char= (char s pos) #\+))
                                              (not (ws-char-p (char s pos)))))
                        (let* ((start (if had-dash (1+ pos) pos))
                               (pe (%m-dotted s start
                                              (lambda (ss pp) (%m-prerelease-id ss pp loose)))))
                          (when (and pe (> pe start))
                            (setf pr (subseq s start pe) pos pe)))))
                    ;; optional build (consumed, discarded)
                    (when (and (< pos n) (char= (char s pos) #\+))
                      (let ((be (%m-dotted s (1+ pos) #'%m-build-id)))
                        (when be (setf pos be))))))))))
        (values mm m p pr pos)))))

(defun replace-caret-one (comp loose include-prerelease)
  "Desugar one caret comparator. Returns the replacement string (or COMP if no match)."
  (let ((n (length comp)))
    (unless (and (> n 0) (char= (char comp 0) #\^))
      (return-from replace-caret-one comp))
    (multiple-value-bind (mm m p pr endp) (match-xrange-plain comp 1 loose)
      (unless (and mm (= endp n)) (return-from replace-caret-one comp))
      (let ((z (if include-prerelease "-0" "")))
        (cond
          ((x-p mm) "")
          ((x-p m) (format nil ">=~a.0.0~a <~d.0.0-0" mm z (1+ (parse-integer mm))))
          ((x-p p)
           (if (string= mm "0")
               (format nil ">=~a.~a.0~a <~a.~d.0-0" mm m z mm (1+ (parse-integer m)))
               (format nil ">=~a.~a.0~a <~d.0.0-0" mm m z (1+ (parse-integer mm)))))
          (pr
           (cond ((string= mm "0")
                  (if (string= m "0")
                      (format nil ">=~a.~a.~a-~a <~a.~a.~d-0" mm m p pr mm m (1+ (parse-integer p)))
                      (format nil ">=~a.~a.~a-~a <~a.~d.0-0" mm m p pr mm (1+ (parse-integer m)))))
                 (t (format nil ">=~a.~a.~a-~a <~d.0.0-0" mm m p pr (1+ (parse-integer mm))))))
          (t
           (cond ((string= mm "0")
                  (if (string= m "0")
                      (format nil ">=~a.~a.~a <~a.~a.~d-0" mm m p mm m (1+ (parse-integer p)))
                      (format nil ">=~a.~a.~a <~a.~d.0-0" mm m p mm (1+ (parse-integer m)))))
                 (t (format nil ">=~a.~a.~a <~d.0.0-0" mm m p (1+ (parse-integer mm)))))))))))

(defun replace-tilde-one (comp loose include-prerelease)
  "Desugar one tilde comparator."
  (let ((n (length comp)))
    (unless (and (> n 0) (char= (char comp 0) #\~))
      (return-from replace-tilde-one comp))
    (let ((start 1))
      (when (and (< start n) (char= (char comp start) #\>)) (incf start)) ; ~>
      (multiple-value-bind (mm m p pr endp) (match-xrange-plain comp start loose)
        (unless (and mm (= endp n)) (return-from replace-tilde-one comp))
        (let ((z (if include-prerelease "-0" "")))
          (cond
            ((x-p mm) "")
            ((x-p m) (format nil ">=~a.0.0~a <~d.0.0-0" mm z (1+ (parse-integer mm))))
            ((x-p p) (format nil ">=~a.~a.0~a <~a.~d.0-0" mm m z mm (1+ (parse-integer m))))
            (pr (format nil ">=~a.~a.~a-~a <~a.~d.0-0" mm m p pr mm (1+ (parse-integer m))))
            (t (format nil ">=~a.~a.~a <~a.~d.0-0" mm m p mm (1+ (parse-integer m))))))))))

(defun invalid-xrange-order-p (mm m p)
  (or (and (x-p mm) (not (x-p m)))
      (and (x-p m) p (not (x-p p)))))

(defun replace-xrange-one (comp loose include-prerelease)
  "Desugar one x-range comparator (with an optional leading gtlt operator)."
  (let* ((comp (trim-ws comp)) (n (length comp)) (pos 0) (gtlt ""))
    ;; ^GTLT\s*XRANGEPLAIN$
    (when (and (< pos n) (member (char comp pos) '(#\< #\>))) (incf pos))
    (when (and (< pos n) (char= (char comp pos) #\=)) (incf pos))
    (setf gtlt (subseq comp 0 pos))
    (loop while (and (< pos n) (ws-char-p (char comp pos))) do (incf pos))
    (multiple-value-bind (mm m p pr endp) (match-xrange-plain comp pos loose)
      (declare (ignore pr))
      (unless (and mm (= endp n)) (return-from replace-xrange-one comp))
      (when (invalid-xrange-order-p mm m p) (return-from replace-xrange-one comp))
      (let* ((xm (x-p mm)) (xmin (or xm (x-p m))) (xp (or xmin (x-p p)))
             (any-x xp) (pr2 (if include-prerelease "-0" ""))
             (mm2 mm) (m2 m) (p2 p))
        (when (and (string= gtlt "=") any-x) (setf gtlt ""))
        (cond
          (xm
           (if (or (string= gtlt ">") (string= gtlt "<")) "<0.0.0-0" "*"))
          ((and (plusp (length gtlt)) any-x)
           (when xmin (setf m2 0)) (setf p2 0)
           (cond
             ((string= gtlt ">")
              (setf gtlt ">=")
              (if xmin
                  (setf mm2 (1+ (parse-integer mm)) m2 0 p2 0)
                  (setf m2 (1+ (parse-integer m)) p2 0)))
             ((string= gtlt "<=")
              (setf gtlt "<")
              (if xmin (setf mm2 (1+ (parse-integer mm))) (setf m2 (1+ (parse-integer m))))))
           (when (string= gtlt "<") (setf pr2 "-0"))
           (format nil "~a~a.~a.~a~a" gtlt mm2 m2 p2 pr2))
          (xmin (format nil ">=~a.0.0~a <~d.0.0-0" mm pr2 (1+ (parse-integer mm))))
          (xp (format nil ">=~a.~a.0~a <~a.~d.0-0" mm m pr2 mm (1+ (parse-integer m))))
          (t comp))))))

(defun replace-star-one (comp)
  "node replaceStars: strip a leading (<|>)?=?\\s*\\* run to ''."
  (let* ((s (trim-ws comp)) (n (length s)) (pos 0))
    (when (and (< pos n) (member (char s pos) '(#\< #\>))) (incf pos))
    (when (and (< pos n) (char= (char s pos) #\=)) (incf pos))
    (loop while (and (< pos n) (ws-char-p (char s pos))) do (incf pos))
    (if (and (< pos n) (char= (char s pos) #\*))
        (concatenate 'string (subseq s 0 0) (subseq s (1+ pos)))
        s)))

(defun replace-gte0-one (comp include-prerelease)
  "node replaceGTE0: '>=0.0.0' (or '>=0.0.0-0' when includePrerelease) → ''."
  (let ((s (trim-ws comp)))
    (if include-prerelease
        (if (%match-gte0 s "0.0.0-0") "" s)
        (if (%match-gte0 s "0.0.0") "" s))))

(defun %match-gte0 (s core)
  "Match ^\\s*>=\\s*CORE\\s*$."
  (let* ((n (length s)) (pos 0))
    (loop while (and (< pos n) (ws-char-p (char s pos))) do (incf pos))
    (unless (and (<= (+ pos 2) n) (char= (char s pos) #\>) (char= (char s (1+ pos)) #\=))
      (return-from %match-gte0 nil))
    (incf pos 2)
    (loop while (and (< pos n) (ws-char-p (char s pos))) do (incf pos))
    (let ((cl (length core)))
      (unless (and (<= (+ pos cl) n) (string= s core :start1 pos :end1 (+ pos cl)))
        (return-from %match-gte0 nil))
      (setf pos (+ pos cl))
      (loop while (and (< pos n) (ws-char-p (char s pos))) do (incf pos))
      (= pos n))))

;;; --- build-metadata strip + hyphen replace ----------------------------------

(defun strip-build-metadata (s)
  "Remove every `+id(.id)*` build-metadata run from S (BUILDSTRIPRE, global)."
  (let ((out (make-string-output-stream)) (i 0) (n (length s)))
    (loop while (< i n)
          do (if (char= (char s i) #\+)
                 (let ((be (%m-dotted s (1+ i) #'%m-build-id)))
                   (if be (setf i be) (progn (write-char (char s i) out) (incf i))))
                 (progn (write-char (char s i) out) (incf i))))
    (get-output-stream-string out)))

(defun match-hyphen-range (range loose)
  "Match ^\\s*(XRANGEPLAIN)\\s+-\\s+(XRANGEPLAIN)\\s*$. Returns the desugar tuple or NIL."
  (let* ((n (length range)) (pos 0))
    (loop while (and (< pos n) (ws-char-p (char range pos))) do (incf pos))
    (multiple-value-bind (fmm fm fp fpr fend) (match-xrange-plain range pos loose)
      (unless fmm (return-from match-hyphen-range nil))
      (setf pos fend)
      ;; \s+-\s+
      (let ((ws1 pos))
        (loop while (and (< pos n) (ws-char-p (char range pos))) do (incf pos))
        (unless (> pos ws1) (return-from match-hyphen-range nil)))
      (unless (and (< pos n) (char= (char range pos) #\-)) (return-from match-hyphen-range nil))
      (incf pos)
      (let ((ws2 pos))
        (loop while (and (< pos n) (ws-char-p (char range pos))) do (incf pos))
        (unless (> pos ws2) (return-from match-hyphen-range nil)))
      (multiple-value-bind (tmm tm tp tpr tend) (match-xrange-plain range pos loose)
        (unless tmm (return-from match-hyphen-range nil))
        (setf pos tend)
        (loop while (and (< pos n) (ws-char-p (char range pos))) do (incf pos))
        (unless (= pos n) (return-from match-hyphen-range nil))
        (list fmm fm fp fpr tmm tm tp tpr)))))

(defun hyphen-replace (tuple include-prerelease)
  "Port of node hyphenReplace: build the '>=from <to' comparator string."
  (destructuring-bind (fmm fm fp fpr tmm tm tp tpr) tuple
    (let* ((incp (if include-prerelease "-0" ""))
           (from-full (with-output-to-string (s)
                        (format s "~a.~a.~a" fmm (or fm "0") (or fp "0"))
                        (when fpr (format s "-~a" fpr))))
           (from (cond ((x-p fmm) "")
                       ((x-p fm) (format nil ">=~a.0.0~a" fmm incp))
                       ((x-p fp) (format nil ">=~a.~a.0~a" fmm fm incp))
                       (fpr (format nil ">=~a" from-full))
                       (t (format nil ">=~a~a" from-full incp))))
           (to (cond ((x-p tmm) "")
                     ((x-p tm) (format nil "<~d.0.0-0" (1+ (parse-integer tmm))))
                     ((x-p tp) (format nil "<~a.~d.0-0" tmm (1+ (parse-integer tm))))
                     (tpr (format nil "<=~a.~a.~a-~a" tmm tm tp tpr))
                     (include-prerelease (format nil "<~a.~a.~d-0" tmm tm (1+ (parse-integer tp))))
                     (t (format nil "<=~a.~a.~a" tmm tm tp)))))
      (trim-ws (format nil "~a ~a" from to)))))

;;; --- range parsing ----------------------------------------------------------

(defstruct (svrange (:constructor %make-svrange))
  (set nil)          ; list of comparator-lists (OR of ANDs)
  (raw "" :type string)
  (loose nil)
  (include-prerelease nil))

(defun parse-comparator-token (comp loose include-prerelease)
  "node parseComparator: strip build, then caret/tilde/xrange/star, returning text."
  (let ((c (strip-build-metadata comp)))
    (setf c (replace-caret-one c loose include-prerelease))
    (setf c (replace-tilde-one c loose include-prerelease))
    (setf c (replace-xrange-one c loose include-prerelease))
    (replace-star-one c)))

(defun parse-range-set (range loose include-prerelease)
  "Port of Range.parseRange: desugar one ||-separated segment into a comparator list."
  (let ((range (strip-build-metadata (trim-ws range))))
    ;; hyphen range
    (let ((htuple (match-hyphen-range range loose)))
      (when htuple (setf range (hyphen-replace htuple include-prerelease))))
    ;; The comparator-trim/tilde-trim/caret-trim steps collapse "op  x" and
    ;; "~ x"/"^ x" into "opx"; collapse-ws already single-spaced, so handle the
    ;; operator-then-space and tilde/caret-then-space joins explicitly.
    (setf range (trim-adjacent-operators range))
    ;; split on single spaces (keeping empties, like JS .split(' ')), desugar each,
    ;; rejoin, resplit on /\s+/, apply GTE0.
    (let* ((comps (split-string range #\Space))
           (desugared (loop for c in comps
                            collect (parse-comparator-token c loose include-prerelease)))
           (rejoined (format nil "~{~a~^ ~}" desugared))
           (relist (js-split-ws-re rejoined))
           (gte0 (loop for c in relist collect (replace-gte0-one c include-prerelease))))
      (when loose
        (setf gte0 (remove-if-not (lambda (c) (loose-comparator-p c)) gte0)))
      ;; build comparators; a null set short-circuits the whole segment.
      (let ((map nil) (result nil))
        (dolist (c gte0)
          (let ((cmp (parse-comparator-string c loose)))
            (when (comparator-null-set-p cmp)
              (return-from parse-range-set (list cmp)))
            (unless (member (comparator-value cmp) map :test #'string=)
              (push (comparator-value cmp) map)
              (push cmp result))))
        (setf result (nreverse result))
        ;; if >1 comparator and one is '' (any), drop the '' ones.
        (when (and (> (length result) 1)
                   (some (lambda (c) (string= (comparator-value c) "")) result))
          (setf result (remove-if (lambda (c) (string= (comparator-value c) "")) result)))
        result))))

(defun trim-adjacent-operators (range)
  "Collapse 'op  1.2.3' → 'op1.2.3', '~ 1.2' → '~1.2', '^ 1.2' → '^1.2'.
Mirrors COMPARATORTRIM/TILDETRIM/CARETTRIM applied to the single-spaced range."
  (let ((out (make-string-output-stream)) (i 0) (n (length range)))
    (flet ((skip-spaces (j) (loop while (and (< j n) (char= (char range j) #\Space)) do (incf j)) j))
      (loop while (< i n)
            do (let ((c (char range i)))
                 (cond
                   ;; gtlt operator: < > <= >= = == — then optional spaces removed
                   ((member c '(#\< #\>))
                    (write-char c out) (incf i)
                    (when (and (< i n) (char= (char range i) #\=)) (write-char #\= out) (incf i))
                    (setf i (skip-spaces i)))
                   ((char= c #\=)
                    (write-char c out) (incf i)
                    (when (and (< i n) (char= (char range i) #\=)) (write-char #\= out) (incf i))
                    (setf i (skip-spaces i)))
                   ((char= c #\~)
                    (write-char c out) (incf i)
                    (when (and (< i n) (char= (char range i) #\>)) (write-char #\> out) (incf i))
                    (setf i (skip-spaces i)))
                   ((char= c #\^)
                    (write-char c out) (incf i)
                    (setf i (skip-spaces i)))
                   (t (write-char c out) (incf i))))))
    (get-output-stream-string out)))

(defun loose-comparator-p (s)
  "True iff S matches the loose comparator regex ^GTLT\\s*(LOOSEPLAIN)$|^$."
  (or (zerop (length s))
      (handler-case (progn (parse-comparator-string s t) t)
        (invalid-version () nil))))

(defun comparator-null-set-p (c) (string= (comparator-value c) "<0.0.0-0"))
(defun comparator-any-value-p (c) (string= (comparator-value c) ""))

(defun parse-range (range &key loose include-prerelease)
  "Parse a range STRING into an svrange (OR of AND-ed comparator sets). Signals
INVALID-RANGE on a whole-range failure."
  (unless (stringp range)
    (error 'invalid-range :input range))
  (let* ((raw (collapse-ws range))
         (segments (split-substring raw "||"))
         (sets (loop for seg in segments
                     for parsed = (handler-case (parse-range-set (trim-ws seg) loose include-prerelease)
                                    (invalid-version () (error 'invalid-range :input range)))
                     when parsed collect parsed)))
    (when (null sets)
      (error 'invalid-range :input range))
    ;; drop null sets unless they are all null; if any pure-* remains, range is *.
    (when (> (length sets) 1)
      (let ((first (first sets)))
        (setf sets (remove-if (lambda (s) (and (= (length s) 1) (comparator-null-set-p (first s)))) sets))
        (cond ((null sets) (setf sets (list first)))
              ((> (length sets) 1)
               (dolist (s sets)
                 (when (and (= (length s) 1) (comparator-any-value-p (first s)))
                   (setf sets (list s)) (return)))))))
    (%make-svrange :set sets :raw raw :loose (and loose t)
                   :include-prerelease (and include-prerelease t))))

(defun split-substring (s sep)
  "Split S on the literal substring SEP."
  (let ((parts nil) (start 0) (slen (length sep)))
    (loop for i = (search sep s :start2 start)
          do (if i
                 (progn (push (subseq s start i) parts) (setf start (+ i slen)))
                 (progn (push (subseq s start) parts) (return))))
    (nreverse parts)))

(defun range-valid-p (range &key loose include-prerelease)
  "Return the canonical range string if RANGE parses, else NIL ('*' for empty)."
  (handler-case
      (let ((s (range-to-string (parse-range range :loose loose
                                                    :include-prerelease include-prerelease))))
        (if (zerop (length s)) "*" s))
    (invalid-range () nil)))

;;; --- range rendering --------------------------------------------------------

(defun range-to-string (range)
  "Render an svrange: comparator sets joined by ' ', segments by '||'."
  (with-output-to-string (s)
    (loop for (set . rest) on (svrange-set range)
          do (loop for (c . more) on set
                   do (write-string (trim-ws (comparator-value c)) s)
                      (when more (write-char #\Space s)))
          when rest do (write-string "||" s))))

;;; --- satisfaction (Range.test / satisfies) ----------------------------------

(defun test-set (set version include-prerelease)
  "Port of testSet: every comparator matches, plus the prerelease allow-list rule."
  (unless (every (lambda (c) (comparator-test c version)) set)
    (return-from test-set nil))
  (when (and (semver-prerelease version) (not include-prerelease))
    ;; version has a prerelease; only allow it if some comparator pins the same
    ;; major.minor.patch and itself has a prerelease.
    (dolist (c set)
      (unless (comparator-any-p c)
        (let ((allowed (comparator-semver c)))
          (when (semver-prerelease allowed)
            (when (and (= (semver-major allowed) (semver-major version))
                       (= (semver-minor allowed) (semver-minor version))
                       (= (semver-patch allowed) (semver-patch version)))
              (return-from test-set t))))))
    (return-from test-set nil))
  t)

(defun range-test (range version)
  "Does VERSION (a semver) satisfy RANGE (an svrange)?"
  (when (null version) (return-from range-test nil))
  (let ((incp (svrange-include-prerelease range)))
    (dolist (set (svrange-set range) nil)
      (when (test-set set version incp) (return-from range-test t)))))

(defun version-satisfies (version range &key loose include-prerelease)
  "node satisfies: true iff VERSION is inside RANGE. Invalid range → NIL."
  (handler-case
      (let ((r (parse-range range :loose loose :include-prerelease include-prerelease))
            (v (handler-case (->semver version :loose loose)
                 (invalid-version () (return-from version-satisfies nil)))))
        (range-test r v))
    (invalid-range () nil)))

;;; --- outside (gtr / ltr) ----------------------------------------------------

(defun %outside (version range hilo loose include-prerelease)
  "Port of ranges/outside. HILO is :> (gtr) or :< (ltr)."
  (let* ((v (->semver version :loose loose))
         (r (parse-range range :loose loose :include-prerelease include-prerelease)))
    ;; gtfn/ltfn/ltefn/comp/ecomp per direction
    (multiple-value-bind (gtfn ltfn ltefn comp ecomp)
        (if (eq hilo :>)
            (values (lambda (a b) (plusp (semver-compare a b)))    ; gt
                    (lambda (a b) (minusp (semver-compare a b)))   ; lt
                    (lambda (a b) (<= (semver-compare a b) 0))     ; lte
                    ">" ">=")
            (values (lambda (a b) (minusp (semver-compare a b)))   ; lt
                    (lambda (a b) (plusp (semver-compare a b)))    ; gt
                    (lambda (a b) (>= (semver-compare a b) 0))     ; gte
                    "<" "<="))
      (when (range-test r v) (return-from %outside nil))
      (dolist (comparators (svrange-set r))
        (let ((high nil) (low nil))
          (dolist (comparator comparators)
            (let ((comparator (if (comparator-any-p comparator)
                                  (parse-comparator-string ">=0.0.0" nil)
                                  comparator)))
              (setf high (or high comparator) low (or low comparator))
              (cond ((funcall gtfn (comparator-semver comparator) (comparator-semver high))
                     (setf high comparator))
                    ((funcall ltfn (comparator-semver comparator) (comparator-semver low))
                     (setf low comparator)))))
          ;; if the edge comparator points our direction, we're not outside.
          (when (or (string= (comparator-operator high) comp)
                    (string= (comparator-operator high) ecomp))
            (return-from %outside nil))
          (cond
            ((and (or (zerop (length (comparator-operator low)))
                      (string= (comparator-operator low) comp))
                  (funcall ltefn v (comparator-semver low)))
             (return-from %outside nil))
            ((and (string= (comparator-operator low) ecomp)
                  (funcall ltfn v (comparator-semver low)))
             (return-from %outside nil)))))
      t)))

(defun range-gtr (version range &key loose include-prerelease)
  "node gtr: VERSION is greater than every version the RANGE can allow."
  (%outside version range :> loose include-prerelease))

(defun range-ltr (version range &key loose include-prerelease)
  "node ltr: VERSION is less than every version the RANGE can allow."
  (%outside version range :< loose include-prerelease))

;;; --- intersection -----------------------------------------------------------

(defun operator-starts-with (op ch)
  (and (plusp (length op)) (char= (char op 0) ch)))

(defun operator-includes-eq (op) (find #\= op))

(defun comparators-intersect (a b &key loose include-prerelease)
  "node Comparator.intersects: do comparators A and B (strings or structs) overlap?"
  (let ((ca (if (comparator-p a) a (parse-comparator-string (collapse-comp a) loose)))
        (cb (if (comparator-p b) b (parse-comparator-string (collapse-comp b) loose))))
    (%comparators-intersect ca cb loose include-prerelease)))

(defun collapse-comp (s)
  "Trim then single-space a comparator string (node: split(/\\s+/).join(' '))."
  (format nil "~{~a~^ ~}" (split-ws (trim-ws s))))

(defun %comparators-intersect (ca cb loose include-prerelease)
  (declare (ignore loose))
  (let ((opa (comparator-operator ca)) (opb (comparator-operator cb)))
    (cond
      ;; this.operator === '' → ANY: true if empty value, else range(comp).test(this)
      ((string= opa "")
       (if (string= (comparator-value ca) "")
           t
           (range-test (%comparator->range cb include-prerelease)
                       (comparator-semver ca))))
      ((string= opb "")
       (if (string= (comparator-value cb) "")
           t
           (range-test (%comparator->range ca include-prerelease)
                       (comparator-semver cb))))
      (t
       ;; special <0.0.0 / <0.0.0-0 cases
       (cond
         ((and include-prerelease
               (or (string= (comparator-value ca) "<0.0.0-0")
                   (string= (comparator-value cb) "<0.0.0-0")))
          nil)
         ((and (not include-prerelease)
               (or (value-starts-with ca "<0.0.0") (value-starts-with cb "<0.0.0")))
          nil)
         ;; same direction increasing
         ((and (operator-starts-with opa #\>) (operator-starts-with opb #\>)) t)
         ;; same direction decreasing
         ((and (operator-starts-with opa #\<) (operator-starts-with opb #\<)) t)
         ;; same semver, both inclusive
         ((and (string= (semver-version (comparator-semver ca))
                        (semver-version (comparator-semver cb)))
               (operator-includes-eq opa) (operator-includes-eq opb))
          t)
         ;; opposite directions, less-than
         ((and (minusp (semver-compare (comparator-semver ca) (comparator-semver cb)))
               (operator-starts-with opa #\>) (operator-starts-with opb #\<))
          t)
         ;; opposite directions, greater-than
         ((and (plusp (semver-compare (comparator-semver ca) (comparator-semver cb)))
               (operator-starts-with opa #\<) (operator-starts-with opb #\>))
          t)
         (t nil))))))

(defun value-starts-with (c prefix)
  (let ((v (comparator-value c)))
    (and (>= (length v) (length prefix))
         (string= v prefix :end1 (length prefix)))))

(defun %comparator->range (c include-prerelease)
  "Build a Range from a single comparator's value (for intersects ANY handling)."
  (parse-range (comparator-value c) :include-prerelease include-prerelease))

(defun range-set-satisfiable-p (comparators include-prerelease)
  "node isSatisfiable: does some version satisfy the whole AND-ed comparator set?"
  (let ((result t) (remaining (copy-list comparators)))
    (let ((test-comp (car (last remaining))))
      (setf remaining (butlast remaining))
      (loop while (and result remaining)
            do (setf result (every (lambda (o) (%comparators-intersect test-comp o nil include-prerelease))
                                    remaining))
               (setf test-comp (car (last remaining)))
               (setf remaining (butlast remaining))))
    result))

(defun ranges-intersect (a b &key loose include-prerelease)
  "node intersects: do ranges A and B (strings or svranges) overlap?"
  (let ((ra (if (svrange-p a) a (parse-range a :loose loose :include-prerelease include-prerelease)))
        (rb (if (svrange-p b) b (parse-range b :loose loose :include-prerelease include-prerelease))))
    (some (lambda (this-set)
            (and (range-set-satisfiable-p this-set include-prerelease)
                 (some (lambda (range-set)
                         (and (range-set-satisfiable-p range-set include-prerelease)
                              (every (lambda (tc)
                                       (every (lambda (rc)
                                                (%comparators-intersect tc rc loose include-prerelease))
                                              range-set))
                                     this-set)))
                       (svrange-set rb))))
          (svrange-set ra))))
