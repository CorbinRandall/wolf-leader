"""Project continue modes and deploy-state defaults for typed checkpoints."""
from __future__ import annotations

import json
import os
from typing import Any, Optional

CONTINUE_MODES = (
    "compose_deploy",
    "compose_maintain",
    "server_daemon",
    "client_setup",
    "integration",
    "investigation",
    "external_host",
)

DEPLOY_STATES = ("deployed", "removed", "partial", "n/a")

# slug -> (continue_mode, default deploy_state)
SLUG_ARCHETYPES: dict[str, tuple[str, str]] = {
    "ssh-passwordless": ("client_setup", "partial"),
    "hermes": ("compose_deploy", "partial"),
    "moltbot": ("compose_deploy", "deployed"),
    "s3-sleep": ("server_daemon", "deployed"),
    "nextcloud": ("compose_maintain", "deployed"),
    "immich": ("compose_maintain", "deployed"),
    "metube": ("compose_deploy", "deployed"),
    "odysseus": ("compose_deploy", "removed"),
    "cache-drive": ("investigation", "n/a"),
    "claude-code": ("client_setup", "partial"),
    "custom-server-url": ("integration", "partial"),
    "google-sso": ("integration", "partial"),
    "wolf-leader": ("compose_maintain", "deployed"),
    "ide-storage": ("compose_maintain", "deployed"),
    "docker-dashboard": ("external_host", "deployed"),
    "memos": ("compose_deploy", "n/a"),
    "timemachine": ("compose_deploy", "n/a"),
}


def parse_metadata(raw: Any) -> dict:
    if not raw:
        return {}
    if isinstance(raw, dict):
        return raw
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return {}


def external_coords(project: dict[str, Any]) -> dict[str, Any]:
    """Documented coordinates for an external_host project (lives on another box)."""
    meta = parse_metadata(project.get("metadata"))
    return {
        "host": meta.get("external_host"),
        "path": meta.get("external_path"),
        "port": meta.get("external_port"),
        "url": meta.get("external_url"),
        "service": meta.get("external_service"),
        "note": meta.get("external_note"),
    }


def get_continue_mode(project: dict[str, Any]) -> str:
    meta = parse_metadata(project.get("metadata"))
    if meta.get("continue_mode") in CONTINUE_MODES:
        return meta["continue_mode"]
    slug = (project.get("slug") or "").lower()
    if slug in SLUG_ARCHETYPES:
        return SLUG_ARCHETYPES[slug][0]
    if project.get("compose_path"):
        return "compose_maintain" if slug in ("nextcloud", "immich", "wolf-leader", "ide-storage") else "compose_deploy"
    return "investigation"


def get_deploy_state(project: dict[str, Any]) -> str:
    meta = parse_metadata(project.get("metadata"))
    if meta.get("deploy_state") in DEPLOY_STATES:
        return meta["deploy_state"]
    slug = (project.get("slug") or "").lower()
    if slug in SLUG_ARCHETYPES:
        return SLUG_ARCHETYPES[slug][1]
    return "n/a"


def host_label_suffix() -> str:
    """Optional host name for pickup prompts (set IDE_STORAGE_HOST_LABEL in .env)."""
    label = os.environ.get("IDE_STORAGE_HOST_LABEL", "").strip()
    return f" on {label}" if label else ""


def pickup_prompt(project: dict[str, Any], *, public_base: str = "http://127.0.0.1:6971") -> str:
    """Mode-aware one-liner for Copy pickup prompt."""
    name = project.get("name") or project.get("slug") or "project"
    slug = project.get("slug") or f"project-{project['id']}"
    mode = get_continue_mode(project)
    state = get_deploy_state(project)
    brief = f"{public_base.rstrip('/')}/api/projects/{slug}/agent-brief"
    on_host = host_label_suffix()

    if mode == "client_setup":
        return (
            f"Continue {name}{on_host} — set up THIS device/client. "
            f"Load checkpoint: {brief}"
        )
    if mode == "compose_deploy" and state == "removed":
        return (
            f"Rebuild {name}{on_host} from saved spec (stack was removed). "
            f"Load: {brief}"
        )
    if mode == "server_daemon":
        return (
            f"Continue {name} tuning{on_host} (daemon/plugin, not compose). "
            f"Load: {brief}"
        )
    if mode == "compose_maintain":
        return (
            f"Continue {name}{on_host} — stack is running, fix/maintain only. "
            f"Load: {brief}"
        )
    if mode == "compose_deploy":
        return (
            f"Continue or deploy {name}{on_host}. "
            f"Load: {brief}"
        )
    if mode == "integration":
        return (
            f"Continue {name} integration setup{on_host}. "
            f"Load: {brief}"
        )
    if mode == "investigation":
        return (
            f"Continue {name} investigation{on_host}. "
            f"Load: {brief}"
        )
    if mode == "external_host":
        coords = external_coords(project)
        host = coords.get("host") or "a remote host"
        url = coords.get("url")
        where = f" ({url})" if url else ""
        return (
            f"Continue {name} — runs on {host}{where} as a systemd service; "
            f"maintain remotely, do NOT redeploy locally. Load: {brief}"
        )
    return f"Work on {name}{on_host}. Load: {brief}"


def metadata_patch(
    project: dict[str, Any],
    *,
    continue_mode: Optional[str] = None,
    deploy_state: Optional[str] = None,
) -> dict:
    meta = parse_metadata(project.get("metadata"))
    if continue_mode and continue_mode in CONTINUE_MODES:
        meta["continue_mode"] = continue_mode
    if deploy_state and deploy_state in DEPLOY_STATES:
        meta["deploy_state"] = deploy_state
    return meta
