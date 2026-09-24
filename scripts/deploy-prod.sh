#!/usr/bin/env bash
# Deploy Wolf Leader to a user-configured remote host (after git push).
#
# Usage:
#   WOLF_LEADER_DEPLOY_HOST=user@server WOLF_LEADER_REMOTE_DIR=/opt/wolf-leader ./scripts/deploy-prod.sh
#   ./scripts/deploy-prod.sh main      # deploy a specific branch
#
set -euo pipefail

DEPLOY_HOST="${WOLF_LEADER_DEPLOY_HOST:-}"
REMOTE_DIR="${WOLF_LEADER_REMOTE_DIR:-/opt/wolf-leader}"
BRANCH="${1:-}"

if [[ -z "$DEPLOY_HOST" ]]; then
  echo "ERROR: set WOLF_LEADER_DEPLOY_HOST to the SSH destination (for example user@server)" >&2
  exit 1
fi
if [[ -n "$BRANCH" && ! "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  echo "ERROR: invalid branch name" >&2
  exit 1
fi
if [[ ! "$REMOTE_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "ERROR: WOLF_LEADER_REMOTE_DIR must be an absolute path using letters, numbers, dots, underscores, dashes, and slashes" >&2
  exit 1
fi

if [[ -n "$BRANCH" ]]; then
  remote_cmd="cd '$REMOTE_DIR' && git fetch origin && git checkout '$BRANCH' && git pull --ff-only origin '$BRANCH' && WOLF_LEADER_BRANCH='$BRANCH' bash scripts/deploy-wolf-leader-lxc.sh"
else
  remote_cmd="cd '$REMOTE_DIR' && git pull --ff-only && bash scripts/deploy-wolf-leader-lxc.sh"
fi

echo "Deploying via $DEPLOY_HOST ..."
ssh "$DEPLOY_HOST" "$remote_cmd"
