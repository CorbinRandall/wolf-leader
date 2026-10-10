#!/usr/bin/env bash
# Install Wolf Leader skills and hooks for Codex.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/wolf-leader-client.sh
source "$ROOT/scripts/lib/wolf-leader-client.sh"
SOURCE="${ROOT}/examples/cursor"
CODEX_TEMPLATE="${ROOT}/examples/codex/hooks.json.template"
CODEX_DIR="${CODEX_DIR:-$HOME/.codex}"
AGENT_SKILLS_DIR="${AGENT_SKILLS_DIR:-$HOME/.agents/skills}"
WORKSPACE="${WORKSPACE:-$PWD}"
WOLF_LEADER_API="${WOLF_LEADER_API:-}"
WOLF_LEADER_MCP="${WOLF_LEADER_MCP:-}"
INSTALL_FAIL=0

if [[ -z "$WOLF_LEADER_API" || -z "$WOLF_LEADER_MCP" ]]; then
  echo "ERROR: WOLF_LEADER_API and WOLF_LEADER_MCP are required" >&2
  exit 1
fi
if [[ ! -d "$SOURCE" || ! -f "$CODEX_TEMPLATE" ]]; then
  echo "ERROR: client bundle is incomplete" >&2
  exit 1
fi

install_one() {
  local mode="$1" src="$2" dest="$3"
  mkdir -p "$(dirname "$dest")"
  if install -m "$mode" "$src" "$dest"; then
    echo "  + $dest"
  else
    echo "  FAIL $dest" >&2
    INSTALL_FAIL=1
  fi
}

echo "Wolf Leader Codex client install"
echo "  Hub API:   $WOLF_LEADER_API"
echo "  Hub MCP:   $WOLF_LEADER_MCP"
echo "  Workspace: $WORKSPACE"
echo ""

mkdir -p \
  "$AGENT_SKILLS_DIR/save/scripts" \
  "$AGENT_SKILLS_DIR/new/scripts" \
  "$CODEX_DIR/hooks" \
  "$CODEX_DIR/lib"

install_one 644 "$ROOT/examples/codex/skills/save/SKILL.md" "$AGENT_SKILLS_DIR/save/SKILL.md"
install_one 755 "$SOURCE/skills/save/scripts/save-session.sh" "$AGENT_SKILLS_DIR/save/scripts/save-session.sh"
install_one 755 "$SOURCE/skills/save/scripts/save-session.py" "$AGENT_SKILLS_DIR/save/scripts/save-session.py"
install_one 755 "$SOURCE/skills/save/scripts/save-session-curl.sh" "$AGENT_SKILLS_DIR/save/scripts/save-session-curl.sh"
install_one 644 "$SOURCE/skills/new/SKILL.md" "$AGENT_SKILLS_DIR/new/SKILL.md"
install_one 755 "$SOURCE/skills/new/scripts/new-project-session.sh" "$AGENT_SKILLS_DIR/new/scripts/new-project-session.sh"
install_one 755 "$SOURCE/skills/new/scripts/new-project-session.py" "$AGENT_SKILLS_DIR/new/scripts/new-project-session.py"
install_one 755 "$SOURCE/skills/new/scripts/new-project-session-curl.sh" "$AGENT_SKILLS_DIR/new/scripts/new-project-session-curl.sh"

install_one 755 "$SOURCE/hooks/wolf-leader-recall.sh" "$CODEX_DIR/hooks/wolf-leader-recall.sh"
install_one 755 "$SOURCE/hooks/wolf-leader-save.sh" "$CODEX_DIR/hooks/wolf-leader-save.sh"
install_one 755 "$SOURCE/hooks/wolf-leader-autosave.py" "$CODEX_DIR/hooks/wolf-leader-autosave.py"
install_one 644 "$ROOT/scripts/lib/wolf-leader-client.sh" "$CODEX_DIR/lib/wolf-leader-client.sh"

cat >"$CODEX_DIR/wolf-leader.env" <<EOF
WOLF_LEADER_API=$WOLF_LEADER_API
WOLF_LEADER_MCP=$WOLF_LEADER_MCP
EOF
chmod 600 "$CODEX_DIR/wolf-leader.env"

escaped_codex_dir="${CODEX_DIR//\\/\\\\}"
escaped_codex_dir="${escaped_codex_dir//&/\\&}"
escaped_codex_dir="${escaped_codex_dir//|/\\|}"
rendered_hooks="${CODEX_DIR}/hooks.wolf-leader.$$"
sed "s|__CODEX_DIR__|${escaped_codex_dir}|g" "$CODEX_TEMPLATE" >"$rendered_hooks"
if ! wl_merge_codex_hooks_json "$CODEX_DIR/hooks.json" "$rendered_hooks"; then
  INSTALL_FAIL=1
fi
rm -f "$rendered_hooks"

if [[ -d "$WORKSPACE" && -w "$WORKSPACE" ]]; then
  if [[ -e "$WORKSPACE/AGENTS.md" ]]; then
    echo "  = existing $WORKSPACE/AGENTS.md kept"
    echo "    Merge the Wolf Leader session rules from examples/AGENTS.md without removing local instructions."
  else
    install_one 644 "$ROOT/examples/AGENTS.md" "$WORKSPACE/AGENTS.md"
  fi
else
  echo "  FAIL workspace is not writable: $WORKSPACE" >&2
  INSTALL_FAIL=1
fi

if command -v codex >/dev/null 2>&1; then
  existing_mcp="$(codex mcp get wolf-leader --json 2>/dev/null || true)"
  if [[ -n "$existing_mcp" ]] && grep -Fq "$WOLF_LEADER_MCP" <<<"$existing_mcp"; then
    echo "  = Codex MCP wolf-leader already uses $WOLF_LEADER_MCP"
  elif [[ -n "$existing_mcp" ]]; then
    echo "  WARN Codex MCP wolf-leader already exists with another URL; update it to $WOLF_LEADER_MCP"
  elif codex mcp add wolf-leader --url "$WOLF_LEADER_MCP" >/dev/null 2>&1; then
    echo "  + Codex MCP wolf-leader"
  else
    echo "  WARN could not configure MCP with the Codex CLI; add wolf-leader → $WOLF_LEADER_MCP manually"
  fi
else
  echo "  WARN Codex CLI not found; add MCP wolf-leader → $WOLF_LEADER_MCP in Codex settings"
fi

echo ""
CODEX_DIR="$CODEX_DIR" AGENT_SKILLS_DIR="$AGENT_SKILLS_DIR" \
  bash "$ROOT/scripts/verify-codex-client.sh" || INSTALL_FAIL=1

echo ""
echo "IMPORTANT: reload Codex, open Settings → Hooks, review the three Wolf Leader hooks, and trust them."
echo "Automatic saves do not run until Codex trusts the hooks."

[[ "$INSTALL_FAIL" -eq 0 ]]
