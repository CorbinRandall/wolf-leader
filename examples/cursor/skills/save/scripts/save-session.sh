#!/usr/bin/env bash
# On-demand Wolf Leader checkpoint (existing project only).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "${SCRIPT_DIR}/save-session.py" "${1:-}"
