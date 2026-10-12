#!/usr/bin/env bash
# Install Wolf Leader's portable skills for any skill-capable agent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_SKILLS_DIR="${AGENT_SKILLS_DIR:-}"

if [[ -z "$AGENT_SKILLS_DIR" ]]; then
  echo "ERROR: set AGENT_SKILLS_DIR to this agent's user-level skills directory" >&2
  exit 2
fi

mkdir -p "$AGENT_SKILLS_DIR"
for source in "$ROOT"/examples/shared/skills/*; do
  [[ -d "$source" && -f "$source/SKILL.md" ]] || continue
  name="$(basename "$source")"
  mkdir -p "$AGENT_SKILLS_DIR/$name"
  cp -R "$source/." "$AGENT_SKILLS_DIR/$name/"
  find "$AGENT_SKILLS_DIR/$name/scripts" -type f -name '*.sh' -exec chmod 755 {} + 2>/dev/null || true
  echo "  + $AGENT_SKILLS_DIR/$name"
done

echo "Portable Wolf Leader skills installed. Reload the agent and confirm /wolfhowl and /wolfeat appear."
