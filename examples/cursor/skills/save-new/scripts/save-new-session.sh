#!/usr/bin/env bash
# Save current chat as a new Wolf Leader project (create + checkpoint).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "${SCRIPT_DIR}/save-new-session.py" "$@"
