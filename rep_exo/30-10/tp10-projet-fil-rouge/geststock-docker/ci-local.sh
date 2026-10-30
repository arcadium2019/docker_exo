#!/usr/bin/env bash
# ci-local.sh - GestStock pipeline: lint -> test -> build -> gate -> integration -> push -> sign.
# Pushes to a disposable local registry (127.0.0.1:5002), key-based cosign (keyless needs CI OIDC).
set -euo pipefail
cd "$(dirname "$0")"
SHA=${GIT_SHA:-$(git rev-parse --short=7 HEAD)}
REGISTRY=${REGISTRY:-localhost:5002}
IMAGE=$REGISTRY/geststock:sha-$SHA
OUT=ci/out
mkdir -p "$OUT"
COSIGN=ghcr.io/sigstore/cosign/cosign:v2.6.5
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

step "lint"
docker run --rm -i hadolint/hadolint:v2.15.1 hadolint --failure-threshold error - < Dockerfile
echo "Dockerfile OK"
docker compose config -q; echo "compose (dev) OK"
REGISTRY=r VERSION=v SMTP_HOST=s docker compose -f compose.yml -f compose.prod.yml -f compose.hardened.yml config -q
echo "compose (prod + hardened) OK"

step "test: php -l (PHP 8.3)"
docker build -q --target test . >/dev/null; echo "php -l OK on every file"

step "build $IMAGE"
docker build -q -t "$IMAGE" --build-arg VERSION="sha-$SHA" --build-arg GIT_SHA="$SHA" .

step "gate: metadata, non-root, healthcheck, trivy"
cfg=$(docker image inspect "$IMAGE" --format '{{json .Config}}')
for l in version revision source; do
  jq -e --arg l "org.opencontainers.image.$l" '.Labels[$l] // "" | length > 0' <<< "$cfg" >/dev/null || fail "label $l"
done
user=$(jq -r '.User' <<< "$cfg"); [[ -n "$user" && ! "$user" =~ ^(root|0) ]] || fail "runs as root"
jq -e '.Healthcheck.Test' <<< "$cfg" >/dev/null || fail "no HEALTHCHECK"
echo "labels OK, user=$user, healthcheck OK"
docker save -o "$OUT/geststock.tar" "$IMAGE"
docker run --rm -v shop-trivy-cache:/root/.cache/trivy -v "$PWD/$OUT:/out" aquasec/trivy:0.76.1 image --quiet \
  --input /out/geststock.tar --scanners vuln,secret --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
  --format json --output /out/geststock-vulns.json \
  || { jq -r '.Results[]?.Vulnerabilities[]? | "  \(.VulnerabilityID) \(.PkgName) \(.Severity)"' "$OUT/geststock-vulns.json"; fail "trivy"; }
echo "trivy: $(jq '[.Results[]?.Vulnerabilities[]?] | length' "$OUT/geststock-vulns.json") fixable HIGH/CRITICAL, $(jq '[.Results[]?.Secrets[]?] | length' "$OUT/geststock-vulns.json") secret"
rm -f "$OUT/geststock.tar"

step "integration: ephemeral stack (prod + hardened), curl, down -v"
CI=(docker compose -p geststock-ci -f compose.yml -f compose.prod.yml -f compose.hardened.yml -f ci/compose.ci.yml)
export REGISTRY VERSION=sha-$SHA SMTP_HOST=localhost
trap '"${CI[@]}" down -v >/dev/null 2>&1' EXIT
"${CI[@]}" up -d --wait >/dev/null 2>&1 || { "${CI[@]}" ps; fail "stack not healthy"; }
app=$("${CI[@]}" ps -q app | head -1)
docker exec "$app" curl -fsS 'http://127.0.0.1:8080/?health' | grep -q OK || fail "health"
docker exec "$app" curl -fsS http://127.0.0.1:8080/ | grep -q 'GestStock' || fail "home page"
docker exec "$app" curl -fsS -o /dev/null -F name=ci-item -F qty=1 http://127.0.0.1:8080/ || fail "add item"
docker exec "$app" curl -fsS http://127.0.0.1:8080/ | grep -q 'ci-item' || fail "item not listed"
"${CI[@]}" exec -T cron php /var/www/geststock/bin/rapport.php | grep -q 'Articles: 5' || fail "rapport"
echo "health OK, home OK, add item OK, rapport OK ($("${CI[@]}" ps -q | wc -l) containers healthy)"
"${CI[@]}" down -v >/dev/null 2>&1; trap - EXIT

step "push + sign + verify"
docker ps -q -f name=^ci-registry$ | grep -q . || docker start ci-registry >/dev/null 2>&1 \
  || docker run -d --name ci-registry -p 127.0.0.1:5002:5000 registry:2.8.3 >/dev/null
until curl -sf "http://$REGISTRY/v2/" >/dev/null; do sleep 0.5; done
docker push -q "$IMAGE"
cosign() { docker run --rm --network host -u "$(id -u):$(id -g)" -e HOME=/tmp -e COSIGN_PASSWORD= -v "$PWD/$OUT:/out" -w /out "$COSIGN" "$@"; }
[ -f "$OUT/cosign.key" ] || cosign generate-key-pair >/dev/null
digest=$(docker inspect -f '{{index .RepoDigests 0}}' "$IMAGE")
cosign sign --yes --key cosign.key --tlog-upload=false --allow-http-registry "$digest" 2>/dev/null
cosign verify --key cosign.pub --insecure-ignore-tlog=true --allow-http-registry "$digest" 2>/dev/null >/dev/null
echo "signed and verified: $digest"
step "pipeline OK: $IMAGE"
