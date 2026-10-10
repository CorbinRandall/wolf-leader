#!/usr/bin/env bash
# /wolfhowl runner: collect git state + transcript, POST /api/howl, print the report.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Probe with a real run: on Windows "python3" may be the Store stub that only prints an ad.
if python3 -c "" >/dev/null 2>&1; then
  exec python3 "${SCRIPT_DIR}/wolfhowl.py" "$@"
fi
if python -c "" >/dev/null 2>&1; then
  exec python "${SCRIPT_DIR}/wolfhowl.py" "$@"
fi
echo "wolfhowl needs python3 on this machine" >&2
exit 1
