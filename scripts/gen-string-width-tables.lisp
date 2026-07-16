;;;; gen-string-width-tables.lisp -- generate Phase 33's immutable Unicode tables.
;;;;
;;;; Input is the byte-pinned Unicode 17.0.0 corpus in vendor-data/ucd/17.0.0.
;;;; Runtime code loads only the generated CL vectors; it performs no file I/O.

(require :asdf)

(defparameter *repo-root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname *load-truename*)))
(defparameter *ucd-root*
  (merge-pathnames "vendor-data/ucd/17.0.0/" *repo-root*))
(defparameter *output-path*
  (merge-pathnames "src/text/unicode-width-tables.lisp" *repo-root*))
(defparameter *required-ucd-inputs*
  '("DerivedCoreProperties.txt"
    "EastAsianWidth.txt"
    "LICENSE.txt"
    "auxiliary/GraphemeBreakProperty.txt"
    "auxiliary/GraphemeBreakTest.txt"
    "emoji/emoji-data.txt"
    "emoji/emoji-test.txt"))

;; Reuse Clun's vendored, pure-Common-Lisp SHA-256 implementation. Verification
;; occurs before any UCD row is parsed or any generated output is opened.
(load (merge-pathnames "scripts/registry.lisp" *repo-root*))
(asdf:load-system :ironclad)

