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

# These are product-managed copies served by the setup API. Refresh them on
# every install/update so existing hubs do not keep stale onboarding prompts.
install -m 644 examples/AGENTS.md data/AGENTS.md
install -m 644 examples/ONBOARDING.md data/ONBOARDING.md
echo "  ~ AGENTS.md"
echo "  ~ ONBOARDING.md"

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
