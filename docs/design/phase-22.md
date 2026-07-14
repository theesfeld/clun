# Phase 22 — Tarball + integrity

**Objective (PLAN §5/§3.5):** safe extraction of npm package tarballs. A hand-rolled read-only
ustar/pax tar reader + a hardened extractor that cannot be made to write outside its destination,
gated by SRI sha512 **verify-then-commit**. cl-tar is disqualified (its extractor needs osicat/CFFI).
All CL-side, under `src/install/`, no engine dependency.

**Gate:** a real-package corpus (a lodash-scale fixture, a bin package, the Phase-21 pax-longname
tarball) extracts correctly; and the **mandated traversal suite** — absolute names, `..`
plain/embedded/via-pax-path, longname `..`, symlink-escape then write-through, hardlink escape, pax
linkpath escape, NUL/empty/`.` names, device/FIFO rejected, setuid stripped, size overflow + base-256,
duplicate last-wins, header-before-pax ordering — every case rejected or handled per spec.

## 1. Integrity (`src/install/integrity.lisp`, package `clun.integrity`)

Subresource-Integrity over the **gzipped `.tgz` bytes** (npm's `dist.integrity`).
- `parse-sri` — `algo-base64[?opts]`, possibly space-separated (pick the strongest available:
  sha512 > sha256 > sha1). A struct `(algorithm . digest-bytes)`.
- `digest-bytes (algorithm octets)` → the raw digest (ironclad `:sha512`/`:sha256`/`:sha1`).
- `sri-string (algorithm octets)` → `"sha512-<base64>"` (ironclad + cl-base64).
- `verify-integrity (octets sri)` → T, or signals `integrity-error` (algorithm unsupported, or digest
  mismatch — reporting expected vs got prefixes, never the raw bytes). Digest comparison is a plain
  `equalp` on the digest byte vectors: the digest is public, not a secret, so constant-time is moot.

## 2. Tar reader (`src/install/tarball.lisp`, package `clun.tarball`)

**Inflate, bounded.** `chipz:make-decompressing-stream :gzip` over the `.tgz` octets; read into a
growing buffer with a hard cap (`*max-inflated-bytes*`, default 512 MB) → the tar octet vector. A
zip-bomb hits the cap and signals `tarball-error` rather than exhausting the heap (§6: bound every
size from the wire).

**Header parse (512-byte blocks).** A `tar-entry` struct: `name mode size typeflag linkname
data-start`. Fields: name[0,100), mode[100,108) octal, size[124,136) **octal OR base-256** (high bit of
byte 0 set → big-endian base-256, GNU large size), typeflag[156], linkname[157,257), ustar magic[257],
prefix[345,500). Full name = `prefix "/" name` when prefix is non-empty. Octal parse tolerates leading
spaces/NULs. The 8-byte checksum[148,156) is verified (header summed with the checksum field read as
spaces) — a bad checksum is a hard error, except an all-zero block which marks end-of-archive (two of
them terminate). **Every parsed size is validated**: non-negative and ≤ `min(remaining-bytes,
*max-entry-size*)` before it is used to slice the buffer (widen-before-multiply, clamp-to-capacity).

**Extension records, applied to the NEXT entry.**
- pax `x` (per-entry) — data is `LEN KEY=VALUE\n` records; honour `path` (→ name), `linkpath`
  (→ linkname), `size` (→ size). `g` (global) is parsed and ignored.
- GNU `L` longname / `K` longlink — the entry's *data* is the long name / linkname for the next entry.
- A pending override struct is consumed by the next real (non-extension) entry; this is the
  "header-before-pax ordering" contract.

The reader returns a list of resolved `tar-entry`s (overrides already applied); it does not touch the
filesystem.

## 3. Hardened extractor (`clun.tarball`)

`extract-package (tgz-octets dest &key integrity (strip-components 1))`:
1. **Verify first.** If `integrity` is given, `verify-integrity` the `.tgz` bytes → else signal. No
   byte is extracted before the whole archive's integrity is proven.
2. **Inflate + parse** (bounded, above).
3. **Stage.** `make-temp-dir` a sibling of `dest` (same filesystem → atomic rename). Everything below
   is written under `staging`.
4. **Per entry, in order** (duplicate entries → last-wins, natural from in-order overwrite):
   - Compute the archive-relative name; strip `strip-components` leading segments (npm's `package/`
     wrapper). Reject up front: an **empty**/`.`/absolute name, a name with an embedded **NUL**, or any
     name containing a **`..`** segment — *after* pax/longname override + strip, so `..` arriving via
     pax `path`, a GNU longname, or an embedded segment is all caught at this one choke point.
   - `safe-descend (staging rel)` walks the parent components from `staging`: each existing component
     must be a **real directory** (`lstat`; a symlink component → reject — this is the "symlink-escape
     then write-through" defense: we never write *through* a symlink), a missing one is `mkdir`ed, a
     non-dir → reject. Returns the final absolute path, guaranteed to have an all-real-dir parent chain
     under `staging`.
   - Dispatch on typeflag:
     - regular (`0`/NUL) / contiguous (`7`) → write the data slice; `chmod` to `mode & #o777`
       (**setuid/setgid/sticky stripped**), so an executable bit survives (bin package) but nothing
       privileged does.
     - directory (`5`) → `mkdir` (mode masked).
     - symlink (`2`) → the linkname must be **relative** and must not lexically escape `staging`
       (normalise `dirname(rel) + linkname`; reject absolute or a normalized path that leaves
       `staging`) → then create the symlink. (Combined with never-write-through-a-symlink, an escaping
       symlink is refused outright; an in-package symlink is preserved.)
     - hardlink (`1`) → the linkname is archive-root-relative; resolve under `staging`, require it to
       exist and stay within `staging` (`realpath` containment), then `sb-posix:link`. An escaping
       target → reject.
     - char/block device (`3`/`4`), FIFO (`6`) → **rejected** (never created).
5. **Commit.** If `dest` exists, `remove-recursive` it, then `rename-path staging dest` (atomic).
6. **On any error**, `remove-recursive staging` and re-signal a `tarball-error` — nothing partial is
   ever committed (verify-then-commit).

The single containment invariant: **every directory in the write path under `staging` is a real
directory we created; `..`/absolute/NUL names are refused before use; symlink and hardlink *targets*
that escape are refused.** Each mandated traversal case reduces to one of these refusals.

## 4. Content-addressed cache (`clun.tarball`)

`cache-path (integrity)` → `~/.clun/cache/<algo>/<base64url-of-digest>.tgz` (config via `$CLUN_CACHE`).
`cache-store (integrity octets)` verifies then writes atomically (temp + rename); `cache-fetch
(integrity)` returns the bytes iff present AND they still verify (a corrupted cache entry is ignored, not
trusted). The registry client / linker (Phase 23) populate + read it; Phase 22 ships + unit-tests it.

## 5. Fixtures + gate tests (`tests/lisp/install/tarball-tests.lisp`)

A CL **tar-writer test helper** builds byte-exact archives (stock `tar` cannot emit the malicious
shapes): `tar-header`/`tar-entry`/`pax-entry`/`gnu-longname-entry` + a zero-block terminator, gzipped
with the Phase-21 `gzip-stored` encoder (valid gzip; chipz inflates it). The suite:
- **Real-package corpus:** a synthetic **lodash-scale** archive (~200 nested files) round-trips
  (every file present with correct contents); a **bin** package keeps its executable bit; the Phase-21
  **pax-longname** tarball extracts to its 156-char path.
- **Traversal suite (each must be refused/handled):** absolute `/etc/x`; `../escape`; `a/../../escape`
  (embedded); `..` via a pax `path`; `..` via a GNU longname; a symlink `s -> /tmp` then a write to
  `s/x` (write-through); a hardlink to `/etc/passwd`; a pax `linkpath` escape; a NUL-embedded / empty /
  `.` name; a char-device + a FIFO entry; a base-256 size and an oversize size field; duplicate entries
  (last wins); an `x`-header-then-entry ordering. Each asserts the escape did **not** happen (nothing
  written outside `dest`; a temp probe file outside stays untouched) and a `tarball-error` is signalled
  where the spec says reject.
- **Integrity:** the Phase-21 fixture tarballs verify against their advertised `dist.integrity`; a
  flipped byte fails closed; the cache stores + re-fetches + rejects a corrupted entry.

## 6. Risks / notes

- Extraction uses `sb-posix` directly (symlink/link/chmod/mkdtemp) via `clun.sys` wrappers — pure,
  no CFFI. `realpath` is `clun.sys:realpath` (truename with a dangling-symlink handler).
- The reader is read-only + allocation-bounded; the extractor is the security surface and gets the
  end-of-phase adversarial review panel (find → verify by crafting a bypass).
