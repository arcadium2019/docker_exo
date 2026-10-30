#!/usr/bin/env bash
# Prints the orders count and checksum (same query as seed.sh) of the current compose project.
set -euo pipefail
COMPOSE=${COMPOSE:-docker compose}
$COMPOSE exec -T db psql -U "${DB_USER:-shop}" -d "${DB_NAME:-shop}" -tA -F ' ' -c \
  "SELECT count(*), md5(string_agg(id::text || status, ',' ORDER BY id)) FROM orders"
