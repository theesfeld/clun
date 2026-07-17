<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.13

Phase 34: CSS Color API.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 6 Yes / 6 Partial / 18 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->

## Highlights

- Adds `Clun.color` parsing for named, hex, RGB, HSL, HWB, Lab, LCH, OKLab, OKLCH, and `color()` inputs.
- Converts and serializes CSS, packed numeric, tuple, object, hexadecimal, ANSI-256, and true-color output
  with bounded input handling and observable option-access order.
- Executes exhaustive named-color, alpha, color-space, round-trip, terminal-palette, hostile-bound, and
  pinned Bun differential evidence through the shipped binary on every release target.
