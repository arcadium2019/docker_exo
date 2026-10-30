#!/usr/bin/env bash
# Load generator: ./load.sh [requests] [parallelism]   (through Traefik)
set -euo pipefail
N=${1:-1000}
P=${2:-20}
URL=${URL:-http://api.localhost}
seq "$N" | xargs -P "$P" -I{} sh -c '
  if [ $(({} % 5)) -eq 0 ]; then
    curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" \
      -d "{\"productId\":$(({} % 3 + 1)),\"quantity\":1}" "$0/orders"
  else
    curl -s -o /dev/null -w "%{http_code}\n" "$0/products"
  fi' "$URL" | sort | uniq -c
