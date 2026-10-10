#!/usr/bin/env bash
# Stop the natively-running Wolf Leader (REST + MCP).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
for name in rest mcp; do
  pidfile="$ROOT/data/$name.pid"
  if [[ -f "$pidfile" ]]; then
    pid="$(cat "$pidfile")"
    if kill "$pid" 2>/dev/null; then echo "stopped $name (pid $pid)"; fi
    rm -f "$pidfile"
  fi
done
# Backstop: kill any stragglers on the ports.
for port in 6971 6972; do
  lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | xargs -r kill 2>/dev/null || true
done
echo "Wolf Leader stopped."
