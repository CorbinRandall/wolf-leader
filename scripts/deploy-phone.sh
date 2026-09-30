#!/usr/bin/env bash
# One-time bootstrap/migration for the native Termux + Debian PRoot deployment.
# Afterwards, use: ssh moto 'cd ~/apps/wolf-leader && git pull --ff-only origin main'
set -euo pipefail

BRANCH="${1:-main}"
APP_DIR="${WOLF_LEADER_PHONE_DIR:-$HOME/apps/wolf-leader}"
REPO="${WOLF_LEADER_PHONE_REPO:-https://github.com/CorbinRandall/wolf-leader.git}"
SERVICE_DIR="${WOLF_LEADER_PHONE_SERVICE_DIR:-${PREFIX:-/data/data/com.termux/files/usr}/var/service/wolf-leader}"
STAMP="$(date +%Y%m%d-%H%M%S)"
STAGING="${APP_DIR}.staging-${STAMP}"
BACKUP="${APP_DIR}.pre-git-${STAMP}"

fail() { echo "Phone deployment failed: $*" >&2; exit 1; }

[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "invalid branch name"
command -v git >/dev/null 2>&1 || fail "git is required"
command -v sv >/dev/null 2>&1 || fail "runit (sv) is required"
[[ -d "$SERVICE_DIR" ]] || fail "service directory not found: $SERVICE_DIR"

if [[ -d "$APP_DIR/.git" ]]; then
  git -C "$APP_DIR" config core.hooksPath .githooks
  git -C "$APP_DIR" fetch origin "$BRANCH"
  git -C "$APP_DIR" checkout "$BRANCH"
  git -C "$APP_DIR" pull --ff-only origin "$BRANCH"
  echo "Wolf Leader is up to date on $BRANCH."
  exit 0
fi

if [[ -e "$STAGING" || -e "$BACKUP" ]]; then
  fail "staging or backup path already exists; retry after resolving $STAGING"
fi

git clone --branch "$BRANCH" --single-branch "$REPO" "$STAGING"

# A pre-Git phone install may already contain the only copies of its database,
# settings, and native virtual environment. Bring those forward untouched.
if [[ -d "$APP_DIR" ]]; then
  for item in .env data .venv; do
    if [[ -e "$APP_DIR/$item" ]]; then
      cp -a "$APP_DIR/$item" "$STAGING/$item"
    fi
  done
fi

git -C "$STAGING" config core.hooksPath .githooks

# Stop the managed service before switching folders. The previous checkout is
# retained as a recovery backup; it is never deleted by this script.
sv force-stop "$SERVICE_DIR" || true
mv "$APP_DIR" "$BACKUP"
mv "$STAGING" "$APP_DIR"

# This performs dependency refresh, restart, and health verification.
bash "$APP_DIR/scripts/phone-refresh.sh"
echo "Migrated the phone installation to Git. Backup retained at $BACKUP"
