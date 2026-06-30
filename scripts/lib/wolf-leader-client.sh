#!/usr/bin/env bash
# Shared helpers for Wolf Leader Cursor client install/verify (no Python required).
# shellcheck shell=bash

wl_step_ok() { echo "  + $*"; }
wl_step_skip() { echo "  = $*"; }
wl_step_warn() { echo "  WARN $*"; }
wl_step_fail() { echo "  FAIL $*" >&2; }

wl_has_cmd() { command -v "$1" >/dev/null 2>&1; }

wl_workspace_supports_symlinks() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  local probe="${dir}/.wl-symlink-probe-$$"
  ln -sfn /dev/null "$probe" 2>/dev/null || return 1
  rm -f "$probe" 2>/dev/null
  return 0
}

wl_resolve_hub_urls() {
  local env_file="${CURSOR_DIR:-$HOME/.cursor}/wolf-leader.env"
  local pass_api="${WOLF_LEADER_API:-}"
  local pass_mcp="${WOLF_LEADER_MCP:-}"
  local file_api="" file_mcp=""

  if [[ -f "$env_file" ]]; then
    file_api=$(grep -E '^WOLF_LEADER_API=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')
    file_mcp=$(grep -E '^WOLF_LEADER_MCP=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')
  fi

  WOLF_LEADER_API="${pass_api:-${file_api:-http://127.0.0.1:6971}}"
  WOLF_LEADER_MCP="${pass_mcp:-${file_mcp:-}}"
  if [[ -z "$WOLF_LEADER_MCP" ]]; then
    WOLF_LEADER_MCP="${WOLF_LEADER_API%:6971}:6972/mcp"
    if [[ "$WOLF_LEADER_MCP" != http* ]]; then
      WOLF_LEADER_MCP="http://127.0.0.1:6972/mcp"
    fi
  fi
  WOLF_LEADER_API="${WOLF_LEADER_API%/}"
}

wl_merge_mcp_json() {
  local dest="$1" url="$2" template="${3:-}"
  local tmp="${dest}.wl-merge.$$"

  if wl_has_cmd jq; then
    if [[ -f "$dest" ]]; then
      if ! jq empty "$dest" 2>/dev/null; then
        wl_step_warn "mcp.json invalid JSON — backing up and recreating wolf-leader entry"
        cp "$dest" "${dest}.bak.$$" 2>/dev/null || true
        jq -n --arg url "$url" \
          '{mcpServers: {"wolf-leader": {"url": $url}, "ide-storage": {"url": $url}}}' >"$tmp"
      else
        jq --arg url "$url" \
          '.mcpServers = (.mcpServers // {}) | .mcpServers["wolf-leader"] = {"url": $url} | .mcpServers["ide-storage"] = {"url": $url}' \
          "$dest" >"$tmp"
      fi
    else
      jq -n --arg url "$url" \
        '{mcpServers: {"wolf-leader": {"url": $url}, "ide-storage": {"url": $url}}}' >"$tmp"
    fi
    mv "$tmp" "$dest"
    wl_step_ok "mcp.json (wolf-leader → $url)"
    return 0
  fi

  if wl_has_cmd node; then
    node - "$dest" "$url" <<'NODE'
const fs = require('fs');
const dest = process.argv[2];
const url = process.argv[3];
let data = { mcpServers: {} };
if (fs.existsSync(dest)) {
  try { data = JSON.parse(fs.readFileSync(dest, 'utf8')); } catch (_) {}
}
data.mcpServers = data.mcpServers || {};
data.mcpServers['wolf-leader'] = { url };
data.mcpServers['ide-storage'] = { url };
fs.writeFileSync(dest, JSON.stringify(data, null, 2) + '\n');
NODE
    wl_step_ok "mcp.json (wolf-leader → $url, via node)"
    return 0
  fi

  if [[ ! -f "$dest" && -n "$template" && -f "$template" ]]; then
    sed "s|WOLF_LEADER_MCP_PLACEHOLDER|${url}|g" "$template" >"$dest"
    wl_step_ok "mcp.json (from template → $url)"
    return 0
  fi

  if [[ -f "$dest" ]] && grep -q '"wolf-leader"' "$dest" 2>/dev/null; then
    # Best-effort URL line update without jq (single-line url entries)
    if sed -E "s|(\"wolf-leader\"[[:space:]]*:[[:space:]]*\\{[^}]*\"url\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")|\\1${url}\\2|g" "$dest" >"$tmp" 2>/dev/null \
      && grep -q "$url" "$tmp" 2>/dev/null; then
      mv "$tmp" "$dest"
      wl_step_ok "mcp.json (wolf-leader URL updated → $url)"
      return 0
    fi
    rm -f "$tmp" 2>/dev/null
  fi

  wl_step_fail "mcp.json merge — need jq, node, or no existing mcp.json (install jq: apt/apk install jq)"
  cat >&2 <<EOF

