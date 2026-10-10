#!/bin/bash
# Nightly Wolf Leader maintenance: distill all specs/briefs + rotate DB backups.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTAINER="${IDE_STORAGE_CONTAINER:-wolf-leader}"
API="${IDE_STORAGE_URL:-http://127.0.0.1:6971}"
LOG="${IDE_STORAGE_NIGHTLY_LOG:-$ROOT/data/nightly.log}"
DB="${IDE_STORAGE_DB_PATH_HOST:-$ROOT/data/ide-work.db}"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

{
  echo "=== nightly $(ts) ==="
  curl -sf --max-time 300 -X POST "${API}/api/projects/distill-all" | head -c 2000
  echo ""
  if [ -f "$DB" ]; then
    cp -f "$DB" "${DB%.db}-backup-$(date -u +%Y%m%d).db" 2>/dev/null || true
    ls -1 "${DB%.db}"-backup-*.db 2>/dev/null | sort | head -n -7 | xargs -r rm -f
    echo "db backup ok"
  fi
  docker exec "$CONTAINER" python -m ide_storage.install_git_hooks 2>/dev/null || true
  echo "done $(ts)"
} >> "$LOG" 2>&1
