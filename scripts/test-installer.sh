#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/clun-installer-test.XXXXXX")
unset XDG_DATA_HOME
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
mkdir -p "$package_dir/bin" "$dist_dir"

printf '%s\n' "$version" >"$package_dir/VERSION"
if [ "$os" = linux ]; then
  mkdir -p "$package_dir/lib" "$package_dir/libexec"
  printf '%s\n' fixture-loader >"$package_dir/lib/LOADER"
  cat >"$package_dir/lib/fixture-loader" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = --library-path ]
shift 2
exec "$@"
EOF
  printf '%s\n' '#!/bin/sh' 'printf "clun 0.0.0-installer-test+build.1\n"' \
    >"$package_dir/libexec/clun"
  cat >"$package_dir/bin/clun" <<'EOF'
#!/bin/sh
set -eu
source_path=$0
while [ -L "$source_path" ]; do
  source_dir=$(CDPATH='' cd -- "$(dirname -- "$source_path")" && pwd -P)
  source_link=$(readlink "$source_path")
  case "$source_link" in
    /*) source_path=$source_link ;;
    *) source_path=$source_dir/$source_link ;;
  esac
done
bin_dir=$(CDPATH='' cd -- "$(dirname -- "$source_path")" && pwd -P)
release_dir=$(CDPATH='' cd -- "$bin_dir/.." && pwd -P)
loader=$(sed -n '1p' "$release_dir/lib/LOADER")
exec "$release_dir/lib/$loader" --library-path "$release_dir/lib" \
  "$release_dir/libexec/clun" "$@"
EOF
  chmod +x "$package_dir/bin/clun" "$package_dir/lib/fixture-loader" \
    "$package_dir/libexec/clun"
else
  printf '%s\n' '#!/bin/sh' 'printf "clun 0.0.0-installer-test+build.1\n"' \
    >"$package_dir/bin/clun"
  chmod +x "$package_dir/bin/clun"
fi
tar -C "$work_dir/package" -czf "$dist_dir/clun-$target.tar.gz" "clun-$target"

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$dist_dir" && sha256sum "clun-$target.tar.gz" >checksums.txt)
else
  (cd "$dist_dir" && shasum -a 256 "clun-$target.tar.gz" >checksums.txt)
fi

if [ "$os" = darwin ]; then
  bash_profile_name=.bash_profile
else
  bash_profile_name=.bashrc
fi

assert_modern_install() {
  fixture_home=$1
  fixture_bin=$2
  fixture_release="$fixture_home/.local/share/clun/releases/$version/$target"
  [ -L "$fixture_bin/clun" ] || {
    printf 'installer-test: stable launcher is not a symlink\n' >&2
    exit 1
  }
  [ -f "$fixture_release/VERSION" ] || {
    printf 'installer-test: complete versioned release bundle is missing\n' >&2
    exit 1
  }
  if [ "$os" = linux ]; then
    [ -x "$fixture_release/libexec/clun" ] &&
      [ -x "$fixture_release/lib/fixture-loader" ] &&
      [ -f "$fixture_release/lib/LOADER" ] || {
        printf 'installer-test: Linux release sidecars were not installed\n' >&2
        exit 1
      }
  fi
  [ "$(PATH="$fixture_bin:$PATH" clun --version)" = "clun $version" ] || {
    printf 'installer-test: PATH launcher did not execute the complete bundle\n' >&2
    exit 1
  }
}

# Fresh installs use ~/.local/bin, ADD_PATH=0 leaves rc files untouched, and the
# installer always prints the current-shell export when the directory is absent.
default_home="$work_dir/default-home"
mkdir -p "$default_home"
default_output="$work_dir/default.output"
HOME="$default_home" SHELL=/bin/bash \
CLUN_DOWNLOAD_BASE="file://$dist_dir" \
CLUN_VERSION="v$version" ADD_PATH=0 \
  sh "$repo_root/site/install" >"$default_output"
assert_modern_install "$default_home" "$default_home/.local/bin"
[ ! -e "$default_home/$bash_profile_name" ] || {
  printf 'installer-test: ADD_PATH=0 modified the shell rc\n' >&2
  exit 1
}
grep -F "export PATH='$default_home/.local/bin':\"\$PATH\"" "$default_output" >/dev/null || {
  printf 'installer-test: missing current-shell PATH export\n' >&2
  exit 1
}

# INSTALL_DIR is the exact binary directory. INSTALL_VERSION accepts an unprefixed pin.
override_dir="$work_dir/override-bin"
HOME="$work_dir/override-home" SHELL=/bin/zsh \
CLUN_DOWNLOAD_BASE="file://$dist_dir" INSTALL_VERSION="$version" \
INSTALL_DIR="$override_dir" ADD_PATH=0 \
  sh "$repo_root/site/install" >/dev/null
assert_modern_install "$work_dir/override-home" "$override_dir"
positional_dir="$work_dir/positional-bin"
HOME="$work_dir/positional-home" SHELL=/bin/bash \
CLUN_DOWNLOAD_BASE="file://$dist_dir" INSTALL_DIR="$positional_dir" ADD_PATH=0 \
  sh "$repo_root/site/install" "$version" >/dev/null
assert_modern_install "$work_dir/positional-home" "$positional_dir"

# The managed block is shell-specific and idempotent across reinstall.
profile_home="$work_dir/profile-home"
profile_bin="$work_dir/profile-bin"
mkdir -p "$profile_home"
for _ in 1 2; do
  HOME="$profile_home" SHELL=/bin/bash \
  CLUN_DOWNLOAD_BASE="file://$dist_dir" CLUN_VERSION="v$version" \
  INSTALL_DIR="$profile_bin" \
    sh "$repo_root/site/install" >/dev/null
done
[ "$(grep -Fxc '# >>> clun installer >>>' "$profile_home/$bash_profile_name")" -eq 1 ] || {
  printf 'installer-test: bash PATH block was not idempotent\n' >&2
  exit 1
}
grep -F "export PATH='$profile_bin':\"\$PATH\"" "$profile_home/$bash_profile_name" >/dev/null || {
  printf 'installer-test: bash PATH block has the wrong directory\n' >&2
  exit 1
}
profile_new_bin="$work_dir/profile-bin-new"
HOME="$profile_home" SHELL=/bin/bash \
CLUN_DOWNLOAD_BASE="file://$dist_dir" CLUN_VERSION="v$version" \
INSTALL_DIR="$profile_new_bin" ADD_PATH=1 \
  sh "$repo_root/site/install" >/dev/null
[ "$(grep -Fxc '# >>> clun installer >>>' "$profile_home/$bash_profile_name")" -eq 1 ] || {
  printf 'installer-test: managed PATH block was duplicated during update\n' >&2
  exit 1
}
grep -F "export PATH='$profile_new_bin':\"\$PATH\"" "$profile_home/$bash_profile_name" >/dev/null || {
  printf 'installer-test: managed PATH block did not follow INSTALL_DIR\n' >&2
  exit 1
}
if grep -F "export PATH='$profile_bin':\"\$PATH\"" "$profile_home/$bash_profile_name" >/dev/null; then
  printf 'installer-test: managed PATH block retained the old INSTALL_DIR\n' >&2
  exit 1
fi

# A user-owned rc symlink is followed without replacing the symlink itself.
symlink_home="$work_dir/symlink-home"
symlink_bin="$work_dir/symlink-bin"
mkdir -p "$symlink_home/config"
printf '%s\n' '# existing managed dotfile' >"$symlink_home/config/bash-profile"
ln -s "config/bash-profile" "$symlink_home/$bash_profile_name"
original_profile_link=$(readlink "$symlink_home/$bash_profile_name")
HOME="$symlink_home" SHELL=/bin/bash \
CLUN_DOWNLOAD_BASE="file://$dist_dir" CLUN_VERSION="v$version" \
INSTALL_DIR="$symlink_bin" ADD_PATH=1 \
  sh "$repo_root/site/install" >/dev/null
[ -L "$symlink_home/$bash_profile_name" ] &&
  [ "$(readlink "$symlink_home/$bash_profile_name")" = "$original_profile_link" ] || {
    printf 'installer-test: shell rc symlink was replaced\n' >&2
    exit 1
  }
grep -F '# >>> clun installer >>>' "$symlink_home/config/bash-profile" >/dev/null || {
  printf 'installer-test: shell rc symlink target was not updated\n' >&2
  exit 1
}

# Home Manager-style links outside HOME are never replaced or edited. The
# installer declines the profile mutation while still completing the install.
external_home="$work_dir/external-home"
external_bin="$work_dir/external-bin"
external_profile="$work_dir/external-managed-profile"
mkdir -p "$external_home"
printf '%s\n' '# externally managed profile' >"$external_profile"
ln -s "$external_profile" "$external_home/$bash_profile_name"
HOME="$external_home" SHELL=/bin/bash \
CLUN_DOWNLOAD_BASE="file://$dist_dir" CLUN_VERSION="v$version" \
INSTALL_DIR="$external_bin" ADD_PATH=1 \
  sh "$repo_root/site/install" >/dev/null
[ -L "$external_home/$bash_profile_name" ] &&
  [ "$(readlink "$external_home/$bash_profile_name")" = "$external_profile" ] || {
    printf 'installer-test: externally managed shell rc symlink was replaced\n' >&2
    exit 1
  }
if grep -F '# >>> clun installer >>>' "$external_profile" >/dev/null; then
  printf 'installer-test: shell rc target outside HOME was edited\n' >&2
  exit 1
fi

# A non-symlink profile below a symlinked parent must receive the same
# protection. In particular, ~/.config/fish may be Home Manager-owned even
# though the eventual config.fish does not exist yet.
parent_link_home="$work_dir/parent-link-home"
parent_link_bin="$work_dir/parent-link-bin"
external_config="$work_dir/external-config"
mkdir -p "$parent_link_home" "$external_config"
ln -s "$external_config" "$parent_link_home/.config"
HOME="$parent_link_home" SHELL=/usr/bin/fish \
CLUN_DOWNLOAD_BASE="file://$dist_dir" CLUN_VERSION="v$version" \
INSTALL_DIR="$parent_link_bin" ADD_PATH=1 \
  sh "$repo_root/site/install" >/dev/null
[ -L "$parent_link_home/.config" ] || {
  printf 'installer-test: symlinked shell-profile parent was replaced\n' >&2
  exit 1
}
if [ -e "$external_config/fish/config.fish" ]; then
  printf 'installer-test: shell profile beneath an outside-HOME parent symlink was created\n' >&2
  exit 1
fi

# ADD_PATH=1 writes the detected rc even when the directory is already on PATH.
force_home="$work_dir/force-home"
force_bin="$work_dir/force-bin"
mkdir -p "$force_home"
HOME="$force_home" SHELL=/bin/zsh PATH="$force_bin:$PATH" \
CLUN_DOWNLOAD_BASE="file://$dist_dir" CLUN_VERSION="v$version" \
INSTALL_DIR="$force_bin" ADD_PATH=1 \
  sh "$repo_root/site/install" >/dev/null
grep -F '# >>> clun installer >>>' "$force_home/.zshrc" >/dev/null || {
  printf 'installer-test: ADD_PATH=1 did not force the zsh rc block\n' >&2
  exit 1
}

fish_home="$work_dir/fish-home"
fish_bin="$work_dir/fish-bin"
mkdir -p "$fish_home"
HOME="$fish_home" SHELL=/usr/bin/fish \
CLUN_DOWNLOAD_BASE="file://$dist_dir" CLUN_VERSION="v$version" \
INSTALL_DIR="$fish_bin" ADD_PATH=1 \
  sh "$repo_root/site/install" >/dev/null
grep -F "set -gx PATH '$fish_bin' \$PATH" "$fish_home/.config/fish/config.fish" >/dev/null || {
  printf 'installer-test: fish PATH block has the wrong syntax\n' >&2
  exit 1
}

# Existing CLUN_INSTALL/CLUN_NO_MODIFY_PATH callers retain the release-root layout.
legacy_root="$work_dir/legacy-root"
HOME="$work_dir/legacy-home" SHELL=/bin/bash \
CLUN_DOWNLOAD_BASE="file://$dist_dir" CLUN_VERSION="v$version" \
CLUN_INSTALL="$legacy_root" CLUN_NO_MODIFY_PATH=1 \
  sh "$repo_root/site/install" >/dev/null
[ "$(PATH="$legacy_root/bin:$PATH" clun --version)" = "clun $version" ] || {
  printf 'installer-test: legacy CLUN_INSTALL layout failed\n' >&2
  exit 1
}
if [ "$os" = linux ]; then
  [ -x "$legacy_root/releases/$version/$target/libexec/clun" ] || {
    printf 'installer-test: legacy layout dropped Linux release sidecars\n' >&2
    exit 1
  }
fi

invalid_tag_error="$work_dir/invalid-tag.error"
if CLUN_DOWNLOAD_BASE="file://$dist_dir" \
   CLUN_VERSION=v01.0.0 \
   CLUN_INSTALL="$work_dir/invalid-tag-install" \
   CLUN_NO_MODIFY_PATH=1 \
     sh "$repo_root/site/install" >/dev/null 2>"$invalid_tag_error"; then
  printf 'installer-test: installer accepted a non-SemVer release tag\n' >&2
  exit 1
fi
grep -F "INSTALL_VERSION/CLUN_VERSION must be strict SemVer with an optional v prefix" \
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
   CLUN_VERSION="v$version" \
   CLUN_INSTALL="$work_dir/malicious-install" \
   CLUN_NO_MODIFY_PATH=1 \
     sh "$repo_root/site/install" >/dev/null 2>&1; then
  printf 'installer-test: installer accepted an archive containing a symlink\n' >&2
  exit 1
fi

# Explicit latest resolution must ask github.com/releases/latest first and skip
# the API entirely when the redirect yields a valid tag. The no-argument path is
# deliberately ledger-bound and is covered by public-claims and Pages checks.
fake_bin="$work_dir/fake-bin"
mkdir -p "$fake_bin"
cp "$repo_root/tests/fixtures/fake-installer-curl.sh" "$fake_bin/curl"
chmod +x "$fake_bin/curl"
redirect_log="$work_dir/redirect-curl.log"
: >"$redirect_log"
redirect_bin="$work_dir/redirect-bin"
HOME="$work_dir/redirect-home" SHELL=/bin/bash PATH="$fake_bin:$PATH" \
CLUN_TEST_CURL_LOG="$redirect_log" CLUN_TEST_DIST_DIR="$dist_dir" \
CLUN_TEST_REDIRECT_TAG="v$version" INSTALL_VERSION=latest \
INSTALL_DIR="$redirect_bin" ADD_PATH=0 \
  sh "$repo_root/site/install" >/dev/null
[ "$(sed -n '1p' "$redirect_log")" = \
  'url:https://github.com/theesfeld/clun/releases/latest' ] || {
  printf 'installer-test: latest redirect was not the first network request\n' >&2
  exit 1
}
if grep -F 'url:https://api.github.com/' "$redirect_log" >/dev/null; then
  printf 'installer-test: successful latest redirect still queried the API\n' >&2
  exit 1
fi

# When the redirect is unavailable, the token-aware API fallback supplies the
# tag before the same checksum-verified assets are installed.
api_log="$work_dir/api-curl.log"
: >"$api_log"
api_bin="$work_dir/api-bin"
HOME="$work_dir/api-home" SHELL=/bin/bash PATH="$fake_bin:$PATH" \
GITHUB_TOKEN=installer-test-token \
CLUN_TEST_CURL_LOG="$api_log" CLUN_TEST_DIST_DIR="$dist_dir" \
CLUN_TEST_API_JSON="[{\"tag_name\":\"v0.0.0-0\",\"draft\":false},{\"tag_name\":\"v99.0.0\",\"draft\":true},{\"tag_name\":\"v$version\",\"draft\":false}]" \
INSTALL_VERSION=latest INSTALL_DIR="$api_bin" ADD_PATH=0 \
  sh "$repo_root/site/install" >/dev/null
sed -n '1p' "$api_log" | grep -F \
  'url:https://github.com/theesfeld/clun/releases/latest' >/dev/null || {
  printf 'installer-test: API fallback did not try the redirect first\n' >&2
  exit 1
}
grep -F 'url:https://api.github.com/repos/theesfeld/clun/releases?per_page=10' \
  "$api_log" >/dev/null || {
  printf 'installer-test: redirect failure did not use the Releases API fallback\n' >&2
  exit 1
}
grep -F 'header:Authorization: Bearer installer-test-token' "$api_log" >/dev/null || {
  printf 'installer-test: API fallback did not honor GITHUB_TOKEN\n' >&2
  exit 1
}
[ "$(PATH="$api_bin:$PATH" clun --version)" = "clun $version" ] || {
  printf 'installer-test: API-resolved fixture did not execute\n' >&2
  exit 1
}

# Prerelease-only repositories cannot rely on /releases/latest. If the API is
# rate-limited, the public Releases Atom feed must still select the highest
# published SemVer tag rather than the first chronological entry.
atom_log="$work_dir/atom-curl.log"
: >"$atom_log"
atom_bin="$work_dir/atom-bin"
atom_xml="<feed><entry><link href=\"https://github.com/theesfeld/clun/releases/tag/v0.0.0-0\"/></entry><entry><link href=\"https://github.com/theesfeld/clun/releases/tag/v$version\"/></entry><entry><link href=\"https://github.com/theesfeld/clun/releases/tag/v0.0.0-1\"/></entry></feed>"
HOME="$work_dir/atom-home" SHELL=/bin/bash PATH="$fake_bin:$PATH" \
CLUN_TEST_CURL_LOG="$atom_log" CLUN_TEST_DIST_DIR="$dist_dir" \
CLUN_TEST_API_STATUS=403 CLUN_TEST_ATOM_XML="$atom_xml" \
INSTALL_VERSION=latest INSTALL_DIR="$atom_bin" ADD_PATH=0 \
  sh "$repo_root/site/install" >/dev/null
grep -F 'url:https://api.github.com/repos/theesfeld/clun/releases?per_page=10' \
  "$atom_log" >/dev/null || {
  printf 'installer-test: prerelease fallback did not try the Releases API\n' >&2
  exit 1
}
grep -F 'url:https://github.com/theesfeld/clun/releases.atom' "$atom_log" >/dev/null || {
  printf 'installer-test: API 403 did not use the public Releases feed fallback\n' >&2
  exit 1
}
grep -F "url:https://github.com/theesfeld/clun/releases/download/v$version/" \
  "$atom_log" >/dev/null || {
  printf 'installer-test: Releases feed fallback did not select the highest SemVer tag\n' >&2
  exit 1
}
[ "$(PATH="$atom_bin:$PATH" clun --version)" = "clun $version" ] || {
  printf 'installer-test: Releases-feed-resolved fixture did not execute\n' >&2
  exit 1
}

printf 'installer fixture smoke passed for %s\n' "$target"
