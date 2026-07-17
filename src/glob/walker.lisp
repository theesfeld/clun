;;;; walker.lisp -- engine-free filesystem traversal for Clun.Glob.

(in-package :clun.glob)

(defconstant +linux-path-ceiling+ 4096)
(defconstant +darwin-path-ceiling+ 1024)

(defstruct (glob-scan-options (:constructor make-glob-scan-options
                                           (&key cwd dot absolute follow-symlinks
                                                 throw-error-on-broken-symlink
                                                 (only-files t))))
  cwd
  (dot nil :type boolean)
  (absolute nil :type boolean)
  (follow-symlinks nil :type boolean)
  (throw-error-on-broken-symlink nil :type boolean)
  (only-files t :type boolean))

(defstruct (glob-scan-token (:constructor make-glob-scan-token ()))
  (cancel-state 0 :type fixnum))

(define-condition glob-scan-cancelled (error) ())

(defstruct (glob-accessor
            (:constructor make-glob-accessor
                (&key (map-directory #'clun.sys:map-directory-entries)
                      (stat #'clun.sys:stat*)
                      (lstat (lambda (path) (clun.sys:stat* path :lstat t)))
                      (stat-entry #'clun.sys:stat-at*)
                      (lstat-entry (lambda (directory name)
                                     (clun.sys:stat-at* directory name :lstat t))))))
  "Engine-free directory/stat protocol used by the real and synthetic walkers."
  map-directory stat lstat stat-entry lstat-entry)

(defparameter *filesystem-glob-accessor* (make-glob-accessor))

(defun cancel-glob-scan (token)
  "Request cooperative cancellation of a scanner using TOKEN."
  (sb-ext:compare-and-swap (glob-scan-token-cancel-state token) 0 1)
  token)

(defun glob-scan-cancelled-p (token)
  (plusp (glob-scan-token-cancel-state token)))

(defun %check-cancelled (token)
  (when (and token
             (if (functionp token)
                 (funcall token)
                 (glob-scan-cancelled-p token)))
    (error 'glob-scan-cancelled)))

(defstruct scan-component
  source compiled literal-p explicit-dot-compiled globstar-p)

(defstruct scan-entry
  name path lstat stat)

(defstruct scan-state
  directory visible pattern-states ancestry)

(defun glob-js-path-to-native (value)
  "Convert a Clun UTF-16-code-unit string to an SBCL native scalar string."
  (let ((output (make-array (length value) :element-type 'character
                                           :adjustable t :fill-pointer 0))
        (index 0))
    (loop while (< index (length value)) do
      (let ((first (char-code (char value index))))
        (if (and (<= #xd800 first #xdbff)
                 (< (1+ index) (length value))
                 (<= #xdc00 (char-code (char value (1+ index))) #xdfff))
            (let ((second (char-code (char value (1+ index)))))
              (vector-push-extend
               (code-char (+ #x10000 (ash (- first #xd800) 10)
                             (- second #xdc00)))
               output)
              (incf index 2))
            (progn
              (vector-push-extend (char value index) output)
              (incf index)))))
    (coerce output 'simple-string)))

(defun glob-native-path-to-js (value)
  "Convert an SBCL native scalar string to Clun UTF-16 code units."
  (let ((output (make-array (length value) :element-type 'character
                                           :adjustable t :fill-pointer 0)))
    (loop for char across value
          for code = (char-code char)
          do (if (>= code #x10000)
                 (let ((offset (- code #x10000)))
                   (vector-push-extend
                    (code-char (+ #xd800 (ash offset -10))) output)
                   (vector-push-extend
                    (code-char (+ #xdc00 (logand offset #x3ff))) output))
                 (vector-push-extend char output)))
    (coerce output 'simple-string)))

(defun %path-ceiling ()
  (if (string= (clun.sys:platform-name) "darwin")
      +darwin-path-ceiling+
      +linux-path-ceiling+))

(defun %encoded-path-length (path)
  (length (sb-ext:string-to-octets path :external-format :utf-8)))

(defun %errno-number (name fallback)
  (let ((symbol (find-symbol name :sb-posix)))
    (if (and symbol (boundp symbol)) (symbol-value symbol) fallback)))

(defun %path-limit-check (path)
  (when (find (code-char 0) path)
    (error 'clun.sys:fs-error :code "EINVAL" :errno (%errno-number "EINVAL" 22)
           :syscall "scandir" :path path))
  (when (> (%encoded-path-length path) (%path-ceiling))
    (error 'clun.sys:fs-error :code "ENAMETOOLONG"
           :errno (%errno-number "ENAMETOOLONG" 36)
           :syscall "scandir" :path path)))

(defun %split-raw-components (pattern)
  "Split PATTERN at every raw slash, preserving empty components."
  (loop with start = 0
        for slash = (position #\/ pattern :start start)
        collect (subseq pattern start slash)
        while slash
        do (setf start (1+ slash))))

(defun %component-balanced-p (source)
  "Whether SOURCE is independently lexically usable by the scanner."
  (let ((braces 0) (class nil) (escaped nil))
    (loop for char across source do
      (cond
        (escaped (setf escaped nil))
        ((char= char #\\) (setf escaped t))
        (class (when (char= char #\]) (setf class nil)))
        ((char= char #\[) (setf class t))
        ((char= char #\{) (incf braces))
        ((char= char #\})
         (when (zerop braces) (return-from %component-balanced-p nil))
         (decf braces))))
    (and (not escaped) (not class) (zerop braces))))

(defun %component-literal-p (source)
  (let ((escaped nil))
    (loop for char across source do
      (cond
        (escaped (setf escaped nil))
        ((char= char #\\) (setf escaped t))
        ((find char "*?[{") (return-from %component-literal-p nil))))
    (not escaped)))

(defun %compile-scan-components (sources)
  (when (some (lambda (source) (not (%component-balanced-p source))) sources)
    (return-from %compile-scan-components nil))
  (map 'vector
       (lambda (source)
         (make-scan-component
          :source source
          :compiled (compile-glob source)
          :literal-p (%component-literal-p source)
          :explicit-dot-compiled (%compile-explicit-dot-glob source)
          :globstar-p (string= source "**")))
       sources))

(defun %state-closure (components states)
  (let ((seen (make-hash-table :test #'eql))
        (queue (copy-list states))
        (count (length components)))
    (loop while queue
          for index = (pop queue)
          unless (gethash index seen) do
            (setf (gethash index seen) t)
            (when (and (< index count)
                       (scan-component-globstar-p (aref components index)))
              (push (1+ index) queue)))
    (sort (loop for index being the hash-keys of seen collect index) #'<)))

(defun %advance-pattern (components states name dot)
  "Advance component NFA over NAME.
Returns the closed state set, whether a literal transition consumed NAME, and
whether this entry itself completed the pattern. The last distinction prevents
the epsilon edge of a trailing /** from matching its parent directory."
  (let ((next '()) (literal nil) (terminal nil) (count (length components)))
    (dolist (index (%state-closure components states))
      (when (< index count)
        (let ((component (aref components index)))
          (when (and (or dot
                         (not (and (plusp (length name))
                                   (char= (char name 0) #\.)))
                         (let ((explicit
                                 (scan-component-explicit-dot-compiled component)))
                           (and explicit (glob-match-p explicit name))))
                     (if (scan-component-globstar-p component)
                         t
                         (glob-match-p (scan-component-compiled component) name)))
            (if (scan-component-globstar-p component)
                (progn
                  (push index next)
                  (when (%accepting-state-p components (list index))
                    (setf terminal t)))
                (progn
                  (push (1+ index) next)
                  (when (= (1+ index) count)
                    (setf terminal t))
                  (when (scan-component-literal-p component)
                    (setf literal t))))))))
    (values (and next
                 (%state-closure components
                                 (remove-duplicates next :test #'eql)))
            literal terminal)))

(defun %accepting-state-p (components states)
  (member (length components) (%state-closure components states) :test #'eql))

(defun %states-can-consume-p (components states)
  (some (lambda (index) (< index (length components)))
        (%state-closure components states)))

(defun %directory-key (stat)
  (when stat (cons (clun.sys:fstat-dev stat) (clun.sys:fstat-ino stat))))

(defun %ancestry-occurrences (key ancestry)
  (count key ancestry :test #'equal))

(defun %scan-entry (accessor directory name token)
  (%check-cancelled token)
  (let* ((path (clun.sys:path-join directory name))
         (overlong-p (> (%encoded-path-length path) (%path-ceiling)))
         (lstat (if overlong-p
                    (funcall (glob-accessor-lstat-entry accessor) directory name)
                    (funcall (glob-accessor-lstat accessor) path)))
         (stat (if (clun.sys:fstat-symlink-p lstat)
                   (handler-case
                       (if overlong-p
                           (funcall (glob-accessor-stat-entry accessor) directory name)
                           (funcall (glob-accessor-stat accessor) path))
                     (clun.sys:fs-error (condition)
                       ;; Only a genuinely missing target is a broken symlink.
                       ;; ELOOP, EACCES, ENOTDIR, and every other filesystem
                       ;; failure remain observable.
                       (if (string= (clun.sys:fs-error-code condition) "ENOENT")
                           nil
                           (error condition))))
                   lstat)))
    (%check-cancelled token)
    (make-scan-entry :name name :path path :lstat lstat :stat stat)))

(defun %entry-result-p (entry options directory-constraint)
  (let* ((lstat (scan-entry-lstat entry))
         (stat (scan-entry-stat entry))
         (symlink (clun.sys:fstat-symlink-p lstat))
         (directory (and stat (clun.sys:fstat-dir-p stat))))
    (cond
      (directory-constraint
       (and (not (glob-scan-options-only-files options)) directory))
      ((glob-scan-options-only-files options)
       (and stat (clun.sys:fstat-file-p stat)))
      (symlink t)
      (t (and stat (or (clun.sys:fstat-file-p stat) directory))))))

(defun %join-visible (prefix name)
  (cond
    ((string= prefix "") name)
    ((string= prefix "/") (concatenate 'string "/" name))
    ((char= (char prefix (1- (length prefix))) #\/)
     (concatenate 'string prefix name))
    (t (concatenate 'string prefix "/" name))))

(defun %absolute-cwd (cwd captured-cwd)
  (let ((value (or cwd captured-cwd)))
    (if (clun.sys:absolute-path-p value)
        (clun.sys:normalize-path value)
        (clun.sys:normalize-path (clun.sys:path-join captured-cwd value)))))

(defun %strip-leading-navigation (sources root visible-prefix)
  "Consume leading empty/dot/dot-dot navigation without inventing entries."
  (loop while sources
        for source = (first sources)
        while (or (string= source "") (string= source ".") (string= source ".."))
        do (setf sources (rest sources))
           (cond
             ((string= source "") nil)
             ((string= source ".")
              (setf visible-prefix (%join-visible visible-prefix ".")))
             (t
              (setf root (clun.sys:normalize-path (clun.sys:path-join root ".."))
                    visible-prefix (%join-visible visible-prefix ".."))))
           (unless (string= source "")
             (%path-limit-check visible-prefix))
        finally (return (values sources root visible-prefix))))

(defun %navigation-component-kind (component)
  (let ((source (scan-component-source component)))
    (cond ((string= source "") :empty)
          ((string= source ".") :dot)
          ((string= source "..") :dot-dot)
          (t nil))))

(defun %navigation-state (state next-index kind accessor token)
  "Advance one explicit empty, dot, or dot-dot pattern component."
  (%check-cancelled token)
  (let* ((directory (scan-state-directory state))
         (visible (scan-state-visible state))
         (ancestry (scan-state-ancestry state))
         (next-directory
           (if (eq kind :dot-dot)
               (clun.sys:normalize-path (clun.sys:path-join directory ".."))
               directory))
         (next-visible
           (case kind
             (:dot (%join-visible visible "."))
             (:dot-dot (%join-visible visible ".."))
             (otherwise visible)))
         (next-ancestry
           (if (eq kind :dot-dot)
               (or (rest ancestry)
                   (let ((key (%directory-key
                               (funcall (glob-accessor-stat accessor)
                                        next-directory))))
                     (and key (list key))))
               ancestry)))
    (%path-limit-check next-directory)
    (make-scan-state :directory next-directory
                     :visible next-visible
                     :pattern-states (list next-index)
                     :ancestry next-ancestry)))

(defun %map-directory-entry-names (accessor directory token function)
  "Deliver immediate entry names incrementally, retaining no directory-sized list."
  (%path-limit-check directory)
  (%check-cancelled token)
  (funcall (glob-accessor-map-directory accessor)
           directory
           (lambda (name)
             (%check-cancelled token)
             (unless (or (string= name ".") (string= name ".."))
               (funcall function name))
             (%check-cancelled token)))
  nil)

(defun %result-path (entry-visible entry-path options absolute-pattern-p)
  (if (or absolute-pattern-p (glob-scan-options-absolute options))
      (glob-native-path-to-js entry-path)
      entry-visible))

(defun scan-glob (pattern &optional (options (make-glob-scan-options)) token
                                    (accessor *filesystem-glob-accessor*))
  "Return a sorted vector of paths selected by PATTERN and OPTIONS.

Traversal is iterative and checks TOKEN around every entry classification and
child push. PATTERN may be a string or an immutable COMPILED-GLOB."
  (let* ((pattern-source (if (compiled-glob-p pattern)
                             (compiled-glob-source pattern)
                             pattern))
         (captured-cwd (clun.sys:current-directory))
         (absolute-pattern-p (clun.sys:absolute-path-p pattern-source))
         (trailing-directory-p
           (and (plusp (length pattern-source))
                (char= (char pattern-source (1- (length pattern-source))) #\/)))
         (raw-sources (%split-raw-components pattern-source))
         (raw-sources (if trailing-directory-p (butlast raw-sources) raw-sources))
         (root (if absolute-pattern-p
                   "/"
                   (%absolute-cwd (glob-scan-options-cwd options) captured-cwd)))
         (visible-prefix (if absolute-pattern-p "/" "")))
    (%path-limit-check root)
    (let ((root-stat (funcall (glob-accessor-stat accessor) root)))
      (unless (clun.sys:fstat-dir-p root-stat)
        (error 'clun.sys:fs-error :code "ENOTDIR"
               :errno (%errno-number "ENOTDIR" 20)
               :syscall "scandir" :path root)))
    (multiple-value-setq (raw-sources root visible-prefix)
      (%strip-leading-navigation raw-sources root visible-prefix))
    (let ((components (%compile-scan-components raw-sources)))
      (unless components
        (return-from scan-glob #()))
      (when (zerop (length components))
        (return-from scan-glob
          (if (and (not (glob-scan-options-only-files options))
                   (or trailing-directory-p absolute-pattern-p))
              (vector (if (or absolute-pattern-p
                              (glob-scan-options-absolute options))
                          (glob-native-path-to-js root)
                          (if (string= visible-prefix "") "." visible-prefix)))
              #())))
      (let* ((root-key (%directory-key (funcall (glob-accessor-stat accessor) root)))
             (stack (list (make-scan-state :directory root
                                           :visible visible-prefix
                                           :pattern-states '(0)
                                           :ancestry (if root-key (list root-key) nil))))
             (results (make-hash-table :test #'equal)))
        (handler-case
            (loop while stack do
              (%check-cancelled token)
              (let* ((state (pop stack))
                     (directory (scan-state-directory state))
                     (closed-states
                       (%state-closure components (scan-state-pattern-states state)))
                     (navigation-states
                       (remove-if-not
                        (lambda (index)
                          (and (< index (length components))
                               (%navigation-component-kind
                                (aref components index))))
                        closed-states))
                     (entry-states
                       (remove-if
                        (lambda (index)
                          (or (= index (length components))
                              (%navigation-component-kind
                               (aref components index))))
                        closed-states)))
                ;; Explicit navigation is a pattern transition, never a fabricated
                ;; directory entry. It can appear after wildcard components and
                ;; therefore must be advanced for each live traversal state.
                (dolist (index navigation-states)
                  (let* ((kind (%navigation-component-kind (aref components index)))
                         (next (%navigation-state state (1+ index) kind accessor token)))
                    (if (= (1+ index) (length components))
                        (when (and trailing-directory-p
                                   (not (eq kind :empty))
                                   (not (glob-scan-options-only-files options)))
                          (setf (gethash
                                 (%result-path (scan-state-visible next)
                                               (scan-state-directory next)
                                               options absolute-pattern-p)
                                 results)
                                t))
                        (push next stack))))
                (when entry-states
                  (setf (scan-state-pattern-states state) entry-states)
                  (%map-directory-entry-names
                 accessor directory token
                 (lambda (name)
                   (%check-cancelled token)
                   (let ((js-name (glob-native-path-to-js name)))
                     (multiple-value-bind (next-states literal-transition-p terminal-p)
                         (%advance-pattern components (scan-state-pattern-states state)
                                           js-name (glob-scan-options-dot options))
                     ;; Classify only names with a live pattern transition. Apart
                     ;; from bounding retention, this prevents an irrelevant
                     ;; broken or inaccessible entry from changing scan results.
                     (when next-states
                       (let* ((entry (%scan-entry accessor directory name token))
                              (visible (%join-visible (scan-state-visible state) js-name))
                             (symlink-p (clun.sys:fstat-symlink-p
                                         (scan-entry-lstat entry)))
                             (target (scan-entry-stat entry))
                             (directory-p (and target (clun.sys:fstat-dir-p target))))
                        (when (and symlink-p (null target)
                                   (glob-scan-options-follow-symlinks options)
                                   (glob-scan-options-throw-error-on-broken-symlink options))
                          (if (> (%encoded-path-length (scan-entry-path entry))
                                 (%path-ceiling))
                              (funcall (glob-accessor-stat-entry accessor)
                                       directory name)
                              (funcall (glob-accessor-stat accessor)
                                       (scan-entry-path entry))))
                        (when (and terminal-p
                                   (%entry-result-p entry options trailing-directory-p))
                          (setf (gethash (%result-path visible (scan-entry-path entry)
                                                      options absolute-pattern-p)
                                         results)
                                t))
                        (when (and directory-p
                                   (%states-can-consume-p components next-states)
                                   (or (not symlink-p)
                                       (glob-scan-options-follow-symlinks options)
                                       literal-transition-p))
                          (let* ((key (%directory-key target))
                                 (ancestry (scan-state-ancestry state)))
                            ;; One alias-visible revisit is allowed. A third
                            ;; occurrence in the same branch is a cycle.
                            (when (or (null key)
                                      (< (%ancestry-occurrences key ancestry) 2))
                              (%check-cancelled token)
                              (push (make-scan-state
                                     :directory (scan-entry-path entry)
                                     :visible visible
                                     :pattern-states next-states
                                     :ancestry (if key (cons key ancestry) ancestry))
                                    stack)))))))))))))
          (glob-scan-cancelled (condition)
            (error condition)))
        (coerce (sort (loop for path being the hash-keys of results collect path)
                      #'string<)
                'vector)))))
