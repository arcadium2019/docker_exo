#!/usr/bin/env bash
# bcrypt htpasswd file: ci (push + pull), dev (pull only, enforced by nginx).
set -euo pipefail
cd "$(dirname "$0")/auth"
CI_PASSWORD="${CI_PASSWORD:-ci-push-2024}"
DEV_PASSWORD="${DEV_PASSWORD:-dev-pull-2024}"
{
  docker run --rm --entrypoint htpasswd httpd:2.4-alpine -B -C 10 -bn ci "$CI_PASSWORD"
  docker run --rm --entrypoint htpasswd httpd:2.4-alpine -B -C 10 -bn dev "$DEV_PASSWORD"
} | sed '/^$/d' > htpasswd.tmp
mv htpasswd.tmp htpasswd
cut -d: -f1,2 htpasswd | cut -c1-20
