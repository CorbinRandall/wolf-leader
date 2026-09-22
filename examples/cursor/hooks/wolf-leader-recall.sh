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
hook_input=$(cat 2>/dev/null || true)
WORKSPACE="${PWD:-/root}"
EVENT=""
PROMPT=""
if command -v python3 >/dev/null 2>&1 && [[ -n "$hook_input" ]]; then
  parsed=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("cwd") or ""); print(d.get("hook_event_name") or ""); print((d.get("prompt") or "").replace("\n", " ")[:1000])' "$hook_input" 2>/dev/null || true)
  WORKSPACE=$(printf '%s\n' "$parsed" | sed -n '1p')
  EVENT=$(printf '%s\n' "$parsed" | sed -n '2p')
  PROMPT=$(printf '%s\n' "$parsed" | sed -n '3p')
  [[ -n "$WORKSPACE" ]] || WORKSPACE="${PWD:-/root}"
fi

bootstrap=$(curl -sS -m 8 -G "${API}/api/bootstrap" --data-urlencode "path=${WORKSPACE}" 2>/dev/null || true)
[[ -n "$bootstrap" ]] || exit 0

if [[ -n "$PROMPT" ]]; then
  match=$(curl -sS -m 8 -X POST "${API}/api/projects/match" -H 'Content-Type: application/json' \
    --data-binary "$(python3 -c 'import json,sys; print(json.dumps({"text":sys.argv[1],"workspace_path":sys.argv[2]}))' "$PROMPT" "$WORKSPACE")" 2>/dev/null || true)
  matched_slug=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); b=d.get("best") or {}; print(b.get("slug") if b.get("confidence") in ("high","medium") else "")' "$match" 2>/dev/null || true)
  if [[ -n "$matched_slug" ]]; then
    bootstrap=$(curl -sS -m 8 -G "${API}/api/bootstrap" --data-urlencode "slug=${matched_slug}" 2>/dev/null || printf '%s' "$bootstrap")
  fi
fi

ctx=""
if declare -F wl_format_bootstrap_context >/dev/null 2>&1; then
  ctx=$(wl_format_bootstrap_context "$bootstrap" 2>/dev/null || true)
fi

if [[ -n "$PROMPT" ]]; then
  recalled=$(curl -sS -m 8 -G "${API}/api/search" --data-urlencode "q=${PROMPT}" --data-urlencode "limit=8" 2>/dev/null || true)
  if [[ -n "$recalled" ]] && command -v python3 >/dev/null 2>&1; then
    hits=$(python3 - "$recalled" <<'PY'
import json, sys
try: rows=json.loads(sys.argv[1]).get("results", [])
except Exception: rows=[]
lines=[]
for row in rows[:8]:
    text=(row.get("content") or row.get("title") or "").strip().replace("\n", " ")
    if text: lines.append(f"- [{row.get('kind','memory')}] {text[:500]}")
if lines: print("Relevant Wolf Leader memory for this prompt:\n" + "\n".join(lines))
PY
    )
    [[ -z "$hits" ]] || ctx="${ctx}${ctx:+$'\n\n'}${hits}"
  fi
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
  if [[ "$EVENT" == "UserPromptSubmit" ]]; then
    python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":sys.argv[1]}}))' "$ctx"
  else
    wl_emit_hook_json "$ctx"
  fi
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
