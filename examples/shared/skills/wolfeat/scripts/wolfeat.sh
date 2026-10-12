#!/usr/bin/env bash
# /wolfeat runner: GET /api/eat for this folder (or SLUG [QUERY]) and print the brief.
#   wolfeat.sh --setup   print the hub's onboarding steps for a workspace that is not connected yet
set -euo pipefail

for env_file in "$HOME/.claude/wolf-leader.env" "$HOME/.codex/wolf-leader.env" "$HOME/.cursor/wolf-leader.env"; do
  # shellcheck disable=SC1090
  [[ -f "$env_file" ]] && source "$env_file"
done
API="${WOLF_LEADER_API_LOCAL:-${WOLF_LEADER_API:-http://wolf.local:6971}}"
API="${API%/}"

# Pretty-print when a real python is present (the Windows Store "python3" stub is not one).
pretty() {
  if python3 -c "" >/dev/null 2>&1; then
    python3 -m json.tool 2>/dev/null || cat
  elif python -c "" >/dev/null 2>&1; then
    python -m json.tool 2>/dev/null || cat
  else
    cat
  fi
}

if [[ "${1:-}" == "--setup" ]]; then
  if ! curl -fsS -m 30 "${API}/api/onboarding" | pretty; then
    echo "wolfeat: cannot reach Wolf Leader at ${API}. Check the hub address in wolf-leader.env." >&2
    exit 1
  fi
  exit 0
fi

SLUG="${1:-}"
QUERY="${2:-}"
WORKSPACE="${WOLF_LEADER_WORKSPACE:-${CURSOR_WORKSPACE:-$PWD}}"
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

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT
status="$(curl -sS -m 120 -o "$body_file" -w '%{http_code}' "$URL" || true)"
if [[ "$status" == "200" ]]; then
  pretty <"$body_file"
  exit 0
fi
if [[ "$status" == "404" ]] && ! grep -q '"projects"' "$body_file"; then
  echo "wolfeat: the hub at ${API} is older than /wolfeat (no /api/eat). Update the hub, or use the Wolf Leader MCP tools resolve_project + recall." >&2
  exit 1
fi
if [[ "$status" == "404" ]]; then
  # No project is registered for this folder yet. Show the choices instead of failing silently.
  pretty <"$body_file"
  echo "wolfeat: no project matches ${WORKSPACE}. Re-run with a slug from the list above, or run 'wolfeat.sh --setup' if this workspace is not connected yet. A new project is created by /wolfhowl after the user confirms." >&2
  exit 3
fi
echo "wolfeat: cannot reach Wolf Leader at ${API} (HTTP ${status:-none}). Run 'wolfeat.sh --setup' once the hub address is right." >&2
exit 1
