# Phase 13 — Files: fs substrate + node:fs + Buffer

Objective (§5): a pure-CL filesystem substrate under `clun.sys`, `node:buffer` (Buffer as a
Uint8Array subclass), `node:fs` (sync core + `fs/promises` + callback shims + Stats/Dirent/
constants), and the `Clun.file`/`Clun.write` lazy-file surface. **Gate:** ~60-case fs conformance
(bracket paths, symlink chains, ENOENT/EISDIR); Buffer KAT vectors; `Clun.file` lazy fixtures;
build/test/purity green; 0 test262 regressions (node builtins are inert in bare realms).

Grounded in the actual source. Deps: Phase 11 (TypedArray/ArrayBuffer — Buffer rides on them),
Phase 12 (the `*builtin-module-builder*` hook + `src/runtime/node/registry.lisp`), Phase 05 loop
(async is Promise-over-sync here; a real worker-pool offload is deferred to when it pays for itself).

## 1. Three engine-free layers, then the runtime boundary

The design mirrors Phase 07's discipline: nothing engine-aware sits below `src/runtime/`.

1. **`src/sys/fs.lisp` (clun.sys)** — path-disciplined POSIX primitives over `sb-posix` + CL
   streams. Every path crossing into a pathname goes through `native->pathname` (paths.lisp) so
   `[`-bearing names never trip SBCL's wildcard reader. New this phase: a code-carrying condition,
   the errno table, mutating ops, octet I/O, and stat.

2. **`src/runtime/node/buffer.lisp`** — `node:buffer`, built on the Phase-11 typed-array machinery
   via a small set of engine helpers (`eng:make-u8-array`, `eng:u8-from-octets`, `eng:ta-octets`,
   `eng:ta-subview`, `eng:u8-over-arraybuffer`). Self-registers with the registry.

3. **`src/runtime/node/fs.lisp`** — `node:fs`, a thin JS-shaped skin over the sys layer. Self-registers.

4. **`Clun.file`/`Clun.write`** in `src/runtime/clun-global.lisp` — Bun-shaped lazy file I/O, sharing
   the same sys octet primitives; async members return real Promises.

## 2. errno → a code-carrying condition (§6: no raw backtrace crosses to JS)

`clun.sys:fs-error` carries `code`/`errno`/`syscall`/`path`. The `with-fs (syscall path)` macro wraps
every syscall body and maps BOTH failure shapes SBCL produces:

- `sb-posix:syscall-error` → `%raise-fs` (errno straight off the condition → POSIX name via the
  host-built `*errno-names*` table).
- CL `file-error` (what `with-open-file`/`truename` signal) → `%raise-fs-file`, which PROBES the path
  (`path-exists-p`/`directory-p`) to synthesize ENOENT/EISDIR/EACCES, then fills `errno` from the code
  via `%errno-of-name` so callers can report Node's negative errno.

`read-file-string`/`read-file-octets` guard a directory target up front (opening a dir stream signals a
non-`file-error` otherwise) → EISDIR. The macro + condition are defined ABOVE the first `with-fs` use
(`read-file-string`) so the macro is available at compile time (macros must precede use; the `%raise-*`
functions it names are ordinary forward references).

The runtime maps `fs-error` → a JS `Error` with `.code`/`.errno`/`.syscall`/`.path`. `.errno` is the
NEGATIVE POSIX errno (`-(abs errno)`) to match Node/libuv on Linux; the message is
`"CODE: description, syscall 'path'"` where `description` comes from the shared `clun.sys:fs-code-message`
(one table behind both the condition `:report` and the JS Error, so they never drift). `%with-fs`
(sync), `%callbackify` (cb(err) / cb(null,res)), and `%promisify` (reject/resolve) are the three
boundary wrappers; all three catch `fs-error` and nothing wider.

## 3. Buffer = a Uint8Array subclass

