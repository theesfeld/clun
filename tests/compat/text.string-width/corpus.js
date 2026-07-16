// Frozen terminal-column vectors from Bun 1.3.14 plus the exact, documented
// engineering/correctness dispositions in docs/design/phase-33.md section 2.1.
const cases = [
  ["empty", "", undefined, 0],
  ["ascii", "hello", undefined, 5],
  ["spaces", "  a  ", undefined, 5],
  ["c0", "\x00\x07\x1f", undefined, 0],
  ["c1", "\x7f\x80\x85\x9f", undefined, 0],
  ["controls-between", "a\tb\nc\rd", undefined, 4],
  ["soft-hyphen", "co\u00adoperate", undefined, 9],
  ["word-joiner", "a\u2060b", undefined, 2],
  ["zero-width-space", "a\u200bb", undefined, 2],
  ["zero-width-non-joiner", "a\u200cb", undefined, 2],
  ["zero-width-joiner", "a\u200db", undefined, 2],
  ["direction-marks", "a\u200eb\u200fc", undefined, 3],
  ["bidi-controls", "\u202eabc\u202c", undefined, 3],
  ["bidi-isolates", "\u2066abc\u2069", undefined, 3],
  ["arabic-letter-mark", "\u061cab", undefined, 2],
  ["mongolian-selectors", "\u180b\u180c\u180d\u180e\u180f", undefined, 0],
  ["bom", "\ufeffhello", undefined, 5],
  // Stable Bun returns 2; the engineering pin correctly preserves zero width.
  ["variation-alone", "\ufe00\ufe0e\ufe0f", undefined, 0],
  ["text-variation-alone", "\ufe0e", undefined, 0],
  ["leading-vs15-combining-ascii", "\ufe0e\u0300A", undefined, 1],
  ["leading-vs15-zwj-ascii", "\ufe0e\u200dA", undefined, 1],
  ["combining-text-presentation", "\u0300\ufe0e", undefined, 1],
  ["prepend-text-presentation", "\u0600\ufe0e", undefined, 1],
  ["prepend-ascii-vs16", "\u0600A\ufe0f", undefined, 1],
  ["prepend-digit-vs16", "\u06001\ufe0f", undefined, 1],
  ["multiple-prepend-ascii-vs16", "\u0600\u0600A\ufe0f", undefined, 1],
  ["prepend-skin-vs15", "\u0600\ud83c\udffb\ufe0e", undefined, 1],
  ["nonzero-prepend-ascii-vs15", "\u0890A\ufe0e", undefined, 2],
  ["nonzero-prepend-ascii-vs16", "\u0890A\ufe0f", undefined, 2],
  ["nonzero-prepend-cjk-vs15", "\u0890\u4e2d\ufe0e", undefined, 1],
  ["nonzero-prepend-skin", "\u0890\ud83c\udffb", undefined, 3],
  ["nonzero-prepend-skin-vs15", "\u0890\ud83c\udffb\ufe0e", undefined, 1],
  ["nonzero-prepend-skin-vs16", "\u0890\ud83c\udffb\ufe0f", undefined, 2],
  ["nonzero-prepend-skin-keycap", "\u0890\ud83c\udffb\u20e3", undefined, 2],
  ["nonzero-prepend-digit-keycap", "\u08901\ufe0f\u20e3", undefined, 3],
  ["nonzero-prepend-ascii-keycap-mark", "\u0890A\u20e3", undefined, 3],
  ["zero-prepend-digit-keycap", "\u06001\ufe0f\u20e3", undefined, 2],
  ["zero-prepend-ascii-keycap-mark", "\u0600A\u20e3", undefined, 2],
  // Bun's carried table misses Unicode 17's GCB Control class for U+E0001.
  ["unicode17-language-tag-control", "\u0890\udb40\udc01\u20e3", undefined, 3],
  ["nonzero-prepend-modifier-pair", "\u0890\ud83d\udc69\ud83c\udffb", undefined, 5],
  ["combining-alone", "\u0300\u0301\u036f", undefined, 0],
  ["combining-base", "e\u0301", undefined, 1],
  ["combining-extended", "x\u1ab0", undefined, 1],
  ["combining-supplement", "x\u1dc0", undefined, 1],
  ["combining-symbol", "x\u20d0", undefined, 1],
  ["combining-half", "x\ufe20", undefined, 1],
  ["lone-high-surrogate", "\ud800", undefined, 0],
  ["lone-low-surrogate", "\udfff", undefined, 0],
  ["cjk", "\u4e2d\u6587", undefined, 4],
  ["hiragana", "\u3053\u3093\u306b\u3061\u306f", undefined, 10],
  ["hangul", "\uc548\ub155\ud558\uc138\uc694", undefined, 10],
  ["fullwidth", "\uff21\uff22\uff23\uff01", undefined, 8],
  ["halfwidth-katakana", "\uff71\uff72\uff73", undefined, 3],
  ["halfwidth-voiced", "\uff8a\uff9e", undefined, 2],
  ["mixed-wide", "hello\u4e16\u754c", undefined, 9],
  ["emoji", "\ud83d\ude00", undefined, 2],
  ["emoji-run", "\ud83d\ude00\ud83c\udf89", undefined, 4],
  ["skin-tone", "\ud83d\udc4d\ud83c\udffd", undefined, 2],
  ["ri-skin-tail", "\ud83c\udde6\ud83c\udffb", undefined, 3],
  ["ri-pair-skin-tail", "\ud83c\udde6\ud83c\udde7\ud83c\udffb", undefined, 4],
  ["skin-tone-pair", "\ud83c\udffb\ud83c\udffc", undefined, 4],
  ["modifier-double", "\ud83d\udc69\ud83c\udffb\ud83c\udffc", undefined, 4],
  ["modifier-after-extend", "\ud83d\udc69\u0300\ud83c\udffb", undefined, 4],
  ["non-modifier-base-skin", "\ud83d\udcbb\ud83c\udffb", undefined, 4],
  ["family-zwj", "\ud83d\udc68\u200d\ud83d\udc69\u200d\ud83d\udc67\u200d\ud83d\udc66", undefined, 2],
  ["technologist-zwj", "\ud83d\udc69\u200d\ud83d\udcbb", undefined, 2],
  ["zwj-invalid-modifier-tail", "\ud83d\udc69\u200d\ud83d\udcbb\ud83c\udffb", undefined, 4],
  ["zwj-valid-modifier-tail", "\ud83d\udcbb\u200d\ud83d\udc69\ud83c\udffb", undefined, 2],
  ["flag-pair", "\ud83c\uddfa\ud83c\uddf8", undefined, 2],
  ["single-regional", "\ud83c\udde6", undefined, 1],
  ["keycap", "1\ufe0f\u20e3", undefined, 2],
  ["keycap-mark-alone", "\u20e3", undefined, 2],
  ["keycap-mark-skin-tail", "\u20e3\ud83c\udffb", undefined, 4],
  ["text-presentation", "\u2600\ufe0e", undefined, 1],
  ["emoji-presentation", "\u2600\ufe0f", undefined, 2],
  ["digit-vs16", "0\ufe0f", undefined, 1],
  ["copyright-vs16", "\u00a9\ufe0f", undefined, 2],
  ["copyright-vs15", "\u00a9\ufe0e", undefined, 1],
  ["copyright-vs16-vs15", "\u00a9\ufe0f\ufe0e", undefined, 2],
  ["sun-vs16-vs15", "\u2600\ufe0f\ufe0e", undefined, 2],
  ["devanagari", "\u0915\u094d", undefined, 1],
  ["thai", "\u0e1b\u0e0f\u0e31\u0e01", undefined, 3],
  ["ansi-sgr", "a\x1b[31mb\x1b[0mc", undefined, 3],
  ["ansi-cursor", "a\x1b[10;20Hb", undefined, 2],
  ["ansi-truecolor", "\x1b[38;2;255;0;0mX\x1b[39m", undefined, 1],
  ["osc-bel", "a\x1b]0;title\x07b", undefined, 2],
  ["osc-st", "a\x1b]0;title\x1b\\b", undefined, 2],
  ["osc-c1-st", "a\x1b]0;title\x9cb", undefined, 2],
  ["osc-unterminated", "abc\x1b]0;title", undefined, 3],
  ["csi-unterminated", "abc\x1b[31", undefined, 3],
  ["bare-escape", "a\x1bZb", undefined, 3],
  ["malformed-csi", "\x1b[31;\x1b[32m", undefined, 3],
  ["ansi-counted", "\x1b[31mred\x1b[0m", { countAnsiEscapeCodes: true }, 10],
  ["ansi-explicit-strip", "\x1b[31mred\x1b[0m", { countAnsiEscapeCodes: false }, 3],
  ["ambiguous-default", "\u2605\u2606", undefined, 2],
  ["ambiguous-narrow", "\u2605\u2606", { ambiguousIsNarrow: true }, 2],
  ["ambiguous-wide", "\u2605\u2606", { ambiguousIsNarrow: false }, 4],
  ["greek-default", "\u03b1\u03b2\u03b3", undefined, 3],
  ["greek-wide", "\u03b1\u03b2\u03b3", { ambiguousIsNarrow: false }, 6],
  ["mixed-options", "\x1b[31m\u2605\x1b[0m", { countAnsiEscapeCodes: true, ambiguousIsNarrow: false }, 9],
];

let passed = 0;
const failures = [];
for (const row of cases) {
  const label = row[0];
  const input = row[1];
  const options = row[2];
  const expected = row[3];
  const actual = options === undefined
    ? Clun.stringWidth(input)
    : Clun.stringWidth(input, options);
  if (actual !== expected) {
    failures.push(label + ": expected " + expected + ", got " + actual);
  } else {
    passed++;
  }
}

if (failures.length > 0) {
  throw new Error(failures.join("; "));
}

console.log("string-width corpus passed", passed, "cases");
