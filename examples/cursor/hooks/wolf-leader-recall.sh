#!/usr/bin/env bash
# sessionStart: inject Wolf Leader bootstrap context for the workspace.
set -euo pipefail

ENV_FILE="${HOME}/.cursor/wolf-leader.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

API="${WOLF_LEADER_API_LOCAL:-${WOLF_LEADER_API:-http://127.0.0.1:6971}}"
WORKSPACE="${PWD:-/root}"

payload=$(python3 -c 'import json,sys; print(json.dumps({"workspace": sys.argv[1]}))' "$WORKSPACE" 2>/dev/null || echo '{}')

bootstrap=$(curl -sS -m 8 -G "${API}/api/bootstrap" --data-urlencode "path=${WORKSPACE}" 2>/dev/null || true)
if [[ -z "$bootstrap" ]]; then
  exit 0
fi

python3 - "$bootstrap" <<'PY'
import json, sys

raw = sys.argv[1]
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)

parts = []
if data.get("project_name") or data.get("project_slug"):
    parts.append(
        f"Wolf Leader project: {data.get('project_name') or '?'} "
        f"({data.get('project_slug') or 'unlinked'})"
    )
if data.get("brief_url"):
    parts.append(f"Agent brief: {data['brief_url']}")
if data.get("pickup_prompt"):
    parts.append(f"Pickup: {data['pickup_prompt']}")
block = data.get("context_block") or data.get("context") or data.get("markdown")
if isinstance(block, str) and block.strip():
    parts.append(block.strip()[:4000])
if not parts:
    sys.exit(0)

ctx = "Wolf Leader bootstrap (sessionStart hook):\n" + "\n\n".join(parts)
print(json.dumps({"additional_context": ctx}))
PY

exit 0
