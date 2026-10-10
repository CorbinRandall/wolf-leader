#!/usr/bin/env bash
# Fail CI when tracked files contain common machine-specific values that should
# live in .env, docker-compose.local.yml, or a workspace-local AGENTS.md.
set -euo pipefail

failed=0

check_pattern() {
  local label="$1"
  local pattern="$2"
  local matches
  matches="$(git grep -nE "$pattern" -- ':!scripts/check-public-hygiene.sh' || true)"
  if [[ -n "$matches" ]]; then
    echo "ERROR: tracked $label found:" >&2
    echo "$matches" >&2
    failed=1
  fi
}

check_pattern "macOS home path" '(^|[[:space:]"=])/Users/[[:alnum:]_.-]+'
check_pattern "RFC1918 URL" 'https?://(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)'

while IFS= read -r path; do
  if [[ -L "$path" ]]; then
    target="$(readlink "$path")"
  else
    target=""
  fi
  if [[ "$target" == /* ]]; then
    echo "ERROR: tracked symlink $path points to absolute path $target" >&2
    failed=1
  fi
done < <(git ls-files -s | awk '$1 == "120000" {print $4}')

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "Public repository hygiene check passed."
