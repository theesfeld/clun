#!/bin/sh
# Fail if docs/man/clun.1 drifts from the live CLI catalog, or if parse-cli
# subcommand tokens are missing from the man page.
# Hard project rule: man page always matches actual current functionality.

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
binary=${CLUN_BINARY:-$repo_root/build/clun}
checked_in=$repo_root/docs/man/clun.1

fail() {
  printf 'man-check: %s\n' "$*" >&2
  exit 1
}

[ -x "$binary" ] || fail "missing executable $binary (run make build)"
[ -f "$checked_in" ] || fail "missing $checked_in (run make man)"

tmp=$(mktemp "${TMPDIR:-/tmp}/clun-man-check.XXXXXX")
trap 'rm -f "$tmp"' EXIT

NO_COLOR=1 "$binary" --emit-man >"$tmp" || fail "$binary --emit-man failed"

if ! cmp -s "$checked_in" "$tmp"; then
  diff -u "$checked_in" "$tmp" >&2 || :
  fail "docs/man/clun.1 is out of date; run: make man"
fi

# Every catalogued usage line must appear in --help (plain text).
help_txt=$(mktemp "${TMPDIR:-/tmp}/clun-help.XXXXXX")
trap 'rm -f "$tmp" "$help_txt"' EXIT
NO_COLOR=1 "$binary" --help >"$help_txt" 2>/dev/null || fail "$binary --help failed"

# Spot-check core commands and flags in both help and man.
for needle in \
  'clun run' \
  'clun install' \
  'clun test' \
  'clun build' \
  'clun update' \
  '--cwd' \
  '--update' \
  '--check-update' \
  '--help'
do
  grep -Fq -- "$needle" "$help_txt" || fail "--help missing expected text: $needle"
  grep -Fq -- "$needle" "$checked_in" || fail "man page missing expected text: $needle"
done

# Subcommand tokens from parse-cli-args must be mentioned somewhere in the man page
# (usage rows use human labels like "clun fmt / lint"; tokens still appear in related lines).
for tok in run test install add remove publish exec build compile fmt lint tsc update; do
  grep -Eq -- "(^|[[:space:]/.])${tok}([[:space:]/.]|$)" "$checked_in" ||
    fail "man page missing subcommand token coverage: $tok"
done

printf 'man-check: docs/man/clun.1 matches live CLI catalog\n'
