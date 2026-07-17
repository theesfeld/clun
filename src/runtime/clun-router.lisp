;;;; clun-router.lisp -- immutable route-table core for Clun.serve.

(in-package :clun.runtime)

(defconstant +route-max-count+ 100000)
(defconstant +route-max-segments+ 1024)
(defconstant +route-max-parameters+ 1024)
(defconstant +route-max-pattern-length+ 16384)

(defstruct (route-node (:constructor %make-route-node))
  (static-children (make-hash-table :test #'equal))
  parameter-child
  (entries '())
  (wildcard-entries '()))

(defstruct (route-entry (:constructor %make-route-entry))
  (parameter-names '())
  any-action
  (method-actions (make-hash-table :test #'equal)))

(defstruct (route-table (:constructor %make-route-table))
  (root (%make-route-node))
  (count 0 :type (integer 0 *)))

(defun %split-route-path (path)
  (cond
    ((string= path "/") '())
    (t
     (loop with start = 1
           for slash = (position #\/ path :start start)
           collect (subseq path start slash)
           while slash
           do (setf start (1+ slash))))))

(defun %route-pattern-error (message)
  (eng:throw-type-error message))

(defun %valid-route-parameter-name-p (name)
  (and (plusp (length name))
       (let ((first (char name 0)))
         (or (alpha-char-p first) (find first "_$" :test #'char=)))
       (every (lambda (character)
                (or (alphanumericp character)
                    (find character "_$" :test #'char=)))
              name)))

(defun %compile-route-pattern (pattern)
  (unless (and (plusp (length pattern)) (char= (char pattern 0) #\/))
    (%route-pattern-error "Route patterns must start with '/'."))
  (when (> (length pattern) +route-max-pattern-length+)
    (%route-pattern-error "Route pattern is too long."))
  (let ((segments (%split-route-path pattern))
        (parameters '())
        (seen (make-hash-table :test #'equal))
        (wildcard-p nil))
    (when (> (length segments) +route-max-segments+)
      (%route-pattern-error "Route pattern has too many segments."))
    (loop for segment in segments
          for index from 0
          do (cond
               ((string= segment "*")
                (unless (= index (1- (length segments)))
                  (%route-pattern-error "Route wildcards must be the final segment."))
                (setf wildcard-p t))
               ((and (plusp (length segment)) (char= (char segment 0) #\:))
                (let ((name (subseq segment 1)))
                  (unless (%valid-route-parameter-name-p name)
                    (if (and (plusp (length name)) (digit-char-p (char name 0)))
                        (%route-pattern-error "Route parameter names cannot start with a number.")
                        (%route-pattern-error "Invalid route parameter name.")))
                  (when (gethash name seen)
                    (%route-pattern-error
                     "Support for duplicate route parameter names is not yet implemented."))
                  (setf (gethash name seen) t)
                  (push name parameters)))
               ((position #\* segment)
                (%route-pattern-error "Route wildcards must occupy a complete segment."))))
    (when (> (length parameters) +route-max-parameters+)
      (%route-pattern-error "Route pattern has too many parameters."))
    (values segments
            (nconc (nreverse parameters) (when wildcard-p (list "*")))
            wildcard-p)))

(defun %route-action-p (value)
  (or (eng:callable-p value) (%response-object-p value)))

(defun %compile-route-value (value)
  (let ((entry (%make-route-entry)))
    (cond
      ((eq value eng:+false+) entry)
      ((%route-action-p value)
       (setf (route-entry-any-action entry) value)
       entry)
      ((eng:js-object-p value)
       (dolist (key (eng:jm-own-property-keys value) entry)
         (when (stringp key)
           (let ((descriptor (eng:jm-get-own-property value key)))
             (when (and descriptor (eq (eng:pd-enumerable descriptor) t))
               (let* ((method (string-upcase key))
                      (action (eng:js-getv value key)))
                 (cond
                   ((eq action eng:+false+))
                   ((%route-action-p action)
                    (setf (gethash method (route-entry-method-actions entry)) action))
                   (t (%route-pattern-error
                       "Route method values must be a function, Response, or false.")))))))))
      (t (%route-pattern-error
          "Route values must be a function, Response, method object, or false.")))))

(defun %route-entry-active-p (entry)
  (or (route-entry-any-action entry)
      (plusp (hash-table-count (route-entry-method-actions entry)))))

(defun %route-table-insert (table segments entry wildcard-p)
  (let ((node (route-table-root table)))
    (dolist (segment (if wildcard-p (butlast segments) segments))
      (if (and (plusp (length segment)) (char= (char segment 0) #\:))
          (setf node
                (or (route-node-parameter-child node)
                    (setf (route-node-parameter-child node) (%make-route-node))))
          (setf node
                (or (gethash segment (route-node-static-children node))
                    (setf (gethash segment (route-node-static-children node))
                          (%make-route-node))))))
    (if wildcard-p
        (setf (route-node-wildcard-entries node)
              (nconc (route-node-wildcard-entries node) (list entry)))
        (setf (route-node-entries node)
              (nconc (route-node-entries node) (list entry))))
    (incf (route-table-count table))))

(defun %compile-route-table (routes)
  (cond
    ((eng:js-undefined-p routes) nil)
    ((not (eng:js-object-p routes))
     (%route-pattern-error "Clun.serve: `routes` must be an object"))
    (t
     (let ((table (%make-route-table)))
       (dolist (pattern (eng:jm-own-property-keys routes) table)
         (when (stringp pattern)
           (let ((descriptor (eng:jm-get-own-property routes pattern)))
             (when (and descriptor (eq (eng:pd-enumerable descriptor) t))
               (multiple-value-bind (segments parameter-names wildcard-p)
                   (%compile-route-pattern pattern)
                 (let ((entry (%compile-route-value (eng:js-getv routes pattern))))
                   (when (%route-entry-active-p entry)
                     (setf (route-entry-parameter-names entry) parameter-names)
                     (when (>= (route-table-count table) +route-max-count+)
                       (%route-pattern-error "Clun.serve: too many routes"))
                     (%route-table-insert table segments entry wildcard-p))))))))))))

(defun %request-target-path (target)
  (let* ((query (position #\? target))
         (fragment (position #\# target))
         (end (or (and query fragment (min query fragment)) query fragment
                  (length target)))
         (without-query (subseq target 0 end)))
    (if (and (not (string= without-query ""))
             (char= (char without-query 0) #\/))
        without-query
        (let* ((scheme (search "://" without-query))
               (authority-start (and scheme (+ scheme 3)))
               (slash (and authority-start
                           (position #\/ without-query :start authority-start))))
          (if slash (subseq without-query slash) "/")))))

(defun %route-hex-byte (string index)
  (when (<= (+ index 2) (1- (length string)))
    (let ((high (digit-char-p (char string (1+ index)) 16))
          (low (digit-char-p (char string (+ index 2)) 16)))
      (when (and high low) (+ (ash high 4) low)))))

(defun %decode-route-segment (segment)
  (let ((bytes (make-array (length segment) :element-type '(unsigned-byte 8)
                                            :adjustable t :fill-pointer 0))
        (index 0))
    (loop while (< index (length segment))
          do (let ((byte (and (char= (char segment index) #\%)
                              (%route-hex-byte segment index))))
               (if byte
                   (progn (vector-push-extend byte bytes) (incf index 3))
                   (let ((code (char-code (char segment index))))
                     (if (<= code #xff)
                         (vector-push-extend code bytes)
                         (loop for encoded across
                               (eng:code-units->utf8-replacing
                                (subseq segment index (1+ index)))
                               do (vector-push-extend encoded bytes)))
                     (incf index)))))
    (eng:utf8->code-units
     (coerce bytes '(simple-array (unsigned-byte 8) (*))))))

(defun %route-action-for-method (entry method)
  (or (route-entry-any-action entry)
      (gethash method (route-entry-method-actions entry))
      (and (string= method "HEAD")
           (gethash "GET" (route-entry-method-actions entry)))))

(defun %route-entry-match (entries method captures)
  (dolist (entry entries)
    (let ((action (%route-action-for-method entry method)))
      (when action
        (return
          (values action
                  (pairlis (route-entry-parameter-names entry)
                           (reverse captures))))))))

(defun %join-route-segments (segments start)
  (format nil "~{~a~^/~}" (subseq segments start)))

(defun %match-route-table (table target method)
  (when table
    (let* ((raw-segments (%split-route-path (%request-target-path target)))
           (segments (mapcar #'%decode-route-segment raw-segments))
           (count (length segments)))
      (labels ((walk (node index captures)
                 (when (= index count)
                   (multiple-value-bind (action params)
                       (%route-entry-match (route-node-entries node) method captures)
                     (when action (return-from walk (values action params))))
                   (multiple-value-bind (action params)
                       (%route-entry-match (route-node-wildcard-entries node)
                                           method (cons "" captures))
                     (when action (return-from walk (values action params)))))
                 (when (< index count)
                   (let ((static (gethash (nth index segments)
                                          (route-node-static-children node))))
                     (when static
                       (multiple-value-bind (action params)
                           (walk static (1+ index) captures)
                         (when action (return-from walk (values action params))))))
                   (let ((parameter (route-node-parameter-child node)))
                     (when parameter
                       (multiple-value-bind (action params)
                           (walk parameter (1+ index)
                                 (cons (nth index segments) captures))
                         (when action (return-from walk (values action params))))))
                   (multiple-value-bind (action params)
                       (%route-entry-match
                        (route-node-wildcard-entries node) method
                        (cons (%join-route-segments segments index) captures))
                     (when action (return-from walk (values action params)))))
                 (values nil nil)))
        (walk (route-table-root table) 0 '())))))

(defun %install-request-route-params (request params)
  (let ((object (eng:new-object)))
    (dolist (pair params)
      (eng:data-prop object (car pair) (cdr pair)))
    (eng:data-prop request "params" object)
    object))
