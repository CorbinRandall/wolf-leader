#!/usr/bin/env bash
# Verify Wolf Leader Cursor client integration files.
set -euo pipefail

CURSOR_DIR="${CURSOR_DIR:-$HOME/.cursor}"
FAIL=0

check() {
  local label="$1"
  local path="$2"
  if [[ -e "$path" ]]; then
    echo "OK  $label"
  else
    echo "MISSING  $label ($path)"
    FAIL=1
  fi
}

echo "Checking Wolf Leader Cursor client under $CURSOR_DIR"
echo ""

check "save skill" "$CURSOR_DIR/skills/save/SKILL.md"
check "save script" "$CURSOR_DIR/skills/save/scripts/save-session.sh"
check "save uploader" "$CURSOR_DIR/skills/save/scripts/save-session.py"
check "new skill" "$CURSOR_DIR/skills/new/SKILL.md"
check "mcp.json" "$CURSOR_DIR/mcp.json"
check "hooks.json" "$CURSOR_DIR/hooks.json"
check "recall hook" "$CURSOR_DIR/hooks/wolf-leader-recall.sh"
check "save hook" "$CURSOR_DIR/hooks/wolf-leader-save.sh"
check "hub rule" "$CURSOR_DIR/rules/wolf-leader-hub.mdc"
check "env file" "$CURSOR_DIR/wolf-leader.env"

for skill_name in save new; do
  skill_md="$CURSOR_DIR/skills/$skill_name/SKILL.md"
  if [[ -f "$skill_md" ]]; then
    if grep -q "^name: $skill_name" "$skill_md" && \
       grep -q 'disable-model-invocation: true' "$skill_md"; then
      echo "OK  skill frontmatter (name: $skill_name)"
    else
      echo "BAD  skill frontmatter — need name: $skill_name and disable-model-invocation: true"
      FAIL=1
    fi
  fi
done

if [[ -x "$CURSOR_DIR/skills/save/scripts/save-session.sh" ]]; then
  echo "OK  save-session.sh executable"
else
  echo "BAD  save-session.sh not executable"
  FAIL=1
fi

if [[ -x "$CURSOR_DIR/skills/save/scripts/save-session.py" ]]; then
  echo "OK  save-session.py executable"
else
  echo "BAD  save-session.py not executable"
  FAIL=1
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
    if curl -sS -m 5 -o /dev/null -w "%{http_code}" "${API}/health" 2>/dev/null | grep -q 200; then
      echo "OK  hub health (${API}/health)"
    elif curl -sS -m 5 -o /dev/null -w "%{http_code}" "${API}/" 2>/dev/null | grep -qE '200|302'; then
      echo "OK  hub web (${API}/)"
    else
      echo "WARN  hub not reachable at $API (client files still OK)"
    fi
  fi

  if [[ -n "$MCP" ]]; then
    code=$(curl -sS -m 5 -o /dev/null -w "%{http_code}" -H 'Accept: text/event-stream' "$MCP" 2>/dev/null || echo "000")
    if [[ "$code" != "000" && "$code" != "404" ]]; then
      echo "OK  MCP endpoint responded (HTTP $code)"
    else
      echo "WARN  MCP not reachable at $MCP"
    fi
  fi
fi

echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "All client files present. Reload Cursor window if /new or /save are missing from / menu."
  exit 0
fi
echo "Some checks failed — run: WOLF_LEADER_API=... WOLF_LEADER_MCP=... ./scripts/install-cursor-client.sh"
exit 1
