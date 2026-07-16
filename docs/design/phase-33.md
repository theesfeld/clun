# Phase 33: Terminal String Width

## 1. Objective and boundary

Phase 33 converts the `text.string-width` compatibility row from `No` to an evidence-backed
`Yes` by adding one public JavaScript function:

```js
Clun.stringWidth(input, options?) // number of terminal columns
```

The behavioral reference is `Bun.stringWidth`, but the namespace remains `Clun`. This phase does
not add a `Bun` global, a `bun` module alias, or any other ANSI utility API. ANSI parsing exists only
inside the width implementation.

The canonical live source of truth is [issue #7](https://github.com/theesfeld/clun/issues/7). It
owns live status, decisions, findings, four-target receipts, release evidence, and closeout. This
document freezes the technical contract before the current core/runtime prototypes are integrated.
Prototype behavior is not accepted merely because it exists in a worktree.

Phase 10 and Phase 27 are the declared dependencies. Their completion supplies the JavaScript
runtime/value model and the compatibility-ledger/evidence machinery respectively.

## 2. Frozen references and evidence priority

The phase uses two Bun references for distinct purposes:

| Role | Version/ref | Exact commit | Relevant paths |
|---|---|---|---|
| Public executable baseline | Bun 1.3.14 | `0d9b296af33f2b851fcbf4df3e9ec89751734ba4` | `docs/runtime/utils.mdx`, `packages/bun-types/bun.d.ts`, `test/js/bun/util/stringWidth.test.ts` |
| Forward engineering inventory | Bun 1.4.0-dev | `c1076ce95effb909bfe9f596919b5dba5567d550` | the same docs/types/test plus `src/jsc/bindings/stringWidth.cpp`, `src/jsc/bindings/stringWidth.h`, `src/jsc/bindings/stringWidthTables.h`, `scripts/generate-stringwidth-tables.mjs` |

The stable assets and their SHA-256 values are already pinned for `linux-x64`, `linux-arm64`,
`darwin-x64`, and `darwin-arm64` in `compat/upstream-assets.tsv`. They are the authority for public
Bun behavior. The engineering commit is source inventory and forward-correctness evidence; it does
not silently replace the public baseline.

Evidence priority is:

1. observable results from the pinned Bun 1.3.14 executable;
2. the stable public type and documentation promise;
3. stable tests at the exact stable commit;
4. engineering tests and implementation at the exact engineering commit; and
5. independently derived Clun correctness corpora.

The actual upstream test path is `test/js/bun/util/stringWidth.test.ts`. The older
`test/js/bun/terminal` reference is incorrect and must be repaired in `compat/references.tsv` in the
implementation unit.

### 2.1 Stable, engineering, and Clun dispositions

| Behavior | Bun 1.3.14 | Engineering pin | Phase 33 disposition |
|---|---|---|---|
| Basic ASCII, CJK, emoji, combining marks, CSI/OSC, options | supported | supported and expanded | match |
| Family/ZWJ emoji such as `U+1F468 ZWJ U+1F469 ZWJ U+1F467 ZWJ U+1F466` | width 2 | width 2 | width 2; the stale type-example value of 1 is not followed |
| `U+202A..U+202E` bidi embedding/override controls | incorrectly visible | width 0 | width 0 |
| `U+2065..U+206F` bidi isolates/reserved controls | incorrectly visible | width 0 | width 0 |
| `U+061C` Arabic Letter Mark | incorrectly visible | width 0 | width 0 |
| `U+180B..U+180F` Mongolian selectors/separator | incorrectly visible | width 0 | width 0 |
| Zero-width-only clusters ending in VS16, including `FE00 FE0E FE0F`, `FE0E FE0F`, `0300 FE0F`, and `200D FE0F` | incorrectly width 2 | incorrectly width 2 | width 0 |
| `ambiguousIsNarrow: false` for Latin-1-backed ambiguous characters such as `U+00B1` | incorrectly remains width 1 | still depends on backing-string representation | uniformly width 2 |
| Unicode 17 GCB Control `U+E0001`, measured by `0890 E0001 20E3` | carried table joins the sequence, width 2 | carried table joins the sequence, width 2 | follow Unicode 17's Control boundary, width 3 |

The four invisible-range changes adopt measured engineering fixes over stable bugs. Zero-width-only
clusters ending in VS16, uniform East Asian Ambiguous handling, and Unicode 17's GCB Control class
for `U+E0001` are explicit Clun correctness improvements: an invisible cluster must stay invisible, and a JavaScript string's semantic answer
must not depend on whether the engine stores it as Latin-1 or UTF-16. These divergences must
be recorded on issue #7 and in `DECISIONS.md`; the fixtures must contain the exact cases. They do not
authorize any other unmeasured deviation.

No Bun performance number is inherited. In particular, the Bun documentation's SIMD benchmark is
not a Clun claim.

## 3. Exact JavaScript contract

### 3.1 Namespace and function descriptors

`install-clun-string-width` installs one own data property on the realm's existing `Clun` object.
The observable descriptor is:

```text
Clun.stringWidth: writable=true, enumerable=true, configurable=false
```

The value is an ordinary native function with all of the following properties:

| Observation | Required value |
|---|---|
| `typeof Clun.stringWidth` | `"function"` |
| `Clun.stringWidth.name` | `"stringWidth"` |
| `Clun.stringWidth.length` | `2` |
| own `name` descriptor | writable false, enumerable false, configurable true |
| own `length` descriptor | writable false, enumerable false, configurable true |
| own `prototype` property | absent |
| constructibility | not constructible |
| receiver | ignored; detached calls behave identically |

Calling `new Clun.stringWidth("x")` throws `TypeError` with message `not a constructor`. Replacing
the property by assignment is allowed because it is writable. Deleting or redefining its attributes
is not allowed because it is non-configurable.

### 3.2 Input coercion

The input algorithm is ordered exactly:

1. Read argument 0. A missing argument and explicit `undefined` return numeric `0` immediately.
2. Otherwise perform ordinary JavaScript `ToString(input)` exactly once.
3. If coercion throws, propagate the original JavaScript exception by identity and do not inspect
   `options`.
4. If the resulting string is empty, return numeric `0` without inspecting `options`.
5. Read options as specified below, then measure the string.

Representative coercions are part of the contract:

| Call | Result |
|---|---:|
| `Clun.stringWidth()` | 0 |
| `Clun.stringWidth(undefined)` | 0 |
| `Clun.stringWidth(null)` | 4 |
| `Clun.stringWidth(false)` | 5 |
| `Clun.stringWidth(123)` | 3 |

A Symbol input, including one produced by a custom coercion hook, throws `TypeError` with the exact
message `Cannot convert a symbol to a string`. There is no string normalization, case conversion,
or UTF-8 round trip.

### 3.3 Options lookup, defaults, and coercion

The option defaults are:

```js
countAnsiEscapeCodes = false
ambiguousIsNarrow = true
```

If argument 1 is not a JavaScript object, including `null`, booleans, numbers, strings, and Symbols,
it is ignored without coercion. For an object, properties are read in this exact order:

1. `countAnsiEscapeCodes`
2. `ambiguousIsNarrow`

Lookup starts at the options object and follows its prototype chain, but stops before an inherited realm
`Object.prototype`. A polluted `Object.prototype` therefore cannot alter an ordinary options object. When
`Object.prototype` is itself passed as `options`, its own properties are observable. The first found own
descriptor on the walked chain wins even when its value is `undefined`.
Inherited accessors on a custom prototype are honored and execute with the original options object
as their receiver.

For each value, `undefined`, `null`, and the empty string leave that option's current default
unchanged. Every other value receives ordinary `ToBoolean`, which does not invoke user coercion
hooks. Thus `false`, `0`, and `NaN` select false; a nonempty string such as `"false"` selects true.
Accessor exceptions propagate by identity. If the first getter throws, the second getter is not
read.

These ordering requirements are observable and mandatory:

- input coercion precedes every option access;
- an empty coerced input touches no option property;
- `countAnsiEscapeCodes` is read before `ambiguousIsNarrow`; and
- inherited `Object.prototype` pollution has no effect while direct own properties and custom inherited
  getters do.

### 3.4 Return and error boundary

The result is a JavaScript `number`, is integral, and is never negative. The implementation must
convert the Common Lisp count to the engine's Number representation rather than accidentally
returning a BigInt.

The only errors in the accepted public domain are the exact non-constructor and `ToString` errors
above plus user exceptions thrown by coercion or option access. No Common Lisp condition may escape
through the JavaScript boundary. Invalid internal table data or an impossible internal code unit is
a build/test failure, not a new public error mode.

## 4. Unicode 17.0.0 contract

### 4.1 Byte-pinned inputs

Unicode behavior is frozen to Unicode 17.0.0. Inputs live below
`vendor-data/ucd/17.0.0/`, retain the Unicode data-file license, and are pinned byte-for-byte in one
`SHA256SUMS` file.

| Vendored path | Exact upstream URL | SHA-256 | Use |
|---|---|---|---|
| `EastAsianWidth.txt` | `https://www.unicode.org/Public/17.0.0/ucd/EastAsianWidth.txt` | `ea7ce50f3444a050333448dffef1cadd9325af55cbb764b4a2280faf52170a33` | W/F/A width classes |
| `DerivedCoreProperties.txt` | `https://www.unicode.org/Public/17.0.0/ucd/DerivedCoreProperties.txt` | `24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08` | Indic Conjunct Break values |
| `auxiliary/GraphemeBreakProperty.txt` | `https://www.unicode.org/Public/17.0.0/ucd/auxiliary/GraphemeBreakProperty.txt` | `d6b51d1d2ae5c33b451b7ed994b48f1f4dc62b2272a5831e7fd418514a6bae89` | grapheme classes |
| `auxiliary/GraphemeBreakTest.txt` | `https://www.unicode.org/Public/17.0.0/ucd/auxiliary/GraphemeBreakTest.txt` | `e2d134d2c52919bace503ebb6a551c1855fe1a1faec18478c78fff254a1793ec` | complete UAX #29 boundary corpus |
| `emoji/emoji-data.txt` | `https://www.unicode.org/Public/17.0.0/ucd/emoji/emoji-data.txt` | `2cb2bb9455cda83e8481541ecf5b6dfda66a3bb89efa3fa7c5297eccf607b72b` | Emoji, modifiers, Extended_Pictographic |
| `emoji/emoji-test.txt` | `https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt` | `1d8a944f88d7952f7ef7c5167fef3c67995bcae24543949710231b03a201acda` | RGI emoji width corpus |
| `LICENSE.txt` | Unicode data-file license distributed with UCD 17.0.0 | `e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96` | redistribution terms |

The generator and corpus readers must verify these hashes before parsing. Builds and runtime
execution never contact unicode.org and never open the vendored text files.

### 4.2 Deterministic generated tables

`scripts/gen-string-width-tables.lisp` is a pure Common Lisp offline generator. It parses comments,
single code points, ranges, and property fields structurally. It rejects malformed or out-of-range
rows. It emits `src/text/unicode-width-tables.lisp` deterministically with
`+unicode-width-version+` equal to `"17.0.0"`.

The generated source contains sorted, non-overlapping, adjacency-merged flat range vectors for:

- East Asian Width `W|F` and `A`;
- GCB `CR`, `LF`, `Control`, `Extend`, `ZWJ`, `Prepend`, `Regional_Indicator`, `SpacingMark`, `L`,
  `V`, `T`, `LV`, and `LVT`;
- `Emoji`, `Emoji_Modifier`, `Emoji_Modifier_Base`, and `Extended_Pictographic`; and
- InCB `Consonant`, `Linker`, and `Extend`.

One classifier applies an explicit precedence when properties overlap: CR/LF/Control, ZWJ, emoji
modifier, emoji modifier base, InCB values, Extended_Pictographic, Prepend, Regional Indicator,
SpacingMark, Hangul classes, generic Extend, then Other. Width class and grapheme class remain
separate so the same scalar can be zero-width while still affecting a boundary state.

Range membership uses binary search. The number of tables and ranges is fixed by the Unicode pin,
so classification is constant-bounded work per scalar and the overall scan remains linear in input
length. Regeneration into a temporary file must be byte-identical to the committed output; hand
editing the generated vectors is forbidden.

### 4.3 JavaScript UTF-16 and lone surrogates

The public scanner consumes JavaScript UTF-16 semantics, independent of the host Common Lisp
implementation's character representation:

- a valid high/low surrogate pair is decoded to one scalar and advances two code units;
- a lone high or low surrogate advances one code unit, contributes width 0, and does not update
  grapheme state;
- a high surrogate followed by a non-low surrogate is skipped alone, after which the following
  unit is processed normally; and
- a native host scalar above `U+FFFF` and the equivalent UTF-16 pair have identical behavior.

Input is never normalized. Canonically equivalent strings can therefore take different internal
paths while still following the same terminal-width rules. No lossy UTF-8 or replacement-character
conversion is permitted at the public boundary.

### 4.4 Scalar width classification

Each scalar first receives a base width of 0, 1, or 2:

1. C0 `U+0000..U+001F`, DEL/C1 `U+007F..U+009F`, and the frozen invisible/combining set below have
   width 0.
2. East Asian Width W or F has width 2.
3. East Asian Width A has width 1 by default and width 2 when `ambiguousIsNarrow` is false.
4. Every other scalar has width 1.

The Bun-compatible explicit zero-width set is:

```text
U+00AD
U+0300..U+036F
U+061C, U+0600..U+0605, U+06DD, U+070F, U+08E2
U+180B..U+180F
U+1AB0..U+1AFF, U+1DC0..U+1DFF
U+200B..U+200F, U+202A..U+202E, U+2060..U+206F
U+20D0..U+20FF
U+FE00..U+FE0F, U+FE20..U+FE2F, U+FEFF
U+E0000..U+E007F, U+E0100..U+E01EF
the exact Indic/Thai/Lao combining-sign rule below
```

The exact Indic/Thai/Lao rule is also frozen. For `U+0900..U+0D4F`, let `offset = cp & 0x7F`;
width is 0 when `offset` is `00..02`, `3A..4D` except `3D`, `51..57`, or `62..63`. Thai width is
0 for `U+0E31`, `U+0E34..U+0E3A`, and `U+0E47..U+0E4E`. Lao width is 0 for `U+0EB1`,
`U+0EB4..U+0EBC`, and `U+0EC8..U+0ECD`. These rules must be exhaustively unit-tested; they are
not approximated as all characters in those scripts. Generic UCD GCB Extend classification affects
grapheme boundaries but does not by itself rewrite Bun's scalar-width rules. For example, the wide
combining kana voicing mark retains Bun's observed width behavior.

The ambiguous option is applied uniformly to all strings, including Latin-1 representable input.

### 4.5 Grapheme boundaries and cluster width

The scanner implements Unicode 17 extended grapheme boundaries from UAX #29: start/end boundaries,
GB3, GB4/GB5, Hangul GB6-GB8, GB9, GB9a, GB9b, Indic GB9c, emoji ZWJ GB11, regional-indicator
GB12/GB13, and GB999. CR, LF, and Control terminate the pending cluster in the outer scanner. A
bounded state machine carries only the current class plus RI, Extended_Pictographic, and InCB
context; it never buffers the cluster's text.

Default non-emoji cluster width is the sum of its constituent scalar widths, matching the pinned
Bun behavior. The following overrides apply:

- a regional-indicator pair is width 2; a lone regional indicator is width 1;
- a keycap sequence is width 2;
- an emoji modifier-base plus skin-tone modifier is width 2;
- an Extended_Pictographic `Extend* ZWJ` sequence, including a family emoji, is width 2;
- VS15 requests text presentation and produces width 1 unless the base is unambiguously wide;
- VS16 requests emoji presentation and produces width 2 for a non-ASCII eligible base;
- a bare ASCII digit, `#`, or `*` plus VS16 remains width 1 unless the keycap mark is present; and
- ANSI sequences stripped by the option are transparent to boundary state, so styling inserted
  between a base and combining mark or inside a ZWJ/flag sequence cannot split the cluster.

The pinned UTF-16 implementation's ASCII bulk path starts a new width component before an ASCII scalar,
even when UAX #29 keeps it joined after GCB `Prepend`. Clun reproduces that width-only boundary while
preserving the Unicode boundary state. This handles zero- and nonzero-width Prepend prefixes exactly:
`0600 A FE0F` is width 1 and `0890 A FE0E` is width 2, while non-ASCII
`0890 4E2D FE0E` stays in the original component and is width 1. A following non-ASCII scalar is not
promoted into the ordinary emoji-modifier-base override, so `0890 1F469 1F3FB` remains width 5. A lone
VS15 remains width 0, while a zero-width base followed by VS15 is width 1. Presentation state matches
Bun's two independent flags: a selector that begins a width component is ignored, and an added VS16
takes precedence over an added VS15 regardless of order. The explicit Phase 33 correctness disposition
still takes precedence for zero-width-only clusters whose final selector is VS16: those remain width 0.

Unicode 17 classifies `Emoji_Modifier` as GCB Extend, so the boundary conformance layer applies GB9
even when the modifier is malformed or not adjacent to a modifier base. Bun 1.3.14 starts a new
*width component* before such a modifier unless the immediately preceding class is
`Emoji_Modifier_Base`. Clun preserves the Unicode grapheme boundary and reproduces that bounded
width-only split. Consequently an intervening variation selector, combining mark, or ZWJ prevents
the modifier-pair width override, and every non-adjacent skin-tone modifier contributes width 2.
The split does not occur directly after GCB `Prepend`, matching the pinned presentation behavior.
This distinction is exercised independently by the Unicode boundary corpus and shipped width
vectors.

Every row in Unicode 17's `GraphemeBreakTest.txt` must pass at the core boundary layer. Every
fully-qualified sequence in Unicode 17's `emoji-test.txt` must have width 2. The file's separate
component rows must be reviewed and assigned explicit expected widths rather than silently
excluded. The UCD pin also takes precedence over Bun's carried boundary table for `U+E0001`:
`0890 E0001 20E3` is width 3 because the Unicode 17 Control boundary ends the Prepend component.

## 5. ANSI scanning contract

ANSI handling is one state machine integrated into the same forward scan. When
`countAnsiEscapeCodes` is false, only these forms receive special treatment:

### 5.1 CSI

`ESC [` begins CSI. Consume from the introducer through the first ASCII final byte in
`U+0040..U+007E`, inclusive. If a non-ASCII scalar occurs first, consume it as an abnormal
terminator, matching the pinned UTF-16 behavior. If no terminator exists, consume the remainder of
the input. Parameters are not interpreted.

This deliberately broad final-byte grammar covers SGR, cursor, erase, scroll, device-status, and
private-mode sequences without maintaining a command whitelist.

### 5.2 OSC

`ESC ]` begins OSC. Consume through the first of:

- BEL (`U+0007`);
- C1 ST (`U+009C`); or
- the two-code-unit ST sequence `ESC \`.

A lone ESC inside OSC is skipped and scanning for a terminator continues. If no terminator exists,
the rest of the input is consumed as OSC payload. OSC 8 hyperlinks and title-setting sequences use
the same rule; payload contents are never interpreted.

### 5.3 Bare and malformed escapes

A bare ESC or ESC followed by anything other than `[` or `]` drops only the ESC. The following
character is processed normally and can itself begin another escape sequence. C1 CSI, DCS,
SOS/PM/APC, and other terminal protocols are not recognized by this phase.

Malformed behavior is fixed, not merely required to avoid a crash. For example, in
`ESC [ 3 1 ; ESC [ 3 2 m`, the second `[` is the final byte of the first CSI; `32m` remains visible
and has width 3. Unterminated CSI/OSC consumes the remainder. These cases must have exact fixtures.

### 5.4 Count semantics

When `countAnsiEscapeCodes` is true, CSI/OSC recognition is disabled. Every code unit flows through
normal Unicode/grapheme measurement. ESC, BEL, and C1 controls still have width 0 because they are
controls; printable introducer, parameter, payload, and final characters contribute normally.
Consequently:

```js
Clun.stringWidth("\x1b[31mred\x1b[0m") // 3
Clun.stringWidth("\x1b[31mred\x1b[0m", { countAnsiEscapeCodes: true }) // 10
```

The option means "do not strip escape sequences", not "assign width 1 to the ESC control byte".

## 6. Complexity and resource bounds

For `n` input UTF-16 code units, the public operation must satisfy:

- one monotonically increasing input index;
- `O(n)` time for the fixed Unicode 17 tables;
- `O(1)` auxiliary scanner state, excluding the already-existing input string and immutable tables;
- no substring, stripped-string, codepoint-array, or grapheme-array proportional to input;
- no recursion or rescanning of ANSI payloads; and
- no runtime filesystem, network, subprocess, locale, or terminal access.

There is no Phase-33-specific low length cap that would reject input accepted by the JavaScript
engine. Width accumulation must remain exact for every allocatable Clun string and must be safely
converted to Number. At minimum the executable stress gate covers one-million-code-unit ASCII,
combining, dense CSI, counted-CSI, unterminated OSC, bare-ESC, and malformed-CSI inputs. Adversarial
review must confirm that escape-heavy input cannot cause quadratic time and that a single enormous
grapheme does not allocate proportional temporary storage.

Performance results may be recorded only from a committed same-host workload that identifies the
Clun and Bun commits, executable targets, host, warmup, repetitions, statistic, and exact input.
No `faster than Bun`, parity, SIMD, or throughput claim is permitted without that evidence. Runtime
performance is not a prerequisite for a truthful functional `Yes`; linear bounded behavior is.

## 7. Pure Common Lisp architecture

The implementation has three ownership layers:

1. `src/text/unicode-width-tables.lisp` is deterministic generated data only.
2. `src/text/string-width.lisp` owns UTF-16 decoding, scalar classification, UAX #29 state,
   cluster width, and ANSI scanning. It has no JavaScript-object dependency.
3. `src/runtime/clun-string-width.lisp` owns descriptors, JavaScript coercion, mitigated options
   lookup, exception propagation, and Number conversion.

`clun.asd` and package definitions load the generated data before the core scanner and the core
scanner before the runtime bridge. `src/runtime/clun-global.lisp` calls the installer once per
realm.

Implementation and generation are pure Common Lisp. There is no CFFI, ICU/native library, embedded
implementation JavaScript/TypeScript, implementation shell-out, or runtime dependency on Node,
Bun, Deno, npm `string-width`, `wcwidth`, or the host libc. JavaScript is allowed only as executable
public fixtures. Upstream code is inspected read-only and is not copied; only independently stated
behavioral facts and Unicode data under its own license enter the repository.

## 8. Evidence and ledger transition

The evidence stack is cumulative:

1. Focused Common Lisp tests cover every scalar class, table boundary, UTF-16 pair/lone-surrogate
   case, grapheme rule/state transition, emoji override, and ANSI state transition.
2. Unicode corpus tests validate every Unicode 17 GraphemeBreakTest row and the reviewed Unicode 17
   emoji sequence expectations.
3. Runtime tests execute in a real Clun realm and pin descriptors, detached/non-constructor calls,
   coercion, getter receiver/order, short circuits, prototype-pollution mitigation, errors, and
   Number results.
4. `tests/compat/text.string-width/basic.js` pins public shape and coercion; `corpus.js` pins stable
   Bun outcomes plus explicitly labeled engineering/correctness improvements; `stress.js` pins
   million-unit results and bounded malformed-ANSI behavior. Expected stdout is byte-exact.
5. Compatibility CI runs the shipped `build/clun`, not an internal Lisp helper, on `linux-x64`,
   `linux-arm64`, `darwin-x64`, and `darwin-arm64`, producing receipts tied to the exact candidate
   commit.

The exact feature selector is:

```sh
make compat FEATURE=text.string-width
```

`FEATURE=string-width` is not a ledger ID and must be corrected in `PLAN.md` and issue #7's generated
technical contract.

The ledger changes atomically only after the evidence is green:

| Field | Before | Candidate after evidence |
|---|---|---|
| `clun_state` | `No` | `Yes` |
| `clun_detail` | `-` | `` `Clun.stringWidth` `` |
| `gap` | terminal display-width measurement absent | `-` |
| four platform states | `unsupported` | `supported` |
| target evidence | `-` | target-scoped shipped-binary evidence IDs |

Static source traces and a passing Linux development machine cannot establish a four-target `Yes`.
The public README, site, and release notes are generated from the candidate ledger in the same unit;
none may independently claim support early.

## 9. SemVer, synchronization, and publication

Adding a public API and changing a ledger row from `No` to `Yes` is SemVer `minor`. In the current
`0.1.0-dev.N` train this means the next unused prerelease after the latest published release; the
exact `dev.N` and immutable tag are assigned from live release state on issue #7, not hard-coded in
this design. The ASDF core remains `0.1.0` while the project is in the `0.1.0` prerelease train.

The release-bearing implementation unit synchronizes:

- `src/version.lisp`, version assertions, installer default, and `compat/release.tsv`;
- `compat/features.tsv`, `compat/evidence.tsv`, `compat/platforms.tsv`, and corrected references;
- generated `README.md`, `site/index.html`, and `docs/releases/current.md`;
- `PLAN.md`, `STATE.md`, `DECISIONS.md`, this design, and issue #7.

Publication follows `docs/versioning.md`: issue-first branch, PR to `master`, exact transition gate,
squash merge, immutable tag on the merge commit, four native archives and checksums, published
ledger reconciliation, Pages deployment, `https://clun.sh/install` smoke, and issue evidence. A
candidate `Yes` in a PR is not described as a published release.

## 10. Acceptance gates

Phase 33 is complete only when all of these are true:

1. `make compat FEATURE=text.string-width` passes all public, corpus, malformed-ANSI, and stress
   fixtures through the shipped binary.
2. The Unicode input checksum check passes, deterministic table regeneration is byte-identical,
   every Unicode 17 grapheme-break row passes, and the emoji corpus reconciles with no silent skip.
3. The exact stable-versus-engineering divergence matrix in section 2.1 is executable and issue #7
   records each disposition.
4. `make build`, `make test`, and `make purity` pass.
5. `make docs-check`, `make public-claims-check`, and the live roadmap verification pass after the
   corrected feature ID/reference path and synchronized public claim.
6. `BASE_SHA=<phase-base> HEAD_SHA=<candidate> make version-transition-check` accepts this exact
   release unit as `minor` and matches issue #7.
7. Compatibility CI produces successful exact-commit shipped-binary receipts for `linux-x64`,
   `linux-arm64`, `darwin-x64`, and `darwin-arm64`.
8. Independent review confirms the JS descriptor/coercion contract, Unicode pin and license,
   UAX/emoji correctness, malformed-ANSI semantics, linear bounded execution, pure-CL constraint,
   and absence of public overclaims.
9. The immutable release assets, Pages deployment, hosted installer smoke, ledger, README, site,
   release notes, `STATE.md`, and issue #7 all identify the same published version and commit before
   the issue closes.

## 11. Explicit nonclaims

Phase 33 does not claim or add:

- a `Bun` global or `bun` module compatibility layer;
- `Clun.stripANSI`, `sliceAnsi`, `wrapAnsi`, or any other public ANSI utility;
- public codepoint-width, grapheme-break, emoji-classification, or UTF-8 helper APIs;
- npm `string-width` package/import compatibility;
- byte-for-byte reproduction of known stable bugs or backing-store-dependent answers;
- a universal `wcwidth` answer for every terminal, font, locale, or CJK environment;
- terminal cursor emulation or support for every ECMA-48 control string;
- Windows release support; or
- a performance advantage over Bun, Node, Deno, or npm.

The truthful public claim after all gates is narrow: Clun ships `Clun.stringWidth` with the frozen
Bun-shaped JavaScript contract, Unicode 17 grapheme/emoji and East Asian width handling, the defined
CSI/OSC behavior, portable pure-Common-Lisp execution, and four-target shipped-binary evidence.