(defun trim (string)
  (string-trim '(#\Space #\Tab #\Return #\Newline) string))

(defun split-semicolons (string)
  (loop with start = 0
        for end = (position #\; string :start start)
        collect (trim (subseq string start end))
        while end
        do (setf start (1+ end))))

(defun hex-field-p (field)
  (and (<= 1 (length field) 6)
       (every (lambda (character) (digit-char-p character 16)) field)))

(defun parse-codepoint-range (field)
  (let* ((dots (search ".." field))
         (second-dots (and dots (search ".." field :start2 (+ dots 2))))
         (low-field (if dots (subseq field 0 dots) field))
         (high-field (if dots (subseq field (+ dots 2)) field)))
    (unless (and (not second-dots)
                 (hex-field-p low-field)
                 (hex-field-p high-field))
      (error "Malformed Unicode codepoint range ~s" field))
    (let ((low (parse-integer low-field :radix 16))
          (high (parse-integer high-field :radix 16)))
      (unless (and (<= 0 low #x10FFFF)
                   (<= 0 high #x10FFFF)
                   (<= low high))
        (error "Invalid Unicode codepoint range ~s" field))
      (cons low high))))

(defun manifest-relative-path-p (name)
  (and (plusp (length name))
       (not (member (char name 0) '(#\/ #\\)))
       (not (position #\\ name))
       (not (position #\: name))
       (every (lambda (part)
                (and (plusp (length part))
                     (not (member part '("." "..") :test #'string=))))
              (uiop:split-string name :separator '(#\/)))))

(defun sha256-file (pathname)
  (string-downcase
   (ironclad:byte-array-to-hex-string
    (ironclad:digest-file :sha256 pathname))))

(defun verify-manifest ()
  (let ((manifest (merge-pathnames "SHA256SUMS" *ucd-root*))
        (seen (make-hash-table :test #'equal))
        (count 0))
    (with-open-file (in manifest :direction :input :external-format :utf-8)
      (loop for line = (read-line in nil)
            while line
            unless (zerop (length (trim line)))
              do (unless (and (>= (length line) 67)
                              (= (length (subseq line 0 64)) 64)
                              (every (lambda (character)
                                       (and (digit-char-p character 16)
                                            (or (digit-char-p character 10)
                                                (char<= #\a character #\f))))
                                     (subseq line 0 64))
                              (char= (char line 64) #\Space)
                              (char= (char line 65) #\Space))
                   (error "Malformed SHA256SUMS row ~s" line))
                 (let* ((expected (subseq line 0 64))
                        (name (subseq line 66))
                        (pathname (merge-pathnames name *ucd-root*)))
                   (unless (manifest-relative-path-p name)
                     (error "Unsafe SHA256SUMS path ~s" name))
                   (unless (member name *required-ucd-inputs* :test #'string=)
                     (error "Unexpected SHA256SUMS path ~s" name))
                   (when (gethash name seen)
                     (error "Duplicate SHA256SUMS path ~s" name))
                   (setf (gethash name seen) t)
                   (unless (probe-file pathname)
                     (error "Missing pinned Unicode input ~s" name))
                   (let ((actual (sha256-file pathname)))
                     (unless (string= expected actual)
                       (error "SHA-256 mismatch for ~a: expected ~a, got ~a"
                              name expected actual)))
                   (incf count))))
    (dolist (name *required-ucd-inputs*)
      (unless (gethash name seen)
        (error "SHA256SUMS is missing required Unicode input ~s" name)))
    (unless (= count (length *required-ucd-inputs*))
      (error "Unicode manifest must pin exactly ~d inputs, found ~d"
             (length *required-ucd-inputs*) count))
    (format t "~&Verified ~d Unicode 17.0.0 inputs from SHA256SUMS~%" count)))

(defun read-property-file (relative-path selector)
  "Return ranges from RELATIVE-PATH for which SELECTOR accepts parsed fields."
  (let ((result '()))
    (with-open-file (in (merge-pathnames relative-path *ucd-root*)
                        :direction :input :external-format :utf-8)
      (loop for line = (read-line in nil)
            while line
            for hash = (position #\# line)
            for body = (trim (subseq line 0 hash))
            unless (zerop (length body))
              do (let ((fields (split-semicolons body)))
                   (unless (and (>= (length fields) 2)
                                (every (lambda (field) (plusp (length field))) fields))
                     (error "Malformed property row in ~a: ~s" relative-path line))
                   (let ((range (parse-codepoint-range (first fields))))
                     (when (funcall selector fields)
                       (push range result))))))
    (nreverse result)))

(defun merge-ranges (ranges)
  (let ((sorted (sort (copy-list ranges) #'< :key #'car))
        (out '()))
    (dolist (range sorted (nreverse out))
      (if (and out (<= (car range) (1+ (cdar out))))
          (setf (cdar out) (max (cdar out) (cdr range)))
          (push (cons (car range) (cdr range)) out)))))

(defun fields-property-p (property &optional value)
  (lambda (fields)
    (and (>= (length fields) (if value 3 2))
         (string= (second fields) property)
         (or (null value) (string= (third fields) value)))))

(defun fields-one-of-p (&rest properties)
  (lambda (fields)
    (and (>= (length fields) 2)
         (member (second fields) properties :test #'string=))))

(defun load-tables ()
  (flet ((eaw (&rest values)
           (merge-ranges
            (read-property-file "EastAsianWidth.txt"
                                (apply #'fields-one-of-p values))))
         (gcb (value)
           (merge-ranges
            (read-property-file "auxiliary/GraphemeBreakProperty.txt"
                                (fields-property-p value))))
         (emoji (value)
           (merge-ranges
            (read-property-file "emoji/emoji-data.txt"
                                (fields-property-p value))))
         (incb (value)
           (merge-ranges
            (read-property-file "DerivedCoreProperties.txt"
                                (fields-property-p "InCB" value)))))
    (list
     (cons '+unicode-17-eaw-wide+ (eaw "W" "F"))
     (cons '+unicode-17-eaw-ambiguous+ (eaw "A"))
     (cons '+unicode-17-gcb-cr+ (gcb "CR"))
     (cons '+unicode-17-gcb-lf+ (gcb "LF"))
     (cons '+unicode-17-gcb-control+ (gcb "Control"))
     (cons '+unicode-17-gcb-prepend+ (gcb "Prepend"))
     (cons '+unicode-17-gcb-regional-indicator+ (gcb "Regional_Indicator"))
     (cons '+unicode-17-gcb-spacing-mark+ (gcb "SpacingMark"))
     (cons '+unicode-17-gcb-l+ (gcb "L"))
     (cons '+unicode-17-gcb-v+ (gcb "V"))
     (cons '+unicode-17-gcb-t+ (gcb "T"))
     (cons '+unicode-17-gcb-lv+ (gcb "LV"))
     (cons '+unicode-17-gcb-lvt+ (gcb "LVT"))
     (cons '+unicode-17-gcb-zwj+ (gcb "ZWJ"))
     (cons '+unicode-17-gcb-extend+ (gcb "Extend"))
     (cons '+unicode-17-emoji+ (emoji "Emoji"))
     (cons '+unicode-17-emoji-modifier-base+ (emoji "Emoji_Modifier_Base"))
     (cons '+unicode-17-emoji-modifier+ (emoji "Emoji_Modifier"))
     (cons '+unicode-17-extended-pictographic+ (emoji "Extended_Pictographic"))
     (cons '+unicode-17-incb-extend+ (incb "Extend"))
     (cons '+unicode-17-incb-linker+ (incb "Linker"))
     (cons '+unicode-17-incb-consonant+ (incb "Consonant")))))

(defun emit-range-vector (out name ranges)
  (format out "~&(defparameter ~s~%  #(" name)
  (loop for (lo . hi) in ranges
        for index from 0
        do (cond
             ((zerop index))
             ((zerop (mod index 4)) (format out "~%    "))
             (t (write-char #\Space out)))
           (format out "#x~x #x~x" lo hi))
  (format out "))~%")
  (format t "~&  ~a: ~d ranges~%" name (length ranges)))

(defun main ()
  (verify-manifest)
  (let ((tables (load-tables)))
    (ensure-directories-exist *output-path*)
    (with-open-file (out *output-path* :direction :output :if-exists :supersede
                                      :if-does-not-exist :create
                                      :external-format :utf-8)
      (format out ";;;; unicode-width-tables.lisp -- GENERATED; DO NOT EDIT.~%")
      (format out ";;;; Unicode 17.0.0; regenerate with scripts/gen-string-width-tables.lisp.~%")
      (format out ";;;; Inputs are pinned by vendor-data/ucd/17.0.0/SHA256SUMS.~%~%")
      (format out "(in-package :clun.text)~%~%")
      (format out "(defparameter +unicode-width-version+ \"17.0.0\")~%")
      (dolist (table tables)
        (emit-range-vector out (car table) (cdr table))))
    (format t "~&Generated ~a~%" *output-path*)))

(main)
