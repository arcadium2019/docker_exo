#!/usr/bin/env bash
# Prints a fingerprint of the data: items count + md5 of the rows, uploads count + md5 of the files.
set -euo pipefail
cd "$(dirname "$0")/.."
COMPOSE=${COMPOSE:-docker compose}
$COMPOSE exec -T db sh -c 'mariadb -ugeststock -p"$(cat /run/secrets/db_password)" geststock -N -e \
  "SELECT CONCAT(\"items=\", COUNT(*), \" md5=\", MD5(GROUP_CONCAT(id, name, qty, IFNULL(photo, \"\") ORDER BY id SEPARATOR \",\"))) FROM items"'
$COMPOSE exec -T app sh -c 'cd /var/www/html/uploads && printf "uploads=%s md5=%s\n" "$(ls | wc -l)" "$(find . -type f | sort | xargs cat | md5sum | cut -d" " -f1)"'
