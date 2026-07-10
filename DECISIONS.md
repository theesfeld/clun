# DECISIONS

Append-only architectural log. One dated entry per choice: decision, why, alternative rejected,
and any pin (name + version + SHA). Newest at the bottom of each section.

---

## Vendored library pins (Phase 00)

All CL dependencies are vendored under `vendor/` (no quicklisp) and pinned to the SHA below. The
`.git` directories were stripped so the sources are checked in. Purity verified: `make purity`
finds zero foreign-code tokens across the whole closure. Full dependency closure of parachute
resolved empirically (see 2026-07-10 entries).

| Library | Purpose | License | Pinned SHA |
|---|---|---|---|
| cl-ppcre | regex backend (parse-tree API); RegExp Phase 10 | BSD-2-Clause | `a2ea581c23fdc184168423adbd4b4c1f48d42743` |
| parachute | CL-side test framework | zlib | `9a6679e611925dfb59067393c5b7996f69501aa6` |
| documentation-utils | parachute dep | zlib | `fcbd927dee7f311915a27ee557e3db1d4510403c` |
| trivial-indent | documentation-utils dep | zlib | `87b35ff9202b107230e35790e93c471cc7880900` |
| trivial-custom-debugger | parachute dep | BSD-2-Clause | `802473c75d9db625b8f37b05c95dde47b67c52fa` |
| form-fiddle | parachute dep | zlib | `706c4fa07552d56b372f728a225021a14db3f62e` |

Later phases add (Appendix B): ironclad (Phase 12/19), pure-tls + its Linux dep closure with the
cl-cancel purity patch (Phase 19), chipz (Phase 18), cl-base64 (with pure-tls). test262 @ `d1d583d`
and other corpora land as `vendor-data/` in their phases.

---

## §3 settled decisions (seeded from PLAN.md — do not relitigate)

These are carried forward from PLAN.md §3 so the log is self-contained. Fallbacks are recorded in
the plan; a fallback taken becomes its own dated entry here.

- **Engine execution**: compile analyzed AST → CL closures (pre-resolved slots); never
  `COMPILE`-per-function at load (0.16–0.5 ms/fn → 10–25 s startup). cl-js is a design blueprint,
  not vendored (ES3).
- **Strings**: CL strings, one char = one UTF-16 code unit; astral → surrogate pairs; lone
  surrogates legal (verified). UTF-8/WTF-8 conversion only at host boundaries.
- **Numbers**: `double-float` + `with-float-traps-masked (:overflow :invalid :divide-by-zero)` at
  engine entry; Int32 via `ldb`; Ryū port for Number→String; BigInt late.
- **Object model**: spec internal-methods as struct-dispatched functions, Proxy-shaped for post-v1;
  structs never hash-table-per-object (4× memory / 2.7× GC win). Shapes/ICs deferred to Phase 25.
- **Scoping**: parser does full scope analysis; strict AND sloppy from day one, including `with`
  and direct eval.
- **Async/generators**: regenerator-style state-machine lowering (AST→AST) before closure emission.
- **RegExp**: own JS-regex parser → CL-PPCRE parse trees; documented gaps error loudly.
- **Event loop**: hybrid — one JS thread owns heap/timers/microtasks + serve-event reactor; worker
  pool for blocking ops; self-pipe wakeup; interrupt handlers enqueue-only.
- **TLS**: vendor pure-tls (+ ~40-line cl-cancel purity patch) atop ironclad; unaudited, fail-closed
  certs, SRI sha512 independent integrity. Default cipher TLS_CHACHA20_POLY1305_SHA256.
- **Package manager**: npm abbreviated metadata; hand-rolled ustar/pax tar reader; hoisted
  node_modules; `clun.lock` versioned JSON; lifecycle scripts never executed.
- **TypeScript**: type-stripping (whitespace-preserving), not transpilation; no sourcemaps by design.

---

## Dated entries

### 2026-07-10 — Phase 00 toolchain: GNU Make installed via nix
`make` is absent by default on this NixOS host, but every phase gate is defined in terms of
`make build|test|purity`. Installed GNU Make 4.4.1 into the user profile
(`nix profile add nixpkgs#gnumake`; on PATH at `~/.nix-profile/bin/make`). This is a host-toolchain
requirement, not a code change — recorded so CI (`.github/workflows/ci.yml`) and README both list it.
Alternative rejected: rewriting gates as raw `sbcl --load` invocations — would diverge from the plan's
literal gate commands and lose the single canonical entry point.

### 2026-07-10 — parachute dependency closure resolved empirically
Parachute's transitive deps were discovered by iterating `asdf:load-system` failures rather than
trusting memory: parachute → {documentation-utils → trivial-indent; trivial-custom-debugger;
form-fiddle → documentation-utils}. All six vendored + pinned above; all pure. cl-ppcre is a leaf.
`documentation-utils` also ships a `multilang-documentation-utils.asd` depending on an un-vendored
`multilang-documentation` system — left in place, inert (nothing depends on it), and its own source
is pure so the purity scan passes.

