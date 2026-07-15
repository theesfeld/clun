;;;; module-compile.lisp — compile a parsed ESM into a frame-based body + link
;;;; metadata (Phase 07, design §4). Reuses the emitter's scope machinery: the
;;;; module's top-level scope is a function-like frame (not the global object), and
;;;; import locals are slots marked so compile-identifier derefs a getter thunk.

(in-package :clun.engine)

(defun module-name-of (node)
  "The name string of an import/export name node (identifier or string literal)."
  (cond ((identifier-p node) (identifier-name node))
        ((literal-p node) (literal-value node))
        (t (error "bad module name node ~a" node))))

(defun declaration-bound-names (decl)
  "The names a `export <decl>` binds (and thus exports)."
  (typecase decl
    (variable-declaration
     (loop for d in (variable-declaration-declarations decl)
           append (binding-bound-names (variable-declarator-id d))))
    (function-node (when (function-node-id decl) (list (identifier-name (function-node-id decl)))))
    (class-node (when (class-node-id decl) (list (identifier-name (class-node-id decl)))))
    (t '())))

(defun default-export-name (stmt)
  "If STMT is `export default` of a NAMED function/class, its own name (which is a
usable local binding); else NIL (anonymous / expression default → the `*default*`
slot)."
  (let ((d (export-default-declaration-declaration stmt)))
    (cond ((and (function-node-p d) (function-node-id d)) (identifier-name (function-node-id d)))
          ((and (class-node-p d) (class-node-id d)) (identifier-name (class-node-id d)))
          (t nil))))

(defun validate-module-early-errors (stmts scope)
  "ESM static SyntaxErrors (§16.2.1.5.1): unique ExportedNames; every `export {x}`
references a declared binding; import locals don't collide with each other or a
lexical name. Throws a JS SyntaxError (never a raw Lisp error)."
  ;; 1. ExportedNames must be unique.
  (let ((seen (make-hash-table :test 'equal)))
    (flet ((add (name)
             (when (gethash name seen)
               (throw-syntax-error (format nil "Duplicate export '~a'" name)))
             (setf (gethash name seen) t)))
      (dolist (s stmts)
        (typecase s
          (export-default-declaration (add "default"))
          (export-all-declaration
           (when (export-all-declaration-exported s)
             (add (module-name-of (export-all-declaration-exported s)))))
          (export-named-declaration
           (let ((decl (export-named-declaration-declaration s)))
             (if decl
                 (dolist (n (declaration-bound-names decl)) (add n))
                 (dolist (spec (export-named-declaration-specifiers s))
                   (add (module-name-of (export-specifier-exported spec)))))))))))
  ;; 2. A local `export {x}` / `export {x as y}` (no source) must be declared.
  (dolist (s stmts)
    (when (and (export-named-declaration-p s)
               (not (export-named-declaration-declaration s))
               (not (export-named-declaration-source s)))
      (dolist (spec (export-named-declaration-specifiers s))
        (let ((local (module-name-of (export-specifier-local spec))))
          (unless (gethash local (cs-names scope))
            (throw-syntax-error (format nil "Export '~a' is not defined in module" local)))))))
  ;; 3. Import locals must not duplicate each other or a lexical (let/const/class) name.
  (let ((seen (make-hash-table :test 'equal)))
    (dolist (n (collect-lexical-names stmts)) (setf (gethash n seen) t))
    (dolist (desc (collect-import-descs stmts))
      (when (id-local desc)
        (when (gethash (id-local desc) seen)
          (throw-syntax-error
           (format nil "Identifier '~a' has already been declared" (id-local desc))))
        (setf (gethash (id-local desc) seen) t)))))

;;; --- descriptor collection --------------------------------------------------

(defun collect-import-descs (stmts)
  "All import bindings across STMTS (a bare `import 'x'` yields a :bare desc)."
  (let ((descs '()))
    (dolist (s stmts)
      (when (import-declaration-p s)
        (let ((src (literal-value (import-declaration-source s)))
              (specs (import-declaration-specifiers s)))
          (if (null specs)
              (push (make-import-desc :local nil :kind :bare :source src) descs)
              (dolist (spec specs)
                (push (typecase spec
                        (import-default-specifier
                         (make-import-desc :kind :default :source src
                                           :local (identifier-name (import-default-specifier-local spec))))
                        (import-namespace-specifier
                         (make-import-desc :kind :namespace :source src
                                           :local (identifier-name (import-namespace-specifier-local spec))))
                        (import-specifier
                         (make-import-desc :kind :named :source src
                                           :local (identifier-name (import-specifier-local spec))
                                           :imported (module-name-of (import-specifier-imported spec)))))
                      descs))))))
    (nreverse descs)))

(defun collect-export-descs (stmts scope)
  "All export bindings across STMTS; :local descs carry the frame slot index."
  (let ((descs '()))
    (flet ((idx (name) (gethash name (cs-names scope))))
      (dolist (s stmts)
        (typecase s
          (export-default-declaration
           ;; a NAMED default fn/class exports its own local slot; anonymous/expr
           ;; exports the reserved `*default*` slot.
           (let ((name (default-export-name s)))
             (push (make-export-desc :exported "default" :kind :local
                                     :local-index (if name (idx name)
                                                      (gethash "*default*" (cs-names scope))))
                   descs)))
          (export-all-declaration
           (let ((src (literal-value (export-all-declaration-source s)))
                 (exp (export-all-declaration-exported s)))
             (push (if exp
                       (make-export-desc :exported (module-name-of exp) :kind :star-as :source src)
                       (make-export-desc :exported nil :kind :star :source src))
                   descs)))
          (export-named-declaration
           (let ((decl (export-named-declaration-declaration s))
                 (specs (export-named-declaration-specifiers s))
                 (src (and (export-named-declaration-source s)
                           (literal-value (export-named-declaration-source s)))))
             (cond
               (decl
                (dolist (name (declaration-bound-names decl))
                  (push (make-export-desc :exported name :kind :local :local-index (idx name)) descs)))
               (t
                (dolist (spec specs)
                  (let ((local (module-name-of (export-specifier-local spec)))
                        (exported (module-name-of (export-specifier-exported spec))))
                    (push (if src
                              (make-export-desc :exported exported :kind :indirect
                                                :source src :imported local)
                              (make-export-desc :exported exported :kind :local
                                                :local-index (idx local)))
                          descs))))))))))
    (nreverse descs)))

(defun collect-requested (stmts)
  "Ordered, de-duplicated list of every module specifier STMTS depend on."
  (let ((seen (make-hash-table :test 'equal)) (out '()))
    (flet ((add (src) (unless (gethash src seen)
                        (setf (gethash src seen) t) (push src out))))
      (dolist (s stmts)
        (typecase s
          (import-declaration (add (literal-value (import-declaration-source s))))
          (export-all-declaration (add (literal-value (export-all-declaration-source s))))
          (export-named-declaration
           (when (export-named-declaration-source s)
             (add (literal-value (export-named-declaration-source s))))))))
    (nreverse out)))

;;; --- the compile ------------------------------------------------------------

(defun compile-esm-module (mr)
  "Compile MR's parsed ESM into a frame body + link metadata, stored on MR. The
module scope is a function-like frame; imports are marked slots. Modules are strict."
  (let* ((program (mr-ast mr))
         (stmts (program-body program))
         (scope (make-cscope :function))
         (comp (make-comp)))
    (setf (comp-module comp) mr (comp-strict comp) t)
    ;; reserved slots: module `this` (undefined) + import.meta object.
    (cs-declare scope "%this%")
    (let ((meta-idx (cs-declare scope "%import.meta%")))
      ;; import locals: a slot each, marked so identifier reads deref the thunk.
      (dolist (desc (collect-import-descs stmts))
        (when (id-local desc)
          (cs-declare scope (id-local desc))
          (cs-mark-import scope (id-local desc))))
      ;; a `*default*` slot iff there's an ANONYMOUS/expression `export default`
      ;; (a named default fn/class uses its own name slot instead).
      (when (some (lambda (s) (and (export-default-declaration-p s)
                                   (not (default-export-name s))))
                  stmts)
        (cs-declare scope "*default*"))
      ;; hoisted top-level var / function / lexical names.
      (multiple-value-bind (vars funcs) (collect-var-names stmts)
        (dolist (n vars) (cs-declare scope n))
        (dolist (n funcs) (cs-declare scope n))
        (dolist (n (collect-lexical-names stmts)) (cs-declare scope n))
        (mark-immutable-lexicals scope stmts)
        (setf (comp-scopes comp) (list scope))
        (validate-module-early-errors stmts scope)
        (let* ((lexical-idxs (loop for n in (collect-lexical-names stmts)
                                   collect (gethash n (cs-names scope))))
               (func-decls (collect-function-decls stmts))
               (func-compiled (loop for fd in func-decls
                                    collect (cons (gethash (identifier-name (function-node-id fd)) (cs-names scope))
                                                  (compile-function-common
                                                   comp (function-node-params fd) (function-node-body fd)
                                                   (identifier-name (function-node-id fd))
                                                   :generator (function-node-generator fd)
                                                   :async (function-node-async fd)))))
               (body-fn (compile-seq comp stmts)))
          (setf (mr-slot-count mr) (cs-count scope)
                (mr-name->index mr) (cs-names scope)
                (mr-body-fn mr) body-fn
                (mr-meta-idx mr) meta-idx
                (mr-default-idx mr) (gethash "*default*" (cs-names scope))
                (mr-lexical-idxs mr) lexical-idxs
                (mr-func-compiled mr) func-compiled
                (mr-import-descs mr) (collect-import-descs stmts)
                (mr-requested mr) (collect-requested stmts)
                ;; export-descs are stashed transiently for link (see loader).
                (gethash :export-descs (mr-requested-map mr)) (collect-export-descs stmts scope)))))
    mr))

;;; --- import.meta object -----------------------------------------------------

(defun make-import-meta-object (mr)
  "The per-module `import.meta`: url/filename/dirname/main (Bun-flavored)."
  (let ((o (new-object))
        (path (mr-resolved-path mr)))
    (data-prop o "url" (concatenate 'string "file://" path))
    (data-prop o "filename" path)
    (data-prop o "dirname" (clun.sys:path-dirname path))
    (data-prop o "main" (js-boolean (eq mr (realm-entry-module *realm*))))
    o))
