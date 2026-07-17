# Phase 34 - CSS Color API

Status: accepted for implementation after source, documentation, type, and executable inventory.

## Objective

Convert `web.css-color` from `No` to an evidence-backed `Yes` with a pure Common Lisp
`Clun.color(input, format?)` implementation. The phase includes Bun's public input forms, modern CSS
Color syntax, color-space conversion, every documented output form, terminal palettes, JavaScript
coercion and descriptor behavior, and bounded failure handling. The capability is exercised through the
shipped `build/clun` binary on every release target before the ledger changes.

This phase does not create a `Bun` global, a `bun` module alias, a CSS bundler, or a macro system.

## Provenance

| Role | Revision | Paths |
| --- | --- | --- |
| Stable executable | Bun `1.3.14+0d9b296af` | pinned linux-x64 asset SHA-256 `a063908ae08b7852ca10939bbdc6ceed3ddabce8fb9402dce83d65d73b36e6c7` |
| Stable source | Bun `1.3.14`, `0d9b296af33f2b851fcbf4df3e9ec89751734ba4` | color docs, types, CSS color parser/printer, runtime bridge, color tests and snapshots |
| Engineering source | Bun `1.4.0-dev`, `c1076ce95effb909bfe9f596919b5dba5567d550` | `docs/runtime/color.mdx`, `packages/bun-types/bun.d.ts`, `src/css/values/color.rs`, `src/css/values/color_generated.rs`, `src/css_jsc/color_js.rs`, `test/js/bun/css/color.test.ts` |
| Standards | CSS Color 4 and CSS Color 5 | named colors, modern functional syntax, D50/D65 adaptation, predefined spaces, powerless components |
| Terminal mapping | tmux color algorithm | RGB to xterm-256 cube/grey selection and 256-to-16 table |

Stable executable observations freeze the public baseline. The engineering revision is authoritative for
later fixes already represented by the repository's phase contract, including valid 16-color SGR output,
near-black palette arithmetic, opaque 24-bit numeric input, percentage-scaled `hsl`/`lab` output, and
boundary gamut clipping. Those corrections are required behavior rather than stable bugs to reproduce.

## Public Surface

```js
Clun.color(input, format?) // function name "color", length 2
```

`Clun.color` is writable and enumerable but non-configurable. It is callable, detached calls work, and it
is not constructible. The format defaults to `css` when absent, `undefined`, or `null`.

Canonical formats and accepted aliases are:

| Result | Canonical | Aliases |
| --- | --- | --- |
| automatic ANSI | `ansi` | - |
| 16 colors | `ansi-16` | `ansi_16` |
| 256 colors | `ansi-256` | `ansi_256`, `ansi256` |
| true color | `ansi-16m` | `ansi_16m`, `ansi-24bit`, `ansi-truecolor` |
| CSS | `css` | - |
| lowercase hex | `hex` | - |
| uppercase hex | `HEX` | - |
| HSL string | `hsl` | - |
| Lab string | `lab` | - |
| packed RGB number | `number` | - |
| RGB strings | `rgb`, `rgba` | - |
| channel arrays | `[rgb]`, `[rgba]` | `[r,g,b,a]` for RGBA |
| channel objects | `{rgb}`, `{rgba}` | `{r,g,b}` for RGB |

The format argument must be a primitive string when non-nullish. Unknown spellings and other types throw
an `ERR_INVALID_ARG_TYPE` TypeError before input parsing or property access.

## Input Contract

### Numbers

Numbers use `ToInt64`, then the low 32 bits. The low three bytes are `0xRRGGBB`. Values whose low unsigned
32-bit value is no wider than 24 bits are opaque; wider values use the high byte as alpha. Negative and
out-of-range values therefore wrap through the low 32 bits exactly as Bun does. NaN and infinities follow
the engine's integer conversion and produce black rather than initiating string parsing.

### Arrays And Typed Arrays

Array-like color input must have length exactly 3 or 4. Channels are read in ascending index order and each
must already be a Number. Values are integer-converted and clamped to `[0, 255]`. A fourth array channel is
an 8-bit alpha value. Abrupt length or indexed access propagates and stops later reads. Other lengths throw.

The selected public contract supports ordinary arrays plus the numeric typed arrays already implemented by
Clun. It does not treat arbitrary objects with a numeric `length` as arrays.

### RGB Objects

Other JavaScript objects are RGB records. `r`, `g`, and `b` are read once in that order through ordinary
property lookup and must be Numbers; missing channels fail as invalid integer input. `a` is read last. A
numeric `a` is multiplied by 255 and integer-converted to the low byte; zero and NaN therefore produce a
zero alpha byte, while absent, nullish, false, or otherwise nonnumeric alpha selects opaque. Getter failures
propagate without reading later properties. Proxies use normal proxy internal methods once Phase 32 is present.

### Strings And String-Like Values

Every remaining input receives ordinary `ToString`; Symbol conversion throws. The parser trims CSS
whitespace, consumes exactly one color value, and rejects trailing non-whitespace. Invalid color strings
return JavaScript `null`, never a partial parse or parser-specific error.

The complete selected grammar includes:

- all CSS named colors, case-insensitively, including aliases and `transparent`;
- 3, 4, 6, and 8 digit hexadecimal colors;
- legacy comma and modern space/slash `rgb()` and `rgba()`, including percentages and clamping;
- legacy comma and modern space/slash `hsl()` and `hsla()`, angle units, hue wrapping, and percentages;
- `hwb()`, `lab()`, `lch()`, `oklab()`, and `oklch()`, including alpha and `none` where CSS permits it;
- `color()` for `srgb`, `srgb-linear`, `display-p3`, `a98-rgb`, `prophoto-rgb`, `rec2020`, `xyz`,
  `xyz-d50`, and `xyz-d65`;