A Buffer instance is a Phase-11 `js-typed-array` of `kind :uint8` whose `[[Prototype]]` is
`Buffer.prototype`, itself proto'd on `Uint8Array.prototype`. So indexing, `.length`, `.buffer`, and the
whole TypedArray method surface are INHERITED for free; `%is-buffer` walks the proto chain for
`*buffer-proto*`. `%buf-view (this)` returns `(values backing byte-offset length)` — the one accessor
every method funnels through. `%buffer-from-octets` is the interop point fs uses to hand bytes to JS.

- **Encodings** (hand-rolled, no external codec): utf8, hex, base64/base64url (own `+b64+`/`+b64url+`
  alphabets), latin1/binary, ascii, ucs2/utf16le. utf8 reuses `eng:code-units->utf8`/`utf8->code-units`.
- **slice/subarray** share memory (`eng:ta-subview this start end *buffer-proto*`) — Node semantics:
  writes through the view hit the parent. **copy** is memmove (backward copy on same-backing forward
  overlap). **concat** allocates `totalLength` (zero-filled tail when it exceeds the sum; truncates when
  smaller). **write(string[,offset[,length]][,encoding])** handles the 2-arg `write(str, encoding)` form.
- **Numeric read/write** — `%read-uint`/`%write-uint` are the primitives; `%read-int` and the float
  readers/writers (via `sb-kernel:make-single-float`/`make-double-float`, trap-masked) all route through
  them, so ONE bounds check (`%num-bounds`, off < 0 ∨ off+n > backing-length → RangeError) covers every
  accessor. `%write-f64` additionally guards its full 8 bytes up front so a boundary offset can't
  partial-write across its two halves. OOB is a catchable RangeError, never a raw subscript abort.

## 4. node:fs surface

Sync core (23): readFile/writeFile/appendFile, stat/lstat, mkdir/rmdir/rm, readdir, unlink, rename,
realpath, copyFile, readlink, symlink, chmod, truncate, mkdtemp, access, exists. Each sync fn is
`%op-*` (a fn of the JS args) wrapped once by `%with-fs`; the SAME `%op-*` fns feed `%callbackify` and
`%promisify`, so callback + promise forms are free. `fs.promises` (14) and the callback forms reuse them
verbatim. **Stats** carries isFile/isDirectory/isSymbolicLink (+ block/char/FIFO/socket stubs), size/
mode/ino/nlink/uid/gid/dev/rdev, and *Ms + Date times (second-granular; birthtime===ctime). **Dirent**
(readdir withFileTypes) lstats each entry. `mkdirSync({recursive})` returns the TOPMOST newly-created
directory (or undefined) — `make-directory` returns that path; non-recursive returns undefined.
`accessSync` honours its mode arg. `rm({force})` swallows ENOENT.

## 5. Crash-safety review (the dominant risk class)

Per the standing §6 contract, the review panel (find → verify-by-running-the-binary) hunted raw Lisp
backtraces reaching a user. Confirmed + fixed: Buffer.from(ArrayBuffer) view (shared, not copied) crash;
OOB numeric read/write (→ RangeError, all accessors, incl. BigInt/float/variable-width — verified by an
adversarial probe: neg/NaN/Inf offsets, 8-byte reads on a 4-byte buffer, byteLength overrun); copy
backward-overlap corruption; Clun.file.text() missing-file crash (read-file-string now signals fs-error);
Clun.write(ArrayBuffer); concat zero-pad; write(str, encoding) 2-arg; error message shape + negative
errno + access mode + mkdir-recursive return. Residual deliberate divergences (integer-write value
masking, negative/NaN-offset clamping, view-vs-backing OOB bound) are enumerated in
`tests/conformance/fs-buffer-gaps.txt` — each is safe (defined byte / catchable error), never a crash.

## 6. Deliberate deferrals

File descriptors (open/read/write/close by fd), streams (createReadStream/WriteStream — Phase 17),
watchers, Dir handles + recursive cp, chown/utimes/link, the `bigint:true` stat option, and a real
worker-pool async offload (Promises currently resolve synchronously). See the gaps file for the full
list. These are absent (a missing method reads as `undefined`), not silently wrong.
