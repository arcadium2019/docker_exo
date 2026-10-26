#!/usr/bin/env bash
# Client-side setup (needs sudo): trust the internal CA, resolve registry.local, use the mirror.
# Restarting dockerd stops every running container (restart policies bring them back).
set -euo pipefail
cd "$(dirname "$0")"
sudo install -d /etc/docker/certs.d/registry.local:5000
sudo install -m 644 certs/ca.crt /etc/docker/certs.d/registry.local:5000/ca.crt
grep -q 'registry.local' /etc/hosts || echo '127.0.0.1 registry.local' | sudo tee -a /etc/hosts
if [ -f /etc/docker/daemon.json ]; then
  echo "/etc/docker/daemon.json exists: merge registry-mirrors by hand" >&2
else
  sudo install -m 644 daemon.json /etc/docker/daemon.json
  sudo systemctl restart docker
fi
docker info --format '{{json .RegistryConfig.Mirrors}}'
