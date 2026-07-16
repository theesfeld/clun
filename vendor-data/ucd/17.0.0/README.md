# Unicode Character Database 17.0.0

This directory contains the Unicode 17.0.0 inputs used to generate Clun's
terminal-width tables. The files are immutable upstream data from
`https://www.unicode.org/Public/17.0.0/ucd/`; `LICENSE.txt` contains the Unicode
data-file license.

`SHA256SUMS` pins all seven inputs byte-for-byte, including the complete UAX
#29 boundary corpus and Unicode 17 RGI emoji corpus. Verify the import from
this directory with:

```sh
sha256sum -c SHA256SUMS
```

The runtime never opens these files. `scripts/gen-string-width-tables.lisp`
verifies every manifest entry before parsing any property data, then emits the
compact, committed `src/text/unicode-width-tables.lisp` source file. Tests also
verify the corpus hashes before executing their rows.
