#!/usr/bin/env bash
# Install Wolf Leader Cursor client files into ~/.cursor/ (skills, MCP, hooks, rule).
# No Python required for install — jq/node/template used for mcp.json merge.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/wolf-leader-client.sh
source "${ROOT}/scripts/lib/wolf-leader-client.sh"

CURSOR_DIR="${CURSOR_DIR:-$HOME/.cursor}"
CURSOR_EXAMPLES="${ROOT}/examples/cursor"
WORKSPACE="${WORKSPACE:-$HOME}"
DRY_RUN=0
JSON_OUT=0
FORCE=0
RECONFIGURE=0
INSTALL_FAIL=0

WOLF_LEADER_API="${WOLF_LEADER_API:-}"
WOLF_LEADER_MCP="${WOLF_LEADER_MCP:-}"

usage() {
  cat <<EOF
Usage: WOLF_LEADER_API=http://HOST:6971 WOLF_LEADER_MCP=http://HOST:6972/mcp $0 [options]

Options:
  --dry-run       Print actions without writing files
  --json          Machine-readable summary on stdout (last line)
  --force         Run install even if preflight warns on hub reachability
  --reconfigure   Update wolf-leader.env from WOLF_LEADER_* env vars
  -h, --help      This help

Installs under \$CURSOR_DIR:
  skills/save, skills/new, mcp.json, hooks, rules, wolf-leader.env, AGENTS.md in WORKSPACE
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --json) JSON_OUT=1; shift ;;
    --force) FORCE=1; shift ;;
    --reconfigure) RECONFIGURE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ! -d "$CURSOR_EXAMPLES" ]]; then
  echo "ERROR: missing $CURSOR_EXAMPLES — run from wolf-leader bundle root" >&2
  exit 1
fi

REQUESTED_API="${WOLF_LEADER_API:-}"
REQUESTED_MCP="${WOLF_LEADER_MCP:-}"
wl_resolve_hub_urls

echo "Wolf Leader client install"
echo "  Hub API:   $WOLF_LEADER_API"
echo "  Hub MCP:   $WOLF_LEADER_MCP"
echo "  Workspace: $WORKSPACE"
echo ""

if ! wl_preflight "$CURSOR_DIR" "$WORKSPACE" "$WOLF_LEADER_API" "$FORCE" "$REQUESTED_API"; then
  [[ "$FORCE" == 1 ]] || exit 1
fi
echo ""

run_step() {
  local label="$1"
  shift
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "  [dry-run] $label"
    return 0
  fi
  if "$@"; then
    return 0
  fi
  INSTALL_FAIL=1
  return 0
}

install_file() {
  install -m "$1" "$2" "$3"
  wl_step_ok "$(basename "$3")"
}

if [[ "$DRY_RUN" == 0 ]]; then
  mkdir -p \
    "$CURSOR_DIR/skills/save/scripts" \
    "$CURSOR_DIR/skills/new/scripts" \
    "$CURSOR_DIR/hooks" \
    "$CURSOR_DIR/rules"
  rm -rf "$CURSOR_DIR/skills/save-new"
fi

run_step "skills/save" install_file 644 \
  "$CURSOR_EXAMPLES/skills/save/SKILL.md" "$CURSOR_DIR/skills/save/SKILL.md"
run_step "save-session.sh" install_file 755 \
  "$CURSOR_EXAMPLES/skills/save/scripts/save-session.sh" "$CURSOR_DIR/skills/save/scripts/save-session.sh"
run_step "save-session.py" install_file 755 \
  "$CURSOR_EXAMPLES/skills/save/scripts/save-session.py" "$CURSOR_DIR/skills/save/scripts/save-session.py"
run_step "save-session-curl.sh" install_file 755 \
  "$CURSOR_EXAMPLES/skills/save/scripts/save-session-curl.sh" "$CURSOR_DIR/skills/save/scripts/save-session-curl.sh"

run_step "skills/new" install_file 644 \
  "$CURSOR_EXAMPLES/skills/new/SKILL.md" "$CURSOR_DIR/skills/new/SKILL.md"
run_step "new-project-session.sh" install_file 755 \
  "$CURSOR_EXAMPLES/skills/new/scripts/new-project-session.sh" "$CURSOR_DIR/skills/new/scripts/new-project-session.sh"
run_step "new-project-session.py" install_file 755 \
  "$CURSOR_EXAMPLES/skills/new/scripts/new-project-session.py" "$CURSOR_DIR/skills/new/scripts/new-project-session.py"
run_step "new-project-session-curl.sh" install_file 755 \
  "$CURSOR_EXAMPLES/skills/new/scripts/new-project-session-curl.sh" "$CURSOR_DIR/skills/new/scripts/new-project-session-curl.sh"

if [[ "$DRY_RUN" == 1 ]]; then
  echo "  [dry-run] hooks.json merge"
elif ! wl_merge_hooks_json "$CURSOR_DIR/hooks.json" "$CURSOR_EXAMPLES/hooks.json"; then
  INSTALL_FAIL=1
