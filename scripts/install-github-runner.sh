#!/usr/bin/env bash
# One-time: register a self-hosted GitHub Actions runner on the Proxmox host.
#
# 1. GitHub → wolf-leader → Settings → Actions → Runners → New self-hosted runner
# 2. Copy the registration token (expires in ~1 hour)
# 3. On Proxmox host:
#      GITHUB_RUNNER_TOKEN='...' ./scripts/install-github-runner.sh
#
set -euo pipefail

REPO="${GITHUB_REPO:-CorbinRandall/wolf-leader}"
RUNNER_DIR="${RUNNER_DIR:-/opt/actions-runner}"
RUNNER_NAME="${RUNNER_NAME:-proxmox}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64,proxmox}"

if [[ -z "${GITHUB_RUNNER_TOKEN:-}" ]]; then
  echo "ERROR: set GITHUB_RUNNER_TOKEN from GitHub → Settings → Actions → Runners" >&2
  exit 1
fi

# Proxmox/host installs often run as root.
if [[ "$(id -u)" -eq 0 ]]; then
  export RUNNER_ALLOW_RUNASROOT=1
fi

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) RUNNER_ARCH=x64 ;;
  aarch64|arm64) RUNNER_ARCH=arm64 ;;
  *)
    echo "ERROR: unsupported arch: $ARCH" >&2
    exit 1
    ;;
esac

RUNNER_VERSION="${RUNNER_VERSION:-2.335.1}"
TARBALL="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}"

mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"

if [[ ! -f bin/Runner.Listener ]]; then
  echo "Downloading GitHub Actions runner ${RUNNER_VERSION} (${RUNNER_ARCH}) ..."
  curl -fsSL -o "$TARBALL" "$URL"
  tar xzf "$TARBALL"
  rm -f "$TARBALL"
fi

if [[ -f .runner ]]; then
  echo "Runner already configured in $RUNNER_DIR"
else
  ./config.sh \
    --url "https://github.com/${REPO}" \
    --token "$GITHUB_RUNNER_TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$RUNNER_LABELS" \
    --unattended \
    --replace
fi

./svc.sh install
./svc.sh start

echo ""
echo "Self-hosted runner installed."
echo "  service: actions.runner.${REPO//\//-}.${RUNNER_NAME}.service"
echo "  verify:  GitHub → Settings → Actions → Runners (should show online)"
echo ""
echo "Pushes to main will now run tests, then deploy automatically."
