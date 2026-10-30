#!/usr/bin/env bash
# rolling-update.sh - replaces the api replicas one at a time with ${REGISTRY}/shopapi:${VERSION}.
#   VERSION=sha-abc1234 ./deploy/rolling-update.sh
# For each old replica: start one new replica, wait until it is healthy (so Traefik routes to it),
# then stop the old one gracefully (SIGTERM, 15 s) and remove it.
set -euo pipefail
cd "$(dirname "$0")/.."
COMPOSE=(docker compose -f compose.yml -f compose.prod.yml)
: "${VERSION:?VERSION must be set}"
export VERSION

wait_healthy() {
  local id=$1
  for _ in $(seq 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$id")" = healthy ] && return 0
    sleep 1
  done
  echo "replica $id never became healthy" >&2
  return 1
}

image="$(docker compose -f compose.yml -f compose.prod.yml config --images | grep shopapi)"
echo "== target image: $image"

# Never deploy an unsigned image (VERIFY=0 when the CI job already verified it, keyless).
if [ "${VERIFY:-1}" = 1 ]; then
  docker run --rm --network host -v "$PWD/ci/out/cosign.pub:/cosign.pub:ro" ghcr.io/sigstore/cosign/cosign:v2.6.5 \
    verify --key /cosign.pub --insecure-ignore-tlog=true --allow-http-registry "$image" >/dev/null 2>&1 \
    || { echo "signature verification FAILED for $image: abort" >&2; exit 1; }
  echo "== signature verified"
fi
old=$("${COMPOSE[@]}" ps -q api)
n=$(wc -w <<< "$old")
[ "$n" -ge 1 ] || { echo "no api replica running" >&2; exit 1; }
start=$SECONDS

for id in $old; do
  echo "-- replacing $(docker inspect -f '{{.Name}}' "$id" | tr -d /)"
  before=$("${COMPOSE[@]}" ps -q api | sort)
  # --no-recreate keeps the running replicas, the extra one is created from the new configuration.
  "${COMPOSE[@]}" up -d --no-deps --no-recreate --scale api=$(($(wc -l <<< "$before") + 1)) api 2>/dev/null
  new=$(comm -13 <(echo "$before") <("${COMPOSE[@]}" ps -q api | sort))
  wait_healthy "$new"
  sleep 3   # at least one Traefik health check (2 s) on the new replica before the old one leaves
  docker stop -t 15 "$id" >/dev/null
  docker rm "$id" >/dev/null
done

echo "== done in $((SECONDS - start)) s"
"${COMPOSE[@]}" ps api --format '{{.Name}} {{.Image}} {{.Status}}'
