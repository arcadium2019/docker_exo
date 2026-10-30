#!/usr/bin/env bash
# restore.sh [TIMESTAMP] - restores db-TS.sql.gz and uploads-TS.tar.gz (latest by default).
set -euo pipefail
cd "$(dirname "$0")/.."
COMPOSE=${COMPOSE:-docker compose}
DIR=${BACKUP_DIR:-./backups}
TS=${1:-$(ls -1t "$DIR"/db-*.sql.gz | head -1 | sed -E 's#.*/db-(.*)\.sql\.gz#\1#')}
[ -f "$DIR/db-$TS.sql.gz" ] && [ -f "$DIR/uploads-$TS.tar.gz" ] || { echo "backup $TS not found" >&2; exit 1; }

echo "== restore $TS"
$COMPOSE up -d --wait db app >/dev/null
gunzip -c "$DIR/db-$TS.sql.gz" | $COMPOSE exec -T db sh -c 'mariadb -ugeststock -p"$(cat /run/secrets/db_password)" geststock'
volume=$(docker inspect "$($COMPOSE ps -q app | head -1)" \
  --format '{{range .Mounts}}{{if eq .Destination "/var/www/html/uploads"}}{{.Name}}{{end}}{{end}}')
docker run --rm -i -v "$volume:/data" alpine:3.20 sh -c 'find /data -mindepth 1 -delete && tar xzf - -C /data && chown -R 33:33 /data' \
  < "$DIR/uploads-$TS.tar.gz"
echo "== restored"
