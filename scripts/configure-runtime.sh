#!/usr/bin/env bash
# Detect this device's stable reachable address and write the local .env file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/.env"
PUBLIC_HOST="${WOLF_LEADER_PUBLIC_HOST:-}"
DEVICE_NAME="${WOLF_LEADER_DEVICE_NAME:-}"
FORCE=0

usage() {
  echo "Usage: $0 [--host ADDRESS] [--name DEVICE] [--force]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) PUBLIC_HOST="${2:?--host needs an address}"; shift 2 ;;
    --name) DEVICE_NAME="${2:?--name needs a device name}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -f "$ENV_FILE" && $FORCE -ne 1 ]]; then
  echo ".env already exists; keeping it. Use --force to redetect this device."
  exit 0
fi

detect_tailscale_ip() {
  if command -v tailscale >/dev/null 2>&1; then
    tailscale ip -4 2>/dev/null | head -n 1
    return
  fi
  # Android's Tailscale app exposes its CGNAT address on tun0 but does not put
  # a tailscale executable inside Termux.
  if command -v ifconfig >/dev/null 2>&1; then
    ifconfig 2>/dev/null | awk '
      /inet 100\./ {
        split($2, octets, ".")
        if (octets[2] >= 64 && octets[2] <= 127) { print $2; exit }
      }'
  fi
}

detect_lan_ip() {
  if command -v ip >/dev/null 2>&1; then
    ip -o -4 addr show scope global 2>/dev/null | awk '!/docker|br-|veth|rndis|tun/ {split($4,a,"/"); print a[1]; exit}'
  elif command -v ifconfig >/dev/null 2>&1; then
    ifconfig 2>/dev/null | awk '
      /^[[:alnum:]]/ { iface=$1; sub(":$", "", iface) }
      /inet / && $2 != "127.0.0.1" && iface !~ /^(docker|br-|veth|rndis|tun)/ { print $2; exit }'
  elif command -v ipconfig >/dev/null 2>&1; then
    ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null
  fi
}

if [[ -z "$PUBLIC_HOST" ]]; then
  PUBLIC_HOST="$(detect_tailscale_ip || true)"
fi
if [[ -z "$PUBLIC_HOST" ]]; then
  PUBLIC_HOST="$(detect_lan_ip || true)"
fi
PUBLIC_HOST="${PUBLIC_HOST:-127.0.0.1}"

if [[ -z "$DEVICE_NAME" ]] && command -v getprop >/dev/null 2>&1; then
  DEVICE_NAME="$(getprop net.hostname 2>/dev/null || true)"
  DEVICE_NAME="${DEVICE_NAME:-$(getprop ro.product.model 2>/dev/null | tr '[:upper:] ' '[:lower:]-')}"
fi
DEVICE_NAME="${DEVICE_NAME:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)}"
DEVICE_NAME="${DEVICE_NAME:-wolf-leader}"

if [[ -f "$ENV_FILE" ]]; then
  cp "$ENV_FILE" "$ENV_FILE.bak"
fi

sed \
  -e "s|^IDE_STORAGE_PUBLIC_HOST=.*|IDE_STORAGE_PUBLIC_HOST=$PUBLIC_HOST|" \
  -e "s|^IDE_STORAGE_PUBLIC_URL=.*|IDE_STORAGE_PUBLIC_URL=http://$PUBLIC_HOST:6971|" \
  -e "s|^IDE_STORAGE_MCP_URL=.*|IDE_STORAGE_MCP_URL=http://$PUBLIC_HOST:6972/mcp|" \
  -e "s|^IDE_STORAGE_DEVICE_NAME=.*|IDE_STORAGE_DEVICE_NAME=$DEVICE_NAME|" \
  -e "s|^IDE_STORAGE_HOST_LABEL=.*|IDE_STORAGE_HOST_LABEL=$DEVICE_NAME|" \
  "$ROOT/.env.example" > "$ENV_FILE"

chmod 600 "$ENV_FILE"
echo "Configured Wolf Leader for $DEVICE_NAME at $PUBLIC_HOST"
echo "  Web: http://$PUBLIC_HOST:6971"
echo "  MCP: http://$PUBLIC_HOST:6972/mcp"
