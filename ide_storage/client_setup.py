"""Client setup profiles and hub-served install bundle for Wolf Leader."""
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

PROFILES: dict[str, dict[str, str]] = {
    "cursor-unraid": {
        "label": "Cursor → Unraid (SSH)",
        "description": "SSH to Unraid (/boot/config). Hub on LAN (e.g. corbox Proxmox).",
        "workspace": "/boot/config",
        "host_label": "unraid",
        "link_slug": "unraid-config",
        "link_name": "Unraid Config",
    },
    "cursor-corbox": {
        "label": "Cursor → Corbox (SSH)",
        "description": "SSH to Proxmox host (/root). Wolf Leader hub on same LAN.",
        "workspace": "/root",
        "host_label": "corbox",
    },
    "cursor-generic": {
        "label": "Cursor (any SSH host)",
        "description": "Generic Cursor Remote-SSH workspace. Set WORKSPACE to your project root.",
        "workspace": "$HOME",
        "host_label": "client",
    },
    "claude-code": {
        "label": "Claude Code CLI",
        "description": "Terminal agent with MCP — no Cursor skills; use save_session via MCP.",
        "workspace": "$HOME",
        "host_label": "cli",
    },
}


def hub_urls() -> dict[str, str]:
    public = os.environ.get("IDE_STORAGE_PUBLIC_URL", "http://127.0.0.1:6971").rstrip("/")
    local = os.environ.get("IDE_STORAGE_LOCAL_URL", public).rstrip("/")
    mcp = os.environ.get("IDE_STORAGE_MCP_URL", f"{public.rsplit(':', 1)[0]}:6972/mcp")
    return {"api": public, "api_local": local, "mcp": mcp, "setup_web": f"{public}/?tab=setup"}


def build_agent_prompt(profile_id: str, *, urls: dict[str, str] | None = None) -> str:
    profile = PROFILES.get(profile_id, PROFILES["cursor-generic"])
    urls = urls or hub_urls()
    api = urls["api"]
    mcp = urls["mcp"]
    workspace = profile["workspace"]
    label = profile["label"]

    if profile_id == "claude-code":
        return f"""Connect this machine to {PRODUCT_NAME} ({label}).

Hub API: {api}
MCP: {mcp}
Workspace: {workspace}

1. Fetch setup guide: curl -s "{api}/api/client-setup/{profile_id}"
2. Add MCP: claude mcp add wolf-leader --url {mcp}
3. Verify hub: curl -s "{api}/health"
4. Before project work: use MCP recall or curl "{api}/api/bootstrap?path=<workspace>"
5. End of session: MCP save_session or curl "{api}/api/save-project-guide"

Report: MCP connected, hub health, and how to save sessions from this client.
"""

    return f"""Connect this Cursor workspace to {PRODUCT_NAME} ({label}).

Hub: {api}
MCP: {mcp}
Workspace path for this client: {workspace}

Do everything below on the **SSH host** (Remote-SSH target), not only on the laptop.

## Step 1 — Fetch client setup spec (mandatory)
curl -s "{api}/api/client-setup/{profile_id}"

## Step 2 — Install client bundle from hub (no git clone)
WOLF_LEADER_API={api} \\
WOLF_LEADER_MCP={mcp} \\
WORKSPACE={workspace} \\
  bash -c "$(curl -fsSL {api}/api/client-setup/install.sh)"

If curl pipe fails, download and run:
  curl -fsSL {api}/api/client-bundle.tar.gz -o /tmp/wl-client.tar.gz
  mkdir -p /tmp/wl-client && tar xzf /tmp/wl-client.tar.gz -C /tmp/wl-client
  WOLF_LEADER_API={api} WOLF_LEADER_MCP={mcp} WORKSPACE={workspace} /tmp/wl-client/scripts/install-cursor-client.sh

## Step 3 — Verify
curl -s "{api}/health"
test -f ~/.cursor/skills/save/SKILL.md && test -f ~/.cursor/wolf-leader.env

## Step 4 — Reload Cursor window
/save and /new must appear in the slash menu.

## Step 5 — Session start
MCP: resolve_project + recall — or curl "{api}/api/bootstrap?path={workspace}"

Report: skills (/save, /new), mcp.json wolf-leader entry, wolf-leader.env, hub health OK, workspace path used.
"""


def profile_payload(profile_id: str) -> dict[str, Any]:
    if profile_id not in PROFILES:
        raise KeyError(profile_id)
    urls = hub_urls()
    profile = PROFILES[profile_id]
    payload = {
        "id": profile_id,
        **profile,
        "hub_api": urls["api"],
        "hub_mcp": urls["mcp"],
        "setup_web_url": urls["setup_web"],
        "agent_prompt": build_agent_prompt(profile_id, urls=urls),
        "install_command": (
            f'WOLF_LEADER_API={urls["api"]} WOLF_LEADER_MCP={urls["mcp"]} '
            f'WORKSPACE={profile["workspace"]} '
            f'bash -c "$(curl -fsSL {urls["api"]}/api/client-setup/install.sh)"'
        ),
        "bundle_url": f'{urls["api"]}/api/client-bundle.tar.gz',
        "onboarding_url": f'{urls["api"]}/api/onboarding',
    }
    if profile.get("link_slug"):
        payload["workspace_link"] = {
            "slug": profile["link_slug"],
            "name": profile.get("link_name") or profile["link_slug"],
        }
    return payload


def list_profiles() -> dict[str, Any]:
    urls = hub_urls()
    return {
        "hub_api": urls["api"],
        "hub_mcp": urls["mcp"],
        "setup_web_url": urls["setup_web"],
        "default_profile": "cursor-generic",
        "profiles": [
            {
                "id": pid,
                "label": meta["label"],
                "description": meta["description"],
                "workspace": meta["workspace"],
            }
            for pid, meta in PROFILES.items()
        ],
    }


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
