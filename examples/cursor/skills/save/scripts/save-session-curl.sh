#!/usr/bin/env bash
# Minimal /save via REST when python3 is unavailable (curl-only clients).
set -euo pipefail

ENV_FILE="${HOME}/.cursor/wolf-leader.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

API="${WOLF_LEADER_API_LOCAL:-${WOLF_LEADER_API:-http://127.0.0.1:6971}}"
API="${API%/}"
SLUG="${1:-}"
WORKSPACE="${PWD:-${WORKSPACE:-$HOME}}"

if command -v jq >/dev/null 2>&1; then
  if [[ -n "$SLUG" ]]; then
    payload=$(jq -n --arg slug "$SLUG" --arg ws "$WORKSPACE" '{slug: $slug, workspace_path: $ws}')
  else
    payload=$(jq -n --arg ws "$WORKSPACE" '{workspace_path: $ws}')
  fi
else
  ws_esc="${WORKSPACE//\\/\\\\}"
  ws_esc="${ws_esc//\"/\\\"}"
  if [[ -n "$SLUG" ]]; then
    slug_esc="${SLUG//\\/\\\\}"
    slug_esc="${slug_esc//\"/\\\"}"
    payload="{\"slug\":\"${slug_esc}\",\"workspace_path\":\"${ws_esc}\"}"
  else
    payload="{\"workspace_path\":\"${ws_esc}\"}"
  fi
fi

echo "Wolf Leader save (curl fallback — no python3 on this host)"
resp=$(curl -sS -m 120 -X POST "${API}/api/save-project" \
  -H 'Content-Type: application/json' \
  -d "$payload" 2>&1) || {
  echo "ERROR: save failed — hub unreachable at $API" >&2
  exit 1
}

echo "$resp"
echo ""
echo "For full transcript upload from this machine, install python3 or use MCP save_session."
