#!/usr/bin/env bash
# retention.sh REPOSITORY [KEEP] [--apply]
# Keeps the KEEP most recent non-semver tags of REPOSITORY and deletes the others (by digest).
# Semver tags (1.4.2, v2.0.0-rc.1, 1.4.2-distroless...) and cosign artifacts (sha256-*.sig/.att)
# are never deleted, nor is any digest still referenced by a protected tag.
# Dry-run unless --apply is given. Run "registry garbage-collect" afterwards to free the blobs.
#
# Env: REG (default https://registry.local:5000), REG_USER / REG_PASSWORD (account allowed to delete),
#      CURL_OPTS (extra curl options, e.g. "--cacert ca.crt").
set -euo pipefail

REPO="${1:?usage: retention.sh REPOSITORY [KEEP] [--apply]}"
KEEP="${2:-3}"
APPLY=false
[[ "${3:-}" == "--apply" || "${2:-}" == "--apply" ]] && APPLY=true
[[ "$KEEP" == "--apply" ]] && KEEP=3

REG="${REG:-https://registry.local:5000}"
AUTH=(-u "${REG_USER:-ci}:${REG_PASSWORD:?set REG_PASSWORD}")
read -r -a EXTRA <<< "${CURL_OPTS:-}"
CURL=(curl -fsS "${EXTRA[@]}" "${AUTH[@]}")
ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"
SEMVER='^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
COSIGN='^sha256-[0-9a-f]{64}(\.sig|\.att|\.sbom)?$'

digest_of() {
  "${CURL[@]}" -I -H "Accept: $ACCEPT" "$REG/v2/$REPO/manifests/$1" \
    | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}' | tr -d '\r'
}

# Creation date from the image config (first platform for a multi-arch index).
created_of() {
  local manifest config
  manifest=$("${CURL[@]}" -H "Accept: $ACCEPT" "$REG/v2/$REPO/manifests/$1")
  if jq -e '.manifests' >/dev/null <<< "$manifest"; then
    manifest=$("${CURL[@]}" -H "Accept: $ACCEPT" "$REG/v2/$REPO/manifests/$(jq -r '.manifests[0].digest' <<< "$manifest")")
  fi
  config=$(jq -r '.config.digest' <<< "$manifest")
  "${CURL[@]}" -L "$REG/v2/$REPO/blobs/$config" | jq -r '.created // "1970-01-01T00:00:00Z"'
}

mapfile -t TAGS < <("${CURL[@]}" "$REG/v2/$REPO/tags/list" | jq -r '.tags // [] | .[]')
declare -A PROTECTED_DIGESTS=()
CANDIDATES=()
for tag in "${TAGS[@]}"; do
  if [[ "$tag" =~ $SEMVER || "$tag" =~ $COSIGN ]]; then
    PROTECTED_DIGESTS["$(digest_of "$tag")"]="$tag"
  else
    CANDIDATES+=("$tag")
  fi
done

# "created<TAB>tag<TAB>digest", newest first
mapfile -t SORTED < <(for tag in "${CANDIDATES[@]}"; do
  printf '%s\t%s\t%s\n' "$(created_of "$tag")" "$tag" "$(digest_of "$tag")"
done | sort -r)

echo "repository=$REPO keep=$KEEP apply=$APPLY protected=${#PROTECTED_DIGESTS[@]} candidates=${#SORTED[@]}"
i=0
declare -A DELETED=()
for line in "${SORTED[@]}"; do
  IFS=$'\t' read -r created tag digest <<< "$line"
  i=$((i + 1))
  if (( i <= KEEP )); then
    echo "KEEP    $tag  ($created)"
    PROTECTED_DIGESTS["$digest"]="$tag"
  elif [[ -n "${PROTECTED_DIGESTS[$digest]:-}" ]]; then
    echo "SKIP    $tag  ($created) same digest as protected tag ${PROTECTED_DIGESTS[$digest]}"
  elif [[ -n "${DELETED[$digest]:-}" ]]; then
    echo "DELETED $tag  ($created) already removed with ${DELETED[$digest]}"
  elif $APPLY; then
    DELETED["$digest"]="$tag"
    "${CURL[@]}" -X DELETE "$REG/v2/$REPO/manifests/$digest" -o /dev/null
    echo "DELETED $tag  ($created) $digest"
  else
    echo "DELETE  $tag  ($created) $digest  [dry-run]"
  fi
done
