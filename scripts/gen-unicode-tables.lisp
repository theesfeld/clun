;;;; gen-unicode-tables.lisp — UCD → Common Lisp property-table generator (SCAFFOLD).
;;;;
;;;; Phase 10 ships RegExp with a deliberate gap: Unicode property escapes
;;;; (\p{...} / \P{...}, the `regexp-unicode-property-escapes` feature) parse to a
;;;; LOUD SyntaxError rather than silently mismatching (see src/engine/regex/parser.lisp
;;;; and tests/conformance/regexp-gaps.txt). Closing that gap needs codepoint-range
;;;; tables for the General_Category / Script / Script_Extensions / binary properties
;;;; that ECMA-262 §22.2.1 (UnicodeMatchProperty) admits.
;;;;
;;;; This file is the SCAFFOLD for the offline generator that will produce those
;;;; tables as pure-CL source (a plain `defparameter` of sorted (lo . hi) ranges per
;;;; property — no runtime UCD parsing, no foreign code; purity contract §3). It is
;;;; intentionally not wired into the build: it errors loudly until the UCD corpus is
;;;; vendored and the emitter below is implemented. Running it today prints the plan.
;;;;
;;;; INPUT  (to be vendored under vendor-data/ucd/ at a pinned UCD version):
;;;;   UnicodeData.txt            — General_Category per codepoint (field 2)
;;;;   PropList.txt               — binary properties (White_Space, Dash, …)
;;;;   DerivedCoreProperties.txt  — Alphabetic, White_Space-derived, …
;;;;   Scripts.txt                — Script
;;;;   ScriptExtensions.txt       — Script_Extensions
;;;;   PropertyValueAliases.txt   — canonical name ↔ alias resolution
;;;;
;;;; OUTPUT (generated, checked in — the runtime loads this, never the UCD text):
;;;;   src/engine/regex/unicode-tables.lisp
;;;;     (in-package :clun.engine)
;;;;     (defparameter +ucd-gc-L+   #((#x41 . #x5A) (#x61 . #x7A) …))  ; per property
;;;;     (defparameter +ucd-script-Latin+ #(…))
;;;;     (defparameter +ucd-property-index+ '(("L" . +ucd-gc-L+) …))   ; name→table
;;;;
;;;; ALGORITHM (when implemented):
;;;;   1. Parse each UCD file into (codepoint → value) assignments (ranges collapse
;;;;      the `First>`/`Last>` UnicodeData conventions).
;;;;   2. Invert to (property-value → sorted disjoint (lo . hi) range vector); coalesce
;;;;      adjacent/overlapping ranges.
;;;;   3. Resolve aliases (gc=L, General_Category=Letter, sc=Latn, …) to one canonical
;;;;      table per ECMA-262 Table 69/70 (the admissible property set — NOT all of UCD).
;;;;   4. Emit the defparameters above, sorted, with the pinned UCD version in a header.
;;;;   Then: translate.lisp maps :unicode-property nodes to :char-class ranges, and
;;;;   parser.lisp stops throwing on \p{} for admissible properties (still loud on the
;;;;   inadmissible ones).

(require :asdf)

(defun ucd-root ()
  (merge-pathnames "vendor-data/ucd/"
                   (uiop:pathname-parent-directory-pathname
                    (uiop:pathname-directory-pathname *load-truename*))))

(defun main ()
  (format t "~&gen-unicode-tables: SCAFFOLD — not yet implemented.~%")
  (format t "  UCD corpus expected under: ~a~%" (ucd-root))
  (if (probe-file (ucd-root))
      (format t "  corpus present; the emitter is still a stub — see this file's header.~%")
      (format t "  corpus NOT vendored yet — \\p{}/\\P{} remains a loud SyntaxError (by design).~%"))
  ;; Fail loudly: a half-run generator must never emit a partial/empty table that would
  ;; silently green a \p{} that should error. (Purity + honest-gap contract.)
  (error "gen-unicode-tables is a scaffold; implement the emitter before wiring \\p{} support."))

(main)
