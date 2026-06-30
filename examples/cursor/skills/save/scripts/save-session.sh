#!/usr/bin/env bash
# On-demand Wolf Leader checkpoint (existing project only).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if command -v python3 >/dev/null 2>&1; then
  exec python3 "${SCRIPT_DIR}/save-session.py" "${1:-}"
fi
exec bash "${SCRIPT_DIR}/save-session-curl.sh" "${1:-}"
