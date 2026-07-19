;;;; bundler-tests.lisp — tooling.bundler full port (#180)

(in-package :clun-test)

(defun %tmpdir (prefix)
  (let* ((base (sys:tmpdir))
         (name (format nil "~a-~a" prefix (get-universal-time)))
         (path (sys:path-join base name)))
    (sys:make-directory path :recursive t)
    path))

(define-test bundler-single-entry-esm
  (let* ((dir (%tmpdir "clun-bundle"))
         (entry (sys:path-join dir "index.js"))
         (helper (sys:path-join dir "helper.js"))
         (outdir (sys:path-join dir "out")))
    (sys:write-file-octets entry
      (eng:code-units->utf8 "import { greet } from './helper.js';
export default greet('world');
"))
    (sys:write-file-octets helper
      (eng:code-units->utf8 "export function greet(name) { return 'hello ' + name; }
"))
    (let ((result (clun.bundler:build
                   (list :entrypoints (list entry)
                         :outdir outdir
                         :format "esm"
                         :throw t))))
      (true (clun.bundler:br-success result))
      (true (plusp (length (clun.bundler:br-outputs result))))
      (let* ((entry-out (find :entry (clun.bundler:br-outputs result)
                              :key #'clun.bundler:ba-kind))
             (text (clun.bundler:ba-text entry-out)))
        (true (search "__modules" text))
        (true (search "greet" text))
        (true (search "export default" text))))))

(define-test bundler-minify-and-define
  (let* ((dir (%tmpdir "clun-bundle-min"))
         (entry (sys:path-join dir "app.js"))
         (outdir (sys:path-join dir "dist")))
    (sys:write-file-octets entry
      (eng:code-units->utf8 "const MODE = __MODE__;
export default MODE + 'ok';
"))
    (let* ((result (clun.bundler:build
                    (list :entrypoints (list entry)
                          :outdir outdir
                          :minify t
                          :define (list (cons "__MODE__" "\"prod\""))
                          :throw t)))
           (text (clun.bundler:ba-text
                  (find :entry (clun.bundler:br-outputs result)
                        :key #'clun.bundler:ba-kind))))
      (true (clun.bundler:br-success result))
      (true (search "prod" text))
      (false (search "__MODE__" text)))))

(define-test bundler-json-text-loaders
  (let* ((dir (%tmpdir "clun-bundle-loaders"))
         (entry (sys:path-join dir "main.js"))
         (data (sys:path-join dir "data.json"))
         (note (sys:path-join dir "note.txt"))
         (outdir (sys:path-join dir "out")))
    (sys:write-file-octets data (eng:code-units->utf8 "{\"n\":42}"))
    (sys:write-file-octets note (eng:code-units->utf8 "hello-asset"))
    (sys:write-file-octets entry
      (eng:code-units->utf8 "import data from './data.json';
import note from './note.txt';
export default { data, note };
"))
    (let* ((result (clun.bundler:build
                    (list :entrypoints (list entry)
                          :outdir outdir
                          :throw t)))
           (text (clun.bundler:ba-text
                  (find :entry (clun.bundler:br-outputs result)
                        :key #'clun.bundler:ba-kind))))
      (true (clun.bundler:br-success result))
      (true (search "42" text))
      (true (search "hello-asset" text)))))

(define-test bundler-virtual-files
  (let* ((dir (%tmpdir "clun-bundle-virt"))
         (outdir (sys:path-join dir "out"))
         (files (make-hash-table :test 'equal)))
    (setf (gethash (sys:path-join dir "index.js") files)
          "import { x } from './lib.js'; export default x * 2;")
    (setf (gethash (sys:path-join dir "lib.js") files)
          "export const x = 21;")
    (let* ((result (clun.bundler:build
                    (list :entrypoints (list (sys:path-join dir "index.js"))
                          :outdir outdir
                          :root dir
                          :files files
                          :throw t)))
           (text (clun.bundler:ba-text
                  (find :entry (clun.bundler:br-outputs result)
                        :key #'clun.bundler:ba-kind))))
      (true (clun.bundler:br-success result))
      (true (search "21" text)))))

(define-test bundler-analyze-exceed
  (let* ((dir (%tmpdir "clun-bundle-analyze"))
         (entry (sys:path-join dir "a.js"))
         (b (sys:path-join dir "b.js")))
    (sys:write-file-octets entry
      (eng:code-units->utf8 "import './b.js'; export default 1;"))
    (sys:write-file-octets b (eng:code-units->utf8 "export const z = 2;"))
    (let ((analysis (clun.bundler:analyze
                     (list :entrypoints (list entry) :root dir))))
      (true (>= (getf analysis :count) 2))
      (true (member entry (getf analysis :entries) :test #'string=)))))

(define-test bundler-cjs-format-and-banner
  (let* ((dir (%tmpdir "clun-bundle-cjs"))
         (entry (sys:path-join dir "i.js"))
         (outdir (sys:path-join dir "o")))
    (sys:write-file-octets entry (eng:code-units->utf8 "export default 7;"))
    (let* ((result (clun.bundler:build
                    (list :entrypoints (list entry)
                          :outdir outdir
                          :format "cjs"
                          :banner "// clun-bundled"
                          :throw t)))
           (text (clun.bundler:ba-text
                  (find :entry (clun.bundler:br-outputs result)
                        :key #'clun.bundler:ba-kind))))
      (true (search "module.exports" text))
      (true (search "clun-bundled" text)))))

(define-test bundler-metafile
  (let* ((dir (%tmpdir "clun-bundle-meta"))
         (entry (sys:path-join dir "e.js"))
         (outdir (sys:path-join dir "d")))
    (sys:write-file-octets entry (eng:code-units->utf8 "export default 1;"))
    (let ((result (clun.bundler:build
                   (list :entrypoints (list entry)
                         :outdir outdir
                         :metafile t
                         :throw t))))
      (true (stringp (clun.bundler:br-metafile result)))
      (true (search "\"inputs\"" (clun.bundler:br-metafile result))))))
