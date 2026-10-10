#!/usr/bin/env bash
# /wolfeat runner: GET /api/eat for this folder (or SLUG [QUERY]) and print the brief.
set -euo pipefail

source ~/.cursor/wolf-leader.env 2>/dev/null || true
API="${WOLF_LEADER_API_LOCAL:-${WOLF_LEADER_API:-http://wolf.local:6971}}"
API="${API%/}"

SLUG="${1:-}"
QUERY="${2:-}"
WORKSPACE="${CURSOR_WORKSPACE:-$PWD}"
DEVICE="${WOLF_LEADER_DEVICE:-$(hostname)}"

urlencode() {
  local s="$1" out="" c
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

URL="${API}/api/eat?device_name=$(urlencode "$DEVICE")&workspace_path=$(urlencode "$WORKSPACE")"
[[ -n "$SLUG" ]] && URL+="&slug=$(urlencode "$SLUG")"
[[ -n "$QUERY" ]] && URL+="&q=$(urlencode "$QUERY")"

# Pretty-print when a real python is present (the Windows Store "python3" stub is not one).
if python3 -c "" >/dev/null 2>&1; then
  curl -sf "$URL" | python3 -m json.tool
elif python -c "" >/dev/null 2>&1; then
  curl -sf "$URL" | python -m json.tool
else
  curl -sf "$URL"
fi
