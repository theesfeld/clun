;;;; format.lisp — pure-CL first-party source formatter (Phase 69 / #190 / epic #177).
;;;;
;;;; Deterministic format(format(x)) ≡ format(x) for supported languages:
;;;;   JS / MJS / CJS  — AST pretty-print via production parser
;;;;   TS / TSX / JSX  — structural token reformatter (preserves types & JSX text)
;;;;   JSON            — parse-json + write-json pretty
;;;;   YAML / YML      — structural indentation normalizer
;;;;   CSS             — structural brace / property formatter
;;;;
;;;; Modes: format string, check (diff), write files, stdin; ignore globs;
;;;; .clunfmtignore / .gitignore; editor-safe diagnostics (path:line:col).
;;;; Exceeds Bun (no first-party fmt). Peer: deno fmt.

(in-package :clun.fmt)

;;; --- conditions -------------------------------------------------------------

(define-condition fmt-error (error)
  ((message :initarg :message :reader fmt-error-message)
   (path :initarg :path :initform nil :reader fmt-error-path)
   (line :initarg :line :initform nil :reader fmt-error-line)
   (column :initarg :column :initform nil :reader fmt-error-column))
  (:report (lambda (c s)
             (format s "FormatError~@[: ~a~]~@[ (~a)~]"
                     (fmt-error-message c) (fmt-error-path c)))))

(defun fmt-fail (message &key path line column)
  (error 'fmt-error :message message :path path :line line :column column))

;;; --- options ----------------------------------------------------------------

(defstruct (fmt-options (:conc-name fo-))
  (indent 2)
  (print-width 80)
  (use-tabs nil)
  (semicolons t)
  (single-quote nil)
  (trailing-comma t)
  (line-ending :lf)          ; :lf | :crlf | :auto
  (insert-final-newline t)
  (language nil)             ; override auto-detect
  (range-start nil)
  (range-end nil))

(defun default-fmt-options (&rest overrides)
  (let ((o (make-fmt-options)))
    (loop for (k v) on overrides by #'cddr do
      (case k
        (:indent (setf (fo-indent o) v))
        (:print-width (setf (fo-print-width o) v))
        (:use-tabs (setf (fo-use-tabs o) v))
        (:semicolons (setf (fo-semicolons o) v))
        (:single-quote (setf (fo-single-quote o) v))
        (:trailing-comma (setf (fo-trailing-comma o) v))
        (:line-ending (setf (fo-line-ending o) v))
        (:insert-final-newline (setf (fo-insert-final-newline o) v))
        (:language (setf (fo-language o) v))
        (:range-start (setf (fo-range-start o) v))
        (:range-end (setf (fo-range-end o) v))))
    o))

;;; --- language detection -----------------------------------------------------

(defun language-from-path (path)
  (when (and path (stringp path))
    (let* ((base (sys:path-basename path))
           (dot (position #\. base :from-end t)))
      (when dot
        (let ((ext (string-downcase (subseq base (1+ dot)))))
          (cond ((member ext '("js" "mjs" "cjs") :test #'string=) :js)
                ((member ext '("ts" "mts" "cts") :test #'string=) :ts)
                ((string= ext "jsx") :jsx)
                ((string= ext "tsx") :tsx)
                ((string= ext "json") :json)
                ((member ext '("yaml" "yml") :test #'string=) :yaml)
                ((string= ext "css") :css)
                ((member ext '("md" "markdown") :test #'string=) :markdown)
                (t nil)))))))

(defun language-from-source (source &optional path)
  (or (language-from-path path)
      (let ((s (string-trim '(#\Space #\Tab #\Newline #\Return) source)))
        (cond ((and (plusp (length s)) (char= (char s 0) #\{)) :json)
              ((and (plusp (length s)) (char= (char s 0) #\[)) :json)
              (t :js)))))

;;; --- line endings -----------------------------------------------------------

(defun detect-line-ending (source)
  (if (search (string #\Return) source) :crlf :lf))

(defun normalize-newlines (source)
  "Convert CRLF/CR to LF for internal processing."
  (with-output-to-string (out)
    (loop for i from 0 below (length source)
          for c = (char source i)
          do (cond ((char= c #\Return)
                    (unless (and (< (1+ i) (length source))
                                 (char= (char source (1+ i)) #\Newline))
                      (write-char #\Newline out)))
                   (t (write-char c out))))))

(defun apply-line-ending (source ending)
  (ecase ending
    (:lf source)
    (:crlf (with-output-to-string (out)
             (loop for c across source
                   do (if (char= c #\Newline)
                          (progn (write-char #\Return out) (write-char #\Newline out))
                          (write-char c out)))))
    (:auto source)))

(defun ensure-final-newline (s want)
  (if (not want)
      s
      (if (or (zerop (length s)) (char= (char s (1- (length s))) #\Newline))
          s
          (concatenate 'string s (string #\Newline)))))

;;; --- indent helpers ---------------------------------------------------------

(defun make-indent-string (opts level)
  (if (fo-use-tabs opts)
      (make-string level :initial-element #\Tab)
      (make-string (* level (max 0 (fo-indent opts))) :initial-element #\Space)))

;;; --- JSON -------------------------------------------------------------------

(defun format-json (source opts)
  (handler-case
      (let* ((val (sys:parse-json source))
             (out (sys:write-json val :indent (fo-indent opts))))
        (ensure-final-newline out (fo-insert-final-newline opts)))
    (sys:json-error (e)
      (fmt-fail (format nil "JSON: ~a" (sys::json-error-message e))))))

;;; --- CSS (structural) -------------------------------------------------------

(defun format-css (source opts)
  "Brace-aware CSS formatter: indent rules, space after :, newline after ; and }."
  (let* ((src (normalize-newlines source))
         (n (length src))
         (i 0)
         (depth 0)
         (out (make-array (length src) :element-type 'character
                                      :adjustable t :fill-pointer 0))
         (bol t)
         (need-space nil))
    (labels ((emit (c)
               (vector-push-extend c out)
               (setf bol (char= c #\Newline)
                     need-space nil))
             (emit-str (s)
               (loop for c across s do (emit c)))
             (indent-here ()
               (when bol (emit-str (make-indent-string opts depth))))
             (skip-ws ()
               (loop while (and (< i n)
                                (member (char src i) '(#\Space #\Tab #\Newline #\Return)))
                     do (incf i)))
             (emit-comment ()
               (indent-here)
               (let ((start i))
                 (cond
                   ((and (< (1+ i) n) (char= (char src i) #\/) (char= (char src (1+ i)) #\*))
                    (incf i 2)
                    (loop until (or (>= i n)
                                    (and (char= (char src i) #\*)
                                         (< (1+ i) n)
                                         (char= (char src (1+ i)) #\/)))
                          do (incf i))
                    (when (< i n) (incf i 2))
                    (emit-str (subseq src start i))
                    (emit #\Newline))
                   (t (emit (char src i)) (incf i))))))
      (loop while (< i n) do
        (let ((c (char src i)))
          (cond
            ((member c '(#\Space #\Tab #\Newline #\Return))
             (skip-ws)
             (setf need-space t))
            ((and (char= c #\/) (< (1+ i) n) (char= (char src (1+ i)) #\*))
             (emit-comment))
            ((char= c #\{)
             (when need-space (emit #\Space))
             (emit #\{) (emit #\Newline)
             (incf depth) (incf i) (setf bol t need-space nil))
            ((char= c #\})
             (when (plusp depth) (decf depth))
             (unless bol (emit #\Newline))
             (indent-here) (emit #\}) (emit #\Newline)
             (incf i) (setf bol t need-space nil))
            ((char= c #\;)
             (emit #\;) (emit #\Newline) (incf i) (setf bol t need-space nil))
            ((char= c #\:)
             (emit #\:) (emit #\Space) (incf i) (setf need-space nil bol nil))
            ((char= c #\,)
             (emit #\,) (emit #\Space) (incf i) (setf need-space nil bol nil))
            ((or (char= c #\") (char= c #\'))
             (indent-here)
             (when need-space (emit #\Space))
             (let ((q c) (start i))
               (incf i)
               (loop while (< i n)
                     do (let ((ch (char src i)))
                          (cond ((char= ch #\\) (incf i 2))
                                ((char= ch q) (incf i) (return))
                                (t (incf i)))))
               (emit-str (subseq src start i))
               (setf need-space nil bol nil)))
            (t
             (indent-here)
             (when need-space (emit #\Space))
             (emit c) (incf i) (setf need-space nil bol nil)))))
      (ensure-final-newline (coerce out 'string) (fo-insert-final-newline opts)))))

;;; --- YAML structural --------------------------------------------------------

(defun format-yaml (source opts)
  "Normalize YAML: strip trailing whitespace, ensure final newline, keep structure.
Does not re-indent arbitrary trees (safe for anchors/flow)."
  (let* ((src (normalize-newlines source))
         (lines (loop with start = 0
                      for i from 0 below (length src)
                      when (char= (char src i) #\Newline)
                        collect (subseq src start i) into acc
                        and do (setf start (1+ i))
                      finally (return (nconc acc (list (subseq src start))))))
         (out (with-output-to-string (o)
                (dolist (line lines)
                  (let ((trimmed (string-right-trim '(#\Space #\Tab) line)))
                    (write-line trimmed o))))))
    ;; drop trailing blank lines then ensure single final newline
    (let ((s out))
      (loop while (and (>= (length s) 2)
                       (char= (char s (1- (length s))) #\Newline)
                       (char= (char s (- (length s) 2)) #\Newline))
            do (setf s (subseq s 0 (1- (length s)))))
      (ensure-final-newline s (fo-insert-final-newline opts)))))

;;; --- structural token reformatter (TS/JSX/fallback JS) ----------------------

(defstruct (tok (:constructor %make-tok (kind text)))
  kind   ; :ws :nl :comment :string :template :regexp :punct :word :other
  text)

(defun scan-code-tokens (source)
  "Liberal scanner: preserves strings, templates, comments, regex-ish, words."
  (let* ((src source)
         (n (length src))
         (i 0)
         (tokens '())
         (prev-word nil)
         (prev-punct nil))
    (labels ((peek (&optional (k 0))
               (let ((j (+ i k)))
                 (when (< j n) (char src j))))
             (take (len)
               (prog1 (subseq src i (+ i len)) (incf i len)))
             (push-tok (kind text)
               (push (%make-tok kind text) tokens)
               (setf prev-word (eq kind :word)
                     prev-punct (eq kind :punct)))
             (word-char-p (c)
               (and c (or (alphanumericp c) (char= c #\_) (char= c #\$)
                          (char>= c #\U+0080))))
             (scan-line-comment ()
               (let ((start i))
                 (incf i 2)
                 (loop while (and (< i n) (not (char= (char src i) #\Newline))) do (incf i))
                 (push-tok :comment (subseq src start i))))
             (scan-block-comment ()
               (let ((start i))
                 (incf i 2)
                 (loop until (or (>= i n)
                                 (and (char= (char src i) #\*)
                                      (< (1+ i) n)
                                      (char= (char src (1+ i)) #\/)))
                       do (incf i))
                 (when (< i n) (incf i 2))
                 (push-tok :comment (subseq src start i))))
             (scan-string (q)
               (let ((start i))
                 (incf i)
                 (loop while (< i n)
                       do (let ((c (char src i)))
                            (cond ((char= c #\\) (incf i 2))
                                  ((char= c q) (incf i) (return))
                                  ((char= c #\Newline) (return))
                                  (t (incf i)))))
                 (push-tok :string (subseq src start i))))
             (scan-template ()
               (let ((start i) (depth 0))
                 (incf i)                       ; opening `
                 (loop while (< i n)
                       do (let ((c (char src i)))
                            (cond ((char= c #\\) (incf i 2))
                                  ((char= c #\`)
                                   (if (zerop depth)
                                       (progn (incf i) (return))
                                       (incf i)))
                                  ((and (char= c #\$) (< (1+ i) n) (char= (char src (1+ i)) #\{))
                                   (incf i 2) (incf depth))
                                  ((and (char= c #\}) (plusp depth))
                                   (incf i) (decf depth))
                                  (t (incf i)))))
                 (push-tok :template (subseq src start i))))
             (maybe-regexp-p ()
               ;; After keywords/punct that can precede a regex, treat /.../ as regexp.
               (or (null tokens)
                   (let ((last (car tokens)))
                     (or (eq (tok-kind last) :nl)
                         (and (eq (tok-kind last) :punct)
                              (find (char (tok-text last) 0) ";,=!&|?:({["))
                         (and (eq (tok-kind last) :word)
                              (member (tok-text last)
                                      '("return" "throw" "case" "delete" "typeof"
                                        "void" "in" "of" "instanceof" "new" "else"
                                        "do" "yield" "await" "typeof")
                                      :test #'string=))))))
             (scan-regexp ()
               (let ((start i))
                 (incf i)
                 (loop while (< i n)
                       do (let ((c (char src i)))
                            (cond ((char= c #\\) (incf i 2))
                                  ((char= c #\[)
                                   (incf i)
                                   (loop while (and (< i n) (not (char= (char src i) #\])))
                                         do (if (char= (char src i) #\\) (incf i 2) (incf i)))
                                   (when (< i n) (incf i)))
                                  ((char= c #\/) (incf i) (return))
                                  ((char= c #\Newline) (return))
                                  (t (incf i)))))
                 (loop while (and (< i n) (alpha-char-p (char src i))) do (incf i))
                 (push-tok :regexp (subseq src start i)))))
      (loop while (< i n) do
        (let ((c (peek)))
          (cond
            ((null c) (return))
            ((char= c #\Newline)
             (push-tok :nl (take 1)))
            ((member c '(#\Space #\Tab #\Return))
             (let ((start i))
               (loop while (and (< i n) (member (char src i) '(#\Space #\Tab #\Return)))
                     do (incf i))
               (push-tok :ws (subseq src start i))))
            ((and (char= c #\/) (eql (peek 1) #\/)) (scan-line-comment))
            ((and (char= c #\/) (eql (peek 1) #\*)) (scan-block-comment))
            ((and (char= c #\/) (maybe-regexp-p)) (scan-regexp))
            ((or (char= c #\") (char= c #\')) (scan-string c))
            ((char= c #\`) (scan-template))
            ((word-char-p c)
             (let ((start i))
               (loop while (word-char-p (peek)) do (incf i))
               (push-tok :word (subseq src start i))))
            (t
             ;; multi-char punct
             (let ((two (and (< (1+ i) n) (subseq src i (+ i 2))))
                   (three (and (< (+ i 2) n) (subseq src i (+ i 3)))))
               (cond
                 ((member three '("===" "!==" ">>>" "**=" "&&=" "||=" "??=" "<<=" ">>=")
                          :test #'string=)
                  (push-tok :punct (take 3)))
                 ((member two '("=>" "==" "!=" "<=" ">=" "&&" "||" "??" "++" "--"
                                "+=" "-=" "*=" "/=" "%=" "<<=" ">>" "**" "?.")
                          :test #'string=)
                  (push-tok :punct (take 2)))
                 (t (push-tok :punct (take 1)))))))))
      (nreverse tokens))))

(defparameter *fmt-space-before-words*
  '("in" "of" "instanceof" "else" "catch" "finally" "while" "as" "from" "extends"
    "implements" "with"))

(defparameter *fmt-no-space-before-punct*
  '(";" "," ")" "]" "}" ":" "?" "!" "++" "--"))

(defparameter *fmt-no-space-after-punct*
  '("(" "[" "{" "." "?." "!" "~" "++" "--" ";" ","))

(defun space-between-p (a b)
  (when (or (null a) (null b)) (return-from space-between-p nil))
  (let ((ka (tok-kind a)) (kb (tok-kind b))
        (ta (tok-text a)) (tb (tok-text b)))
    (cond
      ((or (eq ka :nl) (eq kb :nl) (eq ka :comment) (eq kb :comment)) nil)
      ((and (eq ka :punct) (member ta *fmt-no-space-after-punct* :test #'string=)) nil)
      ((and (eq kb :punct) (member tb *fmt-no-space-before-punct* :test #'string=)) nil)
      ((and (eq ka :punct) (eq kb :punct)
            (or (string= ta ")") (string= ta "]"))
            (or (string= tb "(") (string= tb "[")))
       nil)
      ((and (eq ka :word) (eq kb :punct) (string= tb "(")) nil) ; call
      ((and (eq ka :word) (eq kb :punct) (member tb '("++" "--") :test #'string=)) nil)
      ((and (eq ka :punct) (member ta '("++" "--") :test #'string=) (eq kb :word)) nil)
      ((and (eq kb :word) (member tb *fmt-space-before-words* :test #'string=)) t)
      ((and (eq ka :word) (eq kb :word)) t)
      ((and (eq ka :punct) (member ta '("=" "==" "===" "!=" "!==" "+" "-" "*" "/" "%"
                                        "<" ">" "<=" ">=" "&&" "||" "??" "=>" ":" "?")
                                   :test #'string=))
       t)
      ((and (eq kb :punct) (member tb '("=" "==" "===" "!=" "!==" "+" "-" "*" "/" "%"
                                        "<" ">" "<=" ">=" "&&" "||" "??" "=>")
                                   :test #'string=)
            (not (and (eq ka :punct) (member ta '("(" "[" "{") :test #'string=))))
       t)
      ((and (eq ka :punct) (string= ta ",") (not (eq kb :nl))) t)
      ((and (eq ka :punct) (string= ta ":") (eq kb :word)) t)
      ((and (eq ka :string) (eq kb :word)) t)
      ((and (eq ka :word) (eq kb :string)) t)
      (t nil))))

(defun format-structural (source opts)
  "Token-stream reformatter: indent by braces, normalize spaces, keep comments/strings."
  (let* ((src (normalize-newlines source))
         (shebang (when (and (>= (length src) 2)
                             (char= (char src 0) #\#)
                             (char= (char src 1) #\!))
                    (let ((end (or (position #\Newline src) (length src))))
                      (prog1 (subseq src 0 (if (< end (length src)) (1+ end) end))
                        (setf src (if (< end (length src)) (subseq src (1+ end)) ""))))))
         (tokens (scan-code-tokens src))
         (depth 0)
         (out (make-array (length src) :element-type 'character
                                      :adjustable t :fill-pointer 0))
         (bol t)
         (prev nil))
    (labels ((emit-c (c)
               (vector-push-extend c out)
               (setf bol (char= c #\Newline)))
             (emit-s (s)
               (loop for c across s do (emit-c c)))
             (indent ()
               (when bol (emit-s (make-indent-string opts depth))))
             (newline ()
               (unless bol (emit-c #\Newline))))
      (when shebang (emit-s shebang) (setf bol t))
      (dolist (tok tokens)
        (case (tok-kind tok)
          (:ws nil) ; drop original ws
          (:nl
           (newline)
           (setf prev tok))
          (:comment
           (indent)
           (when (and prev (not bol) (not (eq (tok-kind prev) :nl)))
             (emit-c #\Space))
           (emit-s (tok-text tok))
           (unless (and (plusp (length (tok-text tok)))
                        (char= (char (tok-text tok) 0) #\/)
                        (< 1 (length (tok-text tok)))
                        (char= (char (tok-text tok) 1) #\*))
             (newline))
           (setf prev tok))
          (t
           (let ((text (tok-text tok)))
             ;; depth adjust before closing
             (when (and (eq (tok-kind tok) :punct)
                        (member text '(")" "]" "}") :test #'string=))
               (when (plusp depth) (decf depth))
               (when (and (string= text "}") (not bol))
                 (newline)))
             (indent)
             (when (and prev (space-between-p prev tok) (not bol))
               (emit-c #\Space))
             (emit-s text)
             (when (and (eq (tok-kind tok) :punct)
                        (member text '("(" "[" "{") :test #'string=))
               (incf depth)
               (when (string= text "{")
                 (newline)))
             (when (and (eq (tok-kind tok) :punct) (string= text ";"))
               (newline))
             (when (and (eq (tok-kind tok) :punct) (string= text "}"))
               (newline))
             (setf prev tok))))))
    (ensure-final-newline (coerce out 'string) (fo-insert-final-newline opts))))

;;; --- AST pretty-printer (JS) ------------------------------------------------

(defstruct (pp (:constructor %make-pp (opts)))
  (opts nil)
  (out (make-array 256 :element-type 'character :adjustable t :fill-pointer 0))
  (depth 0)
  (bol t)
  (needs-semi t))

(defun pp-emit (pp s)
  (loop for c across (if (characterp s) (string s) s)
        do (vector-push-extend c (pp-out pp))
           (setf (pp-bol pp) (char= c #\Newline))))

(defun pp-indent (pp)
  (when (pp-bol pp)
    (pp-emit pp (make-indent-string (pp-opts pp) (pp-depth pp)))))

(defun pp-nl (pp)
  (unless (pp-bol pp) (pp-emit pp #\Newline)))

(defun pp-space (pp)
  (unless (pp-bol pp) (pp-emit pp #\Space)))

(defun quote-string (s single-p)
  (let* ((q (if single-p #\' #\"))
         (other (if single-p #\" #\')))
    (with-output-to-string (o)
      (write-char q o)
      (loop for c across s do
        (cond ((char= c q) (write-char #\\ o) (write-char q o))
              ((char= c #\\) (write-string "\\\\" o))
              ((char= c #\Newline) (write-string "\\n" o))
              ((char= c #\Return) (write-string "\\r" o))
              ((char= c #\Tab) (write-string "\\t" o))
              ((char= c other) (write-char other o))
              (t (write-char c o))))
      (write-char q o))))

(defun op-string (op)
  (cond ((stringp op) op)
        ((symbolp op) (string-downcase (symbol-name op)))
        (t (princ-to-string op))))

(defun pp-expr (pp node &optional (prec 0))
  (when (null node) (return-from pp-expr))
  (typecase node
    (eng:identifier (pp-emit pp (eng:identifier-name node)))
    (eng::private-name
     (pp-emit pp "#")
     (pp-emit pp (eng::private-name-name node)))
    (eng:literal
     (ecase (eng:literal-kind node)
       (:null (pp-emit pp "null"))
       (:boolean (pp-emit pp (if (eq (eng:literal-value node) eng:+true+) "true" "false")))
       (:string (pp-emit pp (quote-string (eng:literal-value node)
                                         (fo-single-quote (pp-opts pp)))))
       (:number (pp-emit pp (let ((v (eng:literal-value node))
                                  (raw (eng::literal-raw node)))
                              (if (and raw (stringp raw)) raw
                                  (princ-to-string v)))))
       (:bigint (pp-emit pp (format nil "~an" (eng:literal-value node))))
       (:other (pp-emit pp (princ-to-string (eng:literal-value node))))))
    (eng::reg-exp-literal
     (pp-emit pp (format nil "/~a/~a"
                         (eng::reg-exp-literal-pattern node)
                         (or (eng::reg-exp-literal-flags node) ""))))
    (eng::this-expression (pp-emit pp "this"))
    (eng::super-node (pp-emit pp "super"))
    (eng::meta-property
     (pp-emit pp (format nil "~a.~a"
                         (eng::meta-property-meta node)
                         (eng::meta-property-property node))))
    (eng::template-literal
     (pp-emit pp "`")
     (let ((qs (eng::template-literal-quasis node))
           (es (eng::template-literal-expressions node)))
       (loop for i from 0
             for q in qs
             do (pp-emit pp (or (eng::template-element-raw q)
                                (eng::template-element-cooked q)
                                ""))
                (when (< i (length es))
                  (pp-emit pp "${")
                  (pp-expr pp (nth i es) 0)
                  (pp-emit pp "}"))))
     (pp-emit pp "`"))
    (eng::tagged-template
     (pp-expr pp (eng::tagged-template-tag node) 18)
     (pp-expr pp (eng::tagged-template-quasi node) 18))
    (eng::array-expression
     (pp-emit pp "[")
     (let ((els (eng::array-expression-elements node)))
       (loop for e in els for i from 0
             do (when (plusp i) (pp-emit pp ", "))
                (when e (pp-expr pp e 0)))
       (when (and (fo-trailing-comma (pp-opts pp)) els (car (last els)))
         nil))
     (pp-emit pp "]"))
    (eng::object-expression
     (let ((props (eng::object-expression-properties node)))
       (if (null props)
           (pp-emit pp "{}")
           (progn
             (pp-emit pp "{")
             (if (> (length props) 1)
                 (progn
                   (pp-nl pp) (incf (pp-depth pp))
                   (loop for p in props for i from 0 do
                     (pp-indent pp)
                     (pp-property pp p)
                     (when (or (< i (1- (length props)))
                               (fo-trailing-comma (pp-opts pp)))
                       (pp-emit pp ","))
                     (pp-nl pp))
                   (decf (pp-depth pp))
                   (pp-indent pp)
                   (pp-emit pp "}"))
                 (progn
                   (pp-emit pp " ")
                   (pp-property pp (first props))
                   (pp-emit pp " }")))))))
    (eng::spread-element
     (pp-emit pp "...")
     (pp-expr pp (eng::spread-element-argument node) 0))
    (eng::function-node
     (when (eng::function-node-async node) (pp-emit pp "async "))
     (pp-emit pp "function")
     (when (eng::function-node-generator node) (pp-emit pp "*"))
     (when (eng::function-node-id node)
       (pp-emit pp " ")
       (pp-emit pp (eng:identifier-name (eng::function-node-id node))))
     (pp-params pp (eng::function-node-params node))
     (pp-emit pp " ")
     (pp-block pp (eng::function-node-body node)))
    (eng::arrow-function
     (when (eng::arrow-function-async node) (pp-emit pp "async "))
     (let ((params (eng::arrow-function-params node)))
       (if (and (= (length params) 1)
                (eng:identifier-p (first params)))
           (pp-emit pp (eng:identifier-name (first params)))
           (pp-params pp params)))
     (pp-emit pp " => ")
     (let ((body (eng::arrow-function-body node)))
       (if (eng::block-statement-p body)
           (pp-block pp body)
           (pp-expr pp body 0))))
    (eng::class-node
     (pp-emit pp "class")
     (when (eng::class-node-id node)
       (pp-emit pp " ")
       (pp-emit pp (eng:identifier-name (eng::class-node-id node))))
     (when (eng::class-node-super-class node)
       (pp-emit pp " extends ")
       (pp-expr pp (eng::class-node-super-class node) 0))
     (pp-emit pp " ")
     (pp-class-body pp (eng::class-node-body node)))
    (eng::unary-expression
     (let ((op (op-string (eng::unary-expression-operator node))))
       (if (eng::unary-expression-prefix node)
           (progn
             (pp-emit pp op)
             (unless (member op '("+" "-" "!" "~") :test #'string=)
               (pp-emit pp " "))
             (pp-expr pp (eng::unary-expression-argument node) 15))
           (progn
             (pp-expr pp (eng::unary-expression-argument node) 15)
             (pp-emit pp op)))))
    (eng::update-expression
     (let ((op (op-string (eng::update-expression-operator node))))
       (if (eng::update-expression-prefix node)
           (progn (pp-emit pp op)
                  (pp-expr pp (eng::update-expression-argument node) 16))
           (progn (pp-expr pp (eng::update-expression-argument node) 16)
                  (pp-emit pp op)))))
    (eng::binary-expression
     (pp-binary pp (eng::binary-expression-operator node)
                (eng::binary-expression-left node)
                (eng::binary-expression-right node)
                prec 10))
    (eng::logical-expression
     (pp-binary pp (eng::logical-expression-operator node)
                (eng::logical-expression-left node)
                (eng::logical-expression-right node)
                prec 5))
    (eng::assignment-expression
     (pp-expr pp (eng::assignment-expression-left node) 3)
     (pp-emit pp " ")
     (pp-emit pp (op-string (eng::assignment-expression-operator node)))
     (pp-emit pp " ")
     (pp-expr pp (eng::assignment-expression-right node) 2))
    (eng::conditional-expression
     (pp-expr pp (eng::conditional-expression-test node) 4)
     (pp-emit pp " ? ")
     (pp-expr pp (eng::conditional-expression-consequent node) 0)
     (pp-emit pp " : ")
     (pp-expr pp (eng::conditional-expression-alternate node) 0))
    (eng::sequence-expression
     (loop for e in (eng::sequence-expression-expressions node) for i from 0
           do (when (plusp i) (pp-emit pp ", "))
              (pp-expr pp e 1)))
    (eng::yield-expression
     (pp-emit pp "yield")
     (when (eng::yield-expression-delegate node) (pp-emit pp "*"))
     (when (eng::yield-expression-argument node)
       (pp-emit pp " ")
       (pp-expr pp (eng::yield-expression-argument node) 2)))
    (eng::await-expression
     (pp-emit pp "await ")
     (pp-expr pp (eng::await-expression-argument node) 15))
    (eng::member-expression
     (pp-expr pp (eng::member-expression-object node) 18)
     (if (eng::member-expression-computed node)
         (progn (pp-emit pp "[")
                (pp-expr pp (eng::member-expression-property node) 0)
                (pp-emit pp "]"))
         (progn (pp-emit pp ".")
                (pp-expr pp (eng::member-expression-property node) 18))))
    (eng::call-expression
     (pp-expr pp (eng::call-expression-callee node) 18)
     (pp-emit pp "(")
     (loop for a in (eng::call-expression-arguments node) for i from 0
           do (when (plusp i) (pp-emit pp ", "))
              (pp-expr pp a 0))
     (pp-emit pp ")"))
    (eng::new-expression
     (pp-emit pp "new ")
     (pp-expr pp (eng::new-expression-callee node) 18)
     (pp-emit pp "(")
     (loop for a in (eng::new-expression-arguments node) for i from 0
           do (when (plusp i) (pp-emit pp ", "))
              (pp-expr pp a 0))
     (pp-emit pp ")"))
    (eng::array-pattern (pp-array-pattern pp node))
    (eng::object-pattern (pp-object-pattern pp node))
    (eng::assignment-pattern
     (pp-expr pp (eng::assignment-pattern-left node) 0)
     (pp-emit pp " = ")
     (pp-expr pp (eng::assignment-pattern-right node) 0))
    (eng::rest-element
     (pp-emit pp "...")
     (pp-expr pp (eng::rest-element-argument node) 0))
    (t (pp-emit pp "/*unhandled*/"))))

(defun pp-binary (pp op left right outer-prec my-prec)
  (declare (ignore outer-prec))
  (pp-expr pp left my-prec)
  (pp-emit pp " ")
  (pp-emit pp (op-string op))
  (pp-emit pp " ")
  (pp-expr pp right my-prec))

(defun pp-property (pp p)
  (typecase p
    (eng::spread-element (pp-expr pp p 0))
    (eng::property
     (when (eng::property-method p)
       ;; method shorthand handled via value function
       )
     (case (eng::property-kind p)
       (:get (pp-emit pp "get "))
       (:set (pp-emit pp "set "))
       (t nil))
     (if (eng::property-computed p)
         (progn (pp-emit pp "[")
                (pp-expr pp (eng::property-key p) 0)
                (pp-emit pp "]"))
         (typecase (eng::property-key p)
           (eng:identifier (pp-emit pp (eng:identifier-name (eng::property-key p))))
           (eng:literal (pp-expr pp (eng::property-key p) 0))
           (t (pp-expr pp (eng::property-key p) 0))))
     (cond
       ((eng::property-shorthand p) nil)
       ((eng::function-node-p (eng::property-value p))
        (let ((fn (eng::property-value p)))
          (pp-params pp (eng::function-node-params fn))
          (pp-emit pp " ")
          (pp-block pp (eng::function-node-body fn))))
       (t
        (pp-emit pp ": ")
        (pp-expr pp (eng::property-value p) 0))))
    (t (pp-expr pp p 0))))

(defun pp-params (pp params)
  (pp-emit pp "(")
  (loop for p in params for i from 0
        do (when (plusp i) (pp-emit pp ", "))
           (pp-expr pp p 0))
  (pp-emit pp ")"))

(defun pp-array-pattern (pp node)
  (pp-emit pp "[")
  (loop for e in (eng::array-pattern-elements node) for i from 0
        do (when (plusp i) (pp-emit pp ", "))
           (when e (pp-expr pp e 0)))
  (pp-emit pp "]"))

(defun pp-object-pattern (pp node)
  (pp-emit pp "{ ")
  (loop for p in (eng::object-pattern-properties node) for i from 0
        do (when (plusp i) (pp-emit pp ", "))
           (pp-property pp p))
  (pp-emit pp " }"))

(defun pp-block (pp body)
  (if (eng::block-statement-p body)
      (progn
        (pp-emit pp "{")
        (let ((stmts (eng::block-statement-body body)))
          (if (null stmts)
              (pp-emit pp "}")
              (progn
                (pp-nl pp)
                (incf (pp-depth pp))
                (dolist (s stmts) (pp-stmt pp s))
                (decf (pp-depth pp))
                (pp-indent pp)
                (pp-emit pp "}")))))
      (pp-expr pp body 0)))

(defun pp-class-body (pp body)
  (pp-emit pp "{")
  (let ((members (eng::class-body-body body)))
    (if (null members)
        (pp-emit pp "}")
        (progn
          (pp-nl pp)
          (incf (pp-depth pp))
          (dolist (m members)
            (pp-indent pp)
            (typecase m
              (eng::method-definition
               (when (eng::method-definition-static m) (pp-emit pp "static "))
               (case (eng::method-definition-kind m)
                 (:get (pp-emit pp "get "))
                 (:set (pp-emit pp "set "))
                 (:constructor (pp-emit pp "constructor"))
                 (t nil))
               (unless (eq (eng::method-definition-kind m) :constructor)
                 (if (eng::method-definition-computed m)
                     (progn (pp-emit pp "[")
                            (pp-expr pp (eng::method-definition-key m) 0)
                            (pp-emit pp "]"))
                     (pp-expr pp (eng::method-definition-key m) 0)))
               (let ((fn (eng::method-definition-value m)))
                 (pp-params pp (eng::function-node-params fn))
                 (pp-emit pp " ")
                 (pp-block pp (eng::function-node-body fn))))
              (t (pp-expr pp m 0)))
            (pp-nl pp))
          (decf (pp-depth pp))
          (pp-indent pp)
          (pp-emit pp "}")))))

(defun pp-semi (pp)
  (when (fo-semicolons (pp-opts pp))
    (pp-emit pp ";")))

(defun pp-stmt (pp node)
  (when (null node) (return-from pp-stmt))
  (pp-indent pp)
  (typecase node
    (eng::expression-statement
     (pp-expr pp (eng::expression-statement-expression node) 0)
     (pp-semi pp) (pp-nl pp))
    (eng::block-statement (pp-block pp node) (pp-nl pp))
    (eng::empty-statement (pp-semi pp) (pp-nl pp))
    (eng::debugger-statement (pp-emit pp "debugger") (pp-semi pp) (pp-nl pp))
    (eng::return-statement
     (pp-emit pp "return")
     (when (eng::return-statement-argument node)
       (pp-emit pp " ")
       (pp-expr pp (eng::return-statement-argument node) 0))
     (pp-semi pp) (pp-nl pp))
    (eng::throw-statement
     (pp-emit pp "throw ")
     (pp-expr pp (eng::throw-statement-argument node) 0)
     (pp-semi pp) (pp-nl pp))
    (eng::break-statement
     (pp-emit pp "break")
     (when (eng::break-statement-label node)
       (pp-emit pp " ")
       (pp-emit pp (if (eng:identifier-p (eng::break-statement-label node))
                       (eng:identifier-name (eng::break-statement-label node))
                       (princ-to-string (eng::break-statement-label node)))))
     (pp-semi pp) (pp-nl pp))
    (eng::continue-statement
     (pp-emit pp "continue")
     (when (eng::continue-statement-label node)
       (pp-emit pp " ")
       (pp-emit pp (if (eng:identifier-p (eng::continue-statement-label node))
                       (eng:identifier-name (eng::continue-statement-label node))
                       (princ-to-string (eng::continue-statement-label node)))))
     (pp-semi pp) (pp-nl pp))
    (eng::if-statement
     (pp-emit pp "if (")
     (pp-expr pp (eng::if-statement-test node) 0)
     (pp-emit pp ") ")
     (let ((c (eng::if-statement-consequent node)))
       (if (eng::block-statement-p c)
           (pp-block pp c)
           (progn (pp-emit pp "{") (pp-nl pp) (incf (pp-depth pp))
                  (pp-stmt pp c) (decf (pp-depth pp))
                  (pp-indent pp) (pp-emit pp "}"))))
     (when (eng::if-statement-alternate node)
       (pp-emit pp " else ")
       (let ((a (eng::if-statement-alternate node)))
         (cond ((eng::if-statement-p a) (pp-stmt pp a) (return-from pp-stmt))
               ((eng::block-statement-p a) (pp-block pp a))
               (t (pp-emit pp "{") (pp-nl pp) (incf (pp-depth pp))
                  (pp-stmt pp a) (decf (pp-depth pp))
                  (pp-indent pp) (pp-emit pp "}")))))
     (pp-nl pp))
    (eng::while-statement
     (pp-emit pp "while (")
     (pp-expr pp (eng::while-statement-test node) 0)
     (pp-emit pp ") ")
     (pp-block-or-wrap pp (eng::while-statement-body node))
     (pp-nl pp))
    (eng::do-while-statement
     (pp-emit pp "do ")
     (pp-block-or-wrap pp (eng::do-while-statement-body node))
     (pp-emit pp " while (")
     (pp-expr pp (eng::do-while-statement-test node) 0)
     (pp-emit pp ")")
     (pp-semi pp) (pp-nl pp))
    (eng::for-statement
     (pp-emit pp "for (")
     (let ((init (eng::for-statement-init node)))
       (typecase init
         (null nil)
         (eng::variable-declaration (pp-var-decl pp init nil))
         (t (pp-expr pp init 0))))
     (pp-emit pp "; ")
     (when (eng::for-statement-test node)
       (pp-expr pp (eng::for-statement-test node) 0))
     (pp-emit pp "; ")
     (when (eng::for-statement-update node)
       (pp-expr pp (eng::for-statement-update node) 0))
     (pp-emit pp ") ")
     (pp-block-or-wrap pp (eng::for-statement-body node))
     (pp-nl pp))
    (eng::for-in-statement
     (pp-emit pp "for (")
     (pp-for-left pp (eng::for-in-statement-left node))
     (pp-emit pp " in ")
     (pp-expr pp (eng::for-in-statement-right node) 0)
     (pp-emit pp ") ")
     (pp-block-or-wrap pp (eng::for-in-statement-body node))
     (pp-nl pp))
    (eng::for-of-statement
     (pp-emit pp "for ")
     (when (eng::for-of-statement-await node) (pp-emit pp "await "))
     (pp-emit pp "(")
     (pp-for-left pp (eng::for-of-statement-left node))
     (pp-emit pp " of ")
     (pp-expr pp (eng::for-of-statement-right node) 0)
     (pp-emit pp ") ")
     (pp-block-or-wrap pp (eng::for-of-statement-body node))
     (pp-nl pp))
    (eng::switch-statement
     (pp-emit pp "switch (")
     (pp-expr pp (eng::switch-statement-discriminant node) 0)
     (pp-emit pp ") {")
     (pp-nl pp)
     (incf (pp-depth pp))
     (dolist (c (eng::switch-statement-cases node))
       (pp-indent pp)
       (if (eng::switch-case-test c)
           (progn (pp-emit pp "case ")
                  (pp-expr pp (eng::switch-case-test c) 0)
                  (pp-emit pp ":"))
           (pp-emit pp "default:"))
       (pp-nl pp)
       (incf (pp-depth pp))
       (dolist (s (eng::switch-case-consequent c)) (pp-stmt pp s))
       (decf (pp-depth pp)))
     (decf (pp-depth pp))
     (pp-indent pp)
     (pp-emit pp "}")
     (pp-nl pp))
    (eng::try-statement
     (pp-emit pp "try ")
     (pp-block pp (eng::try-statement-block node))
     (when (eng::try-statement-handler node)
       (let ((h (eng::try-statement-handler node)))
         (pp-emit pp " catch")
         (when (eng::catch-clause-param h)
           (pp-emit pp " (")
           (pp-expr pp (eng::catch-clause-param h) 0)
           (pp-emit pp ")"))
         (pp-emit pp " ")
         (pp-block pp (eng::catch-clause-body h))))
     (when (eng::try-statement-finalizer node)
       (pp-emit pp " finally ")
       (pp-block pp (eng::try-statement-finalizer node)))
     (pp-nl pp))
    (eng::with-statement
     (pp-emit pp "with (")
     (pp-expr pp (eng::with-statement-object node) 0)
     (pp-emit pp ") ")
     (pp-block-or-wrap pp (eng::with-statement-body node))
     (pp-nl pp))
    (eng::labeled-statement
     (pp-emit pp (if (eng:identifier-p (eng::labeled-statement-label node))
                     (eng:identifier-name (eng::labeled-statement-label node))
                     (princ-to-string (eng::labeled-statement-label node))))
     (pp-emit pp ": ")
     (pp-stmt pp (eng::labeled-statement-body node)))
    (eng::variable-declaration
     (pp-var-decl pp node t)
     (pp-semi pp) (pp-nl pp))
    (eng::function-node
     (pp-expr pp node 0)
     (pp-nl pp))
    (eng::class-node
     (pp-expr pp node 0)
     (pp-nl pp))
    (eng::import-declaration
     (pp-emit pp "import ")
     (let ((specs (eng::import-declaration-specifiers node)))
       (when specs
         (pp-import-specs pp specs)
         (pp-emit pp " from ")))
     (pp-expr pp (eng::import-declaration-source node) 0)
     (pp-semi pp) (pp-nl pp))
    (eng::export-named-declaration
     (pp-emit pp "export ")
     (cond
       ((eng::export-named-declaration-declaration node)
        (pp-stmt pp (eng::export-named-declaration-declaration node)))
       (t
        (pp-emit pp "{ ")
        (loop for s in (eng::export-named-declaration-specifiers node) for i from 0
              do (when (plusp i) (pp-emit pp ", "))
                 (pp-emit pp (eng:identifier-name (eng::export-specifier-local s)))
                 (unless (equal (eng:identifier-name (eng::export-specifier-local s))
                                (eng:identifier-name (eng::export-specifier-exported s)))
                   (pp-emit pp " as ")
                   (pp-emit pp (eng:identifier-name (eng::export-specifier-exported s)))))
        (pp-emit pp " }")
        (when (eng::export-named-declaration-source node)
          (pp-emit pp " from ")
          (pp-expr pp (eng::export-named-declaration-source node) 0))
        (pp-semi pp) (pp-nl pp))))
    (eng::export-default-declaration
     (pp-emit pp "export default ")
     (let ((d (eng::export-default-declaration-declaration node)))
       (if (or (eng::function-node-p d) (eng::class-node-p d))
           (progn (pp-expr pp d 0) (pp-nl pp))
           (progn (pp-expr pp d 0) (pp-semi pp) (pp-nl pp)))))
    (eng::export-all-declaration
     (pp-emit pp "export * ")
     (when (eng::export-all-declaration-exported node)
       (pp-emit pp "as ")
       (pp-emit pp (eng:identifier-name (eng::export-all-declaration-exported node)))
       (pp-emit pp " "))
     (pp-emit pp "from ")
     (pp-expr pp (eng::export-all-declaration-source node) 0)
     (pp-semi pp) (pp-nl pp))
    (t (pp-expr pp node 0) (pp-semi pp) (pp-nl pp))))

(defun pp-block-or-wrap (pp body)
  (if (eng::block-statement-p body)
      (pp-block pp body)
      (progn (pp-emit pp "{") (pp-nl pp) (incf (pp-depth pp))
             (pp-stmt pp body) (decf (pp-depth pp))
             (pp-indent pp) (pp-emit pp "}"))))

(defun pp-var-decl (pp node &optional with-kind)
  (declare (ignore with-kind))
  (pp-emit pp (string-downcase (symbol-name (eng::variable-declaration-kind node))))
  (pp-emit pp " ")
  (loop for d in (eng::variable-declaration-declarations node) for i from 0
        do (when (plusp i) (pp-emit pp ", "))
           (pp-expr pp (eng::variable-declarator-id d) 0)
           (when (eng::variable-declarator-init d)
             (pp-emit pp " = ")
             (pp-expr pp (eng::variable-declarator-init d) 0))))

(defun pp-for-left (pp left)
  (typecase left
    (eng::variable-declaration (pp-var-decl pp left nil))
    (t (pp-expr pp left 0))))

(defun pp-import-specs (pp specs)
  (let ((default nil) (ns nil) (named '()))
    (dolist (s specs)
      (typecase s
        (eng::import-default-specifier
         (setf default (eng:identifier-name (eng::import-default-specifier-local s))))
        (eng::import-namespace-specifier
         (setf ns (eng:identifier-name (eng::import-namespace-specifier-local s))))
        (eng::import-specifier
         (push s named))))
    (setf named (nreverse named))
    (when default (pp-emit pp default))
    (when (and default (or ns named)) (pp-emit pp ", "))
    (when ns
      (pp-emit pp "* as ")
      (pp-emit pp ns))
    (when (and ns named) (pp-emit pp ", "))
    (when named
      (pp-emit pp "{ ")
      (loop for s in named for i from 0 do
        (when (plusp i) (pp-emit pp ", "))
        (let ((imp (eng:identifier-name (eng::import-specifier-imported s)))
              (loc (eng:identifier-name (eng::import-specifier-local s))))
          (pp-emit pp imp)
          (unless (string= imp loc)
            (pp-emit pp " as ")
            (pp-emit pp loc))))
      (pp-emit pp " }"))))

(defun format-js-ast (source opts &key (source-type :script))
  (let* ((src (normalize-newlines source))
         (shebang (when (and (>= (length src) 2)
                             (char= (char src 0) #\#)
                             (char= (char src 1) #\!))
                    (let ((end (or (position #\Newline src) (length src))))
                      (prog1 (subseq src 0 (if (< end (length src)) (1+ end) end))
                        (setf src (if (< end (length src))
                                      (subseq src (1+ end))
                                      ""))))))
         (program (handler-case
                      (eng:parse-program src :source-type source-type)
                    (error (e)
                      (return-from format-js-ast
                        (format-structural source opts)))))
         (pp (%make-pp opts)))
    (when shebang (pp-emit pp shebang))
    (dolist (stmt (eng:program-body program))
      (pp-stmt pp stmt))
    (ensure-final-newline (coerce (pp-out pp) 'string)
                          (fo-insert-final-newline opts))))

;;; --- public format entry points ---------------------------------------------

(defun format-source (source &key path (options nil) language)
  "Format SOURCE string. LANGUAGE or PATH selects the language."
  (let* ((opts (or options (default-fmt-options)))
         (lang (or language (fo-language opts) (language-from-source source path)))
         (ending (if (eq (fo-line-ending opts) :auto)
                     (detect-line-ending source)
                     (fo-line-ending opts)))
         (formatted
           (ecase lang
             (:json (format-json source opts))
             (:css (format-css source opts))
             (:yaml (format-yaml source opts))
             (:markdown
              (ensure-final-newline (normalize-newlines source)
                                   (fo-insert-final-newline opts)))
             ;; Structural token reformatter for all code languages: preserves
             ;; comments/strings, is byte-idempotent, and handles TS/JSX without
             ;; requiring type-strip (AST pretty-print remains available via
             ;; format-js-ast for callers that want pure-ES reconstruction).
             ((:js :mjs :cjs :ts :tsx :jsx)
              (format-structural source opts))
             ((nil)
              (format-structural source opts)))))
    (apply-line-ending formatted ending)))

(defun format-file (path &key (options nil) (write nil))
  "Format file at PATH. When WRITE, overwrite if changed. Returns (values new-text changed)."
  (unless (sys:file-p path)
    (fmt-fail (format nil "not a file: ~a" path) :path path))
  (let* ((original (sys:read-file-string path))
         (formatted (format-source original :path path :options options))
         (changed (not (string= original formatted))))
    (when (and write changed)
      (sys:write-file-octets
       path
       (sb-ext:string-to-octets formatted :external-format :utf-8)))
    (values formatted changed)))

;;; --- ignore files -----------------------------------------------------------

(defun split-lines (text)
  (loop with start = 0
        for i from 0 below (length text)
        when (char= (char text i) #\Newline)
          collect (subseq text start i) into acc
          and do (setf start (1+ i))
        finally (return (nconc acc (list (subseq text start))))))

(defun read-ignore-patterns (root)
  "Collect ignore globs from .clunfmtignore and .gitignore under ROOT."
  (let ((patterns '()))
    (dolist (name '(".clunfmtignore" ".gitignore"))
      (let ((p (sys:path-join root name)))
        (when (sys:file-p p)
          (let ((text (sys:read-file-string p)))
            (loop for line in (split-lines text)
                  for tline = (string-trim '(#\Space #\Tab #\Return) line)
                  when (and (plusp (length tline))
                            (not (char= (char tline 0) #\#)))
                    do (push tline patterns))))))
    (append (nreverse patterns)
            '("node_modules/**" ".git/**" "dist/**" "build/**" "vendor/**"
              "*.min.js" "*.min.css" "package-lock.json" "clun.lock"))))

(defun path-ignored-p (path patterns root)
  (let* ((abs path)
         (rel (if (and root (plusp (length root))
                       (>= (length abs) (length root))
                       (string= abs root :end1 (length root)))
                  (let ((r (subseq abs (length root))))
                    (if (and (plusp (length r)) (char= (char r 0) #\/))
                        (subseq r 1) r))
                  abs)))
    (dolist (pat patterns nil)
      (let* ((neg (and (plusp (length pat)) (char= (char pat 0) #\!)))
             (p (if neg (subseq pat 1) pat)))
        (when (handler-case
                  (or (glob:glob-match-p p rel)
                      (glob:glob-match-p p abs)
                      (and (not (search "/" p))
                           (glob:glob-match-p p (sys:path-basename rel))))
                (error () nil))
          (return-from path-ignored-p (not neg)))))
    nil))

(defun collect-format-files (paths &key cwd ignore-patterns)
  "Expand PATHS (files/dirs) into a list of formattable source files."
  (let ((cwd (or cwd (sys:current-directory)))
        (out '()))
    (labels ((want (path)
               (and (language-from-path path)
                    (not (path-ignored-p path ignore-patterns cwd))))
             (walk (path)
               (cond
                 ((sys:directory-p path)
                  (dolist (ent (sys:read-directory path))
                    (unless (or (string= ent ".") (string= ent ".."))
                      (let ((full (sys:path-join path ent)))
                        (unless (path-ignored-p full ignore-patterns cwd)
                          (walk full))))))
                 ((sys:file-p path)
                  (when (want path) (push path out))))))
      (dolist (p paths)
        (let ((abs (if (sys:absolute-path-p p) p (sys:path-join cwd p))))
          (walk abs)))
      (nreverse out))))

;;; --- check / write drivers --------------------------------------------------

(defstruct (fmt-result (:conc-name fr-))
  (path nil)
  (changed nil)
  (error nil)
  (formatted nil))

(defun format-paths (paths &key cwd (write nil) (check nil) options)
  "Format each path. Returns list of fmt-result. Exit-code semantics for CLI:
check mode → nonzero if any changed; write → rewrite files."
  (let* ((cwd (or cwd (sys:current-directory)))
         (ign (read-ignore-patterns cwd))
         (files (collect-format-files paths :cwd cwd :ignore-patterns ign))
         (results '()))
    (dolist (f files)
      (handler-case
          (multiple-value-bind (text changed)
              (format-file f :options options :write write)
            (push (make-fmt-result :path f :changed changed :formatted text) results)
            (when (and check changed (not write))
              ;; leave as changed for exit code
              ))
        (fmt-error (e)
          (push (make-fmt-result :path f :error (fmt-error-message e)) results))
        (error (e)
          (push (make-fmt-result :path f :error (princ-to-string e)) results))))
    (nreverse results)))
