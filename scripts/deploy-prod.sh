#!/usr/bin/env bash
# Deploy Wolf Leader production from your workstation (after git push).
#
# Usage:
#   WOLF_LEADER_PROXMOX_HOST=root@<proxmox-host> WOLF_LEADER_VMID=<ctid> ./scripts/deploy-prod.sh
#   ... ./scripts/deploy-prod.sh main      # deploy a specific branch
#
set -euo pipefail

PROXMOX="${WOLF_LEADER_PROXMOX_HOST:-}"
VMID="${WOLF_LEADER_VMID:-}"
BRANCH="${1:-}"

if [[ -z "$PROXMOX" || -z "$VMID" ]]; then
  echo "ERROR: set WOLF_LEADER_PROXMOX_HOST (ssh target, e.g. root@<proxmox-host>) and WOLF_LEADER_VMID (<ctid>)" >&2
  exit 1
fi

if [[ -n "$BRANCH" ]]; then
  remote_cmd="cd /opt/wolf-leader && git fetch origin && git checkout $BRANCH && git pull --ff-only origin $BRANCH && WOLF_LEADER_VMID=$VMID WOLF_LEADER_BRANCH=$BRANCH bash scripts/deploy-wolf-leader-lxc.sh"
else
  remote_cmd="cd /opt/wolf-leader && git pull --ff-only && WOLF_LEADER_VMID=$VMID bash scripts/deploy-wolf-leader-lxc.sh"
fi

echo "Deploying via $PROXMOX ..."
ssh "$PROXMOX" "$remote_cmd"
