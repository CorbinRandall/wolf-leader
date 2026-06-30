#!/usr/bin/env bash
# Create a new Wolf Leader project and save the current session to it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if command -v python3 >/dev/null 2>&1; then
  exec python3 "${SCRIPT_DIR}/new-project-session.py" "$@"
fi
exec bash "${SCRIPT_DIR}/new-project-session-curl.sh" "$@"
