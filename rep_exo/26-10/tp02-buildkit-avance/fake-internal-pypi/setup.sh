#!/usr/bin/env bash
# Recreates the simulated authenticated internal PyPI used in TP02 step 1 (leak demonstration).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p packages
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD/../shop-worker:/src:ro" -v "$PWD/packages:/pk" \
  python:3.12 pip download -q -d /pk -r /src/requirements-dev.txt
docker run --rm --entrypoint htpasswd httpd:2.4-alpine -bn svc-ci 'Tr3sS3cret' > htpasswd.tmp
mv htpasswd.tmp htpasswd
chmod 644 htpasswd
chmod -R a+rX packages
docker compose up -d
