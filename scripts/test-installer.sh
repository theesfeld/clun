#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/clun-installer-test.XXXXXX")
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) printf 'installer-test: unsupported test host\n' >&2; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64|amd64) arch=x64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) printf 'installer-test: unsupported test architecture\n' >&2; exit 1 ;;
esac

target="$os-$arch"
version=0.0.0-installer-test+build.1
package_dir="$work_dir/package/clun-$target"
dist_dir="$work_dir/dist"
install_dir="$work_dir/install"
mkdir -p "$package_dir/bin" "$dist_dir"

printf '%s\n' "$version" >"$package_dir/VERSION"
printf '%s\n' '#!/bin/sh' 'printf "clun 0.0.0-installer-test+build.1\n"' >"$package_dir/bin/clun"
chmod +x "$package_dir/bin/clun"
tar -C "$work_dir/package" -czf "$dist_dir/clun-$target.tar.gz" "clun-$target"

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$dist_dir" && sha256sum "clun-$target.tar.gz" >checksums.txt)
else
  (cd "$dist_dir" && shasum -a 256 "clun-$target.tar.gz" >checksums.txt)
fi

CLUN_DOWNLOAD_BASE="file://$dist_dir" \
CLUN_VERSION="v$version" \
CLUN_INSTALL="$install_dir" \
CLUN_NO_MODIFY_PATH=1 \
  sh "$repo_root/site/install" >/dev/null

[ "$("$install_dir/bin/clun" --version)" = "clun $version" ] || {
  printf 'installer-test: installed fixture did not execute\n' >&2
  exit 1
}

invalid_tag_error="$work_dir/invalid-tag.error"
if CLUN_DOWNLOAD_BASE="file://$dist_dir" \
   CLUN_VERSION=v01.0.0 \
   CLUN_INSTALL="$work_dir/invalid-tag-install" \
   CLUN_NO_MODIFY_PATH=1 \
     sh "$repo_root/site/install" >/dev/null 2>"$invalid_tag_error"; then
  printf 'installer-test: installer accepted a non-SemVer release tag\n' >&2
  exit 1
fi
grep -F "CLUN_VERSION must be v-prefixed strict SemVer" \
  "$invalid_tag_error" >/dev/null || {
  printf 'installer-test: malformed tag did not fail SemVer validation\n' >&2
  exit 1
}

invalid_version_dist="$work_dir/invalid-version-dist"
mkdir -p "$invalid_version_dist"
printf '%s\n' '01.0.0' >"$package_dir/VERSION"
tar -C "$work_dir/package" -czf "$invalid_version_dist/clun-$target.tar.gz" "clun-$target"
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$invalid_version_dist" && sha256sum "clun-$target.tar.gz" >checksums.txt)
else
  (cd "$invalid_version_dist" && shasum -a 256 "clun-$target.tar.gz" >checksums.txt)
fi
invalid_version_error="$work_dir/invalid-version.error"
if CLUN_DOWNLOAD_BASE="file://$invalid_version_dist" \
   CLUN_VERSION=v0.1.0 \
   CLUN_INSTALL="$work_dir/invalid-version-install" \
   CLUN_NO_MODIFY_PATH=1 \
     sh "$repo_root/site/install" >/dev/null 2>"$invalid_version_error"; then
  printf 'installer-test: installer accepted a non-SemVer archive version\n' >&2
  exit 1
fi
grep -F 'release archive version is not strict SemVer' \
  "$invalid_version_error" >/dev/null || {
  printf 'installer-test: malformed archive version did not fail SemVer validation\n' >&2
  exit 1
}
printf '%s\n' "$version" >"$package_dir/VERSION"

malicious_dist="$work_dir/malicious-dist"
mkdir -p "$malicious_dist"
ln -s /tmp/clun-installer-escape "$package_dir/unsafe-link"
tar -C "$work_dir/package" -czf "$malicious_dist/clun-$target.tar.gz" "clun-$target"
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$malicious_dist" && sha256sum "clun-$target.tar.gz" >checksums.txt)
else
  (cd "$malicious_dist" && shasum -a 256 "clun-$target.tar.gz" >checksums.txt)
fi
if CLUN_DOWNLOAD_BASE="file://$malicious_dist" \
   CLUN_INSTALL="$work_dir/malicious-install" \
   CLUN_NO_MODIFY_PATH=1 \
     sh "$repo_root/site/install" >/dev/null 2>&1; then
  printf 'installer-test: installer accepted an archive containing a symlink\n' >&2
  exit 1
fi

printf 'installer fixture smoke passed for %s\n' "$target"
