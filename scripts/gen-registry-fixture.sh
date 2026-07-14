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

# build_bin: a package whose `bin` is a RUNNABLE tool (an executable shell script with a shebang),
# not a JS module. The installer's linker symlinks it into node_modules/.bin + chmods it +x, so a
# `clun run <script>` can invoke it by bare name via the .bin PATH. Used by examples/e2e.sh — the
# v1 workflow demo (install → run a build script that invokes this tool → test). Its dist.integrity
# is still computed from bytes at fixture startup, so nothing else needs updating.
build_bin() { # name version
  name="$1"; ver="$2"
  d=$(mktemp -d); mkdir -p "$d/package"
  printf '{"name":"%s","version":"%s","dependencies":{},"bin":{"%s":"index.js"}}\n' "$name" "$ver" "$name" > "$d/package/package.json"
  printf '#!/bin/sh\nmkdir -p dist\necho "// built by %s@%s" > dist/bundle.js\necho "%s: wrote dist/bundle.js"\n' "$name" "$ver" "$name" > "$d/package/index.js"
  fn=$(printf '%s-%s.tgz' "$(echo "$name" | sed 's|/|-|g;s|@||')" "$ver")
  ( cd "$d" && tar --sort=name --mtime='2020-01-01 00:00:00' -cf - package 2>/dev/null || (cd "$d" && tar -cf - package) ) | gzip -n > "$fn"
  rm -rf "$d"; echo "  $fn (executable bin)"
}
build_bin "hasbin" "2.0.0"
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