### 2026-07-10 — purity scanner: union of the ASDF load plan and the on-disk source scan
`scripts/purity-scan.lisp` scans the UNION of two file sets, per §1.1's literal wording ("the full
ASDF load plan and all vendored sources"): (1) the load plan — `asdf:required-components` for `clun`
and `clun/tests` with `:other-systems t`, i.e. every cl-source-file actually compiled into the image
including vendored deps; and (2) an on-disk scan of `src/`, `tests/`, and `vendor/` (plus root
`*.asd`), which additionally catches files a library ships but loads only conditionally (e.g.
pure-tls's win/darwin CFFI files before Phase 19 strips them) that the plan omits. The union is a
superset of the load plan by construction. `scripts/` is excluded (build tooling; this file holds the
forbidden tokens as its own search patterns). Verified both ways, including a token planted in
`tests/lisp/smoke.lisp`.
Corrected during the Phase 00 review panel: the first cut scanned only `src/` + `vendor/` and claimed
to be a "strict superset of the load plan," but `clun/tests` loads `tests/lisp/smoke.lisp` under
`tests/` — so a foreign token in a test file passed the gate silently. The load-plan walk now makes
the coverage claim true rather than asserted.

### 2026-07-10 — ASDF :version vs runtime version string
`clun.asd` uses `:version "0.0.1"` (ASDF requires dotted integers; `"0.0.1-dev"` triggers a
PARSE-VERSION warning). The user-facing version — asserted by the Phase 00 gate as `clun 0.0.1-dev`
— lives only in `src/version.lisp` (`*clun-version*`). The two are intentionally distinct.

### 2026-07-10 — Phase 01 value representation: native CL types + keyword singletons (not tagged structs)
Decided by micro-benchmark on this host (SBCL 2.6.4, `speed 3 safety 0`, 200M dispatches over 1M
mixed values): native `typecase` dispatch (numbers = `double-float`, strings = CL `string`, objects
= struct, singletons = keywords) measured **0.88 ns/dispatch and 21.4 MB**; a uniform tagged struct
`(defstruct jsval tag data)` measured **3.77 ns/dispatch and 48.0 MB** — native is 4.3× faster and
~2.25× lighter. Native also lets SBCL keep `double-float`s unboxed in typed arithmetic contexts,
which a wrapper struct defeats. This confirms §3.1 (CL strings; `double-float`; structs never
hash-table-per-object). Rejected: the uniform tagged struct (uniform dispatch, but boxes every
number and adds a pointer hop). Singletons `+undefined+/+null+/+true+/+false+` are keywords behind
named constants + predicates so the representation stays swappable (fallback `(unsigned-byte 16)`
string vectors, if memory ever dominates, touches only strings). BigInt (Phase 11) will be its own
struct/tag, not a change to this scheme.

### 2026-07-10 — Phase 01 review: StringToNumber is ASCII-digit-only, huge exponents clamped
Two fixes from the Phase 01 adversarial panel (both in `src/engine/numbers.lisp`):
(1) **ASCII-only digits.** CL `digit-char-p` accepts every Unicode Nd char, so `Number("١")`
(Arabic-Indic) wrongly returned 1. ECMA-262 §12.9.3 admits only ASCII 0-9/a-f. Replaced
`digit-char-p`/`parse-integer` in the StringToNumber path with `%ascii-digit`/`%ascii-decimal-digit-p`;
non-ASCII digits now yield NaN. Regression tests cover Arabic-Indic/Devanagari/fullwidth digits in
integer, fraction, exponent, and 0x positions.
(2) **Adversarial-length clamp (§6).** `Number("1e1000000")` built a million-digit `(expt 10 exp)`
bignum (measured 470 ms from a 9-char input — asymmetric amplification). Now the result magnitude
(`decimal-length(mantissa) + exponent`) is bounds-checked first: `> 310` → ±Infinity, `<= -324` →
±0, else exact. The clamp is exact-safe (a value is `< 10^mag`), so no representable double is
mis-clamped; `"1e1000000"` is now instant. A huge *digit-string* mantissa is still built (cost
proportional to input, no amplification) — acceptable for Phase 01.
Panel outcome: 5 confirmed / 5 refuted (adversarially verified by running code). The other three
confirmed were test-completeness nits (huge-string, ToInt32/Uint32 modulo-2^32, WTF-8 multibyte
maximal-subpart) — implementations were already correct; tests added.

### 2026-07-10 — Phase 01 Number→String uses naive bignum shortest-round-trip (Ryū deferred to Phase 04)
Per §3.1 the Ryū port is a Phase 04 task; Phase 01 still needs a correct `ToString(number)`. Chose
the plan's named fallback — shortest-round-trip via exact rational arithmetic (try increasing
significant digits until read-back `=` the source double), framed by the ECMA-262 Number::toString
algorithm (sign, NaN/±Infinity/±0, the ≤-6 / ≥21 exponent thresholds). Correct but O(17) per format;
Phase 04 swaps the digit core for Ryū for speed. Pure CL, no SBCL float-printer internals.