Manual fix — add to $dest under mcpServers:
  "wolf-leader": { "url": "$url" }

Already installed: skills, hooks, rules, wolf-leader.env (if present)
EOF
  return 1
}

wl_install_agents_md() {
  local src="$1" canon="$2" dest="$3"
  [[ -f "$src" ]] || return 0
  install -m 644 "$src" "$canon"
  if wl_workspace_supports_symlinks "$(dirname "$dest")"; then
    ln -sfn "$canon" "$dest"
    wl_step_ok "AGENTS.md → symlink ($dest)"
  else
    install -m 644 "$canon" "$dest"
    wl_step_ok "AGENTS.md → copied ($dest, symlinks not supported on this filesystem)"
  fi
}

wl_check_hub_health() {
  local api="$1"
  curl -sS -m 8 -o /dev/null -w "%{http_code}" "${api}/health" 2>/dev/null | grep -q 200
}

wl_preflight() {
  local cursor_dir="${1:-$HOME/.cursor}"
  local workspace="${2:-$HOME}"
  local api="${3:-}"
  local force="${4:-0}"
  local requested_api="${5:-}"
  local env_file="${cursor_dir}/wolf-leader.env"
  local blockers=0
  local file_api=""

  echo "Wolf Leader client preflight"
  echo ""

  if wl_has_cmd curl; then
    echo "  curl              OK"
  else
    echo "  curl              FAIL (required)"
    blockers=$((blockers + 1))
  fi

  if [[ -n "$api" ]]; then
    if wl_check_hub_health "$api"; then
      echo "  Hub REST          OK ($api/health)"
    else
      echo "  Hub REST          FAIL ($api/health unreachable)"
      [[ "$force" == 1 ]] || blockers=$((blockers + 1))
    fi
  else
    echo "  Hub REST          SKIP (WOLF_LEADER_API unset)"
  fi

  if [[ -w "$cursor_dir" ]] || mkdir -p "$cursor_dir" 2>/dev/null; then
    echo "  Cursor dir        OK ($cursor_dir writable)"
  else
    echo "  Cursor dir        FAIL ($cursor_dir not writable)"
    blockers=$((blockers + 1))
  fi

  if [[ -d "$workspace" && -w "$workspace" ]]; then
    if wl_workspace_supports_symlinks "$workspace"; then
      echo "  Workspace         OK ($workspace writable, symlinks OK)"
    else
      echo "  Workspace         OK ($workspace writable, will copy AGENTS.md — no symlinks)"
    fi
  elif [[ ! -d "$workspace" ]]; then
    echo "  Workspace         WARN ($workspace does not exist — will skip AGENTS.md)"
  else
    echo "  Workspace         FAIL ($workspace not writable)"
    [[ "$force" == 1 ]] || blockers=$((blockers + 1))
  fi

  if wl_has_cmd jq; then
    echo "  JSON merge        OK (jq)"
  elif wl_has_cmd node; then
    echo "  JSON merge        OK (node)"
  else
    echo "  JSON merge        WARN (no jq/node — new mcp.json from template only)"
  fi

  if wl_has_cmd python3; then
    echo "  Python runtime    OK (/save and /new full path with transcript upload)"
  else
    echo "  Python runtime    WARN (not found — /save and /new use curl fallback; no local transcript upload)"
  fi

  if [[ -f "$env_file" ]]; then
    file_api=$(grep -E '^WOLF_LEADER_API=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')
  fi
  req="${requested_api:-$api}"
  if [[ -n "$req" && -n "$file_api" && "$file_api" != "$req" ]]; then
    echo "  Env URL mismatch    WARN (wolf-leader.env has ${file_api}, install requested ${req})"
    echo "                    Hint: re-run with --reconfigure to update hub URLs"
  fi

  echo ""
  if [[ "$blockers" -gt 0 ]]; then
    echo "Preflight blocked ($blockers). Fix above or re-run with --force."
    return 1
  fi
  echo "Preflight passed."
  return 0
}

