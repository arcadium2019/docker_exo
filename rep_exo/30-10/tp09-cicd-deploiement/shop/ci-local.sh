#!/usr/bin/env bash
# ci-local.sh [pr|main] - replays the CI pipeline locally (same stages as .github/workflows/ci.yml).
#   pr   : lint, compose config, tests, build (no push)
#   main : + trivy gate, push sha-<sha> to a local registry, cosign sign + verify
# Differences with the real pipeline: single-arch --load build (the docker driver cannot load a
# multi-arch image), key-based cosign signature (keyless needs the CI OIDC token), no tlog upload.
set -euo pipefail
cd "$(dirname "$0")"
MODE=${1:-main}
SHA=${GIT_SHA:-$(git rev-parse --short=7 HEAD)}
REGISTRY=${REGISTRY:-localhost:5002}
SOURCE=https://git.shop-sas.example/platform/shop
OUT=ci/out
mkdir -p "$OUT"
TRIVY=aquasec/trivy:0.76.1
COSIGN=ghcr.io/sigstore/cosign/cosign:v2.6.5
step() { printf '\n\e[1m== %s\e[0m\n' "$*"; }

step "lint: hadolint"
for app in shopapi shop-worker; do
  docker run --rm -i hadolint/hadolint:v2.15.1 hadolint --failure-threshold error - < "apps/$app/Dockerfile"
  echo "apps/$app/Dockerfile OK"
done

step "lint: docker compose config"
docker compose -f compose.yml config -q && echo "compose.yml OK"
REGISTRY=$REGISTRY VERSION=sha-$SHA docker compose -f compose.yml -f compose.prod.yml config -q && echo "compose.prod.yml OK"

step "test stage"
docker build -q --target test apps/shopapi >/dev/null && echo "shopapi tests OK"
docker build -q --target test --secret id=pipconf,src=ci/pip.conf apps/shop-worker >/dev/null && echo "shop-worker tests OK"

step "build sha-$SHA"
docker build -q -t "$REGISTRY/shopapi:sha-$SHA" \
  --build-arg APP_VERSION="sha-$SHA" --build-arg GIT_SHA="$SHA" --build-arg SOURCE_URL="$SOURCE" apps/shopapi
docker build -q -t "$REGISTRY/shop-worker:sha-$SHA" --secret id=pipconf,src=ci/pip.conf \
  --build-arg VERSION="sha-$SHA" --build-arg GIT_SHA="$SHA" --build-arg SOURCE_URL="$SOURCE" apps/shop-worker
[ "$MODE" = main ] || { step "pull request pipeline OK (no push)"; exit 0; }

step "gate: trivy (HIGH/CRITICAL fixable = fail)"
for app in shopapi shop-worker; do
  docker save -o "$OUT/$app.tar" "$REGISTRY/$app:sha-$SHA"
  docker run --rm -v shop-trivy-cache:/root/.cache/trivy -v "$PWD/$OUT:/out" \
    "$TRIVY" image --quiet \
    --input "/out/$app.tar" --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
    --format json --output "/out/$app-vulns.json" \
    || { echo "$app: GATE FAILED"; jq -r '.Results[]?.Vulnerabilities[]? | "  \(.VulnerabilityID) \(.PkgName) \(.Severity)"' "$OUT/$app-vulns.json"; exit 1; }
  echo "$app: $(jq '[.Results[]?.Vulnerabilities[]?] | length' "$OUT/$app-vulns.json") fixable HIGH/CRITICAL -> pass"
  rm -f "$OUT/$app.tar"
done

step "push to $REGISTRY"
docker ps -q -f name=^ci-registry$ | grep -q . \
  || docker run -d --name ci-registry -p 127.0.0.1:5002:5000 registry:2.8.3 >/dev/null
until curl -sf "http://$REGISTRY/v2/" >/dev/null; do sleep 0.5; done
for app in shopapi shop-worker; do docker push -q "$REGISTRY/$app:sha-$SHA"; done

step "sign + verify (cosign, by digest)"
cosign() { docker run --rm --network host -u "$(id -u):$(id -g)" -e HOME=/tmp -e COSIGN_PASSWORD= -v "$PWD/$OUT:/out" -w /out "$COSIGN" "$@"; }
[ -f "$OUT/cosign.key" ] || cosign generate-key-pair >/dev/null
for app in shopapi shop-worker; do
  digest=$(docker inspect -f '{{index .RepoDigests 0}}' "$REGISTRY/$app:sha-$SHA")
  cosign sign --yes --key cosign.key --tlog-upload=false --allow-http-registry "$digest" 2>/dev/null
  cosign verify --key cosign.pub --insecure-ignore-tlog=true --allow-http-registry "$digest" 2>/dev/null \
    | jq -r '.[0].critical.image."docker-manifest-digest" | "verified: '"$app"'@" + .'
done
step "main pipeline OK: $REGISTRY/{shopapi,shop-worker}:sha-$SHA"
