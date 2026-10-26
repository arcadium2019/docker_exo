# Source me: common settings for talking to the registry API with curl.
# shellcheck shell=bash
# shellcheck disable=SC2034  # variables meant to be used by the sourcing shell
REG="${REG:-https://registry.local:5000}"
REG_HOSTPORT="${REG#https://}"
CURL=(curl -fsS --cacert "$(dirname "${BASH_SOURCE[0]}")/registry/trust/ca.crt" --resolve "${REG_HOSTPORT}:127.0.0.1")
ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"
