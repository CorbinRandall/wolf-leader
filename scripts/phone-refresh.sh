#!/usr/bin/env bash
# Refresh the native Termux/PRoot service after a Git update.
# This is called by .githooks/post-merge, making `git pull` a complete update.
set -euo pipefail

APP_DIR="${WOLF_LEADER_PHONE_DIR:-$HOME/apps/wolf-leader}"
SERVICE_DIR="${WOLF_LEADER_PHONE_SERVICE_DIR:-${PREFIX:-/data/data/com.termux/files/usr}/var/service/wolf-leader}"
PROOT_DISTRO="${WOLF_LEADER_PHONE_DISTRO:-debian}"
HEALTH_URL="${WOLF_LEADER_PHONE_HEALTH_URL:-http://127.0.0.1:6971/health}"

fail() { echo "Phone update failed: $*" >&2; exit 1; }

# Debian's interpreter symlink is intentionally resolved inside PRoot. Termux
# itself may report that link as non-executable even though the venv is healthy.
[[ -e "$APP_DIR/.venv/bin/python" || -L "$APP_DIR/.venv/bin/python" ]] || fail "missing Python environment at $APP_DIR/.venv"
command -v proot-distro >/dev/null 2>&1 || fail "proot-distro is required for the phone runtime"
command -v sv >/dev/null 2>&1 || fail "runit (sv) is required for the phone runtime"
[[ -d "$SERVICE_DIR" ]] || fail "service directory not found: $SERVICE_DIR"

# Install only the lean runtime dependencies. The phone uses keyword search by
# default; embedding dependencies remain opt-in and are intentionally omitted.
proot-distro login "$PROOT_DISTRO" -- bash -lc \
  "cd '$APP_DIR' && .venv/bin/python -m pip install --disable-pip-version-check -q -r requirements-core.txt"

sv force-restart "$SERVICE_DIR"

for _ in $(seq 1 20); do
  if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
    echo "Wolf Leader phone service is healthy."
    exit 0
  fi
  sleep 1
done

fail "service did not become healthy at $HEALTH_URL"
