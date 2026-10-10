#!/usr/bin/env bash
# stop: sync transcript and checkpoint to Wolf Leader (never block session close).
set -euo pipefail

ENV_FILE="${HOME}/.cursor/wolf-leader.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

API="${WOLF_LEADER_API_LOCAL:-${WOLF_LEADER_API:-http://127.0.0.1:6971}}"
LOG="${HOME}/.cursor/wolf-leader-last-save.json"

curl -sS -m 120 -X POST "${API}/api/save-project" \
  -H 'Content-Type: application/json' \
  -d '{}' >"$LOG" 2>/dev/null || true

exit 0
