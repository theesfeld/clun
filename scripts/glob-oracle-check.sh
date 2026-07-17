#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
case_dir=$repo_root/tests/compat/filesystem.glob
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
TAB=$(printf '\t')

[ -x "$clun" ] || {
  printf 'filesystem.glob oracle: %s is missing\n' "$clun" >&2
  exit 2
}

case "$(uname -s):$(uname -m)" in
  Linux:x86_64|Linux:amd64) target=linux-x64 ;;
  Linux:aarch64|Linux:arm64) target=linux-arm64 ;;
  Darwin:x86_64|Darwin:amd64) target=darwin-x64 ;;
  Darwin:arm64|Darwin:aarch64) target=darwin-arm64 ;;
  *) printf 'filesystem.glob oracle: unsupported host %s/%s\n' "$(uname -s)" "$(uname -m)" >&2; exit 2 ;;
esac

row=$(awk -F "$TAB" -v target="$target" \
  'NR > 1 && $1 == "bun-stable-1.3.14" && $2 == target { print; n++ } END { if (n != 1) exit 1 }' \
  "$repo_root/compat/upstream-assets.tsv") || {
    printf 'filesystem.glob oracle: missing unique asset row for %s\n' "$target" >&2
    exit 1
  }
asset=$(printf '%s\n' "$row" | awk -F "$TAB" '{ print $3 }')
expected_sha=$(printf '%s\n' "$row" | awk -F "$TAB" '{ print $4 }')
source_url=$(printf '%s\n' "$row" | awk -F "$TAB" '{ print $5 }')

tmp_base=${TMPDIR:-$repo_root/tmp-test}
mkdir -p "$tmp_base"
archive=${BUN_ORACLE_ARCHIVE:-}
if [ -z "$archive" ]; then
  if [ -f "$tmp_base/$asset" ]; then
    archive=$tmp_base/$asset
  elif [ -f "$tmp_base/bun-1.3.14-$asset" ]; then
    archive=$tmp_base/bun-1.3.14-$asset
  else
    archive=$tmp_base/$asset
    curl -fsSL "$source_url" -o "$archive"
  fi
fi
[ -f "$archive" ] || {
  printf 'filesystem.glob oracle: archive is missing: %s\n' "$archive" >&2
  exit 2
}

if command -v sha256sum >/dev/null 2>&1; then
  actual_sha=$(sha256sum "$archive" | awk '{ print $1 }')
elif command -v shasum >/dev/null 2>&1; then
  actual_sha=$(shasum -a 256 "$archive" | awk '{ print $1 }')
else
  printf 'filesystem.glob oracle: sha256sum or shasum is required\n' >&2
  exit 2
fi
[ "$actual_sha" = "$expected_sha" ] || {
  printf 'filesystem.glob oracle: %s digest mismatch; expected %s, got %s\n' \
    "$target" "$expected_sha" "$actual_sha" >&2
  exit 1
}

work=$(mktemp -d "$tmp_base/clun-glob-oracle.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
unzip -q "$archive" -d "$work/bun"
bun=$(find "$work/bun" -type f -name bun -print | head -n 1)
[ -n "$bun" ] || {
  printf 'filesystem.glob oracle: Bun executable is absent from %s\n' "$asset" >&2
  exit 1
}
chmod +x "$bun"
[ "$("$bun" --version)" = 1.3.14 ] || {
  printf 'filesystem.glob oracle: archive does not contain Bun 1.3.14\n' >&2
  exit 1
}

clun_match=$(cd "$case_dir" && "$clun" oracle-match.js)
bun_match=$(cd "$case_dir" && "$bun" oracle-match.js)
[ "$clun_match" = "$bun_match" ] || {
  printf 'filesystem.glob oracle: matcher differential failed\nBun:\n%s\nClun:\n%s\n' \
    "$bun_match" "$clun_match" >&2
  exit 1
}

tree=$work/tree
mkdir -p "$tree/sub" "$tree/real" "$tree/.hidden"
printf 'a\n' > "$tree/a.js"
printf 'z\n' > "$tree/z.txt"
printf 'b\n' > "$tree/sub/b.js"
printf 'x\n' > "$tree/sub/x.txt"
printf 'r\n' > "$tree/real/n.js"
printf 'h\n' > "$tree/.hidden/h.js"
printf 'd\n' > "$tree/.dot.js"
ln -s real "$tree/link"
ln -s missing "$tree/broken"

clun_scan=$(cd "$case_dir" && CLUN_GLOB_ORACLE_ROOT=$tree "$clun" oracle-scan.js)
bun_scan=$(cd "$case_dir" && CLUN_GLOB_ORACLE_ROOT=$tree "$bun" oracle-scan.js)
[ "$clun_scan" = "$bun_scan" ] || {
  printf 'filesystem.glob oracle: scanner differential failed\nBun:\n%s\nClun:\n%s\n' \
    "$bun_scan" "$clun_scan" >&2
  exit 1
}

printf 'filesystem.glob oracle: Bun 1.3.14 %s digest, matcher, and scanner passed\n' "$target"
