#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
[ -x "$clun" ] || {
  printf 'filesystem.glob stress: %s is missing\n' "$clun" >&2
  exit 2
}

tmp_base=${TMPDIR:-$repo_root/tmp-test}
mkdir -p "$tmp_base"
root=$(mktemp -d "$tmp_base/clun-glob-stress.XXXXXX")
trap 'rm -rf "$root"' EXIT HUP INT TERM
mkdir -p "$root/sub"
printf 'a\n' > "$root/a.txt"
printf 'b\n' > "$root/b.txt"
printf 'c\n' > "$root/sub/c.txt"

actual=$(CLUN_GLOB_FIXTURE=$root "$clun" -e '
const root = process.env.CLUN_GLOB_FIXTURE;
const glob = new Clun.Glob("**/*.txt");
for (let index = 0; index < 10000; index++) {
  if (!glob.match("sub/c.txt")) throw new Error("match stress failed at " + index);
}
console.log("match-stress", 10000);

(async function () {
  const scans = [];
  for (let index = 0; index < 1000; index++) {
    scans.push((async function () {
      const values = [];
      for await (const value of glob.scan({ cwd: root })) values.push(value);
      if (values.join("|") !== "a.txt|b.txt|sub/c.txt") throw new Error("scan stress mismatch");
      return values.length;
    })());
  }
  const counts = await Promise.all(scans);
  console.log("scan-stress", counts.length, counts[0], counts[counts.length - 1]);

  const cancellations = [];
  for (let index = 0; index < 1000; index++) {
    const iterator = glob.scan({ cwd: root });
    const pending = iterator.next();
    const stopped = iterator.return("stopped");
    cancellations.push(Promise.all([pending, stopped]).then(function (steps) {
      if (!steps[0].done || !steps[1].done || steps[1].value !== "stopped") {
        throw new Error("cancellation settlement mismatch");
      }
      return true;
    }));
  }
  const cancelled = await Promise.all(cancellations);
  console.log("cancel-stress", cancelled.length);
})();
')

expected='match-stress 10000
scan-stress 1000 3 3
cancel-stress 1000'
[ "$actual" = "$expected" ] || {
  printf 'filesystem.glob stress mismatch\nexpected:\n%s\nactual:\n%s\n' \
    "$expected" "$actual" >&2
  exit 1
}

printf 'filesystem.glob: 10,000 matches, 1,000 scans, and 1,000 cancellations passed\n'
