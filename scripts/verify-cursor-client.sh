#!/usr/bin/env bash
# Verify Wolf Leader Cursor client integration files.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "${ROOT}/scripts/lib/wolf-leader-client.sh" ]]; then
  # shellcheck source=lib/wolf-leader-client.sh
  source "${ROOT}/scripts/lib/wolf-leader-client.sh"
elif [[ -f "${HOME}/.cursor/lib/wolf-leader-client.sh" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/.cursor/lib/wolf-leader-client.sh"
fi

CURSOR_DIR="${CURSOR_DIR:-$HOME/.cursor}"
FAIL=0
WARN=0

check() {
  local label="$1"
  local path="$2"
  if [[ -e "$path" ]]; then
    echo "OK    $label"
  else
    echo "FAIL  $label ($path)"
    FAIL=1
  fi
}

echo "Verify Wolf Leader client"
echo ""

check "wolf-leader.env" "$CURSOR_DIR/wolf-leader.env"
check "mcp.json" "$CURSOR_DIR/mcp.json"
check "hooks.json" "$CURSOR_DIR/hooks.json"
check "save skill" "$CURSOR_DIR/skills/save/SKILL.md"
check "save script" "$CURSOR_DIR/skills/save/scripts/save-session.sh"
check "save curl fallback" "$CURSOR_DIR/skills/save/scripts/save-session-curl.sh"
check "new skill" "$CURSOR_DIR/skills/new/SKILL.md"
check "new project script" "$CURSOR_DIR/skills/new/scripts/new-project-session.sh"
check "new curl fallback" "$CURSOR_DIR/skills/new/scripts/new-project-session-curl.sh"
check "recall hook" "$CURSOR_DIR/hooks/wolf-leader-recall.sh"
check "save hook" "$CURSOR_DIR/hooks/wolf-leader-save.sh"
check "hub rule" "$CURSOR_DIR/rules/wolf-leader-hub.mdc"
check "client lib" "$CURSOR_DIR/lib/wolf-leader-client.sh"

if [[ -f "$CURSOR_DIR/mcp.json" ]]; then
  if grep -q '"wolf-leader"' "$CURSOR_DIR/mcp.json" 2>/dev/null; then
    echo "OK    mcp.json wolf-leader entry"
  else
    echo "FAIL  mcp.json missing wolf-leader entry"
    FAIL=1
  fi
  if type wl_has_cmd >/dev/null 2>&1 && wl_has_cmd jq; then
    url=$(jq -r '.mcpServers["wolf-leader"].url // empty' "$CURSOR_DIR/mcp.json" 2>/dev/null)
    [[ -n "$url" ]] && echo "OK    mcp.json URL ($url)"
  fi
fi

if command -v python3 >/dev/null 2>&1; then
  echo "OK    python runtime (/save full path)"
else
  echo "WARN  python3 not found — /save uses curl fallback; /new needs python3 or MCP"
  WARN=1
fi

ENV_FILE="$CURSOR_DIR/wolf-leader.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  API="${WOLF_LEADER_API_LOCAL:-${WOLF_LEADER_API:-}}"
  MCP="${WOLF_LEADER_MCP:-}"
  echo ""
  echo "Hub API: ${API:-unset}"
  echo "Hub MCP: ${MCP:-unset}"

  if [[ -n "$API" ]]; then
    if type wl_check_hub_health >/dev/null 2>&1 && wl_check_hub_health "$API"; then
      echo "OK    hub health (${API}/health)"
    elif curl -sS -m 5 -o /dev/null -w "%{http_code}" "${API}/health" 2>/dev/null | grep -q 200; then
      echo "OK    hub health (${API}/health)"
    else
      echo "WARN  hub not reachable at $API"
      WARN=1
    fi
  fi
fi

echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "All required checks passed. Reload Cursor window if /new or /save are missing."
  exit 0
fi
echo "Some required checks failed — re-run install or fix items above."
exit 1
