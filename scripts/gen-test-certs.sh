#!/bin/sh
# gen-test-certs.sh — regenerate the hermetic TLS test PKI for Phase 20 (HTTPS).
#
# pure-tls parses/validates certs but cannot GENERATE them, so the test CA + leaves are
# produced offline with openssl and CHECKED IN under tests/fixtures/certs/ (same policy as
# the gzip fixture — openssl is a build-time fixture tool, never a runtime dependency, §1.1).
# Re-run only to refresh the fixtures: `sh scripts/gen-test-certs.sh`. Requires openssl.
#
# Output (tests/fixtures/certs/):
#   test-ca.{key,crt}          self-signed root CA (the trust anchor tests inject)
#   localhost-leaf.{key,crt}   GOOD server cert: CN + SAN localhost / 127.0.0.1, chained to the CA
#   expired.crt                negative: notAfter in the past (else valid, chained)
#   wrong-host.crt             negative: SAN other.example (hostname mismatch), chained
#   self-signed.crt            negative: self-signed leaf (not chained to the CA)
#   bad-chain.crt              negative: signed by a DIFFERENT (untrusted) CA
set -eu
cd "$(dirname "$0")/../tests/fixtures/certs"

subj() { printf "/CN=%s" "$1"; }
leafkey() { openssl req -newkey rsa:2048 -nodes -keyout "$1.key" -out "/tmp/$1.csr" -subj "$(subj "$2")" 2>/dev/null; }
sign() { # csr-name  ca-crt  ca-key  out-crt  extra-x509-args...
  name="$1"; ca="$2"; cak="$3"; out="$4"; shift 4
  openssl x509 -req -in "/tmp/$name.csr" -CA "$ca" -CAkey "$cak" -CAcreateserial -out "$out" "$@" 2>/dev/null
}
san() { printf "subjectAltName=%s" "$1"; }

# --- root CA ---
openssl req -x509 -newkey rsa:2048 -nodes -keyout test-ca.key -out test-ca.crt \
  -days 3650 -subj "$(subj 'Clun Test CA')" 2>/dev/null

# --- GOOD leaf: localhost + 127.0.0.1, chained to the CA ---
leafkey localhost-leaf localhost
sign localhost-leaf test-ca.crt test-ca.key localhost-leaf.crt -days 3650 \
  -extfile /dev/stdin <<EOF
$(san 'DNS:localhost,IP:127.0.0.1')
EOF

# --- NEGATIVE: expired (notAfter in the past) ---
leafkey expired localhost
# -days 1 with a backdated start: use -not_before/-not_after (openssl 1.1.1+/3).
openssl x509 -req -in /tmp/expired.csr -CA test-ca.crt -CAkey test-ca.key -CAcreateserial \
  -out expired.crt -not_before 20200101000000Z -not_after 20200102000000Z \
  -extfile /dev/stdin 2>/dev/null <<EOF
$(san 'DNS:localhost,IP:127.0.0.1')
EOF

# --- NEGATIVE: wrong host (SAN other.example) ---
leafkey wrong-host localhost
sign wrong-host test-ca.crt test-ca.key wrong-host.crt -days 3650 \
  -extfile /dev/stdin <<EOF
$(san 'DNS:other.example')
EOF

# --- NEGATIVE: self-signed leaf (not chained to the CA) ---
openssl req -x509 -newkey rsa:2048 -nodes -keyout self-signed.key -out self-signed.crt \
  -days 3650 -subj "$(subj 'localhost')" -addext "$(san 'DNS:localhost,IP:127.0.0.1')" 2>/dev/null

# --- NEGATIVE: bad chain (signed by a DIFFERENT, untrusted CA) ---
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/rogue-ca.key -out /tmp/rogue-ca.crt \
  -days 3650 -subj "$(subj 'Rogue CA')" 2>/dev/null
leafkey bad-chain localhost
sign bad-chain /tmp/rogue-ca.crt /tmp/rogue-ca.key bad-chain.crt -days 3650 \
  -extfile /dev/stdin <<EOF
$(san 'DNS:localhost,IP:127.0.0.1')
EOF

rm -f *.srl /tmp/*.csr /tmp/rogue-ca.*
echo "test PKI regenerated in tests/fixtures/certs/"
openssl verify -CAfile test-ca.crt localhost-leaf.crt
