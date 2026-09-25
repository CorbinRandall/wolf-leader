"""Client setup and hub-served install bundle for Wolf Leader."""
from __future__ import annotations

import io
import tarfile
from pathlib import Path
from typing import Any

from ide_storage.branding import PRODUCT_NAME
from ide_storage.runtime_config import runtime_config

REPO_ROOT = Path(__file__).resolve().parent.parent
CURSOR_EXAMPLES = REPO_ROOT / "examples" / "cursor"
CODEX_EXAMPLES = REPO_ROOT / "examples" / "codex"
INSTALL_SCRIPT = REPO_ROOT / "scripts" / "install-cursor-client.sh"
INSTALL_FROM_HUB = REPO_ROOT / "scripts" / "install-client-from-hub.sh"
VERIFY_SCRIPT = REPO_ROOT / "scripts" / "verify-cursor-client.sh"
PREFLIGHT_SCRIPT = REPO_ROOT / "scripts" / "preflight-cursor-client.sh"
CLIENT_LIB = REPO_ROOT / "scripts" / "lib" / "wolf-leader-client.sh"
AGENTS_MD = REPO_ROOT / "examples" / "AGENTS.md"

BUNDLE_SCRIPTS = (
    INSTALL_SCRIPT,
    INSTALL_FROM_HUB,
    VERIFY_SCRIPT,
    PREFLIGHT_SCRIPT,
    CLIENT_LIB,
    AGENTS_MD,
)

# Legacy profile IDs from older hubs — all resolve to the unified setup payload.
LEGACY_PROFILE_IDS = frozenset(
    {
        "cursor-unraid",
        "cursor-generic",
        "claude-code",
    }
)


def hub_urls() -> dict[str, str]:
    cfg = runtime_config()
    public = cfg.public_url
    local = cfg.local_url
    mcp = cfg.mcp_url
    return {"api": public, "api_local": local, "mcp": mcp, "setup_web": f"{public}/?tab=setup"}


def build_agent_prompt(*, urls: dict[str, str] | None = None) -> str:
    """Single copy-paste prompt for any device, OS, and MCP-capable agent."""
    urls = urls or hub_urls()
    api = urls["api"]
    mcp = urls["mcp"]

    return f"""Connect this device to {PRODUCT_NAME} and complete the setup.

Hub API: {api}
MCP: {mcp}

Works on macOS, Windows, and Linux — local machine or remote host (SSH). Works with any MCP-capable agent (Cursor, Claude Code, Claude Desktop, Gemini CLI, etc.).

## Step 1 — Read the current setup instructions
Fetch and read both endpoints before changing client configuration:
curl -fsS "{api}/api/client-setup"
curl -fsS "{api}/api/onboarding"

## Step 2 — Identify this client and workspace
Use the current OS and IDE. Set WORKSPACE to the absolute path of the project folder open in the IDE. For Cursor Remote-SSH, install on the remote machine that owns ~/.cursor and use the remote workspace path. Do not guess a different host or overwrite unrelated client settings.

Ask the owner for any setup preference that is not already stated:
- model policy: economy, balanced, or maximum quality
- checkpoint policy: automatic background saves (recommended) or explicit saves only
- a friendly device name

Record these choices in the workspace AGENTS.md after installation. Do not put private addresses, credentials, user names, or machine-specific paths into tracked example files.

## Step 3 — Connect MCP
Add MCP server `wolf-leader` → {mcp}

Examples:
- Cursor: ~/.cursor/mcp.json → "wolf-leader": {{ "url": "{mcp}" }}
- Claude Code: claude mcp add wolf-leader --url {mcp}
- Other MCP clients: use their config format with the same URL

If the hub runs on another machine, use the LAN/Tailscale URL above — not localhost — unless the hub is on this same machine.

## Step 4 — Cursor integration (if this device uses Cursor)
Run on the machine that owns ~/.cursor (local laptop or Remote-SSH target):

WOLF_LEADER_API={api} \\
WOLF_LEADER_MCP={mcp} \\
WORKSPACE=<WORKSPACE> \\
  bash -c "$(curl -fsSL {api}/api/client-setup/install.sh)"

If curl pipe fails:
  curl -fsSL {api}/api/client-bundle.tar.gz -o /tmp/wl-client.tar.gz
  mkdir -p /tmp/wl-client && tar xzf /tmp/wl-client.tar.gz -C /tmp/wl-client
  WOLF_LEADER_API={api} WOLF_LEADER_MCP={mcp} WORKSPACE=<WORKSPACE> /tmp/wl-client/scripts/install-cursor-client.sh

This installs /save and /new skills, MCP, a session-start recall hook, an automatic save hook, and the Wolf Leader rule. It merges the Wolf Leader entries into existing Cursor configuration. Keep existing MCP servers and hooks. If the owner selected explicit saves only, disable the Wolf Leader stop hook after installation and document that choice in AGENTS.md.

Reload the Cursor window. Confirm /save and /new appear in the slash menu. Check ~/.cursor/wolf-leader-last-save.json for the most recent successful automatic checkpoint and ~/.cursor/wolf-leader-autosave-error.log if a save failed.

## Step 5 — Codex integration (if this device uses Codex)
Download and extract the client bundle, then copy `examples/codex/skills/save`
to `$CODEX_HOME/skills/save` (normally `~/.codex/skills/save`). Preserve all
existing Codex skills and configuration. The skill uses MCP `save_session` and
the live `/api/save-project-guide`; it does not use Cursor transcript scripts.

Reload Codex. Confirm the `save` skill is available. Invoke it with `$save`,
`/save`, or “save this” according to the client UI.

## Step 6 — Verify setup
curl -s "{api}/health"
MCP: resolve_project + recall — or curl "{api}/api/bootstrap?path=<WORKSPACE>"
Place AGENTS.md in the workspace root (included in the hub client bundle).

## Step 7 — Every session
Start: let the session-start hook inject Wolf Leader context; confirm the matching project with resolve_project({{ path: "<WORKSPACE>" }}) and recall() or get_brief() before project work.
During: remember() for durable decisions.
In the background: Cursor's automatic save hook checkpoints meaningful transcript updates after responses and on stop. It is best-effort; check the last-save status if needed.
End: use /save (Cursor) or MCP save_session for a deliberate final checkpoint. Automatic saving supplements this explicit checkpoint.

Report: OS, agent/IDE, friendly device name, WORKSPACE used, selected model and checkpoint policies, MCP connected, the exact API and MCP URLs configured, hub health, hooks installed, save/new skill availability, and automatic-save status. Fix setup errors before finishing.
"""


