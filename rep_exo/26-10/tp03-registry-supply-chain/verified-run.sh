#!/usr/bin/env bash
# verified-run.sh [docker run options...] IMAGE [command...]
# Policy as code, poor man's version: refuses to start an image whose signature does not verify
# against the Shop SAS public key. The image is resolved to a digest first and the container is
# started from that digest, so the tag cannot be moved between verification and run (TOCTOU).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools.sh
source "$here/tools.sh"
COSIGN_PUB="${COSIGN_PUB:-$here/cosign.pub}"

# Split docker run options from IMAGE: the first argument that does not start with "-"
# and is not the value of an option taking one.
opts=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env|-p|--publish|-v|--volume|--name|-u|--user|-w|--workdir|--network|--entrypoint|-l|--label|--env-file|--mount|--restart)
      opts+=("$1" "$2"); shift 2 ;;
    -*) opts+=("$1"); shift ;;
    *) break ;;
  esac
done
IMAGE="${1:?usage: verified-run.sh [docker run options] IMAGE [command...]}"; shift

digest=$(cd "$here" && crane digest "$IMAGE") || { echo "verified-run: cannot resolve $IMAGE in the registry" >&2; exit 125; }
# Repository name without tag/digest (a ":" after the last "/" is a tag, before it a registry port).
name="${IMAGE%%@*}"
[[ "${name##*/}" == *:* ]] && name="${name%:*}"
ref="$name@$digest"

if ! (cd "$here" && cosign verify --key "$(basename "$COSIGN_PUB")" --insecure-ignore-tlog=true "$ref" >/dev/null 2>&1); then
  echo "verified-run: REFUSED $IMAGE ($digest): no valid Shop SAS signature" >&2
  exit 126
fi
echo "verified-run: signature OK for $ref" >&2
exec docker run "${opts[@]}" "$ref" "$@"
