;;;; color-tests.lisp -- CSS Color parser and conversion regressions (Phase 34).

(in-package :clun-test)

(defun color-bytes (spelling)
  (multiple-value-list (clun.color:color->rgba-bytes (clun.color:parse-color spelling))))

(define-test color/functional-and-wide-gamut-parsing
  (is equal '(255 0 128 64) (color-bytes "rgb(100% 0% 50% / 25%)"))
  (is equal '(255 0 0 255) (color-bytes "color(display-p3 1 0 0)"))
  (is equal '(255 0 0 255) (color-bytes "color(rec2020 1 0 0)"))
  (is equal '(255 255 255 255)
      (color-bytes "color(xyz-d50 0.96422 1 0.82521)")))

(define-test color/css-component-grammar
  (is equal '(1 2 3 128) (color-bytes "rgb(1,2,3,.5)"))
  (is equal '(0 0 0 255) (color-bytes "rgb(none none none)"))
  (is equal '(0 0 0 0) (color-bytes "rgb(0 0 0 / none)"))
  (is eq nil (clun.color:parse-color "rgb (255 0 0)"))
  (is eq nil (clun.color:parse-color "rgb(1. 2 3)"))
  (is eq nil (clun.color:parse-color "rgb(1%,2,3)"))
  (is eq nil (clun.color:parse-color "hsl(0 1 0.5)"))
  (is eq nil (clun.color:parse-color "hsl(none,0%,0%)"))
  (is eq nil (clun.color:parse-color "hsla(0,none,0%,.5)"))
  (is eq nil (clun.color:parse-color "hwb(0 0 0)"))
  (is eq nil (clun.color:parse-color "hwb(0, 0%, 0%)"))
  (is eq nil (clun.color:parse-color "lab(50 20 30)"))
  (is eq nil (clun.color:parse-color "lab(50% 20% 30%)"))
  (is equal "lab(200% 0 0)"
      (clun.color:format-css-color (clun.color:parse-color "lab(200% 0 0)")))
  (is equal "oklch(101% 2 0)"
      (clun.color:format-css-color (clun.color:parse-color "oklch(101% 2 0)")))
  (is equal "color(display-p3 none 0 0 / none)"
      (clun.color:format-css-color
       (clun.color:parse-color "color(display-p3 none 0 0 / none)")))
  (is equal "color(srgb 1 0 0 / none)"
      (clun.color:format-css-color
       (clun.color:parse-color "color(srgb 1 0 0 / none)")))
  (is equal "color(xyz 1 1 1)"
      (clun.color:format-css-color
       (clun.color:parse-color "color(xyz-d65 1 1 1)"))))

(define-test color/oklab-regressions
  ;; LMS_TO_XYZ's third X coefficient is positive. The wrong sign turns this
  ;; CSS Color 4 vector into #8e5000 instead of the pinned Bun #a14203.
  (is equal '(161 66 3 255) (color-bytes "oklab(50% .1 .1)"))
  (is equal '(255 0 0 255) (color-bytes "oklch(62.8% .258 29.23deg)")))

(define-test color/engineering-boundary-regressions
  (is equal '(0 0 255 255) (color-bytes "lab(29.5683% 68.2874 -112.0297)"))
  (is equal '(0 0 238 255) (color-bytes "lab(27.2497% 64.8129 -106.3296)"))
  (is equal '(2 0 255 255) (color-bytes "oklab(45.2% -0.032 -0.312)"))
  (is equal '(0 50 49 255) (color-bytes "lab(25% -150 -150)"))
  (is equal '(242 0 22 255) (color-bytes "lab(50% 100 100)"))
  (multiple-value-bind (h s l alpha)
      (clun.color:color->hsl (clun.color:parse-color "rgb(1.4 0 0)"))
    (is = 0d0 h)
    (is = 1d0 s)
    (is = (/ 1d0 510d0) l)
    (is = 1d0 alpha))
  (multiple-value-bind (h s l alpha)
      (clun.color:color->hsl (clun.color:parse-color "rgb(1.4 0 0)"))
    (declare (ignore h l alpha))
    (is equal "100" (clun.color:format-color-number (* s 100d0))))
  (multiple-value-bind (h s l alpha)
      (clun.color:color->hsl (clun.color:parse-color "hsl(120 none 50%)"))
    (is = 120d0 h)
    (is = 0d0 s)
    (is = 0.5d0 l)
    (is = 1d0 alpha))
  (multiple-value-bind (l a b alpha)
      (clun.color:color->lab (clun.color:parse-color "lab(none 40 30)"))
    (is = 0d0 l)
    (is = 40d0 a)
    (is = 30d0 b)
    (is = 1d0 alpha)))

(define-test color/css-serialization
  (is equal "0" (clun.color:format-color-number -0d0))
  (is equal "0.12345678901234568"
      (clun.color:format-color-number 0.12345678901234568d0))
  (is equal "1e-20" (clun.color:format-color-number 1d-20))
  (is equal "#00f" (clun.color:format-css-color (clun.color:parse-color "blue")))
  (is equal "#1a334d" (clun.color:format-css-color (clun.color:parse-color "rgb(10% 20% 30%)")))
  (is equal "oklab(50% 0.1 0.1)"
      (clun.color:format-css-color (clun.color:parse-color "oklab(50% .1 .1)"))))
