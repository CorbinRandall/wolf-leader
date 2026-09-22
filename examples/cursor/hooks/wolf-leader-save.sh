#!/usr/bin/env bash
# stop: upload the current transcript and checkpoint it (never block session close).
set -euo pipefail

ENV_FILE="${HOME}/.cursor/wolf-leader.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

API="${WOLF_LEADER_API_LOCAL:-${WOLF_LEADER_API:-http://127.0.0.1:6971}}"
LOG="${HOME}/.cursor/wolf-leader-last-save.json"
hook_input=$(cat 2>/dev/null || true)
script="${HOME}/.cursor/hooks/wolf-leader-autosave.py"
if [[ -x "$script" ]]; then
  printf '%s' "$hook_input" | WOLF_LEADER_API="$API" "$script" 2>>"${LOG%.json}-error.log" || printf '{"continue":true}\n'
else
  printf '{"continue":true}\n'
fi

exit 0
