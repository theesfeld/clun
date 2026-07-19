#!/bin/sh
# Hermetic TLS 1.2-only peer. OpenSSL is a test oracle, never an implementation
# dependency; the Clun client remains pure Common Lisp.
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/clun-tls12.XXXXXX")
server_pid=
upload_server_pid=
responder_pid=
cleanup() {
  cleanup_status=$?
  exec 3>&- 2>/dev/null || true
  if [ -n "$responder_pid" ]; then
    kill "$responder_pid" 2>/dev/null || true
    wait "$responder_pid" 2>/dev/null || true
  fi
  if [ -n "$upload_server_pid" ]; then
    kill "$upload_server_pid" 2>/dev/null || true
    wait "$upload_server_pid" 2>/dev/null || true
  fi
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [ "$cleanup_status" -ne 0 ] && [ -s "$scratch/upload-server.log" ]; then
    cat "$scratch/upload-server.log" >&2
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT HUP INT TERM

command -v openssl >/dev/null 2>&1 || {
  printf 'TLS 1.2 interop: openssl is required for the hermetic peer\n' >&2
  exit 2
}

free_port() {
  sbcl --noinform --non-interactive --no-userinit --no-sysinit \
    --eval '(require :sb-bsd-sockets)' \
    --eval '(let ((s (make-instance (quote sb-bsd-sockets:inet-socket) :type :stream :protocol :tcp))) (unwind-protect (progn (sb-bsd-sockets:socket-bind s (sb-bsd-sockets:make-inet-address "127.0.0.1") 0) (format t "~d" (nth-value 1 (sb-bsd-sockets:socket-name s)))) (sb-bsd-sockets:socket-close s)))'
}

port=$(free_port)
upload_port=$(free_port)
while [ "$upload_port" = "$port" ]; do
  upload_port=$(free_port)
done

openssl s_server -quiet -www -tls1_2 \
  -accept "127.0.0.1:$port" \
  -cert "$repo_root/tests/fixtures/certs/localhost-leaf.crt" \
  -key "$repo_root/tests/fixtures/certs/localhost-leaf.key" \
  -cipher ECDHE-RSA-AES128-GCM-SHA256 \
  -sigalgs rsa_pkcs1_sha256 \
  >"$scratch/server.log" 2>&1 &
server_pid=$!

mkfifo "$scratch/upload-input"
: >"$scratch/upload-request.log"
# The client first attempts TLS 1.3, receives protocol_version, then reconnects
# for TLS 1.2 before reading the non-replayable request source.
openssl s_server -quiet -tls1_2 -naccept 2 \
  -accept "127.0.0.1:$upload_port" \
  -cert "$repo_root/tests/fixtures/certs/localhost-leaf.crt" \
  -key "$repo_root/tests/fixtures/certs/localhost-leaf.key" \
  -cipher ECDHE-RSA-AES128-GCM-SHA256 \
  -sigalgs rsa_pkcs1_sha256 \
  <"$scratch/upload-input" \
  >"$scratch/upload-request.log" 2>"$scratch/upload-server.log" &
upload_server_pid=$!
exec 3>"$scratch/upload-input"

# Wait until OpenSSL has decrypted the streamed payload, then return one bounded
# HTTP response over the same authenticated TLS 1.2 connection.
(
  attempts=0
  while ! grep -aFq 'tls12-' "$scratch/upload-request.log"; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 6000 ]; then
      printf 'TLS 1.2 upload peer did not receive the request body\n' >&2
      exit 1
    fi
    kill -0 "$upload_server_pid" 2>/dev/null || exit 1
    sleep 0.02
  done
  printf 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok' >&3
) &
responder_pid=$!

# OpenSSL binds before entering its accept loop. A short bounded startup delay
# avoids consuming a connection with a second TLS client (which could wait for
# an HTTP request under -www and turn a readiness probe into a hang).
sleep 0.1
kill -0 "$server_pid" 2>/dev/null || {
  printf 'TLS 1.2 interop: peer exited during startup\n' >&2
  cat "$scratch/server.log" >&2
  exit 1
}
kill -0 "$upload_server_pid" 2>/dev/null || {
  printf 'TLS 1.2 upload peer exited during startup\n' >&2
  cat "$scratch/upload-server.log" >&2
  exit 1
}

CLUN_TLS12_PORT=$port \
CLUN_TLS12_UPLOAD_PORT=$upload_port \
CLUN_TLS12_CA_FILE="$repo_root/tests/fixtures/certs/test-ca.crt" \
  sbcl --non-interactive --no-userinit --no-sysinit \
    --load "$repo_root/scripts/run-tls12-interop.lisp"

wait "$responder_pid"
responder_pid=
exec 3>&-
wait "$upload_server_pid"
upload_server_pid=

grep -aFq 'Transfer-Encoding: chunked' "$scratch/upload-request.log" || {
  printf 'TLS 1.2 upload omitted chunked request framing\n' >&2
  exit 1
}
wire_hex=$(od -An -v -tx1 "$scratch/upload-request.log" | tr -d ' \n')
case "$wire_hex" in
  *360d0a746c7331322d0d0a360d0a75706c6f61640d0a300d0a0d0a*) ;;
  *)
    printf 'TLS 1.2 upload payload framing did not match the streamed chunks\n' >&2
    exit 1
    ;;
esac
