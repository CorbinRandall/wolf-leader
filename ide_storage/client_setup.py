"""Client setup and hub-served install bundle for Wolf Leader."""
from __future__ import annotations

import io
import os
import tarfile
from pathlib import Path
from typing import Any

from ide_storage.branding import PRODUCT_NAME

REPO_ROOT = Path(__file__).resolve().parent.parent
CURSOR_EXAMPLES = REPO_ROOT / "examples" / "cursor"
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
        "cursor-corbox",
        "cursor-generic",
        "claude-code",
    }
)


def hub_urls() -> dict[str, str]:
    public = os.environ.get("IDE_STORAGE_PUBLIC_URL", "http://127.0.0.1:6971").rstrip("/")
    local = os.environ.get("IDE_STORAGE_LOCAL_URL", public).rstrip("/")
    mcp = os.environ.get("IDE_STORAGE_MCP_URL", f"{public.rsplit(':', 1)[0]}:6972/mcp")
    return {"api": public, "api_local": local, "mcp": mcp, "setup_web": f"{public}/?tab=setup"}


def build_agent_prompt(*, urls: dict[str, str] | None = None) -> str:
    """Single copy-paste prompt for any device, OS, and MCP-capable agent."""
    urls = urls or hub_urls()
    api = urls["api"]
    mcp = urls["mcp"]

    return f"""Connect this device to {PRODUCT_NAME}.

Hub API: {api}
MCP: {mcp}

Works on macOS, Windows, and Linux — local machine or remote host (SSH). Works with any MCP-capable agent (Cursor, Claude Code, Claude Desktop, Gemini CLI, etc.).

## Step 1 — Fetch setup spec (mandatory)
curl -s "{api}/api/client-setup"
curl -s "{api}/api/onboarding"

## Step 2 — Set workspace path
WORKSPACE = absolute path to the project folder opened in the IDE (use pwd, ask the user, or infer from the workspace root).

## Step 3 — Connect MCP (all agents)
Add MCP server `wolf-leader` → {mcp}

Examples:
- Cursor: ~/.cursor/mcp.json → "wolf-leader": {{ "url": "{mcp}" }}
- Claude Code: claude mcp add wolf-leader --url {mcp}
- Other MCP clients: use their config format with the same URL

If the hub runs on another machine, use the LAN/Tailscale URL above — not localhost — unless the hub is on this same machine.

## Step 4 — Cursor client (only if using Cursor)
Run on the machine that owns ~/.cursor (local laptop or Remote-SSH target):

WOLF_LEADER_API={api} \\
WOLF_LEADER_MCP={mcp} \\
WORKSPACE=<WORKSPACE> \\
  bash -c "$(curl -fsSL {api}/api/client-setup/install.sh)"

If curl pipe fails:
  curl -fsSL {api}/api/client-bundle.tar.gz -o /tmp/wl-client.tar.gz
  mkdir -p /tmp/wl-client && tar xzf /tmp/wl-client.tar.gz -C /tmp/wl-client
  WOLF_LEADER_API={api} WOLF_LEADER_MCP={mcp} WORKSPACE=<WORKSPACE> /tmp/wl-client/scripts/install-cursor-client.sh

Reload the Cursor window. /save and /new should appear in the slash menu.

## Step 5 — Verify
curl -s "{api}/health"
MCP: resolve_project + recall — or curl "{api}/api/bootstrap?path=<WORKSPACE>"
Place AGENTS.md in the workspace root (included in the hub client bundle).

## Step 6 — Every session
Start: resolve_project({{ path: "<WORKSPACE>" }}) → recall() or get_brief()
During: remember() for durable decisions
End: /save (Cursor) or MCP save_session

Report: OS, agent/IDE, WORKSPACE used, MCP connected, hub health OK, and whether /save is available.
"""


def client_setup_payload(*, legacy_profile: str | None = None) -> dict[str, Any]:
    urls = hub_urls()
    payload: dict[str, Any] = {
        "id": "universal",
        "label": "Any device · any agent",
        "description": (
            "One setup flow for macOS, Windows, Linux, local or remote. "
            "Cursor, Claude Code, Claude Desktop, Gemini CLI, or any MCP client."
        ),
        "workspace": "<your project root>",
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
    """Tar.gz of examples/cursor + install script + AGENTS.md for hub install."""
    buf = io.BytesIO()
    paths: list[tuple[Path, str]] = []

    if CURSOR_EXAMPLES.is_dir():
        for path in CURSOR_EXAMPLES.rglob("*"):
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
