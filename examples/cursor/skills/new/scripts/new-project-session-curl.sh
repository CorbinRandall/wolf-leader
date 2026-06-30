#!/usr/bin/env bash
# Create project + checkpoint via REST when python3 is unavailable.
# Usage: new-project-session-curl.sh SLUG "Project Name" [description]
set -euo pipefail

LIB="${HOME}/.cursor/lib/wolf-leader-client.sh"
[[ -f "$LIB" ]] && source "$LIB"

ENV_FILE="${HOME}/.cursor/wolf-leader.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

API="${WOLF_LEADER_API_LOCAL:-${WOLF_LEADER_API:-http://127.0.0.1:6971}}"
API="${API%/}"
WORKSPACE="${PWD:-${WORKSPACE:-$HOME}}"

slugify() {
  local s
  s=$(echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 _-]//g' | tr ' _' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')
  echo "${s:0:64}"
}

title_from_slug() {
  local s="$1" w out=""
  s=${s//-/ }
  for w in $s; do
    out+="${out:+ }$(echo "$w" | sed 's/^\(.\)/\U\1/')"
  done
  echo "${out:-New Project}"
}

SLUG_RAW="${1:-${WOLF_LEADER_NEW_SLUG:-}}"
NAME="${2:-}"
DESC="${3:-}"

if [[ -z "$SLUG_RAW" ]]; then
  echo "ERROR: /new (curl) needs a project slug." >&2
  echo "Usage: new-project-session-curl.sh my-project-slug \"My Project Name\"" >&2
  echo "Or set WOLF_LEADER_NEW_SLUG. For transcript upload install python3 or use MCP save_session." >&2
  exit 1
fi

SLUG=$(slugify "$SLUG_RAW")
NAME="${NAME:-$(title_from_slug "$SLUG")}"

echo "Wolf Leader /new (curl fallback — no python3 on this host)"
echo "  slug: $SLUG"
echo "  name: $NAME"
echo "  workspace: $WORKSPACE"
echo ""

project_id=""
created=false

if command -v jq >/dev/null 2>&1; then
  project_id=$(curl -sS "${API}/api/projects" | jq -r --arg s "$SLUG" '.projects[]? | select(.slug == $s) | .id' | head -1)
elif curl -sS "${API}/api/projects" | grep -q "\"slug\"[[:space:]]*:[[:space:]]*\"${SLUG}\""; then
  project_id=$(curl -sS "${API}/api/projects" | grep -B5 "\"slug\"[[:space:]]*:[[:space:]]*\"${SLUG}\"" | grep '"id"' | head -1 | sed 's/[^0-9]*\([0-9]*\).*/\1/')
fi

if [[ -z "$project_id" || "$project_id" == "null" ]]; then
  if command -v jq >/dev/null 2>&1; then
    body=$(jq -n --arg name "$NAME" --arg slug "$SLUG" --arg path "$WORKSPACE" --arg desc "$DESC" \
      '{name: $name, slug: $slug, path: $path} + (if $desc != "" then {description: $desc} else {} end)')
  else
    name_esc="${NAME//\\/\\\\}"; name_esc="${name_esc//\"/\\\"}"
    path_esc="${WORKSPACE//\\/\\\\}"; path_esc="${path_esc//\"/\\\"}"
    body="{\"name\":\"${name_esc}\",\"slug\":\"${SLUG}\",\"path\":\"${path_esc}\"}"
  fi
  create_resp=$(curl -sS -m 60 -X POST "${API}/api/projects" \
    -H 'Content-Type: application/json' -d "$body")
  if command -v jq >/dev/null 2>&1; then
    project_id=$(echo "$create_resp" | jq -r '.id // empty')
  else
    project_id=$(echo "$create_resp" | grep -o '"id"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | sed 's/[^0-9]*//')
  fi
  [[ -n "$project_id" ]] || { echo "ERROR: create project failed: $create_resp" >&2; exit 1; }
  created=true
  echo "Created project id=$project_id"
else
  echo "Project already exists id=$project_id — updating path"
  if command -v jq >/dev/null 2>&1; then
    upd=$(jq -n --arg path "$WORKSPACE" '{path: $path}')
    curl -sS -m 30 -X PUT "${API}/api/projects/${project_id}" \
      -H 'Content-Type: application/json' -d "$upd" >/dev/null || true
  fi
fi

if command -v jq >/dev/null 2>&1; then
  save_body=$(jq -n --arg slug "$SLUG" --arg ws "$WORKSPACE" --arg title "$NAME" \
    '{slug: $slug, workspace_path: $ws, title: $title}')
else
  title_esc="${NAME//\\/\\\\}"; title_esc="${title_esc//\"/\\\"}"
  path_esc="${WORKSPACE//\\/\\\\}"; path_esc="${path_esc//\"/\\\"}"
  save_body="{\"slug\":\"${SLUG}\",\"workspace_path\":\"${path_esc}\",\"title\":\"${title_esc}\"}"
fi

save_resp=$(curl -sS -m 120 -X POST "${API}/api/save-project" \
  -H 'Content-Type: application/json' -d "$save_body" 2>&1) || {
  echo "WARN: save-project failed (project still created): $save_resp" >&2
  save_resp="{}"
}

distill_resp=$(curl -sS -m 120 -X POST "${API}/api/projects/${project_id}/distill" \
  -H 'Content-Type: application/json' -d '{}' 2>/dev/null || echo "{}")

brief_url="${API}/api/projects/${SLUG}/agent-brief"
echo ""
echo "Summary:"
echo "  ok: true"
echo "  project_created: $created"
echo "  project_slug: $SLUG"
echo "  project_name: $NAME"
echo "  project_id: $project_id"
echo "  brief_url: $brief_url"
echo ""
echo "NOTE: curl /new does not upload local transcript — install python3, use MCP save_session,"
echo "      or paste conversation content via the agent after project creation."
echo ""
if command -v jq >/dev/null 2>&1 && [[ -n "$save_resp" ]]; then
  echo "$save_resp" | jq . 2>/dev/null || echo "$save_resp"
else
  echo "$save_resp"
fi
