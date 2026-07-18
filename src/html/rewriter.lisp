;;;; rewriter.lisp — pure-CL HTML rewriter substrate (Phase 75 / HTMLRewriter).
;;;; Tree-based tokenizer + CSS selector matching + element/text/comment mutation.

(in-package :clun.html)

(defconstant +max-source-length+ (* 8 1024 1024))
(defconstant +max-nodes+ 200000)
(defconstant +max-depth+ 256)

(define-condition html-error (error)
  ((code :initarg :code :reader html-error-code)
   (reason :initarg :reason :reader html-error-reason))
  (:report (lambda (c s)
             (format s "HTML error ~a: ~a"
                     (html-error-code c) (html-error-reason c)))))

(defun %fail (code reason)
  (error 'html-error :code code :reason reason))

(defparameter *void-elements*
  '("area" "base" "br" "col" "embed" "hr" "img" "input" "link" "meta"
    "param" "source" "track" "wbr"))

(defun void-element-p (name)
  (member (ascii-downcase name) *void-elements* :test #'string=))

(defun ascii-downcase (string)
  (map 'string
       (lambda (c)
         (if (char<= #\A c #\Z) (code-char (+ (char-code c) 32)) c))
       string))

(defun escape-attr (string)
  (with-output-to-string (out)
    (loop for c across string do
      (case c
        (#\& (write-string "&amp;" out))
        (#\" (write-string "&quot;" out))
        (#\< (write-string "&lt;" out))
        (t (write-char c out))))))

(defun escape-text (string)
  (with-output-to-string (out)
    (loop for c across (or string "") do
      (case c
        (#\& (write-string "&amp;" out))
        (#\< (write-string "&lt;" out))
        (#\> (write-string "&gt;" out))
        (t (write-char c out))))))

;;; --- DOM tree ---------------------------------------------------------------

(defstruct (html-node (:constructor %make-html-node)
                      (:conc-name html-node-))
  kind                                  ; :document :element :text :comment :doctype :raw
  (name "")
  (attrs nil)
  (children nil)
  (text "")
  (self-closing nil)
  (removed nil)                         ; nil | t | :keep-content
  (before nil)
  (after nil)
  (prepend nil)
  (append nil))

(defun make-node (kind &key name attrs children text self-closing)
  (%make-html-node :kind kind :name (or name "") :attrs attrs
                   :children children :text (or text "")
                   :self-closing self-closing))

;;; --- parser -----------------------------------------------------------------

(defstruct (parse-state (:conc-name ps-))
  source
  (pos 0 :type fixnum)
  (node-count 0 :type fixnum)
  (depth 0 :type fixnum))

(defun %count (state)
  (when (>= (ps-node-count state) +max-nodes+)
    (%fail :limit "HTML node limit exceeded"))
  (incf (ps-node-count state)))

(defun %peek (state &optional (n 0))
  (let ((i (+ (ps-pos state) n)))
    (when (< i (length (ps-source state)))
      (char (ps-source state) i))))

(defun %eof-p (state)
  (>= (ps-pos state) (length (ps-source state))))

(defun %advance (state &optional (n 1))
  (incf (ps-pos state) n))

(defun %match (state string)
  (let* ((src (ps-source state))
         (pos (ps-pos state))
         (len (length string)))
    (when (and (<= (+ pos len) (length src))
               (string-equal src string :start1 pos :end1 (+ pos len)))
      (%advance state len)
      t)))

(defun %skip-ws (state)
  (loop while (member (%peek state) '(#\Space #\Tab #\Newline #\Return #\Page))
        do (%advance state)))

(defun %parse-name (state)
  (let ((start (ps-pos state))
        (src (ps-source state)))
    (loop while (and (< (ps-pos state) (length src))
                     (let ((c (char src (ps-pos state))))
                       (or (alphanumericp c) (find c ":_-."))))
          do (%advance state))
    (ascii-downcase (subseq src start (ps-pos state)))))

(defun %parse-attr-value (state)
  (%skip-ws state)
  (let ((c (%peek state)))
    (cond
      ((or (eql c #\") (eql c #\'))
       (%advance state)
       (let ((start (ps-pos state))
             (src (ps-source state)))
         (loop while (and (< (ps-pos state) (length src))
                          (not (char= (char src (ps-pos state)) c)))
               do (%advance state))
         (prog1 (subseq src start (ps-pos state))
           (when (eql (%peek state) c) (%advance state)))))
      (t
       (let ((start (ps-pos state))
             (src (ps-source state)))
         (loop while (and (< (ps-pos state) (length src))
                          (not (member (char src (ps-pos state))
                                       '(#\Space #\Tab #\Newline #\Return #\> #\/))))
               do (%advance state))
         (subseq src start (ps-pos state)))))))

(defun %parse-attributes (state)
  (let ((attrs '()))
    (loop
      (%skip-ws state)
      (let ((c (%peek state)))
        (when (or (null c) (eql c #\>) (eql c #\/))
          (return))
        (let ((name (%parse-name state)))
          (when (zerop (length name))
            (%advance state)
            (return))
          (%skip-ws state)
          (if (eql (%peek state) #\=)
              (progn
                (%advance state)
                (push (cons name (%parse-attr-value state)) attrs))
              (push (cons name "") attrs)))))
    (nreverse attrs)))

(defun %parse-comment (state)
  (%match state "<!--")
  (let ((start (ps-pos state))
        (src (ps-source state)))
    (loop until (or (%eof-p state)
                    (and (eql (%peek state) #\-)
                         (eql (%peek state 1) #\-)
                         (eql (%peek state 2) #\>)))
          do (%advance state))
    (let ((text (subseq src start (ps-pos state))))
      (when (not (%eof-p state)) (%advance state 3))
      (%count state)
      (make-node :comment :text text))))

(defun %parse-doctype (state)
  (let ((start (ps-pos state))
        (src (ps-source state)))
    (loop until (or (%eof-p state) (eql (%peek state) #\>))
          do (%advance state))
    (when (eql (%peek state) #\>) (%advance state))
    (%count state)
    (make-node :doctype :text (subseq src start (ps-pos state)))))

(defun %raw-text-element-p (name)
  (member name '("script" "style" "textarea" "title") :test #'string=))

(defun %parse-raw-text (state end-name)
  (let* ((start (ps-pos state))
         (src (ps-source state))
         (close (format nil "</~a>" end-name))
         (n (length close)))
    (loop until (%eof-p state) do
      (when (and (<= (+ (ps-pos state) n) (length src))
                 (string-equal src close :start1 (ps-pos state)
                                        :end1 (+ (ps-pos state) n)))
        (return))
      (%advance state))
    (subseq src start (ps-pos state))))

(defun %parse-element (state)
  (%advance state)
  (when (eql (%peek state) #\/)
    (let ((start (1- (ps-pos state)))
          (src (ps-source state)))
      (loop until (or (%eof-p state) (eql (%peek state) #\>))
            do (%advance state))
      (when (eql (%peek state) #\>) (%advance state))
      (%count state)
      (return-from %parse-element
        (make-node :raw :text (subseq src start (ps-pos state))))))
  (let ((name (%parse-name state)))
    (when (zerop (length name))
      (%count state)
      (return-from %parse-element (make-node :text :text "<")))
    (let ((attrs (%parse-attributes state))
          (self-closing nil))
      (%skip-ws state)
      (when (eql (%peek state) #\/)
        (setf self-closing t)
        (%advance state))
      (when (eql (%peek state) #\>) (%advance state))
      (%count state)
      (let ((el (make-node :element :name name :attrs attrs
                           :self-closing (or self-closing (void-element-p name)))))
        (unless (or (html-node-self-closing el) (void-element-p name))
          (when (>= (ps-depth state) +max-depth+)
            (%fail :limit "HTML nesting depth limit exceeded"))
          (incf (ps-depth state))
          (cond
            ((%raw-text-element-p name)
             (let ((text (%parse-raw-text state name)))
               (when (plusp (length text))
                 (%count state)
                 (setf (html-node-children el)
                       (list (make-node :text :text text))))
               (%match state (format nil "</~a>" name))))
            (t
             (setf (html-node-children el)
                   (%parse-children state name))))
          (decf (ps-depth state)))
        el))))

(defun %parse-children (state stop-name)
  (let ((children '()))
    (loop until (%eof-p state) do
      (let ((c (%peek state)))
        (cond
          ((eql c #\<)
           (cond
             ((and stop-name (%match state (format nil "</~a>" stop-name)))
              (return))
             ((and (eql (%peek state 1) #\!)
                   (eql (%peek state 2) #\-)
                   (eql (%peek state 3) #\-))
              (push (%parse-comment state) children))
             ((and (eql (%peek state 1) #\!)
                   (let ((n (%peek state 2)))
                     (or (eql n #\D) (eql n #\d))))
              (push (%parse-doctype state) children))
             ((eql (%peek state 1) #\/)
              (let ((start (ps-pos state))
                    (src (ps-source state)))
                (%advance state 2)
                (let ((name (%parse-name state)))
                  (loop until (or (%eof-p state) (eql (%peek state) #\>))
                        do (%advance state))
                  (when (eql (%peek state) #\>) (%advance state))
                  (if (and stop-name (string= name stop-name))
                      (return)
                      (progn
                        (%count state)
                        (push (make-node :raw
                                         :text (subseq src start (ps-pos state)))
                              children))))))
             (t (push (%parse-element state) children))))
          (t
           (let ((start (ps-pos state))
                 (src (ps-source state)))
             (loop while (and (< (ps-pos state) (length src))
                              (not (char= (char src (ps-pos state)) #\<)))
                   do (%advance state))
             (when (< start (ps-pos state))
               (%count state)
               (push (make-node :text
                                :text (subseq src start (ps-pos state)))
                     children)))))))
    (nreverse children)))

(defun parse-html (source)
  (unless (stringp source)
    (%fail :type "HTML source must be a string"))
  (when (> (length source) +max-source-length+)
    (%fail :limit "HTML source exceeds the 8MiB limit"))
  (let* ((state (make-parse-state :source source))
         (children (%parse-children state nil)))
    (make-node :document :children children)))

;;; --- serialization ----------------------------------------------------------

(defun write-fragments (list out)
  (dolist (frag list)
    (write-string frag out)))

(defun serialize-html (node)
  (with-output-to-string (out)
    (serialize-node node out)))

(defun serialize-node (node out)
  (when (eq (html-node-removed node) t)
    (write-fragments (html-node-before node) out)
    (write-fragments (html-node-after node) out)
    (return-from serialize-node))
  (when (eq (html-node-removed node) :keep-content)
    (write-fragments (html-node-before node) out)
    (write-fragments (html-node-prepend node) out)
    (dolist (c (html-node-children node)) (serialize-node c out))
    (write-fragments (html-node-append node) out)
    (write-fragments (html-node-after node) out)
    (return-from serialize-node))
  (write-fragments (html-node-before node) out)
  (ecase (html-node-kind node)
    (:document
     (write-fragments (html-node-prepend node) out)
     (dolist (c (html-node-children node)) (serialize-node c out))
     (write-fragments (html-node-append node) out))
    (:text
     (write-string (html-node-text node) out))
    (:comment
     (format out "<!--~a-->" (html-node-text node)))
    (:doctype
     (write-string (html-node-text node) out)
     (unless (find #\> (html-node-text node) :from-end t)
       (write-char #\> out)))
    (:raw
     (write-string (html-node-text node) out))
    (:element
     (format out "<~a" (html-node-name node))
     (dolist (pair (html-node-attrs node))
       (if (zerop (length (cdr pair)))
           (format out " ~a" (car pair))
           (format out " ~a=\"~a\"" (car pair) (escape-attr (cdr pair)))))
     (cond
       ((html-node-self-closing node)
        (write-string " />" out))
       (t
        (write-char #\> out)
        (write-fragments (html-node-prepend node) out)
        (dolist (c (html-node-children node)) (serialize-node c out))
        (write-fragments (html-node-append node) out)
        (format out "</~a>" (html-node-name node))))))
  (write-fragments (html-node-after node) out))

;;; --- CSS selectors ----------------------------------------------------------

(defstruct sel-simple
  tag
  id
  classes
  attrs)

(defun split-ws (string)
  (let ((parts '())
        (start 0)
        (n (length string)))
    (loop for i from 0 below n do
      (when (member (char string i) '(#\Space #\Tab #\Newline #\Return))
        (when (< start i) (push (subseq string start i) parts))
        (setf start (1+ i))))
    (when (< start n) (push (subseq string start) parts))
    (nreverse parts)))

(defun %selector-skip-ws (selector n i)
  (loop while (and (< i n)
                   (member (char selector i)
                           '(#\Space #\Tab #\Newline #\Return)))
        do (incf i))
  i)

(defun %selector-read-ident (selector n i)
  (let ((start i))
    (loop while (and (< i n)
                     (let ((c (char selector i)))
                       (or (alphanumericp c) (find c "_-"))))
          do (incf i))
    (values (when (< start i)
              (ascii-downcase (subseq selector start i)))
            i)))

(defun %selector-read-attr (selector n i)
  "Parse [attr...] starting after '['. Returns (name op val next-i)."
  (multiple-value-bind (name i) (%selector-read-ident selector n i)
    (let ((op :has)
          (val nil))
      (when (and name (< i n) (char/= (char selector i) #\]))
        (cond
          ((and (< (1+ i) n) (char= (char selector i) #\^)
                (char= (char selector (1+ i)) #\=))
           (setf op :prefix) (incf i 2))
          ((and (< (1+ i) n) (char= (char selector i) #\$)
                (char= (char selector (1+ i)) #\=))
           (setf op :suffix) (incf i 2))
          ((and (< (1+ i) n) (char= (char selector i) #\*)
                (char= (char selector (1+ i)) #\=))
           (setf op :contains) (incf i 2))
          ((and (< (1+ i) n) (char= (char selector i) #\~)
                (char= (char selector (1+ i)) #\=))
           (setf op :word) (incf i 2))
          ((char= (char selector i) #\=)
           (setf op :eq) (incf i)))
        (when (and (< i n)
                   (or (char= (char selector i) #\")
                       (char= (char selector i) #\')))
          (let ((q (char selector i)))
            (incf i)
            (let ((start i))
              (loop while (and (< i n) (char/= (char selector i) q))
                    do (incf i))
              (setf val (subseq selector start i))
              (when (< i n) (incf i)))))
        (when (and (null val) (< i n) (char/= (char selector i) #\]))
          (let ((start i))
            (loop while (and (< i n) (char/= (char selector i) #\]))
                  do (incf i))
            (setf val (subseq selector start i)))))
      (when (and (< i n) (char= (char selector i) #\]))
        (incf i))
      (values name op val i))))

(defun parse-selector (selector)
  "Return a list of (combinator . simple) from left to right."
  (let ((parts '())
        (i 0)
        (n (length selector))
        (comb :self))
    (loop
      (setf i (%selector-skip-ws selector n i))
      (when (>= i n) (return))
      (when (char= (char selector i) #\>)
        (setf comb :child)
        (incf i)
        (setf i (%selector-skip-ws selector n i))
        (when (>= i n) (return)))
      (let ((simple (make-sel-simple :classes nil :attrs nil)))
        (cond
          ((char= (char selector i) #\*)
           (setf (sel-simple-tag simple) "*")
           (incf i))
          (t
           (multiple-value-bind (id ni) (%selector-read-ident selector n i)
             (setf i ni)
             (when id (setf (sel-simple-tag simple) id)))))
        (loop while (< i n) do
          (let ((c (char selector i)))
            (cond
              ((char= c #\.)
               (incf i)
               (multiple-value-bind (cls ni) (%selector-read-ident selector n i)
                 (setf i ni)
                 (when cls (push cls (sel-simple-classes simple)))))
              ((char= c #\#)
               (incf i)
               (multiple-value-bind (id ni) (%selector-read-ident selector n i)
                 (setf i ni
                       (sel-simple-id simple) id)))
              ((char= c #\[)
               (incf i)
               (multiple-value-bind (name op val ni)
                   (%selector-read-attr selector n i)
                 (setf i ni)
                 (when name
                   (push (list name op val) (sel-simple-attrs simple)))))
              (t (return)))))
        (setf (sel-simple-classes simple)
              (nreverse (sel-simple-classes simple))
              (sel-simple-attrs simple)
              (nreverse (sel-simple-attrs simple)))
        (push (cons comb simple) parts)
        (setf comb :descendant)))
    (nreverse parts)))

(defun attr-value (node name)
  (cdr (assoc name (html-node-attrs node) :test #'string-equal)))

(defun class-list (node)
  (let ((v (attr-value node "class")))
    (when v (split-ws v))))

(defun match-simple-p (node simple)
  (unless (eq (html-node-kind node) :element)
    (return-from match-simple-p nil))
  (let ((tag (sel-simple-tag simple)))
    (when (and tag (not (string= tag "*"))
               (not (string= (html-node-name node) tag)))
      (return-from match-simple-p nil)))
  (when (sel-simple-id simple)
    (unless (equal (attr-value node "id") (sel-simple-id simple))
      (return-from match-simple-p nil)))
  (when (sel-simple-classes simple)
    (let ((classes (class-list node)))
      (unless (every (lambda (c) (member c classes :test #'string=))
                     (sel-simple-classes simple))
        (return-from match-simple-p nil))))
  (dolist (spec (sel-simple-attrs simple) t)
    (destructuring-bind (name op val) spec
      (let ((have (attr-value node name)))
        (ecase op
          (:has (unless have (return nil)))
          (:eq (unless (and have (string= have (or val ""))) (return nil)))
          (:prefix
           (unless (and have val (>= (length have) (length val))
                        (string= have val :end1 (length val)))
             (return nil)))
          (:suffix
           (unless (and have val (>= (length have) (length val))
                        (string= have val
                                 :start1 (- (length have) (length val))))
             (return nil)))
          (:contains (unless (and have val (search val have)) (return nil)))
          (:word
           (unless (and have val
                        (member val (split-ws have) :test #'string=))
             (return nil))))))))

(defun selector-matches-p (selector node ancestors)
  "True when SELECTOR matches NODE given ANCESTORS (root→parent)."
  (let ((parts (parse-selector selector)))
    (unless parts (return-from selector-matches-p nil))
    (let* ((rev (reverse parts))
           (cur node)
           (anc ancestors)
           (prev-comb (car (first rev))))
      ;; Subject is the rightmost simple; its combinator describes how we
      ;; reached it from the left neighbor.
      (unless (match-simple-p cur (cdr (first rev)))
        (return-from selector-matches-p nil))
      (let ((remaining (rest rev)))
        (loop while remaining do
          (destructuring-bind (next-comb . simple) (first remaining)
            (ecase prev-comb
              (:self
               (unless (match-simple-p cur simple)
                 (return-from selector-matches-p nil)))
              (:child
               (let ((parent (car (last anc))))
                 (unless (and parent (match-simple-p parent simple))
                   (return-from selector-matches-p nil))
                 (setf cur parent
                       anc (butlast anc))))
              (:descendant
               (let ((found nil))
                 (loop for i from (1- (length anc)) downto 0
                       for parent = (nth i anc)
                       when (match-simple-p parent simple)
                         do (setf cur parent
                                  anc (subseq anc 0 i)
                                  found t)
                            (return))
                 (unless found
                   (return-from selector-matches-p nil)))))
            (setf prev-comb next-comb
                  remaining (rest remaining))))
        t))))

;;; --- mutation API -----------------------------------------------------------

(defun content-string (content html-p)
  (if html-p (or content "") (escape-text content)))

(defun element-tag-name (node) (html-node-name node))
(defun element-namespace-uri (node)
  (declare (ignore node))
  "http://www.w3.org/1999/xhtml")
(defun element-self-closing (node) (not (null (html-node-self-closing node))))
(defun element-can-have-content (node)
  (not (or (html-node-self-closing node)
           (void-element-p (html-node-name node)))))
(defun element-removed (node) (not (null (html-node-removed node))))

(defun element-get-attribute (node name)
  (attr-value node (ascii-downcase name)))

(defun element-has-attribute (node name)
  (not (null (assoc (ascii-downcase name) (html-node-attrs node)
                    :test #'string-equal))))

(defun element-set-attribute (node name value)
  (let* ((n (ascii-downcase name))
         (pair (assoc n (html-node-attrs node) :test #'string-equal)))
    (if pair
        (setf (cdr pair) (or value ""))
        (setf (html-node-attrs node)
              (append (html-node-attrs node)
                      (list (cons n (or value ""))))))
    node))

(defun element-remove-attribute (node name)
  (setf (html-node-attrs node)
        (remove (ascii-downcase name) (html-node-attrs node)
                :key #'car :test #'string-equal))
  node)

(defun element-attributes (node)
  (copy-list (html-node-attrs node)))

(defun element-before (node content &key html)
  (setf (html-node-before node)
        (append (html-node-before node)
                (list (content-string content html))))
  node)

(defun element-after (node content &key html)
  (setf (html-node-after node)
        (append (html-node-after node)
                (list (content-string content html))))
  node)

(defun element-prepend (node content &key html)
  (setf (html-node-prepend node)
        (append (list (content-string content html))
                (html-node-prepend node)))
  node)

(defun element-append (node content &key html)
  (setf (html-node-append node)
        (append (html-node-append node)
                (list (content-string content html))))
  node)

(defun element-set-inner-content (node content &key html)
  (setf (html-node-children node) nil
        (html-node-prepend node) nil
        (html-node-append node) nil)
  (let ((s (content-string content html)))
    (if html
        (let ((frag (parse-html s)))
          (setf (html-node-children node) (html-node-children frag)))
        (when (plusp (length s))
          (setf (html-node-children node)
                (list (make-node :text :text s))))))
  node)

(defun element-remove (node)
  (setf (html-node-removed node) t
        (html-node-children node) nil
        (html-node-prepend node) nil
        (html-node-append node) nil)
  node)

(defun element-remove-and-keep-content (node)
  (setf (html-node-removed node) :keep-content)
  node)

(defun text-chunk-text (node) (html-node-text node))
(defun text-chunk-last-in-text-node (node)
  (declare (ignore node))
  t)
(defun text-chunk-removed (node) (not (null (html-node-removed node))))
(defun text-chunk-before (node content &key html)
  (element-before node content :html html))
(defun text-chunk-after (node content &key html)
  (element-after node content :html html))
(defun text-chunk-replace (node content &key html)
  (setf (html-node-text node) (content-string content html)
        (html-node-removed node) nil)
  node)
(defun text-chunk-remove (node)
  (setf (html-node-removed node) t
        (html-node-text node) "")
  node)

(defun comment-text (node) (html-node-text node))
(defun comment-removed (node) (not (null (html-node-removed node))))
(defun comment-before (node content &key html)
  (element-before node content :html html))
(defun comment-after (node content &key html)
  (element-after node content :html html))
(defun comment-replace (node content &key html)
  (declare (ignore html))
  (setf (html-node-text node) (or content ""))
  node)
(defun comment-remove (node)
  (setf (html-node-removed node) t)
  node)

;;; --- rewriter object --------------------------------------------------------

(defstruct (rewriter (:constructor make-rewriter)
                     (:conc-name rewriter-))
  (element-handlers nil)                ; ((selector . handlers-plist) ...)
  (document-handlers nil))

(defun rewriter-on (rewriter selector handlers)
  (push (cons selector handlers) (rewriter-element-handlers rewriter))
  rewriter)

(defun rewriter-on-document (rewriter handlers)
  (push handlers (rewriter-document-handlers rewriter))
  rewriter)

(defun call-handler (handlers key node)
  (let ((fn (getf handlers key)))
    (when fn (funcall fn node))))

(defun walk-rewrite (node ancestors rewriter)
  (unless (html-node-removed node)
    (case (html-node-kind node)
      (:element
       (dolist (entry (reverse (rewriter-element-handlers rewriter)))
         (destructuring-bind (selector . handlers) entry
           (when (selector-matches-p selector node ancestors)
             (call-handler handlers :element node)
             (unless (html-node-removed node)
               (dolist (child (html-node-children node))
                 (when (eq (html-node-kind child) :text)
                   (call-handler handlers :text child))
                 (when (eq (html-node-kind child) :comment)
                   (call-handler handlers :comments child)))))))
       (unless (html-node-removed node)
         (let ((next (append ancestors (list node))))
           (dolist (child (html-node-children node))
             (walk-rewrite child next rewriter)))))
      (:document
       (dolist (child (html-node-children node))
         (walk-rewrite child ancestors rewriter)))
      (otherwise nil))))

(defun rewrite-html (rewriter source)
  (let ((doc (parse-html source)))
    (dolist (handlers (reverse (rewriter-document-handlers rewriter)))
      (call-handler handlers :doctype doc)
      (call-handler handlers :comments doc)
      (call-handler handlers :text doc)
      (call-handler handlers :end doc))
    (walk-rewrite doc '() rewriter)
    (serialize-html doc)))

(defun rewriter-transform (rewriter source)
  (rewrite-html rewriter source))
