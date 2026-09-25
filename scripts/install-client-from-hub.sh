#!/usr/bin/env bash
# Install Wolf Leader agent client files from the hub (no git clone).
# Usage: curl -fsSL http://HUB:6971/api/client-setup/install.sh | bash
set -uo pipefail

WOLF_LEADER_API="${WOLF_LEADER_API:-}"
WOLF_LEADER_MCP="${WOLF_LEADER_MCP:-}"
WOLF_LEADER_CLIENT="${WOLF_LEADER_CLIENT:-auto}"
WORKSPACE="${WORKSPACE:-${PWD:-$HOME}}"
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --dry-run) export WL_INSTALL_DRY_RUN=1; shift ;;
    *) shift ;;
  esac
done

if [[ -z "$WOLF_LEADER_API" ]]; then
  echo "ERROR: set WOLF_LEADER_API (hub REST URL, e.g. http://YOUR_HOST:6971)" >&2
  exit 1
fi

API="${WOLF_LEADER_API%/}"
TMP="${TMPDIR:-/tmp}/wolf-leader-client-$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading client bundle from $API ..."
curl -fsSL "${API}/api/client-bundle.tar.gz" | tar xz -C "$TMP"

if [[ ! -f "$TMP/scripts/install-cursor-client.sh" || ! -f "$TMP/scripts/install-codex-client.sh" ]]; then
  echo "ERROR: bundle is missing a client installer" >&2
  exit 1
fi

export WOLF_LEADER_API="$API"
if [[ -z "$WOLF_LEADER_MCP" ]]; then
  base="${API%:*}"
  WOLF_LEADER_MCP="${base}:6972/mcp"
fi
export WOLF_LEADER_MCP
export WORKSPACE

INSTALL_ARGS=()
[[ "$FORCE" == 1 ]] && INSTALL_ARGS+=(--force)
[[ "${WL_INSTALL_DRY_RUN:-0}" == 1 ]] && INSTALL_ARGS+=(--dry-run)

echo "Installing for workspace: $WORKSPACE"
echo "Requested client: $WOLF_LEADER_CLIENT"
echo ""

clients=()
case "$WOLF_LEADER_CLIENT" in
  cursor) clients=(cursor) ;;
  codex) clients=(codex) ;;
  all) clients=(cursor codex) ;;
  auto)
    [[ -d "${HOME}/.cursor" ]] && clients+=(cursor)
    if [[ -d "${HOME}/.codex" || -d "${HOME}/.agents" ]] || command -v codex >/dev/null 2>&1; then
      clients+=(codex)
    fi
    ;;
  *)
    echo "ERROR: WOLF_LEADER_CLIENT must be cursor, codex, all, or auto" >&2
    exit 2
    ;;
esac

if [[ "${#clients[@]}" -eq 0 ]]; then
  echo "ERROR: could not detect Cursor or Codex. Set WOLF_LEADER_CLIENT=cursor or codex." >&2
  exit 1
fi

rc=0
for client in "${clients[@]}"; do
  if [[ "$client" == cursor ]]; then
    bash "$TMP/scripts/install-cursor-client.sh" "${INSTALL_ARGS[@]}" || rc=1
  else
    bash "$TMP/scripts/install-codex-client.sh" || rc=1
  fi
done

if [[ "$rc" -ne 0 ]]; then
  echo ""
  echo "Install reported errors. Safe to re-run the same command after fixing blockers."
  exit "$rc"
fi

echo ""
echo "Client install and file verification complete. Reload the installed client."
echo "For Codex, review and trust Wolf Leader hooks in Settings → Hooks before automatic saves can run."
echo "Confirm /save appears, then complete one test save before considering setup finished."
echo "Hub: $API/health"
