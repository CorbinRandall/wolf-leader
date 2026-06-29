#!/usr/bin/env bash
# Create a new Wolf Leader project and save the current session to it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "${SCRIPT_DIR}/new-project-session.py" "$@"
