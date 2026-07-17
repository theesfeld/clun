#!/bin/sh
# Hermetic TLS 1.2-only peer. OpenSSL is a test oracle, never an implementation
# dependency; the Clun client remains pure Common Lisp.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/clun-tls12.XXXXXX")
server_pid=
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT HUP INT TERM

command -v openssl >/dev/null 2>&1 || {
  printf 'TLS 1.2 interop: openssl is required for the hermetic peer\n' >&2
  exit 2
}

port=$(
  sbcl --noinform --non-interactive --no-userinit --no-sysinit \
    --eval '(require :sb-bsd-sockets)' \
    --eval '(let ((s (make-instance (quote sb-bsd-sockets:inet-socket) :type :stream :protocol :tcp))) (unwind-protect (progn (sb-bsd-sockets:socket-bind s (sb-bsd-sockets:make-inet-address "127.0.0.1") 0) (format t "~d" (nth-value 1 (sb-bsd-sockets:socket-name s)))) (sb-bsd-sockets:socket-close s)))'
)

openssl s_server -quiet -www -tls1_2 \
  -accept "127.0.0.1:$port" \
  -cert "$repo_root/tests/fixtures/certs/localhost-leaf.crt" \
  -key "$repo_root/tests/fixtures/certs/localhost-leaf.key" \
  -cipher ECDHE-RSA-AES128-GCM-SHA256 \
  -sigalgs rsa_pkcs1_sha256 \
  >"$scratch/server.log" 2>&1 &
server_pid=$!

# OpenSSL binds before entering its accept loop. A short bounded startup delay
# avoids consuming a connection with a second TLS client (which could wait for
# an HTTP request under -www and turn a readiness probe into a hang).
sleep 0.1
kill -0 "$server_pid" 2>/dev/null || {
  printf 'TLS 1.2 interop: peer exited during startup\n' >&2
  cat "$scratch/server.log" >&2
  exit 1
}

CLUN_TLS12_PORT=$port \
CLUN_TLS12_CA_FILE="$repo_root/tests/fixtures/certs/test-ca.crt" \
  sbcl --non-interactive --no-userinit --no-sysinit \
    --load "$repo_root/scripts/run-tls12-interop.lisp"
