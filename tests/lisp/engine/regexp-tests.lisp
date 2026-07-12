;;;; regexp-tests.lisp — RegExp engine (Phase 10): parser → CL-PPCRE translation,
;;;; RegExp object, String integration, and the loud-error gaps.

(in-package :clun-test)

(defun rev (src)
  "eval-source in a fresh realm; ToString the result in that realm."
  (let* ((realm (eng:make-realm)) (v (eng:eval-source src :realm realm)))
    (let ((eng::*realm* realm)) (eng:to-string v))))

(defun rthrows (src)
  (handler-case (progn (rev src) nil) (eng:js-condition () t) (error () t)))

(define-test regexp/test-and-anchors
  (is string= "true"  (rev "/abc/.test('xabcy')"))
  (is string= "false" (rev "/^abc$/.test('xabc')"))
  (is string= "true"  (rev "/^abc$/.test('abc')"))
  (is string= "true"  (rev "/a+b*c?/.test('aaab')"))
  (is string= "true"  (rev "/\\d{3}-\\d{4}/.test('call 123-4567')"))
  (is string= "false" (rev "/\\bword\\b/.test('sword')"))
  (is string= "true"  (rev "/\\bword\\b/.test('a word here')")))

(define-test regexp/exec
  (is string= "a1,a,1,0" (rev "var m=/(\\w)(\\d)/.exec('a1'); m[0]+','+m[1]+','+m[2]+','+m.index"))
  (is string= "null" (rev "String(/z/.exec('abc'))"))
  ;; unmatched optional group → undefined capture
  (is string= "a,undefined" (rev "var m=/(a)(b)?/.exec('a'); m[1]+','+m[2]"))
  ;; lastIndex advances under /g (match 'a' at 1 → lastIndex 2; then at 3 → 4)
  (is string= "2,4" (rev "var r=/a/g; r.exec('xaxa'); var i1=r.lastIndex; r.exec('xaxa'); i1+','+r.lastIndex")))

(define-test regexp/flags-and-getters
  (is string= "true,true,true,gimsu" (rev "var r=/x/gimsu; r.global+','+r.ignoreCase+','+r.multiline+','+r.flags"))
  (is string= "x,false" (rev "var r=/x/; r.source+','+r.sticky"))
  (is string= "true" (rev "/ABC/i.test('abc')"))
  (is string= "true" (rev "/a.b/s.test('a\\nb')"))
  (is string= "false" (rev "/a.b/.test('a\\nb')"))
  ;; multiline ^/$
  (is string= "true" (rev "/^b$/m.test('a\\nb\\nc')")))

(define-test regexp/named-groups-and-backrefs
  (is string= "2024" (rev "/(?<year>\\d{4})/.exec('y2024').groups.year"))
  (is string= "true" (rev "/(\\w)\\1/.test('aa')"))
  (is string= "false" (rev "/(\\w)\\1/.test('ab')"))
  (is string= "true" (rev "/(?<q>['\"]).*?\\k<q>/.test(\"'hi'\")")))

(define-test regexp/lookaround
  (is string= "true"  (rev "/foo(?=bar)/.test('foobar')"))
  (is string= "false" (rev "/foo(?=bar)/.test('foobaz')"))
  (is string= "true"  (rev "/foo(?!bar)/.test('foobaz')"))
  (is string= "true"  (rev "/(?<=\\$)\\d+/.test('$100')"))
  (is string= "false" (rev "/(?<=\\$)\\d+/.test('#100')")))

(define-test regexp/char-classes
  (is string= "true"  (rev "/[a-c]+/.test('abcabc')"))
  (is string= "false" (rev "/^[^0-9]+$/.test('a1b')"))
  (is string= "true"  (rev "/[\\d]+/.test('42')"))
  (is string= "true"  (rev "/\\s/.test('a\\tb')"))
  (is string= "false" (rev "/\\S/.test('   ')"))
  ;; \\v (VT) is JS whitespace (PPCRE's isn't) — the fix
  (is string= "true"  (rev "/\\s/.test('\\v')")))

(define-test regexp/string-methods
  (is string= "1-2-3" (rev "'a1b2c3'.match(/\\d/g).join('-')"))
  (is string= "hell0 w0rld" (rev "'hello world'.replace(/o/g,'0')"))
  (is string= "Smith John" (rev "'John Smith'.replace(/(\\w+)\\s(\\w+)/,'$2 $1')"))
  (is string= "[a][b]" (rev "'ab'.replace(/\\w/g, function(m){return '['+m+']';})"))
  (is string= "a|b|c" (rev "'a,b;c'.split(/[,;]/).join('|')"))
  (is string= "2" (rev "'hello'.search(/l/)"))
  (is string= "-1" (rev "'hello'.search(/z/)"))
  (is string= "X.X.X" (rev "'a.b.c'.replace(/[a-c]/g,'X')")))

(define-test regexp/matchall
  (is string= "a1,b2" (rev "var o=[]; for (const m of 'a1b2'.matchAll(/(\\w)(\\d)/g)) o.push(m[0]); o.join(',')"))
  (is string= "1,2" (rev "[...'a1b2'.matchAll(/\\d/g)].map(m=>m[0]).join(',')")))

(define-test regexp/constructor
  (is string= "a+,g" (rev "var r=new RegExp('a+','g'); r.source+','+r.flags"))
  (is string= "true" (rev "new RegExp('\\\\d+').test('42')"))
  ;; copy + flag override
  (is string= "abc,i" (rev "var r=new RegExp(/abc/,'i'); r.source+','+r.flags")))

(define-test regexp/loud-gaps
  ;; variable-length lookbehind + \p{} error loudly (SyntaxError), never silently mismatch
  (true (rthrows "/(?<=a+)b/.test('aab')"))
  (true (rthrows "/(?<=ab*)c/.test('abc')"))
  (true (rthrows "/\\p{L}/u.test('x')"))
  ;; a malformed pattern is a SyntaxError
  (true (rthrows "new RegExp('(')"))
  (true (rthrows "new RegExp('a{2,1}')")))
