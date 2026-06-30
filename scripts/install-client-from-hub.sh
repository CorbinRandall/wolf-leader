#!/usr/bin/env bash
# Install Wolf Leader Cursor client from the hub (no git clone).
# Usage: curl -fsSL http://HUB:6971/api/client-setup/install.sh | bash
set -uo pipefail

WOLF_LEADER_API="${WOLF_LEADER_API:-}"
WOLF_LEADER_MCP="${WOLF_LEADER_MCP:-}"
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
  echo "ERROR: set WOLF_LEADER_API (hub REST URL, e.g. http://192.168.1.230:6971)" >&2
  exit 1
fi

API="${WOLF_LEADER_API%/}"
TMP="${TMPDIR:-/tmp}/wolf-leader-client-$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading client bundle from $API ..."
curl -fsSL "${API}/api/client-bundle.tar.gz" | tar xz -C "$TMP"

if [[ ! -f "$TMP/scripts/install-cursor-client.sh" ]]; then
  echo "ERROR: bundle missing install-cursor-client.sh" >&2
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
echo ""
bash "$TMP/scripts/install-cursor-client.sh" "${INSTALL_ARGS[@]}"
rc=$?

if [[ "$rc" -ne 0 ]]; then
  echo ""
  echo "Install reported errors. Safe to re-run the same command after fixing blockers."
  exit "$rc"
fi

echo ""
echo "Client install complete. Reload Cursor, then use /save and /new."
echo "Hub: $API/health"