- alpha as a number or percentage with CSS clamping.

Variables, `currentColor`, system colors, URL values, declarations, gradients, `calc()`, `var()`, `attr()`,
relative colors, `color-mix()`, and multiple tokens are not concrete single-color inputs and return `null`.
The parser caps string input at 1,048,576 UTF-16 code units and nesting at 32 before tokenization.

## Internal Representation And Conversion

The engine-independent package `clun.color` owns parsing and conversion. Concrete colors carry four
double-float channels in a declared color space; alpha is `[0,1]`. Missing/powerless components are retained
as a marker until concrete conversion and become zero outside interpolation.

Conversion uses the CSS Color reference pipeline:

1. decode transfer functions into linear-light components;
2. multiply by the source RGB-to-XYZ matrix;
3. adapt D50/D65 through the Bradford matrix when required;
4. convert XYZ to the destination space;
5. convert to nonlinear sRGB for byte-oriented outputs;
6. clip boundary values and round channel bytes to nearest, with half values away from negative infinity
   as observed in Bun's byte conversion.

The implementation includes sRGB, linear sRGB, Display P3, A98 RGB, ProPhoto RGB, Rec.2020, XYZ D50/D65,
CIE Lab/LCH, OKLab/OKLCH, HSL, and HWB conversions. Matrix constants are fixed double-float literals and
tests cover published CSS Color examples, white/black points, primaries, gamut boundaries, and round trips.
No native library, subprocess, network call, or JavaScript implementation is used.

## Output Contract

Byte outputs convert through clipped sRGB. `number` is `(r << 16) | (g << 8) | b` and discards alpha.
`hex`/`HEX` always produce six digits and discard alpha. `rgb` always emits `rgb(r, g, b)`; `rgba` always
emits `rgba(r, g, b, a)`. `{rgb}` and `{rgba}` create ordinary own enumerable properties in `r`, `g`, `b`,
`a` order. `[rgb]` and `[rgba]` create ordinary arrays; array alpha is the byte while object alpha is `[0,1]`.

`hsl` emits `hsl(h, s%, l%)`; `lab` emits `lab(l% a b)`. Concrete missing components print as zero. Bun's
bridge exposes single-precision conversion components here; Clun deliberately retains its pure converter's
double precision and records the resulting last-place spelling differences as an accuracy improvement in
the differential evidence. Byte-derived `rgba` alpha strings and `{rgba}.a` retain Bun's exact f32 boundary.
Numeric formatting emits a finite round-trippable decimal, normalizes `-0` to `0`, and never leaks a Common
Lisp exponent marker.

`css` preserves modern wide-gamut/Lab space when it is the compact valid representation and otherwise emits
Bun-compatible compact CSS: shortest named spelling or compressible hex for opaque sRGB, and compact
hex-alpha or functional output for translucent colors. A deterministic table resolves equal-length aliases.
Every CSS result reparses to the same concrete color within the documented numeric tolerance.

## ANSI Contract

`ansi-16m` emits `ESC[38;2;r;g;bm`. `ansi-256` uses the tmux 6-cube/grey algorithm and always emits a palette
index in `[0,255]`. `ansi-16` maps through Bun's frozen 256-to-16 table and emits only `ESC[30m` through
`ESC[37m` or `ESC[90m` through `ESC[97m`; the stable control-character bug is not reproduced.

`ansi` resolves once per call using the runtime environment. `NO_COLOR` or `TERM=dumb` produces an empty
string; `FORCE_COLOR=0` disables output; `FORCE_COLOR=1/2/3` selects 16/256/16m; truecolor `COLORTERM` or
tmux selects 16m; a 256-color TERM selects 256; otherwise a TTY selects 16 and a non-TTY selects none.
Explicit ANSI formats ignore terminal capability. Invalid input still returns `null` rather than the empty
string, so parsing precedes automatic-depth early return.

## Bounds And Failure Discipline

- input strings are capped before parser allocation;
- scanning is linear and every token cursor advances or terminates;
- functional color arity is fixed and no attacker-controlled recursive AST is built;
- named lookup is bounded by a static hash table;
- output allocation has a fixed small upper bound except CSS spelling, which is still constant-size;
- NaN and infinities produced inside a color conversion are rejected or mapped through the specified
  powerless-component rule, never printed;
- no condition escapes as a Common Lisp debugger entry from the public runtime.

## Evidence And Promotion Gate

The registered shipped-binary fixtures under `tests/compat/web.css-color` and `tests/js/color` cover
descriptors, coercion order, all input and output families, named colors, format aliases, stable and
engineering regressions, invalid input, ANSI shape/range, published CSS vectors, round trips, gamut edges,
and bounded stress. Evidence is registered in `compat/evidence.tsv` only after it executes successfully.

Promotion to `Yes` requires all of the following:

- the pinned Bun public corpus passes, with deliberate engineering corrections identified by fixture ID;
- all named colors and every declared color space pass deterministic vectors;
- RGB/HSL/Lab/OKLab/XYZ round-trip and gamut-edge properties stay within documented tolerances;
- a million-code-unit invalid input and a large repeated-call stress case remain linear and bounded;
- the shipped binary passes the compatibility fixture on the local target;
- `make build`, focused Lisp/runtime tests, `make compat FEATURE=web.css-color`, `make purity`,
  `make docs-check`, `make public-claims-check`, and `make roadmap-check` pass;
- four release targets attach valid evidence to one immutable release;
- the canonical issue, README, generated site, ledger, release metadata, PLAN, and STATE agree atomically.

Until every gate is satisfied, `web.css-color` remains `No` publicly.
