#!/bin/sh
# gen-registry-fixture.sh — build the hand-made npm-registry tarball fixtures (Phase 21).
# Each .tgz is a gzipped ustar tar of a `package/` dir (package.json + a file). The local
# registry fixture server computes dist.integrity (sha512) + dist.tarball from these bytes at
# startup, so the tarballs need only be checked in — like the gzip fixture / test CA, this is a
# build-time tool (tar + gzip), never a runtime dep. Re-run: `sh scripts/gen-registry-fixture.sh`.
set -eu
cd "$(dirname "$0")/../tests/fixtures/registry/tarballs"
build() { # name version dependencies-json extra-fields
  name="$1"; ver="$2"; deps="${3:-{}}"; extra="${4:-}"
  d=$(mktemp -d); mkdir -p "$d/package"
  printf '{"name":"%s","version":"%s","dependencies":%s%s}\n' "$name" "$ver" "$deps" "$extra" > "$d/package/package.json"
  printf 'module.exports = "%s@%s";\n' "$name" "$ver" > "$d/package/index.js"
  # deterministic-ish: gzip -n (no timestamp); tar with sorted, fixed mtime for stable-ish bytes
  fn=$(printf '%s-%s.tgz' "$(echo "$name" | sed 's|/|-|g;s|@||')" "$ver")
  ( cd "$d" && tar --sort=name --mtime='2020-01-01 00:00:00' -cf - package 2>/dev/null || (cd "$d" && tar -cf - package) ) | gzip -n > "$fn"
  rm -rf "$d"; echo "  $fn"
}
echo "building registry tarball fixtures:"
build "left-pad" "1.0.0"
build "left-pad" "1.1.0"
build "left-pad" "1.3.0"
build "@scope/widget" "1.0.0" '{"left-pad":"^1.1.0"}'
build "hasbin" "2.0.0" '{}' ',"bin":{"hasbin":"index.js"}'
build "conflict-a" "1.0.0" '{"shared":"1.0.0"}'
build "conflict-b" "1.0.0" '{"shared":"2.0.0"}'
build "shared" "1.0.0"
build "shared" "2.0.0"

# pax-longname: an entry whose path exceeds ustar's 100-byte name field, forcing a pax/GNU
# longname extended header. Phase 21 just verifies its integrity like any other tarball; the
# hardened ustar/pax READER that must handle this entry is Phase 22.
build_longname() { # name version
  name="$1"; ver="$2"
  d=$(mktemp -d); mkdir -p "$d/package/lib"
  printf '{"name":"%s","version":"%s","dependencies":{}}\n' "$name" "$ver" > "$d/package/package.json"
  long="this-is-a-deliberately-long-file-name-that-exceeds-the-ustar-one-hundred-byte-name-field-limit-to-force-a-pax-or-gnu-longname-extended-header.js"
  printf 'module.exports = "%s@%s";\n' "$name" "$ver" > "$d/package/lib/$long"
  fn=$(printf '%s-%s.tgz' "$(echo "$name" | sed 's|/|-|g;s|@||')" "$ver")
  ( cd "$d" && tar --sort=name --mtime='2020-01-01 00:00:00' -cf - package 2>/dev/null || (cd "$d" && tar -cf - package) ) | gzip -n > "$fn"
  rm -rf "$d"; echo "  $fn (pax-longname)"
}
build_longname "longname-pkg" "1.0.0"
echo "done: $(ls *.tgz | wc -l) tarballs"
