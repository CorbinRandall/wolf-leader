#!/usr/bin/env bash
# On-demand Wolf Leader checkpoint (used by /save skill and manual runs).
set -euo pipefail

ENV_FILE="${HOME}/.cursor/wolf-leader.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

API="${WOLF_LEADER_API_LOCAL:-${WOLF_LEADER_API:-http://127.0.0.1:6971}}"
SLUG="${1:-}"

if [[ -n "$SLUG" ]]; then
  BODY=$(python3 -c 'import json,sys; print(json.dumps({"slug": sys.argv[1]}))' "$SLUG")
else
  BODY='{}'
fi

exec curl -sS -f -X POST "${API}/api/save-project" \
  -H 'Content-Type: application/json' \
  -d "$BODY"
