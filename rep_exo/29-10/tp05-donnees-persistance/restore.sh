#!/usr/bin/env bash
# Restores a pg_dump -Fc file into the `db` service of the current compose project.
#   ./restore.sh                     latest dump of ./backups
#   ./restore.sh backups/shop-X.dump
set -euo pipefail
COMPOSE=${COMPOSE:-docker compose}
DB_USER=${DB_USER:-shop}
DB_NAME=${DB_NAME:-shop}
DIR=${BACKUP_DIR:-./backups}
dump=${1:-$(ls -1t "$DIR"/"$DB_NAME"-*.dump | head -1)}
[ -f "$dump" ] || { echo "no dump found" >&2; exit 1; }

echo "restoring $dump"
$COMPOSE up -d --wait db >/dev/null
$COMPOSE exec -T db pg_restore -U "$DB_USER" -d "$DB_NAME" --clean --if-exists --no-owner --exit-on-error < "$dump"
echo "restore done"
