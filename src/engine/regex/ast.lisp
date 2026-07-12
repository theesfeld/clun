;;;; ast.lisp — the JS-regex AST (PLAN.md §3.1, Phase 10). Own node structs; positions
;;;; are not tracked (error messages carry the parser offset). `rx-char` holds a code
;;;; unit (0..#xFFFF) so surrogate handling is explicit.

(in-package :clun.engine)

(defstruct (rx-node (:constructor nil)))
(defstruct (rx-disjunction (:include rx-node) (:constructor make-rx-disjunction (alternatives))) alternatives)
(defstruct (rx-alternative (:include rx-node) (:constructor make-rx-alternative (terms))) terms)
(defstruct (rx-char (:include rx-node) (:constructor make-rx-char (code))) code)
(defstruct (rx-dot (:include rx-node) (:constructor make-rx-dot)))
(defstruct (rx-class (:include rx-node) (:constructor make-rx-class (negated items))) negated items)
(defstruct (rx-class-range (:include rx-node) (:constructor make-rx-class-range (lo hi))) lo hi)
(defstruct (rx-esc (:include rx-node) (:constructor make-rx-esc (kind))) kind)  ; :digit :non-digit :word :non-word :space :non-space
(defstruct (rx-group (:include rx-node) (:constructor make-rx-group (kind index name body)))
  kind index name body)                                     ; kind :capture :non-capture
(defstruct (rx-backref (:include rx-node) (:constructor make-rx-backref (index name))) index name)
(defstruct (rx-anchor (:include rx-node) (:constructor make-rx-anchor (kind))) kind) ; :start :end :word-boundary :non-word-boundary
(defstruct (rx-look (:include rx-node) (:constructor make-rx-look (dir sense body))) dir sense body) ; dir :ahead/:behind sense :pos/:neg
(defstruct (rx-quant (:include rx-node) (:constructor make-rx-quant (atom min max greedy))) atom min max greedy)

;;; A compiled regex literal (memoized on the AST node): the immutable data a
;;; js-regexp wrapper shares across evaluations.
(defstruct (rx-compiled (:conc-name rxc-))
  source flags scanner name-alist group-count flag-bits)
