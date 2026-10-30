#!/usr/bin/env bash
# measure-downtime.sh [seconds] [rate] - hammers /health through Traefik and counts failures.
#   ./deploy/measure-downtime.sh 40 100      (40 s at ~100 req/s)
set -uo pipefail
DURATION=${1:-30}
RATE=${2:-100}
URL=${URL:-http://api.localhost/health}
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

end=$((SECONDS + DURATION))
while [ $SECONDS -lt $end ]; do
  # One batch of $RATE requests per second, each in the background.
  for _ in $(seq "$RATE"); do
    curl -s -o /dev/null -w '%{http_code}\n' --max-time 2 "$URL" >> "$OUT" &
  done
  sleep 1
done
wait

total=$(wc -l < "$OUT")
ok=$(grep -c '^200$' "$OUT")
echo "requests: $total  ok: $ok  failures: $((total - ok))"
sort "$OUT" | uniq -c | sed 's/^/  /'
