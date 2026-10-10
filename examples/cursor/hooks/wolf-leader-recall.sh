#!/usr/bin/env bash
# sessionStart: inject Wolf Leader bootstrap context for the workspace.
set -euo pipefail

ENV_FILE="${HOME}/.cursor/wolf-leader.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

LIB="${HOME}/.cursor/lib/wolf-leader-client.sh"
if [[ -f "$LIB" ]]; then
  # shellcheck source=/dev/null
  source "$LIB"
fi

API="${WOLF_LEADER_API_LOCAL:-${WOLF_LEADER_API:-http://127.0.0.1:6971}}"
WORKSPACE="${PWD:-/root}"

bootstrap=$(curl -sS -m 8 -G "${API}/api/bootstrap" --data-urlencode "path=${WORKSPACE}" 2>/dev/null || true)
[[ -n "$bootstrap" ]] || exit 0

ctx=""
if declare -F wl_format_bootstrap_context >/dev/null 2>&1; then
  ctx=$(wl_format_bootstrap_context "$bootstrap" 2>/dev/null || true)
fi

if [[ -z "$ctx" ]] && command -v python3 >/dev/null 2>&1; then
  ctx=$(python3 - "$bootstrap" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)
parts = []
if data.get("project_name") or data.get("project_slug"):
    parts.append(f"Wolf Leader project: {data.get('project_name') or '?'} ({data.get('project_slug') or 'unlinked'})")
if data.get("brief_url"):
    parts.append(f"Agent brief: {data['brief_url']}")
if data.get("pickup_prompt"):
    parts.append(f"Pickup: {data['pickup_prompt']}")
block = data.get("context_block") or data.get("context") or data.get("markdown")
if isinstance(block, str) and block.strip():
    parts.append(block.strip()[:4000])
if not parts:
    sys.exit(0)
print("Wolf Leader bootstrap (sessionStart hook):\n" + "\n\n".join(parts))
PY
  )
fi

[[ -n "$ctx" ]] || exit 0

if declare -F wl_emit_hook_json >/dev/null 2>&1; then
  wl_emit_hook_json "$ctx"
elif command -v jq >/dev/null 2>&1; then
  jq -n --arg ctx "$ctx" '{additional_context: $ctx}'
elif command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; print(json.dumps({"additional_context": sys.argv[1]}))' "$ctx"
else
  esc="${ctx//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  esc="${esc//$'\n'/\\n}"
  printf '{"additional_context":"%s"}\n' "$esc"
fi

exit 0
