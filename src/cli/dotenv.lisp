;;;; dotenv.lisp — pure-CL .env autoloader (PLAN.md §3.6, Phase 08). Parses
;;;; <cwd>/.env into the process.env object. OS-set vars WIN over .env (no override
;;;; — documented divergence). Supports KEY=VALUE, `export ` prefix, `#` comments,
;;;; single/double quotes (double expands \n\t\r\\, may span lines), unquoted trimmed.

(in-package :clun.cli)

(defstruct (dp (:constructor %make-dp (src)) (:conc-name dp-))
  (src "" :type simple-string) (i 0 :type fixnum))

(declaim (inline dp-peek dp-eof))
(defun dp-peek (p) (if (< (dp-i p) (length (dp-src p))) (char (dp-src p) (dp-i p)) nil))
(defun dp-eof (p) (>= (dp-i p) (length (dp-src p))))
(defun dp-inline-ws (p)
  (loop while (member (dp-peek p) '(#\Space #\Tab)) do (incf (dp-i p))))
(defun dp-to-eol (p)
  (loop until (or (dp-eof p) (char= (dp-peek p) #\Newline)) do (incf (dp-i p)))
  (unless (dp-eof p) (incf (dp-i p))))

(defun dp-read-double (p)
  "Read a double-quoted value (opening quote consumed by caller), expanding escapes."
  (with-output-to-string (o)
    (loop for c = (dp-peek p)
          do (cond ((null c) (return))
                   ((char= c #\") (incf (dp-i p)) (return))
                   ((char= c #\\)
                    (incf (dp-i p))
                    (let ((e (dp-peek p)))
                      (when e
                        (incf (dp-i p))
                        (write-char (case e (#\n #\Newline) (#\t #\Tab) (#\r #\Return)
                                      (#\\ #\\) (#\" #\") (t e)) o))))
                   (t (write-char c o) (incf (dp-i p)))))))

(defun dp-read-single (p)
  "Read a single-quoted value (literal, no escapes)."
  (with-output-to-string (o)
    (loop for c = (dp-peek p)
          do (cond ((null c) (return))
                   ((char= c #\') (incf (dp-i p)) (return))
                   (t (write-char c o) (incf (dp-i p)))))))

(defun dp-read-unquoted (p)
  "Read an unquoted value to end-of-line, trimmed. A `#` starts an inline comment
ONLY when preceded by whitespace (or at value start); a `#` mid-token is literal."
  (let ((out (make-string-output-stream)) (last nil))
    (loop for c = (dp-peek p)
          do (cond ((or (null c) (char= c #\Newline)) (return))
                   ((and (char= c #\#) (or (null last) (member last '(#\Space #\Tab)))) (return))
                   (t (write-char c out) (setf last c) (incf (dp-i p)))))
    (string-right-trim '(#\Space #\Tab #\Return) (get-output-stream-string out))))

(defun %env-lookup (name pairs)
  (or (cdr (assoc name pairs :test #'string=)) (sys:getenv name) ""))

(defun %expand-env (str pairs)
  "Expand $VAR and ${VAR} in STR against already-parsed PAIRS then the OS env (Bun
expands unquoted + double-quoted values by default)."
  (with-output-to-string (o)
    (let ((i 0) (n (length str)))
      (loop while (< i n) do
        (let ((c (char str i)))
          (if (and (char= c #\$) (< (1+ i) n))
              (let ((c2 (char str (1+ i))))
                (cond
                  ((char= c2 #\{)
                   (let ((close (position #\} str :start (+ i 2))))
                     (if close
                         (progn (write-string (%env-lookup (subseq str (+ i 2) close) pairs) o)
                                (setf i (1+ close)))
                         (progn (write-char c o) (incf i)))))
                  ((or (alpha-char-p c2) (char= c2 #\_))
                   (let ((j (1+ i)))
                     (loop while (and (< j n) (let ((ch (char str j)))
                                                (or (alphanumericp ch) (char= ch #\_))))
                           do (incf j))
                     (write-string (%env-lookup (subseq str (1+ i) j) pairs) o)
                     (setf i j)))
                  (t (write-char c o) (incf i))))
              (progn (write-char c o) (incf i))))))))

(defun %dotenv-parse (text)
  "Parse .env TEXT into an ordered list of (KEY . VALUE) conses."
  (let ((p (%make-dp (coerce text 'simple-string))) (out '()))
    (loop until (dp-eof p) do
      (dp-inline-ws p)
      (let ((c (dp-peek p)))
        (cond
          ((null c) (return))
          ((char= c #\Newline) (incf (dp-i p)))
          ((char= c #\#) (dp-to-eol p))
          (t
           ;; optional `export `
           (let ((src (dp-src p)) (i (dp-i p)))
             (when (and (<= (+ i 7) (length src)) (string= (subseq src i (+ i 7)) "export "))
               (incf (dp-i p) 7) (dp-inline-ws p)))
           ;; KEY
           (let ((kstart (dp-i p)))
             (loop for ch = (dp-peek p)
                   while (and ch (or (alphanumericp ch) (char= ch #\_)))
                   do (incf (dp-i p)))
             (let ((key (subseq (dp-src p) kstart (dp-i p))))
               (dp-inline-ws p)
               (if (and (eql (dp-peek p) #\=) (plusp (length key)))
                   (progn
                     (incf (dp-i p))              ; =
                     (dp-inline-ws p)
                     ;; single-quoted values are literal; double-quoted + unquoted
                     ;; expand $VAR/${VAR} against prior keys + OS env (Bun default).
                     (let ((val (case (dp-peek p)
                                  (#\" (incf (dp-i p)) (%expand-env (dp-read-double p) out))
                                  (#\' (incf (dp-i p)) (dp-read-single p))
                                  (t (%expand-env (dp-read-unquoted p) out)))))
                       (push (cons key val) out)
                       (dp-to-eol p)))
                   (dp-to-eol p))))))))          ; malformed → skip line
    (nreverse out)))

(defun load-dotenv (env-object cwd)
  "Load <CWD>/.env into ENV-OBJECT (a JS object), NOT overriding keys already
present (OS env wins). Missing .env is a silent no-op."
  (let ((path (sys:path-join cwd ".env")))
    (when (sys:file-p path)
      (handler-case
          (dolist (kv (%dotenv-parse (sys:read-file-string path)))
            (unless (eng:has-own-property env-object (car kv))
              (eng:create-data-property env-object (car kv) (cdr kv))))
        (error () nil)))))          ; a malformed .env never aborts the run
