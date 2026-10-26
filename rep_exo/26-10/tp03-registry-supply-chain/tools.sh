# shellcheck shell=bash
# Source me: supply-chain tools run as containers (nothing to install on the host).
# - local images are scanned from a `docker save` archive: no Docker socket mounted in the tools;
# - registry credentials come from a dedicated DOCKER_CONFIG holding only the CI account
#   (never mount ~/.docker/config.json and all its credentials into a third-party image);
# - TLS to the private registry is verified against the internal CA.
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DOCKER_CONFIG="${TOOLS_DOCKER_CONFIG:-$TOOLS_DIR/.tools-docker}"
TRIVY_IMAGE=aquasec/trivy:0.76.1
SYFT_IMAGE=anchore/syft:v1.55.0
COSIGN_IMAGE=ghcr.io/sigstore/cosign/cosign:v2.6.5
CRANE_IMAGE=gcr.io/go-containerregistry/crane:v0.22.1

# tools_login HOST:PORT USER PASSWORD -> writes an isolated auth file for the tools
tools_login() {
  mkdir -p "$TOOLS_DOCKER_CONFIG"
  local auth
  auth=$(printf '%s:%s' "$2" "$3" | base64 -w0)
  jq -n --arg h "$1" --arg a "$auth" '{auths: {($h): {auth: $a}}}' > "$TOOLS_DOCKER_CONFIG/config.json"
  chmod 644 "$TOOLS_DOCKER_CONFIG/config.json"
}

# _tool IMAGE [extra docker run args...] -- [tool args...]
_tool() {
  local image=$1; shift
  local extra=()
  while [[ $# -gt 0 && $1 != "--" ]]; do extra+=("$1"); shift; done
  shift
  docker run --rm --network host -w /work \
    -v "$PWD:/work:Z" \
    -v "$TOOLS_DIR/registry/trust/ca.crt:/etc/ssl/certs/shop-ca.crt:ro,Z" -e SSL_CERT_FILE=/etc/ssl/certs/shop-ca.crt \
    -v "$TOOLS_DOCKER_CONFIG:/docker:ro,Z" -e DOCKER_CONFIG=/docker \
    "${extra[@]}" "$image" "$@"
}

crane()  { _tool "$CRANE_IMAGE" -- "$@"; }
syft()   { _tool "$SYFT_IMAGE" -- "$@"; }
# Runs as the calling user so generated keys/bundles in $PWD stay owned by them.
cosign() { _tool "$COSIGN_IMAGE" -u "$(id -u):$(id -g)" -e HOME=/tmp -e COSIGN_PASSWORD="${COSIGN_PASSWORD-}" -- "$@"; }
# Vulnerability DB cached in a named volume (downloaded once).
trivy()  { _tool "$TRIVY_IMAGE" -v shop-trivy-cache:/root/.cache/trivy -- "$@"; }

# save_image IMAGE -> prints the path of a docker-archive tarball (in $PWD/.scan/, relative for the tools)
save_image() {
  mkdir -p .scan
  local f
  f=".scan/$(tr '/:@' '___' <<< "$1").tar"
  docker save -o "$f" "$1" && echo "$f"
}
