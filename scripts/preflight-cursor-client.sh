#!/usr/bin/env bash
# Preflight checks before Wolf Leader Cursor client install.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/wolf-leader-client.sh
source "${ROOT}/scripts/lib/wolf-leader-client.sh"

CURSOR_DIR="${CURSOR_DIR:-$HOME/.cursor}"
WORKSPACE="${WORKSPACE:-$HOME}"
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    -h|--help)
      echo "Usage: WOLF_LEADER_API=http://HOST:6971 $0 [--force]"
      exit 0
      ;;
    *) shift ;;
  esac
done

wl_resolve_hub_urls
wl_preflight "$CURSOR_DIR" "$WORKSPACE" "$WOLF_LEADER_API" "$FORCE"
