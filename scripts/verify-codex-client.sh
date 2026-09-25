#!/usr/bin/env bash
# Verify Wolf Leader Codex skills and hook installation.
set -uo pipefail

CODEX_DIR="${CODEX_DIR:-$HOME/.codex}"
AGENT_SKILLS_DIR="${AGENT_SKILLS_DIR:-$HOME/.agents/skills}"
FAIL=0

check_file() {
  local label="$1" path="$2"
  if [[ -f "$path" ]]; then
    echo "OK    $label"
  else
    echo "FAIL  $label ($path)"
    FAIL=1
  fi
}

check_file "save skill" "$AGENT_SKILLS_DIR/save/SKILL.md"
check_file "save runner" "$AGENT_SKILLS_DIR/save/scripts/save-session.sh"
check_file "new skill" "$AGENT_SKILLS_DIR/new/SKILL.md"
check_file "Codex hooks config" "$CODEX_DIR/hooks.json"
check_file "recall hook" "$CODEX_DIR/hooks/wolf-leader-recall.sh"
check_file "save hook" "$CODEX_DIR/hooks/wolf-leader-save.sh"
check_file "autosave worker" "$CODEX_DIR/hooks/wolf-leader-autosave.py"
check_file "hub URLs" "$CODEX_DIR/wolf-leader.env"

if [[ -f "$CODEX_DIR/hooks.json" ]]; then
  for event in SessionStart UserPromptSubmit Stop; do
    if grep -q "\"$event\"" "$CODEX_DIR/hooks.json"; then
      echo "OK    $event hook configured"
    else
      echo "FAIL  $event hook missing"
      FAIL=1
    fi
  done
  if grep -Fq "$CODEX_DIR/hooks/wolf-leader-save.sh" "$CODEX_DIR/hooks.json"; then
    echo "OK    Stop hook points to Codex save script"
  else
    echo "FAIL  Stop hook does not point to $CODEX_DIR/hooks/wolf-leader-save.sh"
    FAIL=1
  fi
fi

if [[ -f "$CODEX_DIR/wolf-leader.env" ]]; then
  # shellcheck disable=SC1090
  source "$CODEX_DIR/wolf-leader.env"
  if curl -fsS -m 8 "${WOLF_LEADER_API%/}/health" >/dev/null 2>&1; then
    echo "OK    hub health"
  else
    echo "FAIL  hub is not reachable at ${WOLF_LEADER_API%/}/health"
    FAIL=1
  fi

  if command -v codex >/dev/null 2>&1; then
    mcp_config="$(codex mcp get wolf-leader --json 2>/dev/null || true)"
    if [[ -n "$mcp_config" ]] && grep -Fq "$WOLF_LEADER_MCP" <<<"$mcp_config"; then
      echo "OK    Codex MCP URL"
    else
      echo "FAIL  Codex MCP wolf-leader is missing or uses a different URL"
      FAIL=1
    fi
  fi
fi

CONFIG_FILE="${CODEX_CONFIG:-$CODEX_DIR/config.toml}"
trusted=0
if [[ -f "$CONFIG_FILE" ]]; then
  for event in session_start user_prompt_submit stop; do
    if grep -Fq "$CODEX_DIR/hooks.json:${event}:0:0" "$CONFIG_FILE"; then
      trusted=$((trusted + 1))
    fi
  done
fi
if [[ "$trusted" -eq 3 ]]; then
  echo "OK    Codex records all three Wolf Leader hooks as trusted"
else
  echo "FAIL  Codex hooks are not all trusted yet"
  echo "      Reload Codex, open Settings → Hooks, review and trust the Wolf Leader hooks, then rerun this verifier."
  FAIL=1
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "All install-time Codex checks passed."
  exit 0
fi
echo "Codex setup is incomplete. Re-run setup after fixing the failed items."
exit 1
