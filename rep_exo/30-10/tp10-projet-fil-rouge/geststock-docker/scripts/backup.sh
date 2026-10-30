#!/usr/bin/env bash
# backup.sh - consistent online backup: SQL dump (InnoDB snapshot) + uploads archive. Keeps $KEEP.
set -euo pipefail
cd "$(dirname "$0")/.."
COMPOSE=${COMPOSE:-docker compose}
DIR=${BACKUP_DIR:-./backups}
KEEP=${KEEP:-7}
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p "$DIR"

# --single-transaction: consistent snapshot without locking the app (InnoDB only, which is the case).
$COMPOSE exec -T db sh -c 'mariadb-dump -ugeststock -p"$(cat /run/secrets/db_password)" --single-transaction --routines geststock' \
  | gzip > "$DIR/db-$TS.sql.gz"
volume=$(docker inspect "$($COMPOSE ps -q app | head -1)" \
  --format '{{range .Mounts}}{{if eq .Destination "/var/www/html/uploads"}}{{.Name}}{{end}}{{end}}')
docker run --rm -v "$volume:/data:ro" alpine:3.20 tar czf - -C /data . > "$DIR/uploads-$TS.tar.gz"
echo "backup $TS: $(du -h "$DIR/db-$TS.sql.gz" | cut -f1) db, $(du -h "$DIR/uploads-$TS.tar.gz" | cut -f1) uploads"

ls -1t "$DIR"/db-*.sql.gz | tail -n +$((KEEP + 1)) | xargs -r rm -f --
ls -1t "$DIR"/uploads-*.tar.gz | tail -n +$((KEEP + 1)) | xargs -r rm -f --
