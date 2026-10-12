#!/usr/bin/env bash
# Minimal /wolfhowl fallback when Python is unavailable.
# Saves a typed summary to a known existing project. It cannot read the local
# transcript, match a project, or create one.
set -euo pipefail

for env_file in "$HOME/.claude/wolf-leader.env" "$HOME/.codex/wolf-leader.env" "$HOME/.cursor/wolf-leader.env"; do
  # shellcheck disable=SC1090
  [[ -f "$env_file" ]] && source "$env_file"
done
API="${WOLF_LEADER_API_LOCAL:-${WOLF_LEADER_API:-http://127.0.0.1:6971}}"
API="${API%/}"
SESSION_ID="${WOLF_LEADER_SESSION_ID:-${CODEX_THREAD_ID:-${CODEX_SESSION_ID:-${CURSOR_SESSION_ID:-}}}}"
WORKSPACE="${WOLF_LEADER_WORKSPACE:-${CURSOR_WORKSPACE:-$PWD}}"
SLUG="" CONTENT="" TITLE="wolfhowl"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --content) CONTENT="${2:-}"; shift 2 ;;
    --title) TITLE="${2:-}"; shift 2 ;;
    --new|--git-only|--git-init|--push|--commit|--howl-id)
      echo "wolfhowl: $1 needs python3 on this machine." >&2; exit 2 ;;
    --*) shift ;;
    *) [[ -z "$SLUG" ]] && SLUG="$1"; shift ;;
  esac
done

if [[ -z "$SLUG" || -z "$SESSION_ID" || -z "$CONTENT" ]]; then
  echo "wolfhowl (no python3): usage: wolfhowl.sh EXISTING-SLUG --session-id ID --content \"decision: ...\"" >&2
  echo "Ask whether this belongs to an existing project or a new one. Creating a project needs python3 or the Wolf Leader MCP tools." >&2
  exit 2
fi

escape_json() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' | awk 'BEGIN{ORS=""} NR>1{print "\\n"} {print}'; }
payload="{\"slug\":\"$(escape_json "$SLUG")\",\"session_id\":\"$(escape_json "$SESSION_ID")\",\"title\":\"$(escape_json "$TITLE")\",\"content\":\"$(escape_json "$CONTENT")\",\"workspace_path\":\"$(escape_json "$WORKSPACE")\",\"device_name\":\"$(escape_json "$(hostname)")\"}"
curl -fsS -m 180 -X POST "$API/api/howl" -H 'Content-Type: application/json' -d "$payload"
