#!/usr/bin/env bash
# rolling-update.sh - zero-downtime update of GestStock to ${REGISTRY}/geststock:${VERSION}.
#   VERSION=sha-abc1234 ./scripts/rolling-update.sh
# 1. verify the signature, 2. replace the app replicas one at a time (new one healthy before the
# old one stops gracefully), 3. recreate cron (a missed minute of cron is harmless: daily job).
set -euo pipefail
cd "$(dirname "$0")/.."
COMPOSE=(docker compose -f compose.yml -f compose.prod.yml -f compose.hardened.yml)
: "${VERSION:?VERSION must be set}"
export VERSION

wait_healthy() {
  for _ in $(seq 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$1")" = healthy ] && return 0
    sleep 1
  done
  echo "replica $1 never became healthy" >&2
  return 1
}

image=$("${COMPOSE[@]}" config --images | grep geststock | sort -u)
echo "== target image: $image"
if [ "${VERIFY:-1}" = 1 ]; then
  docker run --rm --network host -v "$PWD/ci/out/cosign.pub:/cosign.pub:ro" ghcr.io/sigstore/cosign/cosign:v2.6.5 \
    verify --key /cosign.pub --insecure-ignore-tlog=true --allow-http-registry "$image" >/dev/null 2>&1 \
    || { echo "signature verification FAILED for $image: abort" >&2; exit 1; }
  echo "== signature verified"
fi

start=$SECONDS
for id in $("${COMPOSE[@]}" ps -q app); do
  echo "-- replacing $(docker inspect -f '{{.Name}}' "$id" | tr -d /)"
  before=$("${COMPOSE[@]}" ps -q app | sort)
  "${COMPOSE[@]}" up -d --no-deps --no-recreate --scale app=$(($(wc -l <<< "$before") + 1)) app 2>/dev/null
  new=$(comm -13 <(echo "$before") <("${COMPOSE[@]}" ps -q app | sort))
  wait_healthy "$new"
  sleep 3   # one Traefik health check (2 s) on the new replica before the old one leaves
  # SIGTERM, not the image STOPSIGNAL (SIGWINCH = graceful-stop): during a graceful stop Apache keeps
  # its listening socket open without serving it, connections hang and the retry never triggers.
  # With SIGTERM the socket closes at once: refused, then retried on the other replica by Traefik.
  docker stop -s SIGTERM -t 15 "$id" >/dev/null
  docker rm "$id" >/dev/null
done
"${COMPOSE[@]}" up -d --no-deps --wait cron >/dev/null 2>&1

echo "== done in $((SECONDS - start)) s"
"${COMPOSE[@]}" ps app cron --format '{{.Name}} {{.Image}} {{.Status}}'
