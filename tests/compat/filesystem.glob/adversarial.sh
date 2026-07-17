#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
[ -x "$clun" ] || {
  printf 'filesystem.glob adversarial: %s is missing\n' "$clun" >&2
  exit 2
}

tmp_base=${TMPDIR:-$repo_root/tmp-test}
mkdir -p "$tmp_base"
root=$(mktemp -d "$tmp_base/clun-glob-adversarial.XXXXXX")
trap 'chmod 700 "$root/locked" 2>/dev/null || true; rm -rf "$root"' EXIT HUP INT TERM

mkdir -p "$root/cycle" \
         "$root/cousin/a" "$root/cousin/b" "$root/cousin/shared" \
         "$root/dots/.secret" "$root/locked" "$root/deep" "$root/longleaf"
printf 'a\n' > "$root/cousin/a/own.txt"
printf 'b\n' > "$root/cousin/b/own.txt"
printf 's\n' > "$root/cousin/shared/file.txt"
printf 'd\n' > "$root/dots/.secret/secret.txt"
printf 'x\n' > "$root/locked/file.txt"
ln -s . "$root/cycle/self"
ln -s ../shared "$root/cousin/a/link"
ln -s ../shared "$root/cousin/b/link"
ln -s .secret "$root/dots/.dotlink"
ln -s missing "$root/broken"
ln -s loop "$root/loop"

case $(uname -s) in
  Darwin) path_ceiling=1024 ;;
  *) path_ceiling=4096 ;;
esac

segment=$(printf '%255s' '' | tr ' ' D)
file_name=$(printf '%255s' '' | tr ' ' F)
broken_name=$(printf '%255s' '' | tr ' ' B)

# Keep the shell's cwd below PATH_MAX, then create the over-ceiling leaf with
# one final relative pathname. Some dash builds reject cd after chdir succeeds
# when they cannot refresh the logical PWD.
deep_components=$((path_ceiling / 256))
(
  cd "$root/deep"
  index=0
  while [ "$index" -lt $((deep_components - 1)) ]; do
    mkdir "$segment"
    cd "$segment"
    index=$((index + 1))
  done
  mkdir "$segment"
  printf 'deep\n' > "$segment/$file_name"
)

# Keep the parent openable while making the returned absolute leaf exceed the
# platform ceiling enforced by the scanner.
long_root=$root/longleaf
depth=$(( (path_ceiling - ${#long_root}) / 256 ))
(
  cd "$long_root"
  index=0
  while [ "$index" -lt "$depth" ]; do
    mkdir "$segment"
    cd "$segment"
    index=$((index + 1))
  done
  printf 'leaf\n' > "$file_name"
  ln -s missing "$broken_name"
)

chmod 000 "$root/locked"

set +e
actual=$(CLUN_GLOB_FIXTURE=$root CLUN_GLOB_PATH_CEILING=$path_ceiling "$clun" -e '
const root = process.env.CLUN_GLOB_FIXTURE;
const pathCeiling = Number(process.env.CLUN_GLOB_PATH_CEILING);
function values(pattern, options) {
  return [...new Clun.Glob(pattern).scanSync(options)].join("|");
}
function errorCode(fn) {
  try { fn(); return "NO_THROW"; } catch (error) { return error.code; }
}
console.log("self-cycle", values("**", { cwd: root + "/cycle", onlyFiles: false, followSymlinks: true }));
console.log("cousins", values("**/*.txt", { cwd: root + "/cousin", followSymlinks: true }));
console.log("literal-link", values("a/link/*.txt", { cwd: root + "/cousin" }));
console.log("wildcard-no-follow", values("*/l*/*.txt", { cwd: root + "/cousin" }).length);
console.log("wildcard-follow", values("*/l*/*.txt", { cwd: root + "/cousin", followSymlinks: true }));
console.log("dot-link", values(".dotlink/*.txt", { cwd: root + "/dots" }));
console.log("trailing-cwd", values("*.txt", { cwd: root + "/cousin/shared////" }));
console.log("eloop", errorCode(function () { values("loop", { cwd: root, onlyFiles: false }); }));
let deepResult;
try {
  const deepValues = [...new Clun.Glob("**").scanSync({ cwd: root + "/deep", onlyFiles: false })];
  deepResult = "OK:" + deepValues.length + ":" + (deepValues.length ? deepValues[deepValues.length - 1].length : 0);
} catch (error) { deepResult = error.code; }
console.log("deep", deepResult);
const longLeaf = [...new Clun.Glob("**/*").scanSync({ cwd: root + "/longleaf", absolute: true })];
console.log(
  "long-leaf",
  longLeaf.length,
  longLeaf.length === 1 && longLeaf[0].length > pathCeiling,
  longLeaf.length === 1 && longLeaf[0].endsWith("/" + "F".repeat(255)),
);
console.log("long-broken", errorCode(function () {
  values("**/" + "B".repeat(255), {
    cwd: root + "/longleaf",
    followSymlinks: true,
    throwErrorOnBrokenSymlink: true,
    onlyFiles: false,
  });
}));
console.log("long-cwd", errorCode(function () { values("*", { cwd: "/" + "x".repeat(5000) }); }));
console.log("nul-cwd", errorCode(function () { values("*", { cwd: root + "\0x" }); }));
console.log("leading-dot", errorCode(function () { values("./".repeat(2200) + "*", { cwd: root }); }));
console.log("leading-dotdot", errorCode(function () { values("../".repeat(2200) + "*", { cwd: root }); }));
console.log("inaccessible", errorCode(function () { values("locked/*", { cwd: root }); }));
(async function () {
  const iterator = new Clun.Glob("broken").scan({
    cwd: root,
    followSymlinks: true,
    throwErrorOnBrokenSymlink: true,
    onlyFiles: false,
  });
  let first;
  try { await iterator.next(); first = "NO_REJECT"; } catch (error) { first = error.code; }
  const second = await iterator.next();
  console.log("async-broken", first, second.done);
})();
')
status=$?
set -e

chmod 700 "$root/locked"

[ "$status" -eq 0 ] || {
  printf 'filesystem.glob adversarial executable failed (%s)\npartial output:\n%s\n' \
    "$status" "$actual" >&2
  exit "$status"
}

expected='self-cycle self|self/self
cousins a/link/file.txt|a/own.txt|b/link/file.txt|b/own.txt|shared/file.txt
literal-link a/link/file.txt
wildcard-no-follow 0
wildcard-follow a/link/file.txt|b/link/file.txt
dot-link .dotlink/secret.txt
trailing-cwd file.txt
eloop ELOOP
deep ENAMETOOLONG
long-leaf 1 true true
long-broken ENOENT
long-cwd ENAMETOOLONG
nul-cwd EINVAL
leading-dot ENAMETOOLONG
leading-dotdot ENAMETOOLONG
inaccessible EACCES
async-broken ENOENT true'

[ "$actual" = "$expected" ] || {
  printf 'filesystem.glob adversarial mismatch\nexpected:\n%s\nactual:\n%s\n' \
    "$expected" "$actual" >&2
  exit 1
}

printf 'filesystem.glob: cycles, cousins, path ceilings, errors, and async failure passed\n'
