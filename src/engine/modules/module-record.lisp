;;;; module-record.lisp — the module graph's node type + descriptors (Phase 07).
;;;; A record is created per resolved-path and registered in the realm's module
;;;; registry (environment.lisp). ESM records carry the compiled frame-based body
;;;; + link metadata; CJS records carry the live module.exports object.

(in-package :clun.engine)

(defstruct (module-record (:conc-name mr-))
  resolved-path                 ; truename string — the registry key
  format                        ; :esm :cjs :json :yaml :html
  (status :unlinked)            ; :unlinked :loading :linking :linked :evaluating :evaluated :errored
  source ast                    ; raw source + parsed program (ESM)
  environment                   ; the Option-A module frame (created at link, ESM)
  namespace                     ; the module-namespace js-object (lazy)
  (exports (make-hash-table :test 'equal))  ; exported-name -> export-binding
  (requested '())               ; ordered list of import/re-export source specifiers
  (requested-map (make-hash-table :test 'equal))  ; source-spec -> resolved module-record
  import-descs                  ; list of import-desc (link fills the slots)
  ;; compiled ESM artifacts (from compile-esm-module):
  slot-count name->index body-fn meta-idx (this-idx nil) (default-idx nil)
  lexical-idxs func-compiled
  ;; CJS:
  cjs-exports                   ; the live module.exports js-object
  mock-exports                  ; mock.module replacement namespace, or NIL
  (yaml-named-exports-p nil)    ; only a single top-level mapping exposes named exports
  ;; error capture (cycle re-throw):
  eval-error)

;;; --- descriptors ------------------------------------------------------------

(defstruct (import-desc (:conc-name id-))
  local          ; the local binding name (string), or NIL for a bare `import 'x'`
  kind           ; :named :default :namespace
  imported       ; the imported export name (string), for :named
  source)        ; the source specifier string

(defstruct (export-desc (:conc-name ed-))
  exported       ; the exported name (string)
  kind           ; :local :indirect :star
  local-index    ; slot index in this module's frame, for :local
  source         ; source specifier, for :indirect / :star
  imported)      ; the source's export name, for :indirect

;;; --- export-binding (what mr-exports maps to) -------------------------------
;;; A binding is a thunk of no args returning the current exported value, resolved
;;; at link time. For :star we store a marker resolved during export enumeration.

(defun mr-esm-p (mr) (eq (mr-format mr) :esm))
(defun mr-cjs-p (mr) (eq (mr-format mr) :cjs))
(defun mr-json-p (mr) (eq (mr-format mr) :json))
(defun mr-yaml-p (mr) (eq (mr-format mr) :yaml))
(defun mr-html-p (mr) (eq (mr-format mr) :html))
