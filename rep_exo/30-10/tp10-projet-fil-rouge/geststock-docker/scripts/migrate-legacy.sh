#!/usr/bin/env bash
# migrate-legacy.sh DUMP.sql UPLOADS_DIR - one-shot import of the legacy server data.
# On the legacy server:  mysqldump --single-transaction geststock > geststock-dump.sql
#                        tar czf uploads.tgz -C /var/www/html/uploads .
# The stack must be up. The dump replaces the items table; uploads are added to the volume.
set -euo pipefail
DUMP=$(realpath "${1:?usage: migrate-legacy.sh DUMP.sql UPLOADS_DIR}")
UPLOADS=$(realpath "${2:?usage: migrate-legacy.sh DUMP.sql UPLOADS_DIR}")
cd "$(dirname "$0")/.."
COMPOSE=${COMPOSE:-docker compose}

echo "== import $DUMP"
$COMPOSE exec -T db sh -c 'mariadb -ugeststock -p"$(cat /run/secrets/db_password)" geststock' < "$DUMP"

echo "== copy $(find "$UPLOADS" -type f | wc -l) uploads into the volume"
volume=$(docker inspect "$($COMPOSE ps -q app | head -1)" \
  --format '{{range .Mounts}}{{if eq .Destination "/var/www/html/uploads"}}{{.Name}}{{end}}{{end}}')
# Files must belong to www-data (33): Apache runs as this user and must be able to read them.
docker run --rm -v "$volume:/dst" -v "$UPLOADS:/src:ro" alpine:3.20 \
  sh -c 'cp -a /src/. /dst/ && chown -R 33:33 /dst'

echo "== result"
./scripts/checksum.sh
