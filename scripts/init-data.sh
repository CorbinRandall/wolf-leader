#!/usr/bin/env bash
# Seed ./data from examples/ on first install (does not overwrite existing files).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mkdir -p data/projects

copy_if_missing() {
  local src="$1"
  local dest="$2"
  if [[ ! -f "$dest" ]]; then
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    echo "  + $(basename "$dest")"
  fi
}

echo "Initializing data directory…"

copy_if_missing examples/AGENTS.md data/AGENTS.md
copy_if_missing examples/ONBOARDING.md data/ONBOARDING.md

if [[ ! -f data/INDEX.md ]]; then
  cat > data/INDEX.md <<'EOF'
# Wolf Leader — Project Index

Projects live under `data/projects/{slug}/`. Use the Web UI or MCP to browse.

| Slug | Notes |
|------|-------|
| `_example` | Template — copy when creating projects |
EOF
  echo "  + INDEX.md"
fi

echo "Done."
