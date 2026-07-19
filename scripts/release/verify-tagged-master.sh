#!/bin/sh

set -eu

if [ "$#" -ne 2 ]; then
  printf 'usage: %s <tagged-commit-sha> <origin-master-sha>\n' "$0" >&2
  exit 2
fi

tagged_commit=$1
master_commit=$2

fail() {
  printf 'release-tagged-master-check: %s\n' "$*" >&2
  exit 1
}

for commit in "$tagged_commit" "$master_commit"; do
  printf '%s\n' "$commit" | LC_ALL=C grep -Eq '^[0-9a-f]{40}$' ||
    fail 'both commits must be full lowercase SHAs'
done

[ "$tagged_commit" = "$master_commit" ] ||
  fail "tag peels to $tagged_commit but origin/master is $master_commit"

printf 'release-tagged-master-check: tag and origin/master both resolve to %s\n' \
  "$tagged_commit"