# Format bootstrap JSON into hook additional_context (jq preferred, grep fallback).
wl_format_bootstrap_context() {
  local bootstrap="$1"
  [[ -n "$bootstrap" ]] || return 1

  if wl_has_cmd jq; then
    jq -r '
      def parts:
        (if .project_name or .project_slug then
          "Wolf Leader project: \(.project_name // "?") (\(.project_slug // "unlinked"))"
        else empty end),
        (if .brief_url then "Agent brief: \(.brief_url)" else empty end),
        (if .pickup_prompt then "Pickup: \(.pickup_prompt)" else empty end),
        (.context_block // .context // .markdown // empty | if type == "string" then .[0:4000] else empty end);
      [parts] | map(select(. != null and . != "")) | if length == 0 then empty else
        "Wolf Leader bootstrap (sessionStart hook):\n" + join("\n\n")
      end
    ' <<<"$bootstrap" 2>/dev/null && return 0
  fi

  if wl_has_cmd python3; then
    python3 - "$bootstrap" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(1)
parts = []
if data.get("project_name") or data.get("project_slug"):
    parts.append(f"Wolf Leader project: {data.get('project_name') or '?'} ({data.get('project_slug') or 'unlinked'})")
if data.get("brief_url"):
    parts.append(f"Agent brief: {data['brief_url']}")
if data.get("pickup_prompt"):
    parts.append(f"Pickup: {data['pickup_prompt']}")
block = data.get("context_block") or data.get("context") or data.get("markdown")
if isinstance(block, str) and block.strip():
    parts.append(block.strip()[:4000])
if not parts:
    sys.exit(1)
print("Wolf Leader bootstrap (sessionStart hook):\n" + "\n\n".join(parts))
PY
    return 0
  fi

  # Minimal grep fallback — brief URL and slug only
  local brief slug
  brief=$(grep -o '"brief_url"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$bootstrap" | head -1 | sed 's/.*"\(http[^"]*\)".*/\1/')
  slug=$(grep -o '"project_slug"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$bootstrap" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  if [[ -n "$brief" || -n "$slug" ]]; then
    echo "Wolf Leader bootstrap (sessionStart hook):"
    [[ -n "$slug" ]] && echo "Project: $slug"
    [[ -n "$brief" ]] && echo "Agent brief: $brief"
    return 0
  fi
  return 1
}

wl_emit_hook_json() {
  local ctx="$1"
  if wl_has_cmd jq; then
    jq -n --arg ctx "$ctx" '{additional_context: $ctx}'
  elif wl_has_cmd python3; then
    python3 -c 'import json,sys; print(json.dumps({"additional_context": sys.argv[1]}))' "$ctx"
  else
    # Escape for minimal JSON
    local esc="${ctx//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    esc="${esc//$'\n'/\\n}"
    printf '{"additional_context":"%s"}\n' "$esc"
  fi
}

wl_merge_hooks_json() {
  local dest="$1" src="$2"
  local tmp="${dest}.wl-hooks.$$"
  local wl_recall='./hooks/wolf-leader-recall.sh'
  local wl_save='./hooks/wolf-leader-save.sh'

  if [[ ! -f "$dest" ]]; then
    install -m 644 "$src" "$dest"
    wl_step_ok "hooks.json"
    return 0
  fi

  if wl_has_cmd jq; then
    jq --arg recall "$wl_recall" --arg save "$wl_save" '
      . as $dest |
      ($dest.hooks // {}) as $h |
      ($h.sessionStart // []) as $ss |
      ($h.stop // []) as $st |
      $dest | .hooks = ($h + {
        sessionStart: ($ss + [{command: $recall}] | unique_by(.command)),
        stop: ($st + [{command: $save}] | unique_by(.command))
      })
    ' "$dest" >"$tmp" 2>/dev/null && mv "$tmp" "$dest" && {
      wl_step_ok "hooks.json (merged wolf-leader hooks)"
      return 0
    }
    rm -f "$tmp" 2>/dev/null
  fi

  wl_step_warn "hooks.json replaced (install jq to merge with existing custom hooks)"
  install -m 644 "$src" "$dest"
  wl_step_ok "hooks.json"
}

wl_link_workspace_project() {
  local api="$1" workspace="$2" slug="$3" name="$4"
  [[ -n "$slug" && -n "$api" ]] || return 0

  local bootstrap project_id created=false
  bootstrap=$(curl -sS -m 10 -G "${api}/api/bootstrap" --data-urlencode "path=${workspace}" 2>/dev/null || true)
  if [[ -n "$bootstrap" ]] && grep -q '"matched"[[:space:]]*:[[:space:]]*true' <<<"$bootstrap"; then
    wl_step_skip "workspace already linked ($(grep -o '"project_slug"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$bootstrap" | head -1 || echo matched))"
    return 0
  fi

  if wl_has_cmd jq; then
    project_id=$(curl -sS "${api}/api/projects" | jq -r --arg s "$slug" '.projects[]? | select(.slug == $s) | .id' | head -1)
  else
    project_id=""
  fi

  if [[ -z "$project_id" || "$project_id" == "null" ]]; then
    local body
    if wl_has_cmd jq; then
      body=$(jq -n --arg name "$name" --arg slug "$slug" --arg path "$workspace" \
        '{name: $name, slug: $slug, path: $path}')
    else
      local name_esc="${name//\"/\\\"}" path_esc="${workspace//\"/\\\"}"
      body="{\"name\":\"${name_esc}\",\"slug\":\"${slug}\",\"path\":\"${path_esc}\"}"
    fi
    local resp
    resp=$(curl -sS -m 30 -X POST "${api}/api/projects" -H 'Content-Type: application/json' -d "$body" 2>/dev/null || true)
    if wl_has_cmd jq; then
      project_id=$(echo "$resp" | jq -r '.id // empty')
    else
      project_id=$(echo "$resp" | grep -o '"id"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | sed 's/[^0-9]*//')
    fi
    created=true
  fi

  if [[ -n "$project_id" && "$project_id" != "null" ]]; then
    if wl_has_cmd jq; then
      local upd
      upd=$(jq -n --arg path "$workspace" '{path: $path}')
      curl -sS -m 30 -X PUT "${api}/api/projects/${project_id}" \
        -H 'Content-Type: application/json' -d "$upd" >/dev/null 2>&1 || true
    fi
    if [[ "$created" == true ]]; then
      wl_step_ok "workspace linked → project ${slug} (created, path=${workspace})"
    else
      wl_step_ok "workspace linked → project ${slug} (path=${workspace})"
    fi
  else
    wl_step_warn "could not link workspace to ${slug} — create project in hub UI"
  fi
}
