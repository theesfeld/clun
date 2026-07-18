;;;; markdown.lisp — bounded pure-CL Markdown (CommonMark + GFM subset).
;;;; Powers Clun.markdown.html / .render. No JS parser; limits fail closed.

(in-package :clun.markdown)

(defconstant +max-source-length+ (* 16 1024 1024))
(defconstant +max-nodes+ 1000000)
(defconstant +max-depth+ 256)

(define-condition markdown-error (error)
  ((code :initarg :code :reader markdown-error-code)
   (reason :initarg :reason :reader markdown-error-reason))
  (:report (lambda (c s)
             (format s "~a" (markdown-error-reason c)))))

(defun %fail (code reason)
  (error 'markdown-error :code code :reason reason))

(defstruct (md-options (:conc-name mdo-))
  (tables t)
  (strikethrough t)
  (tasklists t)
  (autolinks nil)
  (autolink-url nil)
  (autolink-www nil)
  (autolink-email nil)
  (headings-ids nil)
  (headings-autolink nil)
  (hard-soft-breaks nil)
  (wiki-links nil)
  (underline nil)
  (latex-math nil)
  (collapse-whitespace nil)
  (permissive-atx nil)
  (no-indented-code nil)
  (no-html-blocks nil)
  (no-html-spans nil)
  (tag-filter nil))

(defstruct (md-node (:conc-name mdn-))
  kind
  children
  meta)

(defun %node (kind &optional children &rest meta-plist)
  (make-md-node :kind kind
                :children (or children '())
                :meta (when meta-plist
                        (loop for (k v) on meta-plist by #'cddr
                              collect (cons k v)))))

(defun %meta (node key &optional default)
  (or (cdr (assoc key (mdn-meta node))) default))

(defun %set-meta (node key value)
  (let ((pair (assoc key (mdn-meta node))))
    (if pair
        (setf (cdr pair) value)
        (push (cons key value) (mdn-meta node))))
  value)

;;; --- options ---------------------------------------------------------------

(defun default-options ()
  (make-md-options))

(defun %truthy-plist (plist key default)
  (let ((cell (member key plist)))
    (if cell (second cell) default)))

(defun options-from-plist (plist)
  (let ((o (default-options)))
    (setf (mdo-tables o) (%truthy-plist plist :tables t)
          (mdo-strikethrough o) (%truthy-plist plist :strikethrough t)
          (mdo-tasklists o) (%truthy-plist plist :tasklists t)
          (mdo-hard-soft-breaks o) (%truthy-plist plist :hard-soft-breaks nil)
          (mdo-wiki-links o) (%truthy-plist plist :wiki-links nil)
          (mdo-underline o) (%truthy-plist plist :underline nil)
          (mdo-latex-math o) (%truthy-plist plist :latex-math nil)
          (mdo-collapse-whitespace o) (%truthy-plist plist :collapse-whitespace nil)
          (mdo-permissive-atx o) (%truthy-plist plist :permissive-atx nil)
          (mdo-no-indented-code o) (%truthy-plist plist :no-indented-code nil)
          (mdo-no-html-blocks o) (%truthy-plist plist :no-html-blocks nil)
          (mdo-no-html-spans o) (%truthy-plist plist :no-html-spans nil)
          (mdo-tag-filter o) (%truthy-plist plist :tag-filter nil))
    (let ((al (%truthy-plist plist :autolinks nil)))
      (cond
        ((eq al t)
         (setf (mdo-autolinks o) t
               (mdo-autolink-url o) t
               (mdo-autolink-www o) t
               (mdo-autolink-email o) t))
        ((consp al)
         (setf (mdo-autolinks o) t
               (mdo-autolink-url o) (%truthy-plist al :url nil)
               (mdo-autolink-www o) (%truthy-plist al :www nil)
               (mdo-autolink-email o) (%truthy-plist al :email nil)))))
    (let ((h (%truthy-plist plist :headings nil)))
      (cond
        ((eq h t)
         (setf (mdo-headings-ids o) t (mdo-headings-autolink o) t))
        ((consp h)
         (setf (mdo-headings-ids o) (%truthy-plist h :ids nil)
               (mdo-headings-autolink o) (%truthy-plist h :autolink nil)))))
    o))

;;; --- helpers ---------------------------------------------------------------

(defun %ws-p (c)
  (or (char= c #\Space) (char= c #\Tab) (char= c #\Page)))

(defun %blank-line-p (line)
  (every #'%ws-p line))

(defun %trim (s)
  (string-trim '(#\Space #\Tab #\Newline #\Return #\Page) s))

(defun %ltrim (s)
  (let ((i 0) (n (length s)))
    (loop while (and (< i n) (%ws-p (char s i))) do (incf i))
    (subseq s i)))

(defun %indent-width (line)
  (loop for c across line
        for i from 0
        sum (cond ((char= c #\Space) 1)
                  ((char= c #\Tab) (- 4 (mod i 4)))
                  (t 0))
        into w
        when (not (or (char= c #\Space) (char= c #\Tab)))
          return w
        finally (return w)))

(defun %strip-indent (line n)
  "Remove up to N columns of leading indent (spaces/tabs expanded to 4)."
  (let ((i 0) (cols 0) (len (length line)))
    (loop while (and (< i len) (< cols n))
          do (let ((c (char line i)))
               (cond
                 ((char= c #\Space) (incf cols) (incf i))
                 ((char= c #\Tab)
                  (let ((add (- 4 (mod cols 4))))
                    (if (> (+ cols add) n)
                        (return)
                        (progn (incf cols add) (incf i)))))
                 (t (return)))))
    (subseq line i)))

(defun %split-lines (source)
  (let ((lines (make-array 16 :adjustable t :fill-pointer 0))
        (start 0)
        (len (length source)))
    (loop for i from 0 below len
          do (let ((c (char source i)))
               (when (or (char= c #\Newline) (char= c #\Return))
                 (vector-push-extend (subseq source start i) lines)
                 (when (and (char= c #\Return)
                            (< (1+ i) len)
                            (char= (char source (1+ i)) #\Newline))
                   (incf i))
                 (setf start (1+ i)))))
    (when (<= start len)
      (vector-push-extend (subseq source start) lines))
    lines))

(defun %escape-html (text)
  (with-output-to-string (out)
    (loop for c across text
          do (case c
               (#\& (write-string "&amp;" out))
               (#\< (write-string "&lt;" out))
               (#\> (write-string "&gt;" out))
               (#\" (write-string "&quot;" out))
               (t (write-char c out))))))

(defun %heading-id (text)
  (let ((s (string-downcase (%trim text))))
    (with-output-to-string (out)
      (loop for c across s
            do (cond
                 ((or (alphanumericp c) (char= c #\-) (char= c #\_))
                  (write-char c out))
                 ((%ws-p c) (write-char #\- out)))))))

;;; --- inline parser ---------------------------------------------------------

(defstruct (inline-state (:conc-name is-))
  (text "" :type string)
  (pos 0 :type fixnum)
  options
  (nodes 0 :type fixnum)
  (depth 0 :type fixnum))

(defun %bump-node (state)
  (when (>= (is-nodes state) +max-nodes+)
    (%fail :node-limit "Markdown node limit exceeded"))
  (incf (is-nodes state)))

(defun %enter (state)
  (when (>= (is-depth state) +max-depth+)
    (%fail :depth-limit "Markdown nesting depth limit exceeded"))
  (incf (is-depth state)))

(defun %leave (state)
  (decf (is-depth state)))

(defun %peek (state &optional (n 0))
  (let ((i (+ (is-pos state) n)))
    (when (< i (length (is-text state)))
      (char (is-text state) i))))

(defun %advance (state &optional (n 1))
  (incf (is-pos state) n))

(defun %rest (state)
  (subseq (is-text state) (is-pos state)))

(defun %match-prefix (state prefix)
  (let* ((text (is-text state))
         (pos (is-pos state))
         (n (length prefix)))
    (and (<= (+ pos n) (length text))
         (string= text prefix :start1 pos :end1 (+ pos n)))))

(defun %parse-code-span (state)
  (let ((ticks 0))
    (loop while (eql (%peek state) #\`) do (incf ticks) (%advance state))
    (let ((start (is-pos state))
          (text (is-text state))
          (end nil)
          (i (is-pos state)))
      (loop while (< i (length text))
            do (if (char= (char text i) #\`)
                   (let ((j i) (count 0))
                     (loop while (and (< j (length text)) (char= (char text j) #\`))
                           do (incf count) (incf j))
                     (when (= count ticks)
                       (setf end i)
                       (setf (is-pos state) j)
                       (return))
                     (setf i j))
                   (incf i)))
      (if end
          (progn
            (%bump-node state)
            (%node :codespan (list (subseq text start end))))
          (progn
            (setf (is-pos state) start)
            (decf (is-pos state) ticks)
            nil)))))

(defun %parse-link-or-image (state image-p)
  (when image-p (%advance state))              ; skip !
  (unless (eql (%peek state) #\[) (return-from %parse-link-or-image nil))
  (%advance state)
  (let ((label-start (is-pos state))
        (depth 1)
        (text (is-text state))
        (i (is-pos state)))
    (loop while (and (< i (length text)) (plusp depth))
          do (let ((c (char text i)))
               (cond
                 ((char= c #\\) (incf i 2))
                 ((char= c #\[) (incf depth) (incf i))
                 ((char= c #\]) (decf depth) (incf i))
                 (t (incf i)))))
    (when (plusp depth) (return-from %parse-link-or-image nil))
    (let* ((label-end (1- i))
           (label (subseq text label-start label-end)))
      (setf (is-pos state) i)
      (unless (eql (%peek state) #\() (return-from %parse-link-or-image nil))
      (%advance state)
      (let ((dest-start (is-pos state))
            (dest-end nil)
            (title nil))
        (loop while (< (is-pos state) (length text))
              for c = (%peek state)
              do (cond
                   ((char= c #\)) (setf dest-end (is-pos state)) (%advance state) (return))
                   ((and (char= c #\Space) (null dest-end))
                    (setf dest-end (is-pos state))
                    (%advance state)
                    (let ((qc (%peek state)))
                      (when (member qc '(#\" #\' #\())
                        (let ((close (if (char= qc #\() #\) qc)))
                          (%advance state)
                          (let ((ts (is-pos state)))
                            (loop while (and (< (is-pos state) (length text))
                                             (not (eql (%peek state) close)))
                                  do (%advance state))
                            (when (eql (%peek state) close)
                              (setf title (subseq text ts (is-pos state)))
                              (%advance state)))))))
                   (t (%advance state))))
        (unless dest-end (return-from %parse-link-or-image nil))
        (let ((dest (%trim (subseq text dest-start dest-end)))
              (children (parse-inlines label (is-options state)
                                       :nodes (is-nodes state)
                                       :depth (1+ (is-depth state)))))
          (setf (is-nodes state) (+ (is-nodes state) (length children) 1))
          (%bump-node state)
          (if image-p
              (%node :image children :src dest :title title)
              (%node :link children :href dest :title title)))))))

(defun %parse-emphasis (state marker)
  "Parse emphasis/strong starting at MARKER (* or _). Returns node or nil.
Restores POS on failure so the caller can emit a literal marker."
  (let ((saved (is-pos state))
        (count 0))
    (loop while (eql (%peek state) marker) do (incf count) (%advance state))
    (when (or (zerop count) (> (is-depth state) +max-depth+))
      (setf (is-pos state) saved)
      (return-from %parse-emphasis nil))
    (let* ((open-n (min count 2))
           (start (is-pos state))
           (text (is-text state))
           (end (length text)))
      ;; If more than open-n markers, leave the extras as literal by rewinding
      ;; the surplus (e.g. ***foo*** opens as strong then emphasis).
      (when (> count open-n)
        (setf (is-pos state) (+ saved open-n)
              start (is-pos state)))
      (loop for i from start below end do
        (when (char= (char text i) marker)
          (let ((j i) (n 0))
            (loop while (and (< j end) (char= (char text j) marker))
                  do (incf n) (incf j))
            (when (>= n open-n)
              (let* ((inner (subseq text start i))
                     (children (if (zerop (length inner))
                                   '()
                                   (parse-inlines inner (is-options state)
                                                  :nodes (is-nodes state)
                                                  :depth (1+ (is-depth state))))))
                (setf (is-pos state) (+ i open-n)
                      (is-nodes state) (+ (is-nodes state) (length children) 1))
                (%bump-node state)
                (return-from %parse-emphasis
                  (if (>= open-n 2)
                      (if (and (mdo-underline (is-options state))
                               (char= marker #\_))
                          (%node :underline children)
                          (%node :strong children))
                      (%node :emphasis children))))))))
      (setf (is-pos state) saved)
      nil)))

(defun %parse-strikethrough (state)
  (let ((saved (is-pos state)))
    (unless (and (mdo-strikethrough (is-options state))
                 (%match-prefix state "~~"))
      (return-from %parse-strikethrough nil))
    (%advance state 2)
    (let ((start (is-pos state))
          (text (is-text state)))
      (loop for i from start below (- (length text) 1)
            when (and (char= (char text i) #\~)
                      (char= (char text (1+ i)) #\~))
              do (let* ((inner (subseq text start i))
                        (children (if (zerop (length inner))
                                      '()
                                      (parse-inlines
                                       inner (is-options state)
                                       :nodes (is-nodes state)
                                       :depth (1+ (is-depth state))))))
                   (setf (is-pos state) (+ i 2)
                         (is-nodes state) (+ (is-nodes state) (length children) 1))
                   (%bump-node state)
                   (return-from %parse-strikethrough
                     (%node :strikethrough children))))
      (setf (is-pos state) saved)
      nil)))

(defun %parse-autolink (state)
  (unless (eql (%peek state) #\<) (return-from %parse-autolink nil))
  (let* ((text (is-text state))
         (pos (is-pos state))
         (end (position #\> text :start (1+ pos))))
    (when end
      (let ((inner (subseq text (1+ pos) end)))
        (when (or (find #\@ inner) (search "://" inner))
          (setf (is-pos state) (1+ end))
          (%bump-node state)
          (return-from %parse-autolink
            (%node :link (list inner) :href inner :title nil))))))
  nil)

(defun parse-inlines (text options &key (nodes 0) (depth 0))
  (let* ((state (make-inline-state :text text :pos 0 :options options
                                   :nodes nodes :depth depth))
         (out '())
         (buf (make-array 64 :element-type 'character :adjustable t :fill-pointer 0)))
    (labels ((flush ()
               (when (plusp (fill-pointer buf))
                 (%bump-node state)
                 ;; COPY-SEQ: COERCE of a fill-pointer string array is EQ to the
                 ;; array itself on SBCL; clearing the fill-pointer would empty
                 ;; any stored text node that shared it.
                 (push (%node :text (list (copy-seq buf))) out)
                 (setf (fill-pointer buf) 0)))
             (emit (node)
               (flush)
               (push node out)))
      (loop while (< (is-pos state) (length text))
            for c = (%peek state)
            do (cond
                 ((char= c #\\)
                  (%advance state)
                  (let ((n (%peek state)))
                    (when n
                      (vector-push-extend n buf)
                      (%advance state))))
                 ((char= c #\`)
                  (let ((node (%parse-code-span state)))
                    (if node (emit node)
                        (progn (vector-push-extend c buf) (%advance state)))))
                 ((and (char= c #\!) (eql (%peek state 1) #\[))
                  (let ((node (%parse-link-or-image state t)))
                    (if node (emit node)
                        (progn (vector-push-extend c buf) (%advance state)))))
                 ((char= c #\[)
                  (let ((node (%parse-link-or-image state nil)))
                    (if node (emit node)
                        (progn (vector-push-extend c buf) (%advance state)))))
                 ((char= c #\<)
                  (let ((node (%parse-autolink state)))
                    (if node (emit node)
                        (progn (vector-push-extend c buf) (%advance state)))))
                 ((and (char= c #\~) (mdo-strikethrough options))
                  (let ((node (%parse-strikethrough state)))
                    (if node (emit node)
                        (progn (vector-push-extend c buf) (%advance state)))))
                 ((or (char= c #\*) (char= c #\_))
                  (let ((node (%parse-emphasis state c)))
                    (if node (emit node)
                        (progn (vector-push-extend c buf) (%advance state)))))
                 ((and (char= c #\Newline) (mdo-hard-soft-breaks options))
                  (emit (%node :hardbreak))
                  (%advance state))
                 (t
                  (vector-push-extend c buf)
                  (%advance state))))
      (flush)
      (nreverse out))))

;;; --- block parser ----------------------------------------------------------

(defstruct (block-state (:conc-name bs-))
  lines
  (index 0 :type fixnum)
  options
  (nodes 0 :type fixnum))

(defun %line (state)
  (when (< (bs-index state) (length (bs-lines state)))
    (aref (bs-lines state) (bs-index state))))

(defun %next-line (state)
  (incf (bs-index state)))

(defun %at-end-p (state)
  (>= (bs-index state) (length (bs-lines state))))

(defun %parse-atx-heading (state line)
  (let* ((indent (%indent-width line))
         (rest (%strip-indent line indent)))
    (when (> indent 3) (return-from %parse-atx-heading nil))
    (let ((level 0))
      (loop while (and (< level (length rest)) (char= (char rest level) #\#)
                       (< level 6))
            do (incf level))
      (when (zerop level) (return-from %parse-atx-heading nil))
      (when (>= level (length rest))
        (%next-line state)
        (return-from %parse-atx-heading (%node :heading '() :level level)))
      (let ((c (char rest level)))
        (unless (or (%ws-p c) (mdo-permissive-atx (bs-options state)))
          (return-from %parse-atx-heading nil))
        (let* ((content (%trim (subseq rest level)))
               ;; strip trailing #
               (content (let ((end (length content)))
                          (loop while (and (plusp end)
                                           (char= (char content (1- end)) #\#))
                                do (decf end))
                          (if (< end (length content))
                              (%trim (subseq content 0 end))
                              content)))
               (children (parse-inlines content (bs-options state)
                                        :nodes (bs-nodes state)))
               (id (when (mdo-headings-ids (bs-options state))
                     (%heading-id content))))
          (setf (bs-nodes state) (+ (bs-nodes state) (length children) 1))
          (%next-line state)
          (%node :heading children :level level :id id))))))

(defun %parse-fence (state line)
  (let* ((indent (%indent-width line))
         (rest (%strip-indent line indent)))
    (when (> indent 3) (return-from %parse-fence nil))
    (unless (and (plusp (length rest))
                 (or (char= (char rest 0) #\`) (char= (char rest 0) #\~)))
      (return-from %parse-fence nil))
    (let* ((marker (char rest 0))
           (count 0))
      (loop while (and (< count (length rest)) (char= (char rest count) marker))
            do (incf count))
      (when (< count 3) (return-from %parse-fence nil))
      (when (and (char= marker #\`) (find #\` rest :start count))
        (return-from %parse-fence nil))
      (let* ((info (%trim (subseq rest count)))
             (lang (let ((sp (position-if #'%ws-p info)))
                     (if sp (subseq info 0 sp) (if (zerop (length info)) nil info))))
             (body (make-array 64 :element-type 'character :adjustable t :fill-pointer 0)))
        (%next-line state)
        (loop until (%at-end-p state)
              for l = (%line state)
              for li = (%indent-width l)
              for lr = (%strip-indent l (min li indent))
              do (let ((close 0))
                   (loop while (and (< close (length lr))
                                    (char= (char lr close) marker))
                         do (incf close))
                   (if (and (>= close count)
                            (every #'%ws-p (subseq lr close)))
                       (progn (%next-line state) (return))
                       (progn
                         (when (plusp (fill-pointer body))
                           (vector-push-extend #\Newline body))
                         (let ((content (if (>= li indent)
                                            (%strip-indent l indent)
                                            l)))
                           (loop for c across content do (vector-push-extend c body)))
                         (%next-line state)))))
        (%node :code (list (coerce body 'string)) :language lang)))))

(defun %hr-p (line)
  (let* ((indent (%indent-width line))
         (rest (%ltrim line)))
    (when (> indent 3) (return-from %hr-p nil))
    (when (zerop (length rest)) (return-from %hr-p nil))
    (let ((marker (char rest 0)))
      (unless (member marker '(#\* #\- #\_)) (return-from %hr-p nil))
      (let ((count 0))
        (loop for c across rest
              do (cond
                   ((char= c marker) (incf count))
                   ((%ws-p c) nil)
                   (t (return-from %hr-p nil))))
        (>= count 3)))))

(defun %parse-blockquote (state line)
  (let* ((indent (%indent-width line))
         (rest (%strip-indent line indent)))
    (when (or (> indent 3) (zerop (length rest)) (char/= (char rest 0) #\>))
      (return-from %parse-blockquote nil))
    (let ((collected (make-array 8 :adjustable t :fill-pointer 0)))
      (loop until (%at-end-p state)
            for l = (%line state)
            for li = (%indent-width l)
            for lr = (%strip-indent l li)
            do (cond
                 ((and (<= li 3) (plusp (length lr)) (char= (char lr 0) #\>))
                  (let ((content (subseq lr 1)))
                    (when (and (plusp (length content)) (%ws-p (char content 0)))
                      (setf content (subseq content 1)))
                    (vector-push-extend content collected)
                    (%next-line state)))
                 ((%blank-line-p l) (return))
                 (t (return))))
      (let* ((inner-source (with-output-to-string (o)
                             (loop for i from 0 below (length collected)
                                   do (write-string (aref collected i) o)
                                      (when (< i (1- (length collected)))
                                        (write-char #\Newline o)))))
             (children (parse-document inner-source (bs-options state)
                                       (bs-nodes state))))
        (setf (bs-nodes state) (+ (bs-nodes state) 1))
        (%node :blockquote children)))))

(defun %list-marker (line)
  "Return (values indent marker-width ordered-p start bullet) or nil."
  (let* ((indent (%indent-width line))
         (rest (%strip-indent line indent)))
    (when (zerop (length rest)) (return-from %list-marker nil))
    (cond
      ((and (member (char rest 0) '(#\- #\+ #\*))
            (or (= (length rest) 1) (%ws-p (char rest 1))))
       (values indent 2 nil nil (char rest 0)))
      ((digit-char-p (char rest 0))
       (let ((i 0))
         (loop while (and (< i (length rest)) (digit-char-p (char rest i)))
               do (incf i))
         (when (and (< i (length rest))
                    (member (char rest i) '(#\. #\)))
                    (or (= (1+ i) (length rest))
                        (%ws-p (char rest (1+ i)))))
           (let ((start (parse-integer rest :end i)))
             (values indent (+ i 2) t start nil)))))
      (t nil))))

(defun %task-marker (content)
  (when (and (>= (length content) 3)
             (char= (char content 0) #\[)
             (member (char content 1) '(#\Space #\x #\X))
             (char= (char content 2) #\]))
    (values (char/= (char content 1) #\Space)
            (%trim (if (> (length content) 3)
                       (subseq content 3)
                       "")))))

(defun %parse-list (state line)
  (multiple-value-bind (indent marker-w ordered start bullet)
      (%list-marker line)
    (declare (ignore bullet marker-w))
    (unless indent (return-from %parse-list nil))
    (when (> indent 3) (return-from %parse-list nil))
    (let ((items '())
          (index 0)
          (opts (bs-options state)))
      (loop while (not (%at-end-p state)) do
        (let ((l (%line state)))
          (if (%blank-line-p l)
              (progn
                (%next-line state)
                (when (or (%at-end-p state)
                          (not (nth-value 0 (%list-marker (%line state)))))
                  (return)))
              (multiple-value-bind (i mw ord st bu) (%list-marker l)
                (declare (ignore st bu))
                (unless (and i (eq (not (null ord)) (not (null ordered)))
                             (= i indent))
                  (return))
                (let* ((after-indent (%strip-indent l indent))
                       (marker-end
                         (cond
                           ((and (plusp (length after-indent))
                                 (member (char after-indent 0) '(#\- #\+ #\*)))
                            1)
                           (t
                            (let ((k 0))
                              (loop while (and (< k (length after-indent))
                                               (digit-char-p
                                                (char after-indent k)))
                                    do (incf k))
                              (if (and (< k (length after-indent))
                                       (member (char after-indent k)
                                               '(#\. #\))))
                                  (1+ k)
                                  k)))))
                       (after-marker (subseq after-indent marker-end))
                       (rest (if (and (plusp (length after-marker))
                                      (%ws-p (char after-marker 0)))
                                 (subseq after-marker 1)
                                 after-marker))
                       (checked nil)
                       (content rest)
                       (item-lines (make-array 4 :adjustable t :fill-pointer 0)))
                  (declare (ignore mw))
                  (when (and (mdo-tasklists opts) (not ordered))
                    (multiple-value-bind (ck body) (%task-marker rest)
                      (when body
                        (setf checked ck content body))))
                  (vector-push-extend content item-lines)
                  (%next-line state)
                  (loop until (%at-end-p state)
                        for cl = (%line state)
                        do (cond
                             ((%blank-line-p cl)
                              (vector-push-extend "" item-lines)
                              (%next-line state))
                             ((nth-value 0 (%list-marker cl))
                              (return))
                             ((>= (%indent-width cl) (+ indent 2))
                              (vector-push-extend
                               (%strip-indent cl (+ indent 2)) item-lines)
                              (%next-line state))
                             (t (return))))
                  ;; Single-line items: parse inlines only (avoids re-entering
                  ;; the list recognizer on the same marker text).
                  (let* ((src (with-output-to-string (o)
                                (loop for j from 0 below (length item-lines)
                                      do (write-string (aref item-lines j) o)
                                         (when (< j (1- (length item-lines)))
                                           (write-char #\Newline o)))))
                         (children
                           (if (or (find #\Newline src)
                                   (and (plusp (length src))
                                        (or (char= (char src 0) #\#)
                                            (char= (char src 0) #\>))))
                               (let ((paras (parse-document src opts
                                                            (bs-nodes state))))
                                 (if (and (= (length paras) 1)
                                          (eq (mdn-kind (first paras))
                                              :paragraph))
                                     (mdn-children (first paras))
                                     paras))
                               (parse-inlines src opts
                                              :nodes (bs-nodes state)))))
                    (setf (bs-nodes state) (+ (bs-nodes state) 1))
                    (push (%node :list-item children
                                 :index index
                                 :depth 0
                                 :ordered ordered
                                 :start start
                                 :checked checked)
                          items)
                    (incf index)))))))
      (when items
        (%node :list (nreverse items)
               :ordered ordered
               :start start
               :depth 0)))))

(defun %table-row-cells (line)
  (let* ((s (%trim line))
         (s (if (and (plusp (length s)) (char= (char s 0) #\|))
                (subseq s 1) s))
         (s (if (and (plusp (length s)) (char= (char s (1- (length s))) #\|))
                (subseq s 0 (1- (length s))) s)))
    (mapcar #'%trim (split-sequence-char s #\|))))

(defun split-sequence-char (string char)
  (let ((parts '()) (start 0))
    (loop for i from 0 below (length string)
          when (char= (char string i) char)
            do (push (subseq string start i) parts)
               (setf start (1+ i)))
    (push (subseq string start) parts)
    (nreverse parts)))

(defun %table-divider-p (line)
  (let ((cells (%table-row-cells line)))
    (and (plusp (length cells))
         (every (lambda (c)
                  (and (plusp (length c))
                       (every (lambda (ch)
                                (or (char= ch #\-) (char= ch #\:) (%ws-p ch)))
                              c)
                       (find #\- c)))
                cells))))

(defun %align-from-cell (cell)
  (let* ((s (%trim cell))
         (left (and (plusp (length s)) (char= (char s 0) #\:)))
         (right (and (plusp (length s)) (char= (char s (1- (length s))) #\:))))
    (cond ((and left right) "center")
          (right "right")
          (left "left")
          (t nil))))

(defun %parse-table (state line)
  (unless (mdo-tables (bs-options state)) (return-from %parse-table nil))
  (when (%at-end-p state) (return-from %parse-table nil))
  (let ((next-index (1+ (bs-index state))))
    (when (>= next-index (length (bs-lines state)))
      (return-from %parse-table nil))
    (let ((divider (aref (bs-lines state) next-index)))
      (unless (and (find #\| line) (%table-divider-p divider))
        (return-from %parse-table nil))
      (let* ((headers (%table-row-cells line))
             (aligns (mapcar #'%align-from-cell (%table-row-cells divider)))
             (rows '()))
        (%next-line state)                      ; header
        (%next-line state)                      ; divider
        (loop until (%at-end-p state)
              for l = (%line state)
              while (and (not (%blank-line-p l)) (find #\| l))
              do (push (%table-row-cells l) rows)
                 (%next-line state))
        (setf rows (nreverse rows))
        (let ((thead-cells
                (loop for h in headers
                      for a in aligns
                      for children = (parse-inlines h (bs-options state)
                                                    :nodes (bs-nodes state))
                      do (setf (bs-nodes state)
                               (+ (bs-nodes state) (length children) 1))
                      collect (%node :th children :align a)))
              (body-rows
                (loop for row in rows
                      collect
                      (%node :tr
                             (loop for cell in row
                                   for a in aligns
                                   for children = (parse-inlines
                                                   (or cell "")
                                                   (bs-options state)
                                                   :nodes (bs-nodes state))
                                   do (setf (bs-nodes state)
                                            (+ (bs-nodes state)
                                               (length children) 1))
                                   collect (%node :td children :align a))))))
          (%node :table
                 (list (%node :thead (list (%node :tr thead-cells)))
                       (%node :tbody body-rows))))))))

(defun %parse-paragraph (state)
  (let ((parts (make-array 4 :adjustable t :fill-pointer 0)))
    (loop until (%at-end-p state)
          for l = (%line state)
          do (cond
               ((%blank-line-p l) (return))
               ((%parse-atx-heading state l) (decf (bs-index state)) (return))
               ((%hr-p l) (return))
               ((%parse-fence state l) (decf (bs-index state)) (return))
               ((and (<= (%indent-width l) 3)
                     (plusp (length (%ltrim l)))
                     (char= (char (%ltrim l) 0) #\>))
                (return))
               ((nth-value 0 (%list-marker l)) (return))
               (t
                (vector-push-extend (%ltrim l) parts)
                (%next-line state))))
    (when (zerop (length parts)) (return-from %parse-paragraph nil))
    (let* ((text (with-output-to-string (o)
                   (loop for i from 0 below (length parts)
                         do (write-string (aref parts i) o)
                            (when (< i (1- (length parts)))
                              (write-char #\Newline o)))))
           (children (parse-inlines text (bs-options state)
                                    :nodes (bs-nodes state))))
      (setf (bs-nodes state) (+ (bs-nodes state) (length children) 1))
      (%node :paragraph children))))

(defun parse-document (source &optional (options (default-options)) (nodes 0))
  (when (> (length source) +max-source-length+)
    (%fail :source-limit "Markdown source exceeds size limit"))
  (let* ((lines (%split-lines source))
         (state (make-block-state :lines lines :index 0 :options options :nodes nodes))
         (blocks '()))
    (loop until (%at-end-p state)
          for line = (%line state)
          do (cond
               ((%blank-line-p line) (%next-line state))
               (t
                (let ((n (or (%parse-atx-heading state line)
                             (and (%hr-p line)
                                  (progn (%next-line state) (%node :hr)))
                             (%parse-fence state line)
                             (%parse-table state line)
                             (%parse-blockquote state line)
                             (%parse-list state line)
                             (%parse-paragraph state))))
                  (when n (push n blocks))))))
    (nreverse blocks)))

;;; --- render HTML -----------------------------------------------------------

(defun %render-children-html (nodes options)
  (with-output-to-string (out)
    (dolist (n nodes)
      (write-string (render-node-html n options) out))))

(defun render-node-html (node options)
  (if (stringp node)
      (%escape-html node)
      (ecase (mdn-kind node)
        (:text (%escape-html (first (mdn-children node))))
        (:hardbreak (format nil "<br />~%"))
        (:softbreak (format nil "~%"))
        (:codespan
         (format nil "<code>~a</code>"
                 (%escape-html (first (mdn-children node)))))
        (:strong
         (format nil "<strong>~a</strong>"
                 (%render-children-html (mdn-children node) options)))
        (:emphasis
         (format nil "<em>~a</em>"
                 (%render-children-html (mdn-children node) options)))
        (:underline
         (format nil "<u>~a</u>"
                 (%render-children-html (mdn-children node) options)))
        (:strikethrough
         (format nil "<del>~a</del>"
                 (%render-children-html (mdn-children node) options)))
        (:link
         (let ((href (%escape-html (or (%meta node :href) "")))
               (title (%meta node :title))
               (body (%render-children-html (mdn-children node) options)))
           (if title
               (format nil "<a href=\"~a\" title=\"~a\">~a</a>"
                       href (%escape-html title) body)
               (format nil "<a href=\"~a\">~a</a>" href body))))
        (:image
         (let ((src (%escape-html (or (%meta node :src) "")))
               (title (%meta node :title))
               (alt (%render-children-html (mdn-children node) options)))
           (if title
               (format nil "<img src=\"~a\" alt=\"~a\" title=\"~a\" />"
                       src alt (%escape-html title))
               (format nil "<img src=\"~a\" alt=\"~a\" />" src alt))))
        (:heading
         (let* ((level (%meta node :level 1))
                (id (%meta node :id))
                (body (%render-children-html (mdn-children node) options))
                (inner (if (and id (mdo-headings-autolink options))
                           (format nil "<a href=\"#~a\">~a</a>" id body)
                           body)))
           (if id
               (format nil "<h~d id=\"~a\">~a</h~d>~%" level id inner level)
               (format nil "<h~d>~a</h~d>~%" level inner level))))
        (:paragraph
         (format nil "<p>~a</p>~%"
                 (%render-children-html (mdn-children node) options)))
        (:blockquote
         (format nil "<blockquote>~%~a</blockquote>~%"
                 (%render-children-html (mdn-children node) options)))
        (:code
         (let ((lang (%meta node :language))
               (code (%escape-html (first (mdn-children node)))))
           (if lang
               (format nil "<pre><code class=\"language-~a\">~a</code></pre>~%"
                       (%escape-html lang) code)
               (format nil "<pre><code>~a</code></pre>~%" code))))
        (:hr (format nil "<hr />~%"))
        (:list
         (let* ((ordered (%meta node :ordered))
                (start (%meta node :start))
                (tag (if ordered "ol" "ul"))
                (attrs (if (and ordered start (/= start 1))
                           (format nil " start=\"~d\"" start)
                           ""))
                (items (%render-children-html (mdn-children node) options)))
           (format nil "<~a~a>~%~a</~a>~%" tag attrs items tag)))
        (:list-item
         (let ((checked (%meta node :checked :absent)))
           (if (eq checked :absent)
               (format nil "<li>~a</li>~%"
                       (%render-children-html (mdn-children node) options))
               (format nil
                       "<li><input type=\"checkbox\" disabled~a /> ~a</li>~%"
                       (if checked " checked" "")
                       (%render-children-html (mdn-children node) options)))))
        (:table
         (format nil "<table>~%~a</table>~%"
                 (%render-children-html (mdn-children node) options)))
        (:thead
         (format nil "<thead>~%~a</thead>~%"
                 (%render-children-html (mdn-children node) options)))
        (:tbody
         (format nil "<tbody>~%~a</tbody>~%"
                 (%render-children-html (mdn-children node) options)))
        (:tr
         (format nil "<tr>~%~a</tr>~%"
                 (%render-children-html (mdn-children node) options)))
        (:th
         (let ((a (%meta node :align))
               (body (%render-children-html (mdn-children node) options)))
           (if a
               (format nil "<th align=\"~a\">~a</th>~%" a body)
               (format nil "<th>~a</th>~%" body))))
        (:td
         (let ((a (%meta node :align))
               (body (%render-children-html (mdn-children node) options)))
           (if a
               (format nil "<td align=\"~a\">~a</td>~%" a body)
               (format nil "<td>~a</td>~%" body))))
        (:html (first (mdn-children node)))
        (:document (%render-children-html (mdn-children node) options)))))

(defun markdown-to-html (source &optional (options (default-options)))
  (let ((blocks (parse-document source options)))
    (%render-children-html blocks options)))

;;; --- callback render -------------------------------------------------------

(defun %call-cb (callbacks name children meta)
  (let ((fn (getf callbacks name)))
    (if fn
        (let ((result (if meta
                          (funcall fn children meta)
                          (funcall fn children))))
          (if (or (null result) (eq result :undefined))
              ""
              (princ-to-string result)))
        children)))

(defun %render-children-cb (nodes callbacks options)
  (with-output-to-string (out)
    (dolist (n nodes)
      (write-string (render-node-cb n callbacks options) out))))

(defun render-node-cb (node callbacks options)
  (if (stringp node)
      (princ-to-string node)
      (let ((kids (mdn-children node)))
        (ecase (mdn-kind node)
          (:text
           (%call-cb callbacks :text (first kids) nil))
          (:hardbreak (%call-cb callbacks :text (format nil "~%") nil))
          (:codespan
           (%call-cb callbacks :codespan (first kids) nil))
          (:strong
           (%call-cb callbacks :strong
                     (%render-children-cb kids callbacks options) nil))
          (:emphasis
           (%call-cb callbacks :emphasis
                     (%render-children-cb kids callbacks options) nil))
          (:underline
           (%call-cb callbacks :underline
                     (%render-children-cb kids callbacks options) nil))
          (:strikethrough
           (%call-cb callbacks :strikethrough
                     (%render-children-cb kids callbacks options) nil))
          (:link
           (%call-cb callbacks :link
                     (%render-children-cb kids callbacks options)
                     (list :href (%meta node :href)
                           :title (%meta node :title))))
          (:image
           (%call-cb callbacks :image
                     (%render-children-cb kids callbacks options)
                     (list :src (%meta node :src)
                           :title (%meta node :title))))
          (:heading
           (%call-cb callbacks :heading
                     (%render-children-cb kids callbacks options)
                     (list :level (%meta node :level)
                           :id (%meta node :id))))
          (:paragraph
           (%call-cb callbacks :paragraph
                     (%render-children-cb kids callbacks options) nil))
          (:blockquote
           (%call-cb callbacks :blockquote
                     (%render-children-cb kids callbacks options) nil))
          (:code
           (%call-cb callbacks :code (first kids)
                     (list :language (%meta node :language))))
          (:hr (%call-cb callbacks :hr "" nil))
          (:list
           (%call-cb callbacks :list
                     (%render-children-cb kids callbacks options)
                     (list :ordered (%meta node :ordered)
                           :start (%meta node :start)
                           :depth (%meta node :depth 0))))
          (:list-item
           (%call-cb callbacks :list-item
                     (%render-children-cb kids callbacks options)
                     (list :index (%meta node :index)
                           :depth (%meta node :depth 0)
                           :ordered (%meta node :ordered)
                           :start (%meta node :start)
                           :checked (%meta node :checked))))
          (:table
           (%call-cb callbacks :table
                     (%render-children-cb kids callbacks options) nil))
          (:thead
           (%call-cb callbacks :thead
                     (%render-children-cb kids callbacks options) nil))
          (:tbody
           (%call-cb callbacks :tbody
                     (%render-children-cb kids callbacks options) nil))
          (:tr
           (%call-cb callbacks :tr
                     (%render-children-cb kids callbacks options) nil))
          (:th
           (%call-cb callbacks :th
                     (%render-children-cb kids callbacks options)
                     (list :align (%meta node :align))))
          (:td
           (%call-cb callbacks :td
                     (%render-children-cb kids callbacks options)
                     (list :align (%meta node :align))))
          (:html (%call-cb callbacks :html (first kids) nil))
          (:document (%render-children-cb kids callbacks options))))))

(defun markdown-render (source callbacks &optional (options (default-options)))
  (let ((blocks (parse-document source options)))
    (%render-children-cb blocks callbacks options)))
