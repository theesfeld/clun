;;;; packages/color.lisp — clun.color package (first packages.lisp split; Elon P3 / #318).
(defpackage :clun.color
  (:use :cl)
  (:documentation "Engine-independent CSS color parsing, conversion, and terminal palettes.")
  (:export #:color #:color-p #:color-space #:color-c1 #:color-c2 #:color-c3 #:color-alpha
           #:make-rgba-color #:parse-color #:color->srgb #:color->rgba-bytes
           #:color->hsl #:color->lab #:format-css-color #:format-color-number
           #:ansi256-index #:ansi16-index))
