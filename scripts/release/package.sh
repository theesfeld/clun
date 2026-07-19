#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <target> <version> <output-directory>" >&2
  exit 2
fi

target=$1
release_tag=$2
output_dir=$3
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
binary="$repo_root/build/clun"

if [[ ! -x "$binary" ]]; then
  echo "package: $binary does not exist; run make build first" >&2
  exit 1
fi

reported_version=$("$binary" --version)
if [[ "$reported_version" != "clun "* ]]; then
  echo "package: unexpected version output: $reported_version" >&2
  exit 1
fi
binary_version=${reported_version#clun }
tag_version=${release_tag#v}
if [[ "$tag_version" != "$binary_version" ]]; then
  echo "package: tag $release_tag does not match binary version $binary_version" >&2
  exit 1
fi

case "$target" in
  linux-x64|linux-arm64) platform=linux ;;
  darwin-x64|darwin-arm64) platform=darwin ;;
  *) echo "package: unsupported target $target" >&2; exit 2 ;;
esac

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/clun-package.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

package_dir="$work_dir/clun-$target"
mkdir -p "$package_dir/bin" "$output_dir"
printf '%s\n' "$binary_version" >"$package_dir/VERSION"
cp "$repo_root/LICENSE" "$package_dir/LICENSE"
cp "$repo_root/COPYING" "$package_dir/COPYING"
cp "$repo_root/THIRD_PARTY_NOTICES.md" "$package_dir/THIRD_PARTY_NOTICES.md"

while IFS= read -r -d '' notice; do
  relative_notice=${notice#"$repo_root/"}
  notice_destination="$package_dir/licenses/$relative_notice"
  mkdir -p "$(dirname "$notice_destination")"
  cp "$notice" "$notice_destination"
done < <(
  find "$repo_root/vendor" "$repo_root/vendor-data" -type f \
    \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'COPYRIGHT*' -o -iname 'NOTICE*' \) \
    -print0
)

unicode_notice="$package_dir/licenses/vendor-data/ucd/17.0.0/LICENSE.txt"
[[ -f "$unicode_notice" ]] || {
  echo "package: Unicode 17.0.0 license notice is missing from the archive tree" >&2
  exit 1
}

if [[ -f "$repo_root/vendor/pure-tls/README.md" ]]; then
  mkdir -p "$package_dir/licenses/vendor/pure-tls"
  cp "$repo_root/vendor/pure-tls/README.md" "$package_dir/licenses/vendor/pure-tls/README.md"
fi

if [[ "$platform" == linux ]]; then
  mkdir -p "$package_dir/lib" "$package_dir/libexec"
  cp "$binary" "$package_dir/libexec/clun"
  chmod 755 "$package_dir/libexec/clun"

  mapfile -t linked_libraries < <(
    ldd "$binary" |
      awk '
        /=> \/[^ ]+/ { print $3 }
        /^[[:space:]]*\/[^ ]+ \(/ { print $1 }
      ' |
      sort -u
  )

  loader=
  for library in "${linked_libraries[@]}"; do
    [[ -f "$library" ]] || continue
    library_name=$(basename "$library")
    cp -L "$library" "$package_dir/lib/$library_name"
    if [[ "$library_name" == ld-linux-* || "$library_name" == ld-musl-* ]]; then
      loader=$library_name
    fi
  done

  if command -v ldconfig >/dev/null 2>&1; then
    for library_name in libnss_dns.so.2 libnss_files.so.2 libresolv.so.2; do
      library=$(ldconfig -p 2>/dev/null | awk -v name="$library_name" '$1 == name { found = $NF } END { print found }' || true)
      if [[ -n "$library" && -f "$library" ]]; then
        cp -L "$library" "$package_dir/lib/$library_name"
      fi
    done
  fi

  mkdir -p "$package_dir/licenses/system"
  for notice in /usr/share/doc/libc6/copyright /usr/share/doc/libzstd1/copyright; do
    if [[ -f "$notice" ]]; then
      cp "$notice" "$package_dir/licenses/system/$(basename "$(dirname "$notice")")-copyright"
    fi
  done

  [[ -n "$loader" ]] || {
    echo "package: could not locate the Linux dynamic loader" >&2
    exit 1
  }
  printf '%s\n' "$loader" >"$package_dir/lib/LOADER"

  cat >"$package_dir/bin/clun" <<'WRAPPER'
#!/bin/sh
set -eu

invocation_path=$0
case "$invocation_path" in
  */*) ;;
  *) invocation_path=$(command -v "$invocation_path") || {
       printf 'clun: could not resolve launcher %s on PATH\n' "$0" >&2
       exit 126
     } ;;
esac
case "$invocation_path" in
  /*) ;;
  *) invocation_path=$(CDPATH= cd -- "$(dirname -- "$invocation_path")" && pwd -P)/$(basename -- "$invocation_path") ;;
esac
export CLUN_UPDATE_LAUNCHER=$invocation_path

source_path=$invocation_path
while [ -L "$source_path" ]; do
  source_dir=$(CDPATH= cd -- "$(dirname -- "$source_path")" && pwd)
  source_link=$(readlink "$source_path")
  case "$source_link" in
    /*) source_path=$source_link ;;
    *) source_path=$source_dir/$source_link ;;
  esac
done

bin_dir=$(CDPATH= cd -- "$(dirname -- "$source_path")" && pwd)
release_dir=$(CDPATH= cd -- "$bin_dir/.." && pwd)
loader=$(sed -n '1p' "$release_dir/lib/LOADER")

exec "$release_dir/lib/$loader" \
  --library-path "$release_dir/lib" \
  "$release_dir/libexec/clun" "$@"
WRAPPER
  chmod 755 "$package_dir/bin/clun"
else
  while IFS= read -r dependency; do
    case "$dependency" in
      /usr/lib/*|/System/*) continue ;;
    esac
    echo "package: macOS binary has a non-system dependency: $dependency" >&2
    exit 1
  done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')

  cp "$binary" "$package_dir/bin/clun"
  chmod 755 "$package_dir/bin/clun"
fi

"$package_dir/bin/clun" --version
tar -C "$work_dir" -czf "$output_dir/clun-$target.tar.gz" "clun-$target"
echo "created $output_dir/clun-$target.tar.gz"
