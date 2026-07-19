#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
  printf 'usage: %s <downloaded-release-directory>\n' "$0" >&2
  exit 2
fi

asset_dir=$1

fail() {
  printf 'release-asset-check: %s\n' "$*" >&2
  exit 1
}

[ -d "$asset_dir" ] || fail "asset directory does not exist: $asset_dir"
command -v sha256sum >/dev/null 2>&1 || fail 'GNU sha256sum is required'

entry_count=$(find "$asset_dir" -mindepth 1 -maxdepth 1 | wc -l | tr -d '[:space:]')
[ "$entry_count" -eq 5 ] ||
  fail "expected exactly five downloaded assets, found $entry_count"

required_archives='clun-linux-x64.tar.gz
clun-linux-arm64.tar.gz
clun-darwin-x64.tar.gz
clun-darwin-arm64.tar.gz'

[ -s "$asset_dir/checksums.txt" ] || fail 'checksums.txt is missing or empty'
old_ifs=$IFS
IFS='
'
for archive in $required_archives; do
  [ -s "$asset_dir/$archive" ] || fail "$archive is missing or empty"
done
IFS=$old_ifs

line_count=$(wc -l <"$asset_dir/checksums.txt" | tr -d '[:space:]')
[ "$line_count" -eq 4 ] ||
  fail "checksums.txt must contain exactly four lines, found $line_count"

LC_ALL=C awk '
  NF != 2 || length($1) != 64 || $1 !~ /^[0-9a-f]+$/ { bad = 1 }
  END { exit bad ? 1 : 0 }
' "$asset_dir/checksums.txt" ||
  fail 'checksums.txt must contain canonical lowercase SHA-256 records'

IFS='
'
for archive in $required_archives; do
  LC_ALL=C awk -v required="$archive" '
    $2 == required { matches++ }
    END { exit matches == 1 ? 0 : 1 }
  ' "$asset_dir/checksums.txt" ||
    fail "checksums.txt must name $archive exactly once"
done
IFS=$old_ifs

(cd "$asset_dir" && sha256sum --check --strict checksums.txt) ||
  fail 'strict SHA-256 verification failed'

printf 'release-asset-check: exactly four archives plus checksums.txt verified\n'
