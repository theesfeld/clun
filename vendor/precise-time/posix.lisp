(in-package #:org.shirakumo.precise-time)

;; clun purity patch (Phase 19): upstream reads clock_gettime through a C-FFI foreign
;; call. Replaced with SBCL's pure sb-unix:clock-gettime (a contrib, allowed by §1.1) —
;; CLOCK_REALTIME for wall time, CLOCK_MONOTONIC for the steady clock. Nanosecond
;; precision preserved. Upstream issue filed (see DECISIONS.md).

(define-constant PRECISE-TIME-UNITS-PER-SECOND 1000000000)
(define-constant MONOTONIC-TIME-UNITS-PER-SECOND 1000000000)

;; universal-time counts from 1900; the POSIX clock counts from 1970.
(defconstant +unix-to-universal+ (encode-universal-time 0 0 0 1 1 1970 0))

(define-implementation get-precise-time ()
  (multiple-value-bind (secs nsecs) (sb-unix:clock-gettime sb-unix:clock-realtime)
    (if secs
        (values (+ secs +unix-to-universal+) nsecs)
        (fail "sb-unix:clock-gettime CLOCK_REALTIME"))))

(define-implementation get-monotonic-time ()
  (multiple-value-bind (secs nsecs) (sb-unix:clock-gettime sb-unix:clock-monotonic)
    (if secs
        (values secs nsecs)
        (fail "sb-unix:clock-gettime CLOCK_MONOTONIC"))))
