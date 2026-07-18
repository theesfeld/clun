;;;; markdown.lisp — bounded pure-CL Markdown parse / HTML render (Phase 75).
;;;; Engine-free substrate for Clun.markdown. CommonMark-shaped blocks plus GFM
;;;; tables, strikethrough, and task lists. Bounds reject expansion adversaries.

(in-package :clun.markdown)

(defconstant +max-source-length+ (* 4 1024 1024))
(defconstant +max-depth+ 64)
(defconstant +max-nodes+ 100000)

(define-condition markdown-error (error)
  ((code :initarg :code :reader markdown-error-code)
   (reason :initarg :reason :reader markdown-error-reason))
  (:report (lambda (c s)
             (format s "Markdown error ~a: ~a"
                     (markdown-error-code c) (markdown-error-reason c)))))

(defun %fail (code reason)
  (error 'markdown-error :code code :reason reason))

(defstruct (markdown-options (:conc-name markdown-options-))
  (tables t)
  (strikethrough t)
  (tasklists t)
  (autolinks nil)
  (headings nil)
  (hard-soft-breaks nil)
  (no-html-blocks nil)
  (no-html-spans nil)
  (tag-filter nil)
  (collapse-whitespace nil))

(defstruct (md-node (:constructor %make-md-node))
  kind
  (children nil)
  (meta nil)
  (text "" :type string))

(defun make-md (kind &key children meta (text ""))
  (%make-md-node :kind kind :children children :meta meta :text text))

;;; --- helpers ----------------------------------------------------------------

(defun %ascii-downcase (string)
  (map 'string
       (lambda (c)
         (if (char<= #\A c #\Z) (code-char (+ (char-code c) 32)) c))
       string))

(defun %escape-html (string)
  (with-output-to-string (out)
    (loop for c across string do
      (case c
        (#\& (write-string "&amp;" out))
        (#\< (write-string "&lt;" out))
        (#\> (write-string "&gt;" out))
        (#\" (write-string "&quot;" out))
        (t (write-char c out))))))

(defun %slugify (string)
  (let ((out (make-array (length string) :element-type 'character
                                         :fill-pointer 0 :adjustable t))
        (prev-hyphen nil))
    (loop for c across string do
      (cond
        ((or (alphanumericp c) (char= c #\_))
         (vector-push-extend (char-downcase c) out)
         (setf prev-hyphen nil))
        ((and (or (char= c #\Space) (char= c #\-) (char= c #\.))
              (plusp (fill-pointer out))
              (not prev-hyphen))
         (vector-push-extend #\- out)
         (setf prev-hyphen t))))
    (when (and (plusp (fill-pointer out))
               (char= (char out (1- (fill-pointer out))) #\-))
      (decf (fill-pointer out)))
    (coerce out 'string)))

(defun %blank-line-p (line)
  (every (lambda (c) (or (char= c #\Space) (char= c #\Tab))) line))

(defun %indent-width (line)
  (loop for c across line
        for n from 0
        when (char= c #\Tab) sum 4 into w
        when (char= c #\Space) sum 1 into w
        when (not (or (char= c #\Space) (char= c #\Tab)))
          return w
        finally (return w)))

(defun %trim-left (string)
  (let ((i 0) (n (length string)))
    (loop while (and (< i n)
                     (or (char= (char string i) #\Space)
                         (char= (char string i) #\Tab)))
          do (incf i))
    (subseq string i)))

(defun %trim (string)
  (string-trim '(#\Space #\Tab #\Newline #\Return) string))

(defun %starts-with-p (string prefix)
  (and (>= (length string) (length prefix))
       (string= string prefix :end1 (length prefix))))

;;; --- inline parser ----------------------------------------------------------

(defstruct (inline-state (:conc-name is-))
  source
  (pos 0 :type fixnum)
  options
  (node-count 0 :type fixnum)
  (depth 0 :type fixnum))

(defun %count-node (state)
  (when (>= (is-node-count state) +max-nodes+)
    (%fail :limit "Markdown node limit exceeded"))
  (incf (is-node-count state)))

(defun %enter (state)
  (when (>= (is-depth state) +max-depth+)
    (%fail :limit "Markdown nesting depth limit exceeded"))
  (incf (is-depth state)))

(defun %leave (state)
  (decf (is-depth state)))

(defun %peek (state &optional (n 0))
  (let ((i (+ (is-pos state) n)))
    (when (< i (length (is-source state)))
      (char (is-source state) i))))

(defun %eof-p (state)
  (>= (is-pos state) (length (is-source state))))

(defun %advance (state &optional (n 1))
  (incf (is-pos state) n))

(defun %match-string (state string)
  (let* ((src (is-source state))
         (pos (is-pos state))
         (len (length string)))
    (when (and (<= (+ pos len) (length src))
               (string= src string :start1 pos :end1 (+ pos len)))
      (%advance state len)
      t)))

(defun %consume-until (state pred)
  (let ((start (is-pos state))
        (src (is-source state)))
    (loop while (and (< (is-pos state) (length src))
                     (not (funcall pred (char src (is-pos state)))))
          do (%advance state))
    (subseq src start (is-pos state))))

(defun %parse-inline-code (state)
  (let ((ticks 0))
    (loop while (eql (%peek state) #\`) do (incf ticks) (%advance state))
    (let ((start (is-pos state))
          (src (is-source state))
          (end nil))
      (loop while (< (is-pos state) (length src)) do
        (if (eql (%peek state) #\`)
            (let ((count 0) (p (is-pos state)))
              (loop while (and (< p (length src)) (char= (char src p) #\`))
                    do (incf count) (incf p))
              (when (= count ticks)
                (setf end (is-pos state))
                (%advance state ticks)
                (return)))
            (%advance state)))
      (if end
          (progn
            (%count-node state)
            (make-md :codespan :text (subseq src start end)))
          (progn
            (setf (is-pos state) start)
            (%count-node state)
            (make-md :text :text (make-string ticks :initial-element #\`)))))))

(defun %dest-terminator-p (c)
  (or (char= c #\Space) (char= c #\Tab) (char= c #\))))

(defun %parse-link-or-image (state image-p)
  (when image-p (%advance state))
  (%advance state)
  (let ((label-start (is-pos state))
        (depth 1)
        (src (is-source state)))
    (loop while (and (< (is-pos state) (length src)) (plusp depth)) do
      (let ((c (char src (is-pos state))))
        (cond
          ((char= c #\\) (%advance state 2))
          ((char= c #\[) (incf depth) (%advance state))
          ((char= c #\]) (decf depth) (%advance state))
          (t (%advance state)))))
    (unless (zerop depth)
      (setf (is-pos state) label-start)
      (%count-node state)
      (return-from %parse-link-or-image
        (make-md :text :text (if image-p "![" "["))))
    (let ((label-end (1- (is-pos state)))
          (label nil)
          (dest-start nil)
          (dest nil)
          (title nil)
          (children nil))
      (setf label (subseq src label-start label-end))
      (unless (eql (%peek state) #\()
        (setf (is-pos state) label-start)
        (%count-node state)
        (return-from %parse-link-or-image
          (make-md :text :text (if image-p "![" "["))))
      (%advance state)
      (setf dest-start (is-pos state))
      (if (eql (%peek state) #\<)
          (progn
            (%advance state)
            (setf dest (%consume-until state (lambda (c) (char= c #\>))))
            (when (eql (%peek state) #\>) (%advance state)))
          (setf dest (%consume-until state #'%dest-terminator-p)))
      (when (or (eql (%peek state) #\Space) (eql (%peek state) #\Tab))
        (loop while (or (eql (%peek state) #\Space) (eql (%peek state) #\Tab))
              do (%advance state))
        (when (member (%peek state) '(#\" #\' #\())
          (let ((q (if (eql (%peek state) #\() #\) (%peek state))))
            (%advance state)
            (setf title (%consume-until state (lambda (c) (char= c q))))
            (when (eql (%peek state) q) (%advance state)))))
      (unless (eql (%peek state) #\))
        (setf (is-pos state) dest-start)
        (%count-node state)
        (return-from %parse-link-or-image
          (make-md :text :text (if image-p "![" "["))))
      (%advance state)
      (%count-node state)
      (setf children (%parse-inlines-string state label))
      (if image-p
          (make-md :image :children children
                   :meta (list :src dest :title title))
          (make-md :link :children children
                   :meta (list :href dest :title title))))))

(defun %parse-emphasis (state marker)
  "Parse * or _ emphasis / strong. Conservative: requires matching closer."
  (let ((count 0))
    (loop while (eql (%peek state) marker) do (incf count) (%advance state))
    (when (zerop count)
      (return-from %parse-emphasis nil))
    (let* ((start (is-pos state))
           (src (is-source state))
           (close nil)
           (close-count 0))
      (loop while (< (is-pos state) (length src)) do
        (cond
          ((eql (%peek state) #\\) (%advance state 2))
          ((eql (%peek state) marker)
           (let ((n 0) (p (is-pos state)))
             (loop while (and (< p (length src)) (char= (char src p) marker))
                   do (incf n) (incf p))
             (when (>= n 1)
               (setf close (is-pos state) close-count (min n count))
               (return)))
           (%advance state))
          (t (%advance state))))
      (unless close
        (setf (is-pos state) start)
        (%count-node state)
        (return-from %parse-emphasis
          (make-md :text :text (make-string count :initial-element marker))))
      (let ((inner (subseq src start close)))
        (setf (is-pos state) (+ close close-count))
        (%count-node state)
        (let ((children (%parse-inlines-string state inner)))
          (cond
            ((>= close-count 2)
             (make-md :strong :children children))
            (t (make-md :emphasis :children children))))))))

(defun %parse-strikethrough (state)
  (unless (and (markdown-options-strikethrough (is-options state))
               (%match-string state "~~"))
    (return-from %parse-strikethrough nil))
  (let* ((start (is-pos state))
         (src (is-source state))
         (end nil))
    (loop while (< (is-pos state) (length src)) do
      (if (%match-string state "~~")
          (progn (setf end (- (is-pos state) 2)) (return))
          (%advance state)))
    (unless end
      (setf (is-pos state) start)
      (%count-node state)
      (return-from %parse-strikethrough (make-md :text :text "~~")))
    (%count-node state)
    (make-md :strikethrough
             :children (%parse-inlines-string state (subseq src start end)))))

(defun %parse-autolink (state)
  (unless (eql (%peek state) #\<)
    (return-from %parse-autolink nil))
  (let* ((start (is-pos state))
         (src (is-source state)))
    (%advance state)
    (let ((content (%consume-until state (lambda (c) (or (char= c #\>) (char= c #\Space)
                                                         (char= c #\Newline))))))
      (unless (eql (%peek state) #\>)
        (setf (is-pos state) start)
        (return-from %parse-autolink nil))
      (%advance state)
      (when (or (search "://" content) (find #\@ content))
        (%count-node state)
        (return-from %parse-autolink
          (make-md :link
                   :children (list (make-md :text :text content))
                   :meta (list :href (if (and (find #\@ content)
                                              (not (search "://" content)))
                                         (format nil "mailto:~a" content)
                                         content)
                               :title nil))))
      (setf (is-pos state) start)
      nil)))

(defun %parse-html-span (state)
  (when (or (markdown-options-no-html-spans (is-options state))
            (not (eql (%peek state) #\<)))
    (return-from %parse-html-span nil))
  (let* ((start (is-pos state))
         (src (is-source state))
         (next (%peek state 1)))
    (unless (or (alpha-char-p (or next #\Space))
                (eql next #\/)
                (eql next #\!)
                (eql next #\?))
      (return-from %parse-html-span nil))
    (%advance state)
    (loop while (and (< (is-pos state) (length src))
                     (not (char= (char src (is-pos state)) #\>)))
          do (%advance state))
    (when (eql (%peek state) #\>)
      (%advance state)
      (%count-node state)
      (return-from %parse-html-span
        (make-md :html :text (subseq src start (is-pos state)))))
    (setf (is-pos state) start)
    nil))

(defun %parse-inlines-string (state string)
  (let ((saved-source (is-source state))
        (saved-pos (is-pos state)))
    (setf (is-source state) string
          (is-pos state) 0)
    (%enter state)
    (let ((nodes (%parse-inlines state)))
      (%leave state)
      (setf (is-source state) saved-source
            (is-pos state) saved-pos)
      nodes)))

(defun %parse-inlines (state)
  (let ((nodes '())
        (text-buf (make-array 64 :element-type 'character
                                 :fill-pointer 0 :adjustable t)))
    (labels ((flush-text ()
               (when (plusp (fill-pointer text-buf))
                 (%count-node state)
                 ;; COPY-SEQ: do not share storage with the fill-pointer buffer.
                 (push (make-md :text :text (copy-seq text-buf)) nodes)
                 (setf (fill-pointer text-buf) 0)))
             (push-char (c)
               (vector-push-extend c text-buf)))
      (loop until (%eof-p state) do
        (let ((c (%peek state)))
          (cond
            ((eql c #\\)
             (%advance state)
             (if (%eof-p state)
                 (push-char #\\)
                 (progn (push-char (%peek state)) (%advance state))))
            ((eql c #\`)
             (flush-text)
             (push (%parse-inline-code state) nodes))
            ((and (eql c #\~) (eql (%peek state 1) #\~)
                  (markdown-options-strikethrough (is-options state)))
             (flush-text)
             (push (%parse-strikethrough state) nodes))
            ((or (eql c #\*) (eql c #\_))
             (flush-text)
             (push (%parse-emphasis state c) nodes))
            ((and (eql c #\!) (eql (%peek state 1) #\[))
             (flush-text)
             (push (%parse-link-or-image state t) nodes))
            ((eql c #\[)
             (flush-text)
             (push (%parse-link-or-image state nil) nodes))
            ((eql c #\<)
             (flush-text)
             (or (let ((n (%parse-autolink state)))
                   (when n (push n nodes) t))
                 (let ((n (%parse-html-span state)))
                   (when n (push n nodes) t))
                 (progn (push-char c) (%advance state))))
            (t (push-char c) (%advance state)))))
      (flush-text)
      (nreverse nodes))))

;;; --- block parser -----------------------------------------------------------

(defstruct (block-state (:conc-name bs-))
  lines
  (index 0 :type fixnum)
  options
  (node-count 0 :type fixnum)
  (depth 0 :type fixnum))

(defun %b-count (state)
  (when (>= (bs-node-count state) +max-nodes+)
    (%fail :limit "Markdown node limit exceeded"))
  (incf (bs-node-count state)))

(defun %b-enter (state)
  (when (>= (bs-depth state) +max-depth+)
    (%fail :limit "Markdown nesting depth limit exceeded"))
  (incf (bs-depth state)))

(defun %b-leave (state)
  (decf (bs-depth state)))

(defun %line (state)
  (when (< (bs-index state) (length (bs-lines state)))
    (aref (bs-lines state) (bs-index state))))

(defun %advance-line (state)
  (incf (bs-index state)))

(defun %eof-block-p (state)
  (>= (bs-index state) (length (bs-lines state))))

(defun %split-lines (source)
  (let ((lines (make-array 16 :adjustable t :fill-pointer 0))
        (start 0)
        (n (length source)))
    (loop for i from 0 below n do
      (when (char= (char source i) #\Newline)
        (vector-push-extend (subseq source start i) lines)
        (setf start (1+ i))))
    (when (<= start n)
      (vector-push-extend (subseq source start n) lines))
    lines))

(defun %heading-line (line)
  (let ((trimmed (%trim-left line)))
    (when (and (plusp (length trimmed)) (char= (char trimmed 0) #\#))
      (let ((level 0))
        (loop while (and (< level (length trimmed))
                         (char= (char trimmed level) #\#)
                         (< level 6))
              do (incf level))
        (when (and (plusp level)
                   (or (= level (length trimmed))
                       (member (char trimmed level) '(#\Space #\Tab))))
          (values level (%trim (subseq trimmed level))))))))

(defun %hr-line-p (line)
  (let ((trimmed (%trim line)))
    (and (>= (length trimmed) 3)
         (let ((c (char trimmed 0)))
           (and (member c '(#\- #\* #\_))
                (every (lambda (ch) (or (char= ch c) (char= ch #\Space) (char= ch #\Tab)))
                       trimmed)
                (>= (count c trimmed) 3))))))

(defun %fence-line (line)
  (let* ((indent (%indent-width line))
         (trimmed (%trim-left line)))
    (when (and (< indent 4)
               (plusp (length trimmed))
               (or (char= (char trimmed 0) #\`)
                   (char= (char trimmed 0) #\~)))
      (let* ((marker (char trimmed 0))
             (count 0))
        (loop while (and (< count (length trimmed))
                         (char= (char trimmed count) marker))
              do (incf count))
        (when (>= count 3)
          (let ((info (%trim (subseq trimmed count))))
            (when (or (char= marker #\~) (not (find #\` info)))
              (values marker count info indent))))))))

(defun %blockquote-prefix (line)
  (let ((trimmed (%trim-left line)))
    (when (and (plusp (length trimmed)) (char= (char trimmed 0) #\>))
      (let ((rest (subseq trimmed 1)))
        (if (and (plusp (length rest))
                 (or (char= (char rest 0) #\Space)
                     (char= (char rest 0) #\Tab)))
            (subseq rest 1)
            rest)))))

(defun %table-row-p (line)
  (let ((trimmed (%trim line)))
    (and (plusp (length trimmed))
         (find #\| trimmed))))

(defun %split-table-row (line)
  (let* ((trimmed (%trim line))
         (s (if (and (plusp (length trimmed)) (char= (char trimmed 0) #\|))
                (subseq trimmed 1) trimmed))
         (s2 (if (and (plusp (length s)) (char= (char s (1- (length s))) #\|))
                 (subseq s 0 (1- (length s))) s)))
    (mapcar #'%trim
            (loop with parts = '()
                  with start = 0
                  for i from 0 below (length s2)
                  when (char= (char s2 i) #\|)
                    do (push (subseq s2 start i) parts)
                       (setf start (1+ i))
                  finally (push (subseq s2 start) parts)
                          (return (nreverse parts))))))

(defun %table-separator-p (line)
  (let ((cells (%split-table-row line)))
    (and (plusp (length cells))
         (every (lambda (cell)
                  (let ((c (%trim cell)))
                    (and (plusp (length c))
                         (every (lambda (ch)
                                  (or (char= ch #\-) (char= ch #\:)
                                      (char= ch #\Space) (char= ch #\Tab)))
                                c)
                         (find #\- c))))
                cells))))

(defun %align-from-sep (cell)
  (let* ((c (%trim cell))
         (left (and (plusp (length c)) (char= (char c 0) #\:)))
         (right (and (plusp (length c)) (char= (char c (1- (length c))) #\:))))
    (cond ((and left right) "center")
          (right "right")
          (left "left")
          (t nil))))

(defun %parse-paragraph-text (state first)
  (let ((parts (list first)))
    (loop until (%eof-block-p state) do
      (let ((line (%line state)))
        (when (or (%blank-line-p line)
                  (%heading-line line)
                  (%hr-line-p line)
                  (%fence-line line)
                  (%blockquote-prefix line)
                  (nth-value 0 (%list-marker-safe state line))
                  (and (markdown-options-tables (bs-options state))
                       (%table-row-p line)
                       (< (1+ (bs-index state)) (length (bs-lines state)))
                       (%table-separator-p
                        (aref (bs-lines state) (1+ (bs-index state))))))
          (return))
        (push line parts)
        (%advance-line state)))
    (format nil "~{~a~^~%~}" (nreverse parts))))

(defun %list-marker-safe (state line)
  (declare (ignore state))
  (let* ((indent (%indent-width line))
         (trimmed (%trim-left line))
         (opts nil))
    (declare (ignore opts))
    (when (and (< indent 4) (plusp (length trimmed)))
      (cond
        ((member (char trimmed 0) '(#\- #\* #\+))
         (when (and (> (length trimmed) 1)
                    (member (char trimmed 1) '(#\Space #\Tab)))
           (values :bullet indent)))
        ((digit-char-p (char trimmed 0))
         (let ((i 0))
           (loop while (and (< i (length trimmed))
                            (digit-char-p (char trimmed i)))
                 do (incf i))
           (when (and (< i (length trimmed))
                      (member (char trimmed i) '(#\. #\))))
             (values :ordered indent))))))))

(defun %parse-list-marker (state line)
  (let* ((indent (%indent-width line))
         (trimmed (%trim-left line))
         (options (bs-options state)))
    (when (and (< indent 4) (plusp (length trimmed)))
      (cond
        ((member (char trimmed 0) '(#\- #\* #\+))
         (when (and (> (length trimmed) 1)
                    (member (char trimmed 1) '(#\Space #\Tab)))
           (let* ((content (%trim-left (subseq trimmed 1)))
                  (checked nil)
                  (task nil))
             (when (and (markdown-options-tasklists options)
                        (>= (length content) 3)
                        (char= (char content 0) #\[)
                        (member (char content 1) '(#\Space #\x #\X))
                        (char= (char content 2) #\])
                        (or (= (length content) 3)
                            (member (char content 3) '(#\Space #\Tab))))
               (setf task t
                     checked (member (char content 1) '(#\x #\X))
                     content (%trim-left (subseq content 3))))
             (values :bullet indent content task checked nil))))
        ((digit-char-p (char trimmed 0))
         (let ((i 0))
           (loop while (and (< i (length trimmed))
                            (digit-char-p (char trimmed i)))
                 do (incf i))
           (when (and (< i (length trimmed))
                      (member (char trimmed i) '(#\. #\)))
                      (or (= (1+ i) (length trimmed))
                          (member (char trimmed (1+ i)) '(#\Space #\Tab))))
             (let ((start (parse-integer trimmed :end i))
                   (content (if (< (1+ i) (length trimmed))
                                (%trim-left (subseq trimmed (1+ i)))
                                "")))
               (values :ordered indent content nil nil start)))))))))

(defun %parse-blocks (state)
  (%b-enter state)
  (let ((nodes '()))
    (loop until (%eof-block-p state) do
      (let ((line (%line state)))
        (cond
          ((%blank-line-p line)
           (%advance-line state))
          ((multiple-value-bind (level text) (%heading-line line)
             (when level
               (%advance-line state)
               (%b-count state)
               (let* ((inline-state (make-inline-state
                                     :source text :options (bs-options state)
                                     :node-count (bs-node-count state)))
                      (children (%parse-inlines inline-state))
                      (id (when (markdown-options-headings (bs-options state))
                            (%slugify text))))
                 (setf (bs-node-count state) (is-node-count inline-state))
                 (push (make-md :heading
                                :children children
                                :meta (list :level level :id id))
                       nodes))
               t)))
          ((%hr-line-p line)
           (%advance-line state)
           (%b-count state)
           (push (make-md :hr) nodes))
          ((multiple-value-bind (marker count info indent) (%fence-line line)
             (when marker
               (%advance-line state)
               (let ((body (make-array 16 :adjustable t :fill-pointer 0)))
                 (loop until (%eof-block-p state) do
                   (let* ((l (%line state))
                          (t2 (%trim-left l)))
                     (when (and (< (%indent-width l) 4)
                                (>= (length t2) count)
                                (every (lambda (i) (char= (char t2 i) marker))
                                       (loop for i below count collect i))
                                (every (lambda (c)
                                         (or (char= c marker)
                                             (char= c #\Space)
                                             (char= c #\Tab)))
                                       t2))
                       (%advance-line state)
                       (return))
                     (vector-push-extend
                      (if (>= (length l) indent) (subseq l indent) l)
                      body)
                     (%advance-line state)))
                 (%b-count state)
                 (push (make-md :code
                                :text (format nil "~{~a~^~%~}"
                                              (coerce body 'list))
                                :meta (list :language
                                            (let ((lang (%trim info)))
                                              (if (zerop (length lang)) nil
                                                  (car (split-sequence-space lang))))))
                       nodes))
               t)))
          ((let ((rest (%blockquote-prefix line)))
             (when rest
               (let ((bq-lines (make-array 8 :adjustable t :fill-pointer 0)))
                 (loop until (%eof-block-p state) do
                   (let* ((l (%line state))
                          (r (%blockquote-prefix l)))
                     (cond
                       (r (vector-push-extend r bq-lines) (%advance-line state))
                       ((%blank-line-p l) (return))
                       (t (return)))))
                 (let ((inner (make-block-state
                               :lines bq-lines
                               :options (bs-options state)
                               :node-count (bs-node-count state)
                               :depth (bs-depth state))))
                   (%b-count state)
                   (let ((children (%parse-blocks inner)))
                     (setf (bs-node-count state) (bs-node-count inner))
                     (push (make-md :blockquote :children children) nodes))))
               t)))
          ((and (markdown-options-tables (bs-options state))
                (%table-row-p line)
                (< (1+ (bs-index state)) (length (bs-lines state)))
                (%table-separator-p (aref (bs-lines state) (1+ (bs-index state)))))
           (let* ((header-cells (%split-table-row line))
                  (sep-cells (%split-table-row
                              (aref (bs-lines state) (1+ (bs-index state)))))
                  (aligns (mapcar #'%align-from-sep sep-cells))
                  (rows '()))
             (%advance-line state)          ; header
             (%advance-line state)          ; separator
             (loop until (%eof-block-p state) do
               (let ((l (%line state)))
                 (unless (%table-row-p l) (return))
                 (push (%split-table-row l) rows)
                 (%advance-line state)))
             (setf rows (nreverse rows))
             (labels ((cell-nodes (text)
                        (let ((is (make-inline-state
                                   :source text
                                   :options (bs-options state)
                                   :node-count (bs-node-count state))))
                          (prog1 (%parse-inlines is)
                            (setf (bs-node-count state) (is-node-count is))))))
               (%b-count state)
               (let* ((ths (loop for cell in header-cells
                                 for align in aligns
                                 collect (progn
                                           (%b-count state)
                                           (make-md :th
                                                    :children (cell-nodes cell)
                                                    :meta (list :align align)))))
                      (header-row (progn (%b-count state)
                                         (make-md :tr :children ths)))
                      (thead (progn (%b-count state)
                                    (make-md :thead :children (list header-row))))
                      (body-rows
                        (loop for row in rows
                              collect
                              (progn
                                (%b-count state)
                                (make-md
                                 :tr
                                 :children
                                 (loop for cell in row
                                       for align in aligns
                                       collect
                                       (progn
                                         (%b-count state)
                                         (make-md :td
                                                  :children (cell-nodes cell)
                                                  :meta (list :align align))))))))
                      (tbody (when body-rows
                               (%b-count state)
                               (make-md :tbody :children body-rows))))
                 (push (make-md :table
                                :children (if tbody (list thead tbody) (list thead)))
                       nodes)))))
          ((multiple-value-bind (kind indent content task checked start)
               (%parse-list-marker state line)
             (when kind
               (let ((items '())
                     (ordered (eq kind :ordered))
                     (list-start start)
                     (index 0))
                 (loop until (%eof-block-p state) do
                   (let ((l (%line state)))
                     (multiple-value-bind (k2 i2 c2 task2 checked2 start2)
                         (%parse-list-marker state l)
                       (declare (ignore i2 start2))
                       (cond
                         ((and k2 (eq (eq k2 :ordered) ordered))
                          (%advance-line state)
                          (let ((item-text c2)
                                (more '()))
                            (loop until (%eof-block-p state) do
                              (let ((nl (%line state)))
                                (when (or (%blank-line-p nl)
                                          (%parse-list-marker state nl)
                                          (%heading-line nl)
                                          (%hr-line-p nl)
                                          (%fence-line nl)
                                          (%blockquote-prefix nl))
                                  (return))
                                (when (>= (%indent-width nl) (+ indent 2))
                                  (push (%trim-left nl) more)
                                  (%advance-line state)
                                  (return)))
                              (return))
                            (when more
                              (setf item-text
                                    (format nil "~a~%~{~a~^~%~}"
                                            item-text (nreverse more))))
                            (%b-count state)
                            (let* ((is (make-inline-state
                                        :source item-text
                                        :options (bs-options state)
                                        :node-count (bs-node-count state)))
                                   (children
                                     (list (progn
                                             (%b-count state)
                                             (make-md :paragraph
                                                      :children (%parse-inlines is))))))
                              (setf (bs-node-count state) (is-node-count is))
                              (push (make-md
                                     :list-item
                                     :children children
                                     :meta (list :index index
                                                 :depth 0
                                                 :ordered ordered
                                                 :start list-start
                                                 :checked (when task2 checked2)
                                                 :task task2))
                                    items)
                              (incf index))))
                         (t (return))))))
                 (%b-count state)
                 (push (make-md :list
                                :children (nreverse items)
                                :meta (list :ordered ordered
                                            :start list-start
                                            :depth 0))
                       nodes))
               t)))
          (t
           (%advance-line state)
           (let* ((text (%parse-paragraph-text state line))
                  (is (make-inline-state
                       :source text
                       :options (bs-options state)
                       :node-count (bs-node-count state)))
                  (children (%parse-inlines is)))
             (setf (bs-node-count state) (is-node-count is))
             (%b-count state)
             (push (make-md :paragraph :children children) nodes))))))
    (%b-leave state)
    (nreverse nodes)))

(defun split-sequence-space (string)
  (let ((parts '())
        (start 0)
        (n (length string)))
    (loop for i from 0 below n do
      (when (or (char= (char string i) #\Space)
                (char= (char string i) #\Tab))
        (when (< start i) (push (subseq string start i) parts))
        (setf start (1+ i))))
    (when (< start n) (push (subseq string start) parts))
    (nreverse parts)))

(defun parse-markdown (source &optional (options (make-markdown-options)))
  (unless (stringp source)
    (%fail :type "Markdown source must be a string"))
  (when (> (length source) +max-source-length+)
    (%fail :limit "Markdown source exceeds the 4MiB limit"))
  (let* ((lines (%split-lines source))
         (state (make-block-state :lines lines :options options)))
    (make-md :document :children (%parse-blocks state))))

;;; --- HTML rendering ---------------------------------------------------------

(defun %render-children (nodes options callbacks)
  (with-output-to-string (out)
    (dolist (n nodes)
      (write-string (%render-node n options callbacks) out))))

(defun %emit (callbacks kind children meta default)
  "Call KIND callback with CHILDREN content (not wrapped). DEFAULT is a
function of the final children string used when no callback is registered.
Callback may return NIL to omit the node."
  (let ((fn (and callbacks (cdr (assoc kind callbacks)))))
    (if fn
        (or (funcall fn children meta) "")
        (funcall default children))))

(defun %render-node (node options callbacks)
  (ecase (md-node-kind node)
    (:document (%render-children (md-node-children node) options callbacks))
    (:text
     (let ((text (md-node-text node)))
       (%emit callbacks :text (%escape-html text) nil #'identity)))
    (:html
     (%emit callbacks :html (md-node-text node) nil #'identity))
    (:codespan
     (let ((inner (%escape-html (md-node-text node))))
       (%emit callbacks :codespan inner nil
              (lambda (c) (format nil "<code>~a</code>" c)))))
    (:strong
     (let ((inner (%render-children (md-node-children node) options callbacks)))
       (%emit callbacks :strong inner nil
              (lambda (c) (format nil "<strong>~a</strong>" c)))))
    (:emphasis
     (let ((inner (%render-children (md-node-children node) options callbacks)))
       (%emit callbacks :emphasis inner nil
              (lambda (c) (format nil "<em>~a</em>" c)))))
    (:strikethrough
     (let ((inner (%render-children (md-node-children node) options callbacks)))
       (%emit callbacks :strikethrough inner nil
              (lambda (c) (format nil "<del>~a</del>" c)))))
    (:link
     (let* ((meta (md-node-meta node))
            (href (%escape-html (or (getf meta :href) "")))
            (title (getf meta :title))
            (inner (%render-children (md-node-children node) options callbacks)))
       (%emit callbacks :link inner meta
              (lambda (c)
                (if title
                    (format nil "<a href=\"~a\" title=\"~a\">~a</a>"
                            href (%escape-html title) c)
                    (format nil "<a href=\"~a\">~a</a>" href c))))))
    (:image
     (let* ((meta (md-node-meta node))
            (src (%escape-html (or (getf meta :src) "")))
            (title (getf meta :title))
            (alt (%render-children (md-node-children node) options callbacks)))
       (%emit callbacks :image alt meta
              (lambda (c)
                (if title
                    (format nil "<img src=\"~a\" alt=\"~a\" title=\"~a\" />"
                            src c (%escape-html title))
                    (format nil "<img src=\"~a\" alt=\"~a\" />" src c))))))
    (:paragraph
     (let ((inner (%render-children (md-node-children node) options callbacks)))
       (%emit callbacks :paragraph inner nil
              (lambda (c) (format nil "<p>~a</p>~%" c)))))
    (:heading
     (let* ((meta (md-node-meta node))
            (level (getf meta :level))
            (id (getf meta :id))
            (inner (%render-children (md-node-children node) options callbacks))
            (body (if (and id (markdown-options-headings options)
                           (not (eq (markdown-options-headings options) :ids-only)))
                      (format nil "<a href=\"#~a\">~a</a>" id inner)
                      inner)))
       (%emit callbacks :heading body meta
              (lambda (c)
                (if id
                    (format nil "<h~d id=\"~a\">~a</h~d>~%" level id c level)
                    (format nil "<h~d>~a</h~d>~%" level c level))))))
    (:hr
     (%emit callbacks :hr "" nil (lambda (c) (declare (ignore c)) "<hr />~%")))
    (:code
     (let* ((meta (md-node-meta node))
            (lang (getf meta :language))
            (body (%escape-html (md-node-text node))))
       (%emit callbacks :code body meta
              (lambda (c)
                (if lang
                    (format nil "<pre><code class=\"language-~a\">~a</code></pre>~%"
                            (%escape-html lang) c)
                    (format nil "<pre><code>~a</code></pre>~%" c))))))
    (:blockquote
     (let ((inner (%render-children (md-node-children node) options callbacks)))
       (%emit callbacks :blockquote inner nil
              (lambda (c) (format nil "<blockquote>~%~a</blockquote>~%" c)))))
    (:list
     (let* ((meta (md-node-meta node))
            (ordered (getf meta :ordered))
            (start (getf meta :start))
            (inner (%render-children (md-node-children node) options callbacks)))
       (%emit callbacks :list inner meta
              (lambda (c)
                (if ordered
                    (if (and start (/= start 1))
                        (format nil "<ol start=\"~d\">~%~a</ol>~%" start c)
                        (format nil "<ol>~%~a</ol>~%" c))
                    (format nil "<ul>~%~a</ul>~%" c))))))
    (:list-item
     (let* ((meta (md-node-meta node))
            (checked (getf meta :checked))
            (task (getf meta :task))
            (inner (%render-children (md-node-children node) options callbacks)))
       (%emit callbacks :list-item inner meta
              (lambda (c)
                (if task
                    (format nil "<li><input type=\"checkbox\" disabled~a /> ~a</li>~%"
                            (if checked " checked" "")
                            (if (and (%starts-with-p c "<p>")
                                     (>= (length c) 5)
                                     (search "</p>" c :from-end t))
                                (subseq c 3 (search "</p>" c :from-end t))
                                c))
                    (format nil "<li>~a</li>~%" c))))))
    (:table
     (let ((inner (%render-children (md-node-children node) options callbacks)))
       (%emit callbacks :table inner nil
              (lambda (c) (format nil "<table>~%~a</table>~%" c)))))
    (:thead
     (let ((inner (%render-children (md-node-children node) options callbacks)))
       (%emit callbacks :thead inner nil
              (lambda (c) (format nil "<thead>~%~a</thead>~%" c)))))
    (:tbody
     (let ((inner (%render-children (md-node-children node) options callbacks)))
       (%emit callbacks :tbody inner nil
              (lambda (c) (format nil "<tbody>~%~a</tbody>~%" c)))))
    (:tr
     (let ((inner (%render-children (md-node-children node) options callbacks)))
       (%emit callbacks :tr inner nil
              (lambda (c) (format nil "<tr>~%~a</tr>~%" c)))))
    (:th
     (let* ((meta (md-node-meta node))
            (align (getf meta :align))
            (inner (%render-children (md-node-children node) options callbacks)))
       (%emit callbacks :th inner meta
              (lambda (c)
                (if align
                    (format nil "<th align=\"~a\">~a</th>~%" align c)
                    (format nil "<th>~a</th>~%" c))))))
    (:td
     (let* ((meta (md-node-meta node))
            (align (getf meta :align))
            (inner (%render-children (md-node-children node) options callbacks)))
       (%emit callbacks :td inner meta
              (lambda (c)
                (if align
                    (format nil "<td align=\"~a\">~a</td>~%" align c)
                    (format nil "<td>~a</td>~%" c))))))))

(defun markdown-html (source &optional (options (make-markdown-options)))
  (%render-node (parse-markdown source options) options nil))

(defun markdown-render (source callbacks &optional (options (make-markdown-options)))
  "CALLBACKS is an alist of (kind . (lambda (html-or-children meta) -> string|null))."
  (%render-node (parse-markdown source options) options callbacks))
