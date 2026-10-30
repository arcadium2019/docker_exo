#!/usr/bin/env bash
# PostgreSQL 14 -> 16 upgrade by dump/restore onto a new volume.
# Rollback: docker compose -f compose.yml up -d --wait db   (PG14 container on the untouched pgdata volume)
set -euo pipefail
OLD="docker compose -f compose.yml"
NEW="docker compose -f compose.yml -f compose.pg16.yml"
DIR=${BACKUP_DIR:-./backups}
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p "$DIR"

echo "== 1. checksum before"
$OLD up -d --wait db >/dev/null
$OLD exec -T db postgres --version
before=$(COMPOSE="$OLD" ./checksum.sh)
echo "$before"

echo "== 2. dumps"
$OLD exec -T db pg_dumpall -U shop > "$DIR/upgrade-$TS-all.sql"
$OLD exec -T db pg_dump -U shop -d shop -Fc > "$DIR/upgrade-$TS-shop.dump"
ls -l "$DIR"/upgrade-"$TS"-*

echo "== 3. stop PG14 (volume kept)"
$OLD stop db

echo "== 4. PG16 on a new volume"
$NEW up -d --wait db
$NEW exec -T db postgres --version

echo "== 5. restore"
$NEW exec -T db pg_restore -U shop -d shop --no-owner --exit-on-error < "$DIR/upgrade-$TS-shop.dump"

echo "== 6. checksum after"
after=$(COMPOSE="$NEW" ./checksum.sh)
echo "$after"

if [ "$before" = "$after" ]; then
  echo "VERDICT: OK, no data loss"
else
  echo "VERDICT: MISMATCH, roll back with: $OLD up -d --wait db" >&2
  exit 1
fi
