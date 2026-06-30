#!/usr/bin/env bash
# Deploy Wolf Leader production from your Mac (after git push).
#
# Usage:
#   ./scripts/deploy-prod.sh           # deploy current branch on Proxmox host
#   ./scripts/deploy-prod.sh main      # deploy a specific branch
#
set -euo pipefail

PROXMOX="${WOLF_LEADER_PROXMOX_HOST:-root@192.168.1.230}"
BRANCH="${1:-}"

if [[ -n "$BRANCH" ]]; then
  remote_cmd="cd /opt/wolf-leader && git fetch origin && git checkout $BRANCH && git pull --ff-only origin $BRANCH && WOLF_LEADER_BRANCH=$BRANCH bash scripts/deploy-wolf-leader-lxc.sh"
else
  remote_cmd="cd /opt/wolf-leader && git pull --ff-only && bash scripts/deploy-wolf-leader-lxc.sh"
fi

echo "Deploying via $PROXMOX ..."
ssh "$PROXMOX" "$remote_cmd"
