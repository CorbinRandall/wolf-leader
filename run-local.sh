#!/usr/bin/env bash
# Run Wolf Leader natively (no Docker), bound to localhost.
# Optional lightweight alternative to docker-compose for single-host use
# (e.g. a Mac without Docker Desktop). The Docker workflow is unchanged.
# Starts the MCP server (6972) + REST/Web UI (6971). Logs to ./data/logs/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

PY="$ROOT/.venv/bin/python"
# First run: bootstrap a local virtualenv + deps (prefer uv, fall back to venv).
if [[ ! -x "$PY" ]]; then
  echo "First run — creating .venv and installing requirements…"
  if command -v uv >/dev/null 2>&1; then
    uv venv --python 3.11 "$ROOT/.venv"
    uv pip install --python "$PY" -r "$ROOT/requirements.txt"
  else
    python3 -m venv "$ROOT/.venv"
    "$PY" -m pip install --quiet --upgrade pip
    "$PY" -m pip install -r "$ROOT/requirements.txt"
  fi
fi

# Defaults bind to localhost only. Override any of these in the environment to
# expose on a LAN/Tailscale (set HOST/MCP_HOST/IDE_STORAGE_PUBLIC_URL/MCP_URL).
export IDE_STORAGE_DB_PATH="${IDE_STORAGE_DB_PATH:-$ROOT/data/ide-work.db}"
export IDE_STORAGE_PROJECTS_DIR="${IDE_STORAGE_PROJECTS_DIR:-$ROOT/data/projects}"
export IDE_STORAGE_PUBLIC_URL="${IDE_STORAGE_PUBLIC_URL:-http://127.0.0.1:6971}"
export IDE_STORAGE_MCP_URL="${IDE_STORAGE_MCP_URL:-http://127.0.0.1:6972/mcp}"
export IDE_STORAGE_HOST_LABEL="${IDE_STORAGE_HOST_LABEL:-local}"
export IDE_STORAGE_COMPOSE_PATH="${IDE_STORAGE_COMPOSE_PATH:-$ROOT}"
export PORT="${PORT:-6971}" MCP_PORT="${MCP_PORT:-6972}"
export HOST="${HOST:-127.0.0.1}" MCP_HOST="${MCP_HOST:-127.0.0.1}" LOG_LEVEL="${LOG_LEVEL:-info}"

mkdir -p "$ROOT/data/logs"

"$PY" -m ide_storage.mcp_standalone >>"$ROOT/data/logs/mcp.log" 2>&1 &
MCP_PID=$!
"$PY" -m ide_storage.main >>"$ROOT/data/logs/rest.log" 2>&1 &
REST_PID=$!

echo "$MCP_PID"  > "$ROOT/data/mcp.pid"
echo "$REST_PID" > "$ROOT/data/rest.pid"
echo "Wolf Leader up — REST :$PORT (pid $REST_PID), MCP :$MCP_PORT (pid $MCP_PID)"
echo "  Web UI: ${IDE_STORAGE_PUBLIC_URL}/"

trap 'kill "$MCP_PID" "$REST_PID" 2>/dev/null || true' EXIT INT TERM
wait
