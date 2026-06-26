#!/usr/bin/env bash
# Cron wrapper: skip quietly when Wolf Leader container is not running.
set -euo pipefail

CONTAINER="${IDE_STORAGE_CONTAINER:-ide-storage-ide-storage-1}"
LOG="${IDE_STORAGE_IMPORT_LOG:-./data/ide-storage-import.log}"

running="$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)"
[[ "$running" == "true" ]] || exit 0

docker exec "$CONTAINER" python -m ide_storage.import_all_transcripts --sync >>"$LOG" 2>&1
