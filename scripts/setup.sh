#!/usr/bin/env bash
# First-time setup: .env, data seed, Docker build + start.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example — edit IDE_STORAGE_PUBLIC_URL before sharing MCP URLs."
fi

bash scripts/init-data.sh

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not found. Install Docker, edit .env, then run:"
  echo "  docker compose up -d --build"
  exit 1
fi

COMPOSE_FILES=(-f docker-compose.yml)
if [[ -f docker-compose.local.yml ]]; then
  COMPOSE_FILES+=(-f docker-compose.local.yml)
  echo "Using docker-compose.local.yml overlay"
fi

echo "Building and starting Wolf Leader…"
docker compose "${COMPOSE_FILES[@]}" up -d --build

PUBLIC="$(grep -E '^IDE_STORAGE_PUBLIC_URL=' .env | cut -d= -f2- | tr -d '"' || true)"
PUBLIC="${PUBLIC:-http://127.0.0.1:6971}"

echo ""
echo "Wolf Leader is starting."
echo "  Web UI:  ${PUBLIC}/"
echo "  Setup:   ${PUBLIC}/?tab=setup"
echo "  MCP:     $(grep -E '^IDE_STORAGE_MCP_URL=' .env | cut -d= -f2- | tr -d '"' || echo 'http://127.0.0.1:6972/mcp')"
echo ""
echo "Next: on each Cursor device run:"
echo "  WOLF_LEADER_API=${PUBLIC} WOLF_LEADER_MCP=\$(grep -E '^IDE_STORAGE_MCP_URL=' .env | cut -d= -f2- | tr -d '\"' || echo 'http://127.0.0.1:6972/mcp') ./scripts/install-cursor-client.sh"
echo "See INSTALL.md for client setup."
