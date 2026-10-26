#!/usr/bin/env bash
# release-gate.sh IMAGE [--push REGISTRY_IMAGE]
# Refuses to publish an image that does not comply with the Shop SAS policy:
#   - OCI labels version / revision / source present
#   - non-root user
#   - HEALTHCHECK defined
#   - no fixable HIGH/CRITICAL CVE (trivy)
#   - no secret, neither in the layers nor in the image config (trivy + custom rules + Env check)
# If every check passes and --push is given: push, sign (cosign) and attach the SBOM attestation,
# always by digest, then verify the signature.
#
# Exit codes: 0 = released (or compliant without --push), 1 = policy violation, 2 = usage/tooling error.
# Env: COSIGN_KEY (default ./cosign.key), COSIGN_PASSWORD, COSIGN_PUB (default ./cosign.pub),
#      REGISTRY_USER / REGISTRY_PASSWORD (optional: otherwise the tools config must already exist).
set -euo pipefail

usage() { echo "usage: release-gate.sh IMAGE [--push REGISTRY_IMAGE]" >&2; exit 2; }
IMAGE="${1:-}"; [[ -n "$IMAGE" ]] || usage
TARGET=""
if [[ $# -ge 2 ]]; then
  [[ "$2" == "--push" && -n "${3:-}" ]] || usage
  TARGET="$3"
fi

cd "$(dirname "$0")"
# shellcheck source=tools.sh
source ./tools.sh

COSIGN_KEY="${COSIGN_KEY:-cosign.key}"
COSIGN_PUB="${COSIGN_PUB:-cosign.pub}"
REPORT_DIR=".release/$(tr '/:@' '___' <<< "$IMAGE")"
mkdir -p "$REPORT_DIR"

FAILURES=0
pass() { printf '  \e[32mPASS\e[0m %s\n' "$1"; }
fail() { printf '  \e[31mFAIL\e[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
step() { printf '\n== %s\n' "$1"; }

docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "image not found locally: $IMAGE" >&2; exit 2; }
CONFIG=$(docker image inspect "$IMAGE" --format '{{json .Config}}')

step "Metadata ($IMAGE)"
for label in version revision source; do
  value=$(jq -r --arg l "org.opencontainers.image.$label" '.Labels[$l] // empty' <<< "$CONFIG")
  if [[ -z "$value" || "$value" == "unknown" ]]; then
    fail "label org.opencontainers.image.$label missing"
  else
    pass "label org.opencontainers.image.$label=$value"
  fi
done

user=$(jq -r '.User // ""' <<< "$CONFIG")
if [[ -z "$user" || "$user" =~ ^(root|0)(:.*)?$ ]]; then
  fail "runs as root (User='${user}')"
else
  pass "non-root user ($user)"
fi

healthcheck=$(jq -c '.Healthcheck.Test // empty' <<< "$CONFIG")
if [[ -z "$healthcheck" || "$healthcheck" == '["NONE"]' ]]; then
  fail "no HEALTHCHECK"
else
  pass "HEALTHCHECK $healthcheck"
fi

# Env values are visible to anyone who can pull the image (docker inspect / registry config blob).
SECRET_ENV=$(jq -r '.Env[]? // empty' <<< "$CONFIG" \
  | grep -Ei '^[A-Z0-9_]*(PASSWORD|PASSWD|SECRET|TOKEN|API_?KEY|PRIVATE_KEY)[A-Z0-9_]*=.+|://[^:/@]+:[^@/]+@' \
  | sed -E 's/=.*/=***/' || true)
if [[ -n "$SECRET_ENV" ]]; then
  fail "secret in image Env: $(paste -sd' ' <<< "$SECRET_ENV")"
else
  pass "no secret in image Env"
fi

step "Scans (trivy, from a docker save archive)"
ARCHIVE=$(save_image "$IMAGE")
if trivy image --quiet --input "$ARCHIVE" --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed \
     --format json --output "$REPORT_DIR/vulns.json"; then
  count=$(jq '[.Results[]?.Vulnerabilities[]?] | length' "$REPORT_DIR/vulns.json")
  if (( count > 0 )); then
    fail "$count fixable HIGH/CRITICAL CVE(s):"
    jq -r '[.Results[]?.Vulnerabilities[]? | "\(.Severity) \(.PkgName)@\(.InstalledVersion) -> \(.FixedVersion) (\(.VulnerabilityID))"] | unique | .[:10][] | "         " + .' \
      "$REPORT_DIR/vulns.json"
    (( count > 10 )) && echo "         ... see $REPORT_DIR/vulns.json"
  else
    pass "no fixable HIGH/CRITICAL CVE"
  fi
else
  echo "trivy vulnerability scan failed" >&2; exit 2
fi

if trivy image --quiet --input "$ARCHIVE" --scanners secret --image-config-scanners secret \
     --secret-config trivy-secret.yaml --format json --output "$REPORT_DIR/secrets.json"; then
  count=$(jq '[.Results[]?.Secrets[]?] | length' "$REPORT_DIR/secrets.json")
  if (( count > 0 )); then
    fail "$count secret(s) found:"
    jq -r '.Results[]? | .Target as $t | .Secrets[]? | "         \(.Severity) \(.RuleID) in \($t)"' "$REPORT_DIR/secrets.json"
  else
    pass "no secret in layers"
  fi
else
  echo "trivy secret scan failed" >&2; exit 2
fi

if (( FAILURES > 0 )); then
  printf '\n\e[31mREJECTED\e[0m %s: %d policy violation(s). Reports in %s/\n' "$IMAGE" "$FAILURES" "$REPORT_DIR"
  exit 1
fi
printf '\n\e[32mCOMPLIANT\e[0m %s\n' "$IMAGE"

[[ -z "$TARGET" ]] && exit 0

step "Release to $TARGET"
[[ -f "$COSIGN_KEY" ]] || { echo "cosign key not found: $COSIGN_KEY" >&2; exit 2; }
if [[ -n "${REGISTRY_USER:-}" ]]; then
  tools_login "${TARGET%%/*}" "$REGISTRY_USER" "${REGISTRY_PASSWORD:?}"
fi

syft "docker-archive:$ARCHIVE" -q -o spdx-json > "$REPORT_DIR/sbom.spdx.json"
pass "SBOM: $(jq '.packages | length' "$REPORT_DIR/sbom.spdx.json") packages"

docker tag "$IMAGE" "$TARGET"
docker push -q "$TARGET" >/dev/null
# Sign what is actually in the registry: resolve the digest there, never trust the tag afterwards.
DIGEST=$(crane digest "$TARGET")
REF="${TARGET%:*}@$DIGEST"
[[ "$TARGET" == *@* ]] && REF="$TARGET"
pass "pushed $REF"

cosign sign --yes --key "$COSIGN_KEY" --tlog-upload=false "$REF" >/dev/null 2>&1
pass "signed"
cosign attest --yes --key "$COSIGN_KEY" --tlog-upload=false --type spdxjson \
  --predicate "$REPORT_DIR/sbom.spdx.json" "$REF" >/dev/null 2>&1
pass "SBOM attestation attached"

if [[ -f "$COSIGN_PUB" ]]; then
  if cosign verify --key "$COSIGN_PUB" --insecure-ignore-tlog=true "$REF" >/dev/null 2>&1; then
    pass "signature verified"
  else
    fail "signature verification"; exit 1
  fi
fi
echo "$REF" > "$REPORT_DIR/released-ref"
printf '\n\e[32mRELEASED\e[0m %s\n' "$REF"
