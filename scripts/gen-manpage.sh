#!/bin/sh
# Generate docs/man/clun.1 from the live binary catalog (`clun --emit-man`).
# Hard rule: man page matches actual CLI functionality. Do not hand-edit the
# generated file; change src/cli/catalog.lisp and re-run `make man`.

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
binary=${CLUN_BINARY:-$repo_root/build/clun}
out=${1:-$repo_root/docs/man/clun.1}

if [ ! -x "$binary" ]; then
  printf 'gen-manpage: missing executable %s (run make build)\n' "$binary" >&2
  exit 1
fi

mkdir -p "$(dirname -- "$out")"
tmp=$(mktemp "${TMPDIR:-/tmp}/clun-man.XXXXXX")
# Disable CLI chrome so the man page is plain roff.
if ! NO_COLOR=1 "$binary" --emit-man >"$tmp"; then
  rm -f "$tmp"
  printf 'gen-manpage: %s --emit-man failed\n' "$binary" >&2
  exit 1
fi

# Sanity: must look like a section-1 page and include catalog markers.
grep -Eq '^\.TH CLUN 1' "$tmp" || {
  rm -f "$tmp"
  printf 'gen-manpage: output is not a clun section-1 man page\n' >&2
  exit 1
}
grep -Fq 'clun run' "$tmp" || {
  rm -f "$tmp"
  printf 'gen-manpage: output missing expected command rows\n' >&2
  exit 1
}

mv "$tmp" "$out"
printf 'gen-manpage: wrote %s\n' "$out"
