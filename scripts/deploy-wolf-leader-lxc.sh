#!/usr/bin/env bash
# Deploy Wolf Leader production (LXC) from GitHub — standard git pull + docker rebuild.
#
# Run on the Proxmox host after pushing to GitHub:
#   cd /opt/wolf-leader && git pull --ff-only && ./scripts/deploy-wolf-leader-lxc.sh
#
# Or from your Mac:
#   ./scripts/deploy-prod.sh
#
set -euo pipefail

VMID="${WOLF_LEADER_VMID:-104}"
DEST="${WOLF_LEADER_DEST:-/opt/wolf-leader}"
SRC="${WOLF_LEADER_SRC:-/opt/wolf-leader}"
REPO="${WOLF_LEADER_REPO:-https://github.com/CorbinRandall/wolf-leader.git}"
HEALTH_URL="${WOLF_LEADER_HEALTH_URL:-http://127.0.0.1:6971/health}"

if [[ -z "${WOLF_LEADER_BRANCH:-}" && -d "$SRC/.git" ]]; then
  WOLF_LEADER_BRANCH="$(git -C "$SRC" rev-parse --abbrev-ref HEAD)"
fi
BRANCH="${WOLF_LEADER_BRANCH:-main}"

if ! pct status "$VMID" 2>/dev/null | grep -q running; then
  echo "ERROR: LXC $VMID is not running" >&2
  exit 1
fi

echo "Deploy Wolf Leader → LXC $VMID ($DEST)"
echo "  branch: $BRANCH"
echo "  repo:   $REPO"
echo ""

pct exec "$VMID" -- bash -s -- "$DEST" "$BRANCH" "$REPO" <<'EOF'
set -euo pipefail
DEST="$1"
BRANCH="$2"
REPO="$3"

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

bootstrap_git() {
  echo "Bootstrapping git in LXC (preserving data/ and .env)..."
  local staging
  staging="$(mktemp -d)"
  git clone --branch "$BRANCH" "$REPO" "$staging/repo"

  mkdir -p "$DEST"
  for keep in data .env; do
    if [[ -e "$DEST/$keep" ]]; then
      rm -rf "$staging/repo/$keep"
      cp -a "$DEST/$keep" "$staging/repo/$keep"
    fi
  done

  find "$DEST" -mindepth 1 -maxdepth 1 ! -name data ! -name .env -exec rm -rf {} +
  shopt -s dotglob nullglob
  cp -a "$staging/repo/"* "$DEST/"
  rm -rf "$staging"
  echo "Git bootstrap complete."
}

if [[ ! -d "$DEST/.git" ]]; then
  bootstrap_git
else
  echo "Pulling latest from origin/$BRANCH ..."
  cd "$DEST"
  git fetch origin
  git checkout "$BRANCH"
  git pull --ff-only origin "$BRANCH"
fi

cd "$DEST"
echo "Building and restarting container..."
compose_cmd up -d --build
docker image prune -f
EOF

echo ""
echo "Checking health: $HEALTH_URL"
if pct exec "$VMID" -- curl -sf "$HEALTH_URL" >/dev/null 2>&1; then
  pct exec "$VMID" -- curl -s "$HEALTH_URL"
  echo ""
  echo "Deploy complete."
else
  echo "WARNING: health check failed — inspect logs:" >&2
  echo "  pct exec $VMID -- docker logs wolf-leader --tail 50" >&2
  exit 1
fi
