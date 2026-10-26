#!/usr/bin/env bash
# Generates an internal CA and a server certificate for registry.local (+ localhost for local tests).
set -euo pipefail
cd "$(dirname "$0")/certs"
[ -f ca.key ] || openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout ca.key -out ca.crt -subj "/O=Shop SAS/CN=Shop SAS Internal CA"
openssl req -newkey rsa:2048 -nodes -keyout registry.key -out registry.csr \
  -subj "/O=Shop SAS/CN=registry.local"
cat > registry.ext <<EXT
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:registry.local,DNS:localhost,IP:127.0.0.1
EXT
openssl x509 -req -in registry.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out registry.crt -days 825 -sha256 -extfile registry.ext
rm -f registry.csr registry.ext
chmod 644 registry.key   # read by the nginx worker inside the container (TP only)
openssl x509 -in registry.crt -noout -subject -issuer -ext subjectAltName
