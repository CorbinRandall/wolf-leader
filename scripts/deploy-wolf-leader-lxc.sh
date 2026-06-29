#!/usr/bin/env bash
# Deploy Wolf Leader on corbox LXC 104 (sync code, rebuild, prune old images).
set -euo pipefail

VMID="${WOLF_LEADER_VMID:-104}"
SRC="${WOLF_LEADER_SRC:-/opt/wolf-leader}"
DEST="/opt/wolf-leader"

if ! pct status "$VMID" 2>/dev/null | grep -q running; then
  echo "ERROR: LXC $VMID is not running" >&2
  exit 1
fi

echo "Syncing $SRC → VMID $VMID:$DEST"
pct exec "$VMID" -- mkdir -p "$DEST"

push_file() {
  local rel="$1"
  [[ -e "$SRC/$rel" ]] || return 0
  pct exec "$VMID" -- mkdir -p "$DEST/$(dirname "$rel")"
  pct exec "$VMID" -- rm -f "$DEST/$rel"
  pct push "$VMID" "$SRC/$rel" "$DEST/$rel"
}

for rel in docker-compose.yml Dockerfile requirements.txt start.sh ide_storage examples scripts; do
  if [[ -d "$SRC/$rel" ]]; then
    while IFS= read -r f; do
      push_file "${f#"$SRC/"/}"
    done < <(find "$SRC/$rel" -type f)
  else
    push_file "$rel"
  fi
done

pct exec "$VMID" -- bash -c "cd $DEST && docker-compose up -d --build && docker image prune -f"

echo "Wolf Leader deployed on VMID $VMID"
echo "  http://192.168.1.221:6971/health"