fi
run_step "recall hook" install_file 755 \
  "$CURSOR_EXAMPLES/hooks/wolf-leader-recall.sh" "$CURSOR_DIR/hooks/wolf-leader-recall.sh"
run_step "save hook" install_file 755 \
  "$CURSOR_EXAMPLES/hooks/wolf-leader-save.sh" "$CURSOR_DIR/hooks/wolf-leader-save.sh"

run_step "wolf-leader-hub rule" install_file 644 \
  "$CURSOR_EXAMPLES/rules/wolf-leader-hub.mdc" "$CURSOR_DIR/rules/wolf-leader-hub.mdc"

if [[ "$DRY_RUN" == 0 ]]; then
  mkdir -p "$CURSOR_DIR/lib"
  install -m 644 "${ROOT}/scripts/lib/wolf-leader-client.sh" "$CURSOR_DIR/lib/wolf-leader-client.sh"
  wl_step_ok "lib/wolf-leader-client.sh"
else
  echo "  [dry-run] lib/wolf-leader-client.sh"
fi

# --- env file ---
ENV_FILE="$CURSOR_DIR/wolf-leader.env"
if [[ "$DRY_RUN" == 1 ]]; then
  echo "  [dry-run] wolf-leader.env"
elif [[ -f "$ENV_FILE" && "$RECONFIGURE" != 1 ]]; then
  wl_step_skip "wolf-leader.env (kept existing — use --reconfigure to update URLs)"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
else
  cat >"$ENV_FILE" <<EOF
# Wolf Leader hub URLs — edit if your hub moves
WOLF_LEADER_API=${WOLF_LEADER_API}
WOLF_LEADER_MCP=${WOLF_LEADER_MCP}
EOF
  if [[ "$RECONFIGURE" == 1 ]]; then
    wl_step_ok "wolf-leader.env (reconfigured)"
  else
    wl_step_ok "wolf-leader.env"
  fi
fi

MCP_URL="${WOLF_LEADER_MCP:-}"
if [[ -z "$MCP_URL" && -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  MCP_URL="${WOLF_LEADER_MCP:-}"
fi
[[ -n "$MCP_URL" ]] || MCP_URL="http://127.0.0.1:6972/mcp"

if [[ "$DRY_RUN" == 1 ]]; then
  echo "  [dry-run] mcp.json merge → $MCP_URL"
else
  wl_merge_mcp_json "$CURSOR_DIR/mcp.json" "$MCP_URL" "$CURSOR_EXAMPLES/mcp.json.template" || INSTALL_FAIL=1
fi

AGENTS_SRC="${ROOT}/examples/AGENTS.md"
AGENTS_CANON="$CURSOR_DIR/AGENTS.md"
AGENTS_DEST="${WORKSPACE}/AGENTS.md"
if [[ -f "$AGENTS_SRC" && -d "$WORKSPACE" && -w "$WORKSPACE" ]]; then
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "  [dry-run] AGENTS.md → $AGENTS_DEST"
  else
    wl_install_agents_md "$AGENTS_SRC" "$AGENTS_CANON" "$AGENTS_DEST" || INSTALL_FAIL=1
  fi
elif [[ -f "$AGENTS_SRC" ]]; then
  wl_step_warn "AGENTS.md skipped — workspace not writable: $WORKSPACE"
fi

LINK_SLUG="${WOLF_LEADER_LINK_SLUG:-}"
LINK_NAME="${WOLF_LEADER_LINK_NAME:-}"
if [[ "$DRY_RUN" == 0 && -n "$LINK_SLUG" ]]; then
  wl_link_workspace_project "$WOLF_LEADER_API" "$WORKSPACE" "$LINK_SLUG" "${LINK_NAME:-$LINK_SLUG}" || true
elif [[ "$DRY_RUN" == 1 && -n "$LINK_SLUG" ]]; then
  echo "  [dry-run] link workspace → project ${LINK_SLUG}"
fi

echo ""
if [[ "$INSTALL_FAIL" -eq 1 ]]; then
  echo "Install finished with errors — fix FAIL items above, then re-run this script (safe to re-run)."
else
  echo "Wolf Leader Cursor client installed under $CURSOR_DIR"
fi

VERIFY="${ROOT}/scripts/verify-cursor-client.sh"
if [[ "$DRY_RUN" == 0 && -x "$VERIFY" ]]; then
  echo ""
  bash "$VERIFY" || INSTALL_FAIL=1
fi

if [[ "$JSON_OUT" == 1 ]]; then
  py_ok=false
  command -v python3 >/dev/null 2>&1 && py_ok=true
  printf '{"ok":%s,"cursor_dir":"%s","workspace":"%s","hub_api":"%s","hub_mcp":"%s","python":%s,"linked_slug":"%s"}\n' \
    "$( [[ "$INSTALL_FAIL" -eq 0 ]] && echo true || echo false )" \
    "$CURSOR_DIR" "$WORKSPACE" "$WOLF_LEADER_API" "$WOLF_LEADER_MCP" \
    "$py_ok" "${LINK_SLUG:-}"
fi

[[ "$INSTALL_FAIL" -eq 0 ]]
