#!/usr/bin/env bash
# Rebuild + restart the Wolf Leader stack inside the hub LXC (/opt/wolf-leader).
# Run inside the container. Only touches this LXC's own containers and files.
set -euo pipefail
cd "$(dirname "$0")/.."

# Files may arrive from a Windows checkout with CRLF; Linux tools need LF.
find . -path ./wiki/node_modules -prune -o -type f \
  \( -name '*.sh' -o -name '*.py' -o -name '*.yml' -o -name 'Dockerfile' -o -name '.dockerignore' -o -name '.env' \) \
  -print0 | xargs -0 sed -i 's/\r$//'

docker compose -f docker-compose.postgres.yml up -d --build 2>&1 | tail -n 8
sleep 30
docker compose -f docker-compose.postgres.yml ps
echo
curl -s http://127.0.0.1:6971/health; echo