def client_setup_payload(*, legacy_profile: str | None = None) -> dict[str, Any]:
    urls = hub_urls()
    payload: dict[str, Any] = {
        "id": "universal",
        "label": "Any device · any agent",
        "description": (
            "Complete setup flow for macOS, Windows, Linux, local or remote. "
            "Cursor, Claude Code, Claude Desktop, Gemini CLI, or any MCP client. Includes Cursor recall and background checkpoint hooks."
        ),
        "workspace": "<your project root>",
        "server": runtime_config().as_dict(),
        "hub_api": urls["api"],
        "hub_mcp": urls["mcp"],
        "setup_web_url": urls["setup_web"],
        "agent_prompt": build_agent_prompt(urls=urls),
        "install_command": (
            f'WOLF_LEADER_API={urls["api"]} WOLF_LEADER_MCP={urls["mcp"]} '
            f'WORKSPACE="<your project root>" '
            f'bash -c "$(curl -fsSL {urls["api"]}/api/client-setup/install.sh)"'
        ),
        "bundle_url": f'{urls["api"]}/api/client-bundle.tar.gz',
        "onboarding_url": f'{urls["api"]}/api/onboarding',
    }
    if legacy_profile:
        payload["legacy_profile"] = legacy_profile
        payload["deprecated"] = (
            f"Profile '{legacy_profile}' is deprecated; use GET /api/client-setup instead."
        )
    return payload


def build_client_bundle() -> bytes:
    """Tar.gz of client examples, install scripts, and AGENTS.md."""
    buf = io.BytesIO()
    paths: list[tuple[Path, str]] = []

    if CURSOR_EXAMPLES.is_dir():
        for path in CURSOR_EXAMPLES.rglob("*"):
            if path.is_file():
                rel = path.relative_to(REPO_ROOT)
                paths.append((path, str(rel)))

    if CODEX_EXAMPLES.is_dir():
        for path in CODEX_EXAMPLES.rglob("*"):
            if path.is_file():
                rel = path.relative_to(REPO_ROOT)
                paths.append((path, str(rel)))

    for extra in BUNDLE_SCRIPTS:
        if extra.is_file():
            paths.append((extra, str(extra.relative_to(REPO_ROOT))))

    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for src, arcname in paths:
            tar.add(src, arcname=arcname)
    buf.seek(0)
    return buf.read()


def read_install_script() -> str:
    if INSTALL_FROM_HUB.is_file():
        return INSTALL_FROM_HUB.read_text(encoding="utf-8")
    return ""
