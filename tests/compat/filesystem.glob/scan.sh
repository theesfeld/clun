#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
[ -x "$clun" ] || {
  printf 'filesystem.glob: %s is missing\n' "$clun" >&2
  exit 2
}

tmp_base=${TMPDIR:-$repo_root/tmp-test}
if [ ! -d "$tmp_base" ]; then
  tmp_base=$repo_root/tmp-test
  mkdir -p "$tmp_base"
fi
root=$(mktemp -d "$tmp_base/clun-glob.XXXXXX")
trap 'rm -rf "$root"' EXIT HUP INT TERM
mkdir -p "$root/sub" "$root/real" "$root/.hidden"
printf 'a\n' > "$root/a.js"
printf 'z\n' > "$root/z.txt"
printf 'b\n' > "$root/sub/b.js"
printf 'x\n' > "$root/sub/x.txt"
printf 'r\n' > "$root/real/n.js"
printf 'h\n' > "$root/.hidden/h.js"
printf 'd\n' > "$root/.dot.js"
ln -s real "$root/link"
ln -s missing "$root/broken"

actual=$(CLUN_GLOB_FIXTURE=$root "$clun" -e '
const root = process.env.CLUN_GLOB_FIXTURE;
function values(pattern, options) {
  return [...new Clun.Glob(pattern).scanSync(options)].join("|");
}
console.log("default", values("**/*.js", { cwd: root }));
console.log("dot", values("**/*.js", { cwd: root, dot: true }));
console.log("directories", values("**", { cwd: root, onlyFiles: false }));
console.log("explicit-dot", values(".hidden/*.js", { cwd: root }));
console.log("literal-link", values("link/**/*.js", { cwd: root }));
console.log("wildcard-link", values("*/n.js", { cwd: root }));
console.log("follow-link", values("*/n.js", { cwd: root, followSymlinks: true }));
console.log("trailing-dir", values("sub/", { cwd: root, onlyFiles: false }));
console.log("trailing-globstar", values("sub/**", { cwd: root, onlyFiles: false }));
console.log("absolute-literal", values(root + "/a.js"));
console.log("absolute-option", values("sub/*.js", { cwd: root, absolute: true }));
console.log("raw-split", values("{a.js,sub/*}", { cwd: root }).length, values("a\\/b", { cwd: root }).length, values("[a/]", { cwd: root }).length);
console.log("broken-entry", values("broken", { cwd: root, onlyFiles: false }));
try {
  values("broken", { cwd: root, followSymlinks: true, throwErrorOnBrokenSymlink: true });
  console.log("broken-error", "NO_THROW");
} catch (error) {
  console.log("broken-error", error.code, error.syscall, error.path === root + "/broken");
}
(async function () {
  const asyncValues = [];
  for await (const value of new Clun.Glob("**/*.js").scan({ cwd: root })) asyncValues.push(value);
  console.log("async", asyncValues.join("|"));
})();
')

expected="default a.js|real/n.js|sub/b.js
dot .dot.js|.hidden/h.js|a.js|real/n.js|sub/b.js
directories a.js|broken|link|real|real/n.js|sub|sub/b.js|sub/x.txt|z.txt
explicit-dot .hidden/h.js
literal-link link/n.js
wildcard-link real/n.js
follow-link link/n.js|real/n.js
trailing-dir sub
trailing-globstar sub/b.js|sub/x.txt
absolute-literal $root/a.js
absolute-option $root/sub/b.js
raw-split 0 0 0
broken-entry broken
broken-error ENOENT stat true
async a.js|real/n.js|sub/b.js"

[ "$actual" = "$expected" ] || {
  printf 'filesystem.glob: scan output mismatch\nexpected:\n%s\nactual:\n%s\n' \
    "$expected" "$actual" >&2
  exit 1
}

printf 'filesystem.glob: shipped sync/async scan contract passed\n'
