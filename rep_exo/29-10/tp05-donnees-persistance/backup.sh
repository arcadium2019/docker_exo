#!/usr/bin/env bash
# Backup of the `db` service of the current compose project, everything through containers.
#   ./backup.sh          logical dump (pg_dump -Fc), online
#   RAW=1 ./backup.sh    + raw tar of the volume, db stopped during the copy (cold = consistent)
# Keeps the last $KEEP backups of each kind.
set -euo pipefail
COMPOSE=${COMPOSE:-docker compose}
DB_USER=${DB_USER:-shop}
DB_NAME=${DB_NAME:-shop}
KEEP=${KEEP:-7}
DIR=${BACKUP_DIR:-./backups}
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p "$DIR"

dump="$DIR/$DB_NAME-$TS.dump"
$COMPOSE exec -T db pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$dump"
echo "logical dump: $dump ($(du -h "$dump" | cut -f1))"

if [ "${RAW:-0}" = 1 ]; then
  cid=$($COMPOSE ps -q db)
  volume=$(docker inspect "$cid" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}')
  raw="$DIR/$volume-$TS.tar.gz"
  # A copy of a running PG data dir can mix pages from different moments: stop it first.
  $COMPOSE stop db >/dev/null
  # tar writes to stdout, so the archive belongs to the host user, not to root.
  docker run --rm -v "$volume:/data:ro" alpine:3.20 tar czf - -C /data . > "$raw" || status=$?
  $COMPOSE start db >/dev/null
  [ "${status:-0}" = 0 ] || { echo "raw backup failed" >&2; exit 1; }
  echo "raw backup:   $raw ($(du -h "$raw" | cut -f1))"
fi

# Retention: keep the $KEEP most recent files of each kind.
ls -1t "$DIR"/"$DB_NAME"-*.dump 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f --
ls -1t "$DIR"/*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f --
