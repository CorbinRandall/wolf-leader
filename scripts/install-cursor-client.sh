#!/usr/bin/env bash
# Install Wolf Leader Cursor client files into ~/.cursor/ (skills, MCP, hooks, rule).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CURSOR_DIR="${CURSOR_DIR:-$HOME/.cursor}"
CURSOR_EXAMPLES="${ROOT}/examples/cursor"
WORKSPACE="${WORKSPACE:-$HOME}"

WOLF_LEADER_API="${WOLF_LEADER_API:-}"
WOLF_LEADER_MCP="${WOLF_LEADER_MCP:-}"

usage() {
  cat <<EOF
Usage: WOLF_LEADER_API=http://HOST:6971 WOLF_LEADER_MCP=http://HOST:6972/mcp $0

Installs:
  \$CURSOR_DIR/skills/save/       — /save slash command
  \$CURSOR_DIR/skills/new/        — /new project setup
  \$CURSOR_DIR/skills/save-new/   — /save-new (rabbit-hole → new project)
  \$CURSOR_DIR/mcp.json         — wolf-leader MCP (merged)
  \$CURSOR_DIR/hooks.json       — sessionStart + stop hooks
  \$CURSOR_DIR/hooks/           — hook scripts
  \$CURSOR_DIR/rules/           — wolf-leader-hub.mdc
  \$CURSOR_DIR/wolf-leader.env  — hub URLs (created if missing)

Optional:
  WORKSPACE=/root   — symlink AGENTS.md into workspace root
  CURSOR_DIR=...    — override ~/.cursor
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! -d "$CURSOR_EXAMPLES" ]]; then
  echo "ERROR: missing $CURSOR_EXAMPLES — run from wolf-leader repo root" >&2
  exit 1
fi

mkdir -p \
  "$CURSOR_DIR/skills/save/scripts" \
  "$CURSOR_DIR/skills/new" \
  "$CURSOR_DIR/skills/save-new/scripts" \
  "$CURSOR_DIR/hooks" \
  "$CURSOR_DIR/rules"

# --- skills ---
install -m 644 "$CURSOR_EXAMPLES/skills/save/SKILL.md" "$CURSOR_DIR/skills/save/SKILL.md"
install -m 755 "$CURSOR_EXAMPLES/skills/save/scripts/save-session.sh" \
  "$CURSOR_DIR/skills/save/scripts/save-session.sh"
install -m 755 "$CURSOR_EXAMPLES/skills/save/scripts/save-session.py" \
  "$CURSOR_DIR/skills/save/scripts/save-session.py"

install -m 644 "$CURSOR_EXAMPLES/skills/new/SKILL.md" "$CURSOR_DIR/skills/new/SKILL.md"

install -m 644 "$CURSOR_EXAMPLES/skills/save-new/SKILL.md" "$CURSOR_DIR/skills/save-new/SKILL.md"
install -m 755 "$CURSOR_EXAMPLES/skills/save-new/scripts/save-new-session.sh" \
  "$CURSOR_DIR/skills/save-new/scripts/save-new-session.sh"
install -m 755 "$CURSOR_EXAMPLES/skills/save-new/scripts/save-new-session.py" \
  "$CURSOR_DIR/skills/save-new/scripts/save-new-session.py"

# --- hooks ---
install -m 644 "$CURSOR_EXAMPLES/hooks.json" "$CURSOR_DIR/hooks.json"
install -m 755 "$CURSOR_EXAMPLES/hooks/wolf-leader-recall.sh" "$CURSOR_DIR/hooks/wolf-leader-recall.sh"
install -m 755 "$CURSOR_EXAMPLES/hooks/wolf-leader-save.sh" "$CURSOR_DIR/hooks/wolf-leader-save.sh"

# --- rule ---
install -m 644 "$CURSOR_EXAMPLES/rules/wolf-leader-hub.mdc" "$CURSOR_DIR/rules/wolf-leader-hub.mdc"

# --- env file (do not overwrite existing) ---
ENV_FILE="$CURSOR_DIR/wolf-leader.env"
if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -z "$WOLF_LEADER_API" ]]; then
    WOLF_LEADER_API="http://127.0.0.1:6971"
  fi
  if [[ -z "$WOLF_LEADER_MCP" ]]; then
    WOLF_LEADER_MCP="${WOLF_LEADER_API%:6971}:6972/mcp"
    WOLF_LEADER_MCP="${WOLF_LEADER_MCP/http:/http:}"
    if [[ "$WOLF_LEADER_MCP" != http* ]]; then
      WOLF_LEADER_MCP="http://127.0.0.1:6972/mcp"
    fi
  fi
  cat >"$ENV_FILE" <<EOF
# Wolf Leader hub URLs — edit if your hub moves
WOLF_LEADER_API=${WOLF_LEADER_API}
WOLF_LEADER_MCP=${WOLF_LEADER_MCP}
EOF
  echo "  + wolf-leader.env"
else
  echo "  = wolf-leader.env (kept existing)"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# --- mcp.json (merge wolf-leader entry) ---
MCP_URL="${WOLF_LEADER_MCP:-}"
if [[ -z "$MCP_URL" && -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  MCP_URL="${WOLF_LEADER_MCP:-}"
fi
if [[ -z "$MCP_URL" ]]; then
  MCP_URL="http://127.0.0.1:6972/mcp"
fi

python3 - "$CURSOR_DIR/mcp.json" "$MCP_URL" <<'PY'
import json, sys
from pathlib import Path

dest, mcp_url = sys.argv[1], sys.argv[2]
data = {"mcpServers": {}}
p = Path(dest)
if p.is_file():
    try:
        data = json.loads(p.read_text())
    except json.JSONDecodeError:
        pass
servers = data.setdefault("mcpServers", {})
servers["wolf-leader"] = {"url": mcp_url}
# Legacy key used on corbox — keep both pointing at same URL
servers["ide-storage"] = {"url": mcp_url}
p.write_text(json.dumps(data, indent=2) + "\n")
print(f"  + mcp.json (wolf-leader → {mcp_url})")
PY

# --- AGENTS.md symlink ---
AGENTS_SRC="${ROOT}/examples/AGENTS.md"
AGENTS_DEST="${WORKSPACE}/AGENTS.md"
if [[ -f "$AGENTS_SRC" ]]; then
  ln -sfn "$AGENTS_SRC" "$AGENTS_DEST"
  echo "  + AGENTS.md → $AGENTS_SRC"
fi

echo ""
echo "Wolf Leader Cursor client installed under $CURSOR_DIR"
echo "Reload the Cursor window, then verify: ./scripts/verify-cursor-client.sh"
echo "Slash commands: /new (setup), /save (checkpoint), /save-new (new project from chat)."
