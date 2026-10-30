#!/usr/bin/env bash
# Smoke test through Traefik: readiness, cache, order processed by the worker.
set -euo pipefail
BASE=${BASE:-http://api.localhost}
COMPOSE=${COMPOSE:-docker compose}

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "1. /ready"
curl -fsS "$BASE/ready" | grep -q '"status":"ready"' || fail "/ready"

echo "2. /products cache"
curl -fsS -o /dev/null "$BASE/products"
curl -fsS -D - -o /dev/null "$BASE/products" | grep -qi '^x-cache: HIT' || fail "no cache HIT"

echo "3. POST /orders"
curl -fsS -X POST -H 'Content-Type: application/json' -d '{"productId":3,"quantity":2}' "$BASE/orders" >/dev/null

echo "4. order confirmed by the worker"
for _ in $(seq 1 10); do
  status=$($COMPOSE exec -T db psql -U shop -d shop -tAc "SELECT status FROM orders ORDER BY id DESC LIMIT 1")
  [ "$status" = confirmed ] && { echo "OK: smoke test passed"; exit 0; }
  sleep 1
done
fail "last order is '$status', expected confirmed"
