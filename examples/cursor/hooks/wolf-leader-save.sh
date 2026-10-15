#!/usr/bin/env bash
# stop: upload the current transcript and checkpoint it (never block session close).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLIENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${CLIENT_DIR}/wolf-leader.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

API="${WOLF_LEADER_API_LOCAL:-${WOLF_LEADER_API:-http://127.0.0.1:6971}}"
LOG="${CLIENT_DIR}/wolf-leader-last-save.json"
hook_input=$(cat 2>/dev/null || true)
script="${SCRIPT_DIR}/wolf-leader-autosave.py"
# The save runs in the background so the chat never waits on the hub. One save runs at a time; a
# turn that ends while one is running leaves its input as "pending", and that runs right after.
LOCK="${CLIENT_DIR}/.wolf-leader-save.lock"
PENDING="${CLIENT_DIR}/.wolf-leader-save.pending"
if [[ -x "$script" ]]; then
  printf '%s' "$hook_input" >"$PENDING.tmp" && mv "$PENDING.tmp" "$PENDING"
  if [[ -d "$LOCK" ]] && [[ -n "$(find "$LOCK" -maxdepth 0 -mmin +20 2>/dev/null)" ]]; then
    rmdir "$LOCK" 2>/dev/null || true  # a save that died long ago must not block the next one
  fi
  if mkdir "$LOCK" 2>/dev/null; then
    (
      while [[ -f "$PENDING" ]]; do
        input_file=$(mktemp "${TMPDIR:-/tmp}/wolf-leader-hook.XXXXXX")
        mv "$PENDING" "$input_file"
        WOLF_LEADER_API="$API" WOLF_LEADER_CLIENT_DIR="$CLIENT_DIR" "$script" <"$input_file" >/dev/null 2>>"${LOG%.json}-error.log"
        rm -f "$input_file"
      done
      rmdir "$LOCK"
    ) </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
fi
printf '{"continue":true}\n'

exit 0
